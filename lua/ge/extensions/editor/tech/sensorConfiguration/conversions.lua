-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local util = require('editor/tech/sensorConfiguration/utilities')                                   -- A utility class for the sensor configuration editors.
local stype = extensions.tech_sensors.stype

local function updateArgsForVehicle(args, veh)
  local pos = util.coeffs2PosVS(args.pos, veh)
  local dir, up = util.sensor2VS(args.dir, args.up, veh)
  args.pos = pos
  args.dir = dir
  args.up = up
  args.isStatic = false
end

local function makeCameraLive(s, veh, vid)
  local args = {
    name = s.name,
    pos = s.pos, dir = s.dir, up = s.up,
    requestedUpdateTime = s.requestedUpdateTime, updatePriority = s.updatePriority,
    size = s.size, fovY = s.fovY, nearFarPlanes = s.nearFarPlanes,
    renderColours = s.renderColours,
    renderAnnotations = s.renderAnnotations,
    renderInstance = s.renderInstance,
    renderDepth = s.renderDepth,
    renderTranslucentAsOpaqueDepth = s.renderTranslucentAsOpaqueDepth,
    isVisualised = s.isVisualised, isStatic = true,
    isDirWorldSpace = true,
    isSnappingDesired = s.isSnappingDesired, isForceInsideTriangle = s.isSnappingDesired
  }
  if veh then updateArgsForVehicle(args, veh) end
  return extensions.tech_sensors.createCamera(vid, args)
end

local function makeLidarLive(s, veh, vid)
  local args = {
    name = s.name,
    pos = s.pos, dir = s.dir, up = s.up,
    requestedUpdateTime = s.requestedUpdateTime, updatePriority = s.updatePriority,
    verticalResolution = s.verticalResolution, verticalAngle = s.verticalAngle,
    horizontalAngle = s.horizontalAngle, frequency = s.frequency,
    minDistance = s.minDistance,
    maxDistance = s.maxDistance,
    isRotate = s.isRotate, is360 = s.is360,
    isVisualised = s.isVisualised, isAnnotated = s.isAnnotated, isStatic = true,
    isDirWorldSpace = true,
    isSnappingDesired = s.isSnappingDesired, isForceInsideTriangle = s.isSnappingDesired
  }
  if veh then updateArgsForVehicle(args, veh) end
  return extensions.tech_sensors.createLidar(vid, args)
end

local function makeUltrasonicLive(s, veh, vid)
  local args = {
    name = s.name,
    pos = s.pos, dir = s.dir, up = s.up,
    requestedUpdateTime = s.requestedUpdateTime, updatePriority = s.updatePriority,
    size = s.size, fovY = s.fovY, nearFarPlanes = s.nearFarPlanes,
    rangeRoundness = s.rangeRoundness, rangeCutoffSensitivity = s.rangeCutoffSensitivity,
    rangeShape = s.rangeShape, rangeFocus = s.rangeFocus,
    rangeMinCutoff = s.rangeMinCutoff, rangeDirectMaxCutoff = s.rangeDirectMaxCutoff,
    sensitivity = s.sensitivity, fixedWindowSize = s.fixedWindowSize,
    isVisualised = s.isVisualised, isStatic = true,
    isDirWorldSpace = true,
    isSnappingDesired = s.isSnappingDesired, isForceInsideTriangle = s.isSnappingDesired
  }
  if veh then updateArgsForVehicle(args, veh) end
  return extensions.tech_sensors.createUltrasonic(vid, args)
end

local function makeRadarLive(s, veh, vid)
  local args = {
    name = s.name,
    pos = s.pos, dir = s.dir, up = s.up,
    requestedUpdateTime = s.requestedUpdateTime, updatePriority = s.updatePriority,
    size = s.size, fovY = s.fovY, nearFarPlanes = s.nearFarPlanes,
    rangeRoundness = s.rangeRoundness, rangeCutoffSensitivity = s.rangeCutoffSensitivity,
    rangeShape = s.rangeShape, rangeFocus = s.rangeFocus,
    rangeMinCutoff = s.rangeMinCutoff, rangeDirectMaxCutoff = s.rangeDirectMaxCutoff,
    rangeBins = s.rangeBins, azimuthBins = s.azimuthBins, velBins = s.velBins,
    rangeMin = s.rangeMin, rangeMax = s.rangeMax,
    halfAngleDeg = s.halfAngleDeg,
    velMin = s.velMin, velMax = s.velMax,
    isVisualised = s.isVisualised, isStatic = true,
    isDirWorldSpace = true,
    isSnappingDesired = s.isSnappingDesired, isForceInsideTriangle = s.isSnappingDesired
  }
  if veh then updateArgsForVehicle(args, veh) end
  return extensions.tech_sensors.createRadar(vid, args)
end

local function makeIMULive(s, veh, vid)
  local args = {
    name = s.name,
    pos = s.pos, dir = s.dir, up = s.up,
    physicsUpdateTime = s.physicsUpdateTime, GFXUpdateTime = s.GFXUpdateTime,
    isUsingGravity = s.isUsingGravity, isAllowWheelNodes = s.isAllowWheelNodes,
    smootherStrength = s.smootherStrength,
    isVisualised = s.isVisualised, isStatic = true,
    isDirWorldSpace = true,
    isSnappingDesired = s.isSnappingDesired, isForceInsideTriangle = s.isSnappingDesired
  }
  if veh then updateArgsForVehicle(args, veh) end
  return extensions.tech_sensors.createAdvancedIMU(vid, args)
end

local function makeGPSLive(s, veh, vid)
  local args = {
    name = s.name,
    pos = s.pos, dir = s.dir, up = s.up,
    physicsUpdateTime = s.physicsUpdateTime, GFXUpdateTime = s.GFXUpdateTime,
    isAllowWheelNodes = s.isAllowWheelNodes,
    refLon = s.refLon, refLat = s.refLat,
    isVisualised = s.isVisualised, isStatic = true,
    isDirWorldSpace = true,
    isSnappingDesired = s.isSnappingDesired, isForceInsideTriangle = false
  }
  if veh then updateArgsForVehicle(args, veh) end
  return extensions.tech_sensors.createGPS(vid, args)
end

local function makeIdealRadarLive(s, veh, vid)
  return extensions.tech_sensors.createIdealRADARSensor(vid, { physicsUpdateTime = s.physicsUpdateTime, GFXUpdateTime = s.GFXUpdateTime })
end

local function makeRoadsLive(s, veh, vid)
  return extensions.tech_sensors.createRoadsSensor(vid, { physicsUpdateTime = s.physicsUpdateTime, GFXUpdateTime = s.GFXUpdateTime })
end

local function makePowertrainLive(s, veh, vid)
  return extensions.tech_sensors.createPowertrainSensor(vid, { physicsUpdateTime = s.physicsUpdateTime, GFXUpdateTime = s.GFXUpdateTime })
end

local function makeMeshLive(s, veh, vid)
  return extensions.tech_sensors.createMeshSensor(vid, { physicsUpdateTime = s.physicsUpdateTime, GFXUpdateTime = s.GFXUpdateTime })
end

local makeLive = {
  [stype.tCamera] = makeCameraLive,
  [stype.tLiDAR] = makeLidarLive,
  [stype.tUltrasonic] = makeUltrasonicLive,
  [stype.tRADAR] = makeRadarLive,
  [stype.tIMU] = makeIMULive,
  [stype.tGPS] = makeGPSLive,
  [stype.tIdealRADAR] = makeIdealRadarLive,
  [stype.tRoads] = makeRoadsLive,
  [stype.tPowertrain] = makePowertrainLive,
  [stype.tMesh] = makeMeshLive
}

local function makeSensorLive(sensor, vehicle)
  local t = sensor.type
  local veh, vid = nil, -1
  if vehicle then
    veh, vid = vehicle.veh, vehicle.vid
  end
  sensor.id = makeLive[t](sensor, veh, vid)
end

local function makeSensorNotLive(sensor, vehicle)
  local t, sid = sensor.type, sensor.id
  local veh, vid = nil, -1
  if vehicle then
    veh, vid = vehicle.veh, vehicle.vid
  end
  if not sid then return end
  if t == stype.tCamera or t == stype.tLiDAR or t == stype.tUltrasonic or t == stype.tRADAR then
    extensions.tech_sensors.removeSensor(sid)
  elseif t == stype.tIMU then
    extensions.tech_sensors.removeAdvancedIMU(vid, sid)
  elseif t == stype.tGPS then
    extensions.tech_sensors.removeGPS(vid, sid)
  elseif t == stype.tIdealRADAR then
    extensions.tech_sensors.removeIdealRADARSensor(vid, sid)
  elseif t == stype.tRoads then
    extensions.tech_sensors.removeRoadsSensor(vid, sid)
  elseif t == stype.tPowertrain then
    extensions.tech_sensors.removePowertrainSensor(vid, sid)
  elseif t == stype.tMesh then
    extensions.tech_sensors.removeMeshSensor(vid, sid)
  end
end

local newSensors = {
  [stype.tCamera] = {
    isLive = false,
    id = nil,
    name = 'Camera ',
    type = stype.tCamera,
    pos = nil,
    dir = vec3(1, 0, 0),
    up = vec3(0, 0, 1),
    size = { 200, 200 },
    fovY = 70,
    nearFarPlanes = { 0.05, 100.0 },
    requestedUpdateTime = 0.05,
    updatePriority = 0.0,
    renderColours = true,
    renderAnnotations = true,
    renderInstance = false,
    renderDepth = true,
    renderTranslucentAsOpaqueDepth = false,
    isVisualised = true,
    isSnappingDesired = false },
  [stype.tLiDAR] = {
    isLive = false,
    id = nil,
    name = 'LiDAR ',
    type = stype.tLiDAR,
    pos = nil,
    dir = vec3(1, 0, 0),
    up = vec3(0, 0, 1),
    verticalResolution = 64,
    verticalAngle = 26.9,
    horizontalAngle = 120.0,
    frequency = 20.0,
    minDistance = 0.05,
    maxDistance = 120.0,
    isRotate = false, is360 = true,
    requestedUpdateTime = 0.05,
    updatePriority = 0.0,
    isVisualised = true,
    isAnnotated = false,
    isSnappingDesired = false },
  [stype.tUltrasonic] = {
    isLive = false,
    id = nil,
    name = 'Ultrasonic ',
    type = stype.tUltrasonic,
    pos = nil,
    dir = vec3(1, 0, 0),
    up = vec3(0, 0, 1),
    size = { 200, 200 },
    fovY = 70,
    nearFarPlanes = { 0.05, 5.1 },
    rangeRoundness = -1.15,
    rangeCutoffSensitivity = 0.0,
    rangeShape = 0.3,
    rangeFocus = 0.376,
    rangeMinCutoff = 0.1,
    rangeDirectMaxCutoff = 5.0,
    sensitivity = 3.0,
    fixedWindowSize = 10.0,
    requestedUpdateTime = 0.05,
    updatePriority = 0.0,
    isVisualised = true,
    isSnappingDesired = false },
  [stype.tRADAR] = {
    isLive = false,
    id = nil,
    name = 'RADAR ',
    type = stype.tRADAR,
    pos = nil,
    dir = vec3(1, 0, 0),
    up = vec3(0, 0, 1),
    size = { 200, 200 },
    fovY = 70,
    nearFarPlanes = { 0.05, 5.1 },
    rangeRoundness = -1.27,
    rangeCutoffSensitivity = 0.0,
    rangeShape = 0.09,
    rangeFocus = 0.37,
    rangeMinCutoff = 0.7,
    rangeDirectMaxCutoff = 300.0,
    rangeBins = 200,
    azimuthBins = 200,
    velBins = 200,
    rangeMin = 0.05,
    rangeMax = 100.0,
    halfAngleDeg = 30.0,
    velMin = -50.0,
    velMax = 50.0,
    requestedUpdateTime = 0.05,
    updatePriority = 0.0,
    isVisualised = true,
    isSnappingDesired = false },
  [stype.tIMU] = {
    isLive = false,
    id = nil,
    name = 'IMU ',
    type = stype.tIMU,
    pos = nil,
    dir = vec3(1, 0, 0),
    up = vec3(0, 0, 1),
    physicsUpdateTime = 0.01,
    GFXUpdateTime = 0.0,
    isUsingGravity = false,
    isAllowWheelNodes = false,
    smootherStrength = 1.0,
    isVisualised = true,
    isSnappingDesired = false },
  [stype.tGPS] = {
    isLive = false,
    id = nil,
    name = 'GPS ',
    type = stype.tGPS,
    pos = nil,
    dir = vec3(1, 0, 0),
    up = vec3(0, 0, 1),
    physicsUpdateTime = 0.01,
    GFXUpdateTime = 0.0,
    isAllowWheelNodes = false,
    refLon = 0.0,
    refLat = 0.0,
    isVisualised = true,
    isSnappingDesired = false }
}

local function createNewSensor(sensorType, ctr, pos)
  local template = newSensors[sensorType]
  if template == nil then
    return nil
  end
  local sensor = deepcopy(template)
  sensor.name = sensor.name .. ctr
  sensor.pos = pos
  return sensor
end

local function getLiveSensorConfiguration(sensorType, id, config)
  config.type = sensorType
  config.id = id
  config.isLive = true
  if not config.isStatic then
    local veh = getObjectByID(config.vid)
    if config.isDirWorldSpace == true then
      config.pos = util.posVS2Coeffs(config.pos, veh)
      config.dir, config.up = util.dirWorldSpace2Sensor(config.dir, config.up, veh)
    elseif config.isDirWorldSpace == false then
      config.pos = util.coeffsToDirWorldSpace(config.pos, veh)
      if config.dir ~= nil then
        config.dir = util.dirToDirWorldSpace(config.dir)
      end
      config.isDirWorldSpace = true
    end
  end
  return config
end

local function updateLiveSensorPositionDirection(sensor, vehicle)
  local dir, up, pos
  if vehicle == nil then
    dir, up = sensor.dir, sensor.up
    pos = sensor.pos
  else
    local veh = vehicle.veh
    dir, up = util.sensor2VS(sensor.dir, sensor.up, veh)
    pos = util.coeffs2PosVS(sensor.pos, veh)
    up = -up
  end
  if sensor.type == stype.tCamera then
    tech_sensors.setCameraSensorPosition(sensor.id, pos)
    tech_sensors.setCameraSensorDirection(sensor.id, dir)
    tech_sensors.setCameraSensorUp(sensor.id, up)
    return true
  end
  return false
end

M.makeSensorLive = makeSensorLive
M.makeSensorNotLive = makeSensorNotLive
M.createNewSensor = createNewSensor
M.getLiveSensorConfiguration = getLiveSensorConfiguration
M.updateLiveSensorPositionDirection = updateLiveSensorPositionDirection

return M