-- Bordered cards drawn as virtual lines in the transcript: permission prompts,
-- plans, and messages held back from other sessions.

local M = {}

--- Word-wrap `text` to `width` columns.
---@param text string
---@param width integer
---@return string[]
function M.wrap(text, width)
  local rows = {}
  for _, para in ipairs(vim.split(text, "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      if line == "" then
        line = word
      elseif vim.fn.strdisplaywidth(line .. " " .. word) <= width then
        line = line .. " " .. word
      else
        table.insert(rows, line)
        line = word
      end
    end
    table.insert(rows, line)
  end
  return rows
end

--- Columns inside a card's border for a window `width` wide.
---@param width integer
---@return integer
function M.inner(width)
  return math.max(width - 6, 20)
end

--- A bordered card: a heading in the top edge, then rows of chunks, each
--- padded (or clipped) to the card's inner width.
---@param width integer Window width.
---@param heading string
---@param rows claude_code.Chunk[][]
---@return claude_code.VirtLine[]
function M.frame(width, heading, rows)
  local inner = M.inner(width)
  local lines = {
    {
      { "  ", "Normal" },
      { "╭─ ", "ClaudeCodeCardBorder" },
      { heading .. " ", "ClaudeCodeCardTitle" },
      { string.rep("─", math.max(inner - vim.fn.strdisplaywidth(heading) - 1, 0)) .. "╮", "ClaudeCodeCardBorder" },
    },
  }
  for _, row in ipairs(rows) do
    local line = { { "  ", "Normal" }, { "│ ", "ClaudeCodeCardBorder" } }
    local used = 0
    for _, chunk in ipairs(row) do
      local text = chunk[1]:gsub("\t", "  ")
      local room = inner - used
      if room <= 0 then
        break
      end
      if vim.fn.strdisplaywidth(text) > room then
        text = vim.fn.strcharpart(text, 0, room - 1) .. "…"
      end
      table.insert(line, { text, chunk[2] })
      used = used + vim.fn.strdisplaywidth(text)
    end
    table.insert(line, { string.rep(" ", math.max(inner - used, 0)), "ClaudeCodeCardText" })
    table.insert(line, { " │", "ClaudeCodeCardBorder" })
    table.insert(lines, line)
  end
  table.insert(
    lines,
    { { "  ", "Normal" }, { "╰" .. string.rep("─", inner + 2) .. "╯", "ClaudeCodeCardBorder" } }
  )
  return lines
end

--- A key and what it does, for a card's row of choices.
---@param key string
---@param label string
---@param hl? string
---@return claude_code.Chunk[]
function M.choice(key, label, hl)
  return { { " " .. key .. " ", hl or "ClaudeCodeCardKey" }, { " " .. label .. "   ", "ClaudeCodeCardText" } }
end

return M
