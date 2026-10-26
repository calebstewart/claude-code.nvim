+++
title = "Custom tools"
weight = 5
description = "Lua functions Claude can call, running inside Neovim."
+++

A custom tool is a Lua function that Claude can call like any of its own tools. It runs inside Neovim, so
it can do anything your config can: read buffers, ask the LSP, open a file, fill the quickfix list.

> [!NOTE]
> Custom tools need [`transport = "direct"`](@/configuration.md#transport) for now. The sidecar transport
> doesn't serve them yet. With tools defined there, the plugin warns once and `:checkhealth claude-code`
> lists them as unserved.

## Defining a tool

Put tools in the [`tools`](@/configuration.md#tools) option:

```lua
opts = {
  transport = "direct",
  tools = {
    {
      name = "list_buffers",
      description = "List the files open in the user's Neovim, with their modified state.",
      annotations = { readOnlyHint = true },
      handler = function()
        local out = {}
        for _, buf in ipairs(vim.api.nvim_list_bufs()) do
          if vim.bo[buf].buflisted and vim.api.nvim_buf_get_name(buf) ~= "" then
            table.insert(out, { path = vim.api.nvim_buf_get_name(buf), modified = vim.bo[buf].modified })
          end
        end
        return out
      end,
    },
  },
}
```

Or register them from anywhere, such as another plugin:

```lua
require("claude-code").register_tool({
  name = "diagnostics",
  description = "LSP diagnostics (errors, warnings) for a file open in the user's editor.",
  annotations = { readOnlyHint = true },
  input_schema = {
    type = "object",
    properties = {
      path = { type = "string", description = "Absolute path of the file" },
    },
    required = { "path" },
  },
  handler = function(input)
    local buf = vim.fn.bufnr(input.path)
    if buf == -1 then
      error("not open in the editor: " .. input.path, 0)
    end
    return vim.tbl_map(function(d)
      return { line = d.lnum + 1, severity = vim.diagnostic.severity[d.severity], message = d.message }
    end, vim.diagnostic.get(buf))
  end,
})
```

`unregister_tool(name)` removes one. A registered tool replaces a tool of the same name in the `tools` option.

| Field | |
|---|---|
| `name` | 1–64 letters, digits, `_` or `-`. Claude sees it as `mcp__nvim__<name>` |
| `description` | What the tool does and when to use it. This is all Claude has to go on, so be specific |
| `input_schema` | JSON Schema for the arguments, an object schema. Omit it for a tool that takes none |
| `handler` | `fun(input, ctx, done)`; see [below](#handlers) |
| `title` | Optional human-readable name |
| `annotations` | Optional MCP hints: `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` |

Tools are read when a session's process starts. A tool added later reaches new sessions, and existing ones
the next time their process starts, for example after an [idle suspend](@/sessions.md#suspending-and-resuming).

> [!TIP]
> An empty Lua table encodes as a JSON array. The plugin fixes this for `input_schema.properties`. Anywhere
> else in a schema that must be an empty object, use `vim.empty_dict()`.

## Handlers

Handlers run on the main loop, so the whole Neovim API is available. There are two ways to return a result:

- **Return it.** This works for anything that finishes straight away.
- **Return nothing, and call `done(result)` later**, exactly once. Use this for work that waits on a callback,
  such as an LSP request or `vim.system`.

```lua
handler = function(input, ctx, done)
  vim.system({ "git", "log", "-n", "5", "--oneline" }, { cwd = ctx.cwd, text = true }, function(res)
    done(res.stdout)
  end)
end
```

A result can be:

- a string, which Claude receives as text
- an MCP `CallToolResult`, `{ content = { { type = "text", text = "..." } }, is_error = true? }`, for images or
  several blocks
- any other value, which Claude receives as JSON

To report a failure, raise an error or call `done(nil, "message")`. Claude sees the message, and so do you,
in the tool call's output in the transcript.

`ctx` describes the call:

| Field | |
|---|---|
| `session_id` | The session calling the tool |
| `cwd` | The session's working directory |
| `tool_use_id` | The tool call's id in the transcript |
| `cancelled()` | Whether the call was withdrawn, for example because you interrupted Claude |
| `on_cancel(fn)` | Run `fn` when the call is withdrawn. A `done` after that is ignored |

## Permissions

Custom tools go through the same [permission prompts](@/permissions.md#permission-requests) as Claude's own
tools. To skip the prompt for a safe tool, allow it in your Claude Code settings:

```json
{
  "permissions": {
    "allow": ["mcp__nvim__list_buffers"]
  }
}
```

`mcp__nvim` on its own allows every custom tool.

## How it works

The tools are served by an in-process MCP server named `nvim`, built with the
[Lua Agent SDK](@/agent-sdk.md#in-process-mcp-servers). Claude Code relays the server's traffic over the
same stdio stream as the conversation, so there is no extra process and no socket.
