-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"

local couplerStates = {
  attached = "attached",
  coupling = "coupling",
  autoCoupling = "autoCoupling",
  detached = "detached",
  broken = "broken",
  desyncedAttached = "desyncedAttached",
  desyncedDetached = "desyncedDetached"
}

local couplerGroupTypes = {
  default = "default",
  autoCoupling = "autoCoupling", --for doors and other latches that latch automatically
  manualClose = "manualClose", --latches that don't latch automatically, but can be closed manually
  manualCloseMultiPoint = "manualCloseMultiPoint" --latches that don't latch automatically, but can be closed manually, and have multiple points of attachment
}

local detachSoundStateLookup = {
  [couplerStates.attached] = true,
  [couplerStates.desyncedAttached] = true
}

local attachSoundStateLookup = {
  [couplerStates.detached] = true,
  [couplerStates.coupling] = true,
  [couplerStates.autoCoupling] = true,
  [couplerStates.desyncedAttached] = true
}

local toggleDetachStateLookup = {
  [couplerStates.attached] = true,
  [couplerStates.detached] = true,
  [couplerStates.coupling] = true,
  [couplerStates.autoCoupling] = true,
  [couplerStates.desyncedAttached] = true
}

local toggleAttachStateLookup = {
  [couplerStates.detached] = true,
  [couplerStates.coupling] = true,
  [couplerStates.autoCoupling] = true,
  [couplerStates.broken] = true,
  [couplerStates.desyncedDetached] = true
}

local couplerGroup
local autoLatchesToActivate
local externalCouplerBreakGroups

local stateData
local stateDataNameGroupState

local notAttachedElectricsName
local attachedElectricsName

local function updateCid2(cnp, roundRobin)
  if cnp.cid2Count == 1 then
    cnp.cid2 = cnp.availableCid2[1]
    return false
  end
  local foundCloserNode = false
  if not roundRobin then
    local distance = math.huge
    for _, cid2 in ipairs(cnp.availableCid2) do
      local d = obj:nodeLength(cnp.cid1, cid2)
      if d < distance then
        foundCloserNode = true
        distance = d
        cnp.cid2 = cid2
      end
    end
  else
    local key, nodeToCheck = next(cnp.availableCid2, cnp.cid2Key)
    if not nodeToCheck then
      nodeToCheck = cnp.availableCid2[1]
      key = 1
    end
    cnp.cid2Key = key
    local currentDistance = obj:nodeLength(cnp.cid1, cnp.cid2)
    local newDistance = obj:nodeLength(cnp.cid1, nodeToCheck)
    if newDistance < currentDistance then
      foundCloserNode = true
      cnp.cid2 = nodeToCheck
    end
  end
  return foundCloserNode
end

local function requestLocalAttach(cnp, radius)
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "requestLocalAttach", cnp.cid1, cnp.cid2, cnp.autoCouplingStrength, radius, cnp.autoCouplingLockRadius, cnp.autoCouplingSpeed)
  obj:attachLocalCoupler(cnp.cid1, cnp.cid2, cnp.autoCouplingStrength, radius, cnp.autoCouplingLockRadius, cnp.autoCouplingSpeed, true)
  cnp.state = couplerStates.autoCoupling
end

local function queueAutoLatch(couplerIndex)
  for _, queuedCouplerIndex in ipairs(autoLatchesToActivate) do
    if queuedCouplerIndex == couplerIndex then
      return
    end
  end
  table.insert(autoLatchesToActivate, couplerIndex)
end

local function requestInitialCouplings()
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "requestInitialCouplings")
  for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
    if cnp.couplingStartRadius and cnp.state ~= couplerStates.attached and cnp.state ~= couplerStates.broken then
      updateCid2(cnp)
      requestLocalAttach(cnp, cnp.couplingStartRadius)
    end
  end
end

local function syncGroupState()
  local currentStates = {}
  for _, coupler in ipairs(couplerGroup.couplerNodePairs) do
    currentStates[coupler.state] = true
  end

  local groupState
  if tableSize(currentStates) == 1 then
    groupState = couplerGroup.couplerNodePairs[1].state
  else
    if currentStates[couplerStates.attached] then
      groupState = couplerStates.desyncedAttached
    else
      groupState = couplerStates.desyncedDetached
    end
  end
  couplerGroup.groupState = groupState
  electrics.values[notAttachedElectricsName] = groupState == couplerStates.attached and 0 or 1
  electrics.values[attachedElectricsName] = groupState == couplerStates.attached and 1 or 0
end

local function tryAttachGroupImpulse()
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "tryAttachGroupImpulse")
  if couplerGroup.groupState == couplerStates.attached then
    return
  end

  if couplerGroup.groupType == couplerGroupTypes.manualClose or couplerGroup.groupType == couplerGroupTypes.manualCloseMultiPoint then
    for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
      if cnp.state == couplerStates.detached then
        --if we are a multi-point type, we need to update the closest cid2
        if couplerGroup.groupType == couplerGroupTypes.manualCloseMultiPoint then
          updateCid2(cnp)
        end
        --obj:attachLocalCoupler(nid1, nid2, strength, radius, lockRadius, latchSpeed, bool persistLatch)
        requestLocalAttach(cnp, cnp.autoCouplingRadius)
        if couplerGroup.attachingUIMessage then
          guihooks.message(couplerGroup.attachingUIMessage, 3, "vehicle.couplers.advanced." .. M.name)
        end
      end
    end
  elseif couplerGroup.groupType == couplerGroupTypes.autoCoupling then
    for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
      if cnp.state == couplerStates.detached or cnp.state == couplerStates.autoCoupling then
        requestLocalAttach(cnp, cnp.autoCouplingRadius)
      end
    end
  end
  syncGroupState()
  couplerGroup.closeForceTimer = couplerGroup.closeForceDuration
end

local function detachGroup()
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "detachGroup")
  if couplerGroup.groupState == couplerStates.autoCoupling or couplerGroup.groupState == couplerStates.detached then
    return
  end

  for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
    obj:detachCoupler(cnp.cid1, 0)
  end

  local canApplyOpenForce = true
  for _, condition in ipairs(couplerGroup.openForceConditions) do
    local couplerController = controller.getController(condition.advancedCouplerControlName)
    if couplerController and couplerController.typeName == "advancedCouplerControl" then
      local couplerControllerState = couplerController.getGroupState()
      local controllerMatchesRequiredStates = false
      for _, requiredState in ipairs(condition.requiredStates) do
        controllerMatchesRequiredStates = couplerControllerState == requiredState or controllerMatchesRequiredStates
      end
      if not controllerMatchesRequiredStates then
        canApplyOpenForce = false
        break
      end
    else
      log("I", "advancedCouplerControl.detachGroup", "Can't find controller (or wrong type) for specified open force condition, ignoring: " .. condition.advancedCouplerControlName)
    end
  end

  if canApplyOpenForce then
    couplerGroup.openForceTimer = couplerGroup.openForceDuration
  end
  if couplerGroup.detachUIMessage then
    guihooks.message(couplerGroup.detachUIMessage, 3, "vehicle.couplers.advanced." .. M.name)
  end
end

local function toggleGroup()
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "toggleGroup")
  if couplerGroup.openForceTimer > 0 or couplerGroup.closeForceTimer > 0 then
    return
  end
  if toggleAttachStateLookup[couplerGroup.groupState] then
    tryAttachGroupImpulse()
  elseif toggleDetachStateLookup[couplerGroup.groupState] then
    detachGroup()
  end
end

local function toggleGroupConditional(conditions)
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "toggleGroupConditional")
  for _, c in ipairs(conditions) do
    if #c < 2 then
      log("E", "advancedCouplerControl.toggleGroupConditional", "Wrong amount of data for condition, expected 2:")
      log("E", "advancedCouplerControl.toggleGroupConditional", dumps(c))
      return
    end
    local controllerName = c[1]
    local nonAllowedState = c[2]
    local errorMessage = c[3]
    if not controllerName or not nonAllowedState then
      log("E", "advancedCouplerControl.toggleGroupConditional", string.format("Wrong condition data, groupName: %q, nonAllowedState: %q", controllerName, nonAllowedState))
      return
    end
    local groupController = controller.getController(controllerName)
    if not groupController or groupController.typeName ~= "advancedCouplerControl" then
      log("D", "advancedCouplerControl.toggleGroupConditional", string.format("Can't find group controller with name %q or it's the wrong type", controllerName))
    end
    if groupController and groupController.typeName == "advancedCouplerControl" then
      local groupState = groupController.getGroupState()
      if groupState == nonAllowedState then
        -- group is in wrong state, don't continue
        guihooks.message(errorMessage, 5, "vehicle.advancedCouplerControl." .. controllerName .. nonAllowedState .. errorMessage)
        return
      end
    end
  end
  toggleGroup()
end

local function updateGFX(dt)
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "updateGFX, group state: " .. couplerGroup.groupState)
  if couplerGroup.spawnSoundDelayTimer > 0 then
    couplerGroup.spawnSoundDelayTimer = couplerGroup.spawnSoundDelayTimer - dt
    if couplerGroup.spawnSoundDelayTimer <= 0 then
      couplerGroup.canPlaySounds = true
    end
  end

  if #autoLatchesToActivate > 0 then
    local activatedAutoLatches = {}
    for key, couplerIndex in ipairs(autoLatchesToActivate) do
      local cnp = couplerGroup.couplerNodePairs[couplerIndex]
      --we can assume only a single cid2 here since we do not support multiple cid2 in auto coupling mode
      local nodeDistance = obj:nodeLength(cnp.cid1, cnp.cid2)
      if nodeDistance > cnp.autoCouplingRadius * 2 then
        table.insert(activatedAutoLatches, key)
        if cnp.state == couplerStates.detached then
          --obj:attachLocalCoupler(nid1, nid2, strength, radius, lockRadius, latchSpeed, bool persistLatch)
          requestLocalAttach(cnp, cnp.autoCouplingRadius)
        end
      end
    end

    for i = #activatedAutoLatches, 1, -1 do
      table.remove(autoLatchesToActivate, activatedAutoLatches[i])
    end

    syncGroupState()
  end

  if couplerGroup.groupState == couplerStates.autoCoupling and couplerGroup.groupType == couplerGroupTypes.manualCloseMultiPoint then
    for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
      local foundCloserNode = updateCid2(cnp, true)
      if foundCloserNode then
        requestLocalAttach(cnp, cnp.autoCouplingRadius)
      end
    end
  end

  if couplerGroup.openForceTimer > 0 then
    couplerGroup.openForceTimer = couplerGroup.openForceTimer - dt
    for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
      obj:applyForceTime(cnp.applyForceCid2, cnp.applyForceCid1, -couplerGroup.openForceMagnitude * couplerGroup.invCouplerNodePairCount, dt)
    end
  end

  if couplerGroup.closeForceTimer > 0 then
    couplerGroup.closeForceTimer = couplerGroup.closeForceTimer - dt
    for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
      obj:applyForceTime(cnp.applyForceCid2, cnp.applyForceCid1, couplerGroup.closeForceMagnitude * couplerGroup.invCouplerNodePairCount, dt)
    end
  end
end

local function onCouplerFound(nodeId, obj2id, obj2nodeId)
  --dump(couplerGroup)
  --local couplerIndex = couplerGroup.couplerNodeIdLookup[nodeId]
  --if couplerIndex then
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "onCouplerFound, " .. nodeId .. ", " .. obj2id .. ", " .. obj2nodeId)
  --end
end

local function onCouplerAttached(nodeId, obj2id, obj2nodeId, attachForce)
  local couplerIndex = couplerGroup.couplerNodeIdLookup[nodeId]
  if couplerIndex then
    --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "onCouplerAttached, " .. nodeId .. ", " .. obj2id .. ", " .. obj2nodeId .. ", " .. attachForce)
    couplerGroup.couplerNodePairs[couplerIndex].state = couplerStates.attached

    local isCorrectPastState = attachSoundStateLookup[couplerGroup.groupState]
    syncGroupState()
    local isCorrectCurrentState = couplerGroup.groupState == couplerStates.attached
    if isCorrectPastState and isCorrectCurrentState and couplerGroup.canPlaySounds then
      local aggressionCoef = linearScale(attachForce, 0.1, 1, 0, 1)
      obj:playSFXOnceCT(couplerGroup.attachSoundEvent, couplerGroup.soundNode, couplerGroup.attachSoundVolume, 0.5, aggressionCoef, 0)
    end
    if isCorrectCurrentState then
      if couplerGroup.detachUIMessage then
        guihooks.message(couplerGroup.attachUIMessage, 3, "vehicle.couplers.advanced." .. M.name)
      end
    end

    if couplerGroup.groupState == couplerStates.attached then
      couplerGroup.closeForceTimer = 0
      couplerGroup.openForceTimer = 0
    end
  end
end

local function onCouplerDetached(nodeId, obj2id, obj2nodeId, breakForce)
  local couplerIndex = couplerGroup.couplerNodeIdLookup[nodeId]
  if couplerIndex then
    --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "onCouplerDetached, " .. nodeId .. ", " .. obj2id .. ", " .. obj2nodeId .. ", " .. breakForce)
    couplerGroup.couplerNodePairs[couplerIndex].state = breakForce <= 0 and couplerStates.detached or couplerStates.broken
    if couplerGroup.couplerNodePairs[couplerIndex].state == couplerStates.detached and couplerGroup.groupType == couplerGroupTypes.autoCoupling then
      queueAutoLatch(couplerIndex)
    end
    local isCorrectPastState = detachSoundStateLookup[couplerGroup.groupState]
    syncGroupState()
    local isCorrectCurrentState = couplerGroup.groupState == couplerStates.detached
    if isCorrectPastState and isCorrectCurrentState then
      obj:playSFXOnceCT(couplerGroup.detachSoundEvent, couplerGroup.soundNode, couplerGroup.detachSoundVolume, 0.5, 1, 0)
    end
  end
end

local function onGameplayEvent(eventName, ...)
end

local function getGroupState()
  return couplerGroup.groupState
end

local function registerExternalCouplerBreakGroups()
  for _, couplerBreakGroupData in ipairs(externalCouplerBreakGroups) do
    beamstate.registerExternalCouplerBreakGroup(couplerBreakGroupData.breakGroup, couplerBreakGroupData.cid)
  end
end

local function resetSounds(jbeamData)
end

local function reset(jbeamData)
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "reset")
  autoLatchesToActivate = {}
  couplerGroup.canPlaySounds = false
  couplerGroup.spawnSoundDelayTimer = 0.1
  couplerGroup.closeForceTimer = 0
  couplerGroup.openForceTimer = 0
  couplerGroup.groupState = couplerStates.detached
  for _, cnp in ipairs(couplerGroup.couplerNodePairs) do
    cnp.state = couplerStates.detached
  end
  requestInitialCouplings()
  syncGroupState()

  table.clear(stateData)

  registerExternalCouplerBreakGroups()
end

local function initSounds(jbeamData)
end

local function init(jbeamData)
  --print(M.name)
  --dump(jbeamData)
  --print((v.config.mainPartName or "nil") .. "-" .. M.name .. ": " .. "init")
  couplerGroup = {
    couplerNodeIdLookup = {},
    couplerNodePairs = {},
    groupState = couplerStates.detached,
    soundNode = jbeamData.soundNode_nodes and jbeamData.soundNode_nodes[1] or 0,
    attachSoundEvent = jbeamData.attachSoundEvent,
    detachSoundEvent = jbeamData.detachSoundEvent,
    breakSoundEvent = jbeamData.breakSoundEvent,
    attachSoundVolume = jbeamData.attachSoundVolume,
    detachSoundVolume = jbeamData.detachSoundVolume,
    breakSoundVolume = jbeamData.breakSoundVolume,
    canPlaySounds = false,
    spawnSoundDelayTimer = 0.1,
    groupType = jbeamData.groupType or couplerGroupTypes.default,
    openForceMagnitude = jbeamData.openForceMagnitude or 100,
    openForceDuration = jbeamData.openForceDuration or 0.2,
    closeForceMagnitude = jbeamData.closeForceMagnitude or 100,
    closeForceDuration = jbeamData.closeForceDuration or 0.3,
    closeForceTimer = 0,
    openForceTimer = 0,
    openForceConditions = tableFromHeaderTable(jbeamData.openForceConditions or {}),
    attachUIMessage = jbeamData.attachUIMessage,
    attachingUIMessage = jbeamData.attachingUIMessage,
    detachUIMessage = jbeamData.detachUIMessage
  }
  bdebug.setNodeDebugText("Latches", couplerGroup.soundNode, M.name .. ": " .. (couplerGroup.attachSoundEvent or "no attach event"))
  bdebug.setNodeDebugText("Latches", couplerGroup.soundNode, M.name .. ": " .. (couplerGroup.detachSoundEvent or "no detach event"))
  bdebug.setNodeDebugText("Latches", couplerGroup.soundNode, M.name .. ": " .. (couplerGroup.breakSoundEvent or "no break event"))

  local nodeData = tableFromHeaderTable(jbeamData.couplerNodes)

  notAttachedElectricsName = M.name .. "_notAttached"
  attachedElectricsName = M.name .. "_attached"

  externalCouplerBreakGroups = {}

  for _, cnp in ipairs(nodeData) do
    local couplerNodePairData = {
      cid1 = beamstate.nodeNameMap[cnp.cid1],
      applyForceCid1 = beamstate.nodeNameMap[cnp.forceCid1 or cnp.cid1],
      autoCouplingStrength = cnp.autoCouplingStrength or 40000,
      autoCouplingRadius = cnp.autoCouplingRadius or 0.01,
      autoCouplingLockRadius = cnp.autoCouplingLockRadius or 0.005,
      autoCouplingSpeed = cnp.autoCouplingSpeed or 0.2,
      couplingStartRadius = cnp.couplingStartRadius,
      breakGroup = cnp.breakGroup,
      state = couplerStates.detached
    }

    if type(cnp.cid2) == "table" then
      couplerNodePairData.availableCid2 = {}
      for _, cid2 in pairs(cnp.cid2) do
        table.insert(couplerNodePairData.availableCid2, beamstate.nodeNameMap[cid2])
      end
    else
      couplerNodePairData.availableCid2 = {beamstate.nodeNameMap[cnp.cid2]}
    end
    couplerNodePairData.cid2Count = #couplerNodePairData.availableCid2
    if couplerNodePairData.cid2Count > 1 and couplerGroup.groupType ~= couplerGroupTypes.manualCloseMultiPoint then
      log("E", "advancedCouplerControl.init", "Multiple cid2 nodes only supported in manual close mode, defaulting to first cid2...")
    end
    couplerNodePairData.cid2 = couplerNodePairData.availableCid2[1]
    couplerNodePairData.cid2Key = 1
    couplerNodePairData.applyForceCid2 = beamstate.nodeNameMap[cnp.forceCid2] or couplerNodePairData.cid2

    if couplerNodePairData.cid1 and couplerNodePairData.cid2 and couplerNodePairData.applyForceCid1 and couplerNodePairData.applyForceCid2 then
      table.insert(couplerGroup.couplerNodePairs, couplerNodePairData)
      couplerGroup.couplerNodeIdLookup[couplerNodePairData.cid1] = #couplerGroup.couplerNodePairs
      for _, cid2 in ipairs(couplerNodePairData.availableCid2) do
        couplerGroup.couplerNodeIdLookup[cid2] = couplerGroup.couplerNodeIdLookup[couplerNodePairData.cid1]
      end
      if couplerNodePairData.breakGroup then
        table.insert(externalCouplerBreakGroups, {breakGroup = couplerNodePairData.breakGroup, cid = couplerNodePairData.cid1})
      end
    else
      log("W", "advancedCouplerControl.init", "Can't find all required nodes for correct initialization of advanced coupler control:")
      log("W", "advancedCouplerControl.init", "Cid1: " .. (cnp.cid1 or "nil"))
      log("W", "advancedCouplerControl.init", "Cid2: " .. (dumps(cnp.cid2) or "nil"))
      log("W", "advancedCouplerControl.init", "forceCid1: " .. ((cnp.forceCid1 or cnp.cid1) or "nil"))
      log("W", "advancedCouplerControl.init", "forceCid2: " .. ((cnp.forceCid2 or dumps(cnp.cid2)) or "nil"))
    end
  end
  couplerGroup.invCouplerNodePairCount = 1 / #couplerGroup.couplerNodePairs

  stateData = {}
  stateDataNameGroupState = M.name .. "_groupState"

  registerExternalCouplerBreakGroups()

  autoLatchesToActivate = {}
  requestInitialCouplings()
  syncGroupState()
end

local function getState()
  stateData[stateDataNameGroupState] = couplerGroup.groupState
  return stateData
end

local function setState(data)
  if not data then
    return
  end

  local groupState = data[stateDataNameGroupState]

  if groupState then
    if couplerGroup.groupState ~= groupState then
      --don't do this here as it will internally desync and not actually execute the state change, maybe needed afterwards? s
      --couplerGroup.groupState = groupState

      if groupState == couplerStates.attached or groupState == couplerStates.desyncedAttached then
        --if it's now attached, try to attach via normal impulse interaction
        tryAttachGroupImpulse()
      elseif groupState == couplerStates.detached or groupState == couplerStates.desyncedDetached or groupState == couplerStates.autoCoupling then
        --if it's detached, try to replicate that
        detachGroup()
      elseif groupState == couplerStates.broken then
        --if the overall group state is broken, we don't really know what exactly caused it
        --instead of trying to somehow replicate the original break, we just break all coupler pairs
        for _, coupler in ipairs(couplerGroup.couplerNodePairs) do
          obj:detachCoupler(coupler.cid1, math.huge)
        end
      end
    end
  end
end

M.init = init
M.initSounds = initSounds

M.reset = reset
M.resetSounds = resetSounds

M.updateGFX = updateGFX

M.onCouplerFound = onCouplerFound
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached

M.onGameplayEvent = onGameplayEvent

M.toggleGroup = toggleGroup
M.toggleGroupConditional = toggleGroupConditional
M.tryAttachGroupImpulse = tryAttachGroupImpulse
M.detachGroup = detachGroup
M.getGroupState = getGroupState

M.getState = getState
M.setState = setState

return M
