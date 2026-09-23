-- A centered splash shown while the transcript is empty.

local api = vim.api
local config = require("claude-code.config")
local icons = require("claude-code.ui.icons")

local ns = api.nvim_create_namespace("claude-code.welcome")

local M = {}

---@param text string
---@param width integer
local function center(text, width)
  return string.rep(" ", math.max(math.floor((width - vim.fn.strdisplaywidth(text)) / 2), 0))
end

--- Draw (or redraw) the splash into `buf`, sized for `win`.
---@param buf integer
---@param win integer
---@param info { model?: string }
function M.render(buf, win, info)
  api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local i = icons.get()
  local width = api.nvim_win_get_width(win)
  local height = api.nvim_win_get_height(win)

  local keys = config.options.keymaps
  local hints = {}
  local submit = config.keys(keys.submit.i)[1]
  if submit then
    table.insert(hints, icons.key(submit) .. " send")
  end
  if keys.interrupt then
    table.insert(hints, icons.key(keys.interrupt) .. " interrupt")
  end
  table.insert(hints, "↑↓ history")
  if keys.close then
    table.insert(hints, keys.close .. " hide")
  end

  local rows = {
    { i.logo .. " Claude Code", "ClaudeCodeWelcomeLogo" },
    { "", "Normal" },
    { i.folder .. " " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~"), "ClaudeCodeMuted" },
    { i.model .. " " .. (info.model or "connecting…"), "ClaudeCodeMuted" },
    { "", "Normal" },
    { table.concat(hints, "  ·  "), "ClaudeCodePlaceholder" },
  }
  local lines = {}
  for _ = 1, math.max(math.floor((height - #rows) / 2) - 1, 0) do
    table.insert(lines, { { "", "Normal" } })
  end
  for _, row in ipairs(rows) do
    table.insert(lines, { { center(row[1], width), "Normal" }, row })
  end
  api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_lines = lines })
end

---@param buf integer
function M.clear(buf)
  if api.nvim_buf_is_valid(buf) then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  end
end

return M
