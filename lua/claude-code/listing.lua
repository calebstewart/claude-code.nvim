-- Sessions as the picker and the neo-tree source list them: stored sessions
-- merged with the ones open in this Neovim, plus the actions both views offer
-- on a row (open, rename, delete, new). The views own their prompts; these
-- only act.

local api = vim.api
local control = require("claude-code.control")
local events = require("claude-code.events")
local icons = require("claude-code.ui.icons")
local sessions = require("claude-code.sessions")

local M = {}

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

---@param seconds integer
---@return string
function M.ago(seconds)
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

--- Status glyph and highlight for a row.
---@param entry claude_code.SessionEntry
---@return string glyph, string hl, string label
function M.status(entry)
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

--- Stored sessions plus the open ones `include_live` accepts (including new
--- sessions not written to disk yet), newest first.
---@param stored table[] SDKSessionInfo[]
---@param include_live fun(session: claude_code.Session): boolean
---@return claude_code.SessionEntry[]
function M.merge(stored, include_live)
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
  for _, s in ipairs(sessions.live()) do
    local entry = by_id[s.id]
    if not entry and include_live(s) then
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

--- An empty, unnamed, unmodified window a chat can take over.
---@param win integer
local function blank(win)
  local buf = api.nvim_win_get_buf(win)
  return api.nvim_win_get_config(win).relative == ""
    and vim.bo[buf].buftype == ""
    and api.nvim_buf_get_name(buf) == ""
    and not vim.bo[buf].modified
    and api.nvim_buf_line_count(buf) == 1
    and (api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "") == ""
end

--- Where a session opened from a list should show: wherever the chat already
--- is (in place or the sidebar), else in `win` if it's empty, else the sidebar.
---@param win? integer
---@return { here?: boolean }
local function placement(win)
  local current = sessions.current()
  if current and current.chat:visible() then
    return {}
  end
  if win and api.nvim_win_is_valid(win) and blank(win) then
    api.nvim_set_current_win(win)
    return { here = true }
  end
  return {}
end

--- Switch to, or resume, a session.
---@param entry claude_code.SessionEntry
---@param opts? { win?: integer } Window to open in when it's empty and no chat is showing.
function M.open(entry, opts)
  local show_opts = placement(opts and opts.win)
  if entry.live then
    sessions.show(entry.live, show_opts)
  else
    sessions.open(entry.info, show_opts)
  end
end

--- Start a session and show it.
---@param title? string
---@param opts? { win?: integer, cwd?: string } `cwd`: run it there instead of Neovim's cwd.
function M.new(title, opts)
  opts = opts or {}
  sessions.new(title, { cwd = opts.cwd, show = placement(opts.win) })
end

--- Set a session's title.
---@param entry claude_code.SessionEntry
---@param title string
---@param done? fun(err?: string)
function M.rename(entry, title, done)
  done = done or function() end
  if entry.live then
    entry.live:rename(title)
    done()
    return
  end
  control.request("rename_session", { session_id = entry.id, title = title, dir = entry.cwd }, function(err)
    if err then
      vim.notify("claude-code: rename failed: " .. err, vim.log.levels.ERROR)
    end
    events.sessions_changed()
    done(err)
  end)
end

--- Why `entry` can't be deleted, if it can't: a session open in another Claude
--- Code process would just have its transcript written back.
---@param entry claude_code.SessionEntry
---@return string?
function M.delete_blocker(entry)
  if entry.elsewhere then
    return ("this session is open in another Claude Code process (pid %d); close it there first"):format(
      entry.elsewhere
    )
  end
end

--- Run `fn` once `session`'s process has exited (it may flush one last entry
--- to the transcript on the way out), or after a few seconds regardless.
---@param session claude_code.Session
---@param fn fun()
local function when_stopped(session, fn)
  local deadline = vim.uv.now() + 5000
  local function check()
    if not session:running() or vim.uv.now() > deadline then
      fn()
    else
      vim.defer_fn(check, 50)
    end
  end
  check()
end

--- Delete a session: close it if it's open here, then remove its transcript.
--- Check `delete_blocker` (and ask) first.
---@param entry claude_code.SessionEntry
---@param done? fun(err?: string)
function M.delete(entry, done)
  done = done or function() end
  local function remove()
    control.request("delete_session", { session_id = entry.id, dir = entry.cwd }, function(err)
      -- A session open here but not in a stored list may never have been written.
      if err and (entry.info or not err:match("not found")) then
        vim.notify("claude-code: delete failed: " .. err, vim.log.levels.ERROR)
      else
        err = nil
      end
      events.sessions_changed()
      done(err)
    end)
  end
  if entry.live then
    local session = entry.live
    sessions.close(session)
    when_stopped(session, remove)
  else
    remove()
  end
end

return M
