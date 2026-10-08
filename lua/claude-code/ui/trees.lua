-- The `wt` tree picker (`:Claude trees`), laid out like the session picker:
--
--   ╭ trees ─────────────────────╮╭ preview ─────────────────╮
--   │ ● fix-login  slot 1 · “Fix…”││ branch, slot, path       │
--   │ ○ parser     slot 2 · ended ││ state, holder            │
--   ╰────────────────────────────╯│ sessions open in it, env │
--   ╭ search ────────────────────╮│                          │
--   ╰────────────────────────────╯╰────────────── key hints ─╯
--
-- Lists `wt list` for the current project (or every project's, with <C-g>).
-- The actions are in claude-code.trees; the list reloads after each one, on
-- `User ClaudeCodeWorktreesChanged`, and when Neovim regains focus.
--
-- Its cleanup mode (`:Claude cleanup`, or <C-l>) lists the project's stale
-- trees instead (`wt cleanup --stale`'s dry run): the ones to remove, the ones
-- `wt` would skip, and the ones kept for being in use here, each with why.
-- <CR> removes the batch, after one confirmation (trees.remove_stale).

local api = vim.api
local events = require("claude-code.events")
local icons = require("claude-code.ui.icons")
local listing = require("claude-code.listing")
local sessions = require("claude-code.sessions")
local trees = require("claude-code.trees")
local worktree = require("claude-code.worktree")

local ns = api.nvim_create_namespace("claude-code.trees")

local M = {}

---@class claude_code.TreePickerState
---@field mode? "trees"|"cleanup" Default "trees".
---@field scope "project"|"all" Of "trees"; "cleanup" is always the project's.
---@field query string
---@field selected? string Key (trees.key) of the selected tree.

---@param text string
---@param width integer
local function clip(text, width)
  if vim.fn.strdisplaywidth(text) > width then
    return vim.fn.strcharpart(text, 0, math.max(width - 1, 0)) .. "…"
  end
  return text
end

---@class claude_code.TreePicker
---@field private state claude_code.TreePickerState
---@field private trees table[] `wt list` entries.
---@field private shown table[] After filtering.
---@field private index integer Selected row in `shown`.
---@field private error? string Why the list couldn't be loaded.
---@field private loading boolean
---@field private generation integer Bumped per load, so an older load's answer is dropped.
---@field private bufs { list: integer, prompt: integer, preview: integer }
---@field private wins { list?: integer, prompt?: integer, preview?: integer }
---@field private closed boolean
---@field private augroup integer
---@field private unsubscribe fun()
---@field private stale table<string, claude_code.StaleTree> In cleanup mode, by tree (trees.key).
---@field private excluded table<string, boolean> Trees left out of the cleanup (<Tab>), by trees.key.
---@field private reclaimed table<string, boolean> See trees.stale.
---@field private reload_pending? boolean In cleanup mode, a reload is about to run.
local Picker = {}
Picker.__index = Picker

--- The holder in a few words, for a row.
---@param tree table
---@return string
local function holder_short(tree)
  local holder = type(tree.holder) == "table" and tree.holder or {}
  if not holder.session then
    return "free"
  end
  local open = sessions.find(holder.session)
  local who = open and ("“%s”"):format(clip(open.title or "New session", 24))
    or (type(holder.label) == "string" and holder.label ~= "" and ("“%s”"):format(clip(holder.label, 24)))
    or tostring(holder.session):sub(1, 8)
  return holder.state == "live" and who or (who .. ", ended")
end

--- Status glyph and highlight for a tree (an action under way, its state, or
--- who holds it), and its state in words.
---@param tree table
---@return string glyph, string hl, string label
local function status(tree)
  local doing = trees.busy(tree)
  if doing then
    return "…", "ClaudeCodeStatus", doing .. "…"
  end
  if tree.exists == false then
    return icons.get().error, "DiagnosticError", "its directory is gone"
  end
  if tree.state == "broken" then
    return icons.get().error, "DiagnosticError", "broken" .. (tree.last_error and (": " .. tree.last_error) or "")
  end
  if tree.state and tree.state ~= "ready" then
    return "…", "ClaudeCodeStatus", tree.state:gsub("_", " ")
  end
  local holder = type(tree.holder) == "table" and tree.holder or {}
  if holder.state == "live" then
    if sessions.find(holder.session) or holder.pid == vim.fn.getpid() then
      return "●", "ClaudeCodeToolSuccess", "ready"
    end
    return "◆", "DiagnosticWarn", "ready"
  elseif holder.state == "ended" then
    return "○", "ClaudeCodeMuted", "ready"
  end
  return " ", "Normal", "ready"
end

--- The order of a cleanup's rows: what's removed first.
local STALE_ORDER = { remove = 1, skip = 2, keep = 3 }

--- In cleanup mode: a stale tree's glyph and highlight, and what happens to it,
--- in a few words.
---@param entry claude_code.StaleTree
---@param excluded? boolean
---@return string glyph, string hl, string label
local function stale_status(entry, excluded)
  local doing = trees.busy(entry.tree)
  if doing then
    return "…", "ClaudeCodeStatus", doing .. "…"
  end
  if entry.status == "keep" then
    return "●", "ClaudeCodeToolSuccess", "kept: in use here"
  elseif entry.status == "skip" then
    return "!", "DiagnosticWarn", "skipped"
  elseif excluded then
    return "○", "ClaudeCodeMuted", "left out"
  end
  return "×", "DiagnosticError", "to remove"
end

---@param state? claude_code.TreePickerState
function M.open(state)
  local self = setmetatable({
    state = state or { scope = "project", query = "" },
    trees = {},
    shown = {},
    index = 1,
    wins = {},
    loading = true,
    generation = 0,
    closed = false,
    stale = {},
    excluded = {},
    reclaimed = {},
  }, Picker)
  self.state.mode = self.state.mode or "trees"
  self:create()
  self:load()
end

---@private
function Picker:create()
  local function scratch(modifiable)
    local buf = api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "claude-code-trees"
    vim.bo[buf].modifiable = modifiable or false
    return buf
  end
  self.bufs = { list = scratch(), prompt = scratch(true), preview = scratch() }
  api.nvim_buf_set_lines(self.bufs.prompt, 0, -1, false, { self.state.query })
  self:layout()
  self:map_keys()

  self.augroup = api.nvim_create_augroup("claude-code.tree-picker", { clear = true })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = self.augroup,
    buffer = self.bufs.prompt,
    callback = function()
      self.state.query = api.nvim_buf_get_lines(self.bufs.prompt, 0, 1, false)[1] or ""
      self.index, self.state.selected = 1, nil
      self:filter()
    end,
  })
  -- Leaving the picker closes it.
  api.nvim_create_autocmd("WinEnter", {
    group = self.augroup,
    callback = function()
      if api.nvim_get_current_win() ~= self.wins.prompt then
        vim.schedule(function()
          self:close()
        end)
      end
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      self:layout()
      self:render()
    end,
  })
  -- Stay current: trees changed (an action here, or `wt` run by the plugin),
  -- or maybe outside Neovim; sessions opened, closed or changed status.
  api.nvim_create_autocmd("User", {
    group = self.augroup,
    pattern = worktree.CHANGED,
    callback = function()
      if not self:cleanup() then
        return self:load()
      end
      -- A cleanup looks again once its removals are all done (it invalidates),
      -- and once for changes that come together: its dry run is slow.
      if not trees.cleaning() and not self.reload_pending then
        self.reload_pending = true
        vim.defer_fn(function()
          self.reload_pending = false
          self:load()
        end, 100)
      end
    end,
  })
  api.nvim_create_autocmd("FocusGained", {
    group = self.augroup,
    callback = function()
      self:load()
    end,
  })
  api.nvim_create_autocmd("User", {
    group = self.augroup,
    pattern = events.SESSIONS_CHANGED,
    callback = function()
      self:render()
    end,
  })
  self.unsubscribe = trees.subscribe(function()
    vim.schedule(function()
      self:render()
    end)
  end)
  api.nvim_set_current_win(self.wins.prompt)
  vim.cmd("startinsert!")
end

---@private
function Picker:layout()
  local width = math.min(math.max(math.floor(vim.o.columns * 0.8), 80), vim.o.columns - 4, 150)
  local height = math.min(math.max(math.floor(vim.o.lines * 0.7), 16), vim.o.lines - 4, 36)
  local left = math.floor(width * 0.5)
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)
  local list_height = height - 2 - 3

  local function place(key, config)
    config =
      vim.tbl_extend("force", { relative = "editor", style = "minimal", border = "rounded", zindex = 60 }, config)
    if self.wins[key] and api.nvim_win_is_valid(self.wins[key]) then
      api.nvim_win_set_config(self.wins[key], config)
    else
      self.wins[key] = api.nvim_open_win(self.bufs[key], false, config)
    end
    vim.wo[self.wins[key]].winhighlight = table.concat({
      "NormalFloat:ClaudeCodePicker",
      "FloatBorder:ClaudeCodePickerBorder",
      "FloatTitle:ClaudeCodePickerTitle",
      "FloatFooter:ClaudeCodeMuted",
      "CursorLine:ClaudeCodePickerSelection",
    }, ",")
  end

  place("list", { row = row, col = col, width = left - 2, height = list_height, focusable = false })
  place("prompt", {
    row = row + list_height + 2,
    col = col,
    width = left - 2,
    height = 1,
    title = { { " " .. icons.get().worktree .. " Search ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
  })
  place("preview", {
    row = row,
    col = col + left,
    width = width - left - 2,
    height = height - 2,
    title = { { " Tree ", "ClaudeCodePickerTitle" } },
    title_pos = "left",
    focusable = false,
  })
  vim.wo[self.wins.list].cursorline = true
  vim.wo[self.wins.preview].wrap = true
  local hints = self:cleanup() and " ⏎ remove them · tab leave out / put back · ^L all trees · esc "
    or " ⏎ open · ^A new · ^T claim · ^R release · ^X remove · ^G all projects · ^L stale · esc "
  api.nvim_win_set_config(self.wins.preview, {
    footer = { { clip(hints, width - left - 4), "ClaudeCodeMuted" } },
    footer_pos = "right",
  })
end

--- Run `wt list` (in the background) for the scope, then show it.
---@private
function Picker:load()
  if self.closed then
    return
  end
  self.generation = self.generation + 1
  local generation = self.generation
  self.loading = true
  self:filter()
  if self:cleanup() then
    trees.stale(vim.fn.getcwd(), function(stale, failed)
      if self.closed or generation ~= self.generation then
        return
      end
      self.loading = false
      self.error = failed and worktree.describe_failure(failed, "wt cleanup") or nil
      stale = stale or {}
      table.sort(stale, function(a, b)
        if a.status ~= b.status then
          return STALE_ORDER[a.status] < STALE_ORDER[b.status]
        end
        return a.tree.name < b.tree.name
      end)
      self.stale, self.trees = {}, {}
      for _, entry in ipairs(stale) do
        self.stale[trees.key(entry.tree)] = entry
        table.insert(self.trees, entry.tree)
      end
      self:filter()
    end, { reclaimed = self.reclaimed })
    return
  end
  local function done(result, flatten)
    if self.closed or generation ~= self.generation then
      return
    end
    self.loading = false
    self.error = not result.ok and (result.error or "wt list failed") or nil
    self.trees = result.ok and flatten(result.data or {}) or {}
    self:filter()
  end
  if self.state.scope == "all" then
    worktree.run({ "list", "--all-projects" }, {}, function(result)
      done(result, function(projects)
        local out = {}
        for _, project in ipairs(projects) do
          for _, tree in ipairs(project.trees or {}) do
            tree.project = tree.project or project.project
            table.insert(out, tree)
          end
        end
        return out
      end)
    end)
  else
    worktree.list(vim.fn.getcwd(), function(result)
      done(result, function(data)
        return data.trees or {}
      end)
    end, { fresh = true })
  end
end

---@private
function Picker:filter()
  local query = vim.trim(self.state.query)
  if query == "" then
    self.shown = self.trees
  else
    local records = {}
    for i, tree in ipairs(self.trees) do
      records[i] = {
        text = table.concat({ tree.name, tree.branch or "", tree.project or "", holder_short(tree) }, " "),
        index = i,
      }
    end
    self.shown = vim.tbl_map(function(record)
      return self.trees[record.index]
    end, vim.fn.matchfuzzy(records, query, { key = "text" }))
  end
  -- Keep the selection on the same tree when the list changes.
  if self.state.selected then
    for i, tree in ipairs(self.shown) do
      if trees.key(tree) == self.state.selected then
        self.index = i
      end
    end
  end
  self.index = math.max(math.min(self.index, #self.shown), 1)
  self:render()
end

---@private
function Picker:render()
  if self.closed or not api.nvim_win_is_valid(self.wins.list) then
    return
  end
  local win = self.wins.list
  local width = api.nvim_win_get_width(win)
  local current = sessions.peek()
  local lines, marks = {}, {}
  for i, tree in ipairs(self.shown) do
    local glyph, hl = status(tree)
    local right = { ("slot %s"):format(tostring(tree.slot or "?")), holder_short(tree) }
    local entry = self:cleanup() and self.stale[trees.key(tree)]
    if entry then
      local label
      glyph, hl, label = stale_status(entry, self.excluded[trees.key(tree)])
      table.insert(right, 1, entry.reasons[1] and clip(entry.reasons[1], math.floor(width / 3)) or label)
    elseif self.state.scope == "all" and tree.project then
      table.insert(right, 1, tree.project)
    end
    local doing = trees.busy(tree)
    if doing and not entry then
      table.insert(right, doing .. "…")
    end
    if current and vim.tbl_contains(trees.sessions_in(tree), current) then
      table.insert(right, 1, "current")
    end
    right = table.concat(right, " · ")
    local room = math.max(width - vim.fn.strdisplaywidth(right) - 6, 10)
    local name = clip(tree.name, room)
    local branch = tree.branch
      and tree.branch ~= tree.name
      and clip(tree.branch, room - vim.fn.strdisplaywidth(name) - 2)
    if branch and vim.fn.strdisplaywidth(branch) < 4 then
      branch = nil
    end
    lines[i] = (" %s %s%s"):format(glyph, name, branch and ("  " .. branch) or "")
    marks[i] = { glyph = glyph, hl = hl, right = right, branch_col = branch and (#lines[i] - #branch) or nil }
  end
  if #lines == 0 then
    if self.loading then
      lines = { self:cleanup() and "  Looking for stale trees…" or "  Loading…" }
    elseif self.error then
      lines = vim.split("  " .. self.error, "\n", { plain = true })
    else
      lines = { self:cleanup() and "  No stale trees" or "  No trees" }
    end
  end

  vim.bo[self.bufs.list].modifiable = true
  api.nvim_buf_set_lines(self.bufs.list, 0, -1, false, lines)
  vim.bo[self.bufs.list].modifiable = false
  api.nvim_buf_clear_namespace(self.bufs.list, ns, 0, -1)
  for i, m in ipairs(marks) do
    api.nvim_buf_set_extmark(self.bufs.list, ns, i - 1, 1, { end_col = 1 + #m.glyph, hl_group = m.hl })
    if m.branch_col then
      api.nvim_buf_set_extmark(self.bufs.list, ns, i - 1, m.branch_col, {
        end_col = #lines[i],
        hl_group = "ClaudeCodeMuted",
      })
    end
    api.nvim_buf_set_extmark(self.bufs.list, ns, i - 1, 0, {
      virt_text = { { m.right .. " ", "ClaudeCodeMuted" } },
      virt_text_pos = "right_align",
    })
  end
  if #self.shown == 0 then
    for i = 1, #lines do
      api.nvim_buf_set_extmark(self.bufs.list, ns, i - 1, 0, {
        line_hl_group = self.error and "DiagnosticError" or "ClaudeCodeMuted",
      })
    end
  end

  local project = vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
  local scope = (self.state.scope == "project" or self:cleanup()) and project or "all projects"
  local count = #self.shown == #self.trees and tostring(#self.trees) or ("%d/%d"):format(#self.shown, #self.trees)
  if self:cleanup() then
    local tally = { remove = 0, skip = 0, keep = 0, out = 0 }
    for key, entry in pairs(self.stale) do
      local what = entry.status == "remove" and self.excluded[key] and "out" or entry.status
      tally[what] = tally[what] + 1
    end
    local t = tally
    count = ("%d to remove · %d left out · %d skipped · %d kept"):format(t.remove, t.out, t.skip, t.keep)
  end
  if self.loading and #self.trees > 0 then
    count = count .. " · refreshing"
  end
  local name = self:cleanup() and "Stale trees" or "Trees"
  api.nvim_win_set_config(win, {
    title = { { (" %s · %s "):format(name, scope), "ClaudeCodePickerTitle" } },
    title_pos = "left",
    footer = { { (" %s "):format(count), "ClaudeCodeMuted" } },
    footer_pos = "right",
  })
  api.nvim_win_set_cursor(win, { math.min(self.index, #lines), 0 })
  local tree = self.shown[self.index]
  self.state.selected = tree and trees.key(tree)
  self:render_preview()
end

---@private
function Picker:render_preview()
  local tree = self.shown[self.index]
  if not tree then
    self:set_preview({})
    return
  end
  local _, hl, label = status(tree)
  local chunks = {}
  local function add(text, group)
    table.insert(chunks, { text, group or "Normal" })
  end
  add(tree.name, "ClaudeCodeTitle")
  local meta = {}
  if tree.branch then
    table.insert(meta, icons.get().worktree .. " " .. tree.branch)
  end
  table.insert(meta, ("slot %s"):format(tostring(tree.slot or "?")))
  if tree.project and self.state.scope == "all" then
    table.insert(meta, tree.project)
  end
  add(table.concat(meta, " · "), "ClaudeCodeMuted")
  if tree.path then
    add(vim.fn.fnamemodify(tree.path, ":~"), "ClaudeCodeMuted")
  end
  add("")
  local entry = self:cleanup() and self.stale[trees.key(tree)]
  if entry then
    local excluded = self.excluded[trees.key(tree)]
    local glyph, stale_hl = stale_status(entry, excluded)
    local headline = ({
      remove = excluded and "Left out of this cleanup (tab puts it back)" or "Removed by this cleanup",
      skip = "Skipped: wt won't remove it",
      keep = "Kept: in use in this Neovim, though wt sees it as stale",
    })[entry.status]
    add(("%s %s"):format(glyph, headline), stale_hl)
    for _, reason in ipairs(entry.reasons) do
      add("  " .. reason, stale_hl)
    end
    add("")
    add("wt's plan", "ClaudeCodeTitle")
    for _, line in ipairs(trees.plan_lines(entry.plan)) do
      add(line, "ClaudeCodeMuted")
    end
    add("")
  end
  add("State: " .. label, label == "ready" and "Normal" or hl)
  local holder = type(tree.holder) == "table" and tree.holder or {}
  if holder.session then
    local who = worktree.describe_holder(holder)
    local live = holder.state == "live"
    add(live and ("Held by %s, running"):format(who) or ("Last held by %s, which has ended"):format(who), hl)
  else
    add("Not held")
  end
  if type(tree.story) == "string" and tree.story ~= "" then
    add("Story: " .. tree.story, "ClaudeCodeMuted")
  end

  local open = trees.sessions_in(tree)
  if #open > 0 then
    add("")
    add("Open in this Neovim", "ClaudeCodeTitle")
    for _, s in ipairs(open) do
      local g, _, l = listing.status({ live = s })
      add(("%s %s · %s"):format(g, s.title or "New session", l))
    end
  end

  local env = {}
  for name, value in pairs(type(tree.env) == "table" and tree.env or {}) do
    if type(name) == "string" and not name:match("^WT_") then
      table.insert(env, ("%s=%s"):format(name, tostring(value)))
    end
  end
  if #env > 0 then
    table.sort(env)
    add("")
    add("Environment", "ClaudeCodeTitle")
    for _, line in ipairs(env) do
      add(line, "ClaudeCodeMuted")
    end
  end
  self:set_preview(chunks)
end

---@private
---@param chunks claude_code.Chunk[]
function Picker:set_preview(chunks)
  local lines = {}
  for i, c in ipairs(chunks) do
    lines[i] = (c[1]:gsub("\n", " "))
  end
  vim.bo[self.bufs.preview].modifiable = true
  api.nvim_buf_set_lines(self.bufs.preview, 0, -1, false, lines)
  vim.bo[self.bufs.preview].modifiable = false
  api.nvim_buf_clear_namespace(self.bufs.preview, ns, 0, -1)
  for i, c in ipairs(chunks) do
    if c[2] ~= "Normal" and #lines[i] > 0 then
      api.nvim_buf_set_extmark(self.bufs.preview, ns, i - 1, 0, { end_col = #lines[i], hl_group = c[2] })
    end
  end
  api.nvim_win_set_cursor(self.wins.preview, { 1, 0 })
end

---@private
---@param delta integer
function Picker:move(delta)
  if #self.shown == 0 then
    return
  end
  self.index = (self.index - 1 + delta) % #self.shown + 1
  self:render()
end

---@private
function Picker:map_keys()
  local buf = self.bufs.prompt
  local function map(lhs, fn)
    vim.keymap.set({ "i", "n" }, lhs, fn, { buffer = buf, nowait = true })
  end
  --- Map `lhs` to an action on the selected tree.
  ---@param lhs string
  ---@param action fun(tree: table)
  ---@param close? boolean Close the picker first.
  ---@param cleanup? fun() What `lhs` does in cleanup mode instead (default: nothing).
  local function act(lhs, action, close, cleanup)
    map(lhs, function()
      if self:cleanup() then
        return cleanup and cleanup()
      end
      local tree = self.shown[self.index]
      if not tree then
        return
      end
      if close then
        self:close()
      end
      action(tree)
    end)
  end
  for _, lhs in ipairs({ "<C-n>", "<Down>", "<C-j>" }) do
    map(lhs, function()
      self:move(1)
    end)
  end
  for _, lhs in ipairs({ "<C-p>", "<Up>", "<C-k>" }) do
    map(lhs, function()
      self:move(-1)
    end)
  end
  act("<CR>", trees.open, true, function()
    self:remove_stale()
  end)
  act("<C-t>", trees.claim)
  act("<C-r>", trees.release)
  act("<C-x>", trees.remove)
  map("<Tab>", function()
    local tree = self:cleanup() and self.shown[self.index]
    local entry = tree and self.stale[trees.key(tree)]
    if not entry then
      return
    end
    if entry.status ~= "remove" then
      vim.notify(("claude-code: %s isn't removed by this cleanup: %s"):format(tree.name, entry.reasons[1] or "?"))
      return
    end
    local key = trees.key(tree)
    self.excluded[key] = not self.excluded[key] or nil
    self:render()
  end)
  map("<C-l>", function()
    self.state.mode = self:cleanup() and "trees" or "cleanup"
    self.index, self.trees, self.stale, self.state.selected = 1, {}, {}, nil
    self:layout()
    self:load()
  end)
  map("<C-a>", function()
    if self:cleanup() then
      return
    end
    self:close()
    require("claude-code.ui.input").open({
      title = "Work on (story id, branch or description)",
      on_submit = function(text)
        if text ~= "" then
          require("claude-code.work").work(text)
        else
          M.open(self.state)
        end
      end,
      on_cancel = function()
        M.open(self.state)
      end,
    })
  end)
  map("<C-g>", function()
    if self:cleanup() then
      return
    end
    self.state.scope = self.state.scope == "project" and "all" or "project"
    self.index, self.trees = 1, {}
    self:load()
  end)
  for _, lhs in ipairs({ "<Esc>", "<C-c>" }) do
    map(lhs, function()
      self:close()
    end)
  end
end

--- Whether it's showing the stale trees (cleanup mode).
---@return boolean
function Picker:cleanup()
  return self.state.mode == "cleanup"
end

--- Remove the stale trees listed, but the ones left out, after one
--- confirmation (trees.remove_stale). All of them, not only the ones the search
--- shows: <Tab> is what leaves one out. Once it's done, the list is loaded again.
---@private
function Picker:remove_stale()
  if self.loading then
    vim.notify("claude-code: still looking for stale trees; try again once the list is loaded")
    return
  end
  local stale = {}
  for _, tree in ipairs(self.trees) do
    local key = trees.key(tree)
    local entry = self.stale[key]
    if entry then
      entry.excluded = self.excluded[key]
      table.insert(stale, entry)
    end
  end
  trees.remove_stale(stale)
end

function Picker:close()
  if self.closed then
    return
  end
  self.closed = true
  vim.cmd("stopinsert")
  pcall(api.nvim_del_augroup_by_id, self.augroup)
  if self.unsubscribe then
    self.unsubscribe()
  end
  for _, win in pairs(self.wins) do
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end
end

return M
