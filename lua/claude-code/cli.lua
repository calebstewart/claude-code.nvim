-- Session transport that drives `claude` directly through the Lua port of the
-- Agent SDK, with no Node sidecar in between.
--
-- It presents the same interface and emits the same events as sidecar.lua (see
-- sidecar/src/protocol.ts), so session.lua works with either one. Selected by
-- `transport = "direct"` in setup(); see claude-code/transport.lua.

local sdk = require("claude-agent-sdk")

---@class claude_code.Cli
---@field private query? claude_agent_sdk.Query
---@field private on_event fun(event: claude_code.SidecarEvent)
---@field private on_exit fun(code: integer, stderr: string)
---@field private permissions table<integer, { respond: fun(result: table), suggestions: table[] }>
---@field private next_permission integer
local Cli = {}
Cli.__index = Cli

---@param handlers { on_event: fun(event: claude_code.SidecarEvent), on_exit: fun(code: integer, stderr: string) }
---@param args? string[] Accepted for interface parity; the node sidecar's `--control` mode has no equivalent here.
---@return claude_code.Cli
function Cli.new(handlers, args)
  if args and #args > 0 then
    error("claude-code: the direct transport has no control mode (got " .. table.concat(args, " ") .. ")")
  end
  return setmetatable({
    on_event = handlers.on_event,
    on_exit = handlers.on_exit,
    permissions = {},
    next_permission = 1,
  }, Cli)
end

--- The permission card protocol is keyed by integer, so each CLI request is
--- given an id and its responder parked until the user answers.
---@private
---@param tool_name string
---@param input table
---@param ctx claude_agent_sdk.PermissionContext
---@param respond fun(result: claude_agent_sdk.PermissionResult)
function Cli:on_permission(tool_name, input, ctx, respond)
  local id = self.next_permission
  self.next_permission = id + 1
  self.permissions[id] = { respond = respond, suggestions = ctx.suggestions }
  ctx.on_cancel(function()
    if self.permissions[id] then
      self.permissions[id] = nil
      self.on_event({ type = "permission_cancel", id = id })
    end
  end)
  self.on_event({
    type = "permission_request",
    id = id,
    tool_use_id = ctx.tool_use_id,
    tool_name = tool_name,
    input = input,
    title = ctx.title,
    description = ctx.description,
    has_suggestions = #ctx.suggestions > 0,
    default_to_no = ctx.default_to_no,
    suppress_always = ctx.suppress_always_allow_rule,
    -- Set when a subagent is asking. session.lua works out the subagent from the
    -- tool_use id instead, but the sidecar sends this, so keep the shapes equal.
    agent_id = ctx.agent_id,
  })
end

---@param init claude_code.InitRequest
function Cli:start(init)
  local session_id = init.resume or init.session_id
  self.query = sdk.query({
    executable = init.claude_path,
    cwd = init.cwd,
    model = init.model,
    permission_mode = init.permission_mode,
    -- The CLI rejects bypassPermissions unless the caller opts in explicitly.
    allow_dangerously_skip_permissions = init.permission_mode == "bypassPermissions" or nil,
    resume = init.resume,
    session_id = init.session_id,
    title = init.title,
    -- Without this the session runs with an empty system prompt, not Claude Code's.
    system_prompt = { type = "preset", preset = "claude_code" },
    include_partial_messages = true,
    -- Absent means on, as in the node sidecar.
    prompt_suggestions = init.prompt_suggestions ~= false,
    on_ready = function(info)
      self.on_event({ type = "ready", session_id = session_id })
      self.on_event({ type = "commands", commands = info.commands or {} })
    end,
    on_message = function(message)
      self.on_event({ type = "sdk", message = message })
    end,
    can_use_tool = function(tool_name, input, ctx, respond)
      self:on_permission(tool_name, input, ctx, respond)
    end,
    on_error = function(message)
      self.on_event({ type = "error", message = message })
    end,
    on_exit = function(code, stderr)
      self.query = nil
      self.permissions = {}
      self.on_exit(code, stderr)
    end,
  })
end

---@param request table
function Cli:send(request)
  local query = self.query
  if not query then
    return
  end
  if request.type == "prompt" then
    query:send({ text = request.text, images = request.images, should_query = request.should_query })
  elseif request.type == "interrupt" then
    query:interrupt()
  elseif request.type == "set_permission_mode" then
    query:set_permission_mode(request.mode, function(_, err)
      if err then
        self.on_event({ type = "error", message = ("Couldn't switch to %s: %s"):format(request.mode, err) })
      end
    end)
  elseif request.type == "permission_response" then
    local pending = self.permissions[request.id]
    if not pending then
      return
    end
    self.permissions[request.id] = nil
    if request.behavior == "deny" then
      pending.respond({ behavior = "deny", message = request.message })
    else
      -- "Always allow" applies the rules the CLI suggested alongside the request.
      local updates = request.always and vim.deepcopy(pending.suggestions) or {}
      if request.set_mode then
        table.insert(updates, { type = "setMode", mode = request.set_mode, destination = "session" })
      end
      pending.respond({
        behavior = "allow",
        updated_input = request.updated_input,
        updated_permissions = updates,
      })
    end
  else
    self.on_event({ type = "error", message = "Unknown request type: " .. tostring(request.type) })
  end
end

function Cli:running()
  return self.query ~= nil and self.query:running()
end

--- Closing stdin tells the CLI to finish the session and exit.
function Cli:stop()
  if self.query then
    self.query:close()
  end
end

return Cli
