-- Noctalia Scope Bar widget.
-- The native Go helper owns PipeWire/PCM processing and pitch locking.  This
-- file only polls its latest frame and draws it on a braille dot canvas.

local mode = noctalia.getConfig("mode") or "free"
local chars = math.floor(tonumber(noctalia.getConfig("width")) or 48)
local lines = math.floor(tonumber(noctalia.getConfig("lines")) or 3)
local fontSize = tonumber(noctalia.getConfig("font_size")) or 5
local sensitivity = (tonumber(noctalia.getConfig("sensitivity")) or 140) / 100
local smoothing = (tonumber(noctalia.getConfig("smoothing")) or 55) / 100
local thickness = math.floor(tonumber(noctalia.getConfig("thickness")) or 2)
local color = noctalia.getConfig("color") or "primary"
local keepEvery = math.floor(tonumber(noctalia.getConfig("keep_every")) or 16)
local captureDevice = noctalia.getConfig("capture_device") or ""
local hideWhenIdle = noctalia.getConfig("hide_when_idle")
if hideWhenIdle == nil then hideWhenIdle = true end

chars = math.max(8, math.min(96, chars))
lines = math.max(1, math.min(5, lines))
thickness = math.max(1, math.min(6, thickness))
keepEvery = math.max(1, math.min(96, keepEvery))
local dotCols = chars * 2
local dotRows = lines * 4
local frameFile = "/tmp/noctalia-scopebar-go.csv"
local outputPoints = math.max(64, dotCols * 3)
local helperStarted = false
local helperAlive = false
local polling = false
local lastFrame = ""
local values = {}
local pitchHz = 0
local active = false
local idleFrames = 0
local smoothed = {}
local lastRenderText = nil

local BRAILLE = {
  [0] = { [0] = 0x01, [1] = 0x08 },
  { [0] = 0x02, [1] = 0x10 },
  { [0] = 0x04, [1] = 0x20 },
  { [0] = 0x40, [1] = 0x80 },
}

local function clamp(v, lo, hi)
  return v < lo and lo or (v > hi and hi or v)
end

local function resample(src, n)
  local out = {}
  local m = #src
  if m == 0 then
    for i = 1, n do out[i] = 0 end
    return out
  end
  if n == 1 then out[1] = src[1] or 0; return out end
  for i = 1, n do
    local p = (i - 1) * (m - 1) / (n - 1)
    local a = math.floor(p) + 1
    local b = math.min(m, a + 1)
    local f = p - (a - 1)
    out[i] = (src[a] or 0) * (1 - f) + (src[b] or 0) * f
  end
  return out
end

local function parseFrame(text)
  local semicolon = text:find(";", 1, true)
  if not semicolon then return nil end
  local p = tonumber(text:sub(1, semicolon - 1)) or 0
  local out = {}
  for part in text:sub(semicolon + 1):gmatch("([^,]+)") do
    out[#out + 1] = tonumber(part) or 0
  end
  if #out == 0 then return nil end
  return p, out
end

local function smoothAt(x, v)
  local old = smoothed[x] or v
  old = old + (v - old) * (1 - smoothing)
  smoothed[x] = old
  return old
end

-- Join neighbouring samples vertically.  Without this, a steep trace can
-- leave holes because each braille dot column is only two pixels wide.
local function renderBraille(points)
  local lo, hi = {}, {}
  local mid = (dotRows + 1) / 2
  local half = (thickness - 1) / 2
  for x = 1, dotCols do
    local v = smoothAt(x, clamp((points[x] or 0) * sensitivity, -1, 1))
    local y = (1 - v) * (dotRows - 1) * 0.5 + 1
    lo[x], hi[x] = y - half, y + half
  end

  local rows = {}
  for line = 0, lines - 1 do
    local row = {}
    for c = 0, chars - 1 do
      local bits = 0
      for subrow = 0, 3 do
        local y = line * 4 + subrow + 1
        for subcol = 0, 1 do
          local x = c * 2 + subcol + 1
          local a, b = lo[x], hi[x]
          if x > 1 then a = math.min(a, lo[x - 1]); b = math.max(b, hi[x - 1]) end
          if x < dotCols then a = math.min(a, lo[x + 1]); b = math.max(b, hi[x + 1]) end
          if y >= math.floor(a) and y <= math.ceil(b) then
            bits = bits + BRAILLE[subrow][subcol]
          end
        end
      end
      row[c + 1] = utf8.char(0x2800 + bits)
    end
    rows[line + 1] = table.concat(row)
  end
  return rows
end

local blank = string.rep(utf8.char(0x2800), chars)
local function setRows(rows)
  local text = table.concat(rows, "\n")
  if text == lastRenderText then return end
  lastRenderText = text
  local labels = {}
  for i, row in ipairs(rows) do
    labels[#labels + 1] = ui.label({
      key = "row" .. i, text = row, color = color,
      fontSize = fontSize, maxLines = 1,
    })
  end
  barWidget.render(ui.column({ key = "scope", gap = 0, align = "center" }, labels))
end

local function isHidden()
  return hideWhenIdle and not active and idleFrames > 8
end

local function render()
  if isHidden() then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)
  if #values == 0 then
    setRows({ blank })
    return
  end
  setRows(renderBraille(resample(values, dotCols)))
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function startHelper()
  if helperStarted then return end
  helperStarted = true
  local dir = noctalia.pluginDir() or ""
  local target = captureDevice:gsub("'", "")
  -- The shell wrapper resolves a sink and pipes raw f32le to the Go binary.
  local command = shellQuote(dir .. "/start-scope-helper-go.sh") .. " "
    .. shellQuote(target) .. " " .. tostring(keepEvery) .. " "
    .. tostring(outputPoints) .. " >/dev/null 2>&1 &"
  local ok = noctalia.runAsync("setsid nohup " .. command, function(r)
    helperAlive = r and r.exitCode == 0
    if not helperAlive then noctalia.log("scopebar: Go helper exited: " .. tostring(r and r.stderr)) end
  end)
  if not ok then noctalia.log("scopebar: failed to start Go helper") end
end

local function pollFrame()
  if polling then return end
  polling = true
  noctalia.readFileAsync(frameFile, function(contents)
    polling = false
    if not contents or contents == "" or contents == lastFrame then return end
    lastFrame = contents
    local p, parsed = parseFrame(contents)
    if parsed then
      pitchHz, values = p, parsed
      active = false
      for _, v in ipairs(values) do
        if math.abs(v) > 0.008 then active = true; break end
      end
      idleFrames = active and 0 or idleFrames + 1
    end
  end)
end

noctalia.setUpdateInterval(1000 / 60)

function update()
  startHelper()
  -- Keep polling while hidden.  A quiet signal hides the widget, but the
  -- next non-silent frame is what wakes it up again.  If polling stops here,
  -- `active` can never become true after a period of silence.
  pollFrame()
  if #values == 0 or not active then
    idleFrames = idleFrames + 1
    for i = 1, #values do values[i] = values[i] * 0.8 end
  end
  render()
end

function onExit()
  noctalia.runAsync("pkill -f 'scopebar-g[o]-helper' 2>/dev/null; pkill -f 'pw-record --ra[w]' 2>/dev/null", nil)
end
