-- Process lifecycle and newline-delimited JSON framing for one `claude`
-- subprocess. Knows nothing about message semantics: it moves decoded frames
-- in and out, and reports how the process died.

---@class claude_agent_sdk.Transport
---@field private proc? vim.SystemObj
---@field private partial string Incomplete trailing line from the last stdout chunk.
---@field private stderr_tail string
---@field private argv string[]
---@field private cwd? string
---@field private env table<string, string>
---@field private on_frame fun(frame: table)
---@field private on_exit fun(code: integer, stderr: string)
---@field private closing boolean
local Transport = {}
Transport.__index = Transport

--- Enough stderr to explain a failed launch, not enough to hold a log in memory.
--- The TypeScript SDK keeps the same 2KB tail for its exit messages.
local STDERR_TAIL = 2048

--- Grace period between closing stdin and escalating to signals.
local TERM_GRACE_MS = 2000
local KILL_GRACE_MS = 5000

---@param spec { argv: string[], cwd?: string, env?: table<string, string>, on_frame: fun(frame: table), on_exit: fun(code: integer, stderr: string) }
---@return claude_agent_sdk.Transport
function Transport.new(spec)
  return setmetatable({
    partial = "",
    stderr_tail = "",
    argv = spec.argv,
    cwd = spec.cwd,
    env = spec.env or {},
    on_frame = spec.on_frame,
    on_exit = spec.on_exit,
    closing = false,
  }, Transport)
end

---@private
---@param chunk string
function Transport:consume(chunk)
  local lines = vim.split(self.partial .. chunk, "\n", { plain = true })
  self.partial = table.remove(lines)
  for _, line in ipairs(lines) do
    if line ~= "" then
      local ok, frame = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      -- vim.schedule keeps callbacks off the fast event loop; it preserves
      -- order, so frames still arrive in the order the CLI wrote them.
      vim.schedule(function()
        if ok and type(frame) == "table" then
          self.on_frame(frame)
        else
          -- The CLI occasionally writes non-JSON to stdout (a crash trace, a
          -- stray log line). The SDK skips these rather than failing the query.
          self.on_frame({ type = "__malformed", line = line })
        end
      end)
    end
  end
end

---@return boolean started, string? err
function Transport:spawn()
  local ok, result = pcall(vim.system, self.argv, {
    cwd = self.cwd,
    stdin = true,
    env = self.env,
    stdout = function(_, data)
      if data then
        self:consume(data)
      end
    end,
    stderr = function(_, data)
      if data then
        self.stderr_tail = (self.stderr_tail .. data):sub(-STDERR_TAIL)
      end
    end,
  }, function(done)
    -- vim.system fires this only once stdout and stderr have both closed, so
    -- the tail is complete by the time it is reported.
    vim.schedule(function()
      self.proc = nil
      self.on_exit(done.code, vim.trim(self.stderr_tail))
    end)
  end)
  if not ok then
    return false, tostring(result)
  end
  self.proc = result
  return true
end

---@param frame table
---@return boolean written
function Transport:write(frame)
  if not self.proc then
    return false
  end
  local ok = pcall(function()
    self.proc:write(vim.json.encode(frame) .. "\n")
  end)
  return ok
end

function Transport:running()
  return self.proc ~= nil
end

--- Close stdin, which is how the CLI is asked to finish and exit. Escalates to
--- SIGTERM and then SIGKILL if it does not, so a wedged process cannot outlive
--- Neovim.
function Transport:close()
  if not self.proc or self.closing then
    return
  end
  self.closing = true
  pcall(function()
    self.proc:write(nil)
  end)
  local proc = self.proc
  vim.defer_fn(function()
    if self.proc == proc then
      pcall(function()
        proc:kill("sigterm")
      end)
      vim.defer_fn(function()
        if self.proc == proc then
          pcall(function()
            proc:kill("sigkill")
          end)
        end
      end, KILL_GRACE_MS)
    end
  end, TERM_GRACE_MS)
end

return Transport
