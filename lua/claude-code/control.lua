-- Client for the control sidecar (`sidecar.mjs --control`): session
-- bookkeeping for the picker, without a Claude process. Started on first use
-- and kept for the rest of the Neovim session.

local Sidecar = require("claude-code.sidecar")

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

--- Call a control method. `callback` runs on the main loop.
---@param method "list_sessions"|"get_messages"|"get_session_info"|"rename_session"
---@param params table
---@param callback fun(err?: string, result?: any)
function M.request(method, params, callback)
  local id = next_id
  next_id = next_id + 1
  pending[id] = callback
  ensure():send({ type = "request", id = id, method = method, params = params })
end

return M
