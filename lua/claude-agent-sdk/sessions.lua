-- The session store: Claude Code's transcripts on disk.
--
-- Claude Code writes one JSONL file per session under
-- `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`, where the directory
-- name is the working directory with every non-alphanumeric character replaced
-- by a dash. Each line is one entry; conversation entries (`user`, `assistant`)
-- carry `uuid`/`parentUuid` and metadata entries (`custom-title`, `ai-title`,
-- `last-prompt`) carry session-level facts.
--
-- These are the local-filesystem equivalents of the SDK's listSessions,
-- getSessionInfo, getSessionMessages, renameSession and deleteSession, plus
-- list_projects, which the SDK has no counterpart for. No Claude process is
-- involved — the CLI is not consulted at all.

local M = {}

--- Lines at or below this decode in full. Metadata entries are small; the large
--- ones are assistant turns, where only cwd and gitBranch matter and a targeted
--- pattern is far cheaper than parsing the whole message.
local SMALL_LINE = 8192

--- Entry properties that carry session metadata, mapped to the accumulator key
--- they land on. Last occurrence wins, so a session reports its latest title and
--- the branch it ended on.
local METADATA = {
  customTitle = "custom_title",
  aiTitle = "ai_title",
  lastPrompt = "last_prompt",
  summary = "summary_hint",
  tag = "tag",
  gitBranch = "git_branch",
  cwd = "cwd",
}

--- Entrypoints belonging to programmatic sessions rather than an interactive CLI.
local PROGRAMMATIC = { ["sdk-cli"] = true, ["sdk-ts"] = true, ["sdk-py"] = true, daemon = true, ["daemon-worker"] = true }

--- A random RFC 4122 v4 UUID, for entries we append ourselves.
---@return string
local function uuid()
  return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    return ("%x"):format(c == "x" and math.random(0, 15) or math.random(8, 11))
  end))
end

---@return string
local function config_dir()
  return vim.env.CLAUDE_CONFIG_DIR or (vim.uv.os_homedir() .. "/.claude")
end

---@return string
function M.projects_root()
  return config_dir() .. "/projects"
end

--- The project directory Claude Code stores a working directory's sessions in.
--- Every non-alphanumeric character becomes a dash, so a path's separators do
--- not matter here: `C:\x\y` and `C:/x/y` encode to the same directory.
---@param cwd string
---@return string
function M.project_dir(cwd)
  return M.projects_root() .. "/" .. (cwd:gsub("[^%w]", "-"))
end

--- A path in a form that two spellings of one location compare equal in.
--- Needed on Windows, where `git` reports forward slashes (`C:/x/y`) while
--- Neovim's cwd uses backslashes (`C:\x\y`): comparing the raw strings would
--- treat a single location as two.
---@param path string
---@return string
local function same_path(path)
  return (path:gsub("\\", "/"):gsub("/+$", ""))
end

---@param value any
---@return string?
local function trimmed(value)
  if type(value) ~= "string" then
    return nil
  end
  local text = vim.trim(value)
  return text ~= "" and text or nil
end

---@param iso any
---@return integer?
local function epoch_ms(iso)
  if type(iso) ~= "string" then
    return nil
  end
  local y, mo, d, h, mi, s, frac = iso:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.?(%d*)")
  if not y then
    return nil
  end
  -- The timestamps are UTC; os.time treats its table as local, so correct for the offset.
  local utc = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s), isdst = false })
  local offset = os.difftime(os.time(os.date("*t", utc)), os.time(os.date("!*t", utc)))
  -- The fraction is a decimal of a second, so pad it to milliseconds: ".5" is 500ms, not 5.
  local millis = tonumber((frac .. "000"):sub(1, 3)) or 0
  return (utc + offset) * 1000 + millis
end

--- User text Claude Code records but that isn't something the user typed.
---@param text string
---@return boolean
local function hidden_prompt(text)
  return text:match("^%s*<[%w_-]+>") ~= nil or text:match("^Caveat: The messages below") ~= nil
end

--- The displayable text of a user entry's content.
---@param message any
---@return string?
local function user_text(message)
  local content = type(message) == "table" and message.content
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return nil
  end
  local parts = {}
  for _, block in ipairs(content) do
    if block.type == "text" and type(block.text) == "string" then
      table.insert(parts, block.text)
    end
  end
  return #parts > 0 and table.concat(parts, "\n") or nil
end

--- First prompt worth showing: slash commands fall back to their own text, a
--- `!command` shows as the command, and hidden scaffolding is skipped. Long
--- prompts are elided, as the CLI's own picker does.
---@param acc table
---@param message any
local function note_first_prompt(acc, message)
  if acc.first_prompt then
    return
  end
  local text = user_text(message)
  if not text then
    return
  end
  text = vim.trim(text)
  local bash = text:match("^<bash%-input>([%s%S]-)</bash%-input>")
  if bash then
    acc.first_prompt = "! " .. vim.trim(bash)
    return
  end
  local command = text:match("^%s*<command%-name>%s*([^<]-)%s*</command%-name>")
  if command then
    -- Remember it, but keep looking for a prompt the user actually typed.
    acc.command_fallback = acc.command_fallback or command
    return
  end
  if text == "" or hidden_prompt(text) then
    return
  end
  if #text > 200 then
    text = text:sub(1, 200) .. "…"
  end
  acc.first_prompt = text
end

--- Read one transcript's metadata without parsing every assistant turn.
---@param path string
---@return table
local function scan(path)
  local acc = {}
  local file = io.open(path, "r")
  if not file then
    return acc
  end
  for line in file:lines() do
    if #line <= SMALL_LINE then
      local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
      if ok and type(entry) == "table" then
        for property, key in pairs(METADATA) do
          if entry[property] ~= nil then
            acc[key] = entry[property]
          end
        end
        if not acc.created_at and entry.timestamp then
          acc.created_at = epoch_ms(entry.timestamp)
        end
        if entry.type == "user" and not entry.isSidechain then
          note_first_prompt(acc, entry.message)
        end
        acc.entrypoint = entry.entrypoint or acc.entrypoint
      end
    else
      -- A big entry: pull out just the two fields worth having from it.
      local cwd = line:match('"cwd":"(.-)"')
      if cwd then
        acc.cwd = cwd
      end
      local branch = line:match('"gitBranch":"(.-)"')
      if branch then
        acc.git_branch = branch
      end
    end
  end
  file:close()
  return acc
end

--- Assemble an SDKSessionInfo, or nil when the session has no usable title —
--- the SDK drops those rather than showing a blank row.
---@param session_id string
---@param path string
---@param mtime integer Milliseconds since the epoch.
---@param dir? string Fallback cwd when the transcript records none.
---@return table?
local function session_info(session_id, path, mtime, dir)
  local acc = scan(path)
  local first_prompt = trimmed(acc.first_prompt) or trimmed(acc.command_fallback)
  local custom_title = trimmed(acc.custom_title) or trimmed(acc.ai_title)
  local summary = custom_title or trimmed(acc.last_prompt) or trimmed(acc.summary_hint) or first_prompt
  if not summary then
    return nil
  end
  return {
    sessionId = session_id,
    summary = summary,
    lastModified = mtime,
    fileSize = nil,
    customTitle = custom_title,
    firstPrompt = first_prompt,
    gitBranch = trimmed(acc.git_branch),
    cwd = trimmed(acc.cwd) or dir,
    tag = trimmed(acc.tag),
    createdAt = acc.created_at,
    -- Not part of SDKSessionInfo; kept so callers can reach the file, and so
    -- list_sessions can apply its programmatic filter.
    path = path,
    entrypoint = trimmed(acc.entrypoint),
  }
end

--- session_info results by transcript path, reused while the file's mtime and
--- size are unchanged: listing re-reads every transcript otherwise, and a
--- sidebar that refreshes as sessions change would do so constantly.
---@type table<string, { mtime: integer, size: integer, info: table? }>
local info_cache = {}

---@param session_id string
---@param path string
---@param mtime integer
---@param size integer
---@param dir? string
---@return table?
local function cached_session_info(session_id, path, mtime, size, dir)
  local hit = info_cache[path]
  if hit and hit.mtime == mtime and hit.size == size then
    return hit.info and vim.deepcopy(hit.info)
  end
  local info = session_info(session_id, path, mtime, dir)
  info_cache[path] = { mtime = mtime, size = size, info = info }
  return info and vim.deepcopy(info)
end

--- Git worktrees of `dir`, which keep their own project directories.
---@param dir string
---@return string[]
local function worktrees(dir)
  local result = vim.system({ "git", "-C", dir, "worktree", "list", "--porcelain" }, { text = true }):wait()
  if result.code ~= 0 then
    return {}
  end
  local paths = {}
  for line in (result.stdout or ""):gmatch("[^\n]+") do
    local path = line:match("^worktree (.+)$")
    if path and same_path(path) ~= same_path(dir) then
      table.insert(paths, path)
    end
  end
  return paths
end

--- Project directories to search for `opts.dir`, or every project when omitted.
---@param opts table
---@return { dir: string, cwd?: string }[]
local function search_roots(opts)
  if opts.dir then
    -- Distinct paths can still encode to one project directory; scanning it
    -- twice would report every session in it twice.
    local roots, seen = {}, {}
    local function add(dir, cwd)
      local encoded = M.project_dir(dir)
      if not seen[encoded] then
        seen[encoded] = true
        table.insert(roots, { dir = encoded, cwd = cwd })
      end
    end
    add(opts.dir, opts.dir)
    if opts.include_worktrees ~= false then
      for _, tree in ipairs(worktrees(opts.dir)) do
        add(tree, tree)
      end
    end
    return roots
  end
  local roots = {}
  local root = M.projects_root()
  for name, kind in vim.fs.dir(root) do
    if kind == "directory" then
      table.insert(roots, { dir = root .. "/" .. name })
    end
  end
  return roots
end

--- Sessions, most recently modified first.
---@param opts? { dir?: string, limit?: integer, offset?: integer, include_worktrees?: boolean, include_programmatic?: boolean }
---@return table[]
function M.list_sessions(opts)
  opts = opts or {}
  local found = {}
  for _, root in ipairs(search_roots(opts)) do
    local ok, entries = pcall(vim.fs.dir, root.dir)
    if ok then
      for name, kind in entries do
        local id = kind == "file" and name:match("^(.+)%.jsonl$")
        if id then
          local path = root.dir .. "/" .. name
          local stat = vim.uv.fs_stat(path)
          if stat then
            table.insert(found, {
              id = id,
              path = path,
              mtime = math.floor(stat.mtime.sec * 1000 + stat.mtime.nsec / 1e6),
              size = stat.size,
              cwd = root.cwd,
            })
          end
        end
      end
    end
  end
  -- Sort before reading: with a limit, only the newest transcripts are parsed.
  table.sort(found, function(a, b)
    return a.mtime > b.mtime
  end)

  local sessions = {}
  local skip = opts.offset or 0
  for _, candidate in ipairs(found) do
    local info = cached_session_info(candidate.id, candidate.path, candidate.mtime, candidate.size, candidate.cwd)
    if info and opts.include_programmatic == false and PROGRAMMATIC[info.entrypoint] then
      info = nil
    end
    if info then
      if skip > 0 then
        skip = skip - 1
      else
        table.insert(sessions, info)
        if opts.limit and #sessions >= opts.limit then
          break
        end
      end
    end
  end
  return sessions
end

--- The working directory a transcript records, from its first entries.
---@param path string
---@return string?
local function transcript_cwd(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end
  local cwd
  local lines = 0
  for line in file:lines() do
    local raw = line:match('"cwd":"(.-[^\\])"')
    if raw then
      local ok, decoded = pcall(vim.json.decode, '"' .. raw .. '"')
      cwd = ok and decoded or nil
      break
    end
    lines = lines + 1
    if lines >= 50 then
      break
    end
  end
  file:close()
  return cwd
end

--- Projects that have sessions, most recently used first. The directory names
--- under `projects/` are a lossy encoding of the path, so each project's real
--- path comes from its newest transcripts. Projects whose path can't be
--- recovered are left out.
---@return { cwd: string, sessions: integer, lastModified: integer }[]
function M.list_projects()
  local projects = {}
  local root = M.projects_root()
  local ok, dirs = pcall(vim.fs.dir, root)
  if not ok then
    return projects
  end
  for name, kind in dirs do
    local dir = root .. "/" .. name
    local files_ok, files = pcall(vim.fs.dir, dir)
    if kind == "directory" and files_ok then
      local transcripts = {}
      for file, file_kind in files do
        if file_kind == "file" and file:match("%.jsonl$") then
          local stat = vim.uv.fs_stat(dir .. "/" .. file)
          if stat then
            local mtime = math.floor(stat.mtime.sec * 1000 + stat.mtime.nsec / 1e6)
            table.insert(transcripts, { path = dir .. "/" .. file, mtime = mtime })
          end
        end
      end
      table.sort(transcripts, function(a, b)
        return a.mtime > b.mtime
      end)
      local cwd
      for i = 1, math.min(#transcripts, 5) do
        cwd = transcript_cwd(transcripts[i].path)
        if cwd then
          break
        end
      end
      if cwd then
        table.insert(projects, { cwd = cwd, sessions = #transcripts, lastModified = transcripts[1].mtime })
      end
    end
  end
  table.sort(projects, function(a, b)
    return a.lastModified > b.lastModified
  end)
  return projects
end

--- Locate a session's transcript.
---@param session_id string
---@param opts? { dir?: string }
---@return string? path, string? cwd
function M.find_transcript(session_id, opts)
  opts = opts or {}
  for _, root in ipairs(search_roots(opts)) do
    local path = root.dir .. "/" .. session_id .. ".jsonl"
    if vim.uv.fs_stat(path) then
      return path, root.cwd
    end
  end
  return nil
end

---@param session_id string
---@param opts? { dir?: string }
---@return table?
function M.get_session_info(session_id, opts)
  local path, cwd = M.find_transcript(session_id, opts)
  if not path then
    return nil
  end
  local stat = vim.uv.fs_stat(path)
  return session_info(session_id, path, stat and math.floor(stat.mtime.sec * 1000 + stat.mtime.nsec / 1e6) or 0, cwd)
end

--- The conversation, in file order.
---
--- Transcripts are append-only and keep rewound branches, so membership is
--- decided by the parentUuid chain ending at the last entry: anything on a
--- branch that was rewound away is left out. Tool results are the exception —
--- when several arrive for one assistant turn they are written as siblings
--- rather than as a chain, so a result hanging off a chain entry is included
--- too. Without that, a turn's parallel tool calls would lose all but the last.
---
--- (The TypeScript SDK is inconsistent here: on a forked transcript it returns
--- the rewound branch's assistant reply while dropping the prompt that produced
--- it. This matches it on every real transcript and diverges only on forks,
--- where it drops the rewound branch cleanly.)
---@param session_id string
---@param opts? { dir?: string, limit?: integer, offset?: integer, include_system_messages?: boolean }
---@return table[]
function M.get_session_messages(session_id, opts)
  opts = opts or {}
  local path = M.find_transcript(session_id, opts)
  if not path then
    return {}
  end
  local file = io.open(path, "r")
  if not file then
    return {}
  end

  -- Every entry with a uuid joins the index, not just the ones we return:
  -- `attachment` and `system` entries sit *inside* the parentUuid chain, so
  -- indexing only user/assistant would break the walk at the first one.
  local order, by_uuid, last = {}, {}, nil
  for line in file:lines() do
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(entry) == "table" and entry.uuid then
      by_uuid[entry.uuid] = entry
      table.insert(order, entry)
      if entry.type == "user" or entry.type == "assistant" or entry.type == "system" then
        last = entry
      end
    end
  end
  file:close()
  if not last then
    return {}
  end

  local on_chain = {}
  local entry = last
  while entry and not on_chain[entry.uuid] do
    on_chain[entry.uuid] = true
    entry = entry.parentUuid and by_uuid[entry.parentUuid] or nil
  end

  local messages = {}
  for _, e in ipairs(order) do
    local kind = e.type
    local message = e.message
    -- An attachment flagged `renderedInHumanTurn` took part in the human turn —
    -- a prompt typed while Claude was busy and queued, say — so it reads back as
    -- a user message carrying the text that was actually submitted.
    if kind == "attachment" and e.renderedInHumanTurn then
      local attachment = e.attachment or {}
      local rendered = type(e.rendered) == "table" and e.rendered[1] or nil
      local text = attachment.prompt or (rendered and rendered.content)
      if type(text) == "string" then
        kind, message = "user", { role = "user", content = text }
      end
    end
    local kept = kind == "user" or kind == "assistant" or (kind == "system" and opts.include_system_messages)
    local tool_result = e.toolUseResult ~= nil or e.sourceToolAssistantUUID ~= nil
    local included = on_chain[e.uuid] or (tool_result and e.parentUuid and on_chain[e.parentUuid])
    if kept and included and not e.isSidechain then
      table.insert(messages, {
        type = kind,
        uuid = e.uuid,
        session_id = e.sessionId,
        message = message,
        parent_tool_use_id = e.parentToolUseID or e.parentToolUseId or nil,
        parent_agent_id = e.parentAgentId or nil,
      })
    end
  end

  if opts.offset and opts.offset > 0 then
    messages = vim.list_slice(messages, opts.offset + 1)
  end
  if opts.limit then
    messages = vim.list_slice(messages, 1, opts.limit)
  end
  return messages
end

--- Set a session's title, the way the CLI's /rename does: by appending a
--- `custom-title` entry. Transcripts are append-only, so the newest wins.
---@param session_id string
---@param title string
---@param opts? { dir?: string }
---@return boolean ok, string? err
function M.rename_session(session_id, title, opts)
  local trimmed_title = vim.trim(title or "")
  if trimmed_title == "" then
    return false, "title must not be empty"
  end
  local path = M.find_transcript(session_id, opts)
  if not path then
    return false, "session not found: " .. session_id
  end
  -- Binary mode: in text mode Windows writes CRLF into an LF-only transcript.
  local file, err = io.open(path, "ab")
  if not file then
    return false, tostring(err)
  end
  local ok, write_err = pcall(function()
    file:write(vim.json.encode({
      type = "custom-title",
      customTitle = trimmed_title,
      sessionId = session_id,
      uuid = uuid(),
      timestamp = os.date("!%Y-%m-%dT%H:%M:%S.000Z"),
    }) .. "\n")
  end)
  file:close()
  if not ok then
    return false, tostring(write_err)
  end
  return true
end

--- Delete a session: its transcript and the directory holding its subagents'
--- transcripts, as the SDK's deleteSession does.
---@param session_id string
---@param opts? { dir?: string }
---@return boolean ok, string? err
function M.delete_session(session_id, opts)
  local path = M.find_transcript(session_id, opts)
  if not path then
    return false, "session not found: " .. session_id
  end
  if vim.fn.delete(path) ~= 0 then
    return false, "couldn't delete " .. path
  end
  local subagents = path:gsub("%.jsonl$", "")
  if vim.fn.isdirectory(subagents) == 1 and vim.fn.delete(subagents, "rf") ~= 0 then
    return false, "couldn't delete " .. subagents
  end
  return true
end

return M
