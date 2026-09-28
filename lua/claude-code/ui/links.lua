-- Links in the transcript: finding the one under the cursor and working out
-- what it points at. Markdown links (inline, reference and autolinks) come from
-- tree-sitter, so they're found even while conceal hides the destination; bare
-- URLs and file paths (`lua/foo.lua:42`) are picked out of the text around the
-- cursor.

local api = vim.api

local M = {}

---@param node TSNode
---@param buf integer
---@return string
local function text(node, buf)
  return vim.treesitter.get_node_text(node, buf)
end

---@param node TSNode
---@param type string
---@return TSNode?
local function child(node, type)
  for c in node:iter_children() do
    if c:type() == type then
      return c
    end
  end
end

--- A link destination without its optional angle brackets.
---@param dest string
---@return string
local function destination(dest)
  return (dest:gsub("^<(.*)>$", "%1"))
end

--- Reference labels match case-insensitively, with runs of whitespace collapsed.
---@param label string
---@return string
local function normalize(label)
  return vim.trim(label:gsub("^%[", ""):gsub("%]$", "")):gsub("%s+", " "):lower()
end

--- The destination of the reference definition `[label]: dest` in the buffer.
---@param buf integer
---@param label string
---@return string?
local function reference(buf, label)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown", { error = false })
  local tree = ok and parser and parser:parse(true)[1]
  if not tree then
    return nil
  end
  local want = normalize(label)
  local query = vim.treesitter.query.parse("markdown", "(link_reference_definition) @def")
  for _, def in query:iter_captures(tree:root(), buf) do
    local l, d = child(def, "link_label"), child(def, "link_destination")
    if l and d and normalize(text(l, buf)) == want then
      return destination(text(d, buf))
    end
  end
end

--- The markdown link at (row, col), if any.
---@param buf integer
---@param row integer 0-based
---@param col integer 0-based
---@return string?
local function markdown_link(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown", { error = false })
  if not ok or not parser then
    return nil
  end
  parser:parse({ row, row + 1 })
  -- Asked of the parser rather than `vim.treesitter.get_node`, which goes by filetype
  -- (the transcript's is its own, not "markdown").
  local node = parser:named_node_for_range({ row, col, row, col }, { ignore_injections = false })
  while node do
    local type = node:type()
    if type == "inline_link" or type == "image" then
      local dest = child(node, "link_destination")
      return dest and destination(text(dest, buf))
    elseif type == "full_reference_link" then
      local label = child(node, "link_label")
      return label and reference(buf, text(label, buf))
    elseif type == "collapsed_reference_link" or type == "shortcut_link" then
      local label = child(node, "link_text")
      return label and reference(buf, text(label, buf))
    elseif type == "uri_autolink" then
      return destination(text(node, buf))
    elseif type == "email_autolink" then
      return "mailto:" .. destination(text(node, buf))
    elseif type == "link_reference_definition" then
      local dest = child(node, "link_destination")
      return dest and destination(text(dest, buf))
    elseif type == "inline" or type == "paragraph" then
      return nil
    end
    node = node:parent()
  end
end

--- Drop punctuation that ends the sentence around a URL or path rather than belonging to it,
--- keeping a closing paren that has a matching opening one (Wikipedia-style URLs).
---@param s string
---@return string
local function trim(s)
  while true do
    local last = s:sub(-1)
    if last:match("[.,;:!?'\"*_`>%]]") then
      s = s:sub(1, -2)
    elseif last == ")" and select(2, s:gsub("%(", "")) < select(2, s:gsub("%)", "")) then
      s = s:sub(1, -2)
    else
      return s
    end
  end
end

--- The whitespace-delimited word covering `col` (1-based byte span) on `line`.
---@param line string
---@param col integer 0-based
---@return string?
local function word_at(line, col)
  local start = 1
  while true do
    local s, e = line:find("%S+", start)
    if not s then
      return nil
    elseif col + 1 < s then
      return nil
    elseif col + 1 <= e then
      return line:sub(s, e)
    end
    start = e + 1
  end
end

--- A bare URL or path in the text at (row, col).
---@param buf integer
---@param row integer
---@param col integer
---@return string?
local function plain(buf, row, col)
  local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
  local word = word_at(line, col)
  if not word then
    return nil
  end
  -- A URL may follow other text in the word, e.g. `(see:https://…)`.
  local url = word:match("%a[%w+.-]*://.*")
  if url then
    return trim(url)
  end
  word = trim(word:gsub("^[%(%[<\"'`*_]+", ""))
  return word ~= "" and word or nil
end

--- What the link under the cursor points at: a markdown link's destination, a bare URL,
--- or the word under the cursor (which may be a file path).
---@param buf integer
---@param row integer 0-based
---@param col integer 0-based
---@return string? target
---@return boolean? explicit True for markdown links and URLs; false for a bare word that may not be a path at all.
function M.at(buf, row, col)
  local link = markdown_link(buf, row, col)
  if link and link ~= "" then
    return link, true
  end
  local word = plain(buf, row, col)
  if word then
    return word, word:match("^%a[%w+.-]*://") ~= nil
  end
end

---@class claude_code.LinkFile
---@field path string Absolute path.
---@field line? integer
---@field col? integer

--- If `target` is a URL (anything with a scheme other than `file:`), return it.
---@param target string
---@return string?
function M.url(target)
  local scheme = target:match("^(%a[%w+.-]*):")
  -- One-letter "schemes" are Windows drive letters.
  if scheme and #scheme > 1 and scheme:lower() ~= "file" then
    return target
  end
end

--- Resolve `target` to an existing file or directory, relative to `cwd`. Understands
--- `file://` URLs, `#L12` anchors (as GitHub and Claude Code write them) and `:12[:3]` suffixes.
---@param target string
---@param cwd string
---@return claude_code.LinkFile?
function M.file(target, cwd)
  local path = target:gsub("^file://", "")
  path = path:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  local line, col
  local anchor = path:match("#L(%d+)")
  if anchor then
    line = tonumber(anchor)
  end
  path = path:gsub("#.*$", "")
  if not line then
    local rest, l, c = path:match("^(.-):(%d+):(%d+)$")
    if not rest then
      rest, l = path:match("^(.-):(%d+)$")
    end
    if rest then
      path, line, col = rest, tonumber(l), tonumber(c)
    end
  end
  if path == "" then
    return nil
  end
  path = vim.fs.normalize(path) -- expands a leading ~
  if not path:match("^/") and not path:match("^%a:/") then
    path = vim.fs.normalize(vim.fs.joinpath(cwd, path))
  end
  if not vim.uv.fs_stat(path) then
    return nil
  end
  return { path = path, line = line, col = col }
end

return M
