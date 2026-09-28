// Control mode: session bookkeeping (list, read, rename, delete) for the session
// picker. It never starts a Claude process; the SDK reads and writes the
// session transcripts under ~/.claude/projects directly.

import { deleteSession, getSessionInfo, getSessionMessages, listSessions, renameSession } from "@anthropic-ai/claude-agent-sdk";
import { appendFile, mkdir, open, readdir, realpath, rename, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { onLines, write } from "./io.js";
import type { ControlRequest, ControlResponse } from "./protocol.js";

interface Project {
  cwd: string;
  sessions: number;
  lastModified: number;
}

function projectsRoot(): string {
  return join(process.env.CLAUDE_CONFIG_DIR ?? join(homedir(), ".claude"), "projects");
}

/** The project directory Claude Code files a working directory's sessions under. */
function projectDir(cwd: string): string {
  return join(projectsRoot(), cwd.replace(/[^a-zA-Z0-9]/g, "-"));
}

/**
 * The working directory a transcript records: where a `relocated` entry in its
 * last 64 KiB moved it, else the first `cwd` in its first 64 KiB.
 */
async function transcriptCwd(path: string): Promise<string | undefined> {
  const file = await open(path, "r");
  try {
    const { size } = await file.stat();
    const tail = await file.read({ buffer: Buffer.alloc(65536), position: Math.max(0, size - 65536) });
    const relocated = [
      ...tail.buffer.subarray(0, tail.bytesRead).toString("utf8").matchAll(/"relocatedCwd":"((?:[^"\\]|\\.)*)"/g),
    ].pop();
    if (relocated) return JSON.parse(`"${relocated[1]}"`) as string;
    const { buffer, bytesRead } = await file.read({ buffer: Buffer.alloc(65536), position: 0 });
    const match = /"cwd":"((?:[^"\\]|\\.)*)"/.exec(buffer.subarray(0, bytesRead).toString("utf8"));
    return match ? (JSON.parse(`"${match[1]}"`) as string) : undefined;
  } catch {
    return undefined;
  } finally {
    await file.close();
  }
}

/** A session's transcript in any project directory. Session ids are unique. */
async function findTranscript(sessionId: string): Promise<string | undefined> {
  const root = projectsRoot();
  let names: string[];
  try {
    names = await readdir(root);
  } catch {
    return undefined;
  }
  for (const name of names) {
    const path = join(root, name, `${sessionId}.jsonl`);
    try {
      if ((await stat(path)).isFile()) return path;
    } catch {
      // not in this project
    }
  }
  return undefined;
}

/**
 * Run `fn` scoped to `dir`, and again unscoped if the session isn't filed under
 * `dir`: the directory may be gone, or the session may have moved into a
 * worktree, and the SDK only searches `dir` (and its live worktrees) when given one.
 */
async function withFallback<T>(dir: string | undefined, fn: (dir?: string) => Promise<T>, missing: (result: T) => boolean): Promise<T> {
  try {
    const result = await fn(dir);
    if (!dir || !missing(result)) return result;
  } catch (err) {
    if (!dir || !(err instanceof Error && /not found/i.test(err.message))) throw err;
  }
  return fn(undefined);
}

/**
 * Move a session to another working directory, as the CLI does when a session's
 * directory changes: its transcript (and its subagents') move to the project
 * directory for `to`, and a `relocated` entry records the new cwd. Matches
 * relocate_session in lua/claude-agent-sdk/sessions.lua.
 */
async function relocateSession(sessionId: string, to: string): Promise<{ cwd: string }> {
  let cwd: string;
  try {
    cwd = await realpath(to);
    if (!(await stat(cwd)).isDirectory()) throw new Error();
  } catch {
    throw new Error(`not a directory: ${to}`);
  }
  const path = await findTranscript(sessionId);
  if (!path) throw new Error(`session not found: ${sessionId}`);
  const destDir = projectDir(cwd);
  const dest = join(destDir, `${sessionId}.jsonl`);
  if (dest !== path) {
    const exists = await stat(dest).then(
      () => true,
      () => false,
    );
    if (exists) throw new Error(`a transcript for this session already exists at ${dest}`);
    await mkdir(destDir, { recursive: true, mode: 0o700 });
    await rename(path, dest);
    // Best effort, as in the CLI: the conversation itself has already moved.
    await rename(path.replace(/\.jsonl$/, ""), join(destDir, sessionId)).catch(() => {});
  }
  await appendFile(dest, JSON.stringify({ type: "relocated", sessionId, relocatedCwd: cwd }) + "\n");
  return { cwd };
}

/**
 * Projects that have sessions, most recently used first. The SDK has no
 * equivalent: the directory names under `projects/` are a lossy encoding of the
 * path, so each project's real path comes from its newest transcripts. Matches
 * list_projects in lua/claude-agent-sdk/sessions.lua.
 */
async function listProjects(): Promise<Project[]> {
  const root = projectsRoot();
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
      const messages = await withFallback(
        dir,
        (d) => getSessionMessages(session_id, { dir: d }),
        (m) => m.length === 0,
      );
      return { total: messages.length, messages: tail ? messages.slice(-tail) : messages };
    }
    case "get_session_info": {
      const { session_id, dir } = request.params;
      return (await withFallback(dir, (d) => getSessionInfo(session_id, { dir: d }), (i) => i === undefined)) ?? null;
    }
    case "rename_session": {
      const { session_id, title, dir } = request.params;
      await withFallback(dir, (d) => renameSession(session_id, title, { dir: d }), () => false);
      return null;
    }
    case "delete_session": {
      const { session_id, dir } = request.params;
      await withFallback(dir, (d) => deleteSession(session_id, { dir: d }), () => false);
      return null;
    }
    case "relocate_session":
      return relocateSession(request.params.session_id, request.params.to);
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
