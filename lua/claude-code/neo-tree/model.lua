-- What the neo-tree source shows: projects, and each expanded project's
-- sessions, cached here and shared by every tab's tree. Projects load once; a
-- project's sessions load when it's first expanded, a page at a time.
--
-- A git repository's worktrees are listed under its main worktree, as one
-- project: their sessions are listed with it, as the picker lists them.
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

---@type claude_code.tree.Project[]? One per project directory on disk, worktrees included.
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
  control.request("list_sessions", { dir = cwd, limit = M.limits[cwd] or M.PAGE }, function(err, result)
    M.loading[cwd] = nil
    if err then
      vim.notify("claude-code: couldn't list sessions: " .. err, vim.log.levels.ERROR)
    end
    M.sessions[cwd] = result or M.sessions[cwd] or {}
    M.watch_group(cwd)
    if callback then
      callback()
    end
    changed()
  end)
end

---@type table<string, string|false> cwd -> its project (false while resolving)
local roots = {}

--- Resolve the project `cwd` belongs to: the main worktree of the repository
--- when `cwd` is the top of one of its worktrees, else `cwd` itself (a plain
--- directory, a subdirectory of a repository, a bare or removed worktree).
---@param cwd string
---@param on_done? fun() Resolve asynchronously, calling this when done.
local function resolve(cwd, on_done)
  roots[cwd] = false
  local function finish(result)
    local root = cwd
    local top, common = (result.stdout or ""):match("^([^\n]+)\n([^\n]+)")
    if
      result.code == 0
      and top
      and vim.fs.normalize(top) == vim.fs.normalize(cwd)
      and vim.fs.basename(common) == ".git"
    then
      root = vim.fs.dirname(common)
    end
    roots[cwd] = root
  end
  local cmd = { "git", "-C", cwd, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir" }
  if not vim.uv.fs_stat(cwd) then
    roots[cwd] = cwd
    if on_done then
      on_done()
    end
  elseif on_done then
    vim.system(
      cmd,
      { text = true },
      vim.schedule_wrap(function(result)
        finish(result)
        on_done()
      end)
    )
  else
    finish(vim.system(cmd, { text = true }):wait())
  end
end

--- The project `cwd`'s sessions are listed under. Until it's known, `cwd`:
--- it's resolved in the background (then the tree redraws), or straight away
--- when `sync`.
---@param cwd string
---@param sync? boolean
---@return string
function M.root(cwd, sync)
  if not cwd then
    return cwd
  end
  if roots[cwd] == nil then
    if sync then
      resolve(cwd)
    else
      resolve(cwd, changed)
    end
  end
  return roots[cwd] or cwd
end

--- The projects to list: those on disk, each repository's worktrees folded
--- into its main worktree.
---@return claude_code.tree.Project[]?
function M.grouped()
  if not M.projects then
    return nil
  end
  local list, by_root = {}, {}
  for _, project in ipairs(M.projects) do
    local root = M.root(project.cwd)
    local group = by_root[root]
    if not group then
      group = { cwd = root, sessions = 0, lastModified = 0 }
      by_root[root] = group
      table.insert(list, group)
    end
    group.sessions = group.sessions + project.sessions
    group.lastModified = math.max(group.lastModified, project.lastModified)
  end
  table.sort(list, function(a, b)
    return a.lastModified > b.lastModified
  end)
  return list
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
    for cwd in pairs(M.sessions) do
      M.watch_group(cwd)
    end
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

--- Whether a transcript changing can be ignored: it's a session open in this
--- Neovim (its status comes from the live session) that the cache already
--- lists. A new one's first writes still reload, so it's listed once closed.
---@param id string?
local function ignorable(id)
  if not (id and require("claude-code.sessions").find(id)) then
    return false
  end
  for _, list in pairs(M.sessions) do
    for _, info in ipairs(list) do
      if info.sessionId == id then
        return true
      end
    end
  end
  return false
end

function M.mark_stale()
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
      if not ignorable(id) then
        M.mark_stale()
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

--- Watch a project's directory and its worktrees' (those with sessions on
--- disk), so any of their transcripts changing reloads it.
---@param cwd string
function M.watch_group(cwd)
  M.watch_project(cwd)
  for _, project in ipairs(M.projects or {}) do
    if project.cwd ~= cwd and M.root(project.cwd) == cwd then
      M.watch_project(project.cwd)
    end
  end
  for _, info in ipairs(M.sessions[cwd] or {}) do
    if info.cwd and info.cwd ~= cwd then
      M.watch_project(info.cwd)
    end
  end
end

return M
