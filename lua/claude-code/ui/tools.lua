-- How tool calls are described: the one-line detail next to the tool name, the
-- summary under it, and the expanded body (output or diff).

local config = require("claude-code.config")

local M = {}

---@alias claude_code.Chunk [string, string] Text and highlight group.
---@alias claude_code.VirtLine claude_code.Chunk[]

--- The most descriptive single input field of a tool call.
---@param input table
---@return string?
function M.detail(input)
  local path = input.file_path or input.notebook_path or input.path
  if type(path) == "string" then
    return vim.fn.fnamemodify(path, ":~:.")
  end
  local detail = input.command or input.pattern or input.url or input.query or input.description
  if type(detail) ~= "string" then
    return nil
  end
  return (detail:gsub("\n.*", " …"))
end

---@param content string|table[]|nil tool_result content
---@return string
function M.result_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(content or {}) do
    if block.type == "text" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, "\n")
end

---@param text string
---@param width integer
local function truncate(text, width)
  if vim.fn.strchars(text) > width then
    return vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text
end

--- One line describing a tool's output.
---@param name string
---@param input table
---@param text string
---@param is_error boolean
---@return string?
function M.summarize(name, input, text, is_error)
  if not is_error then
    if name == "Edit" or name == "MultiEdit" then
      local added, removed = 0, 0
      for _, line in ipairs(M.diff_lines(input)) do
        if line[1]:sub(1, 1) == "+" then
          added = added + 1
        elseif line[1]:sub(1, 1) == "-" then
          removed = removed + 1
        end
      end
      return ("+%d -%d"):format(added, removed)
    elseif name == "AskUserQuestion" then
      -- The result reads: User has answered your questions: "Q"="A", "Q2"="A2". ...
      local answers = {}
      for answer in text:gmatch('"=(%b"")') do
        table.insert(answers, answer:sub(2, -2))
      end
      if #answers > 0 then
        return truncate(table.concat(answers, " · "), 120)
      end
    elseif name == "Write" and type(input.content) == "string" then
      return ("%d lines written"):format(#vim.split(input.content, "\n", { plain = true, trimempty = true }))
    end
  end
  text = vim.trim(text)
  if text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true, trimempty = true })
  local summary
  if not is_error then
    summary = #lines > 1 and ("%d lines"):format(#lines) or lines[1]
  else
    -- The first line is often just "Exit code N"; the reason follows it.
    summary = table.concat(vim.list_slice(lines, 1, 2), " · ")
  end
  return truncate(summary, 120)
end

--- Unified diff lines for an Edit/MultiEdit/Write input, without file headers.
---@param input table
---@return claude_code.Chunk[] lines Each is { text, hl }.
function M.diff_lines(input)
  local edits = input.edits
  if type(edits) ~= "table" then
    edits = { { old_string = input.old_string or "", new_string = input.new_string or input.content or "" } }
  end
  local out = {}
  for _, edit in ipairs(edits) do
    local old = (edit.old_string or "") .. "\n"
    local new = (edit.new_string or "") .. "\n"
    local diff = vim.diff(old, new, { result_type = "unified", ctxlen = 2 }) --[[@as string]]
    for _, line in ipairs(vim.split(diff, "\n", { plain = true, trimempty = true })) do
      local first = line:sub(1, 1)
      if first == "+" then
        table.insert(out, { line, "DiffAdd" })
      elseif first == "-" then
        table.insert(out, { line, "DiffDelete" })
      elseif first == "@" then
        table.insert(out, { "⋯", "ClaudeCodeToolGutter" })
      else
        table.insert(out, { line, "ClaudeCodeToolOutput" })
      end
    end
  end
  return out
end

--- The expanded view of a tool call: its diff for edits, otherwise its output.
---@param name string
---@param input table
---@param result? string Output text; nil while the tool is still running.
---@param width integer Available columns.
---@return claude_code.VirtLine[]
function M.body(name, input, result, width)
  local lines ---@type claude_code.Chunk[]
  if name == "Edit" or name == "MultiEdit" or name == "Write" then
    lines = M.diff_lines(input)
  elseif name == "Bash" and type(input.command) == "string" then
    lines = { { "$ " .. input.command:gsub("\n", " "), "ClaudeCodeToolDetail" } }
    for _, line in ipairs(vim.split(vim.trim(result or ""), "\n", { plain = true })) do
      table.insert(lines, { line, "ClaudeCodeToolOutput" })
    end
  else
    lines = {}
    for _, line in ipairs(vim.split(vim.trim(result or ""), "\n", { plain = true })) do
      table.insert(lines, { line, "ClaudeCodeToolOutput" })
    end
  end

  local max = config.options.tool_output.max_lines
  local virt = {} ---@type claude_code.VirtLine[]
  for i, line in ipairs(lines) do
    if i > max then
      table.insert(virt, { { "  │ ", "ClaudeCodeToolGutter" }, { ("… %d more lines"):format(#lines - max), "ClaudeCodeMuted" } })
      break
    end
    local text = truncate(line[1]:gsub("\t", "  "), math.max(width - 4, 10))
    table.insert(virt, { { "  │ ", "ClaudeCodeToolGutter" }, { text, line[2] } })
  end
  if #virt == 0 then
    virt = { { { "  │ ", "ClaudeCodeToolGutter" }, { "(no output)", "ClaudeCodeMuted" } } }
  end
  return virt
end

return M
