-- Lightweight markdown styling for the transcript: shaded code blocks with a
-- language label, bullet glyphs, full-width rules and quote bars. It runs as a
-- decoration provider, so it only touches visible rows and keeps up with
-- streaming text without any bookkeeping.

local api = vim.api
local config = require("claude-code.config")

local ns = api.nvim_create_namespace("claude-code.markdown")

local M = {}

---@type table<integer, true>
local attached = {}

local query ---@type vim.treesitter.Query?

local function get_query()
  if not query then
    query = vim.treesitter.query.parse(
      "markdown",
      [[
        (fenced_code_block) @code
        (list_marker_minus) @bullet
        (list_marker_star) @bullet
        (list_marker_plus) @bullet
        (thematic_break) @rule
        (block_quote) @quote
      ]]
    )
  end
  return query
end

---@param buf integer
---@param row integer
---@param col integer
---@param opts vim.api.keyset.set_extmark
local function mark(buf, row, col, opts)
  opts.ephemeral = true
  pcall(api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

---@param buf integer
---@param node TSNode
---@param top integer
---@param bot integer
local function code_block(buf, node, top, bot)
  local srow, _, erow, ecol = node:range()
  if ecol == 0 then
    erow = erow - 1
  end
  for row = math.max(srow, top), math.min(erow, bot) do
    mark(buf, row, 0, { end_row = row + 1, end_col = 0, hl_group = "ClaudeCodeCodeBlock", hl_eol = true, priority = 50 })
  end
  -- The opening fence line is concealed, so the label goes on the first line of code.
  local lang
  for child in node:iter_children() do
    if child:type() == "info_string" then
      lang = vim.treesitter.get_node_text(child, buf):match("^%S+")
    end
  end
  if lang and srow + 1 <= erow and srow + 1 >= top and srow + 1 <= bot then
    mark(buf, srow + 1, 0, { virt_text = { { " " .. lang .. " ", "ClaudeCodeCodeLang" } }, virt_text_pos = "right_align" })
  end
end

---@param buf integer
---@param node TSNode
---@param top integer
---@param bot integer
local function quote(buf, node, top, bot)
  local srow, scol, erow, ecol = node:range()
  if ecol == 0 then
    erow = erow - 1
  end
  for row = math.max(srow, top), math.min(erow, bot) do
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local col = line:find(">", scol + 1, true)
    if col then
      mark(buf, row, col - 1, { virt_text = { { "▎", "ClaudeCodeQuote" } }, virt_text_pos = "overlay" })
    end
  end
end

---@param buf integer
function M.attach(buf)
  attached[buf] = true
  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    callback = function()
      attached[buf] = nil
    end,
  })
end

api.nvim_set_decoration_provider(ns, {
  on_win = function(_, win, buf, top, bot)
    if not attached[buf] or not config.options.markdown.enabled then
      return false
    end
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown", { error = false })
    if not ok or not parser then
      return false
    end
    local tree = parser:parse({ top, bot + 1 })
    local root = tree and tree[1] and tree[1]:root()
    if not root then
      return false
    end
    local width = api.nvim_win_get_width(win)
    local q = get_query()
    for id, node in q:iter_captures(root, buf, top, bot + 1) do
      local name = q.captures[id]
      local row, col = node:range()
      if name == "code" then
        code_block(buf, node, top, bot)
      elseif name == "bullet" then
        mark(buf, row, col, { virt_text = { { "•", "ClaudeCodeBullet" } }, virt_text_pos = "overlay" })
      elseif name == "rule" then
        mark(buf, row, 0, { virt_text = { { string.rep("─", width), "ClaudeCodeRule" } }, virt_text_pos = "overlay" })
      elseif name == "quote" then
        quote(buf, node, top, bot)
      end
    end
    return false
  end,
})

return M
