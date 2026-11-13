-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local dequeue = require('dequeue')

local M = {}
M.recoveryPoints = dequeue.new() -- historic log of positions
-- When enabled, recovery input emits recovery hooks without changing the vehicle.
-- This is used in the First Drive tutorial to preview the recovery process without changing the vehicle.
M.recoveryHooksOnly = false

local recoveryPointTimedelta = 0.2 -- secs
local recoveredPointSeparation = 2
local recoveredPointSeparationSq = recoveredPointSeparation * recoveredPointSeparation
local initialRecoverySpeed = 3 -- m/s
local slowRecoverySpeed = 20 -- m/s
local fastRecoverySpeed = 50 -- m/s
local slowRecoveryRampTime = 2.5 -- secs
local fastRecoveryRampTime = 10 -- secs
local logSize = 700
local rollLimit = 45
local pitchLimit = 80
local rewindPositionDelay = 0.5
local debugColor = color(255, 102, 0, 255)

local countDown = 0 -- simDt
local rewindDistance = 0
local recoverySpeedTimer = 0
local pendingRecoveryPointAhead = false
local snapshotTimeSmoother = newTemporalSmoothing(0.0815)
local useSmartSpawn = true
local upVector = vec3(0,0,1)
local recoverTimer
local rewindPosition
local beamsCount = 0

local relativeNodePositions = {}

local lastRecoveryPoint = {
  pos = vec3(),
  dirFront = vec3(),
  dirUp = vec3(),
  set = false,
}

local objPos = vec3()

M.updateGFX = nop

local function clear()
  M.recoveryPoints = dequeue.new()
  M.homePoint = nil
  lastRecoveryPoint.set = false
end

local function onDeserialized(v)
  tableMerge(M, v)
  M.recoveryPoints = dequeue.new(v.recoveryPoints)
end

local function newRecoveryPoint(objPosition)
  if objPosition then
    objPosition = vec3(objPosition)
  else
    objPosition = vec3(obj:getPositionXYZ())
  end
  return {
    pos = objPosition,
    dirFront = obj:getDirectionVector(),
    dirUp = obj:getDirectionVectorUp()
  }
end

local function copyRecoveryPoint(src)
  lastRecoveryPoint.pos:set(src.pos)
  lastRecoveryPoint.dirFront:set(src.dirFront)
  lastRecoveryPoint.dirUp:set(src.dirUp)
  lastRecoveryPoint.set = true
end

local function blendRecoveryPoints(a, b, t)
  lastRecoveryPoint.pos:setSub2(b.pos, a.pos)
  lastRecoveryPoint.pos:setScaled(t)
  lastRecoveryPoint.pos:setAdd(a.pos)

  lastRecoveryPoint.dirFront:setSub2(b.dirFront, a.dirFront)
  lastRecoveryPoint.dirFront:setScaled(t)
  lastRecoveryPoint.dirFront:setAdd(a.dirFront)
  lastRecoveryPoint.dirFront:normalize()

  lastRecoveryPoint.dirUp:setSub2(b.dirUp, a.dirUp)
  lastRecoveryPoint.dirUp:setScaled(t)
  lastRecoveryPoint.dirUp:setAdd(a.dirUp)
  lastRecoveryPoint.dirUp:normalize()

  lastRecoveryPoint.set = true
end

local function getRollPitch(dirFront, dirUp)
  -- find vehicle roll and pitch, in degrees, 0deg being normal upright rotation, +/-180deg being on its roof
  local dirLeft = dirUp:cross(dirFront)
  local roll  = math.deg(math.asin(dirLeft.z))
  local pitch = math.deg(math.asin(dirFront.z))
  if dirUp.z < 0 then -- if we are closer to upside down than to downside up
    -- detect the "on its roof" situation, where angles are zero, and make sure they go all the way to 180deg instead, like this:
    -- original rotation angles:  0deg (ok), 90deg (halfway),      0deg (on its roof), -90deg (halfway), 0deg (ok)
    -- corrected rotation angles: 0deg (ok), 90deg (halfway), +/-180deg (on its roof), -90deg (halfway), 0deg (ok)
    roll  = sign( roll)*(180 - math.abs( roll))
    pitch = sign(pitch)*(180 - math.abs(pitch))
  end
  --log("D", "recovery", "Roll: "..r(roll,2,2)..", Pitch: "..r(pitch,2,2)..", dirUp: "..s(recPoint.dirUp, 2,2))
  return roll, pitch
end

local function constructAABB()
  local pmin = vec3(math.huge, math.huge, math.huge)
  local pmax = vec3(-math.huge, -math.huge, -math.huge)
  local nodes = v.data.nodes
  for i = 0, tableSizeC(nodes) - 1 do
    local pos = nodes[i].pos
    pmax:setMax(pos)
    pmin:setMin(pos)
  end

  local refPos = vec3(nodes[v.data.refNodes[0].ref].pos)
  pmin = pmin - (refPos)
  pmax = pmax - (refPos)

  -- One corner point plus the neighboring points
  return {
      vec3(pmin.x, pmin.y, pmin.z),
      vec3(pmin.x, pmin.y, pmax.z),
      vec3(pmin.x, pmax.y, pmin.z),
      vec3(pmax.x, pmin.y, pmin.z)
    }
end

local mpRecoveringRequestId = nil
local recoveringBeginPending = false
local stopRequested = false
local stopRequestedPlayer = nil
local camPos = vec3()
local camRot = quat()

local function recoveryRotation(dirFront, dirUp)
  -- if the angle limits (in degrees) are surpassed, car is reset to upright position, maintaining the recpoint heading
  local roll, pitch = getRollPitch(dirFront, dirUp)
  if pitchLimit ~= nil and (math.abs(pitch) > pitchLimit or math.abs(roll) > rollLimit) then
    return quatFromDir(-dirFront, upVector)
  end
  return quatFromDir(-dirFront, dirUp)
end

local function applyRecoveryPoint(recPoint, useSmartSpawnParam, player, moveTraffic)
  local pos = recPoint.pos
  local dirFront = recPoint.dirFront
  local dirUp = recPoint.dirUp
  local smart = useSmartSpawnParam
  if smart == nil then smart = useSmartSpawn end

  if smart then
    local rot = quatFromDir(dirFront, dirUp)
    obj:queueGameEngineLua(string.format(
      "spawn.safeTeleport(getObjectByID(%d), vec3(%f,%f,%f), quat(%f,%f,%f,%f), nil, nil, %s, nil, true, %s)",
      obj:getId(),
      pos.x, pos.y, pos.z,
      rot.x, rot.y, rot.z, rot.w,
      tostring(moveTraffic), tostring(player)))
    return
  end

  local rot = recoveryRotation(dirFront, dirUp)
  obj:queueGameEngineLua(string.format(
    "vehicleSetPositionRotation(%d, %f, %f, %f, %f, %f, %f, %f)",
    obj:getId(),
    pos.x, pos.y, pos.z,
    rot.x, rot.y, rot.z, rot.w))
end

local function mpApplyRecoveryPoint(requestId, action, px, py, pz, fx, fy, fz, ux, uy, uz, useSmartSpawnParam, player, moveTraffic)
  local pos = vec3(px, py, pz)
  local dirFront = vec3(fx, fy, fz)
  local dirUp = vec3(ux, uy, uz)
  local smart = useSmartSpawnParam
  if smart == nil then smart = useSmartSpawn end
  local vid = obj:getId()
  local finishCmd
  if smart then
    finishCmd = string.format(
      "if multiplayer_vehicleSync then multiplayer_vehicleSync.onVehicleRecoveryApplied(%d, %q, %d, true) end",
      requestId, action, vid)
    local rot = quatFromDir(dirFront, dirUp)
    obj:queueGameEngineLua(string.format(
      "spawn.safeTeleport(getObjectByID(%d), vec3(%f,%f,%f), quat(%f,%f,%f,%f), nil, nil, %s, nil, true, %s); %s",
      vid,
      pos.x, pos.y, pos.z,
      rot.x, rot.y, rot.z, rot.w,
      tostring(moveTraffic), tostring(player),
      finishCmd))
    return
  end

  local rot = recoveryRotation(dirFront, dirUp)
  finishCmd = string.format(
    "if multiplayer_vehicleSync then multiplayer_vehicleSync.onVehicleRecoveryApplied(%d, %q, %d, false, %f, %f, %f, %f, %f, %f, %f) end",
    requestId, action, vid, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  obj:queueGameEngineLua(string.format(
    "vehicleSetPositionRotation(%d, %f, %f, %f, %f, %f, %f, %f); %s",
    vid,
    pos.x, pos.y, pos.z,
    rot.x, rot.y, rot.z, rot.w,
    finishCmd))
end

local function setRecoveryPoint(recPoint, resetVehicle, moveTraffic, player)
  copyRecoveryPoint(recPoint)

  if resetVehicle then
    applyRecoveryPoint(lastRecoveryPoint, useSmartSpawn, player, moveTraffic)
  end
end

local function saveHome(point)
  M.homePoint = point or newRecoveryPoint()
  if point == nil then
    guihooks.message("vehicle.recovery.saveHome", 5, "recovery")
  end
end

local function updateGFXRecord(dtSim)
  if stopRequested and not recoveringBeginPending then
    stopRequested = false
    stopRequestedPlayer = nil
  end

  countDown = countDown - dtSim
  if countDown <= 0 then
    countDown = countDown + recoveryPointTimedelta
    if M.recoveryPoints:is_empty() then
      local startPoint = newRecoveryPoint()
      if M.homePoint == nil then
        saveHome(startPoint)
      end
      M.recoveryPoints:push_right(startPoint)
      return
    end

    objPos.x, objPos.y, objPos.z = obj:getPositionXYZ()
    if M.recoveryPoints:peek_right().pos:squaredDistance(objPos) < recoveredPointSeparationSq then
      return -- too close to last recovered point
    end

    while M.recoveryPoints:length() >= logSize do  -- remove old positions
      M.recoveryPoints:pop_left()
    end
    M.recoveryPoints:push_right(newRecoveryPoint(objPos))
  end
end

local function cancelRecoveringPreview()
  mpRecoveringRequestId = nil
  recoveringBeginPending = false
  stopRequested = false
  stopRequestedPlayer = nil
  if M.updateGFX == updateGFXRecord then return end
  material.forceReset()
  M.updateGFX = updateGFXRecord
  obj:queueGameEngineLua(string.format("if core_recoveryCamera then core_recoveryCamera.endRecoveryCamera(%d) end", obj:getId()))
  rewindPosition = false
  pendingRecoveryPointAhead = false
  lastRecoveryPoint.set = false
end

local function stopRecovering(player)
  if M.recoveryHooksOnly then
    obj:queueGameEngineLua('extensions.hook("onStopRecovering", 0)')
    return
  end
  stopRequested = true
  stopRequestedPlayer = player
end

local function afterStopRecovering(timer)
  timer = tonumber(timer) or recoverTimer or 0
  obj:queueGameEngineLua('getObjectByID('..tostring(obj:getId())..'):resetBrokenFlexMesh()')
  obj:queueGameEngineLua('be.nodeGrabber:clearVehicleFixedNodes('..tostring(obj:getId())..')')
  if M.recoveryPoints:is_empty() then
    guihooks.message("vehicle.recovery.end", 5, "recovery", "tow")
  else
    if snapshotTimeSmoother:value() > 0.9 then
      guihooks.message("vehicle.recovery.quick", 7, "recovery", "tow")
    else
      guihooks.message("vehicle.recovery.recovered", 3, "recovery", "tow")
    end
  end
  obj:queueGameEngineLua(string.format("if core_recoveryCamera then core_recoveryCamera.endRecoveryCamera(%d) end", obj:getId()))
  obj:queueGameEngineLua("extensions.hook(\"onStopRecovering\", " .. timer .. ")")
end

local function finishStopRecovering()
  material.forceReset() --here on purpurse, it get called a second type on key up and then it fixed what ever material was stuck
  stopRequested = false
  local player = stopRequestedPlayer
  stopRequestedPlayer = nil

  if pendingRecoveryPointAhead and not M.recoveryPoints:is_empty() then
    M.recoveryPoints:pop_right()
  end
  pendingRecoveryPointAhead = false

  if mpRecoveringRequestId then
    if not lastRecoveryPoint.set then
      cancelRecoveringPreview()
      return
    end
    M.updateGFX = updateGFXRecord
    rewindPosition = false

    obj:queueGameEngineLua(string.format(
      "if multiplayer_vehicleSync then multiplayer_vehicleSync.requestRecoveringCommit(%d, %d, vec3(%f,%f,%f), vec3(%f,%f,%f), vec3(%f,%f,%f), %s, %s, %s) end",
      obj:getId(), mpRecoveringRequestId,
      lastRecoveryPoint.pos.x, lastRecoveryPoint.pos.y, lastRecoveryPoint.pos.z,
      lastRecoveryPoint.dirFront.x, lastRecoveryPoint.dirFront.y, lastRecoveryPoint.dirFront.z,
      lastRecoveryPoint.dirUp.x, lastRecoveryPoint.dirUp.y, lastRecoveryPoint.dirUp.z,
      tostring(useSmartSpawn), tostring(player), tostring(recoverTimer or 0)))

    mpRecoveringRequestId = nil
    lastRecoveryPoint.set = false
    return
  end

  M.updateGFX = updateGFXRecord
  rewindPosition = false
  if lastRecoveryPoint.set then
    applyRecoveryPoint(lastRecoveryPoint, useSmartSpawn, nil, player)
  end
  lastRecoveryPoint.set = false
  afterStopRecovering(recoverTimer)
end

local aabb
local p1, p2, t1, t2, backVec, tempVec = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local oobb = {vec3(), vec3(), vec3(), vec3()}
local rot = quat()
local recoveryCameraOffset = vec3()
local recoveryCameraRot = quat()
local recoveryCameraBasisRot = quat()
local recoveryCameraInitialized = false
local nodeRenderPositions = {}
local nodeRenderPositionsUpToDate = {}

local function initRecoveryCamera()
  backVec:set(lastRecoveryPoint.dirFront)
  backVec.z = 0
  if backVec:squaredLength() < 1e-8 then
    backVec:set(0, 1, 0)
  else
    backVec:normalize()
  end

  tempVec:setScaled2(backVec, -1)
  recoveryCameraBasisRot:setFromDir(tempVec, upVector)
  for i, point in ipairs(aabb) do
    oobb[i]:setRotate(recoveryCameraBasisRot, point)
  end

  recoveryCameraOffset:set((push3(oobb[1])+oobb[4])/2 + push3(upVector) * (oobb[2].z-oobb[1].z) * 1.3 + (push3(oobb[3])-oobb[1]) * 1.5 + push3(tempVec))
  tempVec:setScaled2(recoveryCameraOffset, -1)
  recoveryCameraRot:setFromDir(tempVec, upVector)
  recoveryCameraInitialized = true
end

local function updateGFXRecovery(dtSim)
  if stopRequested then
    finishStopRecovering()
    return
  end

  local dtReal = obj:getRealdt()

  recoverTimer = recoverTimer + dtReal

  if not rewindPosition and recoverTimer > rewindPositionDelay then
    applyRecoveryPoint(lastRecoveryPoint, useSmartSpawn)
    aabb = constructAABB()
    rewindPosition = true
    obj:queueGameEngineLua(string.format("if core_recoveryCamera then core_recoveryCamera.beginRecoveryCamera(%d) end", obj:getId()))
    snapshotTimeSmoother:set(0.2)
    rewindDistance = 0
    recoverySpeedTimer = 0
    recoveryCameraInitialized = false
    guihooks.message("vehicle.recovery.recovering", 5, "recovery", "tow")
  end
  if not rewindPosition then return end

  hydros.resetFFBSmoother()
  local currentRecoverySpeed
  if recoverySpeedTimer < slowRecoveryRampTime then
    local rampProgress = recoverySpeedTimer / slowRecoveryRampTime
    currentRecoverySpeed = initialRecoverySpeed + (slowRecoverySpeed - initialRecoverySpeed) * rampProgress
  elseif recoverySpeedTimer < slowRecoveryRampTime + fastRecoveryRampTime then
    local rampProgress = (recoverySpeedTimer - slowRecoveryRampTime) / fastRecoveryRampTime
    currentRecoverySpeed = slowRecoverySpeed + (fastRecoverySpeed - slowRecoverySpeed) * rampProgress
  else
    currentRecoverySpeed = fastRecoverySpeed
  end
  recoverySpeedTimer = recoverySpeedTimer + dtReal
  --print("Recovery speed: " .. tostring(currentRecoverySpeed) .. " m/s")
  rewindDistance = rewindDistance + currentRecoverySpeed * dtReal
  pendingRecoveryPointAhead = false
  while not M.recoveryPoints:is_empty() do
    local lastRecoveredPoint = M.recoveryPoints:pop_right()  -- pop

    if M.recoveryPoints:is_empty() then
      copyRecoveryPoint(lastRecoveredPoint)
      break
    end

    local nextRecoveryPoint = M.recoveryPoints:peek_right()
    local segmentDistanceSq = lastRecoveredPoint.pos:squaredDistance(nextRecoveryPoint.pos)
    if segmentDistanceSq >= 400 then
      copyRecoveryPoint(nextRecoveryPoint)
      rewindDistance = 0
      break
    end

    local segmentDistance = math.sqrt(segmentDistanceSq)
    if segmentDistance <= 1e-4 then
      copyRecoveryPoint(nextRecoveryPoint)
    elseif rewindDistance >= segmentDistance then
      rewindDistance = rewindDistance - segmentDistance
      copyRecoveryPoint(nextRecoveryPoint)
    else
      M.recoveryPoints:push_right(lastRecoveredPoint)
      blendRecoveryPoints(lastRecoveredPoint, nextRecoveryPoint, rewindDistance / segmentDistance)
      pendingRecoveryPointAhead = rewindDistance > 1e-4
      break
    end
  end
  if M.recoveryPoints:is_empty() then
    stopRecovering()
    finishStopRecovering()
    return
  end
  if lastRecoveryPoint.set and aabb then
    local dirFront = lastRecoveryPoint.dirFront
    local dirUp = lastRecoveryPoint.dirUp

    backVec:setScaled2(dirFront, -1)
    rot:setFromDir(backVec, dirUp)

    for i, point in ipairs(aabb) do
      oobb[i]:setRotate(rot, point)
      oobb[i]:setAdd(lastRecoveryPoint.pos)
    end

    local beams = v.data.beams

    table.clear(nodeRenderPositionsUpToDate)
    for i=0, beamsCount - 1 do
      local beam = beams[i]
      if not nodeRenderPositionsUpToDate[beam.id1] then
        t1:set(relativeNodePositions[beam.id1])
        t1:setRotate(rot)
        p1:setAdd2(lastRecoveryPoint.pos, t1)
        nodeRenderPositionsUpToDate[beam.id1] = true
        nodeRenderPositions[beam.id1]:set(p1)
      end

      if not nodeRenderPositionsUpToDate[beam.id2] then
        t2:set(relativeNodePositions[beam.id2])
        t2:setRotate(rot)
        p2:setAdd2(lastRecoveryPoint.pos, t2)
        nodeRenderPositionsUpToDate[beam.id2] = true
        nodeRenderPositions[beam.id2]:set(p2)
      end

      obj.debugDrawProxy:drawLine(nodeRenderPositions[beam.id1], nodeRenderPositions[beam.id2], debugColor)
    end

    if not recoveryCameraInitialized then
      initRecoveryCamera()
    end
    camPos:setAdd2(lastRecoveryPoint.pos, recoveryCameraOffset)
    camRot:set(recoveryCameraRot)
    obj:queueGameEngineLua(string.format("if core_recoveryCamera then core_recoveryCamera.setRecoveryCameraPosRot(%d, %.9g, %.9g, %.9g, %.9g, %.9g, %.9g, %.9g) end", obj:getId(), camPos.x, camPos.y, camPos.z, camRot.x, camRot.y, camRot.z, camRot.w))
  end
  --obj:setMeshNameAlpha(0.6, "", true) -- fade it away... need to be set here becouse sync issues with reset broken props
end

local function beginRecoveringPreview(useAltMode)
  recoveringBeginPending = false
  if useAltMode == nil then useAltMode = false end
  if M.updateGFX == updateGFXRecovery then return end
  M.updateGFX = updateGFXRecovery
  recoverTimer = 0
  recoveryCameraInitialized = false
  pendingRecoveryPointAhead = false
  useSmartSpawn = useAltMode ~= settings.getValue('enableSmartRecovery', true)

  local newPoint = newRecoveryPoint()
  setRecoveryPoint(newPoint, false)
  M.recoveryPoints:push_right(newPoint)
  obj:queueGameEngineLua("extensions.hook(\"onStartRecovering\")")
end

local function loadHome(moveTraffic)
  if M.homePoint == nil then return end
  local useSmart = settings.getValue('enableSmartRecovery', true)
  obj:queueGameEngineLua(string.format(
    "if multiplayer_vehicleSync then multiplayer_vehicleSync.requestLoadHome(%d, vec3(%f,%f,%f), vec3(%f,%f,%f), vec3(%f,%f,%f), %s, 0, %s) else be:queueObjectLua(%d, 'recovery.loadHomeLocal(%s)') end",
    obj:getId(),
    M.homePoint.pos.x, M.homePoint.pos.y, M.homePoint.pos.z,
    M.homePoint.dirFront.x, M.homePoint.dirFront.y, M.homePoint.dirFront.z,
    M.homePoint.dirUp.x, M.homePoint.dirUp.y, M.homePoint.dirUp.z,
    tostring(useSmart),
    tostring(moveTraffic),
    obj:getId(), tostring(moveTraffic)))
end

local function loadHomeLocal(moveTraffic)
  if M.homePoint == nil then return end
  setRecoveryPoint(M.homePoint, true, moveTraffic)
  guihooks.message("vehicle.recovery.loadHome", 5, "recovery")
end

local function startRecovering(useAltMode)
  if M.recoveryHooksOnly then
    obj:queueGameEngineLua('extensions.hook("onStartRecovering")')
    return
  end
  if useAltMode == nil then useAltMode = false end
  if M.updateGFX == updateGFXRecovery or recoveringBeginPending then return end
  if not multiplayer then
    beginRecoveringPreview(useAltMode)
    return
  end
  recoveringBeginPending = true
  stopRequested = false
  stopRequestedPlayer = nil
  obj:queueGameEngineLua(string.format(
    "if multiplayer_vehicleSync then multiplayer_vehicleSync.requestRecoveringBegin(%d, %s) else be:queueObjectLua(%d, 'recovery.beginRecoveringPreview(%s)') end",
    obj:getId(), tostring(useAltMode), obj:getId(), tostring(useAltMode)))
end

local function onRecoveringBeginAllowed(requestId, useAltMode)
  mpRecoveringRequestId = requestId
  beginRecoveringPreview(useAltMode == true or useAltMode == 'true')
end

local function onRecoveringBeginDenied()
  recoveringBeginPending = false
end

local function recoverInPlace()
  setRecoveryPoint(newRecoveryPoint(), true)
end

local function init(path)
  M.updateGFX = updateGFXRecord
  beamsCount = v.data.beams and tableSizeC(v.data.beams) or 0

  local nodes = v.data.nodes or {}
  table.clear(relativeNodePositions)
  for i = 0, tableSizeC(nodes) - 1 do
    relativeNodePositions[i] = nodes[i].pos - nodes[v.data.refNodes[0].ref].pos
    nodeRenderPositions[i] = vec3()
  end
end

-- public interface
M.init = init
M.startRecovering = startRecovering
M.stopRecovering = stopRecovering
M.beginRecoveringPreview = beginRecoveringPreview
M.onRecoveringBeginAllowed = onRecoveringBeginAllowed
M.onRecoveringBeginDenied = onRecoveringBeginDenied
M.cancelRecoveringPreview = cancelRecoveringPreview
M.saveHome = saveHome
M.loadHome = loadHome
M.loadHomeLocal = loadHomeLocal
M.mpApplyRecoveryPoint = mpApplyRecoveryPoint
M.afterStopRecovering = afterStopRecovering
M.onDeserialized = onDeserialized
M.clear = clear
M.recoverInPlace = recoverInPlace

return M
