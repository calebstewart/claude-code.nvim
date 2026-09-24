-- Components for the claude_sessions neo-tree source's renderers, on top of
-- neo-tree's common ones (indent, icon, name, container).

local common = require("neo-tree.sources.common.components")
local highlights = require("neo-tree.ui.highlights")
local listing = require("claude-code.listing")
local source = require("claude-code.neo-tree")

local M = {}

--- The session's status glyph: running, working, waiting on you, suspended,
--- open in another Claude Code, or blank for a saved session.
M.session_status = function(config, node)
  local entry = source.entry(node)
  if not entry then
    return {}
  end
  local glyph, hl = listing.status(entry)
  return { text = glyph .. " ", highlight = hl == "Normal" and highlights.FILE_NAME or hl }
end

--- The title, highlighted like an open file when it's the current session.
M.session_name = function(config, node)
  local entry = source.entry(node)
  local current = require("claude-code.sessions").current()
  local is_current = entry ~= nil and current ~= nil and entry.live == current
  return {
    text = node.name,
    highlight = is_current and highlights.FILE_NAME_OPENED or highlights.FILE_NAME,
  }
end

M.session_time = function(config, node)
  local entry = source.entry(node)
  if not entry then
    return {}
  end
  return { text = " " .. listing.ago(entry.last_used) .. " ", highlight = highlights.DIM_TEXT }
end

--- The most pressing status among a project's open sessions, so a collapsed
--- project still shows that something in it needs you.
M.project_status = function(config, node)
  local cwd = node.extra and node.extra.project and node.extra.cwd
  local live = cwd and source.live_entries(cwd) or {}
  if #live == 0 then
    return {}
  end
  local rank = { ClaudeCodePromptAttention = 3, ClaudeCodeStatus = 2, ClaudeCodeToolSuccess = 1 }
  local best, best_rank = nil, 0
  for _, entry in ipairs(live) do
    local glyph, hl = listing.status(entry)
    local r = rank[hl] or 0
    if r > best_rank then
      best, best_rank = { text = glyph .. " ", highlight = hl }, r
    end
  end
  return best or {}
end

return vim.tbl_deep_extend("force", common, M)
