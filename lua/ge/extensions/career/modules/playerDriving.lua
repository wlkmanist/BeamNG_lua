-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'career_career'}

local playerData = {maxTrafficAmount = 0, maxParkingAmount = 0, defaultTrafficAmount = 1} -- traffic data, parking data, etc.
local tutorialTrafficRestoreActive = nil
local tutorialParkingRestoreActive = nil

M.debugMode = not shipping_build

local function getPlayerData()
  return playerData
end

local function setPlayerData(newId, oldId)
  -- oldId is optional and is used if the vehicle was switched
  playerData.isParked = gameplay_parking.getCurrentParkingSpot(newId) and true or false

  if oldId then
    gameplay_parking.disableTracking(oldId)
  end
  if not gameplay_walk.isWalking() then
    gameplay_parking.enableTracking(newId)
  end

  if not gameplay_traffic.getTrafficData()[newId] then
    gameplay_traffic.insertTraffic(newId, true)
  end

  playerData.traffic = gameplay_traffic.getTrafficData()[newId]
  playerData.parking = gameplay_parking.getTrackingData()[newId]
end

local function setTrafficVars()
  local spawnValue = clamp(6 / math.max(6, gameplay_traffic.getTrafficAmount(true)), 0.1, 1) -- adjust traffic density if amount is high
  gameplay_traffic.setTrafficVars({enableRandomEvents = false, spawnValue = spawnValue})
  gameplay_police.setPursuitVars({arrestRadius = 15, evadeTime = 30})
  gameplay_parking.setParkingVars({precision = 0.2}) -- allows for relaxed parking detection
end

local function getFallbackTrafficAmounts()
  -- NOTE: very low or very high values from gameplay settings can negatively impact career gameplay and performance
  local trafficAmount = settings.getValue('trafficAmount')
  if not M.debugMode then
    trafficAmount = clamp(trafficAmount, 2, 50)
  end

  local parkingAmount = settings.getValue('trafficParkedAmount')
  if not M.debugMode then
    parkingAmount = clamp(parkingAmount, 2, 50)
  end

  return trafficAmount, parkingAmount
end

local function setupTraffic(forceSetup)
  if not forceSetup and playerData.maxTrafficAmount > 0 then return end

  log("I", "career", "Now spawning traffic for career mode")
  if core_gamestate.loading() then core_gamestate.requestEnterLoadingScreen('careerVehicles') end

  local restrict = settings.getValue('trafficRestrictForCareer')
  if shipping_build then restrict = false end -- this line may be temporary

  local trafficAmount, parkingAmount = getFallbackTrafficAmounts()
  if restrict then
    trafficAmount, parkingAmount = playerData.defaultTrafficAmount, playerData.defaultTrafficAmount
  end

  -- traffic extra amount (vehicle pooling) is disabled by default (TODO: reason?)

  -- police amount and vehicle pooling
  --local policeAmount = 0 -- temporarily disabled by default
  --local extraAmount = policeAmount -- enables traffic pooling
  --playerData.maxTrafficAmount = trafficAmount -- store the amount here for future usage
  --if playerData.maxTrafficAmount == 0 then playerData.maxTrafficAmount = math.huge end

  local trafficOptions = {simpleVehs = true, autoLoadFromFile = true}

  gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, nil)
  --gameplay_parking.setupVehicles(restrict and playerData.defaultTrafficAmount or parkingAmount)
  --gameplay_traffic.setupTraffic(restrict and playerData.defaultTrafficAmount + extraAmount or trafficAmount + extraAmount, 0, trafficOptions)

  -- enforce active amounts by setting them here and now
  gameplay_traffic.setActiveAmount(trafficAmount)
  gameplay_parking.setActiveAmount(parkingAmount)
end

local function setPoliceProbability(value)
  for id, tData in pairs(gameplay_traffic.getTrafficData()) do
    if tData.role.name == "police" then
      tData.activeProbability = value
      if value == 0 then -- immediately hide this police vehicle
        local veh = getObjectByID(id)
        if veh then
          veh:setActive(0)
        end
      end
    end
  end
end

local function playerPursuitActive()
  return playerData.traffic and playerData.traffic.pursuit and playerData.traffic.pursuit.mode ~= 0
end

local function resetPlayerState()
  setPlayerData(be:getPlayerVehicleID(0))
  setTrafficVars()
  if playerData.traffic then playerData.traffic:resetAll() end
end

local function setTrafficForTutorial()
  gameplay_parking.scatterParkedCars()
  gameplay_parking.setActiveAmount(0)
  gameplay_traffic.scatterTraffic()
  gameplay_traffic.setActiveAmount(playerData.maxTrafficAmount)
  setPoliceProbability(0)
end

local function setTrafficAfterTutorial()
  gameplay_parking.scatterParkedCars()
  gameplay_traffic.scatterTraffic()
  resetPlayerState()
  setPoliceProbability(0.15)
end

local function cacheTutorialTrafficRestoreAmounts()
  if tutorialTrafficRestoreActive == nil then
    tutorialTrafficRestoreActive = gameplay_traffic.getTrafficVars().activeAmount
  end
  if tutorialParkingRestoreActive == nil then
    tutorialParkingRestoreActive = gameplay_parking.getParkingVars().activeAmount
  end
end

local function restoreTrafficAfterTutorialPhase()
  local trafficAmount, parkedAmount = tutorialTrafficRestoreActive, tutorialParkingRestoreActive
  local fallbackTraffic, fallbackParked = getFallbackTrafficAmounts()
  if not trafficAmount or trafficAmount <= 0 then trafficAmount = fallbackTraffic end
  if not parkedAmount or parkedAmount <= 0 then parkedAmount = fallbackParked end

  if gameplay_traffic.getState() == "off" then
    gameplay_traffic.toggle(true)
  end

  gameplay_traffic.setActiveAmount(trafficAmount)
  gameplay_parking.setActiveAmount(parkedAmount)

  setTrafficAfterTutorial()
end

local function retrieveFavoriteVehicle()
  local inventory = career_modules_inventory
  local favoriteVehicleInventoryId = inventory.getFavoriteVehicle()
  if not favoriteVehicleInventoryId then return end
  local vehInfo = inventory.getVehicles()[favoriteVehicleInventoryId]
  if not vehInfo then return end

  local vehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
  if vehId then
    local playerVehObj = getPlayerVehicle(0)
    spawn.safeTeleport(getObjectByID(vehId), playerVehObj:getPosition(), quatFromDir(playerVehObj:getDirectionVector()), nil, nil, nil, nil, false)
    core_vehicleBridge.executeAction(getObjectByID(vehId),'setIgnitionLevel', 0)
  elseif not vehInfo.timeToAccess and not career_modules_insurance_insurance.inventoryVehNeedsRepair(favoriteVehicleInventoryId) then
    inventory.spawnVehicle(favoriteVehicleInventoryId, nil,
    function()
      local playerVehObj = getPlayerVehicle(0)
      local vehId = inventory.getVehicleIdFromInventoryId(favoriteVehicleInventoryId)
      spawn.safeTeleport(getObjectByID(vehId), playerVehObj:getPosition(), quatFromDir(playerVehObj:getDirectionVector()), nil, nil, nil, nil, false)
    end)
  end
end

local function deleteTrailers(veh)
  local trailerData = core_trailerRespawn.getTrailerData()
  local trailerDataThisVeh = trailerData[veh:getId()]

  if trailerDataThisVeh then
    local trailer = getObjectByID(trailerDataThisVeh.trailerId)
    deleteTrailers(trailer)
    career_modules_inventory.removeVehicleObject(career_modules_inventory.getInventoryIdFromVehicleId(trailerDataThisVeh.trailerId))
  end
end

local teleportTrailerJob = function(job)
  local args = job.args[1]
  local vehicle = getObjectByID(args.vehicleId)
  local trailer = getObjectByID(args.trailerId)
  local vehRot = quat(0,0,1,0) * quat(vehicle:getRefNodeRotation())
  local vehBB = vehicle:getSpawnWorldOOBB()
  local vehBBCenter = vehBB:getCenter()

  local trailerBB = vehicle:getSpawnWorldOOBB()

  spawn.safeTeleport(trailer, vehBBCenter - vehicle:getDirectionVector() * (vehBB:getHalfExtents().y + trailerBB:getHalfExtents().y), vehRot, nil, nil, nil, true, args.resetVeh)

  core_trailerRespawn.getTrailerData()[args.vehicleId] = nil
end

local function teleportToGarage(garageId, veh, resetVeh)
  freeroam_facilities.teleportToGarage(garageId, veh, resetVeh)
  freeroam_bigMapMode.navigateToMission(nil)
  core_vehicleBridge.executeAction(veh,'setIgnitionLevel', 0)

  local trailerData = core_trailerRespawn.getTrailerData()
  local primaryTrailerData = trailerData[veh:getId()]
  if primaryTrailerData then
    local teleportArgs = {
      trailerId = primaryTrailerData.trailerId,
      vehicleId = veh:getId(),
      resetVeh = resetVeh
    }
    -- need to do this with one frame delay, otherwise the safeTeleport gets confused with two vehicles
    core_jobsystem.create(teleportTrailerJob, 0.1, teleportArgs)

    career_modules_inventory.updatePartConditionsOfSpawnedVehicles(
      function()
        local trailer = getObjectByID(primaryTrailerData.trailerId)
        deleteTrailers(trailer)
        career_modules_fuel.minimumRefuelingCheck(veh:getId())
      end
    )
  else
    career_modules_fuel.minimumRefuelingCheck(veh:getId())
  end
end

local function onVehicleParkingStatus(vehId, data)
  if not gameplay_missions_missionManager.getForegroundMissionId() and not career_modules_tutorial.isActive() and vehId == be:getPlayerVehicleID(0) then
    if data.event == "valid" then -- this refers to fully stopping while aligned in a parking spot
      if not playerData.isParked then
        playerData.isParked = true
      end
    elseif data.event == "exit" then
      playerData.isParked = false
    end
  end
end

local function onTrafficStarted()
  local updateAmount = playerData.maxTrafficAmount == 0
  if not career_career.tutorialEnabled and not gameplay_missions_missionManager.getForegroundMissionId() then
    updateAmount = true
    resetPlayerState()
    setPoliceProbability(0.15)
  end
  if updateAmount then
    playerData.maxTrafficAmount = gameplay_traffic.getTrafficAmount(true)
    playerData.maxParkingAmount = gameplay_parking.getParkingAmount(true)
  end
end

local function onTrafficStopped()
  if playerData.traffic then table.clear(playerData.traffic) end
end

local function onPursuitAction(vehId, action, data)
  if not gameplay_missions_missionManager.getForegroundMissionId() and vehId == be:getPlayerVehicleID(0) then
    if action == "start" then -- pursuit started
      gameplay_parking.disableTracking(vehId)
      --core_recoveryPrompt.deactivateAllButtons()
      log("I", "career", "Police pursuing player, now deactivating recovery prompt buttons")
    elseif action == "reset" or action == "evade" then -- pursuit ended, return to normal
      if not gameplay_walk.isWalking() then
        gameplay_parking.enableTracking(vehId)
      end
      --core_recoveryPrompt.setDefaultsForCareer()
      log("I", "career", "Pursuit ended, now activating recovery prompt buttons")
    elseif action == "arrest" then -- pursuit arrest, make the player pay a fine
      local fine = data.mode * data.uniqueOffensesCount * 100 -- fine value is WIP
      --fine = math.min(fine, career_modules_playerAttributes.getAttributeValue("money"))
      career_modules_payment.pay({money = {amount = fine}}, {label = "Fine for being arrested by the police", tags={"gameplay", "police", "fine"}})
      ui_message(_tr("ui.traffic.policeFine", "You got fined by the police: ")..fine, 5, "careerPursuit")
    end
  end
end

local function onTrafficOrParkingReady()
  if core_gamestate.getLoadingStatus('careerVehicles') then
    log("I", "career", "Traffic is now ready for career mode")
    core_gamestate.requestExitLoadingScreen('careerVehicles')
    if freeroam_specialTriggers then
      for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
        freeroam_specialTriggers.setTriggerActive(k, false, true) -- deactivate all triggers
      end
    end
  end
  if career_modules_tutorial.isActive() then -- scatter and hide traffic and parked vehicles
    log("I", "career", "Stashing traffic and parked vehicles for tutorial")
    cacheTutorialTrafficRestoreAmounts()
    gameplay_traffic.scatterTraffic()
    gameplay_traffic.setActiveAmount(0)
    gameplay_parking.scatterParkedCars()
    gameplay_parking.setActiveAmount(0)
  end
end

local function onVehicleSwitched(oldId, newId)
  if not career_career.tutorialEnabled and not gameplay_missions_missionManager.getForegroundMissionId() then
    setPlayerData(newId, oldId)
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not playerPursuitActive() then return end

  -- for now, prevent pursuit softlock by making the police give up
  if not playerData.pursuitStuckTimer then playerData.pursuitStuckTimer = 0 end
  if (playerData.traffic.speed < 3 and playerData.traffic.pursuit.timers.arrest == 0 and playerData.traffic.pursuit.timers.evade == 0) then
    playerData.pursuitStuckTimer = playerData.pursuitStuckTimer + dtSim
    if playerData.pursuitStuckTimer >= 10 then
      log("I", "career", "Ending pursuit early due to stalemate")
      gameplay_police.evadeVehicle(be:getPlayerVehicleID(0), true)
      playerData.pursuitStuckTimer = 0
    end
  else
    playerData.pursuitStuckTimer = 0
  end
end

local function onCareerActive(active)
  if active and playerData.maxTrafficAmount == 0 then
    setupTraffic()
  end
  if core_gamestate.loading() and freeroam_specialTriggers then
    for k, v in pairs(freeroam_specialTriggers.getTriggers()) do
      freeroam_specialTriggers.setTriggerActive(k, true, true) -- activate all garage lights, to precalculate lighting
    end
  end
end

local function buildCamPath(targetPos, endDir)
  --local camMode = core_camera.getGlobalCameras().bigMap

  local path = { looped = false, manualFov = false}
  local startPos = core_camera.getPosition() + vec3(0,0,30)

  local m1 = { fov = 30, movingEnd = false, movingStart = false, positionSmooth = 0.5, pos = startPos, rot = quatFromDir(targetPos - startPos), time = 0, trackPosition = false  }
  local m2 = { fov = 30, movingEnd = false, movingStart = false, positionSmooth = 0.5, pos = startPos, rot = quatFromDir(targetPos - startPos), time = 0.5, trackPosition = false  }
  local m3 = { fov = core_camera.getFovDeg(), movingEnd = false, movingStart = false, positionSmooth = 0.5, pos = core_camera.getPosition(), rot = endDir and quatFromDir(endDir) or core_camera.getQuat(), time = 5.5, trackPosition = false }
  path.markers = {m1, m2, m3}

  return path
end

local function showPosition(pos)
  local camDir = pos - getPlayerVehicle(0):getPosition()
  if gameplay_walk.isWalking() then
    gameplay_walk.setRot(camDir)
  end

  local camDirLength = camDir:length()
  local rayDist = castRayStatic(getPlayerVehicle(0):getPosition(), camDir, camDirLength)

  if rayDist < camDirLength then
    -- Play cam path to show where the position is
    local camPath = buildCamPath(pos, camDir)
    local initData = {}
    initData.finishedPath = function(this)
      core_camera.setVehicleCameraByIndexOffset(0, 1)
    end
    core_paths.playPath(camPath, 0, initData)
  end
end

M.getPlayerData = getPlayerData
M.retrieveFavoriteVehicle = retrieveFavoriteVehicle
M.playerPursuitActive = playerPursuitActive
M.resetPlayerState = resetPlayerState
M.setTrafficForTutorial = setTrafficForTutorial
M.setTrafficAfterTutorial = setTrafficAfterTutorial
M.restoreTrafficAfterTutorialPhase = restoreTrafficAfterTutorialPhase
M.teleportToGarage = teleportToGarage
M.showPosition = showPosition

M.onTrafficOrParkingReady = onTrafficOrParkingReady
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onPursuitAction = onPursuitAction
M.onVehicleParkingStatus = onVehicleParkingStatus
M.onVehicleSwitched = onVehicleSwitched
M.onCareerActive = onCareerActive
M.onUpdate = onUpdate

return M