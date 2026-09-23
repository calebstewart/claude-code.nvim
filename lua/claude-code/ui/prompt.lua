-- The editable prompt buffer shown in the chat's floating input box.

local api = vim.api
local config = require("claude-code.config")

local ns = api.nvim_create_namespace("claude-code.prompt")

---@class claude_code.Prompt
---@field buf integer
---@field private placeholder? integer extmark id
---@field private session_id fun(): string?
---@field private history? string[] Snapshot taken when browsing starts.
---@field private history_index? integer Entry being shown; nil while editing a fresh prompt.
---@field private draft? string The fresh prompt, kept while browsing history.
local Prompt = {}
Prompt.__index = Prompt

---@param name string
---@param on_change fun() Called after every edit, e.g. to fit the window to the text.
---@param session_id? fun(): string? Current Claude session, to rank its prompts first in history.
---@return claude_code.Prompt
function Prompt.new(name, on_change, session_id)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "claude-code-prompt"
  api.nvim_buf_set_name(buf, name)
  pcall(vim.treesitter.start, buf, "markdown")
  local self = setmetatable({ buf = buf, session_id = session_id or function() end }, Prompt)

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      self:update_placeholder()
      on_change()
    end,
  })
  self:update_placeholder()
  return self
end

function Prompt:valid()
  return api.nvim_buf_is_valid(self.buf)
end

---@return string
function Prompt:text()
  return vim.trim(table.concat(api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n"))
end

function Prompt:clear()
  api.nvim_buf_set_lines(self.buf, 0, -1, false, {})
  self.history, self.history_index, self.draft = nil, nil, nil
  self:update_placeholder()
end

--- Step through prompt history, like the CLI's up/down arrows. Only acts when
--- the cursor is on the first line (going back) or last line (going forward),
--- so arrows still move around inside a multi-line prompt.
---@param delta -1|1
---@return boolean handled
function Prompt:recall(delta)
  local cursor = api.nvim_win_get_cursor(0)
  local last = api.nvim_buf_line_count(self.buf)
  if (delta < 0 and cursor[1] ~= 1) or (delta > 0 and cursor[1] ~= last) then
    return false
  end
  local index = self.history_index
  if not index then
    if delta > 0 then
      return false
    end
    -- Read fresh each time browsing starts, so prompts from other sessions show up.
    self.history = require("claude-code.history").entries(self.session_id())
    if #self.history == 0 then
      return false
    end
    self.draft = table.concat(api.nvim_buf_get_lines(self.buf, 0, -1, false), "\n")
    index = #self.history + 1
  end
  local entries = self.history or {}
  index = index + delta
  if index < 1 then
    return true -- already at the oldest entry
  end
  local text
  if index > #entries then
    text, self.history, self.history_index, self.draft = self.draft or "", nil, nil, nil
  else
    text, self.history_index = entries[index], index
  end
  local lines = vim.split(text, "\n", { plain = true })
  api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
  -- Land on the edge line in the direction of travel, so the next press keeps going.
  local row = delta < 0 and 1 or #lines
  local col = #lines[row]
  if api.nvim_get_mode().mode ~= "i" then
    col = math.max(col - 1, 0)
  end
  api.nvim_win_set_cursor(0, { row, col })
  self:update_placeholder()
  return true
end

---@private
function Prompt:update_placeholder()
  local empty = api.nvim_buf_line_count(self.buf) == 1 and api.nvim_buf_get_lines(self.buf, 0, 1, false)[1] == ""
  if empty and not self.placeholder then
    self.placeholder = api.nvim_buf_set_extmark(self.buf, ns, 0, 0, {
      virt_text = { { "Ask Claude anything…", "ClaudeCodePlaceholder" } },
      virt_text_pos = "overlay",
    })
  elseif not empty and self.placeholder then
    api.nvim_buf_del_extmark(self.buf, ns, self.placeholder)
    self.placeholder = nil
  end
end

--- Rows the text needs in `win`, within the configured bounds.
---@param win integer
---@return integer
function Prompt:height(win)
  local bounds = config.options.window.prompt_height
  local height = api.nvim_win_text_height(win, {}).all
  return math.min(math.max(height, bounds.min), bounds.max)
end

return Prompt
