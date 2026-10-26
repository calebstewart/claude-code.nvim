-- Custom tools: Lua functions Claude can call, served to each session from an
-- in-process MCP server named "nvim" (see claude-agent-sdk/mcp.lua). Claude
-- sees a tool named `foo` as `mcp__nvim__foo`, and calls to it go through the
-- usual permission prompt.
--
-- Tools come from the `tools` option and from `register()`. Both are read when
-- a session's process starts, so a tool added later reaches sessions started
-- (or resumed after an idle suspend) from then on.
--
-- Only the direct transport serves them for now.

local config = require("claude-code.config")

local M = {}

--- Name of the MCP server; tools are `mcp__<SERVER>__<name>` to Claude and in
--- permission rules.
M.SERVER = "nvim"

--- A tool for Claude to call.
---@class claude_code.Tool
---@field name string Letters, digits, `_` and `-`; up to 64.
---@field description string What it does and when to use it — this is all Claude has to go on.
---@field input_schema? table JSON Schema for the arguments (an object schema); nil takes none.
---@field handler claude_code.ToolHandler
---@field title? string Human-readable name.
---@field annotations? { readOnlyHint?: boolean, destructiveHint?: boolean, idempotentHint?: boolean, openWorldHint?: boolean } MCP hints about the tool's behaviour.

--- Runs on the main loop, so the whole Neovim API is available. Return the
--- result, or return nothing and call `done(result)` later, exactly once (for
--- work that waits on a callback, like an LSP request). `done(nil, err)` or
--- raising an error reports a failure to Claude (`error(msg, 0)` leaves out the
--- file and line).
---
--- A result is a string, an MCP CallToolResult
--- (`{ content = { { type = "text", text = "..." } }, is_error = true? }`), or
--- any other value, which Claude receives as JSON.
---@alias claude_code.ToolHandler fun(input: table, ctx: claude_code.ToolContext, done: fun(result?: any, err?: string)): any

---@class claude_code.ToolContext
---@field session_id? string The session calling the tool.
---@field cwd string The session's working directory.
---@field tool_use_id? string
---@field cancelled fun(): boolean Whether the call was withdrawn (Claude was interrupted).
---@field on_cancel fun(fn: fun()) Register a callback for when the call is withdrawn; `done` is then ignored.

--- Tools added with `register()`, by name.
---@type table<string, claude_code.Tool>
local registered = {}

--- Invalid entries in the `tools` option already reported, so each is reported once.
---@type table<table, true>
local reported = setmetatable({}, { __mode = "k" })

---@param tool claude_code.Tool
---@return string? err
local function invalid(tool)
  local ok, err = pcall(require("claude-agent-sdk.mcp").validate_tool, tool)
  return not ok and tostring(err) or nil
end

--- Add a tool, replacing any registered tool of the same name (and shadowing
--- one of that name in the `tools` option). Raises if the definition is invalid.
---@param tool claude_code.Tool
function M.register(tool)
  local err = invalid(tool)
  if err then
    error("claude-code: " .. err, 0)
  end
  registered[tool.name] = tool
end

--- Remove a tool added with `register()`.
---@param name string
function M.unregister(name)
  registered[name] = nil
end

--- Every tool, in a stable order: the `tools` option, then registered tools.
--- Invalid entries in the option are reported and skipped.
---@return claude_code.Tool[]
function M.list()
  local tools, seen = {}, {}
  for _, tool in ipairs(config.options.tools or {}) do
    local err = invalid(tool)
    if err then
      if type(tool) ~= "table" or not reported[tool] then
        if type(tool) == "table" then
          reported[tool] = true
        end
        vim.notify("claude-code: ignoring a tool in `tools`: " .. err, vim.log.levels.WARN)
      end
    elseif registered[tool.name] == nil and not seen[tool.name] then
      seen[tool.name] = true
      table.insert(tools, tool)
    end
  end
  local names = vim.tbl_keys(registered)
  table.sort(names)
  for _, name in ipairs(names) do
    table.insert(tools, registered[name])
  end
  return tools
end

--- The `mcp_servers` entry serving every tool to one session, or nil when there
--- are no tools.
---@param session { session_id?: string, cwd: string }
---@return table<string, claude_agent_sdk.McpSdkServerConfig>?
function M.servers(session)
  local tools = M.list()
  if #tools == 0 then
    return nil
  end
  local sdk = require("claude-agent-sdk")
  local defs = {}
  for _, tool in ipairs(tools) do
    local handler = tool.handler
    table.insert(
      defs,
      sdk.tool(tool.name, tool.description, tool.input_schema, function(input, ctx, done)
        return handler(input, {
          session_id = session.session_id,
          cwd = session.cwd,
          tool_use_id = ctx.tool_use_id,
          cancelled = ctx.cancelled,
          on_cancel = ctx.on_cancel,
        }, done)
      end, { title = tool.title, annotations = tool.annotations })
    )
  end
  return { [M.SERVER] = sdk.create_sdk_mcp_server({ name = M.SERVER, tools = defs }) }
end

--- Tools need the direct transport for now; say so once, rather than leaving
--- them silently missing.
local warned = false
function M.warn_unsupported()
  if warned or #M.list() == 0 then
    return
  end
  warned = true
  vim.notify(
    'claude-code: custom tools need `transport = "direct"`; the sidecar transport doesn\'t serve them yet',
    vim.log.levels.WARN
  )
end

return M
