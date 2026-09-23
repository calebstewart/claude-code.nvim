-- Slash-command suggestions in the prompt, like the CLI's: typing `/` at the
-- start of the prompt shows the session's commands and skills in a small list
-- sitting on top of the prompt box, filtered (fuzzily) as you type.
--
-- It's our own float rather than Neovim's completion menu, whose position and
-- size can't be anchored to the prompt. Other completion engines (nvim-cmp,
-- blink.cmp) are paused while a command is typed so their menus don't compete.

local api = vim.api

local ns = api.nvim_create_namespace("claude-code.slash")

--- Rows shown at once (the list scrolls beyond this).
local MAX_ROWS = 8

local M = {}

---@class claude_code.SlashCommand
---@field name string Without the leading slash.
---@field description string
---@field argumentHint? string
---@field aliases? string[]
---@field builtin? boolean

--- The command being typed, if the cursor is in a leading `/word` on the first line.
---@param buf integer
---@return string? query Text after the slash.
function M.query(buf)
  if api.nvim_get_current_buf() ~= buf then
    return nil
  end
  local row, col = unpack(api.nvim_win_get_cursor(0))
  if row ~= 1 then
    return nil
  end
  local before = api.nvim_buf_get_lines(buf, 0, 1, false)[1]:sub(1, col)
  return before:match("^/([%w%-_:%.]*)$")
end

---@param commands claude_code.SlashCommand[]
---@param query string
---@return claude_code.SlashCommand[]
local function filter(commands, query)
  if query == "" then
    local sorted = vim.list_extend({}, commands)
    table.sort(sorted, function(a, b)
      return a.name < b.name
    end)
    return sorted
  end
  return vim.fn.matchfuzzy(commands, query, {
    text_cb = function(c)
      return c.name .. " " .. table.concat(c.aliases or {}, " ")
    end,
  })
end

---@param text string
---@param width integer
local function clip(text, width)
  text = text:gsub("%s+", " ")
  if width <= 0 then
    return ""
  end
  if vim.fn.strdisplaywidth(text) > width then
    return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
  end
  return text
end

--- Pause other completion engines while a slash command is typed.
---@param buf integer
local function quiet_other_completers(buf)
  local ok, cmp = pcall(require, "cmp")
  if ok and cmp.setup and cmp.setup.buffer then
    api.nvim_buf_call(buf, function()
      cmp.setup.buffer({
        enabled = function()
          return M.query(buf) == nil
        end,
      })
    end)
    return true
  end
  return false
end

---@class claude_code.SlashMenu
---@field private buf integer Prompt buffer.
---@field private get_commands fun(): claude_code.SlashCommand[]
---@field private items claude_code.SlashCommand[]
---@field private index integer
---@field private list_buf? integer
---@field private win? integer
---@field private accepted? string Just completed; don't reopen the list for it.
local Menu = {}
Menu.__index = Menu

function Menu:open()
  return self.win ~= nil and api.nvim_win_is_valid(self.win)
end

function Menu:close()
  if self:open() then
    api.nvim_win_close(self.win, true)
  end
  self.win = nil
end

--- The prompt window the list sits on.
---@private
function Menu:prompt_win()
  local win = vim.fn.bufwinid(self.buf)
  return win ~= -1 and win or nil
end

--- Recompute the list for what's typed, and show, update or close it.
function Menu:update()
  local query = M.query(self.buf)
  vim.b[self.buf].completion = query == nil -- blink.cmp honours this
  if not query or "/" .. query == self.accepted then
    self:close()
    return
  end
  self.accepted = nil
  self.items = filter(self.get_commands(), query)
  self.index = 1
  if #self.items == 0 then
    self:close()
    return
  end
  self:render()
end

---@private
function Menu:render()
  local prompt = self:prompt_win()
  if not prompt then
    self:close()
    return
  end
  if not (self.list_buf and api.nvim_buf_is_valid(self.list_buf)) then
    self.list_buf = api.nvim_create_buf(false, true)
    vim.bo[self.list_buf].bufhidden = "wipe"
  end

  local width = api.nvim_win_get_width(prompt)
  local height = math.min(#self.items, MAX_ROWS)
  -- Names get up to ~40% of the width; descriptions fill the rest.
  local name_width = 0
  for _, c in ipairs(self.items) do
    local hint = c.argumentHint and c.argumentHint ~= "" and (" " .. c.argumentHint) or ""
    name_width = math.max(name_width, vim.fn.strdisplaywidth("/" .. c.name .. hint))
  end
  name_width = math.min(name_width, math.floor(width * 0.4))

  local lines, marks = {}, {}
  for i, c in ipairs(self.items) do
    local hint = c.argumentHint and c.argumentHint ~= "" and (" " .. c.argumentHint) or ""
    local name = clip("/" .. c.name .. hint, name_width)
    local pad = string.rep(" ", name_width - vim.fn.strdisplaywidth(name))
    local desc = clip(c.description or "", width - name_width - 4)
    lines[i] = " " .. name .. pad .. "  " .. desc
    marks[i] = { name_end = 1 + #("/" .. c.name), hint_end = 1 + #name, desc_start = #lines[i] - #desc }
  end
  vim.bo[self.list_buf].modifiable = true
  api.nvim_buf_set_lines(self.list_buf, 0, -1, false, lines)
  vim.bo[self.list_buf].modifiable = false
  api.nvim_buf_clear_namespace(self.list_buf, ns, 0, -1)
  for i, m in ipairs(marks) do
    api.nvim_buf_set_extmark(self.list_buf, ns, i - 1, 1, { end_col = math.min(m.name_end, #lines[i]), hl_group = "ClaudeCodeTitle" })
    if m.hint_end > m.name_end then
      api.nvim_buf_set_extmark(self.list_buf, ns, i - 1, m.name_end, { end_col = m.hint_end, hl_group = "ClaudeCodeMuted" })
    end
    api.nvim_buf_set_extmark(self.list_buf, ns, i - 1, m.desc_start, { end_col = #lines[i], hl_group = "ClaudeCodeMuted" })
  end

  -- Sit on the prompt's top border: bottom-left corner just above it, borders aligned.
  local config = {
    relative = "win",
    win = prompt,
    anchor = "SW",
    row = -1,
    col = -1,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    zindex = 50,
    focusable = false,
    footer = { { (" %d/%d · ⇥ complete "):format(self.index, #self.items), "ClaudeCodeMuted" } },
    footer_pos = "right",
  }
  if self:open() then
    api.nvim_win_set_config(self.win, config)
  else
    self.win = api.nvim_open_win(self.list_buf, false, config)
    vim.wo[self.win].winhighlight =
      "NormalFloat:ClaudeCodePicker,FloatBorder:ClaudeCodePickerBorder,FloatFooter:ClaudeCodeMuted,CursorLine:ClaudeCodePickerSelection"
    vim.wo[self.win].cursorline = true
    vim.wo[self.win].wrap = false
  end
  api.nvim_win_set_cursor(self.win, { self.index, 0 })
end

--- Re-anchor after the prompt moved or resized.
function Menu:refresh()
  if self:open() then
    self:render()
  end
end

---@param delta integer
function Menu:move(delta)
  if not self:open() or #self.items == 0 then
    return
  end
  self.index = (self.index - 1 + delta) % #self.items + 1
  self:render()
end

--- Replace the typed `/word` with the selected command.
---@param trailing string Text after it (" " to go on to arguments).
function Menu:accept(trailing)
  local c = self.items[self.index]
  if not c then
    return
  end
  local col = api.nvim_win_get_cursor(0)[2]
  local text = "/" .. c.name .. trailing
  self.accepted = "/" .. c.name
  api.nvim_buf_set_text(self.buf, 0, 0, 0, col, { text })
  api.nvim_win_set_cursor(0, { 1, #text })
  self:close()
end

---@param buf integer Prompt buffer.
---@param get_commands fun(): claude_code.SlashCommand[]
---@return claude_code.SlashMenu
function M.attach(buf, get_commands)
  local self = setmetatable({ buf = buf, get_commands = get_commands, items = {}, index = 1 }, Menu)

  local cmp_quieted = false
  local group = api.nvim_create_augroup("claude-code.slash." .. buf, { clear = true })
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = buf,
    callback = function()
      -- nvim-cmp usually loads lazily on InsertEnter, so try again until it's there.
      if not cmp_quieted then
        vim.schedule(function()
          cmp_quieted = quiet_other_completers(buf)
        end)
      end
    end,
  })
  api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = group,
    buffer = buf,
    callback = function(ev)
      -- Moving the cursor only matters if it leaves the command.
      if ev.event == "CursorMovedI" and (not self:open() or M.query(buf)) then
        return
      end
      self:update()
    end,
  })
  api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    buffer = buf,
    callback = function()
      self:close()
    end,
  })

  -- While the list is open these act on it; otherwise they do what they normally do.
  local function map(lhs, fn)
    vim.keymap.set("i", lhs, function()
      if self:open() then
        fn()
      else
        api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
      end
    end, { buffer = buf, desc = "Claude: slash command suggestions" })
  end
  map("<Tab>", function()
    self:accept(" ")
  end)
  map("<CR>", function()
    self:accept("")
  end)
  map("<C-n>", function()
    self:move(1)
  end)
  map("<C-p>", function()
    self:move(-1)
  end)
  return self
end

return M
