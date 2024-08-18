local M = {}
M.dependencies = {"util_stepHandler"}
local dParcelManager, dCargoScreen, dGeneral, dGenerator, dPages, dProgress, dTasklist
local step
M.onCareerActivated = function()
  dParcelManager = career_modules_delivery_parcelManager
  dCargoScreen = career_modules_delivery_cargoScreen
  dGeneral = career_modules_delivery_general
  dGenerator = career_modules_delivery_generator
  dPages = career_modules_delivery_pages
  dProgress = career_modules_delivery_progress
  dTasklist = career_modules_delivery_tasklist
  step = util_stepHandler
end

local vehicleTasks = {}
local taskThatChangedThisFrame

-- setup for data
local function expandTasks(offerTask, offer)
  local tasks = {}
  if offer.task.type == "trailerDropOff" then
    tasks = {
      {
        type = "coupleTrailer",
      }, {
        type = "bringToDestination",
        destination = offerTask.destination,
        backOn = "unCouple",
      --}, {
--        type = "putIntoParkingSpot",
  --      destination = offerTask.destination,
    --    forwardOn = "uncouple",
      }, {
        type = "confirmDropOff",
        destination = offerTask.dropOff,
      }
    }
  elseif offer.task.type == "vehicleDropOff" then
    tasks = {
      {
        type = "enterVehicle",
      }, {
        type = "bringToDestination",
        destination = offerTask.destination,
        backOn = "exitVehicle",
      }, {
        type = "confirmDropOff",
        destination = offerTask.dropOff,
      }
    }
  end
  return tasks
end

local function navigateToTask(task)
  local activeTaskStep = task.tasks[task.activeTaskIndex]
  if activeTaskStep.destination then
    local destinationPos = dGenerator.getParkingSpotByPath(activeTaskStep.destination.psPath).pos
    core_groundMarkers.setFocus(destinationPos)
  elseif activeTaskStep.type == "enterVehicle" or activeTaskStep.type == "coupleTrailer" then
    local veh = be:getObjectByID(task.vehId)
    if veh then
      core_groundMarkers.setFocus(veh:getPosition())
    end
  end
end

local function addVehicleTask(vehId, offer)
  log("I","","addVehicleTask")
  local taskData = {
    vehId = vehId,
    offer = offer,
    tasks = expandTasks(offer.task, offer),
    activeTaskIndex = 1,
    startedTimestamp = dGeneral.time(),
  }
  table.insert(vehicleTasks, taskData)
  dTasklist.sendCargoToTasklist()
  navigateToTask(taskData)
end
M.addVehicleTask = addVehicleTask


-- checking task completeness

--[[
local function onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == objId1 or taskData.vehId == objId2 then
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "coupleTrailer" then
        -- forward -> bringToDestination
        activeTask.coupled = true
      end
      if activeTask.type == "putIntoParkingSpot" then
        activeTask.uncoupled = false
      end
    end
  end
end

local function onCouplerDetached(objId1, objId2, nodeId, obj2nodeId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == objId1 or taskData.vehId == objId2 then
      local activeTask = taskData.tasks[taskData.activeTaskIndex]
      if activeTask.type == "bringToDestination" then
        -- back to -> coupleTrailer
        activeTask.uncoupled = true
      end
      if activeTask.type == "putIntoParkingSpot" then
        activeTask.uncoupled = true
      end
    end
  end
end
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
]]

local bringToDestinationThreshold = 20 * 20
local function processActiveTask(taskData)
  local taskIndexBefore = taskData.activeTaskIndex
  local activeTask = taskData.tasks[taskData.activeTaskIndex]
  if activeTask.type == "coupleTrailer" then
    -- check if coupled to trailer, go forward if so
    if core_trailerRespawn.getAttachedNonTrailer(taskData.vehId) == be:getPlayerVehicleID(0) then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end

  if activeTask.type == "enterVehicle" then
    -- check if coupled to trailer, go forward if so
    if be:getPlayerVehicleID(0) == taskData.vehId then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end

  if activeTask.type == "bringToDestination" then
    -- check if uncoupled, go back if so
    if activeTask.backOn == "uncouple" and (core_trailerRespawn.getAttachedNonTrailer(taskData.vehId) ~= be:getPlayerVehicleID(0)) then
      activeTask.uncoupled = nil
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
    if activeTask.backOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
    -- check if close enough to destination
    local trailerVeh = scenetree.findObjectById(taskData.vehId)
    local trailerPos = trailerVeh:getPosition()
    local destinationPos = dGenerator.getLocationCoordinates(activeTask.destination)
    if (trailerPos - destinationPos):squaredLength() <= bringToDestinationThreshold then
      taskData.activeTaskIndex = taskData.activeTaskIndex + 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end
  if activeTask.type == "putIntoParkingSpot" then
    -- check if parked in spot and uncoupled
    local trailerVeh = scenetree.findObjectById(taskData.vehId)
    local destinationPs = dGenerator.getParkingSpotByPath(activeTask.destination.psPath)
    local valid, res = destinationPs:checkParking(taskData.vehId)
    simpleDebugText3d(valid and "Valid" or "Invalid", destinationPs.pos + vec3(0,0,2), 0.25, valid and ColorF(0,1,0,0.25) or ColorF(1,0,0,0.25))
    destinationPs:drawDebug()
    if valid then
      if activeTask.forwardOn == "unCouple" and (core_trailerRespawn.getAttachedNonTrailer(taskData.vehId) ~= be:getPlayerVehicleID(0)) then
        taskData.activeTaskIndex = taskData.activeTaskIndex + 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
      if activeTask.forwardOn == "exitVehicle" and be:getPlayerVehicleID(0) ~= taskData.vehId then
        taskData.activeTaskIndex = taskData.activeTaskIndex + 1
        dTasklist.updateTasklistForOfferId(taskData.offer.id)
      end
    end

    -- check if too far away
    local trailerPos = trailerVeh:getPosition()
    local destinationPos = dGenerator.getLocationCoordinates(activeTask.destination)

    if (trailerPos - destinationPos):squaredLength() >= bringToDestinationThreshold*1.5 then
      taskData.activeTaskIndex = taskData.activeTaskIndex - 1
      dTasklist.updateTasklistForOfferId(taskData.offer.id)
    end
  end
  if activeTask.type == "confirmDropOff" then

  end

  if taskIndexBefore ~= taskData.activeTaskIndex then
    taskThatChangedThisFrame = taskData
  end
end

local function checkDeliveredCargo()
  local affectedOfferIds = {}
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type == "confirmDropOff" then
      local veh = be:getObjectByID(taskData.vehId)
      if veh then
        local sequence = {
          step.makeStepReturnTrueFunction(function(step)
            if not step.sentCommand then
              step.sentCommand = true
              core_vehicleBridge.requestValue(veh, function(res)
                local partConditions = res.result
                if tableSize(partConditions) > 0 then
                  taskData.brokenPartsNumber = career_modules_insurance.getNumberOfBrokenParts(partConditions)
                  taskData.partsNumber = tableSize(partConditions)
                end
                step.brokenPartsRequested = true
              end, 'getPartConditions')
            end
            return step.brokenPartsRequested or false
          end),
          step.makeStepReturnTrueFunction(function(step)
            if not step.sentCommand then
              step.sentCommand = true
              local vehData = core_vehicle_manager.getVehicleData(taskData.vehId)
              core_vehicleBridge.requestValue(veh, function(res)
                step.odometerComplete = true
                local part = res.result[vehData.config.mainPartName]
                taskData.offer.endingOdometer = part.odometer
              end, 'getPartConditions')
            end
            return step.odometerComplete or false
          end),
          step.makeStepReturnTrueFunction(function() taskData.finished = true return true end)
        }
        step.startStepSequence(sequence, callback)

      else
        taskData.finished = true
      end
      taskData.dropOffPsPath = activeTask.destination.psPath
      affectedOfferIds[taskData.offer.id] = true
    end
  end
  return affectedOfferIds
end
M.checkDeliveredCargo = checkDeliveredCargo

local function canDropOffCargoAtPsPath(psPath)
  local vehsClose, trailersClose = 0,0
  for _, taskData in ipairs(vehicleTasks) do
    local activeTask = taskData.tasks[taskData.activeTaskIndex]
    if activeTask.type == "confirmDropOff" and psPath == activeTask.destination.psPath then
      if taskData.offer.data.type == "vehicle" then vehsClose = vehsClose + 1 end
      if taskData.offer.data.type == "trailer" then trailersClose = trailersClose +1 end
    end
  end
  return vehsClose, trailersClose
end
M.canDropOffCargoAtPsPath = canDropOffCargoAtPsPath

local taskDataRemoveThisFrame = false
local function processFinished(taskData)
  if taskData.finished then
    taskDataRemoveThisFrame = true

    local psPos = dGenerator.getParkingSpotByPath(taskData.dropOffPsPath).pos
    local _, unicycleId
    if be:getPlayerVehicleID(0) == taskData.vehId then
      _, unicycleId = gameplay_walk.setWalkingMode(true, psPos)
    end
    local veh = scenetree.findObjectById(taskData.vehId)
    if veh then veh:delete() end

    local unicycle = scenetree.findObjectById(unicycleId)
    if unicycle then
      spawn.safeTeleport(unicycle, psPos)
    end


    taskData.remove = true


    local resultElement = {
      type = taskData.offer.data.type,
      offerId = taskData.offer.id,
      label = taskData.offer.name,
      originalRewards = deepcopy(taskData.offer.rewards),
      breakdown = {},
      adjustedRewards = {},
    }

    log("I","","Finished Vehicle: " .. taskData.vehId)
    local brokenPartsRelative = taskData.brokenPartsNumber / taskData.partsNumber
    log("I","",string.format("Broken Parts: %0.1f%% (%d / %d)", brokenPartsRelative*100, taskData.brokenPartsNumber, taskData.partsNumber))
    local distanceDriven = (taskData.offer.endingOdometer - taskData.offer.startingOdometer)
    log("I","",string.format("Driven Distance: %0.3fkm (%0.1f%% of allowed %0.3fkm)", distanceDriven/1000, 100*distanceDriven/taskData.offer.data.originalDistance, 1.2*taskData.offer.data.originalDistance/1000))
    local timeTaken = dGeneral.time() - taskData.startedTimestamp
    local expectedTime = (taskData.offer.data.originalDistance/12 + 30 )
    log("I","",string.format("Time Taken: %0.1f seconds (expected: %0.1fs)", timeTaken, expectedTime))


    local brokenPartsThreshold = career_modules_insurance.getBrokenPartsThreshold()

    local rewards = deepcopy(taskData.offer.rewards)
    local origMoney = rewards.money



    local partsBreakdown = {}
    local brokenPartsMultipler = 1
    if brokenPartsRelative >= 0.25 then
      brokenPartsMultipler = 0
      partsBreakdown.label = "Excessive Damage"
      partsBreakdown.rewards = {money = -origMoney}
    elseif taskData.brokenPartsNumber >= brokenPartsThreshold then
      brokenPartsMultipler = 0.8 - 0.6*(brokenPartsRelative*4)
      partsBreakdown.label = "Slight Damage"
      partsBreakdown.rewards = {money = -(1-brokenPartsMultipler)*origMoney}
    else
      partsBreakdown.label = "No Damage"
      partsBreakdown.rewards = {money = 0}
    end

    table.insert(resultElement.breakdown, partsBreakdown)

    if brokenPartsMultipler == 1 then
      if distanceDriven/taskData.offer.data.originalDistance < 1.2 then
        table.insert(resultElement.breakdown, {label = "No Detours", rewards = {money=origMoney*0.15+10}})
      end
      if timeTaken < expectedTime then
        table.insert(resultElement.breakdown, {label = "No Delays", rewards = {money=origMoney*0.15+10}})
      end
    end

    resultElement.adjustedRewards = deepcopy(resultElement.originalRewards)
    for _, bd in ipairs(resultElement.breakdown) do
      for key, amount in pairs(bd.rewards) do
        resultElement.adjustedRewards[key] = resultElement.adjustedRewards[key] + amount
      end
    end

    dTasklist.clearTasklistForOfferId(taskData.offer.id)
    taskData.offer.rewards = resultElement.adjustedRewards

    dProgress.onVehicleTaskFinished(taskData.offer)
    dProgress.addVehicleTasksResult(resultElement)



  end
end

local function processGiveBack(taskData)
  if taskData.giveBack then
    taskDataRemoveThisFrame = true
    if be:getPlayerVehicleID(0) == taskData.vehId then
      gameplay_walk.setWalkingMode(true)
    end
    local veh = scenetree.findObjectById(taskData.vehId)
    if veh then veh:delete() end
    dTasklist.clearTasklistForOfferId(taskData.offer.id)
    guihooks.trigger('Message',{clear = nil, ttl = 10, msg = string.format("Delivery %s abandoned. %0.2f$ penalty",taskData.offer.name, (taskData.offer.rewards.money or 0) * dGeneral.getDeliveryAbandonPenaltyFactor()), category = "delivery", icon = "local_shipping"})

    career_modules_playerAttributes.addAttributes({money=-(taskData.offer.rewards.money or 0) * dGeneral.getDeliveryAbandonPenaltyFactor()}, {tags={"gameplay", "delivery","fine"}, label="Abandoned Delivery Penalty for " .. taskData.offer.name})
    taskData.remove = true
  end
end



local toDeleteActiveTrailerIndexes = {}
local function onUpdate(dtReal, dtSim, dtRaw)
  taskThatChangedThisFrame = nil
  for _, taskData in ipairs(vehicleTasks) do
    processActiveTask(taskData)
  end
  for _, taskData in ipairs(vehicleTasks) do
    processFinished(taskData)
  end
  for _, taskData in ipairs(vehicleTasks) do
    processGiveBack(taskData)
  end

  local idsToRemove = {}
  if taskDataRemoveThisFrame then
    for id, taskData in ipairs(vehicleTasks) do
      if taskData.remove then
        table.insert(idsToRemove, id)
      end
    end
    -- remove from the back to avoid ids moving
    for _, id in ipairs(arrayReverse(idsToRemove)) do
      local taskToBeRemoved = vehicleTasks[id]
      table.remove(vehicleTasks, id)
    end

    dGeneral.checkExitDeliveryMode()
  end

  if taskThatChangedThisFrame then
    navigateToTask(taskThatChangedThisFrame)
  elseif not tableIsEmpty(idsToRemove) and not tableIsEmpty(vehicleTasks) then
    -- Navigate to the next task if one has been removed
    navigateToTask(vehicleTasks[#vehicleTasks])
  end

  taskDataRemoveThisFrame = false
end
M.onUpdate = onUpdate


local function getTargetDestinationsForActiveTasks()
  local ret = {}
  for id, taskData in ipairs(vehicleTasks) do
    for _, task in ipairs(taskData.tasks) do
      if task.destination then
        table.insert(ret, task.destination)
      end
    end
  end
  return ret
end
M.getTargetDestinationsForActiveTasks = getTargetDestinationsForActiveTasks


local function isVehicleDeliveryVehicle(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId then
      return true
    end
  end
  return false
end
M.isVehicleDeliveryVehicle = isVehicleDeliveryVehicle

local function giveBackDeliveryVehicle(vehId)
  for _, taskData in ipairs(vehicleTasks) do
    if taskData.vehId == vehId then
      taskData.giveBack = true
    end
  end
end
M.giveBackDeliveryVehicle = giveBackDeliveryVehicle

local function getVehicleTasks()
  return vehicleTasks
end
M.getVehicleTasks = getVehicleTasks

-- DEBUG part
local im = ui_imgui
M.debugOrder = 12
M.debugName = "Delivery > Trailer Tasks"
local function drawDebugMenu()
  if im.Begin("Trailer Tasks Debug") then
    im.Text(dumps(vehicleTasks))

    im.End()
  end
end

M.drawDebugMenu = drawDebugMenu

return M