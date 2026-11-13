-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_imgui",
  "ui_imguiUtils",
  "ui_vehicleSelector_tileGrouping",
  "render_renderViews",
  "core_vehicle_manager",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_shippedConfigs",
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_nodeOutpaint",
  "util_screenshotCreator_vehicleSetup",
  "util_screenshotCreator_capture",
  "util_screenshotCreator_framing_legacy",
  "util_screenshotCreator_framing_isometric",
  "util_screenshotCreator_framing_procedural",
  "util_screenshotCreator_framing_configured",
  "util_screenshotCreator_framingManager",
  "util_screenshotCreator_modelSelection",
  "util_screenshotCreator_job",
  "util_screenshotCreator_thumbnailPaths",
  "util_screenshotCreator_thumbnailTargets",
  "util_screenshotCreator_thumbnailCapturePipeline",
  "util_screenshotCreator_currentConfigThumbnail",
  "util_screenshotCreator_ui"
}

M.state = {show = false}

local function openWindow()
  return util_screenshotCreator_ui.openWindow()
end

local function startWork(workOptions)
  return util_screenshotCreator_job.startWork(workOptions)
end

local function frameVehicle(vehicle, fov, nearPlane, aspectRatio, resolution, configName)
  local context = util_screenshotCreator_settings.getFramingContext(resolution)
  context.vehicle = vehicle
  context.configName = configName
  context.fov = fov or context.fov
  context.fieldOfView = context.fov
  context.nearPlane = nearPlane or context.nearPlane
  context.aspectRatio = aspectRatio or context.aspectRatio

  local result, resolveError = util_screenshotCreator_framing_procedural.resolve(context)
  if not result then
    log("E", "screenshotCreator", "Unable to frame vehicle: " .. tostring(resolveError))
    return nil, nil, nil
  end
  return result.pos, result.rot, result.framingData
end

local function takeThumbnailScreenshot(filepath, camera, callback, uniqueId)
  local captureContext = util_screenshotCreator_settings.getCaptureContext()
  return util_screenshotCreator_capture.takeThumbnailScreenshot(
    filepath,
    camera,
    callback,
    uniqueId,
    {
      resolution = captureContext.resolution,
      supersampling = captureContext.superSampling,
      fov = util_screenshotCreator_settings.getFramingContext(captureContext.resolution).fov,
      nearPlane = util_screenshotCreator_settings.getThumbnailConfig().nearPlane
    }
  )
end

local function onDeserialized(data)
  if type(data) == "table" and (
    data.windowOpen ~= nil
    or data.resolutionPtr ~= nil
    or data.reviewData ~= nil
    or data.skipCustomCameras ~= nil
  ) then
    util_screenshotCreator_ui.onDeserialized(data)
  end
end

local function onExtensionUnloaded()
  if util_screenshotCreator_settings and util_screenshotCreator_settings.restoreEnvironment then
    util_screenshotCreator_settings.restoreEnvironment()
  end
  log("I", "screenshotCreator", "Module unloaded")
end

M.openWindow = openWindow
M.startWork = startWork
M.frameVehicle = frameVehicle
M.takeThumbnailScreenshot = takeThumbnailScreenshot
M.listFramingModes = function()
  return util_screenshotCreator_framingManager.listModes()
end
M.getFramingMode = function()
  return util_screenshotCreator_framingManager.getSelectedModeId()
end
M.setFramingMode = function(modeId)
  return util_screenshotCreator_framingManager.setSelectedModeId(modeId)
end
M.onDeserialized = onDeserialized
M.onExtensionUnloaded = onExtensionUnloaded

return M
