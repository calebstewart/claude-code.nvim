{
  description = "claude-code.nvim: Claude Code in Neovim, driven by the Claude Agent SDK";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = "0.1.0-${self.shortRev or self.dirtyShortRev or "dirty"}";
      plugin =
        pkgs:
        pkgs.callPackage ./nix/package.nix {
          src = ./.;
          inherit version;
        };

      # The documentation site. Not in the overlay: nobody installs a website.
      mkDocs = pkgs: pkgs.callPackage ./nix/docs.nix { };

      # Not in the overlay either: it's for working on the plugin.
      mkDev = pkgs: pkgs.callPackage ./nix/dev.nix { src = ./.; };
    in
    {
      packages = forAllSystems (pkgs: {
        default = plugin pkgs;
        claude-code-nvim = plugin pkgs;
        docs = mkDocs pkgs;
        dev = mkDev pkgs;
      });

      # `nix run .#dev`: a Neovim with only this plugin loaded (see nix/dev.nix).
      apps = forAllSystems (pkgs: {
        dev = {
          type = "app";
          program = "${mkDev pkgs}/bin/claude-code-nvim-dev";
          meta.description = "Neovim with only claude-code.nvim loaded, for trying changes";
        };
      });

      # Adds pkgs.vimPlugins.claude-code-nvim.
      overlays.default = final: prev: {
        vimPlugins = prev.vimPlugins // {
          claude-code-nvim = plugin final;
        };
      };

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.nodejs
            pkgs.neovim
            pkgs.stylua
            pkgs.zola
          ];
        };
      });

      # A broken template or a dead `@/` link fails the site build, so the docs
      # cannot go stale unnoticed.
      checks = forAllSystems (pkgs: {
        docs = mkDocs pkgs;
        plugin = plugin pkgs;
        dev = mkDev pkgs;
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
