-- A Telescope-style dialog for AskUserQuestion:
--
--   ╭ question ───────────────────────────────╮
--   ╰─────────────────────────────────────────╯
--   ╭ options ───────╮╭ details ──────────────╮
--   │ 1  Red         ││ description, preview  │
--   │ o  Other…      ││                       │
--   │ c  Chat about… ││                       │
--   ╰────────────────╯╰───────────────────────╯
--   ╭ notes / your answer ────────────────────╮
--   ╰──────────────────────────── key hints ──╯
--
-- Questions are answered one after another. The dialog is modal: dismissing it
-- declines the questions, as in Claude Code.

local api = vim.api
local icons = require("claude-code.ui.icons")

local ns = api.nvim_create_namespace("claude-code.question")

---@class claude_code.QuestionOption
---@field label string
---@field description? string
---@field preview? string

---@class claude_code.Question
---@field question string
---@field header? string
---@field options claude_code.QuestionOption[]
---@field multiSelect? boolean

---@alias claude_code.QuestionAnnotations table<string, { notes?: string, preview?: string }>

---@class claude_code.QuestionPickerOpts
---@field on_answer fun(answers: table<string, string>, annotations: claude_code.QuestionAnnotations)
---@field on_decline fun() Dismissed without answering.
---@field on_chat fun(answers: table<string, string>) "Chat about this": talk it over instead.

---@alias claude_code.InputMode "notes"|"other"

---@class claude_code.QuestionPicker
---@field private questions claude_code.Question[]
---@field private opts claude_code.QuestionPickerOpts
---@field private index integer
---@field private answers table<string, string>
---@field private annotations claude_code.QuestionAnnotations
---@field private selected table<integer, boolean>
---@field private notes string Notes for the current question.
---@field private other string "Other" answer text for the current question.
---@field private mode claude_code.InputMode What the input window is editing.
---@field private bufs { question: integer, list: integer, preview: integer, input: integer }
---@field private wins { question?: integer, list?: integer, preview?: integer, input?: integer }
---@field private closing boolean
---@field private augroup? integer
local Picker = {}
Picker.__index = Picker

--- Word-wrap `text` to `width` columns.
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local rows = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        table.insert(rows, line)
        line = word
      end
    end
    table.insert(rows, line)
  end
  return rows
end

---@param text string
---@param width integer
local function clip(text, width)
  if vim.fn.strdisplaywidth(text) > width then
    return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
  end
  return text
end

---@param modifiable? boolean
local function scratch(modifiable)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "claude-code-question"
  vim.bo[buf].modifiable = modifiable or false
  return buf
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
end

--- The message Claude Code sends when the user picks "Chat about this".
---@param questions claude_code.Question[]
---@param answers table<string, string>
---@return string
function Picker.chat_message(questions, answers)
  local lines = {
    "The user wants to clarify these questions.",
    "This means they may have additional information, context or questions for you.",
    "Take their response into account and then reformulate the questions if appropriate.",
    "Start by asking them what they would like to clarify.",
    "",
    "Questions asked:",
  }
  for _, q in ipairs(questions) do
    table.insert(lines, ('- "%s"'):format(q.question))
    local answer = answers[q.question]
    table.insert(lines, answer and ("  Answer: " .. answer) or "  (No answer provided)")
  end
  return table.concat(lines, "\n")
end

---@param questions claude_code.Question[]
---@param opts claude_code.QuestionPickerOpts
---@return claude_code.QuestionPicker
function Picker.new(questions, opts)
  return setmetatable({
    questions = questions,
    opts = opts,
    index = 1,
    answers = {},
    annotations = {},
    selected = {},
    notes = "",
    other = "",
    mode = "notes",
    wins = {},
    closing = false,
  }, Picker)
end

function Picker:is_open()
  return self.wins.list ~= nil and api.nvim_win_is_valid(self.wins.list)
end

---@private
function Picker:current()
  return self.questions[self.index]
end

---@private
function Picker:option_count()
  return #(self:current().options or {})
end

--- List rows: each option, then "Other…" and "Chat about this".
---@private
---@param row integer
---@return "option"|"other"|"chat"
function Picker:row_kind(row)
  local n = self:option_count()
  if row <= n then
    return "option"
  end
  return row == n + 1 and "other" or "chat"
end

---@private
---@return integer
function Picker:cursor()
  return api.nvim_win_get_cursor(self.wins.list)[1]
end

function Picker:open()
  if self:is_open() then
    self:focus_list()
    return
  end
  vim.cmd("stopinsert")
  self.bufs = { question = scratch(), list = scratch(), preview = scratch(), input = scratch(true) }
  pcall(vim.treesitter.start, self.bufs.preview, "markdown")
  self:map_keys()
  self:layout()
  self:focus_list()

  self.augroup = api.nvim_create_augroup("claude-code.question", { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = self.augroup,
    buffer = self.bufs.list,
    callback = function()
      self:render_preview()
    end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.bufs.input,
    callback = function()
      self:save_input()
      self:render_input_decor()
    end,
  })
  -- Modal: wandering off to another window brings you back.
  api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      if not self:owns(api.nvim_get_current_win()) then
        vim.schedule(function()
          if self:is_open() and not self:owns(api.nvim_get_current_win()) then
            self:focus_list()
          end
        end)
      end
    end,
  })
  -- Any of our windows closing (e.g. :q) dismisses the dialog.
  api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    callback = function(ev)
      if not self.closing and self:owns(tonumber(ev.match)) then
        vim.schedule(function()
          self:decline()
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:layout()
    end,
  })
end

---@private
---@param win? integer
function Picker:owns(win)
  for _, w in pairs(self.wins) do
    if w == win then
      return true
    end
  end
  return false
end

--- Size and place the windows, centered in the editor.
---@private
function Picker:layout()
  local q = self:current()
  local width = math.min(math.max(math.floor(vim.o.columns * 0.7), 60), vim.o.columns - 4, 120)
  local list_width = math.floor(width * 0.4)
  local preview_width = width - list_width

  local question_lines = wrap(q.question or "", width - 4)
  local body = math.min(math.max((self:option_count() + 2) * 2, 8), 18)
  local input_height = 1
  local height = (#question_lines + 2) + (body + 2) + (input_height + 2)
  local row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 0)
  local col = math.floor((vim.o.columns - width) / 2)

  local function place(key, config, enter)
    config = vim.tbl_extend("force", { relative = "editor", style = "minimal", border = "rounded", zindex = 60 }, config)
    if self.wins[key] and api.nvim_win_is_valid(self.wins[key]) then
      api.nvim_win_set_config(self.wins[key], config)
    else
      self.wins[key] = api.nvim_open_win(self.bufs[key], enter or false, config)
    end
    vim.wo[self.wins[key]].winhighlight = table.concat({
      "NormalFloat:ClaudeCodePicker",
      "FloatBorder:ClaudeCodePickerBorder",
      "FloatTitle:ClaudeCodePickerTitle",
      "FloatFooter:ClaudeCodeMuted",
      "CursorLine:ClaudeCodePickerSelection",
    }, ",")
  end

  local count = #self.questions > 1 and (" %d/%d"):format(self.index, #self.questions) or ""
  local header = q.header and q.header ~= "" and { { " " .. q.header .. " ", "ClaudeCodePickerChip" } } or nil
  place("question", {
    row = row,
    col = col,
    width = width - 2,
    height = #question_lines,
    title = { { (" %s Claude asks%s "):format(icons.get().question, count), "ClaudeCodePickerTitle" } },
    title_pos = "left",
    footer = header,
    footer_pos = header and "right" or nil,
    focusable = false,
  })
  local body_row = row + #question_lines + 2
  place("list", {
    row = body_row,
    col = col,
    width = list_width - 2,
    height = body,
    title = { { q.multiSelect and " Options · pick any " or " Options ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
  }, true)
  place("preview", {
    row = body_row,
    col = col + list_width,
    width = preview_width - 2,
    height = body,
    title = { { " Details ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
    focusable = false,
  })
  place("input", {
    row = body_row + body + 2,
    col = col,
    width = width - 2,
    height = input_height,
  })
  vim.wo[self.wins.list].cursorline = true
  vim.wo[self.wins.preview].wrap = false
  vim.wo[self.wins.preview].conceallevel = 2
  vim.wo[self.wins.question].wrap = false

  set_lines(self.bufs.question, question_lines)
  api.nvim_buf_clear_namespace(self.bufs.question, ns, 0, -1)
  for i = 0, #question_lines - 1 do
    api.nvim_buf_set_extmark(self.bufs.question, ns, i, 0, { line_hl_group = "ClaudeCodeTitle" })
  end
  self:render_list()
  self:render_preview()
  self:render_input()
end

---@private
function Picker:render_list()
  local q = self:current()
  local lines = {}
  for i, opt in ipairs(q.options or {}) do
    local box = q.multiSelect and (self.selected[i] and "[x] " or "[ ] ") or ""
    table.insert(lines, (" %d  %s%s"):format(i, box, opt.label or ""))
  end
  table.insert(lines, " o  Other…")
  table.insert(lines, " c  Chat about this")
  set_lines(self.bufs.list, lines)
  api.nvim_buf_clear_namespace(self.bufs.list, ns, 0, -1)
  for i = 0, #lines - 1 do
    local kind = self:row_kind(i + 1)
    api.nvim_buf_set_extmark(self.bufs.list, ns, i, 0, {
      end_col = 3,
      hl_group = kind == "option" and "ClaudeCodeCardKey" or "ClaudeCodePickerChip",
    })
    if kind ~= "option" then
      api.nvim_buf_set_extmark(self.bufs.list, ns, i, 4, { end_col = #lines[i + 1], hl_group = "ClaudeCodeMuted" })
    elseif q.multiSelect and self.selected[i + 1] then
      api.nvim_buf_set_extmark(self.bufs.list, ns, i, 4, { end_col = 7, hl_group = "ClaudeCodeToolSuccess" })
    end
  end
  -- The "Other" row shows what has been typed for it.
  if self.other ~= "" then
    api.nvim_buf_set_extmark(self.bufs.list, ns, self:option_count(), 0, {
      virt_text = { { " " .. self.other, "ClaudeCodeToolDetail" } },
    })
  end
end

---@private
function Picker:render_preview()
  if not self:is_open() then
    return
  end
  local row = self:cursor()
  local kind = self:row_kind(row)
  local width = api.nvim_win_get_width(self.wins.preview) - 2
  local lines
  if kind == "option" then
    local opt = self:current().options[row]
    lines = { "**" .. (opt.label or "") .. "**", "" }
    if opt.description and opt.description ~= "" then
      vim.list_extend(lines, wrap(opt.description, width))
    end
    if opt.preview and opt.preview ~= "" then
      table.insert(lines, "")
      vim.list_extend(lines, vim.split(opt.preview, "\n", { plain = true }))
    end
  elseif kind == "other" then
    lines = { "**Other**", "" }
    vim.list_extend(lines, wrap("None of these? Answer in your own words in the box below.", width))
  else
    lines = { "**Chat about this**", "" }
    vim.list_extend(
      lines,
      wrap(
        "Skip the questions and talk it through with Claude in the chat instead. Claude will ask what you'd like to clarify.",
        width
      )
    )
  end
  set_lines(self.bufs.preview, lines)
end

--- Load the input window with the text for the current mode.
---@private
function Picker:render_input()
  local text = self.mode == "other" and self.other or self.notes
  set_lines(self.bufs.input, { text })
  self:render_input_decor()
end

--- Title, placeholder and key hints for the input window.
---@private
function Picker:render_input_decor()
  local win = self.wins.input
  if not (win and api.nvim_win_is_valid(win)) then
    return
  end
  local editing = api.nvim_get_current_win() == win
  local title, placeholder
  if self.mode == "other" then
    title, placeholder = " Your answer ", "Type your answer…"
  else
    title = " Notes · optional "
    placeholder = editing and "Add a note for Claude…" or "Press n to add a note for Claude…"
  end

  local hints
  if editing then
    hints = self.mode == "other" and "⏎ send · esc back" or "⏎ done · esc back"
  elseif self:current().multiSelect then
    hints = "⇥ toggle · ⏎ confirm · n notes · o other · c chat · esc decline"
  else
    hints = "⏎ choose · n notes · o other · c chat · esc decline"
  end
  local width = api.nvim_win_get_width(win)
  api.nvim_win_set_config(win, {
    title = { { title, "ClaudeCodePickerTitle" } },
    title_pos = "left",
    footer = { { " " .. clip(hints, width - 4) .. " ", "ClaudeCodeMuted" } },
    footer_pos = "right",
  })

  api.nvim_buf_clear_namespace(self.bufs.input, ns, 0, -1)
  local lines = api.nvim_buf_get_lines(self.bufs.input, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    api.nvim_buf_set_extmark(self.bufs.input, ns, 0, 0, {
      virt_text = { { placeholder, "ClaudeCodePlaceholder" } },
      virt_text_pos = "overlay",
    })
  end
end

---@private
function Picker:save_input()
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(self.bufs.input, 0, -1, false), " "))
  if self.mode == "other" then
    self.other = text
  else
    self.notes = text
  end
end

---@private
function Picker:focus_list()
  if not self:is_open() then
    return
  end
  vim.cmd("stopinsert")
  api.nvim_set_current_win(self.wins.list)
  if self.mode ~= "notes" then
    self.mode = "notes"
    self:render_input()
  else
    self:render_input_decor()
  end
  local cursor = api.nvim_win_get_cursor(self.wins.list)
  self:render_list()
  api.nvim_win_set_cursor(self.wins.list, cursor)
end

---@private
---@param mode claude_code.InputMode
function Picker:focus_input(mode)
  self.mode = mode
  self:render_input()
  api.nvim_set_current_win(self.wins.input)
  self:render_input_decor()
  vim.cmd("startinsert!")
end

---@private
function Picker:map_keys()
  local function map(buf, mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true })
  end
  local list = self.bufs.list

  for i = 1, 9 do
    map(list, "n", tostring(i), function()
      if i <= self:option_count() then
        api.nvim_win_set_cursor(self.wins.list, { i, 0 })
        if self:current().multiSelect then
          self:toggle(i)
        else
          self:choose(i)
        end
      end
    end)
  end
  map(list, "n", "<CR>", function()
    local row = self:cursor()
    local kind = self:row_kind(row)
    if kind == "other" then
      self:focus_input("other")
    elseif kind == "chat" then
      self:chat()
    elseif self:current().multiSelect then
      self:confirm()
    else
      self:choose(row)
    end
  end)
  for _, lhs in ipairs({ "<Tab>", "<Space>" }) do
    map(list, "n", lhs, function()
      local row = self:cursor()
      if self:current().multiSelect and self:row_kind(row) == "option" then
        self:toggle(row)
        api.nvim_win_set_cursor(self.wins.list, { math.min(row + 1, self:option_count()), 0 })
      end
    end)
  end
  for _, lhs in ipairs({ "n", "i", "a" }) do
    map(list, "n", lhs, function()
      self:focus_input("notes")
    end)
  end
  map(list, "n", "o", function()
    api.nvim_win_set_cursor(self.wins.list, { self:option_count() + 1, 0 })
    self:focus_input("other")
  end)
  map(list, "n", "c", function()
    self:chat()
  end)
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    map(list, "n", lhs, function()
      self:decline()
    end)
  end
  for _, lhs in ipairs({ "<C-n>", "<Down>" }) do
    map(list, "n", lhs, "j")
  end
  for _, lhs in ipairs({ "<C-p>", "<Up>" }) do
    map(list, "n", lhs, "k")
  end

  -- Input: <CR> finishes (sends an "Other" answer, or keeps the note); <Esc> in
  -- normal mode goes back to the options.
  local input = self.bufs.input
  local function submit_input()
    self:save_input()
    if self.mode == "other" then
      if self.other == "" then
        return
      end
      self:record(self.other)
    else
      self:focus_list()
    end
  end
  map(input, { "i", "n" }, "<CR>", submit_input)
  map(input, { "i", "n" }, "<C-s>", submit_input)
  for _, lhs in ipairs({ "<Esc>", "q" }) do
    map(input, "n", lhs, function()
      self:save_input()
      self:focus_list()
    end)
  end
end

---@private
---@param i integer
function Picker:toggle(i)
  self.selected[i] = not self.selected[i] or nil
  local cursor = api.nvim_win_get_cursor(self.wins.list)
  self:render_list()
  api.nvim_win_set_cursor(self.wins.list, cursor)
end

---@private
---@param i integer
function Picker:choose(i)
  local opt = self:current().options[i]
  self:record(opt.label, opt.preview)
end

---@private
function Picker:confirm()
  local labels = {}
  for i, opt in ipairs(self:current().options or {}) do
    if self.selected[i] then
      table.insert(labels, opt.label)
    end
  end
  if #labels == 0 then
    -- Nothing checked: take the highlighted option.
    local opt = self:current().options[self:cursor()]
    if not opt then
      return
    end
    labels = { opt.label }
  end
  self:record(table.concat(labels, ", "))
end

--- Record the answer to the current question; move on or finish.
---@private
---@param answer string
---@param preview? string Preview of the chosen option, if it had one.
function Picker:record(answer, preview)
  local q = self:current()
  self.answers[q.question] = answer
  local has_preview = preview ~= nil and preview ~= ""
  if self.notes ~= "" or has_preview then
    self.annotations[q.question] = {
      notes = self.notes ~= "" and self.notes or nil,
      preview = has_preview and preview or nil,
    }
  end
  if self.index < #self.questions then
    self.index = self.index + 1
    self.selected, self.notes, self.other, self.mode = {}, "", "", "notes"
    self:layout()
    api.nvim_win_set_cursor(self.wins.list, { 1, 0 })
    self:focus_list()
    return
  end
  self:close()
  self.opts.on_answer(self.answers, self.annotations)
end

---@private
function Picker:decline()
  if self.closing then
    return
  end
  self:close()
  self.opts.on_decline()
end

---@private
function Picker:chat()
  self:close()
  self.opts.on_chat(self.answers)
end

--- Close without reporting anything (answered, declined, or withdrawn by Claude).
function Picker:close()
  if self.closing then
    return
  end
  self.closing = true
  vim.cmd("stopinsert")
  if self.augroup then
    pcall(api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end
  for key, win in pairs(self.wins) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
    self.wins[key] = nil
  end
end

return Picker
