-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_photomode_session",
  "ui_photomode_camera",
  "ui_photomode_scene",
  "ui_photomode_effects",
  "ui_photomode_advancedRender",
  "ui_photomode_capture",
  "ui_photomode_preview",
  "ui_photomode_presets",
}

local FORWARDED_FUNCTIONS = {
  saveCurrentCameraBookmark = "ui_photomode_camera",
  isPhotomodeSessionActive = "ui_photomode_session",
  isCaptureInProgress = "ui_photomode_session",
  isPersistentSessionEnabled = "ui_photomode_session",
  setPersistentSessionEnabled = "ui_photomode_session",
  getPanelSurfaceMode = "ui_photomode_session",
  setPanelSurfaceMode = "ui_photomode_session",
  isDebugEnabled = "ui_photomode_session",
  setDebugEnabled = "ui_photomode_session",
  traceCaptureDebug = "ui_photomode_session",
  setHiddenCameraInputEnabled = "ui_photomode_session",
  onPhotomodeRouteEnter = "ui_photomode_session",
  onPhotomodeRouteLeave = "ui_photomode_session",
  beginPhotomodeSession = "ui_photomode_session",
  endPhotomodeSession = "ui_photomode_session",
  getCameraState = "ui_photomode_camera",
  getSceneState = "ui_photomode_scene",
  getEffectsState = "ui_photomode_effects",
  getAdvancedRenderState = "ui_photomode_advancedRender",
  getCaptureState = "ui_photomode_capture",
  getResolutionPresetState = "ui_photomode_capture",
  setCaptureState = "ui_photomode_capture",
  setEffectsState = "ui_photomode_effects",
  resetEffectsToDefaults = "ui_photomode_effects",
  setAdvancedRenderState = "ui_photomode_advancedRender",
  resetAdvancedRenderToDefaults = "ui_photomode_advancedRender",
  saveAdvancedRenderBookmark = "ui_photomode_advancedRender",
  loadAdvancedRenderBookmark = "ui_photomode_advancedRender",
  setSceneState = "ui_photomode_scene",
  saveEnvironmentBookmark = "ui_photomode_scene",
  loadEnvironmentBookmark = "ui_photomode_scene",
  setCameraFov = "ui_photomode_camera",
  setCameraExposureState = "ui_photomode_camera",
  setCameraSpeed = "ui_photomode_camera",
  setCameraRoll = "ui_photomode_camera",
  restoreCameraBookmark = "ui_photomode_camera",
  restoreSavedFreeCameraBookmark = "ui_photomode_camera",
  restoreSavedRelativeCameraBookmark = "ui_photomode_camera",
  restoreSessionCameraTransformState = "ui_photomode_camera",
  resetCameraDefaults = "ui_photomode_camera",
  requestScreenshot = "ui_photomode_capture",
  setNodeGrabberVisible = "ui_photomode_camera",
  setCameraSmoothMovement = "ui_photomode_camera",
  setAdvancedRenderTuningEnabled = "ui_photomode_advancedRender",
  openPreviewShareUrl = "ui_photomode_preview",
  setResolutionPreset = "ui_photomode_capture",
  playPreviewFromMetadata = "ui_photomode_preview",
  getRoutePayload = "ui_photomode_session",
  listPresets = "ui_photomode_presets",
  discoverTemporaryPresets = "ui_photomode_presets",
  saveCurrentPreset = "ui_photomode_presets",
  applyPreset = "ui_photomode_presets",
  deletePreset = "ui_photomode_presets",
  renamePreset = "ui_photomode_presets",
  applyPresetPayload = "ui_photomode_presets",
  savePresetPayload = "ui_photomode_presets",
  savePresetBundle = "ui_photomode_presets",
}

for functionName, targetName in pairs(FORWARDED_FUNCTIONS) do
  M[functionName] = function(...)
    return _G[targetName][functionName](...)
  end
end

function M.onCollectScreenshotMetadata(...)
  return ui_photomode_preview.collectScreenshotMetadata(...)
end

function M.onPreRender(...)
  return ui_photomode_capture.handlePreRender(...)
end

function M.onUpdate(...)
  return ui_photomode_preview.handleUpdate(...)
end

function M.onScreenshotAllDone(...)
  return ui_photomode_capture.onScreenshotAllDone(...)
end

function M.onExtensionLoaded(...)
  return ui_photomode_session.handleExtensionLoaded(...)
end

function M.onExtensionUnloaded(...)
  return ui_photomode_session.handleExtensionUnloaded(...)
end

return M
