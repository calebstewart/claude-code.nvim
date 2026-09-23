-- Images for the prompt: reading one from the system clipboard (a terminal can
-- only paste text, so like the CLI we ask the OS for it), recognising image
-- files, and preparing them for the API (base64, shrunk when too large).

local M = {}

--- The API rejects images over 5 MB (base64) or 8000 px a side; Claude also
--- works best at modest sizes, so larger images are shrunk to this long edge.
local MAX_EDGE = 2000
local MAX_BYTES = math.floor(5 * 1024 * 1024 * 3 / 4) -- raw bytes that fit in 5 MB of base64

local TYPES = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  gif = "image/gif",
  webp = "image/webp",
}

---@class claude_code.Image
---@field path string
---@field media_type string
---@field bytes integer
---@field width? integer
---@field height? integer

---@param path string
---@return string?
local function read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

---@param s string
---@param i integer 1-based
local function u16be(s, i)
  return s:byte(i) * 256 + s:byte(i + 1)
end

---@param s string
---@param i integer 1-based
local function u32be(s, i)
  return ((s:byte(i) * 256 + s:byte(i + 1)) * 256 + s:byte(i + 2)) * 256 + s:byte(i + 3)
end

--- Media type and dimensions from the file's header (dimensions may be nil).
---@param data string
---@return string? media_type, integer? width, integer? height
local function sniff(data)
  if data:sub(1, 8) == "\137PNG\r\n\26\n" and #data >= 24 then
    return "image/png", u32be(data, 17), u32be(data, 21)
  elseif data:sub(1, 3) == "GIF" and #data >= 10 then
    return "image/gif", data:byte(7) + data:byte(8) * 256, data:byte(9) + data:byte(10) * 256
  elseif data:sub(1, 2) == "\255\216" then
    -- JPEG: walk the segments to the start-of-frame marker.
    local i = 3
    while i + 8 <= #data do
      if data:byte(i) ~= 0xFF then
        break
      end
      local marker = data:byte(i + 1)
      local length = u16be(data, i + 2)
      if marker >= 0xC0 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
        return "image/jpeg", u16be(data, i + 7), u16be(data, i + 5)
      end
      i = i + 2 + length
    end
    return "image/jpeg"
  elseif data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP" then
    return "image/webp"
  end
end

--- Is `path` an image file we can send?
---@param path string
function M.is_image(path)
  local ext = path:match("%.([%w]+)$")
  return ext ~= nil and TYPES[ext:lower()] ~= nil and vim.fn.filereadable(path) == 1
end

--- Inspect an image file.
---@param path string
---@return claude_code.Image?, string? err
function M.inspect(path)
  local data = read(path)
  if not data then
    return nil, "can't read " .. path
  end
  local media_type, width, height = sniff(data)
  if not media_type then
    return nil, "not a PNG, JPEG, GIF or WebP image: " .. path
  end
  return { path = path, media_type = media_type, bytes = #data, width = width, height = height }
end

--- Shrink an image that's too large, into a temp file. Uses `sips` (macOS) or
--- ImageMagick; without either, a too-large image is refused.
---@param image claude_code.Image
---@return claude_code.Image?, string? err
local function shrink(image)
  local too_big = image.bytes > MAX_BYTES
  local too_wide = image.width and math.max(image.width, image.height) > MAX_EDGE
  if not too_big and not too_wide then
    return image
  end
  -- A PNG that's still too heavy at MAX_EDGE (photos, screenshots with gradients) goes to JPEG.
  local out = vim.fn.tempname() .. (too_big and ".jpg" or ("." .. (image.path:match("%.(%w+)$") or "png")))
  local cmd
  if vim.fn.executable("sips") == 1 then
    cmd = { "sips", "-Z", tostring(MAX_EDGE), image.path, "--out", out }
    if too_big then
      cmd = { "sips", "-Z", tostring(MAX_EDGE), "-s", "format", "jpeg", image.path, "--out", out }
    end
  elseif vim.fn.executable("magick") == 1 or vim.fn.executable("convert") == 1 then
    local bin = vim.fn.executable("magick") == 1 and "magick" or "convert"
    cmd = { bin, image.path, "-resize", ("%dx%d>"):format(MAX_EDGE, MAX_EDGE), out }
  else
    return nil, "image is too large to send, and neither sips nor ImageMagick is available to shrink it"
  end
  local result = vim.system(cmd):wait()
  if result.code ~= 0 then
    return nil, "couldn't shrink image: " .. vim.trim(result.stderr or "")
  end
  local shrunk, err = M.inspect(out)
  if shrunk and shrunk.bytes > MAX_BYTES then
    return nil, "image is still too large after shrinking"
  end
  return shrunk, err
end

--- The image as an API attachment (shrunk first if needed).
---@param image claude_code.Image
---@return { media_type: string, data: string }?, claude_code.Image? sent, string? err
function M.attachment(image)
  local sent, err = shrink(image)
  if not sent then
    return nil, nil, err
  end
  local data = read(sent.path)
  if not data then
    return nil, nil, "can't read " .. sent.path
  end
  return { media_type = sent.media_type, data = vim.base64.encode(data) }, sent
end

--- Save the clipboard's image to a temp PNG. Calls back with its path, or nil
--- when the clipboard holds no image (or there's no tool to read it).
---@param callback fun(path?: string)
function M.from_clipboard(callback)
  local out = vim.fn.tempname() .. ".png"
  local function done(ok)
    vim.schedule(function()
      callback(ok and vim.fn.getfsize(out) > 0 and out or nil)
    end)
  end
  if vim.fn.has("mac") == 1 then
    local script = {
      "set f to open for access POSIX file " .. vim.fn.json_encode(out) .. " with write permission",
      "try",
      "  write (the clipboard as «class PNGf») to f",
      "on error",
      "  close access f",
      "  error number -128",
      "end try",
      "close access f",
    }
    local args = { "osascript" }
    for _, line in ipairs(script) do
      vim.list_extend(args, { "-e", line })
    end
    vim.system(args, {}, function(r)
      done(r.code == 0)
    end)
  elseif vim.env.WAYLAND_DISPLAY and vim.fn.executable("wl-paste") == 1 then
    vim.system({ "wl-paste", "--list-types" }, { text = true }, function(types)
      if not (types.stdout or ""):find("image/png", 1, true) then
        return done(false)
      end
      vim.system({ "sh", "-c", 'wl-paste --type image/png > "$1"', "sh", out }, {}, function(r)
        done(r.code == 0)
      end)
    end)
  elseif vim.fn.executable("xclip") == 1 then
    vim.system({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" }, { text = true }, function(targets)
      if not (targets.stdout or ""):find("image/png", 1, true) then
        return done(false)
      end
      vim.system({ "sh", "-c", 'xclip -selection clipboard -t image/png -o > "$1"', "sh", out }, {}, function(r)
        done(r.code == 0)
      end)
    end)
  else
    done(false)
  end
end

return M
