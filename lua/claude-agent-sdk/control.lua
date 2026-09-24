-- The control channel: JSON-RPC-ish request/response multiplexed onto the same
-- stdio stream as the conversation.
--
--   out  {"type":"control_request","request_id":"x1","request":{"subtype":"interrupt"}}
--   in   {"type":"control_response","response":{"subtype":"success","request_id":"x1","response":{}}}
--
-- The CLI also originates requests (permission prompts, hook callbacks) that we
-- must answer. An unanswered inbound request stalls the CLI's turn, so every
-- one is replied to — with an error if nothing handles it.

---@class claude_agent_sdk.Control
---@field private write fun(frame: table): boolean
---@field private pending table<string, fun(response?: table, err?: string)> Requests we sent.
---@field private inflight table<string, { cancelled: boolean, on_cancel: fun()[] }> Requests we received.
---@field private counter integer
local Control = {}
Control.__index = Control

---@param write fun(frame: table): boolean
---@return claude_agent_sdk.Control
function Control.new(write)
  return setmetatable({ write = write, pending = {}, inflight = {}, counter = 0 }, Control)
end

---@private
---@return string
function Control:next_id()
  self.counter = self.counter + 1
  return ("nvim-%d-%s"):format(self.counter, ("%08x"):format(math.random(0, 0xffffffff)))
end

--- Send a control request. `callback` receives the response payload, or an
--- error string if the CLI rejected it or the process died first.
---@param subtype string
---@param params? table
---@param callback? fun(response?: table, err?: string)
function Control:request(subtype, params, callback)
  local id = self:next_id()
  local request = vim.tbl_extend("force", { subtype = subtype }, params or {})
  if callback then
    self.pending[id] = callback
  end
  if not self.write({ type = "control_request", request_id = id, request = request }) then
    self.pending[id] = nil
    if callback then
      callback(nil, "claude process is not running")
    end
  end
end

--- Route a `control_response` frame back to whoever sent the request.
---@param frame table
function Control:on_response(frame)
  local response = frame.response or {}
  local callback = self.pending[response.request_id]
  if not callback then
    -- A response to a request we already gave up on (e.g. after a cancel).
    return
  end
  self.pending[response.request_id] = nil
  if response.subtype == "error" then
    callback(nil, tostring(response.error or "control request failed"))
  else
    callback(response.response or {}, nil)
  end
end

--- Dispatch a `control_request` the CLI sent us.
---
--- Handlers are `fun(request: table, respond: fun(result: table), ctx: table)`.
--- `ctx.on_cancel(fn)` registers a callback for when the CLI withdraws the
--- request; responding after a cancel is silently dropped.
---@param frame table
---@param handlers table<string, fun(request: table, respond: fun(result: table), ctx: table)>
function Control:on_request(frame, handlers)
  local id = frame.request_id
  local request = frame.request or {}
  local handler = handlers[request.subtype]
  if not handler then
    self:respond_error(id, ("no handler for control request %q"):format(tostring(request.subtype)))
    return
  end

  local record = { cancelled = false, on_cancel = {} }
  self.inflight[id] = record
  local ctx = {
    request_id = id,
    on_cancel = function(fn)
      if record.cancelled then
        fn()
      else
        table.insert(record.on_cancel, fn)
      end
    end,
  }
  local function respond(result)
    if record.cancelled or self.inflight[id] == nil then
      return
    end
    self.inflight[id] = nil
    self.write({
      type = "control_response",
      response = { subtype = "success", request_id = id, response = result },
    })
  end

  local ok, err = pcall(handler, request, respond, ctx)
  if not ok then
    self.inflight[id] = nil
    self:respond_error(id, tostring(err))
  end
end

--- The CLI withdrew a request it sent us (an interrupt cancels pending prompts).
---@param frame table
function Control:on_cancel(frame)
  local record = self.inflight[frame.request_id]
  if not record then
    return
  end
  record.cancelled = true
  self.inflight[frame.request_id] = nil
  for _, fn in ipairs(record.on_cancel) do
    pcall(fn)
  end
end

---@param request_id string
---@param err string
function Control:respond_error(request_id, err)
  self.write({
    type = "control_response",
    response = { subtype = "error", request_id = request_id, error = err },
  })
end

--- Fail every outstanding request; called when the process exits.
---@param err string
function Control:fail_all(err)
  local pending, inflight = self.pending, self.inflight
  self.pending, self.inflight = {}, {}
  for _, callback in pairs(pending) do
    pcall(callback, nil, err)
  end
  for _, record in pairs(inflight) do
    for _, fn in ipairs(record.on_cancel) do
      pcall(fn)
    end
  end
end

return Control
