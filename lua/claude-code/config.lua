local M = {}

---@alias claude_code.PermissionMode "default"|"acceptEdits"|"plan"|"dontAsk"|"auto"|"bypassPermissions"

---@class claude_code.Config
---@field node string Node executable used to run the sidecar.
---@field claude? string Claude Code executable. Defaults to `claude` on $PATH.
---@field model? string Model alias or id; nil uses Claude Code's default.
---@field permission_mode? claude_code.PermissionMode Starting mode; nil uses Claude Code's settings (`defaultMode`).
---@field window claude_code.WindowConfig
---@field keymaps claude_code.KeymapConfig
---@field icons "nerd"|"unicode" Glyph set; "nerd" needs a Nerd Font.
---@field markdown { enabled: boolean } Built-in styling for code blocks, lists, rules and quotes in the transcript.
---@field tool_output { max_lines: integer } Line cap for expanded tool output.
---@field history { share: boolean } Share prompt history with the Claude Code CLI (~/.claude/history.jsonl).
---@field sessions { idle_timeout: integer|false } Minutes before an idle background session's process is stopped (it resumes on demand).
---@field shell { respond: boolean, max_output: integer } `!command` prompts: whether Claude responds once the command exits, and how much output (characters) it's given.
---@field prompt_suggestions boolean After each turn, suggest a next prompt (shown in the empty prompt; <Tab> takes it).

---@class claude_code.WindowConfig
---@field position "right"|"left"|"top"|"bottom"
---@field size number Columns/rows, or a fraction of the editor when < 1.
---@field prompt_height { min: integer, max: integer } The prompt grows with its content within these bounds.

--- Chat keymaps. Set any entry to `false` to disable it.
---@class claude_code.KeymapConfig
---@field submit { n: string|string[]|false, i: string|string[]|false } Send the prompt (normal and insert mode).
---@field interrupt string|false Interrupt the turn in progress (normal mode, both windows).
---@field close string|false Hide the chat (normal mode, transcript window).
---@field toggle_tool string[]|false Expand/collapse the tool call under the cursor (normal mode, transcript window).
---@field cycle_mode string|false Cycle the permission mode: default -> accept edits -> plan (prompt, both modes).
---@field paste_image string|false Paste an image from the clipboard into the prompt (insert mode).

---@type claude_code.Config
M.defaults = {
  node = "node",
  claude = nil,
  model = nil,
  permission_mode = nil,
  window = {
    position = "right",
    size = 0.4,
    prompt_height = { min = 3, max = 12 },
  },
  keymaps = {
    -- <C-CR> needs a terminal that reports it (kitty keyboard protocol: Ghostty, kitty,
    -- WezTerm, foot, ...); <C-s> works everywhere.
    submit = { n = "<CR>", i = { "<C-CR>", "<C-s>" } },
    interrupt = "<C-c>",
    close = "q",
    toggle_tool = { "<Tab>", "<CR>" },
    cycle_mode = "<S-Tab>",
    paste_image = "<C-v>",
  },
  icons = "nerd",
  markdown = { enabled = true },
  tool_output = { max_lines = 40 },
  history = { share = true },
  sessions = { idle_timeout = 15 },
  shell = { respond = true, max_output = 30000 },
  prompt_suggestions = true,
}

---@type claude_code.Config
M.options = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

--- A keymap option as a list of lhs (`false` -> empty).
---@param lhs string|string[]|false|nil
---@return string[]
function M.keys(lhs)
  if not lhs then
    return {}
  end
  return type(lhs) == "table" and lhs or { lhs }
end

---@return string?
function M.claude_path()
  local path = M.options.claude or vim.fn.exepath("claude")
  return path ~= "" and path or nil
end

return M
