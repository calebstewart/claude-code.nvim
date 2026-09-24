+++
title = "Overview"
sort_by = "weight"
template = "index.html"
page_template = "page.html"
+++

`claude-code.nvim` runs Claude Code inside Neovim without a terminal emulator. Instead of embedding the
CLI in a `:terminal` buffer and letting it draw, the plugin drives the
[Claude Agent SDK](https://github.com/anthropics/claude-agent-sdk-typescript) directly and renders the
conversation itself: a native chat sidebar, tool calls you can expand, permission prompts as cards under
the call that raised them, and a session picker.

> [!NOTE]
> Early days: expect rough edges.

## Why not a terminal wrapper

Because the rendering is native, the things you would normally lose in a terminal split come back. Tool
output folds. Diffs render as diffs. Permission requests are Neovim UI rather than keystrokes sent to a
pty. Plans open in a real buffer you can edit before approving, and your edits are what Claude receives.

## Sessions are Claude Code's sessions

The plugin does not keep its own conversation store. Sessions live where Claude Code puts them, under
`~/.claude/projects/`, so a session you started in the CLI shows up in the picker here — names included —
and one you start here resumes in the CLI. Prompt history is shared through `~/.claude/history.jsonl`,
appended under the same lock the CLI uses, so <kbd>Up</kbd> in the prompt walks back through prompts you
typed in either place.

## Quick start

```lua
{
  "calebstewart/claude-code.nvim",
  cmd = "Claude",
  opts = {},
}
```

Then `:Claude`. The sidecar ships prebuilt, so there is no build step; `:checkhealth claude-code` verifies
the pieces. See [Installation](@/installation.md) for requirements, other plugin managers and the Nix
flake, and [Configuration](@/configuration.md) for every option.

## Where to go next

- [Usage](@/usage.md) — the chat, slash commands, images, and `!command` shell mode.
- [Permissions](@/permissions.md) — permission modes, approval cards, questions and plans.
- [Sessions](@/sessions.md) — the picker, switching, suspending and resuming.
- [Commands](@/commands.md) — every `:Claude` subcommand and its Lua equivalent.
- [Appearance](@/appearance.md) — the highlight groups and how colors are derived.
- [Architecture](@/architecture.md) — the sidecar, and the Node-free direct transport.
- [Lua Agent SDK](@/agent-sdk.md) — the standalone port of the Agent SDK that the direct transport uses.
