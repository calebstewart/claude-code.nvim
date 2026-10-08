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

--- Actions running, by tree (M.key): what to show for it, e.g. "removing",
--- and the tree's path.
---@type table<string, { what: string, path?: string }>
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

--- A tree's key: its project's root and its name.
---@param tree { root?: string, name: string }
---@return string
function M.key(tree)
  return (tree.root or "") .. "\0" .. tree.name
end

--- What's under way on `tree`, if anything ("removing", "opening", ...).
---@param tree { root?: string, name: string }
---@return string?
function M.busy(tree)
  local entry = busy[M.key(tree)]
  return entry and entry.what
end

--- Whether nothing is under way on `tree`; if something is, says so.
---@param tree { root?: string, name: string }
---@return boolean
function M.idle(tree)
  local doing = M.busy(tree)
  if doing then
    notify(("%s is busy (%s); try again once that's done"):format(tree.name, doing))
  end
  return doing == nil
end
local idle = M.idle

--- Mark an action as under way on `tree` (or done, with no `what`). Also used
--- by `:Claude work` while it claims a tree for a session it's about to open.
---@param tree { root?: string, name: string, path?: string }
---@param what? string
function M.set_busy(tree, what)
  busy[M.key(tree)] = what and { what = what, path = tree.path } or nil
  for _, fn in pairs(listeners) do
    fn()
  end
end
local set_busy = M.set_busy

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

--- The name of the tree being removed that `dir` is in, if any: no session may
--- start there (sessions.new and sessions.open check), since its directory is
--- about to go.
---@param dir? string
---@return string?
function M.removing_at(dir)
  for key, entry in pairs(busy) do
    if entry.what == "removing" and M.within(dir, entry.path) then
      return (key:match("%z(.*)$"))
    end
  end
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
  if not idle(tree) then
    return
  end
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
  -- Busy while looking for its sessions, so it can't be removed meanwhile;
  -- work.open marks it busy again while it claims the tree.
  set_busy(tree, "opening")
  stored_in(tree, function(stored)
    set_busy(tree, nil)
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

--- How long to wait for closed sessions to let go of a tree being removed:
--- longer than a transport takes to stop a process that ignores stdin closing
--- (SIGTERM after 2 s, SIGKILL 5 s after that).
local CLOSE_TIMEOUT_MS = 10000

--- Close `closing`, then call `done` with nil once their processes and
--- `!command`s have exited and their trees have been released, or with why not
--- when that hasn't happened within CLOSE_TIMEOUT_MS.
---@param closing claude_code.Session[]
---@param done fun(problem?: string)
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
  local deadline = vim.uv.now() + CLOSE_TIMEOUT_MS
  local function check()
    local still = {}
    for _, s in ipairs(closing) do
      if s:running() or s.shell then
        table.insert(still, title(s))
      end
    end
    if #still == 0 and releases == 0 then
      return done()
    end
    if vim.uv.now() < deadline then
      return vim.defer_fn(check, 50)
    end
    if #still > 0 then
      done(("%s still running after %ds"):format(table.concat(still, ", "), CLOSE_TIMEOUT_MS / 1000))
    else
      done("releasing the tree for its closed sessions hasn't finished")
    end
  end
  check()
end

--- A Claude Code process outside this Neovim running in `tree`, if any: it
--- would have its directory deleted under it, and the plugin can't close it.
---@param tree table
---@return { id: string, pid: integer, cwd?: string }?
local function process_elsewhere(tree)
  for _, process in ipairs(sessions.running_elsewhere()) do
    if M.within(process.cwd, tree.path) then
      return process
    end
  end
end

---@param process { pid: integer }
---@return string
local function elsewhere_text(process)
  return ("a Claude Code process outside this Neovim (pid %d) is running in it"):format(process.pid)
end

--- Lines for a confirmation listing the sessions that removing closes, and what
--- that cuts short for each; none when there are none.
---@param closing claude_code.Session[]
---@return string[]
local function closing_lines(closing)
  if #closing == 0 then
    return {}
  end
  local lines = { "", "Closes the sessions open here that work in it:" }
  for _, s in ipairs(closing) do
    local cut = interrupts(s)
    table.insert(lines, ("  %s%s"):format(title(s), cut and (" (" .. cut .. ")") or ""))
  end
  return lines
end

---@class claude_code.TreeRemoval
---@field tree table The tree's `wt list` entry.
---@field as? claude_code.WtSession Who to run `wt rm --yes` as.
---@field problem? string Why `wt rm --yes` didn't run: its sessions didn't let go, ...
---@field result? claude_code.WtResult What `wt rm --yes` returned, when it ran.

--- Remove trees the user has confirmed removing, already marked "removing" (so
--- no session can start in them): close the sessions open here that work in
--- each, all at once, and wait for them to let go (close_all). Then run
--- `wt rm --yes` for each tree, one at a time, as `wt cleanup` does.
---
--- Each tree stands alone. One whose sessions don't let go in time, or that a
--- session here or a Claude Code process elsewhere is in again just before its
--- `wt rm --yes`, isn't removed (`problem` says why); the others still are.
--- Each tree's "removing" mark is cleared once it's done with. An item that
--- comes with a `problem` already (left out at the last moment) isn't touched.
---@param batch claude_code.TreeRemoval[]
---@param callback fun(batch: claude_code.TreeRemoval[])
local function remove_confirmed(batch, callback)
  local function done_with(tree)
    if M.busy(tree) == "removing" then
      set_busy(tree, nil)
    end
  end
  local function remove_from(i)
    local item = batch[i]
    if not item then
      return callback(batch)
    end
    if not item.problem then
      -- A session reopened in it anyway (e.g. by a plugin bypassing the
      -- checks) would lose its directory.
      local back = M.sessions_in(item.tree)[1]
      local process = process_elsewhere(item.tree)
      item.problem = back and ("%s is open in it again"):format(title(back))
        or process and elsewhere_text(process)
        or nil
    end
    if item.problem then
      done_with(item.tree)
      return remove_from(i + 1)
    end
    worktree.run({ "rm", item.tree.name, "--yes" }, { cwd = item.tree.root, session = item.as }, function(result)
      item.result = result
      done_with(item.tree)
      remove_from(i + 1)
    end)
  end
  local waiting = #batch
  if waiting == 0 then
    return callback(batch)
  end
  for _, item in ipairs(batch) do
    -- One already left out (`problem` set) keeps its sessions.
    close_all(item.problem and {} or M.sessions_in(item.tree), function(problem)
      item.problem = item.problem or problem
      waiting = waiting - 1
      if waiting == 0 then
        remove_from(1)
      end
    end)
  end
end

---@param tree table
---@param result claude_code.WtResult
local function removed(tree, result)
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
  local process = process_elsewhere(tree)
  if process then
    notify(
      ("a Claude Code process outside this Neovim (pid %d) is running in %s; close it there first"):format(
        process.pid,
        tree.name
      ),
      vim.log.levels.WARN
    )
    return
  end
  local as = identity(tree)
  set_busy(tree, "checking")
  worktree.run({ "rm", tree.name }, { cwd = tree.root, session = as }, function(result)
    local plan = result.data and result.data.plan
    if not result.ok then
      set_busy(tree, nil)
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
    vim.list_extend(lines, closing_lines(M.sessions_in(tree)))
    -- Still "checking" while asking, so nothing else starts on the tree.
    if vim.fn.confirm(table.concat(lines, "\n"), "&Remove\n&Cancel", 2, "Warning") ~= 1 then
      return set_busy(tree, nil)
    end
    -- From here no session may open in it (see M.removing_at, work.lua).
    set_busy(tree, "removing")
    remove_confirmed({ { tree = tree, as = as } }, function(batch)
      local item = batch[1]
      if item.problem then
        notify(("not removing %s: %s"):format(tree.name, item.problem), vim.log.levels.ERROR)
      else
        removed(tree, item.result)
      end
    end)
  end)
end

-- Clean up stale trees ---------------------------------------------------------

---@class claude_code.StaleTree
---@field tree table The tree's `wt list` entry.
---@field plan table `wt cleanup --stale`'s removal plan for it (as `wt rm` makes one).
---@field status "remove"|"skip"|"keep" `remove`: in the batch; `skip`: `wt` would refuse to remove it; `keep`: in use in this Neovim, though `wt` sees its holder as ended.
---@field reasons string[] Why it's skipped or kept.
---@field excluded? boolean Left out of the batch by the user (the cleanup view's <Tab>).

--- Why `tree` is in use in this Neovim, or busy, though `wt` may see the session
--- holding it as ended; empty when it isn't. That's the case when:
---
--- - a session open here holds it: e.g. one resumed after Neovim restarted
---   that hasn't started its process yet (which claims the tree again), so its
---   claim still has the old Neovim's pid;
--- - a session open here runs in it, though it holds another tree, or none;
--- - a Claude Code process outside this Neovim runs in it;
--- - a window's working directory is in it, or a modified buffer's file is;
--- - an action (opening, removing, ...) is under way on it.
---@param tree table
---@return string[]
function M.in_use(tree)
  local reasons = {}
  local holder = type(tree.holder) == "table" and tree.holder.session or nil
  for _, s in ipairs(M.sessions_in(tree)) do
    if s.id == holder then
      table.insert(reasons, ("held by %s, which is open in this Neovim"):format(title(s)))
    else
      table.insert(reasons, ("%s is open in this Neovim and works in it"):format(title(s)))
    end
  end
  local process = process_elsewhere(tree)
  if process then
    table.insert(reasons, elsewhere_text(process))
  end
  local cwds = { vim.fn.getcwd(-1, -1) }
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local tabnr = vim.api.nvim_tabpage_get_number(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      table.insert(cwds, vim.fn.getcwd(vim.api.nvim_win_get_number(win), tabnr))
    end
  end
  for _, dir in ipairs(cwds) do
    if M.within(dir, tree.path) then
      table.insert(reasons, "Neovim's working directory is in it")
      break
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if vim.bo[buf].modified and name ~= "" and M.within(name, tree.path) then
      table.insert(reasons, ("%s has unsaved changes"):format(vim.fn.fnamemodify(name, ":~:.")))
    end
  end
  local doing = M.busy(tree)
  if doing then
    table.insert(reasons, ("busy (%s)"):format(doing))
  end
  return reasons
end

---@class claude_code.StaleOpts
---@field reclaimed? table<string, boolean> Trees (by M.key) already claimed again for their holder open here, which aren't claimed again. A view passes the same table on each load, so that a failing claim isn't retried on every reload.

--- The project's stale trees: `wt cleanup --stale`'s dry run (trees whose
--- holder has ended), with `wt list`'s entry for each. Each is to be removed,
--- skipped (`wt` would refuse: uncommitted changes, ...), or kept (in use here,
--- see M.in_use). A kept tree whose holder is a session open here is claimed
--- again for that session with Neovim's pid (worktree.reclaim), so that `wt`,
--- and other sessions' cleanups, see it as live again. Runs in the background,
--- and removes nothing.
---@param dir string In the project, e.g. Neovim's cwd.
---@param callback fun(stale: claude_code.StaleTree[]?, failed: claude_code.WtResult?)
---@param opts? claude_code.StaleOpts
function M.stale(dir, callback, opts)
  opts = opts or {}
  local listed, planned
  local function joined()
    if not (listed and planned) then
      return
    end
    if not planned.ok then
      return callback(nil, planned)
    end
    local data = listed.ok and listed.data or {}
    local by_name = {}
    for _, tree in ipairs(data.trees or {}) do
      by_name[tree.name] = tree
    end
    local out = {}
    for _, plan in ipairs(planned.data.plans or {}) do
      local tree = by_name[plan.name]
        or {
          name = plan.name,
          path = plan.path,
          slot = plan.slot,
          branch = plan.branch,
          state = plan.state,
          exists = plan.exists,
          holder = plan.holder,
        }
      tree.root = tree.root or data.root or dir
      local entry = { tree = tree, plan = plan, reasons = M.in_use(tree) }
      local blocked = type(plan.blocked) == "table" and plan.blocked or {}
      if #entry.reasons > 0 then
        entry.status = "keep"
        vim.list_extend(entry.reasons, blocked)
        local holder = type(tree.holder) == "table" and tree.holder or {}
        local open = holder.session and sessions.find(holder.session)
        local key = M.key(tree)
        if open and holder.state == "ended" and not (opts.reclaimed and opts.reclaimed[key]) then
          if opts.reclaimed then
            opts.reclaimed[key] = true
          end
          worktree.reclaim(open.id, tree, nil, function(result)
            if result and result.ok then
              notify(("%s's claim had lapsed, though %s is open here; claimed it again"):format(tree.name, title(open)))
            end
          end)
        end
      elseif #blocked > 0 then
        entry.status, entry.reasons = "skip", blocked
      else
        entry.status = "remove"
      end
      table.insert(out, entry)
    end
    callback(out)
  end
  worktree.list(dir, function(result)
    listed = result
    joined()
  end, { fresh = true })
  worktree.run({ "cleanup", "--stale" }, { cwd = dir }, function(result)
    planned = result
    joined()
  end)
end

--- How many batches of stale trees are being removed (see M.cleaning).
local cleaning = 0

--- Whether stale trees are being removed (M.remove_stale), e.g. so that a view
--- of them looks again once that's done, rather than after each tree.
---@return boolean
function M.cleaning()
  return cleaning > 0
end

--- A tree's line in the confirmation.
---@param plan table
---@return string
local function plan_summary(plan)
  local holder = type(plan.holder) == "table" and plan.holder or {}
  local who = holder.session and ("last held by %s"):format(worktree.describe_holder(holder)) or "not held"
  local branch = ""
  if plan.branch then
    local action = ({ ["-d"] = "deletes branch %s if merged", ["-D"] = "deletes branch %s" })[plan.branch_action]
    branch = " · " .. (action or "keeps branch %s"):format(plan.branch)
  end
  return ("  %s  (slot %s) · %s%s"):format(plan.name, tostring(plan.slot), who, branch)
end

--- Remove the stale trees (from M.stale) that are to be removed and aren't left
--- out, after one confirmation listing them. A tree that has come into use here
--- since (M.in_use) is left out, and the confirmation says so.
---
--- Every tree in the batch is marked "removing", so no session can start in it,
--- and removed as `:Claude trees` removes one (remove_confirmed): with
--- `wt rm <name> --yes`, not `wt cleanup --stale --yes`. `cleanup --yes` decides
--- again which trees are stale, so it would remove a tree left out here, or one
--- that became stale since, and only exactly the trees confirmed should go.
--- `wt rm --yes` still checks its tree again: it refuses one a live session has
--- claimed since, or that has changes now.
---
--- Reports what was removed and what wasn't, and why, then has views of the
--- trees look again (worktree.invalidate).
---@param stale claude_code.StaleTree[]
---@param callback? fun(batch: claude_code.TreeRemoval[]?) The batch once it's done, or nil when nothing was removed (nothing to remove, or cancelled).
function M.remove_stale(stale, callback)
  callback = callback or function() end
  local batch, left_out = {}, {}
  for _, entry in ipairs(stale) do
    if entry.status == "remove" and not entry.excluded then
      local using = M.in_use(entry.tree)
      if #using > 0 then
        table.insert(left_out, ("  %s: %s"):format(entry.tree.name, table.concat(using, "; ")))
      else
        table.insert(batch, entry)
      end
    end
  end
  if #batch == 0 then
    local message = "no stale trees to remove"
    if #left_out > 0 then
      message = message .. "; left out, now in use here:\n" .. table.concat(left_out, "\n")
    end
    notify(message)
    return callback(nil)
  end
  local lines = { ("Remove %d stale tree%s?"):format(#batch, #batch == 1 and "" or "s"), "" }
  local closing = {}
  for _, entry in ipairs(batch) do
    table.insert(lines, plan_summary(entry.plan))
    vim.list_extend(closing, M.sessions_in(entry.tree))
  end
  if #left_out > 0 then
    table.insert(lines, "")
    table.insert(lines, "Left out, now in use here:")
    vim.list_extend(lines, left_out)
  end
  vim.list_extend(lines, closing_lines(closing))
  table.insert(lines, "")
  table.insert(lines, "wt checks each tree again as it removes it.")
  if vim.fn.confirm(table.concat(lines, "\n"), "&Remove\n&Cancel", 2, "Warning") ~= 1 then
    return callback(nil)
  end
  local items = {}
  for _, entry in ipairs(batch) do
    -- As nobody, so `wt rm` refuses it if a live session has claimed it since.
    local item = { tree = entry.tree }
    -- In case anything ran while the question was open.
    local using = M.in_use(entry.tree)
    if #using > 0 then
      item.problem = "now in use here: " .. table.concat(using, "; ")
    else
      -- From here no session may start in it (see M.removing_at).
      set_busy(entry.tree, "removing")
    end
    table.insert(items, item)
  end
  cleaning = cleaning + 1
  remove_confirmed(items, function(done)
    cleaning = cleaning - 1
    local gone, kept = {}, {}
    for _, item in ipairs(done) do
      if item.result and item.result.ok then
        table.insert(gone, item.tree.name)
      else
        local why = item.problem or worktree.describe_failure(item.result, item.tree.name)
        table.insert(kept, ("  %s: %s"):format(item.tree.name, (why:gsub("\n", "\n    "))))
      end
    end
    local message = {}
    if #gone > 0 then
      local count = ("%d stale tree%s"):format(#gone, #gone == 1 and "" or "s")
      table.insert(message, ("removed %s: %s"):format(count, table.concat(gone, ", ")))
    end
    if #kept > 0 then
      table.insert(message, #gone > 0 and "not removed:" or "removed no stale trees; not removed:")
      vim.list_extend(message, kept)
    end
    notify(table.concat(message, "\n"), #kept > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    worktree.invalidate()
    callback(done)
  end)
end

return M
