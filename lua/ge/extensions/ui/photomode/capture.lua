-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_photomode_flash" }
local logTag = "ui_photomode_capture"
local PHOTOMODE_PAUSE_REQUEST_ID = "ui_pause_photomode"

local function tr(key, vars)
  if type(vars) == "table" and next(vars) ~= nil then
    return core_locales.contextTranslate(key, vars)
  end
  return _tr(key)
end

local function resolvePresetLabel(preset)
  if preset.labelKey then
    if preset.width and preset.height then
      return tr(preset.labelKey, { width = preset.width, height = preset.height })
    end
    return tr(preset.labelKey)
  end
  return preset.label or preset.id
end

local CAPTURE_LIMITS = {
  superSamplingMin = 1,
  superSamplingMax = 8,
  downscaleLevelMin = 1,
  downscaleLevelMax = 8,
}
local function isHdrCaptureSupported()
  return GFXHdr and type(GFXHdr.getSupported) == "function" and GFXHdr.getSupported() == true
end

local function getHdrOutputModeName()
  if not isHdrCaptureSupported() or not GFXHdr or type(GFXHdr.getOutputModeName) ~= "function" then
    return "LDR"
  end
  return GFXHdr.getOutputModeName()
end

local function isHdrRuntimeActive()
  return getHdrOutputModeName() ~= "LDR"
end

local hdrCaptureRestoreRequested = nil

local function setHdrRuntimeRequested(requested)
  if not GFXHdr then
    return
  end
  if type(GFXHdr.setRequested) == "function" then
    GFXHdr.setRequested(requested == true)
  end
  if type(GFXHdr.applyRequested) == "function" then
    GFXHdr.applyRequested()
  end
end

local function prepareHdrRuntimeForCapture(requested)
  if not isHdrCaptureSupported() then
    return requested ~= true, false
  end
  local previousRequested = isHdrRuntimeActive()
  if hdrCaptureRestoreRequested == nil then
    hdrCaptureRestoreRequested = previousRequested
  end
  setHdrRuntimeRequested(requested == true)
  return true, previousRequested ~= (requested == true)
end

local function restoreHdrRuntimeAfterCapture()
  if hdrCaptureRestoreRequested == nil then
    return
  end
  local restoreRequested = hdrCaptureRestoreRequested
  hdrCaptureRestoreRequested = nil
  setHdrRuntimeRequested(restoreRequested)
end

local function getDefaultHdrScreenshotEnabled()
  return isHdrCaptureSupported() and isHdrRuntimeActive()
end

local CAPTURE_DEFAULTS = {
  superSampling = 2,
  downscaleLevel = 2,
  motionEnabled = false,
  motionBehavior = "followVehicle",
  splitSceneVehicle = false,
  saveNormalDepth = false,
  hdrScreenshot = false,
}

local CAPTURE_WARNING_THRESHOLD = 9
local DEFAULT_RESOLUTION_PRESET_ID = "current"
local RESOLUTION_PRESETS = {
  { id = "current", labelKey = "ui.photomode.capture.preset.current" },
  { id = "windowed_1280x720", labelKey = "ui.photomode.capture.preset.resolution", width = 1280, height = 720 },
  { id = "windowed_1600x900", labelKey = "ui.photomode.capture.preset.resolution", width = 1600, height = 900 },
  { id = "windowed_1920x1080", labelKey = "ui.photomode.capture.preset.resolution", width = 1920, height = 1080 },
  { id = "windowed_2560x1440", labelKey = "ui.photomode.capture.preset.resolution", width = 2560, height = 1440 },
  { id = "windowed_3840x2160", labelKey = "ui.photomode.capture.preset.resolution", width = 3840, height = 2160 },
}

M.DEFAULTS = {
  superSampling = CAPTURE_DEFAULTS.superSampling,
  downscaleLevel = CAPTURE_DEFAULTS.downscaleLevel,
  motionEnabled = CAPTURE_DEFAULTS.motionEnabled,
  motionBehavior = CAPTURE_DEFAULTS.motionBehavior,
  splitSceneVehicle = CAPTURE_DEFAULTS.splitSceneVehicle,
  saveNormalDepth = CAPTURE_DEFAULTS.saveNormalDepth,
  hdrScreenshot = CAPTURE_DEFAULTS.hdrScreenshot,
}

local function clampNumber(value, minValue, maxValue, fallback)
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

local function normalizeBoolean(value, fallback)
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
    local normalizedValue = string.lower(value)
    if normalizedValue == "true" or normalizedValue == "1" then
      return true
    end
    if normalizedValue == "false" or normalizedValue == "0" then
      return false
    end
  end
  return fallback == true
end

function M.buildDefaultSettings()
  return {
    superSampling = CAPTURE_DEFAULTS.superSampling,
    downscaleLevel = CAPTURE_DEFAULTS.downscaleLevel,
    motionEnabled = CAPTURE_DEFAULTS.motionEnabled,
    motionBehavior = CAPTURE_DEFAULTS.motionBehavior,
    splitSceneVehicle = CAPTURE_DEFAULTS.splitSceneVehicle,
    saveNormalDepth = CAPTURE_DEFAULTS.saveNormalDepth,
    hdrScreenshot = getDefaultHdrScreenshotEnabled(),
  }
end

function M.isResolutionPresetFeatureEnabled()
  return shipping_build ~= true
end

local function normalizeResolutionPresetId(value)
  local presetId = tostring(value or "")
  if presetId == "" then
    return DEFAULT_RESOLUTION_PRESET_ID
  end
  return presetId
end

function M.findResolutionPreset(presetId)
  local normalizedPresetId = normalizeResolutionPresetId(presetId)
  for _, preset in ipairs(RESOLUTION_PRESETS) do
    if preset.id == normalizedPresetId then
      return preset
    end
  end
  return nil
end

local function getResolutionApi()
  local resolutionApi = extensions and extensions.util_resolution or nil
  if resolutionApi and type(resolutionApi.setWindowedResolution) == "function" then
    return resolutionApi
  end

  if not extensions or type(extensions.load) ~= "function" then
    return nil
  end

  local loadOk, loadError = pcall(extensions.load, "util/resolution")
  if not loadOk then
    log("E", logTag, "resolution preset load failed: " .. tostring(loadError))
    return nil
  end

  resolutionApi = extensions and extensions.util_resolution or nil
  if resolutionApi and type(resolutionApi.setWindowedResolution) == "function" then
    return resolutionApi
  end

  return nil
end

local function getCurrentWindowVideoMode()
  local resolutionApi = getResolutionApi()
  if resolutionApi and type(resolutionApi.getVideoModeSnapshot) == "function" then
    local snapshotOk, snapshot = pcall(resolutionApi.getVideoModeSnapshot)
    if snapshotOk and type(snapshot) == "table" then
      local width = tonumber(snapshot.width)
      local height = tonumber(snapshot.height)
      if width ~= nil and height ~= nil then
        return {
          width = width,
          height = height,
          displayMode = tostring(snapshot.displayMode or ""),
        }
      end
    end
  end

  if not GFXDevice or type(GFXDevice.getVideoMode) ~= "function" then
    return nil
  end

  local ok, videoMode = pcall(GFXDevice.getVideoMode)
  if not ok or type(videoMode) ~= "table" then
    return nil
  end

  local width = tonumber(videoMode.width)
  local height = tonumber(videoMode.height)
  if width == nil or height == nil then
    return nil
  end

  return {
    width = width,
    height = height,
    displayMode = tostring(videoMode.displayMode or ""),
  }
end

local function buildCurrentWindowLabel(videoMode)
  if type(videoMode) ~= "table" then
    return tr("ui.photomode.capture.currentWindowUnavailable")
  end

  local modeLabel = videoMode.displayMode ~= ""
    and " (" .. videoMode.displayMode .. ")"
    or ""
  return tr("ui.photomode.capture.currentWindowResolution", {
    width = videoMode.width,
    height = videoMode.height,
    mode = modeLabel,
  })
end

local function buildResolutionPresetStateForSelection(selectedResolutionPresetId)
  local visible = M.isResolutionPresetFeatureEnabled()
  local resolutionApiAvailable = getResolutionApi() ~= nil
  local videoMode = getCurrentWindowVideoMode()
  local enabled = visible and resolutionApiAvailable and type(videoMode) == "table"
  local selectedPreset = M.findResolutionPreset(selectedResolutionPresetId) or RESOLUTION_PRESETS[1]
  local items = {}

  for _, preset in ipairs(RESOLUTION_PRESETS) do
    items[#items + 1] = {
      value = preset.id,
      label = resolvePresetLabel(preset),
    }
  end

  return {
    visible = visible,
    enabled = enabled,
    selectedId = selectedPreset.id,
    selectedLabel = resolvePresetLabel(selectedPreset),
    currentWindowLabel = buildCurrentWindowLabel(videoMode),
    applyOnCapture = false,
    followUpBehaviorLabel = tr("ui.photomode.capture.resolutionPresetOnSelection"),
    items = items,
  }
end

function M.applyResolutionPreset(preset)
  if type(preset) ~= "table" or preset.id == DEFAULT_RESOLUTION_PRESET_ID then
    return true
  end

  local resolutionApi = getResolutionApi()
  if not resolutionApi or type(resolutionApi.setWindowedResolution) ~= "function" then
    return false, "resolution_api_unavailable"
  end

  local applyOk, applyError = pcall(resolutionApi.setWindowedResolution, preset.width, preset.height)
  if not applyOk then
    log("E", logTag, "resolution preset apply failed: " .. tostring(applyError))
    return false, "resolution_apply_failed"
  end

  return true
end

function M.applySelectedResolutionPresetBeforeCapture(selectedResolutionPresetId)
  local preset = M.findResolutionPreset(selectedResolutionPresetId)
  return M.applyResolutionPreset(preset)
end

function M.normalizeCaptureSuperSampling(value)
  local numericValue = tonumber(value) or CAPTURE_DEFAULTS.superSampling
  numericValue = math.floor(numericValue + 0.5)
  return ui_photomode_shared.clampNumber(
    numericValue,
    CAPTURE_LIMITS.superSamplingMin,
    CAPTURE_LIMITS.superSamplingMax,
    CAPTURE_DEFAULTS.superSampling
  )
end

local function normalizeCaptureDownscaleLevel(value)
  local numericValue = tonumber(value) or CAPTURE_DEFAULTS.downscaleLevel
  numericValue = math.floor(numericValue + 0.5)
  return ui_photomode_shared.clampNumber(
    numericValue,
    CAPTURE_LIMITS.downscaleLevelMin,
    CAPTURE_LIMITS.downscaleLevelMax,
    CAPTURE_DEFAULTS.downscaleLevel
  )
end

local function normalizeMotionBehavior(value)
  if value == "static" or value == "followVehicle" or value == "followVehicleWithRotation" then
    return value
  end
  return CAPTURE_DEFAULTS.motionBehavior
end

local function motionBehaviorAttachesToVehicle(value)
  value = normalizeMotionBehavior(value)
  return value == "followVehicle" or value == "followVehicleWithRotation"
end

local function motionBehaviorFollowsRotation(value)
  return normalizeMotionBehavior(value) == "followVehicleWithRotation"
end

local function readPostEffectEnabled(effectName)
  local effectObject = scenetree and scenetree.findObject and scenetree.findObject(effectName)
  if not effectObject or type(effectObject.isEnabled) ~= "function" then
    return nil
  end
  local ok, value = pcall(effectObject.isEnabled, effectObject)
  if not ok then
    ui_photomode_shared.logDebug("readPostEffectEnabled failed for " .. tostring(effectName) .. ": " .. tostring(value))
    return nil
  end
  return value ~= false
end

local function buildMotionCaptureAvailability()
  local motionBlurEnabled = readPostEffectEnabled("PostFxMotionBlur")
  return {
    motionBlurAvailable = motionBlurEnabled ~= nil,
    motionBlurEnabled = motionBlurEnabled == true,
  }
end

function M.buildCaptureRescaleFactor(downscaleLevel)
  local normalizedDownscaleLevel = normalizeCaptureDownscaleLevel(downscaleLevel)
  return 1 / math.sqrt(normalizedDownscaleLevel)
end

function M.buildNormalizedCaptureSettings(captureSettings)
  local hdrScreenshot = ui_photomode_shared.normalizeBoolean(
    captureSettings and captureSettings.hdrScreenshot,
    getDefaultHdrScreenshotEnabled()
  )
  if not isHdrCaptureSupported() then
    hdrScreenshot = false
  end

  return {
    superSampling = M.normalizeCaptureSuperSampling(captureSettings and captureSettings.superSampling),
    downscaleLevel = normalizeCaptureDownscaleLevel(captureSettings and captureSettings.downscaleLevel),
    motionEnabled = ui_photomode_shared.normalizeBoolean(captureSettings and captureSettings.motionEnabled, CAPTURE_DEFAULTS.motionEnabled),
    motionBehavior = normalizeMotionBehavior(captureSettings and captureSettings.motionBehavior),
    splitSceneVehicle = ui_photomode_shared.normalizeBoolean(captureSettings and captureSettings.splitSceneVehicle, CAPTURE_DEFAULTS.splitSceneVehicle),
    saveNormalDepth = ui_photomode_shared.normalizeBoolean(captureSettings and captureSettings.saveNormalDepth, CAPTURE_DEFAULTS.saveNormalDepth),
    hdrScreenshot = hdrScreenshot,
  }
end

local function gcd(a, b)
  a = math.abs(math.floor(tonumber(a) or 0))
  b = math.abs(math.floor(tonumber(b) or 0))
  while b ~= 0 do
    local temp = b
    b = a % b
    a = temp
  end
  return a ~= 0 and a or 1
end

local function buildResolutionMegaPixelLabel(width, height)
  if width == nil or height == nil then
    return ""
  end
  local megaPixels = (width * height) / 1000000
  return tr("ui.photomode.capture.megaPixels", { value = string.format("%.2f", megaPixels) })
end

local function buildResolutionWithMegaPixelsLabel(width, height)
  if width == nil or height == nil then
    return tr("ui.photomode.capture.unavailable")
  end
  return tr("ui.photomode.capture.resolutionWithMegaPixels", {
    width = width,
    height = height,
    megaPixels = buildResolutionMegaPixelLabel(width, height),
  })
end

local function buildScaledResolution(baseWidth, baseHeight, scaleFactor)
  if baseWidth == nil or baseHeight == nil or scaleFactor == nil then
    return nil
  end
  return {
    width = math.max(1, math.floor((baseWidth * scaleFactor) + 0.5)),
    height = math.max(1, math.floor((baseHeight * scaleFactor) + 0.5)),
  }
end

local function buildAspectRatioLabel(width, height)
  if width == nil or height == nil or width <= 0 or height <= 0 then
    return tr("ui.photomode.capture.unavailable")
  end

  local ratio = width / height
  local candidates = {
    { label = "16:9", ratio = 16 / 9 },
    { label = "16:10", ratio = 16 / 10 },
    { label = "21:9", ratio = 21 / 9 },
    { label = "4:3", ratio = 4 / 3 },
    { label = "3:2", ratio = 3 / 2 },
    { label = "1:1", ratio = 1 },
  }

  local bestLabel = nil
  local bestDiff = math.huge
  for _, candidate in ipairs(candidates) do
    local diff = math.abs(ratio - candidate.ratio) / candidate.ratio
    if diff < bestDiff then
      bestDiff = diff
      bestLabel = candidate.label
    end
  end

  if bestDiff <= 0.015 and bestLabel then
    return bestLabel
  end

  local aspectGcd = gcd(width, height)
  return string.format("%d:%d", math.floor(width / aspectGcd), math.floor(height / aspectGcd))
end

local function readScreenshotFormatLabel()
  local formatValue = nil
  if settings and type(settings.getValue) == "function" then
    formatValue = settings.getValue("screenshotFormat")
  end
  local normalizedFormat = string.lower(tostring(formatValue or ""))
  if normalizedFormat == "" then
    return tr("ui.photomode.capture.unavailable")
  end
  return string.upper(normalizedFormat)
end

local function buildOutputSizeGuidanceLabels(width, height, formatLabel)
  local unavailable = tr("ui.photomode.capture.unavailable")
  if width == nil or height == nil then
    return unavailable, ""
  end

  local normalizedFormat = string.lower(tostring(formatLabel or ""))
  local unavailableFormat = string.lower(unavailable)
  if normalizedFormat == "" or normalizedFormat == unavailableFormat then
    return unavailable, ""
  end

  local megaPixels = (width * height) / 1000000
  local lowMiB = 0
  local midMiB = 0
  local highMiB = 0

  if normalizedFormat == "jpg" or normalizedFormat == "jpeg" then
    lowMiB = megaPixels * 0.25
    midMiB = megaPixels * 0.45
    highMiB = megaPixels * 0.8
  else
    lowMiB = megaPixels * 0.8
    midMiB = megaPixels * 1.5
    highMiB = megaPixels * 2.5
  end

  return tr("ui.photomode.capture.outputSizeMid", { value = string.format("%.1f", midMiB) }),
    tr("ui.photomode.capture.outputSizeRange", { low = string.format("%.1f", lowMiB), high = string.format("%.1f", highMiB) })
end

local function buildCaptureWarningState(superSampling)
  local warningActive = superSampling >= CAPTURE_WARNING_THRESHOLD
  return {
    active = warningActive,
    reason = warningActive and "high_supersampling" or nil,
    threshold = CAPTURE_WARNING_THRESHOLD,
    label = warningActive and tr("ui.photomode.capture.warningHighSupersampling") or "",
  }
end

function M.buildCaptureState(captureSettings)
  local normalizedSettings = M.buildNormalizedCaptureSettings(captureSettings)
  local motionAvailability = buildMotionCaptureAvailability()
  local rescaleFactor = M.buildCaptureRescaleFactor(normalizedSettings.downscaleLevel)
  local currentWindowVideoMode = getCurrentWindowVideoMode()
  local currentWidth = currentWindowVideoMode and currentWindowVideoMode.width or nil
  local currentHeight = currentWindowVideoMode and currentWindowVideoMode.height or nil
  local renderScale = math.sqrt(normalizedSettings.superSampling)
  local renderTargetResolution = buildScaledResolution(currentWidth, currentHeight, renderScale)
  local outputResolution = renderTargetResolution
    and buildScaledResolution(renderTargetResolution.width, renderTargetResolution.height, rescaleFactor)
    or nil
  local formatLabel = readScreenshotFormatLabel()
  local outputSizeLabel, outputSizeRangeLabel = buildOutputSizeGuidanceLabels(
    outputResolution and outputResolution.width or nil,
    outputResolution and outputResolution.height or nil,
    formatLabel
  )
  local warningState = buildCaptureWarningState(normalizedSettings.superSampling)

  return {
    superSampling = normalizedSettings.superSampling,
    downscaleLevel = normalizedSettings.downscaleLevel,
    rescaleFactor = rescaleFactor,
    limits = {
      superSampling = {
        min = CAPTURE_LIMITS.superSamplingMin,
        max = CAPTURE_LIMITS.superSamplingMax,
        step = 1,
      },
      downscaleLevel = {
        min = CAPTURE_LIMITS.downscaleLevelMin,
        max = CAPTURE_LIMITS.downscaleLevelMax,
        step = 1,
      },
      warningThreshold = CAPTURE_WARNING_THRESHOLD,
    },
    readouts = {
      currentWindowLabel = buildResolutionWithMegaPixelsLabel(currentWidth, currentHeight),
      renderTargetLabel = buildResolutionWithMegaPixelsLabel(
        renderTargetResolution and renderTargetResolution.width or nil,
        renderTargetResolution and renderTargetResolution.height or nil
      ),
      outputResolutionLabel = buildResolutionWithMegaPixelsLabel(
        outputResolution and outputResolution.width or nil,
        outputResolution and outputResolution.height or nil
      ),
      formatLabel = formatLabel,
      aspectLabel = buildAspectRatioLabel(
        outputResolution and outputResolution.width or nil,
        outputResolution and outputResolution.height or nil
      ),
      outputSizeLabel = outputSizeLabel,
      outputSizeRangeLabel = outputSizeRangeLabel,
      actionHintLabel = tr("ui.photomode.capture.takeScreenshotHint"),
    },
    warning = warningState,
    motion = {
      enabled = normalizedSettings.motionEnabled,
      disabled = not motionAvailability.motionBlurAvailable or not motionAvailability.motionBlurEnabled,
      motionBlurAvailable = motionAvailability.motionBlurAvailable,
      motionBlurEnabled = motionAvailability.motionBlurEnabled,
      behavior = normalizedSettings.motionBehavior,
      behaviorLabelKey = "ui.photomode.capture.motionBehavior." .. normalizedSettings.motionBehavior,
    },
    artifacts = {
      splitSceneVehicle = normalizedSettings.splitSceneVehicle,
      saveNormalDepth = normalizedSettings.saveNormalDepth,
    },
    hdr = {
      available = isHdrCaptureSupported(),
      active = isHdrRuntimeActive(),
      enabled = normalizedSettings.hdrScreenshot,
      disabled = isHdrCaptureSupported() ~= true,
      disabledReasonLabel = isHdrCaptureSupported() and "" or tr("ui.photomode.capture.hdrUnavailable"),
    },
    flash = ui_photomode_flash.buildState(),
  }
end

function M.applyCaptureStatePatch(currentCaptureSettings, partialState)
  if type(partialState) ~= "table" then
    return nil, "capture_state_invalid"
  end

  local nextCaptureSettings = M.buildNormalizedCaptureSettings(currentCaptureSettings)

  if partialState.superSampling ~= nil then
    nextCaptureSettings.superSampling = M.normalizeCaptureSuperSampling(partialState.superSampling)
  end

  if partialState.downscaleLevel ~= nil then
    nextCaptureSettings.downscaleLevel = normalizeCaptureDownscaleLevel(partialState.downscaleLevel)
  end

  if type(partialState.motion) == "table" then
    if partialState.motion.enabled ~= nil then
      nextCaptureSettings.motionEnabled = ui_photomode_shared.normalizeBoolean(partialState.motion.enabled, CAPTURE_DEFAULTS.motionEnabled)
    end
    if partialState.motion.behavior ~= nil then
      nextCaptureSettings.motionBehavior = normalizeMotionBehavior(partialState.motion.behavior)
    end
  end

  if type(partialState.artifacts) == "table" then
    if partialState.artifacts.splitSceneVehicle ~= nil then
      nextCaptureSettings.splitSceneVehicle = ui_photomode_shared.normalizeBoolean(partialState.artifacts.splitSceneVehicle, CAPTURE_DEFAULTS.splitSceneVehicle)
    end
    if partialState.artifacts.saveNormalDepth ~= nil then
      nextCaptureSettings.saveNormalDepth = ui_photomode_shared.normalizeBoolean(partialState.artifacts.saveNormalDepth, CAPTURE_DEFAULTS.saveNormalDepth)
    end
  end

  if type(partialState.hdr) == "table" and partialState.hdr.enabled ~= nil then
    nextCaptureSettings.hdrScreenshot = ui_photomode_shared.normalizeBoolean(partialState.hdr.enabled, getDefaultHdrScreenshotEnabled())
  end

  if type(partialState.flash) == "table" then
    ui_photomode_flash.applyStatePatch(partialState.flash)
  end

  return M.buildNormalizedCaptureSettings(nextCaptureSettings)
end



local CAPTURE_IN_PROGRESS_FRAMES = 3
local BASIC_CAPTURE_HDR_SETTLE_MAX_FRAMES = 10
local MOTION_CAPTURE = {
  warmupFrames = 2,
  cleanupFrames = 1,
}
local captureSettings = M.buildDefaultSettings()
local pendingBasicCapture = nil

local function buildCaptureState()
  return M.buildCaptureState(captureSettings)
end

local function applyCaptureStatePatch(partialState)
  local nextCaptureSettings, reason = M.applyCaptureStatePatch(captureSettings, partialState)
  if not nextCaptureSettings then
    return false, reason
  end
  captureSettings = nextCaptureSettings
  ui_photomode_flash.applyRuntimeSettings()
  return true
end

local function requestScreenshotCall(flashKind, screenshotFn, ...)
  local flashState = ui_photomode_flash.buildState()
  if flashState.enabled == true then
    return ui_photomode_flash.runCapture(flashKind, ...)
  end
  return pcall(screenshotFn, ...)
end

local function disableMotionCaptureAttach()
  local attachExtension = extensions and extensions.util_photomodeAttach or nil
  if not attachExtension or type(attachExtension.enable) ~= "function" then
    return
  end
  local disableOk, disableError = pcall(attachExtension.enable, false)
  if not disableOk then
    log("E", logTag, "disableMotionCaptureAttach failed: " .. tostring(disableError))
  end
end

local function releaseMotionCapturePauseRequest()
  if not ui_photomode_shared.S.photomodePauseRequestApplied then
    return false
  end
  if not simTimeAuthority or type(simTimeAuthority.popPauseRequest) ~= "function" then
    return false
  end

  simTimeAuthority.popPauseRequest(PHOTOMODE_PAUSE_REQUEST_ID)
  ui_photomode_shared.S.photomodePauseRequestApplied = false
  return true
end

local function restoreMotionCapturePauseRequest(restorePauseRequest)
  if restorePauseRequest ~= true then
    return false
  end
  if not simTimeAuthority or type(simTimeAuthority.pushPauseRequest) ~= "function" then
    return false
  end

  simTimeAuthority.pushPauseRequest(PHOTOMODE_PAUSE_REQUEST_ID)
  ui_photomode_shared.S.photomodePauseRequestApplied = true
  return true
end

function M.finishPendingMotionCapture()
  if not ui_photomode_shared.S.pendingMotionCapture then
    return
  end
  local repauseAfterCapture = ui_photomode_shared.S.pendingMotionCapture.repauseAfterCapture == true
  local restorePauseRequest = ui_photomode_shared.S.pendingMotionCapture.restorePhotomodePauseRequest == true
  ui_photomode_shared.S.pendingMotionCapture = nil
  disableMotionCaptureAttach()
  if restoreMotionCapturePauseRequest(restorePauseRequest) then
    return
  end
  if repauseAfterCapture
    and simTimeAuthority
    and type(simTimeAuthority.getPause) == "function"
    and type(simTimeAuthority.pause) == "function"
    and simTimeAuthority.getPause() ~= true
  then
    simTimeAuthority.pause(true)
  end
end

local function finishPendingBasicCapture()
  pendingBasicCapture = nil
  restoreHdrRuntimeAfterCapture()
end

function M.resetSettings()
  finishPendingBasicCapture()
  captureSettings = M.buildDefaultSettings()
  ui_photomode_flash.resetSettings()
end

function M.restoreCaptureRuntimeState()
  finishPendingBasicCapture()
  ui_photomode_flash.restoreRuntimeState()
end

function M.refreshSessionDefaults()
  local nextCaptureSettings = M.buildNormalizedCaptureSettings(captureSettings)
  nextCaptureSettings.hdrScreenshot = getDefaultHdrScreenshotEnabled()
  captureSettings = nextCaptureSettings
  ui_photomode_flash.applyRuntimeSettings()
end

function M.markCaptureInProgress(frames)
  frames = tonumber(frames) or 0
  if frames <= 0 then
    return
  end
  frames = math.floor(frames)
  if frames > ui_photomode_shared.S.captureInProgressFramesRemaining then
    ui_photomode_shared.S.captureInProgressFramesRemaining = frames
  end
end

function M.isCaptureInProgress()
  return pendingBasicCapture ~= nil
    or ui_photomode_shared.S.pendingMotionCapture ~= nil
    or ui_photomode_shared.S.captureInProgressFramesRemaining > 0
end

function M.buildState()
  return buildCaptureState()
end

function M.buildResolutionPresetState()
  return buildResolutionPresetStateForSelection(ui_photomode_shared.S.selectedResolutionPresetId)
end

function M.buildMetadataState()
  local captureState = buildCaptureState()
  return {
    superSampling = captureState.superSampling,
    downscaleLevel = captureState.downscaleLevel,
    rescaleFactor = captureState.rescaleFactor,
    motion = {
      enabled = captureState.motion and captureState.motion.enabled or CAPTURE_DEFAULTS.motionEnabled,
      behavior = captureState.motion and captureState.motion.behavior or CAPTURE_DEFAULTS.motionBehavior,
    },
    artifacts = {
      splitSceneVehicle = captureState.artifacts and captureState.artifacts.splitSceneVehicle or false,
      saveNormalDepth = captureState.artifacts and captureState.artifacts.saveNormalDepth or false,
    },
    hdr = {
      enabled = captureState.hdr and captureState.hdr.enabled or false,
    },
    flash = captureState.flash,
  }
end

function M.getCaptureState()
  local captureState = buildCaptureState()
  captureState.ok = ui_photomode_shared.S.sessionActive == true
  if not captureState.ok then
    captureState.reason = "session_inactive"
  end
  return captureState
end

function M.getResolutionPresetState()
  return {
    ok = M.isResolutionPresetFeatureEnabled(),
    state = M.buildResolutionPresetState(),
  }
end

function M.setCaptureState(partialState)
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
      state = buildCaptureState(),
    }
  end
  if type(partialState) ~= "table" then
    return {
      ok = false,
      reason = "capture_state_invalid",
      state = buildCaptureState(),
    }
  end

  local ok, reason = applyCaptureStatePatch(partialState)
  if not ok then
    return {
      ok = false,
      reason = reason or "capture_set_failed",
      state = buildCaptureState(),
    }
  end

  return {
    ok = true,
    state = buildCaptureState(),
  }
end

local function executeBasicScreenshotRequest(basicCapture)
  local requestOk, requestError = nil, nil
  if basicCapture.useDefaultScreenshotPath then
    requestOk, requestError = requestScreenshotCall(
      "takeScreenShot",
      basicCapture.screenshotApi.takeScreenShot,
      basicCapture.captureRequest.splitSceneVehicle,
      basicCapture.captureRequest.saveNormalDepth,
      { callOrigin = "ui_pause_photomode" }
    )
  else
    requestOk, requestError = requestScreenshotCall(
      "takeCustomScreenShot",
      basicCapture.screenshotApi.takeCustomScreenShot,
      basicCapture.requestedSuperSampling,
      M.buildCaptureRescaleFactor(basicCapture.requestedDownscaleLevel),
      basicCapture.captureRequest.splitSceneVehicle,
      basicCapture.captureRequest.saveNormalDepth,
      { callOrigin = "ui_pause_photomode" }
    )
  end
  if not requestOk then
    finishPendingBasicCapture()
    log("E", logTag, "requestBasicScreenshot failed: " .. tostring(requestError))
    return false
  end

  ui_photomode_shared.playPhotoCaptureSound()
  M.markCaptureInProgress(CAPTURE_IN_PROGRESS_FRAMES)
  gameplay_achievement.unlockAchievement("SCREENSHOT_TAKEN")
  return true
end

local function buildBasicScreenshotRequest()
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
      mode = "basic",
    }
  end

  if pendingBasicCapture or ui_photomode_shared.S.pendingMotionCapture then
    return {
      ok = false,
      reason = "capture_busy",
      mode = "basic",
    }
  end

  local screenshotLoaded, screenshotApi = pcall(require, "screenshot")
  if not screenshotLoaded or type(screenshotApi) ~= "table" then
    return {
      ok = false,
      reason = "screenshot_unavailable",
      mode = "basic",
    }
  end

  local captureRequest = M.buildNormalizedCaptureSettings(captureSettings)
  local hasExtraArtifactPasses = captureRequest.splitSceneVehicle == true or captureRequest.saveNormalDepth == true
  local useDefaultScreenshotPath = captureRequest.superSampling == 1
    and captureRequest.downscaleLevel == 1
    and hasExtraArtifactPasses ~= true
  local requestedSuperSampling = captureRequest.superSampling
  local requestedDownscaleLevel = captureRequest.downscaleLevel
  if hasExtraArtifactPasses
    and requestedSuperSampling == M.DEFAULTS.superSampling
    and requestedDownscaleLevel == M.DEFAULTS.downscaleLevel
  then
    -- TODO: fix takeScreenShot() normal data capture, as custom one works good.
    requestedSuperSampling = 2
    requestedDownscaleLevel = 2
  end

  if useDefaultScreenshotPath and type(screenshotApi.takeScreenShot) ~= "function" then
    return {
      ok = false,
      reason = "screenshot_method_missing",
      mode = "basic",
    }
  end

  if not useDefaultScreenshotPath and type(screenshotApi.takeCustomScreenShot) ~= "function" then
    return {
      ok = false,
      reason = "screenshot_method_missing",
      mode = "basic",
    }
  end

  local hdrOk, hdrChanged = prepareHdrRuntimeForCapture(captureRequest.hdrScreenshot)
  if not hdrOk then
    return {
      ok = false,
      reason = "hdr_unavailable",
      mode = "hdr",
    }
  end

  return {
    ok = true,
    screenshotApi = screenshotApi,
    captureRequest = captureRequest,
    useDefaultScreenshotPath = useDefaultScreenshotPath,
    requestedSuperSampling = requestedSuperSampling,
    requestedDownscaleLevel = requestedDownscaleLevel,
    hdrChanged = hdrChanged,
    mode = captureRequest.hdrScreenshot == true and "hdr" or "basic",
  }
end

local function requestBasicScreenshot()
  local basicCapture = buildBasicScreenshotRequest()
  if basicCapture.ok ~= true then
    return basicCapture
  end

  if basicCapture.hdrChanged then
    local flashHoldFrames = ui_photomode_flash.getCaptureUiHoldFrames()
    pendingBasicCapture = basicCapture
    pendingBasicCapture.hdrSettleFramesRemaining = BASIC_CAPTURE_HDR_SETTLE_MAX_FRAMES
    M.markCaptureInProgress(BASIC_CAPTURE_HDR_SETTLE_MAX_FRAMES + flashHoldFrames + CAPTURE_IN_PROGRESS_FRAMES)
    return {
      ok = true,
      mode = basicCapture.mode,
      captureUiHoldFrames = BASIC_CAPTURE_HDR_SETTLE_MAX_FRAMES + flashHoldFrames + CAPTURE_IN_PROGRESS_FRAMES,
    }
  end

  if not executeBasicScreenshotRequest(basicCapture) then
    return {
      ok = false,
      reason = "screenshot_request_failed",
      mode = "basic",
    }
  end

  return {
    ok = true,
    mode = basicCapture.mode,
    captureUiHoldFrames = ui_photomode_flash.getCaptureUiHoldFrames(),
  }
end

local function requestUploadScreenshot()
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
      mode = "upload",
    }
  end

  if pendingBasicCapture or ui_photomode_shared.S.pendingMotionCapture then
    return {
      ok = false,
      reason = "capture_busy",
      mode = "upload",
    }
  end

  local uploadAction = ui_photomode_shared.buildMediaActions().capture.upload
  if not uploadAction or uploadAction.enabled ~= true then
    return {
      ok = false,
      reason = uploadAction and uploadAction.reason or "upload_unavailable",
      mode = "upload",
    }
  end

  local screenshotApi = ui_photomode_shared.getScreenshotApi()
  if not screenshotApi or type(screenshotApi.publish) ~= "function" then
    return {
      ok = false,
      reason = "screenshot_method_missing",
      mode = "upload",
    }
  end

  local requestOk, requestError = requestScreenshotCall(
    "publish",
    screenshotApi.publish,
    nil,
    { callOrigin = "ui_pause_photomode" }
  )
  if not requestOk then
    log("E", logTag, "requestUploadScreenshot failed: " .. tostring(requestError))
    return {
      ok = false,
      reason = "screenshot_request_failed",
      mode = "upload",
    }
  end

  ui_photomode_shared.playPhotoCaptureSound()
  M.markCaptureInProgress(CAPTURE_IN_PROGRESS_FRAMES)
  gameplay_achievement.unlockAchievement("SCREENSHOT_TAKEN")
  return {
    ok = true,
    mode = "upload",
    captureUiHoldFrames = ui_photomode_flash.getCaptureUiHoldFrames(),
  }
end

local function requestSteamScreenshot(useUpload)
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
      mode = "steam",
    }
  end

  if pendingBasicCapture or ui_photomode_shared.S.pendingMotionCapture then
    return {
      ok = false,
      reason = "capture_busy",
      mode = "steam",
    }
  end

  local steamAction = ui_photomode_shared.buildMediaActions().capture.steam
  if not steamAction or steamAction.enabled ~= true then
    return {
      ok = false,
      reason = steamAction and steamAction.reason or "steam_unavailable",
      mode = "steam",
    }
  end

  if useUpload then
    local uploadAction = ui_photomode_shared.buildMediaActions().capture.upload
    if not uploadAction or uploadAction.enabled ~= true then
      return {
        ok = false,
        reason = uploadAction and uploadAction.reason or "upload_unavailable",
        mode = "upload_steam",
      }
    end
  end

  local screenshotApi = ui_photomode_shared.getScreenshotApi()
  if not screenshotApi or type(screenshotApi.doSteamScreenshot) ~= "function" then
    return {
      ok = false,
      reason = "screenshot_method_missing",
      mode = "steam",
    }
  end

  local requestOk, requestError = requestScreenshotCall(
    "steam",
    screenshotApi.doSteamScreenshot,
    { callOrigin = "ui_pause_photomode", upload = useUpload == true }
  )
  if not requestOk then
    log("E", logTag, "requestSteamScreenshot failed: " .. tostring(requestError))
    return {
      ok = false,
      reason = "screenshot_request_failed",
      mode = "steam",
    }
  end

  ui_photomode_shared.playPhotoCaptureSound()
  M.markCaptureInProgress(CAPTURE_IN_PROGRESS_FRAMES)
  gameplay_achievement.unlockAchievement("SCREENSHOT_TAKEN")
  return {
    ok = true,
    mode = useUpload and "upload_steam" or "steam",
    captureUiHoldFrames = ui_photomode_flash.getCaptureUiHoldFrames(),
  }
end

local function requestMotionScreenshotWithMode(requestedOutputMode)
  if not ui_photomode_shared.S.sessionActive then
    return {
      ok = false,
      reason = "session_inactive",
      mode = "motion",
    }
  end

  if pendingBasicCapture or ui_photomode_shared.S.pendingMotionCapture then
    return {
      ok = false,
      reason = "capture_busy",
      mode = "motion",
    }
  end

  if requestedOutputMode ~= "upload" and requestedOutputMode ~= "steam" and requestedOutputMode ~= "upload_steam" then
    requestedOutputMode = "basic"
  end

  local screenshotLoaded, screenshotApi = pcall(require, "screenshot")
  if not screenshotLoaded or type(screenshotApi) ~= "table" then
    return {
      ok = false,
      reason = "screenshot_unavailable",
      mode = "motion",
    }
  end

  if type(screenshotApi.takeMotionBlurScreenShot) ~= "function" then
    return {
      ok = false,
      reason = "screenshot_method_missing",
      mode = "motion",
    }
  end

  if requestedOutputMode == "upload" or requestedOutputMode == "upload_steam" then
    local uploadAction = ui_photomode_shared.buildMediaActions().capture.upload
    if not uploadAction or uploadAction.enabled ~= true then
      return {
        ok = false,
        reason = uploadAction and uploadAction.reason or "upload_unavailable",
        mode = "motion_upload",
      }
    end
  end
  if requestedOutputMode == "steam" or requestedOutputMode == "upload_steam" then
    local steamAction = ui_photomode_shared.buildMediaActions().capture.steam
    if not steamAction or steamAction.enabled ~= true then
      return {
        ok = false,
        reason = steamAction and steamAction.reason or "steam_unavailable",
        mode = "motion_steam",
      }
    end
    if type(screenshotApi.doSteamScreenshot) ~= "function" then
      return {
        ok = false,
        reason = "screenshot_method_missing",
        mode = "motion_steam",
      }
    end
  end

  local captureRequest = M.buildNormalizedCaptureSettings(captureSettings)
  local motionAvailability = buildMotionCaptureAvailability()
  if not motionAvailability.motionBlurAvailable or not motionAvailability.motionBlurEnabled then
    return {
      ok = false,
      reason = "motion_blur_disabled",
      mode = "motion",
    }
  end

  if requestedOutputMode == "basic" and not prepareHdrRuntimeForCapture(captureRequest.hdrScreenshot) then
    return {
      ok = false,
      reason = "hdr_unavailable",
      mode = "motion",
    }
  end

  local attachActive = false
  if motionBehaviorAttachesToVehicle(captureRequest.motionBehavior) and extensions and type(extensions.load) == "function" then
    local loadOk, loadError = pcall(extensions.load, "util/photomodeAttach")
    if not loadOk then
      log("E", logTag, "requestMotionScreenshot attach load failed: " .. tostring(loadError))
    else
      local attachExtension = extensions and extensions.util_photomodeAttach or nil
      if attachExtension and type(attachExtension.enable) == "function" then
        local enableOk, enableError = pcall(attachExtension.enable, true, { followRotation = motionBehaviorFollowsRotation(captureRequest.motionBehavior) })
        if not enableOk then
          log("E", logTag, "requestMotionScreenshot attach enable failed: " .. tostring(enableError))
        else
          attachActive = true
        end
      end
    end
  end

  local repauseAfterCapture = false
  local restorePhotomodePauseRequest = releaseMotionCapturePauseRequest()
  if simTimeAuthority and type(simTimeAuthority.getPause) == "function" and type(simTimeAuthority.pause) == "function" then
    if simTimeAuthority.getPause() == true then
      simTimeAuthority.pause(false)
      repauseAfterCapture = true
    end
  end

  ui_photomode_shared.S.pendingMotionCapture = {
    screenshotApi = screenshotApi,
    warmupFramesRemaining = MOTION_CAPTURE.warmupFrames,
    cleanupFramesRemaining = MOTION_CAPTURE.cleanupFrames,
    repauseAfterCapture = repauseAfterCapture,
    restorePhotomodePauseRequest = restorePhotomodePauseRequest,
    attachActive = attachActive,
    outputMode = requestedOutputMode,
    captureRequest = captureRequest,
  }

  ui_photomode_shared.logDebug(
    "motion screenshot scheduled (warmupFrames="
      .. tostring(MOTION_CAPTURE.warmupFrames)
      .. ", cleanupFrames="
      .. tostring(MOTION_CAPTURE.cleanupFrames)
      .. ", attachActive="
      .. tostring(attachActive)
      .. ", repause="
      .. tostring(repauseAfterCapture)
      .. ")"
  )

  return {
    ok = true,
    mode = requestedOutputMode == "upload_steam" and "motion_upload_steam"
      or requestedOutputMode == "upload" and "motion_upload"
      or requestedOutputMode == "steam" and "motion_steam"
      or "motion",
    captureUiHoldFrames = MOTION_CAPTURE.warmupFrames + MOTION_CAPTURE.cleanupFrames + ui_photomode_flash.getCaptureUiHoldFrames(),
  }
end

function M.requestScreenshot(options)
  local opts = type(options) == "table" and options or {}
  local useMotion = opts.motion == true
  local useUpload = opts.upload == true
  local useSteam = opts.steam == true

  if useMotion then
    local outputMode = "basic"
    if useUpload and useSteam then
      outputMode = "upload_steam"
    elseif useUpload then
      outputMode = "upload"
    elseif useSteam then
      outputMode = "steam"
    end
    return requestMotionScreenshotWithMode(outputMode)
  end

  if useSteam then
    return requestSteamScreenshot(useUpload)
  end
  if useUpload then
    return requestUploadScreenshot()
  end
  return requestBasicScreenshot()
end


function M.setResolutionPreset(presetId)
  if not M.isResolutionPresetFeatureEnabled() then
    return {
      ok = false,
      reason = "shipping_build_required",
      state = buildResolutionPresetStateForSelection(ui_photomode_shared.S.selectedResolutionPresetId),
    }
  end

  local preset = M.findResolutionPreset(presetId)
  if not preset then
    return {
      ok = false,
      reason = "resolution_preset_invalid",
      state = buildResolutionPresetStateForSelection(ui_photomode_shared.S.selectedResolutionPresetId),
    }
  end

  local applyOk, applyReason = M.applyResolutionPreset(preset)
  if not applyOk then
    return {
      ok = false,
      reason = applyReason or "resolution_apply_failed",
      state = buildResolutionPresetStateForSelection(ui_photomode_shared.S.selectedResolutionPresetId),
    }
  end

  ui_photomode_shared.S.selectedResolutionPresetId = preset.id

  return {
    ok = true,
    state = buildResolutionPresetStateForSelection(ui_photomode_shared.S.selectedResolutionPresetId),
  }
end


function M.handlePreRender(dtReal, dtSim, dtRaw)
  if ui_photomode_shared.S.captureInProgressFramesRemaining > 0 then
    ui_photomode_shared.S.captureInProgressFramesRemaining = ui_photomode_shared.S.captureInProgressFramesRemaining - 1
  end

  if pendingBasicCapture then
    if pendingBasicCapture.awaitingScreenshotDone == true then
      return
    end

    pendingBasicCapture.hdrSettleFramesRemaining = (pendingBasicCapture.hdrSettleFramesRemaining or 0) - 1
    local hdrSettled = isHdrRuntimeActive() == (pendingBasicCapture.captureRequest.hdrScreenshot == true)
    if not hdrSettled and pendingBasicCapture.hdrSettleFramesRemaining > 0 then
      return
    end
    if not hdrSettled then
      log("W", logTag, "requestBasicScreenshot HDR settle timeout")
    end

    if not executeBasicScreenshotRequest(pendingBasicCapture) then
      return
    end
    pendingBasicCapture.awaitingScreenshotDone = true
    return
  end

  local motionCapture = ui_photomode_shared.S.pendingMotionCapture
  if not motionCapture then
    return
  end

  if motionCapture.warmupFramesRemaining and motionCapture.warmupFramesRemaining > 0 then
    motionCapture.warmupFramesRemaining = motionCapture.warmupFramesRemaining - 1
    if motionCapture.warmupFramesRemaining > 0 then
      return
    end

    local requestOk, requestError = true, nil
    local captureRequest = motionCapture.captureRequest or M.buildNormalizedCaptureSettings(captureSettings)
    if motionCapture.outputMode == "steam" or motionCapture.outputMode == "upload_steam" then
      requestOk, requestError = requestScreenshotCall(
        "steam",
        motionCapture.screenshotApi.doSteamScreenshot,
        {
          callOrigin = "ui_pause_photomode",
          upload = motionCapture.outputMode == "upload_steam",
        }
      )
    else
      requestOk, requestError = requestScreenshotCall(
        "takeMotionBlurScreenShot",
        motionCapture.screenshotApi.takeMotionBlurScreenShot,
        captureRequest.superSampling or M.DEFAULTS.superSampling,
        M.buildCaptureRescaleFactor(captureRequest.downscaleLevel or M.DEFAULTS.downscaleLevel),
        captureRequest.splitSceneVehicle or false,
        captureRequest.saveNormalDepth or false,
        {
          callOrigin = "ui_pause_photomode",
          upload = motionCapture.outputMode == "upload",
        }
      )
    end
    if not requestOk then
      log("E", logTag, "requestMotionScreenshot failed: " .. tostring(requestError))
      M.finishPendingMotionCapture()
      return
    end

    ui_photomode_shared.playPhotoCaptureSound()
    gameplay_achievement.unlockAchievement("SCREENSHOT_TAKEN")
    motionCapture.cleanupFramesRemaining = MOTION_CAPTURE.cleanupFrames + ui_photomode_flash.getCaptureUiHoldFrames()
    return
  end

  motionCapture.cleanupFramesRemaining = (motionCapture.cleanupFramesRemaining or 0) - 1
  if motionCapture.cleanupFramesRemaining > 0 then
    return
  end

  M.finishPendingMotionCapture()
end

function M.onScreenshotAllDone()
  finishPendingBasicCapture()
end


return M
