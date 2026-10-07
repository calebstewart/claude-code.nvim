-- `:Claude work`: get a `wt` tree for a story, branch or description (creating
-- it, or claiming the one that exists), and open a session in it. The tree
-- picker (`:Claude trees`) opens or resumes sessions in a tree through here too.
--
-- The tree is claimed as the session that's about to open: its id is chosen
-- first (or, resuming, is the stored session's) and passed to `wt` with
-- Neovim's pid, the same identity the session's process gets (WT_SESSION_ID,
-- WT_PID; see worktree.session_env). So the claim is the session's own from the
-- start, stays live while Neovim has it open, and is released when it's closed.

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

--- Why `:Claude <command>` can't run, or nil.
---@param command string
---@return string?
function M.unavailable(command)
  if config.options.worktree.enabled == false then
    return (":Claude %s needs the worktree integration, which is off (`worktree.enabled = false`)"):format(command)
  end
  if not worktree.path() then
    return (":Claude %s needs `wt`, which wasn't found; install the worktree skill, or set `worktree.wt`"):format(
      command
    )
  end
end

--- Why a session can't be opened in a tree, or nil.
---@return string?
local function cannot_open()
  return M.unavailable("work")
    or (not config.claude_path() and "`claude` executable not found; set `claude` in setup()")
    or nil
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

---@class claude_code.WorkRequest
---@field cwd string Where `wt` runs.
---@field text string What it's for, for messages.
---@field id string The session's id.
---@field identity claude_code.WtSession
---@field resume? table SDKSessionInfo of the stored session to resume, instead of starting a new one.
---@field started integer
---@field key string

--- Start a request, or nil (after saying so) when the same one is running.
---@param cwd string
---@param text string
---@param resume? table
---@return claude_code.WorkRequest?
local function begin(cwd, text, resume)
  local key = cwd .. "\0" .. text
  if running[key] then
    notify(("already getting a worktree for “%s”"):format(text))
    return nil
  end
  running[key] = text
  local id = resume and resume.sessionId or Session.new_id()
  pending[id] = text
  return {
    cwd = cwd,
    text = text,
    id = id,
    identity = { id = id, pid = vim.fn.getpid() },
    resume = resume,
    started = vim.uv.now(),
    key = key,
  }
end

---@param request claude_code.WorkRequest
local function finish(request)
  running[request.key] = nil
  pending[request.id] = nil
end

--- Open the request's session in the tree it now holds.
---@param request claude_code.WorkRequest
---@param tree table `wt`'s description of the tree.
---@param how string "created" or "claimed"
local function open_now(request, tree, how)
  finish(request)
  local ok, session
  if request.resume then
    ok, session = pcall(function()
      sessions.open(request.resume)
      return sessions.find(request.id)
    end)
  else
    ok, session = pcall(sessions.new, nil, { cwd = tree.path, id = request.id, claimed = true })
  end
  if ok and session then
    local took = math.floor((vim.uv.now() - request.started) / 1000 + 0.5)
    notify(
      ("%s %s (slot %s)%s"):format(how, tree.name, tree.slot or "?", took >= 2 and (", in %ds"):format(took) or "")
    )
    return
  end
  -- The session never opened: don't leave the tree held by it.
  notify(
    ("couldn't open a session in %s%s; releasing it"):format(tree.name, ok and "" or ": " .. tostring(session)),
    vim.log.levels.ERROR
  )
  worktree.run(
    { "release", tree.name },
    { cwd = tree.root or request.cwd, session = request.identity },
    function(result)
      if not result.ok then
        worktree.report(result, tree.name)
      end
    end
  )
end

--- Open the session once a background `wt list` of the tree is cached: the
--- session's start looks its tree up synchronously (worktree.session_env),
--- and the `wt new`/`claim` that just ran cleared the cache.
---@param request claude_code.WorkRequest
---@param tree table
---@param how string
local function open(request, tree, how)
  worktree.list(tree.path, function()
    open_now(request, tree, how)
  end)
end

--- When the tree's holder is a session open in this Neovim, show that session
--- instead. Its claim may look ended (exit 4) when it was resumed in a new
--- Neovim and still has the old one's pid: claim it again as that session
--- rather than offering to take the tree away from it.
---@param request claude_code.WorkRequest
---@param name string
---@return fun(result: claude_code.WtResult): boolean
local function held_here(request, name)
  return function(result)
    local holder = result.data and result.data.holder
    local session = holder and holder.session and sessions.find(holder.session)
    if session then
      notify(("%s is already open in “%s”"):format(name, session.title or "New session"))
      sessions.show(session)
      worktree.reclaim(session.id, { name = name, holder = holder }, request.cwd)
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

---@param request claude_code.WorkRequest
---@param name string
local function claim(request, name)
  worktree.claim_interactively(function(take_over, done)
    local args = { "claim", name, take_over and "--take-over" or nil }
    worktree.run(args, { cwd = request.cwd, session = request.identity }, done)
  end, { what = name, on_holder = held_here(request, name) }, function(result)
    if result then
      open(request, result.data, request.resume and "resumed a session in" or "claimed")
    else
      finish(request)
    end
  end)
end

---@param request claude_code.WorkRequest
local function create(request)
  local text = request.text
  notify(("creating a worktree for “%s”…"):format(text))
  -- `--`: the text is never an option, even if it starts with "-".
  worktree.run({ "new", "--", text }, { cwd = request.cwd, session = request.identity }, function(result)
    if result.ok then
      return open(request, result.data, "created")
    end
    local existing = claim_instead(result)
    if existing then
      return claim(request, existing)
    end
    worktree.report(result, text)
    finish(request)
    -- A tree whose setup failed stays registered, held by this id: release it.
    if result.data and result.data.name then
      worktree.run({ "release", result.data.name }, { cwd = request.cwd, session = request.identity }, function() end)
    end
  end)
end

---@class claude_code.WorkOpts
---@field cwd? string Directory in the project to work in (default: Neovim's cwd).

--- Get a tree for `text` (`wt new`, or `wt claim` when it exists) and open a
--- session in it. Runs `wt` in the background.
---@param text string Story id, branch, tree name or description.
---@param opts? claude_code.WorkOpts
function M.work(text, opts)
  opts = opts or {}
  local problem = cannot_open()
  if problem then
    notify(problem, vim.log.levels.ERROR)
    return
  end
  text = vim.trim(text or "")
  if text == "" then
    notify("say what to work on: a story id, a branch or a description", vim.log.levels.WARN)
    return
  end
  local request = begin(vim.fs.normalize(opts.cwd or vim.fn.getcwd()), text)
  if not request then
    return
  end
  worktree.list(request.cwd, function(listed)
    if not listed.ok then
      worktree.report(listed)
      return finish(request)
    end
    local tree = find(listed, text)
    if tree then
      claim(request, tree.name)
    else
      create(request)
    end
  end, { fresh = true })
end

---@class claude_code.WorkOpenOpts
---@field resume? table SDKSessionInfo of a stored session to resume in the tree, instead of starting a new one.

--- Claim an existing tree (from `wt list`) for a session and open it there: a
--- new session, or `opts.resume`. Runs `wt` in the background. Doesn't check
--- for a session already open in the tree; the tree picker does that first.
---@param tree table
---@param opts? claude_code.WorkOpenOpts
function M.open(tree, opts)
  opts = opts or {}
  local problem = cannot_open()
  if problem then
    notify(problem, vim.log.levels.ERROR)
    return
  end
  local request = begin(tree.root or vim.fn.getcwd(), tree.name, opts.resume)
  if request then
    claim(request, tree.name)
  end
end

--- Tree names and branches in the project containing `dir`, for completion.
---@param dir string
---@param names_only? boolean Leave out branches.
---@return string[]
function M.candidates(dir, names_only)
  if not worktree.enabled() then
    return {}
  end
  local listed = worktree.list(dir)
  local out = {}
  for _, tree in ipairs(listed and listed.ok and listed.data and listed.data.trees or {}) do
    table.insert(out, tree.name)
    if not names_only and tree.branch and tree.branch ~= tree.name then
      table.insert(out, tree.branch)
    end
  end
  return out
end

return M
