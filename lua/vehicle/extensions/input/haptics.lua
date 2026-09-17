-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min, max, abs, sqrt, clockhp = math.min, math.max, math.abs, math.sqrt, os.clockhp
local M = {}

local FFBID    = -1
local FFBID_accelerate = -1
local FFBID_brake = -1

local FFBperiod = 1 / 30
local nextDriverUpdate = 0

-- Jerk tracking variables
local totalAcceleration = vec3(0,0,0)
local prevTotalAccel = vec3(0,0,0)
local poweredWheelIndices = {}
local numberOfPoweredWheels = 0
local wheelCount = 0

local timeSinceLastVibrationUpdate = 0

local wheelSlipForceMult = 1
local jerkForceMult = 1
local wheelSlipMin = 15000
local jerkMinX = 50 -- sideways jerk
local jerkMinY = 20 -- forward jerk
local jerkMinZ = 15 -- vertical jerk

local smoothVelocity = vec3()

local function setFFBIDs(_FFBID, _FFBID_accelerate, _FFBID_brake)
  FFBID = _FFBID
  FFBID_accelerate = _FFBID_accelerate
  FFBID_brake = _FFBID_brake
end

local function setFFBPeriod(period)
  FFBperiod = period
  nextDriverUpdate = clockhp() + FFBperiod
end

local function setFFBSpeedFast(speed)
  ffbSpeedFast = speed
end

local function initHaptics()
  local poweredWheelNames = powertrain.getPoweredWheelNames()
  table.clear(poweredWheelIndices)
  for index, wheel in pairs(wheels.wheels) do
    if poweredWheelNames[wheel.name] then
      poweredWheelIndices[index] = true
    end
  end
  numberOfPoweredWheels = tableSize(poweredWheelIndices)
  wheelCount = wheels.wheelCount
end

local function vibrationUpdate(dt)
  local now = clockhp() -- important, this must be wall clock time, not sim time (gamepad drivers don't care about sim time)
  timeSinceLastVibrationUpdate = timeSinceLastVibrationUpdate + dt
  if now > nextDriverUpdate then
    local lateralAcceleration = sensors.gx2
    local longitudinalAcceleration = sensors.gy2
    local verticalAcceleration = sensors.gz2
    totalAcceleration:set(lateralAcceleration, longitudinalAcceleration, verticalAcceleration)

    -- Calculate jerk (rate of change of acceleration)
    local jerkForceX = abs(totalAcceleration.x - prevTotalAccel.x) / timeSinceLastVibrationUpdate
    local jerkForceY = abs(totalAcceleration.y - prevTotalAccel.y) / timeSinceLastVibrationUpdate
    local jerkForceZ = abs(totalAcceleration.z - prevTotalAccel.z) / timeSinceLastVibrationUpdate
    prevTotalAccel:set(totalAcceleration)
    if jerkForceX < jerkMinX then jerkForceX = 0 end
    if jerkForceY < jerkMinY then jerkForceY = 0 end
    if jerkForceZ < jerkMinZ then jerkForceZ = 0 end
    local jerkForce = sqrt(square(jerkForceX) + square(jerkForceY) + square(jerkForceZ))

    smoothVelocity:set(obj:getSmoothRefVelocityXYZ())

    -- Start the vibration at 0.2 of the ffbSpeedFast
    local normalizedSpeed = clamp(smoothVelocity:length() / hydros.ffbSpeedFast, 0, 1)
    local stoppedVehicleMultiplier = (normalizedSpeed - 0.2) / 0.8
    stoppedVehicleMultiplier = clamp(stoppedVehicleMultiplier, 0, 1)

    -- add abs trigger
    local absTrigger = 0
    if electrics.values.absActive == 1 and electrics.values.brake > 0 then
      absTrigger = 1
    else
      absTrigger = 0
    end

    local lockedWheels = 0
    local overSpinningWheelsAverageSlip = 0
    local wheelsWithBrake = 0

    local averageSlipEnergy = 0
    local highestSlipEnergy = 0
    local secondHighestSlipEnergy = 0
    for index = 0, wheelCount - 1 do
      local wheel = wheels.wheels[index]

      -- Track the two highest slip energy values
      if wheel.slipEnergy > highestSlipEnergy then
        secondHighestSlipEnergy = highestSlipEnergy
        highestSlipEnergy = wheel.slipEnergy
      elseif wheel.slipEnergy > secondHighestSlipEnergy then
        secondHighestSlipEnergy = wheel.slipEnergy
      end

      local slipRatio = min(max((electrics.values.airspeed - abs(wheel.angularVelocityBrakeCouple * wheel.radius * wheel.wheelDir)) / electrics.values.airspeed, 0), 1)
      local hasBrake = wheel.brakeTorque > 0
      local isPowered = poweredWheelIndices[index]

      -- check which wheels are locked up
      if hasBrake and electrics.values.absActive ~= 1 then
        wheelsWithBrake = wheelsWithBrake + 1
        if slipRatio >= 0.1 and hasBrake and electrics.values.brake > 0 then
          lockedWheels = lockedWheels + slipRatio
        end
      end

      -- check which wheels are over spinning
      if isPowered then
        if isPowered and electrics.values.throttle > 0 and wheel.lastSlip > 4 then
          overSpinningWheelsAverageSlip = overSpinningWheelsAverageSlip + wheel.lastSlip
        end
      end
    end

    -- calculate relative locked wheels amount and average overSpinning wheels slip
    local lockedWheelsRelative = wheelsWithBrake > 0 and lockedWheels / wheelsWithBrake or 0
    overSpinningWheelsAverageSlip = numberOfPoweredWheels > 0 and overSpinningWheelsAverageSlip / numberOfPoweredWheels or 0

    -- Calculate average of the two highest slip energy values
    averageSlipEnergy = (highestSlipEnergy + secondHighestSlipEnergy) / (wheelCount > 1 and 2 or 1)

    if averageSlipEnergy < wheelSlipMin then
      averageSlipEnergy = 0
    end

    -- set force from slip and jerk using multipliers
    local wheelSlipForce = averageSlipEnergy/600000 * wheelSlipForceMult
    wheelSlipForce = math.min(wheelSlipForce, 0.2)
    jerkForce = jerkForce / 325 * jerkForceMult

    -- calculate total controller vibration force
    local totalForce = math.min((jerkForce + wheelSlipForce) * hydros.wheelFFBForceCoef / 100, 1)
    if totalForce > 0 then
      totalForce = math.max(totalForce, 0.008) -- set any force to some minimum value so that the vibration motors definitely activate
    end

    -- add multipliers to the overSpinningWheelsAverageSlip and lockedWheelsRelative
    overSpinningWheelsAverageSlip = overSpinningWheelsAverageSlip/211
    lockedWheelsRelative = lockedWheelsRelative/7

    -- set the vibration values
    totalForce = totalForce * stoppedVehicleMultiplier -- force is normalized to 1
    local totalForceBrake = math.min(lockedWheelsRelative * stoppedVehicleMultiplier * hydros.wheelFFBForceCoef / 100, 1) * 20/2
    local totalForceAccelerate = math.min(overSpinningWheelsAverageSlip * hydros.wheelFFBForceCoef / 100, 1) * 23/2

    if FFBID ~= 1 then hydros.getForceFeedbackFunction()(obj, FFBID, totalForce * 10, 0, 0, 0) end-- the c++ api expects a value between 0 and 10
    if hydros.enableThrottleForceFeedback then
      if FFBID_accelerate ~= -1 then hydros.getForceFeedbackFunction()(obj, FFBID_accelerate, totalForceAccelerate, 0.24, 1, 1) end
    else
      if FFBID_accelerate ~= -1 then hydros.getForceFeedbackFunction()(obj, FFBID_accelerate, 0, 0, 0, 0) end
    end

    if hydros.enableBrakeForceFeedback then
      if FFBID_brake ~= -1 then hydros.getForceFeedbackFunction()(obj, FFBID_brake, totalForceBrake, 0.25, 1, 0) end
    else
      if FFBID_brake ~= -1 then hydros.getForceFeedbackFunction()(obj, FFBID_brake, 0, 0, 0, 0) end
    end
    nextDriverUpdate = now + FFBperiod
    timeSinceLastVibrationUpdate = 0
  end
end

-- vibration debug
local function setWheelSlipForceMultiplier(multiplier) wheelSlipForceMult = multiplier end
local function setJerkForceMultiplier(multiplier) jerkForceMult = multiplier end
local function setWheelSlipMin(min) wheelSlipMin = min end
local function setJerkMin(min) jerkMin = min end

M.setWheelSlipForceMultiplier = setWheelSlipForceMultiplier
M.setJerkForceMultiplier = setJerkForceMultiplier
M.setWheelSlipMin = setWheelSlipMin
M.setJerkMin = setJerkMin

M.vibrationUpdate = vibrationUpdate
M.setFFBIDs = setFFBIDs
M.setFFBPeriod = setFFBPeriod
M.initHaptics = initHaptics

return M
