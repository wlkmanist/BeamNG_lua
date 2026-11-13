-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_framing_procedural",
}

local function resolveCamera(cameraConfig, vehicle, configName, name, source)
  if type(cameraConfig) ~= "table"
    or not cameraConfig.posOffset
    or not cameraConfig.rotOffset
  then
    return nil
  end

  local position, rotation =
    extensions.util_screenshotCreator_thumbnailConfig.rewindCameraOffsets(
      cameraConfig.posOffset,
      cameraConfig.rotOffset,
      vehicle,
      configName
    )
  if not position or not rotation then return nil end

  return {
    pos = position,
    rot = rotation,
    name = name,
    debugData = {cameraSource = source, cameraConfig = cameraConfig},
  }
end

local function resolveOverride(context)
  if type(context) ~= "table" or not context.vehicle then
    return nil, "Configured framing requires context.vehicle"
  end

  local vehicle = context.vehicle
  local modelName = vehicle.jbeam or vehicle.JBeam
  local cameraConfigs =
    extensions.util_screenshotCreator_thumbnailConfig.getCameraConfig(modelName, context.configName)
  cameraConfigs = cameraConfigs or {}

  local config = cameraConfigs.vehCamConfig
  local model = cameraConfigs.modelCamConfig
  if config and config.configCamEnabled and config.cameraConfig then
    local result = resolveCamera(
      config.cameraConfig,
      vehicle,
      context.configName,
      "config camera",
      "config"
    )
    if result then return result end
  end

  if config and config.modelCamEnabled and model and model.cameraConfig then
    local result = resolveCamera(
      model.cameraConfig,
      vehicle,
      context.configName,
      "model camera",
      "model"
    )
    if result then return result end
  end

  return nil
end

local function resolve(context)
  local result, resolveError = resolveOverride(context)
  if resolveError then return nil, resolveError end
  if result then return result end
  return extensions.util_screenshotCreator_framing_procedural.resolve(context)
end

local function onScreenshotCreatorCollectFramingModes(modes)
  modes[#modes + 1] = {
    id = "configured",
    label = "Configured camera",
    order = 200,
    resolve = resolve,
  }
end

M.resolve = resolve
M.resolveOverride = resolveOverride
M.frame = resolve
M.onScreenshotCreatorCollectFramingModes = onScreenshotCreatorCollectFramingModes

return M
