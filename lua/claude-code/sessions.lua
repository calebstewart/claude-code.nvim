-- The sessions open in this Neovim, and which one the sidebar shows.
--
-- Background sessions keep running (and streaming into their hidden
-- transcripts). Once idle for `sessions.idle_timeout` minutes their process is
-- stopped; switching back (or sending) resumes it.

local Session = require("claude-code.session")
local config = require("claude-code.config")
local events = require("claude-code.events")

local M = {}

---@type claude_code.Session[] Most recently opened last.
local live = {}
---@type claude_code.Session?
local current
---@type uv.uv_timer_t?
local reaper

---@return claude_code.Session?
function M.current()
  if current and not current.chat:valid() then
    M.close(current)
  end
  return current
end

---@return claude_code.Session[]
function M.live()
  return live
end

---@param id string
---@return claude_code.Session?
function M.find(id)
  for _, s in ipairs(live) do
    if s.id == id then
      return s
    end
  end
end

local function start_reaper()
  if reaper then
    return
  end
  reaper = assert(vim.uv.new_timer())
  reaper:start(60000, 60000, vim.schedule_wrap(function()
    local timeout = config.options.sessions.idle_timeout
    if not timeout then
      return
    end
    for _, s in ipairs(live) do
      local hidden = s ~= current or not s.chat:visible()
      if hidden and s:running() and not s.busy and os.time() - s.last_active >= timeout * 60 then
        s:suspend() -- no-op while it's waiting on you
      end
    end
  end))
end

---@param session claude_code.Session
local function add(session)
  table.insert(live, session)
  start_reaper()
  events.sessions_changed()
end

--- Show `session` in the sidebar, in place of whichever session is there.
---@param session claude_code.Session
---@param opts? { here?: boolean } `here`: take over the current window instead of a sidebar.
function M.show(session, opts)
  local previous = current
  local show_opts = {}
  if current and current ~= session and current.chat:visible() then
    if current.chat:is_in_place() then
      show_opts = current.chat:detach() -- the next session takes over the same window
    else
      show_opts.size = current.chat:size()
      current.chat:hide()
    end
  elseif opts and opts.here and not session.chat:visible() then
    local win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_config(win).relative == "" then
      show_opts = { win = win, restore = vim.api.nvim_win_get_buf(win) }
    end
  end
  current = session
  session.last_active = os.time()
  session:ensure_running()
  session.chat:show(show_opts)
  -- An untouched new session is only a placeholder: leaving it discards it.
  if previous and previous ~= session and previous:is_placeholder() then
    M.close(previous)
  end
end

--- Track a session created elsewhere (e.g. `:Claude here`), without showing it.
---@param session claude_code.Session
function M.adopt(session)
  add(session)
end

--- Start a new session and show it.
---@param title? string
---@param opts? { cwd?: string, show?: { here?: boolean } } `cwd`: run it there instead of Neovim's cwd.
---@return claude_code.Session?
function M.new(title, opts)
  opts = opts or {}
  local session = Session.new({ title = title ~= "" and title or nil, cwd = opts.cwd })
  if session then
    add(session)
    M.show(session, opts.show)
  end
  return session
end

--- Sessions open in other Claude Code processes: session id -> pid.
--- Best effort: reads the CLI's registry of running processes
--- (~/.claude/sessions/<pid>.json) and keeps the ones whose pid is alive.
---@return table<string, integer>
function M.open_elsewhere()
  local open = {}
  local dir = vim.fs.joinpath(vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME, ".claude"), "sessions")
  if not vim.uv.fs_stat(dir) then
    return open
  end
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("^%d+%.json$") then
      local f = io.open(vim.fs.joinpath(dir, name), "r")
      if f then
        local ok, entry = pcall(vim.json.decode, f:read("*a"))
        f:close()
        local pid = ok and type(entry) == "table" and tonumber(entry.pid)
        if pid and type(entry.sessionId) == "string" and vim.uv.kill(pid, 0) == 0 then
          open[entry.sessionId] = pid
        end
      end
    end
  end
  -- Our own sessions' processes register there too.
  for _, s in ipairs(live) do
    open[s.id] = nil
  end
  return open
end

--- Open a stored session (SDKSessionInfo), or switch to it if it's already open.
---@param info table
---@param show_opts? { here?: boolean }
function M.open(info, show_opts)
  local existing = M.find(info.sessionId)
  if existing then
    M.show(existing, show_opts)
    return
  end
  local pid = M.open_elsewhere()[info.sessionId]
  if pid then
    vim.notify(
      ("claude-code: this session is also open in another Claude Code process (pid %d); both will write to it"):format(pid),
      vim.log.levels.WARN
    )
  end
  local session = Session.new({ info = info })
  if session then
    add(session)
    M.show(session, show_opts)
  end
end

--- The session to use for "open the chat": the current one, or a new one.
---@return claude_code.Session?
function M.current_or_new()
  return M.current() or M.new()
end

--- End a session and remove it from Neovim (its transcript stays on disk).
---@param session claude_code.Session
function M.close(session)
  session:stop()
  session.chat:wipe()
  for i, s in ipairs(live) do
    if s == session then
      table.remove(live, i)
      break
    end
  end
  if current == session then
    current = nil
  end
  events.sessions_changed()
end

--- Nothing but empty scratch space is open: one tab, and only unnamed, unmodified,
--- empty buffers (the chat's own buffers are unlisted, so they don't count).
local function nothing_else_open()
  if #vim.api.nvim_list_tabpages() > 1 then
    return false
  end
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if info.name ~= "" or info.changed == 1 or info.linecount > 1 then
      return false
    end
    if (vim.api.nvim_buf_get_lines(info.bufnr, 0, 1, false)[1] or "") ~= "" then
      return false
    end
  end
  -- Unlisted buffers still on screen (help, terminals, other plugins' windows) count too.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_win_get_config(win).relative == "" and not vim.bo[buf].buflisted then
      return false
    end
  end
  return true
end

--- `/exit`: end `session`, as exiting the CLI would. When Neovim was only being
--- used for Claude, move on to another open session, or quit if there's none.
---@param session claude_code.Session
function M.exit(session)
  local in_place = session.chat:is_in_place()
  M.close(session)
  if not nothing_else_open() then
    return
  end
  local next_session
  for _, s in ipairs(live) do
    if not next_session or s.last_active > next_session.last_active then
      next_session = s
    end
  end
  if next_session then
    M.show(next_session, { here = in_place })
  else
    pcall(vim.cmd, "qall")
  end
end

--- Switch to the next/previous live session.
---@param delta 1|-1
function M.cycle(delta)
  if #live == 0 then
    return
  end
  local index = 0
  for i, s in ipairs(live) do
    if s == current then
      index = i
    end
  end
  M.show(live[(index - 1 + delta) % #live + 1])
end

return M
