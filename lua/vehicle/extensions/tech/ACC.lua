-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Nearby vehicle perception.
local maxVehicleRangeSq = 10000.0
local leaderLateralWindow = 2.0
local leaderDirectionDotMin = 0.45
local leaderDirectionDotMinCorner = 0.05
local leaderRearAllowance = 2.5
local leaderLateralLookaheadGain = 0.2
local leaderLateralLookaheadMax = 10.0
local leaderCorridorHalfLen = 27.5
local leaderCorridorHalfZ = 1.0
local leaderVerticalWindow = 3.0
local leaderVerticalLookaheadGain = 0.04
local leaderVerticalLookaheadMax = 2.0
local lastPos = {}
local egoHalfWidth = 0.0
local egoCorridorC, egoCorridorX, egoCorridorY, egoCorridorZ = vec3(), vec3(), vec3(), vec3()
local targetCorridorC, targetCorridorX, targetCorridorY, targetCorridorZ = vec3(), vec3(), vec3(), vec3()
local leaderState = {
  closingSpeed = 0.0,
  leadAccel = 0.0,
  age = 0.0,
  persisted = false
}

-- ACC state.
local driverOverrideThreshold = 0.03
local targetSpeedVal, loaded, debug = 0.0, false, false
local accLeaderMode = "auto"
local externalLeader = {objectId = nil, leadSpeed = nil, leadAccel = nil}
local driverOverrideCallback

local tableUnpack = rawget(table, "unpack") or rawget(_G, "unpack")
local logTimer, csvData
local debugFields = {
  "targetSpeed", "egoSpeed", "leaderId", "leaderPersisted", "leaderAge",
  "leadSpeed", "leaderAccel", "closingSpeed", "dAvail", "requiredBrakeAccel",
  "unfilteredAccTarget", "accTarget", "desiredDecel", "measuredDecel", "decelError",
  "actuatorMode", "throttle", "brake", "actuator"
}

local eps = 0.1
local leaderConst = {holdTime = 3.0, switchThreatMargin = 2.5}
local ctrl = {
  maxAccel = 2.0,
  brakePedalRefDecel = 9.0,
  accelAggression = 2.3,
  throttleOverrideReengageTime = 1.0,
  actuatorCoastDeadband = 0.05,
  lowTargetSpeedVal = 0.5,
  standstillSpeed = 0.3,
  standstillHoldMargin = 0.3,
  holdBrakeMin = 0.3,
  throttleModel = {
    weightMin = 0.05,
    weightMax = 12.0,
    biasMin = -4.0,
    biasMax = 0.0,
    coastThrottle = 0.001,
    driveThrottle = 0.03,
    minLearnSpeed = 1.0,
    accelMargin = 0.5,
    recoveryAccel = 0.5,
    recoveryLongAccel = 0.05
  }
}

local accTune = {
  auto = {
    headway = {
      standStillDistance = 3.0,
      speedHeadwayGain = 1.00,
      maxDynamicHeadway = 90.0
    },
    leader = {
      speedFilterTau = 0.20,
      accelFilterTau = 0.40,
      accelFilterTauBrake = 0.15
    },
    kinematic = {
      Kv = 0.40,
      K_gap = 1.0,
      K_gapClose = 0.9,
      Kff = 0.25,
      KffBrake = 0.2,
      comfortDecel = 1.2,
      tau = 0.3
    }
  },
  external = {
    headway = {
      standStillDistance = 2.0,
      speedHeadwayGain = 0.32,
      maxDynamicHeadway = 38.0
    },
    leader = {
      speedFilterTau = 0.20,
      accelFilterTau = 0.40,
      accelFilterTauBrake = 0.10
    },
    kinematic = {
      Kv = 0.40,
      K_gap = 0.40,
      K_gapClose = 1.0,
      Kff = 0.25,
      KffBrake = 0.8,
      comfortDecel = 1.2,
      tau = 0.20
    }
  }
}

local params = accTune.auto

local throttleAccModel = newLineFitting(3, 0.3, -0.1, nil, ctrl.throttleModel.weightMin, ctrl.throttleModel.weightMax, ctrl.throttleModel.biasMin, ctrl.throttleModel.biasMax)
local brakeAccModel = newLineFitting(3, ctrl.brakePedalRefDecel, 0.0, nil, 0.1, nil, -0.2, 0.2)
for _, model in ipairs({throttleAccModel, brakeAccModel}) do
  model.weightStartingValue, model.biasStartingValue = model.weight, model.bias
end

local throttleAccModelSmoother = newTemporalSmoothingNonLinear(1e30, 1, 0)

local controlState = {
  longAccel = 0.0,
  lastActuator = "neutral",
  inputAuthority = 1.0
}

local lastCommand = {throttle = 0.0, brake = 0.0}

local function writeDebugSample(sample, shouldLog)
  local csvValues = {}
  local logValues = shouldLog and {} or nil
  for i, field in ipairs(debugFields) do
    local value = sample[field]
    if shouldLog then
      logValues[i] = field .. ": " .. tostring(value)
    end
    if type(value) == "boolean" then
      value = value and 1 or 0
    elseif type(value) == "number" then
      value = roundNear(value, 1e-3)
    end
    csvValues[i] = value
  end
  if shouldLog then
    log("D", "ACC", table.concat(logValues, ", "))
  end
  csvData:add(tableUnpack(csvValues))
end

local function horizSpeed(v)
  return math.sqrt(square(v.x) + square(v.y))
end

local function blendToward(current, target, tau, dtSim)
  return lerp(current, target, dtSim / (tau + dtSim))
end

local function leaderLookahead(relLong, gain, max)
  return clamp(math.max(relLong, 0.0) * gain, 0.0, max)
end

local function measuredLongAccel()
  return sensors and sensors.gy and -sensors.gy or controlState.longAccel
end

local function updateThrottleModelBiasLimits()
  throttleAccModel.biasMin = ctrl.throttleModel.biasMin
  throttleAccModel.biasMax = ctrl.throttleModel.biasMax

  local worldGravityDir = rawget(_G, "gravityDir")
  local fwd = worldGravityDir and obj:getForwardVector()
  if not fwd then
    return
  end

  fwd:normalize()
  throttleAccModel.biasMax = clamp(
    math.min(ctrl.throttleModel.biasMax, fwd:dot(worldGravityDir) * 9.81),
    ctrl.throttleModel.biasMin,
    ctrl.throttleModel.biasMax
  )
  throttleAccModel.bias = clamp(throttleAccModel.bias, throttleAccModel.biasMin, throttleAccModel.biasMax)
end

local function computeTargetDistance(leadSpeed)
  return params.headway.standStillDistance + clamp(leadSpeed * params.headway.speedHeadwayGain, 0.0, params.headway.maxDynamicHeadway)
end

local function filterLeadAccel(current, raw, dtSim)
  return blendToward(current, raw, raw < current and params.leader.accelFilterTauBrake or params.leader.accelFilterTau, dtSim)
end

local function resetLeaderState(clearHistory)
  if clearHistory then
    lastPos = {}
  end
  leaderState.objectId, leaderState.distance, leaderState.leadSpeed = nil, nil, nil
  leaderState.closingSpeed, leaderState.leadAccel, leaderState.age, leaderState.persisted = 0.0, 0.0, 0.0, false
end

local function updateLeaderState(objectId, distance, leadSpeed, egoSpeed, dtSim, externalLeadAccel, closingSpeed)
  local sameLeader = leaderState.objectId == objectId and leaderState.leadSpeed ~= nil
  if sameLeader then
    if externalLeadAccel ~= nil then
      leaderState.leadAccel = externalLeadAccel
      leaderState.leadSpeed = leadSpeed
    else
      local rawLeadAccel = (leadSpeed - leaderState.leadSpeed) / math.max(eps, dtSim)
      leaderState.leadAccel = filterLeadAccel(leaderState.leadAccel, rawLeadAccel, dtSim)
      leaderState.leadSpeed = blendToward(leaderState.leadSpeed, leadSpeed, params.leader.speedFilterTau, dtSim)
    end
  else
    leaderState.objectId = objectId
    leaderState.leadSpeed = leadSpeed
    leaderState.leadAccel = externalLeadAccel or 0.0
  end

  leaderState.distance = distance
  leaderState.closingSpeed = math.max(0.0, closingSpeed or egoSpeed - leadSpeed)
  leaderState.age = 0.0
  leaderState.persisted = false
end

local function getPersistedLeader(dtSim, objects, egoSpeed)
  if leaderState.objectId == nil or leaderState.distance == nil or leaderState.age >= leaderConst.holdTime or not objects[leaderState.objectId] then
    resetLeaderState()
    return
  end

  leaderState.age = leaderState.age + dtSim
  leaderState.closingSpeed = math.max(0.0, egoSpeed - (leaderState.leadSpeed or 0.0))
  leaderState.distance = math.max(0.0, leaderState.distance - leaderState.closingSpeed * dtSim)
  leaderState.persisted = true
end

local function resetControlTracking(inputAuthority, resetModels)
  controlState.filteredAccTarget, controlState.lastLongVel = nil, nil
  controlState.longAccel, controlState.inputAuthority = 0.0, inputAuthority
  resetLeaderState(true)

  lastCommand.throttle, lastCommand.brake = 0.0, 0.0
  throttleAccModelSmoother:set(0.0)

  if resetModels then
    controlState.lastActuator = "neutral"
    throttleAccModel:reset()
    brakeAccModel:reset()
  end
end

local function applyControl(throttle, brake)
  throttle = clamp(throttle or 0.0, 0.0, 1.0)
  brake = clamp(brake or 0.0, 0.0, 1.0)

  if throttle > 0 and brake > 0 then
    if throttle > brake then brake = 0.0 else throttle = 0.0 end
  end

  controlState.lastActuator = throttle > 0 and "throttle" or brake > 0 and "brake" or "neutral"

  if extensions.tech_adasInput.apply(throttle, brake, "standard") then
    throttleAccModelSmoother:set(throttle)
    lastCommand.throttle = throttle
    lastCommand.brake = brake
    return true
  end
  return false
end

local function prepareLeaderScan()
  local fwd = obj:getForwardVector():normalized()
  local right = obj:getDirectionVectorRight():normalized()
  local vel = obj:getVelocity()
  local frame = {
    pos = obj:getPosition(),
    vel = vel,
    egoSpeed = horizSpeed(vel),
    selfFront = obj:getFrontPosition(),
    fwd = fwd,
    right = right,
    up = fwd:cross(right):normalized(),
    selfId = obj:getID()
  }

  egoCorridorX:setScaled2(frame.fwd, leaderCorridorHalfLen)
  egoCorridorC:setAdd2(frame.selfFront, egoCorridorX)
  egoCorridorY:setScaled2(frame.right, egoHalfWidth)
  egoCorridorZ:setScaled2(frame.up, leaderCorridorHalfZ)

  local objects = mapmgr.getObjects() or {}
  for objectId, _ in pairs(lastPos) do
    if not objects[objectId] then
      lastPos[objectId] = nil
    end
  end
  return frame, objects
end

local function scanLeaderCandidate(objectId, frame, dtSim)
  if objectId == frame.selfId then
    return
  end

  local posB = obj:getObjectCenterPosition(objectId)
  if not posB then
    return
  end

  local previousPosB = lastPos[objectId]
  lastPos[objectId] = posB
  local velB = previousPosB and (posB - previousPosB) * (1.0 / math.max(1e-4, dtSim)) or nil

  local fwdB = obj:getObjectDirectionVector(objectId)
  if not fwdB then
    return
  end
  fwdB:normalize()

  local targetLength = obj:getObjectInitialLength(objectId)
  local targetFront = obj:getObjectFrontPosition(objectId)
  if not targetLength or not targetFront then
    return
  end

  local relPos = posB - frame.pos
  local relLong, relLat, relVert = relPos:dot(frame.fwd), relPos:dot(frame.right), relPos:dot(frame.up)
  if relLong <= -leaderRearAllowance
    or math.abs(relLat) > leaderLateralWindow + leaderLookahead(relLong, leaderLateralLookaheadGain, leaderLateralLookaheadMax)
    or math.abs(relVert) > leaderVerticalWindow + leaderLookahead(relLong, leaderVerticalLookaheadGain, leaderVerticalLookaheadMax)
    or relPos:lenSquared() >= maxVehicleRangeSq
    or frame.fwd:dot(fwdB) <= (relLong > 8.0 and leaderDirectionDotMin or leaderDirectionDotMinCorner) then
    return
  end

  local upB = obj:getObjectDirectionVectorUp(objectId)
  if not upB then
    return
  end
  upB:normalize()
  targetCorridorX:setScaled2(fwdB, -leaderCorridorHalfLen)
  targetCorridorC:setSub2(targetFront, fwdB * (targetLength + leaderCorridorHalfLen))
  targetCorridorY:setCross(upB, fwdB)
  targetCorridorY:setScaled(obj:getObjectInitialWidth(objectId) * 0.5 / math.max(targetCorridorY:length(), 1e-30))
  targetCorridorZ:setScaled2(upB, leaderCorridorHalfZ)
  if not overlapsOBB_OBB(egoCorridorC, egoCorridorX, egoCorridorY, egoCorridorZ, targetCorridorC, targetCorridorX, targetCorridorY, targetCorridorZ) then
    return
  end

  local distanceToLeader = (targetFront - fwdB * targetLength - frame.selfFront):length()
  local closingSpeedCandidate = velB and math.max(0.0, (frame.vel - velB):dot(frame.fwd)) or 0.0
  local leadSpeedCandidate = velB and horizSpeed(velB) or frame.egoSpeed
  local candidateScore = distanceToLeader - computeTargetDistance(leadSpeedCandidate) -
    square(closingSpeedCandidate) / (2.0 * ctrl.brakePedalRefDecel)
  return distanceToLeader, velB and leadSpeedCandidate or nil, candidateScore, closingSpeedCandidate
end

local function getLeader(dtSim)
  local frame, objects = prepareLeaderScan()
  local objectId, distance, leadSpeed, externalAccel, closingSpeed

  if accLeaderMode == "external" then
    objectId = externalLeader.objectId
    if objectId and objects[objectId] then
      local dist, _, _, closeSpd = scanLeaderCandidate(objectId, frame, dtSim)
      distance = dist
      if distance then
        leadSpeed = externalLeader.leadSpeed or frame.egoSpeed
        externalAccel = externalLeader.leadAccel
        closingSpeed = closeSpd
      end
    end
  else
    local nearestId, nearestDist, nearestLeadSpd, nearestScore, nearestClose = nil, nil, nil, math.huge, nil
    local currentId, currentDist, currentLeadSpd, currentScore, currentClose = nil, nil, nil, math.huge, nil

    for oid, _ in pairs(objects) do
      local dist, leadSpd, score, closeSpd = scanLeaderCandidate(oid, frame, dtSim)
      if dist then
        score, closeSpd = score or math.huge, closeSpd or 0.0
        if oid == leaderState.objectId then
          currentId, currentDist, currentLeadSpd, currentScore, currentClose = oid, dist, leadSpd, score, closeSpd
        end
        if score < nearestScore then
          nearestId, nearestDist, nearestLeadSpd, nearestScore, nearestClose = oid, dist, leadSpd, score, closeSpd
        end
      end
    end

    if currentId and nearestId ~= currentId and nearestScore > currentScore - leaderConst.switchThreatMargin then
      nearestId, nearestDist, nearestLeadSpd, nearestClose = currentId, currentDist, currentLeadSpd, currentClose
    end

    if nearestId then
      objectId = nearestId
      distance = nearestDist
      leadSpeed = nearestLeadSpd or (leaderState.objectId == nearestId and leaderState.leadSpeed) or frame.egoSpeed
      closingSpeed = nearestClose or 0.0
    end
  end

  if objectId and distance then
    updateLeaderState(objectId, distance, leadSpeed, frame.egoSpeed, dtSim, externalAccel, closingSpeed)
  elseif accLeaderMode == "external" and not (objectId and objects[objectId]) then
    resetLeaderState()
  else
    getPersistedLeader(dtSim, objects, frame.egoSpeed)
  end
  return frame.egoSpeed
end

-- Follow law: vDes = lead + gapRate(gapErr), a = Kv*(vDes-ego) + kff*leadAccel, capped by v²/2room when inside the desired gap.
local function computeKinematicAccel(egoSpeed, distanceToLeader, leadSpeed, closingSpeed, leadAccel, hasNoLeadCar, dtSim)
  local km = params.kinematic

  local gapDes = hasNoLeadCar and math.huge or computeTargetDistance(leadSpeed)
  local gapErr = hasNoLeadCar and 0.0 or (distanceToLeader - gapDes)
  local dAvail = hasNoLeadCar and math.huge or math.max(0.0, gapErr)
  local gapRate = gapErr >= 0.0 and math.sqrt(2.0 * km.comfortDecel * km.K_gap * gapErr) or km.K_gapClose * gapErr
  local vDes = hasNoLeadCar and targetSpeedVal or clamp(leadSpeed + gapRate, 0.0, targetSpeedVal)

  local kff = leadAccel < 0.0 and km.KffBrake or km.Kff
  local aCmd = km.Kv * (vDes - egoSpeed) + kff * leadAccel
  local aReqBrake = 0.0

  if not hasNoLeadCar then
    if closingSpeed > eps and gapErr < 0.0 then
      local room = math.max(distanceToLeader - params.headway.standStillDistance, eps)
      local aStop = -square(closingSpeed) / (2.0 * room)
      aReqBrake, aCmd = -aStop, math.min(aCmd, aStop)
    end
    if egoSpeed < ctrl.standstillSpeed and leadSpeed < ctrl.standstillSpeed and math.abs(gapErr) <= ctrl.standstillHoldMargin then
      aCmd = math.min(aCmd, 0.0)
    end
  end
  aCmd = hasNoLeadCar and clamp(aCmd, -km.comfortDecel, ctrl.maxAccel) or math.min(aCmd, ctrl.maxAccel)

  controlState.filteredAccTarget = blendToward(controlState.filteredAccTarget or 0, aCmd, km.tau, dtSim)
  local accTarget = hasNoLeadCar and math.max(controlState.filteredAccTarget, -km.comfortDecel) or controlState.filteredAccTarget

  return accTarget, vDes, gapDes, dAvail, aReqBrake, aCmd
end

local function updateThrottleModel(dtSim, egoSpeed)
  local tm = ctrl.throttleModel
  local clutch = (electrics and electrics.values and electrics.values.clutch) or 0.0
  local throttle = clamp(lastCommand.throttle, 0.0, 1.0)
  local isCoastingSample = throttle <= tm.coastThrottle
  local isDriveSample = throttle >= tm.driveThrottle

  if lastCommand.brake > 0 or clutch > 0 or egoSpeed <= tm.minLearnSpeed or (not isCoastingSample and not isDriveSample) then
    return
  end

  updateThrottleModelBiasLimits()

  local longAccel = measuredLongAccel()
  if isCoastingSample then
    longAccel = clamp(longAccel, throttleAccModel.biasMin, throttleAccModel.biasMax)
  else
    local minPlausibleAccel = tm.biasMin - tm.accelMargin
    local maxPlausibleAccel = tm.biasMax + throttle * tm.weightMax + tm.accelMargin
    if longAccel < minPlausibleAccel or longAccel > maxPlausibleAccel then
      return
    end
  end

  throttleAccModel:get(throttle, longAccel, dtSim)
end

local function mapAccelerationToPedals(accTarget, targetSpeedControl, dtSim)
  local throttle, brake, actuatorMode = 0.0, 0.0, "coast"
  local tm = ctrl.throttleModel
  local coastBias = throttleAccModel.bias

  if targetSpeedControl >= ctrl.lowTargetSpeedVal and accTarget >= coastBias then
    actuatorMode = "throttle"
    local throttleTarget = clamp(throttleAccModel:getX(accTarget), 0.0, 1.0)
    if accTarget > tm.recoveryAccel and throttleTarget < tm.driveThrottle and controlState.longAccel <= tm.recoveryLongAccel then
      throttleAccModel:reset()
      throttleTarget = clamp(throttleAccModel:getX(accTarget), 0.0, 1.0)
    end
    throttle = throttleAccModelSmoother:getWithRate(throttleTarget, dtSim, ctrl.accelAggression)
  elseif accTarget <= coastBias - ctrl.actuatorCoastDeadband then
    actuatorMode = "brake"
    local modelBrake = clamp(brakeAccModel:getX(coastBias - accTarget), 0.0, 1.0)
    local holdBrakeMin = sign(math.max(0, ctrl.lowTargetSpeedVal - targetSpeedControl)) * ctrl.holdBrakeMin
    local arcadeAutoBrakeSwitch = sign(math.max(0, (electrics.values.smoothShiftLogicAV or 0) - 3)) -- arcade autobrake comes in at |smoothShiftLogicAV| < 5
    brake = clamp(modelBrake, holdBrakeMin, 1.0) * arcadeAutoBrakeSwitch
  end

  if actuatorMode == "brake" then
    throttleAccModelSmoother:set(0.0)
  end

  return clamp(throttle, 0.0, 1.0), clamp(brake, 0.0, 1.0), actuatorMode
end

local function updateLongitudinalControl(egoSpeed, dtSim)
  local hasNoLeadCar = leaderState.distance == nil
  local distanceToLeader = hasNoLeadCar and math.huge or leaderState.distance
  local leadSpeed = clamp(leaderState.leadSpeed or targetSpeedVal, 0.0, targetSpeedVal)
  local closingSpeed = leaderState.closingSpeed or 0.0
  local leadAccel = leaderState.leadAccel or 0.0

  controlState.longAccel = controlState.lastLongVel and (egoSpeed - controlState.lastLongVel) / math.max(eps, dtSim) or 0.0
  controlState.lastLongVel = egoSpeed

  local accTarget, targetSpeedControl, _, dAvail, aReqBrake, unfilteredAccTarget =
    computeKinematicAccel(egoSpeed, distanceToLeader, leadSpeed, closingSpeed, leadAccel, hasNoLeadCar, dtSim)

  updateThrottleModel(dtSim, egoSpeed)

  local throttle, brake, actuatorMode = mapAccelerationToPedals(accTarget, targetSpeedControl, dtSim)
  local desiredDecel = math.max(0.0, -accTarget)
  if controlState.inputAuthority < 1.0 then
    controlState.inputAuthority = math.min(1.0, controlState.inputAuthority + dtSim / math.max(eps, ctrl.throttleOverrideReengageTime))
    local inputAuthority = smoothstep(controlState.inputAuthority)
    throttle = throttle * inputAuthority
    brake = brake * inputAuthority
  end
  if not applyControl(throttle, brake) then
    return
  end

  if debug then
    local measuredDecel = math.max(0.0, -measuredLongAccel())
    local decelError = measuredDecel - desiredDecel
    local sample = {
      targetSpeed = targetSpeedControl, egoSpeed = egoSpeed,
      leaderId = leaderState.objectId or -1, leaderPersisted = leaderState.persisted, leaderAge = leaderState.age,
      leadSpeed = leadSpeed, leaderAccel = leadAccel, closingSpeed = closingSpeed,
      dAvail = dAvail, requiredBrakeAccel = aReqBrake, unfilteredAccTarget = unfilteredAccTarget, accTarget = accTarget,
      desiredDecel = desiredDecel, measuredDecel = measuredDecel, decelError = decelError,
      actuatorMode = actuatorMode, throttle = throttle, brake = brake, actuator = controlState.lastActuator
    }

    logTimer = logTimer + dtSim

    local shouldLog = logTimer > 0.2
    writeDebugSample(sample, shouldLog)
    if shouldLog then
      logTimer = 0
    end
  end
end

local function unload()
  if not loaded then
    return
  end

  loaded = false
  accLeaderMode = "auto"
  params = accTune.auto
  externalLeader.objectId, externalLeader.leadSpeed, externalLeader.leadAccel = nil, nil, nil
  input.event("throttle", 0, 1, nil, nil, nil, "adas")
  input.event("brake", 0, 1, nil, nil, nil, "adas")
  resetControlTracking(1.0, true)
  extensions.tech_adasInput.setAiEnabled(true)

  log("I", "ACC", "ACC extension unloaded")
  if debug then
    csvData:write("accLog")
  end
  ui_message("ACC extension unloaded", 5, "Tech", "forward")
end

local function updateGFX(dtSim)
  if not loaded then
    return
  end

  local playerInputs = input.lastInputs["local"] or {}
  if (playerInputs["brake"] or 0) > driverOverrideThreshold then
    unload()
    if driverOverrideCallback then
      driverOverrideCallback("brake")
    end
    return
  end
  if (playerInputs["throttle"] or 0) > driverOverrideThreshold then
    input.event("brake", 0, 1, nil, nil, nil, "adas")
    resetControlTracking(0.0)
    return
  end

  updateLongitudinalControl(getLeader(dtSim), dtSim)
end

local function load(speed, debugFlag)
  if loaded then
    return
  end

  targetSpeedVal = math.max(0.0, speed or horizSpeed(obj:getVelocity()))
  loaded = true
  egoHalfWidth = obj:getInitialWidth() * 0.5
  debug = debugFlag == true
  extensions.tech_adasInput.setAiEnabled(false)
  resetControlTracking(1.0, true)

  if debug then
    csvData = require("csvlib").newCSV(tableUnpack(debugFields))
    logTimer = 0
  end
  ui_message("ACC extension loaded", 5, "Tech", "forward")
end

local function changeSpeed(speed)
  targetSpeedVal = math.max(0.0, speed or 0.0)
  if accLeaderMode ~= "external" then
    ui_message("Speed set", 5, "Tech", "forward")
  end
end

local function setLeaderMode(mode)
  if accLeaderMode == mode then
    return
  end

  resetLeaderState(mode == "auto")
  accLeaderMode = mode
  params = accTune[mode]
end

local function setExternalLeader(objectId, leadSpeed, leadAccel)
  externalLeader.objectId = tonumber(objectId)
  externalLeader.leadSpeed = math.max(0.0, leadSpeed)
  externalLeader.leadAccel = leadAccel
  setLeaderMode("external")
end

local function clearExternalLeader()
  externalLeader.objectId, externalLeader.leadSpeed, externalLeader.leadAccel = nil, nil, nil
  setLeaderMode("auto")
end

local function setDriverOverrideCallback(callback)
  driverOverrideCallback = callback
end

M.updateGFX = updateGFX
M.onUnload = unload
M.unload = unload
M.load = load
M.changeSpeed = changeSpeed
M.setLeaderMode = setLeaderMode
M.setExternalLeader = setExternalLeader
M.clearExternalLeader = clearExternalLeader
M.setDriverOverrideCallback = setDriverOverrideCallback

return M
