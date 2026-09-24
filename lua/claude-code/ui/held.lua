-- Messages from other Claude sessions that this session's inbound policy is
-- holding back (Claude Code's `crossSessionInbound`, or its default of holding
-- messages between sessions in different permission modes).
--
-- The interactive CLI asks in a dialog. A headless session has no dialog: a held
-- message is released only when a settings or mode change lets it in, and a
-- parity hold is dropped after `dialogExpiry` (five minutes by default). So the
-- card offers to deliver them, which the transport does by accepting inbound
-- messages for a moment (see deliver_held in sidecar/src/session.ts).
--
-- Unlike a permission card nothing is blocked while one waits, so its keys are
-- bound in the transcript only, never in the prompt you may be typing in.

local api = vim.api
local card = require("claude-code.ui.card")
local icons = require("claude-code.ui.icons")

local ns = api.nvim_create_namespace("claude-code.held")

--- Keys bound in the transcript while the card is up.
local DELIVER, DISMISS = "D", "X"

---@class claude_code.HeldMessage
---@field uuid string message_uuid from system/peer_message_hold
---@field from string Sender's name (or address when it gave none).
---@field cause? string Why it's held.

---@class claude_code.Held
---@field private chat claude_code.Chat
---@field private on_deliver fun()
---@field private messages claude_code.HeldMessage[]
---@field private card? integer extmark id
---@field private dismissed boolean The card was put away; it returns when another message is held.
local Held = {}
Held.__index = Held

--- Why a message is held, in words.
local CAUSES = {
  ["mode-mismatch"] = "it comes from a session in a different permission mode",
  ["no-mode-asserted"] = "its sender didn't say which permission mode it runs in",
  ["bypass-default"] = "this session bypasses permission prompts",
  ["mode-unknown"] = "this session's permission mode isn't known yet",
  ["explicit-setting"] = "crossSessionInbound is set to hold",
  ["managed-setting"] = "managed settings set crossSessionInbound to hold",
  ["repo-setting"] = "this project's settings set crossSessionInbound to hold",
  ["invalid-setting"] = "crossSessionInbound has an invalid value",
}

--- Parity holds (the permission-mode defaults) expire; a standing `hold` setting doesn't.
local EXPIRE =
  { ["mode-mismatch"] = true, ["no-mode-asserted"] = true, ["bypass-default"] = true, ["mode-unknown"] = true }

---@param chat claude_code.Chat
---@param on_deliver fun() Release every held message.
---@return claude_code.Held
function Held.new(chat, on_deliver)
  return setmetatable({ chat = chat, on_deliver = on_deliver, messages = {}, dismissed = false }, Held)
end

---@return integer
function Held:count()
  return #self.messages
end

--- A message was held (system/peer_message_hold, state "held").
---@param message claude_code.HeldMessage
function Held:add(message)
  for _, m in ipairs(self.messages) do
    if m.uuid == message.uuid then
      -- Held again for another cause: keep one entry, with the latest reason.
      m.cause = message.cause
      self:render()
      return
    end
  end
  table.insert(self.messages, message)
  self.dismissed = false
  self:render()
end

--- A held message was released or dropped.
---@param uuid string
---@return claude_code.HeldMessage? message The entry, if it was being held.
function Held:remove(uuid)
  for i, m in ipairs(self.messages) do
    if m.uuid == uuid then
      table.remove(self.messages, i)
      self:render()
      return m
    end
  end
end

--- The process exited: whatever it held is gone with it.
function Held:clear()
  self.messages = {}
  self:render()
end

--- Deliver everything held.
function Held:deliver()
  if #self.messages == 0 then
    vim.notify("claude-code: no messages from other sessions are waiting", vim.log.levels.INFO)
    return
  end
  self.on_deliver()
end

--- Put the card away; the messages stay held (and may expire).
function Held:dismiss()
  self.dismissed = true
  self:render()
end

---@private
---@param width integer
---@return claude_code.VirtLine[]
function Held:card_lines(width)
  local inner = card.inner(width)
  local rows = {} ---@type claude_code.Chunk[][]
  local expires = false
  for _, m in ipairs(self.messages) do
    table.insert(rows, { { "From " .. m.from, "ClaudeCodeCardTitle" } })
    for _, line in ipairs(card.wrap("Held because " .. (CAUSES[m.cause] or "of this session's settings"), inner)) do
      table.insert(rows, { { line, "ClaudeCodeMuted" } })
    end
    expires = expires or EXPIRE[m.cause] or false
  end
  table.insert(rows, {})
  local note = "Claude hasn't seen " .. (#self.messages == 1 and "it" or "them") .. " yet."
  if expires then
    note = note .. " Held messages are dropped after a few minutes unless delivered."
  end
  for _, line in ipairs(card.wrap(note, inner)) do
    table.insert(rows, { { line, "ClaudeCodeCardText" } })
  end
  table.insert(rows, {})
  local choices = {} ---@type claude_code.Chunk[]
  vim.list_extend(choices, card.choice(DELIVER, #self.messages == 1 and "deliver" or "deliver all"))
  vim.list_extend(choices, card.choice(DISMISS, "hide", "ClaudeCodeCardDenyKey"))
  table.insert(rows, choices)
  local heading = ("%s %s from another session"):format(
    icons.get().message,
    #self.messages == 1 and "Message" or (#self.messages .. " messages")
  )
  return card.frame(width, heading, rows)
end

--- Draw the card at the end of the transcript (or remove it), and update the status.
---@private
function Held:render()
  local transcript = self.chat.transcript
  if not transcript:valid() then
    return
  end
  self.chat:set_status({ activity = self.chat:activity(), held = #self.messages })
  if self.card then
    api.nvim_buf_del_extmark(transcript.buf, ns, self.card)
    self.card = nil
  end
  self:unmap()
  if #self.messages == 0 or self.dismissed then
    return
  end
  local win = transcript:window()
  local width = win and api.nvim_win_get_width(win) or 80
  self.card = api.nvim_buf_set_extmark(transcript.buf, ns, api.nvim_buf_line_count(transcript.buf) - 1, 0, {
    virt_lines = self:card_lines(width),
  })
  local function map(key, fn, desc)
    vim.keymap.set("n", key, fn, { buffer = transcript.buf, nowait = true, desc = "Claude: " .. desc })
  end
  map(DELIVER, function()
    self:deliver()
  end, "deliver held messages from other sessions")
  map(DISMISS, function()
    self:dismiss()
  end, "hide the held-messages card")
  transcript:follow()
end

---@private
function Held:unmap()
  local buf = self.chat.transcript.buf
  if api.nvim_buf_is_valid(buf) then
    pcall(vim.keymap.del, "n", DELIVER, { buffer = buf })
    pcall(vim.keymap.del, "n", DISMISS, { buffer = buf })
  end
end

return Held
