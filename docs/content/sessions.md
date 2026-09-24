+++
title = "Sessions"
weight = 5
description = "The picker, the neo-tree sidebar, switching between conversations, idle suspension, and resuming from disk."
+++

Sessions are Claude Code's own, stored under `~/.claude/projects/`. A session started in the CLI shows up
here and vice versa, names included.

## The picker

`:Claude sessions` opens a picker of this project's sessions: title, when it was last used, and a preview
of the most recent exchanges.

| Key | |
|---|---|
| Type | Filter |
| <kbd>C-n</kbd> / <kbd>C-p</kbd>, or arrows | Move |
| <kbd>CR</kbd> | Switch to, or resume, the session |
| <kbd>C-a</kbd> | Start a new session |
| <kbd>C-r</kbd> | Rename |
| <kbd>C-x</kbd> | Delete, after confirming. A session open in this Neovim is closed first; one open in another Claude Code process can't be deleted |
| <kbd>C-g</kbd> | Toggle between this project and all projects |

Markers show sessions open in this Neovim (`●` running, `○` suspended), ones waiting on you, and ones open
in another Claude Code process (`◆`).

## The sidebar (neo-tree)

With [neo-tree](https://github.com/nvim-neo-tree/neo-tree.nvim), sessions can also live in a sidebar, grouped
by project, the way Claude Desktop lists them. Add the source to neo-tree's `sources` (listing every source
you use, since setting `sources` replaces the defaults):

```lua
require("neo-tree").setup({
  sources = { "filesystem", "buffers", "git_status", "claude-code.neo-tree" },
  claude_sessions = {
    sessions_per_page = 50, -- per project, before a "Show more" row
  },
})
```

Then `:Neotree claude_sessions` (or `:Neotree toggle claude_sessions`) opens it in the file tree's place;
with neo-tree's `source_selector`, it gets a tab next to Files. The current project is listed first and
expanded. Other projects load their sessions when expanded.

| Key | |
|---|---|
| <kbd>CR</kbd> | Open the session, or expand/collapse a project |
| <kbd>a</kbd> | Start a session in the project under the cursor (named, or leave it empty) |
| <kbd>r</kbd> | Rename |
| <kbd>d</kbd> | Delete, after confirming (same rules as the picker) |
| <kbd>R</kbd> | Re-read everything from disk |
| <kbd>/</kbd> | Filter the loaded sessions by words in their title, first prompt or branch |
| <kbd>C-x</kbd> | Clear the filter |
| <kbd>C</kbd> / <kbd>z</kbd> | Collapse a project / all projects |

neo-tree's other defaults (`q`, `?`, `<`/`>`, `e`) work as usual; file operations are switched off.

A session opens where the chat already is: in place of the chat you opened with `:Claude here`, or in the
sidebar. With no chat showing, it takes over the last window if that's empty, and opens the sidebar
otherwise. Rows carry the picker's markers, and a collapsed project shows the most pressing one among its
open sessions. The tree follows changes on disk, such as a session started from the CLI, within a couple of
seconds.

## Switching

Switching keeps the sidebar where it is. The session you left keeps running in the background, streaming
into its own transcript, so you can come back to a finished turn.

`:Claude next` and `:Claude prev` cycle through the sessions open in this Neovim without the picker.

A new session you leave untouched is only a placeholder: switching to another session from anywhere (the
picker, the sidebar, `:Claude next`, `:Claude new`) closes it, and it disappears from the lists. It counts
as used, and stays, once it has a name, a message or shell command in its transcript, or a draft in its
prompt.

## Suspending and resuming

A background session that stays idle for [`sessions.idle_timeout`](@/configuration.md#sessions-idle-timeout)
minutes has its process stopped. Switching back to it, or sending to it, resumes it; nothing is lost.

Resuming a session from disk redraws its conversation — the last 200 messages.

> [!WARNING]
> If a session is still open in another Claude Code process, resuming it warns you, since both would be
> writing to the same transcript.

## Names

A new session's name is saved to disk after its first turn, and unnamed sessions pick up Claude Code's
generated title. `:Claude rename [name]` renames the current one, and <kbd>C-r</kbd> does it from the
picker.

## Sessions open elsewhere

Sessions open in another Claude Code process are detected from the CLI's process registry in
`~/.claude/sessions/`, on a best-effort basis. That is also what drives the `◆` marker in the picker and the
sidebar.
