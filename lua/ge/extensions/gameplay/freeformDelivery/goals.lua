-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "gameplay_freeformDelivery_utils", "core_trailerRespawn", "core_vehicles", "core_vehicleBridge" }
local logTag = "freeformDelivery_goals"

local p = nil -- Profiler instance (assigned in update function)

local goals = {}
local goalStates = {}
local pendingEngineRunningRequests = {}

-- Auto-completion timer state
local completionTimer = nil
local completionTimerDuration = 5.0 -- seconds
local completionMessageId = "delivery_completion_timer"

local Text = {
  allGoalsCompleted = "missions.freeformDelivery.common.allGoalsCompleted",
}

local function contextTranslate(key, vars)
  if core_locales and core_locales.contextTranslate then
    return core_locales.contextTranslate(key, vars)
  end
  return _tr(key)
end

-- Cache for target areas and site objects
local targetAreaCache = {} -- areaId -> targetArea
local siteObjectCache = {} -- areaId -> siteObj

local function findTargetArea(delivery, areaId)
  -- Use cache if available
  if targetAreaCache[areaId] then
    return targetAreaCache[areaId]
  end

  local area = gameplay_freeformDelivery_utils.findTargetArea(delivery, areaId)
  if area then
    targetAreaCache[areaId] = area
  end
  return area
end

local function getSiteObject(delivery, targetAreaId)
  -- Use cache if available
  if siteObjectCache[targetAreaId] then
    return siteObjectCache[targetAreaId]
  end

  local targetArea = findTargetArea(delivery, targetAreaId)
  if not targetArea then return nil end

  local siteObj = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, targetArea.type, targetArea.siteId)
  if siteObj then
    siteObjectCache[targetAreaId] = siteObj
  end

  return siteObj
end

local function checkPlacementGoal(goal, delivery)
  -- Use module-level p variable

  if p then p:add("checkPlacementGoal: " .. (goal.id or "unknown")) end

  local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goal)
  if #vehicleIds == 0 then return false end

  local targetAreaId = goal.targetAreaId
  if not targetAreaId then return false end

  local siteObj = getSiteObject(delivery, targetAreaId)
  if p then p:add("get site object") end
  if not siteObj then return false end

  local targetArea = findTargetArea(delivery, targetAreaId)
  if not targetArea then return false end

  local inAreaCount = 0
  local requiredAmount = goal.requiredAmount or #vehicleIds
  for _, vehicleId in ipairs(vehicleIds) do
    if p then p:add("get vehicle ID: " .. vehicleId) end
    local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleId)
    if not veh then
      goto continue
    end

    if gameplay_freeformDelivery_utils.checkVehicleInArea(veh, siteObj, targetArea.type) then
      if p then p:add("check vehicle in area") end
      inAreaCount = inAreaCount + 1
    end

    ::continue::
  end

  return inAreaCount >= requiredAmount
end

local function checkPlayerInVehicleGoal(goal)
  if not goal then return false end

  local playerVeh = gameplay_freeformDelivery_utils.getPlayerVehicle()
  if not playerVeh then return false end

  if not goal.vehicleId then return false end
  local targetVeh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(goal.vehicleId)
  if not targetVeh then return false end

  return playerVeh:getID() == targetVeh:getID()
end

local function checkEngineRunningGoal(goal)
  if not goal or not core_vehicleBridge then return false end

  local vehicle = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(goal.vehicleId)
  if not vehicle then return false end

  core_vehicleBridge.registerValueChangeNotification(vehicle, "engineRunning")

  local vehicleId = vehicle:getID()
  local engineRunning = core_vehicleBridge.getCachedVehicleData(vehicleId, "engineRunning")
  if engineRunning == nil and not pendingEngineRunningRequests[vehicleId] then
    pendingEngineRunningRequests[vehicleId] = true
    core_vehicleBridge.requestValue(vehicle, function(res)
      pendingEngineRunningRequests[vehicleId] = nil
      if res and res.result ~= nil then
        core_vehicleBridge.vehicleData[vehicleId] = core_vehicleBridge.vehicleData[vehicleId] or {data = {}, registeredCallbacks = {}}
        core_vehicleBridge.vehicleData[vehicleId].data.engineRunning = res.result
      end
    end, "electricsValue", "engineRunning")
  end

  return tonumber(engineRunning) ~= nil and tonumber(engineRunning) > 0
end

local function isAttachedCouplerPair(vehicleId, trailerId)
  if not core_vehicles or not core_vehicles.attachedCouplers then return false end

  for _, coupler in ipairs(core_vehicles.attachedCouplers) do
    if type(coupler) == "table" and ((coupler[1] == vehicleId and coupler[2] == trailerId) or (coupler[1] == trailerId and coupler[2] == vehicleId)) then
      return true
    end
  end

  return false
end

local function isTrailerRespawnCoupled(vehicleId, trailerId)
  if not core_trailerRespawn then return false end

  if core_trailerRespawn.getAttachedNonTrailer and core_trailerRespawn.getAttachedNonTrailer(trailerId) == vehicleId then
    return true
  end

  if core_trailerRespawn.isVehicleCoupledToTrailer then
    return core_trailerRespawn.isVehicleCoupledToTrailer(vehicleId, trailerId)
      or core_trailerRespawn.isVehicleCoupledToTrailer(trailerId, vehicleId)
  end

  local trailerData = core_trailerRespawn.getTrailerData and core_trailerRespawn.getTrailerData()
  if not trailerData then return false end

  local vehicleData = trailerData[vehicleId]
  local trailerDataEntry = trailerData[trailerId]
  return (type(vehicleData) == "table" and vehicleData.trailerId == trailerId)
    or (type(trailerDataEntry) == "table" and trailerDataEntry.trailerId == vehicleId)
end

local function checkCoupledGoal(goal)
  if not goal then return false end

  local vehicle = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(goal.vehicleId)
  local trailer = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(goal.trailerId)
  if not vehicle or not trailer then return false end

  local vehicleId = vehicle:getID()
  local trailerId = trailer:getID()

  return isAttachedCouplerPair(vehicleId, trailerId) or isTrailerRespawnCoupled(vehicleId, trailerId)
end

local function checkUnhitchedGoal(goal)
  return not checkCoupledGoal(goal)
end

local function checkDamageGoal(goal, delivery)
  -- Use module-level p variable

  if p then p:add("checkDamageGoal: " .. (goal.id or "unknown")) end

  local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goal)
  if #vehicleIds == 0 then return true end

  local maxDamage = goal.maxDamage or 10000

  -- Check if all vehicles are within damage limit
  for _, vehicleId in ipairs(vehicleIds) do
    local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleId)
    if not veh then
      goto continue -- If vehicle doesn't exist, skip it
    end

    local damage = veh.damage or 0
    if p then p:add("check damage: " .. vehicleId) end
    if damage > maxDamage then
      return false -- At least one vehicle exceeds damage limit
    end

    ::continue::
  end

  return true -- All vehicles within damage limit
end

local function getDistanceGoalMaxDistance(goal)
  -- Use module-level p variable

  if p then p:add("getDistanceGoalMaxDistance: " .. (goal.id or "unknown")) end

  local vehicleListA = goal.vehicleListA or {}
  local vehicleListB = goal.vehicleListB or {}

  if #vehicleListA == 0 or #vehicleListB == 0 then
    return 0, false
  end

  -- Get positions of all vehicles in list A (use cached positions)
  local positionsA = {}
  for _, vehicleId in ipairs(vehicleListA) do
    local pos = gameplay_freeformDelivery_utils.getVehiclePositionByDeliveryId(vehicleId)
    if pos then
      table.insert(positionsA, pos)
    end
  end
  if p then p:add("get positions A: " .. #positionsA) end

  -- Get positions of all vehicles in list B (use cached positions)
  local positionsB = {}
  for _, vehicleId in ipairs(vehicleListB) do
    local pos = gameplay_freeformDelivery_utils.getVehiclePositionByDeliveryId(vehicleId)
    if pos then
      table.insert(positionsB, pos)
    end
  end
  if p then p:add("get positions B: " .. #positionsB) end

  if #positionsA == 0 or #positionsB == 0 then
    return 0, false
  end

  -- Find maximum distance between any pair
  local maxDistance = 0
  for _, posA in ipairs(positionsA) do
    for _, posB in ipairs(positionsB) do
      local distance = posA:distance(posB)
      if distance > maxDistance then
        maxDistance = distance
      end
    end
  end
  if p then p:add("calculate max distance") end

  return maxDistance, true
end

local function checkDistanceGoal(goal, delivery)
  local maxDistance, valid = getDistanceGoalMaxDistance(goal)
  if not valid then
    return false
  end

  local failThreshold = goal.failThreshold or 1000
  return maxDistance <= failThreshold
end

function M.isDistanceGoalWarningActive(goal)
  local maxDistance, valid = getDistanceGoalMaxDistance(goal)
  if not valid then
    return false
  end

  local warningThreshold = goal.warningThreshold or 0
  local hideThreshold = warningThreshold * 0.9
  return maxDistance > hideThreshold
end

local function getGoalProgress(goal)
  -- Use module-level p variable

  -- For multi-vehicle goals, calculate partial progress
  if goal.type == "placement" and goal.vehicleIds and #goal.vehicleIds > 1 then
    if p then p:add("getGoalProgress multi-vehicle: " .. (goal.id or "unknown")) end
    local requiredAmount = goal.requiredAmount or #goal.vehicleIds
    local totalAmount = #goal.vehicleIds

    local siteObj = getSiteObject(goal.delivery, goal.targetAreaId)
    if not siteObj then
      return { total = totalAmount, requiredAmount = requiredAmount, inArea = 0, partial = false, complete = false }
    end

    local targetArea = findTargetArea(goal.delivery, goal.targetAreaId)
    if not targetArea then
      return { total = totalAmount, requiredAmount = requiredAmount, inArea = 0, partial = false, complete = false }
    end

    local inArea = 0
    for _, vehicleId in ipairs(goal.vehicleIds) do
      local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleId)
      if veh and gameplay_freeformDelivery_utils.checkVehicleInArea(veh, siteObj, targetArea.type) then
        inArea = inArea + 1
      end
    end
    if p then p:add("count vehicles in area: " .. inArea) end

    return {
      total = totalAmount,
      requiredAmount = requiredAmount,
      inArea = inArea,
      partial = inArea > 0 and inArea < requiredAmount,
      complete = inArea >= requiredAmount
    }
  else
    -- Single vehicle or damage goal
    local state = goalStates[goal.id]
    return {
      total = 1,
      inArea = (state and state.completed) and 1 or 0,
      partial = false,
      complete = (state and state.completed) or false
    }
  end
end

local function checkPrerequisiteRequirement(requiredGoalId, requirement)
  local requiredState = goalStates[requiredGoalId]
  if not requiredState then
    return false
  end

  local reqId = type(requirement) == "string" and requirement or (requirement.id or requirement.goalId)
  if reqId ~= requiredGoalId then
    return false
  end

  local reqState = type(requirement) == "table" and (requirement.state or "complete") or "complete"

  if reqState == "complete" or reqState == "completely_fulfilled" then
    return requiredState.completed
  elseif reqState == "not" or reqState == "not_fulfilled" then
    return not requiredState.completed
  else
    -- partial, partially_fulfilled, any, any_fulfilled
    local requiredGoal = goals[requiredGoalId]
    if not requiredGoal then
      return false
    end
    local progress = getGoalProgress(requiredGoal)
    if not progress then
      return false
    end
    return progress.partial or progress.complete
  end
end

local function checkPrerequisites(goal)
  -- Use module-level p variable

  if not goal.requires or #goal.requires == 0 then
    return true
  end

  if p then p:add("checkPrerequisites: " .. (goal.id or "unknown")) end

  -- All requirements must be fulfilled (AND logic)
  for _, requirement in ipairs(goal.requires) do
    local reqId = type(requirement) == "string" and requirement or (requirement.id or requirement.goalId)
    if not reqId or not checkPrerequisiteRequirement(reqId, requirement) then
      if p then p:add("prerequisite not met: " .. tostring(reqId)) end
      return false
    end
  end

  return true
end

local function shouldKeepGoalCompleted(goal)
  if not goal.stayCompletedAfterGoalId then
    return true
  end

  local state = goalStates[goal.stayCompletedAfterGoalId]
  return state and state.completed or false
end

local function createGoal(goalData, delivery, order)
  local goal = {
    id = goalData.id,
    type = goalData.type or "placement",
    required = goalData.required ~= false,
    requires = goalData.requires or {},
    label = goalData.label,
    subtext = goalData.subtext,
    stayCompleted = goalData.stayCompleted == true,
    stayCompletedAfterGoalId = goalData.stayCompletedAfterGoalId,
    removeOnComplete = goalData.removeOnComplete == true,
    showInTasklist = goalData.showInTasklist ~= false,
    showRequiredProgress = goalData.showRequiredProgress == true,
    delivery = delivery,
    order = order or 0
  }

  if goal.type == "placement" then
    if not goalData.targetAreaId then
      return nil, 'Placement goal missing targetAreaId: ' .. goalData.id
    end
    goal.targetAreaId = goalData.targetAreaId

    local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goalData)
    if #vehicleIds == 0 then
      return nil, 'Placement goal missing vehicleId or vehicleIds: ' .. goalData.id
    end
    goal.vehicleIds = vehicleIds
    goal.requiredAmount = goalData.requiredAmount
    if goal.requiredAmount == nil then
      goal.requiredAmount = #vehicleIds
    end
    if goalData.vehicleId then
      goal.vehicleId = goalData.vehicleId
    end

    local targetArea = findTargetArea(delivery, goalData.targetAreaId)
    goal.targetAreaName = targetArea and targetArea.name or goalData.targetAreaId
  elseif goal.type == "playerInVehicle" then
    local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goalData)
    if #vehicleIds == 0 then
      return nil, 'playerInVehicle goal missing vehicleId or vehicleIds: ' .. goalData.id
    end
    if #vehicleIds > 1 then
      return nil, 'playerInVehicle goal only supports a single vehicleId: ' .. goalData.id
    end
    goal.vehicleId = vehicleIds[1]
  elseif goal.type == "engineRunning" then
    local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goalData)
    if #vehicleIds == 0 then
      return nil, 'engineRunning goal missing vehicleId or vehicleIds: ' .. goalData.id
    end
    if #vehicleIds > 1 then
      return nil, 'engineRunning goal only supports a single vehicleId: ' .. goalData.id
    end
    goal.vehicleId = vehicleIds[1]
  elseif goal.type == "coupled" or goal.type == "unhitched" then
    if not goalData.vehicleId then
      return nil, goal.type .. ' goal missing vehicleId: ' .. goalData.id
    end
    if not goalData.trailerId then
      return nil, goal.type .. ' goal missing trailerId: ' .. goalData.id
    end
    goal.vehicleId = goalData.vehicleId
    goal.trailerId = goalData.trailerId
  elseif goal.type == "damage" then
    local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goalData)
    if #vehicleIds == 0 then
      return nil, 'Damage goal missing vehicleId or vehicleIds: ' .. goalData.id
    end
    goal.vehicleIds = vehicleIds
    if goalData.vehicleId then
      goal.vehicleId = goalData.vehicleId
    end
    goal.maxDamage = goalData.maxDamage or 10000
  elseif goal.type == "distance" then
    if not goalData.vehicleListA or #goalData.vehicleListA == 0 then
      return nil, 'Distance goal missing vehicleListA: ' .. goalData.id
    end
    if not goalData.vehicleListB or #goalData.vehicleListB == 0 then
      return nil, 'Distance goal missing vehicleListB: ' .. goalData.id
    end
    goal.vehicleListA = goalData.vehicleListA
    goal.vehicleListB = goalData.vehicleListB
    goal.warningThreshold = goalData.warningThreshold or 0
    goal.failThreshold = goalData.failThreshold or 1000
  else
    return nil, 'Unknown goal type: ' .. tostring(goal.type) .. ' for goal: ' .. goalData.id
  end

  return goal, nil
end

function M.setup(delivery)
  goals = {}
  goalStates = {}

  -- Clear caches
  targetAreaCache = {}
  siteObjectCache = {}

  if not delivery then
    log('W', logTag, 'setup called with nil delivery')
    return
  end

  log('I', logTag, string.format('Setting up goals for delivery: %s', delivery.name or "Unknown"))

  -- Pre-populate caches for all target areas
  if delivery.targetAreas then
    for _, area in ipairs(delivery.targetAreas) do
      targetAreaCache[area.id] = area
      if delivery.sites then
        local siteObj = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, area.type, area.siteId)
        if siteObj then
          siteObjectCache[area.id] = siteObj
        end
      end
    end
  end

  local goalCount = 0
  for i, goalData in ipairs(delivery.goals or {}) do
    if not goalData.id then
      log('E', logTag, 'Goal missing required id field')
      goto continue
    end

    local goal, errorMsg = createGoal(goalData, delivery, i - 1)
    if not goal then
      log('E', logTag, errorMsg)
      goto continue
    end

    goals[goalData.id] = goal
    goalStates[goalData.id] = {
      completed = false,
      lastCheck = false,
      active = false
    }
    goalCount = goalCount + 1

    ::continue::
  end

  -- Now that all goals are created, check prerequisites for each goal
  for goalId, goal in pairs(goals) do
    local prerequisitesMet = checkPrerequisites(goal)
    goalStates[goalId].active = prerequisitesMet
  end

  log('I', logTag, string.format('Created %d goals', goalCount))
end

function M.update(dtReal, dtSim, dtRaw, profiler)
  p = profiler -- Assign to module-level variable for local functions

  if not next(goals) then
    log('W', logTag, 'update() called but no goals to check')
    return
  end

  if p then p:add("goals initialization") end

  -- Update vehicle cache for all vehicles used in goals
  local vehiclesToCache = {}

  -- Helper function to add vehicle to cache
  local function addVehicleToCache(vehicleId)
    local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleId)
    if veh then
      vehiclesToCache[veh:getID()] = veh
    end
  end

  for goalId, goal in pairs(goals) do
    if goal.type == "placement" or goal.type == "damage" then
      local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goal)
      for _, vehicleId in ipairs(vehicleIds) do
        addVehicleToCache(vehicleId)
      end
    elseif goal.type == "engineRunning" then
      addVehicleToCache(goal.vehicleId)
    elseif goal.type == "coupled" or goal.type == "unhitched" then
      addVehicleToCache(goal.vehicleId)
      addVehicleToCache(goal.trailerId)
    elseif goal.type == "distance" then
      for _, vehicleId in ipairs(goal.vehicleListA or {}) do
        addVehicleToCache(vehicleId)
      end
      for _, vehicleId in ipairs(goal.vehicleListB or {}) do
        addVehicleToCache(vehicleId)
      end
    end
  end

  -- Update cache for all unique vehicles
  local vehicleCount = 0
  for _, veh in pairs(vehiclesToCache) do
    gameplay_freeformDelivery_utils.updateVehicleCache(veh)
    vehicleCount = vehicleCount + 1
  end
  if p then p:add("update vehicle cache: " .. vehicleCount) end

  -- Pass 1: evaluate completion using prerequisite state from the previous frame.
  -- This avoids activation/completion order glitches inside a single unordered pairs() loop.
  for goalId, goal in pairs(goals) do
    if not goal then
      log('E', logTag, 'Nil goal found for goalId: ' .. tostring(goalId))
      goto continue_completion
    end

    if not goal.delivery then
      log('E', logTag, 'Goal missing delivery reference: ' .. tostring(goalId))
      goto continue_completion
    end

    local state = goalStates[goalId]
    if not state then
      state = { completed = false, lastCheck = false, active = false }
      goalStates[goalId] = state
    end

    if p then p:add("goal completion pass: " .. goalId) end

    local prerequisitesMet = checkPrerequisites(goal)
    if not prerequisitesMet then
      goto continue_completion
    end

    local completed = false
    if goal.stayCompleted and state.completed and shouldKeepGoalCompleted(goal) then
      completed = true
    else
      if goal.type == "placement" then
        completed = checkPlacementGoal(goal, goal.delivery)
      elseif goal.type == "playerInVehicle" then
        completed = checkPlayerInVehicleGoal(goal)
      elseif goal.type == "engineRunning" then
        completed = checkEngineRunningGoal(goal)
      elseif goal.type == "coupled" then
        completed = checkCoupledGoal(goal)
      elseif goal.type == "unhitched" then
        completed = checkUnhitchedGoal(goal)
      elseif goal.type == "damage" then
        completed = checkDamageGoal(goal, goal.delivery)
      elseif goal.type == "distance" then
        completed = checkDistanceGoal(goal, goal.delivery)
      else
        log('W', logTag, 'Unknown goal type: ' .. tostring(goal.type) .. ' for goalId: ' .. tostring(goalId))
      end
    end

    if completed ~= state.lastCheck then
      state.lastCheck = completed
      state.completed = completed

      if completed then
        log('I', logTag, 'Goal completed: ' .. goalId)
        if p then p:add("goal completed: " .. goalId) end
      end
    end

    ::continue_completion::
  end

  -- Pass 2: recompute activation using completion results from pass 1.
  for goalId, goal in pairs(goals) do
    if not goal then
      goto continue_activation
    end

    local state = goalStates[goalId]
    if not state then
      state = { completed = false, lastCheck = false, active = false }
      goalStates[goalId] = state
    end

    if p then p:add("goal activation pass: " .. goalId) end
    local prerequisitesMet = checkPrerequisites(goal)
    local wasActive = state.active
    state.active = prerequisitesMet

    if prerequisitesMet and not wasActive then
      log('I', logTag, 'Goal became active: ' .. goalId)
    end

    ::continue_activation::
  end

  if p then p:add("goals loop complete") end
end

function M.getProgress()
  local total, completed, required, requiredCompleted = 0, 0, 0, 0

  for _, goal in pairs(goals) do
    local state = goalStates[goal.id]
    if state and state.active then
      total = total + 1
      if state.completed then
        completed = completed + 1
      end
      if goal.required then
        required = required + 1
        if state.completed then
          requiredCompleted = requiredCompleted + 1
        end
      end
    end
  end

  return {
    total = total,
    completed = completed,
    required = required,
    requiredCompleted = requiredCompleted,
    allRequiredComplete = required > 0 and requiredCompleted >= required
  }
end

function M.getGoals()
  -- Return only active goals (prerequisites met)
  local activeGoals = {}
  for goalId, goal in pairs(goals) do
    local state = goalStates[goalId]
    if state and state.active then
      activeGoals[goalId] = goal
    end
  end
  return activeGoals
end

function M.getAllGoals()
  return goals
end

function M.getGoalState(goalId)
  return goalStates[goalId]
end

function M.getGoalProgress(goalId)
  local goal = goals[goalId]
  if not goal then return nil end
  return getGoalProgress(goal)
end

function M.isGoalActive(goalId)
  local state = goalStates[goalId]
  return state and state.active or false
end

function M.getGoalsByTargetArea(targetAreaId)
  local result = {}
  for _, goal in pairs(goals) do
    if goal.targetAreaId == targetAreaId then
      table.insert(result, goal)
    end
  end
  return result
end

function M.getGoalsByType(goalType)
  local result = {}
  for _, goal in pairs(goals) do
    if goal.type == goalType then
      table.insert(result, goal)
    end
  end
  return result
end

function M.areAllGoalsInAreaComplete(areaId)
  local areaGoals = M.getGoalsByTargetArea(areaId)
  if #areaGoals == 0 then
    return false
  end
  for _, goal in ipairs(areaGoals) do
    local state = goalStates[goal.id]
    if not state or not state.completed then
      return false
    end
  end
  return true
end

local function areAllGoalsCompleted()
  if not goals or not next(goals) then
    return false
  end

  -- Check all active goals
  for goalId, goal in pairs(goals) do
    local state = goalStates[goalId]
    if state and state.active then
      if not state.completed then
        return false
      end
    end
  end

  return true
end

local function areAllRequiredGoalsCompleted()
  if not goals or not next(goals) then
    return false
  end

  local hasRequiredActive = false
  for goalId, goal in pairs(goals) do
    if not goal.required then
      goto continue
    end
    local state = goalStates[goalId]
    if state and state.active then
      hasRequiredActive = true
      if not state.completed then
        return false
      end
    end
    ::continue::
  end

  return hasRequiredActive
end

function M.updateCompletionTimer(dtReal)
  if not areAllRequiredGoalsCompleted() then
    -- Reset timer if any goal becomes incomplete
    if completionTimer ~= nil then
      completionTimer = nil
      -- Remove completion message from tasklist
      guihooks.trigger("DiscardTasklistItem", completionMessageId)
    end
    return false
  end

  -- All goals completed - start or update timer
  if completionTimer == nil then
    completionTimer = completionTimerDuration
    -- Add completion message to tasklist
    guihooks.trigger("SetTasklistTask", {
      id = completionMessageId,
      type = "message",
      label = contextTranslate(Text.allGoalsCompleted, { seconds = math.ceil(completionTimer) }),
      done = false,
      fail = false
    })
    return false
  end

  -- Update timer
  completionTimer = completionTimer - dtReal
  if completionTimer <= 0 then
    completionTimer = nil
    -- Remove completion message
    guihooks.trigger("DiscardTasklistItem", completionMessageId)
    return true -- Signal that delivery should finish
  else
    -- Update message with remaining time
    guihooks.trigger("SetTasklistTask", {
      id = completionMessageId,
      type = "message",
      label = contextTranslate(Text.allGoalsCompleted, { seconds = math.ceil(completionTimer) }),
      done = false,
      fail = false
    })
    return false
  end
end

function M.getCompletionTimer()
  return completionTimer
end

-- Hide goals from UI (tasklist) but keep internal state for evaluation
function M.hideFromTasklist()
  -- Remove completion message if it exists
  guihooks.trigger("DiscardTasklistItem", completionMessageId)
  -- Stop completion timer (but don't clear goals/goalStates)
  completionTimer = nil
end

-- Full cleanup: removes everything (for teardown)
function M.cleanup()
  goals = {}
  goalStates = {}
  completionTimer = nil
  pendingEngineRunningRequests = {}
  targetAreaCache = {}
  siteObjectCache = {}
  -- Clear vehicle cache
  gameplay_freeformDelivery_utils.clearVehicleCache()
  -- Remove completion message if it exists
  guihooks.trigger("DiscardTasklistItem", completionMessageId)
end

return M
