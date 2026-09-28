-- Markdown pipe tables in the transcript, drawn as aligned grids: cells padded
-- to their column's width (and alignment), pipes shown as box-drawing lines,
-- the delimiter row as a rule, and a border above and below.
--
-- The buffer text stays as Claude wrote it; everything here is extmarks. Unlike
-- the rest of the markdown styling this can't be a decoration provider, since
-- ephemeral extmarks can't hold inline virtual text or virtual lines, so tables
-- are re-rendered whenever the lines they're on change.

local api = vim.api
local config = require("claude-code.config")

local ns = api.nvim_create_namespace("claude-code.tables")

local BORDER = "ClaudeCodeTableBorder"
local HEADER = "ClaudeCodeTableHeader"

local M = {}

---@type table<integer, { first: integer, last: integer }>
local dirty = {}

local table_query ---@type vim.treesitter.Query?

---@type table<string, integer>
local widths = {}
local cached = 0

--- Display width of a cell's markdown once conceal (conceallevel=2) has hidden its
--- markup: code span backticks, emphasis markers, link destinations and so on. Asks
--- the markdown_inline highlight query, so it agrees with what's on screen.
---@param text string
---@return integer
local function visible_width(text)
  if widths[text] then
    return widths[text]
  end
  local width = vim.fn.strdisplaywidth(text)
  local ok, parser = pcall(vim.treesitter.get_string_parser, text, "markdown_inline")
  local query = ok and vim.treesitter.query.get("markdown_inline", "highlights")
  local tree = ok and parser:parse()[1]
  if query and tree then
    local hidden, replaced = {}, {}
    for _, node, metadata in query:iter_captures(tree:root(), text) do
      local conceal = metadata.conceal
      if conceal then
        local _, s, _, e = node:range()
        for i = s + 1, e do
          hidden[i] = true
        end
        if conceal ~= "" then
          replaced[s + 1] = conceal
        end
      end
    end
    local shown = {}
    for i = 1, #text do
      if replaced[i] then
        shown[#shown + 1] = replaced[i]
      elseif not hidden[i] then
        shown[#shown + 1] = text:sub(i, i)
      end
    end
    width = vim.fn.strdisplaywidth(table.concat(shown))
  end
  if cached > 2000 then
    widths, cached = {}, 0
  end
  widths[text], cached = width, cached + 1
  return width
end

---@class claude_code.TableCell
---@field s integer Start of the cell's span between pipes (0-based byte col).
---@field e integer End of that span (exclusive).
---@field cs integer Start of its content, surrounding whitespace excluded.
---@field ce integer End of its content (exclusive).
---@field text string
---@field pipe? integer Column of the pipe closing the cell, if it has one.

---@class claude_code.TableRow
---@field row integer
---@field col integer Where the row starts (past any list or quote prefix).
---@field lead? integer Column of the leading pipe, if the row has one.
---@field cells claude_code.TableCell[]
---@field header boolean

---@param buf integer
---@param node TSNode pipe_table_header or pipe_table_row
---@return claude_code.TableRow
local function parse_row(buf, node)
  local row, col = node:range()
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  ---@type claude_code.TableRow
  local r = { row = row, col = col, cells = {}, header = node:type() == "pipe_table_header" }
  local pipes = {}
  local last_end = col
  for child in node:iter_children() do
    local _, cs, _, ce = child:range()
    if child:type() == "|" then
      pipes[#pipes + 1] = cs
    end
    last_end = math.max(last_end, ce)
  end
  local start = col
  local i = 1
  if pipes[1] and vim.trim(line:sub(col + 1, pipes[1])) == "" then
    r.lead = pipes[1]
    start = pipes[1] + 1
    i = 2
  end
  local function cell(s, e, pipe)
    local text = line:sub(s + 1, e)
    local lead_ws = #text:match("^%s*")
    local content = vim.trim(text)
    local cs = s + lead_ws
    r.cells[#r.cells + 1] = { s = s, e = e, cs = cs, ce = cs + #content, text = content, pipe = pipe }
  end
  for j = i, #pipes do
    cell(start, pipes[j], pipes[j])
    start = pipes[j] + 1
  end
  -- A last cell with no closing pipe.
  if last_end > start and vim.trim(line:sub(start + 1, last_end)) ~= "" then
    cell(start, last_end, nil)
  end
  return r
end

---@param node TSNode pipe_table_delimiter_row
---@return ("left"|"right"|"center")[]
local function alignments(node)
  local aligns = {}
  for child in node:iter_children() do
    if child:type() == "pipe_table_delimiter_cell" then
      local left, right = false, false
      for c in child:iter_children() do
        left = left or c:type() == "pipe_table_align_left"
        right = right or c:type() == "pipe_table_align_right"
      end
      aligns[#aligns + 1] = (left and right) and "center" or right and "right" or "left"
    end
  end
  return aligns
end

---@param buf integer
---@param row integer
---@param col integer
---@param opts vim.api.keyset.set_extmark
local function mark(buf, row, col, opts)
  pcall(api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

---@param buf integer
---@param row integer
---@param s integer
---@param e integer
local function conceal(buf, row, s, e)
  if e > s then
    mark(buf, row, s, { end_col = e, conceal = "" })
  end
end

---@param buf integer
---@param row integer
---@param col integer
---@param text string
---@param hl? string
local function inline(buf, row, col, text, hl)
  if text ~= "" then
    mark(buf, row, col, { virt_text = { { text, hl or BORDER } }, virt_text_pos = "inline" })
  end
end

---@param left string
---@param mid string
---@param right string
---@param cols integer[]
local function rule(left, mid, right, cols)
  local parts = {}
  for i, w in ipairs(cols) do
    parts[i] = string.rep("─", w + 2)
  end
  return left .. table.concat(parts, mid) .. right
end

---@param buf integer
---@param r claude_code.TableRow
---@param cols integer[]
---@param aligns string[]
local function render_row(buf, r, cols, aligns)
  local row = r.row
  if r.lead then
    mark(buf, row, r.lead, { virt_text = { { "│", BORDER } }, virt_text_pos = "overlay" })
  else
    inline(buf, row, r.col, "│")
  end
  local tail = r.lead and r.lead + 1 or r.col
  for i, c in ipairs(r.cells) do
    local pad = cols[i] - visible_width(c.text)
    local left = aligns[i] == "right" and pad or aligns[i] == "center" and math.floor(pad / 2) or 0
    if c.text == "" then
      conceal(buf, row, c.s, c.e)
      inline(buf, row, c.s, string.rep(" ", cols[i] + 2))
    else
      conceal(buf, row, c.s, c.cs)
      conceal(buf, row, c.ce, c.e)
      inline(buf, row, c.cs, string.rep(" ", left + 1))
      inline(buf, row, c.ce, string.rep(" ", pad - left + 1))
      if r.header then
        mark(buf, row, c.cs, { end_col = c.ce, hl_group = HEADER })
      end
    end
    if c.pipe then
      mark(buf, row, c.pipe, { virt_text = { { "│", BORDER } }, virt_text_pos = "overlay" })
      tail = c.pipe + 1
    else
      tail = c.e
    end
  end
  -- Close off a row with no trailing pipe, and pad out one with too few cells.
  local rest = r.cells[#r.cells] and not r.cells[#r.cells].pipe and "│" or ""
  for i = #r.cells + 1, #cols do
    rest = rest .. string.rep(" ", cols[i] + 2) .. "│"
  end
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  conceal(buf, row, tail, #line)
  inline(buf, row, tail, rest)
end

---@param buf integer
---@param node TSNode pipe_table
local function render(buf, node)
  local delimiter ---@type TSNode?
  local rows = {} ---@type claude_code.TableRow[]
  for child in node:iter_children() do
    local type = child:type()
    if type == "pipe_table_delimiter_row" then
      delimiter = child
    elseif type == "pipe_table_header" or type == "pipe_table_row" then
      rows[#rows + 1] = parse_row(buf, child)
    end
  end
  if not delimiter or #rows == 0 then
    return
  end
  local aligns = alignments(delimiter)
  local cols = {} ---@type integer[]
  for i = 1, #aligns do
    cols[i] = 1
  end
  for _, r in ipairs(rows) do
    for i, c in ipairs(r.cells) do
      cols[i] = math.max(cols[i] or 1, visible_width(c.text))
    end
  end

  for _, r in ipairs(rows) do
    render_row(buf, r, cols, aligns)
  end

  local drow, dcol = delimiter:range()
  local dline = api.nvim_buf_get_lines(buf, drow, drow + 1, false)[1] or ""
  conceal(buf, drow, dcol, #dline)
  inline(buf, drow, dcol, rule("├", "┼", "┤", cols))

  -- Borders above and below, indented to line up with a table inside a list or quote.
  local first, last = rows[1], rows[#rows]
  local function indent(r)
    local line = api.nvim_buf_get_lines(buf, r.row, r.row + 1, false)[1] or ""
    return string.rep(" ", vim.fn.strdisplaywidth(line:sub(1, r.col)))
  end
  mark(buf, first.row, 0, {
    virt_lines = { { { indent(first), BORDER }, { rule("┌", "┬", "┐", cols), BORDER } } },
    virt_lines_above = true,
  })
  mark(buf, last.row, 0, {
    virt_lines = { { { indent(last), BORDER }, { rule("└", "┴", "┘", cols), BORDER } } },
  })
end

--- Re-render the tables touching rows [first, last].
---@param buf integer
---@param first integer
---@param last integer
local function refresh(buf, first, last)
  if not config.options.markdown.enabled then
    api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    return
  end
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown", { error = false })
  local tree = ok and parser and parser:parse()[1]
  if not tree then
    return
  end
  table_query = table_query or vim.treesitter.query.parse("markdown", "(pipe_table) @table")
  local tables = {} ---@type TSNode[]
  local lo, hi = first, last
  for _, node in table_query:iter_captures(tree:root(), buf, first, last + 1) do
    local s, _, e = node:range()
    lo, hi = math.min(lo, s), math.max(hi, e)
    tables[#tables + 1] = node
  end
  api.nvim_buf_clear_namespace(buf, ns, lo, hi + 1)
  for _, node in ipairs(tables) do
    render(buf, node)
  end
end

---@param buf integer
local function flush(buf)
  local range = dirty[buf]
  dirty[buf] = nil
  if range and api.nvim_buf_is_valid(buf) then
    refresh(buf, range.first, range.last)
  end
end

---@param buf integer
function M.attach(buf)
  api.nvim_buf_attach(buf, false, {
    on_lines = function(_, _, _, first, _, new_last)
      local range = dirty[buf]
      if range then
        range.first, range.last = math.min(range.first, first), math.max(range.last, new_last)
      else
        -- Coalesce a burst of streamed chunks into one render.
        dirty[buf] = { first = first, last = new_last }
        vim.schedule(function()
          flush(buf)
        end)
      end
    end,
    on_detach = function()
      dirty[buf] = nil
    end,
  })
  refresh(buf, 0, api.nvim_buf_line_count(buf))
end

return M
