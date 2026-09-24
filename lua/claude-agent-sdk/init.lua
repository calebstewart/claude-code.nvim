-- A Lua port of the Claude Agent SDK.
--
-- The official SDK (@anthropic-ai/claude-agent-sdk) is a thin wrapper around
-- the `claude` CLI: it builds an argv, spawns the binary with
-- `--input-format stream-json --output-format stream-json`, and pumps
-- newline-delimited JSON over stdio. Conversation messages and a bidirectional
-- control channel share that one stream. None of that needs a Node runtime, so
-- this module does the same thing from Neovim and talks to `claude` directly.
--
-- Usage:
--
--   local sdk = require("claude-agent-sdk")
--   local query = sdk.query({
--     cwd = vim.fn.getcwd(),
--     system_prompt = { type = "preset", preset = "claude_code" },
--     include_partial_messages = true,
--     on_message = function(msg) vim.print(msg.type) end,
--     can_use_tool = function(name, input, ctx, respond)
--       respond({ behavior = "allow" })
--     end,
--   })
--   query:send({ text = "hello" })
--
-- Layout mirrors the TypeScript SDK's own seams:
--
--   options.lua    options    -> argv + env      (ProcessTransport's arg builder)
--   transport.lua  process    -> framed JSON     (ProcessTransport)
--   control.lua    control_request/response      (Query's control plumbing)
--   query.lua      demux + the imperative API    (Query)

---@alias claude_agent_sdk.PermissionMode "default"|"acceptEdits"|"plan"|"dontAsk"|"auto"|"bypassPermissions"

---@class claude_agent_sdk.Image
---@field media_type "image/png"|"image/jpeg"|"image/gif"|"image/webp"
---@field data string Base64, without a data: prefix.

--- What `can_use_tool` passes to `respond`.
---@class claude_agent_sdk.PermissionResult
---@field behavior "allow"|"deny"
---@field message? string Shown to Claude on deny.
---@field interrupt? boolean Deny and end the turn.
---@field updated_input? table Replacement tool input.
---@field updated_permissions? table[] Rules to remember; usually `ctx.suggestions`.

--- Context for a permission request. `suggestions` are the CLI's proposed
--- "always allow" rules; hand them back as `updated_permissions` to apply them.
---@class claude_agent_sdk.PermissionContext
---@field tool_use_id string
---@field suggestions table[]
---@field display_name? string
---@field description? string
---@field title? string
---@field default_to_no boolean Approval should not be a single keystroke.
---@field suppress_always_allow_rule boolean Don't offer "always allow".
---@field blocked_path? string
---@field decision_reason? table
---@field agent_id? string
---@field mcp_server? table
---@field request_id string
---@field on_cancel fun(fn: fun()) Register a callback for when the CLI withdraws the request.

---@class claude_agent_sdk.Options
---@field executable? string Path to `claude` (default: `claude` on $PATH).
---@field cwd? string Working directory for the conversation.
---@field env? table<string, string> Extra environment, merged over Neovim's.
---@field entrypoint? string CLAUDE_CODE_ENTRYPOINT (default "sdk-ts"). The CLI gates some features on it — see options.lua.
--- Conversation
---@field model? string
---@field fallback_model? string
---@field agent? string
---@field betas? string[]
---@field effort? "low"|"medium"|"high"|"xhigh"|"max"
---@field thinking? { type: "adaptive"|"enabled"|"disabled", budget_tokens?: integer, display?: "omitted"|"summarized"|"updates" }
---@field max_turns? integer
---@field max_budget_usd? number
--- Sessions
---@field session_id? string Id for a new session.
---@field resume? string Session id to resume (wins over session_id).
---@field fork_session? boolean Resume into a copy, leaving the original alone.
---@field continue_conversation? boolean Resume the most recent session.
---@field resume_session_at? string Resume at a specific message uuid.
---@field persist_session? boolean Set false to leave no transcript on disk.
--- Prompting (sent in the initialize handshake, not as flags)
---@field system_prompt? string|table `{ type = "preset", preset = "claude_code" }` for Claude Code's own.
---@field append_system_prompt? string
---@field append_subagent_system_prompt? string
---@field plan_mode_instructions? string
---@field title? string Title for a new session.
---@field agents? table
---@field skills? string[]|"all"
---@field plugins? table[]
---@field tool_aliases? table
---@field exclude_dynamic_sections? boolean
---@field forward_subagent_text? boolean
---@field agent_progress_summaries? boolean Ask for `system/task_progress` updates from subagents.
---@field prompt_suggestions? boolean Emit a `prompt_suggestion` message after each turn.
---@field workspace_trust? table
---@field extra_initialize? table Additional initialize fields, verbatim.
--- Tools and permissions
---@field permission_mode? claude_agent_sdk.PermissionMode
---@field allow_dangerously_skip_permissions? boolean Required for bypassPermissions.
---@field allowed_tools? string[]
---@field disallowed_tools? string[]
---@field add_dirs? string[]
---@field mcp_servers? table<string, table>
---@field strict_mcp_config? boolean
---@field setting_sources? string[]
---@field project_config_root? string
---@field permission_prompt_tool_name? string Alternative to `can_use_tool`.
--- Streaming
---@field include_partial_messages? boolean Emit `stream_event` deltas.
---@field include_hook_events? boolean
---@field extra_args? table<string, string|boolean> Flags with no option above.
--- Callbacks
---@field on_message? fun(message: table) Every conversation message.
---@field on_ready? fun(info: table) Handshake done; carries commands, models, agents.
---@field on_error? fun(message: string)
---@field on_exit? fun(code: integer, stderr: string)
---@field can_use_tool? fun(tool_name: string, input: table, ctx: claude_agent_sdk.PermissionContext, respond: fun(result: claude_agent_sdk.PermissionResult))

local M = {}

--- Protocol revision this port was written against; the CLI reports its own in
--- the `sdkCompat.harnessSchema` field of the npm package's manifest.json.
M.HARNESS_SCHEMA = 1

--- Start a conversation.
---@param opts claude_agent_sdk.Options
---@return claude_agent_sdk.Query
function M.query(opts)
  return require("claude-agent-sdk.query").new(opts or {})
end

--- Exposed for tests and for callers that want to inspect the spawn.
---@param opts? claude_agent_sdk.Options
---@return string[]
function M.build_argv(opts)
  return require("claude-agent-sdk.options").build_argv(opts or {})
end

-- Session store: Claude Code's transcripts on disk. These never start a
-- process, so they work whether or not a conversation is running.

---@param opts? { dir?: string, limit?: integer, offset?: integer, include_worktrees?: boolean, include_programmatic?: boolean }
---@return table[]
function M.list_sessions(opts)
  return require("claude-agent-sdk.sessions").list_sessions(opts)
end

---@param session_id string
---@param opts? { dir?: string }
---@return table?
function M.get_session_info(session_id, opts)
  return require("claude-agent-sdk.sessions").get_session_info(session_id, opts)
end

---@param session_id string
---@param opts? { dir?: string, limit?: integer, offset?: integer, include_system_messages?: boolean }
---@return table[]
function M.get_session_messages(session_id, opts)
  return require("claude-agent-sdk.sessions").get_session_messages(session_id, opts)
end

---@param session_id string
---@param title string
---@param opts? { dir?: string }
---@return boolean ok, string? err
function M.rename_session(session_id, title, opts)
  return require("claude-agent-sdk.sessions").rename_session(session_id, title, opts)
end

---@param session_id string
---@param opts? { dir?: string }
---@return boolean ok, string? err
function M.delete_session(session_id, opts)
  return require("claude-agent-sdk.sessions").delete_session(session_id, opts)
end

return M
