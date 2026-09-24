+++
title = "Configuration"
weight = 2
description = "Every option, its default, and what it changes."
+++

Options are passed to `setup()` — or to `opts` with lazy.nvim, which calls it for you. They are merged over
the defaults with `vim.tbl_deep_extend("force", …)`, so a partial table only overrides what it names.

## Defaults

```lua
{
  node = "node",             -- Node executable used to run the sidecar (unused when transport = "direct")
  transport = "sidecar",     -- "sidecar": everything goes through Node and the Agent SDK
                             -- "direct":  Neovim drives `claude` itself and reads transcripts in Lua,
                             --            so Node is never started (experimental)
  claude = nil,              -- Claude Code executable; defaults to `claude` on $PATH
  model = nil,               -- e.g. "opus", "sonnet"; nil uses Claude Code's default
  permission_mode = nil,     -- starting mode: "default" | "acceptEdits" | "plan" | "dontAsk" | "auto" | "bypassPermissions";
                             -- nil uses Claude Code's settings (`defaultMode`)
  window = {
    position = "right",      -- "right" | "left" | "top" | "bottom"
    size = 0.4,              -- columns/rows, or a fraction of the editor when < 1
    prompt_height = { min = 3, max = 12 }, -- the prompt grows with its content
  },
  keymaps = {                -- set any entry to false to disable it
    submit = { n = "<CR>", i = { "<C-CR>", "<C-s>" } }, -- <C-CR> needs a terminal that reports it (Ghostty, kitty, WezTerm, …)
    interrupt = "<C-c>",     -- normal mode, transcript and prompt
    close = "q",             -- normal mode, transcript
    toggle_tool = { "<Tab>", "<CR>" }, -- normal mode, transcript: expand/collapse tool output
    cycle_mode = "<S-Tab>",  -- prompt and transcript: cycle default → accept edits → plan → auto
    paste_image = "<C-v>",   -- prompt, insert mode: paste an image from the clipboard
  },
  icons = "nerd",            -- "nerd" (needs a Nerd Font) | "unicode"
  markdown = { enabled = true }, -- shaded code blocks, bullets, rules, quote bars; disable if you use render-markdown.nvim
  tool_output = { max_lines = 40 }, -- cap for expanded tool output
  history = { share = true }, -- share prompt history with the Claude Code CLI (~/.claude/history.jsonl)
  sessions = {
    idle_timeout = 15,       -- minutes before an idle background session's process is stopped; false to never
  },
  shell = {                  -- `!command` prompts
    respond = true,          -- Claude responds once the command exits (false: output is just context)
    max_output = 30000,      -- characters of output given to Claude
  },
  prompt_suggestions = true, -- suggest a next prompt after each turn
}
```

## Process

### node

`string`, default `"node"`. The Node executable used to run the sidecar. Ignored entirely when
`transport = "direct"`, since nothing spawns Node then. The Nix package rewrites this to the store path of
its own Node, so `$PATH` does not need one.

### transport

`"sidecar" | "direct"`, default `"sidecar"`.

`"sidecar"` runs the official Agent SDK under Node, one process per session plus one for session
bookkeeping. `"direct"` drives `claude` from Lua using the [bundled port of the SDK](@/agent-sdk.md) and
reads transcripts itself, so Node is never started. See [Architecture](@/architecture.md).

### claude

`string?`, default `nil`. Path to the Claude Code executable. When `nil` the plugin resolves `claude` on
`$PATH` via `vim.fn.exepath`.

## Conversation

### model

`string?`, default `nil`. A model alias or id, for example `"opus"` or `"sonnet"`. `nil` uses whatever
Claude Code would pick on its own. The model in effect is shown in the prompt's border.

### permission_mode

`claude_code.PermissionMode?`, default `nil`. The mode new sessions start in — one of `"default"`,
`"acceptEdits"`, `"plan"`, `"dontAsk"`, `"auto"` or `"bypassPermissions"`.

When `nil`, the plugin reads `permissions.defaultMode` from your Claude Code settings, highest precedence
first:

1. `<cwd>/.claude/settings.local.json`
2. `<cwd>/.claude/settings.json`
3. `$CLAUDE_CONFIG_DIR/settings.json`, or `~/.claude/settings.json`

`"manual"` is accepted there as a documented alias for `"default"`.

> [!WARNING]
> `bypassPermissions` can only be a session's *starting* mode — the SDK requires it to be chosen up front —
> so it must be set here. `<S-Tab>` and `:Claude mode` cannot switch into it.

See [Permissions](@/permissions.md) for what each mode does.

### prompt_suggestions

`boolean`, default `true`. After a turn, show Claude Code's suggested next prompt in the empty prompt, where
<kbd>Tab</kbd> takes it. Can also be turned off globally with `promptSuggestionEnabled: false` in Claude
Code's own settings.

## Window

### window.position

`"right" | "left" | "top" | "bottom"`, default `"right"`. Which edge the chat sidebar docks to.

### window.size

`number`, default `0.4`. Columns for a vertical split or rows for a horizontal one. Values below 1 are
treated as a fraction of the editor, so `0.4` is 40%.

### window.prompt_height

`{ min: integer, max: integer }`, default `{ min = 3, max = 12 }`. The prompt grows with its content
between these bounds.

## Keymaps

Every entry accepts a single `string`, a list of strings, or `false` to disable it. These apply inside the
chat only; the plugin creates no global mappings.

| Option | Default | Where | Does |
|---|---|---|---|
| `keymaps.submit` | `{ n = "<CR>", i = { "<C-CR>", "<C-s>" } }` | Prompt | Send the prompt |
| `keymaps.interrupt` | `"<C-c>"` | Transcript and prompt, normal | Stop the turn in progress |
| `keymaps.close` | `"q"` | Transcript, normal | Hide the chat |
| `keymaps.toggle_tool` | `{ "<Tab>", "<CR>" }` | Transcript, normal | Expand/collapse tool output, or an edit's diff |
| `keymaps.cycle_mode` | `"<S-Tab>"` | Transcript and prompt | Cycle default → accept edits → plan → auto |
| `keymaps.paste_image` | `"<C-v>"` | Prompt, insert | Paste an image from the clipboard |

> [!NOTE]
> `<C-CR>` requires a terminal that reports it — one implementing the kitty keyboard protocol, such as
> Ghostty, kitty, WezTerm or foot. `<C-s>` works everywhere, which is why both are bound by default.

Disabling one looks like this:

```lua
opts = {
  keymaps = {
    close = false,
    submit = { n = "<CR>", i = "<C-s>" },
  },
}
```

## Presentation

### icons

`"nerd" | "unicode"`, default `"nerd"`. `"nerd"` uses Nerd Font v3 codepoints; `"unicode"` falls back to
glyphs any font has.

### markdown.enabled

`boolean`, default `true`. The transcript's built-in decoration: shaded code blocks, bullets, horizontal
rules and quote bars. Turn it off if you render the transcript with something else, such as
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) — the transcript is a
plain markdown buffer, so other renderers work on it. See [Appearance](@/appearance.md).

### tool_output.max_lines

`integer`, default `40`. How many lines an expanded tool call shows before it is truncated.

## Sessions and history

### history.share

`boolean`, default `true`. Share prompt history with the Claude Code CLI through
`~/.claude/history.jsonl`, appending under the CLI's own lock so both can write. With this off, history is
per-Neovim and the CLI never sees it.

### sessions.idle_timeout

`integer | false`, default `15`. Minutes a background session may sit idle before its process is stopped.
Switching back to it, or sending to it, resumes it from disk with nothing lost. `false` never stops them.

## Shell

`!command` prompts run a shell command directly, without going through Claude. See [Usage](@/usage.md).

### shell.respond

`boolean`, default `true`. Whether Claude responds once the command exits. With `false`, the command and
its output are added to the conversation as context and nothing else happens.

### shell.max_output

`integer`, default `30000`. How many characters of the command's output are given to Claude.

## Environment

| Variable | |
|---|---|
| `CLAUDE_CONFIG_DIR` | Overrides `~/.claude` for the session store, settings and prompt history |
