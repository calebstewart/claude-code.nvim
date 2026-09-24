-- Glyph sets. "nerd" needs a Nerd Font; "unicode" works in any terminal font.

local config = require("claude-code.config")

---@class claude_code.Icons
---@field user string
---@field claude string
---@field logo string
---@field folder string
---@field model string
---@field clock string
---@field success string
---@field error string
---@field cancelled string
---@field permission string
---@field question string
---@field spinner string[]
---@field pill [string, string] Left and right caps for header pills.
---@field plan string
---@field image string
---@field background string
---@field message string A message from another Claude session.
---@field tools table<string, string> Tool name -> icon; `default` for anything else.

---@type table<string, claude_code.Icons>
local sets = {
  -- Nerd Font v3 codepoints, escaped so editors and tools can't mangle them.
  nerd = {
    user = "\u{f007}", -- fa-user
    claude = "\u{f06a9}", -- md-robot
    logo = "✻",
    folder = "\u{f07c}", -- fa-folder_open
    model = "\u{f4bc}", -- oct-cpu
    clock = "\u{f13ab}", -- md-timer_outline
    success = "\u{f00c}", -- fa-check
    error = "\u{f00d}", -- fa-close
    cancelled = "\u{f05e}", -- fa-ban
    permission = "\u{f132}", -- fa-shield
    question = "\u{f128}", -- fa-question
    plan = "\u{f022}", -- fa-list_alt
    image = "\u{f03e}", -- fa-picture_o
    background = "\u{f1da}", -- fa-history
    message = "\u{f0e0}", -- fa-envelope
    pill = { "\u{e0b6}", "\u{e0b4}" }, -- powerline rounded caps
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    tools = {
      Bash = "\u{f489}", -- oct-terminal
      Read = "\u{f4a5}", -- oct-file
      Edit = "\u{f448}", -- oct-pencil
      MultiEdit = "\u{f448}",
      Write = "\u{f448}",
      NotebookEdit = "\u{f448}",
      Grep = "\u{f422}", -- oct-search
      Glob = "\u{f422}",
      WebFetch = "\u{f059f}", -- md-web
      WebSearch = "\u{f059f}",
      Task = "\u{f070e}", -- md-account_multiple_outline
      Agent = "\u{f070e}",
      TodoWrite = "\u{f45e}", -- oct-checklist
      AskUserQuestion = "\u{f128}", -- fa-question
      ExitPlanMode = "\u{f022}", -- fa-list_alt
      Shell = "\u{f489}", -- oct-terminal (a `!command` you ran)
      SendMessage = "\u{f0e0}", -- fa-envelope
      ListAgents = "\u{f0c0}", -- fa-users
      default = "\u{f423}", -- oct-gear
    },
  },
  unicode = {
    user = "›",
    claude = "✻",
    logo = "✻",
    folder = "▸",
    model = "◆",
    clock = "◷",
    success = "✓",
    error = "✗",
    cancelled = "○",
    permission = "!",
    question = "?",
    plan = "☰",
    image = "▣",
    background = "◷",
    message = "✉",
    pill = { "", "" },
    spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    tools = {
      Bash = "$",
      Read = "◇",
      Edit = "✎",
      MultiEdit = "✎",
      Write = "✎",
      NotebookEdit = "✎",
      Grep = "⌕",
      Glob = "⌕",
      WebFetch = "◎",
      WebSearch = "◎",
      Task = "◈",
      Agent = "◈",
      TodoWrite = "☐",
      AskUserQuestion = "?",
      ExitPlanMode = "☰",
      Shell = "$",
      SendMessage = "✉",
      ListAgents = "◈",
      default = "•",
    },
  },
}

local M = {}

---@return claude_code.Icons
function M.get()
  return sets[config.options.icons] or sets.nerd
end

--- Compact key names for hints: `<C-s>` -> `^S`, `<CR>` -> `⏎`, `<C-CR>` -> `^⏎`.
---@param lhs string
---@return string
function M.key(lhs)
  local named = { ["<cr>"] = "⏎", ["<c-cr>"] = "^⏎", ["<tab>"] = "⇥", ["<s-tab>"] = "⇧⇥", ["<esc>"] = "esc" }
  if named[lhs:lower()] then
    return named[lhs:lower()]
  end
  local ctrl = lhs:match("^<[Cc]%-(.)>$")
  return ctrl and ("^" .. ctrl:upper()) or lhs
end

---@param name string
---@return string
function M.tool(name)
  local tools = M.get().tools
  return tools[name] or tools.default
end

return M
