-- Turns SDK options into a `claude` argv.
--
-- The TypeScript SDK's ProcessTransport does exactly this and nothing more:
-- every option is either a CLI flag or a field of the `initialize` control
-- request (see control.lua). Flag spellings here mirror that builder — note
-- `--allowedTools` is camelCase while its neighbours are kebab-case; that
-- inconsistency is the CLI's, and matching it matters.

local M = {}

--- Fixed prefix. `--verbose` is required alongside stream-json output.
local BASE = { "--output-format", "stream-json", "--verbose", "--input-format", "stream-json" }

--- Flags whose value is joined with `=` rather than passed as a second argv entry.
local EQUALS = {
  resume = "--resume",
  session_id = "--session-id",
  setting_sources = "--setting-sources",
  project_config_root = "--project-config-root",
  resume_session_at = "--resume-session-at",
}

--- `--flag value`, or `--flag=value` when the value looks like a flag itself.
--- Mirrors the SDK's own escaping of leading-dash values.
---@param argv string[]
---@param flag string
---@param value string
local function push_value(argv, flag, value)
  if #value > 1 and value:sub(1, 1) == "-" then
    table.insert(argv, ("--%s=%s"):format(flag, value))
  else
    table.insert(argv, "--" .. flag)
    table.insert(argv, value)
  end
end

---@param list? string[]
---@return string?
local function csv(list)
  if not list or #list == 0 then
    return nil
  end
  return table.concat(list, ",")
end

--- Build the argv for `claude`, excluding the executable itself.
---@param opts claude_agent_sdk.Options
---@return string[]
function M.build_argv(opts)
  local argv = vim.list_extend({}, BASE)

  local function flag(name, value)
    if value ~= nil then
      table.insert(argv, "--" .. name)
      table.insert(argv, tostring(value))
    end
  end
  local function bare(name, enabled)
    if enabled then
      table.insert(argv, "--" .. name)
    end
  end
  local function equals(key, value)
    if value ~= nil then
      table.insert(argv, ("%s=%s"):format(EQUALS[key], value))
    end
  end

  -- Thinking: an explicit budget switches the CLI to the legacy token flag.
  local thinking = opts.thinking
  if thinking then
    if thinking.type == "enabled" and thinking.budget_tokens then
      flag("max-thinking-tokens", thinking.budget_tokens)
    elseif thinking.type == "disabled" then
      flag("thinking", "disabled")
    else
      flag("thinking", "adaptive")
    end
    if thinking.type ~= "disabled" and thinking.display then
      flag("thinking-display", thinking.display)
    end
  end

  flag("effort", opts.effort)
  flag("max-turns", opts.max_turns)
  flag("max-budget-usd", opts.max_budget_usd)
  flag("model", opts.model)
  flag("fallback-model", opts.fallback_model)
  flag("agent", opts.agent)
  flag("betas", csv(opts.betas))
  flag("permission-mode", opts.permission_mode)
  flag("allowedTools", csv(opts.allowed_tools))
  flag("disallowedTools", csv(opts.disallowed_tools))

  -- A canUseTool handler is wired up by asking the CLI to prompt over stdio.
  if opts.can_use_tool then
    if opts.permission_prompt_tool_name then
      error("can_use_tool and permission_prompt_tool_name are mutually exclusive")
    end
    flag("permission-prompt-tool", "stdio")
  else
    flag("permission-prompt-tool", opts.permission_prompt_tool_name)
  end

  if opts.mcp_servers and not vim.tbl_isempty(opts.mcp_servers) then
    flag("mcp-config", vim.json.encode({ mcpServers = opts.mcp_servers }))
  end

  equals("resume", opts.resume)
  -- `--session-id` names a *new* session, so it is meaningless while resuming.
  equals("session_id", not opts.resume and opts.session_id or nil)
  equals("setting_sources", csv(opts.setting_sources))
  equals("project_config_root", opts.project_config_root)
  equals("resume_session_at", opts.resume_session_at)

  bare("continue", opts.continue_conversation)
  bare("fork-session", opts.fork_session)
  bare("strict-mcp-config", opts.strict_mcp_config)
  bare("include-partial-messages", opts.include_partial_messages)
  bare("include-hook-events", opts.include_hook_events)
  bare("no-session-persistence", opts.persist_session == false)
  -- The CLI refuses bypassPermissions unless the caller opts in explicitly.
  bare("allow-dangerously-skip-permissions", opts.allow_dangerously_skip_permissions)

  for _, dir in ipairs(opts.add_dirs or {}) do
    table.insert(argv, "--add-dir")
    table.insert(argv, dir)
  end

  for key, value in pairs(opts.extra_args or {}) do
    if value == true then
      table.insert(argv, "--" .. key)
    else
      push_value(argv, key, tostring(value))
    end
  end

  return argv
end

--- Environment overlaid on the inherited one.
---@param opts claude_agent_sdk.Options
---@return table<string, string>
function M.build_env(opts)
  return vim.tbl_extend("force", {
    -- Not only telemetry: the CLI gates features on this. Measured against
    -- 2.1.263, an unrecognised value exposes two artifact skills that "sdk-ts"
    -- hides, so the default reproduces the TypeScript SDK's behaviour exactly.
    -- Override it only once you know which side of that gate you want.
    CLAUDE_CODE_ENTRYPOINT = opts.entrypoint or "sdk-ts",
    -- Node flags meant for the parent must not leak into a CLI that may itself
    -- be a Node script; the TypeScript SDK deletes this for the same reason.
    NODE_OPTIONS = "",
  }, opts.env or {})
end

return M
