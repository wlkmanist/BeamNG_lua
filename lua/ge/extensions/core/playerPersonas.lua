-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local personas = {}
local revision = 0
local commonVehiclePaints

local iconPool = {
  "explosion",
  "hingeBroken",
  "drag01",
  "trafficCone",
  "engine",
  "mirrorInteriorMiddle",
  "doorFrontDetached",
  "vehicleTrunk",
  "carCrash",
  "barrelKnocker01",
  "bollard",
  "drift01",
  "hazardLights",
  "N2OHoriz",
  "rangeboxHi",
  "rallyHelmet",
  "road",
  "tire3Fourth",
  "tireDeflated",
}

local iconLookup = {}
for _, icon in ipairs(iconPool) do iconLookup[icon] = true end

local function oklch(l, c, h)
  local a, b = c * math.cos(math.rad(h)), c * math.sin(math.rad(h))
  local l1 = l + 0.3963377774 * a + 0.2158037573 * b
  local m1 = l - 0.1055613458 * a - 0.0638541728 * b
  local s1 = l - 0.0894841775 * a - 1.2914855480 * b
  local l2, m2, s2 = l1 * l1 * l1, m1 * m1 * m1, s1 * s1 * s1
  local r = 4.0767416621 * l2 - 3.3077115913 * m2 + 0.2309699292 * s2
  local g = -1.2684380046 * l2 + 2.6097574011 * m2 - 0.3413193965 * s2
  local blue = -0.0041960863 * l2 - 0.7034186147 * m2 + 1.7076147010 * s2
  local function srgb(value)
    value = value <= 0.0031308 and 12.92 * value or 1.055 * value ^ (1 / 2.4) - 0.055
    return math.max(0, math.min(1, value))
  end
  return {srgb(r), srgb(g), srgb(blue)}
end

local palette = {
  oklch(61.97/100, 0.2194, 30.58),  -- bng-add-red-500
  oklch(61.98/100, 0.1940, 264.13), -- bng-add-indigoblue-500
  oklch(62.09/100, 0.1266, 153.22), -- bng-add-green-500
  oklch(69.54/100, 0.1351, 99.90),  -- bng-ter-yellow-400
  oklch(62.00/100, 0.17,   293),    -- custom purple
  oklch(65.0/100,  0.17,   43.49),  -- custom orange
  oklch(60.50/100, 0.2300, 337.5),  -- custom magenta/pink
  oklch(68.50/100, 0.1050, 204.5),  -- custom babyblue
}
local function defaultColor(personaNumber)
  return palette[(personaNumber - 1) % #palette + 1]
end

local soloColor = {0.37, 0.37, 0.39}

local function channel(value)
  value = math.floor((value or 0) * 255 + 0.5)
  return math.max(0, math.min(255, value))
end

local function colorHex(color)
  return string.format("#%02x%02x%02x", channel(color[1]), channel(color[2]), channel(color[3]))
end

local function getVehicleFallbackPaint(color)
  if type(color) ~= "table" then return nil end
  if commonVehiclePaints == nil then
    local library = jsonReadFile("/vehicles/common/paintLibraries/common.paintLibrary.json")
    commonVehiclePaints = type(library) == "table" and type(library.paints) == "table" and library.paints or false
  end
  if not commonVehiclePaints then return nil end

  local closestPaint
  local closestDistance = math.huge
  for _, paint in pairs(commonVehiclePaints) do
    local baseColor = paint.baseColor
    if type(baseColor) == "table" then
      local red = baseColor[1] - color[1]
      local green = baseColor[2] - color[2]
      local blue = baseColor[3] - color[3]
      local distance = red * red + green * green + blue * blue
      if distance < closestDistance then
        closestPaint = paint
        closestDistance = distance
      end
    end
  end
  return deepcopy(closestPaint)
end

-- the offset is picked once so icons stay stable for the session, but differ between sessions
local iconOffset = math.random(#iconPool) - 1

local function getDefaultDisplayName(personaNumber)
  if core_locales and core_locales.contextTranslate then
    return core_locales.contextTranslate("ui.multiseat.playerTag", {number = personaNumber})
  end
  return "Player " .. personaNumber
end

-- personas walk the pool one step at a time, so their default icons never collide
local function getDefaultIcon(personaNumber)
  return iconPool[(math.floor(personaNumber - 1 + iconOffset) % #iconPool) + 1]
end

local function build(personaNumber, data)
  data = data or {}
  local color = data.color or defaultColor(personaNumber)
  color = {color[1], color[2], color[3]}
  return {
    id = data.id or ("local-persona:" .. personaNumber),
    number = personaNumber,
    displayName = data.displayName or getDefaultDisplayName(personaNumber),
    icon = data.icon or getDefaultIcon(personaNumber),
    color = color,
    colorHex = colorHex(color),
    vehicleFallbackPaint = getVehicleFallbackPaint(color),
    vehicle = deepcopy(data.vehicle),
  }
end

local function get(personaNumber)
  personaNumber = tonumber(personaNumber)
  if personaNumber == nil or personaNumber < 1 then return nil end
  return build(personaNumber, personas[personaNumber])
end

local function applySoloColor(persona)
  if type(persona) ~= "table" then return persona end
  persona.color = {soloColor[1], soloColor[2], soloColor[3]}
  persona.colorHex = colorHex(persona.color)
  persona.vehicleFallbackPaint = getVehicleFallbackPaint(persona.color)
  return persona
end

local function getNumberForPlayer(player)
  player = tonumber(player)
  if player == nil or player < 0 or player % 1 ~= 0 then return nil end
  return player + 1
end

local function set(personaNumber, data)
  personaNumber = tonumber(personaNumber)
  if personaNumber == nil or personaNumber < 1 or type(data) ~= "table" then return false end

  local displayName = data.displayName
  if displayName == getDefaultDisplayName(personaNumber) then displayName = nil end
  personas[personaNumber] = {
    id = data.id,
    displayName = displayName,
    icon = data.icon,
    color = type(data.color) == "table" and {data.color[1], data.color[2], data.color[3]} or nil,
    vehicle = deepcopy(data.vehicle),
  }
  revision = revision + 1
  return true
end

local function clear(personaNumber)
  personaNumber = tonumber(personaNumber)
  if personaNumber == nil or personas[personaNumber] == nil then return false end
  personas[personaNumber] = nil
  revision = revision + 1
  return true
end

local function clearAll()
  if not next(personas) then return false end
  for personaNumber in pairs(personas) do personas[personaNumber] = nil end
  revision = revision + 1
  return true
end

local function invalidate()
  revision = revision + 1
end

local function snapshot()
  return {
    personas = deepcopy(personas),
    revision = revision,
  }
end

local function replaceAll(values)
  if type(values) ~= "table" then return false end
  local replacement = {}
  for key, data in pairs(values) do
    local personaNumber = tonumber(type(data) == "table" and data.number or key)
    if personaNumber and personaNumber >= 1 and type(data) == "table" then
      local displayName = data.displayName
      if displayName == getDefaultDisplayName(personaNumber) then displayName = nil end
      replacement[personaNumber] = {
        id = data.id,
        displayName = displayName,
        icon = data.icon,
        color = type(data.color) == "table" and {data.color[1], data.color[2], data.color[3]} or nil,
        vehicle = deepcopy(data.vehicle),
      }
    end
  end
  personas = replacement
  revision = revision + 1
  return true
end

local function restoreSnapshot(value)
  if type(value) ~= "table" or type(value.personas) ~= "table" then return false end
  personas = deepcopy(value.personas)
  revision = revision + 1
  return true
end

M.get = get
M.applySoloColor = applySoloColor
M.getNumberForPlayer = getNumberForPlayer
M.getDefaultDisplayName = getDefaultDisplayName
M.preview = function(personaNumber) return build(tonumber(personaNumber) or 1) end
M.getDefaultIcon = getDefaultIcon
M.getIconPool = function() return deepcopy(iconPool) end
M.isPersonaIcon = function(icon) return iconLookup[icon] == true end
M.set = set
M.clear = clear
M.clearAll = clearAll
M.getRevision = function() return revision end
M.invalidate = invalidate
M.snapshot = snapshot
M.replaceAll = replaceAll
M.restoreSnapshot = restoreSnapshot

return M
