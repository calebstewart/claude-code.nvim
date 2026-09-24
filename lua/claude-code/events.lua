-- `User ClaudeCodeSessionsChanged`: fired (coalesced, on the next tick) when
-- a session opens, closes, is renamed or deleted, or changes status — so views
-- listing sessions (the neo-tree source, statuslines) can redraw.
--
-- No dependencies, so any module can require it without a require cycle.

local M = {}

local PATTERN = "ClaudeCodeSessionsChanged"
local pending = false

function M.sessions_changed()
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    vim.api.nvim_exec_autocmds("User", { pattern = PATTERN, modeline = false })
  end)
end

M.SESSIONS_CHANGED = PATTERN

return M
