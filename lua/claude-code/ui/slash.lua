-- Slash-command completion in the prompt, like the CLI's: typing `/` at the
-- start of the prompt opens Neovim's completion menu with the session's
-- commands and skills, filtered (fuzzily) as you type. <Tab> completes.
--
-- Other completion engines (nvim-cmp, blink.cmp) are paused while a slash
-- command is being typed so their menus don't compete with this one.

local api = vim.api

local M = {}

---@class claude_code.SlashCommand
---@field name string Without the leading slash.
---@field description string
---@field argumentHint? string
---@field aliases? string[]
---@field builtin? boolean

--- The command being typed, if the cursor is in a leading `/word` on the first line.
---@param buf integer
---@return string? query Text after the slash.
function M.query(buf)
  if api.nvim_get_current_buf() ~= buf then
    return nil
  end
  local row, col = unpack(api.nvim_win_get_cursor(0))
  if row ~= 1 then
    return nil
  end
  local before = api.nvim_buf_get_lines(buf, 0, 1, false)[1]:sub(1, col)
  return before:match("^/([%w%-_:%.]*)$")
end

---@param text string
---@param width integer
local function clip(text, width)
  text = text:gsub("%s+", " ")
  if vim.fn.strchars(text) > width then
    return vim.fn.strcharpart(text, 0, width - 1) .. "…"
  end
  return text
end

---@param commands claude_code.SlashCommand[]
---@param query string
---@return table[] complete-items
local function items(commands, query)
  local matches
  if query == "" then
    matches = vim.list_extend({}, commands)
    table.sort(matches, function(a, b)
      return a.name < b.name
    end)
  else
    matches = vim.fn.matchfuzzy(commands, query, {
      text_cb = function(c)
        return c.name .. " " .. table.concat(c.aliases or {}, " ")
      end,
    })
  end
  local out = {}
  for _, c in ipairs(matches) do
    local hint = c.argumentHint and c.argumentHint ~= "" and (" " .. c.argumentHint) or ""
    table.insert(out, {
      word = "/" .. c.name,
      abbr = "/" .. c.name .. hint,
      menu = clip(c.description or "", 60),
      info = c.description ~= "" and c.description or nil,
      kind = c.builtin and "" or (c.name:find(":", 1, true) and "plugin" or "skill"),
      dup = 1,
    })
  end
  return out
end

--- Pause other completion engines while a slash command is typed.
---@param buf integer
local function quiet_other_completers(buf)
  local ok, cmp = pcall(require, "cmp")
  if ok and cmp.setup and cmp.setup.buffer then
    api.nvim_buf_call(buf, function()
      cmp.setup.buffer({
        enabled = function()
          return M.query(buf) == nil
        end,
      })
    end)
    return true
  end
  return false
end

---@param buf integer Prompt buffer.
---@param get_commands fun(): claude_code.SlashCommand[]
function M.attach(buf, get_commands)
  -- menuone: show for a single match; noinsert: highlight the first without inserting it.
  pcall(function()
    vim.bo[buf].completeopt = "menuone,noinsert,popup"
  end)

  local active = false
  local cmp_quieted = false
  local group = api.nvim_create_augroup("claude-code.slash." .. buf, { clear = true })
  api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = buf,
    callback = function()
      -- nvim-cmp usually loads lazily on InsertEnter, so try again until it's there.
      if not cmp_quieted then
        vim.schedule(function()
          cmp_quieted = quiet_other_completers(buf)
        end)
      end
    end,
  })
  api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    group = group,
    buffer = buf,
    callback = function()
      local query = M.query(buf)
      vim.b[buf].completion = query == nil -- blink.cmp honours this
      if not query then
        if active and vim.fn.pumvisible() == 1 then
          vim.fn.complete(vim.fn.col("."), {})
        end
        active = false
        return
      end
      if active and vim.fn.pumvisible() == 1 then
        -- Moving through the menu inserts the highlighted item; that's not new
        -- input to filter on.
        local info = vim.fn.complete_info({ "selected", "items" })
        local selected = info.selected >= 0 and info.items[info.selected + 1]
        if selected and selected.word == "/" .. query then
          return
        end
      end
      local list = items(get_commands(), query)
      active = #list > 0
      -- Replace the whole `/word` (it starts in column 1).
      vim.fn.complete(1, list)
    end,
  })
  api.nvim_create_autocmd("InsertLeave", {
    group = group,
    buffer = buf,
    callback = function()
      active = false
    end,
  })

  --- Is our menu the one showing?
  local function ours()
    return active and vim.fn.pumvisible() == 1
  end
  local function expr(lhs, when_ours)
    vim.keymap.set("i", lhs, function()
      if ours() then
        return when_ours
      end
      return api.nvim_replace_termcodes(lhs, true, false, true)
    end, { buffer = buf, expr = true, replace_keycodes = false, desc = "Claude: slash command completion" })
  end
  local ctrl_y = api.nvim_replace_termcodes("<C-y>", true, false, true)
  -- Complete the highlighted command, ready for its arguments.
  expr("<Tab>", ctrl_y .. " ")
  expr("<CR>", ctrl_y)

  return {
    --- For the prompt's own arrow-key handling (history): is our menu open?
    menu_open = ours,
  }
end

return M
