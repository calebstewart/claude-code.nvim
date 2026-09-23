-- Review window for a plan from plan mode: the plan's markdown file, opened
-- side by side with the chat. It's the real file, so edits (saved or not) are
-- picked up when the plan is approved.

local api = vim.api
local config = require("claude-code.config")

local M = {}

local WINBAR =
  "%#ClaudeCodeModePlan# ⏸ Plan for review %#ClaudeCodeMuted#· edit freely; approve or keep planning from the Claude chat"

---@param path string
---@return integer? win Showing the plan in this tab, if any.
function M.window(path)
  local buf = vim.fn.bufnr(path)
  if buf == -1 then
    return nil
  end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage() then
      return win
    end
  end
end

--- The editor window nearest the chat sidebar (not one of the chat's own, not a float).
---@param chat claude_code.Chat
---@return integer?
local function editor_window(chat)
  local ours = chat:windows()
  local position = config.options.window.position
  local editor, best
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local is_chat = win == ours.transcript or win == ours.dock or win == ours.prompt
    if not is_chat and api.nvim_win_get_config(win).relative == "" then
      local row, col = unpack(api.nvim_win_get_position(win))
      local score = ({
        right = col + api.nvim_win_get_width(win),
        left = -col,
        bottom = row + api.nvim_win_get_height(win),
        top = -row,
      })[position] or col
      if not best or score > best then
        editor, best = win, score
      end
    end
  end
  return editor
end

--- Show the plan next to the chat: in the editor window beside it if there is
--- one (as another buffer), otherwise in a new split. Focuses it.
---@param path string
---@param chat claude_code.Chat
function M.open(path, chat)
  vim.cmd("stopinsert")
  local existing = M.window(path)
  if existing then
    api.nvim_set_current_win(existing)
    return
  end

  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  vim.bo[buf].buflisted = true
  local win = editor_window(chat)
  if win then
    api.nvim_win_set_buf(win, buf)
    api.nvim_set_current_win(win)
  else
    -- Only the chat is open: make room beside it.
    local position = config.options.window.position
    win = api.nvim_open_win(buf, true, { split = position == "left" and "right" or "left", win = -1 })
  end
  -- Local to this buffer in this window, so it goes away when you switch back to your file.
  vim.wo[win][0].winbar = WINBAR
end

--- The plan's current text: the buffer if it's loaded (saving unsaved edits), else the file.
---@param path string
---@return string?
function M.read(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    if vim.bo[buf].modified then
      api.nvim_buf_call(buf, function()
        vim.cmd("silent write")
      end)
    end
    return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") .. "\n"
  end
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

return M
