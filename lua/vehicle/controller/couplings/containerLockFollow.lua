-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: The secondary/follow part of the container lock system. Provides the primary/lead part with
--position information, applies counter-alignment forces and stiffens the physical coupling structure once all locksites are attached

local M = {}
M.type = "auxiliary"

local abs = math.abs

local lockSites  --indexed by lock site id, aka the feeler node id
local lockNodeFeelerLookup = {} --lookup table to find the lock site index by lock node id

local lockStates = {
  unlocked = "unlocked",
  locked = "locked"
}

local function requestFollowLastLockCouplerPosition(objId, controllerName, lockCouplerNodeId)
  local lockSite = lockSites[lockNodeFeelerLookup[lockCouplerNodeId]]
  if not lockSite then
    --this happens when:
    --a) something is setup incorrectly
    --b) we have multiple controllers in a single vehicle and this is not the one that should be handling the lock site
    --in any case, we exit gracefully
    return
  end
  local position = obj:getPosition() + obj:getNodePosition(lockSite.lockCouplerId)

  local cmd = string.format("controller.getControllerSafe(%q).lastLockCouplerPositionCallback(%d, %s)", controllerName, lockCouplerNodeId, serialize(position))
  obj:queueObjectLuaCommand(objId, cmd)
end

local function requestFollowLockCouplerPosition(objId, controllerName, lockSiteId)
  local lockSite = lockSites[lockSiteId]
  if not lockSite then
    --this happens when:
    --a) something is setup incorrectly
    --b) we have multiple controllers in a single vehicle and this is not the one that should be handling the lock site
    --in any case, we exit gracefully
    return
  end
  local position = obj:getPosition() + obj:getNodePosition(lockSite.lockCouplerId)

  local cmd = string.format("controller.getControllerSafe(%q).lockSitePositionCallback(%d, %s, %s)", controllerName, lockSiteId, serialize(position), lockSite.needsVisualLockProp)
  obj:queueObjectLuaCommand(objId, cmd)
end

local function applyAligningForce(lockSiteId, forceVector)
  local lockSite = lockSites[lockSiteId]

  if not lockSite then
    --this happens when:
    --a) something is setup incorrectly
    --b) we have multiple controllers in a single vehicle and this is not the one that should be handling the lock site
    --in any case, we exit gracefully
    return
  end

  local isLockCoupled = obj:getNodeCoupler(lockSite.lockCouplerId) >= 0
  if isLockCoupled then
    return
  end

  lockSite.aligningForceVector = forceVector
end

local function setLockBeamsLocked(lockSite, locked)
  if not lockSite then
    return
  end
  local spring = locked and lockSite.couplerLockBeamsLockedSpring or lockSite.couplerLockBeamsUnlockedSpring
  local damp = locked and lockSite.couplerLockBeamsLockedDamp or lockSite.couplerLockBeamsUnlockedDamp
  for _, cid in pairs(lockSite.couplerLockBeamCids) do
    obj:setBeamSpringDamp(cid, spring, damp, -1, -1)
  end
end

local function setLockSiteEnabled(lockSite, enabled)
  if lockSite.isEnabled == enabled then
    return
  end
  lockSite.isEnabled = enabled

  local feelerTag = lockSite.feelerTag .. (enabled and "" or "_disabled")
  local lockTag = lockSite.lockTag .. (enabled and "" or "_disabled")
  obj:setNodeTag(lockSite.feelerCouplerId, feelerTag)
  obj:setNodeTag(lockSite.lockCouplerId, lockTag)
end

local function updateGFX(dt)
  local allLocked = true
  for _, site in pairs(lockSites) do
    if site.aligningForceVector then
      obj:applyForceVectorTime(site.aligningForceNodeId, site.aligningForceVector, dt)
    end

    if site.lockState ~= lockStates.locked then
      allLocked = false
    end

    local isEnabled = true
    if site.isEnabledElectricsName then
      --check if we are supposed to be enabled based on the electrics value, use some small epsilon to avoid floating point precision issues
      isEnabled = abs(electrics.values[site.isEnabledElectricsName] - site.isEnabledElectricsValue) <= 0.001
    end
    setLockSiteEnabled(site, isEnabled)

    electrics.values[site.lockIsLockedElectricsName] = site.lockState == lockStates.locked and 1 or 0
  end

  for _, site in pairs(lockSites) do
    setLockBeamsLocked(site, allLocked)
  end
end

local function debugDraw(focusPos)
  local pos = obj:getPosition()
  for _, lockSite in pairs(lockSites) do
    local globalFeelerPos = obj:getNodePosition(lockSite.feelerCouplerId) + pos
    obj.debugDrawProxy:drawNodeSphere(lockSite.feelerCouplerId, 0.1, getContrastColor(stringHash(lockSite.feelerCouplerId), 150))
    obj.debugDrawProxy:drawNodeSphere(lockSite.lockCouplerId, 0.1, getContrastColor(stringHash(lockSite.lockCouplerId), 150))
    if lockSite.aligningForceVector then
      obj.debugDrawProxy:drawLine(globalFeelerPos, globalFeelerPos + lockSite.aligningForceVector / 5000, color(239, 139, 0, 255))
    end
    local enabledColor = lockSite.isEnabled and color(0, 255, 0, 255) or color(255, 0, 0, 255)
    obj.debugDrawProxy:drawText(globalFeelerPos, enabledColor, lockSite.name .. " enabled:" .. tostring(lockSite.isEnabled) .. " " .. lockSite.lockTag .. " " .. lockSite.feelerTag .. " feelerId:" .. lockSite.feelerCouplerId .. " lockId:" .. lockSite.lockCouplerId)
  end
end

local function beamBroken(id, energy)
end

local function onCouplerAttached(nodeId, obj2id, obj2nodeId)
  local lockSiteLock = lockSites[lockNodeFeelerLookup[nodeId]]

  if lockSiteLock then
    lockSiteLock.aligningForceVector = nil
    lockSiteLock.lockState = lockStates.locked
    setLockBeamsLocked(lockSiteLock, true)
  end
end

local function onCouplerDetached(nodeId, obj2id, obj2nodeId, breakForce)
  local lockSiteFeeler = lockSites[nodeId]
  local lockSiteLock = lockSites[lockNodeFeelerLookup[nodeId]]

  if lockSiteFeeler then
    lockSiteFeeler.aligningForceVector = nil
  end
  if lockSiteLock then
    lockSiteLock.aligningForceVector = nil
    lockSiteLock.lockState = lockStates.unlocked
  end
end

local function reset(jbeamData)
  for _, lockSite in pairs(lockSites) do
    lockSite.aligningForceVector = nil
    lockSite.isEnabled = nil --set to nil so first update to enabled is not skipped
    electrics.values[lockSite.lockIsLockedElectricsName] = 0
  end
end

local function init(jbeamData)
  lockSites = {}

  local lockSiteData = tableFromHeaderTable(jbeamData.lockSites or {})
  for _, lockSite in pairs(lockSiteData) do
    local lockSiteId = beamstate.nodeNameMap[lockSite.feelerCouplerNodeName]
    local feelerCouplerId = beamstate.nodeNameMap[lockSite.feelerCouplerNodeName]
    local lockCouplerId = beamstate.nodeNameMap[lockSite.lockCouplerNodeName]
    local aligningForceNodeId = beamstate.nodeNameMap[lockSite.aligningForceNodeName]
    if not feelerCouplerId then
      log("E", "containerLockFollow.init", string.format("Can't find feeler coupler node with name '%s'", lockSite.feelerCouplerNodeName))
    end
    if not lockCouplerId then
      log("E", "containerLockFollow.init", string.format("Can't find lock coupler node with name '%s'", lockSite.lockCouplerNodeName))
    end
    if not aligningForceNodeId then
      log("E", "containerLockFollow.init", string.format("Can't find aligning force node with name '%s'", lockSite.aligningForceNodeName))
    end

    lockSites[lockSiteId] = {
      name = lockSite.name,
      lockState = lockStates.unlocked,
      feelerCouplerId = feelerCouplerId,
      lockCouplerId = lockCouplerId,
      feelerTag = v.data.nodes[feelerCouplerId].tag,
      lockTag = v.data.nodes[lockCouplerId].tag,
      aligningForceNodeId = aligningForceNodeId,
      aligningForceVector = nil,
      couplerLockBeamsUnlockedSpring = lockSite.couplerLockBeamsUnlockedSpring,
      couplerLockBeamsLockedSpring = lockSite.couplerLockBeamsLockedSpring,
      couplerLockBeamsUnlockedDamp = lockSite.couplerLockBeamsUnlockedDamp,
      couplerLockBeamsLockedDamp = lockSite.couplerLockBeamsLockedDamp,
      couplerLockBeamCids = beamstate.tagBeamMap[lockSite.couplerLockBeamsTag] or {},
      needsVisualLockProp = lockSite.needsVisualLockProp == nil and true or lockSite.needsVisualLockProp,
      isEnabled = nil, --set to nil so first update to enabled is not skipped
      isEnabledElectricsName = lockSite.isEnabledElectricsName,
      isEnabledElectricsValue = lockSite.isEnabledElectricsValue or 1,
      lockIsLockedElectricsName = M.name .. "_" .. lockSite.name .. "_lock_is_locked"
    }
    --lock node based site lookup
    lockNodeFeelerLookup[lockCouplerId] = lockSiteId
    setLockBeamsLocked(lockSites[lockSiteId], false)
  end
  --dump(lockSites)
end

M.init = init
M.reset = reset

M.updateGFX = updateGFX

--M.debugDraw = debugDraw

M.beamBroken = beamBroken

M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached

M.applyAligningForce = applyAligningForce
M.requestFollowLockCouplerPosition = requestFollowLockCouplerPosition
M.requestFollowLastLockCouplerPosition = requestFollowLastLockCouplerPosition

return M
