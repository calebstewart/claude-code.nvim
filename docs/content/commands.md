+++
title = "Commands"
weight = 6
description = "The :Claude subcommands and the matching Lua API."
+++

## :Claude

`:Claude` takes a subcommand; with none, it opens the chat. Completion covers the subcommands, file paths
after `image`, mode names after `mode`, the project's `wt` tree names and branches after `work`, and its tree
names after `trees`.

| Command | |
|---|---|
| `:Claude` / `:Claude open` | Open the chat and focus the prompt, starting a session if needed |
| `:Claude toggle` | Show or hide the chat |
| `:Claude here` | Open the chat in the current window (e.g. `nvim +"Claude here"`) |
| `:Claude send [text]` | Send `text`, or just focus the prompt |
| `:Claude interrupt` | Stop the turn in progress |
| `:Claude send-now` | Interrupt Claude and send the [queued messages](@/usage.md#queueing-messages) right away |
| `:Claude sessions` | Pick a session to switch to or resume |
| `:Claude new [name]` | Start a new session (asks for a name if none is given; leave it empty for none) |
| `:Claude work [text]` | Get a [`wt` tree](@/configuration.md#working-on-something-in-a-tree) for a story id, branch or description, creating it or claiming the existing one, and open a session in it (asks if no text is given) |
| `:Claude trees [name]` | Pick one of the project's [`wt` trees](@/configuration.md#picking-a-tree) to open or resume a session in, claim, release or remove. `name` pre-fills the search |
| `:Claude rename [name]` | Rename the current session (asks if no name is given) |
| `:Claude relocate [dir]` | Move the current session to another working directory (asks if none is given). See [moved directories](@/sessions.md#moved-or-deleted-directories) |
| `:Claude next` / `:Claude prev` | Cycle through the sessions open in this Neovim |
| `:Claude mode [mode]` | Set the current session's permission mode (pick from a list if none is given) |
| `:Claude image <path>` | Attach an image file to the prompt |
| `:Claude deliver` | Deliver the [held messages](@/sessions.md#held-messages) from other sessions to the current session's Claude |
| `:Claude stop` | End the current session and close it (resume it later from the picker) |

## Lua API

Every subcommand has a Lua equivalent on `require("claude-code")`, which is what you want for keymaps that
need arguments or conditions.

| Function | |
|---|---|
| `setup(opts?)` | Apply [configuration](@/configuration.md). Optional — the plugin registers `:Claude` on its own |
| `open()` | Open or focus the chat, starting a session if there isn't one |
| `here()` | Open the chat in the current window instead of a sidebar |
| `toggle()` | Show or hide the chat |
| `send(text?)` | Send a prompt; with no text, focus the prompt instead |
| `interrupt()` | Interrupt the turn in progress |
| `send_now()` | Interrupt Claude and send the queued messages right away |
| `stop()` | End the current session and close it. It stays on disk |
| `sessions()` | Open the session picker |
| `new(name?)` | Start a new session. With no name, asks for one |
| `work(text?, opts?)` | Get a `wt` tree for `text` and open a session in it. With no text, asks for it. `opts.cwd` picks the project (default: Neovim's cwd) |
| `trees(query?)` | Open the `wt` tree picker, with `query` in its search |
| `rename(name?)` | Rename the current session. With no name, asks for one |
| `relocate(dir?)` | Move the current session to another working directory. With no directory, asks for one |
| `mode(mode?)` | Set the permission mode. With no mode, pick one from a list |
| `image(path)` | Attach an image file to the prompt, opening the chat if needed |
| `deliver()` | Deliver the current session's held messages from other sessions |
| `next()` / `prev()` | Switch to the next or previous session open in this Neovim |
| `worktree()` | The current session's [`wt` tree](@/configuration.md#worktrees) (`{ name, slot, branch, path }`) or `nil`, for statuslines. Never runs `wt` |

```lua
vim.keymap.set("n", "<leader>cc", require("claude-code").toggle, { desc = "Claude: toggle chat" })

vim.keymap.set("v", "<leader>ce", function()
  require("claude-code").send("Explain this selection")
end, { desc = "Claude: explain selection" })
```

The plugin does not create any mappings itself, so nothing is taken from you by installing it.
