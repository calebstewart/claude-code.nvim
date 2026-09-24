# claude-code.nvim

Claude Code inside Neovim, driven by the [Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-typescript)
rather than a terminal emulator: a native chat sidebar, inline permission prompts, and sessions you can switch
between, all shared with the Claude Code CLI.

> Early days: expect rough edges.

**[Documentation](https://calebstew.art/claude-code.nvim)** — installation, every configuration option, and the
Lua Agent SDK port.

## Requirements

- Neovim 0.10+
- Node 18+ (not needed with `transport = "direct"`; see [Architecture](#architecture))
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and logged in (`claude` on `$PATH`)
- Optional: a [Nerd Font](https://www.nerdfonts.com/) for icons (or set `icons = "unicode"`)

## Install (lazy.nvim)

```lua
{
  "calebstewart/claude-code.nvim",
  cmd = "Claude",
  opts = {},
}
```

The sidecar ships prebuilt in `dist/`, so there is no build step. Run `:checkhealth claude-code` to verify.

The plugin doesn't create global keymaps; bind the commands you want. With lazy.nvim, `keys` also defers loading
until the first press:

```lua
{
  "calebstewart/claude-code.nvim",
  cmd = "Claude",
  keys = {
    { "<leader>cc", "<cmd>Claude toggle<cr>", desc = "Claude: toggle chat" },
    { "<leader>cs", "<cmd>Claude sessions<cr>", desc = "Claude: sessions" },
    { "<leader>cn", "<cmd>Claude new<cr>", desc = "Claude: new session" },
  },
  opts = {},
}
```

### Nix

The repository is a flake. Its package is the plugin with Node.js from Nix baked in as the default `node`, so
nothing needs to be on `$PATH` except `claude`.

```nix
{
  inputs.claude-code-nvim = {
    url = "github:calebstewart/claude-code.nvim";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Outputs: `packages.<system>.default`, `overlays.default` (adds `pkgs.vimPlugins.claude-code-nvim`), and a
`devShells.<system>.default` for working on the plugin.

With Home Manager's Neovim module:

```nix
programs.neovim.plugins = [ inputs.claude-code-nvim.packages.${pkgs.system}.default ];
```

With lazy.nvim, point `dir` at the package's store path (for example by writing it into a Lua file your config
reads):

```lua
{
  dir = "/nix/store/…-vimplugin-claude-code.nvim-…", -- "${inputs.claude-code-nvim.packages.${pkgs.system}.default}"
  name = "claude-code.nvim",
  cmd = "Claude",
  opts = {},
}
```

## Configuration

Defaults:

```lua
{
  node = "node",             -- Node executable used to run the sidecar (unused when transport = "direct")
  transport = "sidecar",     -- "sidecar": everything goes through Node and the Agent SDK
                             -- "direct":  Neovim drives `claude` itself and reads transcripts in Lua,
                             --            so Node is never started (experimental; see Architecture)
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

## Usage

### Chat

`:Claude` opens a sidebar with the conversation on top and a floating prompt at the bottom. Type and press
`<C-CR>` or `<C-s>` (insert mode), or `<CR>` (normal mode), to send. The prompt's border shows what Claude is
doing, the model and the session cost.

- `<Up>`/`<Down>` on the first/last line of the prompt step through earlier prompts for this project, including
  ones typed in the Claude Code CLI. The current session's prompts come first.
- After a turn, Claude Code may suggest what you'd send next; it shows in the empty prompt, and `<Tab>` takes it
  (to send as is or edit). Typing anything else ignores it. Not offered on a session's first turn or in plan
  mode; `prompt_suggestions = false` (or `promptSuggestionEnabled: false` in Claude Code's settings) turns it off.
- In the transcript, `i`/`a`/`o` jump to the prompt, `<Tab>`/`<CR>` on a tool call expand its output (or an
  edit's diff), and `q` hides the chat.
- `:q` in any of the chat's windows closes the whole sidebar; the session keeps running.
- `:Claude here` opens the chat in the current window instead of a sidebar, so `nvim +"Claude here"` gives
  you a Neovim that's just Claude (`:q` in the chat then quits). Switching sessions stays in that window, and
  hiding the chat gives the window back.
- Typing `/` at the start of the prompt opens a menu of slash commands, skills and plugin commands (Claude
  Code's list for the session, minus ones tied to its terminal UI), filtered fuzzily as you type. `<Tab>`
  completes, `<Up>`/`<Down>` move. Output of built-in commands like `/context` appears in the transcript.
  nvim-cmp and blink.cmp are paused in the prompt while you type a command, so only one menu shows.
- **Images:** `<C-v>` in the prompt pastes an image from the clipboard (a terminal can only paste text, so, like
  the CLI, the plugin asks the OS for it: `osascript` on macOS, `wl-paste` or `xclip` on Linux). Pasting or
  dragging in a path to a PNG, JPEG, GIF or WebP file attaches it too, as does `:Claude image <path>`. Each
  shows as an `[Image #N]` placeholder; delete it to drop the image. Images larger than the API accepts are
  shrunk first (with `sips` on macOS, or ImageMagick).
- `!command` runs a shell command yourself, as in the CLI's bash mode: in the session's directory, without
  going through Claude or a permission prompt. It shows in the transcript like a tool call (`<Tab>` expands the
  output), and the command and output are added to the conversation. When it exits Claude responds; stop it
  with `<C-c>` and it's only kept as context. Running one while Claude is working adds it as context for
  Claude's next step.
- Sending `/exit`, `/quit` or `exit` ends the session, as in the CLI. If Neovim has nothing else open (only
  empty buffers), it then moves on to your other open session, or quits Neovim when there isn't one, so a
  `nvim +"Claude here"` exits like the CLI. With files open, it just closes the chat.

### Permission modes

The prompt's bottom border shows the current mode when it isn't the default (`⏵⏵ accept edits`,
`⏸ plan mode`, `⏵ auto mode`, …). `<S-Tab>` cycles default → accept edits → plan → auto, like the CLI's
shift+tab, and `:Claude mode [mode]` sets any mode (or pick one from a list). Modes changed by Claude Code
itself, such as leaving plan mode, are reflected too, and a session keeps its mode when it's suspended and
resumed.

New sessions start in `permission_mode` if you set one, otherwise in `permissions.defaultMode` from your Claude
Code settings (`.claude/settings.local.json`, `.claude/settings.json`, then `~/.claude/settings.json`).

As in the CLI, accept edits only auto-approves file edits and simple file operations in the project; other
shell commands still ask. Auto mode lets Claude Code's classifier approve safe actions.

`bypassPermissions` can only be a session's starting mode (the SDK requires it to be chosen up front), so set
it with `permission_mode` in `setup()`.

### When Claude needs you

- **Permission requests** appear as a card under the tool call: `y` allow, `a` always allow (applies Claude Code's
  suggested rule), `n` deny.
- **Questions** (`AskUserQuestion`) open a dialog: the question on top, options on the left, the highlighted
  option's description and preview on the right, and a notes box below. Press a number or `<CR>` to choose
  (for multi-select: numbers or `<Tab>` toggle, `<CR>` confirms), `n` to attach a note to your answer, `o` to
  answer in your own words, and `c` to "chat about this" instead. `<Esc>` declines the questions.
- **Plans** (leaving plan mode) appear as a card with the plan: `o` opens the plan's markdown file in a window
  beside the chat for review, `a` approves and switches to accept edits, `y` approves and keeps reviewing each
  edit, `n` keeps planning (optionally with feedback). Edits you make to the plan, saved or not, are what
  Claude gets on approval.

If this happens in a session you're not looking at, you get a notification, and the card or dialog appears when
you switch to that session.

### Subagents

When Claude launches a subagent (the Agent tool), its line in the transcript shows what it's doing while it
runs (`⎿ Running … · 3 tools · 12s`), then a summary when it's done. `<Tab>` on the line expands it: the
subagent's own tool calls with their status, followed by its report. Permission requests from a subagent
appear under its line and say which subagent is asking.

Background subagents keep their line running after Claude moves on; the prompt's border shows how many are
still running, and a note appears in the transcript when one finishes.

### Sessions

Sessions are Claude Code's own, stored under `~/.claude/projects/`, so sessions started in the CLI show up here
and vice versa, names included.

- `:Claude sessions` opens a picker of this project's sessions: title, when it was last used, and a preview of
  the most recent exchanges. Type to filter; `<C-n>`/`<C-p>` (or arrows) move, `<CR>` switches to or resumes
  the session, `<C-a>` starts a new one, `<C-r>` renames, `<C-x>` deletes (after confirming), and `<C-g>`
  toggles between this project and all projects. Markers show sessions open in this Neovim (`●` running,
  `○` suspended), ones waiting on you, and ones open in another Claude Code process (`◆`).
- Switching keeps the sidebar where it is. The session you left keeps running in the background, streaming
  into its transcript.
- A background session that stays idle for `sessions.idle_timeout` minutes has its process stopped. Switching
  back (or sending to it) resumes it; nothing is lost.
- Resuming a session from disk redraws its conversation (the last 200 messages). If it's still open in another
  Claude Code process you get a warning, since both would write to it.
- A new session's name is saved to disk after its first turn. Unnamed sessions pick up Claude Code's generated
  title.

### Commands

| Command | |
|---|---|
| `:Claude` / `:Claude open` | Open the chat and focus the prompt, starting a session if needed |
| `:Claude toggle` | Show or hide the chat |
| `:Claude here` | Open the chat in the current window (e.g. `nvim +"Claude here"`) |
| `:Claude send [text]` | Send `text` (or just focus the prompt) |
| `:Claude interrupt` | Stop the turn in progress |
| `:Claude sessions` | Pick a session to switch to or resume |
| `:Claude new [name]` | Start a new session (asks for a name if none is given; leave it empty for none) |
| `:Claude rename [name]` | Rename the current session (asks if no name is given) |
| `:Claude next` / `:Claude prev` | Cycle through the sessions open in this Neovim |
| `:Claude mode [mode]` | Set the current session's permission mode (pick from a list if none is given) |
| `:Claude image <path>` | Attach an image file to the prompt |
| `:Claude stop` | End the current session and close it (resume it later from the picker) |

The same actions are available from Lua: `require("claude-code").sessions()`, `.new(name)`, `.rename(name)`,
`.next()`, and so on.

### Appearance

Colors are derived from your colorscheme (and work with transparent backgrounds). Every highlight group is prefixed
`ClaudeCode` and can be overridden; see `lua/claude-code/ui/highlights.lua`.

The transcript (`claude-code-chat`), prompt (`claude-code-prompt`) and the spacer under the prompt
(`claude-code-dock`) have their own filetypes, e.g. for your statusline plugin's `disabled_filetypes`.

## Architecture

```
                  ┌─▶ dist/sidecar.mjs            (one per session: Agent SDK) ──▶ claude
Neovim (Lua) ─────┤
  NDJSON / stdio  └─▶ dist/sidecar.mjs --control  (one: list/read/rename/delete sessions)
```

- **Sidecar** (`sidecar/src/`): `session.ts` runs one conversation and forwards raw SDK messages, so rendering
  decisions live in Lua; `control.ts` handles session bookkeeping without starting Claude. The line protocol is
  defined in `protocol.ts`.
- **Lua core** (`lua/claude-code/`): `sidecar.lua` spawns sidecars and frames the protocol; `transport.lua`
  picks between it and the direct transport in `cli.lua`; `control.lua` answers the picker's requests from
  whichever store the transport implies; `session.lua` is one conversation (its chat, its process, suspend
  and resume, replaying history); `sessions.lua` tracks the sessions open in Neovim, switching and idle
  suspension; `history.lua` reads and writes the shared prompt history.
- **Lua Agent SDK** (`lua/claude-agent-sdk/`): a standalone port of the Agent SDK, used by the direct
  transport and reusable on its own — see [Direct transport](#direct-transport-experimental).
- **UI** (`lua/claude-code/ui/`): `chat.lua` (layout, keymaps, status), `transcript.lua` (append-only markdown
  buffer; headers, tool status, output and footers are extmarks so the text stays plain markdown), `prompt.lua`,
  `permission.lua` (permission cards), `question.lua` (question dialog), `sessions.lua` (session picker),
  `input.lua`, `markdown.lua` (decoration provider), `tools.lua`, `welcome.lua`, `icons.lua` and
  `highlights.lua`.

The Agent SDK normally brings its own platform-specific Claude binary, which can't be bundled into a single
file, so the sidecar runs the user's installed `claude` via `pathToClaudeCodeExecutable`.

### Direct transport (experimental)

`transport = "direct"` removes Node entirely — nothing spawns it, and `:checkhealth` stops requiring it:

```
Neovim (Lua) ──▶ claude          (lua/claude-agent-sdk)
```

The Agent SDK is a thin wrapper: it builds an argv, spawns `claude` with `--input-format stream-json
--output-format stream-json`, and pumps newline-delimited JSON over stdio, with conversation messages and a
bidirectional control channel sharing the one stream. `lua/claude-agent-sdk/` is a Lua port of it — usable on
its own, independent of this plugin — laid out along the same seams:

| File | Role |
| --- | --- |
| `options.lua` | options → `claude` argv and environment |
| `transport.lua` | process lifecycle and newline-delimited JSON framing |
| `control.lua` | `control_request`/`control_response` in both directions |
| `query.lua` | message demultiplexing, the handshake, and the control methods |
| `sessions.lua` | the session store: transcripts under `~/.claude/projects` |

`query.lua` covers the SDK's imperative surface — `interrupt`, `set_permission_mode`, `set_model`,
`get_context_usage`, `get_usage`, `read_file`, `rewind_files`, `mcp_*`, `reload_*`, and the rest — with
`query:request(subtype, params, cb)` as the escape hatch for anything unwrapped. `sessions.lua` replaces the
`--control` sidecar: it reads and writes the JSONL transcripts directly, so the session picker, history replay
and `/rename` need no Claude process and no Node. `claude-code/cli.lua` adapts the query to the same events
`sidecar.lua` emits, and `claude-code/control.lua` routes the picker to whichever store the transport implies,
so `session.lua` is indifferent to the choice.

The caveat is unchanged: the control-channel subtypes and the on-disk transcript format are not published APIs
the way the CLI flags are, so they can shift between Claude Code releases with no compile-time warning. The
session store is verified against the Node implementation by differential test rather than by specification —
on every local transcript the two agree exactly, and where the SDK is self-inconsistent (a forked transcript,
where it returns a rewound branch's reply but not the prompt that caused it) this drops the rewound branch
cleanly instead. Control subtypes newer than the installed `claude` report an ordinary error rather than
hanging.

Shared state follows the CLI's conventions: prompt history is appended under the CLI's lock on
`history.jsonl`, and sessions open elsewhere are detected from the CLI's process registry in
`~/.claude/sessions/` (best effort).

## Development

`nix develop` gives you Node, Neovim and stylua.

```sh
cd sidecar
npm ci
npm run typecheck
npm run build   # writes ../dist/sidecar.mjs — commit it
```
