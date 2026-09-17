-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: The primary/lead part of the container lock system. Controls the feeling couplers, requests positional information
--from the a detected secondary/follow controller, calculate and applied the alighment forces, initates the lock attachment once ready

local M = {}
M.type = "auxiliary"

local lockStates = {
  feeling = "feeling",
  locking = "locking",
  locked = "locked"
}
local lockState  --global state, indicates if all lock sites are in the locked state or not

local lockSites  --main data of all lock sites
local feelerNodeLockSiteLookup = {} --lookup table to find the lock site index by feeler node id
local lockNodeFeelerLookup = {} --lookup table to find the lock site index by lock node id

local lastFeelerRoundRobinIndex  --index of the last feeler tested in the round robin
local feelerRoundRobinTimer  --timer for the feeler round robin
local feelerRoundRobinTime = 1 / 10 --time in seconds between feeler round robin checks
local containerLockDebugData = {lockSites = {}}

local function syncGlobalLockState()
  local allLocked = true
  for _, lockSite in pairs(lockSites) do
    if lockSite.lockState ~= lockStates.locked then
      allLocked = false
      break
    end
  end
  lockState = allLocked and lockStates.locked or lockStates.feeling
end

local function requestFollowLastLockCouplerPosition(lockSite)
  if lockSite.lockLastCouplerData.connectedObjId and lockSite.lockLastCouplerData.lockCouplerNodeId then
    local cmd = string.format("for _, controller in pairs(controller.getControllersByType('couplings/containerLockFollow')) do controller.requestFollowLastLockCouplerPosition(%d, %q, %d) end", objectId, M.name, lockSite.lockLastCouplerData.lockCouplerNodeId)
    obj:queueObjectLuaCommand(lockSite.lockLastCouplerData.connectedObjId, cmd)
  else
    --if we don't have all necessary data, clear the data out of precaution, this should never happen
    lockSite.lockLastCouplerData = nil
  end
end

local function lastLockCouplerPositionCallback(lockCouplerNodeId, lastLockCouplerPosition)
  for _, lockSite in pairs(lockSites) do
    if lockSite.lockLastCouplerData and lockSite.lockLastCouplerData.lockCouplerNodeId == lockCouplerNodeId then
      lockSite.lockLastCouplerPosition = lastLockCouplerPosition
      return
    end
  end
end

--requess the lock position from the follow controller
local function requestFollowLockCouplerPosition(lockSite)
  if lockSite.feelerConnectedObjId and lockSite.lockSiteId then
    local cmd = string.format("for _, controller in pairs(controller.getControllersByType('couplings/containerLockFollow')) do controller.requestFollowLockCouplerPosition(%d, %q, %d) end", objectId, M.name, lockSite.lockSiteId)
    obj:queueObjectLuaCommand(lockSite.feelerConnectedObjId, cmd)
  end
end

local function lockSitePositionCallback(lockSiteId, lockCouplerPosition, needsVisualLockProp)
  for _, lockSite in pairs(lockSites) do
    if lockSite.lockSiteId == lockSiteId then
      lockSite.followLockCouplerPosition = lockCouplerPosition
      lockSite.needsVisualLockProp = needsVisualLockProp
      return
    end
  end
end

local function setLockSiteFollowAligningForce(lockSite, forceVector)
  if lockSite.feelerConnectedObjId and lockSite.lockSiteId and forceVector then
    local cmd = string.format("for _, controller in pairs(controller.getControllersByType('couplings/containerLockFollow')) do controller.applyAligningForce(%d, %s) end", lockSite.lockSiteId, serialize(forceVector))
    obj:queueObjectLuaCommand(lockSite.feelerConnectedObjId, cmd)
  end
end

local function updateVec3DebugTable(target, vector)
  if vector then
    target.x = vector.x
    target.y = vector.y
    target.z = vector.z
    target.valid = true
    return
  end
  target.x = nil
  target.y = nil
  target.z = nil
  target.valid = false
end

local function updateVec3DebugTableFromSum(target, a, b)
  if a and b then
    target.x = a.x + b.x
    target.y = a.y + b.y
    target.z = a.z + b.z
    target.valid = true
    return
  end
  updateVec3DebugTable(target, nil)
end

local function updateLockSiteDebugData(lockSite, debugData)
  local feelerLatchState = lockSite.feelerCouplerId and obj:getNodeLatch(lockSite.feelerCouplerId) or nil
  local feelerCoupleState = lockSite.feelerCouplerId and obj:getNodeCoupler(lockSite.feelerCouplerId) or nil
  local lockLatchState = lockSite.lockCouplerId and obj:getNodeLatch(lockSite.lockCouplerId) or nil
  local lockCoupleState = lockSite.lockCouplerId and obj:getNodeCoupler(lockSite.lockCouplerId) or nil
  local vehiclePosition = obj:getPosition()
  local localLockPosition = lockSite.lockCouplerId and obj:getNodePosition(lockSite.lockCouplerId) or nil

  debugData.name = lockSite.name
  debugData.lockState = lockSite.lockState
  debugData.feelerLatchState = feelerLatchState
  debugData.feelerCoupleState = feelerCoupleState
  debugData.lockLatchState = lockLatchState
  debugData.lockCoupleState = lockCoupleState
  debugData.isFeelerAttached = lockSite.isFeelerAttached
  debugData.isLockAttached = lockSite.isLockAttached
  debugData.isLockStable = lockSite.isLockStable
  debugData.lockedStableTimer = lockSite.lockedStableTimer
  debugData.stableLockTime = lockSite.stableLockTime
  debugData.isAllowedToLock = lockSite.lockLastCouplerData == nil
  updateVec3DebugTableFromSum(debugData.lockPosition, vehiclePosition, localLockPosition)
  updateVec3DebugTable(debugData.followLockCouplerPosition, lockSite.followLockCouplerPosition)
  updateVec3DebugTable(debugData.lockLastCouplerPosition, lockSite.lockLastCouplerPosition)
  debugData.distanceVerticalLockToCoupler = lockSite.distanceVerticalLockToCoupler
  debugData.distanceHorizontalLockToCoupler = lockSite.distanceHorizontalLockToCoupler
  debugData.aligningForce = lockSite.aligningForce
  debugData.forceConeCoef = lockSite.forceConeCoef
  debugData.forceConeVerticalOffset = lockSite.forceConeVerticalOffset
  debugData.forceConeSlope = lockSite.forceConeSlope
  debugData.forceConeTransitionWidth = lockSite.forceConeTransitionWidth
  debugData.forceConeDeadzoneRadius = lockSite.forceConeDeadzoneRadius
  debugData.feelerRadius = lockSite.feelerRadius
end

local function sendContainerLockDebugData()
  if not streams.willSend("containerLockDebug") then
    return
  end

  for index, lockSite in pairs(lockSites) do
    updateLockSiteDebugData(lockSite, containerLockDebugData.lockSites[index])
  end

  gui.send("containerLockDebug", containerLockDebugData)
end

local function setFeelerCouplerActive(feeler, active)
  if active then
    obj:attachCoupler(feeler.feelerCouplerId, feeler.feelerTag, feeler.feelerStrength, feeler.feelerRadius, feeler.feelerLockRadius, feeler.feelerLatchSpeed, 0)
  else
    obj:detachCoupler(feeler.feelerCouplerId, 0)
  end
end

local function setLockCouplerActive(lockSite, active)
  if active then
    obj:attachCoupler(lockSite.lockCouplerId, lockSite.lockTag, lockSite.lockStrength, lockSite.lockRadius, lockSite.lockLockRadius, lockSite.lockLatchSpeed, 0)
  else
    obj:detachCoupler(lockSite.lockCouplerId, 0)
  end
end

local function lockSiteSetLockState(lockSite, newState)
  lockSite.lockState = newState
  if newState == lockStates.feeling then
    -- Keep stable-lock state until the lock detach event consumes it.
    if not lockSite.isLockAttached then
      lockSite.lockedStableTimer = 0
      lockSite.isLockStable = false
    end
    setFeelerCouplerActive(lockSite, true)
    setLockCouplerActive(lockSite, false)
    lockSite.aligningForceVector = nil
    lockSite.followLockCouplerPosition = nil
  elseif newState == lockStates.locking then
    lockSite.lockedStableTimer = 0
    lockSite.isLockStable = false
    setLockCouplerActive(lockSite, true)
  end
end

local function setLockState(newState)
  if newState == lockStates.feeling then
    for _, lockSite in pairs(lockSites) do
      lockSiteSetLockState(lockSite, lockStates.feeling)
    end
  end
end

local function getInactiveFeelerRoundRobin()
  local isInactive = false
  local firstFeelerTested  --save first feeler tested to avoid infinite loop

  while not isInactive do
    local lockSite
    lastFeelerRoundRobinIndex, lockSite = next(lockSites, lastFeelerRoundRobinIndex) --fetch next feeler in round robin
    --restart round robin if we reached end of table
    if not lockSite then
      lastFeelerRoundRobinIndex = nil
      lastFeelerRoundRobinIndex, lockSite = next(lockSites)
    end

    if firstFeelerTested == lockSite then
      --if we have tested all feelers and none are inactive, return nil
      return nil
    end

    firstFeelerTested = firstFeelerTested or lockSite --save first feeler tested to avoid infinite loop

    --when we are feeling or trying to lock, consider the feeler usable
    if lockSite.lockState == lockStates.feeling or lockSite.lockState == lockStates.locking then
      local feelerNodeLatchState = obj:getNodeLatch(lockSite.feelerCouplerId)
      local feelerNodeCoupleState = obj:getNodeCoupler(lockSite.feelerCouplerId)
      local lockNodeCoupleState = obj:getNodeCoupler(lockSite.lockCouplerId)
      isInactive = feelerNodeLatchState <= 0 and feelerNodeCoupleState <= 0 and lockNodeCoupleState <= 0

      if isInactive then
        return lockSite
      end
    end
  end
  return nil
end

local function updateGFX(dt)
  syncGlobalLockState()

  if lockState == lockStates.feeling then
    --activate feelers in round robin, one per frame if it's inactive or has not found a matching coupler
    feelerRoundRobinTimer = feelerRoundRobinTimer - dt
    if feelerRoundRobinTimer <= 0 then
      feelerRoundRobinTimer = feelerRoundRobinTimer + feelerRoundRobinTime --reset round robin timer

      local inactiveFeeler = getInactiveFeelerRoundRobin() --try to find an inactive feeler to activate
      if inactiveFeeler then
        lockSiteSetLockState(inactiveFeeler, lockStates.feeling) --if we found one, activate it
      end
    end
  end

  local globalPosition = obj:getPosition()

  for _, lockSite in pairs(lockSites) do
    local lockIsVisible = false --electrics values to control lock prop visibility
    local lockIsLocked = false --electrics values to control lock prop locked state

    --if we are not locked and our current couple is different from last couple (including current being nil, aka detached), then we know that we are no longer near the previous locksite and can count down a small timer until we re-enter feeling phase
    if lockSite.lockState == lockStates.feeling or lockSite.lockState == lockStates.locking then
      --if we have data about our last lock, request its position so we can track if we seperated from it
      if lockSite.lockLastCouplerData then
        requestFollowLastLockCouplerPosition(lockSite)
      end
      local leadLockCouplerPosition = globalPosition + obj:getNodePosition(lockSite.lockCouplerId)
      --if we have a position of our last lock, check if we are still near it
      if lockSite.lockLastCouplerPosition then
        local toLock = leadLockCouplerPosition - lockSite.lockLastCouplerPosition
        if toLock:length() > 0.2 then
          --we seperated from our last lock, clear the data, allow for relock to the same one
          lockSite.lockLastCouplerData = nil
          lockSite.lockLastCouplerPosition = nil
        end
      end

      --only allow locking if we seperated from our previous lock
      local isAllowedToLock = lockSite.lockLastCouplerData == nil
      if isAllowedToLock then
        requestFollowLockCouplerPosition(lockSite) -- ask for lock position data from the follow controller
        if lockSite.followLockCouplerPosition then --if we received lock position data from the follow controller
          lockSite.upVector = obj:getNodesVector(lockSite.lockCouplerId, lockSite.verticalReferenceNodeCid):normalized() --calculate up ref vector of the locksite

          local toLock = leadLockCouplerPosition - lockSite.followLockCouplerPosition
          local upComponent = lockSite.upVector * toLock:dot(lockSite.upVector)
          local alignmentDirection = toLock - upComponent -- calculate the horizontal component for use in the alignment force
          --calculate the distance between the the lock and the feeler along the upright direction
          lockSite.distanceVerticalLockToCoupler = toLock:dot(lockSite.upVector)
          lockSite.distanceHorizontalLockToCoupler = alignmentDirection:length()
          local forceConeRadius = lockSite.forceConeDeadzoneRadius
          if lockSite.distanceVerticalLockToCoupler > lockSite.forceConeVerticalOffset then
            forceConeRadius = lockSite.forceConeDeadzoneRadius + (lockSite.distanceVerticalLockToCoupler - lockSite.forceConeVerticalOffset) * lockSite.forceConeSlope
          end
          local forceConeCoef = linearScale(lockSite.distanceHorizontalLockToCoupler, forceConeRadius, forceConeRadius + lockSite.forceConeTransitionWidth, 0, 1)
          lockSite.forceConeRadius = forceConeRadius
          lockSite.forceConeCoef = forceConeCoef
          local aligningForce = linearScale(lockSite.distanceVerticalLockToCoupler, 0.5, 0, 0, lockSite.aligningForceMaximum)
          lockSite.aligningForce = lockSite.aligningForceSmoother:get(aligningForce, dt)
          local forceVector = alignmentDirection:normalized() * lockSite.aligningForce * forceConeCoef
          --apply force vector and reaction force
          lockSite.aligningForceVector = -forceVector
          obj:applyForceVectorTime(lockSite.lockCouplerId, -forceVector, dt)
          setLockSiteFollowAligningForce(lockSite, forceVector)

          if lockSite.distanceVerticalLockToCoupler < lockSite.lockRadius * 0.8 then
            lockSiteSetLockState(lockSite, lockStates.locking)
          end

          lockIsVisible = true
        end
      end
    end

    if lockSite.lockState == lockStates.feeling then
      electrics.values[lockSite.lockStateElectricsName] = 0.5
    elseif lockSite.lockState == lockStates.locking then
      electrics.values[lockSite.lockStateElectricsName] = 0.5
      --when we are trying to lock
      if lockSite.distanceVerticalLockToCoupler >= lockSite.lockRadius * 0.9 then
        lockSiteSetLockState(lockSite, lockStates.feeling)
      end
    elseif lockSite.lockState == lockStates.locked then
      electrics.values[lockSite.lockStateElectricsName] = 1
      lockIsVisible = true
      lockIsLocked = true
      if lockSite.isLockAttached then
        lockSite.lockedStableTimer = lockSite.lockedStableTimer + dt
        if lockSite.lockedStableTimer >= lockSite.stableLockTime then
          lockSite.isLockStable = true
        end
      end
    end

    lockIsVisible = lockIsVisible and lockSite.needsVisualLockProp
    lockIsLocked = lockIsLocked and lockSite.needsVisualLockProp

    electrics.values[lockSite.lockIsVisibleElectricsName] = lockIsVisible and 1 or 0
    electrics.values[lockSite.lockIsLockedElectricsName] = lockIsLocked and 1 or 0
  end

  sendContainerLockDebugData()
end

local function getCouplerDebugColor(coupleState, latchState, isActive)
  if coupleState and coupleState >= 0 then
    return color(80, 220, 80, 255)
  end
  if latchState and latchState > 0 then
    return color(255, 190, 40, 255)
  end
  if isActive then
    return color(70, 150, 255, 255)
  end
  return color(120, 120, 120, 180)
end

local function getLockSiteDebugColor(lockSite)
  if lockSite.lockState == lockStates.locked then
    return color(80, 220, 80, 255)
  end
  if lockSite.lockState == lockStates.locking then
    return color(255, 190, 40, 255)
  end
  if lockSite.lockState == lockStates.feeling then
    return color(70, 150, 255, 255)
  end
  return color(180, 180, 180, 220)
end

local function debugDraw(focusPos)
  local pos = obj:getPosition()
  for _, lockSite in pairs(lockSites) do
    local globalLockPos = obj:getNodePosition(lockSite.lockCouplerId) + pos
    local globalFeelerPos = obj:getNodePosition(lockSite.feelerCouplerId) + pos
    local feelerLatchState = obj:getNodeLatch(lockSite.feelerCouplerId)
    local feelerCoupleState = obj:getNodeCoupler(lockSite.feelerCouplerId)
    local lockLatchState = obj:getNodeLatch(lockSite.lockCouplerId)
    local lockCoupleState = obj:getNodeCoupler(lockSite.lockCouplerId)
    local isFeelerActive = lockSite.lockState == lockStates.feeling or lockSite.lockState == lockStates.locking
    local isLockActive = lockSite.lockState == lockStates.locking or lockSite.lockState == lockStates.locked
    local feelerColor = getCouplerDebugColor(feelerCoupleState, feelerLatchState, isFeelerActive)
    local lockColor = getCouplerDebugColor(lockCoupleState, lockLatchState, isLockActive)
    local stateColor = getLockSiteDebugColor(lockSite)

    obj.debugDrawProxy:drawNodeSphere(lockSite.feelerCouplerId, 0.1, feelerColor)
    obj.debugDrawProxy:drawNodeSphere(lockSite.lockCouplerId, 0.1, lockColor)
    obj.debugDrawProxy:drawLine(globalFeelerPos, globalLockPos, stateColor)
    if lockSite.aligningForceVector then
      obj.debugDrawProxy:drawLine(globalLockPos, globalLockPos + lockSite.aligningForceVector / lockSite.aligningForceMaximum, color(47, 114, 199, 255))
    end
    obj.debugDrawProxy:drawText(globalLockPos, stateColor, lockSite.name .. " " .. lockSite.lockState .. " F:" .. feelerCoupleState .. "/" .. feelerLatchState .. " L:" .. lockCoupleState .. "/" .. lockLatchState)
  end
end

local function beamBroken(id, energy)
end

local function onCouplerFound(nodeId, obj2id, obj2nodeId)
end

local function onCouplerAttached(nodeId, obj2id, obj2nodeId)
  --try to find the lock site that the node belongs to
  local lockSiteFeeler = lockSites[feelerNodeLockSiteLookup[nodeId]]
  local lockSiteLock = lockSites[lockNodeFeelerLookup[nodeId]]

  --does the node belong to a feeler?
  if lockSiteFeeler then
    lockSiteFeeler.isFeelerAttached = true --feel node attached
    lockSiteFeeler.feelerConnectedObjId = obj2id --save the connected object id of the follow object
    lockSiteFeeler.lockSiteId = obj2nodeId --lock site id is the feeler node id of the other object
    lockSiteFeeler.aligningForceVector = nil --clear our own aligning force vector for this new feeler
    lockSiteFeeler.aligningForce = 0 --new feeler -> no active alignment force yet
    lockSiteFeeler.forceConeCoef = 0 --new feeler -> no active cone force yet
    lockSiteFeeler.aligningForceSmoother:reset()
  end

  --does the node belong to a lock?
  if lockSiteLock then
    lockSiteLock.isLockAttached = true --lock node attached
    lockSiteLock.lockConnectedObjId = obj2id --save the connected object id of the follow object
    lockSiteLock.aligningForceVector = nil --clear our own aligning force vector, we are locked
    lockSiteLock.aligningForce = 0 --locked -> no active alignment force
    lockSiteLock.forceConeCoef = 0 --locked -> no active cone force
    lockSiteLock.aligningForceSmoother:reset()
    lockSiteLock.lockedStableTimer = 0
    lockSiteLock.isLockStable = false
    lockSiteLock.lockState = lockStates.locked --set lock state to locked
    lockSiteLock.lockLastCouplerData = nil --clear data about the last coupler lock
    lockSiteLock.lockLastCouplerPosition = nil --clear position about the last coupler lock
    setLockSiteFollowAligningForce(lockSiteLock, nil) --lock node attached -> no more aligning force on the other object
  end
end

local function onCouplerDetached(nodeId, obj2id, obj2nodeId, breakForce)
  --try to find the lock site that the node belongs to
  local lockSiteFeeler = lockSites[feelerNodeLockSiteLookup[nodeId]]
  local lockSiteLock = lockSites[lockNodeFeelerLookup[nodeId]]

  --does the node belong to a feeler?
  if lockSiteFeeler then
    setLockSiteFollowAligningForce(lockSiteFeeler, nil) --feeler node detached -> no more aligning force on the other object
    lockSiteFeeler.isFeelerAttached = false --feel node detached -> no longer attached
    lockSiteFeeler.feelerConnectedObjId = nil -- no more connected object
    lockSiteFeeler.lockSiteId = nil -- no more lock site id from the other object
    lockSiteFeeler.aligningForceVector = nil --clear our own aligning force vector
    lockSiteFeeler.followLockCouplerPosition = nil --feeler detached -> no more lock coupler position from follow controller
  end

  --does the node belong to a lock?
  if lockSiteLock then
    lockSiteLock.isLockAttached = false -- lock node detached -> no longer attached
    lockSiteLock.lockConnectedObjId = nil -- no more connected object

    if breakForce <= 0 and lockSiteLock.isLockStable then --force > 0 when it broke
      --only prevent re-locking to the same target if the detaching was intentional
      lockSiteLock.lockLastCouplerData = {connectedObjId = obj2id, lockCouplerNodeId = obj2nodeId} --save data about the last coupler lock
      lockSiteLock.lockLastCouplerPosition = nil --we don't have a position yet, will be queried later
    else --lock broke
      --broken or unstable locks can reattach to the same target immediately
      lockSiteLock.lockLastCouplerData = nil --clear data about the last coupler lock
      lockSiteLock.lockLastCouplerPosition = nil --clear position about the last coupler lock
    end
    lockSiteLock.lockedStableTimer = 0
    lockSiteLock.isLockStable = false
    --detached lock -> go back to feeling state
    lockSiteSetLockState(lockSiteLock, lockStates.feeling)
  end
end

--when already locked, unlocks all. When not locked, only resets last coupler data to allow relocking to the same target
local function toggleLockState()
  if lockState == lockStates.locked then
    --if we are globally locked, simply unlock all
    setLockState(lockStates.feeling)
  else
    --if not, also unlock all to get to a known state
    setLockState(lockStates.feeling)
    --also reset all last coupler data to enable relocking to the same target
    for _, lockSite in pairs(lockSites) do
      lockSite.lockLastCouplerData = nil
      lockSite.lockLastCouplerPosition = nil
    end
  end
end

-- local function resetSounds(jbeamData)
-- end

local function reset(jbeamData)
  lockState = lockStates.feeling
  for _, lockSite in pairs(lockSites) do
    lockSite.isFeelerAttached = false
    lockSite.isLockAttached = false
    lockSite.isLockStable = false
    lockSite.lockedStableTimer = 0
    lockSite.aligningForce = 0
    lockSite.aligningForceVector = vec3()
    lockSite.upVector = vec3()
    lockSite.distanceVerticalLockToCoupler = math.huge
    lockSite.distanceHorizontalLockToCoupler = math.huge
    lockSite.followLockCouplerPosition = nil
    lockSite.lockLastCouplerPosition = nil
    lockSite.lockLastCouplerData = nil
    lockSite.forceConeRadius = 0
    lockSite.forceConeCoef = 0
    lockSite.lockState = lockStates.feeling
    lockSite.aligningForceSmoother:reset()
    electrics.values[lockSite.lockStateElectricsName] = 0
    electrics.values[lockSite.lockIsVisibleElectricsName] = 0
    electrics.values[lockSite.lockIsLockedElectricsName] = 0
  end

  feelerRoundRobinTimer = 0
  lastFeelerRoundRobinIndex = nil
end

local function initSounds(jbeamData)
end

local function init(jbeamData)
  feelerRoundRobinTimer = 0
  lastFeelerRoundRobinIndex = nil

  local feelerRadius = jbeamData.feelerCouplerRadius or 0.35 --latch radius for the feeler coupler
  local feelerLockRadius = jbeamData.feelerCouplerLockRadius or 0.005 --lock radius for the feeler coupler
  local feelerLatchSpeed = jbeamData.feelerCouplerLatchSpeed or 1.0 --speed at which the feeler coupler latches
  local feelerStrength = jbeamData.feelerCouplerStrength or 500 --strength of the feeler coupler
  local feelerAligningForceMaximum = jbeamData.aligningForceMaximum or 10000 --maximum force used to align lead to follow

  local lockRadius = jbeamData.lockCouplerRadius or 0.05 --radius of the lock coupler
  local lockLockRadius = jbeamData.lockCouplerLockRadius or 0.02 --lock radius for the lock coupler
  local lockLatchSpeed = jbeamData.lockCouplerLatchSpeed or 0.05 --speed at which the lock coupler latches
  local lockStrength = jbeamData.lockCouplerStrength or 10001000 --strength of the lock coupler

  --the alignment force emulates a cone shape with the point being at the coupler node
  local forceConeVerticalOffset = jbeamData.aligningForceConeVerticalOffset or 0.05 --vertical offset for the force cone, at 0 the cone starts at the coupler node
  local forceConeSlope = jbeamData.aligningForceConeSlope or 0.2 --how wide the cone is
  local forceConeTransitionWidth = jbeamData.aligningForceConeTransitionWidth or 0.01 --transition zone for the cone force
  local forceConeDeadzoneRadius = jbeamData.aligningForceConeDeadzoneRadius or lockRadius * 0.5 --radius of the deadzone tube below the cone

  local aligningForceSmootherIn = jbeamData.aligningForceSmootherIn or math.huge
  local aligningForceSmootherOut = jbeamData.aligningForceSmootherOut or feelerAligningForceMaximum
  local stableLockTime = jbeamData.stableLockTime or 0.5

  lockSites = {}
  feelerNodeLockSiteLookup = {}
  lockNodeFeelerLookup = {}
  containerLockDebugData.lockSites = {}

  local lockSiteData = tableFromHeaderTable(jbeamData.lockSites or {})
  for _, site in pairs(lockSiteData) do
    local feelerCouplerId = beamstate.nodeNameMap[site.feelerCouplerNodeName]
    local lockCouplerId = beamstate.nodeNameMap[site.lockCouplerNodeName]
    local verticalReferenceNodeCid = beamstate.nodeNameMap[site.verticalReferenceNodeName]
    if not feelerCouplerId then
      log("E", "containerLockLead.init", string.format("Can't find feeler coupler node with name '%s'", site.feelerCouplerNodeName))
    end
    if not lockCouplerId then
      log("E", "containerLockLead.init", string.format("Can't find lock coupler node with name '%s'", site.lockCouplerNodeName))
    end
    if not verticalReferenceNodeCid then
      log("E", "containerLockLead.init", string.format("Can't find vertical reference node with name '%s'", site.verticalReferenceNodeName))
    end
    local lockSite = {
      name = site.name,
      feelerCouplerId = feelerCouplerId,
      lockCouplerId = lockCouplerId,
      verticalReferenceNodeCid = verticalReferenceNodeCid,
      lockTag = site.lockCouplerTag,
      feelerTag = site.feelerCouplerTag,
      feelerStrength = feelerStrength,
      feelerRadius = feelerRadius,
      feelerLockRadius = feelerLockRadius,
      feelerLatchSpeed = feelerLatchSpeed,
      lockRadius = lockRadius,
      lockLockRadius = lockLockRadius,
      lockLatchSpeed = lockLatchSpeed,
      lockStrength = lockStrength,
      upVector = vec3(),
      aligningForceVector = vec3(),
      isFeelerAttached = false,
      isLockAttached = false,
      isLockStable = false,
      lockedStableTimer = 0,
      stableLockTime = stableLockTime,
      aligningForceMaximum = feelerAligningForceMaximum,
      aligningForce = 0,
      lockState = lockStates.feeling,
      followLockCouplerPosition = nil,
      distanceVerticalLockToCoupler = math.huge,
      distanceHorizontalLockToCoupler = math.huge,
      forceConeRadius = 0,
      forceConeCoef = 0,
      forceConeVerticalOffset = forceConeVerticalOffset,
      forceConeSlope = forceConeSlope,
      forceConeTransitionWidth = forceConeTransitionWidth,
      forceConeDeadzoneRadius = forceConeDeadzoneRadius,
      aligningForceSmoother = newTemporalSmoothing(aligningForceSmootherIn, aligningForceSmootherOut),
      lockStateElectricsName = site.lockStateElectricsName or site.name .. "_lock_state",
      lockIsVisibleElectricsName = M.name .. "_" .. site.name .. "_lock_is_visible",
      lockIsLockedElectricsName = M.name .. "_" .. site.name .. "_lock_is_locked"
    }
    table.insert(lockSites, lockSite)
    containerLockDebugData.lockSites[#lockSites] = {
      lockPosition = {},
      followLockCouplerPosition = {},
      lockLastCouplerPosition = {}
    }
    feelerNodeLockSiteLookup[feelerCouplerId] = #lockSites
    lockNodeFeelerLookup[lockCouplerId] = #lockSites

    electrics.values[lockSite.lockStateElectricsName] = 0
    electrics.values[lockSite.lockIsVisibleElectricsName] = 0
    electrics.values[lockSite.lockIsLockedElectricsName] = 0
  end
  --dump(lockSites)

  if #lockSites <= 0 then
    M.updateGFX = nop
  end

  lockState = lockStates.feeling
end

M.init = init
M.initSounds = initSounds

M.reset = reset
--M.resetSounds = resetSounds

M.updateGFX = updateGFX

--M.debugDraw = debugDraw

M.beamBroken = beamBroken

M.onCouplerFound = onCouplerFound
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached

M.toggleLockState = toggleLockState

M.lockSitePositionCallback = lockSitePositionCallback
M.lastLockCouplerPositionCallback = lastLockCouplerPositionCallback

return M
