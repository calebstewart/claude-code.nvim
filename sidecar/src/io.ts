// stdio framing shared by both modes: one JSON object per line. stdout is
// reserved for the protocol, so diagnostics go to stderr.

import { createInterface } from "node:readline";

export function write(message: unknown): void {
  process.stdout.write(JSON.stringify(message) + "\n");
}

export function onLines(
  handle: (message: unknown) => void,
  onClose: () => void,
  onInvalid: (line: string) => void,
): void {
  const lines = createInterface({ input: process.stdin });
  lines.on("line", (line) => {
    if (line.trim() === "") return;
    let message: unknown;
    try {
      message = JSON.parse(line);
    } catch {
      onInvalid(line);
      return;
    }
    handle(message);
  });
  lines.on("close", onClose);
}
