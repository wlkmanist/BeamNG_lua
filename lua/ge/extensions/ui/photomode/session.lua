-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  "ui_photomode_shared",
  "ui_photomode_camera",
  "ui_photomode_scene",
  "ui_photomode_flash",
  "ui_photomode_effects",
  "ui_photomode_advancedRender",
  "ui_photomode_capture",
  "ui_photomode_presets",
}


local DEFAULT_PHOTOMODE_PROFILE = "pause"
local PERSISTENT_SESSION_SETTING = "photomodePersistentSession"
local PANEL_SURFACE_MODES = {
  hidden = true,
  settings = true,
}

-- Fixed per-route profile policy. `hiddenControls` is sparse: a missing key means
-- normal/default visibility, while a key set to `true` hides that control for the
-- active profile. `features` overrides specific capability feature flags.
-- This is a UI visibility policy only; it intentionally does not guard Lua mutations,
-- so direct calls that change hidden fields are still allowed.
local PHOTOMODE_PROFILES = {
  pause = {
    hiddenControls = {},
  },
  garage = {
    hiddenControls = {
      scene = {
        timeOfDay = true,
        cloudCover = true,
      },
      effects = {
        motionBlur = true,
      },
      advancedRender = {
        terrainLodScale = true,
        grassDensity = true,
        cloudQuality = true,
      },
    },
    features = {
      motionBlurCapture = false,
    },
  },
}

local function getActiveProfile()
  return PHOTOMODE_PROFILES[ui_photomode_shared.S.activeProfile] or PHOTOMODE_PROFILES[DEFAULT_PHOTOMODE_PROFILE]
end

local function getActiveProfileHiddenControls()
  local profile = getActiveProfile()
  return profile and profile.hiddenControls or {}
end

local function getActiveProfileFeatureOverrides()
  local profile = getActiveProfile()
  return profile and profile.features or {}
end

local PHOTOMODE_PAUSE_REQUEST_ID = "ui_pause_photomode"
local PHOTOMODE_CAMERA_ACTION_MAP = "PhotoModeCamera"
local hiddenCameraInputEnabled = false

local function setHiddenCameraInputEnabled(enabled)
  enabled = enabled == true
  if enabled == hiddenCameraInputEnabled then
    return true
  end

  if enabled then
    pushActionMap(PHOTOMODE_CAMERA_ACTION_MAP)
  else
    popActionMap(PHOTOMODE_CAMERA_ACTION_MAP)
  end

  hiddenCameraInputEnabled = enabled
  ui_photomode_shared.logDebug("hidden camera input enabled=" .. tostring(enabled))
  return true
end

local function applyPhotomodePauseRequest()
  if simTimeAuthority and type(simTimeAuthority.getPause) == "function" then
    ui_photomode_shared.S.photomodePauseWasPaused = simTimeAuthority.getPause() == true
  end

  if simTimeAuthority and type(simTimeAuthority.pushPauseRequest) == "function" then
    simTimeAuthority.pushPauseRequest(PHOTOMODE_PAUSE_REQUEST_ID)
    ui_photomode_shared.S.photomodePauseRequestApplied = true
  end

  if simTimeAuthority and type(simTimeAuthority.pause) == "function" then
    simTimeAuthority.pause(true)
  end
end

local function releasePhotomodePauseRequest()
  if not ui_photomode_shared.S.photomodePauseRequestApplied then
    return
  end

  if simTimeAuthority and type(simTimeAuthority.popPauseRequest) == "function" then
    simTimeAuthority.popPauseRequest(PHOTOMODE_PAUSE_REQUEST_ID)
  end

  ui_photomode_shared.S.photomodePauseRequestApplied = false
  if ui_photomode_shared.S.photomodePauseWasPaused
    and simTimeAuthority
    and type(simTimeAuthority.getPause) == "function"
    and type(simTimeAuthority.pause) == "function"
    and simTimeAuthority.getPause() ~= true
  then
    simTimeAuthority.pause(true)
  end
  ui_photomode_shared.S.photomodePauseWasPaused = false
end

local function getCurrentLevelId()
  return type(getCurrentLevelIdentifier) == "function" and tostring(getCurrentLevelIdentifier() or "") or ""
end

local function capturePersistentSessionState()
  local cameraState = ui_photomode_camera.getCameraState()
  ui_photomode_shared.S.persistentSessionState = {
    levelId = getCurrentLevelId(),
    camera = ui_photomode_camera.capturePresetState(),
    cameraControls = {
      fov = cameraState.fov,
      rollDeg = cameraState.rollDeg,
      speed = cameraState.speed,
      smoothMovement = cameraState.smoothMovement,
      autoExposure = cameraState.autoExposure,
      manualEV = cameraState.manualEV,
    },
    scene = ui_photomode_scene.capturePresetState(),
    effects = ui_photomode_effects.capturePresetState(),
    capture = ui_photomode_capture.buildMetadataState(),
    resolutionPresetId = ui_photomode_shared.S.selectedResolutionPresetId,
  }
end

local function logPersistentApplyFailure(scope, result)
  if type(result) == "table" and result.ok == false then
    ui_photomode_shared.logDebug(
      "persistent session " .. tostring(scope) .. " apply failed: " .. tostring(result.reason)
    )
  end
end

local function applyPersistentSessionState()
  local state = ui_photomode_shared.S.persistentSessionState
  if type(state) ~= "table" then
    return
  end

  if type(state.scene) == "table" then
    logPersistentApplyFailure("scene", ui_photomode_scene.applyPresetState(state.scene))
  end
  if type(state.effects) == "table" then
    logPersistentApplyFailure("effects", ui_photomode_effects.applyPresetState(state.effects))
  end

  if type(state.camera) == "table" and state.levelId == getCurrentLevelId() then
    logPersistentApplyFailure("camera pose", ui_photomode_camera.applyPresetState(state.camera))
  end
  if type(state.cameraControls) == "table" then
    logPersistentApplyFailure("camera controls", ui_photomode_camera.applyPresetState(state.cameraControls))
  end

  if type(state.capture) == "table" then
    logPersistentApplyFailure("capture", ui_photomode_capture.setCaptureState(state.capture))
  end
  if state.resolutionPresetId ~= nil then
    logPersistentApplyFailure("resolution preset", ui_photomode_capture.setResolutionPreset(state.resolutionPresetId))
  end
end


local function resetLocalSessionState()
  ui_photomode_capture.finishPendingMotionCapture()
  setHiddenCameraInputEnabled(false)
  releasePhotomodePauseRequest()
  ui_photomode_shared.S.sessionActive = false
  ui_photomode_shared.S.suppressionsApplied = false
  ui_photomode_shared.S.previousCompatPhotoModeOpen = false
  ui_photomode_shared.S.sessionCameraRestoreState = nil
  ui_photomode_shared.S.sessionSceneRestoreState = nil
  ui_photomode_shared.S.sessionEffectsRestoreState = nil
  ui_photomode_shared.S.sessionEffectsRestoreStatePersisted = false
  ui_photomode_shared.S.sessionAdvancedRenderRestoreState = nil
  ui_photomode_shared.S.sessionNodeGrabberRestoreState = nil
  ui_photomode_shared.S.nodeGrabberVisible = false
  ui_photomode_shared.S.sessionDofManualFocusRange = nil
  ui_photomode_shared.S.pendingPreviewPlayback = nil
  ui_photomode_shared.S.captureInProgressFramesRemaining = 0
  ui_photomode_shared.S.photomodePauseRequestApplied = false
  ui_photomode_shared.S.photomodePauseWasPaused = false
  ui_photomode_shared.S.selectedResolutionPresetId = nil
  ui_photomode_shared.S.pendingExitNavigation = nil
  ui_photomode_shared.S.exitConfirmationBypass = false
  ui_photomode_shared.S.persistentSessionState = nil
  ui_photomode_shared.S.advancedRenderTuningEnabledOverride = nil
  ui_photomode_capture.resetSettings()
  ui_photomode_presets.resetTemporaryPresets()
end

local function buildCapabilities()
  local mediaActions = ui_photomode_shared.buildMediaActions()
  local developerToolsEnabled = not shipping_build
  local advancedRenderTuningEnabled = ui_photomode_advancedRender.isTuningEnabled()
  local advancedRenderUnlockVisible = ui_photomode_advancedRender.isUnlockVisible()
  local resolutionPresetState = ui_photomode_capture.buildResolutionPresetState()
  local featureOverrides = getActiveProfileFeatureOverrides()

  local function resolveFeature(key, value)
    if featureOverrides[key] ~= nil then
      return featureOverrides[key]
    end
    return value
  end

  return {
    profile = ui_photomode_shared.S.activeProfile,
    hiddenControls = getActiveProfileHiddenControls(),
    sections = {
      camera = true,
      scene = true,
      effects = true,
      capture = true,
      developer = developerToolsEnabled,
    },
    features = {
      upload = resolveFeature("upload", mediaActions.capture.upload.visible == true),
      steam = resolveFeature("steam", mediaActions.capture.steam.visible == true),
      openShareUrl = resolveFeature("openShareUrl", mediaActions.preview.openShareUrl.visible == true),
      overlays = resolveFeature("overlays", true),
      resolutionPresets = resolveFeature("resolutionPresets", resolutionPresetState.visible == true),
      motionBlurCapture = resolveFeature("motionBlurCapture", true),
      advancedRenderTuning = resolveFeature("advancedRenderTuning", advancedRenderTuningEnabled),
      advancedRenderTuningUnlock = resolveFeature("advancedRenderTuningUnlock", advancedRenderUnlockVisible),
      developerTools = resolveFeature("developerTools", developerToolsEnabled),
    },
    build = {
      shipping = shipping_build == true,
      developer = developerToolsEnabled,
    },
    advancedRender = {
      enabled = advancedRenderTuningEnabled,
      defaultEnabled = ui_photomode_advancedRender.getDefaultEnabled(),
      unlockVisible = advancedRenderUnlockVisible,
      unlockAllowed = true,
      reason = advancedRenderTuningEnabled and nil or "advanced_render_locked",
    },
  }
end


local function applySuppressions()
  if ui_photomode_shared.S.suppressionsApplied then
    return
  end

  ui_photomode_shared.S.previousCompatPhotoModeOpen = photoModeOpen == true
  ui_photomode_shared.S.photoModeOpen = true
  photoModeOpen = true
  ui_photomode_shared.S.suppressionsApplied = true
  ui_photomode_shared.logDebug("suppressions applied (photoModeOpen=true)")
end

local function restoreSuppressions()
  if not ui_photomode_shared.S.suppressionsApplied then
    return
  end

  ui_photomode_shared.S.photoModeOpen = ui_photomode_shared.S.previousCompatPhotoModeOpen
  photoModeOpen = ui_photomode_shared.S.previousCompatPhotoModeOpen
  ui_photomode_shared.S.suppressionsApplied = false
  ui_photomode_shared.logDebug("suppressions restored (photoModeOpen=" .. tostring(ui_photomode_shared.S.photoModeOpen) .. ")")
end

local function getSuppressionState()
  return {
    worldSuppressionActive = ui_photomode_shared.S.suppressionsApplied,
    compatibility = {
      photoModeOpen = {
        active = ui_photomode_shared.S.photoModeOpen == true,
        previousValue = ui_photomode_shared.S.previousCompatPhotoModeOpen,
        owner = "ui_pause_photomode",
      },
    },
    targets = {
      markers = ui_photomode_shared.S.suppressionsApplied,
      interactions = ui_photomode_shared.S.suppressionsApplied,
    },
  }
end

local function getRoutePayload()
  local mediaActions = ui_photomode_shared.buildMediaActions()
  local payload = {
    contractVersion = ui_photomode_shared.S.routePayloadContractVersion,
    sessionActive = ui_photomode_shared.S.sessionActive,
    capabilities = buildCapabilities(),
    capture = ui_photomode_capture.buildState(),
    persistentSession = {
      enabled = M.isPersistentSessionEnabled(),
    },
    panelSurfaceMode = M.getPanelSurfaceMode(),
    mediaActions = mediaActions,
    resolutionPresets = ui_photomode_capture.buildResolutionPresetState(),
    suppressions = getSuppressionState(),
  }
  return payload
end


function M.isPhotomodeSessionActive()
  return ui_photomode_shared.S.sessionActive
end

function M.isCaptureInProgress()
  return ui_photomode_capture.isCaptureInProgress()
end

function M.isPersistentSessionEnabled()
  return ui_photomode_shared.normalizeBoolean(
    ui_photomode_shared.readSettingValue(PERSISTENT_SESSION_SETTING),
    false
  )
end

function M.setPersistentSessionEnabled(value)
  local enabled = ui_photomode_shared.normalizeBoolean(value, false)
  local ok = ui_photomode_shared.writeSettingValue(PERSISTENT_SESSION_SETTING, enabled)
  if not ok then
    return {
      ok = false,
      enabled = M.isPersistentSessionEnabled(),
    }
  end
  if not enabled then
    ui_photomode_shared.S.persistentSessionState = nil
  end
  ui_photomode_shared.notifySettingsUi()
  return {
    ok = ok,
    enabled = enabled,
  }
end

function M.getPanelSurfaceMode()
  local mode = ui_photomode_shared.S.panelSurfaceMode
  return PANEL_SURFACE_MODES[mode] and mode or "hidden"
end

function M.setPanelSurfaceMode(mode)
  if not PANEL_SURFACE_MODES[mode] then
    return {
      ok = false,
      mode = M.getPanelSurfaceMode(),
    }
  end
  ui_photomode_shared.S.panelSurfaceMode = mode
  return {
    ok = true,
    mode = mode,
  }
end

function M.consumeExitConfirmationBypass()
  if ui_photomode_shared.S.exitConfirmationBypass ~= true then
    return false
  end
  ui_photomode_shared.S.exitConfirmationBypass = false
  return true
end

function M.requestExitConfirmation(route, params, context)
  context = type(context) == "table" and context or {}
  local routeName = context.routeName or (type(route) == "table" and route.name)
  if type(routeName) ~= "string" or routeName == "" then
    return false
  end

  if type(ui_photomode_shared.S.pendingExitNavigation) == "table" then
    return true
  end

  ui_photomode_shared.S.pendingExitNavigation = {
    routeName = routeName,
    params = params,
    options = context.options,
    restoreHiddenCameraInput = hiddenCameraInputEnabled,
  }
  setHiddenCameraInputEnabled(false)

  guihooks.trigger("showConfirmationDialog", {
    title = "ui.photomode.exitConfirmation.title",
    text = M.isPersistentSessionEnabled()
      and "ui.photomode.exitConfirmation.remembered"
      or "ui.photomode.exitConfirmation.discarded",
    buttons = {
      {
        label = "ui.photomode.exitConfirmation.return",
        luaCallback = "ui_photomode_session.cancelExitConfirmation()",
        isCancel = true,
        default = true,
      },
      {
        label = "ui.photomode.exitConfirmation.exit",
        luaCallback = "ui_photomode_session.confirmExit()",
      },
    },
  })
  return true
end

function M.cancelExitConfirmation()
  local pendingNavigation = ui_photomode_shared.S.pendingExitNavigation
  ui_photomode_shared.S.pendingExitNavigation = nil
  if type(pendingNavigation) == "table"
    and pendingNavigation.restoreHiddenCameraInput == true
    and ui_photomode_shared.S.sessionActive
  then
    setHiddenCameraInputEnabled(true)
  end
end

function M.confirmExit()
  local pendingNavigation = ui_photomode_shared.S.pendingExitNavigation
  ui_photomode_shared.S.pendingExitNavigation = nil
  if type(pendingNavigation) ~= "table" or type(pendingNavigation.routeName) ~= "string" then
    return false
  end

  ui_photomode_shared.S.exitConfirmationBypass = true
  return extensions.ui_router.navigate(
    pendingNavigation.routeName,
    pendingNavigation.params,
    pendingNavigation.options
  )
end

function M.isDebugEnabled()
  return isDebugEnabled
end

function M.setDebugEnabled(value)
  isDebugEnabled = value == true
  local screenshotLoaded, screenshotApi = pcall(require, "screenshot")
  if screenshotLoaded and type(screenshotApi) == "table" and type(screenshotApi.setDebugTracingEnabled) == "function" then
    screenshotApi.setDebugTracingEnabled(isDebugEnabled)
  end
  ui_photomode_shared.logDebug("debug enabled=" .. tostring(isDebugEnabled))
end

function M.traceCaptureDebug(scope, payload)
  local message = tostring(scope or "capture")
  local details = ui_photomode_shared.stringifyDebugPayload(payload)
  if details ~= "" then
    message = message .. " " .. details
  end
  ui_photomode_shared.logDebug(message)
end

function M.onPhotomodeRouteEnter(routeName)
  ui_photomode_shared.logDebug("route enter=" .. tostring(routeName))
end

function M.onPhotomodeRouteLeave(routeName)
  ui_photomode_shared.logDebug("route leave=" .. tostring(routeName))
end

function M.beginPhotomodeSession(options)
  if ui_photomode_shared.S.sessionActive then
    ui_photomode_shared.logDebug("session begin ignored (already active)")
    return false
  end

  local requestedProfile = type(options) == "table" and options.profile or nil
  if requestedProfile ~= nil and PHOTOMODE_PROFILES[requestedProfile] then
    ui_photomode_shared.S.activeProfile = requestedProfile
  else
    ui_photomode_shared.S.activeProfile = DEFAULT_PHOTOMODE_PROFILE
  end
  ui_photomode_shared.logDebug("session profile=" .. tostring(ui_photomode_shared.S.activeProfile))

  ui_photomode_shared.S.advancedRenderTuningEnabledOverride = nil
  ui_photomode_presets.resetTemporaryPresets()

  ui_photomode_capture.refreshSessionDefaults()

  applyPhotomodePauseRequest()
  ui_photomode_camera.captureRestoreState()
  ui_photomode_scene.captureRestoreState()
  ui_photomode_effects.captureRestoreState()
  ui_photomode_advancedRender.captureRestoreState()
  ui_photomode_camera.captureNodeGrabberRestoreState()
  ui_photomode_presets.captureSessionDefaultPresets()
  ui_photomode_camera.activateSessionFreeCamera()
  applySuppressions()
  ui_photomode_shared.S.sessionActive = true
  if M.isPersistentSessionEnabled() then
    applyPersistentSessionState()
  end
  ui_photomode_shared.logDebug("session begin")
  return true
end

function M.endPhotomodeSession()
  if not ui_photomode_shared.S.sessionActive
    and not ui_photomode_shared.S.suppressionsApplied
    and not ui_photomode_shared.S.sessionCameraRestoreState
    and not ui_photomode_shared.S.sessionSceneRestoreState
    and not ui_photomode_shared.S.sessionEffectsRestoreState
    and not ui_photomode_shared.S.sessionAdvancedRenderRestoreState
    and not ui_photomode_shared.S.sessionNodeGrabberRestoreState
    and not ui_photomode_shared.S.pendingMotionCapture
    and not ui_photomode_shared.S.photomodePauseRequestApplied
  then
    ui_photomode_shared.logDebug("session end ignored (already inactive)")
    return false
  end

  ui_photomode_shared.logDebug("session end")
  ui_photomode_scene.logTimeOfDayDebug("endPhotomodeSession current", ui_photomode_scene.captureSerializableState())
  ui_photomode_capture.finishPendingMotionCapture()
  if M.isPersistentSessionEnabled() then
    capturePersistentSessionState()
  else
    ui_photomode_shared.S.persistentSessionState = nil
  end
  setHiddenCameraInputEnabled(false)
  ui_photomode_capture.restoreCaptureRuntimeState()
  ui_photomode_shared.S.sessionActive = false
  ui_photomode_scene.restoreState()
  ui_photomode_effects.restoreState()
  ui_photomode_advancedRender.restoreState()
  ui_photomode_camera.restoreState()
  ui_photomode_camera.restoreNodeGrabberState()
  ui_photomode_capture.resetSettings()
  ui_photomode_shared.S.selectedResolutionPresetId = nil
  restoreSuppressions()
  releasePhotomodePauseRequest()
  ui_photomode_shared.S.advancedRenderTuningEnabledOverride = nil
  ui_photomode_shared.S.activeProfile = DEFAULT_PHOTOMODE_PROFILE
  ui_photomode_presets.resetTemporaryPresets()
  ui_photomode_scene.logTimeOfDayDebug("endPhotomodeSession after", ui_photomode_scene.captureSerializableState())
  return true
end


function M.handleExtensionLoaded()
  ui_photomode_shared.S.savedCameraBookmark = nil
  ui_photomode_shared.S.savedRelativeCameraBookmark = nil
  ui_photomode_shared.S.savedEnvironmentBookmark = nil
  ui_photomode_shared.S.savedAdvancedRenderBookmark = nil
  resetLocalSessionState()
end

function M.handleExtensionUnloaded()
  M.endPhotomodeSession()
  ui_photomode_shared.S.savedCameraBookmark = nil
  ui_photomode_shared.S.savedRelativeCameraBookmark = nil
  ui_photomode_shared.S.savedEnvironmentBookmark = nil
  ui_photomode_shared.S.savedAdvancedRenderBookmark = nil
  resetLocalSessionState()
end

M.getRoutePayload = getRoutePayload
M.buildCapabilities = buildCapabilities
M.setHiddenCameraInputEnabled = setHiddenCameraInputEnabled


return M
