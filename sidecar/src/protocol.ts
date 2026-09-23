// Wire protocol between Neovim and the sidecar: one JSON object per line on stdio.
// Keep in sync with the annotations in lua/claude-code/sidecar.lua.

import type { PermissionMode, SDKMessage } from "@anthropic-ai/claude-agent-sdk";

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
}

export interface PromptRequest {
  type: "prompt";
  text: string;
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
  | SdkEvent
  | PermissionRequestEvent
  | PermissionCancelEvent
  | ErrorEvent
  | ExitEvent;

// Control mode (`sidecar.mjs --control`): session bookkeeping, no Claude process.
// Neovim sends requests; each gets exactly one response with the same id.

export type ControlRequest =
  | { type: "request"; id: number; method: "list_sessions"; params: { dir?: string; limit?: number } }
  | {
      type: "request";
      id: number;
      method: "get_messages";
      /** `tail`: only the last N messages (the total is reported alongside). */
      params: { session_id: string; dir?: string; tail?: number };
    }
  | { type: "request"; id: number; method: "rename_session"; params: { session_id: string; title: string; dir?: string } }
  | { type: "request"; id: number; method: "get_session_info"; params: { session_id: string; dir?: string } };

export interface ControlResponse {
  type: "response";
  id: number;
  result?: unknown;
  error?: string;
}
