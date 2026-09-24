-- Messages from other Claude sessions, recovered from a transcript for replay.
--
-- The Agent SDK's session reader leaves them out: Claude Code stores one that
-- arrived while the session was idle as a meta user entry, and one that arrived
-- mid-turn as a `queued_command` attachment, and the reader returns neither.
-- Resuming without them would show Claude answering nothing, so they're read
-- back here (in Lua, whichever transport is in use) and put where they belong
-- among the messages the reader did return, by the entries' parentUuid links.

local M = {}

---@class claude_code.ReplayedPeerMessage
---@field type "peer"
---@field uuid string
---@field from string
---@field body string

--- Peer message entries in a transcript, in file order, each with the entry
--- that follows it in the conversation (its child: normally Claude's answer).
---@param path string
---@return { uuid: string, parent?: string, child?: string, from: string, body: string }[]
local function scan(path)
  local file = io.open(path, "r")
  if not file then
    return {}
  end
  local found, waiting = {}, {} -- waiting: peer entries whose child hasn't been seen yet
  local function decode(line)
    local ok, entry = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    return ok and type(entry) == "table" and entry or nil
  end
  for line in file:lines() do
    -- Cheap tests first: most lines are large and none of these.
    for i = #waiting, 1, -1 do
      local peer = waiting[i]
      if line:find('"parentUuid":"' .. peer.uuid .. '"', 1, true) then
        local entry = decode(line)
        if entry and entry.parentUuid == peer.uuid then
          peer.child = entry.uuid
          table.remove(waiting, i)
        end
      end
    end
    if line:find('"kind":"peer"', 1, true) then
      local entry = decode(line)
      if entry and entry.uuid and not entry.isSidechain then
        local origin
        if entry.type == "user" and entry.isMeta then
          origin = entry.origin
        elseif entry.type == "attachment" and type(entry.attachment) == "table" then
          origin = entry.attachment.type == "queued_command" and entry.attachment.origin or nil
        end
        if type(origin) == "table" and origin.kind == "peer" and type(origin.body) == "string" then
          local peer = {
            uuid = entry.uuid,
            parent = entry.parentUuid,
            from = origin.name or origin.from or "another session",
            body = origin.body,
          }
          table.insert(found, peer)
          table.insert(waiting, peer)
        end
      end
    end
  end
  file:close()
  return found
end

--- `messages` (from the session reader) with the session's peer messages added
--- as `{ type = "peer", ... }` entries: before the message that answered them,
--- or else after the one they followed. Ones anchored outside `messages` (e.g.
--- before the replayed tail) are left out.
---@param session_id string
---@param dir? string
---@param messages table[]
---@return table[]
function M.merge(session_id, dir, messages)
  if #messages == 0 then
    return messages
  end
  local path = require("claude-agent-sdk.sessions").find_transcript(session_id, { dir = dir })
  local peers = path and scan(path) or {}
  if #peers == 0 then
    return messages
  end
  local present = {}
  for _, m in ipairs(messages) do
    if m.uuid then
      present[m.uuid] = true
    end
  end
  local before, after = {}, {}
  for _, p in ipairs(peers) do
    -- The reader may have returned it itself (as a user message); replay shows that one.
    if not present[p.uuid] then
      local entry = { type = "peer", uuid = p.uuid, from = p.from, body = p.body }
      local list, key
      if p.child and present[p.child] then
        list, key = before, p.child
      elseif p.parent and present[p.parent] then
        list, key = after, p.parent
      end
      if list then
        list[key] = list[key] or {}
        table.insert(list[key], entry)
      end
    end
  end
  local out = {}
  for _, m in ipairs(messages) do
    vim.list_extend(out, m.uuid and before[m.uuid] or {})
    table.insert(out, m)
    vim.list_extend(out, m.uuid and after[m.uuid] or {})
  end
  return out
end

return M
