+++
title = "Usage"
weight = 3
description = "The chat, the prompt, slash commands, images, and running shell commands yourself."
+++

## The chat

`:Claude` opens a sidebar with the conversation on top and a floating prompt at the bottom. Type and press
<kbd>C-CR</kbd> or <kbd>C-s</kbd> in insert mode, or <kbd>CR</kbd> in normal mode, to send. The prompt's
border shows what Claude is doing, the model, and the session cost.

- In the transcript, <kbd>i</kbd>, <kbd>a</kbd> and <kbd>o</kbd> jump to the prompt, <kbd>Tab</kbd> or
  <kbd>CR</kbd> on a tool call expands its output (or an edit's diff), and <kbd>q</kbd> hides the chat.
- `:q` in any of the chat's windows closes the whole sidebar. The session keeps running.
- `:Claude here` opens the chat in the current window instead of a sidebar, so `nvim +"Claude here"` gives
  you a Neovim that is just Claude — `:q` in the chat then quits. Switching sessions stays in that window,
  and hiding the chat gives the window back.

## Prompt history

<kbd>Up</kbd> and <kbd>Down</kbd> on the first or last line of the prompt step through earlier prompts for
this project, including ones typed in the Claude Code CLI. The current session's prompts come first.

This is the same `~/.claude/history.jsonl` the CLI uses, written under the CLI's lock, so the two stay in
sync. Turn it off with [`history.share = false`](@/configuration.md#history-share).

## Prompt suggestions

After a turn, Claude Code may suggest what you would send next. It appears in the empty prompt, and
<kbd>Tab</kbd> takes it — to send as is, or to edit first. Typing anything else ignores it.

Suggestions are not offered on a session's first turn or in plan mode. Disable them with
[`prompt_suggestions = false`](@/configuration.md#prompt-suggestions), or with
`promptSuggestionEnabled: false` in Claude Code's settings.

## Slash commands

Typing `/` at the start of the prompt opens a menu of slash commands, skills and plugin commands — Claude
Code's list for this session, minus the ones tied to its terminal UI — filtered fuzzily as you type.
<kbd>Tab</kbd> completes and <kbd>Up</kbd>/<kbd>Down</kbd> move. Output of built-in commands like
`/context` appears in the transcript.

nvim-cmp and blink.cmp are paused in the prompt while you type a command, so you only ever see one menu.

Sending `/exit`, `/quit` or `exit` ends the session, as in the CLI. If Neovim has nothing else open — only
empty buffers — it then moves on to your other open session, or quits Neovim when there isn't one, so a
`nvim +"Claude here"` exits the way the CLI does. With files open, it just closes the chat.

## Images

<kbd>C-v</kbd> in the prompt pastes an image from the clipboard. A terminal can only paste text, so, like
the CLI, the plugin asks the OS directly: `osascript` on macOS, `wl-paste` or `xclip` on Linux.

Pasting or dragging in a path to a PNG, JPEG, GIF or WebP file attaches it too, as does
`:Claude image <path>`. Each shows as an `[Image #N]` placeholder in the prompt; delete the placeholder to
drop the image.

Images larger than the API accepts are shrunk first, with `sips` on macOS or ImageMagick elsewhere.

## Running a command yourself

`!command` runs a shell command as in the CLI's bash mode: in the session's directory, without going
through Claude and without a permission prompt.

It shows in the transcript like a tool call — <kbd>Tab</kbd> expands the output — and the command and its
output are added to the conversation. When it exits, Claude responds; interrupt it with <kbd>C-c</kbd> and
it is kept as context only. Running one while Claude is working adds it as context for Claude's next step.

Both behaviours are configurable: see [`shell.respond`](@/configuration.md#shell-respond) and
[`shell.max_output`](@/configuration.md#shell-max-output).
