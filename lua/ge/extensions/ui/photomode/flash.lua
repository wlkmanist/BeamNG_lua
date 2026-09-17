-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "ui_photomode_flash"

local FLASH_DEFAULTS = {
  enabled = false,
  fireOnCapture = false,
  intensity = 25000,
  outerAngle = 55,
  hue = 0,
  saturation = 0,
}

local FLASH_CAPTURE_UI_HOLD_FRAMES = 5
local flashSettings = nil

local function buildDefaultSettings()
  return {
    enabled = FLASH_DEFAULTS.enabled,
    fireOnCapture = FLASH_DEFAULTS.fireOnCapture,
    intensity = FLASH_DEFAULTS.intensity,
    outerAngle = FLASH_DEFAULTS.outerAngle,
    hue = FLASH_DEFAULTS.hue,
    saturation = FLASH_DEFAULTS.saturation,
  }
end

flashSettings = buildDefaultSettings()

local function getPhotomodeFlashExtension()
  if not extensions or type(extensions.load) ~= "function" then
    return nil, "extensions_unavailable"
  end

  local loadOk, loadError = pcall(extensions.load, "util/photomodeFlash")
  if not loadOk then
    log("E", logTag, "photomodeFlash load failed: " .. tostring(loadError))
    return nil, "flash_unavailable"
  end

  local flashExtension = extensions.util_photomodeFlash
  if not flashExtension or type(flashExtension.applyFromUi) ~= "function" or type(flashExtension.runCapture) ~= "function" then
    return nil, "flash_unavailable"
  end
  return flashExtension
end

local function disableRuntime()
  local flashExtension = extensions and extensions.util_photomodeFlash or nil
  if not flashExtension or type(flashExtension.enable) ~= "function" then
    return
  end

  local disableOk, disableError = pcall(flashExtension.enable, false)
  if not disableOk then
    log("E", logTag, "photomodeFlash disable failed: " .. tostring(disableError))
  end
end

function M.buildState()
  return {
    enabled = flashSettings.enabled == true,
    fireOnCapture = flashSettings.fireOnCapture == true,
    intensity = flashSettings.intensity,
    outerAngle = flashSettings.outerAngle,
    hue = flashSettings.hue,
    saturation = flashSettings.saturation,
  }
end

function M.capturePresetState()
  return M.buildState()
end

function M.captureDefaultPresetState()
  return buildDefaultSettings()
end

function M.applyStatePatch(partialState)
  if type(partialState) ~= "table" then
    return true
  end
  if partialState.enabled ~= nil then flashSettings.enabled = partialState.enabled == true end
  if partialState.fireOnCapture ~= nil then flashSettings.fireOnCapture = partialState.fireOnCapture == true end
  if partialState.intensity ~= nil then flashSettings.intensity = partialState.intensity end
  if partialState.outerAngle ~= nil then flashSettings.outerAngle = partialState.outerAngle end
  if partialState.hue ~= nil then flashSettings.hue = partialState.hue end
  if partialState.saturation ~= nil then flashSettings.saturation = partialState.saturation end
  return true
end

function M.applyPresetState(flashState)
  if type(flashState) ~= "table" then
    return true
  end
  M.applyStatePatch(flashState)
  return M.applyRuntimeSettings()
end

function M.applyRuntimeSettings()
  if flashSettings.enabled ~= true then
    disableRuntime()
    return true
  end

  local flashExtension, reason = getPhotomodeFlashExtension()
  if not flashExtension then
    return false, reason
  end

  local applyOk, applyError = pcall(
    flashExtension.applyFromUi,
    true,
    flashSettings.fireOnCapture,
    flashSettings.intensity,
    flashSettings.outerAngle,
    flashSettings.hue,
    flashSettings.saturation
  )
  if not applyOk then
    log("E", logTag, "photomodeFlash apply failed: " .. tostring(applyError))
    return false, "flash_apply_failed"
  end
  return true
end

function M.runCapture(kind, ...)
  local flashExtension, reason = getPhotomodeFlashExtension()
  if not flashExtension then
    return false, reason
  end

  local callOk, captureOk, captureError = pcall(flashExtension.runCapture, kind, ...)
  if not callOk then
    log("E", logTag, "photomodeFlash capture failed: " .. tostring(captureOk))
    return false, "screenshot_request_failed"
  end
  if captureOk ~= true then
    return false, captureError or "screenshot_request_failed"
  end
  return true
end

function M.getCaptureUiHoldFrames()
  if flashSettings.enabled == true and flashSettings.fireOnCapture == true then
    return FLASH_CAPTURE_UI_HOLD_FRAMES
  end
  return 0
end

function M.resetSettings()
  disableRuntime()
  flashSettings = buildDefaultSettings()
end

function M.restoreRuntimeState()
  disableRuntime()
end

return M
