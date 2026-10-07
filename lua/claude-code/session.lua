-- A Session is one Claude conversation: its chat sidebar (which outlives the
-- process) and, while it's running, a sidecar process. A session that isn't
-- running — suspended while idle, exited, or opened from disk — is resumed
-- automatically when it's needed.

local Chat = require("claude-code.ui.chat")
local Held = require("claude-code.ui.held")
local Permissions = require("claude-code.ui.permission")
local config = require("claude-code.config")
local control = require("claude-code.control")
local modes = require("claude-code.modes")
local tools = require("claude-code.ui.tools")
local transport = require("claude-code.transport")
local worktree = require("claude-code.worktree")

---@class claude_code.Session
---@field id string Claude session id (chosen up front for new sessions).
---@field claimed? boolean Opened for a `wt` tree it already holds (`:Claude work`): never discarded as a placeholder.
---@field title? string Custom title, or Claude Code's summary.
---@field private named boolean `title` was chosen (not Claude Code's summary): it's also the name other sessions message this one by.
---@field cwd string
---@field chat claude_code.Chat
---@field busy boolean A turn is in progress.
---@field last_active integer os.time() of the last activity.
---@field mode? claude_code.PermissionMode Current permission mode (nil until Claude Code reports it).
---@field private started_mode? claude_code.PermissionMode Mode the process was started in.
---@field private commands claude_code.SlashCommand[] From the SDK.
---@field private terminal_commands table<string, true> Commands tied to the CLI's terminal UI.
---@field private streamed table<string, true> Assistant message ids whose text arrived as stream events.
---@field private shell? { job: vim.SystemObj, id: string, killed: boolean } A running `!command`.
---@field private shell_count integer
---@field private replay_shell? string Replaying: id of the `!command` awaiting its output.
---@field private relocating? boolean Asking where to move it (its directory is gone).
---@field private silent_results integer Results still to come from context-only messages (they have no turn to finish).
---@field private subagents table<string, claude_code.Subagent> Agent/Task tool_use id -> its subagent.
---@field private child_parent table<string, string> A subagent's own tool_use id -> its Agent call.
---@field private tasks table<string, string> SDK task id -> Agent tool_use id.
---@field private notes string[] Notes to add once the current turn ends (e.g. a background agent finished).
---@field private persisted boolean Its transcript exists on disk (so it can be resumed).
---@field private sidecar? claude_code.Sidecar|claude_code.Cli The session transport (see claude-code/transport.lua).
---@field private permissions claude_code.Permissions
---@field private held claude_code.Held Messages from other sessions awaiting delivery.
---@field private messaging boolean Has messaged, or been messaged by, another session: kept running while idle so replies reach it.
---@field private suspending boolean
---@field private env? table<string, string> Extra environment the running process was started with (see environment()).
---@field private pending_title? string Rename to apply once the transcript exists.
---@field private in_reply boolean The current turn already has a "Claude" header.
---@field private reply_has_text boolean
---@field private interrupted boolean
---@field private cost number Cumulative session cost reported by the last result.
---@field private queue claude_code.QueuedMessage[] Prompts sent while Claude was working, delivered when the turn ends.
---@field private state_events boolean Claude Code reports session_state_changed (so idle, not the result, ends a turn).
---@field private reload_pending? boolean The transcript was replaced mid-turn; reload the conversation when it ends.
local Session = {}
Session.__index = Session

---@class claude_code.QueuedMessage
---@field text string
---@field attachments { label: string, image: claude_code.Image }[] As attached in the prompt (to restore it for editing).
---@field payload table[] Images prepared for sending.
---@field shown table[] Images as the transcript shows them.

local count = 0

--- Resuming shows at most this many of the most recent messages.
local REPLAY_LIMIT = 200

--- A random RFC 4122 v4 UUID.
local function uuid()
  math.randomseed(vim.uv.hrtime())
  return (
    ("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
      return ("%x"):format(c == "x" and math.random(0, 15) or math.random(8, 11))
    end)
  )
end

--- Text of a user message's content (a string or text blocks).
---@param content any
---@return string
local function content_text(content)
  if type(content) == "string" then
    return content
  end
  local parts = {}
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "text" and type(block.text) == "string" then
      table.insert(parts, block.text)
    end
  end
  return table.concat(parts, "\n")
end

local ENTITIES = { lt = "<", gt = ">", quot = '"', apos = "'", amp = "&" }

---@param text string
local function unescape(text)
  return (text:gsub("&(%a+);", function(name)
    return ENTITIES[name]
  end):gsub("&#(%d+);", function(code)
    return vim.fn.nr2char(tonumber(code))
  end))
end

---@class claude_code.PeerMessage
---@field from string Name of the sending session (or its address when it gave none).
---@field body string

--- A message from another Claude session, as Claude Code wraps it for the model:
--- `<cross-session-message from="…" from-name="…">body</cross-session-message>`.
---@param text string
---@return claude_code.PeerMessage?
local function parse_peer_message(text)
  local attrs, body = text:match("<cross%-session%-message(.-)>(.-)</cross%-session%-message>")
  if not attrs then
    return nil
  end
  local from = attrs:match('from%-name="(.-)"') or attrs:match('from="(.-)"') or "another session"
  return { from = unescape(from), body = unescape(vim.trim(body)) }
end

--- The peer message a replayed user message carries, if it's one. Claude Code
--- describes it in `origin`; the envelope in the text is the fallback.
---@param msg table SDKUserMessageReplay
---@return claude_code.PeerMessage?
local function replayed_peer_message(msg)
  local origin = type(msg.origin) == "table" and msg.origin or {}
  local parsed = parse_peer_message(content_text(msg.message and msg.message.content))
  if origin.kind ~= "peer" and not parsed then
    return nil
  end
  local from = origin.name or (parsed and parsed.from) or origin.from or "another session"
  local body = origin.body or (parsed and parsed.body) or ""
  return { from = from, body = body }
end

--- What happened to a held message that was dropped (peer_message_hold's `outcome`).
local DROPPED = {
  expired = "expired before it was delivered",
  refused = "was refused",
  dropped = "was dropped",
  discarded = "was discarded",
}

---@class claude_code.SessionOpts
---@field title? string Name for a new session.
---@field info? table SDKSessionInfo of a stored session to resume.
---@field cwd? string Directory for a new session to run in (default: Neovim's cwd).
---@field id? string Id for a new session, chosen beforehand (see Session.new_id), e.g. to claim a `wt` tree as it.
---@field claimed? boolean It already holds a `wt` tree (see Session.claimed).

--- A fresh session id, for a new session whose id is needed before it's opened.
---@return string
function Session.new_id()
  return uuid()
end

---@param opts? claude_code.SessionOpts
---@return claude_code.Session?
function Session.new(opts)
  opts = opts or {}
  if not config.claude_path() then
    vim.notify("claude-code: `claude` executable not found; set `claude` in setup()", vim.log.levels.ERROR)
    return nil
  end

  count = count + 1
  local info = opts.info
  local self = setmetatable({
    id = info and info.sessionId or opts.id or uuid(),
    claimed = opts.claimed or nil,
    title = info and (info.customTitle or info.summary) or opts.title,
    named = (info and info.customTitle or opts.title) ~= nil,
    messaging = false,
    cwd = info and info.cwd or opts.cwd or vim.fn.getcwd(),
    persisted = info ~= nil,
    busy = false,
    last_active = info and math.floor((info.lastModified or 0) / 1000) or os.time(),
    mode = config.options.permission_mode or modes.settings_default(info and info.cwd or opts.cwd or vim.fn.getcwd()),
    commands = {},
    terminal_commands = {},
    streamed = {},
    shell_count = 0,
    silent_results = 0,
    subagents = {},
    child_parent = {},
    tasks = {},
    notes = {},
    suspending = false,
    in_reply = false,
    reply_has_text = false,
    interrupted = false,
    cost = 0,
    queue = {},
    state_events = false,
  }, Session)
  self.chat = Chat.new({
    id = count,
    title = self.title,
    cwd = self.cwd,
    on_submit = function(text, attachments)
      return self:send(text, attachments)
    end,
    on_interrupt = function()
      self:interrupt()
    end,
    on_send_now = function(text, attachments)
      return self:send_now(text, attachments)
    end,
    on_edit_queue = function()
      return self:edit_queue()
    end,
    session_id = function()
      return self.id
    end,
    on_show = function()
      self.permissions:on_show()
    end,
    on_cycle_mode = function()
      self:set_mode(modes.next(self.mode))
    end,
    commands = function()
      return self:slash_commands()
    end,
    on_rebuild = function(transcript)
      self:on_chat_rebuilt(transcript)
    end,
  })
  self.permissions = Permissions.new(self.chat, function(id, answer)
    if self.sidecar then
      self.sidecar:send({
        type = "permission_response",
        id = id,
        behavior = answer.behavior,
        always = answer.always,
        updated_input = answer.updated_input,
        set_mode = answer.set_mode,
        message = answer.message,
      })
    end
  end, function()
    vim.notify(("Claude needs your input in “%s”"):format(self.title or "New session"), vim.log.levels.WARN)
  end)

  self.held = Held.new(self.chat, function()
    if self:running() then
      self.sidecar:send({ type = "deliver_held" })
    end
  end)

  if info then
    self.chat:set_status({ activity = "Loading" })
    self:load_history()
  else
    self:start()
  end
  return self
end

function Session:running()
  return self.sidecar ~= nil and self.sidecar:running()
end

--- A new session nobody has used: unnamed, never written to disk, nothing
--- in its transcript, and no draft in its prompt. Switching away from one
--- discards it (see sessions.show), so trying "new" costs nothing. A session
--- opened for a `wt` tree it holds isn't one: it was asked for, and has a claim.
function Session:is_placeholder()
  return not self.persisted
    and not self.claimed
    and not self.title
    and not self.pending_title
    and not self.busy
    and not self.shell
    and #self.queue == 0
    and not self:needs_attention()
    and self.chat:valid()
    and self.chat.transcript:empty()
    and self.chat.prompt:text() == ""
end

--- Waiting on the user (a permission card or question).
function Session:needs_attention()
  return self.permissions:pending()
end

--- Start (or restart) the process, resuming the transcript if there is one.
--- Not when its working directory is gone: Claude can't run there, and would
--- fail with an error that doesn't say why. Offers to move the session instead.
---@private
function Session:start()
  if vim.fn.isdirectory(self.cwd) == 0 then
    self.chat:set_status({ activity = nil, stopped = "no_cwd" })
    self:offer_relocate()
    return
  end
  self.suspending = false
  local sidecar
  sidecar = transport.session().new({
    on_event = function(event)
      -- Events can still arrive after the session was closed and its chat wiped.
      if self.sidecar == sidecar and self.chat:valid() then
        self:on_event(event)
      end
    end,
    on_exit = function(code, stderr)
      if self.sidecar ~= sidecar then
        return
      end
      self.sidecar = nil
      self.busy = false
      self.permissions:clear()
      self.held:clear()
      -- Nothing is left to deliver the queue after; give it back rather than lose it.
      self:return_queue()
      self.chat:set_status({ activity = nil, stopped = self.suspending and "suspended" or "ended" })
      self:reload_if_pending()
      if code ~= 0 and not self.suspending then
        vim.notify(("claude-code: sidecar exited with code %d\n%s"):format(code, stderr), vim.log.levels.ERROR)
      end
    end,
  })
  self.sidecar = sidecar
  self.started_mode = self.mode
  self.env = self:environment()
  self.chat:set_status({ activity = self.busy and "Thinking" or "Starting", stopped = false, mode = self.mode })
  sidecar:start({
    type = "init",
    cwd = self.cwd,
    claude_path = config.claude_path() --[[@as string]],
    model = config.options.model,
    -- Keeps the session's current mode across suspend/resume.
    permission_mode = self.mode,
    resume = self.persisted and self.id or nil,
    session_id = not self.persisted and self.id or nil,
    title = not self.persisted and self.title or nil,
    name = self.named and self.title or nil,
    inbound = config.options.messaging.inbound,
    prompt_suggestions = config.options.prompt_suggestions,
    env = self.env,
  })
end

--- Extra environment for the process: with the worktree integration on, the
--- session's `wt` identity and, in a tree, the tree's environment; then the
--- `env` option, which wins over both. Worked out on every start, so a function
--- sees the session as it is now (its cwd may have moved) and a restart after an
--- idle suspend picks up any change.
---@private
---@return table<string, string>?
function Session:environment()
  local out = {}
  if worktree.enabled() then
    local err
    out, err = worktree.session_env(self.id, self.cwd)
    if err then
      vim.notify("claude-code: starting without the worktree's environment: " .. err, vim.log.levels.WARN)
    end
  end
  local env = config.options.env
  if type(env) == "function" then
    local ok, result = pcall(env, { session_id = self.id, cwd = self.cwd, title = self.title })
    if not ok then
      vim.notify("claude-code: `env` failed: " .. tostring(result), vim.log.levels.ERROR)
      env = nil
    else
      env = result
    end
  end
  if type(env) ~= "table" then
    env = {}
  end
  for name, value in pairs(env) do
    if type(name) == "string" and (type(value) == "string" or type(value) == "number") then
      out[name] = tostring(value)
    else
      vim.notify(("claude-code: ignoring `env` entry %s"):format(vim.inspect(name)), vim.log.levels.WARN)
    end
  end
  -- An empty table encodes as a JSON array; leave the field out instead.
  return next(out) and out or nil
end

--- Ask where to move a session whose working directory is gone.
---@private
function Session:offer_relocate()
  if self.relocating then
    return
  end
  self.relocating = true
  local problem = ("“%s” can't start: its working directory %s no longer exists"):format(
    self.title or "New session",
    vim.fn.fnamemodify(self.cwd, ":~")
  )
  local here = vim.uv.cwd()
  local choices = {}
  if here and vim.fn.isdirectory(here) == 1 and here ~= self.cwd then
    table.insert(choices, { label = "Neovim's cwd (" .. vim.fn.fnamemodify(here, ":~") .. ")", dir = here })
  end
  table.insert(choices, { label = "Another directory…" })
  table.insert(choices, { label = "Leave it for now", cancel = true })
  vim.ui.select(choices, {
    prompt = problem .. ". Move it to",
    format_item = function(choice)
      return choice.label
    end,
  }, function(choice)
    if not choice or choice.cancel then
      self.relocating = false
      vim.notify(("claude-code: %s. :Claude relocate <dir> moves it."):format(problem), vim.log.levels.WARN)
      return
    end
    if choice.dir then
      self.relocating = false
      self:relocate(choice.dir)
      return
    end
    local default = (here or vim.env.HOME) .. "/"
    vim.ui.input({ prompt = "Move session to: ", default = default, completion = "dir" }, function(dir)
      self.relocating = false
      if dir and vim.trim(dir) ~= "" then
        self:relocate(dir)
      end
    end)
  end)
end

--- Move the session to another working directory, and start it there if it's
--- showing. A stored session's transcript moves too (relocate_session in the
--- store), so later resumes run there as well. A running session is stopped
--- first: the CLI mustn't be writing the transcript while it moves.
---@param dir string
---@param done? fun(err?: string)
function Session:relocate(dir, done)
  done = done or function() end
  local path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(dir), ":p"))
  local function fail(err)
    vim.notify("claude-code: couldn't relocate the session: " .. err, vim.log.levels.ERROR)
    done(err)
  end
  if vim.fn.isdirectory(path) == 0 then
    return fail("not a directory: " .. dir)
  end
  if self.busy then
    return fail("Claude is working; interrupt it first")
  end
  local function moved(cwd)
    self.cwd = cwd
    self.chat:set_cwd(cwd)
    require("claude-code.events").sessions_changed()
    if self.chat:visible() then
      self:start()
    else
      self.chat:set_status({ stopped = "ended" })
    end
    done()
  end
  local function move()
    if not self.persisted then
      moved(vim.uv.fs_realpath(path) or path)
      return
    end
    control.request("relocate_session", { session_id = self.id, dir = self.cwd, to = path }, function(err, result)
      if err then
        return fail(err)
      end
      moved(result.cwd)
    end)
  end
  if not self:running() then
    move()
    return
  end
  self:stop()
  local deadline = vim.uv.now() + 5000
  local function when_stopped()
    if not self:running() then
      move()
    elseif vim.uv.now() > deadline then
      fail("Claude didn't exit")
    else
      vim.defer_fn(when_stopped, 50)
    end
  end
  when_stopped()
end

--- Make sure the process is running (e.g. after being suspended).
function Session:ensure_running()
  if not self:running() then
    self:start()
  end
end

--- Stop the process while idle; the conversation stays and resumes on demand.
--- Not while messages from other sessions wait on you (they'd be lost), nor once
--- it's been talking to another session: a stopped session can't be messaged.
function Session:suspend()
  local keep = self.busy or self:needs_attention() or self.held:count() > 0 or self.messaging or #self.queue > 0
  if self:running() and not keep then
    self.suspending = true
    self.sidecar:stop()
  end
end

--- End the process (the transcript stays on disk and can be resumed).
function Session:stop()
  if self:running() then
    self.suspending = true
    if self.busy then
      -- Closing stdin alone would let the current turn run to completion first.
      self.sidecar:send({ type = "interrupt" })
    end
    self.sidecar:stop()
  end
end

--- Prompts that end the session, as in the Claude Code CLI.
local EXIT_COMMANDS = { ["/exit"] = true, ["/quit"] = true, ["exit"] = true }

--- Run a `!command` here (not through Claude), as the CLI's bash mode does, and
--- add the command and its output to the conversation in the CLI's format.
---@private
---@param command string
---@return boolean started
function Session:run_shell(command)
  if self.shell then
    local key = require("claude-code.ui.icons").key(config.options.keymaps.interrupt or "<C-c>")
    vim.notify(("claude-code: a shell command is already running (%s stops it)"):format(key), vim.log.levels.WARN)
    return false
  end
  if vim.fn.isdirectory(self.cwd) == 0 then
    self:start() -- explains, and offers to move it
    return false
  end
  local transcript = self.chat.transcript
  self.shell_count = self.shell_count + 1
  local id = "shell-" .. self.shell_count
  transcript:start_turn("user")
  transcript:tool_use(id, "Shell", { command = command })
  self.in_reply, self.reply_has_text = false, false
  self.last_active = os.time()

  local shell = { id = id, killed = false }
  self.shell = shell
  if not self.busy then
    self.chat:set_status({ activity = "Running !" .. command:gsub("\n.*", " …") })
  end
  -- The same environment Claude's own commands get. Worked out afresh when the
  -- process isn't running (suspended, or never started), rather than reusing
  -- what it last started with.
  local env = self:running() and self.env or self:environment()
  local opts = { cwd = self.cwd, text = true, env = env }
  shell.job = vim.system({ vim.o.shell, vim.o.shellcmdflag, command }, opts, function(result)
    vim.schedule(function()
      self:finish_shell(command, shell, result)
    end)
  end)
  return true
end

---@private
---@param command string
---@param shell { id: string, killed: boolean }
---@param result vim.SystemCompleted
function Session:finish_shell(command, shell, result)
  if self.shell == shell then
    self.shell = nil
  end
  if not self.chat:valid() then
    return
  end
  local stdout = vim.trim(result.stdout or "")
  local stderr = vim.trim(result.stderr or "")
  if shell.killed then
    stderr = vim.trim(stderr .. "\nCommand interrupted")
  elseif result.code ~= 0 and stderr == "" then
    stderr = ("Exit code %d"):format(result.code)
  end
  local shown = vim.trim(stdout .. (stderr ~= "" and ("\n" .. stderr) or ""))
  self.chat.transcript:tool_result(shell.id, (shell.killed or result.code ~= 0) and "error" or "success", shown)
  -- It may have been a `wt` command that created or removed a tree.
  local worktree = require("claude-code.worktree")
  if worktree.enabled() then
    worktree.invalidate()
  end

  local max = config.options.shell.max_output
  local function cap(text)
    if #text > max then
      return text:sub(1, max) .. ("\n… (%d more characters)"):format(#text - max)
    end
    return text
  end
  -- Claude responds once it exits (as in the CLI), unless you stopped it or Claude
  -- is mid-turn; then it's just context for the next turn.
  local respond = config.options.shell.respond and not shell.killed and not self.busy
  self:ensure_running()
  if not self:running() then
    -- Couldn't start. Usually its directory is gone (often this very command removed it),
    -- and start() has offered to move the session; the process can also fail to spawn
    -- (e.g. a bad `claude` path with the direct transport). The output is above, so drop
    -- the message rather than hold it. The queue goes back to the prompt, as when the
    -- process exits, so nothing restarts it (and asks again) behind the user's back.
    if vim.fn.isdirectory(self.cwd) == 0 then
      self:note("Not sent to Claude: the session's working directory no longer exists.")
    else
      self:note("Not sent to Claude: the session couldn't start.")
    end
    self:return_queue()
    return
  end
  -- The CLI's tags, in one message: Claude Code treats a message that starts with
  -- <bash-stdout> as local output and never queries the model for it.
  self.sidecar:send({
    type = "prompt",
    text = ("<bash-input>%s</bash-input><bash-stdout>%s</bash-stdout><bash-stderr>%s</bash-stderr>"):format(
      command,
      stdout == "" and stderr == "" and "(Bash completed with no output)" or cap(stdout),
      cap(stderr)
    ),
    should_query = respond,
  })
  if not respond then
    -- A context-only message still produces a (turnless) result; don't treat it as a turn ending.
    self.silent_results = self.silent_results + 1
  end
  if respond then
    self.busy = true
    self.interrupted = false
    self.chat:set_status({ activity = "Thinking" })
  elseif not self.busy then
    self.chat:set_status({ activity = nil })
    if not self.state_events then
      -- Otherwise the context-only message's idle (see settle) sends it, after that message.
      self:flush_queue()
    end
  end
end

--- Prepare a prompt's images for sending. A failure (e.g. too large to shrink)
--- is reported, and the prompt should stay as it is.
---@param text string
---@param attachments? { label: string, image: claude_code.Image }[]
---@return claude_code.QueuedMessage?
local function prepare(text, attachments)
  local payload, shown = {}, {}
  for _, a in ipairs(attachments or {}) do
    local image, sent, err = require("claude-code.images").attachment(a.image)
    if not image then
      vim.notify(("claude-code: %s: %s"):format(a.label, err), vim.log.levels.ERROR)
      return nil
    end
    table.insert(payload, image)
    table.insert(shown, { label = a.label, image = a.image, sent = sent })
  end
  return { text = text, attachments = attachments or {}, payload = payload, shown = shown }
end

--- Send a prompt now, or queue it while Claude (or a `!command`) is working.
---@param text string
---@param attachments? { label: string, image: claude_code.Image }[] Images to send with it.
---@return boolean sent Sent or queued: the prompt can be cleared.
function Session:send(text, attachments)
  local command = text:match("^!%s*(.-)%s*$")
  if command and command ~= "" then
    return self:run_shell(command)
  end
  if EXIT_COMMANDS[vim.trim(text)] then
    vim.notify(("claude-code: ended “%s”; resume it from :Claude sessions"):format(self.title or "New session"))
    require("claude-code.sessions").exit(self)
    -- Not "sent": the chat's buffers are gone, so there's no prompt to clear.
    return false
  end
  local message = prepare(text, attachments)
  if not message then
    return false
  end
  if self.busy or self.shell then
    -- Delivered when the turn ends; editable until then.
    self:enqueue(message)
    return true
  elseif #self.queue > 0 then
    -- Something is still queued: this goes out with it, after it.
    self:enqueue(message)
    self:flush_queue()
    return true
  end
  return self:dispatch(message)
end

--- Send a prepared prompt to Claude, starting a turn.
---@private
---@param message claude_code.QueuedMessage
---@return boolean sent
function Session:dispatch(message)
  self:ensure_running()
  if not self:running() then
    return false -- couldn't start (its directory is gone); keep the prompt
  end
  self.last_active = os.time()
  self.chat.prompt:suggest(nil)
  self.chat.transcript:user_message(message.text, message.shown)
  self.busy = true
  self.in_reply = false
  self.reply_has_text = false
  self.interrupted = false
  self.chat:set_status({ activity = "Thinking" })
  local payload = #message.payload > 0 and message.payload or nil
  self.sidecar:send({ type = "prompt", text = message.text, images = payload })
  return true
end

---@private
---@param message claude_code.QueuedMessage
function Session:enqueue(message)
  table.insert(self.queue, message)
  self.last_active = os.time()
  self.chat:set_queue(self.queue)
end

--- Send everything queued as one prompt, as the CLI does, once nothing is in the way.
---@private
function Session:flush_queue()
  if #self.queue == 0 or self.busy or self.shell or self:needs_attention() then
    return
  end
  local texts = {}
  local message = { attachments = {}, payload = {}, shown = {} }
  for _, m in ipairs(self.queue) do
    table.insert(texts, m.text)
    vim.list_extend(message.attachments, m.attachments)
    vim.list_extend(message.payload, m.payload)
    vim.list_extend(message.shown, m.shown)
  end
  message.text = table.concat(texts, "\n\n")
  local queue = self.queue
  self.queue = {}
  self.chat:set_queue(self.queue)
  if not self:dispatch(message) then
    -- Couldn't start (its directory is gone): back to the prompt, rather than stuck.
    self.chat:restore_queue(queue)
  end
end

--- Put the queued prompts back in the prompt (ahead of what's there), to edit or drop.
---@private
---@return boolean returned Anything was queued.
function Session:return_queue()
  if #self.queue == 0 then
    return false
  end
  local queue = self.queue
  self.queue = {}
  self.chat:set_queue(self.queue)
  self.chat:restore_queue(queue)
  return true
end

--- Pull the queue back into the prompt for editing (<Up>, as in the CLI).
---@return boolean pulled
function Session:edit_queue()
  return self:return_queue()
end

--- Interrupt Claude and send the queue (plus `text`, if given) right away.
---@param text? string The prompt's text, sent along with the queue.
---@param attachments? { label: string, image: claude_code.Image }[]
---@return boolean sent The prompt was taken (sent or queued), so it can be cleared.
function Session:send_now(text, attachments)
  if text and text ~= "" then
    if text:match("^!") or EXIT_COMMANDS[vim.trim(text)] then
      -- Not something to queue; handle it as an ordinary send.
      return self:send(text, attachments)
    end
    local message = prepare(text, attachments)
    if not message then
      return false
    end
    self:enqueue(message)
  end
  if #self.queue == 0 then
    vim.notify("claude-code: nothing to send", vim.log.levels.INFO)
    return false
  end
  if self.shell then
    -- finish_shell sends the queue once the command is gone (unless Claude is busy too).
    self:kill_shell()
  end
  if self.busy and self:running() then
    -- settle (or finish_turn) sends the queue once the interrupted turn ends.
    self:interrupt_turn()
  else
    self:flush_queue()
  end
  return true
end

---@private
function Session:kill_shell()
  self.shell.killed = true
  self.shell.job:kill("sigterm")
end

---@private
function Session:interrupt_turn()
  if self.busy and self:running() then
    self.interrupted = true
    self.chat:set_status({ activity = "Interrupting" })
    self.sidecar:send({ type = "interrupt" })
  end
end

--- Stop what you're waiting on: a running `!command` first, else Claude's turn.
--- Anything queued goes back to the prompt rather than out without you.
function Session:interrupt()
  self:return_queue()
  if self.shell then
    self:kill_shell()
    return
  end
  self:interrupt_turn()
end

--- Handled by the plugin itself rather than Claude Code.
local LOCAL_COMMANDS = {
  { name = "exit", description = "End this session (it stays saved; resume it from :Claude sessions)", builtin = true },
  { name = "quit", description = "End this session", builtin = true },
}

--- Slash commands to offer: the SDK's, minus ones tied to the CLI's terminal UI,
--- plus the plugin's own.
---@return claude_code.SlashCommand[]
function Session:slash_commands()
  local out, seen = {}, {}
  for _, c in ipairs(LOCAL_COMMANDS) do
    table.insert(out, c)
    seen[c.name] = true
  end
  for _, c in ipairs(self.commands) do
    if not seen[c.name] and not self.terminal_commands[c.name] then
      table.insert(out, c)
      seen[c.name] = true
    end
  end
  return out
end

--- Switch permission mode (takes effect immediately if running, else on start).
---@param mode claude_code.PermissionMode
function Session:set_mode(mode)
  if not modes.valid(mode) then
    vim.notify("claude-code: unknown permission mode: " .. tostring(mode), vim.log.levels.ERROR)
    return
  end
  if mode == "bypassPermissions" and self:running() and self.started_mode ~= "bypassPermissions" then
    -- The SDK only allows it for sessions started in it (a deliberate safety check).
    vim.notify(
      "claude-code: bypassPermissions has to be the starting mode; set `permission_mode` in setup()",
      vim.log.levels.ERROR
    )
    return
  end
  self.mode = mode
  self.chat:set_status({ activity = self.chat:activity(), mode = mode })
  if self:running() then
    self.sidecar:send({ type = "set_permission_mode", mode = mode })
  end
end

---@param title string
function Session:rename(title)
  self.title = title
  self.named = true
  self.chat:set_title(title)
  if not self.persisted then
    -- No transcript to write the title to yet; apply it after the first turn.
    self.pending_title = title
    return
  end
  if self:running() then
    -- Through the process itself, as the CLI's /rename does: it records the title and
    -- also renames the session for messaging, so other sessions reach it by the new name.
    self.sidecar:send({ type = "rename", title = title })
    return
  end
  -- Not running: record the title; it becomes the session's name (--name) when it starts.
  control.request("rename_session", { session_id = self.id, title = title, dir = self.cwd }, function(err)
    if err then
      vim.notify("claude-code: rename failed: " .. err, vim.log.levels.ERROR)
    end
  end)
end

---@private
function Session:reply()
  if not self.in_reply then
    self.chat.transcript:start_turn("assistant")
    self.in_reply = true
  end
end

--- Set the activity unless a permission card is waiting on the user.
---@private
---@param activity string
function Session:activity(activity)
  if not self.permissions:pending() then
    self.chat:set_status({ activity = activity })
  end
end

---@private
---@param event claude_code.SidecarEvent
function Session:on_event(event)
  self.last_active = os.time()
  if event.type == "ready" then
    if not self.busy then
      self.chat:set_status({ activity = nil })
    end
  elseif event.type == "commands" then
    self.commands = event.commands or {}
  elseif event.type == "sdk" then
    self:on_sdk_message(event.message --[[@as table]])
  elseif event.type == "permission_request" then
    local parent = self.child_parent[event.tool_use_id]
    if parent then
      -- A subagent is asking: show the card under its Agent call, and say who's asking.
      local sub = self.subagents[parent]
      event.anchor = parent
      event.subagent = sub and (sub.description or sub.kind) or "subagent"
    end
    self.permissions:request(event --[[@as claude_code.PermissionRequest]])
  elseif event.type == "permission_cancel" then
    self.permissions:cancel(event.id --[[@as integer]])
  elseif event.type == "error" then
    vim.notify("claude-code: " .. tostring(event.message), vim.log.levels.ERROR)
  end
end

---@private
---@param msg table An SDKMessage from @anthropic-ai/claude-agent-sdk.
function Session:on_sdk_message(msg)
  -- A subagent's own messages: gathered under its Agent call rather than shown inline.
  if msg.parent_tool_use_id then
    self:on_subagent_message(msg)
    return
  end
  local transcript = self.chat.transcript
  if msg.type == "system" and self:on_task_event(msg) then
    return
  end
  if msg.type == "system" and msg.subtype == "session_state_changed" then
    -- Claude Code's own account of whether a turn is running, whatever started it.
    self.state_events = true
    if msg.state == "running" then
      self:begin_turn()
    elseif msg.state == "idle" then
      self:settle()
    end
    return
  elseif msg.type == "command_lifecycle" then
    -- A queued message (e.g. from another session) starting; for CLIs without the above.
    if msg.state == "started" then
      self:begin_turn()
    end
    return
  elseif msg.type == "system" and msg.subtype == "peer_message_hold" then
    self:on_peer_hold(msg)
    return
  elseif msg.type == "system" and msg.subtype == "informational" then
    self:on_informational(msg)
    return
  end
  if not self.busy and (msg.type == "stream_event" or msg.type == "assistant") then
    -- Claude is answering something we didn't send, and Claude Code didn't pass through
    -- idle first (e.g. a delivery notice queued behind the last turn): it's a new turn.
    self:begin_turn()
  end

  if msg.type == "system" and (msg.subtype == "init" or msg.subtype == "status") and msg.permissionMode then
    -- Claude Code reports the mode each turn, and when it changes (e.g. leaving plan mode).
    self.mode = msg.permissionMode
    self.chat:set_status({ activity = self.chat:activity(), mode = self.mode })
  end
  if msg.type == "system" and msg.subtype == "commands_changed" then
    self.commands = msg.commands or self.commands
  end
  if msg.type == "system" and msg.subtype == "init" then
    self.terminal_commands = {}
    for _, name in ipairs(msg.terminal_slash_commands or {}) do
      self.terminal_commands[(name:gsub("^/", ""))] = true
    end
    self.chat:set_status({ activity = self.busy and "Thinking" or nil, model = msg.model })
  elseif msg.type == "stream_event" then
    local ev = msg.event
    if ev.type == "message_start" and ev.message and ev.message.id then
      self.streamed[ev.message.id] = true
    end
    if ev.type == "content_block_start" then
      local block = ev.content_block
      if block.type == "text" then
        self:reply()
        if self.reply_has_text then
          transcript:paragraph_break()
        end
        self:activity("Responding")
      elseif block.type == "thinking" then
        self:activity("Thinking")
      elseif block.type == "tool_use" then
        self:activity("Preparing " .. block.name)
      end
    elseif ev.type == "content_block_delta" and ev.delta.type == "text_delta" then
      self:reply()
      transcript:append(ev.delta.text)
      self.reply_has_text = true
    end
  elseif msg.type == "assistant" then
    -- Text normally streamed in via stream_event already; the full message is where
    -- tool calls are complete. Messages that weren't streamed (e.g. output of a
    -- built-in slash command like /context) carry their text only here.
    local streamed = msg.message.id and self.streamed[msg.message.id]
    for _, block in ipairs(msg.message.content or {}) do
      if block.type == "text" and not streamed and vim.trim(block.text or "") ~= "" then
        self:reply()
        if self.reply_has_text then
          transcript:paragraph_break()
        end
        transcript:append(block.text)
        self.reply_has_text = true
      elseif block.type == "tool_use" then
        self:reply()
        transcript:tool_use(block.id, block.name, block.input or {})
        self:activity("Running " .. block.name)
        if block.name == "SendMessage" then
          self.messaging = true
        end
      end
    end
  elseif msg.type == "user" and msg.isReplay then
    -- User messages echoed back (--replay-user-messages). Ours are shown already;
    -- one from another session arrives only this way.
    local peer = replayed_peer_message(msg)
    if peer then
      self:peer_message(msg.uuid or tostring(vim.uv.hrtime()), peer)
    end
  elseif msg.type == "user" then
    self:tool_results(msg.message and msg.message.content, msg.tool_use_result)
  elseif msg.type == "prompt_suggestion" then
    -- A predicted next prompt, after the turn; shown until you type or send.
    if not self.busy then
      self.chat.prompt:suggest(msg.suggestion)
      self.chat:refresh_status()
    end
  elseif msg.type == "result" then
    if (msg.num_turns or 0) == 0 and self.silent_results > 0 then
      self.silent_results = self.silent_results - 1
    else
      self:finish_turn(msg)
    end
  end
end

---@private
---@param content any user message content
---@param structured? table The message's tool_use_result (the tool's own output object).
function Session:tool_results(content, structured)
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "tool_result" then
      local sub = self.subagents[block.tool_use_id]
      if type(structured) == "table" and (structured.isAsync or structured.status == "async_launched") then
        -- A background agent: the call returns at once but the agent keeps going.
        self.chat.transcript:tool_background(block.tool_use_id)
      else
        local text = tools.result_text(block.content)
        if sub then
          sub.status = block.is_error and "failed" or "completed"
          text = self:subagent_report(sub, text, structured)
        end
        self.chat.transcript:tool_result(block.tool_use_id, block.is_error == true and "error" or "success", text)
      end
      self:activity("Thinking")
    end
  end
end

--- The subagent behind an Agent/Task call, created on first sight.
---@private
---@param id string tool_use id of the Agent call
---@return claude_code.Subagent
function Session:subagent(id)
  local sub = self.subagents[id]
  if not sub then
    sub = { status = "running", started = os.time(), tools = {}, index = {} }
    self.subagents[id] = sub
  end
  return sub
end

--- A finished subagent's report: the Agent call's result text without the parts
--- addressed to Claude (the hand-back preamble, agent id and usage trailer). Totals
--- come from the tool's structured output.
---@private
---@param sub claude_code.Subagent
---@param text string The Agent call's result text.
---@param structured? table AgentOutput
---@return string
function Session:subagent_report(sub, text, structured)
  if type(structured) == "table" and structured.totalToolUseCount then
    sub.usage = {
      tool_uses = structured.totalToolUseCount,
      duration_ms = structured.totalDurationMs,
      total_tokens = structured.totalTokens,
    }
  end
  local report = text
    :gsub("^%s*%[Subagent hand%-back%][^\n]*\n", "")
    :gsub("%s*<usage>.-</usage>%s*$", "")
    :gsub("%s*agentId: [^\n]*%s*$", "")
  return vim.trim(report)
end

--- Internal plumbing a subagent uses to return; not worth listing.
local HIDDEN_SUBAGENT_TOOLS = { SubagentHandback = true }

--- A message from inside a subagent: its tool calls, their results, its report.
---@private
---@param msg table
function Session:on_subagent_message(msg)
  local parent = msg.parent_tool_use_id
  local sub = self:subagent(parent)
  local content = type(msg.message) == "table" and msg.message.content
  if msg.type == "assistant" and type(content) == "table" then
    for _, block in ipairs(content) do
      if block.type == "tool_use" and not HIDDEN_SUBAGENT_TOOLS[block.name] then
        table.insert(sub.tools, { id = block.id, name = block.name, input = block.input or {}, status = "pending" })
        sub.index[block.id] = #sub.tools
        self.child_parent[block.id] = parent
      elseif block.type == "text" and vim.trim(block.text or "") ~= "" then
        sub.report = block.text
      end
    end
  elseif msg.type == "user" and type(content) == "table" then
    for _, block in ipairs(content) do
      local i = block.type == "tool_result" and sub.index[block.tool_use_id]
      if i then
        sub.tools[i].status = block.is_error and "error" or "success"
      end
    end
  else
    return
  end
  self.chat.transcript:subagent(parent, sub)
end

--- The SDK's task events (subagents' progress, background agents finishing).
---@private
---@param msg table system message
---@return boolean handled
function Session:on_task_event(msg)
  local transcript = self.chat.transcript
  local id = msg.tool_use_id or (msg.task_id and self.tasks[msg.task_id])
  if msg.subtype == "task_started" and msg.tool_use_id then
    self.tasks[msg.task_id] = msg.tool_use_id
    local sub = self:subagent(msg.tool_use_id)
    sub.description, sub.kind = msg.description, msg.subagent_type
    sub.background = msg.is_backgrounded or sub.background
    transcript:subagent(msg.tool_use_id, sub)
  elseif msg.subtype == "task_progress" and id then
    local sub = self:subagent(id)
    sub.activity = msg.description ~= sub.description and msg.description or sub.activity
    sub.usage = msg.usage or sub.usage
    transcript:subagent(id, sub)
  elseif msg.subtype == "task_notification" and id then
    local sub = self:subagent(id)
    sub.status = msg.status or "completed"
    sub.usage = msg.usage or sub.usage
    if sub.background then
      -- Its call returned long ago; finish its line now, and say so where you're reading.
      transcript:tool_result(id, sub.status == "completed" and "success" or (sub.status == "failed" and "error" or "cancelled"), sub.report or msg.summary)
      local label = sub.description or sub.kind or "Background agent"
      self:note(("%s Background agent “%s” %s"):format(require("claude-code.ui.icons").tool("Agent"), label, sub.status))
    end
  elseif msg.subtype == "background_tasks_changed" then
    local running = #vim.tbl_filter(function(t)
      return not t.ambient
    end, msg.tasks or {})
    self.chat:set_status({ activity = self.chat:activity(), background = running })
  elseif msg.subtype ~= "task_updated" then
    return false
  end
  return true
end

--- A note in the transcript; held until the current turn ends so it doesn't split a reply.
---@private
---@param text string
function Session:note(text)
  if self.busy then
    table.insert(self.notes, text)
  else
    self.chat.transcript:note(text)
  end
end

--- A turn we didn't start (a message from another session, a background task
--- finishing): track it like one of ours, so the status shows it and it can be
--- interrupted. A no-op for our own turns, which are already busy.
---@private
function Session:begin_turn()
  if self.busy then
    return
  end
  self.busy = true
  self.in_reply = false
  self.reply_has_text = false
  self.interrupted = false
  self.last_active = os.time()
  self.chat.prompt:suggest(nil)
  self.chat:set_status({ activity = "Thinking" })
end

--- Claude Code went idle: nothing running or queued. A turn's result normally ended
--- it already; this ends the ones that don't produce a result we count (a context-only
--- message still reports "running" first). Either way, it's when the queue goes out:
--- sent any earlier (on the result), this idle would arrive after it and end its turn.
---@private
function Session:settle()
  if self.busy then
    self.busy = false
    self.interrupted = false
    for _, note in ipairs(self.notes) do
      self.chat.transcript:note(note)
    end
    self.notes = {}
    self.chat:set_status({ activity = nil })
    self:reload_if_pending()
  end
  self:flush_queue()
end

--- A message from another session reached Claude.
---@private
---@param id string
---@param peer claude_code.PeerMessage
function Session:peer_message(id, peer)
  self.messaging = true
  self.chat.transcript:peer_message(id, peer.from, peer.body)
  -- Claude's answer gets its own header below it.
  self.in_reply, self.reply_has_text = false, false
  if not self.chat:visible() then
    local preview = peer.body:gsub("\n.*", " …")
    local title = self.title or "New session"
    vim.notify(("claude-code: “%s” got a message from %s: %s"):format(title, peer.from, preview))
  end
end

--- A message from another session was held back, then released or dropped.
---@private
---@param msg table system/peer_message_hold
function Session:on_peer_hold(msg)
  local id = msg.message_uuid
  if not id then
    return
  end
  local from = msg.from_name or (msg.from ~= "" and msg.from) or "another session"
  if msg.state == "held" then
    self.held:add({ uuid = id, from = from, cause = msg.cause })
    if not self.chat:visible() then
      vim.notify(
        ("claude-code: a message from %s is waiting in “%s”"):format(from, self.title or "New session"),
        vim.log.levels.WARN
      )
    end
    return
  end
  local held = self.held:remove(id)
  if msg.state == "dropped" and held then
    local icon = require("claude-code.ui.icons").get().message
    self:note(("%s Message from %s %s"):format(icon, from, DROPPED[msg.outcome] or "was dropped"))
  end
end

--- Claude Code's notices. Shown: how messages this session sent fared (held for the
--- recipient's approval, released, refused, the recipient going idle).
---@private
---@param msg table system/informational
function Session:on_informational(msg)
  local text = type(msg.content) == "string" and msg.content or ""
  if not text:lower():find("cross%-session") then
    return
  end
  -- The recipient is a socket path; the text around it is what matters.
  local body = vim.trim((text:gsub("^%b[]%s*", ""):gsub("%s*%(recipient: [^)]*%)", "")))
  if text:match("^%[") then
    -- Worded for Claude ("[Cross-session delivery notice] … Do not wait for a reply"):
    -- the first sentence says what happened.
    body = body:match("^(.-%.)%s") or body
  end
  self:note(("%s %s"):format(require("claude-code.ui.icons").get().message, body))
end

--- Deliver the messages from other sessions that are being held for you.
function Session:deliver_held()
  self.held:deliver()
end

---@private
---@param msg table SDKResultMessage
function Session:finish_turn(msg)
  local transcript = self.chat.transcript
  transcript:cancel_pending_tools()

  local turn_cost = math.max((msg.total_cost_usd or self.cost) - self.cost, 0)
  self.cost = msg.total_cost_usd or self.cost
  local parts = {}
  local hl
  if self.interrupted then
    table.insert(parts, "Interrupted")
  elseif msg.subtype ~= "success" or msg.is_error then
    table.insert(parts, "Error: " .. (msg.subtype == "success" and tostring(msg.result) or msg.subtype))
    hl = "ClaudeCodeError"
  end
  table.insert(parts, ("%.1fs"):format((msg.duration_ms or 0) / 1000))
  if turn_cost > 0 then
    table.insert(parts, ("$%.4f"):format(turn_cost))
  end
  transcript:footer(table.concat(parts, " · "), hl)
  for _, note in ipairs(self.notes) do
    transcript:note(note)
  end
  self.notes = {}

  self.busy = false
  self.interrupted = false
  self.chat:set_status({ activity = nil, cost = self.cost })
  self:reload_if_pending()
  if not self.state_events then
    -- A CLI without session_state_changed: the result is all there is to go on.
    self:flush_queue()
  end

  if not self.persisted then
    -- The transcript exists now: apply a rename made before the first turn, and
    -- pick up Claude Code's title if the session wasn't named.
    self.persisted = true
    if self.pending_title then
      local title = self.pending_title
      self.pending_title = nil
      self:rename(title)
    elseif not self.title then
      control.request("get_session_info", { session_id = self.id, dir = self.cwd }, function(_, session)
        if session and not self.title then
          self.title = session.customTitle or session.summary
          self.chat:set_title(self.title)
        end
      end)
    end
  end
end

-- Resuming ---------------------------------------------------------------------

--- User text that Claude Code records but doesn't show as something you typed.
---@param text string
local function hidden_user_text(text)
  return text:match("^%s*<[%w_-]+>") ~= nil -- <command-name>, <local-command-stdout>, <system-reminder>, ...
    or text:match("^Caveat: The messages below") ~= nil
end

--- The chat's buffers were deleted (`:bdelete`) and replaced with new ones: put
--- back what they showed.
---@private
---@param transcript boolean The transcript is new and empty.
function Session:on_chat_rebuilt(transcript)
  if transcript then
    if self.busy then
      -- Replaying now would tangle with the turn still streaming in.
      self.reload_pending = true
      self.chat.transcript:note("The chat buffer was deleted; the conversation reloads when this turn ends")
    elseif self.persisted then
      self:load_history({ reload = true })
    end
  end
  self.permissions:redraw()
  self.held:render()
end

--- Reload a conversation whose transcript was replaced mid-turn, now the turn is over.
---@private
function Session:reload_if_pending()
  if self.reload_pending and not self.busy then
    self.reload_pending = false
    self.chat.transcript:reset()
    if self.persisted then
      self:load_history({ reload = true })
    end
  end
end

--- Load the stored conversation into the transcript. The process starts when
--- the session is shown (or on send).
---@private
---@param opts? { reload?: boolean } Refilling a replaced transcript, not resuming.
function Session:load_history(opts)
  local reload = opts and opts.reload
  control.request("get_messages", { session_id = self.id, dir = self.cwd, tail = REPLAY_LIMIT }, function(err, result)
    if err or not result then
      vim.notify("claude-code: couldn't load session: " .. tostring(err), vim.log.levels.ERROR)
      self.chat:set_status({ activity = nil, stopped = "suspended" })
      return
    end
    local messages = require("claude-code.peer_history").merge(self.id, self.cwd, result.messages or {})
    self.chat.transcript:batch(function()
      self:replay(messages, result.total or 0, reload)
    end)
    if reload then
      self.held:render()
    end
    if self:running() or self.chat.status.stopped == "no_cwd" then
      self.chat:set_status({ activity = nil })
    else
      self.chat:set_status({ activity = nil, stopped = "suspended" })
    end
  end)
end

---@private
---@param messages table[] SessionMessage[]
---@param total integer
---@param reload? boolean
function Session:replay(messages, total, reload)
  local transcript = self.chat.transcript
  if total > #messages then
    transcript:note(("%d earlier messages not shown"):format(total - #messages))
  end
  for _, m in ipairs(messages) do
    local content = type(m.message) == "table" and m.message.content
    if m.type == "peer" then
      -- From another session (see peer_history.lua).
      transcript:peer_message(m.uuid, m.from, m.body)
      self.in_reply, self.reply_has_text = false, false
    elseif m.parent_tool_use_id then
      self:on_subagent_message(m)
    elseif m.type == "user" then
      local texts = {}
      if type(content) == "string" then
        texts = { content }
      elseif type(content) == "table" then
        for _, block in ipairs(content) do
          if block.type == "text" then
            table.insert(texts, block.text)
          end
        end
        -- Images: our placeholders are in the text already; otherwise mark them.
        local placeholders = select(2, table.concat(texts, "\n"):gsub("%[Image #%d+%]", ""))
        local count = #vim.tbl_filter(function(b)
          return b.type == "image"
        end, content)
        for _ = placeholders + 1, count do
          table.insert(texts, "[image]")
        end
      end
      local text = vim.trim(table.concat(texts, "\n"))
      -- `!commands`: the CLI stores input and output as two messages; we send one.
      local bash_input = text:match("^<bash%-input>(.-)</bash%-input>")
      local bash_stdout = text:match("<bash%-stdout>(.-)</bash%-stdout>")
      if bash_input then
        -- A `!command` (from here or the CLI).
        self.shell_count = self.shell_count + 1
        self.replay_shell = "shell-" .. self.shell_count
        transcript:start_turn("user")
        transcript:tool_use(self.replay_shell, "Shell", { command = bash_input })
        self.in_reply, self.reply_has_text = false, false
      end
      if bash_input and not bash_stdout then
        -- output follows in the next message
      elseif bash_stdout and self.replay_shell then
        local stderr = text:match("<bash%-stderr>(.-)</bash%-stderr>") or ""
        local out = vim.trim(bash_stdout:gsub("^%(Bash completed with no output%)$", "") .. "\n" .. stderr)
        transcript:tool_result(self.replay_shell, stderr ~= "" and "error" or "success", out)
        self.replay_shell = nil
      elseif bash_input then
        -- handled above
      elseif text:match("^%[Request interrupted by user") then
        transcript:footer("Interrupted")
      elseif parse_peer_message(text) then
        local peer = parse_peer_message(text) --[[@as claude_code.PeerMessage]]
        transcript:peer_message(m.uuid or ("replayed-" .. tostring(vim.uv.hrtime())), peer.from, peer.body)
        self.in_reply, self.reply_has_text = false, false
      elseif text ~= "" and not hidden_user_text(text) then
        transcript:user_message(text)
        self.in_reply, self.reply_has_text = false, false
      end
      self:tool_results(content)
    elseif m.type == "assistant" and type(content) == "table" then
      for _, block in ipairs(content) do
        if block.type == "text" and block.text ~= "" then
          self:reply()
          if self.reply_has_text then
            transcript:paragraph_break()
          end
          transcript:append(block.text)
          self.reply_has_text = true
        elseif block.type == "tool_use" then
          self:reply()
          transcript:tool_use(block.id, block.name, block.input or {})
        end
      end
    end
  end
  transcript:cancel_pending_tools()
  self.in_reply, self.reply_has_text = false, false
  if not reload then
    transcript:note(("↻ Resumed · last active %s"):format(os.date("%b %d %H:%M", self.last_active)))
  end
end

return Session
