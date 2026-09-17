-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")
local logTag = "tutorial_step8"

local NEAR_PARKING_DISTANCE_M = 25
local DRIVE_GOAL_ATTENTION_CLEAR_DISTANCE_M = 5
local PARK_STATIONARY_SECONDS = 1.0

local PHASE_DRIVE_TO_GARAGE = "driveToGarage"
local PHASE_PARK_AT_GARAGE = "parkAtGarage"
local PHASE_WAIT_ARRIVAL_POPUPS = "waitArrivalPopups"
local PHASE_HOP_OUT = "hopOut"

local headers = {
  driveToGarage = { label = "ui.career.tutorial.task.step08.header.driveToGarage" },
}

local taskUpdates = {
  driveToGarageAttentionOff = {
    id = "step8_driveToGarageGoal",
    attention = false,
  },
}

local goals = {
  driveToGarageGoal = {
    done = false,
    id = "step8_driveToGarageGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step08.goal.driveToGarage.label",
    subtext = "ui.career.tutorial.task.step08.goal.driveToGarage.subtext",
    attention = true,
  },
  parkGoal = {
    done = false,
    id = "step8_parkGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step08.goal.park.label",
    subtext = "ui.career.tutorial.task.step08.goal.park.subtext",
    attention = true,
  },
  hopOutGoal = {
    done = false,
    id = "step8_hopOutGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step08.goal.hopOut.label",
    subtext = "ui.career.tutorial.task.step08.goal.hopOut.subtext",
    actionItems = {
      { action = "toggleWalkingMode" },
    },
    attention = true,
  },
}

local playerVehicleId = nil
local garageParkingSpot = nil
local garageInteriorWalkStartSpot = nil
local parkingSpotMarkerId = nil
local parkGoalState = {}
local garageResetZones = {}
local garageResetSpots = {}
local currentResetCheckpointIndex = 1
local phase = PHASE_DRIVE_TO_GARAGE
local driveGoalStartPos = nil

local GARAGE_RESET_ZONE_NAMES = {"driveToGarageZone1","driveToGarageZone2","driveToGarageZone3",}
local GARAGE_RESET_SPOT_NAMES = {"driveToGarageReset1","driveToGarageReset2","driveToGarageReset3",}
local GARAGE_ACTIVE_ZONE_NAMES = {"driveToGarageZone1","driveToGarageZone2","driveToGarageZone3","garageBounds",}

local function setWalkingToggleBlocked(blocked)
  gameplay_tutorial_setup.blockedActionsTemplates.walkingMode = blocked
  gameplay_tutorial_setup.setupBlockedActions()
end

local function shutOffPlayerVehicle()
  if not playerVehicleId then return end
  local veh = getObjectByID(playerVehicleId)
  if not veh then return end
  core_vehicleBridge.executeAction(veh, "setIgnitionLevel", 0)
end

local function setPlayerVehicleFrozen(frozen)
  if not playerVehicleId then return end
  local veh = getObjectByID(playerVehicleId)
  if not veh then return end
  core_vehicleBridge.executeAction(veh, "setFreeze", frozen)
end

local function setPlayerVehicleEnterable(enterable)
  if not playerVehicleId then return end
  local veh = getObjectByID(playerVehicleId)
  if not veh then return end
  veh.playerUsable = enterable
  if gameplay_walk then
    if enterable then
      gameplay_walk.removeVehicleFromBlacklist(playerVehicleId)
    else
      gameplay_walk.addVehicleToBlacklist(playerVehicleId)
    end
  end
end

local function checkParkGoal(dtReal)
  if not garageParkingSpot or not playerVehicleId or not gameplay_tutorial_markers then return false end
  local veh = getObjectByID(playerVehicleId)
  if not veh then return false end
  return gameplay_tutorial_markers.checkParkGoalWithStationaryTime(
    veh,
    garageParkingSpot,
    dtReal,
    PARK_STATIONARY_SECONDS,
    parkGoalState
  )
end

local function setupParkingMarker()
  if not garageParkingSpot or not gameplay_tutorial_markers then return end
  gameplay_tutorial_markers.addParkingSpotDecal(garageParkingSpot)
  if playerVehicleId then
    gameplay_tutorial_markers.setParkingSpotVehicle(garageParkingSpot.name, getObjectByID(playerVehicleId))
  end
  local p = garageParkingSpot.pos
  parkingSpotMarkerId = gameplay_tutorial_markers.createMarker(vec3(p.x, p.y, p.z + 2), nil, vec3(1.5, 1.5, 1.5))
end

local function clearGarageParkingVisuals()
  if parkingSpotMarkerId and gameplay_tutorial_markers then
    gameplay_tutorial_markers.removeMarker(parkingSpotMarkerId)
    parkingSpotMarkerId = nil
  end
  if garageParkingSpot and gameplay_tutorial_markers then
    gameplay_tutorial_markers.removeParkingSpotDecal(garageParkingSpot.name)
  end
end

local function setRouteToGarageInteriorWalkStart()
  if not garageInteriorWalkStartSpot then return end
  core_groundMarkers.setPath(garageInteriorWalkStartSpot.pos)
end

local function updateResetCheckpointFromPosition(pos)
  if not pos then return end
  for i = #garageResetZones, 1, -1 do
    local zone = garageResetZones[i]
    if zone and zone.containsPoint2D and zone:containsPoint2D(pos) then
      if i > currentResetCheckpointIndex then
        currentResetCheckpointIndex = i
      end
      return
    end
  end
end

local function resetToStep8Start()
  local spot = garageResetSpots[currentResetCheckpointIndex]
  if not spot then
    spot = garageParkingSpot
  end
  if not spot and gameplay_tutorial_setup.tutorialSites then
    spot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["garageExteriorPark"]
  end
  local veh = playerVehicleId and getObjectByID(playerVehicleId) or getPlayerVehicle(0)
  if not veh or not spot then return end
  spawn.safeTeleport(veh, spot.pos, spot.rot, nil, nil, nil, nil, false)
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(veh)
  end
end

local function scheduleAdvance()
  core_jobsystem.create(function(job)
    job.sleep(1.0)
    career_modules_tutorial.advanceToNextStep()
  end, 1)
end

function M.setup(stepData)
  goals.driveToGarageGoal.done = false
  goals.parkGoal.done = false
  goals.hopOutGoal.done = false
  playerVehicleId = nil
  garageParkingSpot = nil
  parkingSpotMarkerId = nil
  parkGoalState = {}
  garageResetZones = {}
  garageResetSpots = {}
  currentResetCheckpointIndex = 1
  garageInteriorWalkStartSpot = nil
  phase = PHASE_DRIVE_TO_GARAGE
  driveGoalStartPos = nil

  gameplay_drag_dragBridge.stopDragRace()

  local playerVeh = getPlayerVehicle(0)
  if playerVeh then
    playerVehicleId = playerVeh:getID()
  elseif gameplay_tutorial_setup.tutorialVehicleId then
    playerVehicleId = gameplay_tutorial_setup.tutorialVehicleId
  end

  if gameplay_tutorial_setup.tutorialSites then
    local sites = gameplay_tutorial_setup.tutorialSites
    garageParkingSpot = sites.parkingSpots.byName["garageExteriorPark"]
    if not garageParkingSpot then
      log("W", logTag, "Parking spot garageExteriorPark not found")
    end
    garageInteriorWalkStartSpot = sites.parkingSpots.byName["garageInteriorWalkStart"]
    if not garageInteriorWalkStartSpot then
      log("W", logTag, "Parking spot garageInteriorWalkStart not found")
    end
    local zonesByName = sites.zones and sites.zones.byName
    local spotsByName = sites.parkingSpots and sites.parkingSpots.byName
    for i, zoneName in ipairs(GARAGE_RESET_ZONE_NAMES) do
      garageResetZones[i] = zonesByName and zonesByName[zoneName] or nil
    end
    for i, spotName in ipairs(GARAGE_RESET_SPOT_NAMES) do
      garageResetSpots[i] = spotsByName and spotsByName[spotName] or nil
    end
  end

  local hasAnyResetZone = false
  for _, zone in ipairs(garageResetZones) do
    if zone then
      hasAnyResetZone = true
      break
    end
  end

  if hasAnyResetZone then
    gameplay_tutorial_bounds.setActiveZones(GARAGE_ACTIVE_ZONE_NAMES)
    gameplay_tutorial_setup.setOutOfBoundsResetHandler(resetToStep8Start)
  else
    -- Keep step functional while sites data is being authored.
    gameplay_tutorial_bounds.setActiveZones({})
    gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  end

  -- Keep normal enter behavior while driving to the garage.
  setWalkingToggleBlocked(false)
  setPlayerVehicleEnterable(true)

  if playerVehicleId then
    local playerVehObj = getObjectByID(playerVehicleId)
    driveGoalStartPos = playerVehObj and vec3(playerVehObj:getPosition()) or nil
  end

  setupParkingMarker()

  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.driveToGarage)
  tasklistLocale.setTasklistTask(goals.driveToGarageGoal)
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

function M.onIntroPopupCareerClosed(id)
  if career_modules_tutorial.getCurrentStep() ~= "08driveToGarage" then return end
  -- Popup sequence runs in one container; once the final page closes, continue flow.
  if id == "v2/garageArrivalIntro2" and phase == PHASE_WAIT_ARRIVAL_POPUPS then
    -- After arrival onboarding popups close, guide player toward the garage interior.
    setRouteToGarageInteriorWalkStart()
    scheduleAdvance()
  end
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  local veh = playerVehicleId and getObjectByID(playerVehicleId) or nil
  if not veh or not garageParkingSpot then return end
  updateResetCheckpointFromPosition(veh:getPosition())

  if phase == PHASE_DRIVE_TO_GARAGE then
    if goals.driveToGarageGoal.attention and driveGoalStartPos then
      local movedDist = veh:getPosition():distance(driveGoalStartPos)
      if movedDist > DRIVE_GOAL_ATTENTION_CLEAR_DISTANCE_M then
        goals.driveToGarageGoal.attention = false
        tasklistLocale.setTasklistTask(taskUpdates.driveToGarageAttentionOff)
      end
    end
    local dist = veh:getPosition():distance(garageParkingSpot.pos)
    if dist <= NEAR_PARKING_DISTANCE_M then
      goals.driveToGarageGoal.done = true
      tasklistLocale.setTasklistTask(goals.driveToGarageGoal)
      tasklistLocale.setTasklistTask(goals.parkGoal)
      phase = PHASE_PARK_AT_GARAGE
    end
    return
  end

  if phase == PHASE_PARK_AT_GARAGE and not goals.parkGoal.done and checkParkGoal(dtReal) then
    goals.parkGoal.done = true
    tasklistLocale.setTasklistTask(goals.parkGoal)
    -- Lock the parked vehicle immediately so player can't back out after completing park.
    shutOffPlayerVehicle()
    setPlayerVehicleFrozen(true)
    clearGarageParkingVisuals()
    setPlayerVehicleEnterable(false)
    phase = PHASE_HOP_OUT
    -- Ask player to exit after parking lock; popup onboarding happens after hop out.
    setWalkingToggleBlocked(false)
    tasklistLocale.setTasklistTask(goals.hopOutGoal)
    return
  end

  if phase == PHASE_HOP_OUT and not goals.hopOutGoal.done and gameplay_walk and gameplay_walk.isWalking() then
    goals.hopOutGoal.done = true
    tasklistLocale.setTasklistTask(goals.hopOutGoal)
    -- After exit at garage, repair is no longer valid; stop repair-task resurfacing from tracker updates.
    gameplay_tutorial_damageTracker.setEnabled(false)
    phase = PHASE_WAIT_ARRIVAL_POPUPS
    core_jobsystem.create(function(job)
      job.sleep(1.0)
      if career_modules_tutorial.getCurrentStep() ~= "08driveToGarage" then return end
      if phase ~= PHASE_WAIT_ARRIVAL_POPUPS then return end
      career_modules_tutorialPopups.introPopupSequence({"v2/garageArrivalIntro1", "v2/garageArrivalIntro2"}, true)
    end, 1)
  end
end

function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  -- Keep walking toggle enabled for following steps and post-tutorial gameplay.
  setWalkingToggleBlocked(false)
  guihooks.trigger("ClearTasklist")
  clearGarageParkingVisuals()
end

function M.onDebugMenu(im)
  im.Text("Step 8 - Drive To Garage")
  im.Separator()
  im.Text(string.format("Phase: %s", tostring(phase)))
  if im.Button("Skip Step 8") then
    local spot = garageParkingSpot
    if not spot and gameplay_tutorial_setup.tutorialSites then
      spot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["garageExteriorPark"]
    end
    local veh = playerVehicleId and getObjectByID(playerVehicleId) or getPlayerVehicle(0)
    if spot and veh then
      spawn.safeTeleport(veh, spot.pos, spot.rot)
    end
    gameplay_walk.setWalkingMode(true)
    shutOffPlayerVehicle()
    setPlayerVehicleEnterable(false)
    goals.driveToGarageGoal.done = true
    goals.parkGoal.done = true
    goals.hopOutGoal.done = true
    tasklistLocale.setTasklistTask(goals.driveToGarageGoal)
    tasklistLocale.setTasklistTask(goals.parkGoal)
    tasklistLocale.setTasklistTask(goals.hopOutGoal)
    scheduleAdvance()
  end
end

return M
