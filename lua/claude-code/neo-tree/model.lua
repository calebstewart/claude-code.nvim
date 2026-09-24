-- What the neo-tree source shows: projects, and each expanded project's
-- sessions, cached here and shared by every tab's tree. Projects load once; a
-- project's sessions load when it's first expanded, a page at a time.
--
-- The cache is marked stale when a transcript changes on disk (a session run
-- from the CLI, say); the next render uses what's cached and reloads behind it.

local control = require("claude-code.control")

local M = {}

--- Sessions listed per project before a "Show more" row.
M.PAGE = 50

---@class claude_code.tree.Project
---@field cwd string
---@field sessions integer Transcripts on disk (an upper bound: untitled ones aren't listed).
---@field lastModified integer

---@type claude_code.tree.Project[]?
M.projects = nil
---@type table<string, table[]> cwd -> SDKSessionInfo[], for projects that have been expanded
M.sessions = {}
---@type table<string, integer> cwd -> sessions to list
M.limits = {}
---@type table<string, boolean> cwd -> sessions are being fetched
M.loading = {}
M.loading_projects = false
M.stale = false

---@type fun()?
local on_change

--- Called whenever the cache changes or goes stale, to redraw.
---@param fn fun()
function M.on_change(fn)
  on_change = fn
end

local function changed()
  if on_change then
    on_change()
  end
end

---@param cwd string
---@param callback? fun()
function M.load_sessions(cwd, callback)
  M.loading[cwd] = true
  control.request(
    "list_sessions",
    { dir = cwd, limit = M.limits[cwd] or M.PAGE, include_worktrees = false },
    function(err, result)
      M.loading[cwd] = nil
      if err then
        vim.notify("claude-code: couldn't list sessions: " .. err, vim.log.levels.ERROR)
      end
      M.sessions[cwd] = result or M.sessions[cwd] or {}
      M.watch_project(cwd)
      if callback then
        callback()
      end
      changed()
    end
  )
end

--- List one more page of a project's sessions.
---@param cwd string
function M.more(cwd)
  M.limits[cwd] = (M.limits[cwd] or M.PAGE) + M.PAGE
  M.load_sessions(cwd)
end

--- Reload the project list and every expanded project's sessions.
---@param callback? fun()
function M.reload(callback)
  M.stale = false
  M.loading_projects = true
  control.request("list_projects", {}, function(err, result)
    M.loading_projects = false
    if err then
      vim.notify("claude-code: couldn't list projects: " .. err, vim.log.levels.ERROR)
    end
    M.projects = result or M.projects or {}
    local pending = 1
    local function done()
      pending = pending - 1
      if pending == 0 and callback then
        callback()
      end
    end
    for cwd in pairs(M.sessions) do
      pending = pending + 1
      M.load_sessions(cwd, done)
    end
    done()
    changed()
  end)
end

--- Forget a session straight away (it's being deleted), ahead of the reload.
---@param id string
function M.forget(id)
  for cwd, list in pairs(M.sessions) do
    M.sessions[cwd] = vim.tbl_filter(function(info)
      return info.sessionId ~= id
    end, list)
  end
end

-- Watching: the projects directory (new projects) and each expanded project's
-- directory (its transcripts). Directory watches report changes to the files
-- in them on every platform, unlike recursive ones.

---@type table<string, uv.uv_fs_event_t>
local watchers = {}
---@type uv.uv_timer_t?
local debounce

--- Session ids open in this Neovim: their status comes from the live session,
--- so their transcripts streaming to disk needn't trigger reloads.
local function live_ids()
  local ids = {}
  for _, s in ipairs(require("claude-code.sessions").live()) do
    ids[s.id] = true
  end
  return ids
end

local function mark_stale()
  if not debounce then
    debounce = assert(vim.uv.new_timer())
  end
  debounce:stop()
  debounce:start(
    1000,
    0,
    vim.schedule_wrap(function()
      M.stale = true
      changed()
    end)
  )
end

---@param dir string
local function watch(dir)
  if watchers[dir] or not vim.uv.fs_stat(dir) then
    return
  end
  local handle = vim.uv.new_fs_event()
  if not handle then
    return
  end
  local ok = handle:start(dir, {}, function(err, filename)
    if err then
      return
    end
    local id = filename and filename:match("([^/\\]+)%.jsonl$")
    vim.schedule(function()
      if not (id and live_ids()[id]) then
        mark_stale()
      end
    end)
  end)
  if ok then
    watchers[dir] = handle
  else
    handle:close()
  end
end

function M.watch_root()
  watch(require("claude-agent-sdk.sessions").projects_root())
end

---@param cwd string
function M.watch_project(cwd)
  watch(require("claude-agent-sdk.sessions").project_dir(cwd))
end

return M
