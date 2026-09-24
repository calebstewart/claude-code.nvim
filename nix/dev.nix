# `nix run .#dev`: a Neovim with only this plugin (and a few companions) loaded,
# reading and writing nothing of yours — no user config, plugins, shada, swap or
# undo files. Configured by dev/init.lua.
#
# Run from inside a checkout, it loads that checkout, so edits (even uncommitted
# or untracked ones) take effect on the next start. Anywhere else, e.g.
# `nix run github:calebstewart/claude-code.nvim#dev`, it loads the flake's copy.
#
# Claude itself is not sandboxed: `claude` must be on $PATH and logged in, and
# sessions are saved under ~/.claude/projects/ like any other.
{
  lib,
  writeShellApplication,
  linkFarm,
  neovim-unwrapped,
  nodejs,
  git,
  vimPlugins,
  src,
}:
let
  # Companions: a colorscheme and icons like a typical setup, and neo-tree for
  # the sessions sidebar. Loaded as start packages from this directory.
  plugins = with vimPlugins; [
    base16-nvim
    nvim-web-devicons
    neo-tree-nvim
    plenary-nvim
    nui-nvim
  ];
  pack = linkFarm "claude-code-nvim-dev-pack" (
    map (plugin: {
      name = "pack/dev/start/${lib.getName plugin}";
      path = plugin;
    }) plugins
  );
in
writeShellApplication {
  name = "claude-code-nvim-dev";
  runtimeInputs = [
    neovim-unwrapped
    nodejs # the sidecar
    git
  ];
  text = ''
    root="''${CLAUDE_CODE_DEV_ROOT:-}"
    if [ -z "$root" ]; then
      top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
      if [ -n "$top" ] && [ -f "$top/dev/init.lua" ] && [ -f "$top/lua/claude-code/init.lua" ]; then
        root="$top"
      else
        root="${src}"
      fi
    fi

    # Neovim's log would otherwise go to your state directory.
    state="''${TMPDIR:-/tmp}/claude-code-nvim-dev"
    mkdir -p "$state"
    export NVIM_LOG_FILE="$state/nvim.log"
    export CLAUDE_CODE_DEV_PACK="${pack}"

    exec nvim --clean -u "$root/dev/init.lua" -i NONE "$@"
  '';
  meta = {
    description = "Neovim with only claude-code.nvim loaded, for trying changes";
    mainProgram = "claude-code-nvim-dev";
  };
}
