-- Picks the session transport. Both implementations expose the same interface
-- and emit the same events (sidecar/src/protocol.ts):
--
--   "sidecar"  Neovim -> node dist/sidecar.mjs -> claude   (default)
--   "direct"   Neovim -> claude                            (lua/claude-agent-sdk)
--
-- The choice also decides how the session picker reads transcripts: through the
-- control sidecar, or straight off disk in Lua. See control.lua.

local config = require("claude-code.config")

local M = {}

--- Read at start time, not load time, so setup() ordering doesn't matter.
---@return table
function M.session()
  if config.options.transport == "direct" then
    return require("claude-code.cli")
  end
  return require("claude-code.sidecar")
end

--- Whether the current configuration needs Node at all for conversations.
---@return boolean
function M.uses_node()
  return config.options.transport ~= "direct"
end

return M
