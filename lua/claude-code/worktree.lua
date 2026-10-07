-- Optional integration with `wt`, the worktree skill's CLI
-- (https://calebstew.art/ai-slop/skills/worktree/). This module only runs `wt`
-- and reads its JSON: naming, slots, setup, liveness and safety checks all stay
-- in `wt`. Every other worktree feature goes through here.
--
-- `wt` never prompts. It reports decisions through exit codes (see M.outcomes),
-- and with `--json` prints its result, or `{ error, code, hint, ... }`, on stdout.

local config = require("claude-code.config")

local M = {}

--- What each `wt` exit code means.
---@alias claude_code.WtOutcome "ok"|"error"|"usage"|"held"|"confirm"|"refused"
---@type table<integer, claude_code.WtOutcome>
M.outcomes = {
  [0] = "ok", -- for rm/cleanup without --yes: a dry-run plan
  [1] = "error",
  [2] = "usage",
  [3] = "held", -- held by another session that is still running
  [4] = "confirm", -- held by a session that has ended: repeat with --take-over, after asking
  [5] = "refused", -- unsafe, or a blocked dry run
}

---@class claude_code.WtResult
---@field ok boolean Exit code 0.
---@field code integer Exit code.
---@field outcome claude_code.WtOutcome
---@field data? table Decoded JSON (on failure, includes `error`, `hint` and extras such as `holder`).
---@field error? string Failure message.
---@field hint? string Suggested next step, from `wt`.

---@class claude_code.WtSession Identity `wt` records for a claim.
---@field id string Session id.
---@field pid integer Process whose lifetime is the claim's.

---@class claude_code.WtRunOpts
---@field cwd? string Run as if started here (`-C`); default: Neovim's cwd.
---@field session? claude_code.WtSession Act for this session (`--session`, `--pid`).
---@field timeout? integer Milliseconds, when called without a callback (default 5000).
---@field package on_exit? fun(done: vim.SystemCompleted) With a callback: called as the process exits, in a fast event (before `callback` is scheduled), so a synchronous caller can wait for it without running anything else.

--- Commands that change which trees exist or who holds them.
local MUTATING = { new = true, adopt = true, claim = true, release = true, rm = true, cleanup = true, setup = true }

--- Blanks the variables `wt` falls back on for the session's identity, so a
--- Neovim started from inside a Claude session never acts as that session:
--- identity is only ever passed explicitly (`opts.session`). `wt` treats an
--- empty value as unset.
local ANONYMOUS = { WT_SESSION_ID = "", WT_PID = "", CLAUDE_CODE_SESSION_ID = "", CLAUDE_PID = "" }

--- `User` autocmd fired (on the next tick) after the trees or their holders may
--- have changed: a mutating command run through this module finished, or
--- M.invalidate() was called. Views showing a tree look it up again.
M.CHANGED = "ClaudeCodeWorktreesChanged"

--- How long a `wt list` result is reused for the same directory.
local LIST_TTL_MS = 5000

--- Keyed by directory; `at` is when the `wt list` started.
---@type table<string, { at: integer, result: claude_code.WtResult }>
local list_cache = {}

--- Asynchronous `wt list`s running, by directory, with the callbacks waiting on
--- each. `done` is the finished process, set as soon as it exits (see M.list).
---@alias claude_code.WtListRun { at: integer, generation: integer, callbacks: fun(result: claude_code.WtResult)[], done?: vim.SystemCompleted }
---@type table<string, claude_code.WtListRun>
local in_flight = {}

--- Bumped by M.invalidate(). A `wt list` caches its result only if this hasn't
--- changed since it started, so one that read the registry before a change
--- can't put the old state back after the change cleared the cache.
local generation = 0

local function forget()
  list_cache = {}
  generation = generation + 1
end

---@return string
local function default_path()
  local base = vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME or "~", ".claude")
  return vim.fs.joinpath(base, "skills", "worktree", "bin", "wt")
end

--- The `wt` executable, or nil when it isn't installed.
---
--- `worktree.wt` may be a path or a command name on $PATH. Unset, only the
--- skill's install location is tried, not $PATH: other tools are called `wt` too.
---@return string?
function M.path()
  local wt = config.options.worktree.wt
  if wt then
    local path = vim.fn.exepath(vim.fn.expand(wt))
    return path ~= "" and path or nil
  end
  local path = default_path()
  return vim.fn.executable(path) == 1 and path or nil
end

--- Whether worktree features are on: `worktree.enabled`, or when that is nil,
--- whether `wt` is installed.
---@return boolean
function M.enabled()
  local enabled = config.options.worktree.enabled
  if enabled == false then
    return false
  end
  return M.path() ~= nil
end

---@param args string[]
---@param opts claude_code.WtRunOpts
---@return string[]?
local function command(args, opts)
  local path = M.path()
  if not path then
    return nil
  end
  local cmd = { path, "--json" }
  if opts.cwd then
    vim.list_extend(cmd, { "-C", opts.cwd })
  end
  if opts.session then
    vim.list_extend(cmd, { "--session", opts.session.id, "--pid", tostring(opts.session.pid) })
  end
  return vim.list_extend(cmd, args)
end

--- Turn a finished `wt` process into a result.
---@param code integer
---@param stdout? string
---@param stderr? string
---@return claude_code.WtResult
function M.parse(code, stdout, stderr)
  local ok, data = pcall(vim.json.decode, stdout or "", { luanil = { object = true, array = true } })
  data = ok and type(data) == "table" and data or nil
  local result = {
    ok = code == 0,
    code = code,
    outcome = M.outcomes[code] or "error",
    data = data,
  }
  if code ~= 0 then
    -- A blocked `rm` is not an error object but a plan saying why; argparse's
    -- usage errors are plain text on stderr, not JSON.
    local blocked = data and type(data.plan) == "table" and data.plan.blocked
    if data and data.error then
      result.error = data.error
    elseif type(blocked) == "table" and #blocked > 0 then
      result.error = table.concat(blocked, "; ")
    else
      result.error = vim.trim(stderr or "")
    end
    if result.error == "" then
      result.error = ("wt exited with code %d"):format(code)
    end
    result.hint = data and data.hint or nil
  elseif not data then
    result.ok, result.outcome, result.error = false, "error", "wt printed no JSON"
  end
  return result
end

---@param message string
---@return claude_code.WtResult
local function failure(message)
  return { ok = false, code = 1, outcome = "error", error = message }
end

--- Run `wt <args>` with `--json`.
---
--- With a callback, runs asynchronously and calls it on the main loop. Without
--- one, waits (up to `opts.timeout`) and returns the result.
---@param args string[] Subcommand and its arguments, e.g. { "claim", "foo", "--take-over" }.
---@param opts? claude_code.WtRunOpts
---@param callback? fun(result: claude_code.WtResult)
---@return claude_code.WtResult?
function M.run(args, opts, callback)
  opts = opts or {}
  local cmd = command(args, opts)
  if MUTATING[args[1]] then
    forget()
  end
  if not cmd then
    local result = failure("wt not found; install the worktree skill, or set `worktree.wt`")
    if callback then
      vim.schedule(function()
        callback(result)
      end)
      return nil
    end
    return result
  end

  local function finish(done)
    if MUTATING[args[1]] then
      M.invalidate()
    end
    return M.parse(done.code, done.stdout, done.stderr)
  end

  local ok, proc = pcall(vim.system, cmd, { text = true, env = ANONYMOUS }, callback and function(done)
    if opts.on_exit then
      opts.on_exit(done)
    end
    vim.schedule(function()
      callback(finish(done))
    end)
  end or nil)
  if not ok then
    local result = failure(tostring(proc))
    if callback then
      vim.schedule(function()
        callback(result)
      end)
      return nil
    end
    return result
  end
  if callback then
    return nil
  end
  local timeout = opts.timeout or 5000
  local done = proc:wait(timeout)
  -- On timeout vim.system kills the process and reports exit code 124.
  if done.code == 124 and done.signal ~= 0 then
    return failure(("wt did not finish within %d ms"):format(timeout))
  end
  return finish(done)
end

--- Forget cached `wt list` results, e.g. after a tree was created or removed
--- outside this module, and tell views showing a tree (M.CHANGED).
function M.invalidate()
  forget()
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = M.CHANGED, modeline = false })
  end)
end

---@class claude_code.WtListOpts
---@field fresh? boolean Only a `wt list` started by this call or later will do, not a cached or running older one.

--- `wt list` for the project containing `dir`, reused for a few seconds.
---
--- Asynchronous calls for the same directory share a running `wt list`. With
--- `opts.fresh`, the result reflects the registry as of the call, e.g. to catch
--- a change made outside the plugin; fresh calls in the same tick still share.
---@param dir string
---@param callback? fun(result: claude_code.WtResult) Without one, runs synchronously.
---@param opts? claude_code.WtListOpts
---@return claude_code.WtResult?
function M.list(dir, callback, opts)
  local now = vim.uv.now()
  -- The oldest start time of a `wt list` whose result will do.
  local oldest = opts and opts.fresh and now or now - LIST_TTL_MS + 1
  local hit = list_cache[dir]
  if hit and hit.at >= oldest then
    if callback then
      vim.schedule(function()
        callback(hit.result)
      end)
      return nil
    end
    return hit.result
  end
  local started = generation
  ---@param result claude_code.WtResult
  ---@param at integer When the `wt list` that produced it started.
  local function store(result, at)
    -- A fresh `wt list` can overtake an older one still running: the newer start wins.
    local newer = list_cache[dir]
    if result.ok and generation == started and not (newer and newer.at > at) then
      list_cache[dir] = { at = at, result = result }
    end
    return result
  end
  local running = in_flight[dir]
  local joinable = running and running.generation == generation and running.at >= oldest
  if not callback then
    if joinable then
      -- Wait for the background `wt list` that will do rather than start
      -- another (e.g. a new session starting while its chat's winbar looks the
      -- tree up). Only fast events run meanwhile, as in a synchronous M.run: no
      -- scheduled callbacks or autocmds, which could re-enter the caller.
      vim.wait(5000, function()
        return running.done ~= nil
      end, 5, true)
      local done = running.done
      if not done then
        return failure("wt did not finish within 5000 ms")
      end
      return store(M.parse(done.code, done.stdout, done.stderr), running.at)
    end
    return store(M.run({ "list" }, { cwd = dir }) --[[@as claude_code.WtResult]], now)
  end
  if joinable then
    table.insert(running.callbacks, callback)
    return nil
  end
  ---@type claude_code.WtListRun
  running = { at = now, generation = generation, callbacks = { callback } }
  in_flight[dir] = running
  local run_opts = {
    cwd = dir,
    on_exit = function(done)
      running.done = done
    end,
  }
  M.run({ "list" }, run_opts, function(result)
    if in_flight[dir] == running then
      in_flight[dir] = nil
    end
    store(result, running.at)
    for _, cb in ipairs(running.callbacks) do
      cb(result)
    end
  end)
  return nil
end

--- Whether `dir` is `root` or somewhere inside it.
---@param dir string
---@param root string
---@return boolean
local function within(dir, root)
  return dir == root or vim.startswith(dir, root:gsub("/+$", "") .. "/")
end

---@param dir string
---@return string
local function real(dir)
  return vim.uv.fs_realpath(dir) or vim.fs.normalize(dir)
end

--- The registered tree containing `dir`, from `wt list`.
---@param result claude_code.WtResult
---@param dir string
---@return table?
local function find_tree(result, dir)
  if not result.ok or not result.data then
    return nil
  end
  dir = real(dir)
  for _, tree in ipairs(result.data.trees or {}) do
    if tree.path and within(dir, tree.path) then
      return tree
    end
  end
  return nil
end

--- Whether `dir` is in a linked git worktree: the nearest `.git` above it is a
--- file, not a directory. Every `wt` tree is one (the root checkout can't be a
--- tree), so anywhere else can't be in a tree, and this answers that without
--- starting `wt` (a Python process, around 100 ms).
---@param dir string
---@return boolean
local function in_linked_worktree(dir)
  local git = vim.fs.find(".git", { path = dir, upward = true, limit = 1 })[1]
  local stat = git and vim.uv.fs_stat(git)
  return stat ~= nil and stat.type == "file"
end

--- The tree containing `dir`, and why it couldn't be found if `wt` failed.
---@param dir string
---@param callback? fun(tree: table?, err: string?) Without one, runs synchronously.
---@param opts? claude_code.WtListOpts
---@return table? tree
---@return string? err
local function lookup(dir, callback, opts)
  if not M.enabled() or vim.fn.isdirectory(dir) == 0 or not in_linked_worktree(dir) then
    if callback then
      vim.schedule(function()
        callback(nil)
      end)
    end
    return nil
  end
  local function found(result)
    return find_tree(result, dir), not result.ok and result.error or nil
  end
  if callback then
    M.list(dir, function(result)
      callback(found(result))
    end, opts)
    return nil
  end
  return found(M.list(dir, nil, opts) --[[@as claude_code.WtResult]])
end

--- The `wt` tree containing `dir`, or nil (not in a tree, not a git repository,
--- or `wt` unavailable). The tree is `wt list`'s entry: name, path, branch,
--- slot, state, holder, env, ...
---@param dir string
---@param callback? fun(tree: table?) Without one, runs synchronously.
---@param opts? claude_code.WtListOpts
---@return table?
function M.tree_for(dir, callback, opts)
  if callback then
    lookup(dir, function(tree)
      callback(tree)
    end, opts)
    return nil
  end
  return (lookup(dir, nil, opts))
end

--- Environment for a session's claude process running in `dir`: the tree's
--- environment when `dir` is in one (what `wt env <name>` prints: its setup
--- output plus `wt`'s own WT_* variables), and the session's identity.
---
--- WT_PID is Neovim's pid, not the claude process's: `wt` reads it before
--- CLAUDE_PID, so a claim made from the session stays live while Neovim has the
--- session open, including while its process is stopped for being idle.
--- WT_SESSION_ID pins the id too, over any WT_SESSION_ID Neovim inherited.
---
--- When the tree is the session's own but its claim has ended (the session was
--- resumed in a new Neovim, so the claim has the old Neovim's pid), it's
--- claimed again with this Neovim's pid, in the background (M.reclaim).
---
--- Synchronous, but only runs `wt` when `dir` is in a linked git worktree.
---@param session_id string
---@param dir string
---@return table<string, string> env
---@return string? err Why the tree's environment is missing, when `wt` failed.
function M.session_env(session_id, dir)
  local env = {}
  local tree, err = lookup(dir)
  if tree and type(tree.env) == "table" then
    for name, value in pairs(tree.env) do
      if type(name) == "string" and (type(value) == "string" or type(value) == "number") then
        env[name] = tostring(value)
      end
    end
  end
  env.WT_PID = tostring(vim.fn.getpid())
  env.WT_SESSION_ID = session_id
  M.reclaim(session_id, tree)
  return env, err
end

--- Who holds a tree, for messages: the session's title when it's open in this
--- Neovim, else `wt`'s label for it, else the start of its id.
---@param holder? table A tree's `holder`, or `data.holder` of a failed claim.
---@return string
function M.describe_holder(holder)
  if type(holder) ~= "table" or not holder.session then
    return "nobody"
  end
  local sessions = package.loaded["claude-code.sessions"]
  local open = sessions and sessions.find(holder.session)
  if open then
    return ("“%s” (open in this Neovim)"):format(open.title or "New session")
  end
  if type(holder.label) == "string" and holder.label ~= "" then
    return ("“%s”"):format(holder.label)
  end
  return ("session %s"):format(tostring(holder.session):sub(1, 8))
end

--- Show why a `wt` command failed: who holds the tree (held), or `wt`'s reason
--- and hint.
---@param result claude_code.WtResult
---@param what? string The tree, for the message, e.g. its name.
function M.report(result, what)
  what = what or (result.data and result.data.name) or "the worktree"
  local message
  if result.outcome == "held" and result.data and result.data.holder then
    message = ("%s is held by %s, which is still running"):format(what, M.describe_holder(result.data.holder))
  elseif result.outcome == "refused" then
    message = ("wt refused: %s"):format(result.error or "no reason given")
  else
    message = result.error or ("wt exited with code %d"):format(result.code)
  end
  if result.hint and result.outcome ~= "held" then
    message = message .. "\nhint: " .. result.hint
  end
  vim.notify("claude-code: " .. message, result.outcome == "held" and vim.log.levels.WARN or vim.log.levels.ERROR)
end

---@class claude_code.WtClaimOpts
---@field what? string The tree, for messages, e.g. its name.
---@field on_holder? fun(result: claude_code.WtResult): boolean? Called when another session holds the tree, live (exit 3) or ended (exit 4), before reporting or asking; return true when it's dealt with. E.g. the holder is a session open in this Neovim, whose claim only looks ended because it was resumed in a new Neovim.

--- Run a `wt` command that claims a tree (`claim`, `new`, `adopt --claim`),
--- taking the decisions `wt` leaves to its caller in the editor:
---
--- - held by a live session (exit 3): report who holds it;
--- - held by a session that has ended (exit 4): ask, then run it again with
---   `--take-over`;
---   (either of these only when `opts.on_holder` doesn't deal with it first)
--- - refused (exit 5), or any other failure: show `wt`'s reason and hint.
---
--- `callback` gets the successful result, or nil when it failed (already
--- reported) or the take-over was declined.
---@param run fun(take_over: boolean, done: fun(result: claude_code.WtResult)) Runs the command, in the background; with `take_over`, adds `--take-over`.
---@param opts? claude_code.WtClaimOpts
---@param callback fun(result: claude_code.WtResult?)
function M.claim_interactively(run, opts, callback)
  opts = opts or {}
  local function handle(result, took_over)
    if result.ok then
      return callback(result)
    end
    local what = opts.what or (result.data and result.data.name) or "the worktree"
    local by_holder = result.outcome == "held" or (result.outcome == "confirm" and not took_over)
    if by_holder and opts.on_holder and opts.on_holder(result) then
      return callback(nil)
    end
    if result.outcome == "confirm" and not took_over then
      local holder = result.data and result.data.holder
      local prompt = ("%s was last used by %s, which has ended. Take it over?"):format(what, M.describe_holder(holder))
      vim.ui.select({ "Take it over", "Cancel" }, { prompt = prompt }, function(choice)
        if choice == "Take it over" then
          run(true, function(again)
            handle(again, true)
          end)
        else
          vim.notify(("claude-code: left %s to its previous session"):format(what))
          callback(nil)
        end
      end)
      return
    end
    M.report(result, what)
    callback(nil)
  end
  run(false, function(result)
    handle(result, false)
  end)
end

--- Claim `tree` again as session `id` with Neovim's pid, when `wt` records it as
--- that session's but with a process that has ended: the session was resumed
--- in a new Neovim (its claim has the old Neovim's pid, see M.session_env).
--- `wt` grants it without `--take-over`, since the claim is already the
--- session's. Does nothing for a tree held by another session, or by nobody.
--- Runs in the background; a failure is only reported.
---@param id string
---@param tree? table The tree's `wt list` entry (or a failed claim's `data`, with `name` and `holder`).
---@param cwd? string Where to run `wt` (default: the tree's `root`).
---@param callback? fun(result: claude_code.WtResult?) The claim's result, or nil when there was nothing to do.
function M.reclaim(id, tree, cwd, callback)
  local holder = tree and tree.holder
  if type(holder) ~= "table" or holder.session ~= id or holder.state ~= "ended" then
    if callback then
      vim.schedule(function()
        callback(nil)
      end)
    end
    return
  end
  local opts = { cwd = cwd or tree.root or tree.path, session = { id = id, pid = vim.fn.getpid() } }
  M.run({ "claim", tree.name }, opts, function(result)
    if not result.ok then
      M.report(result, tree.name)
    end
    if callback then
      callback(result)
    end
  end)
end

---@class claude_code.WtReleaseOpts
---@field keep? fun(): boolean Whether session `id` should keep its tree after all, e.g. it was reopened in this Neovim since it was closed. Checked just before `wt release` runs, which is then skipped, and again once it has run, when the tree is claimed back.

--- Releases of each session id that are running (see M.release_session), with
--- the ones waiting for them to finish.
---@type table<string, fun()[]>
local releasing = {}

---@param id string
---@param keep fun(): boolean
---@param done fun(name: string?, result: claude_code.WtResult?)
local function release_now(id, keep, done)
  M.run({ "list", "--all-projects" }, {}, function(listed)
    if not listed.ok then
      return done(nil, listed)
    end
    if keep() then
      return done(nil)
    end
    for _, project in ipairs(listed.data or {}) do
      for _, tree in ipairs(project.trees or {}) do
        if type(tree.holder) == "table" and tree.holder.session == id then
          local session = { id = id, pid = vim.fn.getpid() }
          local cwd = tree.root or project.root
          M.run({ "release", tree.name }, { cwd = cwd, session = session }, function(result)
            if not (result.ok and keep()) then
              return done(tree.name, not result.ok and result or nil)
            end
            -- Reopened while `wt release` ran: give the tree back. Nobody holds
            -- it now, unless another session took it in the meantime, which
            -- is only reported (no --take-over).
            M.run({ "claim", tree.name }, { cwd = cwd, session = session }, function(claimed)
              if not claimed.ok then
                M.report(claimed, tree.name)
              end
              done(nil)
            end)
          end)
          return
        end
      end
    end
    done(nil)
  end)
end

--- Release whichever tree session `id` holds, in any project, acting as that
--- session (`--session`, with Neovim's pid). Found from `wt list --all-projects`
--- by its holder, not from the session's directory: a session may hold a tree
--- other than the one it runs in. `wt` gives a session at most one tree.
---
--- `wt` keys a claim by session id, so a session reopened with the same id
--- would lose its claim to a release meant for when it was closed. With
--- `opts.keep`, the release is skipped when it returns true before `wt release`
--- runs, and undone (the tree claimed again as `id`) when it returns true only
--- once `wt release` has run. A failed re-claim is reported.
---
--- Releases of the same id run one at a time, in order: one that starts while
--- an earlier one is still claiming the tree back would find nothing to
--- release, and the claim would then outlive the session. Each release runs
--- at most three `wt` commands, so the last one to finish decides, from
--- whether the session is open by then.
---@param id string
---@param callback fun(name: string?, result: claude_code.WtResult?) `name` is nil when the session held nothing or kept its tree; `result` is the failed `wt` call, if any.
---@param opts? claude_code.WtReleaseOpts
function M.release_session(id, callback, opts)
  local keep = opts and opts.keep or function()
    return false
  end
  local function start()
    release_now(id, keep, function(name, result)
      local next_release = table.remove(releasing[id], 1)
      if next_release then
        next_release()
      else
        releasing[id] = nil
      end
      callback(name, result)
    end)
  end
  if releasing[id] then
    table.insert(releasing[id], start)
    return
  end
  releasing[id] = {}
  start()
end

return M
