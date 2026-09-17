-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_photomode_shared", "core_settings_graphic" }


local ADVANCED_RENDER_LIMITS = {
  detailAdjustMin = 0.5,
  detailAdjustMax = 5,
  terrainLodScaleMin = 0.001,
  terrainLodScaleMax = 2,
  grassDensityMin = 0,
  grassDensityMax = 1,
  manualEvMin = -20,
  manualEvMax = 20,
}

local ADVANCED_RENDER_NUMBER_FIELDS = {
  detailAdjust = {
    min = ADVANCED_RENDER_LIMITS.detailAdjustMin,
    max = ADVANCED_RENDER_LIMITS.detailAdjustMax,
    default = 2,
  },
  terrainLodScale = {
    min = ADVANCED_RENDER_LIMITS.terrainLodScaleMin,
    max = ADVANCED_RENDER_LIMITS.terrainLodScaleMax,
    default = 0.75,
  },
  grassDensity = {
    min = ADVANCED_RENDER_LIMITS.grassDensityMin,
    max = ADVANCED_RENDER_LIMITS.grassDensityMax,
    default = 1,
  },
}

local CLOUD_QUALITY_MODES = {
  Low = {
    vrtDownsampleFactor = 8,
    shadowLutUpdateGroupSize = 8,
  },
  Normal = {
    vrtDownsampleFactor = 6,
    shadowLutUpdateGroupSize = 4,
  },
  High = {
    vrtDownsampleFactor = 4,
    shadowLutUpdateGroupSize = 2,
  },
  Ultra = {
    vrtDownsampleFactor = 2,
    shadowLutUpdateGroupSize = 2,
  },
}

local SHADOW_QUALITY_MODES = { "Lowest", "Low", "Normal", "High", "Ultra" }


local function getAdvancedRenderDefaultEnabled()
  return shipping_build ~= true
end

local function isAdvancedRenderUnlockVisible()
  return shipping_build == true
end

local function isAdvancedRenderTuningEnabled()
  if ui_photomode_shared.S.advancedRenderTuningEnabledOverride ~= nil then
    return ui_photomode_shared.S.advancedRenderTuningEnabledOverride == true
  end

  return getAdvancedRenderDefaultEnabled()
end

local function normalizeShadowQualityMode(value, fallback)
  if type(value) == "string" then
    for _, mode in ipairs(SHADOW_QUALITY_MODES) do
      if mode == value then
        return mode
      end
    end
  end
  return fallback
end

local function getShadowQualityOption()
  if not core_settings_graphic or type(core_settings_graphic.getOptions) ~= "function" then
    return nil
  end

  return core_settings_graphic.getOptions("GraphicShadowsQuality")
end

local function readShadowQualityMode()
  local option = getShadowQualityOption()
  if option and type(option.get) == "function" then
    return option.get()
  end

  return ui_photomode_shared.readSettingValue("GraphicShadowsQuality")
end

local function applyShadowQualityMode(value)
  ui_photomode_shared.writeSettingValue("GraphicShadowsQuality", value)
  local option = getShadowQualityOption()
  if option and type(option.set) == "function" then
    option.set(value)
  end
end

local function readSettingBoolean(settingName)
  local value = ui_photomode_shared.readSettingValue(settingName)
  if type(value) == "boolean" then
    return value
  end
  return nil
end

local function captureCloudQualitySerializableState()
  local cloudLayer = CloudLayer
  return {
    settingName = ui_photomode_shared.readSettingValue("GraphicCloudsQuality"),
    vrtDownsampleFactor = tonumber(cloudLayer and cloudLayer.vrtDownsampleFactor),
    shadowLutUpdateGroupSize = tonumber(cloudLayer and cloudLayer.shadowLutUpdateGroupSize),
  }
end

local function normalizeCloudQualityMode(value, fallback)
  if type(value) == "string" and CLOUD_QUALITY_MODES[value] then
    return value
  end

  local numericValue = tonumber(value)
  if numericValue ~= nil then
    if numericValue <= 2 then
      return "Ultra"
    elseif numericValue <= 4 then
      return "High"
    elseif numericValue <= 6 then
      return "Normal"
    else
      return "Low"
    end
  end

  return fallback
end

local function getCloudQualityModeData(mode)
  local normalizedMode = normalizeCloudQualityMode(mode, nil)
  return normalizedMode and CLOUD_QUALITY_MODES[normalizedMode] or nil, normalizedMode
end

local function cloudQualityStateToMode(cloudState)
  if type(cloudState) ~= "table" then
    return nil
  end

  local settingMode = normalizeCloudQualityMode(
    cloudState.settingName or cloudState.cloudQualitySettingName,
    nil
  )
  if settingMode then
    return settingMode
  end

  return normalizeCloudQualityMode(
    cloudState.vrtDownsampleFactor or cloudState.cloudVrtDownsampleFactor,
    nil
  )
end

local function getAdvancedRenderNumberField(fieldName)
  return ADVANCED_RENDER_NUMBER_FIELDS[fieldName]
end

local function normalizeAdvancedRenderNumber(fieldName, value)
  local field = getAdvancedRenderNumberField(fieldName)
  return ui_photomode_shared.clampNumber(value, field.min, field.max, field.default)
end

local ADVANCED_RENDER_DISPLAY_FIELDS = {
  {
    key = "detailAdjust",
    normalize = function(value) return normalizeAdvancedRenderNumber("detailAdjust", value) end,
  },
  {
    key = "terrainLodScale",
    normalize = function(value) return normalizeAdvancedRenderNumber("terrainLodScale", value) end,
  },
  {
    key = "grassDensity",
    normalize = function(value) return normalizeAdvancedRenderNumber("grassDensity", value) end,
  },
  { key = "shadowsQualitySettingName", outputKey = "shadowsQualityMode" },
  { key = "lastSplitCastersEnabled" },
  { key = "vehicleShadowEnabled" },
}

local function buildAdvancedRenderDisplayState(state)
  local out = ui_photomode_shared.buildDescribedState(state, ADVANCED_RENDER_DISPLAY_FIELDS)
  out.cloudQualityMode = cloudQualityStateToMode(state)
  return out
end

local function captureAdvancedRenderSerializableState()
  local cloudQualityState = captureCloudQualitySerializableState()

  return {
    detailAdjust = tonumber(ui_photomode_shared.readVariableRegistryValue("$pref::TS::detailAdjust")),
    terrainLodScale = tonumber(ui_photomode_shared.readVariableRegistryValue("$pref::Terrain::lodScale")),
    grassDensity = tonumber(ui_photomode_shared.readSettingValue("GraphicGrassDensity")),
    shadowsQualitySettingName = normalizeShadowQualityMode(readShadowQualityMode(), nil),
    lastSplitCastersEnabled = readSettingBoolean("lastSplitCastersEnabled"),
    vehicleShadowEnabled = readSettingBoolean("vehicleShadowEnabled"),
    cloudQualitySettingName = cloudQualityState.settingName,
    cloudVrtDownsampleFactor = cloudQualityState.vrtDownsampleFactor,
    cloudShadowLutUpdateGroupSize = cloudQualityState.shadowLutUpdateGroupSize,
  }
end

local function hasAdvancedRenderStateFields(state)
  if type(state) ~= "table" then
    return false
  end

  return ui_photomode_shared.hasAnyDescribedField(state, ADVANCED_RENDER_DISPLAY_FIELDS)
    or state.cloudQualitySettingName ~= nil
    or state.cloudVrtDownsampleFactor ~= nil
    or state.cloudShadowLutUpdateGroupSize ~= nil
end

local function buildAdvancedRenderAvailability(state)
  return {
    detailAdjust = state.detailAdjust ~= nil,
    terrainLodScale = state.terrainLodScale ~= nil,
    grassDensity = state.grassDensity ~= nil,
    shadowsQuality = state.shadowsQualitySettingName ~= nil,
    lastSplitCasters = state.lastSplitCastersEnabled ~= nil,
    vehicleShadow = state.vehicleShadowEnabled ~= nil,
    cloudQuality = cloudQualityStateToMode(state) ~= nil,
  }
end

local function buildAdvancedRenderDefaults()
  if not ui_photomode_shared.S.sessionAdvancedRenderRestoreState then
    return nil
  end

  return buildAdvancedRenderDisplayState(ui_photomode_shared.S.sessionAdvancedRenderRestoreState)
end

local function buildAdvancedRenderState()
  local state = captureAdvancedRenderSerializableState()
  local defaults = buildAdvancedRenderDefaults()

  local displayState = buildAdvancedRenderDisplayState(state)
  displayState.sessionActive = ui_photomode_shared.S.sessionActive == true
  displayState.bookmarkAvailable = ui_photomode_shared.S.savedAdvancedRenderBookmark ~= nil
  displayState.availability = buildAdvancedRenderAvailability(state)
  displayState.defaultsAvailable = defaults ~= nil
  displayState.defaults = defaults
  return displayState
end

local function captureAdvancedRenderRestoreState()
  local state = captureAdvancedRenderSerializableState()
  ui_photomode_shared.S.sessionAdvancedRenderRestoreState = hasAdvancedRenderStateFields(state) and state or nil
end

local function captureSavedAdvancedRenderBookmark()
  local state = captureAdvancedRenderSerializableState()
  if not hasAdvancedRenderStateFields(state) then
    ui_photomode_shared.logDebug("saved advanced render bookmark capture skipped")
    return false
  end

  ui_photomode_shared.S.savedAdvancedRenderBookmark = state
  return true
end

local function applyAdvancedRenderRawState(state)
  if type(state) ~= "table" then
    return false, "advanced_render_state_invalid"
  end

  local changed = false

  if state.detailAdjust ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$pref::TS::detailAdjust", tonumber(state.detailAdjust))
    changed = true
  end

  if state.terrainLodScale ~= nil then
    ui_photomode_shared.writeVariableRegistryValue("$pref::Terrain::lodScale", tonumber(state.terrainLodScale))
    changed = true
  end

  if state.grassDensity ~= nil then
    ui_photomode_shared.writeSettingValue("GraphicGrassDensity", tonumber(state.grassDensity))
    changed = true
  end

  if state.shadowsQualitySettingName ~= nil then
    applyShadowQualityMode(tostring(state.shadowsQualitySettingName))
    changed = true
  end

  if state.lastSplitCastersEnabled ~= nil then
    ui_photomode_shared.writeSettingValue("lastSplitCastersEnabled", state.lastSplitCastersEnabled == true)
    changed = true
  end

  if state.vehicleShadowEnabled ~= nil then
    ui_photomode_shared.writeSettingValue("vehicleShadowEnabled", state.vehicleShadowEnabled == true)
    changed = true
  end

  local cloudLayer = CloudLayer
  if cloudLayer and state.cloudVrtDownsampleFactor ~= nil then
    cloudLayer.vrtDownsampleFactor = tonumber(state.cloudVrtDownsampleFactor)
    changed = true
  end
  if cloudLayer and state.cloudShadowLutUpdateGroupSize ~= nil then
    cloudLayer.shadowLutUpdateGroupSize = tonumber(state.cloudShadowLutUpdateGroupSize)
    changed = true
  end
  if state.cloudQualitySettingName ~= nil then
    ui_photomode_shared.writeSettingValue("GraphicCloudsQuality", tostring(state.cloudQualitySettingName))
    changed = true
  end

  if not changed then
    return false, "advanced_render_patch_empty"
  end

  return true
end

local function applyAdvancedRenderStatePatch(partialState)
  if type(partialState) ~= "table" then
    return false, "advanced_render_state_invalid"
  end

  local rawState = {}
  local changed = false

  if partialState.detailAdjust ~= nil then
    rawState.detailAdjust = normalizeAdvancedRenderNumber("detailAdjust", partialState.detailAdjust)
    changed = true
  end

  if partialState.terrainLodScale ~= nil then
    rawState.terrainLodScale = normalizeAdvancedRenderNumber("terrainLodScale", partialState.terrainLodScale)
    changed = true
  end

  if partialState.grassDensity ~= nil then
    rawState.grassDensity = normalizeAdvancedRenderNumber("grassDensity", partialState.grassDensity)
    changed = true
  end

  if partialState.shadowsQualityMode ~= nil then
    local normalizedMode = normalizeShadowQualityMode(partialState.shadowsQualityMode, nil)
    if not normalizedMode then
      return false, "shadow_quality_invalid"
    end
    rawState.shadowsQualitySettingName = normalizedMode
    changed = true
  end

  if partialState.lastSplitCastersEnabled ~= nil then
    rawState.lastSplitCastersEnabled = ui_photomode_shared.normalizeBoolean(partialState.lastSplitCastersEnabled, false)
    changed = true
  end

  if partialState.vehicleShadowEnabled ~= nil then
    rawState.vehicleShadowEnabled = ui_photomode_shared.normalizeBoolean(partialState.vehicleShadowEnabled, false)
    changed = true
  end

  if partialState.cloudQualityMode ~= nil then
    local modeData, normalizedMode = getCloudQualityModeData(partialState.cloudQualityMode)
    if not modeData or not normalizedMode then
      return false, "cloud_quality_invalid"
    end
    rawState.cloudQualitySettingName = normalizedMode
    rawState.cloudVrtDownsampleFactor = modeData.vrtDownsampleFactor
    rawState.cloudShadowLutUpdateGroupSize = modeData.shadowLutUpdateGroupSize
    changed = true
  end

  if not changed then
    return false, "advanced_render_patch_empty"
  end

  return applyAdvancedRenderRawState(rawState)
end

local function restoreAdvancedRenderState()
  if not ui_photomode_shared.S.sessionAdvancedRenderRestoreState then
    return
  end

  local restoreState = ui_photomode_shared.S.sessionAdvancedRenderRestoreState
  ui_photomode_shared.S.sessionAdvancedRenderRestoreState = nil
  local ok, reason = applyAdvancedRenderRawState(restoreState)
  if not ok then
    ui_photomode_shared.logDebug("restoreAdvancedRenderState skipped: " .. tostring(reason))
  end
end


function M.setAdvancedRenderState(partialState)
  if not isAdvancedRenderTuningEnabled() then
    return {
      ok = false,
      reason = "advanced_render_disabled",
    }
  end
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end
  if type(partialState) ~= "table" then
    return {
      ok = false,
      reason = "advanced_render_state_invalid",
    }
  end

  local ok, reason = applyAdvancedRenderStatePatch(partialState)
  if not ok then
    return {
      ok = false,
      reason = reason or "advanced_render_set_failed",
      state = buildAdvancedRenderState(),
    }
  end

  return {
    ok = true,
    state = buildAdvancedRenderState(),
  }
end

function M.resetAdvancedRenderToDefaults()
  if not isAdvancedRenderTuningEnabled() then
    return {
      ok = false,
      reason = "advanced_render_disabled",
    }
  end
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end
  if not ui_photomode_shared.S.sessionAdvancedRenderRestoreState then
    return {
      ok = false,
      reason = "advanced_render_defaults_unavailable",
      state = buildAdvancedRenderState(),
    }
  end

  local ok, reason = applyAdvancedRenderRawState(ui_photomode_shared.S.sessionAdvancedRenderRestoreState)
  if not ok then
    return {
      ok = false,
      reason = reason or "advanced_render_set_failed",
      state = buildAdvancedRenderState(),
    }
  end

  return {
    ok = true,
    state = buildAdvancedRenderState(),
  }
end

function M.saveAdvancedRenderBookmark()
  if not isAdvancedRenderTuningEnabled() then
    return {
      ok = false,
      reason = "advanced_render_disabled",
    }
  end
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end

  if not captureSavedAdvancedRenderBookmark() then
    return {
      ok = false,
      reason = "advanced_render_state_unavailable",
    }
  end

  return {
    ok = true,
    state = buildAdvancedRenderState(),
  }
end

function M.loadAdvancedRenderBookmark()
  if not isAdvancedRenderTuningEnabled() then
    return {
      ok = false,
      reason = "advanced_render_disabled",
    }
  end
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
    }
  end
  if not ui_photomode_shared.S.savedAdvancedRenderBookmark then
    return {
      ok = false,
      reason = "bookmark_unavailable",
    }
  end

  local ok, reason = applyAdvancedRenderRawState(ui_photomode_shared.S.savedAdvancedRenderBookmark)
  if not ok then
    return {
      ok = false,
      reason = reason or "advanced_render_set_failed",
      state = buildAdvancedRenderState(),
    }
  end

  return {
    ok = true,
    state = buildAdvancedRenderState(),
  }
end

function M.getAdvancedRenderState()
  local advancedRenderState = buildAdvancedRenderState()
  advancedRenderState.ok = ui_photomode_shared.S.sessionActive == true and isAdvancedRenderTuningEnabled()
  if not isAdvancedRenderTuningEnabled() then
    advancedRenderState.reason = "advanced_render_disabled"
  elseif not advancedRenderState.ok then
    advancedRenderState.reason = "session_inactive"
  end
  return advancedRenderState
end

function M.setAdvancedRenderTuningEnabled(value)
  local enabled = ui_photomode_shared.normalizeBoolean(value, true)

  ui_photomode_shared.S.advancedRenderTuningEnabledOverride = enabled

  local response = {
    ok = true,
    enabled = isAdvancedRenderTuningEnabled(),
    capabilities = ui_photomode_session.buildCapabilities(),
  }

  if ui_photomode_shared.S.sessionActive and response.enabled == true then
    response.state = buildAdvancedRenderState()
  end

  return response
end

function M.capturePresetState()
  return M.buildMetadataState()
end

function M.captureDefaultPresetState()
  if type(ui_photomode_shared.S.sessionAdvancedRenderRestoreState) ~= "table" then
    return nil
  end

  return buildAdvancedRenderDisplayState(ui_photomode_shared.S.sessionAdvancedRenderRestoreState)
end

function M.applyPresetState(state)
  local ok, reason = applyAdvancedRenderStatePatch(type(state) == "table" and state or {})
  if not ok then
    return { ok = false, reason = reason or "advanced_render_set_failed" }
  end

  return { state = buildAdvancedRenderState() }
end


M.captureRestoreState = captureAdvancedRenderRestoreState
M.restoreState = restoreAdvancedRenderState
M.buildState = buildAdvancedRenderState
function M.buildMetadataState()
  local advancedRenderState = buildAdvancedRenderState()
  return {
    detailAdjust = advancedRenderState.detailAdjust,
    terrainLodScale = advancedRenderState.terrainLodScale,
    grassDensity = advancedRenderState.grassDensity,
    shadowsQualityMode = advancedRenderState.shadowsQualityMode,
    lastSplitCastersEnabled = advancedRenderState.lastSplitCastersEnabled,
    vehicleShadowEnabled = advancedRenderState.vehicleShadowEnabled,
    cloudQualityMode = advancedRenderState.cloudQualityMode,
  }
end
M.isTuningEnabled = isAdvancedRenderTuningEnabled
M.getDefaultEnabled = getAdvancedRenderDefaultEnabled
M.isUnlockVisible = isAdvancedRenderUnlockVisible

return M
