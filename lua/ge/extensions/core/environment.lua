-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max
local cloudWeatherSeedMax = 2147483647

local M = {}
M.dependencies = {'core_solarTimeOfDay'}

M.groundModels = {}
M.loadedGroundModelFiles = {}

local envObjectIdCache = {}
local environmentChangesEnabled = true
local updatingWholeState = false
local stateLerp = nil

local gm_filename = 'art/groundmodels.json'
local simSpeed = 1
local init_env={}
local myTexture = {}
local tempCurve = {}

local temperatureK = 0.0
local groundWind = vec3()
local sendState

local nightLights = {
  initialized = false,
  lastNight = nil,
  lights = {},
  emissives = {},
  intensityLights = {},
  refreshing = false
}
local editorSaveNightLightsState = nil

local nightLightsNightStart = 0.25
local nightLightsNightEnd = 0.75

local linkedChildFieldName = "child"
local maxLinkedChildFieldsToScan = 256

local function applyGroundWind()
  if not environmentChangesEnabled then return end
  if not be then return end
  be:queueAllObjectLua(string.format("obj:setWind(%f,%f,%f)", groundWind.x, groundWind.y, groundWind.z))
  be:setGroundWind(groundWind)
end

local function getObject(className)
  if envObjectIdCache[className] then
    if envObjectIdCache[className] == 0 then return nil end
    return scenetree.findObjectById(envObjectIdCache[className])
  end
  envObjectIdCache[className] = 0
  local objNames = scenetree.findClassObjects(className)
  if objNames and not tableIsEmpty(objNames) then
    local obj = scenetree.findObject(objNames[1])
    if obj then
      envObjectIdCache[className] = obj:getID()
      return obj
    end
  end
end

local function getSimObjectId(obj)
  if not obj then return nil end

  if obj.getID then
    local ok, id = pcall(obj.getID, obj)
    if ok and id then return id end
  end

  if obj.getId then
    local ok, id = pcall(obj.getId, obj)
    if ok and id then return id end
  end

  return nil
end

local function getObjectFieldStringAt(obj, fieldName, index)
  if not obj or not fieldName then return nil end
  index = index or 0

  if obj.getDynDataFieldbyName then
    local ok, value = pcall(obj.getDynDataFieldbyName, obj, fieldName, index)
    if ok and value ~= nil and tostring(value) ~= "" then
      return tostring(value)
    end
  end

  if obj.getField then
    local ok, value = pcall(obj.getField, obj, fieldName, index)
    if ok and value ~= nil and tostring(value) ~= "" then
      return tostring(value)
    end
  end

  return nil
end

local function getObjectFieldString(obj, fieldName)
  return getObjectFieldStringAt(obj, fieldName, 0)
end

local function getObjectFieldNumber(obj, fieldName)
  local value = getObjectFieldString(obj, fieldName)
  if value == nil then return nil end
  return tonumber(value)
end

local function parseBoolValue(value)
  if value == nil then return nil end
  if type(value) == "boolean" then return value end
  if type(value) == "number" then return value ~= 0 end

  value = string.lower(tostring(value))
  if value == "" then return nil end
  if value == "1" or value == "true" or value == "yes" or value == "on" then return true end
  if value == "0" or value == "false" or value == "no" or value == "off" then return false end
  return nil
end

local function getObjectFieldBool(obj, fieldName)
  if not obj or not fieldName then return nil end

  local direct = parseBoolValue(obj[fieldName])
  if direct ~= nil then return direct end

  return parseBoolValue(getObjectFieldString(obj, fieldName))
end

local function setObjectFieldBool(obj, fieldName, value)
  if not obj or not fieldName then return end

  local bool = value == true
  obj[fieldName] = bool
  if obj.setField then
    pcall(obj.setField, obj, fieldName, 0, bool and "1" or "0")
  end
end

local function getObjectFieldStringAtFast(obj, fieldName, index)
  if not obj or not fieldName then return nil end
  index = index or 0

  if obj.getDynDataFieldbyName then
    local value = obj:getDynDataFieldbyName(fieldName, index)
    if value ~= nil and value ~= "" then return tostring(value) end
  end

  if obj.getField then
    local value = obj:getField(fieldName, index)
    if value ~= nil and value ~= "" then return tostring(value) end
  end
end

local function getObjectFieldNumberFast(obj, fieldName)
  local value = getObjectFieldStringAtFast(obj, fieldName, 0)
  return value and tonumber(value) or nil
end

local function getObjectFieldBoolFast(obj, fieldName)
  if not obj or not fieldName then return nil end

  local direct = parseBoolValue(obj[fieldName])
  if direct ~= nil then return direct end

  return parseBoolValue(getObjectFieldStringAtFast(obj, fieldName, 0))
end

local function parseRgbColor(value, fallback)
  if not value or tostring(value) == "" then
    return fallback
  end

  local nums = {}
  for token in tostring(value):gmatch("[^%s,]+") do
    local n = tonumber(token)
    if n then table.insert(nums, n) end
  end

  if #nums < 3 then
    return fallback
  end

  local scale = 1
  if nums[1] > 1 or nums[2] > 1 or nums[3] > 1 then
    scale = 255
  end

  return {
    min(max(nums[1] / scale, 0), 1),
    min(max(nums[2] / scale, 0), 1),
    min(max(nums[3] / scale, 0), 1)
  }
end

local function getInstanceColorTable(obj)
  if not obj then return {1, 1, 1, 1} end

  if obj.instanceColor and obj.instanceColor.toTable then
    local ok, color = pcall(obj.instanceColor.toTable, obj.instanceColor)
    if ok and color then
      return {
        tonumber(color[1]) or 1,
        tonumber(color[2]) or 1,
        tonumber(color[3]) or 1,
        tonumber(color[4]) or 1
      }
    end
  end

  local field = getObjectFieldString(obj, "instanceColor")
  if field then
    local nums = {}
    for token in field:gmatch("[^%s,]+") do
      local n = tonumber(token)
      if n then table.insert(nums, n) end
    end

    if #nums >= 4 then
      return {nums[1], nums[2], nums[3], nums[4]}
    elseif #nums >= 3 then
      return {nums[1], nums[2], nums[3], 1}
    end
  end

  return {1, 1, 1, 1}
end

local function isLightBaseObject(obj)
  if not obj then return false end

  if obj.isSubClassOf then
    local ok, result = pcall(obj.isSubClassOf, obj, "LightBase")
    if ok and result then return true end
  end

  local className = obj.className or (obj.getClassName and obj:getClassName()) or ""

  return className == "LightBase"
    or className == "PointLight"
    or className == "SpotLight"
end

local function addNightLightUnique(lightObj, seen)
  if not lightObj then return end

  local id = getSimObjectId(lightObj)
  if not id or seen[id] then return end

  seen[id] = true
  table.insert(nightLights.lights, { id = id })
end

local function addIntensityLightUnique(lightObj, seen)
  if not lightObj then return end

  local nightIntensity = getObjectFieldNumberFast(lightObj, "nightIntensity")
  local dayIntensity = getObjectFieldNumberFast(lightObj, "dayIntensity")

  if nightIntensity == nil and dayIntensity == nil then return end

  local id = getSimObjectId(lightObj)
  if not id or seen[id] then return end

  seen[id] = true
  table.insert(nightLights.intensityLights, {
    id = id,
    nightIntensity = nightIntensity,
    dayIntensity = dayIntensity
  })
end

local getLightColorTable

local function addLinkedNightLights(obj, firstChildValue, seen)
  local firstLightId = nil
  local firstLightColor = nil

  for i = 0, maxLinkedChildFieldsToScan - 1 do
    local value = i == 0 and firstChildValue or getObjectFieldStringAtFast(obj, linkedChildFieldName, i)

    if not value or value == "" then break end
    for childName in tostring(value):gmatch("[^,%s]+") do
      local childObj = scenetree.findObject(childName)
      if childObj and isLightBaseObject(childObj) then
        addNightLightUnique(childObj, seen)
        if not firstLightId then
          firstLightId = getSimObjectId(childObj)
          firstLightColor = getLightColorTable(childObj, {1, 1, 1})
        end
      end
    end
  end

  return firstLightId, firstLightColor
end

getLightColorTable = function(lightObj, fallback)
  fallback = fallback or {1, 1, 1}

  if not lightObj then return fallback end

  if lightObj.color and lightObj.color.toTable then
    local ok, color = pcall(lightObj.color.toTable, lightObj.color)
    if ok and color then
      return {
        tonumber(color[1]) or fallback[1] or 1,
        tonumber(color[2]) or fallback[2] or 1,
        tonumber(color[3]) or fallback[3] or 1
      }
    end
  end

  local colorField = getObjectFieldString(lightObj, "color")
  if colorField then
    return parseRgbColor(colorField, fallback)
  end

  return fallback
end

local getTimeOfDay

local function getLevelInfoNumberDynField(fieldName)
  local levelInfo = getObject("LevelInfo") or scenetree.theLevelInfo
  if not levelInfo then return nil end

  local value = getObjectFieldString(levelInfo, fieldName)
  local numberValue = tonumber(value)

  if numberValue == nil then return nil end

  return min(max(numberValue, 0), 1)
end

local function getNightLightsTimeWindow()
  local manualStartTime = getLevelInfoNumberDynField("nightLightsNightStart")
  local manualEndTime = getLevelInfoNumberDynField("nightLightsNightEnd")

  if manualStartTime == nil and manualEndTime == nil then
    local solarStartTime, solarEndTime = core_solarTimeOfDay.getSolarNightWindow(getTimeOfDay())
    if solarStartTime ~= nil and solarEndTime ~= nil then
      return solarStartTime, solarEndTime
    end
  end

  return manualStartTime or nightLightsNightStart, manualEndTime or nightLightsNightEnd
end

local function isNightTime(time)
  if time == nil then return false end

  time = time % 1

  local startTime, endTime = getNightLightsTimeWindow()

  if startTime == endTime then
    return false
  end

  if startTime < endTime then
    return time > startTime and time < endTime
  end

  return time > startTime or time < endTime
end

local function setLightEnabledSafe(lightObj, enabled)
  if not lightObj then return end

  if lightObj.setLightEnabled then
    lightObj:setLightEnabled(enabled)
    return
  end

  if lightObj.obj and lightObj.obj.setLightEnabled then
    lightObj.obj:setLightEnabled(enabled)
    return
  end
end

local function setLightIntensitySafe(lightObj, intensity)
  if not lightObj or intensity == nil then return end

  local ok = pcall(function()
    lightObj.intensity = intensity
  end)
  if not ok then return end

  if lightObj.postApply then
    pcall(lightObj.postApply, lightObj)
  end
end

local function setNightLightsEnabled(night, force)
  if not nightLights.initialized then return end

  if not force and nightLights.lastNight == night then return end

  nightLights.lastNight = night

  for _, data in ipairs(nightLights.lights) do
    local lightObj = scenetree.findObjectById(data.id)
    if lightObj then
      setLightEnabledSafe(lightObj, night)
    end
  end

  for _, data in ipairs(nightLights.intensityLights) do
    local lightObj = scenetree.findObjectById(data.id)
    if lightObj then
      local intensity
      if night then
        intensity = data.nightIntensity
      else
        intensity = data.dayIntensity
      end
      setLightIntensitySafe(lightObj, intensity)
    end
  end

  for _, data in ipairs(nightLights.emissives) do
    local obj = scenetree.findObjectById(data.id)
    if obj then
      local r, g, b
      if night then
        local color = data.color

        if data.sourceLightId then
          local lightObj = scenetree.findObjectById(data.sourceLightId)
          if lightObj then
            color = getLightColorTable(lightObj, color)
          end
        end

        r, g, b = color[1], color[2], color[3]
      else
        r, g, b = 0, 0, 0
      end

      local currentColor = getInstanceColorTable(obj)
      local alpha = tonumber(currentColor[4]) or data.alpha or 1

      obj:setField(
        "instanceColor",
        0,
        string.format("%f %f %f %f", r, g, b, alpha)
      )

      if obj.updateInstanceRenderData then
        obj:updateInstanceRenderData()
      end
    end
  end
end

local function applynightLightsState(time, force)
  setNightLightsEnabled(isNightTime(time), force)
end

local timeOfDay = {}
local timeOfDayStateFields = {
  "time",
  "play",
  "dayLength",
  "startTime",
  "latitude",
  "longitude",
  "year",
  "month",
  "day",
  "utcOffset",
  "dstRule",
  "celestialProfile",
}

local function hasTimeOfDayState(state)
  if type(state) ~= "table" then return false end
  for _, key in ipairs(timeOfDayStateFields) do
    if state[key] ~= nil then return true end
  end
  return false
end

getTimeOfDay = function()
  local timeObj = getObject("TimeOfDay")
  if timeObj then
    timeOfDay.time = timeObj.time
    local play = getObjectFieldBool(timeObj, "play")
    if play == nil then play = getObjectFieldBool(timeObj, "animate") end
    timeOfDay.play = play == true
    timeOfDay.dayLength = timeObj.dayLength
    timeOfDay.startTime = timeObj.startTime
    -- observer location + UTC date for the real astronomical sky (stars/moon)
    timeOfDay.latitude = timeObj.latitude
    timeOfDay.longitude = timeObj.longitude
    timeOfDay.year = timeObj.year
    timeOfDay.month = timeObj.month
    timeOfDay.day = timeObj.day
    timeOfDay.utcOffset = timeObj.utcOffset and tonumber(timeObj.utcOffset) or nil
    timeOfDay.dstRule = timeObj.dstRule
    timeOfDay.celestialProfile = timeObj.celestialProfile
    return timeOfDay
  end
end

-- Current world lighting state, for callers that need to know whether it is day
-- or night (e.g. to react when the auto night-lights switch on/off). Extensible:
-- switch on `phase` rather than only the boolean, so more phases can be added.
--   { time, phase = 'day'|'night', isNight, nightLightsActive, nightStart, nightEnd }
-- Returns nil when there is no TimeOfDay (e.g. main menu), like getTimeOfDay().
local function getLightState()
  local tod = getTimeOfDay()
  if not tod or tod.time == nil then return nil end

  local startTime, endTime = getNightLightsTimeWindow()
  local night = isNightTime(tod.time)

  return {
    time = tod.time,
    phase = night and "night" or "day",
    isNight = night,
    nightLightsActive = nightLights.lastNight == true, -- what the engine actually applied
    nightStart = startTime,
    nightEnd = endTime,
  }
end


local function refreshnightLightsObjects()
  if nightLights.refreshing then return end

  nightLights.refreshing = true
  nightLights.initialized = false
  nightLights.lastNight = nil
  nightLights.lights = {}
  nightLights.emissives = {}
  nightLights.intensityLights = {}

  local registeredLightIds = {}
  local registeredIntensityLightIds = {}

  local lightNames
  if scenetree.findSubClassObjects then
    lightNames = scenetree.findSubClassObjects("LightBase")
  else
    lightNames = scenetree.findClassObjects("LightBase")
  end

  if lightNames then
    for _, name in ipairs(lightNames) do
      local obj = scenetree.findObject(name)
      if obj then
        if getObjectFieldBoolFast(obj, "nightLight") == true then
          addNightLightUnique(obj, registeredLightIds)
        end
        addIntensityLightUnique(obj, registeredIntensityLightIds)
      end
    end
  end

  local tsStaticNames = scenetree.findClassObjects("TSStatic")
  if tsStaticNames then
    for _, name in ipairs(tsStaticNames) do
      local obj = scenetree.findObject(name)

      if obj then
        local isNightEmissive = getObjectFieldBoolFast(obj, "nightEmissive") == true
        local firstChildValue = getObjectFieldStringAtFast(obj, linkedChildFieldName, 0)
        local sourceLightId = nil
        local linkedLightColor = nil

        if firstChildValue then
          sourceLightId, linkedLightColor = addLinkedNightLights(obj, firstChildValue, registeredLightIds)
        end

        if isNightEmissive or sourceLightId then
          local id = getSimObjectId(obj)

          if id then
            local instColor = getInstanceColorTable(obj)
            local nightColor

            if sourceLightId then
              nightColor = linkedLightColor or {1, 1, 1}
            else
              local colorField = getObjectFieldStringAtFast(obj, "nightEmissiveColor", 0)
              nightColor = parseRgbColor(colorField, {1, 1, 1})
            end

            table.insert(nightLights.emissives, {
              id = id,
              color = nightColor,
              alpha = tonumber(instColor[4]) or 1,
              sourceLightId = sourceLightId
            })
          end
        end
      end
    end
  end

  nightLights.initialized = true
  nightLights.refreshing = false

  local tod = getTimeOfDay()
  if tod and tod.time then
    applynightLightsState(tod.time, true)
  end

  log("I", "environment.nightLights", string.format(
    "Registered %d night lights, %d night emissive TSStatics and %d day/night intensity lights",
    #nightLights.lights,
    #nightLights.emissives,
    #nightLights.intensityLights
  ))
end

local function clearnightLightsObjects()
  nightLights.initialized = false
  nightLights.lastNight = nil
  nightLights.lights = {}
  nightLights.emissives = {}
  nightLights.intensityLights = {}
end

-------------------------------------------------------------
----------------------- TimeofDay ---------------------------
-------------------------------------------------------------

M.defaultTimeOfDayOptions = {
  { key = "sunrise", value = 0.775, label = "ui.quickrace.tod.sunrise" },
  { key = "morning", value = 0.825, label = "ui.quickrace.tod.morning" },
  { key = "earlyNoon", value = 0.9, label = "ui.quickrace.tod.earlyNoon" },
  { key = "noon", value = 0, label = "ui.quickrace.tod.noon" },
  { key = "lateNoon", value = 0.1, label = "ui.quickrace.tod.lateNoon" },
  { key = "afternoon", value = 0.175, label = "ui.quickrace.tod.afternoon" },
  { key = "evening", value = 0.23, label = "ui.quickrace.tod.evening" },
  { key = "sunset", value = 0.245, label = "ui.quickrace.tod.sunset" },
  { key = "night", value = 0.5, label = "ui.quickrace.tod.night" },
}
M.defaultSolarTimeOfDayOptions = deepcopy(M.defaultTimeOfDayOptions)
M.timeOfDayKeyToTime = {}
for _, v in ipairs(M.defaultTimeOfDayOptions) do
  M.timeOfDayKeyToTime[v.key] = v.value
end

-- Environment controls UI: gravity / simulation-speed presets (pause route + UI bridge)
M.gravityPresets = {
  { key = "ui.environment.earth", title = "ui.environment.earth", value = -9.81 },
  { key = "ui.environment.moon", title = "ui.environment.moon", value = -1.62 },
  { key = "ui.environment.mars", title = "ui.environment.mars", value = -3.71 },
  { key = "ui.environment.sun", title = "ui.environment.sun", value = -274 },
  { key = "ui.environment.jupiter", title = "ui.environment.jupiter", value = -24.92 },
  { key = "ui.environment.neptune", title = "ui.environment.neptune", value = -11.15 },
  { key = "ui.environment.saturn", title = "ui.environment.saturn", value = -10.44 },
  { key = "ui.environment.uranus", title = "ui.environment.uranus", value = -8.87 },
  { key = "ui.environment.venus", title = "ui.environment.venus", value = -8.87 },
  { key = "ui.environment.mercury", title = "ui.environment.mercury", value = -3.7 },
  { key = "ui.environment.pluto", title = "ui.environment.pluto", value = -0.58 },
  { key = "ui.environment.zeroGravity", title = "ui.environment.zeroGravity", value = 0.0 },
  { key = "ui.environment.negativeEarth", title = "ui.environment.negativeEarth", value = 9.81 },
}

M.simSpeedPresets = {
  { key = "realtime", label = "ui.environment.realtime", value = 1 },
  { key = "2", label = "1/2x", value = 2 },
  { key = "4", label = "1/4x", value = 4 },
  { key = "10", label = "1/10x", value = 10 },
  { key = "25", label = "1/25x", value = 25 },
  { key = "50", label = "1/50x", value = 50 },
  { key = "100", label = "1/100x", value = 100 },
  { key = "1000", label = "1/1000x", value = 1000 },
}

M.getTimeOfDayOptions = function(levelIdentifier)
  levelIdentifier = levelIdentifier or getCurrentLevelIdentifier()
  return core_solarTimeOfDay.buildSolarTimeOfDayOptions(getTimeOfDay(), core_levels.getTimeOfDayOptions(levelIdentifier))
end

M.getDefaultTimeOfDayOptions = function()
  return M.defaultTimeOfDayOptions
end

M.getSolarTimeOfDayOptions = function(state)
  return core_solarTimeOfDay.buildSolarTimeOfDayOptions(state or getTimeOfDay(), M.defaultSolarTimeOfDayOptions)
end

M.getSolarTimeOfDayValue = function(key, state)
  return core_solarTimeOfDay.getTimeValueForKey(key, state or getTimeOfDay(), M.defaultSolarTimeOfDayOptions)
end

M.getTimeOfDayValueForNormalizedTime = function(normalizedTime, state)
  return core_solarTimeOfDay.timeFromNormalizedTime(normalizedTime, state or getTimeOfDay())
end

local function setTimeOfDay(timeOfDay)
  if not hasTimeOfDayState(timeOfDay) then return end
  if not updatingWholeState then stateLerp = nil end
  local timeObj = getObject("TimeOfDay")

  if timeObj then
    if not updatingWholeState then extensions.hook('onEnvironmentChanged', shallowcopy(timeOfDay)) end
    if not environmentChangesEnabled then return end

    if timeOfDay.startTime ~= nil then timeObj.startTime = timeOfDay.startTime end
    if timeOfDay.dayLength ~= nil then timeObj.dayLength = timeOfDay.dayLength end

    local needsPositionRefresh = false
    if timeOfDay.latitude ~= nil then timeObj.latitude = timeOfDay.latitude end
    if timeOfDay.longitude ~= nil then timeObj.longitude = timeOfDay.longitude end
    if timeOfDay.year ~= nil then timeObj.year = timeOfDay.year; needsPositionRefresh = true end
    if timeOfDay.month ~= nil then timeObj.month = timeOfDay.month; needsPositionRefresh = true end
    if timeOfDay.day ~= nil then timeObj.day = timeOfDay.day; needsPositionRefresh = true end
    if timeOfDay.latitude ~= nil then needsPositionRefresh = true end

    if timeOfDay.utcOffset ~= nil then timeObj.utcOffset = timeOfDay.utcOffset end
    if timeOfDay.dstRule ~= nil then timeObj.dstRule = timeOfDay.dstRule end
    if timeOfDay.celestialProfile ~= nil then
      timeObj.celestialProfile = tostring(timeOfDay.celestialProfile)
      if core_celestial and core_celestial.reloadProfile then core_celestial.reloadProfile() end
    end

    if timeOfDay.time ~= nil then
      timeObj.time = timeOfDay.time
      applynightLightsState(timeObj.time)
    elseif needsPositionRefresh then
      timeObj.time = timeObj.time
    end

    if timeOfDay.play ~= nil then
      local play = parseBoolValue(timeOfDay.play) == true
      setObjectFieldBool(timeObj, "play", play)
      setObjectFieldBool(timeObj, "animate", play)
    end
  end
end

local function cycleTimeOfDay()
  local v = getTimeOfDay()
  if not v then return end
  local t = v.time
  if t < 0.2 then
    t = 0.23
  elseif t >= 0.5 then
    t = 0.05
  else
    t = 0.5
  end
  v.time = t
  setTimeOfDay(v)
end

-------------------------------------------------------------
----------------------- ScatterSky --------------------------
-------------------------------------------------------------

-- For now, we keep the old functions for compatibility, but they do not do anything and will have to be removed at some point

local function getShadowDistance()
  log("W", "environment", "Shadow distance has been deprecated, the engine fits it automatically")
  return nil
end

local function setShadowDistance(shadowDistance)
  log("W", "environment", "Shadow distance has been deprecated, the engine fits it automatically")
end

local function getSkyBrightness()
  log("W", "environment", "Sky brightness has been deprecated")
  return nil
end

local function setSkyBrightness(skyBrightness)
  log("W", "environment", "Sky brightness has been deprecated")
end

local function getColorizeGradientFile()
  log("W", "environment", "Sky gradients has been deprecated")
  return nil
end

local function setColorizeGradientFile(colorizeGradientFile)
  log("W", "environment", "Sky gradients has been deprecated")
end

local function getSunScaleGradientFile()
  log("W", "environment", "Sky gradients has been deprecated")
  return nil
end

local function setSunScaleGradientFile(sunScaleGradientFile)
  log("W", "environment", "Sky gradients has been deprecated")
end

local function getAmbientScaleGradientFile()
  log("W", "environment", "Sky gradients has been deprecated")
  return nil
end

local function setAmbientScaleGradientFile(ambientScaleGradientFile)
  log("W", "environment", "Sky gradients has been deprecated")
end

local function getFogScaleGradientFile()
  log("W", "environment", "Sky gradients has been deprecated")
  return nil
end

local function setFogScaleGradientFile(fogScaleGradientFile)
  log("W", "environment", "Sky gradients has been deprecated")
end

local function getNightGradientFile()
  log("W", "environment", "Sky gradients has been deprecated")
  return nil
end

local function setNightGradientFile(nightGradientFile)
  log("W", "environment", "Sky gradients has been deprecated")
end

local function getNightFogGradientFile()
  log("W", "environment", "Sky gradients has been deprecated")
  return nil
end

local function setNightFogGradientFile(nightFogGradientFile)
  log("W", "environment", "Sky gradients has been deprecated")
end

-- can accept a vec3, or 3 arguments (x,y,z)
local function setGroundWind(...)
  if not ... then return end
  groundWind:set(...)
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {groundWind = groundWind }) end
  if not environmentChangesEnabled then return end
  applyGroundWind()
end

local function getGroundWind() return groundWind end

-------------------------------------------------------------
------------------------- Clouds ----------------------------
-------------------------------------------------------------

-- Old functions below, only works for the first cloud object in the scene

local function setWindSpeed(windSpeed)
  if not windSpeed then return end
  local cloudObj = getObject("CloudLayer")
  if not cloudObj then return end
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {windSpeed = windSpeed}) end
  if not environmentChangesEnabled then return end
  cloudObj.windSpeed = windSpeed
  cloudObj:postApply()
end

local function getWindSpeed()
  local cloudObj = getObject("CloudLayer")
  return cloudObj and cloudObj.windSpeed
end

local function setCloudCover(cloud)
  if not updatingWholeState then stateLerp = nil end
  if not cloud then return end
  local cloudObj = getObject("CloudLayer")
  if not cloudObj then return end
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {cloudCover = cloud}) end
  if not environmentChangesEnabled then return end
  cloudObj.coverage = cloud
  cloudObj:postApply()
end

local function getCloudCover()
  local cloudObj = getObject("CloudLayer")
  return cloudObj and cloudObj.coverage
end

-- can accept a vec3, or 2 arguments (x,y)
local function setCloudWindDirection(...)
  if not ... then return end
  local cloudObj = getObject("CloudLayer")
  if not cloudObj then return end
  local dir = vec3(...)
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {cloudWindDirection = dir}) end
  if not environmentChangesEnabled then return end
  cloudObj.windDirection = Point2F(dir.x, dir.y)
  cloudObj:postApply()
end

local function getCloudWindDirection()
  local cloudObj = getObject("CloudLayer")
  if not cloudObj then return nil end
  local dir = cloudObj.windDirection
  if not dir then return nil end
  return vec3(dir.x, dir.y, 0)
end

local function setCloudAltitudeKm(altitudeKm)
  if not altitudeKm then return end
  local cloudObj = getObject("CloudLayer")
  if not cloudObj then return end
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {cloudAltitudeKm = altitudeKm}) end
  if not environmentChangesEnabled then return end
  cloudObj.altitudeKm = altitudeKm
  cloudObj:postApply()
end

local function getCloudAltitudeKm()
  local cloudObj = getObject("CloudLayer")
  return cloudObj and cloudObj.altitudeKm
end

local function getCloudWeatherOffsetKm()
  if not CloudLayer or type(CloudLayer.getWeatherOffsetKm) ~= "function" then return nil end

  local ok, offset = pcall(CloudLayer.getWeatherOffsetKm)
  if not ok then
    log("E", "environment", "Unable to get CloudLayer weather offset: " .. tostring(offset))
    return nil
  end
  if not offset then return nil end

  return vec3(tonumber(offset.x) or 0, tonumber(offset.y) or 0, tonumber(offset.z) or 0)
end

-- can accept a vec3, or 3 arguments (x,y,z)
local function setCloudWeatherOffsetKm(...)
  if not ... then return end
  if not CloudLayer or type(CloudLayer.setWeatherOffsetKm) ~= "function" or type(Point3F) ~= "function" then
    log("W", "environment", "CloudLayer.setWeatherOffsetKm is not available.")
    return false
  end

  local offset = vec3(...)
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {cloudWeatherOffsetKm = offset}) end
  if not environmentChangesEnabled then return false end

  local ok, err = pcall(CloudLayer.setWeatherOffsetKm, Point3F(offset.x, offset.y, offset.z))
  if not ok then
    log("E", "environment", "Unable to set CloudLayer weather offset: " .. tostring(err))
    return false
  end

  return true
end

local function resetCloudWeatherOffsetKm()
  return setCloudWeatherOffsetKm(0, 0, 0)
end

local function getNormalizedCloudWeatherSeed(seed)
  local normalizedSeed = math.floor(tonumber(seed) or math.random(0, cloudWeatherSeedMax))
  return max(0, min(cloudWeatherSeedMax, normalizedSeed))
end

local function regenerateWeatherMap(seed)
  if not CloudLayer or type(CloudLayer.regenerateWeatherMap) ~= "function" then
    log("W", "environment", "CloudLayer.regenerateWeatherMap is not available.")
    return false
  end

  local normalizedSeed = getNormalizedCloudWeatherSeed(seed)
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {cloudWeatherSeed = normalizedSeed}) end
  if not environmentChangesEnabled then return false, normalizedSeed end

  local ok, err = pcall(CloudLayer.regenerateWeatherMap, normalizedSeed)
  if not ok then
    log("E", "environment", "Unable to regenerate CloudLayer weather map: " .. tostring(err))
    return false
  end

  return true, normalizedSeed
end

local function getCloudField(fieldName)
  local cloudObj = getObject("CloudLayer")
  return cloudObj and cloudObj[fieldName]
end

local function setCloudField(fieldName, stateKey, value)
  if value == nil then return end
  local cloudObj = getObject("CloudLayer")
  if not cloudObj then return end
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {[stateKey] = value}) end
  if not environmentChangesEnabled then return end
  cloudObj[fieldName] = value
  cloudObj:postApply()
end

local function getCloudCirrusAltitudeKm()
  return getCloudField("cirrusAltitudeKm")
end

local function setCloudCirrusAltitudeKm(altitudeKm)
  setCloudField("cirrusAltitudeKm", "cloudCirrusAltitudeKm", altitudeKm)
end

local function getCloudCirrusCoverage()
  return getCloudField("cirrusCoverage")
end

local function setCloudCirrusCoverage(coverage)
  setCloudField("cirrusCoverage", "cloudCirrusCoverage", coverage)
end

local function getCloudCirrusDensity()
  return getCloudField("cirrusDensity")
end

local function setCloudCirrusDensity(density)
  setCloudField("cirrusDensity", "cloudCirrusDensity", density)
end

-- Cloud per ID functions below

local function getCloudCoverByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.coverage
end

local function setCloudCoverByID(objectID, coverage)
  if not coverage then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.coverage = coverage
  cloudObj:postApply()
end

local function getCloudExposureByID(objectID)
  log("W", "environment", "Cloud exposure has been deprecated")
  return nil
end

local function setCloudExposureByID(objectID, exposure)
  log("W", "environment", "Sky gradients has been deprecated")
end

local function getCloudWindByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.windSpeed
end

local function setCloudWindByID(objectID, windSpeed)
  if not windSpeed then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.windSpeed = windSpeed
  cloudObj:postApply()
end

local function getCloudHeightByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.height
end

local function setCloudHeightByID(objectID, height)
  if not height then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.height = height
  cloudObj:postApply()
end

local function getCloudWindDirectionByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return nil end
  local dir = cloudObj.windDirection
  if not dir then return nil end
  return vec3(dir.x, dir.y, 0)
end

-- can accept a vec3, or 2 arguments (x,y) after the objectID
local function setCloudWindDirectionByID(objectID, ...)
  if not ... then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  local dir = vec3(...)
  cloudObj.windDirection = Point2F(dir.x, dir.y)
  cloudObj:postApply()
end

local function getCloudAltitudeKmByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.altitudeKm
end

local function setCloudAltitudeKmByID(objectID, altitudeKm)
  if not altitudeKm then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.altitudeKm = altitudeKm
  cloudObj:postApply()
end

local function getCloudCirrusAltitudeKmByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.cirrusAltitudeKm
end

local function setCloudCirrusAltitudeKmByID(objectID, altitudeKm)
  if altitudeKm == nil then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.cirrusAltitudeKm = altitudeKm
  cloudObj:postApply()
end

local function getCloudCirrusCoverageByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.cirrusCoverage
end

local function setCloudCirrusCoverageByID(objectID, coverage)
  if coverage == nil then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.cirrusCoverage = coverage
  cloudObj:postApply()
end

local function getCloudCirrusDensityByID(objectID)
  local cloudObj = scenetree.findObjectById(objectID)
  return cloudObj and cloudObj.cirrusDensity
end

local function setCloudCirrusDensityByID(objectID, density)
  if density == nil then return end
  local cloudObj = scenetree.findObjectById(objectID)
  if not cloudObj then return end
  cloudObj.cirrusDensity = density
  cloudObj:postApply()
end

-------------------------------------------------------------
----------------------- LevelInfo ---------------------------
-------------------------------------------------------------

local function setFogDensity(fog)
  if not updatingWholeState then stateLerp = nil end
  local fogObj = getObject("LevelInfo")
  if fogObj and fog then
    if not updatingWholeState then extensions.hook('onEnvironmentChanged', {fogDensity = fog}) end
    if not environmentChangesEnabled then return end
    fogObj.fogDensity = fog
    fogObj:postApply()
  end
end

local function getFogDensity()
  local fogObj = getObject("LevelInfo")
  local fog = 0.0
  if fogObj then
    fog = fogObj.fogDensity
  end
  return fog, fogObj
end

local function setFogDensityOffset(fogOffset)
  log("W", "environment", "Fog density offset has been deprecated")
end

local function getFogDensityOffset()
  log("W", "environment", "Fog density offset has been deprecated")
  return nil
end

local function setFogAtmosphereHeight(fogHeight)
  if not updatingWholeState then stateLerp = nil end
  local fogObj = getObject("LevelInfo")
  if fogObj and fogHeight then
    fogObj.FogAtmosphereHeight = fogHeight
    fogObj:postApply()
  end
end

local function getFogAtmosphereHeight()
  local fogObj = getObject("LevelInfo")
  local fogHeight = 0.0
  if fogObj then
    fogHeight = fogObj.FogAtmosphereHeight
  end
  return fogHeight
end

local function setGravity(grav)
  if not grav then return end
  if not updatingWholeState then extensions.hook('onEnvironmentChanged', {gravity = grav}) end
  if not environmentChangesEnabled then return end

  -- important: let the level known about the change
  -- otherwise the spawning of objects will have the wrong gravity
  if scenetree.theLevelInfo then
    scenetree.theLevelInfo.gravity = grav
  end
  be:queueAllObjectLua("obj:setGravity("..grav..")")
end

local function getGravity()
  if scenetree.theLevelInfo then
    return scenetree.theLevelInfo.gravity
  end
  return -9.81; -- fallback
end

-------------------------------------------------------------
--------------------- Precipitation -------------------------
-------------------------------------------------------------

local function setPrecipitation(rainDrops)
  local rainObj = getObject("Precipitation")
  if rainObj and rainDrops then
    rainObj.numOfDrops = rainDrops
  end
end

local function getPrecipitation()
  local rainObj = getObject("Precipitation")
  local rainDrops
  if rainObj then
    rainDrops = rainObj.numOfDrops
  end
  return rainDrops
end

local function getTemperatureK()
  return temperatureK
end


-------------------------------------------------------------
local function getState()
  local res = {}
  local timeObj = getTimeOfDay()
  if timeObj then
    for _, key in ipairs(timeOfDayStateFields) do
      res[key] = timeObj[key]
    end
  end

  local windSpeed = getWindSpeed()
  res.windSpeed = windSpeed
  res.groundWind = getGroundWind()

  local cloudCover = getCloudCover()
  res.cloudCover = cloudCover
  res.cloudWindDirection = getCloudWindDirection()
  res.cloudAltitudeKm = getCloudAltitudeKm()
  res.cloudWeatherOffsetKm = getCloudWeatherOffsetKm()
  res.cloudCirrusAltitudeKm = getCloudCirrusAltitudeKm()
  res.cloudCirrusCoverage = getCloudCirrusCoverage()
  res.cloudCirrusDensity = getCloudCirrusDensity()
  res.fogDensity = getFogDensity() * 1000
  res.fogAtmosphereHeight = getFogAtmosphereHeight()

  local numOfDrops = getPrecipitation()
  res.numOfDrops = numOfDrops
  res.gravity = getGravity()
  res.temperatureC = getTemperatureK() - 273.15

  if next(res) == nil then
    return nil
  end
  return res
end

local function applyStateNow(state)
  if not state then return end
  if not environmentChangesEnabled then return end
  updatingWholeState = true
  -- time is optional: only move the clock when a time is supplied. Other TOD
  -- fields keep the engine's live time and update the sky in place.
  if hasTimeOfDayState(state) then
    local timeOfDayState = {}
    for _, key in ipairs(timeOfDayStateFields) do
      if state[key] ~= nil then timeOfDayState[key] = state[key] end
    end
    setTimeOfDay(timeOfDayState)
  end
  setWindSpeed(state.windSpeed)
  if state.groundWind then setGroundWind(state.groundWind.x, state.groundWind.y, state.groundWind.z) end
  setCloudCover(state.cloudCover)
  if state.cloudWindDirection then setCloudWindDirection(state.cloudWindDirection.x, state.cloudWindDirection.y) end
  setCloudAltitudeKm(state.cloudAltitudeKm)
  if state.cloudWeatherOffsetKm then setCloudWeatherOffsetKm(state.cloudWeatherOffsetKm.x, state.cloudWeatherOffsetKm.y, state.cloudWeatherOffsetKm.z) end
  setCloudCirrusAltitudeKm(state.cloudCirrusAltitudeKm)
  setCloudCirrusCoverage(state.cloudCirrusCoverage)
  setCloudCirrusDensity(state.cloudCirrusDensity)
  if state.fogDensity then
    setFogDensity(state.fogDensity / 1000) -- sliders do not work with tiny values, so we use big values and divide them here
  end
  setFogAtmosphereHeight(state.fogAtmosphereHeight)
  setPrecipitation(state.numOfDrops)
  setGravity(state.gravity)
  updatingWholeState = false
end

local function timeWrap(time)
  local t = tonumber(time)
  if not t then return nil end
  t = t % 1
  return t < 0 and t + 1 or t
end

local lerpFields = {
  cloudCover = true,
  fogDensity = true,
  fogAtmosphereHeight = true,
  time = true
}

local lerpRanges = {
  cloudCover = 3,
  fogDensity = 50,
  fogAtmosphereHeight = 1999,
  time = 0.5
}

local function getScaledLerpDuration(maxDuration, fields)
  local maxRatio = 0
  for key, field in pairs(fields) do
    local range = lerpRanges[key]
    if range then
      local diff = key == "time" and math.abs(field.delta) or math.abs(field.to - field.from)
      maxRatio = max(maxRatio, min(diff / range, 1))
    end
  end
  if maxRatio <= 0 then return 0 end
  return max(0.12, maxDuration * math.sqrt(maxRatio))
end

local function setState(state, lerpSeconds)
  local wasLerping = stateLerp ~= nil
  stateLerp = nil
  if not state then return end
  extensions.hook('onEnvironmentChanged', shallowcopy(state))

  local duration = tonumber(lerpSeconds) or 0
  if duration <= 0 then
    applyStateNow(state)
    sendState()
    return
  end

  local current = getState()
  local fields = {}
  local immediateState = {}
  for _, key in ipairs({"cloudCover", "fogDensity", "fogAtmosphereHeight"}) do
    local from, to = tonumber(current and current[key]), tonumber(state[key])
    if from and to then fields[key] = {from = from, to = to} end
  end

  local fromTime, toTime = timeWrap(current and current.time), timeWrap(state.time)
  if fromTime and toTime then
    local delta = toTime - fromTime
    if delta > 0.5 then delta = delta - 1 elseif delta < -0.5 then delta = delta + 1 end
    fields.time = {from = fromTime, to = toTime, delta = delta, play = parseBoolValue(state.play) == true}
  end

  for key, value in pairs(state) do
    if not lerpFields[key] and key ~= "play" then immediateState[key] = value end
  end
  if next(immediateState) then
    applyStateNow(immediateState)
  end

  duration = getScaledLerpDuration(duration, fields)
  local elapsed = 0
  if wasLerping then
    duration = min(duration, 0.3)
    elapsed = duration * 0.35
  end
  if duration <= 0 then
    applyStateNow(state)
    return
  end
  stateLerp = next(fields) and {elapsed = elapsed, duration = duration, fields = fields} or nil
  if not stateLerp then applyStateNow(state) end
end

local function updateStateLerp(dtReal)
  if not stateLerp or not environmentChangesEnabled then return end

  stateLerp.elapsed = min(stateLerp.elapsed + max(tonumber(dtReal) or 1 / 60, 0), stateLerp.duration)
  local f = clamp(stateLerp.elapsed / stateLerp.duration, 0, 1)
  local easedF = f * f * f * (f * (f * 6 - 15) + 10)
  local state = {}
  for key, field in pairs(stateLerp.fields) do
    state[key] = key == "time" and timeWrap(field.from + field.delta * easedF) or lerp(field.from, field.to, easedF)
  end
  if stateLerp.fields.time then state.play = stateLerp.fields.time.play end

  applyStateNow(state)
  if f >= 1 then
    stateLerp = nil
    sendState()
  end
end

local function dumpGroundModels()
  local gmCount = be:getGroundModelCount()
  local gms = {}
  for i = 0, gmCount do
    local gm = be:getGroundModelByID(i)
    if gm.data then
      gm = gm.data
      gms[gm.name or i] = {
      id = i,
      roughnessCoefficient = gm.roughnessCoefficient,
      defaultDepth = gm.defaultDepth,
      staticFrictionCoefficient = gm.staticFrictionCoefficient,
      slidingFrictionCoefficient = gm.slidingFrictionCoefficient,
      hydrodynamicFriction = gm.hydrodynamicFriction or gm.hydrodnamicFriction,
      stribeckVelocity = gm.stribeckVelocity,
      strength = gm.strength,
      collisiontype = gm.collisiontype,
      fluidDensity = gm.fluidDensity,
      flowConsistencyIndex = gm.flowConsistencyIndex,
      flowBehaviorIndex = gm.flowBehaviorIndex or gm.flowBehaviourIndex, -- omg ...
      dragAnisotropy = gm.dragAnisotropy,
      skidMarks = gm.skidMarks,
      shearStrength = gm.shearStrength
      }
    end
  end
  jsonWriteFile('groundmodels_dump.json', gms, true)
end

local function submitGroundModel(k, v)
  local particles = require("particles")
  local materials = particles.getMaterialsParticlesTable()

  local gm = ground_model()
  local names = v.aliases or {}
  table.insert(names, k)

  local knownAttributes = {aliases=1, roughnessCoefficient=1, staticFrictionCoefficient=1, slidingFrictionCoefficient=1, hydrodynamicFriction=1, stribeckVelocity=1, strength=1, collisiontype=1, fluidDensity=1, flowConsistencyIndex=1, flowBehaviorIndex=1, dragAnisotropy=1, skidMarks=1, defaultDepth=1, shearStrength = 1}
  local knownProblems = {hydrodnamicFriction='hydrodynamicFriction', flowBehaviourIndex='flowBehaviorIndex'}
  for j, _ in pairs(v) do
    if knownProblems[j] then
      log('E', 'groundmodels', 'Please fix your grounmodel up: ' .. tostring(j) .. ' should be instead: ' .. knownProblems[j])
    elseif not knownAttributes[j] then
      log('E', 'groundmodels', 'Unknown ground model attribute: ' .. tostring(j) .. ' - IGNORED')
    end
  end

  gm.roughnessCoefficient = v.roughnessCoefficient or 0
  gm.defaultDepth = v.defaultDepth or 0
  gm.staticFrictionCoefficient = v.staticFrictionCoefficient or 1
  gm.slidingFrictionCoefficient = v.slidingFrictionCoefficient or 0.7
  gm.hydrodynamicFriction = v.hydrodynamicFriction or v.hydrodnamicFriction or 0.01
  gm.stribeckVelocity = v.stribeckVelocity or 6
  gm.strength = v.strength or 1
  gm.collisiontype = 0
  if type(v.collisiontype) == 'string' then
    gm.collisiontype = particles.getOrAddMaterialIDByName(materials, v.collisiontype)
    --print(v.collisiontype .. ' -> ' .. tostring(gm.collisiontype))
  end
  gm.fluidDensity = v.fluidDensity or 200
  gm.flowConsistencyIndex = v.flowConsistencyIndex or 10000
  gm.flowBehaviorIndex = v.flowBehaviorIndex or 0.5
  gm.dragAnisotropy = v.dragAnisotropy or 0
  gm.skidMarks = v.skidMarks or false
  gm.shearStrength = v.shearStrength or 0

  for _, name in ipairs(names) do
    local newName = string.upper(name)

    M.groundModels[newName] = {cdata = gm, isAlias = false, parent = 'none'}

    if newName ~= k then
      M.groundModels[newName].isAlias = true
      M.groundModels[newName].parent = k
    end

    be:setGroundModel(newName, gm)
    --print("****** setting groundmodel: " .. tostring(newName))
    -- save them in lua so we could work with them later
  end
end

local function loadGroundModelFile(filename)
  local gms = jsonReadFile(filename)
  if not gms then
    log('E', 'ge.environment.reloadGroundModels', 'unable to load main ground models file: ' .. filename);
    return {}
  end

  -- convert the keys to uppercase
  local newGms = {}
  for k, v in pairs(gms) do
    local key = k
    if string.len(k) > 31 then
      local newk = string.sub(k, 1, 30)
      log('E', 'ge.environment.reloadGroundModels', 'Ground model name too long: "' .. tostring(k) .. '" is longer than the supported 31 characters. It will be cut to "' .. tostring(newk) .. '")')
      key = newk
    end
    newGms[string.upper(key)] = v
  end
  gms = newGms

  if filename == gm_filename then
    if gms['ASPHALT'] == nil then
      log('E', 'ge.environment.reloadGroundModels', 'Ground model "ASPHALT" was not found in: ' .. tostring(gm_filename))
    end
  end

  table.insert(M.loadedGroundModelFiles, filename)

  return gms
end

local function loadGroundModels(gms)
  -- this enforces asphalt being the first always
  if gms['ASPHALT'] then
    submitGroundModel('ASPHALT', gms['ASPHALT'])
  end

  local sortedGmNames = {}
  for k, v in pairs(gms) do
    if k ~= 'ASPHALT' then
      table.insert(sortedGmNames, k)
    end
  end
  table.sort(sortedGmNames)

  -- submit all other ground models afterwards in alphabetical order
  for _, name in ipairs(sortedGmNames) do
    submitGroundModel(name, gms[name])
  end
end

local function reloadGroundModels(levelPath)
  if not be then return end

  profilerPushEvent('reloadGroundModels')

  --log('D', 'ge.environment.reloadGroundModels', 'reloading all ground models ...')
  be:resetGroundModels()
  M.groundModels = {}
  M.loadedGroundModelFiles = {}

  -- load the common groundmodels first
  local allGroundModels = loadGroundModelFile(gm_filename)

  -- then load level groundmaps
  levelPath = levelPath or getMissionFilename()
  if levelPath and string.len(levelPath) > 0 then
    local levelDir, filename, ext = path.split(levelPath, "(.-)([^/]-([^%.]*))$")
    local files = FS:findFiles(levelDir..'/groundModels/', '*.json', -1, true, false)

    -- filter paths to only return filename without extension
    for _,fn in pairs(files) do
      tableMerge(allGroundModels, loadGroundModelFile(fn));
    end
  end

  loadGroundModels(allGroundModels)

  profilerPopEvent('reloadGroundModels')
end

local function reset()
  local levelInfo = getObject("LevelInfo")
  if levelInfo then
    tempCurve = levelInfo:getTemperatureCurveC()
  end
  guihooks.trigger("EnvironmentStateUpdate", getState())
  guihooks.trigger("EnvironmentCanUpdateChanged", environmentChangesEnabled)
  reloadGroundModels()
end

local function reset_init()
  setState(init_env)
end

local function getInitState()
  if not init_env then return nil end
  return shallowcopy(init_env)
end

local function enableChanges(enabled)
  environmentChangesEnabled = enabled
  guihooks.trigger("EnvironmentCanUpdateChanged", environmentChangesEnabled)
end

local function canChange()
  return environmentChangesEnabled
end

local function onClientPreStartMission(levelPath)
  local levelInfo = getObject("LevelInfo")
  if levelInfo then
    tempCurve = levelInfo:getTemperatureCurveC()
  end
  reloadGroundModels(levelPath)
end

local function onClientPostStartMission(levelPath)
  --print("onClientPreStartMission: " .. tostring(levelPath))
  envObjectIdCache = {}
  init_env=getState()
  --init_env.time = init_env.startTime --TOD:onAdd is already doing that
  setState(init_env) --necesary to "fix" some maps that have the sky changed
end

-- having this function, enables writing groundmodels that are getting reloaded dynamically in the game
local function onFilesChanged(files)
  for _,v in pairs(files) do
    local filename = v.filename
    if filename and filename:find('.json') then
      filename = string.upper(filename)
      for _, f in pairs(M.loadedGroundModelFiles) do
        if string.upper(f) == filename then
          log('D', 'environment', 'ground model changed dynamically, reloading collision')
          -- in this case we want to make sure everything uses the new properties
          -- do not put this in reset as it would be called twice
          reset()
          be:reloadCollision()
          return
        end
      end
    end
  end
end

local function setTemperatureK(tempK)
  be:setSeaLevelTemperatureK(tempK)
  temperatureK = tempK
end

function sendState()
  local state = getState()
  guihooks.trigger("EnvironmentStateUpdate", state)
  guihooks.trigger("EnvironmentCanUpdateChanged", environmentChangesEnabled)
end

local function invertLerp(from,to,value)
  value = min(max(from, value),to)
  return (value - from) / (to-from)
end

local function onUpdate(dtReal)
  local levelInfo = getObject("LevelInfo")
  if not levelInfo or not be then return end

  updateStateLerp(dtReal)

  if levelInfo:isEditorDirty() then
    tempCurve = levelInfo:getTemperatureCurveC()
  end

  local tod = getTimeOfDay()
  if tod and tod.time then
    applynightLightsState(tod.time)
  end

  if #tempCurve < 2 then return end
  if not tod or not tod.time then
    setTemperatureK( tempCurve[1][2] + 273.15 )
    return
  end

  local tempC = 15
  local t = max(tempCurve[1][1], min(tempCurve[#tempCurve][1], tod.time))
  for i, v in ipairs(tempCurve) do
    if v[1] > t or i == #tempCurve then
      local factor = invertLerp(tempCurve[i-1][1], v[1], t)
      tempC = lerp(tempCurve[i-1][2], v[2], clamp(factor,0,1))
      break
    end
  end

  setTemperatureK( tempC + 273.15 )
end

local function onClientStartMission(levelPath)
  local levelInfo = getObject("LevelInfo")
  if levelInfo then tempCurve = levelInfo:getTemperatureCurveC() end
  envObjectIdCache = {}
  refreshnightLightsObjects()
  local tod = getTimeOfDay()
  if tod then
    applynightLightsState(tod.time, true)
  end
  applyGroundWind()
  -- randomize clouds every level load
  regenerateWeatherMap()
end

local function onEditorDeactivated()
  envObjectIdCache = {}
  refreshnightLightsObjects()
end

local function onEditorBeforeSaveLevel()
  if not nightLights.initialized then return end

  editorSaveNightLightsState = {
    night = nightLights.lastNight
  }
  setNightLightsEnabled(false, true)
end

local function onEditorAfterSaveLevel()
  if not editorSaveNightLightsState then return end

  setNightLightsEnabled(editorSaveNightLightsState.night, true)
  editorSaveNightLightsState = nil
end

local function onClientEndMission()
  stateLerp = nil
  clearnightLightsObjects()
  for k,v in pairs(myTexture) do
    myTexture[k] = nil
  end
  --Stop time of day object when we unload a level
  local timeObj = getObject("TimeOfDay")
  if timeObj then
    setObjectFieldBool(timeObj, "play", false)
    setObjectFieldBool(timeObj, "animate", false)
  end
  groundWind:set(0,0,0)
  if be then be:setGroundWind(groundWind) end
  reset()
end

local function onSerialize()
  return { groundWind = groundWind }
end
local function onDeserialized(data)
  setGroundWind(data.groundWind)
end

local function syncTimeToClockSeconds(totalSeconds, lerpSeconds, extraState)
  local base = getTimeOfDay()
  if not base then
    return
  end
  local duration = tonumber(lerpSeconds) or 0
  local state = extraState and shallowcopy(extraState) or {}
  state.time = (totalSeconds / 86400 - 0.5) % 1
  state.play = base.play == true
  setState(state, duration)
  if duration <= 0 then
    sendState()
  end
end

local function syncTimeToClockTable(t, lerpSeconds)
  syncTimeToClockSeconds(t.hour * 3600 + t.min * 60 + t.sec, lerpSeconds)
end

local function syncTimeToRealClock(lerpSeconds)
  syncTimeToClockTable(os.date("*t"), lerpSeconds)
end

local function getLevelDateForRealClock(base, epoch)
  local utcDate = os.date("!*t", epoch)
  local offsetState = shallowcopy(base)
  offsetState.year = utcDate.year
  offsetState.month = utcDate.month
  offsetState.day = utcDate.day

  local offsetHours = core_solarTimeOfDay.getCivilOffsetHours(offsetState)
  if offsetHours == nil then return nil end

  local levelDate = os.date("!*t", epoch + offsetHours * 3600)
  offsetState.year = levelDate.year
  offsetState.month = levelDate.month
  offsetState.day = levelDate.day

  local adjustedOffsetHours = core_solarTimeOfDay.getCivilOffsetHours(offsetState)
  if adjustedOffsetHours ~= nil and adjustedOffsetHours ~= offsetHours then
    levelDate = os.date("!*t", epoch + adjustedOffsetHours * 3600)
  end

  return levelDate
end

local function syncTimeToRealClockUtc(lerpSeconds)
  local base = getTimeOfDay()
  if not base then
    return
  end

  local levelDate = getLevelDateForRealClock(base, os.time())
  if not levelDate then return end
  local totalSeconds = levelDate.hour * 3600 + levelDate.min * 60 + levelDate.sec
  syncTimeToClockSeconds(totalSeconds, lerpSeconds, {
    year = levelDate.year,
    month = levelDate.month,
    day = levelDate.day,
  })
end

local function resetTireMarks()
  if be then
    be:resetTireMarks()
  end
end

local function saveTireMarks(filename)
  if be then
    be:saveTireMarks(filename or "tiremarks.dat")
  end
end

local function loadTireMarks(filename)
  if be then
    be:loadTireMarks(filename or "tiremarks.dat")
  end
end

local function getGravityPresets()
  return M.gravityPresets
end

local function getSimSpeedPresets()
  return M.simSpeedPresets
end

------------------------------------------
-- For ui interface environment property
M.setState = setState
M.requestState = sendState
M.reset = reset
M.getState = getState
M.reset_init = reset_init
M.getInitState = getInitState
M.syncTimeToRealClock = syncTimeToRealClock
M.syncTimeToRealClockUtc = syncTimeToRealClockUtc
M.resetTireMarks = resetTireMarks
M.saveTireMarks = saveTireMarks
M.loadTireMarks = loadTireMarks
M.getGravityPresets = getGravityPresets
M.getSimSpeedPresets = getSimSpeedPresets
----------------------------------------------
-- TimeofDay
M.setTimeOfDay = setTimeOfDay
M.getTimeOfDay = getTimeOfDay
M.getLightState = getLightState
M.cycleTimeOfDay = cycleTimeOfDay
-- ScatterSky
M.getShadowDistance = getShadowDistance
M.setShadowDistance = setShadowDistance
M.getSkyBrightness = getSkyBrightness
M.setSkyBrightness = setSkyBrightness
M.getColorizeGradientFile = getColorizeGradientFile
M.setColorizeGradientFile = setColorizeGradientFile
M.getSunScaleGradientFile = getSunScaleGradientFile
M.setSunScaleGradientFile = setSunScaleGradientFile
M.getAmbientScaleGradientFile = getAmbientScaleGradientFile
M.setAmbientScaleGradientFile = setAmbientScaleGradientFile
M.getFogScaleGradientFile = getFogScaleGradientFile
M.setFogScaleGradientFile = setFogScaleGradientFile
M.getNightGradientFile = getNightGradientFile
M.setNightGradientFile = setNightGradientFile
M.getNightFogGradientFile = getNightFogGradientFile
M.setNightFogGradientFile = setNightFogGradientFile
-- Clouds
M.setWindSpeed = setWindSpeed
M.getWindSpeed = getWindSpeed
M.setGroundWind = setGroundWind
M.getGroundWind = getGroundWind
M.setCloudCover = setCloudCover
M.getCloudCover = getCloudCover
M.setCloudWindDirection = setCloudWindDirection
M.getCloudWindDirection = getCloudWindDirection
M.setCloudAltitudeKm = setCloudAltitudeKm
M.getCloudAltitudeKm = getCloudAltitudeKm
M.getCloudWeatherOffsetKm = getCloudWeatherOffsetKm
M.setCloudWeatherOffsetKm = setCloudWeatherOffsetKm
M.resetCloudWeatherOffsetKm = resetCloudWeatherOffsetKm
M.regenerateWeatherMap = regenerateWeatherMap
M.getCloudCirrusAltitudeKm = getCloudCirrusAltitudeKm
M.setCloudCirrusAltitudeKm = setCloudCirrusAltitudeKm
M.getCloudCirrusCoverage = getCloudCirrusCoverage
M.setCloudCirrusCoverage = setCloudCirrusCoverage
M.getCloudCirrusDensity = getCloudCirrusDensity
M.setCloudCirrusDensity = setCloudCirrusDensity
M.getCloudCoverByID = getCloudCoverByID
M.setCloudCoverByID = setCloudCoverByID
M.getCloudExposureByID = getCloudExposureByID
M.setCloudExposureByID = setCloudExposureByID
M.getCloudWindByID = getCloudWindByID
M.setCloudWindByID = setCloudWindByID
M.getCloudHeightByID = getCloudHeightByID
M.setCloudHeightByID = setCloudHeightByID
M.getCloudWindDirectionByID = getCloudWindDirectionByID
M.setCloudWindDirectionByID = setCloudWindDirectionByID
M.getCloudAltitudeKmByID = getCloudAltitudeKmByID
M.setCloudAltitudeKmByID = setCloudAltitudeKmByID
M.getCloudCirrusAltitudeKmByID = getCloudCirrusAltitudeKmByID
M.setCloudCirrusAltitudeKmByID = setCloudCirrusAltitudeKmByID
M.getCloudCirrusCoverageByID = getCloudCirrusCoverageByID
M.setCloudCirrusCoverageByID = setCloudCirrusCoverageByID
M.getCloudCirrusDensityByID = getCloudCirrusDensityByID
M.setCloudCirrusDensityByID = setCloudCirrusDensityByID
-- LevelInfo
M.setFogDensity = setFogDensity
M.getFogDensity = getFogDensity
M.setFogDensityOffset = setFogDensityOffset
M.getFogDensityOffset = getFogDensityOffset
M.setFogAtmosphereHeight = setFogAtmosphereHeight
M.getFogAtmosphereHeight = getFogAtmosphereHeight
M.setGravity = setGravity
M.getGravity = getGravity
-- Precipitation
M.setPrecipitation = setPrecipitation
M.getPrecipitation = getPrecipitation
-- Other
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.enableChanges = enableChanges
M.canChange = canChange
M.getTemperatureK = getTemperatureK
M.reloadGroundModels = reloadGroundModels
M.onClientPreStartMission = onClientPreStartMission
M.onClientPostStartMission = onClientPostStartMission
M.onInit = reset
M.onFilesChanged = onFilesChanged
M.onUpdate = onUpdate
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onVehicleSpawned = applyGroundWind
M.onVehicleResetted = applyGroundWind
M.onEditorDeactivated = onEditorDeactivated
M.onEditorBeforeSaveLevel = onEditorBeforeSaveLevel
M.onEditorAfterSaveLevel = onEditorAfterSaveLevel
M.refreshnightLightsObjects = refreshnightLightsObjects
M.dumpGroundModels = dumpGroundModels

return M
