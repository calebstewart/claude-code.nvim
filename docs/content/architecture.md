+++
title = "Architecture"
weight = 8
description = "The Node sidecar, the Lua core, and the experimental Node-free direct transport."
+++

## The default: a Node sidecar

```
                  ┌─▶ dist/sidecar.mjs            (one per session: Agent SDK) ──▶ claude
Neovim (Lua) ─────┤
  NDJSON / stdio  └─▶ dist/sidecar.mjs --control  (one: list/read/rename/delete sessions)
```

**Sidecar** (`sidecar/src/`) — `session.ts` runs one conversation and forwards raw SDK messages, so every
rendering decision stays in Lua. `control.ts` handles session bookkeeping without starting Claude. The line
protocol is defined in `protocol.ts`. It is built with esbuild into a single committed `dist/sidecar.mjs`,
which is why installing the plugin needs no build step.

**Lua core** (`lua/claude-code/`):

| Module | |
|---|---|
| `sidecar.lua` | Spawns sidecars and frames the NDJSON protocol |
| `transport.lua` | Picks between the sidecar and the direct transport |
| `cli.lua` | The direct transport — drives the Lua SDK, emitting the same events as `sidecar.lua` |
| `control.lua` | Answers the picker's requests from whichever store the transport implies |
| `session.lua` | One conversation: its chat, its process, suspend and resume, replaying history |
| `sessions.lua` | The sessions open in this Neovim; switching, cycling, idle suspension |
| `history.lua` | The shared prompt history |
| `images.lua` | Clipboard and file images, resizing and encoding |
| `modes.lua` | Permission modes and reading `defaultMode` from settings |
| `health.lua` | `:checkhealth claude-code` |

**UI** (`lua/claude-code/ui/`) — `chat.lua` (layout, keymaps, status), `transcript.lua` (the append-only
markdown buffer), `prompt.lua`, `permission.lua`, `question.lua`, `sessions.lua` (the picker), `slash.lua`,
`plan.lua`, `tools.lua`, `input.lua`, `markdown.lua`, `welcome.lua`, `icons.lua` and `highlights.lua`.

> [!NOTE]
> The Agent SDK normally brings its own platform-specific Claude binary, which can't be bundled into a
> single file. The sidecar instead runs the `claude` you already have, via
> `pathToClaudeCodeExecutable`.

## Direct transport

Setting [`transport = "direct"`](@/configuration.md#transport) removes Node entirely. Nothing spawns it,
and `:checkhealth` stops requiring it:

```
Neovim (Lua) ──▶ claude          (lua/claude-agent-sdk)
```

This works because the Agent SDK is a thin wrapper. It builds an argv, spawns `claude` with
`--input-format stream-json --output-format stream-json`, and pumps newline-delimited JSON over stdio, with
conversation messages and a bidirectional control channel sharing the one stream. None of that needs a Node
runtime.

`lua/claude-agent-sdk/` is a Lua port of it, laid out along the same seams — and usable on its own,
independent of this plugin. See [Lua Agent SDK](@/agent-sdk.md).

`sessions.lua` in that port replaces the `--control` sidecar: it reads and writes the JSONL transcripts
directly, so the session picker, history replay and renaming need no Claude process and no Node.
`claude-code/cli.lua` adapts a query to the same events `sidecar.lua` emits, and `claude-code/control.lua`
routes the picker to whichever store the transport implies — so `session.lua` is indifferent to the choice.

### Caveats

> [!WARNING]
> The control-channel subtypes and the on-disk transcript format are not published APIs the way the CLI
> flags are. They can shift between Claude Code releases with no compile-time warning.

The session store is verified against the Node implementation by differential test rather than by
specification: on every local transcript the two agree exactly, and where the SDK is self-inconsistent — a
forked transcript, where it returns a rewound branch's reply but not the prompt that caused it — this drops
the rewound branch cleanly instead.

Control subtypes newer than the installed `claude` report an ordinary error rather than hanging.

## Shared state

Both transports follow the CLI's conventions, which is what makes sessions interchangeable between the
plugin and the CLI:

- Sessions live under `~/.claude/projects/`.
- Prompt history is appended to `~/.claude/history.jsonl` under the CLI's lock.
- Sessions open elsewhere are detected from the CLI's process registry in `~/.claude/sessions/`, best
  effort.
