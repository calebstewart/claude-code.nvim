-- Owns the Node sidecar process and the newline-delimited JSON protocol.
-- Message shapes are defined in sidecar/src/protocol.ts.

local config = require("claude-code.config")

---@class claude_code.InitRequest
---@field type "init"
---@field cwd string
---@field claude_path string
---@field model? string
---@field permission_mode? claude_code.PermissionMode
---@field resume? string
---@field session_id? string Id for a new session.
---@field title? string Title for a new session.
---@field prompt_suggestions? boolean Ask for a predicted next prompt after each turn.

---@class claude_code.SidecarEvent
---@field type "ready"|"sdk"|"permission_request"|"permission_cancel"|"error"|"exit"|"response"
---@field message? table|string SDK message for "sdk", error text for "error".
---@field session_id? string ready
---@field result? any response (control mode)
---@field error? string response (control mode)
---@field id? integer permission_request / permission_cancel
---@field tool_use_id? string permission_request fields follow
---@field tool_name? string
---@field input? table
---@field title? string
---@field description? string
---@field has_suggestions? boolean
---@field default_to_no? boolean
---@field suppress_always? boolean
---@field agent_id? string permission_request: set when a subagent is asking.

---@class claude_code.Sidecar
---@field private proc? vim.SystemObj
---@field private partial string
---@field private on_event fun(event: claude_code.SidecarEvent)
---@field private on_exit fun(code: integer, stderr: string)
---@field private args string[]
local Sidecar = {}
Sidecar.__index = Sidecar

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

---@return string
function Sidecar.script_path()
  return plugin_root .. "/dist/sidecar.mjs"
end

---@param handlers { on_event: fun(event: claude_code.SidecarEvent), on_exit: fun(code: integer, stderr: string) }
---@param args? string[] Extra arguments, e.g. { "--control" }.
---@return claude_code.Sidecar
function Sidecar.new(handlers, args)
  return setmetatable({
    partial = "",
    on_event = handlers.on_event,
    on_exit = handlers.on_exit,
    args = args or {},
  }, Sidecar)
end

---@param init? claude_code.InitRequest Sent first; session mode needs it, control mode doesn't.
function Sidecar:start(init)
  local stderr = {}
  local cmd = { config.options.node, Sidecar.script_path() }
  vim.list_extend(cmd, self.args)
  self.proc = vim.system(cmd, {
    stdin = true,
    stdout = function(_, data)
      if data then
        self:receive(data)
      end
    end,
    stderr = function(_, data)
      table.insert(stderr, data)
    end,
  }, function(result)
    vim.schedule(function()
      self.proc = nil
      self.on_exit(result.code, table.concat(stderr))
    end)
  end)
  if init then
    self:send(init)
  end
end

---@private
---@param data string
function Sidecar:receive(data)
  local lines = vim.split(self.partial .. data, "\n", { plain = true })
  self.partial = table.remove(lines)
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      vim.schedule(function()
        if ok then
          self.on_event(event)
        else
          self.on_event({ type = "error", message = "Malformed sidecar output: " .. line })
        end
      end)
    end
  end
end

---@param request table
function Sidecar:send(request)
  if self.proc then
    self.proc:write(vim.json.encode(request) .. "\n")
  end
end

function Sidecar:running()
  return self.proc ~= nil
end

--- Closing stdin tells the sidecar to finish the session and exit.
function Sidecar:stop()
  if self.proc then
    self.proc:write(nil)
  end
end

return Sidecar
