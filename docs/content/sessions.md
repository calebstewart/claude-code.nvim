+++
title = "Sessions"
weight = 5
description = "The picker, switching between conversations, idle suspension, and resuming from disk."
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

## Switching

Switching keeps the sidebar where it is. The session you left keeps running in the background, streaming
into its own transcript, so you can come back to a finished turn.

`:Claude next` and `:Claude prev` cycle through the sessions open in this Neovim without the picker.

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
`~/.claude/sessions/`, on a best-effort basis. That is also what drives the `◆` marker in the picker.
