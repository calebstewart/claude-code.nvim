-- A small floating single-line input, e.g. for naming a session.

local api = vim.api

local M = {}

---@class claude_code.InputOpts
---@field title string
---@field default? string
---@field on_submit fun(text: string)
---@field on_cancel? fun()

---@param opts claude_code.InputOpts
function M.open(opts)
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default or "" })
  local width = math.min(math.max(50, vim.fn.strdisplaywidth(opts.default or "") + 10), vim.o.columns - 4)
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - 3) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    zindex = 80,
    title = { { " " .. opts.title .. " ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
    footer = { { " ⏎ ok · esc cancel ", "ClaudeCodeMuted" } },
    footer_pos = "right",
  })
  vim.wo[win].winhighlight = "NormalFloat:ClaudeCodePicker,FloatBorder:ClaudeCodePickerBorder"

  local done = false
  local function finish(submit)
    if done then
      return
    end
    done = true
    local text = vim.trim(api.nvim_buf_get_lines(buf, 0, 1, false)[1] or "")
    vim.cmd("stopinsert")
    pcall(api.nvim_win_close, win, true)
    if submit then
      opts.on_submit(text)
    elseif opts.on_cancel then
      opts.on_cancel()
    end
  end
  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, "<CR>", function()
      finish(true)
    end, { buffer = buf })
    vim.keymap.set(mode, "<Esc>", function()
      finish(false)
    end, { buffer = buf })
    vim.keymap.set(mode, "<C-c>", function()
      finish(false)
    end, { buffer = buf })
  end
  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(false)
      end)
    end,
  })
  vim.cmd("startinsert!")
end

return M
