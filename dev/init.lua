-- The Neovim config behind `nix run .#dev` (see nix/dev.nix): this plugin and a
-- few companions, and nothing of yours. Edit freely; it only affects that.
--
-- Launched as `nvim --clean -u dev/init.lua -i NONE`, so your ~/.config/nvim,
-- installed plugins and shada stay out of it. Without Nix, that command works
-- too; you just go without the companion plugins.
--
-- CLAUDE_CODE_DEV_TRANSPORT=direct tries the Node-free transport.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

-- --clean already leaves out your config and data directories; drop system-wide
-- site directories too (e.g. plugins installed through a Nix profile), keeping
-- Neovim's own runtime and its bundled parsers.
local rtp = { root }
for _, dir in ipairs(vim.opt.rtp:get()) do
  if dir ~= root and not dir:find("/site", 1, true) and not dir:find("/etc/xdg", 1, true) then
    table.insert(rtp, dir)
  end
end
vim.opt.rtp = rtp
-- Companion plugins come from the Nix-built pack directory.
vim.opt.packpath = { vim.env.VIMRUNTIME, vim.env.CLAUDE_CODE_DEV_PACK }

vim.g.mapleader = " "
vim.opt.swapfile = false
vim.opt.undofile = false
vim.opt.termguicolors = true
vim.opt.number = true
vim.opt.splitright = true

require("claude-code").setup({
  transport = vim.env.CLAUDE_CODE_DEV_TRANSPORT or "sidecar",
  -- Keep test prompts out of the CLI's ~/.claude/history.jsonl.
  history = { share = false },
  -- model = "sonnet",
  -- permission_mode = "acceptEdits",
  -- window = { position = "bottom", size = 0.3 },
  -- messaging = { inbound = "hold" },
})

local function map(lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { desc = "Claude: " .. desc })
end
map("<leader>cc", "<cmd>Claude toggle<cr>", "toggle chat")
map("<leader>cs", "<cmd>Claude sessions<cr>", "sessions")
map("<leader>cn", "<cmd>Claude new<cr>", "new session")
map("<leader>ci", "<cmd>Claude interrupt<cr>", "interrupt")
map("<leader>cq", "<cmd>Claude stop<cr>", "stop session")
map("<leader>cd", "<cmd>Claude deliver<cr>", "deliver held messages")

-- Companions, if this was started by nix/dev.nix. Loaded now rather than after
-- this file, so they can be configured here.
vim.cmd.packloadall()
pcall(vim.cmd.colorscheme, "base16-catppuccin-mocha")
local ok, neo_tree = pcall(require, "neo-tree")
if ok then
  neo_tree.setup({
    sources = { "filesystem", "claude-code.neo-tree" },
    source_selector = { winbar = true },
  })
  map("<leader>ce", "<cmd>Neotree toggle claude_sessions<cr>", "sessions sidebar")
end
