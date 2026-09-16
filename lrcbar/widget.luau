-- Lyrics Bar (lrc_tty) — karaoke-highlighted current lyric line.
-- Visual engine adapted from h465855hgg/lyrics (MIT), backend: lrc_tty.

-- ===== settings =====
local maxChars = tonumber(noctalia.getConfig("max_chars")) or 50
local activeColor = noctalia.getConfig("active_color") or "primary"
local inactiveColor = noctalia.getConfig("inactive_color") or "on_surface_variant"
local targetPlayer = noctalia.getConfig("player") or ""
local hideWhenPaused = noctalia.getConfig("hide_when_paused")
if hideWhenPaused == nil then hideWhenPaused = true end
local fps = tonumber(noctalia.getConfig("fps_limit")) or 60
local pollEvery = 2.0 -- seconds between playerctl/lrc_tty polls
local INTERLUDE_TEXT = noctalia.getConfig("interlude_text") or "♪ ♪ ♪"
local INTRO_GAP_MS = tonumber(noctalia.getConfig("intro_gap_ms")) or 6000

local charWidth = 9
local FADE_OUT_MS = 160
local FADE_IN_MS = 260
local BLEND_MS = 350

-- ===== state =====
local fetching = false
local lastPoll = 0
local playing = false
local playerInstance = ""
local trackKey = ""
local positionMs = 0
local lengthMs = 0
local baseClock = 0
local lines = {} -- { {t=ms, dur=ms, text=} }
local dumpKey = ""
local dumpFetching = false

local smoothLineProgress = 0
local displayLine = nil
local outgoingLine = nil
local displayKey = ""
local transitionMs = FADE_OUT_MS + FADE_IN_MS
local lastClock = 0

-- ===== helpers =====
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function charUnits(char)
  return char:byte() ~= nil and char:byte() > 255 and 2 or 1
end

local function toChars(text)
  local chars = {}
  for _, ch in utf8.codes(tostring(text or "")) do
    chars[#chars + 1] = utf8.char(ch)
  end
  return chars
end

local function textUnits(text)
  local units = 0
  for _, ch in ipairs(toChars(text)) do units = units + charUnits(ch) end
  return units
end

local function easeOutCubic(t) return 1 - math.pow(1 - clamp(t, 0, 1), 3) end

-- lrc_tty --dump passes the raw lrclib text through as-is, so timestamps can
-- arrive in several shapes: [mm:ss], [mm:ss.xx], [mm:ss:xx] (2-digit fraction)
-- or [mm:ss:xxx] (3-digit). Scale the fraction by its digit count so every
-- variant lands on the same millisecond value:
--   1 digit = tenths (x100ms), 2 digits = centiseconds (x10ms), 3 digits = ms.
local function parseTimestamps(text)
  local times = {}
  for m, s, frac in text:gmatch("%[(%d+):(%d+)[%.,:](%d+)%]") do
    local scale = 10 ^ (3 - #frac)
    times[#times + 1] = (tonumber(m) * 60 + tonumber(s)) * 1000 + tonumber(frac) * scale
  end
  for m, s in text:gmatch("%[(%d+):(%d+)%]") do
    if tonumber(s) < 60 then
      times[#times + 1] = (tonumber(m) * 60 + tonumber(s)) * 1000
    end
  end
  table.sort(times)
  return times
end

local function parseLrc(dump)
  local out = {}
  local offset = 0
  for line in (dump or ""):gmatch("[^\n]+") do
    local o = line:match("%[offset:(%-?%d+)%]")
    if o then offset = tonumber(o) or 0 end
    local times = parseTimestamps(line)
    if #times > 0 then
      local text = line:gsub("%[[^%]]*%]", ""):gsub("^%s+", ""):gsub("%s+$", "")
      -- empty timed lines mark instrumental breaks -> show "♪ ♪ ♪"
      if text == "" then text = INTERLUDE_TEXT end
      for _, t in ipairs(times) do
        out[#out + 1] = { t = t - offset, text = text }
      end
    end
  end
  table.sort(out, function(a, b) return a.t < b.t end)
  -- intro: text doesn't start at the beginning of the track -> show "♪ ♪ ♪"
  if #out > 0 and out[1].t >= INTRO_GAP_MS then
    table.insert(out, 1, { t = 0, text = INTERLUDE_TEXT, interlude = true })
  end
  for i, l in ipairs(out) do
    local nextT = out[i + 1] and out[i + 1].t or (l.t + 8000)
    l.dur = math.max(700, nextT - l.t)
  end
  return out
end

local function shouldScroll(text)
  return textUnits(text) > maxChars
end

-- Custom scroll instead of the built-in marquee: the line stays static while
-- the karaoke highlight travels from the start; once the highlight reaches the
-- middle of the visible window the text scrolls right-to-left (moves left),
-- keeping the sung part near the window center. It stops as soon as the tail
-- of the line fills the window, letting the karaoke sweep finish in place.
local function getScrollOffset(text, progress)
  local units = textUnits(text)
  if units <= maxChars then return 0 end
  -- position of the highlighted character, in units from the line start
  local advance = clamp(progress, 0, 1) * units
  local windowCenter = maxChars / 2
  -- no movement until the highlight reaches the visible middle
  local offset = advance - windowCenter
  -- never scroll past the end: keep the last maxChars units in view
  return clamp(offset, 0, units - maxChars)
end

local function getProgressMs()
  if playing then
    return positionMs + (os.clock() - baseClock) * 1000
  end
  return positionMs
end

local function getLineInfo()
  if #lines == 0 then return nil end
  local pos = getProgressMs()
  local current = nil
  for _, l in ipairs(lines) do
    if l.t <= pos then current = l else break end
  end
  if not current then return nil end
  local progress = clamp((pos - current.t) / math.max(1, current.dur), 0, 1.2)
  return { line = current, progress = progress, key = tostring(current.t) .. "|" .. current.text }
end

-- ===== rendering =====
local function karaokeColor(charProgress, lineProgress)
  if not playing then return inactiveColor end
  local distance = charProgress - lineProgress
  if distance <= 0 then return activeColor end
  if distance >= 0.14 then return inactiveColor end
  local alpha = 1 - distance / 0.14
  if alpha <= 0.5 then return inactiveColor end
  return activeColor .. "/" .. string.format("%.2f", math.max(0.72, alpha))
end

local function buildLineRow(text, opts)
  opts = opts or {}
  local chars = toChars(text)
  if #chars == 0 then chars = { " " } end
  local widthUnits = math.floor(opts.widthUnits or maxChars)

  local exactOffset = opts.scroll and getScrollOffset(text, opts.lineProgress or 0) or 0
  local offset = math.floor(exactOffset)
  local fraction = exactOffset - offset
  local first = offset + 1
  local last = #chars
  if opts.scroll then
    local units = 0
    last = first - 1
    for si = first, #chars do
      units = units + charUnits(chars[si])
      last = si
      if units > maxChars then break end
    end
  end

  local labels = {}
  local edgeAlpha = noctalia.isDarkMode() and 0.5 or 0.72
  for si = first, last do
    local color = opts.solid and (opts.solidInactive and inactiveColor or activeColor) or inactiveColor
    local alpha = 1
    if not opts.solid then
      local charProgress = #chars > 1 and (si - 1) / (#chars - 1) or 0
      color = karaokeColor(charProgress, opts.lineProgress or 0)
    end
    if opts.scroll and offset > 0 and si == first then alpha = edgeAlpha end
    if opts.scroll and last < #chars and si == last then alpha = edgeAlpha end
    if opts.reveal then
      -- left-to-right fade-in of the incoming line
      local charProgress = (si - first) / math.max(1, last - first)
      alpha = alpha * clamp((opts.reveal - charProgress * 0.45) * 2.4, 0.08, 1)
    end
    if opts.fadeOut then
      -- left-to-right fade-out of the outgoing line
      local charProgress = (si - first) / math.max(1, last - first)
      alpha = alpha * (1 - clamp((opts.fadeOut - charProgress * 0.45) * 2.4, 0, 1))
    end
    if opts.scroll and fraction > 0 then
      if si == first then
        alpha = alpha * (1 - fraction)
      elseif si == last and si > first then
        alpha = alpha * fraction
      end
    end

    labels[#labels + 1] = ui.label({
      key = "c" .. si,
      text = chars[si],
      color = color,
      opacity = alpha,
      maxLines = 1,
    })
  end

  -- pad to the row width so scrolling has a stable window
  while #labels < widthUnits + 1 do
    labels[#labels + 1] = ui.label({ text = " ", opacity = 0, maxLines = 1 })
  end

  return ui.row({
    key = opts.key or "line",
    gap = 0,
    align = "center",
    minWidth = widthUnits * charWidth,
    opacity = opts.opacity or 1,
  }, labels)
end

local function render()
  local info = getLineInfo()
  if not info or (hideWhenPaused and not playing) then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local text = info.line.text
  local interlude = info.line.interlude == true
  local scroll = not interlude and shouldScroll(text)
  -- one width per frame, shared by incoming/outgoing rows so the
  -- widget hugs the lyric length instead of always taking maxChars
  local widthUnits = scroll and maxChars or clamp(textUnits(text), 1, maxChars)
  local children = {}

  if transitionMs < FADE_OUT_MS and outgoingLine and outgoingLine ~= text then
    -- outgoing line fades out left-to-right
    children[#children + 1] = buildLineRow(outgoingLine, {
      key = "out", solid = true, opacity = 1 - easeOutCubic(transitionMs / FADE_OUT_MS),
      scroll = scroll, lineProgress = info.progress,
      fadeOut = transitionMs / FADE_OUT_MS, widthUnits = widthUnits,
    })
  else
    local reveal = clamp((transitionMs - FADE_OUT_MS) / FADE_IN_MS, 0, 1)
    children[#children + 1] = buildLineRow(text, {
      key = "in", scroll = scroll, lineProgress = info.progress,
      reveal = reveal >= 1 and nil or reveal, widthUnits = widthUnits,
    })
  end

  barWidget.render(ui.row({ gap = 0, align = "center", opacity = playing and 1 or 0.58 }, children))
  barWidget.setTooltip(text)
end

-- ===== polling =====
local function poll()
  if fetching then return end
  fetching = true
  local scope = targetPlayer ~= "" and ("--player " .. targetPlayer) or "--all-players"
  noctalia.runAsync(
    "playerctl " .. scope .. " metadata --format '{{lc(status)}} {{playerInstance}} {{position}} {{mpris:length}} {{title}}' 2>/dev/null",
    function(r)
      fetching = false
      if r.exitCode ~= 0 or not r.stdout or r.stdout == "" then
        playing = false
        lines = {}
        return
      end
      local chosen = nil
      for record in r.stdout:gmatch("[^\n]+") do
        local status, instance, rest = record:match("^(%S+) (%S+) (.+)$")
        if status and instance then
          local posUs, lenUs, title = rest:match("^(%d+) (%d+) (.+)$")
          if status == "playing" then chosen = { status = status, instance = instance, posUs = posUs, lenUs = lenUs, title = title } break end
          if not chosen and status == "paused" then
            chosen = { status = status, instance = instance, posUs = posUs, lenUs = lenUs, title = title }
          end
        end
      end

      if not chosen then
        playing = false
        lines = {}
        return
      end

      local newPlaying = chosen.status == "playing"
      local newPos = tonumber(chosen.posUs) or 0
      if newPlaying ~= playing then
        playing = newPlaying
        baseClock = os.clock()
      end
      positionMs = newPos / 1000
      lengthMs = (tonumber(chosen.lenUs) or 0) / 1000
      baseClock = os.clock()

      local newKey = chosen.instance .. "|" .. chosen.title
      if newKey ~= trackKey then
        trackKey = newKey
        playerInstance = chosen.instance
        lines = {}
        dumpKey = ""
        if not dumpFetching then
          dumpFetching = true
          local dumpPlayer = targetPlayer ~= "" and targetPlayer or chosen.instance
          noctalia.runAsync("lrc_tty --dump --player " .. dumpPlayer, function(d)
            dumpFetching = false
            if d.exitCode == 0 then
              lines = parseLrc(d.stdout)
            end
          end)
        end
      end
    end
  )
end

-- ===== entry points =====
noctalia.setUpdateInterval(1000 / clamp(fps, 30, 120))

function update()
  local now = os.clock()
  local delta = lastClock > 0 and now - lastClock or 0
  lastClock = now

  if now - lastPoll >= pollEvery then
    lastPoll = now
    poll()
  end

  local info = getLineInfo()
  local nextKey = info and info.key or ""
  if nextKey ~= displayKey then
    outgoingLine = displayLine
    displayKey = nextKey
    transitionMs = 0
    -- hard-jump instead of smoothing: the scroll offset and karaoke sweep
    -- are derived from this progress, so a lingering old value would push
    -- the fresh line way off to the left
    smoothLineProgress = info and info.progress or 0
  else
    transitionMs = transitionMs + delta * 1000
  end
  if info then
    -- exponential smoothing keeps the karaoke sweep fluid between ticks
    smoothLineProgress = smoothLineProgress + (info.progress - smoothLineProgress) * math.min(1, delta * 14)
    info.progress = smoothLineProgress
  end
  displayLine = info and info.line.text or nil

  render()
end
