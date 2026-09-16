-- HyprSpaces — bar workspace pills mirroring the built-in Workspaces
-- widget (styles: regular / minimal / focus_hint), plus app icons of ALL
-- windows running on each workspace. Extra style "show_always": every pill
-- is always expanded and shows all of its workspace's apps.
--
-- Data source: Hyprland via `hyprctl -j workspaces/clients/monitors`.
-- Click a pill to switch, scroll the widget to step through workspaces.
-- Hovering an inactive pill smoothly tints it toward the focused color
-- after a short delay.

-- ===== settings =====
local cfg = noctalia.getConfig

local function bool(key, default)
  local v = cfg(key)
  if v == nil then return default end
  return v == true or v == "true"
end

local function num(key, default, lo, hi)
  local v = tonumber(cfg(key))
  if v == nil then return default end
  if lo and v < lo then v = lo end
  if hi and v > hi then v = hi end
  return v
end

local style = cfg("style") or "regular"
if style ~= "regular" and style ~= "minimal" and style ~= "focus_hint" and style ~= "show_always" then
  style = "regular"
end
local showAppIcons = bool("show_app_icons", true)
local appIconSize = math.floor(num("app_icon_size", 16, 10, 32))
local appIconsMax = math.floor(num("app_icons_max", 0, 0, 16))
local showLabels = bool("show_labels", true)
local labelSource = cfg("label_source") or "id"
local labelsOnlyWhenOccupied = bool("labels_only_when_occupied", false)
local maxLabelChars = math.floor(num("max_label_chars", 1, 1, 20))
local hideWhenEmpty = bool("hide_when_empty", false)
local showAllOutputs = bool("show_all_outputs", false)
local focusedOutputOnly = bool("focused_output_only", false)
local pillScale = num("pill_scale", 1.0, 0.1, 1.0)
local activePillSize = num("active_pill_size", 2.2, 0.25, 8.0)
local inactivePillSize = num("inactive_pill_size", 1.0, 0.25, 8.0)
local capsuleRadius = math.floor(num("capsule_radius", 12, 0, 24))
local changeColorOnHover = bool("change_color_on_hover", true)
local focusedColor = cfg("focused_color") or "primary"
local urgentColor = cfg("urgent_color") or "error"

-- hover feel
local HOVER_DELAY = 0.05   -- seconds before the glow starts
local HOVER_FADE = 0.15    -- seconds of fill animation (in)
local HOVER_FADE_OUT = 0.12 -- seconds of fade animation (out)
local HOVER_MAX_ALPHA = 0.55

-- smoothstep easing for a softer, more organic fade
local function ease(t)
  t = t < 0 and 0 or (t > 1 and 1 or t)
  return t * t * (3 - 2 * t)
end

-- ===== state =====
local wsList = {}      -- sorted array of {id,name,monitor,isFocused,isActive,isOccupied,isUrgent,wins={...}}
local dataSig = ""     -- signature of the last rendered data set
local iconCache = {}   -- [class .. "|" .. size] -> { path, at }
local hoverAnim = {}   -- [key] -> { v = 0..1, target = 0|1, at = clock }
local barOutput = nil  -- captured on the main update() thread; nil inside async callbacks
local dirty = true
local fetching = 0     -- number of in-flight hyprctl calls
local lastPoll = 0
local helperStarted = false
local eventStamp = ""  -- last seen helper stamp; change triggers instant refresh
local stampFetching = false

-- ===== helpers =====
local function clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

-- wall-clock seconds (nowSec() here is CPU time and unsuitable for pacing)
local function nowSec() return noctalia.nowMs() / 1000 end

-- on-color token for text drawn on top of a fill token
local ON_COLOR = {
  primary = "on_primary",
  secondary = "on_secondary",
  tertiary = "on_tertiary",
  error = "on_error",
  surface = "on_surface",
  surface_variant = "on_surface_variant",
  outline = "on_surface",
  hover = "on_hover",
}

local function textColorFor(fill)
  local on = ON_COLOR[fill]
  if on then return on end
  -- hex "#rrggbb" / "#rrggbbaa": pick black/white by luminance
  local r, g, b = tostring(fill):match("^#(%x%x)(%x%x)(%x%x)")
  if r then
    local lum = 0.299 * tonumber(r, 16) + 0.587 * tonumber(g, 16) + 0.114 * tonumber(b, 16)
    if lum > 140 then return "#101010" end
    return "#f5f5f5"
  end
  return "on_surface"
end

local ICON_MISS_TTL = 15 -- seconds; retry unresolved icons (theme may load late)

local function appIconPath(class, sizePx)
  if not class or class == "" then return nil end
  local key = class .. "|" .. sizePx
  local cached = iconCache[key]
  if cached then
    if cached.path ~= "" then return cached.path end
    if nowSec() - cached.at < ICON_MISS_TTL then return nil end
  end
  local path = noctalia.appIconPath(class:lower(), sizePx)
  iconCache[key] = { path = path or "", at = nowSec() }
  return path
end

-- ===== data polling =====
local function rebuild(wss, clients, monitors)
  -- monitor name -> active workspace id; also find globally focused monitor
  local activeByMonitor = {}
  local focusedMonitor = nil
  for _, mon in ipairs(monitors or {}) do
    local aw = mon.activeWorkspace
    if aw and aw.id ~= nil then
      activeByMonitor[mon.name] = aw.id
      if mon.focused then focusedMonitor = mon.name end
    end
  end

  local focusedId = nil
  for _, mon in ipairs(monitors or {}) do
    if mon.focused then
      local aw = mon.activeWorkspace
      if aw then focusedId = aw.id end
    end
  end

  -- windows grouped per workspace id
  local byWs = {}
  for _, c in ipairs(clients or {}) do
    local w = c.workspace
    if w and w.id ~= nil and not c.hidden then
      local list = byWs[w.id]
      if not list then list = {}; byWs[w.id] = list end
      list[#list + 1] = {
        class = c.class or c.initialClass or "",
        title = c.title or "",
        focused = c.focused == true,
        urgent = c.urgent == true,
      }
    end
  end

  local barOut = barOutput or focusedMonitor
  local targetMonitor = focusedOutputOnly and (focusedMonitor or barOut) or barOut

  local out = {}
  for _, ws in ipairs(wss or {}) do
    local matches = showAllOutputs
      or (ws.monitor ~= nil and targetMonitor ~= nil and ws.monitor == targetMonitor)
    if matches then
      local wins = byWs[ws.id] or {}
      local isActive = activeByMonitor[ws.monitor] == ws.id
      local entry = {
        id = ws.id,
        name = ws.name or "",
        monitor = ws.monitor,
        isActive = isActive,
        isFocused = focusedId ~= nil and ws.id == focusedId,
        isOccupied = #wins > 0,
        isUrgent = false,
        wins = wins,
      }
      for _, w in ipairs(wins) do
        if w.urgent then entry.isUrgent = true break end
      end
      out[#out + 1] = entry
    end
  end

  table.sort(out, function(a, b)
    local an, bn = type(a.id) == "number", type(b.id) == "number"
    if an and bn then return a.id < b.id end
    if an ~= bn then return an end -- numeric ids first, special workspaces last
    return a.id < b.id
  end)

  -- signature: skip re-render entirely when nothing visible changed
  local sig = {}
  for _, ws in ipairs(out) do
    sig[#sig + 1] = tostring(ws.id) .. ":" .. tostring(ws.isActive) .. ":" .. tostring(ws.isFocused)
      .. ":" .. tostring(ws.isUrgent) .. ":" .. tostring(#ws.wins)
    for _, w in ipairs(ws.wins) do
      sig[#sig + 1] = w.class .. (w.focused and "!" or "")
    end
  end
  local newSig = table.concat(sig, "|")

  wsList = out
  if newSig ~= dataSig then
    dataSig = newSig
    dirty = true
  end
end

local EVENT_STAMP = "/tmp/noctalia-hyprspaces-events.stamp"

local function startHelper()
  if helperStarted then return end
  helperStarted = true
  local dir = noctalia.pluginDir() or ""
  noctalia.runAsync(
    "setsid nohup python3 '" .. dir .. "/hyprspaces-events.py' >/dev/null 2>&1 &",
    nil
  )
end

local function checkEvents()
  if stampFetching then return end
  stampFetching = true
  noctalia.readFileAsync(EVENT_STAMP, function(contents)
    stampFetching = false
    if contents and contents ~= "" and contents ~= eventStamp then
      local fresh = eventStamp ~= ""
      eventStamp = contents
      if fresh then
        -- compositor event: refresh immediately, bypassing the poll interval
        lastPoll = 0
      end
    end
  end)
end

local function poll()
  if fetching > 0 then return end
  fetching = 3
  lastPoll = nowSec()

  local wss, clients, monitors = nil, nil, nil
  local function done()
    if wss and clients and monitors then
      rebuild(wss, clients, monitors)
    end
  end

  local function parse(r)
    if r.exitCode ~= 0 then return nil end
    local v = noctalia.json.decode(r.stdout or "")
    return v
  end

  noctalia.runAsync("hyprctl -j workspaces", function(r)
    wss = parse(r) or {}
    fetching -= 1
    done()
  end)
  noctalia.runAsync("hyprctl -j clients", function(r)
    clients = parse(r) or {}
    fetching -= 1
    done()
  end)
  noctalia.runAsync("hyprctl -j monitors", function(r)
    monitors = parse(r) or {}
    fetching -= 1
    done()
  end)
end

-- ===== actions =====
local function switchTo(id)
  local target
  if type(id) == "number" then
    target = tostring(math.floor(id))
  else
    target = "name:" .. tostring(id)
  end
  noctalia.runAsync('hyprctl dispatch "hl.dsp.focus({ workspace = ' .. "'" .. target .. "'" .. ' })"', nil)
end

function onScroll(axis, steps)
  -- steps negative = wheel up / left -> previous workspace
  local dir = steps < 0 and "e-1" or "e+1"
  noctalia.runAsync('hyprctl dispatch "hl.dsp.focus({ workspace = ' .. "'" .. dir .. "'" .. ' })"', nil)
end

local function onPillHover(state, key)
  local anim = hoverAnim[key]
  if state == "true" then
    if not anim then
      hoverAnim[key] = { v = 0, target = 1, at = nowSec() + HOVER_DELAY }
    else
      anim.target = 1
      anim.at = nowSec() + HOVER_DELAY
    end
  else
    if anim then
      -- fade out immediately, no delay
      anim.target = 0
      anim.at = nowSec()
    end
  end
  dirty = true
end

-- ===== rendering =====
local function baseSize()
  -- pill square side derived from icon size so pills hug their content
  return math.max(12, math.floor(appIconSize * 1.1 * pillScale + 0.5))
end

local function labelFor(ws)
  local raw
  if labelSource == "name" and ws.name ~= nil and ws.name ~= "" then
    raw = ws.name
  elseif type(ws.id) == "number" then
    raw = tostring(math.floor(ws.id))
  else
    raw = tostring(ws.id)
  end
  -- numeric labels ARE the workspace identifier: truncating them would
  -- mislabel it (workspace 10 would read as "1"), so keep them in full.
  -- max_label_chars only applies to real (named) labels.
  if raw:match("^-?%d+$") then return raw end
  return raw:sub(1, maxLabelChars)
end

local function shouldShowLabel(ws)
  if not showLabels then return false end
  if labelsOnlyWhenOccupied and style ~= "show_always" then
    return ws.isOccupied or ws.isFocused
  end
  return true
end

local function iconsRow(ws)
  if not showAppIcons or #ws.wins == 0 then return nil end
  local children = {}
  -- keep the icon inside the pill interior (pill side minus padding)
  local iconPx = math.max(10, math.min(appIconSize, baseSize() - 4))
  local n = #ws.wins
  if appIconsMax > 0 and n > appIconsMax then n = appIconsMax end
  for i = 1, n do
    local win = ws.wins[i]
    local path = appIconPath(win.class, iconPx * 2)
    if path then
      children[#children + 1] = ui.image({
        key = "ic" .. i,
        path = path,
        width = iconPx,
        height = iconPx,
        fit = "contain",
      })
    else
      -- fallback: initial letter of the window class
      children[#children + 1] = ui.label({
        key = "ic" .. i,
        text = (win.class ~= "" and win.class:sub(1, 1):upper()) or "?",
        fontSize = math.max(8, appIconSize - 5),
        color = "on_surface_variant",
      })
    end
  end
  if n < #ws.wins then
    children[#children + 1] = ui.label({
      key = "more",
      text = "+" .. (#ws.wins - n),
      fontSize = math.max(8, appIconSize - 5),
      color = "on_surface_variant",
    })
  end
  return children
end

-- resolved palette hexes (refreshed periodically) so hover can cross-fade
-- smoothly between real colors; role tokens can't be interpolated
local pal = nil
local palClock = 0
local palLogged = false
local COLORS_JSON = noctalia.expandPath("~/.config/noctalia/colors.json")

local ROLE_TO_PAL = {
  primary = "primary",
  secondary = "secondary",
  tertiary = "tertiary",
  error = "error",
  surface = "surface",
  surface_variant = "surface_variant",
  outline = "outline",
  hover = "hover",
}

local function loadPalette(now)
  -- nowSec() is CPU time here, so gate on wall clock via os.time()
  if pal and os.time() - palClock < 5 then return end
  palClock = os.time()
  palClock = now
  noctalia.readFileAsync(COLORS_JSON, function(contents)
    local data = contents and noctalia.json.decode(contents)
    if type(data) == "table" then
      local function hexof(v)
        if type(v) == "table" then v = v.hex or v[1] end
        if type(v) == "string" and v:match("^#%x%x%x%x%x%x") then return v:sub(1, 7) end
        return nil
      end
      pal = {
        primary = hexof(data.mPrimary),
        secondary = hexof(data.mSecondary),
        tertiary = hexof(data.mTertiary),
        error = hexof(data.mError),
        surface = hexof(data.mSurface),
        surface_variant = hexof(data.mSurfaceVariant),
        outline = hexof(data.mOutline),
        hover = hexof(data.mHover),
        on_primary = hexof(data.mOnPrimary) or "#101010",
        on_surface_variant = hexof(data.mOnSurfaceVariant),
      }
    end
    if not pal and not palLogged then
      palLogged = true
      noctalia.log("hyprspaces: palette load failed from " .. COLORS_JSON)
    end
  end)
end

local function hexToRgb(h)
  local r, g, b = tostring(h):match("^#(%x%x)(%x%x)(%x%x)$")
  if not r then return nil end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function hexBlend(a, b, t)
  local ar, ag, ab = hexToRgb(a)
  local br, bg, bb = hexToRgb(b)
  if not ar or not br then return nil end
  local function mix(x, y) return math.floor(x + (y - x) * t + 0.5) end
  return string.format("#%02x%02x%02x", mix(ar, br), mix(ag, bg), mix(ab, bb))
end

-- resolve a color setting (role token or hex) to hex via the palette
local function resolveHex(token)
  if type(token) ~= "string" then return nil end
  if token:match("^#") then return token:sub(1, 7) end
  local key = ROLE_TO_PAL[token]
  if key and pal then return pal[key] end
  return nil
end

local function baseFillHex(ws)
  if ws.isUrgent then return resolveHex(urgentColor) end
  if ws.isFocused or ws.isActive then return resolveHex(focusedColor) end
  return pal and pal.surface_variant or nil
end

local function advanceHoverAnims(now)
  local active = false
  for key, anim in pairs(hoverAnim) do
    if anim.target ~= anim.v then
      if now >= anim.at then
        local fade = anim.target > anim.v and HOVER_FADE or HOVER_FADE_OUT
        local step = 0.016 / fade
        if anim.target > anim.v then
          anim.v = math.min(anim.target, anim.v + step)
        else
          anim.v = math.max(anim.target, anim.v - step)
        end
      end
      active = true
    end
  end
  return active
end

local function buildPill(ws, now)
  local key = "ws" .. tostring(ws.id)
  local fill = "surface_variant" -- fallback token when palette hexes aren't loaded yet
  local isActivePill = ws.isFocused or ws.isActive or ws.isUrgent
  local anim = hoverAnim[key]
  local glow = (changeColorOnHover and anim and not isActivePill) and anim.v or 0

  local expanded = style == "show_always" or ws.isActive
  -- height is always one compact "square"; active/inactive pill size only
  -- widens the pill via horizontal padding (like the built-in widget)
  local side = baseSize()
  local padH = math.max(4, math.floor(side * 0.28 * (expanded and activePillSize / 2.2 or inactivePillSize) + 0.5))
  if style == "minimal" then padH = math.max(3, math.floor(side * 0.22)) end

  -- content
  -- smooth fill: blend base hex toward the focused color by glow amount
  local fillToken = fill
  local baseHex = baseFillHex(ws)
  local glowHex = resolveHex(focusedColor)
  if glow > 0.003 and baseHex and glowHex then
    fillToken = hexBlend(baseHex, glowHex, glow * HOVER_MAX_ALPHA) or fill
  elseif baseHex then
    fillToken = baseHex
  end

  local children = {}
  local label = labelFor(ws)
  if label ~= "" and shouldShowLabel(ws) then
    -- digit color follows the ACTUAL fill: on bright fills use near-black,
    -- on dark fills near-white, chosen by luminance with a smooth crossover
    local txtHex = nil
    if type(fillToken) == "string" and fillToken:sub(1, 1) == "#" then
      local r, g, b = hexToRgb(fillToken)
      if r then
        local lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255
        -- 0 at dark -> 1 at bright, eased around the crossover point
        local bright = ease(clamp((lum - 0.45) / 0.2, 0, 1))
        txtHex = hexBlend("#f2f2f2", "#141414", bright)
      end
    end
    children[#children + 1] = ui.label({
      key = key .. "-label",
      text = label,
      fontSize = math.max(10, appIconSize - 3),
      fontWeight = ws.isActive and "bold" or "medium",
      color = txtHex or textColorFor(fillToken),
    })
  end

  local icons = iconsRow(ws)
  if icons then
    children[#children + 1] = ui.row({
      key = key .. "-icons",
      gap = 2,
      align = "center",
    }, icons)
  end
  if #children == 0 then
    children[1] = ui.spacer({ width = 1, height = 1 })
  end

  return ui.row({
    key = key,
    minHeight = side,
    minWidth = side,
    paddingH = padH,
    paddingV = 2,
    gap = 6,
    align = "center",
    justify = "center",
    radius = capsuleRadius,
    fill = fillToken,
    onClick = function() switchTo(ws.id) end,
    onHover = onPillHover,
  }, children)
end

local function buildDot(ws)
  local key = "ws" .. tostring(ws.id)
  local d = math.max(4, math.floor(baseSize() * 0.28 + 0.5))
  return ui.box({
    key = key,
    width = d,
    height = d,
    radius = math.floor(d / 2),
    fill = baseFillHex(ws) or "surface_variant",
    onClick = function() switchTo(ws.id) end,
    onHover = onPillHover,
  })
end

local function render(now)
  local visible = {}
  for _, ws in ipairs(wsList) do
    if not (hideWhenEmpty and not ws.isOccupied and not ws.isFocused) then
      visible[#visible + 1] = ws
    end
  end

  if #visible == 0 then
    barWidget.setVisible(false)
    return
  end
  barWidget.setVisible(true)

  local children = {}
  for _, ws in ipairs(visible) do
    if style == "focus_hint" and not ws.isFocused then
      children[#children + 1] = buildDot(ws)
    else
      children[#children + 1] = buildPill(ws, now)
    end
  end

  local vertical = barWidget.isVertical()
  local rootCtor = vertical and ui.column or ui.row
  barWidget.render(rootCtor({ key = "root", gap = 4, align = "center" }, children))
end

-- ===== entry points =====
noctalia.setUpdateInterval(16)

function update()
  local now = nowSec()
  barOutput = barWidget.outputName()
  loadPalette(now)


  -- watchdog: a lost hyprctl callback would freeze data forever
  if fetching > 0 and now - lastPoll > 2 then
    fetching = 0
  end

  startHelper()
  checkEvents()
  -- fast path: compositor events reset lastPoll, so this fires immediately;
  -- slow path: regular refresh at least every 0.5s
  if now - lastPoll >= 0.5 then
    poll()
  end

  local animating = advanceHoverAnims(now)
  if dirty or animating then
    dirty = false
    render(now)
  end
end

function onConfigChanged()
  dirty = true
end
