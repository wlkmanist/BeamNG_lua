-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Virtual sensor estimating trustworthy vehicle speed and body slip for driving dynamics control

local M = {}
M.type = "auxiliary"
M.defaultOrder = 56

M.isActive = false

local sin = math.sin
local cos = math.cos
local tan = math.tan
local arctan = math.atan
local abs = math.abs
local atan2 = math.atan2
local sqrt = math.sqrt
local pi = math.pi
local twoPi = pi * 2
local halfPi = pi * 0.5
local max = math.max
local min = math.min
local floor = math.floor

M.reference = {
  bodySlipAngle = 0,
  speed = 0
}

M.virtual = {
  speed = 0, --actual final calculated speed
  integratedSpeed = 0, --integration based speed component
  avgWheelSpeed = 0, --avg speed of all wheels
  avgNonPropulsedWheelSpeed = 0, --avg wheelspeed of all non propulsed wheels
  wheelSpeed = 0, --final calculated wheelspeed
  imuAcceleration = 0, --smoothed acceleration used for wheel acceleration agreement
  recoveryWheelSpeed = 0, --wheel speed from wheels whose acceleration agrees with the IMU
  recoveryWheelCount = 0,
  bodySlipAngle = 0, --final BSA
  bodySlipAngleIntegrated = 0, --BSA based on integratings things (for higher speeds)
  bodySlipAngleLowSpeed = 0, --Estimated BSA based on yaw rate (low speeds)
  bodySlipAngleLowSpeedTrust = 1,
  lastBodySlipAngle = 0,
  bodySlipAngleRate = 0
  --roll = 0,
  --pitch = 0
  --forceYFrontAxle = 0
}

local resetCriteria = {
  isRollingProbability = 0, --rolling straight without turning, braking or putting power to the wheels
  isStoppedProbability = 0, --stopped, no power to the wheels, might be braking
  isDrivingStraightProbability = 0, --driving in a straight line, power or brakes possible
  isWheelAccelerationConsistentProbability = 0, --wheel speed acceleration agrees with the IMU acceleration
  isRollingProbabilitySmoother = newTemporalSmoothing(2),
  isStoppedProbabilitySmoother = newTemporalSmoothing(2),
  isDrivingStraightProbabilitySmoother = newTemporalSmoothing(2),
  isWheelAccelerationConsistentProbabilitySmoother = newTemporalSmoothing(2)
}

M.trustWorthiness = {
  pitch = 1,
  roll = 1,
  jerk = 1,
  bodySlipAngle = 1,
  wheelSpeed = 1,
  virtualSpeed = 1,
  recoverySpeed = 0,
  needsFullReset = false
}

local smoother = {
  wheelSpeedTrust = newTemporalSmoothing(100, 5),
  imuAcceleration = newTemporalSmoothingNonLinear(20, 20),
  isVirtualToRecoverySpeedOffsetTooHighSmoother = newTemporalSmoothing(5, 2)
}

local boolToNumber = {[true] = 1, [false] = 0}

local virtualSpeedLowBiasThreshold = 1.0

local wheelCount = 0
local lastWheelSpeeds = {}
local wheelAccelerationSmoothers = {}
local recoveryWheelSpeedCandidates = {}

local CMU = nil
local isDebugEnabled = false

local debugPacket = {sourceType = "virtualSensors"}

-- offset from reference node(where the accelerations are measured) to vehicle center of gravity
local offsetRefNodeFromCoG = vec3(0, 0, 0)

local refNodeCoGTransformationLastOmega = vec3(0, 0, 0)
local refNodeCoGTransformationOmega = vec3(0, 0, 0)
local refNodeCoGTransformationAlpha = vec3(0, 0, 0)
local refNodeCoGTransformationAccRefNode = vec3(0, 0, 0)
local refNodeCoGTransformationAccCoG = vec3(0, 0, 0)

-- position derived acceleration: CoG point carried by the live vehicle frame, differentiated twice at a fixed rate
local positionSampleTime = 1 / 250
local positionMaxAccelerationSquared = 200 * 200 --anything above ~20g is treated as a position discontinuity (teleport)
local positionSampleTimer = 0
local positionHasLastCoG = false
local positionHasLastVelocity = false
local positionLastSampleDt = 0
local positionCoGForward, positionCoGLeft, positionCoGUp = 0, 0, 0
local positionLastCoG = vec3(0, 0, 0)
local positionLastCoGVelocity = vec3(0, 0, 0)
local positionLastForward = vec3(0, 0, 0)
local positionLastLeft = vec3(0, 0, 0)
local positionLastYawIncrement = 0
local positionAccelerationX = 0
local positionAccelerationY = 0
local positionYawRate = 0

local function updateBodySlipAngle(sinBodySlipAngle, cosBodySlipAngle, accelerationX, accelerationY, yawRate, dt)
  local virtual = M.virtual
  local vehicleData = CMU.vehicleData
  local vehicleStats = vehicleData.vehicleStats
  local sensorHub = CMU.sensorHub
  local yawRateSmooth = sensorHub.yawAVSmooth

  local virtualSpeed = virtual.speed

  local invSpeed = 1 / guardZero(virtualSpeed)
  local lowSpeedCoef = linearScale(abs(virtualSpeed), 0.1, 1, 0, 1)

  virtual.lastBodySlipAngle = virtual.bodySlipAngle
  --(5.7) in original form from the paper WITH the gravity compensation for x and y
  --local deltaHighSpeedBSA = -(sinBodySlipAngle * (accelerationX + sinPitch * gravity * 0) * invSpeed) + (cosBodySlipAngle * (accelerationY - sinRoll * cosPitch * gravity * 0) * invSpeed) - yawRate
  --(5.7) but WITHOUT the gravity compensation for x and y since the acc readinngs are already compensated for gravity
  local deltaHighSpeedBSA = -(sinBodySlipAngle * accelerationX * invSpeed) + (cosBodySlipAngle * accelerationY * invSpeed) - yawRate
  virtual.bodySlipAngleIntegrated = virtual.bodySlipAngleIntegrated + deltaHighSpeedBSA * dt * lowSpeedCoef
  --print("virtualSensors bodySlipAngleTrace: bodySlipAngleUsed: " .. tostring(virtual.bodySlipAngle) .. ", bodySlipAngleIntegrated: " .. tostring(virtual.bodySlipAngleIntegrated) .. ", virtualSpeedUsed: " .. tostring(virtualSpeed) .. ", wheelSpeed: " .. tostring(virtual.wheelSpeed) .. ", recoveryWheelSpeed: " .. tostring(virtual.recoveryWheelSpeed) .. ", accelerationX: " .. tostring(accelerationX) .. ", accelerationY: " .. tostring(accelerationY) .. ", accelerationBodySlipAngleRate: " .. tostring(deltaHighSpeedBSA + yawRate) .. ", yawRate: " .. tostring(yawRate) .. ", bodySlipAngleRateResidual: " .. tostring(deltaHighSpeedBSA))

  -- if abs(virtual.bodySlipAngleIntegrated) > twoPi then
  --   virtual.bodySlipAngleIntegrated = virtual.bodySlipAngleIntegrated - sign(virtual.bodySlipAngleIntegrated) * twoPi
  -- end

  --flip the speed instead of growing the slip angle past 90deg, but only when the wheels confirm the reversal: the integrated slip angle drifts freely at low speed
  if abs(virtual.bodySlipAngleIntegrated) > halfPi and virtual.integratedSpeed * virtual.wheelSpeed < 0 and abs(virtual.wheelSpeed) > 1 then
    virtual.bodySlipAngleIntegrated = virtual.bodySlipAngleIntegrated - sign(virtual.bodySlipAngleIntegrated) * pi
    virtual.integratedSpeed = -virtual.integratedSpeed
  elseif abs(virtual.bodySlipAngleIntegrated) > pi then
    virtual.bodySlipAngleIntegrated = virtual.bodySlipAngleIntegrated - sign(virtual.bodySlipAngleIntegrated) * twoPi
  end

  ---low speed bsa---
  local vSTM = (vehicleData.wheelAccess.frontRight.wheelSpeed + vehicleData.wheelAccess.frontLeft.wheelSpeed) * 0.5
  local vX = vSTM / (cos(vehicleData.frontWheelAngle) + sin(vehicleData.frontWheelAngle) * vehicleData.frontWheelAngle) --(5.38)
  local vY = vX * tan(vehicleData.frontWheelAngle) - yawRateSmooth * vehicleStats.distanceCOGFrontAxle --(5.38)
  virtual.bodySlipAngleLowSpeed = vX ~= 0 and (arctan(vY / vX) * lowSpeedCoef) or 0 --(5.39)
  ------------------

  if virtual.bodySlipAngleIntegrated ~= virtual.bodySlipAngleIntegrated then
    virtual.bodySlipAngleIntegrated = 0
  end

  --we want to invalidate the low speed BSA when we are in an active spin
  --so if both the integrated (old) BSA is large and the yaw rate is high, we should distrust the low speed BSA
  local lowSpeedBsaYawDistrust = linearScale(abs(yawRateSmooth), 1.5, 3, 0, 1)
  local lowSpeedBsaIntegratedDistrust = linearScale(abs(virtual.bodySlipAngleIntegrated), 0.4, 0.8, 0, 1)
  local lowSpeedBsaSpeedTrust = linearScale(abs(vX), 0.5, 1.5, 0, 1)
  local lowSpeedBsaTrust = (1 - lowSpeedBsaYawDistrust * lowSpeedBsaIntegratedDistrust) * lowSpeedBsaSpeedTrust
  local trustedLowSpeedBsa = virtual.bodySlipAngleLowSpeed * lowSpeedBsaTrust + virtual.bodySlipAngleIntegrated * (1 - lowSpeedBsaTrust)
  virtual.bodySlipAngleLowSpeedTrust = lowSpeedBsaTrust
  virtual.bodySlipAngle = linearScale(abs(virtualSpeed), 4, 5, trustedLowSpeedBsa, virtual.bodySlipAngleIntegrated)

  local bodySlipAngleChange = virtual.lastBodySlipAngle - virtual.bodySlipAngle
  virtual.bodySlipAngleRate = abs(bodySlipAngleChange - pi * floor(bodySlipAngleChange / pi + 0.5)) / dt --a 180deg flip is not a change
end

local function updateIntegratedSpeed(sinBodySlipAngle, cosBodySlipAngle, accelerationX, accelerationY, dt)
  local virtual = M.virtual
  --(5.6) in original form from the paper WITH the gravity compensation for x and y
  --local dSpeed = (cosBodySlipAngle * (accelerationX + sinPitch * gravity * 0)) + (sinBodySlipAngle * (accelerationY - sinRoll * cosPitch * gravity * 0))
  --(5.6) but WITHOUT the gravity compensation for x and y since the acc readinngs are already compensated for gravity
  local dSpeed = (cosBodySlipAngle * accelerationX) + (sinBodySlipAngle * accelerationY)
  virtual.imuAcceleration = smoother.imuAcceleration:get(dSpeed, dt)
  virtual.integratedSpeed = virtual.integratedSpeed + dSpeed * dt
  --print("virtualSensors speedTrace: integratedSpeed: " .. tostring(virtual.integratedSpeed) .. ", integratedSpeedRate: " .. tostring(dSpeed) .. ", speedRateFromLongitudinalAcceleration: " .. tostring(cosBodySlipAngle * accelerationX) .. ", speedRateFromLateralAcceleration: " .. tostring(sinBodySlipAngle * accelerationY))
end

local function updateRecoveryWheelSpeed(dt)
  local virtual = M.virtual
  local wheelAccelerationAgreementThreshold = linearScale(abs(virtual.imuAcceleration), 0, 20, 1.5, 4)
  local recoveryWheelSpeedSpreadThreshold = 3
  local turningCircleSpeedRatios = CMU.vehicleData.turningCircleSpeedRatios
  local candidateCount = 0
  local baseWheelSpeed
  local baseWheelSpeedAbs

  table.clear(recoveryWheelSpeedCandidates)
  --print("Wheel acc agreement")
  --print("IMU acc: " .. tostring(virtual.imuAcceleration))

  for i = 0, wheelCount - 1 do
    local wd = wheels.wheels[i]
    local wheelSpeed = wd.wheelSpeed * (turningCircleSpeedRatios[wd.name] or 1)
    local lastSpeed = lastWheelSpeeds[i] or wheelSpeed
    local rawWheelAcceleration = (wheelSpeed - lastSpeed) / dt
    local wheelAccelerationSmoother = wheelAccelerationSmoothers[i]
    if not wheelAccelerationSmoother then
      wheelAccelerationSmoother = newTemporalSmoothingNonLinear(20, 20)
      wheelAccelerationSmoothers[i] = wheelAccelerationSmoother
    end
    local wheelAcceleration = wheelAccelerationSmoother:get(rawWheelAcceleration, dt)

    local wheelAccelerationDifference = abs(wheelAcceleration - virtual.imuAcceleration)

    lastWheelSpeeds[i] = wheelSpeed

    if wheelAccelerationDifference <= wheelAccelerationAgreementThreshold then
      local wheelSpeedAbs = abs(wheelSpeed)
      candidateCount = candidateCount + 1
      recoveryWheelSpeedCandidates[candidateCount] = wheelSpeed
      if not baseWheelSpeedAbs or wheelSpeedAbs < baseWheelSpeedAbs then
        baseWheelSpeed = wheelSpeed
        baseWheelSpeedAbs = wheelSpeedAbs
      end
    end
    --print(string.format("Wheel acc diff (%s): %.2f", wheelAccelerationDifference <= wheelAccelerationAgreementThreshold and "good" or "bad", wheelAccelerationDifference))
  end

  local recoveryWheelSpeed = 0
  local recoveryWheelCount = 0
  if baseWheelSpeed then
    for i = 1, candidateCount do
      local wheelSpeed = recoveryWheelSpeedCandidates[i]
      if abs(abs(wheelSpeed) - baseWheelSpeedAbs) <= recoveryWheelSpeedSpreadThreshold then
        recoveryWheelSpeed = recoveryWheelSpeed + wheelSpeed
        recoveryWheelCount = recoveryWheelCount + 1
      end
    end
  end

  virtual.recoveryWheelCount = recoveryWheelCount
  virtual.recoveryWheelSpeed = recoveryWheelCount > 0 and recoveryWheelSpeed / recoveryWheelCount or virtual.recoveryWheelSpeed -- default to last value if no wheels are available
end

local function updateWheelSpeed(dt)
  local trustWorthiness = M.trustWorthiness
  local avgWheelSpeed = 0
  local avgNonPropulsedWheelSpeed = 0
  local nonPropulsedWheelCount = 0
  local brakingTrustWorthiness = 1
  local brakingTrustWorthinessNonPropulsed = 1
  local propulsionTrustWorthiness = 1

  for i = 0, wheelCount - 1 do
    local wd = wheels.wheels[i]
    avgWheelSpeed = avgWheelSpeed + wd.wheelSpeed
    local brakeTorqueTrustCoef = abs((abs(wd.coreData.brakeTorqueApplied) - wd.frictionTorque) * 0.01)
    if not wd.isPropulsed then
      nonPropulsedWheelCount = nonPropulsedWheelCount + 1
      avgNonPropulsedWheelSpeed = avgNonPropulsedWheelSpeed + wd.wheelSpeed
      brakingTrustWorthinessNonPropulsed = max(brakingTrustWorthinessNonPropulsed - brakeTorqueTrustCoef, 0)
    end
    local wheelPropulsionDevice = powertrain.getPropulsionDeviceForWheel(wd.name)
    local propulsionTorque = wheelPropulsionDevice and wheelPropulsionDevice.outputTorque1 or 0
    propulsionTrustWorthiness = max(propulsionTrustWorthiness - max(propulsionTorque * 0.005, 0), 0)
    brakingTrustWorthiness = max(brakingTrustWorthiness - brakeTorqueTrustCoef, 0)
  end

  if nonPropulsedWheelCount > 0 then
    M.virtual.wheelSpeed = avgNonPropulsedWheelSpeed / nonPropulsedWheelCount
    trustWorthiness.wheelSpeed = smoother.wheelSpeedTrust:getUncapped(brakingTrustWorthinessNonPropulsed, dt)
  else
    M.virtual.wheelSpeed = avgWheelSpeed / wheels.wheelCount
    trustWorthiness.wheelSpeed = smoother.wheelSpeedTrust:getUncapped(min(brakingTrustWorthiness, propulsionTrustWorthiness), dt)
  end

  updateRecoveryWheelSpeed(dt)
end

local function updateTrustWorthiness(dt)
  local trustWorthiness = M.trustWorthiness
  local sensorHub = CMU.sensorHub
  local virtual = M.virtual

  local accNoiseX = sensorHub.accNoiseX
  local accNoiseY = sensorHub.accNoiseY
  local accNoiseZ = sensorHub.accNoiseZ
  local accNoiseSum = accNoiseX + accNoiseY + accNoiseZ

  trustWorthiness.pitch = linearScale(abs(sensorHub.pitch), 1.4, halfPi, 1, 0)
  trustWorthiness.roll = linearScale(abs(sensorHub.roll), 1.4, halfPi, 1, 0)

  trustWorthiness.virtualSpeed = min(trustWorthiness.pitch, trustWorthiness.roll, trustWorthiness.bodySlipAngle)
  trustWorthiness.bodySlipAngle = 1 --we trust the body slip angle fully until we don't anymore when a reset is needed

  local absAccX = abs(sensorHub.accelerationXSmooth)
  local absAccY = abs(sensorHub.accelerationYSmooth)
  local absAccZ = abs(sensorHub.accelerationZSmooth - sensorHub.gravity)

  local absPitchAV = abs(sensorHub.pitchAVSmooth)
  local absRollAV = abs(sensorHub.rollAVSmooth)
  local absYawAV = abs(sensorHub.yawAVSmooth)

  if not trustWorthiness.needsFullReset then
    local bodySlipAngleRunAway = virtual.bodySlipAngleRate > 1000 and abs(virtual.bodySlipAngle) > 1
    local bodySlipAngleRateTooHigh = virtual.bodySlipAngleRate > 15 and abs(virtual.wheelSpeed) > 5
    local accXTooHigh = absAccX > 20
    local accYTooHigh = absAccY > 30
    local accZTooHigh = absAccZ > 40
    local accTooHigh = accXTooHigh or accYTooHigh or accZTooHigh
    local avTooHigh = max(absPitchAV, absRollAV, absYawAV) > 5
    local accNoiseTooHigh = accNoiseSum > 100

    local rawVirtualToRecoverySpeedOffsetTooHigh = (abs(abs(virtual.speed) - abs(virtual.recoveryWheelSpeed)) > virtualSpeedLowBiasThreshold) and trustWorthiness.recoverySpeed >= 0.99
    local smoothedVirtualToRecoverySpeedOffsetTooHigh = smoother.isVirtualToRecoverySpeedOffsetTooHighSmoother:getUncapped(rawVirtualToRecoverySpeedOffsetTooHigh and 1 or 0, dt)
    local virtualToRecoverySpeedOffsetTooHigh = smoothedVirtualToRecoverySpeedOffsetTooHigh >= 1

    if bodySlipAngleRunAway or bodySlipAngleRateTooHigh or accTooHigh or avTooHigh or accNoiseTooHigh or virtualToRecoverySpeedOffsetTooHigh then
      trustWorthiness.needsFullReset = true
      local degradationReason = "virtualSensors degraded: " .. (bodySlipAngleRunAway and "bodySlipAngleRunAway" or bodySlipAngleRateTooHigh and "bodySlipAngleRateTooHigh" or accTooHigh and "accTooHigh" or avTooHigh and "avTooHigh" or accNoiseTooHigh and "accNoiseTooHigh" or virtualToRecoverySpeedOffsetTooHigh and "virtualToRecoverySpeedOffsetTooHigh")
      CMU.systemDegradationDetected(degradationReason)
      CMU.logDebugMessage("virtualSensors", string.format("Full reset requested: %s", degradationReason))
    end
  end

  --if we have a degrated system state and need a full reset, kill any meaningful estimates
  if trustWorthiness.needsFullReset then
    trustWorthiness.bodySlipAngle = 0
    trustWorthiness.virtualSpeed = 0
  end

  local accXLow = absAccX < 1.5
  local accXVeryLow = absAccX < 1.0
  local accYLow = absAccY < 3
  local accYVeryLow = absAccY < 2
  local accZLow = absAccZ < 2

  local pitchLow = abs(sensorHub.pitch) < 0.8
  local rollLow = abs(sensorHub.roll) < 0.8

  local pitchAVLow = absPitchAV < 0.2
  local rollAVLow = absRollAV < 0.2
  local yawAVLow = absYawAV < 0.2

  local wheelSpeedTrustHigh = trustWorthiness.wheelSpeed >= 0.95
  local wheelSpeedLow = abs(virtual.wheelSpeed) < 0.2
  local wheelsAgreeWithIMU = virtual.recoveryWheelCount >= 2

  local electricsValues = electrics.values

  local throttleZero = electricsValues.throttle <= 0
  local throttleLow = electricsValues.throttle <= 0.2
  local brakeLow = electricsValues.brake <= 0.2
  local steeringZero = abs(electricsValues.steering_input) <= 0.05

  local sharedProbability = boolToNumber[accXLow] + boolToNumber[accZLow] + boolToNumber[pitchLow] + boolToNumber[rollLow] + boolToNumber[pitchAVLow] + boolToNumber[rollAVLow] + boolToNumber[yawAVLow]
  local rawIsRollingProbability = (sharedProbability + boolToNumber[accYLow] + boolToNumber[wheelSpeedTrustHigh] + boolToNumber[throttleLow] + boolToNumber[brakeLow]) * 0.0909090909 -- / 11
  local rawIsStoppedProbability = (sharedProbability + boolToNumber[accYVeryLow] + boolToNumber[wheelSpeedLow] + boolToNumber[throttleZero]) * 0.1 -- / 10
  local rawIsDrivingStraight = (boolToNumber[accXVeryLow] + boolToNumber[accZLow] + boolToNumber[pitchLow] + boolToNumber[rollLow] + boolToNumber[pitchAVLow] + boolToNumber[rollAVLow] + boolToNumber[yawAVLow] + boolToNumber[steeringZero]) * 0.125 --/ 8
  local rawIsWheelAccelerationConsistent = (boolToNumber[accZLow] + boolToNumber[pitchLow] + boolToNumber[rollLow] + boolToNumber[pitchAVLow] + boolToNumber[rollAVLow] + boolToNumber[wheelsAgreeWithIMU]) * 0.166666667 -- / 6

  resetCriteria.isRollingProbability = resetCriteria.isRollingProbabilitySmoother:getUncapped(rawIsRollingProbability, dt)
  resetCriteria.isStoppedProbability = resetCriteria.isStoppedProbabilitySmoother:getUncapped(rawIsStoppedProbability, dt)
  resetCriteria.isDrivingStraightProbability = resetCriteria.isDrivingStraightProbabilitySmoother:getUncapped(rawIsDrivingStraight, dt)
  resetCriteria.isWheelAccelerationConsistentProbability = resetCriteria.isWheelAccelerationConsistentProbabilitySmoother:getUncapped(rawIsWheelAccelerationConsistent, dt)
  trustWorthiness.recoverySpeed = resetCriteria.isWheelAccelerationConsistentProbability * resetCriteria.isDrivingStraightProbability

  if resetCriteria.isStoppedProbability >= 0.99 then
    --if we are stopped, we can reset everything back to normal
    virtual.bodySlipAngle = 0
    virtual.bodySlipAngleIntegrated = 0
    virtual.integratedSpeed = 0

    trustWorthiness.virtualSpeed = 1
    trustWorthiness.bodySlipAngle = 1
    smoother.isVirtualToRecoverySpeedOffsetTooHighSmoother:reset()
    if trustWorthiness.needsFullReset then
      CMU.logDebugMessage("virtualSensors", "Full reset resolved: isStoppedProbability >= 0.99")
    end
    trustWorthiness.needsFullReset = false
    CMU.systemDegradationResolved()
  elseif resetCriteria.isRollingProbability >= 0.99 then
    --if we are rolling, we can reset everything, but set the speed to the wheel speed
    virtual.bodySlipAngle = 0
    virtual.bodySlipAngleIntegrated = 0
    virtual.integratedSpeed = virtual.wheelSpeed

    trustWorthiness.virtualSpeed = 1
    trustWorthiness.bodySlipAngle = 1
    smoother.isVirtualToRecoverySpeedOffsetTooHighSmoother:reset()
    if trustWorthiness.needsFullReset then
      CMU.logDebugMessage("virtualSensors", "Full reset resolved: isRollingProbability >= 0.99")
    end
    trustWorthiness.needsFullReset = false
    CMU.systemDegradationResolved()
  elseif trustWorthiness.needsFullReset and resetCriteria.isDrivingStraightProbability >= 0.99 and resetCriteria.isWheelAccelerationConsistentProbability >= 0.99 then
    --if the wheels and IMU agree while driving straight, wheel speed is good enough to reacquire the speed estimate
    virtual.bodySlipAngle = 0
    virtual.bodySlipAngleIntegrated = 0
    virtual.integratedSpeed = virtual.recoveryWheelSpeed

    trustWorthiness.virtualSpeed = 1
    trustWorthiness.bodySlipAngle = 1
    smoother.isVirtualToRecoverySpeedOffsetTooHighSmoother:reset()
    if trustWorthiness.needsFullReset then
      CMU.logDebugMessage("virtualSensors", "Full reset resolved: isWheelAccelerationConsistentProbability >= 0.99")
    end
    trustWorthiness.needsFullReset = false
    CMU.systemDegradationResolved()
  elseif resetCriteria.isDrivingStraightProbability >= 0.99 then
    --if we are still actively driving, but straight, we can at least reset the body slip angle, but speed is unknown since we might have wheel slip
    virtual.bodySlipAngle = 0
    virtual.bodySlipAngleIntegrated = 0

    trustWorthiness.bodySlipAngle = 1
    CMU.logDebugMessage("virtualSensors", "Full reset improved: isDrivingStraightProbability >= 0.99")
  end
end

local function updateFixedStep(dt)
  updateWheelSpeed(dt)
  updateTrustWorthiness(dt)
end

local function updatePositionDerivedAcceleration(sampleDt, forwardX, forwardY, forwardZ, upX, upY, upZ, cogX, cogY, cogZ)
  local invForwardLength = 1 / sqrt(forwardX * forwardX + forwardY * forwardY + forwardZ * forwardZ)
  forwardX, forwardY, forwardZ = forwardX * invForwardLength, forwardY * invForwardLength, forwardZ * invForwardLength
  local leftX, leftY, leftZ = upY * forwardZ - upZ * forwardY, upZ * forwardX - upX * forwardZ, upX * forwardY - upY * forwardX
  local invLeftLength = 1 / sqrt(leftX * leftX + leftY * leftY + leftZ * leftZ)
  leftX, leftY, leftZ = leftX * invLeftLength, leftY * invLeftLength, leftZ * invLeftLength
  upX, upY, upZ = forwardY * leftZ - forwardZ * leftY, forwardZ * leftX - forwardX * leftZ, forwardX * leftY - forwardY * leftX

  cogX = cogX + forwardX * positionCoGForward + leftX * positionCoGLeft + upX * positionCoGUp
  cogY = cogY + forwardY * positionCoGForward + leftY * positionCoGLeft + upY * positionCoGUp
  cogZ = cogZ + forwardZ * positionCoGForward + leftZ * positionCoGLeft + upZ * positionCoGUp

  local isVelocityValid = false
  if positionHasLastCoG then
    local invSampleDt = 1 / sampleDt
    local velocityX = (cogX - positionLastCoG.x) * invSampleDt
    local velocityY = (cogY - positionLastCoG.y) * invSampleDt
    local velocityZ = (cogZ - positionLastCoG.z) * invSampleDt
    local lastForward, lastLeft = positionLastForward, positionLastLeft
    local yawIncrement = atan2((lastForward.y * forwardZ - lastForward.z * forwardY) * upX + (lastForward.z * forwardX - lastForward.x * forwardZ) * upY + (lastForward.x * forwardY - lastForward.y * forwardX) * upZ, lastForward.x * forwardX + lastForward.y * forwardY + lastForward.z * forwardZ)
    isVelocityValid = true
    if positionHasLastVelocity then
      local invSampleDtSum = 1 / (sampleDt + positionLastSampleDt)
      local invAccelerationDt = 2 * invSampleDtSum
      local accelerationX = (velocityX - positionLastCoGVelocity.x) * invAccelerationDt
      local accelerationY = (velocityY - positionLastCoGVelocity.y) * invAccelerationDt
      local accelerationZ = (velocityZ - positionLastCoGVelocity.z) * invAccelerationDt
      if accelerationX * accelerationX + accelerationY * accelerationY + accelerationZ * accelerationZ > positionMaxAccelerationSquared then
        isVelocityValid = false --this velocity spans a position jump (teleport), restart the difference chain and keep the last valid acceleration and yaw rate
      else
        --the second difference is centred on the previous sample, so project on its frame and match the yaw rate to it
        positionAccelerationX = accelerationX * lastForward.x + accelerationY * lastForward.y + accelerationZ * lastForward.z
        positionAccelerationY = -(accelerationX * lastLeft.x + accelerationY * lastLeft.y + accelerationZ * lastLeft.z)
        positionYawRate = -(yawIncrement + positionLastYawIncrement) * invSampleDtSum
      end
    end
    positionLastYawIncrement = yawIncrement
    positionLastCoGVelocity:set(velocityX, velocityY, velocityZ)
  end
  positionLastCoG:set(cogX, cogY, cogZ)
  positionLastForward:set(forwardX, forwardY, forwardZ)
  positionLastLeft:set(leftX, leftY, leftZ)
  positionLastSampleDt = sampleDt
  positionHasLastCoG = true
  positionHasLastVelocity = isVelocityValid
end

local function getPositionDerivedAcceleration(dt)
  positionSampleTimer = positionSampleTimer + dt
  if positionSampleTimer < positionSampleTime - 1e-9 then
    return positionAccelerationX, positionAccelerationY, positionYawRate
  end
  local sampleDt = positionSampleTimer --includes the overshoot, so resetting to 0 loses no time
  positionSampleTimer = 0

  local forwardX, forwardY, forwardZ = obj:getDirectionVectorXYZ()
  local upX, upY, upZ = obj:getDirectionVectorUpXYZ()
  local cogX, cogY, cogZ = obj:getPositionXYZ()
  updatePositionDerivedAcceleration(sampleDt, forwardX, forwardY, forwardZ, upX, upY, upZ, cogX, cogY, cogZ)

  return positionAccelerationX, positionAccelerationY, positionYawRate
end

local function update(dt)
  local accelerationX, accelerationY, yawRate = getPositionDerivedAcceleration(dt)

  local virtual = M.virtual
  local bsa = virtual.bodySlipAngle
  local sinBodySlipAngle = sin(bsa)
  local cosBodySlipAngle = cos(bsa)

  updateIntegratedSpeed(sinBodySlipAngle, cosBodySlipAngle, accelerationX, accelerationY, dt) --before updateBodySlipAngle, which may flip the speed sign
  updateBodySlipAngle(sinBodySlipAngle, cosBodySlipAngle, accelerationX, accelerationY, yawRate, dt)

  virtual.speed = virtual.integratedSpeed
end

local function updateDebug(dt)
  update(dt)
  local reference = M.reference
  local speedUnsigned = sqrt(CMU.sensorHub.vX * CMU.sensorHub.vX + CMU.sensorHub.vY * CMU.sensorHub.vY)

  local bsa = atan2(CMU.sensorHub.vX, CMU.sensorHub.vY)
  local bsaSign = sign(bsa)
  reference.bodySlipAngle = (bsa - halfPi * bsaSign) * clamp(speedUnsigned, 0, 1)
  reference.speed = speedUnsigned
end

local function updateGFX(dt)
end

local function updateGFXDebug(dt)
  updateGFX(dt)
  local virtual = M.virtual
  local reference = M.reference
  local trustWorthiness = M.trustWorthiness

  debugPacket.referenceBodySlipAngle = reference.bodySlipAngle
  debugPacket.referenceSpeed = reference.speed

  debugPacket.virtualBodySlipAngle = virtual.bodySlipAngle
  debugPacket.virtualBodySlipAngleIntegrated = virtual.bodySlipAngleIntegrated
  debugPacket.virtualBodySlipAngleLowSpeed = virtual.bodySlipAngleLowSpeed
  debugPacket.virtualBodySlipAngleLowSpeedTrust = virtual.bodySlipAngleLowSpeedTrust
  debugPacket.virtualSpeed = virtual.speed

  debugPacket.avgWheelSpeed = virtual.avgWheelSpeed
  debugPacket.avgNonPropulsedWheelspeed = virtual.avgNonPropulsedWheelSpeed
  debugPacket.wheelSpeed = virtual.wheelSpeed
  debugPacket.wheelSpeedOffset = virtual.wheelSpeed - reference.speed
  debugPacket.imuAcceleration = virtual.imuAcceleration
  debugPacket.recoveryWheelSpeed = virtual.recoveryWheelSpeed
  debugPacket.recoveryWheelCount = virtual.recoveryWheelCount

  debugPacket.virtualSpeedOffset = virtual.speed - reference.speed
  debugPacket.wheelVirtualSpeedOffset = virtual.speed - virtual.wheelSpeed
  debugPacket.wheelRecoverySpeedOffset = virtual.wheelSpeed - virtual.recoveryWheelSpeed
  debugPacket.virtualRecoverySpeedOffset = virtual.speed - virtual.recoveryWheelSpeed

  debugPacket.pitchTrust = trustWorthiness.pitch
  debugPacket.rollTrust = trustWorthiness.roll
  debugPacket.bodySlipAngleTrust = trustWorthiness.bodySlipAngle
  debugPacket.wheelSpeedTrust = trustWorthiness.wheelSpeed
  debugPacket.virtualSpeedTrust = trustWorthiness.virtualSpeed
  debugPacket.recoverySpeedTrust = trustWorthiness.recoverySpeed

  debugPacket.resetIsStopped = resetCriteria.isStoppedProbability
  debugPacket.resetIsRolling = resetCriteria.isRollingProbability
  debugPacket.resetIsDrivingStraight = resetCriteria.isDrivingStraightProbability
  debugPacket.resetIsWheelAccelerationConsistent = resetCriteria.isWheelAccelerationConsistentProbability
  debugPacket.virtualSpeedLowBiasThreshold = virtualSpeedLowBiasThreshold

  CMU.sendDebugPacket(debugPacket)
end

local function reset(jbeamData)
  M.reference.bodySlipAngle = 0
  M.reference.speed = 0

  M.virtual.speed = 0
  M.virtual.integratedSpeed = 0
  M.virtual.wheelSpeed = 0
  M.virtual.imuAcceleration = 0
  M.virtual.recoveryWheelSpeed = 0
  M.virtual.recoveryWheelCount = 0
  M.virtual.bodySlipAngle = 0
  M.virtual.bodySlipAngleIntegrated = 0
  M.virtual.bodySlipAngleLowSpeed = 0
  M.virtual.bodySlipAngleLowSpeedTrust = 1
  M.virtual.lastBodySlipAngle = 0
  M.virtual.bodySlipAngleRate = 0

  M.trustWorthiness.pitch = 1
  M.trustWorthiness.roll = 1
  M.trustWorthiness.bodySlipAngle = 1
  M.trustWorthiness.virtualSpeed = 1
  M.trustWorthiness.recoverySpeed = 1
  M.trustWorthiness.needsFullReset = false

  resetCriteria.isRollingProbability = 0
  resetCriteria.isStoppedProbability = 0
  resetCriteria.isDrivingStraightProbability = 0
  resetCriteria.isWheelAccelerationConsistentProbability = 0
  resetCriteria.isRollingProbabilitySmoother:reset()
  resetCriteria.isStoppedProbabilitySmoother:reset()
  resetCriteria.isDrivingStraightProbabilitySmoother:reset()
  resetCriteria.isWheelAccelerationConsistentProbabilitySmoother:reset()

  smoother.isVirtualToRecoverySpeedOffsetTooHighSmoother:reset()
  smoother.wheelSpeedTrust:reset()
  smoother.imuAcceleration:reset()

  table.clear(lastWheelSpeeds)
  table.clear(wheelAccelerationSmoothers)
  table.clear(recoveryWheelSpeedCandidates)

  refNodeCoGTransformationLastOmega:set(0, 0, 0)
  refNodeCoGTransformationOmega:set(0, 0, 0)
  refNodeCoGTransformationAlpha:set(0, 0, 0)
  refNodeCoGTransformationAccRefNode:set(0, 0, 0)
  refNodeCoGTransformationAccCoG:set(0, 0, 0)

  positionSampleTimer = 0
  positionHasLastCoG = false
  positionHasLastVelocity = false
  positionLastSampleDt = 0
  positionLastYawIncrement = 0
  positionAccelerationX = 0
  positionAccelerationY = 0
  positionYawRate = 0
end

local function init(jbeamData)
  M.reference.bodySlipAngle = 0
  M.reference.speed = 0

  M.virtual.speed = 0
  M.virtual.integratedSpeed = 0
  M.virtual.wheelSpeed = 0
  M.virtual.imuAcceleration = 0
  M.virtual.recoveryWheelSpeed = 0
  M.virtual.recoveryWheelCount = 0
  M.virtual.bodySlipAngle = 0
  M.virtual.bodySlipAngleIntegrated = 0
  M.virtual.bodySlipAngleLowSpeed = 0
  M.virtual.bodySlipAngleLowSpeedTrust = 1
  M.virtual.lastBodySlipAngle = 0
  M.virtual.bodySlipAngleRate = 0

  M.trustWorthiness.pitch = 1
  M.trustWorthiness.roll = 1
  M.trustWorthiness.bodySlipAngle = 1
  M.trustWorthiness.virtualSpeed = 1
  M.trustWorthiness.recoverySpeed = 1
  M.trustWorthiness.needsFullReset = false
  smoother.imuAcceleration:reset()
  table.clear(lastWheelSpeeds)
  table.clear(wheelAccelerationSmoothers)
  table.clear(recoveryWheelSpeedCandidates)

  M.isActive = true
end

local function initLastStage()
  wheelCount = wheels.wheelCount

  local cogPos = CMU.vehicleData.vehicleStats.cogWithWheels or offsetRefNodeFromCoG
  local accPos = CMU.vehicleData.vehicleStats.refNodePos or offsetRefNodeFromCoG

  offsetRefNodeFromCoG = accPos - cogPos

  --CoG offset from the ref node in the axes of obj:getDirectionVector/obj:getDirectionVectorUp
  local refNodes = v.data.refNodes[0]
  local nodes = v.data.nodes
  local refNodePos = vec3(nodes[refNodes.ref].pos)
  local forward = refNodePos - vec3(nodes[refNodes.back].pos)
  forward:normalize()
  local left = (vec3(nodes[refNodes.up].pos) - refNodePos):cross(forward)
  left:normalize()
  local up = forward:cross(left)
  local cogOffset = cogPos - refNodePos
  positionCoGForward, positionCoGLeft, positionCoGUp = cogOffset:dot(forward), cogOffset:dot(left), cogOffset:dot(up)
end

local function setDebugMode(debugEnabled)
  isDebugEnabled = debugEnabled

  M.updateGFX = isDebugEnabled and updateGFXDebug or updateGFX
  M.update = isDebugEnabled and updateDebug or update
end

local function registerCMU(cmu)
  CMU = cmu
end

local function shutdown()
  M.isActive = false
  M.updateGFX = nil
  M.update = nil
  M.updateWheelsIntermediate = nil
end

M.init = init
M.initLastStage = initLastStage

M.reset = reset

M.updateGFX = updateGFX
M.update = update
M.updateFixedStep = updateFixedStep

M.registerCMU = registerCMU
M.setDebugMode = setDebugMode
M.shutdown = shutdown

return M
