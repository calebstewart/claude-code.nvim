local config = require("claude-code.config")

local M = {}

function M.check()
  vim.health.start("claude-code.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local node = config.options.node
  if vim.fn.executable(node) == 1 then
    local version = vim.trim(vim.system({ node, "--version" }, { text = true }):wait().stdout or "")
    local parsed = vim.version.parse(version)
    if parsed and parsed.major >= 18 then
      vim.health.ok(("Node %s (%s)"):format(version, vim.fn.exepath(node)))
    else
      vim.health.error(("Node 18 or newer is required, found %s"):format(version))
    end
  else
    vim.health.error(("`%s` not found; install Node or set `node` in setup()"):format(node))
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
  else
    vim.health.error("Sidecar bundle missing: " .. script, "Run `npm ci && npm run build` in sidecar/")
  end
end

return M
