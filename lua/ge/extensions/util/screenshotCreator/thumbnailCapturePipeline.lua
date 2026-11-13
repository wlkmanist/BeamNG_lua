-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "core_vehicles",
  "core_camera",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_vehicleSetup",
  "util_screenshotCreator_capture",
  "util_screenshotCreator_lightingSetup",
  "util_screenshotCreator_framing_legacy",
  "util_screenshotCreator_framingManager",
  "util_screenshotCreator_thumbnailPaths"
}

local logTag = "thumbnailCapturePipeline"
local captureWarmupSeconds = 2
local legacyFramingMarginScale = 0.85
local framingMarginKeys = {"left", "right", "top", "bottom", "extraBottom"}
local savedMainCamera

-- Background blur in thumbnailComposerRun focuses from the main camera, so it has to look at the shot
local function pointMainCameraAt(camera, fov)
  savedMainCamera = savedMainCamera or core_camera.getContextCameraState(nil)
  local pos, rot = camera.pos, camera.rot
  core_camera.setByName(0, "free")
  core_camera.setPosRot(0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  core_camera.setFOV(0, camera.fov or fov or 20)
end

local function yieldSeconds(seconds)
  local start = os.clock()
  while os.clock() - start < seconds do coroutine.yield() end
end

local function setPhysicsForSettling()
  be:setPhysicsSpeedFactor(1)
  be:setPhysicsRunning(true)
end

-- "Warehouse angle" framing with slightly tighter margins, saved config/model cameras are ignored
function M.resolveCamera(vehicle, modelName, configName, outputResolution)
  local context = util_screenshotCreator_settings.getFramingContext(outputResolution)
  context.vehicle = vehicle
  context.modelName = modelName
  context.configName = configName
  context.framingModeId = "legacy"
  context.preview = false
  for _, key in ipairs(framingMarginKeys) do
    if type(context.margin) == "table" and context.margin[key] then
      context.margin[key] = context.margin[key] * legacyFramingMarginScale
    end
  end
  local camera, resolveError = util_screenshotCreator_framingManager.resolve("legacy", context)
  if type(camera) ~= "table" or not camera.pos or not camera.rot then
    log("E", logTag, "Framing did not return a valid camera: " .. tostring(resolveError))
    return nil
  end
  return camera, context
end

function M.processWorkItem(item, index, total, settingsSnapshot, runContext, options)
  local current = item.modelKey .. "/" .. tostring(item.configName)
  if options.sendProgress then options.sendProgress(index - 1, total, current) end

  setPhysicsForSettling()
  local vehicle = core_vehicles.replaceVehicle(item.modelKey, {config = item.configName, licenseText = "BeamNG"})
  yieldSeconds(0.7)
  vehicle = getPlayerVehicle(0) or vehicle
  if not vehicle then return {status = "failed", error = "Vehicle replacement failed"} end

  util_screenshotCreator_lightingSetup.restore()
  util_screenshotCreator_vehicleSetup.placeVehicleForThumbnail(vehicle, item.configName, runContext.initialPosition, runContext.initialRotation)
  vehicle:queueLuaCommand("input.event('parkingbrake', 1, 1)")
  vehicle:queueLuaCommand("input.event('throttle', 0, 2)")
  vehicle:queueLuaCommand("controller.mainController.setEngineIgnition(false)")

  setPhysicsForSettling()
  util_screenshotCreator_vehicleSetup.waitForVehicleToSettle(
    item.modelName,
    item.configName,
    settingsSnapshot.capture
  )
  if options.isCancelled and options.isCancelled() then return nil end
  if settingsSnapshot.capture.freezePhysics ~= false then
    be:setPhysicsRunning(false)
    if be:getPhysicsRunning() then
      return {status = "failed", error = "Unable to freeze physics before capture"}
    end
  end

  local camera, framingContext = M.resolveCamera(vehicle, item.modelName, item.configName, options.outputResolution)
  if not camera then return {status = "failed", error = "Unable to resolve camera"} end

  pointMainCameraAt(camera, framingContext.fieldOfView)
  if not util_screenshotCreator_lightingSetup.adjust(vehicle, camera) then
    return {status = "failed", error = "Unable to prepare screenshot lighting"}
  end
  yieldSeconds(captureWarmupSeconds)
  if options.isCancelled and options.isCancelled() then return nil end

  local paths = util_screenshotCreator_thumbnailPaths.makeOutputPaths(item, options.captureMode)
  local success = util_screenshotCreator_capture.captureFramedThumbnail(paths.final, camera, {
    resolution = options.outputResolution,
    supersampling = settingsSnapshot.capture.superSampling,
    fov = framingContext.fieldOfView,
    nearPlane = framingContext.nearPlane,
    captureTimeout = settingsSnapshot.captureTimeout
  })
  if success and paths.defaultFinal then FS:copyFile(paths.final, paths.defaultFinal) end
  if not util_screenshotCreator_lightingSetup.restore() then
    return {status = "failed", error = "Unable to restore screenshot lighting"}
  end
  if not success then return {status = "failed", error = "Capture failed"} end

  return {
    status = "saved",
    current = current,
    camera = camera.name,
    outputFolder = paths.outputFolder,
    outputPath = paths.final
  }
end

function M.resetRenderState()
  if savedMainCamera then
    core_camera.setContextCameraState(nil, savedMainCamera)
    savedMainCamera = nil
  end
  if util_screenshotCreator_lightingSetup then util_screenshotCreator_lightingSetup.restore() end
end

return M
