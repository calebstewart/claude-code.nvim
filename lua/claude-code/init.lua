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

--- Open the chat in the current window instead of a sidebar, e.g.
--- `nvim +"Claude here"` for a Neovim that's just the chat.
function M.here()
  local s = sessions.current()
  if s and s.chat:visible() then
    sessions.show(s)
    return
  end
  if not s then
    if sessions.being_removed(vim.fn.getcwd()) then
      return
    end
    s = require("claude-code.session").new()
    if not s then
      return
    end
    sessions.adopt(s)
  end
  sessions.show(s, { here = true })
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

--- Interrupt Claude and send the queued messages right away.
function M.send_now()
  local s = sessions.current()
  if s then
    s:send_now()
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

--- Work on a story, branch or description in its own `wt` tree: create the tree
--- (`wt new`), or claim it when it exists, then open a session there. With no
--- text, asks for it. `wt` runs in the background; needs the worktree integration.
---@param text? string
---@param opts? claude_code.WorkOpts
function M.work(text, opts)
  if text and vim.trim(text) ~= "" then
    require("claude-code.work").work(text, opts)
    return
  end
  require("claude-code.ui.input").open({
    title = "Work on (story id, branch or description)",
    on_submit = function(input)
      if input ~= "" then
        require("claude-code.work").work(input, opts)
      end
    end,
  })
end

--- Pick a `wt` tree of the current project to open or resume a session in,
--- claim, release or remove. `query` pre-fills the search. Needs the worktree
--- integration; `wt` runs in the background.
---@param query? string
function M.trees(query)
  local problem = require("claude-code.work").unavailable("trees")
  if problem then
    vim.notify("claude-code: " .. problem, vim.log.levels.ERROR)
    return
  end
  require("claude-code.ui.trees").open({ scope = "project", query = vim.trim(query or "") })
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

--- Move the current session to another working directory, e.g. when the one it
--- ran in was deleted. With no directory, asks for one.
---@param dir? string
function M.relocate(dir)
  local s = sessions.current()
  if not s then
    vim.notify("claude-code: no current session", vim.log.levels.WARN)
    return
  end
  if dir and dir ~= "" then
    s:relocate(dir)
    return
  end
  vim.ui.input({ prompt = "Move session to: ", default = vim.fn.getcwd() .. "/", completion = "dir" }, function(text)
    if text and vim.trim(text) ~= "" then
      s:relocate(text)
    end
  end)
end

--- Set the current session's permission mode. With no mode, pick one.
---@param mode? string
function M.mode(mode)
  local s = sessions.current()
  if not s then
    vim.notify("claude-code: no current session", vim.log.levels.WARN)
    return
  end
  if mode and mode ~= "" then
    s:set_mode(mode)
    return
  end
  local modes = require("claude-code.modes")
  vim.ui.select(modes.all, {
    prompt = ("Permission mode (now: %s)"):format(s.mode or "default"),
    format_item = function(m)
      return (modes.display(m))
    end,
  }, function(choice)
    if choice then
      s:set_mode(choice)
    end
  end)
end

--- Attach an image file to the prompt (opening the chat if needed).
---@param path string
function M.image(path)
  if not path or path == "" then
    vim.notify("claude-code: :Claude image <path>", vim.log.levels.WARN)
    return
  end
  path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
  M.open()
  local s = sessions.current()
  if s then
    s.chat:attach_image(path)
  end
end

--- Deliver the messages from other Claude sessions that the current session is holding.
function M.deliver()
  local s = sessions.current()
  if not s then
    vim.notify("claude-code: no current session", vim.log.levels.WARN)
    return
  end
  s:deliver_held()
end

--- The `wt` tree the current session runs in, for statuslines: `{ name, slot,
--- branch, path }`, or nil (not in a tree, or the worktree integration is off).
--- Cheap: returns what the chat last looked up, and never runs `wt`. Redraw on
--- `User ClaudeCodeSessionsChanged`, which fires when it changes.
---@return claude_code.ChatTree?
function M.worktree()
  local s = sessions.peek()
  return s and s.chat:worktree()
end

--- Switch to the next/previous session open in this Neovim.
function M.next()
  sessions.cycle(1)
end

function M.prev()
  sessions.cycle(-1)
end

return M
