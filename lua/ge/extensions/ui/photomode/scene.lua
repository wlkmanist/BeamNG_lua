-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_photomode_shared", "ui_photomode_advancedRender", "core_celestial" }


local SCENE_LIMITS = {
  timeMin = 0,
  timeMax = 1,
  cloudCoverMin = 0,
  cloudCoverMax = 3,
  fogDensityMin = 0,
  fogDensityMax = 50,
  fogAtmosphereHeightMin = 1,
  fogAtmosphereHeightMax = 1000,
}

local SCENE_TOD_PRESET_FIELDS = { "time", "play", "year", "month", "day" }
local SCENE_WEATHER_PRESET_FIELDS = { "cloudCover", "fogDensity", "fogAtmosphereHeight", "windSpeed", "cloudWindDirection", "groundWind" }
local SCENE_CELESTIAL_DISPLAY_FIELDS = {
  "constellationLines",
  "constellationLabels",
  "horizonGrid",
  "equatorialGrid",
  "meridianGrid",
  "moonGrid",
}

local function tableHasAnyValue(data)
  if type(data) ~= "table" then
    return false
  end
  for _, value in pairs(data) do
    if value ~= nil then
      return true
    end
  end
  return false
end

local function copyFields(source, fields)
  local out = {}
  if type(source) ~= "table" then
    return out
  end
  for _, key in ipairs(fields) do
    out[key] = source[key]
  end
  return out
end

local function copyVector(value)
  local x = tonumber(value and value.x)
  local y = tonumber(value and value.y)
  if x == nil or y == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = tonumber(value.z) or 0,
  }
end


local function readSceneTimeOfDay()
  if not core_environment or type(core_environment.getTimeOfDay) ~= "function" then
    return nil
  end
  local ok, value = pcall(core_environment.getTimeOfDay)
  if not ok then
    ui_photomode_shared.logDebug("getTimeOfDay failed: " .. tostring(value))
    return nil
  end
  return type(value) == "table" and value or nil
end

local function readSceneEnvironmentState()
  if not core_environment or type(core_environment.getState) ~= "function" then
    return nil
  end
  local ok, value = pcall(core_environment.getState)
  if not ok then
    ui_photomode_shared.logDebug("getState failed: " .. tostring(value))
    return nil
  end
  return type(value) == "table" and value or nil
end

local function readSceneNorthOverride()
  if not core_celestial or type(core_celestial.getNorthOffset) ~= "function" then
    return nil
  end
  local ok, value = pcall(core_celestial.getNorthOffset)
  if not ok then
    ui_photomode_shared.logDebug("getNorthOffset failed: " .. tostring(value))
    return nil
  end
  return tonumber(value)
end

local function readSceneCelestialState()
  if not core_celestial or type(core_celestial.getState) ~= "function" then
    return nil
  end
  local ok, value = pcall(core_celestial.getState)
  if not ok then
    ui_photomode_shared.logDebug("core_celestial.getState failed: " .. tostring(value))
    return nil
  end
  return type(value) == "table" and value or nil
end

local function normalizeSceneTime(value)
  return ui_photomode_shared.clampNumber(value, SCENE_LIMITS.timeMin, SCENE_LIMITS.timeMax, SCENE_LIMITS.timeMin)
end

local function normalizeSceneCloudCover(value)
  return ui_photomode_shared.clampNumber(value, SCENE_LIMITS.cloudCoverMin, SCENE_LIMITS.cloudCoverMax, SCENE_LIMITS.cloudCoverMin)
end

local function normalizeSceneFogDensity(value)
  return ui_photomode_shared.clampNumber(value, SCENE_LIMITS.fogDensityMin, SCENE_LIMITS.fogDensityMax, SCENE_LIMITS.fogDensityMin)
end

local function normalizeSceneFogAtmosphereHeight(value)
  return ui_photomode_shared.clampNumber(value, SCENE_LIMITS.fogAtmosphereHeightMin, SCENE_LIMITS.fogAtmosphereHeightMax, SCENE_LIMITS.fogAtmosphereHeightMin)
end

local function normalizeSceneNorthOverride(value)
  local numericValue = tonumber(value)
  if numericValue == nil then
    return 0
  end
  local normalizedValue = ((numericValue + 180) % 360) - 180
  if normalizedValue == -180 and numericValue > 0 then
    return 180
  end
  return normalizedValue
end


local function captureSceneSerializableState()
  local timeOfDay = readSceneTimeOfDay()
  local environmentState = readSceneEnvironmentState()
  local celestialState = readSceneCelestialState()
  local celestialDisplay = type(celestialState and celestialState.display) == "table" and celestialState.display or {}
  local celestialMeteor = type(celestialState and celestialState.meteor) == "table" and celestialState.meteor or {}
  local celestial = {
    meteor = {
      ratePreset = celestialMeteor.ratePreset,
      test = celestialMeteor.test,
      rate = tonumber(celestialMeteor.rate),
    },
    display = copyFields(celestialDisplay, SCENE_CELESTIAL_DISPLAY_FIELDS),
  }
  if not tableHasAnyValue(celestial.meteor) then
    celestial.meteor = nil
  end
  if not tableHasAnyValue(celestial.display) then
    celestial.display = nil
  end
  return {
    time = tonumber(timeOfDay and timeOfDay.time),
    play = timeOfDay and timeOfDay.play == true,
    year = tonumber(timeOfDay and timeOfDay.year),
    month = tonumber(timeOfDay and timeOfDay.month),
    day = tonumber(timeOfDay and timeOfDay.day),
    cloudCover = tonumber(environmentState and environmentState.cloudCover),
    fogDensity = tonumber(environmentState and environmentState.fogDensity),
    fogAtmosphereHeight = tonumber(environmentState and environmentState.fogAtmosphereHeight),
    windSpeed = tonumber(environmentState and environmentState.windSpeed),
    cloudWindDirection = copyVector(environmentState and environmentState.cloudWindDirection),
    groundWind = copyVector(environmentState and environmentState.groundWind),
    northOverride = readSceneNorthOverride(),
    celestial = tableHasAnyValue(celestial) and celestial or nil,
  }
end

local function captureSceneBookmarkState()
  local sceneState = captureSceneSerializableState()
  return {
    time = sceneState.time,
    play = sceneState.play,
    year = sceneState.year,
    month = sceneState.month,
    day = sceneState.day,
    cloudCover = sceneState.cloudCover,
    fogDensity = sceneState.fogDensity,
    fogAtmosphereHeight = sceneState.fogAtmosphereHeight,
    windSpeed = sceneState.windSpeed,
    cloudWindDirection = sceneState.cloudWindDirection,
    groundWind = sceneState.groundWind,
    northOverride = sceneState.northOverride,
    celestial = sceneState.celestial,
  }
end

local function formatSceneTimeOfDayDebugState(sceneState)
  if type(sceneState) ~= "table" then
    return tostring(sceneState)
  end

  return string.format(
    "{time=%s, play=%s, dayLength=%s}",
    tostring(sceneState.time),
    tostring(sceneState.play),
    tostring(sceneState.dayLength)
  )
end

local function logSceneTimeOfDayDebug(label, sceneState)
  if not isDebugEnabled then
    return
  end

  ui_photomode_shared.logDebug(label .. " " .. formatSceneTimeOfDayDebugState(sceneState))
end

local function hasSceneStateFields(sceneState)
  return type(sceneState) == "table"
    and (
      sceneState.time ~= nil
      or sceneState.play ~= nil
      or sceneState.year ~= nil
      or sceneState.month ~= nil
      or sceneState.day ~= nil
      or sceneState.cloudCover ~= nil
      or sceneState.fogDensity ~= nil
      or sceneState.fogAtmosphereHeight ~= nil
      or sceneState.windSpeed ~= nil
      or sceneState.cloudWindDirection ~= nil
      or sceneState.groundWind ~= nil
      or sceneState.northOverride ~= nil
      or sceneState.celestial ~= nil
    )
end

local function hasSceneBookmarkFields(sceneState)
  return type(sceneState) == "table"
    and (
      sceneState.time ~= nil
      or sceneState.play ~= nil
      or sceneState.year ~= nil
      or sceneState.month ~= nil
      or sceneState.day ~= nil
      or sceneState.cloudCover ~= nil
      or sceneState.fogDensity ~= nil
      or sceneState.fogAtmosphereHeight ~= nil
      or sceneState.windSpeed ~= nil
      or sceneState.cloudWindDirection ~= nil
      or sceneState.groundWind ~= nil
      or sceneState.northOverride ~= nil
      or sceneState.celestial ~= nil
    )
end

local function buildSceneAvailability(sceneState)
  return {
    timeOfDay = sceneState.time ~= nil,
    cloudCover = sceneState.cloudCover ~= nil,
    fogDensity = sceneState.fogDensity ~= nil,
    fogAtmosphereHeight = sceneState.fogAtmosphereHeight ~= nil,
    windSpeed = sceneState.windSpeed ~= nil,
    cloudWindDirection = sceneState.cloudWindDirection ~= nil,
    groundWind = sceneState.groundWind ~= nil,
    northOverride = sceneState.northOverride ~= nil,
    celestial = sceneState.celestial ~= nil,
  }
end

local function buildSceneState()
  local sceneState = captureSceneSerializableState()
  return {
    sessionActive = ui_photomode_shared.S.sessionActive == true,
    bookmarkAvailable = ui_photomode_shared.S.savedEnvironmentBookmark ~= nil,
    availability = buildSceneAvailability(sceneState),
    time = sceneState.time ~= nil and normalizeSceneTime(sceneState.time) or nil,
    play = sceneState.play,
    year = sceneState.year,
    month = sceneState.month,
    day = sceneState.day,
    cloudCover = sceneState.cloudCover ~= nil and normalizeSceneCloudCover(sceneState.cloudCover) or nil,
    fogDensity = sceneState.fogDensity ~= nil and normalizeSceneFogDensity(sceneState.fogDensity) or nil,
    fogAtmosphereHeight = sceneState.fogAtmosphereHeight ~= nil and normalizeSceneFogAtmosphereHeight(sceneState.fogAtmosphereHeight) or nil,
    windSpeed = sceneState.windSpeed,
    cloudWindDirection = sceneState.cloudWindDirection,
    groundWind = sceneState.groundWind,
    northOverride = sceneState.northOverride ~= nil and normalizeSceneNorthOverride(sceneState.northOverride) or nil,
    celestial = sceneState.celestial,
  }
end

local function captureSceneRestoreState()
  local sceneState = captureSceneSerializableState()
  ui_photomode_shared.S.sessionSceneRestoreState = hasSceneStateFields(sceneState) and {
    time = sceneState.time,
    play = sceneState.play,
    year = sceneState.year,
    month = sceneState.month,
    day = sceneState.day,
    cloudCover = sceneState.cloudCover,
    fogDensity = sceneState.fogDensity,
    fogAtmosphereHeight = sceneState.fogAtmosphereHeight,
    windSpeed = sceneState.windSpeed,
    cloudWindDirection = sceneState.cloudWindDirection,
    groundWind = sceneState.groundWind,
    northOverride = sceneState.northOverride,
    celestial = sceneState.celestial,
  } or nil
  logSceneTimeOfDayDebug("captureSceneRestoreState", ui_photomode_shared.S.sessionSceneRestoreState)
end

local function applySceneTimeOfDayPatch(sceneState, options)
  if type(sceneState) ~= "table" then
    return false, "scene_state_invalid"
  end
  local hasTimeOfDayPatch = false
  for _, key in ipairs(SCENE_TOD_PRESET_FIELDS) do
    if sceneState[key] ~= nil then
      hasTimeOfDayPatch = true
      break
    end
  end
  if not hasTimeOfDayPatch then
    return true
  end
  if not core_environment or (type(core_environment.setState) ~= "function" and type(core_environment.setTimeOfDay) ~= "function") then
    return false, "scene_api_unavailable"
  end

  local baseState = readSceneTimeOfDay()
  if type(baseState) ~= "table" then
    return false, "scene_tod_unavailable"
  end

  options = type(options) == "table" and options or {}

  logSceneTimeOfDayDebug("applySceneTimeOfDayPatch incoming", sceneState)
  logSceneTimeOfDayDebug("applySceneTimeOfDayPatch base", baseState)

  local nextState = {}
  if sceneState.time ~= nil then
    nextState.time = normalizeSceneTime(sceneState.time)
    if sceneState.play == nil then
      nextState.play = baseState.play == true
    end
  end
  if sceneState.play ~= nil then
    nextState.play = sceneState.play == true
  end
  if sceneState.year ~= nil then
    nextState.year = tonumber(sceneState.year)
  end
  if sceneState.month ~= nil then
    nextState.month = tonumber(sceneState.month)
  end
  if sceneState.day ~= nil then
    nextState.day = tonumber(sceneState.day)
  end

  local ok, err
  if core_environment and type(core_environment.setState) == "function" then
    ok, err = pcall(core_environment.setState, nextState, options.lerpSeconds)
  else
    ok, err = pcall(core_environment.setTimeOfDay, nextState)
  end
  if not ok then
    log("E", logTag, "applySceneTimeOfDayPatch failed: " .. tostring(err))
    return false, "scene_set_failed"
  end

  logSceneTimeOfDayDebug("applySceneTimeOfDayPatch after", readSceneTimeOfDay())
  return true
end

local function applySceneEnvironmentPatch(sceneState, options)
  if type(sceneState) ~= "table" then
    return false, "scene_state_invalid"
  end
  local hasWeatherPatch = false
  for _, key in ipairs(SCENE_WEATHER_PRESET_FIELDS) do
    if sceneState[key] ~= nil then
      hasWeatherPatch = true
      break
    end
  end
  if not hasWeatherPatch then
    return true
  end
  if not core_environment or type(core_environment.setState) ~= "function" then
    return false, "scene_api_unavailable"
  end

  local nextState = {}
  if sceneState.cloudCover ~= nil then
    nextState.cloudCover = normalizeSceneCloudCover(sceneState.cloudCover)
  end
  if sceneState.fogDensity ~= nil then
    nextState.fogDensity = normalizeSceneFogDensity(sceneState.fogDensity)
  end
  if sceneState.fogAtmosphereHeight ~= nil then
    nextState.fogAtmosphereHeight = normalizeSceneFogAtmosphereHeight(sceneState.fogAtmosphereHeight)
  end
  if sceneState.windSpeed ~= nil then
    nextState.windSpeed = tonumber(sceneState.windSpeed)
  end
  if sceneState.cloudWindDirection ~= nil then
    nextState.cloudWindDirection = copyVector(sceneState.cloudWindDirection)
  end
  if sceneState.groundWind ~= nil then
    nextState.groundWind = copyVector(sceneState.groundWind)
  end

  options = type(options) == "table" and options or {}
  local ok, err = pcall(core_environment.setState, nextState, options.lerpSeconds)
  if not ok then
    log("E", logTag, "applySceneEnvironmentPatch failed: " .. tostring(err))
    return false, "scene_set_failed"
  end
  return true
end

local function applySceneCelestialPatch(sceneState)
  if type(sceneState) ~= "table" then
    return false, "scene_state_invalid"
  end
  local celestialState = type(sceneState.celestial) == "table" and sceneState.celestial or nil
  if not celestialState then
    return true
  end
  if not core_celestial then
    return false, "scene_api_unavailable"
  end

  local meteorState = type(celestialState.meteor) == "table" and celestialState.meteor or {}
  if meteorState.test == true and meteorState.rate ~= nil and type(core_celestial.setMeteorTestRate) == "function" then
    core_celestial.setMeteorTestRate(tonumber(meteorState.rate))
  elseif meteorState.ratePreset ~= nil and type(core_celestial.setMeteorRatePreset) == "function" then
    core_celestial.setMeteorRatePreset(tostring(meteorState.ratePreset))
  elseif meteorState.test == false and type(core_celestial.setMeteorRatePreset) == "function" then
    core_celestial.setMeteorRatePreset("default")
  end

  local displayState = type(celestialState.display) == "table" and celestialState.display or {}
  if type(core_celestial.setDisplayOption) == "function" then
    for _, key in ipairs(SCENE_CELESTIAL_DISPLAY_FIELDS) do
      if displayState[key] ~= nil then
        core_celestial.setDisplayOption(key, displayState[key] == true)
      end
    end
  end

  return true
end

local function applySceneNorthOverridePatch(sceneState)
  if type(sceneState) ~= "table" then
    return false, "scene_state_invalid"
  end
  if sceneState.northOverride == nil then
    return true
  end
  if not core_celestial or type(core_celestial.setNorthOffset) ~= "function" then
    return false, "scene_celestial_api_unavailable"
  end

  local ok, err = pcall(core_celestial.setNorthOffset, normalizeSceneNorthOverride(sceneState.northOverride))
  if not ok then
    log("E", logTag, "applySceneNorthOverridePatch failed: " .. tostring(err))
    return false, "scene_set_failed"
  end
  return true
end

local function restoreSceneState()
  if not ui_photomode_shared.S.sessionSceneRestoreState then
    return
  end

  local restoreState = ui_photomode_shared.S.sessionSceneRestoreState
  ui_photomode_shared.S.sessionSceneRestoreState = nil
  logSceneTimeOfDayDebug("restoreSceneState target", restoreState)

  local ok, reason = applySceneTimeOfDayPatch(restoreState)
  if not ok then
    ui_photomode_shared.logDebug("restoreSceneState time restore skipped: " .. tostring(reason))
  end

  ok, reason = applySceneEnvironmentPatch(restoreState)
  if not ok then
    ui_photomode_shared.logDebug("restoreSceneState environment restore skipped: " .. tostring(reason))
  end

  ok, reason = applySceneNorthOverridePatch(restoreState)
  if not ok then
    ui_photomode_shared.logDebug("restoreSceneState north override restore skipped: " .. tostring(reason))
  end

  ok, reason = applySceneCelestialPatch(restoreState)
  if not ok then
    ui_photomode_shared.logDebug("restoreSceneState celestial restore skipped: " .. tostring(reason))
  end

  logSceneTimeOfDayDebug("restoreSceneState after", readSceneTimeOfDay())
end

local function captureSavedEnvironmentBookmark()
  local sceneState = captureSceneBookmarkState()
  if not hasSceneBookmarkFields(sceneState) then
    ui_photomode_shared.logDebug("saved environment bookmark capture skipped")
    return false
  end

  ui_photomode_shared.S.savedEnvironmentBookmark = sceneState
  logSceneTimeOfDayDebug("captureSavedEnvironmentBookmark", ui_photomode_shared.S.savedEnvironmentBookmark)
  return true
end


function M.setSceneState(partialState)
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end
  if type(partialState) ~= "table" then
    return {
      ok = false,
      reason = "scene_state_invalid",
    }
  end

  logSceneTimeOfDayDebug("setSceneState partial", partialState)
  local lerpSeconds = tonumber(partialState.__lerpSeconds) or 0

  local sceneChanged = false
  if partialState.time ~= nil then
    local ok, reason = applySceneTimeOfDayPatch(partialState, {lerpSeconds = lerpSeconds})
    if not ok then
      return {
        ok = false,
        reason = reason or "scene_set_failed",
      }
    end
    sceneChanged = true
  end

  if partialState.cloudCover ~= nil or partialState.fogDensity ~= nil or partialState.fogAtmosphereHeight ~= nil then
    local ok, reason = applySceneEnvironmentPatch(partialState, {lerpSeconds = lerpSeconds})
    if not ok then
      return {
        ok = false,
        reason = reason or "scene_set_failed",
      }
    end
    sceneChanged = true
  end

  if partialState.northOverride ~= nil then
    local ok, reason = applySceneNorthOverridePatch(partialState)
    if not ok then
      return {
        ok = false,
        reason = reason or "scene_set_failed",
      }
    end
    sceneChanged = true
  end

  if not sceneChanged then
    return {
      ok = false,
      reason = "scene_patch_empty",
      state = buildSceneState(),
    }
  end

  return {
    ok = true,
    state = buildSceneState(),
  }
end

function M.saveEnvironmentBookmark()
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end

  if not captureSavedEnvironmentBookmark() then
    return {
      ok = false,
      reason = "scene_state_unavailable",
    }
  end

  return {
    ok = true,
    state = buildSceneState(),
  }
end

function M.loadEnvironmentBookmark()
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end

  if not ui_photomode_shared.S.savedEnvironmentBookmark then
    return {
      ok = false,
      reason = "bookmark_unavailable",
    }
  end

  local bookmark = ui_photomode_shared.S.savedEnvironmentBookmark
  logSceneTimeOfDayDebug("loadEnvironmentBookmark target", bookmark)

  local ok, reason = applySceneTimeOfDayPatch(bookmark)
  if not ok then
    return {
      ok = false,
      reason = reason or "scene_set_failed",
      state = buildSceneState(),
    }
  end

  ok, reason = applySceneEnvironmentPatch(bookmark)
  if not ok then
    return {
      ok = false,
      reason = reason or "scene_set_failed",
      state = buildSceneState(),
    }
  end

  ok, reason = applySceneNorthOverridePatch(bookmark)
  if not ok then
    return {
      ok = false,
      reason = reason or "scene_set_failed",
      state = buildSceneState(),
    }
  end

  ok, reason = applySceneCelestialPatch(bookmark)
  if not ok then
    return {
      ok = false,
      reason = reason or "scene_set_failed",
      state = buildSceneState(),
    }
  end

  logSceneTimeOfDayDebug("loadEnvironmentBookmark after", readSceneTimeOfDay())
  return {
    ok = true,
    state = buildSceneState(),
  }
end

function M.getSceneState()
  local sceneState = buildSceneState()
  sceneState.ok = ui_photomode_shared.S.sessionActive == true
  if not sceneState.ok then
    sceneState.reason = "session_inactive"
  end
  return sceneState
end

local function buildScenePresetState(sceneState)
  sceneState = sceneState or buildSceneState()
  return {
    time = sceneState.time,
    play = sceneState.play,
    year = sceneState.year,
    month = sceneState.month,
    day = sceneState.day,
    cloudCover = sceneState.cloudCover,
    fogDensity = sceneState.fogDensity,
    fogAtmosphereHeight = sceneState.fogAtmosphereHeight,
    windSpeed = sceneState.windSpeed,
    cloudWindDirection = sceneState.cloudWindDirection,
    groundWind = sceneState.groundWind,
    northOverride = sceneState.northOverride,
    celestial = sceneState.celestial,
  }
end

local function buildAdvancedRenderPresetState()
  if ui_photomode_advancedRender and type(ui_photomode_advancedRender.buildMetadataState) == "function" then
    return ui_photomode_advancedRender.buildMetadataState()
  end
  return nil
end

local function buildAdvancedRenderDefaultPresetState()
  if ui_photomode_advancedRender and type(ui_photomode_advancedRender.captureDefaultPresetState) == "function" then
    return ui_photomode_advancedRender.captureDefaultPresetState()
  end
  return nil
end

local function buildCombinedScenePresetState(sceneState, advancedRenderState)
  return {
    scene = buildScenePresetState(sceneState),
    advancedRender = advancedRenderState or buildAdvancedRenderPresetState(),
  }
end

local function applyScenePresetState(sceneState)
  sceneState = type(sceneState) == "table" and sceneState or {}
  local timeOk, timeReason = applySceneTimeOfDayPatch(sceneState)
  if not timeOk then
    return { ok = false, reason = timeReason or "scene_set_failed" }
  end

  local envOk, envReason = applySceneEnvironmentPatch(sceneState)
  if not envOk then
    return { ok = false, reason = envReason or "scene_set_failed" }
  end

  local northOk, northReason = applySceneNorthOverridePatch(sceneState)
  if not northOk then
    return { ok = false, reason = northReason or "scene_set_failed" }
  end

  local celestialOk, celestialReason = applySceneCelestialPatch(sceneState)
  if not celestialOk then
    return { ok = false, reason = celestialReason or "scene_set_failed" }
  end

  return { state = buildSceneState() }
end

local function buildCombinedScenePresetStateForPart(presetState, part)
  if part == nil or part == "" or part == "all" then
    return presetState
  end

  local sceneState = type(presetState.scene) == "table" and presetState.scene or {}
  local advancedRenderState = type(presetState.advancedRender) == "table" and presetState.advancedRender or {}

  if part == "environment" then
    return {
      scene = {
        time = sceneState.time,
        play = sceneState.play,
        year = sceneState.year,
        month = sceneState.month,
        day = sceneState.day,
      },
    }
  end

  if part == "shadows" then
    local advancedRenderPart = {
      shadowsQualityMode = advancedRenderState.shadowsQualityMode,
      lastSplitCastersEnabled = advancedRenderState.lastSplitCastersEnabled,
      vehicleShadowEnabled = advancedRenderState.vehicleShadowEnabled,
    }
    return tableHasAnyValue(advancedRenderPart) and { advancedRender = advancedRenderPart } or {}
  end

  if part == "detailTerrain" then
    local advancedRenderPart = {
      detailAdjust = advancedRenderState.detailAdjust,
      terrainLodScale = advancedRenderState.terrainLodScale,
      grassDensity = advancedRenderState.grassDensity,
      cloudQualityMode = advancedRenderState.cloudQualityMode,
    }
    return tableHasAnyValue(advancedRenderPart) and { advancedRender = advancedRenderPart } or {}
  end

  if part == "weather" then
    return {
      scene = {
        cloudCover = sceneState.cloudCover,
        fogDensity = sceneState.fogDensity,
        fogAtmosphereHeight = sceneState.fogAtmosphereHeight,
        windSpeed = sceneState.windSpeed,
        cloudWindDirection = sceneState.cloudWindDirection,
        groundWind = sceneState.groundWind,
      },
    }
  end

  if part == "celestial" then
    return {
      scene = {
        northOverride = sceneState.northOverride,
        celestial = sceneState.celestial,
      },
    }
  end

  return nil, "preset_part_invalid"
end

function M.capturePresetState()
  return buildCombinedScenePresetState()
end

function M.captureDefaultPresetState()
  local sceneState = ui_photomode_shared.S.sessionSceneRestoreState
  local advancedRenderState = buildAdvancedRenderDefaultPresetState()
  if type(sceneState) ~= "table" and type(advancedRenderState) ~= "table" then
    return nil
  end

  return buildCombinedScenePresetState(sceneState or buildSceneState(), advancedRenderState)
end

function M.applyPresetState(state, options)
  local presetState = type(state) == "table" and state or {}
  options = type(options) == "table" and options or {}
  local filteredState, filterReason = buildCombinedScenePresetStateForPart(presetState, options.part)
  if not filteredState then
    return { ok = false, reason = filterReason or "preset_part_invalid" }
  end
  presetState = filteredState

  local sceneState = type(presetState.scene) == "table" and presetState.scene or {}
  local sceneResult = applyScenePresetState(sceneState)
  if sceneResult and sceneResult.ok == false then
    return sceneResult
  end

  local advancedRenderState = type(presetState.advancedRender) == "table" and presetState.advancedRender or nil
  if advancedRenderState then
    local advancedResult = ui_photomode_advancedRender.applyPresetState(advancedRenderState)
    if advancedResult and advancedResult.ok == false then
      return advancedResult
    end
  end

  return { state = buildCombinedScenePresetState() }
end


M.captureRestoreState = captureSceneRestoreState
M.restoreState = restoreSceneState
M.buildState = buildSceneState
function M.buildMetadataState()
  local sceneState = buildSceneState()
  return {
    time = sceneState.time,
    play = sceneState.play,
    year = sceneState.year,
    month = sceneState.month,
    day = sceneState.day,
    cloudCover = sceneState.cloudCover,
    fogDensity = sceneState.fogDensity,
    fogAtmosphereHeight = sceneState.fogAtmosphereHeight,
    windSpeed = sceneState.windSpeed,
    cloudWindDirection = sceneState.cloudWindDirection,
    groundWind = sceneState.groundWind,
    northOverride = sceneState.northOverride,
    celestial = sceneState.celestial,
  }
end
M.captureSerializableState = captureSceneSerializableState
M.logTimeOfDayDebug = logSceneTimeOfDayDebug

return M
