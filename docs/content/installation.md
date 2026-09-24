+++
title = "Installation"
weight = 1
description = "Requirements, plugin managers, the Nix flake, and verifying the install."
+++

## Requirements

| | |
|---|---|
| Neovim | 0.10 or newer |
| Node | 18 or newer — **not needed** with `transport = "direct"` |
| Claude Code | Installed and logged in, with `claude` on `$PATH` |
| Font | Optional: a [Nerd Font](https://www.nerdfonts.com/) for icons, or set `icons = "unicode"` |

The plugin talks to your installed `claude`; it does not bundle or download one. If
[Claude Code](https://docs.claude.com/en/docs/claude-code) works in your shell, it will work here.

Node is only used to run the sidecar. Setting [`transport = "direct"`](@/architecture.md#direct-transport)
drives `claude` from Lua instead and removes the dependency entirely.

## lazy.nvim

```lua
{
  "calebstewart/claude-code.nvim",
  cmd = "Claude",
  opts = {},
}
```

`opts = {}` is what calls `setup()`. The plugin registers `:Claude` on its own, so `setup()` is only
required if you are changing defaults.

The plugin creates no global keymaps — bind what you want. With lazy.nvim, `keys` also defers loading
until the first press:

```lua
{
  "calebstewart/claude-code.nvim",
  cmd = "Claude",
  keys = {
    { "<leader>cc", "<cmd>Claude toggle<cr>", desc = "Claude: toggle chat" },
    { "<leader>cs", "<cmd>Claude sessions<cr>", desc = "Claude: sessions" },
    { "<leader>cn", "<cmd>Claude new<cr>", desc = "Claude: new session" },
  },
  opts = {},
}
```

## Other plugin managers

There is no build step and no dependency on another plugin, so installation is just "put it on the
runtimepath".

```lua
-- packer.nvim
use({
  "calebstewart/claude-code.nvim",
  config = function()
    require("claude-code").setup({})
  end,
})

-- mini.deps
add("calebstewart/claude-code.nvim")
require("claude-code").setup({})

-- paq-nvim
require("paq")({ "calebstewart/claude-code.nvim" })
require("claude-code").setup({})
```

```vim
" vim-plug
Plug 'calebstewart/claude-code.nvim'
" then, after plug#end():
lua require('claude-code').setup({})
```

## Nix

The repository is a flake. Its package is the plugin with Node.js from Nix baked in as the default `node`,
so nothing needs to be on `$PATH` except `claude`.

```nix
{
  inputs.claude-code-nvim = {
    url = "github:calebstewart/claude-code.nvim";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

Outputs:

| Output | |
|---|---|
| `packages.<system>.default` | The plugin |
| `packages.<system>.claude-code-nvim` | The same derivation, named |
| `packages.<system>.docs` | This documentation site |
| `overlays.default` | Adds `pkgs.vimPlugins.claude-code-nvim` |
| `devShells.<system>.default` | Node, Neovim, stylua and zola, for working on the plugin |

With Home Manager's Neovim module:

```nix
programs.neovim.plugins = [ inputs.claude-code-nvim.packages.${pkgs.system}.default ];
```

With lazy.nvim, point `dir` at the package's store path (for example by writing it into a Lua file your
config reads):

```lua
{
  dir = "/nix/store/…-vimplugin-claude-code.nvim-…", -- "${inputs.claude-code-nvim.packages.${pkgs.system}.default}"
  name = "claude-code.nvim",
  cmd = "Claude",
  opts = {},
}
```

## Verifying

```vim
:checkhealth claude-code
```

This checks the Neovim version, that `claude` is on `$PATH`, and — unless you are on the direct transport —
that Node is present and new enough. Then open the chat with `:Claude`.
