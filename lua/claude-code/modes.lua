-- Claude Code's permission modes: names, how they're shown, the cycle order
-- (as the CLI's shift+tab), and the starting mode from Claude Code's settings.

local M = {}

---@type claude_code.PermissionMode[]
M.all = { "default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions" }

--- What <S-Tab> steps through.
---@type claude_code.PermissionMode[]
M.cycle = { "default", "acceptEdits", "plan", "auto" }

local labels = {
  default = "default",
  acceptEdits = "⏵⏵ accept edits",
  plan = "⏸ plan mode",
  auto = "⏵ auto mode",
  dontAsk = "don't ask",
  bypassPermissions = "⏵⏵ bypass permissions",
}

local highlights = {
  acceptEdits = "ClaudeCodeModeAcceptEdits",
  plan = "ClaudeCodeModePlan",
  bypassPermissions = "ClaudeCodeModeBypass",
}

--- `permissions.defaultMode` from Claude Code's settings for `cwd`, highest
--- precedence first: local project, project, then user settings.
---
--- The SDK only passes a mode to Claude Code when given one, and SDK sessions
--- don't pick up every `defaultMode` on their own (notably "auto"), so the
--- plugin reads it and passes it explicitly.
---@param cwd string
---@return claude_code.PermissionMode?
function M.settings_default(cwd)
  local home = vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME or "~", ".claude")
  local files = {
    vim.fs.joinpath(cwd, ".claude", "settings.local.json"),
    vim.fs.joinpath(cwd, ".claude", "settings.json"),
    vim.fs.joinpath(home, "settings.json"),
  }
  for _, path in ipairs(files) do
    local f = io.open(path, "r")
    if f then
      local ok, settings = pcall(vim.json.decode, f:read("*a"))
      f:close()
      local mode = ok and type(settings) == "table" and type(settings.permissions) == "table"
        and settings.permissions.defaultMode
      if mode == "manual" then
        mode = "default" -- documented alias
      end
      if type(mode) == "string" and M.valid(mode) then
        return mode
      end
    end
  end
end

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
