-- Session bookkeeping for the picker: list, read and rename transcripts,
-- without starting a Claude process.
--
-- With `transport = "direct"` this reads `~/.claude/projects` from Lua. With
-- `transport = "sidecar"` it asks `sidecar.mjs --control`, which does the same
-- work through the Agent SDK. Both answer the same four methods, so callers
-- (session.lua, the picker) don't care which is in use.

local Sidecar = require("claude-code.sidecar")
local config = require("claude-code.config")

local M = {}

---@type claude_code.Sidecar?
local sidecar
local next_id = 1
---@type table<integer, fun(err?: string, result?: any)>
local pending = {}

local function ensure()
  if sidecar and sidecar:running() then
    return sidecar
  end
  sidecar = Sidecar.new({
    on_event = function(event)
      if event.type ~= "response" then
        return
      end
      local callback = pending[event.id]
      pending[event.id] = nil
      if callback then
        callback(event.error, event.result)
      end
    end,
    on_exit = function(_, stderr)
      sidecar = nil
      for id, callback in pairs(pending) do
        pending[id] = nil
        callback("control sidecar exited: " .. stderr)
      end
    end,
  }, { "--control" })
  sidecar:start()
  return sidecar
end

--- Read the store directly. Returns `result, err` the way the sidecar would.
---@param method string
---@param params table
---@return any result, string? err
local function locally(method, params)
  local store = require("claude-agent-sdk.sessions")
  if method == "list_sessions" then
    return store.list_sessions({ dir = params.dir, limit = params.limit, offset = params.offset })
  elseif method == "get_session_info" then
    return store.get_session_info(params.session_id, { dir = params.dir })
  elseif method == "get_messages" then
    local messages = store.get_session_messages(params.session_id, { dir = params.dir })
    local total = #messages
    return { total = total, messages = params.tail and vim.list_slice(messages, math.max(1, total - params.tail + 1)) or messages }
  elseif method == "rename_session" then
    local ok, err = store.rename_session(params.session_id, params.title, { dir = params.dir })
    if not ok then
      return nil, err
    end
    return vim.NIL
  end
  return nil, "Unknown method: " .. tostring(method)
end

--- Call a control method. `callback` runs on the main loop, as it does for the
--- sidecar, so callers can treat both paths identically.
---@param method "list_sessions"|"get_messages"|"get_session_info"|"rename_session"
---@param params table
---@param callback fun(err?: string, result?: any)
function M.request(method, params, callback)
  if config.options.transport == "direct" then
    local ok, result, err = pcall(locally, method, params)
    vim.schedule(function()
      if not ok then
        callback(tostring(result))
      else
        callback(err, result)
      end
    end)
    return
  end
  local id = next_id
  next_id = next_id + 1
  pending[id] = callback
  ensure():send({ type = "request", id = id, method = method, params = params })
end

return M
