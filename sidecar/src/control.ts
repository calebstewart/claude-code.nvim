// Control mode: session bookkeeping (list, read, rename, delete) for the session
// picker. It never starts a Claude process; the SDK reads and writes the
// session transcripts under ~/.claude/projects directly.

import { deleteSession, getSessionInfo, getSessionMessages, listSessions, renameSession } from "@anthropic-ai/claude-agent-sdk";
import { open, readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { onLines, write } from "./io.js";
import type { ControlRequest, ControlResponse } from "./protocol.js";

interface Project {
  cwd: string;
  sessions: number;
  lastModified: number;
}

/** The working directory a transcript records, from its first 64 KiB. */
async function transcriptCwd(path: string): Promise<string | undefined> {
  const file = await open(path, "r");
  try {
    const { buffer, bytesRead } = await file.read({ buffer: Buffer.alloc(65536), position: 0 });
    const match = /"cwd":"((?:[^"\\]|\\.)*)"/.exec(buffer.subarray(0, bytesRead).toString("utf8"));
    return match ? (JSON.parse(`"${match[1]}"`) as string) : undefined;
  } catch {
    return undefined;
  } finally {
    await file.close();
  }
}

/**
 * Projects that have sessions, most recently used first. The SDK has no
 * equivalent: the directory names under `projects/` are a lossy encoding of the
 * path, so each project's real path comes from its newest transcripts. Matches
 * list_projects in lua/claude-agent-sdk/sessions.lua.
 */
async function listProjects(): Promise<Project[]> {
  const root = join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"), "projects");
  let names: string[];
  try {
    names = await readdir(root);
  } catch {
    return [];
  }
  const projects: Project[] = [];
  for (const name of names) {
    const dir = join(root, name);
    let files: string[];
    try {
      if (!(await stat(dir)).isDirectory()) continue;
      files = (await readdir(dir)).filter((file) => file.endsWith(".jsonl"));
    } catch {
      continue;
    }
    const transcripts: { path: string; mtime: number }[] = [];
    for (const file of files) {
      try {
        const info = await stat(join(dir, file));
        if (info.isFile()) transcripts.push({ path: join(dir, file), mtime: Math.floor(info.mtimeMs) });
      } catch {
        // gone since readdir
      }
    }
    transcripts.sort((a, b) => b.mtime - a.mtime);
    let cwd: string | undefined;
    for (const transcript of transcripts.slice(0, 5)) {
      cwd = await transcriptCwd(transcript.path);
      if (cwd) break;
    }
    if (cwd) projects.push({ cwd, sessions: transcripts.length, lastModified: transcripts[0].mtime });
  }
  return projects.sort((a, b) => b.lastModified - a.lastModified);
}

async function dispatch(request: ControlRequest): Promise<unknown> {
  switch (request.method) {
    case "list_sessions":
      return listSessions({
        dir: request.params.dir,
        limit: request.params.limit,
        includeWorktrees: request.params.include_worktrees,
      });
    case "list_projects":
      return listProjects();
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
    case "delete_session":
      await deleteSession(request.params.session_id, { dir: request.params.dir });
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
