-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "gameplay_tutorial_setup"

local spawnedPrefabs = {}
local activePrefabs = {}

-- Expose only vehicle IDs; steps use getObjectByID(setup.tutorialVehicleId) when they need the object
M.tutorialVehicleId = nil

local tutorialSites = nil
M.vehicleSetupComplete = false
M.loadingScreenFadeoutComplete = false
M.tutorialSites = nil
M.outOfBoundsSystemActive = false

-- OOB reset is only allowed after the player has closed early onboarding popups.
local outOfBoundsResetAllowed = false
local pendingOobResetWithFade = false
local pendingOobResetCallback = nil
local activeOutOfBoundsResetHandler = nil


function M.setOutOfBoundsResetAllowed(allowed)
  outOfBoundsResetAllowed = allowed and true or false
end

function M.isOutOfBoundsResetAllowed()
  return outOfBoundsResetAllowed
end

function M.setOutOfBoundsResetHandler(resetCallback)
  activeOutOfBoundsResetHandler = resetCallback
end

function M.activateOutOfBoundsSystem()
  M.outOfBoundsSystemActive = true
end

function M.spawnPrefab(prefabPath, pos, rot, name)
  name = name or generateObjectNameForClass("Prefab", "tutorial_prefab_")

  local prefab = spawnPrefab(
    name,
    prefabPath,
    pos.x .. " " .. pos.y .. " " .. pos.z,
    rot.x .. " " .. rot.y .. " " .. rot.z .. " " .. rot.w,
    "1 1 1",
    false
  )

  if prefab then
    prefab.canSave = false
    if scenetree.MissionGroup then
      scenetree.MissionGroup:add(prefab)
    end
    spawnedPrefabs[name] = prefab
    log("D", logTag, "Spawned prefab: " .. prefabPath)
  else
    log("E", logTag, "Failed to spawn prefab: " .. prefabPath)
  end

  return prefab
end

function M.setActivePrefabs(prefabStates)
  if type(prefabStates) ~= "table" then
    log("W", logTag, "setActivePrefabs expects a table")
    return
  end

  local changedPrefabs = false

  for prefabId, shouldBeActive in pairs(prefabStates) do
    if type(prefabId) == "string" then
      local desiredActive = shouldBeActive and true or false
      local wasActive = activePrefabs[prefabId] and true or false
      if desiredActive ~= wasActive then
        if desiredActive then
          local prefab = M.spawnPrefab(
            "gameplay/tutorials/" .. prefabId .. ".prefab.json",
            vec3(0, 0, 0),
            quat(0, 0, 1, 0),
            prefabId .. "Prefab"
          )
          activePrefabs[prefabId] = prefab and true or false
          if activePrefabs[prefabId] then
            changedPrefabs = true
          end
        else
          local prefabName = prefabId .. "Prefab"
          local prefab = spawnedPrefabs[prefabName]
          if prefab then
            if editor and editor.onRemoveSceneTreeObjects then
              editor.onRemoveSceneTreeObjects({ prefab:getID() })
            end
            prefab:delete()
            spawnedPrefabs[prefabName] = nil
            changedPrefabs = true
          end
          activePrefabs[prefabId] = false
        end
      end
    end
  end

  if changedPrefabs then
    be:reloadCollision()
  end
end

function M.cleanup()
  outOfBoundsResetAllowed = false
  pendingOobResetWithFade = false
  pendingOobResetCallback = nil
  activeOutOfBoundsResetHandler = nil
  M.vehicleSetupComplete = false
  M.loadingScreenFadeoutComplete = false
  M.outOfBoundsSystemActive = false
  for _, prefab in pairs(spawnedPrefabs) do
    if prefab then
      if editor and editor.onRemoveSceneTreeObjects then
        editor.onRemoveSceneTreeObjects({ prefab:getID() })
      end
      prefab:delete()
    end
  end

  spawnedPrefabs = {}
  activePrefabs = {}
  M.tutorialVehicleId = nil

  log("D", logTag, "Cleanup complete")
end

function M.loadTutorialSites()
  local sitesPath = "/gameplay/tutorials/tutorialZones.sites.json"
  tutorialSites = gameplay_sites_sitesManager.loadSites(sitesPath, true, true)
  M.tutorialSites = tutorialSites

  if tutorialSites then
    log("D", logTag, "Loaded tutorial sites file: " .. sitesPath)
  else
    log("E", logTag, "Failed to load tutorial sites file: " .. sitesPath)
  end

  return tutorialSites
end

local function spawnVehicleAtSpot(model, config, spotName, vehicleName, afterSpawn)
  if not tutorialSites then
    M.loadTutorialSites()
  end
  local pos, rot = vec3(0, 0, 0), quat(0, 0, 0, 1)
  if tutorialSites then
    local carSpot = tutorialSites.parkingSpots.byName[spotName]
    if carSpot then
      pos = carSpot.pos
      rot = carSpot.rot
      log("D", logTag, "Using parking spot position for vehicle: " .. spotName)
    else
      log("W", logTag, "Parking spot " .. spotName .. " not found, using default position")
    end
  end
  local options = {
    config = config,
    licenseText = "TUTORIAL",
    vehicleName = vehicleName,
    pos = pos,
    rot = rot
  }
  local spawningOptions = sanitizeVehicleSpawnOptions(model, options)
  spawningOptions.autoEnterVehicle = false
  local veh = core_vehicles.spawnNewVehicle(model, spawningOptions)
  if veh and afterSpawn then
    afterSpawn(veh)
  end
  return veh
end

function M.setupVehicles()
  M.vehicleSetupComplete = false
  M.loadingScreenFadeoutComplete = false
  M.spawnTutorialVehicle(M.setupPlayer)
end

function M.onLoadingScreenFadeout()
  M.loadingScreenFadeoutComplete = true
end

function M.setupPlayer()
  if gameplay_walk then
    local playerPos = vec3(-20.746, 598.736, 75.112)
    local playerRot = quat(0, 0, 1, 1)
    if tutorialSites then
      local playerSpot = tutorialSites.parkingSpots.byName["playerWalkingStart"]
      if playerSpot then
        playerPos = playerSpot.pos
        playerRot = playerSpot.rot
        log("D", logTag, "Using parking spot position for player: playerWalkingStart")
      else
        log("W", logTag, "Parking spot playerWalkingStart not found, using default position")
      end
    end
    gameplay_walk.setWalkingMode(true, playerPos, playerRot, true)
    local unicycle = gameplay_walk.getCurrentUnicycle()
    if unicycle then
      M.placePlayerBackToParkingStart()
    end
  end
  log("D", logTag, "Player setup complete")
  M.vehicleSetupComplete = true
end

function M.spawnTutorialVehicle(thenFunction)
  local model, config = "sunburst2", "vehicles/sunburst2/apmTutorial_sunburst.pc"
  local veh = spawnVehicleAtSpot(model, config, "tutorialCarStart", "TutorialVehicle", function(v)
    M.tutorialVehicleId = v:getID()
    log("D", logTag, "Vehicle is ready: " .. dumps(v:isReady()))
    core_vehicleBridge.requestValue(v, function()
      core_vehicleBridge.executeAction(v, "setGearboxMode", "realistic")
      core_vehicleBridge.executeAction(v, "setFreeze", true)
      core_vehicleBridge.executeAction(v, "setIgnitionLevel", 0)
      if thenFunction then thenFunction() end
    end, "mainController", "gearboxMode")
    log("D", logTag, "Spawned tutorial vehicle: " .. model .. " (ID: " .. M.tutorialVehicleId .. ")")
  end)
  if not veh then
    log("E", logTag, "Failed to spawn tutorial vehicle")
  end
  return veh
end

M.blockedActionsTemplates = {
  aiControls = true,
  bigMap = true,
  competitive = true,
  couplers = true,
  freeCam = true,
  funStuff = true,
  gameCam = false,
  miniMap = false,
  missionPopup = false,
  physicsControls = true,
  resetPhysics = true,
  trackBuilder = true,
  vehicleMenues = true,
  vehicleSwitching = true,
  vehicleTeleporting = true,
  vehicleTriggers = false,
  walkingMode = true
}
M.blockedActions = {
  gear1 = true,
  gear2 = true,
  gear3 = true,
  gear4 = true,
  gear5 = true,
  gear6 = true,
  gear7 = true,
  gear8 = true,
  gearN = true,
  gearR = true,
  shiftDown = true,
  shiftUp = true,
  setShifterMode = true
}

local gearActionNames = {
  "gear1", "gear2", "gear3", "gear4", "gear5", "gear6", "gear7", "gear8", "gearN", "gearR", "shiftDown", "shiftUp", "setShifterMode"
}

function M.unblockGearActions()
  for _, actionName in ipairs(gearActionNames) do
    M.blockedActions[actionName] = false
  end
  M.setupBlockedActions()
end

function M.placePlayerBackToParkingStart()
  if not tutorialSites then M.loadTutorialSites() end
  if not tutorialSites then return end

  local carSpot = tutorialSites.parkingSpots.byName["tutorialCarStart"]

  if gameplay_walk and gameplay_walk.isWalking() then
    local playerSpot = tutorialSites.parkingSpots.byName["playerWalkingStart"]
    if playerSpot then
      spawn.safeTeleport(getPlayerVehicle(0), playerSpot.pos, nil, nil, nil, nil, nil, false)
      local forward = playerSpot.rot * vec3(0, 1, 0)
      gameplay_walk.setRot(forward, vec3(0, 0, 1))
    end
  else
    local veh = getPlayerVehicle(0)
    local tutorialVeh = M.tutorialVehicleId and getObjectByID(M.tutorialVehicleId) or nil
    if tutorialVeh and carSpot then
      spawn.safeTeleport(tutorialVeh, carSpot.pos, carSpot.rot, nil, nil, nil, nil, false)
      if not veh or veh:getID() ~= tutorialVeh:getID() then
        gameplay_walk.getInVehicle(tutorialVeh)
      end
    end
  end
end

local FADE_DURATION = 0.3

function M.runOutOfBoundsResetWithFade(resetCallback)
  if pendingOobResetWithFade then return end
  pendingOobResetCallback = resetCallback
  pendingOobResetWithFade = true
  ui_fadeScreen.start(FADE_DURATION)
end

function M.runCurrentStepOutOfBoundsReset()
  if activeOutOfBoundsResetHandler then
    M.runOutOfBoundsResetWithFade(activeOutOfBoundsResetHandler)
  else
    M.runOutOfBoundsResetWithFade(M.placePlayerBackToParkingStart)
  end
end

local OOB_MESSAGE_ID = "tutorial_oob_stayInZone"
function M.showOutOfBoundsWarning()
  guihooks.trigger("SetTasklistTask", { id = OOB_MESSAGE_ID, type = "message", label = "Please stay inside of the evaluation zone.", clear = false })
  core_jobsystem.create(function(job)
    job.sleep(3)
    guihooks.trigger("DiscardTasklistItem", OOB_MESSAGE_ID)
  end, 1)
end

function M.onScreenFadeState(state)
  if not pendingOobResetWithFade or state ~= 2 then return end
  if pendingOobResetCallback then
    pendingOobResetCallback()
  else
    M.placePlayerBackToParkingStart()
  end
  ui_fadeScreen.stop(FADE_DURATION)
  pendingOobResetWithFade = false
  pendingOobResetCallback = nil

  M.showOutOfBoundsWarning()
end

function M.placePlayerAtDragStart()
  if not tutorialSites then M.loadTutorialSites() end
  if not tutorialSites then return end

  if gameplay_walk then
    gameplay_walk.setWalkingMode(true)
    local spot = tutorialSites.parkingSpots.byName["dragPlayerStart"]
    if spot then
      spawn.safeTeleport(getPlayerVehicle(0), spot.pos)
      local forward = spot.rot * vec3(0, 1, 0)
      gameplay_walk.setRot(forward, vec3(0, 0, 1))
      log("D", logTag, "Placed player at dragPlayerStart")
    else
      local carSpot = tutorialSites.parkingSpots.byName["dragCarStart"]
      if carSpot then
        local pos = vec3(carSpot.pos.x, carSpot.pos.y - 6, carSpot.pos.z)
        spawn.safeTeleport(getPlayerVehicle(0), pos)
        gameplay_walk.setRot(vec3(0, 1, 0), vec3(0, 0, 1))
      end
    end
  end
end

function M.placePlayerBackInTutorialVehicle()
  if not M.tutorialVehicleId then return end
  local tutorialVeh = getObjectByID(M.tutorialVehicleId)
  if not tutorialVeh then return end
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(tutorialVeh)
  else
    local veh = getPlayerVehicle(0)
    if veh and veh:getID() ~= tutorialVeh:getID() then
      gameplay_walk.getInVehicle(tutorialVeh)
    end
  end
end

function M.setupBlockedActions()
  local blockedActionGroups = {}
  for actionGroupName, enabled in pairs(M.blockedActionsTemplates) do
    if enabled then
      table.insert(blockedActionGroups, actionGroupName)
    end
  end
  local list = core_input_actionFilter.createActionTemplate(blockedActionGroups)
  for actionName, blocked in pairs(M.blockedActions) do
    if blocked then
      table.insert(list, actionName)
    end
  end
  log("D", logTag, "Blocking actions: " .. table.concat(list, ", "))
  core_input_actionFilter.setGroup("tutorialBlockedActions", list)
  core_input_actionFilter.addAction(0, "tutorialBlockedActions", true)
end

return M
