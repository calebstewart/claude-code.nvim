-- Prompt history, shared with the Claude Code CLI by default. It follows the
-- CLI's conventions for ~/.claude/history.jsonl so the two can run side by side:
--
-- * Reading: the file is read fresh each time you start browsing, filtered to
--   the current project, with the current session's prompts ahead of other
--   sessions' (newest first within each).
-- * Writing: records are appended in a single write while holding the CLI's
--   lock (proper-lockfile's `history.jsonl.lock` directory, stale after 10s).
-- * A prompt identical to the previous one from the same session isn't stored twice.

local config = require("claude-code.config")

local M = {}

local MAX_ENTRIES = 1000
local LOCK_STALE_SECONDS = 10
local LOCK_RETRY_MS = 50
local LOCK_ATTEMPTS = 40

---@class claude_code.HistoryRecord
---@field text string Prompt with pastes expanded.
---@field session_id? string
---@field timestamp integer ms since the epoch

--- Prompts sent from this Neovim, so recall works even when sharing is off or a
--- write is still waiting on the lock.
---@type table<string, claude_code.HistoryRecord[]> project -> records, oldest first
local sent = {}

---@type claude_code.HistoryRecord?
local last_added

local function claude_dir()
  return vim.env.CLAUDE_CONFIG_DIR or vim.fs.joinpath(vim.env.HOME or "~", ".claude")
end

local function history_file()
  return vim.fs.joinpath(claude_dir(), "history.jsonl")
end

---@return string
local function project()
  return vim.fn.getcwd()
end

---@param record { timestamp?: integer, session_id?: string }
local function key(record)
  return ("%s\0%s"):format(record.timestamp or 0, record.session_id or "")
end

---@param path string
---@return string?
local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

--- The CLI stores pasted text out of line: `[Pasted text #1 +13 lines]` in the
--- prompt, with the content in paste-cache/<hash>.txt. Put it back.
---@param entry table history.jsonl record
---@return string
local function expand_pastes(entry)
  local text = entry.display or ""
  local pasted = type(entry.pastedContents) == "table" and entry.pastedContents or {}
  return (text:gsub("%[Pasted text #(%d+)[^%]]*%]", function(id)
    local paste = pasted[id]
    if type(paste) ~= "table" then
      return nil
    end
    local content = paste.content
    if not content and paste.contentHash then
      content = read_file(vim.fs.joinpath(claude_dir(), "paste-cache", paste.contentHash .. ".txt"))
    end
    return content
  end))
end

--- This project's records from the shared file, oldest first.
---@param proj string
---@return claude_code.HistoryRecord[]
local function read_shared(proj)
  local records = {}
  local ok, lines = pcall(io.lines, history_file())
  if not ok then
    return records
  end
  for line in lines do
    -- Cheap pre-filter before decoding: most lines belong to other projects.
    if line:find(proj, 1, true) then
      local decoded, entry = pcall(vim.json.decode, line)
      if decoded and type(entry) == "table" and entry.project == proj and type(entry.display) == "string" then
        local text = expand_pastes(entry)
        if text ~= "" then
          table.insert(records, {
            text = text,
            session_id = type(entry.sessionId) == "string" and entry.sessionId or nil,
            timestamp = tonumber(entry.timestamp) or 0,
          })
        end
      end
    end
  end
  return records
end

--- Prompts to step through with Up, as a list whose *last* element is the
--- first one Up shows: the current session's newest prompt, then its older
--- ones, then other sessions' (newest first), as the CLI orders them.
---@param session_id? string
---@return string[]
function M.entries(session_id)
  local proj = project()
  local records = config.options.history.share and read_shared(proj) or {}
  -- Add prompts sent from here that aren't on disk (yet).
  local seen = {}
  for _, r in ipairs(records) do
    seen[key(r)] = true
  end
  for _, r in ipairs(sent[proj] or {}) do
    if not seen[key(r)] then
      table.insert(records, r)
    end
  end
  table.sort(records, function(a, b)
    return a.timestamp < b.timestamp
  end)

  -- Newest first: this session, then everyone else.
  local mine, others = {}, {}
  for i = #records, 1, -1 do
    local r = records[i]
    table.insert(session_id and r.session_id == session_id and mine or others, r.text)
  end
  local ordered = {}
  for _, list in ipairs({ mine, others }) do
    for _, text in ipairs(list) do
      if text ~= ordered[#ordered] and #ordered < MAX_ENTRIES then
        table.insert(ordered, text)
      end
    end
  end
  -- Reverse so the list reads oldest -> newest, i.e. ordered[1] is last.
  local entries = {}
  for i = #ordered, 1, -1 do
    table.insert(entries, ordered[i])
  end
  return entries
end

--- Run `fn` holding the CLI's lock on history.jsonl, retrying while another
--- process holds it. Never blocks: retries are scheduled on a timer.
---@param fn fun()
---@param attempt? integer
local function with_lock(fn, attempt)
  attempt = attempt or 1
  local lock = history_file() .. ".lock"
  if vim.uv.fs_mkdir(lock, 448) then
    local ok, err = pcall(fn)
    vim.uv.fs_rmdir(lock)
    if not ok then
      vim.notify("claude-code: couldn't write prompt history: " .. tostring(err), vim.log.levels.WARN)
    end
    return
  end
  local stat = vim.uv.fs_stat(lock)
  if stat and os.time() - stat.mtime.sec > LOCK_STALE_SECONDS then
    -- Left behind by a process that died holding it (same rule as proper-lockfile).
    vim.uv.fs_rmdir(lock)
  elseif attempt >= LOCK_ATTEMPTS then
    return -- give up; the prompt is still in this Neovim's history
  end
  vim.defer_fn(function()
    with_lock(fn, attempt + 1)
  end, LOCK_RETRY_MS)
end

--- Remember a sent prompt.
---@param text string
---@param session_id? string
function M.add(text, session_id)
  -- Like the CLI: don't store a repeat of the previous prompt from the same session.
  if last_added and last_added.text == text and last_added.session_id == session_id then
    return
  end
  local sec, usec = vim.uv.gettimeofday()
  ---@type claude_code.HistoryRecord
  local record = { text = text, session_id = session_id, timestamp = math.floor(sec * 1000 + usec / 1000) }
  last_added = record
  local proj = project()
  sent[proj] = sent[proj] or {}
  table.insert(sent[proj], record)

  if not config.options.history.share then
    return
  end
  local line = vim.json.encode({
    display = text,
    -- empty_dict so it encodes as {} rather than [].
    pastedContents = vim.empty_dict(),
    timestamp = record.timestamp,
    project = proj,
    sessionId = session_id,
  }) .. "\n"
  with_lock(function()
    -- One write on an O_APPEND descriptor, so the record lands whole.
    local fd = assert(vim.uv.fs_open(history_file(), "a", 384))
    local ok, err = vim.uv.fs_write(fd, line)
    vim.uv.fs_close(fd)
    assert(ok, err)
  end)
end

return M
