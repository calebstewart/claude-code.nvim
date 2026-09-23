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
    in
    {
      packages = forAllSystems (pkgs: {
        default = plugin pkgs;
        claude-code-nvim = plugin pkgs;
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
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
