-- Mermaid diagrams in the transcript. Rendering Mermaid needs a browser (it lays
-- text out in a DOM to size boxes), so rather than drawing it in the buffer, a
-- diagram is opened in one: the block under the cursor is written to a small
-- HTML page that loads mermaid.js, and that page goes to the system handler.

local api = vim.api

local M = {}

--- Where mermaid.js is loaded from. The page needs network access for this,
--- but the diagram itself stays in the local file.
local SCRIPT = "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"

local PAGE = [[
<!doctype html>
<html>
<head>
<meta charset="utf-8">
<title>Mermaid diagram</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; padding: 2rem; font-family: sans-serif; }
  .mermaid { display: flex; justify-content: center; }
  #error { white-space: pre-wrap; color: #d33; }
  details { margin-top: 2rem; }
</style>
</head>
<body>
<pre class="mermaid">%s</pre>
<pre id="error"></pre>
<details><summary>Source</summary><pre>%s</pre></details>
<script type="module">
  import mermaid from "%s";
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default" });
  try {
    await mermaid.run({ querySelector: ".mermaid" });
  } catch (err) {
    document.getElementById("error").textContent = String(err && err.message || err);
  }
</script>
</body>
</html>
]]

---@param s string
---@return string
local function escape(s)
  return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

--- The source of the mermaid code block at (row, col), if the cursor is in one
--- (fence lines included).
---@param buf integer
---@param row integer 0-based
---@param col integer 0-based
---@return string?
function M.at(buf, row, col)
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown", { error = false })
  if not ok or not parser then
    return nil
  end
  parser:parse({ row, row + 1 })
  local node = parser:named_node_for_range({ row, col, row, col })
  while node and node:type() ~= "fenced_code_block" do
    node = node:parent()
  end
  if not node then
    return nil
  end
  local lang, content
  for child in node:iter_children() do
    if child:type() == "info_string" then
      lang = vim.treesitter.get_node_text(child, buf):match("^%S+")
    elseif child:type() == "code_fence_content" then
      content = vim.treesitter.get_node_text(child, buf)
    end
  end
  if lang and lang:lower() == "mermaid" and content and vim.trim(content) ~= "" then
    return content
  end
end

--- Write `source` to an HTML page that renders it and open that in the browser.
--- Pages are cached by content, so reopening a diagram reuses its file.
---@param source string
---@return boolean ok
function M.open(source)
  local dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "claude-code", "mermaid")
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, vim.fn.sha256(source):sub(1, 16) .. ".html")
  if not vim.uv.fs_stat(path) then
    local text = escape(source)
    local page = PAGE:format(text, text, SCRIPT)
    if vim.fn.writefile(vim.split(page, "\n", { plain = true }), path) ~= 0 then
      vim.notify("claude-code: couldn't write " .. path, vim.log.levels.ERROR)
      return false
    end
  end
  local _, err = vim.ui.open(path)
  if err then
    vim.notify("claude-code: " .. err, vim.log.levels.ERROR)
    return false
  end
  return true
end

return M
