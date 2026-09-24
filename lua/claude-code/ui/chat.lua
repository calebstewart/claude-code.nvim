-- The chat sidebar. Layout, top to bottom:
--
--   transcript  a split showing the conversation
--   dock        an empty split that reserves room at the bottom...
--   prompt      ...for the floating, bordered prompt laid over it
--
-- The dock means the float never hides transcript text, and ordinary window
-- commands (resize, close, move) keep working on the splits.

local api = vim.api
local config = require("claude-code.config")
local icons = require("claude-code.ui.icons")
local Prompt = require("claude-code.ui.prompt")
local Transcript = require("claude-code.ui.transcript")
local welcome = require("claude-code.ui.welcome")
local images = require("claude-code.images")

--- Prompt buffer -> chat, for pastes of image paths (see install_paste_hook).
---@type table<integer, claude_code.Chat>
local prompts = {}

--- A pasted (or dragged-in) image path, as terminals deliver it: maybe quoted,
--- maybe with backslash-escaped spaces.
---@param text string
---@return string
local function unescape_path(text)
  text = vim.trim(text)
  text = text:match([[^'(.*)'$]]) or text:match([[^"(.*)"$]]) or text:gsub("\\(.)", "%1")
  return vim.fn.expand(text)
end

--- Pasting a path to an image into a prompt attaches the image. Wraps vim.paste,
--- touching nothing but single-line pastes into a chat prompt.
local function install_paste_hook()
  if vim.g.claude_code_paste_hook then
    return
  end
  vim.g.claude_code_paste_hook = true
  local paste = vim.paste
  vim.paste = function(lines, phase)
    local chat = prompts[api.nvim_get_current_buf()]
    local text = lines[1]
    if chat and phase == -1 and text and (#lines == 1 or (#lines == 2 and lines[2] == "")) then
      local path = unescape_path(text)
      if images.is_image(path) then
        chat:attach_image(path)
        return true
      end
    end
    return paste(lines, phase)
  end
end

---@class claude_code.ChatStatus
---@field activity? string What Claude is doing; nil when idle.
---@field attention? string|false Waiting on the user (a permission card or question); shown in the border.
---@field model? string
---@field cost? number Session cost in USD.
---@field stopped? "suspended"|"ended"|false Not running: suspended while idle, or exited.
---@field mode? string Permission mode.
---@field background? integer Background agents still running.

---@class claude_code.ChatOpts
---@field id integer
---@field on_submit fun(text: string, attachments: { label: string, image: claude_code.Image }[]): boolean Returns false to keep the prompt text.
---@field on_interrupt fun()
---@field session_id? fun(): string? Claude session id, recorded with history entries.
---@field title? string
---@field on_show? fun() Called after the chat is shown (e.g. to present deferred cards).
---@field on_cycle_mode? fun() The cycle-mode key was pressed.
---@field commands? fun(): claude_code.SlashCommand[] Slash commands for completion.

---@class claude_code.Chat
---@field transcript claude_code.Transcript
---@field prompt claude_code.Prompt
---@field private dock integer Scratch buffer shown in the dock split.
---@field private float? integer The prompt window.
---@field private opts claude_code.ChatOpts
---@field private status claude_code.ChatStatus
---@field private timer? uv.uv_timer_t
---@field private frame integer
---@field private title? string
---@field private augroup integer
---@field private slash claude_code.SlashMenu
---@field private in_place? { restore?: integer } Shown in a window it took over (`:Claude here`); what to give it back.
local Chat = {}
Chat.__index = Chat

---@param chunks claude_code.Chunk[]
local function width_of(chunks)
  local w = 0
  for _, c in ipairs(chunks) do
    w = w + vim.fn.strdisplaywidth(c[1])
  end
  return w
end

---@param opts claude_code.ChatOpts
---@return claude_code.Chat
function Chat.new(opts)
  require("claude-code.ui.highlights").setup()
  local self = setmetatable({ opts = opts, status = {}, frame = 1, title = opts.title }, Chat)
  self.transcript = Transcript.new(("claude://session/%d"):format(opts.id))
  self.prompt = Prompt.new(("claude://prompt/%d"):format(opts.id), function()
    self:layout()
  end, opts.session_id)
  self.slash = require("claude-code.ui.slash").attach(self.prompt.buf, function()
    return opts.commands and opts.commands() or {}
  end, function()
    -- <Tab> in an empty prompt takes the suggested next prompt.
    return self.prompt:accept_suggestion()
  end)
  prompts[self.prompt.buf] = self
  install_paste_hook()
  self.dock = api.nvim_create_buf(false, true)
  vim.bo[self.dock].filetype = "claude-code-dock"
  self:apply_keymaps()

  local group = api.nvim_create_augroup(("claude-code.chat.%d"):format(opts.id), { clear = true })
  self.augroup = group
  -- Closing any of the three windows closes the set.
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      local wins = self:windows()
      if closed and (closed == wins.transcript or closed == wins.dock or closed == wins.prompt) then
        vim.schedule(function()
          self:hide({ closing = true })
        end)
      end
    end,
  })
  api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
    group = group,
    callback = function()
      if self:visible() then
        self:layout()
        self:render_welcome()
      end
    end,
  })
  -- The dock is only a placeholder; landing in it means "go to the prompt".
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if api.nvim_get_current_buf() == self.dock then
        vim.schedule(function()
          self:focus_prompt(false)
        end)
      end
    end,
  })
  -- Some focus changes skip WinEnter (e.g. Neovim leaving a float at the end of
  -- startup); starting to type in the dock is the other giveaway.
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = self.dock,
    callback = function()
      vim.schedule(function()
        self:focus_prompt(true)
      end)
    end,
  })
  return self
end

function Chat:valid()
  return self.transcript:valid() and self.prompt:valid()
end

---@return { transcript?: integer, dock?: integer, prompt?: integer }
function Chat:windows()
  local function find(buf)
    local win = vim.fn.bufwinid(buf)
    return win ~= -1 and win or nil
  end
  local prompt = self.float and api.nvim_win_is_valid(self.float) and self.float or nil
  return { transcript = find(self.transcript.buf), dock = find(self.dock), prompt = prompt }
end

function Chat:visible()
  return self:windows().transcript ~= nil
end

--- The chat's windows are stacked, and the row between them is drawn either as
--- a statusline or as a window separator depending on 'laststatus'. Both are
--- hidden so the pane reads as one surface; only the edge against the rest of
--- the editor stays visible.
---@param win integer
local function plain_window(win)
  -- Local to the chat's buffer in this window, so a window handed back after
  -- `:Claude here` gets its own options back.
  local wo = vim.wo[win][0]
  wo.number, wo.relativenumber, wo.cursorline = false, false, false
  wo.signcolumn, wo.foldcolumn, wo.spell = "no", "0", false
  wo.wrap, wo.linebreak = true, true
  -- With laststatus=3 there is no statusline to occupy the row between the
  -- transcript and the prompt, so Neovim draws a separator there instead.
  -- Blanking `horiz` erases the rule, and keeping the junctions as the plain
  -- vertical character stops the pane's edge turning into a tee where the two
  -- meet. A space has no foreground, so the separator highlight below only has
  -- to get the background right.
  local vert = (vim.opt.fillchars:get() or {}).vert or "│"
  wo.fillchars = ("eob: ,horiz: ,horizup: ,horizdown: ,vertright:%s,vertleft:%s"):format(vert, vert)
  -- A blank statusline in the Normal color makes the bar invisible.
  wo.statusline = " "
  wo.winhighlight =
    "StatusLine:ClaudeCodeBar,StatusLineNC:ClaudeCodeBar,WinSeparator:ClaudeCodeSeparator"
end

--- Current width (side layouts) or height (top/bottom) of the pane, to carry
--- over when switching sessions.
---@return integer?
function Chat:size()
  local win = self:windows().transcript
  if not win then
    return nil
  end
  local position = config.options.window.position
  if position == "left" or position == "right" then
    return api.nvim_win_get_width(win)
  end
  return api.nvim_win_get_height(win) + api.nvim_win_get_height(self:windows().dock or win)
end

---@param title? string
function Chat:set_title(title)
  self.title = title
  local win = self:windows().transcript
  if win then
    vim.wo[win][0].winbar = self:winbar()
  end
end

---@private
function Chat:winbar()
  local escape = function(s)
    return (s:gsub("%%", "%%%%"))
  end
  return ("%%#ClaudeCodeTitle# %s %s %%#ClaudeCodeMuted#%s"):format(
    icons.get().claude,
    escape(self.title or "New session"),
    escape(vim.fn.fnamemodify(vim.fn.getcwd(), ":~"))
  )
end

---@class claude_code.ChatShowOpts
---@field size? integer Pane size to use instead of the configured one.
---@field win? integer Take over this window instead of opening a split (`:Claude here`).
---@field restore? integer Buffer to give `win` back when the chat is hidden.

--- Open the sidebar (or focus it) with the cursor in the prompt.
---@param show_opts? claude_code.ChatShowOpts
function Chat:show(show_opts)
  show_opts = show_opts or {}
  local wins = self:windows()
  local opts = config.options.window
  if not wins.transcript then
    local vertical = opts.position == "left" or opts.position == "right"
    if show_opts.win then
      wins.transcript = show_opts.win
      api.nvim_win_set_buf(wins.transcript, self.transcript.buf)
      self.in_place = { restore = show_opts.restore }
    else
      local size = show_opts.size or opts.size
      if size < 1 then
        size = math.floor((vertical and vim.o.columns or vim.o.lines) * size)
      end
      wins.transcript = api.nvim_open_win(self.transcript.buf, false, {
        split = opts.position,
        win = -1,
        width = vertical and size or nil,
        height = not vertical and size or nil,
      })
      vim.wo[wins.transcript][0].winfixwidth = vertical
    end
    plain_window(wins.transcript)
    local wo = vim.wo[wins.transcript][0]
    wo.conceallevel, wo.concealcursor = 2, "nc"
    wo.winbar = self:winbar()
  end
  if not wins.dock then
    wins.dock = api.nvim_open_win(self.dock, false, {
      split = "below",
      win = wins.transcript,
      height = opts.prompt_height.min + 2,
    })
    plain_window(wins.dock)
    vim.wo[wins.dock].winfixheight = true
  end
  if not wins.prompt then
    self.float = api.nvim_open_win(self.prompt.buf, false, {
      relative = "win",
      win = wins.dock,
      row = 0,
      col = 0,
      width = math.max(api.nvim_win_get_width(wins.dock) - 2, 1),
      height = opts.prompt_height.min,
      border = "rounded",
      style = "minimal",
      zindex = 40,
    })
    local wo = vim.wo[self.float]
    wo.wrap, wo.linebreak = true, true
    wo.winhighlight = "NormalFloat:ClaudeCodePrompt,FloatBorder:ClaudeCodePromptBorder"
  end
  self:layout()
  self:render_welcome()
  self:focus_prompt(true)
  if vim.v.vim_did_enter == 0 then
    -- Opened during startup (`nvim +"Claude here"`): Neovim moves focus out of the
    -- floating prompt as startup finishes, so come back once it has.
    api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function()
        vim.schedule(function()
          if self:visible() then
            self:focus_prompt(true)
          end
        end)
      end,
    })
  end
  if self.opts.on_show then
    self.opts.on_show()
  end
end

--- Fit the dock and float to the prompt text and the dock's current size.
function Chat:layout()
  local wins = self:windows()
  if not (wins.dock and wins.prompt) then
    return
  end
  local height = self.prompt:height(wins.prompt)
  if api.nvim_win_get_height(wins.dock) ~= height + 2 then
    api.nvim_win_set_height(wins.dock, height + 2)
  end
  api.nvim_win_set_config(wins.prompt, {
    relative = "win",
    win = wins.dock,
    row = 0,
    col = 0,
    width = math.max(api.nvim_win_get_width(wins.dock) - 2, 1),
    height = math.min(height, math.max(api.nvim_win_get_height(wins.dock) - 2, 1)),
  })
  self.slash:refresh()
  self:render_status()
end

---@param insert boolean Start insert mode at the end of the prompt.
function Chat:focus_prompt(insert)
  local win = self:windows().prompt
  if not win then
    return
  end
  api.nvim_set_current_win(win)
  if insert then
    vim.cmd("normal! G$")
    vim.cmd("startinsert!")
    -- If this runs inside a mapping that also left insert mode (e.g. switching
    -- sessions closes one chat, then opens another), the stopinsert lands after
    -- our startinsert; re-enter once the mapping is done.
    vim.schedule(function()
      if api.nvim_get_current_win() == win and api.nvim_get_mode().mode ~= "i" then
        vim.cmd("startinsert!")
      end
    end)
  else
    vim.cmd("stopinsert")
  end
end

--- Close the prompt and the space under it, keeping the transcript's window
--- for the next session to take over (switching sessions in place).
---@return claude_code.ChatShowOpts
function Chat:detach()
  self.slash:close()
  local wins = self:windows()
  local handoff = { win = wins.transcript, restore = self.in_place and self.in_place.restore }
  self.in_place = nil
  for _, key in ipairs({ "prompt", "dock" }) do
    if wins[key] then
      pcall(api.nvim_win_close, wins[key], false)
    end
  end
  self.float = nil
  return handoff
end

---@param opts? { closing?: boolean } `closing`: one of the chat's windows was closed (e.g. `:q`).
function Chat:hide(opts)
  opts = opts or {}
  self.slash:close()
  local wins = self:windows()
  -- Closing the window you're typing in shouldn't leave you in insert mode elsewhere.
  local cur = api.nvim_get_current_win()
  if cur == wins.prompt or cur == wins.transcript or cur == wins.dock then
    vim.cmd("stopinsert")
  end
  if self.in_place and not opts.closing and wins.transcript then
    -- Give the window we took over back, rather than closing it.
    local restore = self.in_place.restore
    local handoff = self:detach()
    api.nvim_win_call(handoff.win, function()
      if restore and api.nvim_buf_is_valid(restore) then
        api.nvim_win_set_buf(0, restore)
      else
        vim.cmd("enew")
      end
    end)
    return
  end
  self.in_place = nil
  -- Any of these may already be gone, so no ipairs (it stops at the first nil).
  for _, key in ipairs({ "prompt", "dock", "transcript" }) do
    local win = wins[key]
    if win and api.nvim_win_is_valid(win) and not pcall(api.nvim_win_close, win, false) then
      -- It's the last window. After `:q` that means quit (e.g. a Neovim that was
      -- only running the chat); otherwise leave an empty window.
      api.nvim_win_call(win, function()
        if opts.closing then
          pcall(vim.cmd, "quit")
        else
          vim.cmd("enew")
        end
      end)
    end
  end
  self.float = nil
end

--- Showing in a window it took over (`:Claude here`)?
function Chat:is_in_place()
  return self.in_place ~= nil
end

function Chat:toggle()
  if self:visible() then
    self:hide()
  else
    self:show()
  end
end

---@private
function Chat:submit()
  local text = self.prompt:text()
  if text == "" then
    return
  end
  if self.opts.on_submit(text, self.prompt:attachments_in(text)) then
    require("claude-code.history").add(text, self.opts.session_id and self.opts.session_id())
    self.prompt:clear()
    self:layout()
  end
end

--- Attach an image file to the prompt.
---@param path string
function Chat:attach_image(path)
  local image, err = images.inspect(path)
  if not image then
    vim.notify("claude-code: " .. err, vim.log.levels.ERROR)
    return
  end
  self.prompt:attach(image)
end

--- Paste the clipboard's image into the prompt; with no image there, paste its text.
function Chat:paste_image()
  images.from_clipboard(function(path)
    if path then
      self:attach_image(path)
      return
    end
    local text = vim.fn.getreg("+")
    if text ~= "" then
      api.nvim_paste(text, true, -1)
    else
      vim.notify("claude-code: no image on the clipboard", vim.log.levels.WARN)
    end
  end)
end

--- (Re)install the chat's buffer-local keymaps.
function Chat:apply_keymaps()
  if not self:valid() then
    return
  end
  local keys = config.options.keymaps
  local function map(buf, mode, lhs, rhs, desc)
    if lhs then
      vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, desc = "Claude: " .. desc })
    end
  end
  local submit = function()
    self:submit()
  end
  local interrupt = function()
    self.opts.on_interrupt()
  end

  for _, lhs in ipairs(config.keys(keys.submit.n)) do
    map(self.prompt.buf, "n", lhs, submit, "send prompt")
  end
  for _, lhs in ipairs(config.keys(keys.submit.i)) do
    map(self.prompt.buf, "i", lhs, submit, "send prompt")
  end
  -- Up/Down move through the slash-command menu when it's open; otherwise they
  -- recall earlier prompts when the cursor is on the first/last line.
  for _, dir in ipairs({ { "<Up>", -1 }, { "<Down>", 1 } }) do
    map(self.prompt.buf, { "n", "i" }, dir[1], function()
      if self.slash:open() then
        self.slash:move(dir[2])
      elseif not self.prompt:recall(dir[2]) then
        api.nvim_feedkeys(api.nvim_replace_termcodes(dir[1], true, false, true), "n", false)
      end
    end, dir[2] < 0 and "previous prompt" or "next prompt")
  end
  for _, buf in ipairs({ self.prompt.buf, self.transcript.buf }) do
    map(buf, "n", keys.interrupt, interrupt, "interrupt")
  end
  map(self.transcript.buf, "n", keys.close, function()
    self:hide()
  end, "hide chat")
  for _, lhs in ipairs({ "i", "a", "I", "A", "o", "O" }) do
    map(self.transcript.buf, "n", lhs, function()
      self:focus_prompt(true)
    end, "focus prompt")
  end
  map(self.prompt.buf, "i", keys.paste_image, function()
    self:paste_image()
  end, "paste image from clipboard")
  if keys.cycle_mode and self.opts.on_cycle_mode then
    map(self.prompt.buf, { "n", "i" }, keys.cycle_mode, self.opts.on_cycle_mode, "cycle permission mode")
    map(self.transcript.buf, "n", keys.cycle_mode, self.opts.on_cycle_mode, "cycle permission mode")
  end
  for _, lhs in ipairs(keys.toggle_tool or {}) do
    map(self.transcript.buf, "n", lhs, function()
      self.transcript:toggle_tool_at(api.nvim_win_get_cursor(0)[1] - 1)
    end, "expand/collapse tool output")
  end
end

--- Redraw the prompt's border (e.g. after the hints changed).
function Chat:refresh_status()
  self:render_status()
end

--- The activity currently shown (so callers can update other fields without clearing it).
---@return string?
function Chat:activity()
  return self.status.activity
end

---@param status claude_code.ChatStatus Fields to update; `activity` is always replaced.
function Chat:set_status(status)
  local activity = status.activity
  self.status = vim.tbl_extend("force", self.status, status)
  self.status.activity = activity
  if activity and not self.timer then
    self.timer = assert(vim.uv.new_timer())
    self.timer:start(
      0,
      80,
      vim.schedule_wrap(function()
        self.frame = self.frame % #icons.get().spinner + 1
        self.transcript:tick(self.frame)
        self:render_status()
      end)
    )
  elseif not activity and self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
  self:render_status()
  if status.model then
    self:render_welcome()
  end
end

---@private
function Chat:render_welcome()
  local win = self:windows().transcript
  if win and self.transcript:empty() then
    welcome.render(self.transcript.buf, win, { model = self.status.model })
  end
end

--- Status in the prompt's border: activity on the left of the top edge, model
--- and cost on the right, key hints in the bottom edge.
---@private
function Chat:render_status()
  local win = self:windows().prompt
  if not win then
    return
  end
  local s = self.status
  local border_hl = "ClaudeCodePromptBorder"
  local left ---@type claude_code.Chunk[]
  if s.stopped and not s.activity then
    local text = s.stopped == "suspended" and " Suspended · resumes when you send " or " Not running · resumes when you send "
    left = { { text, "ClaudeCodeMuted" } }
  elseif s.attention then
    border_hl = "ClaudeCodePromptAttention"
    left = { { " " .. icons.get().permission .. " " .. s.attention .. " ", "ClaudeCodePromptAttention" } }
  elseif s.activity then
    border_hl = "ClaudeCodePromptBusy"
    left = { { (" %s %s… "):format(icons.get().spinner[self.frame], s.activity), "ClaudeCodeStatus" } }
  else
    left = { { " Ready ", "ClaudeCodeMuted" } }
  end

  local info = {}
  if s.background and s.background > 0 then
    table.insert(info, ("%s %d agent%s running"):format(icons.tool("Agent"), s.background, s.background == 1 and "" or "s"))
  end
  if s.model then
    table.insert(info, s.model)
  end
  if s.cost and s.cost > 0 then
    table.insert(info, ("$%.4f"):format(s.cost))
  end
  local right = #info > 0 and { { " " .. table.concat(info, " · ") .. " ", "ClaudeCodeMuted" } } or {}

  local width = api.nvim_win_get_width(win)
  local title = { { "─", border_hl } }
  vim.list_extend(title, left)
  local gap = width - 1 - width_of(left) - width_of(right) - 1
  if gap >= 1 then
    table.insert(title, { string.rep("─", gap), border_hl })
    vim.list_extend(title, right)
  end

  local keys = config.options.keymaps
  local hints = {}
  local submit = config.keys(keys.submit.i)[1]
  if submit then
    table.insert(hints, icons.key(submit) .. " send")
  end
  if self.prompt:has_suggestion() then
    table.insert(hints, "⇥ suggestion")
  end
  table.insert(hints, "↑↓ history")
  if keys.interrupt and s.activity then
    table.insert(hints, icons.key(keys.interrupt) .. " interrupt")
  end
  -- Bottom edge: permission mode on the left (as the CLI shows it under its
  -- input), key hints on the right.
  local right_hints = { { " " .. table.concat(hints, " · ") .. " ", "ClaudeCodeMuted" } }
  local mode_chunks = {}
  local first = self.prompt:valid() and api.nvim_buf_get_lines(self.prompt.buf, 0, 1, false)[1] or ""
  if first:sub(1, 1) == "!" then
    -- Like the CLI's bash mode indicator.
    mode_chunks = { { " ! shell command", "ClaudeCodeShellMode" }, { " (runs here, not by Claude) ", "ClaudeCodeMuted" } }
  elseif s.mode and s.mode ~= "default" then
    local label, mode_hl = require("claude-code.modes").display(s.mode)
    local cycle = keys.cycle_mode and (" (" .. icons.key(keys.cycle_mode) .. ")") or ""
    mode_chunks = { { " " .. label, mode_hl }, { cycle .. " ", "ClaudeCodeMuted" } }
  end
  local footer
  local footer_gap = width - 1 - width_of(mode_chunks) - width_of(right_hints) - 1
  if #mode_chunks > 0 and footer_gap >= 1 then
    footer = { { "─", border_hl } }
    vim.list_extend(footer, mode_chunks)
    table.insert(footer, { string.rep("─", footer_gap), border_hl })
    vim.list_extend(footer, right_hints)
  elseif #mode_chunks > 0 then
    footer = mode_chunks
  else
    footer = right_hints
  end

  api.nvim_win_set_config(win, {
    title = title,
    title_pos = "left",
    footer = footer,
    footer_pos = #mode_chunks > 0 and "left" or "right",
  })
  vim.wo[win].winhighlight = "NormalFloat:ClaudeCodePrompt,FloatBorder:" .. border_hl
end

function Chat:destroy()
  if self.timer then
    self.timer:stop()
    self.timer:close()
    self.timer = nil
  end
end

--- Close the windows and delete the buffers, for a session that's being closed.
function Chat:wipe()
  self:destroy()
  self:hide()
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  prompts[self.prompt.buf] = nil
  for _, buf in ipairs({ self.transcript.buf, self.prompt.buf, self.dock }) do
    if api.nvim_buf_is_valid(buf) then
      api.nvim_buf_delete(buf, { force = true })
    end
  end
end

return Chat
