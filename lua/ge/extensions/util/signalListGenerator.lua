-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local dat = require('tech/cosimulationNames')
local vSensors = require('editor/sensorConfigurationEditor')

local names, groups = dat.names, dat.groups

local function buildSignalList(options)
  local signals = {}
  local includeKinematics = options.includeKinematics
  local includeDriver = options.includeDriver
  local includeWheels = options.includeWheels
  local includeElectrics = options.includeElectrics
  local includePowertrain = options.includePowertrain
  local includeSensors = options.includeSensors
  local cData = options.cData or {}
  local sensors = options.sensors

  -----------------------
  -- Kinematics Group:
  -----------------------
  if includeKinematics then
    -- Vehicle position.
    signals[#signals + 1] = {
      name = names.vehiclePositionX, groupName = groups.kinematics, description = 'Vehicle position - Lateral - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = true }
    signals[#signals + 1] = {
      name = names.vehiclePositionY, groupName = groups.kinematics, description = 'Vehicle position - Longitudinal - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = true }
    signals[#signals + 1] = {
      name = names.vehiclePositionZ, groupName = groups.kinematics, description = 'Vehicle position - Vertical - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = true }

    -- Vehicle velocity.
    signals[#signals + 1] = {
      name = names.vehicleVelocityX, groupName = groups.kinematics, description = 'Vehicle velocity - Lateral - m/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = true }
    signals[#signals + 1] = {
      name = names.vehicleVelocityY, groupName = groups.kinematics, description = 'Vehicle velocity - Longitudinal - m/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = true }
    signals[#signals + 1] = {
      name = names.vehicleVelocityZ, groupName = groups.kinematics, description = 'Vehicle velocity - Vertical - m/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = true }

    -- Vehicle acceleration.
    signals[#signals + 1] = {
      name = names.vehicleAccelerationX, groupName = groups.kinematics, description = 'Vehicle acceleration - Lateral - ms^-2',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleAccelerationY, groupName = groups.kinematics, description = 'Vehicle acceleration - Longitudinal - ms^-2',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleAccelerationZ, groupName = groups.kinematics, description = 'Vehicle acceleration - Vertical - ms^-2',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle roll/pitch/yaw.
    signals[#signals + 1] = {
      name = names.vehicleRoll, groupName = groups.kinematics, description = 'Roll angle - rad',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehiclePitch, groupName = groups.kinematics, description = 'Pitch angle - rad',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleYaw, groupName = groups.kinematics, description = 'Yaw angle - rad',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle roll/pitch/yaw rate.
    signals[#signals + 1] = {
      name = names.vehicleRollRate, groupName = groups.kinematics, description = 'Roll rate - rad/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehiclePitchRate, groupName = groups.kinematics, description = 'Pitch rate - rad/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleYawRate, groupName = groups.kinematics, description = 'Yaw rate - rad/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Ground speed.
    signals[#signals + 1] = {
      name = names.vehicleGroundSpeed, groupName = groups.kinematics, description = 'Vehicle ground speed - m/s',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Altitude.
    signals[#signals + 1] = {
      name = names.vehicleAltitude, groupName = groups.kinematics, description = 'Vehicle altitude - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle local orthonormal frame.
    signals[#signals + 1] = {
      name = names.vehicleForwardX, groupName = groups.kinematics, description = 'Unit forward vector - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleForwardY, groupName = groups.kinematics, description = 'Unit forward vector - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleForwardZ, groupName = groups.kinematics, description = 'Unit forward vector - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleUpX, groupName = groups.kinematics, description = 'Unit up vector - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleUpY, groupName = groups.kinematics, description = 'Unit up vector - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleUpZ, groupName = groups.kinematics, description = 'Unit up vector - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleRightX, groupName = groups.kinematics, description = 'Unit right vector - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleRightY, groupName = groups.kinematics, description = 'Unit right vector - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleRightZ, groupName = groups.kinematics, description = 'Unit right vector - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle length/width/height (initial values).
    signals[#signals + 1] = {
      name = names.vehicleInitialLength, groupName = groups.kinematics, description = 'Initial vehicle length - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleInitialWidth, groupName = groups.kinematics, description = 'Initial vehicle width - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleInitialHeight, groupName = groups.kinematics, description = 'Initial vehicle height - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle Center-of-Gravity (COG) [with and without wheels included].
    signals[#signals + 1] = {
      name = names.vehicleCOGWithWheelsX, groupName = groups.kinematics, description = 'COG (inc. wheels) - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleCOGWithWheelsY, groupName = groups.kinematics, description = 'COG (inc. wheels) - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleCOGWithWheelsZ, groupName = groups.kinematics, description = 'COG (inc. wheels) - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleCOGWithoutWheelsX, groupName = groups.kinematics, description = 'COG (not inc. wheels) - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleCOGWithoutWheelsY, groupName = groups.kinematics, description = 'COG (not inc. wheels) - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleCOGWithoutWheelsZ, groupName = groups.kinematics, description = 'COG (not inc. wheels) - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle mid-front-bumper and mid-rear-bumper positions.
    signals[#signals + 1] = {
      name = names.vehicleMidFrontBumperX, groupName = groups.kinematics, description = 'Front bumper midpoint - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleMidFrontBumperY, groupName = groups.kinematics, description = 'Front bumper midpoint - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleMidFrontBumperZ, groupName = groups.kinematics, description = 'Front bumper midpoint - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleMidRearBumperX, groupName = groups.kinematics, description = 'Rear bumper midpoint - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleMidRearBumperY, groupName = groups.kinematics, description = 'Rear bumper midpoint - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleMidRearBumperZ, groupName = groups.kinematics, description = 'Rear bumper midpoint - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Vehicle front-axle-midpoint and rear-axle-midpoint positions.
    signals[#signals + 1] = {
      name = names.vehicleFrontAxleMidpointX, groupName = groups.kinematics, description = 'Front axle midpoint - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleFrontAxleMidpointY, groupName = groups.kinematics, description = 'Front axle midpoint - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleFrontAxleMidpointZ, groupName = groups.kinematics, description = 'Front axle midpoint - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleRearAxleMidpointX, groupName = groups.kinematics, description = 'Rear axle midpoint - Lat - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleRearAxleMidpointY, groupName = groups.kinematics, description = 'Rear axle midpoint - Long - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
    signals[#signals + 1] = {
      name = names.vehicleRearAxleMidpointZ, groupName = groups.kinematics, description = 'Rear axle midpoint - Vert - meters',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }
  end

  -----------------------
  -- Driver Control Group:
  -----------------------
  if includeDriver then
    -- Throttle pedal.
    signals[#signals + 1] = {
      name = names.throttle, groupName = groups.driver, description = 'Throttle pedal - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = true, readOnly = false, isIncluded = true }
    signals[#signals + 1] = {
      name = names.throttleInput, groupName = groups.driver, description = 'Throttle pedal input value - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Brake pedal.
    signals[#signals + 1] = {
      name = names.brake, groupName = groups.driver, description = 'Brake pedal - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = true, readOnly = false, isIncluded = true }
    signals[#signals + 1] = {
      name = names.brakeInput, groupName = groups.driver, description = 'Brake pedal input value - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Clutch pedal.
    signals[#signals + 1] = {
      name = names.clutch, groupName = groups.driver, description = 'Clutch pedal - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = true, readOnly = false, isIncluded = true }
    signals[#signals + 1] = {
      name = names.clutchInput, groupName = groups.driver, description = 'Clutch pedal input value - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Parking brake.
    signals[#signals + 1] = {
      name = names.parkingBrake, groupName = groups.driver, description = 'Parking brake - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = true, readOnly = false, isIncluded = true }
    signals[#signals + 1] = {
      name = names.parkingBrakeInput, groupName = groups.driver, description = 'Parking brake input value - range [0..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Steering wheel.
    signals[#signals + 1] = {
      name = names.steeringWheelPosition, groupName = groups.driver, description = 'Steering wheel position - range [-1..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = true, readOnly = false, isIncluded = true }
    signals[#signals + 1] = {
      name = names.steeringWheelPositionInput, groupName = groups.driver, description = 'Steering wheel input value - range [-1..1]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = false, readOnly = true, isIncluded = false }

    -- Gear (physical index: -1=R, 0=N, 1+=forward; for auto: mode index).
    signals[#signals + 1] = {
      name = names.gearIndex, groupName = groups.driver, description = 'Gear index - [-1=R, 0=N, 1+=forward]',
      type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
      isFrom = true, readOnly = false, isIncluded = true }
  end

  -----------------------
  -- Wheels Group:
  -----------------------
  if includeWheels then
    local wheelData = cData.wheels or {}
    local numWheels = #wheelData
    for i = 1, numWheels do
      local wId = tostring(wheelData[i])
      signals[#signals + 1] = {
        name = names.wheelSpeed .. wId, groupName = groups.wheels, description = wId .. ' - Wheel speed - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.angularVelocity .. wId, groupName = groups.wheels, description = wId .. ' - Angular velocity - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.downforce .. wId, groupName = groups.wheels, description = wId .. ' - Downforce - N-m',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.brakingTorque .. wId, groupName = groups.wheels, description = wId .. ' - Braking torque - N-m',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = false, isIncluded = true }
      signals[#signals + 1] = {
        name = names.propulsionTorque .. wId, groupName = groups.wheels, description = wId .. ' - Propulsion torque - N-m',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = false, isIncluded = true }
      signals[#signals + 1] = {
        name = names.frictionTorque .. wId, groupName = groups.wheels, description = wId .. ' - Friction torque - N-m',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = false, isIncluded = false }
      signals[#signals + 1] = {
        name = names.wheelAngle .. wId, groupName = groups.wheels, description = wId .. ' - Wheel angle - rad',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end
  end

  -----------------------
  -- Electrics Group:
  -----------------------
  if includeElectrics then
    local elecData = cData.electrics or {}
    local numElec = #elecData
    for i = 1, numElec do
      signals[#signals + 1] = {
        name = elecData[i].name, groupName = groups.electrics, description = elecData[i].name,
        type = elecData[i].type, isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end
  end

  -----------------------
  -- Powertrain Group:
  -----------------------
  if includePowertrain then
    local pTData = cData.powertrain or {}
    local numPT = #pTData
    for i = 1, numPT do
      signals[#signals + 1] = {
        name = pTData[i].name, groupName = groups.powertrain, description = pTData[i].name,
        type = pTData[i].type, isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end
  end

  -----------------------
  -- IMU Sensors Group(s):
  -----------------------
  if includeSensors and sensors then
    local numIMU, IMUids = vSensors.numberOfSensorType(sensors, 'IMU')
    for i = 1, numIMU do
      local sensor = sensors[IMUids[i]]
      local name = sensor.name
      signals[#signals + 1] = {
        name = names.imuPositionX, groupName = name, description = 'Position - Lateral - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuPositionY, groupName = name, description = 'Position - Longitudinal - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuPositionZ, groupName = name, description = 'Position - Vertical - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis1DirectionX, groupName = name, description = 'Axis 1 direction - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis1DirectionY, groupName = name, description = 'Axis 1 direction - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis1DirectionZ, groupName = name, description = 'Axis 1 direction - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis2DirectionX, groupName = name, description = 'Axis 2 direction - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis2DirectionY, groupName = name, description = 'Axis 2 direction - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis2DirectionZ, groupName = name, description = 'Axis 2 direction - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis3DirectionX, groupName = name, description = 'Axis 3 direction - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis3DirectionY, groupName = name, description = 'Axis 3 direction - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAxis3DirectionZ, groupName = name, description = 'Axis 3 direction - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuMass, groupName = name, description = 'Mass at sensor position - kg',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularVelocityRawAxis1, groupName = name, description = 'Angular velocity raw - Lat - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularVelocityRawAxis2, groupName = name, description = 'Angular velocity raw - Long - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularVelocityRawAxis3, groupName = name, description = 'Angular velocity raw - Vert - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularVelocitySmoothedAxis1, groupName = name, description = 'Angular velocity smoothed - Lat - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularVelocitySmoothedAxis2, groupName = name, description = 'Angular velocity smoothed - Long - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularVelocitySmoothedAxis3, groupName = name, description = 'Angular velocity smoothed - Vert - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAccelerationRawAxis1, groupName = name, description = 'Acceleration raw - Lat - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAccelerationRawAxis2, groupName = name, description = 'Acceleration raw - Long - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAccelerationRawAxis3, groupName = name, description = 'Acceleration raw - Vert - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAccelerationSmoothedAxis1, groupName = name, description = 'Acceleration smoothed - Lat - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAccelerationSmoothedAxis2, groupName = name, description = 'Acceleration smoothed - Long - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAccelerationSmoothedAxis3, groupName = name, description = 'Acceleration smoothed - Vert - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularAccelerationAxis1, groupName = name, description = 'Angular acceleration - Lat - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularAccelerationAxis2, groupName = name, description = 'Angular acceleration - Long - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuAngularAccelerationAxis3, groupName = name, description = 'Angular acceleration - Vert - rad/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.imuReadingTimestamp, groupName = name, description = 'IMU Reading timestamp - seconds',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end

    -----------------------
    -- GPS Sensors Group(s):
    -----------------------
    local numGPS, GPSids = vSensors.numberOfSensorType(sensors, 'GPS')
    for i = 1, numGPS do
      local sensor = sensors[GPSids[i]]
      local name = sensor.name
      signals[#signals + 1] = {
        name = names.gpsXCoordinate, groupName = name, description = 'Lateral Pos - world-space - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.gpsYCoordinate, groupName = name, description = 'Longitudinal Pos - world-space - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.gpsLongitude, groupName = name, description = 'Longitude - degrees',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.gpsLatitude, groupName = name, description = 'Latitude - degrees',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.gpsReadingTimestamp, groupName = name, description = 'GPS Reading timestamp - seconds',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end

    -----------------------
    -- Ideal Radar Group:
    -----------------------
    if vSensors.doesContainSensorType(sensors, 'idealRADAR') then
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1Distance, groupName = groups.idealRADAR, description = 'Vehicle #1 - distance to - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1Length, groupName = groups.idealRADAR, description = 'Vehicle #1 - length - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1Width, groupName = groups.idealRADAR, description = 'Vehicle #1 - width - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1VelocityX, groupName = groups.idealRADAR, description = 'Vehicle #1 - velocity - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1VelocityY, groupName = groups.idealRADAR, description = 'Vehicle #1 - velocity - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1VelocityZ, groupName = groups.idealRADAR, description = 'Vehicle #1 - velocity - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1AccelerationX, groupName = groups.idealRADAR, description = 'Vehicle #1 - acceleration - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1AccelerationY, groupName = groups.idealRADAR, description = 'Vehicle #1 - acceleration - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1AccelerationZ, groupName = groups.idealRADAR, description = 'Vehicle #1 - acceleration - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1RelativeDistanceX, groupName = groups.idealRADAR, description = 'Vehicle #1 - relative dist - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1RelativeDistanceY, groupName = groups.idealRADAR, description = 'Vehicle #1 - relative dist - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1RelativeVelocityX, groupName = groups.idealRADAR, description = 'Vehicle #1 - relative vel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1RelativeVelocityY, groupName = groups.idealRADAR, description = 'Vehicle #1 - relative vel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1RelativeAccelerationX, groupName = groups.idealRADAR, description = 'Vehicle #1 - relative accel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle1RelativeAccelerationY, groupName = groups.idealRADAR, description = 'Vehicle #1 - relative accel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }

      signals[#signals + 1] = {
        name = names.idealRADARVehicle2Distance, groupName = groups.idealRADAR, description = 'Vehicle #2 - distance to - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2Length, groupName = groups.idealRADAR, description = 'Vehicle #2 - length - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2Width, groupName = groups.idealRADAR, description = 'Vehicle #2 - width - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2VelocityX, groupName = groups.idealRADAR, description = 'Vehicle #2 - velocity - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2VelocityY, groupName = groups.idealRADAR, description = 'Vehicle #2 - velocity - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2VelocityZ, groupName = groups.idealRADAR, description = 'Vehicle #2 - velocity - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2AccelerationX, groupName = groups.idealRADAR, description = 'Vehicle #2 - acceleration - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2AccelerationY, groupName = groups.idealRADAR, description = 'Vehicle #2 - acceleration - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2AccelerationZ, groupName = groups.idealRADAR, description = 'Vehicle #2 - acceleration - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2RelativeDistanceX, groupName = groups.idealRADAR, description = 'Vehicle #2 - relative dist - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2RelativeDistanceY, groupName = groups.idealRADAR, description = 'Vehicle #2 - relative dist - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2RelativeVelocityX, groupName = groups.idealRADAR, description = 'Vehicle #2 - relative vel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2RelativeVelocityY, groupName = groups.idealRADAR, description = 'Vehicle #2 - relative vel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2RelativeAccelerationX, groupName = groups.idealRADAR,  description = 'Vehicle #2 - relative accel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle2RelativeAccelerationY, groupName = groups.idealRADAR,  description = 'Vehicle #2 - relative accel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }

      signals[#signals + 1] = {
        name = names.idealRADARVehicle3Distance, groupName = groups.idealRADAR, description = 'Vehicle #3 - distance to - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3Length, groupName = groups.idealRADAR, description = 'Vehicle #3 - length - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3Width, groupName = groups.idealRADAR, description = 'Vehicle #3 - width - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3VelocityX, groupName = groups.idealRADAR, description = 'Vehicle #3 - velocity - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3VelocityY, groupName = groups.idealRADAR, description = 'Vehicle #3 - velocity - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3VelocityZ, groupName = groups.idealRADAR, description = 'Vehicle #3 - velocity - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3AccelerationX, groupName = groups.idealRADAR, description = 'Vehicle #3 - acceleration - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3AccelerationY, groupName = groups.idealRADAR, description = 'Vehicle #3 - acceleration - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3AccelerationZ, groupName = groups.idealRADAR, description = 'Vehicle #3 - acceleration - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3RelativeDistanceX, groupName = groups.idealRADAR, description = 'Vehicle #3 - relative dist - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3RelativeDistanceY, groupName = groups.idealRADAR, description = 'Vehicle #3 - relative dist - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3RelativeVelocityX, groupName = groups.idealRADAR, description = 'Vehicle #3 - relative vel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3RelativeVelocityY, groupName = groups.idealRADAR, description = 'Vehicle #3 - relative vel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3RelativeAccelerationX, groupName = groups.idealRADAR,  description = 'Vehicle #3 - relative accel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle3RelativeAccelerationY, groupName = groups.idealRADAR,  description = 'Vehicle #3 - relative accel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }

      signals[#signals + 1] = {
        name = names.idealRADARVehicle4Distance, groupName = groups.idealRADAR, description = 'Vehicle #4 - distance to - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4Length, groupName = groups.idealRADAR, description = 'Vehicle #4 - length - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4Width, groupName = groups.idealRADAR, description = 'Vehicle #4 - width - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4VelocityX, groupName = groups.idealRADAR, description = 'Vehicle #4 - velocity - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4VelocityY, groupName = groups.idealRADAR, description = 'Vehicle #4 - velocity - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4VelocityZ, groupName = groups.idealRADAR, description = 'Vehicle #4 - velocity - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4AccelerationX, groupName = groups.idealRADAR, description = 'Vehicle #4 - acceleration - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4AccelerationY, groupName = groups.idealRADAR, description = 'Vehicle #4 - acceleration - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4AccelerationZ, groupName = groups.idealRADAR, description = 'Vehicle #4 - acceleration - Vert - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4RelativeDistanceX, groupName = groups.idealRADAR,
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false, description = 'Vehicle #4 - relative dist - Lat - m/s',
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4RelativeDistanceY, groupName = groups.idealRADAR,
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false, description = 'Vehicle #4 - relative dist - Long - m/s',
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4RelativeVelocityX, groupName = groups.idealRADAR, description = 'Vehicle #4 - relative vel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4RelativeVelocityY, groupName = groups.idealRADAR, description = 'Vehicle #4 - relative vel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4RelativeAccelerationX, groupName = groups.idealRADAR,  description = 'Vehicle #4 - relative accel - Lat - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.idealRADARVehicle4RelativeAccelerationY, groupName = groups.idealRADAR,  description = 'Vehicle #4 - relative accel - Long - m/s',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }

      signals[#signals + 1] = {
        name = names.idealRADARReadingTimestamp, groupName = groups.idealRADAR, description = 'Reading timestamp',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end

    -------------------------
    -- Roads Sensor Group:
    -------------------------
    if vSensors.doesContainSensorType(sensors, 'roads') then
      signals[#signals + 1] = {
        name = names.roadsRoadHalfWidth, groupName = groups.roadsSensor, description = 'Local road half-width - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsRoadRadius, groupName = groups.roadsSensor, description = 'Local road radius - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsRoadHeading, groupName = groups.roadsSensor, description = 'Local road heading - rad',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsDistanceToCenterline, groupName = groups.roadsSensor, description = 'Distance to road centerline - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsDistanceToRoadLeftEdge, groupName = groups.roadsSensor, description = 'Distance to road left edge - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsDistanceToRoadRightEdge, groupName = groups.roadsSensor, description = 'Distance to road right edge - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsDrivability, groupName = groups.roadsSensor, description = 'Road drivability score',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsSpeedLimit, groupName = groups.roadsSensor, description = 'Road speed limit',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsIsOneWay, groupName = groups.roadsSensor, description = 'Is one-way road',
        type = 'boolean', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsClosestPointX, groupName = groups.roadsSensor, description = 'Closest road point - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsClosestPointY, groupName = groups.roadsSensor, description = 'Closest road point - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsClosestPointZ, groupName = groups.roadsSensor, description = 'Closest road point - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads2ndClosestPointX, groupName = groups.roadsSensor, description = '2nd closest road point - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads2ndClosestPointY, groupName = groups.roadsSensor, description = '2nd closest road point - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads2ndClosestPointZ, groupName = groups.roadsSensor, description = '2nd closest road point - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads3rdClosestPointX, groupName = groups.roadsSensor, description = '3rd closest road point - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads3rdClosestPointY, groupName = groups.roadsSensor, description = '3rd closest road point - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads3rdClosestPointZ, groupName = groups.roadsSensor, description = '3rd closest road point - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads4thClosestPointX, groupName = groups.roadsSensor, description = '4th closest road point - Lat - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads4thClosestPointY, groupName = groups.roadsSensor, description = '4th closest road point - Long - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roads4thClosestPointZ, groupName = groups.roadsSensor, description = '4th closest road point - Vert - meters',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
      signals[#signals + 1] = {
        name = names.roadsReadingTimestamp, groupName = groups.roadsSensor, description = 'Reading timestamp - seconds',
        type = 'number', isMultiply = false, isAdd = false, isFreeze = false,
        isFrom = false, readOnly = true, isIncluded = false }
    end
  end

  return signals
end

M.buildSignalList = buildSignalList

return M
