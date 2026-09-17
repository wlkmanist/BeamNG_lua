-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { 'gameplay_freeformDelivery_utils', 'gameplay_freeformDelivery_routes', 'core_groundMarkers' }
local logTag = "freeformDelivery_tasklist"
local p

local taskIds = {}
local lastTasklistState = nil -- Cache last state to avoid unnecessary updates
local routeMessageIds = {} -- Track route message IDs separately
local routePromptShown = false -- Track if route prompt has been shown and cleared
local pendingDiscards = {} -- Track tasks scheduled for delayed discard: taskId -> true
local discardedGoals = {} -- Track goal IDs that have been discarded: goalId -> true
local discardDelay = 2.0 -- Delay in seconds before discarding completed goals with removeOnComplete

local Text = {
  title = "bigMap.missionLabels.freeformDelivery",
  delivery = "missions.freeformDelivery.common.bigmapGroup.delivery.label",
  customGoalProgress = "missions.freeformDelivery.common.goal.customProgress",
  placeVehiclesInAreaProgress = "missions.freeformDelivery.common.goal.placeVehiclesInAreaProgress",
  placeVehiclesInArea = "missions.freeformDelivery.common.goal.placeVehiclesInArea",
  placeVehicleInArea = "missions.freeformDelivery.common.goal.placeVehicleInArea",
  startEngine = "missions.freeformDelivery.common.goal.startEngineGeneric",
  dontDamageCargo = "missions.freeformDelivery.common.goal.dontDamageCargo",
  dontDamageAnyCargo = "missions.freeformDelivery.common.goal.dontDamageAnyCargo",
  keepVehiclesWithin = "missions.freeformDelivery.common.goal.keepVehiclesWithin",
  hitchTrailer = "missions.freeformDelivery.common.goal.hitchTrailer.label",
  unhitchTrailer = "missions.freeformDelivery.common.goal.unhitchTrailer.label",
  completeGoal = "missions.freeformDelivery.common.goal.completeGoal",
  routePromptSingle = "missions.freeformDelivery.common.routePrompt.single",
  routePromptMultiple = "missions.freeformDelivery.common.routePrompt.multiple",
}

local function translateText(text)
  if text == nil then return nil end
  if core_locales and core_locales.translateWithOrWithoutContext then
    return core_locales.translateWithOrWithoutContext(text)
  end
  if type(text) == "table" and text.txt then
    return _tr(text.txt)
  end
  if type(text) == "string" then
    return _tr(text)
  end
  return text
end

local function contextTranslate(key, vars)
  if core_locales and core_locales.contextTranslate then
    return core_locales.contextTranslate(key, vars)
  end
  return _tr(key)
end

local function getRadialActionsTranslationKey()
  if gameplay_missions_missionManager
    and gameplay_missions_missionManager.getForegroundMissionId
    and gameplay_missions_missionManager.getForegroundMissionId() then
    return "ui.radialmenu2.challengeActions"
  end
  return "ui.radialmenu2.freeroamActions"
end

local function formatGoalLabel(goal, progress)
  if goal.label then
    local label = translateText(goal.label)
    local total = goal.requiredAmount or #gameplay_freeformDelivery_utils.getVehicleIds(goal)

    if total > 1 then
      -- Show progress for multi-vehicle goals even with custom label
      local goalProgress = gameplay_freeformDelivery_goals.getGoalProgress(goal.id)
      if goalProgress then
        local displayTotal = goal.showRequiredProgress and goalProgress.requiredAmount or goalProgress.total
        return contextTranslate(Text.customGoalProgress, {
          label = label,
          completed = math.min(goalProgress.inArea, displayTotal),
          total = displayTotal
        })
      end
      return label
    else
      return label
    end
  end

  if goal.type == "placement" then
    local total = goal.requiredAmount or #gameplay_freeformDelivery_utils.getVehicleIds(goal)

    if total > 1 then
      -- Show progress for multi-vehicle goals
      local goalProgress = gameplay_freeformDelivery_goals.getGoalProgress(goal.id)
      if goalProgress then
        local displayTotal = goal.showRequiredProgress and goalProgress.requiredAmount or goalProgress.total
        return contextTranslate(Text.placeVehiclesInAreaProgress, {
          area = translateText(goal.targetAreaName) or goal.targetAreaId,
          completed = math.min(goalProgress.inArea, displayTotal),
          total = displayTotal
        })
      end
      return contextTranslate(Text.placeVehiclesInArea, { area = translateText(goal.targetAreaName) or goal.targetAreaId })
    else
      return contextTranslate(Text.placeVehicleInArea, { area = translateText(goal.targetAreaName) or goal.targetAreaId })
    end
  elseif goal.type == "engineRunning" then
    return _tr(Text.startEngine)
  elseif goal.type == "damage" then
    return _tr(Text.dontDamageCargo)
  elseif goal.type == "distance" then
    return contextTranslate(Text.keepVehiclesWithin, { distance = string.format("%.0fm", goal.failThreshold or 1000) })
  elseif goal.type == "coupled" then
    return _tr(Text.hitchTrailer)
  elseif goal.type == "unhitched" then
    return _tr(Text.unhitchTrailer)
  end

  return _tr(Text.completeGoal)
end

-- Update route message in tasklist (called by routes.lua)
function M.updateRouteMessage()
  -- Clear existing route messages
  for _, routeId in ipairs(routeMessageIds) do
    guihooks.trigger("DiscardTasklistItem", routeId)
  end
  routeMessageIds = {}

  -- Check if a route is currently active using groundMarkers
  local hasRoute = false
  if core_groundMarkers and core_groundMarkers.currentlyHasTarget then
    hasRoute = core_groundMarkers.currentlyHasTarget()
  end

  local routeCount = gameplay_freeformDelivery_routes.getRouteCount()

  if routeCount > 0 then
    if hasRoute then
      -- Route is set - clear message and mark as shown
      routePromptShown = true
      if p then p:add("route active, message cleared") end
    else
      -- No route set - only show prompt if we haven't shown it before
      if not routePromptShown then
        local label = nil
        local radialActionsKey = getRadialActionsTranslationKey()
        if routeCount == 1 then
          label = contextTranslate(Text.routePromptSingle, {
            radialActions = radialActionsKey,
            delivery = Text.delivery,
            map = "ui.dashboard.bigmap"
          })
        else
          label = contextTranslate(Text.routePromptMultiple, {
            count = routeCount,
            radialActions = radialActionsKey,
            delivery = Text.delivery,
            map = "ui.dashboard.bigmap"
          })
        end

        guihooks.trigger("SetTasklistTask", {
          id = "delivery_route_prompt",
          type = "message",
          label = label,
          subtext = nil,
          done = false,
          fail = false
        })
        table.insert(routeMessageIds, "delivery_route_prompt")
        if p then p:add("create route prompt message") end
      end
    end
  end
end



local function updateTasklist()
  -- Use module-level p variable

  if p then p:add("tasklist initialization") end

  local allGoals = gameplay_freeformDelivery_goals.getGoals()
  local currentProgress = gameplay_freeformDelivery_goals.getProgress()
  if p then p:add("get goals and progress") end

  -- Clear existing tasks
  for _, taskId in ipairs(taskIds) do
    guihooks.trigger("DiscardTasklistItem", taskId)
  end
  taskIds = {}

  if p then p:add("clear existing tasks") end

  local placementGoals = {}
  local damageGoals = {}
  local distanceGoals = {}

  for _, goal in pairs(allGoals) do
    if goal.showInTasklist == false then
      goto continue
    end

    -- Only show active goals (prerequisites met)
    if not gameplay_freeformDelivery_goals.isGoalActive(goal.id) then
      goto continue
    end

    local state = gameplay_freeformDelivery_goals.getGoalState(goal.id)
    if discardedGoals[goal.id] and state and not state.completed then
      discardedGoals[goal.id] = nil
      pendingDiscards["delivery_goal_" .. goal.id] = nil
    end

    -- Skip goals that have been discarded
    if discardedGoals[goal.id] then
      goto continue
    end

    if goal.type == "placement" or goal.type == "playerInVehicle" or goal.type == "engineRunning" or goal.type == "coupled" or goal.type == "unhitched" then
      table.insert(placementGoals, goal)
    elseif goal.type == "damage" then
      table.insert(damageGoals, goal)
    elseif goal.type == "distance" then
      table.insert(distanceGoals, goal)
    end

    ::continue::
  end
  if p then p:add("group goals by type") end

  local function byOrder(a, b)
    return (a.order or 0) < (b.order or 0)
  end
  table.sort(placementGoals, byOrder)
  table.sort(damageGoals, byOrder)
  table.sort(distanceGoals, byOrder)

  if currentProgress.total == 0 then
    log('W', logTag, 'No goals detected!')
  end

  local function createTask(taskId, label, subtext, done, goal)
    guihooks.trigger("SetTasklistTask", {
      id = taskId,
      type = "goal",
      label = label,
      subtext = translateText(subtext),
      done = done,
      fail = false
    })
    table.insert(taskIds, taskId)

    -- If goal is completed and has removeOnComplete, schedule delayed discard
    if done and goal and goal.removeOnComplete and not pendingDiscards[taskId] then
      pendingDiscards[taskId] = true
      -- Mark goal as discarded so it won't be re-added
      discardedGoals[goal.id] = true
      guihooks.trigger("DiscardTasklistItem", taskId, discardDelay)
    end
  end

  -- Add one task per placement goal
  for _, goal in ipairs(placementGoals) do
    if not discardedGoals[goal.id] then
      local state = gameplay_freeformDelivery_goals.getGoalState(goal.id)
      createTask("delivery_goal_" .. goal.id,
                 formatGoalLabel(goal, currentProgress),
                 goal.subtext,
                 state and state.completed or false,
                 goal)
    end
  end
  if p then p:add("create placement tasks") end

  -- Add damage goals as a group
  if #damageGoals > 0 then
    -- Filter out discarded damage goals
    local activeDamageGoals = {}
    for _, goal in ipairs(damageGoals) do
      if not discardedGoals[goal.id] then
        table.insert(activeDamageGoals, goal)
      end
    end

    -- Only create task if there are non-discarded damage goals
    if #activeDamageGoals > 0 then
      local allDamageComplete = true
      local firstDamageGoal = activeDamageGoals[1]
      for _, goal in ipairs(activeDamageGoals) do
        local state = gameplay_freeformDelivery_goals.getGoalState(goal.id)
        if not state or not state.completed then
          allDamageComplete = false
        end
      end
      createTask("delivery_damage", _tr(Text.dontDamageAnyCargo), nil, allDamageComplete, firstDamageGoal)
    end
  end
  if p then p:add("create damage tasks") end

  -- Add distance goals (only show when warning threshold is exceeded)
  for _, goal in ipairs(distanceGoals) do
    if gameplay_freeformDelivery_goals.isDistanceGoalWarningActive(goal) then
      local state = gameplay_freeformDelivery_goals.getGoalState(goal.id)
      local label = translateText(goal.label) or contextTranslate(Text.keepVehiclesWithin, { distance = string.format("%.0fm", goal.failThreshold or 1000) })
      createTask("delivery_distance_" .. goal.id, label, goal.subtext, state and state.completed or false, goal)
    end
  end
  if p then p:add("create distance tasks") end

end

function M.setup(delivery)
  if not delivery then
    log('W', logTag, 'setup called with nil delivery')
    return
  end

  log('I', logTag, string.format('Setting up tasklist: %s', delivery.name or "Unknown"))

  -- Clear existing tasks
  ui_appContainers.showApp("topLeft", "tasks")
  guihooks.trigger("ClearTasklist")
  taskIds = {}
  lastTasklistState = nil -- Reset state cache
  routeMessageIds = {}
  routePromptShown = false -- Reset for new delivery
  pendingDiscards = {} -- Reset pending discards
  discardedGoals = {} -- Reset discarded goals

  -- Set header
  guihooks.trigger("SetTasklistHeader", {
    label = translateText(delivery.name) or _tr(Text.title),
    --subtext = delivery.description or ""
  })

  -- Initial update
  updateTasklist()

  -- Initial route message update
  M.updateRouteMessage()
end

function M.update(profiler)
  p = profiler -- Assign to module-level variable for local functions

  -- Update odometer tasklist message
  gameplay_freeformDelivery_odometer.updateTasklistMessage()

  -- Get current progress
  local currentProgress = gameplay_freeformDelivery_goals.getProgress()

  -- Build state hash to detect changes
  local stateHash = string.format("%d_%d_%d_%d",
    currentProgress.total or 0,
    currentProgress.completed or 0,
    currentProgress.required or 0,
    currentProgress.requiredCompleted or 0)

  local allGoals = gameplay_freeformDelivery_goals.getGoals()
  local goalStates = {}
  local goalCount = 0

  for goalId, goal in pairs(allGoals) do
    local state = gameplay_freeformDelivery_goals.getGoalState(goalId)
    if state then
      local goalHash = string.format("%s_%s_%s", goalId,
        state.completed and "1" or "0",
        state.active and "1" or "0")

      -- Track partial progress for multi-vehicle placement goals so task labels
      -- (for example "2/16") update in realtime.
      if goal.type == "placement" then
        local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goal)
        if #vehicleIds > 1 then
          local goalProgress = gameplay_freeformDelivery_goals.getGoalProgress(goalId)
          local inArea = goalProgress and goalProgress.inArea or 0
          local total = goalProgress and goalProgress.total or #vehicleIds
          goalHash = string.format("%s_%d_%d", goalHash, inArea, total)
        end
      end

      goalStates[goalId] = goalHash
      goalCount = goalCount + 1
    end
  end

  local needsUpdate = not lastTasklistState or lastTasklistState.hash ~= stateHash or (lastTasklistState.goalCount or 0) ~= goalCount
  if not needsUpdate and lastTasklistState and lastTasklistState.goalStates then
    for goalId, goalHash in pairs(goalStates) do
      if lastTasklistState.goalStates[goalId] ~= goalHash then
        needsUpdate = true
        break
      end
    end
  end

  if needsUpdate then
    updateTasklist()
    lastTasklistState = {
      hash = stateHash,
      goalStates = goalStates,
      goalCount = goalCount
    }
  end
end

function M.cleanup()
  -- Clear header
  guihooks.trigger("SetTasklistHeader", nil)

  -- Clear tasks
  for _, taskId in ipairs(taskIds) do
    guihooks.trigger("DiscardTasklistItem", taskId)
  end
  taskIds = {}

  -- Clear route messages
  for _, routeId in ipairs(routeMessageIds) do
    guihooks.trigger("DiscardTasklistItem", routeId)
  end
  routeMessageIds = {}

  lastTasklistState = nil
end

return M
