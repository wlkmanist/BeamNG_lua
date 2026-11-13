-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"core_camera", "core_vehicles"}

local function saveConfigFile(path, config)
  local info = jsonReadFile(path)
  if not info then
    if FS:fileExists(path) then
      log("E", "screenshotCreator", "Unable to read vehicle info file: " .. path)
      return false
    end
    info = {}
  end

  info.thumbnailConfig = config
  if not jsonWriteFile(path, info, true) then
    log("E", "screenshotCreator", "Unable to save thumbnail config: " .. path)
    return false
  end
  return true
end

function M.saveVehicleConfig(modelName, configName, config)
  local modelData = core_vehicles.getModel(modelName)
  local configData = modelData.configs and modelData.configs[configName]
  local path = configData and configData.infoFilename
    or string.format("/vehicles/%s/info_%s.json", modelName, configName)
  if not saveConfigFile(path, config) then
    return false
  end
  if configData then
    configData.thumbnailConfig = config
  end
  return true
end

function M.saveModelConfig(modelName, config)
  local path = string.format("/vehicles/%s/info.json", modelName)
  if not saveConfigFile(path, config) then
    return false
  end

  local modelData = core_vehicles.getModel(modelName)
  if modelData.model then
    modelData.model.thumbnailConfig = config
  end
  return true
end

function M.getCameraConfig(modelName, configName)
  local modelData = core_vehicles.getModel(modelName)
  local configData = modelData.configs and modelData.configs[configName]
  local vehicleConfig = configData and configData.thumbnailConfig
  if not vehicleConfig then
    local info = jsonReadFile(string.format("/vehicles/%s/info_%s.json", modelName, configName))
    vehicleConfig = info and info.thumbnailConfig
  end

  return {
    vehCamConfig = vehicleConfig or {
      configCamEnabled = false,
      modelCamEnabled = false
    },
    modelCamConfig = modelData.model and modelData.model.thumbnailConfig
  }
end

function M.getRotation(modelName, configName)
  local cameraConfigs = M.getCameraConfig(modelName, configName)
  if cameraConfigs.vehCamConfig.rotation ~= nil then
    return tonumber(cameraConfigs.vehCamConfig.rotation) or 0
  end
  if cameraConfigs.modelCamConfig and cameraConfigs.modelCamConfig.rotation ~= nil then
    return tonumber(cameraConfigs.modelCamConfig.rotation) or 0
  end
  return 0
end

function M.getPauseDelay(modelName, configName)
  local cameraConfigs = M.getCameraConfig(modelName, configName)
  if cameraConfigs.vehCamConfig.pauseDelay ~= nil then
    return math.max(tonumber(cameraConfigs.vehCamConfig.pauseDelay) or 0, 0)
  end
  if cameraConfigs.modelCamConfig and cameraConfigs.modelCamConfig.pauseDelay ~= nil then
    return math.max(tonumber(cameraConfigs.modelCamConfig.pauseDelay) or 0, 0)
  end
  return 0
end

-- vehicle box axes levelled to world up (heading kept), so a tilted spawn cannot tilt the camera
function M.getLevelAxes(bb)
  local up = vec3(0, 0, 1)
  local axis0, axis1 = bb:getAxis(0), bb:getAxis(1)
  local forward = vec3(axis1.x, axis1.y, 0):normalized()
  local right = forward:cross(up)
  if right:dot(axis0) < 0 then right = -right end
  return right, forward, up
end

function M.getReferenceAxes(vehicle, configName, boundingBox)
  local bb = boundingBox or vehicle:getSpawnWorldOOBB()
  local axis0, axis1, axis2 = M.getLevelAxes(bb)
  local rotation = M.getRotation(vehicle.jbeam or vehicle.JBeam, configName)
  if rotation == 0 then
    return axis0, axis1, axis2
  end

  local inverseRotation = quatFromEuler(0, 0, math.rad(-rotation))
  return inverseRotation * axis0, inverseRotation * axis1, inverseRotation * axis2
end

function M.getCameraOffsets(configName, vehicle)
  local veh = vehicle or getPlayerVehicle(0)
  local bb = veh:getSpawnWorldOOBB()
  local x, y, z = M.getReferenceAxes(veh, configName, bb)
  local vehicleToCamera = core_camera.getPosition() - veh:getPosition()
  local vehicleRotation = quatFromDir(y, z)
  local unrotatedCameraRotation = core_camera.getQuat() * vehicleRotation:inversed()
  local offset = vec3(
    x:dot(vehicleToCamera),
    y:dot(vehicleToCamera),
    z:dot(vehicleToCamera)
  )

  return offset, unrotatedCameraRotation
end

function M.rewindCameraOffsets(posOffset, rotOffset, vehicle, configName)
  local veh = vehicle or getPlayerVehicle(0)
  local bb = veh:getSpawnWorldOOBB()
  local x, y, z = M.getReferenceAxes(veh, configName, bb)
  local offset = x * posOffset.x + y * posOffset.y + z * posOffset.z
  local vehicleRotation = quatFromDir(y, z)

  return offset + veh:getPosition(), rotOffset * vehicleRotation
end

return M
