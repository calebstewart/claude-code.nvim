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

--- Commands that change which trees exist or who holds them.
local MUTATING = { new = true, adopt = true, claim = true, release = true, rm = true, cleanup = true, setup = true }

--- Blanks the variables `wt` falls back on for the session's identity, so a
--- Neovim started from inside a Claude session never acts as that session:
--- identity is only ever passed explicitly (`opts.session`). `wt` treats an
--- empty value as unset.
local ANONYMOUS = { WT_SESSION_ID = "", WT_PID = "", CLAUDE_CODE_SESSION_ID = "", CLAUDE_PID = "" }

--- How long a `wt list` result is reused for the same directory.
local LIST_TTL_MS = 5000

---@type table<string, { at: integer, result: claude_code.WtResult }>
local list_cache = {}

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
    M.invalidate()
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
--- outside this module.
function M.invalidate()
  list_cache = {}
end

--- `wt list` for the project containing `dir`, reused for a few seconds.
---@param dir string
---@param callback? fun(result: claude_code.WtResult) Without one, runs synchronously.
---@return claude_code.WtResult?
function M.list(dir, callback)
  local hit = list_cache[dir]
  if hit and vim.uv.now() - hit.at < LIST_TTL_MS then
    if callback then
      vim.schedule(function()
        callback(hit.result)
      end)
      return nil
    end
    return hit.result
  end
  local function store(result)
    if result.ok then
      list_cache[dir] = { at = vim.uv.now(), result = result }
    end
    return result
  end
  if callback then
    M.run({ "list" }, { cwd = dir }, function(result)
      callback(store(result))
    end)
    return nil
  end
  return store(M.run({ "list" }, { cwd = dir }) --[[@as claude_code.WtResult]])
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

--- The `wt` tree containing `dir`, or nil (not in a tree, not a git repository,
--- or `wt` unavailable). The tree is `wt list`'s entry: name, path, branch,
--- slot, state, holder, env, ...
---@param dir string
---@param callback? fun(tree: table?) Without one, runs synchronously.
---@return table?
function M.tree_for(dir, callback)
  if not M.enabled() or vim.fn.isdirectory(dir) == 0 then
    if callback then
      vim.schedule(function()
        callback(nil)
      end)
    end
    return nil
  end
  if callback then
    M.list(dir, function(result)
      callback(find_tree(result, dir))
    end)
    return nil
  end
  return find_tree(M.list(dir) --[[@as claude_code.WtResult]], dir)
end

return M
