-- The session picker, Telescope-style:
--
--   ╭ sessions ──────────────╮╭ preview ─────────────────╮
--   │ ● Fix the login bug 2h ││ title, branch, directory │
--   │   Refactor parser  1d  ││                          │
--   ╰────────────────────────╯│ last few exchanges       │
--   ╭ search ────────────────╮│                          │
--   ╰────────────────────────╯╰────────────── key hints ─╯
--
-- Lists the current project's sessions (or every project's, with <C-g>),
-- merged with the sessions open in this Neovim.

local api = vim.api
local control = require("claude-code.control")
local icons = require("claude-code.ui.icons")
local sessions = require("claude-code.sessions")

local ns = api.nvim_create_namespace("claude-code.sessions")

local M = {}

--- Messages shown in the preview.
local PREVIEW_MESSAGES = 12

---@class claude_code.SessionEntry
---@field id string
---@field title string
---@field last_used integer os.time()
---@field cwd? string
---@field branch? string
---@field first_prompt? string
---@field info? table SDKSessionInfo, for stored sessions
---@field live? claude_code.Session Open in this Neovim.
---@field elsewhere? integer pid of another Claude Code process that has it open

---@class claude_code.PickerState
---@field scope "project"|"all"
---@field query string
---@field selected_id? string

---@param seconds integer
local function ago(seconds)
  local d = os.time() - seconds
  if d < 60 then
    return "just now"
  elseif d < 3600 then
    return ("%dm ago"):format(d / 60)
  elseif d < 86400 then
    return ("%dh ago"):format(d / 3600)
  elseif d < 7 * 86400 then
    return ("%dd ago"):format(d / 86400)
  end
  return os.date("%b %d", seconds) --[[@as string]]
end

---@param text string
---@param width integer
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
    if line ~= "" then
      table.insert(rows, line)
    end
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

--- Status glyph and highlight for a row.
---@param entry claude_code.SessionEntry
---@return string glyph, string hl, string label
local function status(entry)
  local s = entry.live
  if s then
    if s:needs_attention() then
      return icons.get().permission, "ClaudeCodePromptAttention", "needs your input"
    elseif s.busy then
      return "●", "ClaudeCodeStatus", "working"
    elseif s:running() then
      return "●", "ClaudeCodeToolSuccess", "open"
    end
    return "○", "ClaudeCodeMuted", "open (suspended)"
  elseif entry.elsewhere then
    return "◆", "DiagnosticWarn", ("open in another Claude Code (pid %d)"):format(entry.elsewhere)
  end
  return " ", "Normal", "saved"
end

---@class claude_code.SessionPicker
---@field private state claude_code.PickerState
---@field private entries claude_code.SessionEntry[]
---@field private shown claude_code.SessionEntry[] After filtering.
---@field private index integer Selected row in `shown`.
---@field private bufs { list: integer, prompt: integer, preview: integer }
---@field private wins { list?: integer, prompt?: integer, preview?: integer }
---@field private previews table<string, table> Cache: id..mtime -> get_messages result.
---@field private preview_token integer
---@field private loading boolean
---@field private closed boolean
---@field private augroup integer
local Picker = {}
Picker.__index = Picker

--- Stored sessions plus the ones open in this Neovim (including new sessions
--- not written to disk yet), newest first.
---@param stored table[] SDKSessionInfo[]
---@param scope "project"|"all"
---@return claude_code.SessionEntry[]
local function merge(stored, scope)
  local elsewhere = sessions.open_elsewhere()
  local by_id = {}
  local entries = {}
  for _, info in ipairs(stored) do
    local entry = {
      id = info.sessionId,
      title = info.customTitle or info.summary or "Untitled",
      last_used = math.floor((info.lastModified or 0) / 1000),
      cwd = info.cwd,
      branch = info.gitBranch,
      first_prompt = info.firstPrompt,
      info = info,
      elsewhere = elsewhere[info.sessionId],
    }
    by_id[entry.id] = entry
    table.insert(entries, entry)
  end
  local cwd = vim.fn.getcwd()
  for _, s in ipairs(sessions.live()) do
    local entry = by_id[s.id]
    if not entry and (scope == "all" or s.cwd == cwd) then
      entry = { id = s.id, title = s.title or "New session", last_used = s.last_active, cwd = s.cwd }
      table.insert(entries, entry)
    end
    if entry then
      entry.live = s
      entry.title = s.title or entry.title
      entry.last_used = math.max(entry.last_used, s.last_active)
    end
  end
  table.sort(entries, function(a, b)
    return a.last_used > b.last_used
  end)
  return entries
end

---@param state? claude_code.PickerState
function M.open(state)
  local self = setmetatable({
    state = state or { scope = "project", query = "" },
    entries = merge({}, (state or {}).scope or "project"),
    shown = {},
    index = 1,
    wins = {},
    previews = {},
    preview_token = 0,
    loading = true,
    closed = false,
  }, Picker)
  self:create()
  self:load()
end

---@private
function Picker:create()
  local function scratch(modifiable)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "claude-code-sessions"
    vim.bo[buf].modifiable = modifiable or false
    return buf
  end
  self.bufs = { list = scratch(), prompt = scratch(true), preview = scratch() }
  pcall(vim.treesitter.start, self.bufs.preview, "markdown")
  api.nvim_buf_set_lines(self.bufs.prompt, 0, -1, false, { self.state.query })
  self:layout()
  self:map_keys()

  self.augroup = api.nvim_create_augroup("claude-code.session-picker", { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.bufs.prompt,
    callback = function()
      self.state.query = api.nvim_buf_get_lines(self.bufs.prompt, 0, 1, false)[1] or ""
      self.index, self.state.selected_id = 1, nil
      self:filter()
    end,
  })
  -- Leaving the picker closes it.
  api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      local win = api.nvim_get_current_win()
      if win ~= self.wins.prompt then
        vim.schedule(function()
          self:close()
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:layout()
      self:render()
    end,
  })
  api.nvim_set_current_win(self.wins.prompt)
  vim.cmd("startinsert!")
end

---@private
function Picker:layout()
  local width = math.min(math.max(math.floor(vim.o.columns * 0.8), 80), vim.o.columns - 4, 150)
  local height = math.min(math.max(math.floor(vim.o.lines * 0.7), 16), vim.o.lines - 4, 36)
  local left = math.floor(width * 0.45)
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)
  local list_height = height - 2 - 3

  local function place(key, config)
    config = vim.tbl_extend("force", { relative = "editor", style = "minimal", border = "rounded", zindex = 60 }, config)
    if self.wins[key] and api.nvim_win_is_valid(self.wins[key]) then
      api.nvim_win_set_config(self.wins[key], config)
    else
      self.wins[key] = api.nvim_open_win(self.bufs[key], false, config)
    end
    vim.wo[self.wins[key]].winhighlight = table.concat({
      "NormalFloat:ClaudeCodePicker",
      "FloatBorder:ClaudeCodePickerBorder",
      "FloatTitle:ClaudeCodePickerTitle",
      "FloatFooter:ClaudeCodeMuted",
      "CursorLine:ClaudeCodePickerSelection",
    }, ",")
  end

  place("list", { row = row, col = col, width = left - 2, height = list_height, focusable = false })
  place("prompt", {
    row = row + list_height + 2,
    col = col,
    width = left - 2,
    height = 1,
    title = { { " " .. icons.get().claude .. " Search ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
  })
  place("preview", {
    row = row,
    col = col + left,
    width = width - left - 2,
    height = height - 2,
    title = { { " Preview ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
    focusable = false,
  })
  vim.wo[self.wins.list].cursorline = true
  vim.wo[self.wins.preview].wrap = false
  vim.wo[self.wins.preview].conceallevel = 2
  local hints = " ⏎ open · ^A new · ^R rename · ^G all projects · esc "
  api.nvim_win_set_config(self.wins.preview, {
    footer = { { clip(hints, width - left - 4), "ClaudeCodeMuted" } },
    footer_pos = "right",
  })
end

--- Fetch stored sessions for the scope, then show them.
---@private
function Picker:load()
  self.loading = true
  self:filter()
  local dir = self.state.scope == "project" and vim.fn.getcwd() or nil
  local scope = self.state.scope
  control.request("list_sessions", { dir = dir, limit = 200 }, function(err, result)
    if self.closed or scope ~= self.state.scope then
      return
    end
    self.loading = false
    if err then
      vim.notify("claude-code: couldn't list sessions: " .. err, vim.log.levels.ERROR)
    end
    self.entries = merge(result or {}, scope)
    self:filter()
  end)
end

---@private
function Picker:filter()
  local query = vim.trim(self.state.query)
  if query == "" then
    self.shown = self.entries
  else
    -- matchfuzzy converts its list to Vimscript values, and entries for open sessions
    -- hold the live Session (functions, process handles), so match plain records.
    local records = {}
    for i, entry in ipairs(self.entries) do
      records[i] = {
        text = entry.title .. " " .. (entry.first_prompt or "") .. " " .. (entry.branch or ""),
        index = i,
      }
    end
    self.shown = vim.tbl_map(function(record)
      return self.entries[record.index]
    end, vim.fn.matchfuzzy(records, query, { key = "text" }))
  end
  -- Keep the selection on the same session when the list changes.
  if self.state.selected_id then
    for i, entry in ipairs(self.shown) do
      if entry.id == self.state.selected_id then
        self.index = i
      end
    end
  end
  self.index = math.max(math.min(self.index, #self.shown), 1)
  self:render()
end

---@private
function Picker:render()
  if self.closed then
    return
  end
  local win = self.wins.list
  local width = api.nvim_win_get_width(win)
  local current = sessions.current()
  local lines, marks = {}, {}
  for i, entry in ipairs(self.shown) do
    local glyph, hl = status(entry)
    local right = ago(entry.last_used)
    if self.state.scope == "all" and entry.cwd then
      right = vim.fn.fnamemodify(entry.cwd, ":t") .. " · " .. right
    end
    if current and entry.live == current then
      right = "current · " .. right
    end
    local title = clip(entry.title:gsub("\n", " "), math.max(width - vim.fn.strdisplaywidth(right) - 6, 10))
    lines[i] = (" %s %s"):format(glyph, title)
    marks[i] = { glyph = glyph, hl = hl, right = right }
  end
  if #lines == 0 then
    lines = { self.loading and "  Loading…" or "  No sessions" }
  end

  vim.bo[self.bufs.list].modifiable = true
  api.nvim_buf_set_lines(self.bufs.list, 0, -1, false, lines)
  vim.bo[self.bufs.list].modifiable = false
  api.nvim_buf_clear_namespace(self.bufs.list, ns, 0, -1)
  for i, m in ipairs(marks) do
    api.nvim_buf_set_extmark(self.bufs.list, ns, i - 1, 1, { end_col = 1 + #m.glyph, hl_group = m.hl })
    api.nvim_buf_set_extmark(self.bufs.list, ns, i - 1, 0, {
      virt_text = { { m.right .. " ", "ClaudeCodeMuted" } },
      virt_text_pos = "right_align",
    })
  end
  if #self.shown == 0 then
    api.nvim_buf_set_extmark(self.bufs.list, ns, 0, 0, { line_hl_group = "ClaudeCodeMuted" })
  end

  local scope = self.state.scope == "project" and vim.fn.fnamemodify(vim.fn.getcwd(), ":t") or "all projects"
  local count = #self.shown == #self.entries and tostring(#self.entries) or ("%d/%d"):format(#self.shown, #self.entries)
  api.nvim_win_set_config(win, {
    title = { { (" Sessions · %s "):format(scope), "ClaudeCodePickerTitle" } },
    title_pos = "left",
    footer = { { (" %s "):format(count), "ClaudeCodeMuted" } },
    footer_pos = "right",
  })
  api.nvim_win_set_cursor(win, { self.index, 0 })
  local entry = self.shown[self.index]
  self.state.selected_id = entry and entry.id
  self:render_preview()
end

---@private
function Picker:render_preview()
  local entry = self.shown[self.index]
  local width = api.nvim_win_get_width(self.wins.preview) - 2
  if not entry then
    self:set_preview({})
    return
  end

  local _, hl, label = status(entry)
  local meta = {}
  if entry.branch then
    table.insert(meta, " " .. entry.branch)
  end
  if entry.cwd then
    table.insert(meta, vim.fn.fnamemodify(entry.cwd, ":~"))
  end
  table.insert(meta, "last used " .. ago(entry.last_used))
  local header = {
    { (entry.title:gsub("\n", " ")), "ClaudeCodeTitle" },
    { table.concat(meta, " · "), "ClaudeCodeMuted" },
    { label, hl },
    { "", "Normal" },
  }

  local key = entry.id .. ":" .. entry.last_used
  local cached = self.previews[key]
  if cached then
    self:set_preview(header, self:conversation(cached, width))
    return
  end
  if not entry.info then
    self:set_preview(header, { { "No messages yet.", "ClaudeCodeMuted" } })
    return
  end
  self:set_preview(header, { { "Loading…", "ClaudeCodeMuted" } })
  -- Debounce: only fetch for the row the cursor settles on.
  self.preview_token = self.preview_token + 1
  local token = self.preview_token
  vim.defer_fn(function()
    if self.closed or token ~= self.preview_token then
      return
    end
    control.request(
      "get_messages",
      { session_id = entry.id, dir = entry.cwd, tail = PREVIEW_MESSAGES },
      function(err, result)
        if self.closed then
          return
        end
        self.previews[key] = err and { messages = {} } or result
        if token == self.preview_token then
          self:render_preview()
        end
      end
    )
  end, 80)
end

--- The tail of a conversation as preview lines.
---@private
---@param result { messages: table[], total: integer }
---@param width integer
---@return claude_code.Chunk[]
function Picker:conversation(result, width)
  local out = {}
  local last_role
  local function say(role, text, max_lines)
    if role ~= last_role then
      if #out > 0 then
        table.insert(out, { "", "Normal" })
      end
      table.insert(out, role == "user" and { icons.get().user .. " You", "ClaudeCodeUserHeader" }
        or { icons.get().claude .. " Claude", "ClaudeCodeAssistantHeader" })
      last_role = role
    end
    local rows = wrap(text, width)
    for i, row in ipairs(rows) do
      if i > max_lines then
        table.insert(out, { "…", "ClaudeCodeMuted" })
        break
      end
      table.insert(out, { row, "Normal" })
    end
  end
  if (result.total or 0) > #(result.messages or {}) then
    table.insert(out, { ("… %d earlier messages"):format(result.total - #result.messages), "ClaudeCodeMuted" })
  end
  for _, m in ipairs(result.messages or {}) do
    local content = type(m.message) == "table" and m.message.content
    if m.parent_tool_use_id then
      -- skip subagent traffic
    elseif m.type == "user" then
      local text = type(content) == "string" and content or ""
      if type(content) == "table" then
        for _, block in ipairs(content) do
          if block.type == "text" then
            text = text .. block.text
          end
        end
      end
      text = vim.trim(text)
      if text ~= "" and not text:match("^%s*<[%w_-]+>") and not text:match("^Caveat:") then
        say("user", text, 4)
      end
    elseif m.type == "assistant" and type(content) == "table" then
      for _, block in ipairs(content) do
        if block.type == "text" and vim.trim(block.text) ~= "" then
          say("assistant", block.text, 6)
        elseif block.type == "tool_use" then
          if last_role ~= "assistant" then
            say("assistant", "", 0)
          end
          local detail = require("claude-code.ui.tools").detail(block.input or {})
          table.insert(out, {
            clip(("  %s %s%s"):format(icons.tool(block.name), block.name, detail and (" " .. detail) or ""), width),
            "ClaudeCodeToolDetail",
          })
        end
      end
    end
  end
  if #out == 0 then
    out = { { "No messages yet.", "ClaudeCodeMuted" } }
  end
  return out
end

---@private
---@param header claude_code.Chunk[]
---@param body? claude_code.Chunk[]
function Picker:set_preview(header, body)
  local chunks = vim.list_extend(vim.list_extend({}, header), body or {})
  local lines = {}
  for i, c in ipairs(chunks) do
    lines[i] = c[1]
  end
  vim.bo[self.bufs.preview].modifiable = true
  api.nvim_buf_set_lines(self.bufs.preview, 0, -1, false, lines)
  vim.bo[self.bufs.preview].modifiable = false
  api.nvim_buf_clear_namespace(self.bufs.preview, ns, 0, -1)
  for i, c in ipairs(chunks) do
    if c[2] ~= "Normal" and #c[1] > 0 then
      api.nvim_buf_set_extmark(self.bufs.preview, ns, i - 1, 0, { end_col = #c[1], hl_group = c[2] })
    end
  end
  -- Show the end of the conversation (the most recent bit).
  if body and #lines > api.nvim_win_get_height(self.wins.preview) then
    api.nvim_win_set_cursor(self.wins.preview, { #lines, 0 })
  else
    api.nvim_win_set_cursor(self.wins.preview, { 1, 0 })
  end
end

---@private
---@param delta integer
function Picker:move(delta)
  if #self.shown == 0 then
    return
  end
  self.index = (self.index - 1 + delta) % #self.shown + 1
  self:render()
end

---@private
function Picker:map_keys()
  local buf = self.bufs.prompt
  local function map(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = buf, nowait = true })
  end
  for _, lhs in ipairs({ "<C-n>", "<Down>", "<C-j>" }) do
    map(lhs, function()
      self:move(1)
    end)
  end
  for _, lhs in ipairs({ "<C-p>", "<Up>", "<C-k>" }) do
    map(lhs, function()
      self:move(-1)
    end)
  end
  map("<CR>", function()
    local entry = self.shown[self.index]
    if not entry then
      return
    end
    self:close()
    if entry.live then
      sessions.show(entry.live)
    else
      sessions.open(entry.info)
    end
  end)
  map("<C-a>", function()
    self:close()
    require("claude-code.ui.input").open({
      title = "New session name (optional)",
      on_submit = function(name)
        sessions.new(name)
      end,
      on_cancel = function()
        M.open(self.state)
      end,
    })
  end)
  map("<C-r>", function()
    local entry = self.shown[self.index]
    if not entry then
      return
    end
    self:close()
    require("claude-code.ui.input").open({
      title = "Rename session",
      default = entry.title,
      on_submit = function(title)
        if title == "" or title == entry.title then
          M.open(self.state)
        elseif entry.live then
          entry.live:rename(title)
          M.open(self.state)
        else
          control.request("rename_session", { session_id = entry.id, title = title, dir = entry.cwd }, function(err)
            if err then
              vim.notify("claude-code: rename failed: " .. err, vim.log.levels.ERROR)
            end
            M.open(self.state)
          end)
        end
      end,
      on_cancel = function()
        M.open(self.state)
      end,
    })
  end)
  map("<C-g>", function()
    self.state.scope = self.state.scope == "project" and "all" or "project"
    self.index = 1
    self.entries = merge({}, self.state.scope)
    self:load()
  end)
  for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
    map(lhs, function()
      self:close()
    end)
  end
end

function Picker:close()
  if self.closed then
    return
  end
  self.closed = true
  vim.cmd("stopinsert")
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  for _, win in pairs(self.wins) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

return M
