// claude-code.nvim sidecar. Neovim talks to it with newline-delimited JSON on
// stdio (see protocol.ts). Two modes:
//
//   sidecar.mjs            one Claude conversation (session.ts)
//   sidecar.mjs --control  session bookkeeping for the picker (control.ts)

import { runControl } from "./control.js";
import { runSession } from "./session.js";

console.log = console.error;

if (process.argv.includes("--control")) {
  runControl();
} else {
  runSession();
}
