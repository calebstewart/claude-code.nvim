+++
title = "Lua Agent SDK"
weight = 9
description = "A standalone Lua port of the Claude Agent SDK: what it is, how to drive a conversation, and how it reads Claude Code's session store."
+++

`lua/claude-agent-sdk/` is a Lua port of
[`@anthropic-ai/claude-agent-sdk`](https://github.com/anthropics/claude-agent-sdk-typescript). It powers
the plugin's [direct transport](@/architecture.md#direct-transport), but it does not depend on the plugin
in any way — you can `require("claude-agent-sdk")` from your own code and drive Claude Code from Neovim
without Node.

For the exhaustive option and method tables, see [SDK reference](@/agent-sdk-reference.md).

## Why a port is possible

The official SDK is a thin wrapper around the `claude` CLI. It builds an argv, spawns the binary with
`--input-format stream-json --output-format stream-json`, and pumps newline-delimited JSON over stdio.
Conversation messages and a bidirectional control channel share that one stream. There is no protocol logic
that needs a Node runtime — so this module does the same thing from Neovim and talks to `claude` directly.

The layout deliberately mirrors the TypeScript SDK's own seams, so the two can be read side by side:

| File | Mirrors | |
|---|---|---|
| `options.lua` | `ProcessTransport`'s arg builder | Options → `claude` argv and environment |
| `transport.lua` | `ProcessTransport` | Process lifecycle, NDJSON framing |
| `control.lua` | `Query`'s control plumbing | `control_request`/`control_response` in both directions |
| `query.lua` | `Query` | Message demultiplexing, the handshake, the imperative API |
| `sessions.lua` | `listSessions` and friends | The on-disk transcript store |

## Quick start

```lua
local sdk = require("claude-agent-sdk")

local query = sdk.query({
  cwd = vim.fn.getcwd(),
  system_prompt = { type = "preset", preset = "claude_code" },
  include_partial_messages = true,
  on_message = function(msg)
    vim.print(msg.type)
  end,
  can_use_tool = function(name, input, ctx, respond)
    respond({ behavior = "allow" })
  end,
})

query:send({ text = "hello" })
```

`sdk.query()` returns immediately. The process starts, the handshake runs, and messages arrive on
`on_message` from then on.

## The shape of the API

The TypeScript SDK models a conversation as an async generator you iterate. Lua has no equivalent, so this
port splits it in two:

- **Messages are pushed to callbacks.** `on_message` receives every conversation message;
  `on_ready`, `on_error` and `on_exit` cover the lifecycle.
- **The imperative half is methods.** Everything the TS SDK exposes on its `Query` object — `interrupt`,
  `set_permission_mode`, `set_model`, `get_usage`, and the rest — is a method on the returned object.

### Lifecycle

```lua
local query = sdk.query({
  on_ready = function(info)
    -- The handshake completed. `info` is the whole initialize response.
    vim.print(query:supported_models())
  end,
  on_message = function(msg) end,
  on_error = function(message) end,
  on_exit = function(code, stderr) end,
})

query:running()  -- is the process still up?
query:close()    -- finish the conversation and let the process exit
```

`close()` closes stdin first, then sends `SIGTERM` after 2 seconds, then `SIGKILL` after a further 5 — so a
wedged CLI still goes away.

Accessors like `supported_commands()`, `supported_models()`, `supported_agents()` and `account_info()` read
from the handshake response, so they return nothing useful until `on_ready` has fired.
`initialization_result()` returns the whole payload for anything without an accessor.

### Sending

```lua
query:send({ text = "explain this file" })
```

`send` also takes `content` (raw content blocks), `images` (which lead the content blocks), and
`should_query`:

```lua
-- Add context without starting a turn. The next `send` picks it up.
query:send({ text = "here is the failing test output: …", should_query = false })
```

Images are `{ media_type = "image/png", data = <base64> }`, with no `data:` prefix.

## Permissions

Pass `can_use_tool` and every tool call that needs permission is routed to you:

```lua
can_use_tool = function(tool_name, input, ctx, respond)
  if tool_name == "Read" then
    return respond({ behavior = "allow" })
  end
  vim.ui.select({ "allow", "deny" }, { prompt = tool_name }, function(choice)
    if choice == "allow" then
      -- Hand `ctx.suggestions` back to persist the CLI's proposed rule.
      respond({ behavior = "allow", updated_permissions = ctx.suggestions })
    else
      respond({ behavior = "deny", message = "not this time" })
    end
  end)
end
```

`respond` may be called asynchronously — that is the point, since a human is usually deciding. The context
carries what you need to render a prompt: `display_name`, `description`, `title`, `suggestions`,
`default_to_no` (approval should not be a single keystroke), `suppress_always_allow_rule`, `blocked_path`,
`agent_id` for subagent requests, and `on_cancel` to register a callback for when the CLI withdraws the
request.

> [!NOTE]
> Supplying `can_use_tool` implies `--permission-prompt-tool stdio`, so it is mutually exclusive with
> `permission_prompt_tool_name`. Passing both is an error.

## Control methods

Anything the CLI can be asked to do mid-conversation is a method. They are grouped in
[the reference](@/agent-sdk-reference.md#query-methods); the common ones:

```lua
query:interrupt({ cancel_queued = true })
query:set_permission_mode("plan")
query:set_model("opus")
query:get_context_usage(function(response, err)
  vim.print(response)
end)
```

Each method issues one `control_request` and takes an optional `callback(response, err)`. Fire-and-forget
is fine — with no callback the response is simply discarded.

For a subtype with no named wrapper — the CLI exposes roughly sixty, and they change between releases —
there is an escape hatch:

```lua
query:request("some_new_subtype", { foo = 1 }, function(response, err) end)
```

## The session store

Four module-level functions read and write Claude Code's transcripts directly. **None of them start a
process**, so they work whether or not a conversation is running — this is what replaces the `--control`
sidecar.

```lua
local sdk = require("claude-agent-sdk")

for _, s in ipairs(sdk.list_sessions({ limit = 20 })) do
  print(s.session_id, s.custom_title or s.ai_title)
end

local info = sdk.get_session_info(id)
local messages = sdk.get_session_messages(id, { limit = 200 })
sdk.rename_session(id, "refactor the parser")
```

How it works, in case you need to reason about the edges:

- Claude Code writes one JSONL file per session under
  `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where the directory name is the working directory
  with every non-alphanumeric character replaced by a dash.
- Lines up to 8192 bytes are decoded in full. Larger ones are assistant turns where only `cwd` and
  `gitBranch` matter, so a targeted pattern is used instead of parsing the whole message.
- Metadata entries (`customTitle`, `aiTitle`, `lastPrompt`, `summary`, `tag`, `gitBranch`, `cwd`) are
  accumulated with last-occurrence-wins, so a session reports its latest title and the branch it ended on.
- Message membership follows the `parentUuid` chain back from the last entry, with sibling tool results
  included. That is what makes a forked transcript resolve to one coherent branch.
- Git worktrees are included by default (`include_worktrees`).
- `include_programmatic = false` filters out sessions whose entrypoint is `sdk-cli`, `sdk-ts`, `sdk-py`,
  `daemon` or `daemon-worker` — that is, everything that wasn't an interactive CLI session.
- `rename_session` appends a `custom-title` entry. The file is append-only and newest wins, so renaming
  never rewrites history.

## Caveats

> [!WARNING]
> The control-channel subtypes and the on-disk transcript format are not published APIs the way the CLI
> flags are. They can shift between Claude Code releases with no compile-time warning.

In practice this is less fragile than it sounds:

- An unknown control subtype answers with `Unsupported control request subtype` rather than hanging, so a
  method the installed `claude` is too old for surfaces as an ordinary error on your callback. Measured
  against Claude Code 2.1.263, `get_status`, `list_permission_rules` and `export_conversation` answer that
  way; everything else works.
- Non-JSON lines on the stream surface as `{ type = "__malformed", line = … }` rather than failing the
  transport.
- Inbound control requests are *always* answered, with an error if nothing handles them, because an
  unanswered one stalls the CLI's turn.
- The session store is verified against the Node implementation by differential test rather than by
  specification.

`M.HARNESS_SCHEMA` records the protocol revision this port was written against. The CLI reports its own in
the `sdkCompat.harnessSchema` field of the npm package's `manifest.json`.
