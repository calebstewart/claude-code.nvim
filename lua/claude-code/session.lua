-- A Session is one Claude conversation: its chat sidebar (which outlives the
-- process) and, while it's running, a sidecar process. A session that isn't
-- running — suspended while idle, exited, or opened from disk — is resumed
-- automatically when it's needed.

local Chat = require("claude-code.ui.chat")
local Permissions = require("claude-code.ui.permission")
local Sidecar = require("claude-code.sidecar")
local config = require("claude-code.config")
local control = require("claude-code.control")
local modes = require("claude-code.modes")
local tools = require("claude-code.ui.tools")

---@class claude_code.Session
---@field id string Claude session id (chosen up front for new sessions).
---@field title? string Custom title, or Claude Code's summary.
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
---@field private silent_results integer Results still to come from context-only messages (they have no turn to finish).
---@field private persisted boolean Its transcript exists on disk (so it can be resumed).
---@field private sidecar? claude_code.Sidecar
---@field private permissions claude_code.Permissions
---@field private suspending boolean
---@field private pending_title? string Rename to apply once the transcript exists.
---@field private in_reply boolean The current turn already has a "Claude" header.
---@field private reply_has_text boolean
---@field private interrupted boolean
---@field private cost number Cumulative session cost reported by the last result.
local Session = {}
Session.__index = Session

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

---@class claude_code.SessionOpts
---@field title? string Name for a new session.
---@field info? table SDKSessionInfo of a stored session to resume.

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
    id = info and info.sessionId or uuid(),
    title = info and (info.customTitle or info.summary) or opts.title,
    cwd = info and info.cwd or vim.fn.getcwd(),
    persisted = info ~= nil,
    busy = false,
    last_active = info and math.floor((info.lastModified or 0) / 1000) or os.time(),
    mode = config.options.permission_mode or modes.settings_default(info and info.cwd or vim.fn.getcwd()),
    commands = {},
    terminal_commands = {},
    streamed = {},
    shell_count = 0,
    silent_results = 0,
    suspending = false,
    in_reply = false,
    reply_has_text = false,
    interrupted = false,
    cost = 0,
  }, Session)
  self.chat = Chat.new({
    id = count,
    title = self.title,
    on_submit = function(text, attachments)
      return self:send(text, attachments)
    end,
    on_interrupt = function()
      self:interrupt()
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

--- Waiting on the user (a permission card or question).
function Session:needs_attention()
  return self.permissions:pending()
end

--- Start (or restart) the process, resuming the transcript if there is one.
---@private
function Session:start()
  self.suspending = false
  local sidecar
  sidecar = Sidecar.new({
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
      self.chat:set_status({ activity = nil, stopped = self.suspending and "suspended" or "ended" })
      if code ~= 0 and not self.suspending then
        vim.notify(("claude-code: sidecar exited with code %d\n%s"):format(code, stderr), vim.log.levels.ERROR)
      end
    end,
  })
  self.sidecar = sidecar
  self.started_mode = self.mode
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
  })
end

--- Make sure the process is running (e.g. after being suspended).
function Session:ensure_running()
  if not self:running() then
    self:start()
  end
end

--- Stop the process while idle; the conversation stays and resumes on demand.
function Session:suspend()
  if self:running() and not self.busy and not self:needs_attention() then
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
  shell.job = vim.system({ vim.o.shell, vim.o.shellcmdflag, command }, { cwd = self.cwd, text = true }, function(result)
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
  end
end

---@param text string
---@param attachments? { label: string, image: claude_code.Image }[] Images to send with it.
---@return boolean sent
function Session:send(text, attachments)
  local command = text:match("^!%s*(.-)%s*$")
  if command and command ~= "" then
    return self:run_shell(command)
  end
  if EXIT_COMMANDS[vim.trim(text)] then
    require("claude-code.sessions").close(self)
    vim.notify(("claude-code: ended “%s”; resume it from :Claude sessions"):format(self.title or "New session"))
    -- Not "sent": the chat's buffers are gone, so there's no prompt to clear.
    return false
  end
  if self.busy then
    vim.notify("claude-code: Claude is still working; interrupt it first", vim.log.levels.WARN)
    return false
  end
  if self.shell then
    vim.notify("claude-code: wait for the shell command to finish (or stop it)", vim.log.levels.WARN)
    return false
  end
  -- Prepare images first: a failure (e.g. too large to shrink) keeps the prompt as it is.
  local payload, shown = {}, {}
  for _, a in ipairs(attachments or {}) do
    local image, sent, err = require("claude-code.images").attachment(a.image)
    if not image then
      vim.notify(("claude-code: %s: %s"):format(a.label, err), vim.log.levels.ERROR)
      return false
    end
    table.insert(payload, image)
    table.insert(shown, { label = a.label, image = a.image, sent = sent })
  end
  self:ensure_running()
  self.last_active = os.time()
  self.chat.transcript:user_message(text, shown)
  self.busy = true
  self.in_reply = false
  self.reply_has_text = false
  self.interrupted = false
  self.chat:set_status({ activity = "Thinking" })
  self.sidecar:send({ type = "prompt", text = text, images = #payload > 0 and payload or nil })
  return true
end

function Session:interrupt()
  if self.shell then
    -- A running `!command` is what you're waiting on: stop that first.
    self.shell.killed = true
    self.shell.job:kill("sigterm")
    return
  end
  if self.busy and self:running() then
    self.interrupted = true
    self.chat:set_status({ activity = "Interrupting" })
    self.sidecar:send({ type = "interrupt" })
  end
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
  self.chat:set_title(title)
  if not self.persisted then
    -- No transcript to write the title to yet; apply it after the first turn.
    self.pending_title = title
    return
  end
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
  -- Subagent traffic is nested under a tool call; the top-level transcript skips it for now.
  if msg.parent_tool_use_id then
    return
  end
  local transcript = self.chat.transcript

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
      end
    end
  elseif msg.type == "user" then
    self:tool_results(msg.message and msg.message.content)
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
function Session:tool_results(content)
  for _, block in ipairs(type(content) == "table" and content or {}) do
    if block.type == "tool_result" then
      self.chat.transcript:tool_result(
        block.tool_use_id,
        block.is_error == true and "error" or "success",
        tools.result_text(block.content)
      )
      self:activity("Thinking")
    end
  end
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

  self.busy = false
  self.interrupted = false
  self.chat:set_status({ activity = nil, cost = self.cost })

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

--- Load the stored conversation into the transcript. The process starts when
--- the session is shown (or on send).
---@private
function Session:load_history()
  control.request("get_messages", { session_id = self.id, dir = self.cwd, tail = REPLAY_LIMIT }, function(err, result)
    if err or not result then
      vim.notify("claude-code: couldn't load session: " .. tostring(err), vim.log.levels.ERROR)
      self.chat:set_status({ activity = nil, stopped = "suspended" })
      return
    end
    self.chat.transcript:batch(function()
      self:replay(result.messages or {}, result.total or 0)
    end)
    if self:running() then
      self.chat:set_status({ activity = nil })
    else
      self.chat:set_status({ activity = nil, stopped = "suspended" })
    end
  end)
end

---@private
---@param messages table[] SessionMessage[]
---@param total integer
function Session:replay(messages, total)
  local transcript = self.chat.transcript
  if total > #messages then
    transcript:note(("%d earlier messages not shown"):format(total - #messages))
  end
  for _, m in ipairs(messages) do
    local content = type(m.message) == "table" and m.message.content
    if m.parent_tool_use_id then
      -- Subagent traffic: skipped, as in live sessions.
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
  transcript:note(("↻ Resumed · last active %s"):format(os.date("%b %d %H:%M", self.last_active)))
end

return Session
