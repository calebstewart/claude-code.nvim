local config = require("claude-code.config")
local sessions = require("claude-code.sessions")

local M = {}

---@param opts? table See claude_code.Config.
function M.setup(opts)
  config.setup(opts)
end

--- Open (or focus) the chat, starting a session if there isn't one.
function M.open()
  local s = sessions.current()
  if s then
    sessions.show(s)
  else
    sessions.new()
  end
end

--- Show or hide the chat.
function M.toggle()
  local s = sessions.current()
  if s and s.chat:visible() then
    s.chat:hide()
  else
    M.open()
  end
end

--- Send a prompt to the current session; with no text, focus the prompt instead.
---@param text? string
function M.send(text)
  M.open()
  local s = sessions.current()
  if s and text and text ~= "" then
    s:send(text)
  end
end

--- Interrupt the turn in progress.
function M.interrupt()
  local s = sessions.current()
  if s then
    s:interrupt()
  end
end

--- End the current session and close it (it stays on disk; resume it from the picker).
function M.stop()
  local s = sessions.current()
  if s then
    sessions.close(s)
  end
end

--- Pick a session to switch to or resume.
function M.sessions()
  require("claude-code.ui.sessions").open()
end

--- Start a new session. With no name, asks for one (leave it empty for none).
---@param name? string
function M.new(name)
  if name and name ~= "" then
    sessions.new(name)
    return
  end
  require("claude-code.ui.input").open({
    title = "New session name (optional)",
    on_submit = function(text)
      sessions.new(text)
    end,
  })
end

--- Rename the current session. With no name, asks for one.
---@param name? string
function M.rename(name)
  local s = sessions.current()
  if not s then
    vim.notify("claude-code: no current session", vim.log.levels.WARN)
    return
  end
  if name and name ~= "" then
    s:rename(name)
    return
  end
  require("claude-code.ui.input").open({
    title = "Rename session",
    default = s.title,
    on_submit = function(text)
      if text ~= "" then
        s:rename(text)
      end
    end,
  })
end

--- Switch to the next/previous session open in this Neovim.
function M.next()
  sessions.cycle(1)
end

function M.prev()
  sessions.cycle(-1)
end

return M
