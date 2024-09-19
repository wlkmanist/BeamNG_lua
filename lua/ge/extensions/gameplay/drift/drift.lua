local M = {}

local im = ui_imgui
local vehId
local resetFlag = false

local currDriftCompletedTime = 0
local currFailPointsCooldown = 0
local isDrifting
local isChainingDrifts
local isCrashing
local lastFrameIsDrifting
local currDegAngle
local lastDriftTimer = 0
local resetTimer = 0.1
local currResetTimer = 0
local score
local driftChainActiveData = nil -- data about a whole chain of drifts
local driftActiveData = nil -- data about a single drift
local frontPoint = {} -- arbitrary points placed behind and in front of the car to detect a drift
local rearPoint = {} -- arbitrary points placed behind and in front of the car to detect a drift

local driftOptions = {
  minAngle = 5,
  maxAngle = 165, -- cheap anti cheese
  allowDonut = false,
  allowTightDrifts = true,
  totalDriftAngleModulo = true,
  raycastHeight = 0.5,
  raycastDist = 1.8,
  raycastInwardOffset = 0.650,
  wallDetectionLength = 2,
  driftCompletedTime = 1.2,
  failPointsCooldown = 1,
  minAirSpeed = 10,
  maxWasDriftingTime = 4, -- used to detect spinouts
  crashDamageThreshold = 150
}

local function reset()
  driftActiveData = nil
  resetFlag = true
  isDrifting = false
end

--------- GARBAGE COLLECTION VARIABLES -----------
local velDir = vec3(0,0,0)
local isInTheAir
local wallMulti
local veh
local vehData
local driftAngleDiff
local dir = vec3()
local pos = vec3()
local hitDist
local hitPos = vec3()
local dirVec = vec3()
local radAngle
local corner_FL = vec3()
local corner_FR = vec3()
local corner_BR = vec3()
local corner_BL = vec3()
local center = vec3()
local frontCenter = vec3()
local rearCenter = vec3()
local kphAirSpeed
local up = vec3(0,0,1)
local vecZero = vec3(0,0,0)
local tempVec = vec3(0,0,0)
local avrgRefPointsKphSpeed -- instead of picking the car speed, we use two off-centered ones
local frontDot -- calculate the front reference point's velocity dot product with vehicle dir
local centerDot -- calculate the center reference point's velocity dot product with vehicle dir
local rearDot -- calculate the rear reference point's velocity dot product with vehicle dir
--------------------------------------------------

local function newDriftActiveData(vehicleData)
  driftActiveData = {
    closestWallDistanceFront = 0,
    closestWallDistanceRear = 0,
    currDegAngle = 0,
    direction = nil,
    lastFrameVelDir = vec3(velDir),
    totalDriftAngle = 0,
    totalDriftTime = 0,
    angleVelocity = 0,
    angles = {},
    speeds = {},
    totalDonutsInRow = 0,
    lastPos = vec3(vehicleData.pos),
    avgDriftAngle = 0,
    driftUniformity = 0,
  }
end

local function newDriftChainActiveData()
  driftChainActiveData = {
    totalDriftDistance = 0,
    totalDriftTime = 0,
    rightDrifts = 0,
    leftDrifts = 0,
    chainedDrifts = 0,
    currentCircleDrift = { -- 360 drifts
      totalAngle = 0
    }
  }
end

local raycastHeightVec = vec3()
local norm = vec3()
local function throwRaycast(startPosition, direction)
  raycastHeightVec:set(0,0, driftOptions.raycastHeight)
  dir:setSub2(direction, startPosition)
  norm:set(push3(dir):normalized())
  pos:setAdd2(direction, push3(raycastHeightVec) - push3(norm) * driftOptions.raycastInwardOffset)

  hitDist = castRayStatic(pos, dir, driftOptions.wallDetectionLength)
  hitPos:setAdd2(pos, push3(norm) * hitDist)

  if gameplay_drift_general.getDebug() then
    debugDrawer:drawLine(pos, hitPos, ColorF(0,1,1,1))
    debugDrawer:drawSphere(hitPos, 0.2, ColorF(0,0.3,1,0.3))
  end
  return hitDist
end


local velocityTip = vec3(0,0,0)
local function calculateDriftAngle(vehData)
  dirVec:set(vehData.dirVec)

  radAngle = math.acos(dirVec:dot(vehData.vel:normalized()) / (dirVec:length() * vehData.vel:normalized():length()))
  currDegAngle = math.deg(radAngle)

  if gameplay_drift_general.getDebug() then
    debugDrawer:drawLine(center, center + dirVec, ColorF(1,0,0,1))
    velocityTip:set(center + vehData.vel:normalized())
    debugDrawer:drawLine(center, velocityTip, ColorF(1,0.3,0,1))
    debugDrawer:drawTextAdvanced(velocityTip, string.format("%d ° (req:%d)", currDegAngle, driftOptions.minAngle), ColorF(1,1,1,1), true, false, ColorI(0,0,0,255))
  end
end

local halfAxis0 = vec3()
local halfAxis1 = vec3()
local halfAxis2 = vec3()
local oobbCenter = vec3()
local function calculateVehCenterAndWheels()
  halfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  halfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  halfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))
  oobbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  corner_FL:set(-push3(halfAxis1)+push3(oobbCenter)+push3(halfAxis0)-push3(halfAxis2))
  corner_FR:set(-push3(halfAxis1)+push3(oobbCenter)-push3(halfAxis0)-push3(halfAxis2))
  corner_BR:set(push3(halfAxis1)+push3(oobbCenter)+push3(halfAxis0)-push3(halfAxis2))
  corner_BL:set(push3(halfAxis1)+push3(oobbCenter)-push3(halfAxis0)-push3(halfAxis2))
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

local heightOffset = vec3(0,0,0.3)
local percentages = {0, 0.15, 0.30, 0.50, 0.70, 0.85, 1}
local minFront
local min
local function calculateDistWall()
  -- front needs more raycasts for tight donuts
  minFront = math.huge
  for _, percent in ipairs(percentages) do
    tempVec:set(lerp(corner_FR, corner_FL, percent))
    min = throwRaycast(frontCenter, tempVec)
    if min < minFront then minFront = min end
  end
  driftActiveData.closestWallDistanceFront = minFront

  -- rear doesn't need to be as accurate as the front
  driftActiveData.closestWallDistanceRear = math.min(
    throwRaycast(rearCenter, corner_BL),
    throwRaycast(rearCenter, corner_BR)
  )
end

local function driftFailed()
  currFailPointsCooldown = driftOptions.failPointsCooldown
end

local minDamageThreshold = 10
local damageAtStart = 0
local lastFrameDamage = 0
local frameDelay = 30
local currFrameDelay = 0
local damageTaken = 0
local thisFrameDamage = 0
local function manageDamages(vehData, dtSim) --counts the total damage throughout frames of one crash
  if not vehData.damage then return end

  thisFrameDamage = vehData.damage
  --Beginning of a crash
  if thisFrameDamage > (lastFrameDamage + minDamageThreshold) and not isCrashing then
    isCrashing = true
    damageAtStart = thisFrameDamage
  end

  if thisFrameDamage == lastFrameDamage and isCrashing then
    currFrameDelay = currFrameDelay + 1
    if currFrameDelay == frameDelay then -- we consider end of a crash when the vehicle hasn't taken any damage for x frames

      damageTaken = vehData.damage - damageAtStart
      if damageTaken >= driftOptions.crashDamageThreshold then
        if currFailPointsCooldown <= 0 then
          extensions.hook('onDriftCrash', score.cachedScore > 0)
          driftFailed()
        end
      end

      isCrashing = false
      damageAtStart = 0
      currFrameDelay = 0
    end
  end
  lastFrameDamage = vehData.damage
end

local totalAngle = 0
local function detectCircleDrift()
  if isChainingDrifts then
    if isDrifting then
      driftChainActiveData.currentCircleDrift.totalAngle = driftChainActiveData.currentCircleDrift.totalAngle + driftAngleDiff
    else
    end
  end
end

local minSpeedAllowed = 1.5
local minAllowedAngle = 110
local stopSpinoutCheck = false
local function detectSpinout()
  if currFailPointsCooldown > 0 or isCrashing then return end -- to avoid the message "drift failed : spinout" to appear before crashing
  if kphAirSpeed < minSpeedAllowed then
    if currDegAngle > minAllowedAngle and not stopSpinoutCheck then
      driftFailed()
      extensions.hook("onDriftSpinout")
    end
    if lastDriftTimer < driftOptions.maxWasDriftingTime then
      stopSpinoutCheck = true -- at low speed, "currDegAngle" goes crazy, so we check only once otherwise the player will always "spinout"
    end
  end
end

local distFromCenter = 4
local function updateReferencePoint(point)
  if gameplay_drift_general.getDebug() then
    debugDrawer:drawSphere(point.pos + up, 0.2, ColorF(1,0.3,1,0.3))
  end
  if point.lastFramePos then
    point.vel = (point.pos - point.lastFramePos)
    if gameplay_drift_general.getDebug() then
      debugDrawer:drawLineInstance(point.pos + up, up + point.pos + point.vel:normalized(), 3, ColorF(1,0.3,0,1))
    end
  else
    point.lastFramePos = vec3()
  end
  point.lastFramePos:set(point.pos.x, point.pos.y, point.pos.z)
end

local function isAngledForDrift()
  frontPoint.pos = center + dirVec * distFromCenter
  rearPoint.pos = center - dirVec * distFromCenter
  updateReferencePoint(frontPoint)
  updateReferencePoint(rearPoint)

  if frontPoint.vel and vehData then
    avrgRefPointsKphSpeed = ((frontPoint.vel:length() + rearPoint.vel:length()) / 2) * 520
    frontDot = frontPoint.vel:dot(dirVec:cross(up))
    centerDot = velDir:dot(dirVec:cross(up))
    rearDot = rearPoint.vel:dot(dirVec:cross(up))

    return
    frontDot < 0 and centerDot > 0 or centerDot < 0 and frontDot > 0
    or frontDot > 0 and centerDot > 0 and rearDot > 0 or frontDot < 0 and centerDot < 0 and rearDot < 0
  end
end

local oldIsDrifting
local inTheAirTop = vec3(0,0,0)
local inTheAirBottom = vec3(0,0,0)
local airOffset = vec3(0,0,0.5)

local vec3DistDiff = vec3(0,0,0)
local function detectAndGatherDriftInfo(vehicleData, dtSim)
  inTheAirBottom:setAdd2(center, -push3(airOffset))
  inTheAirTop:setAdd2(center, airOffset)

  velDir:set(push3(vehicleData.vel):normalized())

  isInTheAir = throwRaycast(inTheAirTop, inTheAirBottom) > 0.9

  isDrifting =
  isAngledForDrift()
  and currDegAngle > driftOptions.minAngle and currDegAngle < driftOptions.maxAngle
  and avrgRefPointsKphSpeed > driftOptions.minAirSpeed
  and not gameplay_walk.isWalking()
  and not isInTheAir
  and currFailPointsCooldown <= 0
  and currResetTimer <= 0

  if isDrifting then
    if driftChainActiveData == nil then
      newDriftChainActiveData()
    end

    if driftActiveData == nil then
      newDriftActiveData(vehicleData)

      if velDir:dot(vehicleData.dirVec:normalized():cross(up)) < 0 then
        driftChainActiveData.rightDrifts = driftChainActiveData.rightDrifts + 1
        driftActiveData.direction = "right"
      else
        driftChainActiveData.leftDrifts = driftChainActiveData.leftDrifts + 1
        driftActiveData.direction = "left"
      end
      driftChainActiveData.chainedDrifts = driftChainActiveData.chainedDrifts + 1
      stopSpinoutCheck = false

      extensions.hook("onDriftStatusChanged", true)
    end

    currDriftCompletedTime = driftOptions.driftCompletedTime

    driftAngleDiff = math.deg(math.acos(velDir:cosAngle(driftActiveData.lastFrameVelDir))) -- angle in deg

    driftActiveData.angleVelocity = driftAngleDiff / dtSim
    driftActiveData.totalDriftAngle = driftActiveData.totalDriftAngle + driftAngleDiff
    driftActiveData.lastFrameVelDir:set(velDir)
    driftActiveData.totalDriftTime = driftActiveData.totalDriftTime + dtSim

    -- total drifting distance
    vec3DistDiff:setSub2(driftActiveData.lastPos, vehicleData.pos)
    driftChainActiveData.totalDriftDistance = driftChainActiveData.totalDriftDistance + vec3DistDiff:length()
    driftActiveData.lastPos:set(vehicleData.pos)

    -- total drift time
    driftChainActiveData.totalDriftTime = driftChainActiveData.totalDriftTime + dtSim

    table.insert(driftActiveData.angles, currDegAngle)
    table.insert(driftActiveData.speeds, kphAirSpeed)
    -- avg drift angle
    local sum = 0
    for _, v in ipairs(driftActiveData.angles) do sum = sum + v end
    driftActiveData.avgDriftAngle = sum / #driftActiveData.angles

    lastDriftTimer = 0
  else
    if driftActiveData then --if just stopped drifting
      extensions.hook("onDriftStatusChanged", false)
      driftActiveData = nil
    end

    lastDriftTimer = lastDriftTimer + dtSim
  end

  isChainingDrifts = driftChainActiveData ~= nil

  lastFrameIsDrifting = isDrifting
end

local function driftCoolDown(dtSim)
  if currDriftCompletedTime > 0 then
    currDriftCompletedTime = currDriftCompletedTime - dtSim
    if currDriftCompletedTime < 0 and score.cachedScore > 0 then
      extensions.hook('onDriftCompleted', {
        chainDriftData = driftChainActiveData
      })

      driftChainActiveData = nil
    end
  end
end

-- "near" a wall is speed sensitive
local function adaptWallDetectionDistToSpeed()
  driftOptions.wallDetectionLength = linearScale(kphAirSpeed, 0, 150, 2, 4)
end

local function imguiDebug()
  if gameplay_drift_general.getDebug() then
    if im.Begin("Drift detection") then
      im.Text("Is drifting : " .. ((isDrifting and "Yes") or "No"))
      im.Text("Is crashing : " .. ((isCrashing and "Yes") or "No"))
      im.Text("Is in the air : " .. ((isInTheAir and "Yes") or "No"))
      im.Text(string.format("Air speed : %d kph", kphAirSpeed or 0))
      im.Text(string.format("Min required angle : %0.2f", driftOptions.minAngle or 0))
      im.Text(string.format("Time to confirmation : %0.2f", currDriftCompletedTime))

      if isDrifting then
        im.Text(string.format("Angle : %d °", currDegAngle))
        im.Text(string.format("Total drift distance : %d", driftChainActiveData.totalDriftDistance))
        im.Text(string.format("Average drift angle : %d", driftActiveData.avgDriftAngle))
        im.Text(string.format("Wall distance front : %f", driftActiveData.closestWallDistanceFront))
        im.Text(string.format("Wall distance rear : %f", driftActiveData.closestWallDistanceRear))
      end
    end
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  imguiDebug()
  if gameplay_drift_general.getContext() == "stopped" or gameplay_drift_general.getFrozen() then return end

  score = gameplay_drift_scoring.getScore()

  if not resetFlag then reset() end

  if vehId and not veh then
    veh = scenetree.findObjectById(vehId)
  else
    veh = getPlayerVehicle(0)
  end

  isDrifting = false

  if not veh then return end
  vehId = veh:getId()

  vehData = map.objects[vehId]
  if not vehData then return end
  kphAirSpeed = vehData.vel:length() * 3.6

  calculateVehCenterAndWheels()
  calculateDriftAngle(vehData)
  manageDamages(vehData, dtSim)

  if not isDrifting and (score.cachedScore or 0) > 0 then
    detectSpinout()
  end
  detectAndGatherDriftInfo(vehData, dtSim)
  detectCircleDrift()

  if isDrifting then
    adaptWallDetectionDistToSpeed()
    calculateDistWall()

    driftActiveData.currDegAngle = currDegAngle
  else
    driftCoolDown(dtSim)
  end
  if currFailPointsCooldown > 0 then
    currFailPointsCooldown = currFailPointsCooldown - dtSim
  end

  if currResetTimer > 0 then
    currResetTimer = currResetTimer - dtSim
  end
end

local function getDriftActiveData()
  return driftActiveData
end

local function setAllowDonut(value)
  driftOptions.allowDonut = value
end

local function setAllowTightDrift(value)
  driftOptions.allowTightDrifts = value
end

local function setVehId(newVehId)
  vehId = newVehId
end

local function getVehId()
  return vehId
end

local function getIsDrifting()
  return isDrifting
end

local function getDriftOptions()
  return driftOptions
end

local function getVehCorners()
  return {corner_FR, corner_BR, corner_BL, corner_FL}
end

local function getAirSpeed()
  return kphAirSpeed
end

local function getVehPos()
  if M.doesPlHaveVeh() then
    return vehData.pos
  end
end

local function getAngleDiff()
  return driftAngleDiff
end

local function onVehicleSwitched(oldId, newVehId)
  vehId = newVehId
end

local function onDriftGeneralContextChanged(newContext)
  if newContext == "stopped" then isDrifting = false end
end

local function onDriftPlVehReset()
  reset()
  currResetTimer = resetTimer
end

local function doesPlHaveVeh()
  return vehData ~= nil
end

M.onUpdate = onUpdate
M.onVehicleSwitched = onVehicleSwitched
M.onDriftGeneralContextChanged = onDriftGeneralContextChanged
M.onDriftPlVehReset = onDriftPlVehReset

M.reset = reset

M.getDriftActiveData = getDriftActiveData
M.getVehId = getVehId
M.getIsDrifting = getIsDrifting
M.getDriftOptions = getDriftOptions
M.getAirSpeed = getAirSpeed
M.getVehPos = getVehPos
M.getAngleDiff = getAngleDiff
M.getVehCorners = getVehCorners

M.doesPlHaveVeh = doesPlHaveVeh

M.setVehId = setVehId
M.setAllowTightDrift = setAllowTightDrift
M.setAllowDonut = setAllowDonut

return M