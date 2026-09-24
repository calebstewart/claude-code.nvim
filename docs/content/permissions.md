+++
title = "Permissions"
weight = 4
description = "Permission modes, approval cards, questions, plans, and subagents."
+++

## Modes

The prompt's bottom border shows the current mode when it isn't the default — `⏵⏵ accept edits`,
`⏸ plan mode`, `⏵ auto mode`, and so on.

<kbd>S-Tab</kbd> cycles default → accept edits → plan → auto, like the CLI's shift+tab. `:Claude mode
[mode]` sets any mode, or offers a list when given none. Modes changed by Claude Code itself — leaving plan
mode, for instance — are reflected too, and a session keeps its mode when suspended and resumed.

| Mode | |
|---|---|
| `default` | Ask before every tool that needs permission |
| `acceptEdits` | Auto-approve file edits and simple file operations in the project; other shell commands still ask |
| `plan` | Research and plan only; no edits until the plan is approved |
| `auto` | Claude Code's classifier approves actions it judges safe |
| `dontAsk` | Claude Code's "don't ask" mode. Outside the `<S-Tab>` cycle |
| `bypassPermissions` | Skip permission checks entirely. Starting mode only |

New sessions start in [`permission_mode`](@/configuration.md#permission-mode) if you set one, otherwise in
`permissions.defaultMode` from your Claude Code settings.

> [!WARNING]
> `bypassPermissions` can only be a session's starting mode, because the SDK requires it to be chosen up
> front. Set it with `permission_mode` in `setup()`; you cannot switch into it at runtime.

## When Claude needs you

### Permission requests

A card appears under the tool call that raised it:

| Key | |
|---|---|
| <kbd>y</kbd> | Allow, once |
| <kbd>a</kbd> | Always allow — applies Claude Code's suggested rule |
| <kbd>n</kbd> | Deny |

### Questions

`AskUserQuestion` opens a dialog: the question on top, options on the left, the highlighted option's
description and preview on the right, and a notes box below.

| Key | |
|---|---|
| A number, or <kbd>CR</kbd> | Choose the option |
| Numbers, or <kbd>Tab</kbd>, then <kbd>CR</kbd> | Toggle and confirm, for multi-select questions |
| <kbd>n</kbd> | Attach a note to your answer |
| <kbd>o</kbd> | Answer in your own words instead |
| <kbd>c</kbd> | "Chat about this" rather than answering |
| <kbd>Esc</kbd> | Decline the questions |

### Plans

Leaving plan mode produces a card with the plan:

| Key | |
|---|---|
| <kbd>o</kbd> | Open the plan's markdown file in a window beside the chat |
| <kbd>a</kbd> | Approve and switch to accept edits |
| <kbd>y</kbd> | Approve, but keep reviewing each edit |
| <kbd>n</kbd> | Keep planning, optionally with feedback |

Edits you make to the plan — saved or not — are what Claude receives on approval.

> [!NOTE]
> If any of this happens in a session you are not looking at, you get a notification, and the card or
> dialog appears when you switch to that session.

## Subagents

When Claude launches a subagent with the Agent tool, its line in the transcript shows what it is doing
while it runs (`⎿ Running … · 3 tools · 12s`), then a summary when it finishes. <kbd>Tab</kbd> on the line
expands it: the subagent's own tool calls with their status, followed by its report.

Permission requests from a subagent appear under its line and say which subagent is asking.

Background subagents keep their line running after Claude moves on. The prompt's border shows how many are
still going, and a note appears in the transcript when one finishes.
