-- Highlight groups. Colors are derived from the active colorscheme's accents so
-- the chat blends in; tinted backgrounds are blended against Normal's
-- background (or black/white when Normal is transparent).

local M = {}

---@param name string
---@param attr "fg"|"bg"
---@return integer?
local function color(name, attr)
  local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
  return hl[attr]
end

---@param a integer
---@param b integer
---@param alpha number Weight of `a`.
---@return integer
local function blend(a, b, alpha)
  local function channel(shift)
    local x = bit.band(bit.rshift(a, shift), 0xff)
    local y = bit.band(bit.rshift(b, shift), 0xff)
    return bit.lshift(math.floor(x * alpha + y * (1 - alpha) + 0.5), shift)
  end
  return bit.bor(channel(16), channel(8), channel(0))
end

---@return integer
local function background()
  return color("Normal", "bg") or (vim.o.background == "light" and 0xffffff or 0x000000)
end

---@param fallback integer
local function accent(group, fallback)
  return color(group, "fg") or fallback
end

local function apply()
  local bg = background()
  local fg = color("Normal", "fg") or (vim.o.background == "light" and 0x000000 or 0xffffff)
  local user = accent("Function", 0x61afef)
  local claude = accent("Special", 0xd19a66)
  local ok = accent("DiagnosticOk", 0x98c379)
  local err = accent("DiagnosticError", 0xe06c75)
  local warn = accent("DiagnosticWarn", 0xe5c07b)
  local muted = accent("Comment", blend(fg, bg, 0.5))

  ---@type table<string, vim.api.keyset.highlight>
  local groups = {
    -- Turn headers
    ClaudeCodeUserPill = { fg = bg, bg = user, bold = true },
    ClaudeCodeAssistantPill = { fg = bg, bg = claude, bold = true },
    ClaudeCodeUserPillEdge = { fg = user },
    ClaudeCodeAssistantPillEdge = { fg = claude },
    ClaudeCodeRule = { fg = blend(fg, bg, 0.15) },
    -- User messages
    ClaudeCodeUserBlock = { bg = blend(user, bg, 0.10) },
    ClaudeCodeUserBar = { fg = user, bg = blend(user, bg, 0.10) },
    -- Tools
    ClaudeCodeToolName = { fg = fg, bold = true },
    ClaudeCodeToolDetail = { fg = muted },
    ClaudeCodeToolPending = { fg = claude },
    ClaudeCodeToolSuccess = { fg = ok },
    ClaudeCodeToolError = { fg = err },
    ClaudeCodeToolCancelled = { fg = muted },
    ClaudeCodeToolOutput = { fg = blend(fg, bg, 0.75) },
    ClaudeCodeToolGutter = { fg = blend(fg, bg, 0.2) },
    -- Permission cards
    ClaudeCodeCard = { bg = blend(warn, bg, 0.10) },
    ClaudeCodeCardBorder = { fg = warn, bg = blend(warn, bg, 0.10) },
    ClaudeCodeCardTitle = { fg = warn, bg = blend(warn, bg, 0.10), bold = true },
    ClaudeCodeCardText = { fg = fg, bg = blend(warn, bg, 0.10) },
    ClaudeCodeCardKey = { fg = bg, bg = warn, bold = true },
    ClaudeCodeCardDenyKey = { fg = bg, bg = err, bold = true },
    -- Markdown
    ClaudeCodeCodeBlock = { bg = blend(fg, bg, 0.06) },
    ClaudeCodeCodeLang = { fg = muted, bg = blend(fg, bg, 0.06), italic = true },
    ClaudeCodeBullet = { fg = claude },
    ClaudeCodeQuote = { fg = muted },
    -- Chrome
    ClaudeCodeMuted = { fg = muted },
    ClaudeCodeError = { fg = err },
    ClaudeCodeStatus = { fg = claude, bold = true },
    ClaudeCodeTitle = { fg = claude, bold = true },
    ClaudeCodePrompt = { link = "Normal" },
    ClaudeCodePromptBorder = { fg = blend(claude, bg, 0.6) },
    ClaudeCodePromptBusy = { fg = claude },
    ClaudeCodePromptAttention = { fg = warn, bold = true },
    ClaudeCodePlaceholder = { fg = muted, italic = true },
    ClaudeCodeBar = { link = "Normal" },
    -- The separator between the chat's own windows, kept on Normal's background
    -- so the rule vanishes while the pane's edge keeps the theme's colour.
    ClaudeCodeSeparator = { fg = color("WinSeparator", "fg"), bg = bg },
    ClaudeCodeWelcomeLogo = { fg = claude, bold = true },
    -- Permission modes (shown in the prompt border)
    ClaudeCodeModeAcceptEdits = { fg = accent("Constant", 0xc678dd), bold = true },
    ClaudeCodeModePlan = { fg = accent("Type", 0x56b6c2), bold = true },
    ClaudeCodeModeBypass = { fg = err, bold = true },
    ClaudeCodeModeOther = { fg = warn, bold = true },
    ClaudeCodeShellMode = { fg = accent("Statement", 0xe06c75), bold = true },
    ClaudeCodeAttachment = { fg = claude, bold = true },
    -- Question picker
    ClaudeCodePicker = { link = "NormalFloat" },
    ClaudeCodePickerBorder = { fg = blend(claude, bg, 0.6) },
    ClaudeCodePickerTitle = { fg = bg, bg = claude, bold = true },
    ClaudeCodePickerChip = { fg = bg, bg = user, bold = true },
    ClaudeCodePickerSelection = { bg = blend(claude, bg, 0.20), bold = true },
  }
  for name, spec in pairs(groups) do
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
end

local initialized = false

function M.setup()
  if initialized then
    return
  end
  initialized = true
  apply()
  -- :colorscheme runs :hi clear, which drops our groups; the palette may also change.
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("claude-code.highlights", { clear = true }),
    callback = apply,
  })
end

return M
