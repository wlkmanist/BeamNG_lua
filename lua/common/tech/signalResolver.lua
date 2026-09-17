-- Shared signal resolver for vlua (VSL, cosim). Lives in common/tech with cosimulationNames.
-- Resolves signal values at physics rate from obj, electrics, wheels, input, sensors, powertrain.

local M = {}

local dat = require('tech/cosimulationNames')
local names, groups = dat.names, dat.groups

local atan2, asin = math.atan2, math.asin
local sqrt = math.sqrt

local staticKinematicsData = {}

-- Sensor map populated at logger init: { IMUs={{name,id,ctrl}, ...}, GPSs=..., idealRADARs=..., roads=... }.
-- Lookup by sensor display name lets us resolve signals whose groupName is a per-instance sensor name (e.g. 'IMU 1').
local sensorMap = { IMUs = {}, GPSs = {}, idealRADARs = {}, roads = {} }
local imuByName, gpsByName = {}, {}

local function tryGetController(prefix, id)
  if not id then return nil end
  if controller and controller.getController then
    return controller.getController(prefix .. id)
  end
  return nil
end

-- Tries the exact id first, then small offsets — mirrors editor_cosimulationSignalEditor, which compensates
-- for ge<->vlua sensor id drift (eg. ge id 5 -> vlua controller 'advancedIMU6').
local function tryGetControllerWithOffset(prefix, id, maxOffset)
  if not id or not (controller and controller.getController) then return nil, 0 end
  for off = 0, (maxOffset or 8) do
    local c = controller.getController(prefix .. (id + off))
    if c then return c, off end
  end
  return nil, 0
end

local function bindSensorControllers()
  imuByName = {}
  local imuBound, imuTotal = 0, 0
  for _, v in ipairs(sensorMap.IMUs or {}) do
    if v and v.id then
      imuTotal = imuTotal + 1
      if not v.ctrl then
        local c, off = tryGetControllerWithOffset('advancedIMU', v.id, 8)
        v.ctrl = c
        if c and off ~= 0 then v.id = v.id + off end
      end
      if v.ctrl then imuBound = imuBound + 1 end
      if v.name then imuByName[v.name] = v end
    end
  end
  gpsByName = {}
  local gpsBound, gpsTotal = 0, 0
  for _, v in ipairs(sensorMap.GPSs or {}) do
    if v and v.id then
      gpsTotal = gpsTotal + 1
      if not v.ctrl then
        local c, off = tryGetControllerWithOffset('GPS', v.id, 8)
        v.ctrl = c
        if c and off ~= 0 then v.id = v.id + off end
      end
      if v.ctrl then gpsBound = gpsBound + 1 end
      if v.name then gpsByName[v.name] = v end
    end
  end
  local irBound, irTotal = 0, 0
  for _, v in ipairs(sensorMap.idealRADARs or {}) do
    if v and v.id then
      irTotal = irTotal + 1
      if not v.ctrl then
        local c, off = tryGetControllerWithOffset('idealRADARSensor', v.id, 8)
        v.ctrl = c
        if c and off ~= 0 then v.id = v.id + off end
      end
      if v.ctrl then irBound = irBound + 1 end
    end
  end
  local rdBound, rdTotal = 0, 0
  for _, v in ipairs(sensorMap.roads or {}) do
    if v and v.id then
      rdTotal = rdTotal + 1
      if not v.ctrl then
        local c, off = tryGetControllerWithOffset('roadsSensor', v.id, 8)
        v.ctrl = c
        if c and off ~= 0 then v.id = v.id + off end
      end
      if v.ctrl then rdBound = rdBound + 1 end
    end
  end
  log('I', 'signalResolver', string.format('sensor controllers bound: IMU %d/%d, GPS %d/%d, idealRADAR %d/%d, roads %d/%d',
    imuBound, imuTotal, gpsBound, gpsTotal, irBound, irTotal, rdBound, rdTotal))
end

local function safeObjCall(method)
  if obj and obj[method] then
    return obj[method](obj)
  end
  return nil
end

local function getDirectionVectors()
  local fwd = safeObjCall("getDirectionVector")
  local up = safeObjCall("getDirectionVectorUp")
  if not fwd or not up then
    return nil, nil, nil
  end
  fwd:normalize()
  up:normalize()
  local right = fwd:cross(up)
  return fwd, up, right
end

local function trimWheelId(s)
  if type(s) ~= 'string' then return s end
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function getWheelById(wheelId)
  if not wheels or not wheels.wheels then
    return nil
  end
  wheelId = trimWheelId(wheelId)
  local idx = tonumber(wheelId)
  if idx then
    return wheels.wheels[idx] or wheels.wheels[idx - 1]
  end
  for _, wheel in pairs(wheels.wheels) do
    if wheel and wheel.name then
      if wheel.name == wheelId or string.find(wheel.name, wheelId, 1, true) then
        return wheel
      end
    end
  end
  return nil
end

local function resolveKinematics(signalName)
  local pos = safeObjCall("getPosition")
  local vel = safeObjCall("getVelocity")
  local fwd, up, right = getDirectionVectors()

  if signalName == names.vehiclePositionX then return pos and pos.x end
  if signalName == names.vehiclePositionY then return pos and pos.y end
  if signalName == names.vehiclePositionZ then return pos and pos.z end
  if signalName == names.vehicleVelocityX then return vel and vel.x end
  if signalName == names.vehicleVelocityY then return vel and vel.y end
  if signalName == names.vehicleVelocityZ then return vel and vel.z end

  if signalName == names.vehicleAccelerationX then return sensors and sensors.gx end
  if signalName == names.vehicleAccelerationY then return sensors and sensors.gy end
  if signalName == names.vehicleAccelerationZ then return sensors and sensors.gz end

  if signalName == names.vehicleRoll then
    if not up or not right then return nil end
    return atan2(right.z, up.z)
  end
  if signalName == names.vehiclePitch then
    if not fwd then return nil end
    return asin(-fwd.z)
  end
  if signalName == names.vehicleYaw then
    if not fwd then return nil end
    return atan2(fwd.x, fwd.y)
  end

  if signalName == names.vehicleRollRate or signalName == names.vehiclePitchRate or signalName == names.vehicleYawRate then
    local av = safeObjCall("getAngularVelocity")
    if av and type(av) ~= 'number' then
      if signalName == names.vehicleRollRate then return av.x end
      if signalName == names.vehiclePitchRate then return av.y end
      if signalName == names.vehicleYawRate then return av.z end
    end
    return nil
  end

  if signalName == names.vehicleGroundSpeed then
    return (electrics and electrics.values and electrics.values.groundspeed) or (vel and vel:length())
  end
  if signalName == names.vehicleAltitude then
    return (electrics and electrics.values and electrics.values.altitude) or (pos and pos.z)
  end
  if signalName == names.vehicleForwardX then return fwd and fwd.x end
  if signalName == names.vehicleForwardY then return fwd and fwd.y end
  if signalName == names.vehicleForwardZ then return fwd and fwd.z end
  if signalName == names.vehicleUpX then return up and up.x end
  if signalName == names.vehicleUpY then return up and up.y end
  if signalName == names.vehicleUpZ then return up and up.z end
  if signalName == names.vehicleRightX then return right and right.x end
  if signalName == names.vehicleRightY then return right and right.y end
  if signalName == names.vehicleRightZ then return right and right.z end

  -- Static kinematics from editor cData
  local function fromStatic(key, alt)
    return staticKinematicsData[signalName] or (key and staticKinematicsData[key]) or (alt and staticKinematicsData[alt])
  end
  if signalName == names.vehicleInitialLength then return fromStatic('length', 'vehicleInitialLength') end
  if signalName == names.vehicleInitialWidth then return fromStatic('width', 'vehicleInitialWidth') end
  if signalName == names.vehicleInitialHeight then return fromStatic('height', 'vehicleInitialHeight') end
  if signalName == names.vehicleCOGWithWheelsX then return fromStatic('cogWithWheelsX', 'vehicleCOGWithWheelsX') end
  if signalName == names.vehicleCOGWithWheelsY then return fromStatic('cogWithWheelsY', 'vehicleCOGWithWheelsY') end
  if signalName == names.vehicleCOGWithWheelsZ then return fromStatic('cogWithWheelsZ', 'vehicleCOGWithWheelsZ') end
  if signalName == names.vehicleCOGWithoutWheelsX then return fromStatic('cogWithoutWheelsX', 'vehicleCOGWithoutWheelsX') end
  if signalName == names.vehicleCOGWithoutWheelsY then return fromStatic('cogWithoutWheelsY', 'vehicleCOGWithoutWheelsY') end
  if signalName == names.vehicleCOGWithoutWheelsZ then return fromStatic('cogWithoutWheelsZ', 'vehicleCOGWithoutWheelsZ') end
  if signalName == names.vehicleMidFrontBumperX then return fromStatic('midFrontBumperX', 'vehicleMidFrontBumperX') end
  if signalName == names.vehicleMidFrontBumperY then return fromStatic('midFrontBumperY', 'vehicleMidFrontBumperY') end
  if signalName == names.vehicleMidFrontBumperZ then return fromStatic('midFrontBumperZ', 'vehicleMidFrontBumperZ') end
  if signalName == names.vehicleMidRearBumperX then return fromStatic('midRearBumperX', 'vehicleMidRearBumperX') end
  if signalName == names.vehicleMidRearBumperY then return fromStatic('midRearBumperY', 'vehicleMidRearBumperY') end
  if signalName == names.vehicleMidRearBumperZ then return fromStatic('midRearBumperZ', 'vehicleMidRearBumperZ') end
  if signalName == names.vehicleFrontAxleMidpointX then return fromStatic('frontAxleMidpointX', 'vehicleFrontAxleMidpointX') end
  if signalName == names.vehicleFrontAxleMidpointY then return fromStatic('frontAxleMidpointY', 'vehicleFrontAxleMidpointY') end
  if signalName == names.vehicleFrontAxleMidpointZ then return fromStatic('frontAxleMidpointZ', 'vehicleFrontAxleMidpointZ') end
  if signalName == names.vehicleRearAxleMidpointX then return fromStatic('rearAxleMidpointX', 'vehicleRearAxleMidpointX') end
  if signalName == names.vehicleRearAxleMidpointY then return fromStatic('rearAxleMidpointY', 'vehicleRearAxleMidpointY') end
  if signalName == names.vehicleRearAxleMidpointZ then return fromStatic('rearAxleMidpointZ', 'vehicleRearAxleMidpointZ') end
  return nil
end

local function resolveWheel(signalName)
  local function matchPrefix(prefix)
    if string.sub(signalName, 1, #prefix) == prefix then
      return string.sub(signalName, #prefix + 1)
    end
    return nil
  end

  local wheelId = matchPrefix(names.wheelSpeed)
  if wheelId then
    local wheel = getWheelById(wheelId)
    return wheel and wheel.wheelSpeed
  end
  wheelId = matchPrefix(names.angularVelocity)
  if wheelId then
    local wheel = getWheelById(wheelId)
    return wheel and wheel.angularVelocity
  end
  wheelId = matchPrefix(names.downforce)
  if wheelId then
    local wheel = getWheelById(wheelId)
    return wheel and (wheel.downForce or wheel.downforce)
  end
  wheelId = matchPrefix(names.wheelAngle)
  if wheelId then
    local wheel = getWheelById(wheelId)
    return wheel and wheel.wheelAngle
  end

  wheelId = matchPrefix(names.brakingTorque)
  if wheelId then
    local wheel = getWheelById(wheelId)
    if wheel and wheel.coreData and wheel.coreData.brakeTorqueApplied ~= nil then
      return math.max(0, math.abs(wheel.coreData.brakeTorqueApplied) - (wheel.frictionTorque or 0))
    end
    return nil
  end
  wheelId = matchPrefix(names.propulsionTorque)
  if wheelId then
    local wheel = getWheelById(wheelId)
    return wheel and wheel.propulsionTorque
  end
  wheelId = matchPrefix(names.frictionTorque)
  if wheelId then
    local wheel = getWheelById(wheelId)
    return wheel and wheel.frictionTorque
  end
  return nil
end

local function resolveDriver(signalName)
  if signalName == names.throttleInput or signalName == names.throttle then return (input and input.throttle) end
  if signalName == names.brakeInput or signalName == names.brake then return (input and input.brake) end
  if signalName == names.clutchInput or signalName == names.clutch then return (input and input.clutch) end
  if signalName == names.parkingBrakeInput or signalName == names.parkingBrake then return (input and input.parkingbrake) end
  if signalName == names.steeringWheelPositionInput or signalName == names.steeringWheelPosition then return (input and input.steering) end
  return nil
end

local function resolveElectrics(signalName)
  if electrics and electrics.values then
    return electrics.values[signalName]
  end
  return nil
end

local function resolvePowertrain(signalName)
  if powertrain then
    local devices = powertrain.getDevices and powertrain.getDevices()
    if devices then
      for _, dev in pairs(devices) do
        if dev.name then
          local prefix = dev.name .. " "
          if string.sub(signalName, 1, #prefix) == prefix then
            local prop = string.sub(signalName, #prefix + 1)
            if dev[prop] ~= nil then
              return dev[prop]
            end
          end
        end
      end
    end
  end
  if electrics and electrics.values then
    return electrics.values[signalName]
  end
  return nil
end

local function resolveIMU(signal)
  local v = imuByName[signal.groupName]
  if not v then return nil end
  if not v.ctrl then
    v.ctrl = tryGetController('advancedIMU', v.id)
    if not v.ctrl or not v.ctrl.getLatest then return nil end
  end
  local d = v.ctrl.getLatest()
  if type(d) ~= 'table' then return nil end
  local n = signal.name
  local pos, dirX, dirY, dirZ = d.pos, d.dirX, d.dirY, d.dirZ
  local angVel, angVelSm = d.angVel, d.angVelSmooth
  local accRaw, accSmooth, angAccel = d.accRaw, d.accSmooth, d.angAccel
  if n == names.imuPositionX then return pos and pos[1] end
  if n == names.imuPositionY then return pos and pos[2] end
  if n == names.imuPositionZ then return pos and pos[3] end
  if n == names.imuAxis1DirectionX then return dirX and dirX[1] end
  if n == names.imuAxis1DirectionY then return dirX and dirX[2] end
  if n == names.imuAxis1DirectionZ then return dirX and dirX[3] end
  if n == names.imuAxis2DirectionX then return dirY and dirY[1] end
  if n == names.imuAxis2DirectionY then return dirY and dirY[2] end
  if n == names.imuAxis2DirectionZ then return dirY and dirY[3] end
  if n == names.imuAxis3DirectionX then return dirZ and dirZ[1] end
  if n == names.imuAxis3DirectionY then return dirZ and dirZ[2] end
  if n == names.imuAxis3DirectionZ then return dirZ and dirZ[3] end
  if n == names.imuMass then return d.mass end
  if n == names.imuAngularVelocityRawAxis1 then return angVel and angVel[1] end
  if n == names.imuAngularVelocityRawAxis2 then return angVel and angVel[2] end
  if n == names.imuAngularVelocityRawAxis3 then return angVel and angVel[3] end
  if n == names.imuAngularVelocitySmoothedAxis1 then return angVelSm and angVelSm[1] end
  if n == names.imuAngularVelocitySmoothedAxis2 then return angVelSm and angVelSm[2] end
  if n == names.imuAngularVelocitySmoothedAxis3 then return angVelSm and angVelSm[3] end
  if n == names.imuAccelerationRawAxis1 then return accRaw and accRaw[1] end
  if n == names.imuAccelerationRawAxis2 then return accRaw and accRaw[2] end
  if n == names.imuAccelerationRawAxis3 then return accRaw and accRaw[3] end
  if n == names.imuAccelerationSmoothedAxis1 then return accSmooth and accSmooth[1] end
  if n == names.imuAccelerationSmoothedAxis2 then return accSmooth and accSmooth[2] end
  if n == names.imuAccelerationSmoothedAxis3 then return accSmooth and accSmooth[3] end
  if n == names.imuAngularAccelerationAxis1 then return angAccel and angAccel[1] end
  if n == names.imuAngularAccelerationAxis2 then return angAccel and angAccel[2] end
  if n == names.imuAngularAccelerationAxis3 then return angAccel and angAccel[3] end
  if n == names.imuReadingTimestamp then return d.time end
  return nil
end

local function resolveGPS(signal)
  local v = gpsByName[signal.groupName]
  if not v then return nil end
  if not v.ctrl then
    v.ctrl = tryGetController('GPS', v.id)
    if not v.ctrl or not v.ctrl.getLatest then return nil end
  end
  local d = v.ctrl.getLatest()
  if type(d) ~= 'table' then return nil end
  local n = signal.name
  if n == names.gpsXCoordinate then return d.x end
  if n == names.gpsYCoordinate then return d.y end
  if n == names.gpsLongitude then return d.lon end
  if n == names.gpsLatitude then return d.lat end
  if n == names.gpsReadingTimestamp then return d.time end
  return nil
end

-- Returns the named per-vehicle subtable from an idealRADAR getLatest() reading (closestVehicles1..4).
local function radarVehicle(d, idx)
  if idx == 1 then return d.closestVehicles1 end
  if idx == 2 then return d.closestVehicles2 end
  if idx == 3 then return d.closestVehicles3 end
  if idx == 4 then return d.closestVehicles4 end
  return nil
end

local idealRadarVehicleSignalIdx = {
  [names.idealRADARVehicle1Distance] = 1, [names.idealRADARVehicle1Length] = 1, [names.idealRADARVehicle1Width] = 1,
  [names.idealRADARVehicle1VelocityX] = 1, [names.idealRADARVehicle1VelocityY] = 1, [names.idealRADARVehicle1VelocityZ] = 1,
  [names.idealRADARVehicle1AccelerationX] = 1, [names.idealRADARVehicle1AccelerationY] = 1, [names.idealRADARVehicle1AccelerationZ] = 1,
  [names.idealRADARVehicle1RelativeDistanceX] = 1, [names.idealRADARVehicle1RelativeDistanceY] = 1,
  [names.idealRADARVehicle1RelativeVelocityX] = 1, [names.idealRADARVehicle1RelativeVelocityY] = 1,
  [names.idealRADARVehicle1RelativeAccelerationX] = 1, [names.idealRADARVehicle1RelativeAccelerationY] = 1,
  [names.idealRADARVehicle2Distance] = 2, [names.idealRADARVehicle2Length] = 2, [names.idealRADARVehicle2Width] = 2,
  [names.idealRADARVehicle2VelocityX] = 2, [names.idealRADARVehicle2VelocityY] = 2, [names.idealRADARVehicle2VelocityZ] = 2,
  [names.idealRADARVehicle2AccelerationX] = 2, [names.idealRADARVehicle2AccelerationY] = 2, [names.idealRADARVehicle2AccelerationZ] = 2,
  [names.idealRADARVehicle2RelativeDistanceX] = 2, [names.idealRADARVehicle2RelativeDistanceY] = 2,
  [names.idealRADARVehicle2RelativeVelocityX] = 2, [names.idealRADARVehicle2RelativeVelocityY] = 2,
  [names.idealRADARVehicle2RelativeAccelerationX] = 2, [names.idealRADARVehicle2RelativeAccelerationY] = 2,
  [names.idealRADARVehicle3Distance] = 3, [names.idealRADARVehicle3Length] = 3, [names.idealRADARVehicle3Width] = 3,
  [names.idealRADARVehicle3VelocityX] = 3, [names.idealRADARVehicle3VelocityY] = 3, [names.idealRADARVehicle3VelocityZ] = 3,
  [names.idealRADARVehicle3AccelerationX] = 3, [names.idealRADARVehicle3AccelerationY] = 3, [names.idealRADARVehicle3AccelerationZ] = 3,
  [names.idealRADARVehicle3RelativeDistanceX] = 3, [names.idealRADARVehicle3RelativeDistanceY] = 3,
  [names.idealRADARVehicle3RelativeVelocityX] = 3, [names.idealRADARVehicle3RelativeVelocityY] = 3,
  [names.idealRADARVehicle3RelativeAccelerationX] = 3, [names.idealRADARVehicle3RelativeAccelerationY] = 3,
  [names.idealRADARVehicle4Distance] = 4, [names.idealRADARVehicle4Length] = 4, [names.idealRADARVehicle4Width] = 4,
  [names.idealRADARVehicle4VelocityX] = 4, [names.idealRADARVehicle4VelocityY] = 4, [names.idealRADARVehicle4VelocityZ] = 4,
  [names.idealRADARVehicle4AccelerationX] = 4, [names.idealRADARVehicle4AccelerationY] = 4, [names.idealRADARVehicle4AccelerationZ] = 4,
  [names.idealRADARVehicle4RelativeDistanceX] = 4, [names.idealRADARVehicle4RelativeDistanceY] = 4,
  [names.idealRADARVehicle4RelativeVelocityX] = 4, [names.idealRADARVehicle4RelativeVelocityY] = 4,
  [names.idealRADARVehicle4RelativeAccelerationX] = 4, [names.idealRADARVehicle4RelativeAccelerationY] = 4,
}

local function resolveIdealRADAR(signal)
  local list = sensorMap.idealRADARs
  if not list or #list == 0 then return nil end
  local v = list[1]
  if not v.ctrl then
    v.ctrl = tryGetController('idealRADARSensor', v.id)
    if not v.ctrl or not v.ctrl.getLatest then return nil end
  end
  local d = v.ctrl.getLatest()
  if type(d) ~= 'table' then return nil end
  local n = signal.name
  if n == names.idealRADARReadingTimestamp then return d.time end
  local idx = idealRadarVehicleSignalIdx[n]
  if not idx then return nil end
  local rv = radarVehicle(d, idx)
  if type(rv) ~= 'table' then return nil end
  -- Per-vehicle scalar fields.
  if n == names.idealRADARVehicle1Distance or n == names.idealRADARVehicle2Distance
      or n == names.idealRADARVehicle3Distance or n == names.idealRADARVehicle4Distance then
    return rv.distToPlayerVehicleSq and sqrt(rv.distToPlayerVehicleSq)
  end
  if n == names.idealRADARVehicle1Length or n == names.idealRADARVehicle2Length
      or n == names.idealRADARVehicle3Length or n == names.idealRADARVehicle4Length then return rv.length end
  if n == names.idealRADARVehicle1Width or n == names.idealRADARVehicle2Width
      or n == names.idealRADARVehicle3Width or n == names.idealRADARVehicle4Width then return rv.width end
  -- Per-vehicle vector fields (vel, acc are vec3-like).
  local vel, acc = rv.vel, rv.acc
  if n == names.idealRADARVehicle1VelocityX or n == names.idealRADARVehicle2VelocityX
      or n == names.idealRADARVehicle3VelocityX or n == names.idealRADARVehicle4VelocityX then return vel and vel.x end
  if n == names.idealRADARVehicle1VelocityY or n == names.idealRADARVehicle2VelocityY
      or n == names.idealRADARVehicle3VelocityY or n == names.idealRADARVehicle4VelocityY then return vel and vel.y end
  if n == names.idealRADARVehicle1VelocityZ or n == names.idealRADARVehicle2VelocityZ
      or n == names.idealRADARVehicle3VelocityZ or n == names.idealRADARVehicle4VelocityZ then return vel and vel.z end
  if n == names.idealRADARVehicle1AccelerationX or n == names.idealRADARVehicle2AccelerationX
      or n == names.idealRADARVehicle3AccelerationX or n == names.idealRADARVehicle4AccelerationX then return acc and acc.x end
  if n == names.idealRADARVehicle1AccelerationY or n == names.idealRADARVehicle2AccelerationY
      or n == names.idealRADARVehicle3AccelerationY or n == names.idealRADARVehicle4AccelerationY then return acc and acc.y end
  if n == names.idealRADARVehicle1AccelerationZ or n == names.idealRADARVehicle2AccelerationZ
      or n == names.idealRADARVehicle3AccelerationZ or n == names.idealRADARVehicle4AccelerationZ then return acc and acc.z end
  -- Per-vehicle relative scalar fields.
  if n == names.idealRADARVehicle1RelativeDistanceX or n == names.idealRADARVehicle2RelativeDistanceX
      or n == names.idealRADARVehicle3RelativeDistanceX or n == names.idealRADARVehicle4RelativeDistanceX then return rv.relDistX end
  if n == names.idealRADARVehicle1RelativeDistanceY or n == names.idealRADARVehicle2RelativeDistanceY
      or n == names.idealRADARVehicle3RelativeDistanceY or n == names.idealRADARVehicle4RelativeDistanceY then return rv.relDistY end
  if n == names.idealRADARVehicle1RelativeVelocityX or n == names.idealRADARVehicle2RelativeVelocityX
      or n == names.idealRADARVehicle3RelativeVelocityX or n == names.idealRADARVehicle4RelativeVelocityX then return rv.relVelX end
  if n == names.idealRADARVehicle1RelativeVelocityY or n == names.idealRADARVehicle2RelativeVelocityY
      or n == names.idealRADARVehicle3RelativeVelocityY or n == names.idealRADARVehicle4RelativeVelocityY then return rv.relVelY end
  if n == names.idealRADARVehicle1RelativeAccelerationX or n == names.idealRADARVehicle2RelativeAccelerationX
      or n == names.idealRADARVehicle3RelativeAccelerationX or n == names.idealRADARVehicle4RelativeAccelerationX then return rv.relAccX end
  if n == names.idealRADARVehicle1RelativeAccelerationY or n == names.idealRADARVehicle2RelativeAccelerationY
      or n == names.idealRADARVehicle3RelativeAccelerationY or n == names.idealRADARVehicle4RelativeAccelerationY then return rv.relAccY end
  return nil
end

local function resolveRoads(signal)
  local list = sensorMap.roads
  if not list or #list == 0 then return nil end
  local v = list[1]
  if not v.ctrl then
    v.ctrl = tryGetController('roadsSensor', v.id)
    if not v.ctrl or not v.ctrl.getLatest then return nil end
  end
  local d = v.ctrl.getLatest()
  if type(d) ~= 'table' then return nil end
  local n = signal.name
  if n == names.roadsRoadHalfWidth then return d.halfWidth end
  if n == names.roadsRoadRadius then return d.roadRadius end
  if n == names.roadsRoadHeading then return d.headingAngle end
  if n == names.roadsDistanceToCenterline then return d.dist2CL end
  if n == names.roadsDistanceToRoadLeftEdge then return d.dist2Left end
  if n == names.roadsDistanceToRoadRightEdge then return d.dist2Right end
  if n == names.roadsDrivability then return d.drivability end
  if n == names.roadsSpeedLimit then return d.speedLimit end
  if n == names.roadsIsOneWay then return d.flag1way end
  if n == names.roadsClosestPointX then return d.xP0onCL end
  if n == names.roadsClosestPointY then return d.yP0onCL end
  if n == names.roadsClosestPointZ then return d.zP0onCL end
  if n == names.roads2ndClosestPointX then return d.xP1onCL end
  if n == names.roads2ndClosestPointY then return d.yP1onCL end
  if n == names.roads2ndClosestPointZ then return d.zP1onCL end
  if n == names.roads3rdClosestPointX then return d.xP2onCL end
  if n == names.roads3rdClosestPointY then return d.yP2onCL end
  if n == names.roads3rdClosestPointZ then return d.zP2onCL end
  if n == names.roads4thClosestPointX then return d.xP3onCL end
  if n == names.roads4thClosestPointY then return d.yP3onCL end
  if n == names.roads4thClosestPointZ then return d.zP3onCL end
  if n == names.roadsReadingTimestamp then return d.time end
  return nil
end

function M.resolve(signal)
  local g = signal.groupName
  if g == groups.kinematics then
    return resolveKinematics(signal.name)
  end
  if g == groups.wheels then
    return resolveWheel(signal.name)
  end
  if g == groups.electrics then
    return resolveElectrics(signal.name)
  end
  if g == groups.powertrain then
    return resolvePowertrain(signal.name)
  end
  if g == groups.driver then
    return resolveDriver(signal.name)
  end
  if g == groups.idealRADAR then
    return resolveIdealRADAR(signal)
  end
  if g == groups.roadsSensor then
    return resolveRoads(signal)
  end
  -- IMU/GPS use per-instance sensor display names as the group key.
  if imuByName[g] then
    return resolveIMU(signal)
  end
  if gpsByName[g] then
    return resolveGPS(signal)
  end
  return nil
end

function M.setStaticKinematicsData(data)
  staticKinematicsData = (data and type(data) == 'table') and data or {}
end

function M.setSensorMap(map)
  if type(map) == 'table' then
    sensorMap = {
      IMUs = map.IMUs or {},
      GPSs = map.GPSs or {},
      idealRADARs = map.idealRADARs or {},
      roads = map.roads or {}
    }
  else
    sensorMap = { IMUs = {}, GPSs = {}, idealRADARs = {}, roads = {} }
  end
  bindSensorControllers()
end

-- Exact catalog name -> group for BeamNGpy / name-only VSL lists (see signalsFromSignalNames).
local staticNameToGroup = {}
do
  local function reg(nameStr, group)
    if nameStr and nameStr ~= '' then
      staticNameToGroup[nameStr] = group
    end
  end
  local k = {
    'vehiclePositionX', 'vehiclePositionY', 'vehiclePositionZ',
    'vehicleVelocityX', 'vehicleVelocityY', 'vehicleVelocityZ',
    'vehicleAccelerationX', 'vehicleAccelerationY', 'vehicleAccelerationZ',
    'vehicleRoll', 'vehiclePitch', 'vehicleYaw',
    'vehicleRollRate', 'vehiclePitchRate', 'vehicleYawRate',
    'vehicleGroundSpeed', 'vehicleAltitude',
    'vehicleForwardX', 'vehicleForwardY', 'vehicleForwardZ',
    'vehicleUpX', 'vehicleUpY', 'vehicleUpZ',
    'vehicleRightX', 'vehicleRightY', 'vehicleRightZ',
    'vehicleInitialLength', 'vehicleInitialWidth', 'vehicleInitialHeight',
    'vehicleCOGWithWheelsX', 'vehicleCOGWithWheelsY', 'vehicleCOGWithWheelsZ',
    'vehicleCOGWithoutWheelsX', 'vehicleCOGWithoutWheelsY', 'vehicleCOGWithoutWheelsZ',
    'vehicleMidFrontBumperX', 'vehicleMidFrontBumperY', 'vehicleMidFrontBumperZ',
    'vehicleMidRearBumperX', 'vehicleMidRearBumperY', 'vehicleMidRearBumperZ',
    'vehicleFrontAxleMidpointX', 'vehicleFrontAxleMidpointY', 'vehicleFrontAxleMidpointZ',
    'vehicleRearAxleMidpointX', 'vehicleRearAxleMidpointY', 'vehicleRearAxleMidpointZ',
  }
  for i = 1, #k do
    reg(names[k[i]], groups.kinematics)
  end
  local d = {
    'throttle', 'throttleInput', 'brake', 'brakeInput', 'clutch', 'clutchInput',
    'parkingBrake', 'parkingBrakeInput', 'steeringWheelPosition', 'steeringWheelPositionInput',
    -- gearIndex: resolved via electrics.values at runtime, not resolveDriver
  }
  for i = 1, #d do
    reg(names[d[i]], groups.driver)
  end
end

local function wheelPrefixGroup(signalName)
  local prefixes = {
    names.wheelSpeed,
    names.angularVelocity,
    names.downforce,
    names.wheelAngle,
    names.brakingTorque,
    names.propulsionTorque,
    names.frictionTorque,
  }
  for i = 1, #prefixes do
    local p = prefixes[i]
    if string.sub(signalName, 1, #p) == p and #signalName > #p then
      return groups.wheels
    end
  end
  return nil
end

local function electricsRuntimeGroup(signalName)
  if electrics and electrics.values and electrics.values[signalName] ~= nil then
    return groups.electrics
  end
  return nil
end

local function powertrainRuntimeGroup(signalName)
  if not powertrain or not powertrain.getDevices then
    return nil
  end
  local devices = powertrain.getDevices()
  if not devices then
    return nil
  end
  for _, dev in pairs(devices) do
    if dev.name then
      local prefix = dev.name .. ' '
      if string.sub(signalName, 1, #prefix) == prefix then
        local prop = string.sub(signalName, #prefix + 1)
        if dev[prop] ~= nil then
          return groups.powertrain
        end
      end
    end
  end
  return nil
end

function M.groupForSignalName(signalName)
  if type(signalName) ~= 'string' or signalName == '' then
    return nil
  end
  local g = staticNameToGroup[signalName]
  if g then
    return g
  end
  g = wheelPrefixGroup(signalName)
  if g then
    return g
  end
  g = electricsRuntimeGroup(signalName)
  if g then
    return g
  end
  return powertrainRuntimeGroup(signalName)
end

function M.signalsFromSignalNames(signalNames)
  if type(signalNames) ~= 'table' or #signalNames == 0 then
    return nil, 'signalNames must be a non-empty array of strings'
  end
  local out = {}
  for i = 1, #signalNames do
    local n = signalNames[i]
    if type(n) ~= 'string' or n == '' then
      return nil, 'signalNames[' .. tostring(i) .. '] must be a non-empty string'
    end
    local g = M.groupForSignalName(n)
    if not g then
      return nil, 'Unknown signal name (cannot infer group): "' .. n .. '". Use full {name, groupName} for this channel.'
    end
    out[#out + 1] = {
      name = n,
      groupName = g,
      type = 'Float',
      description = '',
    }
  end
  return out
end

return M
