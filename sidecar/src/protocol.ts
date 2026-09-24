// Wire protocol between Neovim and the sidecar: one JSON object per line on stdio.
// Keep in sync with the annotations in lua/claude-code/sidecar.lua.

import type { PermissionMode, SDKMessage, SlashCommand } from "@anthropic-ai/claude-agent-sdk";

// Neovim -> sidecar

export interface InitRequest {
  type: "init";
  cwd: string;
  claude_path: string;
  model?: string;
  permission_mode?: PermissionMode;
  /** Session id to resume. */
  resume?: string;
  /** Id for a new session (ignored when resuming). */
  session_id?: string;
  /** Title for a new session. */
  title?: string;
  /** Ask for a predicted next prompt after each turn (a `prompt_suggestion` message). */
  prompt_suggestions?: boolean;
}

export interface PromptRequest {
  type: "prompt";
  text: string;
  /** false: add to the conversation without starting a turn (it's merged into the next one). */
  should_query?: boolean;
  /** Images to send with the text (base64), e.g. pasted from the clipboard. */
  images?: ImageAttachment[];
}

export interface ImageAttachment {
  media_type: "image/png" | "image/jpeg" | "image/gif" | "image/webp";
  data: string;
}

export interface InterruptRequest {
  type: "interrupt";
}

/** Switch the running session's permission mode. */
export interface SetPermissionModeRequest {
  type: "set_permission_mode";
  mode: PermissionMode;
}

export interface PermissionResponse {
  type: "permission_response";
  id: number;
  behavior: "allow" | "deny";
  /** Allow, and apply the SDK's suggested rules so this isn't asked again. */
  always?: boolean;
  /** Replacement tool input, e.g. AskUserQuestion's input with `answers` filled in. */
  updated_input?: Record<string, unknown>;
  /** Also switch the session's permission mode (e.g. approving a plan into acceptEdits). */
  set_mode?: PermissionMode;
  message?: string;
}

export type Inbound = InitRequest | PromptRequest | InterruptRequest | SetPermissionModeRequest | PermissionResponse;

// Sidecar -> Neovim

export interface ReadyEvent {
  type: "ready";
  /** Known up front (we choose it), so the first prompt can be tagged with it. */
  session_id: string;
}

/** Slash commands available to the session (later changes arrive as system/commands_changed). */
export interface CommandsEvent {
  type: "commands";
  commands: SlashCommand[];
}

/** A raw SDK message, forwarded untouched so the Lua side decides how to render it. */
export interface SdkEvent {
  type: "sdk";
  message: SDKMessage;
}

export interface PermissionRequestEvent {
  type: "permission_request";
  id: number;
  tool_use_id: string;
  tool_name: string;
  input: Record<string, unknown>;
  title?: string;
  description?: string;
  /** The SDK offered rules for an "always allow" choice. */
  has_suggestions: boolean;
  /** Approval must not be a single keystroke. */
  default_to_no: boolean;
  /** Don't offer "always allow" even if suggestions exist. */
  suppress_always: boolean;
  /** Set when a subagent is asking. */
  agent_id?: string;
}

/** Sent when the SDK aborts a pending permission request (e.g. after an interrupt). */
export interface PermissionCancelEvent {
  type: "permission_cancel";
  id: number;
}

export interface ErrorEvent {
  type: "error";
  message: string;
}

/** The query ended; the sidecar exits after sending this. */
export interface ExitEvent {
  type: "exit";
}

export type Outbound =
  | ReadyEvent
  | CommandsEvent
  | SdkEvent
  | PermissionRequestEvent
  | PermissionCancelEvent
  | ErrorEvent
  | ExitEvent;

// Control mode (`sidecar.mjs --control`): session bookkeeping, no Claude process.
// Neovim sends requests; each gets exactly one response with the same id.

export type ControlRequest =
  | {
      type: "request";
      id: number;
      method: "list_sessions";
      params: { dir?: string; limit?: number; include_worktrees?: boolean };
    }
  | { type: "request"; id: number; method: "list_projects"; params: Record<string, never> }
  | {
      type: "request";
      id: number;
      method: "get_messages";
      /** `tail`: only the last N messages (the total is reported alongside). */
      params: { session_id: string; dir?: string; tail?: number };
    }
  | { type: "request"; id: number; method: "rename_session"; params: { session_id: string; title: string; dir?: string } }
  | { type: "request"; id: number; method: "delete_session"; params: { session_id: string; dir?: string } }
  | { type: "request"; id: number; method: "get_session_info"; params: { session_id: string; dir?: string } };

export interface ControlResponse {
  type: "response";
  id: number;
  result?: unknown;
  error?: string;
}
