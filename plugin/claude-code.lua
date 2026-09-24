if vim.g.loaded_claude_code then
  return
end
vim.g.loaded_claude_code = true

local subcommands = {
  open = function()
    require("claude-code").open()
  end,
  toggle = function()
    require("claude-code").toggle()
  end,
  here = function()
    require("claude-code").here()
  end,
  send = function(args)
    require("claude-code").send(args)
  end,
  interrupt = function()
    require("claude-code").interrupt()
  end,
  stop = function()
    require("claude-code").stop()
  end,
  sessions = function()
    require("claude-code").sessions()
  end,
  new = function(args)
    require("claude-code").new(args)
  end,
  rename = function(args)
    require("claude-code").rename(args)
  end,
  mode = function(args)
    require("claude-code").mode(args)
  end,
  image = function(args)
    require("claude-code").image(args)
  end,
  deliver = function()
    require("claude-code").deliver()
  end,
  next = function()
    require("claude-code").next()
  end,
  prev = function()
    require("claude-code").prev()
  end,
}

vim.api.nvim_create_user_command("Claude", function(cmd)
  local name, rest = cmd.args:match("^(%S*)%s*(.*)$")
  if name == "" then
    name = "open"
  end
  local fn = subcommands[name]
  if not fn then
    vim.notify("claude-code: unknown subcommand `" .. name .. "`", vim.log.levels.ERROR)
    return
  end
  fn(rest)
end, {
  nargs = "*",
  desc = "Claude Code",
  complete = function(arg_lead, line)
    if line:match("^%S+%s+image%s+") then
      return vim.fn.getcompletion(arg_lead, "file")
    end
    if line:match("^%S+%s+mode%s+%S*$") then
      return vim.tbl_filter(function(mode)
        return vim.startswith(mode, arg_lead)
      end, require("claude-code.modes").all)
    end
    if line:match("^%S+%s+%S+%s") then
      return {}
    end
    return vim.tbl_filter(function(name)
      return vim.startswith(name, arg_lead)
    end, vim.tbl_keys(subcommands))
  end,
})
