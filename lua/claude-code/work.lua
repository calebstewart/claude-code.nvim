-- `:Claude work`: get a `wt` tree for a story, branch or description (creating
-- it, or claiming the one that exists), and open a session in it.
--
-- The tree is claimed as the session that's about to open: its id is chosen
-- first and passed to `wt` with Neovim's pid, the same identity the session's
-- process gets (WT_SESSION_ID, WT_PID; see worktree.session_env). So the claim
-- is the session's own from the start, stays live while Neovim has it open, and
-- is released when it's closed.

local Session = require("claude-code.session")
local config = require("claude-code.config")
local sessions = require("claude-code.sessions")
local worktree = require("claude-code.worktree")

local M = {}

--- Requests in progress: "<dir>\0<text>" -> the text.
---@type table<string, string>
local running = {}

--- Session ids being got a tree for -> what for; their sessions aren't open yet.
---@type table<string, string>
local pending = {}

---@param message string
---@param level? integer
local function notify(message, level)
  vim.notify("claude-code: " .. message, level or vim.log.levels.INFO)
end

--- Why `:Claude work` can't run, or nil.
---@return string?
local function unavailable()
  if config.options.worktree.enabled == false then
    return ":Claude work needs the worktree integration, which is off (`worktree.enabled = false`)"
  end
  if not worktree.path() then
    return ":Claude work needs `wt`, which wasn't found; install the worktree skill, or set `worktree.wt`"
  end
  if not config.claude_path() then
    return "`claude` executable not found; set `claude` in setup()"
  end
end

--- The registered tree `text` names exactly, by name or branch.
---@param listed claude_code.WtResult
---@param text string
---@return table?
local function find(listed, text)
  for _, tree in ipairs(listed.ok and listed.data and listed.data.trees or {}) do
    if tree.name == text or tree.branch == text then
      return tree
    end
  end
end

--- The tree `wt new` says to claim instead ("a tree named X is already
--- registered", "branch B is already checked out at <a tree>").
---@param result claude_code.WtResult
---@return string?
local function claim_instead(result)
  return result.outcome == "error" and result.hint and result.hint:match("claim ([%w._-]+)$") or nil
end

---@class claude_code.WorkOpts
---@field cwd? string Directory in the project to work in (default: Neovim's cwd).

--- Get a tree for `text` (`wt new`, or `wt claim` when it exists) and open a
--- session in it. Runs `wt` in the background.
---@param text string Story id, branch, tree name or description.
---@param opts? claude_code.WorkOpts
function M.work(text, opts)
  opts = opts or {}
  local problem = unavailable()
  if problem then
    notify(problem, vim.log.levels.ERROR)
    return
  end
  text = vim.trim(text or "")
  if text == "" then
    notify("say what to work on: a story id, a branch or a description", vim.log.levels.WARN)
    return
  end
  local cwd = vim.fs.normalize(opts.cwd or vim.fn.getcwd())
  local key = cwd .. "\0" .. text
  if running[key] then
    notify(("already getting a worktree for “%s”"):format(text))
    return
  end
  running[key] = text

  local id = Session.new_id()
  local identity = { id = id, pid = vim.fn.getpid() }
  pending[id] = text
  local started = vim.uv.now()

  local function finish()
    running[key] = nil
    pending[id] = nil
  end

  --- Open the session in the tree it now holds.
  ---@param tree table `wt`'s description of the tree.
  ---@param how string "created" or "claimed"
  local function open(tree, how)
    finish()
    local ok, session = pcall(sessions.new, nil, { cwd = tree.path, id = id, claimed = true })
    if ok and session then
      local took = math.floor((vim.uv.now() - started) / 1000 + 0.5)
      notify(
        ("%s %s (slot %s)%s"):format(how, tree.name, tree.slot or "?", took >= 2 and (", in %ds"):format(took) or "")
      )
      return
    end
    -- The session never existed: don't leave the tree held by it.
    notify(
      ("couldn't open a session in %s%s; releasing it"):format(tree.name, ok and "" or ": " .. tostring(session)),
      vim.log.levels.ERROR
    )
    worktree.run({ "release", tree.name }, { cwd = tree.root or cwd, session = identity }, function(result)
      if not result.ok then
        worktree.report(result, tree.name)
      end
    end)
  end

  --- When the tree's holder is a session open in this Neovim, show that session
  --- instead. Its claim may look ended (exit 4) when it was resumed in a new
  --- Neovim and still has the old one's pid: claim it again as that session
  --- rather than offering to take the tree away from it.
  ---@param name string
  ---@return fun(result: claude_code.WtResult): boolean
  local function held_here(name)
    return function(result)
      local holder = result.data and result.data.holder
      local session = holder and holder.session and sessions.find(holder.session)
      if session then
        notify(("%s is already open in “%s”"):format(name, session.title or "New session"))
        sessions.show(session)
        worktree.reclaim(session.id, { name = name, holder = holder }, cwd)
        return true
      end
      local other = holder and holder.session and pending[holder.session]
      if other then
        notify(("%s is being set up for “%s” already"):format(name, other), vim.log.levels.WARN)
        return true
      end
      return false
    end
  end

  ---@param name string
  local function claim(name)
    worktree.claim_interactively(function(take_over, done)
      worktree.run({ "claim", name, take_over and "--take-over" or nil }, { cwd = cwd, session = identity }, done)
    end, { what = name, on_holder = held_here(name) }, function(result)
      if result then
        open(result.data, "claimed")
      else
        finish()
      end
    end)
  end

  local function create()
    notify(("creating a worktree for “%s”…"):format(text))
    -- `--`: the text is never an option, even if it starts with "-".
    worktree.run({ "new", "--", text }, { cwd = cwd, session = identity }, function(result)
      if result.ok then
        return open(result.data, "created")
      end
      local existing = claim_instead(result)
      if existing then
        return claim(existing)
      end
      worktree.report(result, text)
      finish()
      -- A tree whose setup failed stays registered, held by this id: release it.
      if result.data and result.data.name then
        worktree.run({ "release", result.data.name }, { cwd = cwd, session = identity }, function() end)
      end
    end)
  end

  worktree.list(cwd, function(listed)
    if not listed.ok then
      worktree.report(listed)
      return finish()
    end
    local tree = find(listed, text)
    if tree then
      claim(tree.name)
    else
      create()
    end
  end, { fresh = true })
end

--- Tree names and branches in the project containing `dir`, for completion.
---@param dir string
---@return string[]
function M.candidates(dir)
  if not worktree.enabled() then
    return {}
  end
  local listed = worktree.list(dir)
  local out = {}
  for _, tree in ipairs(listed and listed.ok and listed.data and listed.data.trees or {}) do
    table.insert(out, tree.name)
    if tree.branch and tree.branch ~= tree.name then
      table.insert(out, tree.branch)
    end
  end
  return out
end

return M
