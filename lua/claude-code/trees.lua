-- The actions the tree picker (`:Claude trees`) offers on a `wt` tree: open or
-- resume a session in it, claim it for the current session, release it, and
-- remove it. The picker owns the list; these act, always running `wt` in the
-- background, and take the decisions `wt` leaves to its caller in the editor.

local control = require("claude-code.control")
local sessions = require("claude-code.sessions")
local worktree = require("claude-code.worktree")

local M = {}

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify("claude-code: " .. message, level or vim.log.levels.INFO)
end

-- What's under way per tree ----------------------------------------------------

--- Actions running, by tree (M.key): what to show for it, e.g. "removing".
---@type table<string, string>
local busy = {}

---@type table<integer, fun()>
local listeners = {}
local next_listener = 0

--- Call `fn` whenever an action starts or ends on a tree.
---@param fn fun()
---@return fun() unsubscribe
function M.subscribe(fn)
  next_listener = next_listener + 1
  local id = next_listener
  listeners[id] = fn
  return function()
    listeners[id] = nil
  end
end

---@param tree table
---@return string
function M.key(tree)
  return (tree.root or "") .. "\0" .. tree.name
end

--- What's under way on `tree`, if anything ("removing", ...).
---@param tree table
---@return string?
function M.busy(tree)
  return busy[M.key(tree)]
end

--- Whether nothing is under way on `tree`; if something is, says so.
---@param tree table
---@return boolean
local function idle(tree)
  local doing = busy[M.key(tree)]
  if doing then
    notify(("already %s %s"):format(doing, tree.name))
  end
  return doing == nil
end

---@param tree table
---@param what? string
local function set_busy(tree, what)
  busy[M.key(tree)] = what
  for _, fn in pairs(listeners) do
    fn()
  end
end

-- Who's in a tree --------------------------------------------------------------

---@param dir string
---@return string
local function real(dir)
  return vim.uv.fs_realpath(dir) or vim.fs.normalize(dir)
end

--- Whether `dir` is `root` or inside it.
---@param dir? string
---@param root? string
---@return boolean
function M.within(dir, root)
  if not dir or not root then
    return false
  end
  dir, root = real(dir), real(root)
  return dir == root or vim.startswith(dir, root:gsub("/+$", "") .. "/")
end

--- Sessions open in this Neovim working in `tree`: running in it, or holding it.
--- The holder first, then the most recently active.
---@param tree table
---@return claude_code.Session[]
function M.sessions_in(tree)
  local holder = type(tree.holder) == "table" and tree.holder.session or nil
  local found = {}
  for _, s in ipairs(sessions.live()) do
    if s.id == holder or M.within(s.cwd, tree.path) then
      table.insert(found, s)
    end
  end
  table.sort(found, function(a, b)
    if (a.id == holder) ~= (b.id == holder) then
      return a.id == holder
    end
    return a.last_active > b.last_active
  end)
  return found
end

--- Whether `tree`'s holder is a session of this Neovim: open here, or claimed
--- with Neovim's pid (a closed session whose release failed).
---@param tree table
---@return boolean
local function held_here(tree)
  local holder = tree.holder
  return type(holder) == "table"
    and holder.session ~= nil
    and (sessions.find(holder.session) ~= nil or holder.pid == vim.fn.getpid())
end

--- The identity to act on `tree` as: its holder's, when that's this Neovim's
--- (so `wt` doesn't refuse it as held by another live session), else none.
---@param tree table
---@return claude_code.WtSession?
local function identity(tree)
  if held_here(tree) then
    return { id = tree.holder.session, pid = vim.fn.getpid() }
  end
end

---@param session claude_code.Session
---@return string
local function title(session)
  return ("“%s”"):format(session.title or "New session")
end

-- Open -------------------------------------------------------------------------

--- Stored sessions that ran in `tree`, newest first, leaving out ones open in
--- another Claude Code process.
---@param tree table
---@param callback fun(stored: table[])
local function stored_in(tree, callback)
  control.request("list_sessions", { dir = tree.path, limit = 200 }, function(err, result)
    if err then
      notify("couldn't list the tree's sessions: " .. err, vim.log.levels.WARN)
    end
    local elsewhere = sessions.open_elsewhere()
    local out = {}
    for _, info in ipairs(result or {}) do
      if M.within(info.cwd, tree.path) and not elsewhere[info.sessionId] then
        table.insert(out, info)
      end
    end
    table.sort(out, function(a, b)
      return (a.lastModified or 0) > (b.lastModified or 0)
    end)
    callback(out)
  end)
end

--- Open a session in `tree`. A session open here that works in it is shown.
--- Otherwise, when sessions ran there before, asks whether to resume one (the
--- one that last held the tree first) or start a new one; the tree is then
--- claimed for that session (see work.open).
---@param tree table
function M.open(tree)
  local here = M.sessions_in(tree)[1]
  if here then
    sessions.show(here)
    -- Resumed in a new Neovim, its claim has the old one's pid: renew it.
    worktree.reclaim(here.id, tree)
    return
  end
  local holder = type(tree.holder) == "table" and tree.holder or {}
  if holder.state == "live" then
    notify(
      ("%s is held by %s, which is still running"):format(tree.name, worktree.describe_holder(holder)),
      vim.log.levels.WARN
    )
    return
  end
  if tree.exists == false then
    notify(("%s's directory is gone; remove the tree"):format(tree.name), vim.log.levels.WARN)
    return
  end
  local work = require("claude-code.work")
  stored_in(tree, function(stored)
    if #stored == 0 then
      return work.open(tree)
    end
    -- The session that last held it first: resuming it needs no take-over.
    for i, info in ipairs(stored) do
      if info.sessionId == holder.session then
        table.insert(stored, 1, table.remove(stored, i))
        break
      end
    end
    local new = { new = true }
    local choices = vim.list_extend({ new }, stored)
    local ago = require("claude-code.listing").ago
    vim.ui.select(choices, {
      prompt = ("Open a session in %s"):format(tree.name),
      format_item = function(info)
        if info == new then
          return "New session"
        end
        local name = (info.customTitle or info.summary or "Untitled"):gsub("\n", " ")
        local when = ago(math.floor((info.lastModified or 0) / 1000))
        local last = info.sessionId == holder.session and ", last held the tree" or ""
        return ("Resume “%s” (%s%s)"):format(name, when, last)
      end,
    }, function(choice)
      if choice then
        work.open(tree, { resume = choice ~= new and choice or nil })
      end
    end)
  end)
end

-- Claim and release ------------------------------------------------------------

--- Claim `tree` for the current session (the one the chat shows), asking
--- before taking it over from a session that has ended.
---@param tree table
function M.claim(tree)
  if not idle(tree) then
    return
  end
  local session = sessions.current()
  if not session then
    notify("no current session to claim it for; ⏎ opens a session in the tree instead", vim.log.levels.WARN)
    return
  end
  local holder = type(tree.holder) == "table" and tree.holder or {}
  if holder.session == session.id and holder.state == "live" then
    notify(("%s already holds %s"):format(title(session), tree.name))
    return
  end
  local who = { id = session.id, pid = vim.fn.getpid() }
  set_busy(tree, "claiming")
  worktree.claim_interactively(function(take_over, done)
    worktree.run({ "claim", tree.name, take_over and "--take-over" or nil }, { cwd = tree.root, session = who }, done)
  end, { what = tree.name }, function(result)
    set_busy(tree, nil)
    if result then
      -- It holds a claim now: never discard it as an untouched placeholder,
      -- which would skip releasing the claim.
      session.claimed = true
      notify(("claimed %s for %s"):format(tree.name, title(session)))
    end
  end)
end

--- Release `tree`: as its holder when that's a session of this Neovim. `wt`
--- refuses (and says who) when another live session holds it.
---@param tree table
function M.release(tree)
  if not idle(tree) then
    return
  end
  local holder = type(tree.holder) == "table" and tree.holder or {}
  if not holder.session then
    notify(("nobody holds %s"):format(tree.name))
    return
  end
  local was = worktree.describe_holder(holder)
  set_busy(tree, "releasing")
  worktree.run({ "release", tree.name }, { cwd = tree.root, session = identity(tree) }, function(result)
    set_busy(tree, nil)
    if result.ok then
      notify(("released %s (held by %s)"):format(tree.name, was))
    else
      worktree.report(result, tree.name)
    end
  end)
end

-- Remove -----------------------------------------------------------------------

--- `wt rm`'s dry-run plan as text, as `wt` prints it.
---@param plan table
---@return string[]
function M.plan_lines(plan)
  local lines = {}
  local function add(fmt, ...)
    table.insert(lines, fmt:format(...))
  end
  add("%s  (slot %s, %s)", plan.name, tostring(plan.slot), vim.fn.fnamemodify(plan.path or "?", ":~"))
  add("  holder:   %s", worktree.describe_holder(plan.holder))
  if plan.exists then
    local dirty = plan.dirty or {}
    local state = #dirty > 0 and ("%d uncommitted change(s)"):format(#dirty) or "clean"
    add("  worktree: %s; %d unpushed commit(s)", state, plan.unpushed or 0)
    for i, line in ipairs(dirty) do
      if i > 10 then
        add("              … and %d more", #dirty - 10)
        break
      end
      add("              %s", line)
    end
  else
    add("  worktree: directory is gone")
  end
  if type(plan.pr) == "table" then
    add("  PR:       #%s %s %s", tostring(plan.pr.number), tostring(plan.pr.state), tostring(plan.pr.url or ""))
  end
  local mode = plan.mode == "release" and "release (the slot stays warm for the next tree)" or "destroy"
  add("  teardown: %s%s", mode, plan.teardown == nil and " (no teardown hook)" or "")
  if type(plan.teardown) == "table" and type(plan.teardown.output) == "string" then
    for _, line in ipairs(vim.split(vim.trim(plan.teardown.output), "\n", { plain = true })) do
      if line ~= "" then
        add("    | %s", line)
      end
    end
  end
  if plan.branch then
    local action = ({ ["-d"] = "delete if merged (git branch -d)", ["-D"] = "delete (git branch -D)" })[plan.branch_action]
    add("  branch:   %s %s", action or "keep", plan.branch)
  end
  for _, note in ipairs(plan.notes or {}) do
    add("  note:     %s", note)
  end
  for _, reason in ipairs(plan.blocked or {}) do
    add("  BLOCKED:  %s", reason)
  end
  return lines
end

--- What closing `session` interrupts, if anything.
---@param session claude_code.Session
---@return string?
local function interrupts(session)
  local what = {}
  if session.busy then
    table.insert(what, "its turn is interrupted")
  end
  if session:needs_attention() then
    table.insert(what, "the question it's waiting on is dropped")
  end
  if session.shell then
    table.insert(what, "its !command is killed")
  end
  return #what > 0 and table.concat(what, ", ") or nil
end

--- Close `closing` and call `done` once their processes and `!command`s have
--- exited and their trees have been released, or after a few seconds anyway.
---@param closing claude_code.Session[]
---@param done fun()
local function close_all(closing, done)
  local releases = #closing
  for _, s in ipairs(closing) do
    if s.shell then
      pcall(s.kill_shell, s)
    end
    -- Waiting for the release keeps it from running into (or after) `wt rm`.
    sessions.close(s, function()
      releases = releases - 1
    end)
  end
  local deadline = vim.uv.now() + 5000
  local function check()
    local settled = releases == 0
    for _, s in ipairs(closing) do
      settled = settled and not s:running() and not s.shell
    end
    if settled or vim.uv.now() > deadline then
      done()
    else
      vim.defer_fn(check, 50)
    end
  end
  check()
end

---@param tree table
---@param result claude_code.WtResult
local function removed(tree, result)
  set_busy(tree, nil)
  if not result.ok then
    worktree.report(result, tree.name)
    return
  end
  local done = result.data and result.data.result or {}
  local branch = done.branch and ("; branch %s %s"):format(done.branch, done.branch_result or "kept") or ""
  notify(("removed %s (%s%s)"):format(tree.name, done.mode or "done", branch))
end

--- Remove `tree`: show `wt rm`'s dry-run plan and ask, then close the sessions
--- open here that work in it and run `wt rm --yes`. A blocked plan only says
--- why. Refuses while a Claude Code process outside this Neovim runs in it.
---@param tree table
function M.remove(tree)
  if not idle(tree) then
    return
  end
  for _, process in ipairs(sessions.running_elsewhere()) do
    if M.within(process.cwd, tree.path) then
      notify(
        ("a Claude Code process outside this Neovim (pid %d) is running in %s; close it there first"):format(
          process.pid,
          tree.name
        ),
        vim.log.levels.WARN
      )
      return
    end
  end
  local as = identity(tree)
  set_busy(tree, "checking")
  worktree.run({ "rm", tree.name }, { cwd = tree.root, session = as }, function(result)
    set_busy(tree, nil)
    local plan = result.data and result.data.plan
    if not result.ok then
      if type(plan) == "table" and (result.outcome == "held" or result.outcome == "refused") then
        local lines = M.plan_lines(plan)
        notify(("can't remove %s:\n%s"):format(tree.name, table.concat(lines, "\n")), vim.log.levels.WARN)
      else
        worktree.report(result, tree.name)
      end
      return
    end
    local lines = { ("Remove %s?"):format(tree.name), "" }
    vim.list_extend(lines, M.plan_lines(plan or {}))
    local closing = M.sessions_in(tree)
    if #closing > 0 then
      table.insert(lines, "")
      table.insert(lines, "Closes the sessions open here that work in it:")
      for _, s in ipairs(closing) do
        local cut = interrupts(s)
        table.insert(lines, ("  %s%s"):format(title(s), cut and (" (" .. cut .. ")") or ""))
      end
    end
    if vim.fn.confirm(table.concat(lines, "\n"), "&Remove\n&Cancel", 2, "Warning") ~= 1 then
      return
    end
    set_busy(tree, "removing")
    close_all(M.sessions_in(tree), function()
      worktree.run({ "rm", tree.name, "--yes" }, { cwd = tree.root, session = as }, function(done)
        removed(tree, done)
      end)
    end)
  end)
end

return M
