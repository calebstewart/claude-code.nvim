-- A neo-tree source listing Claude sessions by project:
--
--   Claude Sessions
--   ├  claude-code.nvim        ●
--   │   ● Add a sessions tree   2m ago
--   │     Fix the login bug     1d ago
--   └  dotfiles
--
-- Add "claude-code.neo-tree" to neo-tree's `sources`, then `:Neotree claude_sessions`.
-- Sessions open with <CR> like files do; `a`, `r` and `d` start, rename and
-- delete them. The current project is listed first and expanded; the others
-- load their sessions when expanded.

local listing = require("claude-code.listing")
local manager = require("neo-tree.sources.manager")
local model = require("claude-code.neo-tree.model")
local renderer = require("neo-tree.ui.renderer")

local M = {
  name = "claude_sessions",
  display_name = " 󰚩 Sessions ",
}

local ROOT = "claude:root"

---@param cwd string
function M.project_id(cwd)
  return "claude:project:" .. cwd
end

--- Every project to list: those with sessions on disk, Neovim's cwd (pinned
--- first, even with none yet) and any with a session open here.
---@return claude_code.tree.Project[]
local function projects()
  local cwd = vim.fn.getcwd()
  local list, seen = {}, {}
  local function add(project)
    if not seen[project.cwd] then
      seen[project.cwd] = true
      table.insert(list, project)
    end
  end
  add({ cwd = cwd, sessions = 0, lastModified = 0 })
  for _, project in ipairs(model.projects or {}) do
    if project.cwd == cwd then
      list[1] = project
    else
      add(project)
    end
  end
  for _, s in ipairs(require("claude-code.sessions").live()) do
    add({ cwd = s.cwd, sessions = 0, lastModified = s.last_active * 1000 })
  end
  return list
end

--- Project names: the directory's name, with its parent's when two collide.
---@param list claude_code.tree.Project[]
---@return table<string, string>
local function labels(list)
  local count = {}
  for _, p in ipairs(list) do
    local tail = vim.fn.fnamemodify(p.cwd, ":t")
    count[tail] = (count[tail] or 0) + 1
  end
  local out = {}
  for _, p in ipairs(list) do
    local tail = vim.fn.fnamemodify(p.cwd, ":t")
    out[p.cwd] = count[tail] > 1 and (vim.fn.fnamemodify(p.cwd, ":h:t") .. "/" .. tail) or tail
  end
  return out
end

--- Rows hold only plain data: neo-tree deep-copies the tree (to filter it),
--- and an entry for an open session holds the live Session, process handles
--- and all. Components and commands look entries up here by id.
---@type table<string, claude_code.SessionEntry>
local entries_by_id = {}

---@param node table
---@return claude_code.SessionEntry?
function M.entry(node)
  return node.extra and node.extra.entry_id and entries_by_id[node.extra.entry_id]
end

---@param cwd string
---@param kind string
---@param text string
local function message(cwd, kind, text)
  return {
    id = ("claude:%s:%s"):format(kind, cwd),
    name = text,
    type = "message",
    extra = { cwd = cwd, search_path = "" },
  }
end

--- A project's rows: its sessions (stored and open here), then "Show more"
--- when there may be more on disk.
--- Every word of `filter` appears (case-insensitively) in the entry's title,
--- first prompt or branch.
---@param entry claude_code.SessionEntry
---@param filter? string
local function matches(entry, filter)
  if not filter then
    return true
  end
  local haystack = table.concat({ entry.title, entry.first_prompt or "", entry.branch or "" }, " "):lower()
  for word in filter:lower():gmatch("%S+") do
    if not haystack:find(word, 1, true) then
      return false
    end
  end
  return true
end

---@param project claude_code.tree.Project
---@param filter? string
---@return table[]? children nil while the project hasn't been expanded
local function project_children(project, filter)
  local cwd = project.cwd
  local stored = model.sessions[cwd]
  if not stored then
    if model.loading[cwd] then
      return { message(cwd, "loading", "Loading…") }
    end
    return nil
  end
  local children = {}
  local entries = listing.merge(stored, function(s)
    return s.cwd == cwd
  end)
  for _, entry in ipairs(entries) do
    if matches(entry, filter) then
      entries_by_id[entry.id] = entry
      local title = entry.title:gsub("\n", " ")
      table.insert(children, {
        id = "claude:session:" .. entry.id,
        name = title,
        type = "session",
        extra = { entry_id = entry.id, cwd = cwd, search_path = title },
      })
    end
  end
  if filter then
    return children -- no "Show more" or "No sessions" rows while filtering
  end
  if #stored >= (model.limits[cwd] or model.PAGE) and project.sessions > #stored then
    table.insert(children, {
      id = "claude:more:" .. cwd,
      name = ("Show more (%d on disk)"):format(project.sessions),
      type = "more",
      extra = { cwd = cwd, search_path = "" },
    })
  end
  if #children == 0 then
    children = { message(cwd, "empty", "No sessions") }
  end
  return children
end

--- Open sessions in a project, for its row's status marker when collapsed.
---@param cwd string
---@return claude_code.SessionEntry[]
function M.live_entries(cwd)
  local out = {}
  for _, s in ipairs(require("claude-code.sessions").live()) do
    if s.cwd == cwd then
      table.insert(out, { id = s.id, title = s.title or "", last_used = s.last_active, live = s })
    end
  end
  return out
end

---@param filter? string
---@return table[]
local function items(filter)
  entries_by_id = {}
  local list = projects()
  local names = labels(list)
  local children = {}
  for _, project in ipairs(list) do
    local rows = project_children(project, filter)
    -- While filtering, only projects with a match.
    if not filter or (rows and #rows > 0) then
      table.insert(children, {
        id = M.project_id(project.cwd),
        name = names[project.cwd],
        type = "directory",
        loaded = rows ~= nil,
        children = rows,
        extra = { cwd = project.cwd, project = true, search_path = names[project.cwd] },
      })
    end
  end
  if filter and #children == 0 then
    table.insert(children, message("", "empty", "No matching sessions"))
  end
  if model.projects == nil then
    table.insert(children, message("", "loading", "Loading projects…"))
  end
  return {
    {
      id = ROOT,
      name = filter and ("Claude Sessions (filter: %s)"):format(filter) or "Claude Sessions",
      type = "directory",
      loaded = true,
      children = children,
      extra = { search_path = "" },
    },
  }
end

--- Projects to expand once they have rows to show (e.g. one whose sessions
--- are loading); after that, neo-tree keeps whatever you expand or collapse.
---@type table<string, boolean> cwd -> true
local pending_expand = {}

--- Load a project's sessions and expand it.
---@param cwd string
function M.expand(cwd)
  pending_expand[cwd] = true
  if not model.sessions[cwd] and not model.loading[cwd] then
    model.load_sessions(cwd)
  end
  M.refresh()
end

local started = false

---@param state table neotree.State
M.navigate = function(state, path, path_to_reveal, callback)
  state.dirty = false
  state.path = vim.fn.getcwd()
  if not started then
    -- First show: list projects, and the current one's sessions, expanded.
    started = true
    model.watch_root()
    pending_expand[state.path] = true
    model.load_sessions(state.path)
  end
  if (model.projects == nil or model.stale) and not model.loading_projects then
    model.reload()
  end

  -- Folders to reopen, e.g. after a filter is cleared. neo-tree only stops
  -- preserving the current ones when this is set; reopening them is ours to do.
  local expand = vim.list_extend({ ROOT }, state.force_open_folders or {})
  for cwd in pairs(pending_expand) do
    if model.sessions[cwd] or model.loading[cwd] then
      table.insert(expand, M.project_id(cwd))
      if model.sessions[cwd] then
        pending_expand[cwd] = nil
      end
    end
  end
  local filter = state.claude_filter
  if filter then
    -- Open every project with a match.
    for _, project in ipairs(model.projects or {}) do
      table.insert(expand, M.project_id(project.cwd))
    end
    table.insert(expand, M.project_id(vim.fn.getcwd()))
  end
  state.default_expanded_nodes = expand
  if path_to_reveal then
    renderer.position.set(state, path_to_reveal)
  end
  renderer.show_nodes(items(filter), state)
  state.default_expanded_nodes = nil
  if type(callback) == "function" then
    vim.schedule(callback)
  end
end

local refresh_timer

--- Redraw every visible tree from the cache, soon (coalescing bursts of
--- session status changes).
function M.refresh()
  if not refresh_timer then
    refresh_timer = assert(vim.uv.new_timer())
  end
  refresh_timer:stop()
  refresh_timer:start(
    50,
    0,
    vim.schedule_wrap(function()
      manager.refresh(M.name)
    end)
  )
end

---@param config table
---@param global_config table
M.setup = function(config, global_config)
  require("claude-code.ui.highlights").setup()
  model.PAGE = config.sessions_per_page or model.PAGE
  model.on_change(M.refresh)
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("claude-code.neo-tree", { clear = true }),
    pattern = require("claude-code.events").SESSIONS_CHANGED,
    callback = M.refresh,
  })
  -- The current project follows Neovim's cwd.
  manager.subscribe(M.name, {
    event = require("neo-tree.events").VIM_DIR_CHANGED,
    handler = function()
      if started then
        M.expand(vim.fn.getcwd())
      end
    end,
  })
end

M.default_config = {
  --- Sessions listed per project before "Show more".
  sessions_per_page = 50,
  renderers = {
    directory = {
      { "indent" },
      { "icon" },
      {
        "container",
        content = {
          { "name", zindex = 10, use_git_status_colors = false, highlight_opened_files = false },
          { "project_status", zindex = 20, align = "right" },
        },
      },
    },
    session = {
      { "indent" },
      { "session_status" },
      {
        "container",
        content = {
          { "session_name", zindex = 10 },
          { "session_time", zindex = 20, align = "right" },
        },
      },
    },
    message = {
      { "indent", with_markers = false },
      { "name", highlight = "NeoTreeMessage", use_git_status_colors = false, highlight_opened_files = false },
    },
    more = {
      { "indent" },
      { "name", highlight = "NeoTreeMessage", use_git_status_colors = false, highlight_opened_files = false },
    },
  },
  window = {
    mappings = {
      ["<cr>"] = "open",
      ["<2-LeftMouse>"] = "open",
      ["o"] = "open",
      ["a"] = "add",
      ["r"] = "rename",
      ["d"] = "delete",
      ["R"] = "refresh",
      -- File operations with no meaning for sessions.
      ["A"] = "noop",
      ["c"] = "noop",
      ["m"] = "noop",
      ["y"] = "noop",
      ["x"] = "noop",
      ["p"] = "noop",
      ["T"] = "noop",
      ["u"] = "noop",
      ["U"] = "noop",
      ["<C-r>"] = "noop",
      ["<Tab>"] = "noop",
      ["<C-S-i>"] = "noop",
      ["<C-;>"] = "noop",
      ["S"] = "noop",
      ["s"] = "noop",
      ["t"] = "noop",
      ["w"] = "noop",
      ["P"] = "noop",
      ["l"] = "noop",
      ["<C-f>"] = "noop",
      ["<C-b>"] = "noop",
      ["Z"] = "noop",
      ["<C-s>"] = "noop", -- quick_jump opens its target as a file
      ["/"] = "filter",
      ["<C-x>"] = "clear_filter",
    },
  },
}

return M
