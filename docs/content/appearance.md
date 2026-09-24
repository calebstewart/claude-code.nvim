+++
title = "Appearance"
weight = 7
description = "How colors are derived from your colorscheme, every highlight group, and the chat's filetypes."
+++

## How colors are chosen

The chat has no palette of its own. Every color is derived from the active colorscheme's accents, so it
blends in without configuration:

| Source group | Used for |
|---|---|
| `Normal` | Foreground and background, and the base for every blend |
| `Function` | The "user" accent — your turn headers, the user message bar, picker chips |
| `Special` | The "Claude" accent — assistant headers, pending tools, bullets, titles, the prompt border |
| `DiagnosticOk` | Successful tool calls |
| `DiagnosticError` | Failed tool calls, errors, the deny key, bypass mode |
| `DiagnosticWarn` | Permission cards and their keys, attention states |
| `Comment` | Muted text (falls back to a 50% blend of `Normal` fg and bg) |
| `Constant` | Accept-edits mode |
| `Type` | Plan mode |
| `Statement` | Shell (`!command`) mode |
| `WinSeparator` | The separator between the chat's own windows |

Tinted backgrounds are blended against `Normal`'s background. When `Normal` is transparent — no `bg` at
all — the blend falls back to black or white depending on `&background`, so transparent colorschemes still
get sensible shading rather than nothing.

Each source group has a hardcoded fallback color, so a colorscheme that defines none of them still
produces a usable chat.

## Overriding

Every group is set with `default = true`, which means **any value you set yourself wins** — the plugin will
not clobber it. Groups are re-applied on `ColorScheme`, because `:colorscheme` runs `:hi clear` and would
otherwise drop them.

Set yours after the colorscheme loads:

```lua
vim.api.nvim_set_hl(0, "ClaudeCodePromptBorder", { fg = "#d9a066" })
vim.api.nvim_set_hl(0, "ClaudeCodeUserBlock", { bg = "#1d1c22" })
```

If you want them to survive a colorscheme change, do it from an autocommand:

```lua
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.api.nvim_set_hl(0, "ClaudeCodeCodeBlock", { bg = "#16151a" })
  end,
})
```

## Highlight groups

All groups are prefixed `ClaudeCode`. The prefix is omitted in the table below.

### Turn headers

| Group | |
|---|---|
| `UserPill` | The pill on your turn header |
| `AssistantPill` | The pill on Claude's turn header |
| `UserPillEdge` | The pill's rounded edges, your turn |
| `AssistantPillEdge` | The pill's rounded edges, Claude's turn |
| `Rule` | The horizontal rule between turns |

### User messages

| Group | |
|---|---|
| `UserBlock` | Background tint behind your message |
| `UserBar` | The bar down the left of your message |

### Tool calls

| Group | |
|---|---|
| `ToolName` | The tool's name |
| `ToolDetail` | The argument summary beside the name |
| `ToolPending` | Status glyph while the tool is running |
| `ToolSuccess` | Status glyph on success |
| `ToolError` | Status glyph on failure |
| `ToolCancelled` | Status glyph when the call was cancelled |
| `ToolOutput` | Expanded output text |
| `ToolGutter` | The gutter beside expanded output |

### Permission cards

| Group | |
|---|---|
| `Card` | Card background |
| `CardBorder` | Card border |
| `CardTitle` | Card title |
| `CardText` | Card body text |
| `CardKey` | The key cap for an allow action |
| `CardDenyKey` | The key cap for deny |

### Markdown

| Group | |
|---|---|
| `CodeBlock` | Shaded background behind a fenced code block |
| `CodeLang` | The language tag on a code block |
| `Bullet` | List bullets |
| `Quote` | Blockquote bars |

### Chrome

| Group | |
|---|---|
| `Muted` | De-emphasised text throughout |
| `Error` | Error text |
| `Status` | Status text in the prompt border |
| `Title` | Titles |
| `Prompt` | The prompt buffer (links to `Normal`) |
| `PromptBorder` | The prompt's border |
| `PromptBusy` | The border while Claude is working |
| `PromptAttention` | The border when something is waiting on you |
| `Placeholder` | Placeholder and suggestion text in an empty prompt |
| `Bar` | The chat's status bar (links to `Normal`) |
| `Separator` | The separator between the chat's own windows |
| `WelcomeLogo` | The logo on the welcome screen |
| `Attachment` | `[Image #N]` placeholders in the prompt |

### Permission modes

Shown in the prompt's border.

| Group | |
|---|---|
| `ModeAcceptEdits` | `⏵⏵ accept edits` |
| `ModePlan` | `⏸ plan mode` |
| `ModeBypass` | `bypassPermissions` |
| `ModeOther` | Any other non-default mode |
| `ShellMode` | Shown while the prompt holds a `!command` |

### Pickers and dialogs

| Group | |
|---|---|
| `Picker` | Picker background (links to `NormalFloat`) |
| `PickerBorder` | Picker border |
| `PickerTitle` | Picker title |
| `PickerChip` | Chips in the picker and question dialog |
| `PickerSelection` | The highlighted row |

## Filetypes

The chat's three windows have their own filetypes, which is what you want for a statusline plugin's
`disabled_filetypes`, or for a `FileType` autocommand of your own:

| Filetype | Window |
|---|---|
| `claude-code-chat` | The transcript |
| `claude-code-prompt` | The prompt |
| `claude-code-dock` | The spacer under the prompt |

```lua
require("lualine").setup({
  options = {
    disabled_filetypes = { "claude-code-chat", "claude-code-prompt", "claude-code-dock" },
  },
})
```

## Markdown rendering

The transcript is an append-only markdown buffer. Headers, tool status, output and footers are drawn as
extmarks, so the buffer's *text* stays plain markdown — which means other markdown renderers work on it.

The built-in decoration (shaded code blocks, bullets, rules, quote bars) is
[`markdown.enabled`](@/configuration.md#markdown-enabled). Turn it off if you use
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) or similar, so the two
don't both draw.

## Icons

[`icons`](@/configuration.md#icons) picks the glyph set: `"nerd"` uses Nerd Font v3 codepoints, `"unicode"`
sticks to glyphs any font has. Set it to `"unicode"` if you see tofu.
