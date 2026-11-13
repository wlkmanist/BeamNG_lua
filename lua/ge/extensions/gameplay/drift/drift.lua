-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {"gameplay_walk"}
local im = ui_imgui
local pow = math.pow
local abs = math.abs
local sqrt = math.sqrt

local redF = ColorF(1,0,0,1)
local blueF = ColorF(0,0.5,1,0.5)

local simulatedDriftData
local dtSim

local profiler = LuaProfiler("drift profiler")
local gc
local driftDebugInfo = {
  default = true,
  canBeChanged = true
}

local plotHelperUtil
local maxHistorySize = 50
local debugHistoryTimer = 0
local debugHistorySamplesPerSec = 10
local debugToggleSmothnessGraph = im.BoolPtr(false)

local resetTimer = 0.1

local showImguiCrashWindow = false

local crashDetectionSettings = {
  verticallyUnweighted = true,
  maxAccel = 30,
  maxDamage = 10000,
  enableImpactLocationData = false
}

local driftOptions = {
  minAngle = 7,
  maxAngle = 165,
  allowDonut = false,
  allowTightDrifts = true,
  totalDriftAngleModulo = true,
  raycastHeight = 0.5,
  raycastDist = 1.8,
  raycastInwardOffset = 0.650,
  wallDetectionLength = 3,
  baseDriftCompleteTime = 1.2,
  failPointsCooldown = 1.65,
  minAirSpeed = 4,
  maxWasDriftingTime = 4,
  crashDamageThreshold = 150
}

local trackedVehicles = {} -- keyed by vehId
local firstDriveSuppressed = false

local function newVehicleDriftState(id)
  return {
    vehId = id,
    playerId = 0,
    veh = nil,
    vehData = nil,
    resetFlag = false,
    isDrifting = false,
    isOverSteering = false,
    isChainingDrifts = false,
    isCrashing = false,
    currDegAngle = 0,
    currDegAngleSign = 0,
    currDriftCompletedTimer = 0,
    currFailPointsCooldown = 0,
    lastDriftTimer = 0,
    currResetTimer = 0,
    driftActiveData = nil,
    driftChainActiveData = nil,
    driftSmoothnessData = nil,
    frontPoint = {
      lastFrameVel = vec3(),
      lastFramePos = vec3(),
      vel = vec3(),
      pos = vec3(),
    },
    rearPoint = {
      lastFrameVel = vec3(),
      lastFramePos = vec3(),
      vel = vec3(),
      pos = vec3(),
    },
    accelSmoother = newTemporalSmoothing(0.13, 0.13),
    gForceSmoother = newTemporalSmoothing(2, 2),
    accelerationSmoothed = nil,
    lastFrameKphAirSpeed = nil,
    kphAirSpeed = 0,
    distSinceLastFrame = 0,
    isInTheAir = false,
    isReverseCheesing = false,
    currDriftCompleteTime = nil,
    crashed = false,
    balanceMode = false,
    vehPos = vec3(),
    velDir = vec3(0,0,0),
    lastFramePlPos = vec3(),
    lastFrameVel = vec3(),
    avrgRefPointsKphSpeed = nil,
    frontDot = nil,
    centerDot = nil,
    rearDot = nil,
    driftAngleDiff = nil,
    stopSpinoutCheck = false,
    triggerCrashDelayTimer = 0,
    score = nil,
    -- debug
    debugHistories = {
      jerk = {color = {1, 0.1, 0.1, 1}, name = "G-Force Jerk", data = {}},
      angleDiff = {color = {0.3, 1, 1, 1}, name = "Angle Diff", data = {}},
      speedDiff = {color = {0.3, 1, 0.3, 1}, name = "Speed Diff", data = {}},
    },
  }
end

local function getState(vehId)
  if vehId then return trackedVehicles[vehId] end
  local plVehId = be:getPlayerVehicleID(0)
  if plVehId and trackedVehicles[plVehId] then return trackedVehicles[plVehId] end
  for _, state in pairs(trackedVehicles) do return state end
  return nil
end

-- GC-avoidance scratch vectors (shared across all vehicles per frame)
local dirVec = vec3()
local corner_FL = vec3()
local corner_FR = vec3()
local corner_BR = vec3()
local corner_BL = vec3()
local center = vec3()
local frontCenter = vec3()
local rearCenter = vec3()
local up = vec3(0,0,1)
local tempVec = vec3(0,0,0)

local halfAxis0 = vec3()
local halfAxis1 = vec3()
local halfAxis2 = vec3()
local oobbCenter = vec3()
local raycastHeightVec = vec3(0,0,driftOptions.raycastHeight)

local velocityTip = vec3(0,0,0)

local tempVecCurrVel = vec3()
local tempVecPos = vec3()
local tempVecPosUp = vec3()
local tempVecPosUp2 = vec3()
local tempNormalizedVel = vec3()
local tempColor = ColorF(1,0.3,1,0.3)

local frontPointTempVec = vec3()
local rearPointTempVec = vec3()
local crossUpTempVec = vec3()

local vec3DistDiff = vec3(0,0,0)
local tempVellDiff = vec3()
local tempVec2 = vec3()

local random = 0.5
local distFromCenter = 4
local minSpeedAllowed = 1.5
local minAllowedAngle = 110
local triggerCrashDelay = 0.3

--------------------------------------------------

local scanners = {
  front = {
    limitStart = corner_FR,
    limitEnd = corner_FL,
    startPoint = frontCenter,
    currOffTimer = 0,
    lockLerp = 0,
    lockDist = math.huge,
    value = "closestWallDistanceFront"
  },
  rear = {
    limitStart = corner_BR,
    limitEnd = corner_BL,
    startPoint = rearCenter,
    currOffTimer = 0,
    lockLerp = 0,
    lockDist = math.huge,
    value = "closestWallDistanceRear"
  },
}

local function resetVehicleState(state)
  gameplay_util_crashDetection.resetCrashData(state.vehId)
  state.driftActiveData = nil
  state.driftChainActiveData = nil
  state.driftSmoothnessData = nil
  state.resetFlag = true
  state.isDrifting = false
  state.balanceMode = false

  for _, historyData in pairs(state.debugHistories) do
    historyData.data = {}
  end
end

local function newDriftSmoothnessData(state)
  state.driftSmoothnessData = {
    totalScore = 0,
    numberOfSamples = 0,
    smoothness = 0,
    gForceJerk = 0,
  }
end

local function newDriftActiveData(state, vehicleData)
  state.driftActiveData = {
    driftDuration = 0,
    driftDistance = 0,
    closestWallDistanceFront = 0,
    closestWallDistanceRear = 0,
    currDegAngle = 0,
    direction = nil,
    lastFrameVelDir = vec3(state.velDir),
    totalDriftAngle = 0,
    totalDriftTime = 0,
    angleVelocity = 0,
    totalDonutsInRow = 0,
    startPos = vec3(vehicleData.pos),
    lastPos = vec3(vehicleData.pos),
    avgDriftAngle = 0,
    driftUniformity = 0,
    score = 0,

    totalAngles = 0,
    totalSpeeds = 0,
    totalPerformanceFactors = 0,
    totalSteps = 0,

    lastFrameDriftAngle = state.currDegAngle,
    driftAngleDiffSinceLastFrame = 0,
    lastFrameSpeed = 0,
    speedDiffSinceLastFrame = 0,
    lastFrameGForce = 0,
    gForceJerk = 0,
  }
end

local function newDriftChainActiveData(state)
  state.driftChainActiveData = {
    totalDriftDistance = 0,
    totalDriftTime = 0,
    rightDrifts = 0,
    leftDrifts = 0,
    chainedDrifts = 0,
    currentCircleDrift = {
      totalAngle = 0
    }
  }
end

local function calculateYaw(vector)
  local normalized = vector:normalized()
  return math.atan2(normalized.y, normalized.x)
end

local function yawDifference(vec1, vec2)
  local yaw1 = calculateYaw(vec1)
  local yaw2 = calculateYaw(vec2)
  local difference = yaw2 - yaw1

  while difference > math.pi do
      difference = difference - 2 * math.pi
  end
  while difference < -math.pi do
      difference = difference + 2 * math.pi
  end

  return difference
end

local isBeingDebugged
local function calculateDriftAngle(state, vehData)
  dirVec:set(vehData.dirVec)
  dirVec:normalize()
  tempVec:set(vehData.vel)
  tempVec:normalize()

  local difference = math.atan2(dirVec.y, dirVec.x) - math.atan2(tempVec.y, tempVec.x)
  if difference > math.pi then difference = difference - 2 * math.pi
  elseif difference < -math.pi then difference = difference + 2 * math.pi end
  state.currDegAngle = math.abs(difference * (180 / math.pi))
  state.currDegAngleSign = vehData.vel:dot(up:cross(dirVec))

  if simulatedDriftData then state.currDegAngle = simulatedDriftData.currDegAngle end

  if isBeingDebugged then
    debugDrawer:drawTextAdvanced(center, string.format("Smoothed accel : %0.2f", state.accelerationSmoothed or 0), ColorF(1,1,1,1),  true, false, ColorI(0,0,0,255), false, false)
    debugDrawer:drawLine(center, center + dirVec, ColorF(1,0,0,1))
    velocityTip:set(center + vehData.vel:normalized())
    debugDrawer:drawLine(center, velocityTip, ColorF(1,0.3,0,1))
    debugDrawer:drawTextAdvanced(center, string.format("Yaw : %d ° (min req:%d)", state.currDegAngle, driftOptions.minAngle), ColorF(1,1,1,1), true, false, ColorI(0,0,0,255), false, false)
  end
end

local function calculateVehCenterAndWheels(state)
  halfAxis0:set(be:getObjectOOBBHalfAxisXYZ(state.vehId, 0))
  halfAxis1:set(be:getObjectOOBBHalfAxisXYZ(state.vehId, 1))
  halfAxis2:set(be:getObjectOOBBHalfAxisXYZ(state.vehId, 2))
  oobbCenter:set(be:getObjectOOBBCenterXYZ(state.vehId))
  corner_FL:set(
    -halfAxis1.x + oobbCenter.x + halfAxis0.x - halfAxis2.x + raycastHeightVec.x,
    -halfAxis1.y + oobbCenter.y + halfAxis0.y - halfAxis2.y + raycastHeightVec.y,
    -halfAxis1.z + oobbCenter.z + halfAxis0.z - halfAxis2.z + raycastHeightVec.z
  )
  corner_FR:set(
    -halfAxis1.x + oobbCenter.x - halfAxis0.x - halfAxis2.x + raycastHeightVec.x,
    -halfAxis1.y + oobbCenter.y - halfAxis0.y - halfAxis2.y + raycastHeightVec.y,
    -halfAxis1.z + oobbCenter.z - halfAxis0.z - halfAxis2.z + raycastHeightVec.z
  )
  corner_BR:set(
    halfAxis1.x + oobbCenter.x + halfAxis0.x - halfAxis2.x + raycastHeightVec.x,
    halfAxis1.y + oobbCenter.y + halfAxis0.y - halfAxis2.y + raycastHeightVec.y,
    halfAxis1.z + oobbCenter.z + halfAxis0.z - halfAxis2.z + raycastHeightVec.z
  )
  corner_BL:set(
    halfAxis1.x + oobbCenter.x - halfAxis0.x - halfAxis2.x + raycastHeightVec.x,
    halfAxis1.y + oobbCenter.y - halfAxis0.y - halfAxis2.y + raycastHeightVec.y,
    halfAxis1.z + oobbCenter.z - halfAxis0.z - halfAxis2.z + raycastHeightVec.z
  )
  center:set(
    (corner_FL.x + corner_FR.x + corner_BL.x + corner_BR.x) / 4,
    (corner_FL.y + corner_FR.y + corner_BL.y + corner_BR.y) / 4,
    (corner_FL.z + corner_FR.z + corner_BL.z + corner_BR.z) / 4
  )
  frontCenter:set(
    (corner_FL.x + corner_FR.x + center.x) / 3,
    (corner_FL.y + corner_FR.y + center.y) / 3,
    (corner_FL.z + corner_FR.z + center.z) / 3
  )
  rearCenter:set(
    (corner_BL.x + corner_BR.x + center.x) / 3,
    (corner_BL.y + corner_BR.y + center.y) / 3,
    (corner_BL.z + corner_BR.z + center.z) / 3
  )
end

local function calculateDistWall(state)
  random = getBlueNoise1d(random)
  for _, scannerData in pairs(scanners) do
    tempVec:setSub2(scannerData.limitEnd, scannerData.limitStart)
    tempVec:setScaled(random)
    tempVec:setAdd(scannerData.limitStart)

    tempVec2:setSub2(tempVec, scannerData.startPoint)
    local scanDist = castRayStatic(scannerData.startPoint, tempVec2, driftOptions.wallDetectionLength)

    if isBeingDebugged then
      debugDrawer:drawLine(scannerData.startPoint, scannerData.startPoint + (tempVec2):normalized() * scanDist, blueF)
      debugDrawer:drawSphere(scannerData.startPoint + (tempVec2):normalized() * scanDist, 0.1, blueF)
    end

    if scanDist < scannerData.lockDist then
      scannerData.lockLerp = random
    end

    if scannerData.lockDist < driftOptions.wallDetectionLength or scanDist < driftOptions.wallDetectionLength then
      scannerData.lockDist = castRayStatic(scannerData.startPoint, tempVec2, driftOptions.wallDetectionLength)
      if isBeingDebugged then
        debugDrawer:drawLine(scannerData.startPoint, scannerData.startPoint + (tempVec2):normalized() * scannerData.lockDist, redF)
        debugDrawer:drawSphere(scannerData.startPoint + (tempVec2):normalized() * scannerData.lockDist, 0.15, redF)
      end
    end

    if simulatedDriftData and simulatedDriftData.wallDistance then
      state.driftActiveData[scannerData.value] = simulatedDriftData.wallDistance
    else
      state.driftActiveData[scannerData.value] = scannerData.lockDist
    end
  end
end

local function driftFailed(state)
  state.currFailPointsCooldown = driftOptions.failPointsCooldown
  state.driftChainActiveData = nil
  state.driftActiveData = nil
end

local function checkForCrash(state)
  if simulatedDriftData then
    if simulatedDriftData.isCrashing then
      state.crashed = true
    end
  end

  if state.crashed then
    state.triggerCrashDelayTimer = state.triggerCrashDelayTimer + dtSim
    if state.triggerCrashDelayTimer >= triggerCrashDelay then
      if state.score.cachedScore > 0 then
        driftFailed(state)
        extensions.hook("onDriftCrash", state.vehId)
        state.crashed = false
      end
    end
  end

  state.isCrashing = gameplay_util_crashDetection.isVehCrashing(state.vehId)
end

local function detectCircleDrift(state)
  if state.isChainingDrifts then
    if state.isDrifting then
      state.driftChainActiveData.currentCircleDrift.totalAngle = state.driftChainActiveData.currentCircleDrift.totalAngle + state.driftAngleDiff
    end
  end
end

local function detectSpinout(state)
  if state.currFailPointsCooldown > 0 or state.isCrashing then return end
  if state.kphAirSpeed < minSpeedAllowed then
    if state.currDegAngle > minAllowedAngle and not state.stopSpinoutCheck then
      driftFailed(state)
      extensions.hook("onDriftSpinout", state.vehId)
    end
    if state.lastDriftTimer < driftOptions.maxWasDriftingTime then
      state.stopSpinoutCheck = true
    end
  end
end

local function updateReferencePointData(point)
  tempVecPos:set(point.pos)

  if isBeingDebugged then
    tempVecPosUp:setAdd2(point.pos, up)
    debugDrawer:drawSphere(tempVecPosUp, 0.2, tempColor)
    if point.vel then
      tempNormalizedVel:set(point.vel)
      tempNormalizedVel:normalize()
      tempVecPosUp2:setAdd2(tempVecPosUp, tempNormalizedVel)
      debugDrawer:drawLineInstance(tempVecPosUp, tempVecPosUp2, 3, tempColor)
    end
  end

  if point.lastFramePos then
    tempVecCurrVel:setSub2(tempVecPos, point.lastFramePos)
    tempVecCurrVel:setScaled(1/dtSim)
  else
    tempVecCurrVel:set(0,0,0)
  end

  point.lastFrameVel:set(tempVecCurrVel)
  point.lastFramePos:set(tempVecPos)
  point.vel:set(tempVecCurrVel)
end

local function checkOverSteering(state)
  state.isOverSteering = false

  frontPointTempVec:set(dirVec)
  frontPointTempVec:setScaled(distFromCenter)
  frontPointTempVec:setAdd(center)

  rearPointTempVec:set(dirVec)
  rearPointTempVec:setScaled(-distFromCenter)
  rearPointTempVec:setAdd(center)

  state.frontPoint.pos:set(frontPointTempVec)
  state.rearPoint.pos:set(rearPointTempVec)
  updateReferencePointData(state.frontPoint)
  updateReferencePointData(state.rearPoint)
  if state.frontPoint.vel and state.vehData then
    state.avrgRefPointsKphSpeed = ((state.frontPoint.vel:length() + state.rearPoint.vel:length()) / 2) * 3.6

    crossUpTempVec:set(dirVec:cross(up))
    state.frontDot = state.frontPoint.vel:normalized():dot(crossUpTempVec)
    state.centerDot = state.velDir:dot(crossUpTempVec)
    state.rearDot = state.rearPoint.vel:normalized():dot(crossUpTempVec)

    state.isOverSteering =
    state.frontDot < 0 and state.centerDot > 0 or
    state.centerDot < 0 and state.frontDot > 0 or
    state.frontDot > 0 and state.centerDot > 0 and state.rearDot > 0 or
    state.frontDot < 0 and state.centerDot < 0 and state.rearDot < 0
  end
end

local function isReverseCheesingFunc(state)
  state.isReverseCheesing = (state.currDegAngle or 0) > 120 and (state.accelerationSmoothed or 0) > -0.07
  if isBeingDebugged then
    debugDrawer:drawTextAdvanced(center, "Reverse cheesing : " .. tostring(state.isReverseCheesing), ColorF(1,1,1,1), true, false, ColorI(0,0,0,255), false, false)
  end
end

local function populateDriftSmoothnessHistory(state)
  if isBeingDebugged then
    debugHistoryTimer = debugHistoryTimer + dtSim * debugHistorySamplesPerSec
    if debugHistoryTimer > 1 then
      table.insert(state.debugHistories.jerk.data, 1, state.driftActiveData.gForceJerk)
      table.insert(state.debugHistories.angleDiff.data, 1, state.driftActiveData.driftAngleDiffSinceLastFrame or 0)
      table.insert(state.debugHistories.speedDiff.data, 1, state.driftActiveData.speedDiffSinceLastFrame or 0)

      for _, historyData in pairs(state.debugHistories) do
        if historyData.data and historyData.data[maxHistorySize] then
          historyData.data[maxHistorySize] = nil
        end
      end

      debugHistoryTimer = debugHistoryTimer - 1
    end
  end
end

local function calculateGForceJerk(state)
  tempVellDiff:setSub2(state.vehData.vel, state.lastFrameVel)
  state.lastFrameVel:set(state.vehData.vel)
  local gForce = tempVellDiff:length() / dtSim / 9.81

  local gForceJerk = math.abs(gForce - state.driftActiveData.lastFrameGForce)
  local gForceJerkSmoothed = state.gForceSmoother:get(gForceJerk, dtSim)
  state.driftActiveData.lastFrameGForce = gForce

  state.driftActiveData.gForceJerk = gForceJerkSmoothed
end

local function calculateAngleDiff(state)
  state.driftActiveData.driftAngleDiffSinceLastFrame = math.abs(state.currDegAngle - state.driftActiveData.lastFrameDriftAngle)
  state.driftActiveData.lastFrameDriftAngle = state.currDegAngle
end

local function calculateSpeedDiff(state)
  state.driftActiveData.speedDiffSinceLastFrame = math.abs(state.kphAirSpeed - state.lastFrameKphAirSpeed)
end

local function calculateDriftSmoothnessScore(state)
  if not state.driftSmoothnessData then
    newDriftSmoothnessData(state)
  end
  calculateGForceJerk(state)
  calculateAngleDiff(state)
  calculateSpeedDiff(state)
  populateDriftSmoothnessHistory(state)

  state.driftSmoothnessData.totalScore = state.driftSmoothnessData.totalScore + (state.driftActiveData.gForceJerk ^ 2 + state.driftActiveData.driftAngleDiffSinceLastFrame ^ 2 + state.driftActiveData.speedDiffSinceLastFrame ^ 2)
  state.driftSmoothnessData.numberOfSamples = state.driftSmoothnessData.numberOfSamples + 1
  state.driftSmoothnessData.smoothness = state.driftSmoothnessData.totalScore / state.driftSmoothnessData.numberOfSamples
end

local function detectAndGatherDriftInfo(state, vehicleData)
  isReverseCheesingFunc(state)
  state.isInTheAir = not gameplay_util_groundContact.isOnWheels(state.vehId)

  checkOverSteering(state)

  if simulatedDriftData then
    state.isReverseCheesing = false
    state.isInTheAir = false
    state.avrgRefPointsKphSpeed = simulatedDriftData.airSpeed
    state.currFailPointsCooldown = 0
    state.currResetTimer = 0
    state.isOverSteering = true
  end

  state.isDrifting =
  state.isOverSteering
  and not state.isReverseCheesing
  and state.currDegAngle > driftOptions.minAngle and state.currDegAngle < driftOptions.maxAngle
  and state.avrgRefPointsKphSpeed > driftOptions.minAirSpeed
  and not gameplay_walk.isWalking()
  and not state.isInTheAir
  and state.currFailPointsCooldown <= 0
  and state.currResetTimer <= 0
  and not state.isCrashing

  state.velDir:set(push3(vehicleData.vel):normalized())

  if state.isDrifting then
    if state.driftChainActiveData == nil then
      newDriftChainActiveData(state)
      extensions.hook("onDriftChainStarted", state.vehId)
    end

    if state.driftActiveData == nil then
      newDriftActiveData(state, vehicleData)

      if state.velDir:dot(up:cross(vehicleData.dirVec:normalized())) > 0 then
        state.driftChainActiveData.rightDrifts = state.driftChainActiveData.rightDrifts + 1
        state.driftActiveData.direction = "right"
      else
        state.driftChainActiveData.leftDrifts = state.driftChainActiveData.leftDrifts + 1
        state.driftActiveData.direction = "left"
      end
      state.driftChainActiveData.chainedDrifts = state.driftChainActiveData.chainedDrifts + 1
      state.stopSpinoutCheck = false

      if state.driftChainActiveData.chainedDrifts > 1 then
        extensions.hook("onDriftTransition", state.vehId)
      end
      extensions.hook("onDriftStatusChanged", true, state.driftActiveData.direction, state.vehId)
    end

    state.currDriftCompletedTimer = state.currDriftCompleteTime

    state.driftAngleDiff = math.deg(math.acos(state.velDir:cosAngle(state.driftActiveData.lastFrameVelDir)))

    state.driftActiveData.angleVelocity = state.driftAngleDiff / dtSim
    state.driftActiveData.totalDriftAngle = state.driftActiveData.totalDriftAngle + state.driftAngleDiff
    if debugToggleSmothnessGraph[0] then
      calculateDriftSmoothnessScore(state)
    end

    state.driftActiveData.lastFrameVelDir:set(state.velDir)
    state.driftActiveData.totalDriftTime = state.driftActiveData.totalDriftTime + dtSim
    state.driftActiveData.score = state.driftActiveData.score + gameplay_drift_scoring.getScoreAddedThisFrame(state.vehId)

    vec3DistDiff:setSub2(state.driftActiveData.lastPos, vehicleData.pos)
    state.driftChainActiveData.totalDriftDistance = state.driftChainActiveData.totalDriftDistance + vec3DistDiff:length()
    state.driftActiveData.lastPos:set(vehicleData.pos)
    state.driftActiveData.driftDistance = state.driftActiveData.driftDistance + vec3DistDiff:length()
    state.driftChainActiveData.totalDriftTime = state.driftChainActiveData.totalDriftTime + dtSim

    state.driftActiveData.totalSpeeds = state.driftActiveData.totalSpeeds + state.kphAirSpeed
    state.driftActiveData.totalAngles = state.driftActiveData.totalAngles + state.currDegAngle
    state.driftActiveData.totalPerformanceFactors = state.driftActiveData.totalPerformanceFactors + gameplay_drift_scoring.getDriftPerformanceFactor(state.vehId)
    state.driftActiveData.totalSteps = state.driftActiveData.totalSteps + 1

    state.lastDriftTimer = 0

  else
    if state.driftActiveData then
      extensions.hook("onDriftStatusChanged", false, nil, state.vehId)
      extensions.hook("onDriftActiveDataFinished", state.driftActiveData, state.vehId)
      state.driftActiveData = nil
    end

    state.lastDriftTimer = state.lastDriftTimer + dtSim
  end

  state.isChainingDrifts = state.driftChainActiveData ~= nil
end

local function driftCoolDown(state)
  if state.currDriftCompletedTimer > 0 then
    state.currDriftCompletedTimer = state.currDriftCompletedTimer - dtSim
    if state.balanceMode then state.currDriftCompletedTimer = 1 end
    if state.currDriftCompletedTimer < 0 and state.score.cachedScore > 0 then
      extensions.hook('onDriftCompleted', {
        chainDriftData = state.driftChainActiveData,
        vehId = state.vehId
      })
      state.driftChainActiveData = nil
    end
  end
end

local function updateDriftCompleteTime(state)
  state.currDriftCompleteTime = linearScale(state.score.combo, 5, 20, driftOptions.baseDriftCompleteTime, 2.25)
end

local function calculateDistSinceLastFrame(state)
  if state.lastFramePlPos then
    state.distSinceLastFrame = state.vehPos:distance(state.lastFramePlPos)
    if simulatedDriftData then
      state.distSinceLastFrame = simulatedDriftData.airSpeed * dtSim / 3.6421
    end
  end

  state.lastFramePlPos:set(state.vehPos)
end

local function tryTrackDriftVehForCrash(state)
  if state.vehId ~= nil and gameplay_drift_general.getContext() ~= "inAnotherMissionType" and not gameplay_util_crashDetection.isVehTracked(state.vehId) and state.vehId > -1 then
    gameplay_util_crashDetection.addTrackedVehicleById(state.vehId, crashDetectionSettings, "drift")
  end
end

local function imguiDebug()
  if not isBeingDebugged then return end
  local state = getState()
  if not state then return end

  if im.Begin("Drift detection") then
    im.Text("Is drifting : " .. ((state.isDrifting and "Yes") or "No"))
    im.Text("Is crashing : " .. ((state.isCrashing and "Yes") or "No"))
    im.Text("Is reverse cheesing : " .. ((state.isReverseCheesing and "Yes") or "No"))
    im.Text("Is in the air : " .. ((state.isInTheAir and "Yes") or "No"))
    im.Text(string.format("Air speed : %d(%d) kph", state.kphAirSpeed or 0, state.avrgRefPointsKphSpeed or 0))
    im.Text(string.format("Min required angle : %0.2f", driftOptions.minAngle or 0))
    im.Text(string.format("Drift complete time : %0.2f", state.currDriftCompleteTime or 0))
    im.Text(string.format("Time to confirmation : %0.2f", state.currDriftCompletedTimer))
    im.Text(string.format("Acceleration : %0.2f", state.accelerationSmoothed or 0))
    im.Text(string.format("Tracked vehicles : %d", tableSize(trackedVehicles)))

    im.Dummy(im.ImVec2(1, 10))

    if im.Button("Toggle Imgui Crash Window") then
      showImguiCrashWindow = not showImguiCrashWindow
    end

    if state.isDrifting and state.driftActiveData then
      local avgDriftAngle = state.driftActiveData.totalAngles / state.driftActiveData.totalSteps
      im.Text(string.format("Angle : %d °", state.currDegAngle))
      im.Text(string.format("Total drift distance : %d", state.driftChainActiveData.totalDriftDistance))
      im.Text(string.format("Average drift angle : %d", avgDriftAngle))
      im.Text(string.format("Wall distance front : %f", state.driftActiveData.closestWallDistanceFront))
      im.Text(string.format("Wall distance rear : %f", state.driftActiveData.closestWallDistanceRear))
    end

    im.Text("Balance mode : " .. (state.balanceMode and "Yes" or "No"))

    im.Dummy(im.ImVec2(1, 10))

    im.Checkbox("Toggle Smothness Graph", debugToggleSmothnessGraph)
    if debugToggleSmothnessGraph[0] then
      im.Text(string.format("Drift smoothness : %0.2f", state.driftSmoothnessData and state.driftSmoothnessData.smoothness or 0))
      im.SameLine()
      if im.Button("Reset Drift Smoothness") then
        newDriftSmoothnessData(state)
      end

      plotHelperUtil = plotHelperUtil or require('/lua/ge/extensions/editor/util/plotHelperUtil')()
      im.BeginChild1("Debug Graph", im.ImVec2(im.GetContentRegionAvailWidth(), 400), true)
      for _, historyData in pairs(state.debugHistories) do
        im.PushStyleColor2(im.Col_Text, im.ImVec4(historyData.color[1], historyData.color[2], historyData.color[3], historyData.color[4]))
        im.TextWrapped(historyData.name)
        im.PopStyleColor()
      end

      local chartData = {}
      local chartColors = {}
      local i = 1
      for _, historyData in pairs(state.debugHistories) do
        chartData[i] = {}
        for j = 1, #historyData.data do
          chartData[i][j] = {j, historyData.data[j]}
        end
        chartColors[i] = historyData.color
        i = i + 1
      end

      plotHelperUtil:setDataMulti(chartData)
      plotHelperUtil:setSeriesColors(chartColors)
      plotHelperUtil:scaleToFitData()
      plotHelperUtil:setScale(nil, nil, 0, nil)
      plotHelperUtil:draw(im.GetContentRegionAvailWidth(), im.GetContentRegionAvail().y, 400)

      im.EndChild()
    end
  end
  im.End()

  gameplay_util_crashDetection.setDebug(showImguiCrashWindow)
end

local function updateVehicle(state)
  if not state.resetFlag then resetVehicleState(state) end

  if state.vehId and not state.veh then
    state.veh = scenetree.findObjectById(state.vehId)
  end

  if not state.veh then return end

  state.vehData = map.objects[state.vehId]
  if not state.vehData then return end
  state.kphAirSpeed = state.vehData.vel:length() * 3.6

  state.vehPos:set(state.vehData.pos)
  tryTrackDriftVehForCrash(state)

  state.score = gameplay_drift_scoring.getScore(state.vehId)

  updateDriftCompleteTime(state)
  calculateVehCenterAndWheels(state)

  calculateDriftAngle(state, state.vehData)
  calculateDistSinceLastFrame(state)
  checkForCrash(state)
  if not state.isDrifting and (state.score.cachedScore or 0) > 0 then
    detectSpinout(state)
  end
  detectAndGatherDriftInfo(state, state.vehData)
  detectCircleDrift(state)

  if state.isDrifting then
    calculateDistWall(state)
    state.driftActiveData.currDegAngle = state.currDegAngle
  else
    driftCoolDown(state)
  end
  if state.currFailPointsCooldown > 0 then
    state.currFailPointsCooldown = state.currFailPointsCooldown - dtSim
  end

  if state.currResetTimer > 0 then
    state.currResetTimer = state.currResetTimer - dtSim
  end

  state.accelerationSmoothed = state.accelSmoother:get(state.kphAirSpeed - (state.lastFrameKphAirSpeed or state.kphAirSpeed), dtSim)
  state.lastFrameKphAirSpeed = state.kphAirSpeed
end

local function onUpdate(dtReal, _dtSim, dtRaw)
  dtSim = _dtSim

  local firstDriveActive = gameplay_discover_firstDrive_experience
    and gameplay_discover_firstDrive_experience.isActive
    and gameplay_discover_firstDrive_experience.isActive()
  if firstDriveActive then
    if not firstDriveSuppressed then
      for _, state in pairs(trackedVehicles) do resetVehicleState(state) end
      gameplay_drift_scoring.reset()
    end
    firstDriveSuppressed = true
    return
  end
  firstDriveSuppressed = false

  isBeingDebugged = gameplay_drift_general.getExtensionDebug("gameplay_drift_drift")
  imguiDebug()

  if gameplay_drift_general.getGeneralDebug() then profiler:start() end

  if gameplay_walk.isWalking() or gameplay_drift_general.getPaused() or _dtSim <= 0 then return end

  -- skip drift processing during splitscreen unless the drift gamemode is running
  if core_multiseat.isMultiseatActive() and gameplay_drift_general.getContext() ~= "inSplitscreen" then return end

  -- auto-track player 0 if nothing tracked yet
  if not next(trackedVehicles) then
    local plVeh = getPlayerVehicle(0)
    if plVeh then
      local plId = plVeh:getId()
      if plId and plId > -1 then
        M.addTrackedVehicle(plId)
      end
    end
  end

  for _, state in pairs(trackedVehicles) do
    updateVehicle(state)
  end

  if gameplay_drift_general.getGeneralDebug() then
    profiler:add("Drift detection")
    gc = profiler.sections[1].garbage
    profiler:finish(false)
  end
end

local function simulateADrift(data)
  simulatedDriftData = data
end

local function getPlayerIdForVehicle(vehId)
  local state = trackedVehicles[vehId]
  return state and state.playerId or 0
end

local function removeTrackedVehicle(vehId)
  if not vehId then return end
  local state = trackedVehicles[vehId]
  if state then
    gameplay_util_crashDetection.removeTrackedVehicleById(vehId)
  end
  trackedVehicles[vehId] = nil
end

local function addTrackedVehicle(vehId, opts)
  if not vehId or vehId < 0 then return end
  local state = trackedVehicles[vehId]
  if not state then
    state = newVehicleDriftState(vehId)
    trackedVehicles[vehId] = state
  end
  if opts then
    if opts.playerId ~= nil then
      state.playerId = opts.playerId
      -- a player drives one vehicle at a time: drop any older claim on that player, otherwise
      -- leftovers (eg a mission vehicle removed without a vehicle switch) keep being tracked
      -- and fight over the same player slot in the UI stream
      for otherId, otherState in pairs(trackedVehicles) do
        if otherId ~= vehId and otherState.playerId == opts.playerId then
          removeTrackedVehicle(otherId)
        end
      end
    end
  end
  return state
end

local function getTrackedVehicles()
  return trackedVehicles
end

local function getDriftActiveData(vehId)
  local state = getState(vehId)
  return state and state.driftActiveData
end

local function getDriftChainActiveData(vehId)
  local state = getState(vehId)
  return state and state.driftChainActiveData
end

local function getDriftChainChainedDrifts(vehId)
  local state = getState(vehId)
  return state and state.driftChainActiveData and state.driftChainActiveData.chainedDrifts or 0
end

local function getIsDrifting(vehId)
  local state = getState(vehId)
  return state and state.isDrifting or false
end

local function getAirSpeed(vehId)
  local state = getState(vehId)
  return state and state.kphAirSpeed
end

local function getVehPos(vehId)
  local state = getState(vehId)
  return state and state.vehPos
end

local function getVehId()
  local state = getState()
  return state and state.vehId
end

local function getPlVeh()
  local state = getState()
  return state and state.veh
end

local function getVehData(vehId)
  local state = getState(vehId)
  return state and state.vehData
end

local function getVehVel(vehId)
  local state = getState(vehId)
  return state and state.velDir
end

local function getCurrDegAngleSigned(vehId)
  local state = getState(vehId)
  if not state then return 0 end
  return (state.currDegAngle or 0) * sign(state.currDegAngleSign or 0)
end

local function getCurrDriftCompletedTime(vehId)
  local state = getState(vehId)
  if not state or not state.currDriftCompleteTime or state.currDriftCompleteTime == 0 then return 0 end
  return state.currDriftCompletedTimer / state.currDriftCompleteTime
end

local function getAngleDiff(vehId)
  local state = getState(vehId)
  return state and state.driftAngleDiff
end

local function getDistSinceLastFrame(vehId)
  local state = getState(vehId)
  return state and state.distSinceLastFrame or 0
end

local function getCurrentDriftDuration(vehId)
  local state = getState(vehId)
  if state and state.isDrifting and state.driftActiveData then
    return state.driftActiveData.totalDriftTime
  end
  return 0
end

local function getIsOverSteering(vehId)
  local state = getState(vehId)
  return state and state.isOverSteering or false
end

local function getIsOverMinSpeedForDrift(vehId)
  local state = getState(vehId)
  return state and state.avrgRefPointsKphSpeed and state.avrgRefPointsKphSpeed > driftOptions.minAirSpeed or false
end

local function getIsInTheAir(vehId)
  local state = getState(vehId)
  return state and state.isInTheAir or false
end

local function getIsCrashing(vehId)
  local state = getState(vehId)
  return state and state.isCrashing or false
end

local function doesPlHaveVeh(vehId)
  local state = getState(vehId)
  return state and state.vehData ~= nil
end

local function getDriftOptions()
  return driftOptions
end

local function getVehCorners()
  return {corner_FR, corner_BR, corner_BL, corner_FL}
end

local function getGC()
  return gc
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function setAllowDonut(value)
  driftOptions.allowDonut = value
end

local function setAllowTightDrift(value)
  driftOptions.allowTightDrifts = value
end

local function setVehId(newVehId)
  for id, _ in pairs(trackedVehicles) do
    if id ~= newVehId then
      removeTrackedVehicle(id)
    end
  end
  addTrackedVehicle(newVehId)
end

local function setBalanceMode(_balanceMode, vehId)
  local state = getState(vehId)
  if state then state.balanceMode = _balanceMode end
end

--------- HOOKS -----------

local function reset(vehId)
  if vehId then
    local state = trackedVehicles[vehId]
    if state then resetVehicleState(state) end
  else
    for _, state in pairs(trackedVehicles) do
      resetVehicleState(state)
    end
  end
end

local function onVehicleSwitched(oldId, newVehId, player)
  player = player or 0
  if oldId and oldId ~= -1 then
    -- only untrack the vehicle this player was actually driving, otherwise a
    -- second seat entering a vehicle would evict the other players' vehicles
    local oldState = trackedVehicles[oldId]
    if oldState and oldState.playerId == player then
      removeTrackedVehicle(oldId)
    end
  end
  if newVehId and newVehId ~= -1 then
    local state = addTrackedVehicle(newVehId, {playerId = player})
    if state then state.currResetTimer = resetTimer end
  end
end

local function onVehicleDestroyed(vehId)
  removeTrackedVehicle(vehId)
end

local function onClientEndMission()
  table.clear(trackedVehicles)
end

local function onAnyStuntZoneAccomplished()
  local state = getState()
  if state and state.currDriftCompleteTime then
    state.currDriftCompletedTimer = state.currDriftCompleteTime
  end
end

local function onDriftContextChanged(context, oldContext)
  if oldContext ~= context then
    if context ~= "inAnotherMissionType" then
      for _, state in pairs(trackedVehicles) do
        if state.vehId and not gameplay_util_crashDetection.isVehTracked(state.vehId) and state.vehId > -1 then
          gameplay_util_crashDetection.addTrackedVehicleById(state.vehId, crashDetectionSettings, "drift")
        end
      end
    elseif context == "inAnotherMissionType" then
      for _, state in pairs(trackedVehicles) do
        gameplay_util_crashDetection.removeTrackedVehicleById(state.vehId)
      end
    end
  end
end

local function onDriftChallengeFinished()
  for _, state in pairs(trackedVehicles) do
    if state.driftChainActiveData ~= nil then
      extensions.hook('onDriftCompleted', {
        chainDriftData = state.driftChainActiveData,
        vehId = state.vehId
      })
    end
    if state.isDrifting then
      extensions.hook("onDriftActiveDataFinished", state.driftActiveData, state.vehId)
    end
  end
end

local function onVehicleCrashStarted(crashStartData)
  if gameplay_walk.isWalking() or gameplay_drift_general.getPaused() or gameplay_drift_general.getFrozen() or dtSim <= 0 then return end
  if crashStartData.vehId == nil then return end

  local state = trackedVehicles[crashStartData.vehId]
  if not state then return end

  local score = gameplay_drift_scoring.getScore(state.vehId)
  if score and score.cachedScore and score.cachedScore > 0 then
    state.crashed = true
  end
end

local function onDriftPlVehReset(vehId)
  if vehId then
    local state = trackedVehicles[vehId]
    if state then
      resetVehicleState(state)
      state.currResetTimer = resetTimer
    end
  else
    for _, state in pairs(trackedVehicles) do
      resetVehicleState(state)
      state.currResetTimer = resetTimer
    end
  end
end

local function onSerialize()
  return {
    debugToggleSmothnessGraph = debugToggleSmothnessGraph[0],
  }
end

local function onDeserialized(data)
  debugToggleSmothnessGraph = im.BoolPtr(data.debugToggleSmothnessGraph)
end

M.onUpdate = onUpdate
M.onVehicleCrashStarted = onVehicleCrashStarted
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onDriftPlVehReset = onDriftPlVehReset
M.onDriftContextChanged = onDriftContextChanged
M.onAnyStuntZoneAccomplished = onAnyStuntZoneAccomplished
M.onDriftChallengeFinished = onDriftChallengeFinished
M.reset = reset

M.getDriftActiveData = getDriftActiveData
M.getDriftChainActiveData = getDriftChainActiveData
M.getVehId = getVehId
M.getVehVel = getVehVel
M.getDriftChainChainedDrifts = getDriftChainChainedDrifts
M.getPlVeh = getPlVeh
M.getVehData = getVehData
M.getIsDrifting = getIsDrifting
M.getDriftOptions = getDriftOptions
M.getAirSpeed = getAirSpeed
M.getDistSinceLastFrame = getDistSinceLastFrame
M.getVehPos = getVehPos
M.getAngleDiff = getAngleDiff
M.getVehCorners = getVehCorners
M.getCurrDriftCompletedTime = getCurrDriftCompletedTime
M.getCurrDegAngleSigned = getCurrDegAngleSigned
M.getIsCrashing = getIsCrashing
M.getDriftDebugInfo = getDriftDebugInfo
M.getGC = getGC
M.getCurrentDriftDuration = getCurrentDriftDuration
M.getIsOverSteering = getIsOverSteering
M.getIsOverMinSpeedForDrift = getIsOverMinSpeedForDrift
M.getIsInTheAir = getIsInTheAir

M.doesPlHaveVeh = doesPlHaveVeh

M.addTrackedVehicle = addTrackedVehicle
M.removeTrackedVehicle = removeTrackedVehicle
M.getTrackedVehicles = getTrackedVehicles
M.getPlayerIdForVehicle = getPlayerIdForVehicle

M.setVehId = setVehId
M.setAllowTightDrift = setAllowTightDrift
M.setAllowDonut = setAllowDonut
M.setBalanceMode = setBalanceMode

M.simulateADrift = simulateADrift
return M
