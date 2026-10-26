-- In-process MCP servers: tools whose handlers run inside Neovim.
--
-- The TypeScript SDK's `createSdkMcpServer()` and `tool()` build these. The CLI
-- treats such a server like any other MCP server, except that instead of
-- spawning it, it relays the server's JSON-RPC traffic through the host over
-- the control channel:
--
--   argv        --mcp-config {"mcpServers":{"nvim":{"type":"sdk","name":"nvim"}}}
--   initialize  { ..., sdkMcpServers = { "nvim" } }
--   in          control_request { subtype = "mcp_message", server_name = "nvim", message = <JSON-RPC> }
--   out         control_response { response = { mcp_response = <JSON-RPC reply> } }
--
-- Only the tools half of MCP is implemented: `initialize`, `ping`, `tools/list`
-- and `tools/call`, plus the `notifications/cancelled` that withdraws a call.
-- Claude sees each tool as `mcp__<server>__<tool>`, and calls to it go through
-- `can_use_tool` like any other tool.

local M = {}

--- What Claude sees of a tool and how to run it. See `M.tool`.
---@class claude_agent_sdk.McpTool
---@field name string
---@field description string
---@field input_schema table JSON Schema for the arguments (an object schema).
---@field handler claude_agent_sdk.McpToolHandler
---@field title? string Human-readable name.
---@field annotations? { title?: string, readOnlyHint?: boolean, destructiveHint?: boolean, idempotentHint?: boolean, openWorldHint?: boolean }
---@field meta? table Sent as the tool's `_meta`, verbatim.

--- Runs a tool. Either return the result, or return nothing and call `done`
--- later (exactly once). `done(nil, err)` and a thrown error both report an
--- error to Claude.
---
--- A result is a string (one text block), an MCP CallToolResult table
--- (`{ content = { { type = "text", text = ... } }, is_error?, structured_content? }`),
--- or any other value, which is sent to Claude as JSON.
---@alias claude_agent_sdk.McpToolHandler fun(input: table, ctx: claude_agent_sdk.McpToolContext, done: fun(result?: any, err?: string)): any

---@class claude_agent_sdk.McpToolContext
---@field server string Name of the server the tool belongs to.
---@field tool_use_id? string The tool_use block this call answers, when the CLI says.
---@field cancelled fun(): boolean Whether Claude has withdrawn the call (an interrupt, say).
---@field on_cancel fun(fn: fun()) Register a callback for when the call is withdrawn; `done` is then ignored.

--- An SDK server, as it goes in `mcp_servers`.
---@class claude_agent_sdk.McpSdkServerConfig
---@field type "sdk"
---@field name string
---@field instance claude_agent_sdk.McpServer

local JSONRPC_METHOD_NOT_FOUND = -32601
local JSONRPC_INVALID_PARAMS = -32602

--- Used when the client doesn't name a protocol version. Tools have not changed
--- shape across revisions, so whatever the client asks for is answered in kind.
local DEFAULT_PROTOCOL_VERSION = "2025-06-18"

--- Where the CLI puts the tool_use id in `tools/call`'s `_meta`.
local TOOL_USE_ID_META = "claudecode/toolUseId"

--- An empty Lua table encodes as a JSON array; these must be objects.
---@param value any
---@return any
local function object(value)
  if type(value) == "table" and next(value) == nil then
    return vim.empty_dict()
  end
  return value
end

--- Fill the gaps that make a hand-written schema fail to encode as intended:
--- a missing schema, and `properties = {}` (which would become `[]`).
---@param schema? table
---@return table
local function normalize_schema(schema)
  schema = vim.deepcopy(schema or {})
  schema.type = schema.type or "object"
  if schema.type == "object" then
    schema.properties = object(schema.properties or {})
  end
  return schema
end

---@param text string
---@return table
local function error_result(text)
  return { content = { { type = "text", text = text } }, isError = true }
end

--- A handler's return value as a CallToolResult.
---@param value any
---@return table
local function to_result(value)
  if value == nil or value == vim.NIL then
    return { content = {} }
  end
  if type(value) == "string" then
    return { content = { { type = "text", text = value } } }
  end
  if type(value) == "table" and type(value.content) == "table" then
    local result = {
      content = value.content,
      structuredContent = value.structured_content or value.structuredContent,
      _meta = value.meta or value._meta,
    }
    local is_error = value.is_error
    if is_error == nil then
      is_error = value.isError
    end
    result.isError = is_error and true or nil
    return result
  end
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    return error_result("tool result could not be encoded as JSON: " .. tostring(encoded))
  end
  return { content = { { type = "text", text = encoded } } }
end

--- Define a tool. Mirrors the TypeScript SDK's `tool()`, with a JSON Schema in
--- place of a zod shape.
---@param name string Letters, digits, `_` and `-`.
---@param description string
---@param input_schema? table JSON Schema; nil takes no arguments.
---@param handler claude_agent_sdk.McpToolHandler
---@param extras? { title?: string, annotations?: table, meta?: table }
---@return claude_agent_sdk.McpTool
function M.tool(name, description, input_schema, handler, extras)
  extras = extras or {}
  return {
    name = name,
    description = description,
    input_schema = input_schema,
    handler = handler,
    title = extras.title,
    annotations = extras.annotations,
    meta = extras.meta,
  }
end

---@class claude_agent_sdk.McpServer
---@field name string
---@field version string
---@field private tools table<string, claude_agent_sdk.McpTool>
---@field private order string[]
---@field private calls table<string|number, { cancelled: boolean, on_cancel: fun()[], cancel: fun() }> In-flight `tools/call`s by JSON-RPC id.
local Server = {}
Server.__index = Server

--- Check a tool definition, raising on anything the CLI would reject or that
--- would only fail when Claude calls it.
---@param tool claude_agent_sdk.McpTool
function M.validate_tool(tool)
  if type(tool) ~= "table" then
    error("tool must be a table", 0)
  end
  if type(tool.name) ~= "string" or not tool.name:match("^[%w_-]+$") or #tool.name > 64 then
    error(("tool name %s must be 1-64 letters, digits, `_` or `-`"):format(vim.inspect(tool.name)), 0)
  end
  if type(tool.description) ~= "string" or tool.description == "" then
    error(("tool %q needs a description"):format(tool.name), 0)
  end
  if type(tool.handler) ~= "function" then
    error(("tool %q needs a handler function"):format(tool.name), 0)
  end
  if tool.input_schema ~= nil and type(tool.input_schema) ~= "table" then
    error(("tool %q: input_schema must be a table"):format(tool.name), 0)
  end
end

---@param opts { name: string, version?: string, tools?: claude_agent_sdk.McpTool[] }
---@return claude_agent_sdk.McpServer
function Server.new(opts)
  local self = setmetatable({
    name = opts.name,
    version = opts.version or "1.0.0",
    tools = {},
    order = {},
    calls = {},
  }, Server)
  for _, tool in ipairs(opts.tools or {}) do
    M.validate_tool(tool)
    if self.tools[tool.name] then
      error(("duplicate tool %q in server %q"):format(tool.name, opts.name), 0)
    end
    self.tools[tool.name] = tool
    table.insert(self.order, tool.name)
  end
  return self
end

---@return string[]
function Server:tool_names()
  return vim.list_extend({}, self.order)
end

---@private
---@return table[]
function Server:list_tools()
  local tools = {}
  for _, name in ipairs(self.order) do
    local tool = self.tools[name]
    table.insert(tools, {
      name = tool.name,
      title = tool.title,
      description = tool.description,
      inputSchema = normalize_schema(tool.input_schema),
      annotations = tool.annotations and object(tool.annotations) or nil,
      _meta = tool.meta and object(tool.meta) or nil,
    })
  end
  return tools
end

--- Handle one JSON-RPC request. `reply` receives the complete JSON-RPC
--- response; it is not called for a call that was cancelled.
---@param message table
---@param reply fun(response: table)
---@param on_transport_cancel? fun(fn: fun()) The control request carrying this message was withdrawn.
function Server:handle(message, reply, on_transport_cancel)
  local id = message.id
  local function ok(result)
    reply({ jsonrpc = "2.0", id = id, result = object(result) })
  end
  local function fail(code, text)
    reply({ jsonrpc = "2.0", id = id, error = { code = code, message = text } })
  end

  local method = message.method
  local params = type(message.params) == "table" and message.params or {}
  if method == "initialize" then
    ok({
      protocolVersion = type(params.protocolVersion) == "string" and params.protocolVersion or DEFAULT_PROTOCOL_VERSION,
      capabilities = { tools = vim.empty_dict() },
      serverInfo = { name = self.name, version = self.version },
    })
  elseif method == "ping" then
    ok({})
  elseif method == "tools/list" then
    ok({ tools = self:list_tools() })
  elseif method == "tools/call" then
    self:call_tool(id, params, ok, fail, on_transport_cancel)
  else
    fail(JSONRPC_METHOD_NOT_FOUND, ("method not found: %s"):format(tostring(method)))
  end
end

---@private
---@param id string|number
---@param params table
---@param ok fun(result: table)
---@param fail fun(code: integer, text: string)
---@param on_transport_cancel? fun(fn: fun())
function Server:call_tool(id, params, ok, fail, on_transport_cancel)
  local tool = self.tools[params.name]
  if not tool then
    fail(JSONRPC_INVALID_PARAMS, ("unknown tool: %s"):format(tostring(params.name)))
    return
  end

  local record = { cancelled = false, on_cancel = {} }
  self.calls[id] = record
  local function cancel()
    if record.cancelled then
      return
    end
    record.cancelled = true
    if self.calls[id] == record then
      self.calls[id] = nil
    end
    for _, fn in ipairs(record.on_cancel) do
      pcall(fn)
    end
  end
  record.cancel = cancel
  if on_transport_cancel then
    on_transport_cancel(cancel)
  end

  local finished = false
  local function finish(result)
    if finished or record.cancelled then
      return
    end
    finished = true
    if self.calls[id] == record then
      self.calls[id] = nil
    end
    ok(result)
  end
  local function done(result, err)
    if err ~= nil then
      finish(error_result(tostring(err)))
    else
      local converted_ok, converted = pcall(to_result, result)
      finish(converted_ok and converted or error_result(tostring(converted)))
    end
  end

  local meta = type(params._meta) == "table" and params._meta or {}
  local ctx = {
    server = self.name,
    tool_use_id = meta[TOOL_USE_ID_META],
    cancelled = function()
      return record.cancelled
    end,
    on_cancel = function(fn)
      if record.cancelled then
        pcall(fn)
      else
        table.insert(record.on_cancel, fn)
      end
    end,
  }
  local input = type(params.arguments) == "table" and params.arguments or {}

  local called, returned = pcall(tool.handler, input, ctx, done)
  if not called then
    finish(error_result(tostring(returned)))
  elseif returned ~= nil then
    done(returned)
  end
end

--- Handle a JSON-RPC notification (a message without an id).
---@param message table
function Server:notify(message)
  if message.method == "notifications/cancelled" then
    local params = type(message.params) == "table" and message.params or {}
    local record = params.requestId ~= nil and self.calls[params.requestId]
    if record then
      record.cancel()
    end
  end
  -- notifications/initialized and the rest need nothing from a tools-only server.
end

--- Withdraw every call still running; the process is gone.
function Server:cancel_all()
  local calls = self.calls
  self.calls = {}
  for _, record in pairs(calls) do
    record.cancel()
  end
end

--- Build a server to put in `mcp_servers`. Mirrors the TypeScript SDK's
--- `createSdkMcpServer()`; the key it is stored under in `mcp_servers` is the
--- name the CLI uses, as it is there.
---@param opts { name: string, version?: string, tools?: claude_agent_sdk.McpTool[] }
---@return claude_agent_sdk.McpSdkServerConfig
function M.create_server(opts)
  if type(opts) ~= "table" or type(opts.name) ~= "string" or opts.name == "" then
    error("create_sdk_mcp_server needs a name", 2)
  end
  return { type = "sdk", name = opts.name, instance = Server.new(opts) }
end

--- Whether an `mcp_servers` entry is an in-process server rather than a config for the CLI.
---@param config any
---@return boolean
function M.is_sdk_server(config)
  return type(config) == "table" and config.type == "sdk" and getmetatable(config.instance) == Server
end

M.Server = Server

return M
