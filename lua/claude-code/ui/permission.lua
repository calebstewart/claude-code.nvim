-- Requests that need the user. Tool permission prompts are inline cards under
-- the tool's line in the transcript (y/a/n). AskUserQuestion opens a modal
-- dialog (ui/question.lua).
--
-- AskUserQuestion arrives through the same permission callback: the host shows
-- the questions and answers by allowing the tool with `answers` filled into its input.

local api = vim.api
local card = require("claude-code.ui.card")
local icons = require("claude-code.ui.icons")
local QuestionPicker = require("claude-code.ui.question")
local tools = require("claude-code.ui.tools")

local ns = api.nvim_create_namespace("claude-code.permission")

---@class claude_code.PermissionRequest
---@field id integer
---@field tool_use_id string
---@field tool_name string
---@field input table
---@field title? string
---@field description? string
---@field has_suggestions boolean
---@field default_to_no boolean
---@field suppress_always boolean
---@field anchor? string tool_use id to show the card under (a subagent's Agent call).
---@field subagent? string Set when a subagent is asking: its description.

---@class claude_code.PermissionAnswer
---@field behavior "allow"|"deny"
---@field always? boolean Also apply the SDK's suggested rules.
---@field updated_input? table Replacement tool input.
---@field message? string Reason given to Claude on deny.
---@field set_mode? claude_code.PermissionMode Also switch the session's permission mode.

---@class claude_code.Permissions
---@field private chat claude_code.Chat
---@field private respond fun(id: integer, answer: claude_code.PermissionAnswer)
---@field private queue claude_code.PermissionRequest[] The head is the one on screen.
---@field private card? integer extmark id
---@field private mapped string[] Keys currently mapped for the card.
---@field private picker? claude_code.QuestionPicker Open while an AskUserQuestion is pending.
---@field private deferred boolean The head request arrived while the chat was hidden.
---@field private on_attention? fun() Called when a request is waiting on a hidden chat.
local Permissions = {}
Permissions.__index = Permissions

---@param chat claude_code.Chat
---@param respond fun(id: integer, answer: claude_code.PermissionAnswer)
---@param on_attention? fun() A request is waiting while the chat is hidden (e.g. to notify).
---@return claude_code.Permissions
function Permissions.new(chat, respond, on_attention)
  return setmetatable({
    chat = chat,
    respond = respond,
    queue = {},
    mapped = {},
    deferred = false,
    on_attention = on_attention,
  }, Permissions)
end

function Permissions:pending()
  return #self.queue > 0
end

---@param request claude_code.PermissionRequest
function Permissions:request(request)
  table.insert(self.queue, request)
  if #self.queue > 1 then
    return
  end
  if self.chat:visible() then
    self:present()
  else
    -- A background session: don't pop anything over the one you're in.
    self.deferred = true
    self.chat:set_status({ activity = "Waiting for you", attention = "Needs your input" })
    if self.on_attention then
      self.on_attention()
    end
  end
end

--- The chat was shown: present a request that arrived while it was hidden.
function Permissions:on_show()
  if self.deferred and #self.queue > 0 then
    self.deferred = false
    self:present()
  end
end

--- The session's process exited: outstanding requests can't be answered any more.
function Permissions:clear()
  if #self.queue > 0 then
    self:dismiss()
    self.queue = {}
    self.deferred = false
    self.chat:set_status({ attention = false })
  end
end

--- The SDK withdrew a request (e.g. after an interrupt).
---@param id integer
function Permissions:cancel(id)
  for index, request in ipairs(self.queue) do
    if request.id == id then
      if index == 1 then
        self:dismiss()
        self:advance()
      else
        table.remove(self.queue, index)
      end
      return
    end
  end
end

-- Card drawing ---------------------------------------------------------------

local wrap, frame, choice = card.wrap, card.frame, card.choice

---@param request claude_code.PermissionRequest
local function offers_always(request)
  return request.has_suggestions and not request.suppress_always
end

---@param request claude_code.PermissionRequest
---@param width integer
---@return claude_code.VirtLine[]
local function permission_card(request, width)
  local inner = card.inner(width)
  local rows = {} ---@type claude_code.Chunk[][]
  if request.subagent then
    table.insert(rows, { { icons.tool("Agent") .. " Subagent: " .. request.subagent, "ClaudeCodeMuted" } })
  end
  for _, line in ipairs(wrap(request.title or ("Claude wants to use " .. request.tool_name), inner)) do
    table.insert(rows, { { line, "ClaudeCodeCardTitle" } })
  end

  -- What exactly will run.
  local body = {} ---@type claude_code.Chunk[]
  local input = request.input or {}
  if type(input.command) == "string" then
    for _, line in ipairs(vim.split(input.command, "\n", { plain = true })) do
      table.insert(body, { "$ " .. line, "ClaudeCodeCardText" })
    end
  elseif request.tool_name == "Edit" or request.tool_name == "MultiEdit" or request.tool_name == "Write" then
    table.insert(body, { tools.detail(input) or "", "ClaudeCodeCardText" })
    vim.list_extend(body, vim.list_slice(tools.diff_lines(input), 1, 8))
  else
    local detail = tools.detail(input)
    if detail then
      table.insert(body, { detail, "ClaudeCodeCardText" })
    end
  end
  if #body > 0 then
    table.insert(rows, {})
    for index, chunk in ipairs(body) do
      if index > 10 then
        table.insert(rows, { { ("… %d more lines"):format(#body - 10), "ClaudeCodeMuted" } })
        break
      end
      table.insert(rows, { chunk })
    end
  end
  if request.description then
    table.insert(rows, {})
    for _, line in ipairs(wrap(request.description, inner)) do
      table.insert(rows, { { line, "ClaudeCodeMuted" } })
    end
  end

  table.insert(rows, {})
  local choices = {} ---@type claude_code.Chunk[]
  if request.default_to_no then
    vim.list_extend(choices, choice("n", "deny", "ClaudeCodeCardDenyKey"))
    vim.list_extend(choices, choice("y", "allow (confirm)"))
  else
    vim.list_extend(choices, choice("y", "allow"))
    if offers_always(request) then
      vim.list_extend(choices, choice("a", "always allow"))
    end
    vim.list_extend(choices, choice("n", "deny", "ClaudeCodeCardDenyKey"))
  end
  table.insert(rows, choices)
  return frame(width, icons.get().permission .. " Permission", rows)
end

--- Claude finished planning and asks to leave plan mode.
---@param request claude_code.PermissionRequest
local function is_plan(request)
  return request.tool_name == "ExitPlanMode"
end

---@param request claude_code.PermissionRequest
---@param width integer
---@return claude_code.VirtLine[]
local function plan_card(request, width)
  local input = request.input or {}
  local rows = {} ---@type claude_code.Chunk[][]
  local lines = vim.split(vim.trim(input.plan or ""), "\n", { plain = true })
  local max = 12
  for i, line in ipairs(lines) do
    if i > max then
      table.insert(rows, { { ("… %d more lines · o opens the full plan"):format(#lines - max), "ClaudeCodeMuted" } })
      break
    end
    table.insert(rows, { { line, "ClaudeCodeCardText" } })
  end
  if input.planFilePath then
    table.insert(rows, {})
    table.insert(rows, { { vim.fn.fnamemodify(input.planFilePath, ":~"), "ClaudeCodeMuted" } })
  end
  table.insert(rows, {})
  if input.planFilePath then
    table.insert(rows, choice("o", "open the plan for review"))
  end
  table.insert(rows, choice("a", "approve · auto-accept edits"))
  table.insert(rows, choice("y", "approve · review each edit"))
  table.insert(rows, choice("n", "keep planning", "ClaudeCodeCardDenyKey"))
  return frame(width, icons.get().plan .. " Plan ready for review", rows)
end

-- Flow -----------------------------------------------------------------------

---@param request claude_code.PermissionRequest
local function is_question(request)
  local questions = request.tool_name == "AskUserQuestion" and request.input and request.input.questions
  return type(questions) == "table" and #questions > 0
end

---@private
function Permissions:present()
  local request = self.queue[1]
  if not request then
    return
  end
  if is_question(request) then
    self.chat:set_status({ activity = "Waiting for your answer", attention = "Claude has a question" })
    local questions = request.input.questions
    self.picker = QuestionPicker.new(questions, {
      on_answer = function(answers, annotations)
        -- Rebuild rather than copy the input: empty JSON objects decode to empty Lua
        -- tables, which would re-encode as arrays and fail the tool's schema.
        local input = { questions = questions, answers = answers }
        if next(annotations) then
          input.annotations = annotations
        end
        self:answer({ behavior = "allow", updated_input = input })
      end,
      on_decline = function()
        self:answer({ behavior = "deny", message = "User declined to answer questions" })
      end,
      on_chat = function(answers)
        self:answer({ behavior = "deny", message = QuestionPicker.chat_message(questions, answers) })
      end,
    })
    self.picker:open()
  elseif is_plan(request) then
    self.chat:set_status({ activity = "Waiting for plan approval", attention = "Plan ready: o open · a/y approve · n keep planning" })
    self:render()
    self.chat:focus_prompt(false)
  else
    self.chat:set_status({ activity = "Waiting for permission", attention = "Permission required: y allow · n deny" })
    self:render()
    self.chat:focus_prompt(false)
  end
end

--- Draw (or redraw) the head permission request's card and bind its keys.
---@private
function Permissions:render()
  local request = self.queue[1]
  local transcript = self.chat.transcript
  local row = (request.anchor and transcript:tool_row(request.anchor))
    or transcript:tool_row(request.tool_use_id)
    or (api.nvim_buf_line_count(transcript.buf) - 1)
  local win = transcript:window()
  local width = win and api.nvim_win_get_width(win) or 80
  self.card = api.nvim_buf_set_extmark(transcript.buf, ns, row, 0, {
    id = self.card,
    virt_lines = is_plan(request) and plan_card(request, width) or permission_card(request, width),
  })
  transcript:follow()
  self:unmap_keys()
  if is_plan(request) then
    self:map_plan_keys(request)
  else
    self:map_permission_keys(request)
  end
end

---@private
---@param keys table<string, fun()>
function Permissions:map(keys)
  for _, buf in ipairs({ self.chat.transcript.buf, self.chat.prompt.buf }) do
    for key, fn in pairs(keys) do
      vim.keymap.set("n", key, fn, { buffer = buf, nowait = true, desc = "Claude: answer request" })
    end
  end
  self.mapped = vim.tbl_keys(keys)
end

---@private
---@param request claude_code.PermissionRequest
function Permissions:map_permission_keys(request)
  local keys = {
    y = function()
      if request.default_to_no then
        local prompt = request.title or ("Allow " .. request.tool_name .. "?")
        vim.ui.select({ "Deny", "Allow" }, { prompt = prompt }, function(c)
          self:answer({ behavior = c == "Allow" and "allow" or "deny" })
        end)
      else
        self:answer({ behavior = "allow" })
      end
    end,
    n = function()
      self:answer({ behavior = "deny" })
    end,
  }
  if offers_always(request) and not request.default_to_no then
    keys.a = function()
      self:answer({ behavior = "allow", always = true })
    end
  end
  self:map(keys)
end

---@private
---@param request claude_code.PermissionRequest
function Permissions:map_plan_keys(request)
  local path = request.input.planFilePath
  local plan = require("claude-code.ui.plan")
  local function approve(mode)
    local answer = { behavior = "allow", set_mode = mode } ---@type claude_code.PermissionAnswer
    -- Hand Claude the plan as reviewed: edits in the review window (saved first) count.
    local text = path and plan.read(path)
    if text and vim.trim(text) ~= vim.trim(request.input.plan or "") then
      answer.updated_input = { plan = text, planFilePath = path }
    end
    self:answer(answer)
  end
  local keys = {
    a = function()
      approve("acceptEdits")
    end,
    y = function()
      approve("default")
    end,
    n = function()
      require("claude-code.ui.input").open({
        title = "What should change? (optional)",
        on_submit = function(feedback)
          self:answer({
            behavior = "deny",
            message = feedback ~= "" and ("The user wants to keep planning. Their feedback: " .. feedback)
              or "The user wants to keep planning. Ask what they would like changed.",
          })
        end,
        on_cancel = function()
          self.chat:focus_prompt(false)
        end,
      })
    end,
  }
  if path then
    keys.o = function()
      plan.open(path, self.chat)
    end
  end
  self:map(keys)
end

---@private
function Permissions:unmap_keys()
  if #self.mapped == 0 then
    return
  end
  for _, buf in ipairs({ self.chat.transcript.buf, self.chat.prompt.buf }) do
    if api.nvim_buf_is_valid(buf) then
      for _, key in ipairs(self.mapped) do
        pcall(vim.keymap.del, "n", key, { buffer = buf })
      end
    end
  end
  self.mapped = {}
  -- Our temporary maps may have shadowed the chat's own (e.g. `a` or <CR>).
  self.chat:apply_keymaps()
end

---@private
function Permissions:dismiss()
  if self.card and api.nvim_buf_is_valid(self.chat.transcript.buf) then
    api.nvim_buf_del_extmark(self.chat.transcript.buf, ns, self.card)
  end
  self.card = nil
  if self.picker then
    self.picker:close()
    self.picker = nil
  end
  self:unmap_keys()
end

---@private
function Permissions:advance()
  table.remove(self.queue, 1)
  if #self.queue > 0 then
    if self.chat:visible() then
      self:present()
    else
      self.deferred = true
    end
  else
    self.chat:set_status({ attention = false })
  end
end

---@private
---@param answer claude_code.PermissionAnswer
function Permissions:answer(answer)
  local request = self.queue[1]
  if not request then
    return
  end
  self:dismiss()
  self.respond(request.id, answer)
  self:advance()
  if not self:pending() then
    self.chat:set_status({ activity = "Running " .. request.tool_name })
    self.chat:focus_prompt(true)
  end
end

return Permissions
