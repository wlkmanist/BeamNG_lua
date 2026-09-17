-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "ui_pause_photomode"
local isDebugEnabled = true
local PHOTO_CAPTURE_SOUND_EVENT = "event:>UI>Main>Photo"

local S = {
  sessionActive = false,
  activeProfile = "pause",
  suppressionsApplied = false,
  previousCompatPhotoModeOpen = false,
  photoModeOpen = false,
  routePayloadContractVersion = 8,
  photomodeMetadataStateVersion = 2,

  sessionCameraRestoreState = nil,
  sessionSceneRestoreState = nil,
  sessionEffectsRestoreState = nil,
  sessionEffectsRestoreStatePersisted = false,
  sessionAdvancedRenderRestoreState = nil,

  sessionNodeGrabberRestoreState = nil,
  nodeGrabberVisible = false,

  savedCameraBookmark = nil,
  savedRelativeCameraBookmark = nil,
  savedEnvironmentBookmark = nil,
  savedAdvancedRenderBookmark = nil,

  sessionDofManualFocusRange = nil,

  pendingMotionCapture = nil,
  pendingPreviewPlayback = nil,
  captureInProgressFramesRemaining = 0,
  photomodePauseRequestApplied = false,
  photomodePauseWasPaused = false,
  selectedResolutionPresetId = nil,
  pendingExitNavigation = nil,
  exitConfirmationBypass = false,
  persistentSessionState = nil,
  panelSurfaceMode = "hidden",

  advancedRenderTuningEnabledOverride = nil
}



M.S = S

function M.isDebugEnabled()
  return isDebugEnabled
end

function M.setDebugEnabled(value)
  isDebugEnabled = value == true
  local screenshotLoaded, screenshotApi = pcall(require, "screenshot")
  if screenshotLoaded and type(screenshotApi) == "table" and type(screenshotApi.setDebugTracingEnabled) == "function" then
    screenshotApi.setDebugTracingEnabled(isDebugEnabled)
  end
  M.logDebug("debug enabled=" .. tostring(isDebugEnabled))
end

function M.logDebug(message)
  if not isDebugEnabled then
    return
  end
  log("I", logTag, "[Photomode] " .. tostring(message))
end

function M.stringifyDebugPayload(payload)
  if payload == nil then
    return ""
  end
  if type(payload) == "string" then
    return payload
  end
  local ok, encoded = pcall(jsonEncode, payload)
  if ok and type(encoded) == "string" then
    return encoded
  end
  return tostring(payload)
end

function M.playPhotoCaptureSound()
  if Engine and Engine.Audio and type(Engine.Audio.playOnce) == "function" then
    Engine.Audio.playOnce("AudioGui", PHOTO_CAPTURE_SOUND_EVENT)
  end
end

function M.clampNumber(value, minValue, maxValue, fallback)
  local numericValue = tonumber(value)
  if numericValue == nil then
    return fallback
  end
  if numericValue < minValue then
    return minValue
  end
  if numericValue > maxValue then
    return maxValue
  end
  return numericValue
end

function M.normalizeBoolean(value, fallback)
  if value == nil then
    return fallback == true
  end
  if type(value) == "boolean" then
    return value
  end
  if type(value) == "number" then
    return value ~= 0
  end
  if type(value) == "string" then
    local normalized = string.lower(value)
    if normalized == "true" or normalized == "1" then
      return true
    end
    if normalized == "false" or normalized == "0" then
      return false
    end
  end
  return fallback == true
end

function M.hasAnyDescribedField(state, fieldDescriptors)
  if type(state) ~= "table" then
    return false
  end
  for _, field in ipairs(fieldDescriptors) do
    if state[field.key] ~= nil then
      return true
    end
  end
  return false
end

function M.buildDescribedState(source, fieldDescriptors)
  local out = {}
  if type(source) ~= "table" then
    return out
  end
  for _, field in ipairs(fieldDescriptors) do
    local value = source[field.key]
    if value ~= nil then
      if field.normalize then
        value = field.normalize(value)
      end
      out[field.outputKey or field.key] = value
    end
  end
  return out
end

function M.getCoreCameraFunction(name)
  if not core_camera then
    return nil
  end
  local fn = core_camera[name]
  if type(fn) ~= "function" then
    return nil
  end
  return fn
end

function M.normalizePathForCompare(value)
  local normalizedValue = tostring(value or "")
  normalizedValue = normalizedValue:gsub("\\", "/")
  normalizedValue = normalizedValue:gsub("^/+", "")
  normalizedValue = normalizedValue:gsub("%s+$", "")
  return string.lower(normalizedValue)
end

function M.normalizePreviewNumberArray(values, expectedLength)
  if type(values) ~= "table" then
    return nil
  end
  local out = {}
  for index = 1, expectedLength do
    local numericValue = tonumber(values[index])
    if numericValue == nil then
      return nil
    end
    out[index] = numericValue
  end
  return out
end

function M.readVariableRegistryValue(variableName)
  if not VariableRegistry or type(VariableRegistry.get) ~= "function" then
    return nil
  end
  local ok, value = pcall(VariableRegistry.get, variableName)
  if not ok then
    M.logDebug("VariableRegistry.get failed for " .. tostring(variableName) .. ": " .. tostring(value))
    return nil
  end
  return value
end

function M.writeVariableRegistryValue(variableName, value)
  if not VariableRegistry or type(VariableRegistry.set) ~= "function" then
    return false
  end
  local ok, err = pcall(VariableRegistry.set, variableName, value)
  if not ok then
    log("E", logTag, "VariableRegistry.set failed for " .. tostring(variableName) .. ": " .. tostring(err))
    return false
  end
  return true
end

function M.readSettingValue(settingName)
  if not settings or type(settings.getValue) ~= "function" then
    return nil
  end
  local ok, value = pcall(settings.getValue, settingName)
  if not ok then
    M.logDebug("settings.getValue failed for " .. tostring(settingName) .. ": " .. tostring(value))
    return nil
  end
  return value
end

function M.writeSettingValue(settingName, value)
  if not settings or type(settings.setValue) ~= "function" then
    return false
  end
  local ok, err = pcall(settings.setValue, settingName, value)
  if not ok then
    log("E", logTag, "settings.setValue failed for " .. tostring(settingName) .. ": " .. tostring(err))
    return false
  end
  return true
end

function M.writeSettingsState(partialState)
  if not settings or type(settings.setState) ~= "function" then
    return false
  end
  local ok, err = pcall(settings.setState, partialState)
  if not ok then
    log("E", logTag, "settings.setState failed: " .. tostring(err))
    return false
  end
  return true
end

function M.notifySettingsUi()
  if settings and type(settings.notifyUI) == "function" then
    local ok, err = pcall(settings.notifyUI)
    if not ok then
      M.logDebug("settings.notifyUI failed: " .. tostring(err))
    end
  end
end

function M.getScreenshotApi()
  local screenshotLoaded, screenshotApi = pcall(require, "screenshot")
  if not screenshotLoaded or type(screenshotApi) ~= "table" then
    return nil
  end
  return screenshotApi
end

local function isOnlineFeaturesEnabled()
  if not settings or not settings.getValue then
    return false
  end
  return settings.getValue("onlineFeatures") == "enable"
end

local function isOnlineServiceWorking()
  if not OnlineServiceProvider then
    return false
  end
  return OnlineServiceProvider.isWorking == true
end

local function isOnlineAccountLoggedIn()
  if not OnlineServiceProvider then
    return false
  end
  return OnlineServiceProvider.accountLoggedIn == true
end

local function getMediaActionReasonLabel(reason)
  local labels = {
    shipping_build_required = "Unavailable in non-shipping builds.",
    backend_unavailable = "Unavailable in the current runtime.",
    online_features_disabled = "Enable Online Features to use this action.",
    online_service_unavailable = "Online services are not available right now.",
    online_account_required = "Sign in to a BeamNG account to use this action.",
    browser_unavailable = "Web browser open is unavailable in this runtime.",
  }
  return labels[reason] or ""
end

local function buildMediaActionState(visible, enabled, reason)
  return {
    visible = visible == true,
    enabled = enabled == true,
    reason = reason,
    reasonLabel = getMediaActionReasonLabel(reason),
  }
end

function M.buildMediaActions()
  local shippingBuild = shipping_build == true
  local uiDevMode = shippingBuild ~= true
  local onlineFeaturesEnabled = isOnlineFeaturesEnabled()
  local onlineServiceWorking = isOnlineServiceWorking()
  local onlineAccountLoggedIn = isOnlineAccountLoggedIn()
  local screenshotApi = M.getScreenshotApi()
  local uploadBackendAvailable = screenshotApi and type(screenshotApi.publish) == "function"
  local steamBackendAvailable = screenshotApi
    and type(screenshotApi.doSteamScreenshot) == "function"
    and OnlineServiceProvider
    and type(OnlineServiceProvider.triggerScreenshot) == "function"
  local openShareUrlAvailable = type(openWebBrowser) == "function"

  local uploadVisible = uploadBackendAvailable
  local uploadEnabled = uploadVisible and onlineFeaturesEnabled and onlineServiceWorking and onlineAccountLoggedIn
  local uploadReason = nil
  if not uploadBackendAvailable then
    uploadReason = "backend_unavailable"
  elseif not onlineFeaturesEnabled then
    uploadReason = "online_features_disabled"
  elseif not onlineServiceWorking then
    uploadReason = "online_service_unavailable"
  elseif not onlineAccountLoggedIn then
    uploadReason = "online_account_required"
  end

  local steamVisible = steamBackendAvailable
  local steamEnabled = steamVisible and onlineFeaturesEnabled and onlineServiceWorking
  local steamReason = nil
  if not steamBackendAvailable then
    steamReason = "backend_unavailable"
  elseif not onlineFeaturesEnabled then
    steamReason = "online_features_disabled"
  elseif not onlineServiceWorking then
    steamReason = "online_service_unavailable"
  end

  local openShareUrlReason = openShareUrlAvailable and nil or "browser_unavailable"

  return {
    runtime = {
      shippingBuild = shippingBuild,
      uiDevMode = uiDevMode,
      onlineFeaturesEnabled = onlineFeaturesEnabled,
      onlineServiceWorking = onlineServiceWorking,
      onlineAccountLoggedIn = onlineAccountLoggedIn,
    },
    capture = {
      upload = buildMediaActionState(uploadVisible, uploadEnabled, uploadReason),
      steam = buildMediaActionState(steamVisible, steamEnabled, steamReason),
    },
    preview = {
      openShareUrl = buildMediaActionState(openShareUrlAvailable, openShareUrlAvailable, openShareUrlReason),
    },
  }
end

return M
