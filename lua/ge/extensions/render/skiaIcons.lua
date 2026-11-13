-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Skia world icons: a pooled, data-driven replacement for the atlas icons of the C++
-- BeamNGWorldIconsRenderer (gameplay_playmodeMarkers.getIconRendererObj).
--
-- Everything is drawn from the bngIcons font - no SVG files, no shape templates. An icon is
-- four glyph layers, bottom to top:
--   <shape>Back    the outline silhouette, in borderColor
--   <shape>Front   the fill sitting inside it, in the icon's colour
--   motive rim     the motive repeated around the compass in the icon's colour
--   motive         the motive itself, in borderColor
-- The rim exists because the renderer cannot stroke a text node, so an outline has to be
-- faked by offset copies underneath. It costs 8 extra draws, once, when the texture is baked.
--
-- Icons render as camera-facing Skia billboards (WorldBillboardRenderer, the same path
-- render_playerTags uses). Rasterizing one is expensive but moving and scaling it is nearly
-- free, so identical-looking icons share a pool: releasing an icon parks its billboard and
-- the next request for that look hands it back instead of building another texture.
--
--   local icon = render_skiaIcons.getIcon("mission", pos)  -- a *.skiaIcon.json preset
--   local icon = render_skiaIcons.getIcon({shape = "circle", motive = "fuelPump", color = "blue"})
--   icon:setVisible(shown)                                 -- fades, no per-caller smoother
--   icon:update(pos, worldHeight, dt)                      -- the per-frame call
--   icon:release()                                         -- park it back in the pool
--
-- Spec fields, all optional: shape, motive, text, motiveScale, motiveOffset, outline, color,
-- borderColor, motiveColor, plus `preset` to start from a *.skiaIcon.json entry. `text` is a
-- short label ("3", "9+") that takes the motive's place, for markers that stack. `outline`
-- is measured in motive-font units per 24, so the default 1.5 is always 1.5/24 of its size.
--
-- Sizing: `worldHeight` is a plain world height in metres. For distance-aware sizing that
-- stays readable far away without swamping the view up close, run it through
-- screenBoundedScale first.
--
-- Visibility: the billboard API carries no alpha yet, so an icon fades by scaling between
-- full size and nothing. Callers only hand over the on/off target and a dt - the fade
-- smoother lives on the icon, so nobody has to keep one per marker.

require("utils") -- newTemporalSmoothingNonLinear

local M = {}

local GLYPH_SOURCE = "ui/ui-vue/src/assets/fonts/bngIcons/bngIcons.js"
local CONFIG_SOURCE = "ui/ui-vue/src/assets/fonts/bngIcons/iconMarkerConfig.json"
local PRESET_DIR   = "/art/skiaIcons/"
local RENDERER_NAME = "skiaIconBillboards"

-- Shared with BngIconMarker.vue so browser and world markers use one visual contract.
local FONT, TEXT_BASELINE, SHAPES, SHAPE_SIZE, MARGIN
local MOTIVE_INK_WIDTH, MOTIVE_INK_CENTER
local LABEL_FONT, LABEL_BASELINE, LABEL_CHAR_WIDTH, LABEL_CAP_HEIGHT, LABEL_INK_CENTER
local OUTLINE_EM_SIZE, MAX_OUTLINE, DEFAULT_OUTLINE, DEFAULT_SHAPE, DEFAULT_COLOR, DEFAULT_BORDER_COLOR
local COLORS, RIM_DIRECTIONS

local function loadConfig()
  local data = jsonReadFile(CONFIG_SOURCE)
  if type(data) ~= "table" or type(data.font) ~= "table" or type(data.label) ~= "table"
    or type(data.motive) ~= "table" or type(data.defaults) ~= "table"
    or type(data.shapes) ~= "table" or type(data.colors) ~= "table"
    or type(data.rimDirections) ~= "table" then
    log("E", "skiaIcons", "cannot read icon marker config: " .. CONFIG_SOURCE)
    return false
  end

  FONT                = data.font.path
  TEXT_BASELINE       = data.font.baseline
  SHAPES              = data.shapes
  SHAPE_SIZE          = data.shapeSize
  MARGIN              = data.margin
  MOTIVE_INK_WIDTH    = data.motive.inkWidth
  MOTIVE_INK_CENTER   = data.motive.inkCenter
  LABEL_FONT          = data.label.path
  LABEL_BASELINE      = data.label.baseline
  LABEL_CHAR_WIDTH    = data.label.charWidth
  LABEL_CAP_HEIGHT    = data.label.capHeight
  LABEL_INK_CENTER    = data.label.inkCenter
  OUTLINE_EM_SIZE     = data.outlineEmSize
  MAX_OUTLINE         = data.maxOutline
  DEFAULT_OUTLINE     = data.defaults.outline
  DEFAULT_SHAPE       = data.defaults.shape
  DEFAULT_COLOR       = data.defaults.color
  DEFAULT_BORDER_COLOR = data.defaults.borderColor
  COLORS              = data.colors
  RIM_DIRECTIONS      = data.rimDirections
  return true
end

if not loadConfig() then error("skiaIcons requires " .. CONFIG_SOURCE) end

local MIN_VISIBLE_SCALE = 0.005
local DEFAULT_SCALE     = 1     -- world height in metres
local MAX_POOLED        = 192   -- parked billboards kept before released ones are destroyed
local DEFAULT_FOV       = math.rad(65) -- fallback when no camera context can be read
local VISIBILITY_RATE   = 20    -- fade smoothing, high enough to read as a quick pop
local FADE_SETTLE       = 0.002 -- snap the fade onto its target below this difference

local renderer                 -- the live WorldBillboardRenderer, or nil
local renderGen  = 0           -- bumped whenever the renderer is (re)created; every id from
                               -- an older generation died with the object that handed it out
local lookGen    = 0           -- bumped by reload() so live icons rebuild from the new files
local glyphs                   -- icon name -> glyph character, nil until loaded
local motiveNames              -- sorted list of every glyph name, nil until asked for
local presets                  -- preset name -> spec, nil until loaded
local looks      = {}          -- signature -> look (false when it cannot be built)
local pooledCount = 0
local liveCount   = 0
local stats = { created = 0, reused = 0, destroyed = 0 }

local hidePos       = vec3()
local updateScratch = vec3()

local function skiaTemplate()
  if not extensions.core_skiaTemplate then extensions.load("core_skiaTemplate") end
  return extensions.core_skiaTemplate
end

-- bngIcons.js is generated, and its `icons` object is strict JSON wrapped in Object.freeze(),
-- so one balanced-brace match gives the whole name -> glyph table. Beats reading a thousand
-- SVG files, and the font is the same source the UI renders these icons from.
local function loadGlyphs()
  if glyphs then return glyphs end
  local src = readFile(GLYPH_SOURCE)
  local body = type(src) == "string" and src:match("Object%.freeze%((%b{})%)") or nil
  local data = body and jsonDecode(body) or nil
  if type(data) ~= "table" then
    log("E", "skiaIcons", "cannot read the icon font table: " .. GLYPH_SOURCE)
    return nil
  end
  glyphs = {}
  for name, entry in pairs(data) do
    if type(entry) == "table" and type(entry.glyph) == "string" then glyphs[name] = entry.glyph end
  end
  return glyphs
end

-- The renderer lives in MissionGroup, so it goes away with the scene and takes every
-- billboard id with it. Bumping the generation on a fresh object is what makes live icons
-- notice their id is stale and rebuild. Called once per icon per frame, so the handle is
-- cached and only re-resolved when it is gone (sceneGone drops it when the scene unloads).
local function getRenderer()
  if renderer and renderer.create then return renderer end
  local live = scenetree and scenetree[RENDERER_NAME]
  if live then
    renderer = live
    return live
  end
  if not (WorldBillboardRenderer and scenetree and scenetree.MissionGroup) then
    renderer = nil
    return nil
  end
  local r = WorldBillboardRenderer()
  if not r then
    renderer = nil
    return nil
  end
  r:registerObject(RENDERER_NAME)
  scenetree.MissionGroup:addObject(r)
  renderer = r
  renderGen = renderGen + 1
  for _, look in pairs(looks) do
    if look then table.clear(look.free) end
  end
  pooledCount = 0
  return r
end

local function color(value, default)
  if type(value) ~= "string" or value == "" then return default end
  return COLORS[value] or value
end

local function loadPresets()
  if presets then return presets end
  presets = {}
  for _, path in ipairs(FS:findFiles(PRESET_DIR, "*.skiaIcon.json", -1, true, false) or {}) do
    local data = jsonReadFile(path:gsub("\\", "/"))
    if type(data) == "table" and type(data.presets) == "table" then
      for name, spec in pairs(data.presets) do
        if type(spec) == "table" then presets[name] = spec end
      end
    else
      log("W", "skiaIcons", "no 'presets' table in " .. tostring(path))
    end
  end
  return presets
end

-- Fill a spec's gaps from its preset (when it names one) and then from the defaults, so
-- callers can pass a bare preset name, a full spec, or a preset plus a few overrides.
local function resolveSpec(spec)
  if type(spec) == "string" then spec = { preset = spec } end
  if type(spec) ~= "table" then spec = {} end
  local base
  if spec.preset then
    base = loadPresets()[spec.preset]
    if not base then log("W", "skiaIcons", "unknown preset: " .. tostring(spec.preset)) end
  end
  local function pick(key, default)
    local v = spec[key]
    if v == nil and base then v = base[key] end
    if v == nil then v = default end
    return v
  end
  local shape = tostring(pick("shape", DEFAULT_SHAPE))
  if not SHAPES[shape] then
    log("W", "skiaIcons", "unknown shape '" .. shape .. "', using " .. DEFAULT_SHAPE)
    shape = DEFAULT_SHAPE
  end
  local motive = pick("motive", nil)
  if motive == "" then motive = nil end -- so a cleared motive shares one look, not two
  local text = pick("text", nil)
  if text ~= nil then
    text = tostring(text)
    if text == "" then text = nil end
  end
  -- A label hides the motive, so forget it here too: otherwise two clusters showing the same
  -- count would sign differently and each bake its own identical texture.
  if text then motive = nil end
  -- Size and nudge default per shape, since each one presents a different amount of room, and
  -- a label takes the label nudge rather than the motive one. An explicit value still wins.
  local def = SHAPES[shape]
  local defScale = def.motiveScale or 1
  local defOffset = (text and def.labelOffset or def.motiveOffset) or 0
  -- These three are quantised to the precision the signature carries, so float noise cannot
  -- ask for a look the pool would key differently than it was built.
  local q = function(v) return math.floor(v * 100 + 0.5) / 100 end
  local border = color(pick("borderColor", DEFAULT_BORDER_COLOR), COLORS[DEFAULT_BORDER_COLOR])
  return {
    shape        = shape,
    motive       = motive,
    text         = text, -- takes the motive's place when set
    motiveOffset = q(tonumber(pick("motiveOffset", defOffset)) or defOffset),
    motiveScale  = math.max(0.05, q(tonumber(pick("motiveScale", defScale)) or defScale)),
    outline      = math.min(MAX_OUTLINE, math.max(0, q(tonumber(pick("outline", DEFAULT_OUTLINE)) or DEFAULT_OUTLINE))),
    color        = color(pick("color", DEFAULT_COLOR), COLORS[DEFAULT_COLOR]),
    borderColor  = border,
    -- the motive reads as part of the outline, so it follows the border unless overridden
    motiveColor  = color(pick("motiveColor", nil), border),
  }
end

local function signature(s)
  return string.format("%s|%s|%s|%.2f|%.2f|%.2f|%s|%s|%s", s.shape, s.motive or "-", s.text or "-",
    s.motiveOffset, s.motiveScale, s.outline, s.color, s.borderColor, s.motiveColor)
end

local function buildLook(spec)
  local shape = SHAPES[spec.shape]
  local glyphTable = loadGlyphs()
  local st = skiaTemplate()
  if not (shape and glyphTable and st) then return nil end
  local backGlyph, frontGlyph = glyphTable[shape.back], glyphTable[shape.front]
  if not (backGlyph and frontGlyph) then
    log("E", "skiaIcons", "shape glyphs missing from the font: " .. shape.back .. " / " .. shape.front)
    return nil
  end

  local baseline = TEXT_BASELINE * SHAPE_SIZE
  local tipY = baseline - shape.bottom * SHAPE_SIZE -- bottom is negative, so this is below it
  local canvasW = math.ceil(shape.width * SHAPE_SIZE) + 2 * MARGIN
  local canvasH = math.ceil(tipY) + MARGIN
  local children = {}

  -- Every layer is a one-em text box, which keeps the baseline placement predictable and
  -- makes the layers register with each other whatever their size.
  local function layer(glyph, size, col, baseY, dx, dy)
    children[#children + 1] = {
      type = "text", text = glyph, font = FONT, fontSize = size, color = col, textAlign = "left",
      style = {
        position = "absolute",
        left = (canvasW - size) * 0.5 + (dx or 0),
        top = baseY - TEXT_BASELINE * size + (dy or 0),
        width = size, height = size,
      },
    }
  end

  layer(backGlyph, SHAPE_SIZE, spec.borderColor, baseline) -- outline, lowest layer
  layer(frontGlyph, SHAPE_SIZE, spec.color, baseline)      -- fill on top of it

  -- A short label wins over a motive glyph: markers use it to show a count when several
  -- different things stack on one spot. It gets centred by a flex box rather than by its
  -- advance width, and uses Overpass' own baseline rather than the icon font's.
  local function labelLayer(size, col, baseY, dx, dy)
    local box = size * 2 -- roomy enough for any one or two character label at this size
    children[#children + 1] = {
      type = "group",
      style = {
        position = "absolute",
        left = (canvasW - box) * 0.5 + (dx or 0),
        top = baseY - LABEL_BASELINE * size + (dy or 0),
        width = box, height = size, justifyContent = "center",
      },
      children = { { type = "text", text = spec.text, font = LABEL_FONT, fontSize = size,
                     color = col, style = { height = size } } },
    }
  end

  local motiveGlyph = spec.motive and glyphTable[spec.motive] or nil
  if spec.motive and not motiveGlyph then
    log("W", "skiaIcons", "motive not in the font: " .. tostring(spec.motive))
  end
  if motiveGlyph or spec.text then
    -- Fit the content plus its rim into the shape's inscribed square, then put its baseline
    -- where the content's ink centres on that square's centre.
    local room = math.max(1, shape.motiveInk * SHAPE_SIZE)
    local outlineRatio = spec.outline / OUTLINE_EM_SIZE
    local motiveSize, inkCenter
    if spec.text then
      -- Sized off the character count so a one and a two character label both fill the
      -- square: width binds for the longer one, cap height for the shorter. Scaling only ever
      -- shrinks it, because the per-shape motiveScale is tuned for glyph ink and a label
      -- already reaches the edges of the room a glyph leaves spare.
      local chars = math.max(1, #spec.text)
      local contentWidth = math.max(chars * LABEL_CHAR_WIDTH, LABEL_CAP_HEIGHT)
      local scale = math.min(1, spec.motiveScale)
      motiveSize = room * scale / (contentWidth + 2 * outlineRatio * scale)
      inkCenter = LABEL_INK_CENTER
    else
      motiveSize = room * spec.motiveScale / (MOTIVE_INK_WIDTH + 2 * outlineRatio * spec.motiveScale)
      inkCenter = MOTIVE_INK_CENTER
    end
    local outlineWidth = motiveSize * outlineRatio
    local centerY = baseline - shape.motiveCenter * SHAPE_SIZE
    local motiveBaseline = centerY + inkCenter * motiveSize + spec.motiveOffset
    local emit = spec.text and labelLayer or function(size, col, baseY, dx, dy)
      layer(motiveGlyph, size, col, baseY, dx, dy)
    end

    if spec.outline > 0 then
      for _, dir in ipairs(RIM_DIRECTIONS) do
        emit(motiveSize, spec.color, motiveBaseline, dir[1] * outlineWidth, dir[2] * outlineWidth)
      end
    end
    emit(motiveSize, spec.motiveColor, motiveBaseline)
  end

  local resolved = st.resolveTemplate({
    type = "skiaIcon", size = { canvasW, canvasH },
    root = { type = "group", children = children },
  })
  if not resolved then return nil end
  return {
    json = jsonEncode(resolved),
    -- update() centres the canvas on the position it is given, so lift the billboard by this
    -- fraction of its world height to put the pin tip on the caller's position instead.
    anchorLift = (tipY - canvasH * 0.5) / canvasH,
    free = {},
  }
end

local function getLook(spec, sig)
  local look = looks[sig]
  if look == nil then
    look = buildLook(spec) or false
    looks[sig] = look
    if not look then log("E", "skiaIcons", "cannot build icon: " .. sig) end
  end
  return look or nil
end

local Icon = {}
Icon.__index = Icon

-- Make sure this icon owns a billboard of its current look, rebuilding after a reload or
-- after the scene took the renderer down. Returns nil when there is nothing to draw with.
function Icon:sync()
  if self.dead then return nil end
  if self.lookGen ~= lookGen then
    self.lookGen = lookGen
    self.look = getLook(self.spec, self.sig)
    self.id = nil
  end
  local look = self.look
  if not look then return nil end
  local r = getRenderer()
  if not r then
    self.id = nil
    return nil
  end
  if self.id and self.gen == renderGen then return self.id end

  local free = look.free
  local n = #free
  if n > 0 then
    self.id = free[n]
    free[n] = nil
    pooledCount = pooledCount - 1
    stats.reused = stats.reused + 1
  else
    local id = r:create(look.json, false) -- static texture, rasterized once
    if not id or id == 0 then return nil end
    r:render(id, "{}")
    self.id = id
    stats.created = stats.created + 1
  end
  self.gen = renderGen
  return self.id
end

-- The per-frame call. `pos` and `scale` keep their current value when nil; `dt` advances the
-- visibility fade (nil or 0 leaves it where it is).
function Icon:update(pos, scale, dt)
  if scale ~= nil then self.scale = scale end
  if pos ~= nil then self.pos:set(pos) end

  local fade = self.fade:get(self.visible, dt or 0)
  -- The smoother only ever approaches its target, so snap once the rest stops mattering.
  -- That is what lets visibility() be a reliable "still fading" test for callers.
  if math.abs(fade - self.visible) < FADE_SETTLE then
    fade = self.visible
    self.fade:set(fade)
  end

  local scl = self.scale * fade
  local show = scl > MIN_VISIBLE_SCALE
  -- Faded out with no billboard yet: skip building one, so the many markers that never come
  -- into view never cost a texture.
  if not show and not self.id then return self end
  local id = self:sync()
  if not id then return self end

  updateScratch:set(self.pos)
  if show then updateScratch.z = updateScratch.z + scl * self.look.anchorLift end
  renderer:update(id, updateScratch, scl, show)
  return self
end

function Icon:setPos(pos) return self:update(pos, nil, nil) end
function Icon:setScale(scale) return self:update(nil, scale, nil) end

-- Fade the icon in or out. `instant` skips the fade and pushes the result straight away, so
-- it also works for a caller that is about to stop updating this icon (a hidden marker).
function Icon:setVisible(visible, instant)
  self.visible = visible and 1 or 0
  if instant then
    self.fade:set(self.visible)
    return self:update(nil, nil, 0)
  end
  return self
end

-- How far the fade currently is, 0..1, for callers that want to match related visuals to it.
function Icon:visibility() return self.fade:value() end

-- False when this icon has no billboard to draw with: it was released, its look could not be
-- built, or the engine has no billboard renderer.
function Icon:isLive() return not self.dead and self.id ~= nil end

-- Park the billboard so an icon of the same look can pick it up instead of rasterizing a
-- new texture. The handle is spent afterwards; ask for a new one with getIcon.
function Icon:release()
  if self.dead then return end
  self.dead = true
  liveCount = liveCount - 1
  local id, look = self.id, self.look
  self.id = nil
  if not id or self.gen ~= renderGen then return end -- its generation is already gone
  local r = renderer
  if not r then return end
  r:update(id, hidePos, 0, false)
  if pooledCount >= MAX_POOLED then
    pcall(function() r:destroy(id) end)
    stats.destroyed = stats.destroyed + 1
    return
  end
  local free = look.free
  free[#free + 1] = id
  pooledCount = pooledCount + 1
end

-- Hand out an icon for a preset name, a spec table, or a preset plus overrides. `pos` is
-- optional and only decides whether the billboard is built now or on the first update.
local function getIcon(spec, pos)
  local resolved = resolveSpec(spec)
  local sig = signature(resolved)
  local icon = setmetatable({
    spec = resolved,
    sig = sig,
    look = getLook(resolved, sig),
    lookGen = lookGen,
    pos = vec3(),
    scale = DEFAULT_SCALE,
    -- Shown by default so plain callers need no setup; ask for setVisible(false, true)
    -- first when the icon should fade in from nothing.
    visible = 1,
    fade = newTemporalSmoothingNonLinear(VISIBILITY_RATE, VISIBILITY_RATE, 1),
    dead = false,
  }, Icon)
  if not icon.look then
    icon.dead = true
    return icon
  end
  liveCount = liveCount + 1
  if pos then icon:update(pos, nil, nil) end
  return icon
end

-- World height for an icon that behaves like a real object in the mid range but is bounded
-- on screen: it never shrinks below `minScreen` (so a distant marker stays readable) and
-- never grows past `maxScreen` (so a close one does not swamp the view). Both bounds are
-- fractions of the viewport height; equal bounds give a constant on-screen size, which is
-- what the old renderer's mConstantSizeIcons did.
--
--   icon:update(pos, render_skiaIcons.screenBoundedScale(pos, 0.8, 0.03, 0.12), true)
local function screenBoundedScale(pos, worldSize, minScreen, maxScreen)
  if not (pos and core_camera) then return worldSize end
  local cam = core_camera.getPosition()
  if not cam then return worldSize end
  local fov = (core_camera.getFovRad and core_camera.getFovRad()) or DEFAULT_FOV
  -- how tall the viewport is, in world units, at the icon's distance
  local span = 2 * cam:distance(pos) * math.tan(fov * 0.5)
  if span <= 0 then return worldSize end
  local lo = (minScreen or 0) * span
  local hi = (maxScreen or 1) * span
  if hi < lo then hi = lo end
  return math.min(math.max(worldSize, lo), hi)
end

-- Drop everything and re-read the shared config, font table and presets from disk. Deleting the renderer
-- reclaims every texture at once, including the ones live icons still hold; they rebuild
-- from the new data on their next update.
local function reload()
  local configLoaded = loadConfig()
  glyphs, motiveNames, presets = nil, nil, nil
  looks = {}
  pooledCount = 0
  lookGen = lookGen + 1
  local live = scenetree and scenetree[RENDERER_NAME]
  if live then pcall(function() live:delete() end) end
  renderer = nil
  return configLoaded
end

-- Forget the loaded presets so the next getIcon re-reads the *.skiaIcon.json files. Cheap
-- next to reload(): the built looks and their textures are left alone.
local function reloadPresets()
  presets = nil
end

-- The scene (and the renderer inside it) is gone, so every id it handed out is dead.
local function sceneGone()
  renderer = nil
  renderGen = renderGen + 1
  for _, look in pairs(looks) do
    if look then table.clear(look.free) end
  end
  pooledCount = 0
end

local function getMotives()
  if motiveNames then return motiveNames end
  motiveNames = {}
  for name in pairs(loadGlyphs() or {}) do motiveNames[#motiveNames + 1] = name end
  table.sort(motiveNames)
  return motiveNames
end

-- The folders this system reads from, so a tool can show or open them.
local function getFolders()
  return { presets = "/" .. PRESET_DIR:gsub("^/", ""), font = "/" .. FONT:gsub("/[^/]+$", "") }
end

-- Show one of those folders in the OS file browser (dev convenience). Returns the path, or
-- nil when the platform cannot open it.
local function exploreFolder(which)
  local path = getFolders()[which] or which
  if not (type(path) == "string" and Engine and Engine.Platform and Engine.Platform.exploreFolder) then return nil end
  Engine.Platform.exploreFolder(path)
  return path
end

local function getStats()
  local lookCount = 0
  for _, look in pairs(looks) do
    if look then lookCount = lookCount + 1 end
  end
  return {
    live = liveCount, looks = lookCount, pooled = pooledCount,
    created = stats.created, reused = stats.reused, destroyed = stats.destroyed,
    hasRenderer = (scenetree and scenetree[RENDERER_NAME]) ~= nil,
  }
end

-- A renderer left behind by a previous Lua VM still holds billboards we no longer track,
-- so drop it and start clean.
local function onExtensionLoaded()
  local live = scenetree and scenetree[RENDERER_NAME]
  if live then pcall(function() live:delete() end) end
  renderer = nil
end

M.getIcon             = getIcon
M.screenBoundedScale  = screenBoundedScale
M.reload              = reload
M.reloadPresets       = reloadPresets
M.getStats            = getStats
M.getMotives          = getMotives
M.getPresets          = loadPresets
M.getFolders          = getFolders
M.exploreFolder       = exploreFolder
M.getColors           = function() return COLORS end
M.getShapes           = function()
  local out = {}
  for name in pairs(SHAPES) do out[#out + 1] = name end
  table.sort(out)
  return out
end

M.onExtensionLoaded   = onExtensionLoaded
M.onExtensionUnloaded = reload
M.onClientEndMission  = sceneGone

return M
