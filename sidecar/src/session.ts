// Session mode: one process per Claude conversation.

import { randomUUID } from "node:crypto";
import {
  query,
  type CanUseTool,
  type PermissionResult,
  type PermissionUpdate,
  type Query,
  type SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { onLines, write } from "./io.js";
import type { ImageAttachment, Inbound, InitRequest, Outbound } from "./protocol.js";

function send(event: Outbound): void {
  write(event);
}

/** An async queue of user messages feeding the SDK's streaming input mode. */
class Inbox implements AsyncIterable<SDKUserMessage> {
  private items: SDKUserMessage[] = [];
  private waiter: ((result: IteratorResult<SDKUserMessage>) => void) | undefined;
  private closed = false;

  push(text: string, shouldQuery = true, images: ImageAttachment[] = []): void {
    // Images go before the text, as the Messages API recommends.
    const content: SDKUserMessage["message"]["content"] =
      images.length === 0
        ? text
        : [
            ...images.map((image) => ({
              type: "image" as const,
              source: { type: "base64" as const, media_type: image.media_type, data: image.data },
            })),
            { type: "text" as const, text },
          ];
    const item: SDKUserMessage = {
      type: "user",
      message: { role: "user", content },
      parent_tool_use_id: null,
      ...(shouldQuery ? {} : { shouldQuery: false }),
    };
    if (this.waiter) {
      const resolve = this.waiter;
      this.waiter = undefined;
      resolve({ value: item, done: false });
    } else {
      this.items.push(item);
    }
  }

  close(): void {
    this.closed = true;
    this.waiter?.({ value: undefined, done: true });
    this.waiter = undefined;
  }

  [Symbol.asyncIterator](): AsyncIterator<SDKUserMessage> {
    return {
      next: () => {
        const item = this.items.shift();
        if (item) return Promise.resolve({ value: item, done: false });
        if (this.closed) return Promise.resolve({ value: undefined, done: true });
        return new Promise((resolve) => (this.waiter = resolve));
      },
    };
  }
}

const inbox = new Inbox();
interface PendingPermission {
  resolve: (result: PermissionResult) => void;
  suggestions?: PermissionUpdate[];
}

const pendingPermissions = new Map<number, PendingPermission>();
let nextPermissionId = 1;
let session: Query | undefined;
/** Neovim closed stdin; the session is shutting down on purpose. */
let closing = false;

const canUseTool: CanUseTool = (toolName, input, options) =>
  new Promise((resolve) => {
    const id = nextPermissionId++;
    pendingPermissions.set(id, { resolve, suggestions: options.suggestions });
    options.signal.addEventListener("abort", () => {
      if (pendingPermissions.delete(id)) {
        send({ type: "permission_cancel", id });
        resolve({ behavior: "deny", message: "Permission request was cancelled." });
      }
    });
    send({
      type: "permission_request",
      id,
      tool_use_id: options.toolUseID,
      tool_name: toolName,
      input,
      title: options.title,
      description: options.description,
      has_suggestions: (options.suggestions?.length ?? 0) > 0,
      default_to_no: options.defaultToNo ?? false,
      suppress_always: options.suppressAlwaysAllowRule ?? false,
      agent_id: options.agentID,
    });
  });

/** Accepting releases every held message at once; null then restores whatever applied before. */
async function deliverHeld(): Promise<void> {
  if (!session) return;
  await session.applyFlagSettings({ crossSessionInbound: "accept" });
  await session.applyFlagSettings({ crossSessionInbound: initRequest?.inbound ?? null });
}

let sessionId: string | undefined;
let initRequest: InitRequest | undefined;

async function run(init: InitRequest): Promise<void> {
  initRequest = init;
  sessionId = init.resume ?? init.session_id ?? randomUUID();
  session = query({
    prompt: inbox,
    options: {
      cwd: init.cwd,
      pathToClaudeCodeExecutable: init.claude_path,
      model: init.model,
      permissionMode: init.permission_mode,
      // The SDK refuses bypassPermissions without this; only set it when that mode was chosen.
      allowDangerouslySkipPermissions: init.permission_mode === "bypassPermissions" || undefined,
      resume: init.resume,
      sessionId: init.resume ? undefined : sessionId,
      title: init.resume ? undefined : init.title,
      // Without this the SDK runs with an empty system prompt, not Claude Code's.
      systemPrompt: { type: "preset", preset: "claude_code" },
      includePartialMessages: true,
      promptSuggestions: init.prompt_suggestions ?? true,
      canUseTool,
      settings: init.inbound ? { crossSessionInbound: init.inbound } : undefined,
      extraArgs: {
        // Echo user messages back: how a message from another session (which starts or joins
        // a turn without a prompt from us) reaches the transcript.
        "replay-user-messages": null,
        ...(init.name ? { name: init.name } : {}),
      },
      env: {
        ...process.env,
        // system/session_state_changed: running and idle, whatever started the turn.
        CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: "1",
      },
    },
  });
  send({ type: "ready", session_id: sessionId });
  session
    .supportedCommands()
    .then((commands) => send({ type: "commands", commands }))
    .catch(() => {});
  for await (const message of session) {
    send({ type: "sdk", message });
  }
}

function handle(request: Inbound): void {
  switch (request.type) {
    case "init":
      if (session) {
        send({ type: "error", message: "Session already initialized." });
        return;
      }
      run(request)
        .catch((err: unknown) => {
          // After an interrupted turn the SDK reports the CLI's normal exit as an error.
          if (closing) return;
          send({ type: "error", message: err instanceof Error ? err.message : String(err) });
        })
        .finally(() => {
          send({ type: "exit" });
          process.exit(0);
        });
      return;
    case "prompt":
      inbox.push(request.text, request.should_query ?? true, request.images);
      return;
    case "set_permission_mode":
      session?.setPermissionMode(request.mode).catch((err: unknown) => {
        send({ type: "error", message: `Couldn't switch to ${request.mode}: ${String(err)}` });
      });
      return;
    case "interrupt":
      session?.interrupt().catch((err: unknown) => {
        send({ type: "error", message: `Interrupt failed: ${String(err)}` });
      });
      return;
    case "rename":
      // Not in the SDK's typings, but on Query since 0.3: the control request the CLI's
      // /rename makes, which also updates the name in the cross-session registry.
      (session as unknown as { renameSession(title: string, sessionId?: string): Promise<void> } | undefined)
        ?.renameSession(request.title, sessionId)
        .catch((err: unknown) => {
          send({ type: "error", message: `Rename failed: ${String(err)}` });
        });
      return;
    case "deliver_held":
      deliverHeld().catch((err: unknown) => {
        send({ type: "error", message: `Couldn't deliver held messages: ${String(err)}` });
      });
      return;
    case "permission_response": {
      const pending = pendingPermissions.get(request.id);
      if (!pending) return;
      pendingPermissions.delete(request.id);
      if (request.behavior === "deny") {
        pending.resolve({ behavior: "deny", message: request.message ?? "The user denied this tool use." });
      } else {
        const updates: PermissionUpdate[] = request.always ? [...(pending.suggestions ?? [])] : [];
        if (request.set_mode) {
          updates.push({ type: "setMode", mode: request.set_mode, destination: "session" });
        }
        pending.resolve({
          behavior: "allow",
          updatedInput: request.updated_input,
          updatedPermissions: updates.length > 0 ? updates : undefined,
        });
      }
      return;
    }
    default:
      send({ type: "error", message: `Unknown request type: ${(request as { type: string }).type}` });
  }
}

export function runSession(): void {
  onLines(
    (request) => handle(request as Inbound),
    // Neovim closing our stdin ends the session.
    () => {
      closing = true;
      inbox.close();
      if (!session) process.exit(0);
    },
    (line) => send({ type: "error", message: `Invalid JSON from Neovim: ${line}` }),
  );
}
