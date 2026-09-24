local config = require("claude-code.config")
local transport = require("claude-code.transport")

local M = {}

function M.check()
  vim.health.start("claude-code.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local needs_node = transport.uses_node()
  if needs_node then
    vim.health.info("Transport: sidecar (Neovim -> node -> claude)")
  else
    vim.health.info("Transport: direct (Neovim -> claude), no Node involved")
  end

  local node = config.options.node
  if vim.fn.executable(node) == 1 then
    local version = vim.trim(vim.system({ node, "--version" }, { text = true }):wait().stdout or "")
    local parsed = vim.version.parse(version)
    if parsed and parsed.major >= 18 then
      vim.health.ok(("Node %s (%s)"):format(version, vim.fn.exepath(node)))
    elseif needs_node then
      vim.health.error(("Node 18 or newer is required, found %s"):format(version))
    else
      vim.health.info(("Node %s is older than 18, but the direct transport doesn't use it"):format(version))
    end
  elseif needs_node then
    vim.health.error(("`%s` not found; install Node, or set `transport = \"direct\"` in setup()"):format(node))
  else
    vim.health.info(("`%s` not found — not needed by the direct transport"):format(node))
  end

  local claude = config.claude_path()
  if claude then
    local version = vim.trim(vim.system({ claude, "--version" }, { text = true }):wait().stdout or "")
    vim.health.ok(("Claude Code %s (%s)"):format(version, claude))
  else
    vim.health.error("`claude` not found; install Claude Code or set `claude` in setup()")
  end

  if config.options.icons == "nerd" then
    vim.health.info("Icons: nerd (needs a Nerd Font; set `icons = \"unicode\"` otherwise)")
  else
    vim.health.info("Icons: " .. config.options.icons)
  end

  local script = require("claude-code.sidecar").script_path()
  if vim.uv.fs_stat(script) then
    vim.health.ok("Sidecar bundle: " .. script)
  elseif needs_node then
    vim.health.error("Sidecar bundle missing: " .. script, "Run `npm ci && npm run build` in sidecar/")
  else
    vim.health.info("Sidecar bundle missing — not needed by the direct transport")
  end

  local store = require("claude-agent-sdk.sessions").projects_root()
  if vim.uv.fs_stat(store) then
    vim.health.ok("Session store: " .. store)
  else
    vim.health.warn("Session store not found: " .. store, "It appears once Claude Code has run here")
  end
end

return M
