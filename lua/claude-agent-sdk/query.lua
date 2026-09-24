-- A Query is one `claude` conversation: the process, the control channel, and
-- the demultiplexer that separates conversation messages from control traffic.
--
-- The TypeScript SDK models this as an async generator you iterate. Lua has no
-- equivalent, so messages are delivered to an `on_message` callback and the
-- imperative half of the SDK's Query (interrupt, set_permission_mode, ...) is
-- exposed as methods.

local Control = require("claude-agent-sdk.control")
local Transport = require("claude-agent-sdk.transport")
local options = require("claude-agent-sdk.options")

---@class claude_agent_sdk.Query
---@field private transport claude_agent_sdk.Transport
---@field private control claude_agent_sdk.Control
---@field private opts claude_agent_sdk.Options
---@field private info? table Payload of the initialize response.
---@field private commands table[] Kept current from `system/commands_changed`.
---@field private closed boolean
local Query = {}
Query.__index = Query

--- Frames that are transport bookkeeping rather than conversation.
local IGNORED = {
  -- Liveness ping while a long tool call runs.
  keep_alive = true,
  -- Transcript mirroring, only emitted for callers using a custom session store.
  transcript_mirror = true,
}

--- Fields of the `initialize` control request, mapped from snake_case options.
--- These are deliberately *not* CLI flags: the CLI takes them over the control
--- channel so they can carry structured values.
---@param opts claude_agent_sdk.Options
---@return table
local function initialize_payload(opts)
  local system_prompt = opts.system_prompt
  if type(system_prompt) == "string" then
    -- The wire format is a list of segments; a bare string is one segment.
    system_prompt = { system_prompt }
  end
  return vim.tbl_extend("force", {
    subtype = "initialize",
    systemPrompt = system_prompt,
    appendSystemPrompt = opts.append_system_prompt,
    appendSubagentSystemPrompt = opts.append_subagent_system_prompt,
    planModeInstructions = opts.plan_mode_instructions,
    title = opts.title,
    agents = opts.agents,
    skills = opts.skills,
    plugins = opts.plugins,
    toolAliases = opts.tool_aliases,
    excludeDynamicSections = opts.exclude_dynamic_sections,
    forwardSubagentText = opts.forward_subagent_text,
    agentProgressSummaries = opts.agent_progress_summaries,
    -- Turns on the `prompt_suggestion` message after each turn.
    promptSuggestions = opts.prompt_suggestions,
    workspaceTrust = opts.workspace_trust,
  }, opts.extra_initialize or {})
end

--- Convert a Lua permission result to the wire shape.
---@param result claude_agent_sdk.PermissionResult
---@param tool_use_id? string
---@return table
local function permission_result(result, tool_use_id)
  if result.behavior == "deny" then
    return {
      behavior = "deny",
      message = result.message or "The user denied this tool use.",
      interrupt = result.interrupt,
      toolUseID = tool_use_id,
    }
  end
  return {
    behavior = "allow",
    updatedInput = result.updated_input,
    -- Rule suggestions and mode changes; pass through in the CLI's own shape.
    updatedPermissions = (result.updated_permissions and #result.updated_permissions > 0)
        and result.updated_permissions
      or nil,
    toolUseID = tool_use_id,
  }
end

---@param opts claude_agent_sdk.Options
---@return claude_agent_sdk.Query
function Query.new(opts)
  local self = setmetatable({ opts = opts, commands = {}, closed = false }, Query)

  self.transport = Transport.new({
    argv = vim.list_extend({ opts.executable or "claude" }, options.build_argv(opts)),
    cwd = opts.cwd,
    env = options.build_env(opts),
    on_frame = function(frame)
      self:on_frame(frame)
    end,
    on_exit = function(code, stderr)
      self.closed = true
      self.control:fail_all("claude process exited")
      if opts.on_exit then
        opts.on_exit(code, stderr)
      end
    end,
  })
  self.control = Control.new(function(frame)
    return self.transport:write(frame)
  end)

  local ok, err = self.transport:spawn()
  if not ok then
    self.closed = true
    self:fail(("could not start %s: %s"):format(opts.executable or "claude", err))
    return self
  end

  -- The handshake carries everything that is not expressible as a flag, and its
  -- response is the only source of the session's slash commands and models.
  self.control:request("initialize", initialize_payload(opts), function(response, request_err)
    if request_err then
      self:fail("initialize failed: " .. request_err)
      return
    end
    self.info = response
    self.commands = response.commands or {}
    if opts.on_ready then
      opts.on_ready(response)
    end
  end)

  return self
end

---@private
---@param message string
function Query:fail(message)
  if self.opts.on_error then
    self.opts.on_error(message)
  end
end

---@private
---@param frame table
function Query:on_frame(frame)
  local kind = frame.type
  if kind == "control_response" then
    self.control:on_response(frame)
  elseif kind == "control_request" then
    self.control:on_request(frame, self:control_handlers())
  elseif kind == "control_cancel_request" then
    self.control:on_cancel(frame)
  elseif kind == "__malformed" then
    self:fail("non-JSON output from claude: " .. tostring(frame.line))
  elseif not IGNORED[kind] then
    -- Slash commands can change mid-session (a plugin loads, a directory is
    -- added), so keep the cached list current.
    if kind == "system" and frame.subtype == "commands_changed" and frame.commands then
      self.commands = frame.commands
    end
    if self.opts.on_message then
      self.opts.on_message(frame)
    end
  end
end

---@private
---@return table<string, fun(request: table, respond: fun(result: table), ctx: table)>
function Query:control_handlers()
  return {
    can_use_tool = function(request, respond, ctx)
      if not self.opts.can_use_tool then
        error("can_use_tool option is not set")
      end
      self.opts.can_use_tool(request.tool_name, request.input or {}, {
        tool_use_id = request.tool_use_id,
        suggestions = request.permission_suggestions or {},
        display_name = request.display_name,
        description = request.description,
        title = request.title,
        default_to_no = request.default_to_no == true,
        suppress_always_allow_rule = request.suppress_always_allow_rule == true,
        blocked_path = request.blocked_path,
        decision_reason = request.decision_reason,
        agent_id = request.agent_id,
        mcp_server = request.mcp_server,
        request_id = ctx.request_id,
        on_cancel = ctx.on_cancel,
      }, function(result)
        respond(permission_result(result, request.tool_use_id))
      end)
    end,
  }
end

-- Sending ----------------------------------------------------------------------

--- Append a user message. With `should_query = false` the message becomes
--- context for the next turn instead of starting one.
---@param message { text?: string, content?: table[], images?: claude_agent_sdk.Image[], should_query?: boolean }
---@return boolean sent
function Query:send(message)
  local content = message.content
  if not content then
    local images = message.images or {}
    if #images == 0 then
      content = message.text or ""
    else
      -- Images lead, as the Messages API recommends.
      content = {}
      for _, image in ipairs(images) do
        table.insert(content, {
          type = "image",
          source = { type = "base64", media_type = image.media_type, data = image.data },
        })
      end
      table.insert(content, { type = "text", text = message.text or "" })
    end
  end
  local frame = {
    type = "user",
    message = { role = "user", content = content },
    -- Must serialise as JSON null, not be absent.
    parent_tool_use_id = vim.NIL,
  }
  if message.should_query == false then
    frame.shouldQuery = false
  end
  return self.transport:write(frame)
end

-- Control methods ---------------------------------------------------------------
--
-- Every method here is one control_request. Wire field names are the CLI's, so
-- they stay camelCase or snake_case exactly as the CLI spells them (it is not
-- consistent — `serverName` next to `max_thinking_tokens`); the Lua-facing
-- arguments are snake_case throughout.
--
-- Each takes an optional `callback(response, err)`. Fire-and-forget is fine:
-- with no callback the response is simply discarded.
--
-- Subtypes come and go between Claude Code releases. An unknown one answers
-- with "Unsupported control request subtype" rather than hanging, so a method
-- the installed CLI is too old for surfaces as an ordinary error on the
-- callback. Against 2.1.263, `get_status`, `list_permission_rules` and
-- `export_conversation` answer that way; everything else here works.

--- Escape hatch for control subtypes without a named wrapper — the CLI exposes
--- roughly sixty, and they change between releases.
---@param subtype string
---@param params? table
---@param callback? fun(response?: table, err?: string)
function Query:request(subtype, params, callback)
  self.control:request(subtype, params, callback)
end

-- Turn control

--- Stop the current turn. `cancel_queued` also drops messages waiting behind it;
--- the response reports what was still queued and what was cancelled.
---@param opts? { cancel_queued?: boolean }|fun(response?: table, err?: string)
---@param callback? fun(response?: table, err?: string)
function Query:interrupt(opts, callback)
  if type(opts) == "function" then
    opts, callback = nil, opts
  end
  self.control:request("interrupt", (opts or {}).cancel_queued and { cancel_queued = true } or nil, callback)
end

---@param task_id string
---@param callback? fun(response?: table, err?: string)
function Query:stop_task(task_id, callback)
  self.control:request("stop_task", { task_id = task_id }, callback)
end

--- Whether a tool call is still running in the background.
---@param tool_use_id? string
---@param callback? fun(response?: table, err?: string)
function Query:background_tasks(tool_use_id, callback)
  self.control:request("background_tasks", { tool_use_id = tool_use_id }, callback)
end

-- Model and thinking

---@param model? string
---@param callback? fun(response?: table, err?: string)
function Query:set_model(model, callback)
  self.control:request("set_model", { model = model }, callback)
end

---@param max_thinking_tokens integer|nil nil clears the override.
---@param thinking_display? "summarized"|"omitted"|"highlights"
---@param callback? fun(response?: table, err?: string)
function Query:set_max_thinking_tokens(max_thinking_tokens, thinking_display, callback)
  self.control:request(
    "set_max_thinking_tokens",
    { max_thinking_tokens = max_thinking_tokens or vim.NIL, thinking_display = thinking_display },
    callback
  )
end

-- Permissions and settings

---@param mode claude_agent_sdk.PermissionMode
---@param callback? fun(response?: table, err?: string)
function Query:set_permission_mode(mode, callback)
  self.control:request("set_permission_mode", { mode = mode }, callback)
end

---@param callback fun(response?: table, err?: string)
function Query:list_permission_rules(callback)
  self.control:request("list_permission_rules", nil, callback)
end

---@param source "localSettings"|"userSettings"
---@param settings table
---@param callback? fun(response?: table, err?: string)
function Query:update_settings(source, settings, callback)
  self.control:request("update_settings", { source = source, settings = settings }, callback)
end

---@param settings table
---@param callback? fun(response?: table, err?: string)
function Query:apply_flag_settings(settings, callback)
  self.control:request("apply_flag_settings", { settings = settings }, callback)
end

---@param callback fun(response?: table, err?: string)
function Query:get_settings(callback)
  self.control:request("get_settings", nil, callback)
end

-- Session and workspace

---@param title string
---@param callback? fun(response?: table, err?: string)
function Query:rename_session(title, callback)
  self.control:request("rename_session", { title = title }, callback)
end

---@param path string
---@param opts? { trust_accepted?: boolean }
---@param callback? fun(response?: table, err?: string)
function Query:set_cwd(path, opts, callback)
  local params = { path = path }
  if opts and opts.trust_accepted ~= nil then
    params.trust_accepted = opts.trust_accepted
  end
  self.control:request("set_cwd", params, callback)
end

--- Undo the file changes made since a user message. `dry_run` reports what
--- would change without touching anything.
---@param user_message_id string
---@param opts? { dry_run?: boolean }
---@param callback? fun(response?: table, err?: string)
function Query:rewind_files(user_message_id, opts, callback)
  self.control:request(
    "rewind_files",
    { user_message_id = user_message_id, dry_run = opts and opts.dry_run or nil },
    callback
  )
end

--- Tell the CLI a file has already been read, so an edit isn't refused for
--- want of a prior Read.
---@param path string
---@param mtime integer
---@param callback? fun(response?: table, err?: string)
function Query:seed_read_state(path, mtime, callback)
  self.control:request("seed_read_state", { path = path, mtime = mtime }, callback)
end

---@param path string
---@param opts? { max_bytes?: integer, encoding?: string }
---@param callback fun(response?: table, err?: string)
function Query:read_file(path, opts, callback)
  self.control:request(
    "read_file",
    { path = path, max_bytes = opts and opts.max_bytes, encoding = opts and opts.encoding },
    callback
  )
end

---@param callback fun(response?: table, err?: string)
function Query:export_conversation(callback)
  self.control:request("export_conversation", nil, callback)
end

-- Status and usage

---@param callback fun(response?: table, err?: string)
function Query:get_status(callback)
  self.control:request("get_status", nil, callback)
end

---@param opts? { skip_behaviors?: boolean }
---@param callback fun(response?: table, err?: string)
function Query:get_usage(opts, callback)
  self.control:request("get_usage", (opts or {}).skip_behaviors and { skip_behaviors = true } or nil, callback)
end

---@param callback fun(response?: table, err?: string)
function Query:get_context_usage(callback)
  self.control:request("get_context_usage", nil, callback)
end

---@param callback fun(response?: table, err?: string)
function Query:get_plan(callback)
  self.control:request("get_plan", nil, callback)
end

-- MCP

---@param callback fun(response?: table, err?: string)
function Query:mcp_server_status(callback)
  self.control:request("mcp_status", nil, callback)
end

---@param server_name string
---@param callback? fun(response?: table, err?: string)
function Query:reconnect_mcp_server(server_name, callback)
  self.control:request("mcp_reconnect", { serverName = server_name }, callback)
end

---@param server_name string
---@param enabled boolean
---@param callback? fun(response?: table, err?: string)
function Query:toggle_mcp_server(server_name, enabled, callback)
  self.control:request("mcp_toggle", { serverName = server_name, enabled = enabled }, callback)
end

---@param server_name string
---@param uri string
---@param callback fun(response?: table, err?: string)
function Query:read_mcp_resource(server_name, uri, callback)
  self.control:request("mcp_read_resource", { serverName = server_name, uri = uri }, callback)
end

---@param servers table<string, table>
---@param callback? fun(response?: table, err?: string)
function Query:set_mcp_servers(servers, callback)
  self.control:request("mcp_set_servers", { servers = servers }, callback)
end

---@param server_name string
---@param mode "default"|"auto"|nil
---@param callback? fun(response?: table, err?: string)
function Query:set_mcp_permission_mode_override(server_name, mode, callback)
  self.control:request("set_mcp_permission_mode_override", { serverName = server_name, mode = mode or vim.NIL }, callback)
end

-- Reloading

---@param opts? { hold_on_cache_impact?: boolean }
---@param callback? fun(response?: table, err?: string)
function Query:reload_plugins(opts, callback)
  self.control:request("reload_plugins", (opts or {}).hold_on_cache_impact and { hold_on_cache_impact = true } or nil, callback)
end

---@param callback? fun(response?: table, err?: string)
function Query:reload_skills(callback)
  self.control:request("reload_skills", nil, callback)
end

---@param callback? fun(response?: table, err?: string)
function Query:reload_output_styles(callback)
  self.control:request("reload_output_styles", nil, callback)
end

--- Re-run the handshake, picking up configuration that changed since start.
---@param callback? fun(response?: table, err?: string)
function Query:reinitialize(callback)
  self.control:request("initialize", initialize_payload(self.opts), function(response, err)
    if response then
      self.info = response
      self.commands = response.commands or self.commands
    end
    if callback then
      callback(response, err)
    end
  end)
end

-- Accessors ---------------------------------------------------------------------

--- Slash commands for this session (empty until the handshake completes).
---@return table[]
function Query:supported_commands()
  return self.commands
end

---@return table[]
function Query:supported_models()
  return self.info and self.info.models or {}
end

---@return table[]
function Query:supported_agents()
  return self.info and self.info.agents or {}
end

--- The signed-in account, as reported by the handshake.
---@return table?
function Query:account_info()
  return self.info and self.info.account or nil
end

--- The whole initialize response, for anything without an accessor.
---@return table?
function Query:initialization_result()
  return self.info
end

function Query:running()
  return not self.closed and self.transport:running()
end

--- Finish the conversation and let the process exit.
function Query:close()
  self.transport:close()
end

return Query
