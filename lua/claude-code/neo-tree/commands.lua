-- Commands for the claude_sessions neo-tree source, bound in its
-- default_config. They follow the filesystem source's: <CR> opens, `a` adds,
-- `r` renames, `d` deletes (after confirming), `R` refreshes.

local cc = require("neo-tree.sources.common.commands")
local inputs = require("neo-tree.ui.inputs")
local listing = require("claude-code.listing")
local model = require("claude-code.neo-tree.model")
local source = require("claude-code.neo-tree")
local utils = require("neo-tree.utils")

local M = {}

---@param state table
---@return table? node
local function current(state)
  local ok, node = pcall(state.tree.get_node, state.tree)
  return ok and node or nil
end

--- The window a session opened from the tree should use when it's empty.
---@param state table
---@return integer
local function target_window(state)
  return (utils.get_appropriate_window(state))
end

--- Expand or collapse a project, loading its sessions the first time.
M.toggle_node = function(state)
  local node = current(state)
  if not node then
    return
  end
  local cwd = node.extra and node.extra.project and node.extra.cwd
  if cwd and node.loaded == false then
    source.expand(cwd)
    return
  end
  cc.toggle_node(state)
end

--- Open the session under the cursor, or expand/collapse a project.
M.open = function(state)
  local node = current(state)
  if not node then
    return
  end
  local entry = source.entry(node)
  if entry then
    listing.open(entry, { win = target_window(state) })
  elseif node.type == "more" then
    model.more(node.extra.cwd)
  elseif node.type == "directory" then
    M.toggle_node(state)
  end
end

--- Start a session in the project under the cursor (Neovim's cwd on the root).
M.add = function(state)
  local node = current(state)
  local cwd = node and node.extra and node.extra.cwd
  if not cwd or cwd == "" then
    cwd = vim.fn.getcwd()
  end
  local win = target_window(state)
  inputs.input(("New session in %s (name optional):"):format(vim.fn.fnamemodify(cwd, ":~")), "", function(name)
    if name == nil then
      return
    end
    source.expand(cwd)
    listing.new(name, { cwd = cwd, win = win })
  end)
end

M.rename = function(state)
  local node = current(state)
  local entry = node and source.entry(node)
  if not entry then
    return
  end
  inputs.input(("Rename %q:"):format(entry.title), entry.title, function(title)
    title = title and vim.trim(title) or ""
    if title == "" or title == entry.title then
      return
    end
    listing.rename(entry, title, function()
      if not entry.live then
        model.load_sessions(node.extra.cwd)
      end
    end)
  end)
end

M.delete = function(state)
  local node = current(state)
  local entry = node and source.entry(node)
  if not entry then
    return
  end
  local blocker = listing.delete_blocker(entry)
  if blocker then
    vim.notify("claude-code: " .. blocker, vim.log.levels.WARN)
    return
  end
  local question = entry.live and ("Delete %q? It will be closed, and its transcript removed."):format(entry.title)
    or ("Delete %q? Its transcript will be removed."):format(entry.title)
  inputs.confirm(question, function(confirmed)
    if not confirmed then
      return
    end
    model.forget(entry.id)
    listing.delete(entry, function()
      model.load_sessions(node.extra.cwd)
    end)
  end)
end

--- Re-read projects and sessions from disk.
M.refresh = function()
  model.reload()
end

--- Put the cursor on the first session row.
---@param state table
local function focus_first_session(state)
  if not (state.tree and state.winid and vim.api.nvim_win_is_valid(state.winid)) then
    return
  end
  for linenr = 1, vim.api.nvim_buf_line_count(state.bufnr) do
    local node = state.tree:get_node(linenr)
    if node and node.type == "session" then
      require("neo-tree.ui.renderer").focus_node(state, node:get_id())
      return
    end
  end
end

---@param state table
---@param filter? string
local function set_filter(state, filter)
  if filter and not state.claude_filter then
    -- Remember what was open, to reopen when the filter is cleared.
    state.claude_open_before_filter = require("neo-tree.ui.renderer").get_expanded_nodes(state.tree)
  elseif not filter and state.claude_filter then
    state.force_open_folders = state.claude_open_before_filter
    state.claude_open_before_filter = nil
  end
  state.claude_filter = filter
  require("neo-tree.sources.manager").navigate(state, nil, nil, filter and function()
    focus_first_session(state)
  end or nil)
end

--- Show only sessions whose title, first prompt or branch contains every word
--- typed (in expanded projects: the others haven't loaded their sessions).
--- An empty filter, or `clear_filter` (<C-x>), shows everything again.
M.filter = function(state)
  inputs.input("Filter sessions:", state.claude_filter or "", function(text)
    if text == nil then
      return
    end
    text = vim.trim(text)
    set_filter(state, text ~= "" and text or nil)
  end)
end

M.clear_filter = function(state)
  set_filter(state, nil)
end

cc._add_common_commands(M, "^close_node$")
cc._add_common_commands(M, "^close_all_nodes$")
cc._add_common_commands(M, "^close_all_subnodes$")
cc._add_common_commands(M, "^close_window$")
cc._add_common_commands(M, "source$") -- next_source, prev_source
cc._add_common_commands(M, "^cancel$")
cc._add_common_commands(M, "help")
cc._add_common_commands(M, "^toggle_auto_expand_width$")

return M
