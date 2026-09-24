+++
title = "Commands"
weight = 6
description = "The :Claude subcommands and the matching Lua API."
+++

## :Claude

`:Claude` takes a subcommand; with none, it opens the chat. Completion covers the subcommands, file paths
after `image`, and mode names after `mode`.

| Command | |
|---|---|
| `:Claude` / `:Claude open` | Open the chat and focus the prompt, starting a session if needed |
| `:Claude toggle` | Show or hide the chat |
| `:Claude here` | Open the chat in the current window (e.g. `nvim +"Claude here"`) |
| `:Claude send [text]` | Send `text`, or just focus the prompt |
| `:Claude interrupt` | Stop the turn in progress |
| `:Claude sessions` | Pick a session to switch to or resume |
| `:Claude new [name]` | Start a new session (asks for a name if none is given; leave it empty for none) |
| `:Claude rename [name]` | Rename the current session (asks if no name is given) |
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
| `stop()` | End the current session and close it. It stays on disk |
| `sessions()` | Open the session picker |
| `new(name?)` | Start a new session. With no name, asks for one |
| `rename(name?)` | Rename the current session. With no name, asks for one |
| `mode(mode?)` | Set the permission mode. With no mode, pick one from a list |
| `image(path)` | Attach an image file to the prompt, opening the chat if needed |
| `deliver()` | Deliver the current session's held messages from other sessions |
| `next()` / `prev()` | Switch to the next or previous session open in this Neovim |

```lua
vim.keymap.set("n", "<leader>cc", require("claude-code").toggle, { desc = "Claude: toggle chat" })

vim.keymap.set("v", "<leader>ce", function()
  require("claude-code").send("Explain this selection")
end, { desc = "Claude: explain selection" })
```

The plugin does not create any mappings itself, so nothing is taken from you by installing it.
