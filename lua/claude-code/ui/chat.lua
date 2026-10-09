-- The chat sidebar. Layout, top to bottom:
--
--   transcript  a split showing the conversation
--   dock        an empty split that reserves room at the bottom...
--   prompt      ...for the floating, bordered prompt laid over it
--
-- The dock means the float never hides transcript text, and ordinary window
-- commands (resize, close, move) keep working on the splits. Above the prompt,
-- the dock also shows the running subagents and the queued messages.

local api = vim.api
local config = require("claude-code.config")
local icons = require("claude-code.ui.icons")
local Prompt = require("claude-code.ui.prompt")
local Transcript = require("claude-code.ui.transcript")
local welcome = require("claude-code.ui.welcome")
local images = require("claude-code.images")
local events = require("claude-code.events")
local worktree = require("claude-code.worktree")

local dock_ns = api.nvim_create_namespace("claude-code.dock")

--- The queue preview above the prompt: at most this many lines per message, and in all.
local QUEUE_LINES_EACH, QUEUE_LINES_MAX = 3, 8

--- The running subagents pinned above the prompt: at most this many rows of them.
local AGENT_ROWS_MAX = 5

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

--- Filetypes of the chat's split windows, which nothing else should open files in.
local CHAT_FILETYPES = { "claude-code-chat", "claude-code-dock" }

--- neo-tree opens files (and previews them) in the window you came from unless its
--- filetype is in `open_files_do_not_replace_types`. A locked chat window would
--- make that fail with E1513, and a failed preview leaves neo-tree's `eventignore`
--- behind. neo-tree rebuilds its config on the first use after every `setup()`,
--- so this runs whenever the chat shows or a neo-tree window is entered.
local function exclude_from_neo_tree()
  local neo_tree = package.loaded["neo-tree"]
  if type(neo_tree) ~= "table" then
    return
  end
  -- Apply a pending `setup()` now, so the list isn't replaced after this.
  local ok, cfg = pcall(neo_tree.ensure_config)
  cfg = ok and type(cfg) == "table" and cfg or neo_tree.config
  if type(cfg) ~= "table" then
    return
  end
  local types = cfg.open_files_do_not_replace_types or {}
  for _, ft in ipairs(CHAT_FILETYPES) do
    if not vim.tbl_contains(types, ft) then
      table.insert(types, ft)
    end
  end
  cfg.open_files_do_not_replace_types = types
end

local neo_tree_hook = false
local function install_neo_tree_hook()
  if neo_tree_hook then
    return
  end
  neo_tree_hook = true
  local group = api.nvim_create_augroup("claude-code.neo-tree-guard", { clear = true })
  api.nvim_create_autocmd("FileType", { group = group, pattern = "neo-tree", callback = exclude_from_neo_tree })
  api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
    group = group,
    callback = function()
      if vim.bo.filetype == "neo-tree" then
        exclude_from_neo_tree()
      end
    end,
  })
end

---@class claude_code.ChatStatus
---@field activity? string What Claude is doing; nil when idle.
---@field attention? string|false Waiting on the user (a permission card or question); shown in the border.
---@field model? string
---@field cost? number Session cost in USD.
---@field stopped? "suspended"|"ended"|"no_cwd"|false Not running: suspended while idle, exited, or its working directory is gone.
---@field mode? string Permission mode.
---@field background? integer Background agents still running.
---@field held? integer Messages from other sessions waiting for you to deliver them.

---@class claude_code.ChatOpts
---@field id integer
---@field on_submit fun(text: string, attachments: { label: string, image: claude_code.Image }[]): boolean Returns false to keep the prompt text.
---@field on_interrupt fun()
---@field on_send_now? fun(text: string, attachments: { label: string, image: claude_code.Image }[]): boolean Interrupt and send the queue with this text; false keeps the prompt text.
---@field on_edit_queue? fun(): boolean Pull the queue back into the prompt; false if nothing was queued.
---@field session_id? fun(): string? Claude session id, recorded with history entries.
---@field title? string
---@field cwd? string The session's working directory, shown in the winbar.
---@field on_show? fun() Called after the chat is shown (e.g. to present deferred cards).
---@field on_cycle_mode? fun() The cycle-mode key was pressed.
---@field commands? fun(): claude_code.SlashCommand[] Slash commands for completion.
---@field on_rebuild? fun(transcript: boolean) A deleted buffer was replaced (`transcript`: the transcript, now empty).

---@class claude_code.ChatTree The `wt` tree the session's working directory is in.
---@field name string
---@field slot integer
---@field branch? string Nil when detached.
---@field path string

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
---@field private queued string[] Texts of the messages queued while Claude works, shown above the prompt.
---@field private locked table<integer, integer> Chat window -> the only buffer it may show.
---@field private recovery? { visible: boolean, in_place?: { win?: integer, restore?: integer } } Rebuild scheduled.
---@field private rebuilding? boolean
---@field private closing_windows? boolean Inside hide/detach: its own window closes aren't the user closing the chat.
---@field private wiped? boolean
---@field private agent_lines table<integer, string> Dock line -> tool_use id of the running subagent shown there.
---@field private agent_range? { first: integer, last: integer } Dock lines holding subagents, if any.
---@field private tree? claude_code.ChatTree Last result of refresh_tree(), shown in the winbar.
---@field private tree_lookup? { cwd: string, again: boolean, fresh: boolean } The lookup in flight, if any, and whether another (fresh) one is due after it.
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
  local self = setmetatable(
    { opts = opts, status = {}, frame = 1, title = opts.title, queued = {}, locked = {}, agent_lines = {} },
    Chat
  )
  install_paste_hook()
  install_neo_tree_hook()

  local group = api.nvim_create_augroup(("claude-code.chat.%d"):format(opts.id), { clear = true })
  self.augroup = group
  self:create_buffers()
  -- Closing any of the three windows closes the set.
  api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if self.closing_windows then
        return -- our own hide/detach closing the rest of the set
      end
      local wins = self:windows()
      if closed and (closed == wins.transcript or closed == wins.dock or closed == wins.prompt) then
        vim.schedule(function()
          -- A deleted buffer took the window with it: recover() tidies up instead,
          -- without quitting when the chat's dock is all that's left.
          if not self.recovery then
            self:hide({ closing = true })
          end
        end)
      end
    end,
  })
  -- A tree may have been created or removed: by the plugin (which has cleared
  -- `wt list`'s cache), or from a terminal outside Neovim (so skip the cache).
  -- What Claude does is caught when its turn ends. Hidden chats too, since
  -- worktree() reports the current session's tree while the sidebar is closed;
  -- chats in the same directory share one `wt list`.
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = worktree.CHANGED,
    callback = function()
      self:refresh_tree()
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      self:refresh_tree({ fresh = true })
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
  -- The dock is a placeholder, except for the running subagents pinned in it:
  -- landing there picks one, landing anywhere else in it means "go to the prompt".
  api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      if api.nvim_get_current_buf() == self.dock then
        vim.schedule(function()
          self:settle_dock()
        end)
      end
    end,
  })
  -- The chat's windows only ever show the chat. 'winfixbuf' stops `:edit`,
  -- `:buffer` and nvim_win_set_buf; this catches whatever gets past it (code that
  -- clears the option first): the chat goes back, the other buffer opens beside it.
  api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(ev)
      local win = api.nvim_get_current_win()
      local want = self.locked[win]
      if not want or ev.buf == want then
        return
      end
      vim.schedule(function()
        if self.locked[win] ~= want or not api.nvim_win_is_valid(win) or not api.nvim_buf_is_loaded(want) then
          return
        end
        local intruder = api.nvim_win_get_buf(win)
        if intruder == want then
          return
        end
        api.nvim_set_option_value("winfixbuf", false, { scope = "local", win = win })
        api.nvim_win_set_buf(win, want)
        api.nvim_set_option_value("winfixbuf", true, { scope = "local", win = win })
        if api.nvim_buf_is_valid(intruder) then
          self:show_in_editor(intruder)
        end
      end)
    end,
  })
  -- `:bdelete` / `:bwipeout` can't be refused, so a lost buffer is rebuilt instead.
  api.nvim_create_autocmd({ "BufUnload", "BufWipeout" }, {
    group = group,
    callback = function(ev)
      if self.rebuilding or self.recovery or vim.v.exiting ~= vim.NIL then
        return
      end
      if ev.buf ~= self.transcript.buf and ev.buf ~= self.prompt.buf and ev.buf ~= self.dock then
        return
      end
      local wins = self:windows()
      self.recovery = {
        visible = wins.transcript ~= nil or wins.prompt ~= nil,
        -- By BufUnload, Neovim may have closed the transcript's window already.
        in_place = self.in_place and { win = wins.transcript, restore = self.in_place.restore },
      }
      vim.schedule(function()
        self:recover()
      end)
    end,
  })
  self:refresh_tree()
  return self
end

--- Create whichever of the chat's buffers is missing (all of them, the first time).
---@private
---@return boolean transcript The transcript is new: what it showed is gone.
function Chat:create_buffers()
  local function missing(buf)
    return not (buf and api.nvim_buf_is_valid(buf) and api.nvim_buf_is_loaded(buf))
  end
  -- An unloaded buffer is still around (and holds the name); drop it for good.
  local function discard(buf)
    if buf and api.nvim_buf_is_valid(buf) then
      pcall(api.nvim_buf_delete, buf, { force = true })
    end
  end
  local opts = self.opts
  local new_transcript = missing(self.transcript and self.transcript.buf)
  if new_transcript then
    discard(self.transcript and self.transcript.buf)
    self.transcript = Transcript.new(("claude://session/%d"):format(opts.id))
    self.transcript.on_agents = function()
      self:layout()
    end
  end
  if missing(self.prompt and self.prompt.buf) then
    if self.prompt then
      prompts[self.prompt.buf] = nil
      discard(self.prompt.buf)
      self.slash:close()
    end
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
  end
  if missing(self.dock) then
    discard(self.dock)
    self.dock = api.nvim_create_buf(false, true)
    vim.bo[self.dock].filetype = "claude-code-dock"
    vim.bo[self.dock].modifiable = false
    api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = self.dock,
      callback = function()
        self:settle_dock()
      end,
    })
    api.nvim_create_autocmd("WinLeave", {
      group = self.augroup,
      buffer = self.dock,
      callback = function()
        vim.wo.cursorline = false
      end,
    })
    -- Some focus changes skip WinEnter (e.g. Neovim leaving a float at the end of
    -- startup); starting to type in the dock is the other giveaway.
    api.nvim_create_autocmd("InsertEnter", {
      group = self.augroup,
      buffer = self.dock,
      callback = function()
        vim.schedule(function()
          self:focus_prompt(true)
        end)
      end,
    })
  end
  self:apply_keymaps()
  return new_transcript
end

--- One of the chat's buffers was deleted: make a new one, let the session refill
--- the transcript, and show the chat again where it was.
---@private
function Chat:recover()
  local state = self.recovery
  self.recovery = nil
  if not state or self.wiped then
    return
  end
  self.rebuilding = true
  -- Close what's left of the layout and release every window it had locked.
  local wins = self:windows()
  if wins.dock or wins.prompt then
    self:hide()
  end
  self:unlock(vim.tbl_keys(self.locked))
  local new_transcript = self:create_buffers()
  self.rebuilding = false
  if self.opts.on_rebuild then
    self.opts.on_rebuild(new_transcript)
  end
  if state.visible then
    local in_place = state.in_place
    local win = in_place and in_place.win
    if in_place and not (win and api.nvim_win_is_valid(win)) then
      -- Neovim closed the window we'd taken over; take over the one left instead.
      win = api.nvim_get_current_win()
      win = api.nvim_win_get_config(win).relative == "" and win or nil
    end
    self:show(win and { win = win, restore = in_place.restore } or nil)
  end
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

--- The editor window nearest the chat sidebar (not one of the chat's own, not a float).
---@return integer?
function Chat:editor_window()
  local ours = self:windows()
  local position = config.options.window.position
  local editor, best
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local is_chat = win == ours.transcript or win == ours.dock or win == ours.prompt
    local buf = api.nvim_win_get_buf(win)
    local special = vim.wo[win].winfixbuf or vim.bo[buf].buftype ~= "" or vim.bo[buf].filetype == "neo-tree"
    if not is_chat and not special and api.nvim_win_get_config(win).relative == "" then
      local row, col = unpack(api.nvim_win_get_position(win))
      local score = ({
        right = col + api.nvim_win_get_width(win),
        left = -col,
        bottom = row + api.nvim_win_get_height(win),
        top = -row,
      })[position] or col
      if not best or score > best then
        editor, best = win, score
      end
    end
  end
  return editor
end

--- Pin `win` to `buf`: nothing else can be shown in it until `unlock`.
---@private
---@param win integer
---@param buf integer
function Chat:lock(win, buf)
  self.locked[win] = buf
  api.nvim_set_option_value("winfixbuf", true, { scope = "local", win = win })
end

--- Release the chat's windows in this tab, before closing them or handing one back.
---@private
---@param wins { transcript?: integer, dock?: integer, prompt?: integer }
function Chat:unlock(wins)
  for _, win in pairs(wins) do
    self.locked[win] = nil
    if api.nvim_win_is_valid(win) then
      api.nvim_set_option_value("winfixbuf", false, { scope = "local", win = win })
    end
  end
end

--- Show `buf` next to the chat: in the editor window beside it if there is one,
--- otherwise in a new split. Focuses it.
---@param buf integer
---@return integer win
function Chat:show_in_editor(buf)
  local win = self:editor_window()
  if win then
    api.nvim_win_set_buf(win, buf)
    api.nvim_set_current_win(win)
  else
    -- Only the chat is open: make room beside it.
    local position = config.options.window.position
    win = api.nvim_open_win(buf, true, { split = position == "left" and "right" or "left", win = -1 })
  end
  return win
end

--- Open the link under the cursor in the transcript: URLs with the system handler
--- (`vim.ui.open`), files and directories in the editor window beside the chat.
--- Inside a mermaid code block, the diagram opens in the browser instead.
---@param opts? { quiet?: boolean } Say nothing when there's no link under the cursor.
---@return boolean opened
function Chat:open_link(opts)
  local links = require("claude-code.ui.links")
  local mermaid = require("claude-code.ui.mermaid")
  local win = api.nvim_get_current_win()
  local row, col = unpack(api.nvim_win_get_cursor(win))
  local diagram = mermaid.at(self.transcript.buf, row - 1, col)
  if diagram then
    mermaid.open(diagram)
    return true
  end
  local target, explicit = links.at(self.transcript.buf, row - 1, col)
  local file = target and links.file(target, self.opts.cwd or vim.fn.getcwd())
  local url = target and not file and explicit and links.url(target)
  if file then
    local buf = vim.fn.bufadd(file.path)
    vim.bo[buf].buflisted = true
    local editor = self:show_in_editor(buf)
    if file.line then
      local last = api.nvim_buf_line_count(buf)
      pcall(api.nvim_win_set_cursor, editor, { math.min(file.line, last), math.max((file.col or 1) - 1, 0) })
      vim.cmd("normal! zz")
    end
    return true
  elseif url then
    local _, err = vim.ui.open(url)
    if err then
      vim.notify("claude-code: " .. err, vim.log.levels.ERROR)
    end
    return true
  end
  if not (opts and opts.quiet) then
    local msg = explicit and ("no such file: " .. target) or "no link under the cursor"
    vim.notify("claude-code: " .. msg, vim.log.levels.WARN)
  end
  return false
end

--- Open the link that was just clicked in the transcript (for a mouse mapping). The cursor
--- moves to the click either way, as a plain click would put it.
function Chat:click_link()
  local win = self:windows().transcript
  if not win or vim.fn.getmousepos().winid ~= win then
    return
  end
  -- Replay it as a plain click so Neovim positions the cursor: that accounts for
  -- concealed text (link destinations), which getmousepos()'s column doesn't.
  api.nvim_feedkeys(api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "nx", false)
  if api.nvim_get_current_win() == win then
    vim.cmd("stopinsert")
    self:open_link({ quiet = true })
  end
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
  events.sessions_changed()
  self:redraw_winbar()
end

--- The session moved to another working directory.
---@param cwd string
function Chat:set_cwd(cwd)
  self.opts.cwd = cwd
  self:redraw_winbar()
  self:refresh_tree()
end

--- The `wt` tree the session's working directory is in, as last looked up, or
--- nil (not in a tree, not looked up yet, or the integration is off). Never
--- runs `wt`.
---@return claude_code.ChatTree?
function Chat:worktree()
  return self.tree and vim.deepcopy(self.tree)
end

--- Look up, in the background, which `wt` tree the session's working directory
--- is in, and redraw the winbar if that changed. Rendering only reads the stored
--- result, so it never waits on `wt`. Without the integration, runs nothing.
---@param opts? claude_code.WtListOpts `fresh`: something outside the plugin may have changed the trees, so skip `wt list`'s cache.
function Chat:refresh_tree(opts)
  if self.wiped then
    return
  end
  if not worktree.enabled() then
    self:set_tree(nil) -- turned off since the last lookup
    return
  end
  local fresh = opts and opts.fresh or false
  if self.tree_lookup then
    -- One lookup at a time, plus one more if this one may be out of date.
    self.tree_lookup.again = true
    self.tree_lookup.fresh = self.tree_lookup.fresh or fresh
    return
  end
  local cwd = self.opts.cwd or vim.fn.getcwd()
  self.tree_lookup = { cwd = cwd, again = false, fresh = false }
  worktree.tree_for(cwd, function(entry)
    local lookup = self.tree_lookup
    self.tree_lookup = nil
    if self.wiped then
      return
    end
    -- The session moved, or something changed, while it ran: look again.
    if lookup and (lookup.again or lookup.cwd ~= (self.opts.cwd or vim.fn.getcwd())) then
      self:refresh_tree({ fresh = lookup.fresh })
      return
    end
    self:set_tree(entry and { name = entry.name, slot = entry.slot, branch = entry.branch, path = entry.path })
  end, { fresh = fresh })
end

---@private
---@param tree? claude_code.ChatTree
function Chat:set_tree(tree)
  if vim.deep_equal(tree, self.tree) then
    return
  end
  self.tree = tree
  self:redraw_winbar()
  -- Statuslines showing require("claude-code").worktree() redraw on this.
  events.sessions_changed()
end

---@private
function Chat:redraw_winbar()
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
  local tree = ""
  if self.tree then
    -- Before the directory, which is truncated first (`%<`) when space runs out.
    tree = ("%%#ClaudeCodeWorktree#%s %s · slot %s %%<"):format(
      icons.get().worktree,
      escape(tostring(self.tree.name)),
      tostring(self.tree.slot)
    )
  end
  return ("%%#ClaudeCodeTitle# %s %s %s%%#ClaudeCodeMuted#%s"):format(
    icons.get().claude,
    escape(self.title or "New session"),
    tree,
    escape(vim.fn.fnamemodify(self.opts.cwd or vim.fn.getcwd(), ":~"))
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
    -- The tree may have changed while the chat was hidden.
    self:refresh_tree()
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
  self:lock(wins.transcript, self.transcript.buf)
  self:lock(wins.dock, self.dock)
  self:lock(self.float, self.prompt.buf)
  exclude_from_neo_tree()
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

--- The messages queued while Claude works changed.
---@param items { text: string }[]
function Chat:set_queue(items)
  self.queued = vim.tbl_map(function(item)
    return item.text
  end, items)
  self:layout()
end

--- Queued messages coming back for editing: into the prompt, ahead of what's there.
---@param items { text: string, attachments: { label: string, image: claude_code.Image }[] }[]
function Chat:restore_queue(items)
  self.prompt:restore(items)
  self:layout()
end

--- Lines previewing the queue (as the CLI shows queued messages above its input), each
--- a list of chunks, wrapped to `width`.
---@private
---@param width integer
---@return claude_code.Chunk[][]
function Chat:queue_rows(width)
  if #self.queued == 0 then
    return {}
  end
  local keys = config.options.keymaps
  local hints = { "↑ edit" }
  local send_now = config.keys(keys.send_now)[1]
  if send_now then
    table.insert(hints, icons.key(send_now) .. " send now")
  end
  local rows = {
    {
      { " Queued", "ClaudeCodeQueuedTitle" },
      { (" · %s"):format(table.concat(hints, " · ")), "ClaudeCodeMuted" },
    },
  }
  local card = require("claude-code.ui.card")
  local body, hidden = {}, 0
  for _, text in ipairs(self.queued) do
    local lines = card.wrap(text, math.max(width - 4, 10))
    for i, line in ipairs(lines) do
      if #body >= QUEUE_LINES_MAX then
        hidden = hidden + (#lines - i + 1)
        break
      elseif i > QUEUE_LINES_EACH then
        table.insert(body, { { "   …", "ClaudeCodeQueued" } })
        break
      end
      table.insert(body, { { (i == 1 and " › " or "   ") .. line, "ClaudeCodeQueued" } })
    end
  end
  if hidden > 0 then
    -- The last line shown makes way for the count, so it's one of the hidden ones.
    hidden = hidden + 1
    body[#body] = { { ("   … %d more line%s"):format(hidden, hidden == 1 and "" or "s"), "ClaudeCodeQueued" } }
  end
  return vim.list_extend(rows, body)
end

--- Cut a row of chunks down to `width` display columns, ending it with "…" if it was longer.
---@param row claude_code.Chunk[]
---@param width integer
---@return claude_code.Chunk[]
local function fit(row, width)
  local out, used = {}, 0
  for _, chunk in ipairs(row) do
    -- A buffer line can't hold a newline, and a description or activity may carry one.
    chunk = { (chunk[1]:gsub("%s*[\r\n]+%s*", " ")), chunk[2] }
    local w = vim.fn.strdisplaywidth(chunk[1])
    if used + w > width then
      local room = math.max(width - used - 1, 0)
      local text = ""
      for i = 1, vim.fn.strchars(chunk[1]) do
        local next = vim.fn.strcharpart(chunk[1], 0, i)
        if vim.fn.strdisplaywidth(next) > room then
          break
        end
        text = next
      end
      table.insert(out, { text .. "…", chunk[2] })
      return out
    end
    table.insert(out, chunk)
    used = used + w
  end
  return out
end

--- Lines pinning the running subagents above the prompt, so what they're doing
--- stays in sight however far the transcript has moved on. Also returns, for
--- each row that is a subagent, its tool_use id.
---@private
---@param width integer
---@return claude_code.Chunk[][] rows
---@return table<integer, string> ids Row index -> tool_use id.
function Chat:agent_rows(width)
  local running = self.transcript:running_agents()
  if #running == 0 then
    return {}, {}
  end
  local tools = require("claude-code.ui.tools")
  local jump = config.keys(config.options.keymaps.toggle_tool)[1]
  local hint = jump and (" · ^W k, %s to show"):format(icons.key(jump)) or ""
  local rows = { { { " Agents", "ClaudeCodeAgentsTitle" }, { hint, "ClaudeCodeMuted" } } }
  local ids = {}
  local shown = #running > AGENT_ROWS_MAX and AGENT_ROWS_MAX - 1 or #running
  for i = 1, shown do
    local sub = running[i].sub
    local label = sub.description or sub.kind or "subagent"
    if sub.background then
      label = label .. " (background)"
    end
    local row = {
      { " ● ", "ClaudeCodeToolPending" },
      { label, "ClaudeCodeAgentsName" },
      { " · " .. tools.subagent_activity(sub), "ClaudeCodeMuted" },
    }
    table.insert(rows, fit(row, width))
    ids[#rows] = running[i].id
  end
  if shown < #running then
    table.insert(rows, { { ("   … %d more"):format(#running - shown), "ClaudeCodeMuted" } })
  end
  return rows, ids
end

--- Write the pinned subagents and the queue preview into the dock, above where
--- the prompt floats.
---@private
---@param rows claude_code.Chunk[][]
function Chat:render_dock(rows)
  if not api.nvim_buf_is_valid(self.dock) then
    return
  end
  local lines = vim.tbl_map(function(row)
    return table.concat(vim.tbl_map(function(chunk)
      return chunk[1]
    end, row))
  end, rows)
  vim.bo[self.dock].modifiable = true
  api.nvim_buf_set_lines(self.dock, 0, -1, false, lines)
  vim.bo[self.dock].modifiable = false
  api.nvim_buf_clear_namespace(self.dock, dock_ns, 0, -1)
  for i, row in ipairs(rows) do
    local col = 0
    for _, chunk in ipairs(row) do
      api.nvim_buf_set_extmark(self.dock, dock_ns, i - 1, col, { end_col = col + #chunk[1], hl_group = chunk[2] })
      col = col + #chunk[1]
    end
  end
end

--- With the cursor in the dock: keep it on a pinned subagent, or send it on to the
--- prompt when there's none there (or it moved past them).
---@private
function Chat:settle_dock()
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= self.dock then
    return
  end
  local range = self.agent_range
  local row = api.nvim_win_get_cursor(win)[1]
  if not range or row > range.last + 1 then
    self:focus_prompt(false)
    return
  end
  vim.wo[win].cursorline = true
  local clamped = math.min(math.max(row, range.first), range.last)
  if clamped ~= row then
    api.nvim_win_set_cursor(win, { clamped, 0 })
  end
end

--- Jump to the Agent call of the subagent under the cursor in the dock, expanded.
---@private
function Chat:show_agent_at_cursor()
  local id = self.agent_lines[api.nvim_win_get_cursor(0)[1]]
  local win = self:windows().transcript
  local row = id and win and self.transcript:expand_tool(id)
  if not row then
    return
  end
  api.nvim_set_current_win(win)
  api.nvim_win_set_cursor(win, { row + 1, 0 })
  vim.cmd("normal! zt")
end

--- Fit the dock and float to the prompt text, the pinned subagents, the queue, and
--- the dock's current size.
function Chat:layout()
  local wins = self:windows()
  if not (wins.dock and wins.prompt) then
    return
  end
  local width = api.nvim_win_get_width(wins.dock)
  local rows, ids = self:agent_rows(width)
  self.agent_lines = ids
  local first, last = math.huge, 0
  for line in pairs(ids) do
    first, last = math.min(first, line), math.max(last, line)
  end
  self.agent_range = last > 0 and { first = first, last = last } or nil
  vim.list_extend(rows, self:queue_rows(width))
  self:render_dock(rows)
  local height = self.prompt:height(wins.prompt)
  if api.nvim_win_get_height(wins.dock) ~= #rows + height + 2 then
    api.nvim_win_set_height(wins.dock, #rows + height + 2)
  end
  local dock_height = api.nvim_win_get_height(wins.dock)
  -- If the editor is too short for all of it, the prompt wins over the preview.
  local offset = math.max(math.min(#rows, dock_height - height - 2), 0)
  api.nvim_win_call(wins.dock, function()
    vim.fn.winrestview({ topline = 1 })
  end)
  if api.nvim_get_current_win() == wins.dock then
    -- The subagents under the cursor may have finished.
    self:settle_dock()
  end
  api.nvim_win_set_config(wins.prompt, {
    relative = "win",
    win = wins.dock,
    row = offset,
    col = 0,
    width = math.max(api.nvim_win_get_width(wins.dock) - 2, 1),
    height = math.min(height, math.max(dock_height - offset - 2, 1)),
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
  self:unlock(wins)
  local handoff = { win = wins.transcript, restore = self.in_place and self.in_place.restore }
  self.in_place = nil
  self.closing_windows = true
  for _, key in ipairs({ "prompt", "dock" }) do
    if wins[key] then
      pcall(api.nvim_win_close, wins[key], false)
    end
  end
  self.closing_windows = false
  self.float = nil
  return handoff
end

---@param opts? { closing?: boolean } `closing`: one of the chat's windows was closed (e.g. `:q`).
function Chat:hide(opts)
  opts = opts or {}
  self.slash:close()
  local wins = self:windows()
  self:unlock(wins)
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
  self.closing_windows = true
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
          -- Not `:enew`: in the dock's window it would reuse the (empty, unnamed) dock.
          api.nvim_win_set_buf(0, api.nvim_create_buf(true, false))
        end
      end)
    end
  end
  self.closing_windows = false
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

--- Interrupt Claude and send the queue, with whatever is in the prompt, right away.
function Chat:send_now()
  if not self.opts.on_send_now then
    return
  end
  local text = self.prompt:text()
  if self.opts.on_send_now(text, self.prompt:attachments_in(text)) and text ~= "" then
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
      local on_first_line = api.nvim_win_get_cursor(0)[1] == 1
      if self.slash:open() then
        self.slash:move(dir[2])
      elseif
        dir[2] < 0
        and on_first_line
        and not self.prompt:browsing()
        and self.opts.on_edit_queue
        and self.opts.on_edit_queue()
      then
        -- Pulled the queue back into the prompt to edit, as the CLI's ↑ does.
        return
      elseif not self.prompt:recall(dir[2]) then
        api.nvim_feedkeys(api.nvim_replace_termcodes(dir[1], true, false, true), "n", false)
      end
    end, dir[2] < 0 and "previous prompt" or "next prompt")
  end
  for _, buf in ipairs({ self.prompt.buf, self.transcript.buf }) do
    map(buf, "n", keys.interrupt, interrupt, "interrupt")
  end
  for _, lhs in ipairs(config.keys(keys.send_now)) do
    map(self.prompt.buf, { "n", "i" }, lhs, function()
      self:send_now()
    end, "interrupt and send the queue now")
  end
  map(self.transcript.buf, "n", keys.close, function()
    self:hide()
  end, "hide chat")
  for _, lhs in ipairs({ "i", "a", "I", "A", "o", "O" }) do
    for _, buf in ipairs({ self.transcript.buf, self.dock }) do
      map(buf, "n", lhs, function()
        self:focus_prompt(true)
      end, "focus prompt")
    end
  end
  map(self.dock, "n", keys.interrupt, interrupt, "interrupt")
  map(self.dock, "n", keys.close, function()
    self:hide()
  end, "hide chat")
  for _, lhs in ipairs(config.keys(keys.toggle_tool)) do
    map(self.dock, "n", lhs, function()
      self:show_agent_at_cursor()
    end, "show this agent in the transcript")
  end
  -- Moving off the ends of the pinned agents: down to the prompt, up to the transcript.
  for _, move in ipairs({ { "j", 1 }, { "<Down>", 1 }, { "k", -1 }, { "<Up>", -1 } }) do
    map(self.dock, "n", move[1], function()
      local range, row = self.agent_range, api.nvim_win_get_cursor(0)[1]
      local wins = self:windows()
      if range and move[2] > 0 and row < range.last then
        api.nvim_win_set_cursor(0, { row + 1, 0 })
      elseif range and move[2] < 0 and row > range.first then
        api.nvim_win_set_cursor(0, { row - 1, 0 })
      elseif move[2] > 0 then
        self:focus_prompt(false)
      elseif wins.transcript then
        api.nvim_set_current_win(wins.transcript)
      end
    end, move[2] > 0 and "next agent, or the prompt" or "previous agent, or the transcript")
  end
  -- A float's neighbours go by screen position, so from the prompt <C-w>k can land
  -- in the editor beside the chat; go to what's above it here instead.
  for _, lhs in ipairs({ "<C-w>k", "<C-w><C-k>", "<C-w><Up>" }) do
    map(self.prompt.buf, "n", lhs, function()
      local wins = self:windows()
      if self.agent_range and wins.dock then
        api.nvim_set_current_win(wins.dock)
        api.nvim_win_set_cursor(wins.dock, { self.agent_range.first, 0 })
      elseif wins.transcript then
        api.nvim_set_current_win(wins.transcript)
      end
    end, "go to the agents above the prompt, or the transcript")
  end
  map(self.prompt.buf, "i", keys.paste_image, function()
    self:paste_image()
  end, "paste image from clipboard")
  if keys.cycle_mode and self.opts.on_cycle_mode then
    map(self.prompt.buf, { "n", "i" }, keys.cycle_mode, self.opts.on_cycle_mode, "cycle permission mode")
    map(self.transcript.buf, "n", keys.cycle_mode, self.opts.on_cycle_mode, "cycle permission mode")
  end
  for _, lhs in ipairs(config.keys(keys.toggle_tool)) do
    map(self.transcript.buf, "n", lhs, function()
      -- Off a tool call, the same key follows a link under the cursor.
      if not self.transcript:toggle_tool_at(api.nvim_win_get_cursor(0)[1] - 1) then
        self:open_link({ quiet = true })
      end
    end, "expand/collapse tool output or open link")
  end
  for _, lhs in ipairs(config.keys(keys.open_link)) do
    map(self.transcript.buf, "n", lhs, function()
      self:open_link()
    end, "open link")
  end
  -- The transcript's window can't show a file, so `gf` opens it beside the chat.
  map(self.transcript.buf, "n", "gf", function()
    self:open_link()
  end, "open file under cursor")
  -- Mappings belong to the buffer with the cursor, not the one clicked, so the
  -- click is also mapped in the prompt (where the cursor usually is).
  local click = function()
    self:click_link()
  end
  for _, lhs in ipairs(config.keys(keys.click_link)) do
    map(self.transcript.buf, "n", lhs, click, "open clicked link")
    map(self.prompt.buf, { "n", "i" }, lhs, click, "open clicked link")
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
  -- Starting and Loading end without a turn having run, so nothing can have changed the trees.
  local previous = self.status.activity
  local was_busy = previous ~= nil and previous ~= "Starting" and previous ~= "Loading"
  local was_stopped = self.status.stopped
  self.status = vim.tbl_extend("force", self.status, status)
  self.status.activity = activity
  events.sessions_changed()
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
  -- (Re)started, or a turn or `!command` just ended, which may have created or
  -- removed a tree without the plugin knowing: look the session's tree up again.
  if was_busy and not activity then
    self:refresh_tree({ fresh = true })
  elseif status.stopped == false and was_stopped ~= false then
    self:refresh_tree()
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
    if s.stopped == "no_cwd" then
      left = { { " Working directory is gone · :Claude relocate ", "DiagnosticWarn" } }
    else
      local text = s.stopped == "suspended" and " Suspended · resumes when you send "
        or " Not running · resumes when you send "
      left = { { text, "ClaudeCodeMuted" } }
    end
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
  if #self.queued > 0 then
    table.insert(info, ("%d queued"):format(#self.queued))
  end
  if s.held and s.held > 0 then
    table.insert(info, ("%s %d waiting"):format(icons.get().message, s.held))
  end
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
  local send_now = config.keys(keys.send_now)[1]
  if send_now and s.activity and (#self.queued > 0 or not self.prompt:empty()) then
    table.insert(hints, icons.key(send_now) .. " send now")
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
  self.wiped = true
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
