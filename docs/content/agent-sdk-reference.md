+++
title = "SDK reference"
weight = 10
description = "Every option, method and type in the Lua Agent SDK port."
+++

The narrative version is [Lua Agent SDK](@/agent-sdk.md). This page is the surface.

## Module

```lua
local sdk = require("claude-agent-sdk")
```

| | |
|---|---|
| `sdk.HARNESS_SCHEMA` | Protocol revision this port was written against |
| `sdk.query(opts)` | Start a conversation. Returns a `Query` |
| `sdk.build_argv(opts?)` | The argv `query` would spawn. Exposed for tests and inspection |
| `sdk.list_sessions(opts?)` | Sessions on disk |
| `sdk.get_session_info(session_id, opts?)` | One session's metadata, or `nil` |
| `sdk.get_session_messages(session_id, opts?)` | One session's messages |
| `sdk.rename_session(session_id, title, opts?)` | Set a session's title. Returns `ok, err` |
| `sdk.list_projects()` | Projects with sessions on disk (`cwd`, `sessions`, `lastModified`), newest first. Not in the TypeScript SDK |
| `sdk.delete_session(session_id, opts?)` | Delete a session's transcript and its subagents' transcripts. Returns `ok, err` |

The session functions never start a process.

| Function | `opts` |
|---|---|
| `list_sessions` | `dir`, `limit`, `offset`, `include_worktrees`, `include_programmatic` |
| `get_session_info` | `dir` |
| `get_session_messages` | `dir`, `limit`, `offset`, `include_system_messages` |
| `rename_session` | `dir` |
| `delete_session` | `dir` |

## Options

Everything below is a field of the table passed to `sdk.query()`. All are optional.

### Process

| Field | Type | |
|---|---|---|
| `executable` | `string` | Path to `claude`. Defaults to `claude` on `$PATH` |
| `cwd` | `string` | Working directory for the conversation |
| `env` | `table<string, string>` | Extra environment, merged over Neovim's |
| `entrypoint` | `string` | `CLAUDE_CODE_ENTRYPOINT`, default `"sdk-ts"` |

### Conversation

| Field | Type | |
|---|---|---|
| `model` | `string` | |
| `fallback_model` | `string` | |
| `agent` | `string` | |
| `betas` | `string[]` | |
| `effort` | `"low"\|"medium"\|"high"\|"xhigh"\|"max"` | |
| `thinking` | `table` | `{ type = "adaptive"\|"enabled"\|"disabled", budget_tokens?, display? }` where `display` is `"omitted"\|"summarized"\|"updates"` |
| `max_turns` | `integer` | |
| `max_budget_usd` | `number` | |

### Sessions

| Field | Type | |
|---|---|---|
| `session_id` | `string` | Id for a new session |
| `resume` | `string` | Session id to resume. Wins over `session_id` |
| `fork_session` | `boolean` | Resume into a copy, leaving the original alone |
| `continue_conversation` | `boolean` | Resume the most recent session |
| `resume_session_at` | `string` | Resume at a specific message uuid |
| `persist_session` | `boolean` | `false` leaves no transcript on disk |

### Prompting

These are sent in the `initialize` handshake rather than as CLI flags, so they can carry structured values.

| Field | Type | |
|---|---|---|
| `system_prompt` | `string\|table` | `{ type = "preset", preset = "claude_code" }` for Claude Code's own |
| `append_system_prompt` | `string` | |
| `append_subagent_system_prompt` | `string` | |
| `plan_mode_instructions` | `string` | |
| `title` | `string` | Title for a new session |
| `agents` | `table` | |
| `skills` | `string[]\|"all"` | |
| `plugins` | `table[]` | |
| `tool_aliases` | `table` | |
| `exclude_dynamic_sections` | `boolean` | |
| `forward_subagent_text` | `boolean` | |
| `agent_progress_summaries` | `boolean` | Ask for `system/task_progress` updates from subagents |
| `prompt_suggestions` | `boolean` | Emit a `prompt_suggestion` message after each turn |
| `workspace_trust` | `table` | |
| `extra_initialize` | `table` | Additional `initialize` fields, verbatim |

### Tools and permissions

| Field | Type | |
|---|---|---|
| `permission_mode` | `PermissionMode` | |
| `allow_dangerously_skip_permissions` | `boolean` | Required for `bypassPermissions` |
| `allowed_tools` | `string[]` | |
| `disallowed_tools` | `string[]` | |
| `add_dirs` | `string[]` | |
| `mcp_servers` | `table<string, table>` | |
| `strict_mcp_config` | `boolean` | |
| `setting_sources` | `string[]` | |
| `project_config_root` | `string` | |
| `permission_prompt_tool_name` | `string` | Alternative to `can_use_tool`; mutually exclusive with it |

### Streaming

| Field | Type | |
|---|---|---|
| `include_partial_messages` | `boolean` | Emit `stream_event` deltas |
| `include_hook_events` | `boolean` | |
| `extra_args` | `table<string, string\|boolean>` | Flags with no option above |

### Callbacks

| Field | Signature |
|---|---|
| `on_message` | `fun(message: table)` — every conversation message |
| `on_ready` | `fun(info: table)` — handshake done; carries commands, models, agents |
| `on_error` | `fun(message: string)` |
| `on_exit` | `fun(code: integer, stderr: string)` |
| `can_use_tool` | `fun(tool_name: string, input: table, ctx: PermissionContext, respond: fun(result: PermissionResult))` |

## Query methods

Every method except the accessors issues one `control_request` and takes an optional
`callback(response, err)`. Fire-and-forget is fine.

Wire field names are the CLI's, so they stay camelCase or snake_case exactly as the CLI spells them — it is
not consistent, `serverName` sits next to `max_thinking_tokens`. The Lua-facing arguments are snake_case
throughout.

### Sending

| Method | |
|---|---|
| `send(message)` | `{ text?, content?, images?, should_query? }`. Returns whether it was sent |

### Escape hatch

| Method | |
|---|---|
| `request(subtype, params?, callback?)` | Any control subtype without a named wrapper |

### Turn control

| Method | |
|---|---|
| `interrupt(opts?, callback?)` | Stop the current turn. `opts.cancel_queued` also drops queued messages |
| `stop_task(task_id, callback?)` | |
| `background_tasks(tool_use_id?, callback?)` | Whether a tool call is still running in the background |

### Model and thinking

| Method | |
|---|---|
| `set_model(model?, callback?)` | |
| `set_max_thinking_tokens(n?, display?, callback?)` | `nil` clears the override. `display` is `"summarized"\|"omitted"\|"highlights"` |

### Permissions and settings

| Method | |
|---|---|
| `set_permission_mode(mode, callback?)` | |
| `list_permission_rules(callback)` | |
| `update_settings(source, settings, callback?)` | `source` is `"localSettings"` or `"userSettings"` |
| `apply_flag_settings(settings, callback?)` | |
| `get_settings(callback)` | |

### Session and workspace

| Method | |
|---|---|
| `rename_session(title, opts?, callback?)` | Also renames the session for [cross-session messaging](https://code.claude.com/docs/en/cross-session-messaging). `opts.source`: `"host"` for a rename the user made in your application, which the CLI counts as a user rename (the CLI's default is `"remote"`). `opts.session_id`: refuse if the process has moved to another session |
| `set_cwd(path, opts?, callback?)` | `opts.trust_accepted` |
| `rewind_files(user_message_id, opts?, callback?)` | Undo file changes since a user message. `opts.dry_run` reports without touching anything |
| `seed_read_state(path, mtime, callback?)` | Tell the CLI a file was already read, so an edit isn't refused for want of a prior `Read` |
| `read_file(path, opts?, callback)` | `opts.max_bytes`, `opts.encoding` |
| `export_conversation(callback)` | |

### Status and usage

| Method | |
|---|---|
| `get_status(callback)` | |
| `get_usage(opts?, callback)` | `opts.skip_behaviors` |
| `get_context_usage(callback)` | |
| `get_plan(callback)` | |

### MCP

| Method | |
|---|---|
| `mcp_server_status(callback)` | |
| `reconnect_mcp_server(server_name, callback?)` | |
| `toggle_mcp_server(server_name, enabled, callback?)` | |
| `read_mcp_resource(server_name, uri, callback)` | |
| `set_mcp_servers(servers, callback?)` | |
| `set_mcp_permission_mode_override(server_name, mode, callback?)` | `mode` is `"default"`, `"auto"` or `nil` |

### Reloading

| Method | |
|---|---|
| `reload_plugins(opts?, callback?)` | `opts.hold_on_cache_impact` |
| `reload_skills(callback?)` | |
| `reload_output_styles(callback?)` | |
| `reinitialize(callback?)` | Re-run the handshake, picking up configuration that changed since start |

### Accessors

These read the handshake response and return immediately — no control request, nothing useful before
`on_ready`.

| Method | |
|---|---|
| `supported_commands()` | Slash commands for this session |
| `supported_models()` | |
| `supported_agents()` | |
| `account_info()` | The signed-in account |
| `initialization_result()` | The whole initialize response |
| `running()` | Whether the process is still up |
| `close()` | Finish the conversation and let the process exit |

> [!NOTE]
> Measured against Claude Code 2.1.263, `get_status`, `list_permission_rules` and `export_conversation`
> answer with `Unsupported control request subtype`. Everything else here works. An unknown subtype errors
> on the callback rather than hanging.

## Types

### PermissionMode

```lua
"default" | "acceptEdits" | "plan" | "dontAsk" | "auto" | "bypassPermissions"
```

### Image

| Field | |
|---|---|
| `media_type` | `"image/png"`, `"image/jpeg"`, `"image/gif"` or `"image/webp"` |
| `data` | Base64, without a `data:` prefix |

### PermissionResult

What `can_use_tool` passes to `respond`.

| Field | |
|---|---|
| `behavior` | `"allow"` or `"deny"` |
| `message` | Shown to Claude on deny |
| `interrupt` | Deny and end the turn |
| `updated_input` | Replacement tool input |
| `updated_permissions` | Rules to remember; usually `ctx.suggestions` |

### PermissionContext

| Field | |
|---|---|
| `tool_use_id` | |
| `suggestions` | The CLI's proposed "always allow" rules. Hand them back as `updated_permissions` to apply them |
| `display_name`, `description`, `title` | For rendering the prompt |
| `default_to_no` | Approval should not be a single keystroke |
| `suppress_always_allow_rule` | Don't offer "always allow" |
| `blocked_path` | |
| `decision_reason` | |
| `agent_id` | Set when a subagent is asking |
| `mcp_server` | |
| `request_id` | |
| `on_cancel` | `fun(fn)` — register a callback for when the CLI withdraws the request |

## Argv construction

`sdk.build_argv(opts)` returns what would be spawned, which is the quickest way to check an option does
what you expect. The details that surprise people:

- Every argv starts with `--output-format stream-json --verbose --input-format stream-json`. `--verbose` is
  required alongside stream-json output.
- `--allowedTools` and `--disallowedTools` are camelCase while their neighbours are kebab-case. That
  inconsistency is the CLI's, and matching it matters.
- `resume`, `session_id`, `setting_sources`, `project_config_root` and `resume_session_at` join their value
  with `=` rather than passing it as a separate argv entry.
- A value that looks like a flag (leading `-`) is passed as `--flag=value`, mirroring the SDK's own
  escaping.
- `--session-id` is dropped while resuming.
- `can_use_tool` implies `--permission-prompt-tool stdio`, and conflicts with
  `permission_prompt_tool_name`.
- Prompting options are **not** flags — they go in the `initialize` control request.

### Environment

`CLAUDE_CODE_ENTRYPOINT` defaults to `"sdk-ts"`, and it is load-bearing rather than telemetry: measured
against 2.1.263, an unrecognised value exposes two artifact skills that `sdk-ts` hides. `NODE_OPTIONS` is
blanked.
