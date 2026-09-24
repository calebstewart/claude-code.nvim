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

---@class claude_code.SubagentTool
---@field id string
---@field name string
---@field input table
---@field status "pending"|"success"|"error"

--- What a subagent (an Agent/Task tool call) is doing, gathered from its own
--- messages and the SDK's task events.
---@class claude_code.Subagent
---@field description? string
---@field kind? string Subagent type (e.g. "general-purpose").
---@field background? boolean Launched with run_in_background.
---@field status string "running", then "completed", "failed" or "stopped".
---@field activity? string Latest progress, e.g. "Running Print contents of one.txt".
---@field usage? { total_tokens: integer, tool_uses: integer, duration_ms: integer }
---@field started integer os.time()
---@field tools claude_code.SubagentTool[] Its own tool calls, in order.
---@field index table<string, integer> tool_use id -> position in `tools`.
---@field report? string Its last text (the report it hands back).

---@param sub claude_code.Subagent
local function stats(sub)
  local parts = {}
  local count = sub.usage and sub.usage.tool_uses or #sub.tools
  if count > 0 then
    table.insert(parts, ("%d tool%s"):format(count, count == 1 and "" or "s"))
  end
  local ms = sub.usage and sub.usage.duration_ms or (os.time() - sub.started) * 1000
  if ms >= 1000 then
    table.insert(parts, ("%ds"):format(math.floor(ms / 1000)))
  end
  return parts
end

--- The live line under a running subagent: what it's doing and how far along.
---@param sub claude_code.Subagent
---@return string
function M.subagent_activity(sub)
  local parts = { sub.activity or (sub.background and "Running in the background" or "Starting…") }
  vim.list_extend(parts, stats(sub))
  return truncate(table.concat(parts, " · "), 120)
end

--- The summary once it's done.
---@param sub claude_code.Subagent
---@return string
function M.subagent_summary(sub)
  local parts = { sub.status == "completed" and "Done" or (sub.status:gsub("^%l", string.upper)) }
  vim.list_extend(parts, stats(sub))
  return table.concat(parts, " · ")
end

--- Expanded subagent: its tool calls with their status, then its report.
---@param sub claude_code.Subagent
---@param result? string The Agent tool's result (the report), if it's back.
---@param width integer
---@return claude_code.VirtLine[]
function M.subagent_body(sub, result, width)
  local gutter = { "  │ ", "ClaudeCodeToolGutter" }
  local virt = {} ---@type claude_code.VirtLine[]
  local header = { sub.kind or "subagent" }
  if sub.background then
    table.insert(header, "background")
  end
  table.insert(virt, { gutter, { table.concat(header, " · "), "ClaudeCodeToolDetail" } })
  local status_icon = {
    pending = { "…", "ClaudeCodeToolPending" },
    success = { "✓", "ClaudeCodeToolSuccess" },
    error = { "✗", "ClaudeCodeToolError" },
  }
  for _, t in ipairs(sub.tools) do
    local detail = M.detail(t.input)
    local mark = status_icon[t.status] or status_icon.pending
    table.insert(virt, {
      gutter,
      { mark[1] .. " ", mark[2] },
      { require("claude-code.ui.icons").tool(t.name) .. " " .. t.name, "ClaudeCodeToolName" },
      { detail and (" " .. truncate(detail, math.max(width - #t.name - 12, 10))) or "", "ClaudeCodeToolDetail" },
    })
  end
  local report = vim.trim(result or sub.report or "")
  if report ~= "" then
    table.insert(virt, { gutter })
    local max = config.options.tool_output.max_lines
    local lines = vim.split(report, "\n", { plain = true })
    for i, line in ipairs(lines) do
      if i > max then
        table.insert(virt, { gutter, { ("… %d more lines"):format(#lines - max), "ClaudeCodeMuted" } })
        break
      end
      table.insert(virt, { gutter, { truncate(line:gsub("\t", "  "), math.max(width - 4, 10)), "ClaudeCodeToolOutput" } })
    end
  end
  return virt
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
  elseif (name == "Bash" or name == "Shell") and type(input.command) == "string" then
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
