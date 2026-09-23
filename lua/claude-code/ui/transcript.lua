-- The conversation transcript: a read-only markdown buffer that is only ever
-- appended to. Turn headers, tool status, tool output and footers are
-- extmarks, so the buffer text itself stays plain markdown (and copies cleanly).

local api = vim.api
local icons = require("claude-code.ui.icons")
local tools = require("claude-code.ui.tools")

local ns = api.nvim_create_namespace("claude-code.transcript")

local RULE = string.rep("─", 300)

---@alias claude_code.ToolStatus "pending"|"success"|"error"|"cancelled"

---@class claude_code.ToolEntry
---@field name string
---@field input table
---@field status claude_code.ToolStatus
---@field result? string
---@field icon integer extmark id of the status icon
---@field summary? integer extmark id of the summary line
---@field body? integer extmark id of the expanded output

---@class claude_code.Transcript
---@field buf integer
---@field private tools table<string, claude_code.ToolEntry> keyed by tool_use id
---@field private pending_break boolean The next streamed text starts a new paragraph.
---@field private frame integer Spinner frame for pending tools.
---@field private quiet boolean Inside batch(): don't scroll after each write.
local Transcript = {}
Transcript.__index = Transcript

local STATUS_HL = {
  pending = "ClaudeCodeToolPending",
  success = "ClaudeCodeToolSuccess",
  error = "ClaudeCodeToolError",
  cancelled = "ClaudeCodeToolCancelled",
}

--- Wrap `text` in a markdown code span that survives backticks inside it.
---@param text string
local function code_span(text)
  local longest = 0
  for run in text:gmatch("`+") do
    longest = math.max(longest, #run)
  end
  local fence = string.rep("`", longest + 1)
  local pad = (text:sub(1, 1) == "`" or text:sub(-1) == "`") and " " or ""
  return fence .. pad .. text .. pad .. fence
end

---@param name string
---@return claude_code.Transcript
function Transcript.new(name)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "claude-code-chat"
  vim.bo[buf].modifiable = false
  api.nvim_buf_set_name(buf, name)
  pcall(vim.treesitter.start, buf, "markdown")
  require("claude-code.ui.markdown").attach(buf)
  return setmetatable({ buf = buf, tools = {}, pending_break = false, frame = 1, quiet = false }, Transcript)
end

function Transcript:valid()
  return api.nvim_buf_is_valid(self.buf)
end

--- Nothing has been said yet.
function Transcript:empty()
  return api.nvim_buf_line_count(self.buf) == 1 and self:line(0) == ""
end

---@return integer? win
function Transcript:window()
  local win = vim.fn.bufwinid(self.buf)
  return win ~= -1 and win or nil
end

---@private
function Transcript:width()
  local win = self:window()
  return win and api.nvim_win_get_width(win) or 80
end

---@private
function Transcript:last_row()
  return api.nvim_buf_line_count(self.buf) - 1
end

---@private
---@param row integer
function Transcript:line(row)
  return api.nvim_buf_get_lines(self.buf, row, row + 1, false)[1]
end

--- Insert text at the very end of the buffer. Uses set_text rather than
--- set_lines so extmarks on the last line stay where they are.
---@private
---@param text string
function Transcript:write(text)
  local row = self:last_row()
  local col = #self:line(row)
  vim.bo[self.buf].modifiable = true
  api.nvim_buf_set_text(self.buf, row, col, row, col, vim.split(text, "\n", { plain = true }))
  vim.bo[self.buf].modifiable = false
  self:follow()
end

--- Leave the buffer ending in an empty line that follows a blank line.
--- Row 0 is kept blank so the first turn has a separator line to hang its header on.
---@private
function Transcript:new_paragraph()
  local row = self:last_row()
  if self:line(row) ~= "" then
    self:write("\n\n")
  elseif row == 0 or self:line(row - 1) ~= "" then
    self:write("\n")
  end
  self.pending_break = false
end

---@param role "user"|"assistant"
---@return integer row First row of the turn.
function Transcript:start_turn(role)
  self:new_paragraph()
  local row = self:last_row()
  local i = icons.get()
  local label, kind = i.user .. " You", "User"
  if role == "assistant" then
    label, kind = i.claude .. " Claude", "Assistant"
  end
  local edge = "ClaudeCode" .. kind .. "PillEdge"
  -- Hang the header below the blank separator line rather than above the turn's first
  -- line: that line may be a code fence, which markdown conceals along with its virtual lines.
  api.nvim_buf_set_extmark(self.buf, ns, row - 1, 0, {
    virt_lines = {
      {
        { i.pill[1], edge },
        { " " .. label .. " ", "ClaudeCode" .. kind .. "Pill" },
        { i.pill[2], edge },
        { " " .. RULE, "ClaudeCodeRule" },
      },
    },
  })
  return row
end

---@param bytes integer
local function size(bytes)
  if bytes >= 1024 * 1024 then
    return ("%.1f MB"):format(bytes / 1024 / 1024)
  end
  return ("%d KB"):format(math.max(math.floor(bytes / 1024 + 0.5), 1))
end

---@class claude_code.SentImage
---@field label string `[Image #N]`
---@field image claude_code.Image As attached.
---@field sent claude_code.Image As sent (shrunk, if it was too large).

---@param text string
---@param images? claude_code.SentImage[] Attached images, described under the message.
function Transcript:user_message(text, images)
  if not self:valid() then
    return
  end
  require("claude-code.ui.welcome").clear(self.buf)
  local first = self:start_turn("user")
  self:write(text)
  local last = self:last_row()
  for row = first, last do
    api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
      virt_text = { { "▎ ", "ClaudeCodeUserBar" } },
      virt_text_pos = "inline",
      line_hl_group = "ClaudeCodeUserBlock",
      right_gravity = false,
    })
    -- Image placeholders: highlighted, with an image icon.
    local line = self:line(row)
    for start, stop in line:gmatch("()%[Image #%d+%]()") do
      api.nvim_buf_set_extmark(self.buf, ns, row, start - 1, {
        end_col = stop - 1,
        hl_group = "ClaudeCodeAttachment",
        virt_text = { { icons.get().image .. " ", "ClaudeCodeAttachment" } },
        virt_text_pos = "inline",
      })
    end
  end
  if images and #images > 0 then
    local details = {}
    for _, img in ipairs(images) do
      local a, s = img.image, img.sent
      local desc = ("%s %s"):format(img.label, vim.fn.fnamemodify(a.path, ":t"))
      local dims = a.width and ("%d×%d"):format(a.width, a.height) or nil
      local parts = { desc, dims, size(a.bytes) }
      if s.path ~= a.path then
        table.insert(parts, ("sent as %s%s"):format(s.width and ("%d×%d "):format(s.width, s.height) or "", size(s.bytes)))
      end
      table.insert(details, {
        { "  ⎿  ", "ClaudeCodeToolGutter" },
        { table.concat(vim.tbl_filter(function(p) return p ~= nil end, parts), " · "), "ClaudeCodeMuted" },
      })
    end
    api.nvim_buf_set_extmark(self.buf, ns, last, 0, { virt_lines = details })
  end
  self.pending_break = true
end

--- Stream assistant text.
---@param text string
function Transcript:append(text)
  if not self:valid() or text == "" then
    return
  end
  if self.pending_break then
    self:new_paragraph()
  end
  self:write(text)
end

--- Start the next streamed text in a new paragraph.
function Transcript:paragraph_break()
  self.pending_break = true
end

---@private
---@param entry claude_code.ToolEntry
function Transcript:icon_chunk(entry)
  local i = icons.get()
  local glyph = entry.status == "pending" and i.spinner[self.frame] or icons.tool(entry.name)
  return { { glyph .. " ", STATUS_HL[entry.status] } }
end

---@param id string tool_use id
---@param name string
---@param input table
function Transcript:tool_use(id, name, input)
  if not self:valid() then
    return
  end
  self:new_paragraph()
  local row = self:last_row()
  local detail = tools.detail(input)
  local span = detail and code_span(detail)
  self:write(span and (name .. " " .. span) or name)
  ---@type claude_code.ToolEntry
  local entry = { name = name, input = input, status = "pending", icon = 0 }
  entry.icon = api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
    virt_text = self:icon_chunk(entry),
    virt_text_pos = "inline",
    right_gravity = false,
  })
  api.nvim_buf_set_extmark(self.buf, ns, row, 0, { end_col = #name, hl_group = "ClaudeCodeToolName" })
  if span then
    api.nvim_buf_set_extmark(self.buf, ns, row, #name + 1, {
      end_col = #name + 1 + #span,
      hl_group = "ClaudeCodeToolDetail",
      priority = 200,
    })
  end
  self.tools[id] = entry
  -- Keep an empty line after the tool so virtual lines under it (summary, output,
  -- permission card) are never below the last buffer line, where they can't be scrolled to.
  self:write("\n")
  self.pending_break = true
end

--- Row of a tool call's line, if it is in this transcript.
---@param id string tool_use id
---@return integer?
function Transcript:tool_row(id)
  local entry = self.tools[id]
  if not entry or not self:valid() then
    return nil
  end
  return api.nvim_buf_get_extmark_by_id(self.buf, ns, entry.icon, {})[1]
end

---@param id string tool_use id
---@param status "success"|"error"|"cancelled"
---@param result? string Output text.
function Transcript:tool_result(id, status, result)
  local entry = self.tools[id]
  local row = self:tool_row(id)
  if not entry or not row or entry.status ~= "pending" then
    return
  end
  entry.status = status
  entry.result = result
  api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
    id = entry.icon,
    virt_text = self:icon_chunk(entry),
    virt_text_pos = "inline",
    right_gravity = false,
  })
  local summary = status ~= "cancelled"
    and tools.summarize(entry.name, entry.input, result or "", status == "error")
  if summary then
    entry.summary = api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
      virt_lines = {
        { { "  ⎿  ", "ClaudeCodeToolGutter" }, { summary, status == "error" and "ClaudeCodeError" or "ClaudeCodeMuted" } },
      },
    })
  end
  if entry.body then
    -- Re-render so the output sits below the summary and includes the result.
    self:render_body(entry, row)
  end
end

---@private
---@param entry claude_code.ToolEntry
---@param row integer
function Transcript:render_body(entry, row)
  if entry.body then
    api.nvim_buf_del_extmark(self.buf, ns, entry.body)
  end
  entry.body = api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
    virt_lines = tools.body(entry.name, entry.input, entry.result, self:width()),
  })
end

--- Expand or collapse the output of the tool call on `row`.
---@param row integer
---@return boolean found
function Transcript:toggle_tool_at(row)
  for id, entry in pairs(self.tools) do
    if self:tool_row(id) == row then
      if entry.body then
        api.nvim_buf_del_extmark(self.buf, ns, entry.body)
        entry.body = nil
      else
        self:render_body(entry, row)
      end
      return true
    end
  end
  return false
end

--- Mark tool calls that never got a result (e.g. after an interrupt).
function Transcript:cancel_pending_tools()
  for id, entry in pairs(self.tools) do
    if entry.status == "pending" then
      self:tool_result(id, "cancelled")
    end
  end
end

--- Advance the spinner on pending tool calls.
---@param frame integer
function Transcript:tick(frame)
  self.frame = frame
  if not self:valid() then
    return
  end
  for id, entry in pairs(self.tools) do
    local row = entry.status == "pending" and self:tool_row(id)
    if row then
      api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
        id = entry.icon,
        virt_text = self:icon_chunk(entry),
        virt_text_pos = "inline",
        right_gravity = false,
      })
    end
  end
end

--- A dimmed line under the last content of the current turn.
---@param text string
---@param hl? string
function Transcript:footer(text, hl)
  if not self:valid() then
    return
  end
  -- Anchor above a trailing empty line rather than below the last content line:
  -- that line may be a code fence, which markdown conceals along with its virtual lines.
  local row = self:last_row()
  if self:line(row) ~= "" then
    self:write("\n")
    row = row + 1
  end
  api.nvim_buf_set_extmark(self.buf, ns, row, 0, {
    virt_lines = { { { icons.get().clock .. " " .. text, hl or "ClaudeCodeMuted" } } },
    virt_lines_above = true,
    right_gravity = false,
  })
  self.pending_break = true
  self:follow()
end

--- A dimmed line between turns, e.g. "Resumed · 2h ago".
---@param text string
---@param hl? string
function Transcript:note(text, hl)
  if not self:valid() then
    return
  end
  self:new_paragraph()
  -- Like turn headers, hang it below the blank separator line.
  api.nvim_buf_set_extmark(self.buf, ns, self:last_row() - 1, 0, {
    virt_lines = { { { text, hl or "ClaudeCodeMuted" } } },
  })
  self:follow()
end

--- Run `fn` (many appends, e.g. replaying history) and scroll once at the end.
---@param fn fun()
function Transcript:batch(fn)
  self.quiet = true
  local ok, err = pcall(fn)
  self.quiet = false
  self:follow()
  if not ok then
    error(err, 0)
  end
end

--- Keep windows that were already at the bottom scrolled to the bottom.
function Transcript:follow()
  if self.quiet then
    return
  end
  local last = api.nvim_buf_line_count(self.buf)
  for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
    if win ~= api.nvim_get_current_win() or api.nvim_win_get_cursor(win)[1] >= last - 2 then
      api.nvim_win_set_cursor(win, { last, 0 })
      api.nvim_win_call(win, function()
        vim.cmd("normal! zb")
      end)
    end
  end
end

return Transcript
