# The plugin as a Neovim package. The sidecar is the committed, prebuilt
# dist/sidecar.mjs (building it here would pull the Agent SDK's per-platform
# Claude binaries, which the plugin doesn't use; it runs your installed
# `claude`). Node.js comes from Nix rather than $PATH.
{
  lib,
  vimUtils,
  nodejs,
  src,
  version ? "unstable",
}:

vimUtils.buildVimPlugin {
  pname = "claude-code.nvim";
  inherit version;

  src = lib.fileset.toSource {
    root = src;
    fileset = lib.fileset.unions [
      (src + "/lua")
      (src + "/plugin")
      (src + "/dist")
      (src + "/README.md")
    ];
  };

  # Default the sidecar's runtime to this Node.js; `node` in setup() still overrides it.
  postPatch = ''
    substituteInPlace lua/claude-code/config.lua \
      --replace-fail 'node = "node",' 'node = "${lib.getExe nodejs}",'
  '';

  meta = {
    description = "Claude Code in Neovim, driven by the Claude Agent SDK";
    homepage = "https://github.com/calebstewart/claude-code.nvim";
    platforms = lib.platforms.unix;
  };
}
