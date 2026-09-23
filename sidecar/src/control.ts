// Control mode: session bookkeeping (list, read, rename) for the session
// picker. It never starts a Claude process; the SDK reads and writes the
// session transcripts under ~/.claude/projects directly.

import { getSessionInfo, getSessionMessages, listSessions, renameSession } from "@anthropic-ai/claude-agent-sdk";
import { onLines, write } from "./io.js";
import type { ControlRequest, ControlResponse } from "./protocol.js";

async function dispatch(request: ControlRequest): Promise<unknown> {
  switch (request.method) {
    case "list_sessions":
      return listSessions({ dir: request.params.dir, limit: request.params.limit });
    case "get_messages": {
      const { session_id, dir, tail } = request.params;
      const messages = await getSessionMessages(session_id, { dir });
      return { total: messages.length, messages: tail ? messages.slice(-tail) : messages };
    }
    case "get_session_info":
      return (await getSessionInfo(request.params.session_id, { dir: request.params.dir })) ?? null;
    case "rename_session":
      await renameSession(request.params.session_id, request.params.title, { dir: request.params.dir });
      return null;
    default:
      throw new Error(`Unknown method: ${(request as { method: string }).method}`);
  }
}

export function runControl(): void {
  const respond = (response: ControlResponse) => write(response);
  onLines(
    (message) => {
      const request = message as ControlRequest;
      dispatch(request)
        .then((result) => respond({ type: "response", id: request.id, result }))
        .catch((err: unknown) =>
          respond({ type: "response", id: request.id, error: err instanceof Error ? err.message : String(err) }),
        );
    },
    () => process.exit(0),
    (line) => process.stderr.write(`Invalid JSON from Neovim: ${line}\n`),
  );
}
