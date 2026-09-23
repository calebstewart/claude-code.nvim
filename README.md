# claude-code.nvim

Claude Code inside Neovim, driven by the [Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-typescript)
rather than a terminal emulator: a native chat sidebar, inline permission prompts, and sessions you can switch
between, all shared with the Claude Code CLI.

> Early days: expect rough edges.

## Requirements

- Neovim 0.10+
- Node 18+
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
  node = "node",             -- Node executable used to run the sidecar
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
  },
  icons = "nerd",            -- "nerd" (needs a Nerd Font) | "unicode"
  markdown = { enabled = true }, -- shaded code blocks, bullets, rules, quote bars; disable if you use render-markdown.nvim
  tool_output = { max_lines = 40 }, -- cap for expanded tool output
  history = { share = true }, -- share prompt history with the Claude Code CLI (~/.claude/history.jsonl)
  sessions = {
    idle_timeout = 15,       -- minutes before an idle background session's process is stopped; false to never
  },
}
```

## Usage

### Chat

`:Claude` opens a sidebar with the conversation on top and a floating prompt at the bottom. Type and press
`<C-CR>` or `<C-s>` (insert mode), or `<CR>` (normal mode), to send. The prompt's border shows what Claude is
doing, the model and the session cost.

- `<Up>`/`<Down>` on the first/last line of the prompt step through earlier prompts for this project, including
  ones typed in the Claude Code CLI. The current session's prompts come first.
- In the transcript, `i`/`a`/`o` jump to the prompt, `<Tab>`/`<CR>` on a tool call expand its output (or an
  edit's diff), and `q` hides the chat.
- `:q` in any of the chat's windows closes the whole sidebar; the session keeps running.
- Sending `/exit`, `/quit` or `exit` ends the session, as in the CLI (same as `:Claude stop`).

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

### Sessions

Sessions are Claude Code's own, stored under `~/.claude/projects/`, so sessions started in the CLI show up here
and vice versa, names included.

- `:Claude sessions` opens a picker of this project's sessions: title, when it was last used, and a preview of
  the most recent exchanges. Type to filter; `<C-n>`/`<C-p>` (or arrows) move, `<CR>` switches to or resumes
  the session, `<C-a>` starts a new one, `<C-r>` renames, and `<C-g>` toggles between this project and all
  projects. Markers show sessions open in this Neovim (`●` running, `○` suspended), ones waiting on you, and
  ones open in another Claude Code process (`◆`).
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
| `:Claude send [text]` | Send `text` (or just focus the prompt) |
| `:Claude interrupt` | Stop the turn in progress |
| `:Claude sessions` | Pick a session to switch to or resume |
| `:Claude new [name]` | Start a new session (asks for a name if none is given; leave it empty for none) |
| `:Claude rename [name]` | Rename the current session (asks if no name is given) |
| `:Claude next` / `:Claude prev` | Cycle through the sessions open in this Neovim |
| `:Claude mode [mode]` | Set the current session's permission mode (pick from a list if none is given) |
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
  NDJSON / stdio  └─▶ dist/sidecar.mjs --control  (one: list/read/rename sessions)
```

- **Sidecar** (`sidecar/src/`): `session.ts` runs one conversation and forwards raw SDK messages, so rendering
  decisions live in Lua; `control.ts` handles session bookkeeping without starting Claude. The line protocol is
  defined in `protocol.ts`.
- **Lua core** (`lua/claude-code/`): `sidecar.lua` spawns sidecars and frames the protocol; `control.lua` is the
  request/response client for control mode; `session.lua` is one conversation (its chat, its process, suspend
  and resume, replaying history); `sessions.lua` tracks the sessions open in Neovim, switching and idle
  suspension; `history.lua` reads and writes the shared prompt history.
- **UI** (`lua/claude-code/ui/`): `chat.lua` (layout, keymaps, status), `transcript.lua` (append-only markdown
  buffer; headers, tool status, output and footers are extmarks so the text stays plain markdown), `prompt.lua`,
  `permission.lua` (permission cards), `question.lua` (question dialog), `sessions.lua` (session picker),
  `input.lua`, `markdown.lua` (decoration provider), `tools.lua`, `welcome.lua`, `icons.lua` and
  `highlights.lua`.

The Agent SDK normally brings its own platform-specific Claude binary, which can't be bundled into a single
file, so the sidecar runs the user's installed `claude` via `pathToClaudeCodeExecutable`.

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
