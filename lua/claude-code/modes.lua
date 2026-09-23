-- Claude Code's permission modes: names, how they're shown, and the cycle order
-- (as the CLI's shift+tab).

local M = {}

---@type claude_code.PermissionMode[]
M.all = { "default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions" }

--- What <S-Tab> steps through.
---@type claude_code.PermissionMode[]
M.cycle = { "default", "acceptEdits", "plan" }

local labels = {
  default = "default",
  acceptEdits = "⏵⏵ accept edits",
  plan = "⏸ plan mode",
  auto = "⏵ auto",
  dontAsk = "don't ask",
  bypassPermissions = "⏵⏵ bypass permissions",
}

local highlights = {
  acceptEdits = "ClaudeCodeModeAcceptEdits",
  plan = "ClaudeCodeModePlan",
  bypassPermissions = "ClaudeCodeModeBypass",
}

---@param mode string
function M.valid(mode)
  return vim.tbl_contains(M.all, mode)
end

---@param mode string
---@return string label, string hl
function M.display(mode)
  return labels[mode] or mode, highlights[mode] or "ClaudeCodeModeOther"
end

--- The mode after `mode` in the cycle (modes outside it go back to default).
---@param mode? string
---@return claude_code.PermissionMode
function M.next(mode)
  for i, m in ipairs(M.cycle) do
    if m == (mode or "default") then
      return M.cycle[i % #M.cycle + 1]
    end
  end
  return "default"
end

return M
