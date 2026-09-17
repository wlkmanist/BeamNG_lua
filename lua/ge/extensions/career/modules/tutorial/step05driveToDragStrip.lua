-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")
local logTag = "tutorial_step5"
local PREFAB_SWAP_DELAY_S = 0.5

local NEAR_STAGING_DISTANCE_M = 25
local DRIVE_GOAL_ATTENTION_CLEAR_DISTANCE_M = 5
local PARK_STATIONARY_SECONDS = 1.0

local PHASE_WAIT_POPUP = "waitPopup"
local PHASE_DRIVE_TO_STRIP = "driveToStrip"
local PHASE_PARK_IN_STAGING = "parkInStaging"

local headers = {
  driveToDragStrip = { label = "ui.career.tutorial.task.step05.header.driveToDragStrip" },
}

local taskUpdates = {
  driveToStripAttentionOff = {
    id = "step5_driveToStripGoal",
    attention = false,
  },
}

local goals = {
  driveToStripGoal = {
    done = false,
    id = "step5_driveToStripGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step05.goal.driveToStrip.label",
    subtext = "ui.career.tutorial.task.step05.goal.driveToStrip.subtext",
    attention = true,
  },
  parkInStagingGoal = {
    done = false,
    id = "step5_parkInStagingGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step05.goal.parkInStaging.label",
    subtext = "ui.career.tutorial.task.step05.goal.parkInStaging.subtext",
    attention = true,
  },
}

local tutorialVehicleId = nil
local dragStripParkingSpot = nil
local parkingSpotMarkerId = nil
local parkGoalState = {}
local phase = PHASE_WAIT_POPUP
local driveGoalStartPos = nil


local function setRouteToStaging()
  if not dragStripParkingSpot then return end
  if core_groundMarkers.currentlyHasTarget() then return end
  core_groundMarkers.setPath(dragStripParkingSpot.pos)
end

local function clearRoute()
  core_groundMarkers.setPath(nil)
end

local function checkParkGoal(dtReal)
  if not dragStripParkingSpot or not tutorialVehicleId or not gameplay_tutorial_markers then return false end
  local veh = getObjectByID(tutorialVehicleId)
  if not veh then return false end
  return gameplay_tutorial_markers.checkParkGoalWithStationaryTime(
    veh,
    dragStripParkingSpot,
    dtReal,
    PARK_STATIONARY_SECONDS,
    parkGoalState
  )
end

local function resetToStep5Start()
  local sites = gameplay_tutorial_setup.tutorialSites
  local spot = sites and sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName["simpleTimeTrialFinish"] or nil
  local tutorialVeh = tutorialVehicleId and getObjectByID(tutorialVehicleId) or nil
  if not tutorialVeh then
    tutorialVeh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  end
  if not tutorialVeh or not spot then return end

  spawn.safeTeleport(tutorialVeh, spot.pos, spot.rot, nil, nil, nil, nil, false)
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(tutorialVeh)
  end
end

local function setupStagingMarker()
  if not dragStripParkingSpot or not gameplay_tutorial_markers then return end
  gameplay_tutorial_markers.addParkingSpotDecal(dragStripParkingSpot)
  if tutorialVehicleId then
    gameplay_tutorial_markers.setParkingSpotVehicle(dragStripParkingSpot.name, getObjectByID(tutorialVehicleId))
  end
  local p = dragStripParkingSpot.pos
  parkingSpotMarkerId = gameplay_tutorial_markers.createMarker(vec3(p.x, p.y, p.z + 2), nil, vec3(1.5, 1.5, 1.5))
end

local function clearStagingVisuals()
  if parkingSpotMarkerId then
    gameplay_tutorial_markers.removeMarker(parkingSpotMarkerId)
    parkingSpotMarkerId = nil
  end
  if dragStripParkingSpot then
    gameplay_tutorial_markers.removeParkingSpotDecal(dragStripParkingSpot.name)
  end
end

function M.setup(stepData)
  goals.driveToStripGoal.done = false
  goals.parkInStagingGoal.done = false
  tutorialVehicleId = nil
  dragStripParkingSpot = nil
  parkingSpotMarkerId = nil
  parkGoalState = {}
  phase = PHASE_WAIT_POPUP
  driveGoalStartPos = nil

  -- Restore pre-tutorial traffic amounts (moving + parked) for this phase.
  career_modules_playerDriving.restoreTrafficAfterTutorialPhase()

  gameplay_tutorial_bounds.setActiveZones({"drivingToDragBounds", "parkingBounds"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(resetToStep5Start)

  local tutorialVeh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if tutorialVeh then
    tutorialVehicleId = tutorialVeh:getID()
    tutorialVeh:setActive(1)
    core_vehicleBridge.executeAction(tutorialVeh, "setIgnitionLevel", 3)
    core_vehicleBridge.executeAction(tutorialVeh, "setFreeze", false)
    local playerVeh = getPlayerVehicle(0)
    if gameplay_walk and (gameplay_walk.isWalking() or not playerVeh or playerVeh:getID() ~= tutorialVeh:getID()) then
      gameplay_walk.getInVehicle(tutorialVeh)
    end
  else
    log("W", logTag, "Tutorial vehicle not found in step05 setup")
  end

  if gameplay_tutorial_setup.tutorialSites then
    dragStripParkingSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["beforeDragStrip"]
    if not dragStripParkingSpot then
      log("W", logTag, "Parking spot beforeDragStrip not found")
    end
  end

  -- Ensure this step always starts from its intended handoff location.
  resetToStep5Start()
  if tutorialVehicleId then
    local tutorialVeh = getObjectByID(tutorialVehicleId)
    driveGoalStartPos = tutorialVeh and vec3(tutorialVeh:getPosition()) or nil
  end
  setRouteToStaging()
  setupStagingMarker()

  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.driveToDragStrip)

  career_modules_tutorialPopups.introPopup("v2/driveToDragStrip", true)
  core_jobsystem.create(function(job)
    job.sleep(PREFAB_SWAP_DELAY_S)
    if career_modules_tutorial.getCurrentStep() == "05driveToDragStrip" then
      -- Match step04 behavior: show popup first, then switch prefabs.
      gameplay_tutorial_setup.setActivePrefabs({
        startingArea = true,
        tutorialTrackOpen = false,
        tutorialTrackClosed = true,
        driveToDragStripGuidesClosed = true,
        driveToDragStripGuidesOpen = false,
        dragStripStartLine = true
      })
    end
  end, 1)
end

function M.onIntroPopupCareerClosed(id)
  if id ~= "v2/driveToDragStrip" then return end
  if career_modules_tutorial.getCurrentStep() ~= "05driveToDragStrip" then return end
  -- Re-apply guidance once at handoff; avoids per-frame marker churn.
  setRouteToStaging()
  if not parkingSpotMarkerId then
    setupStagingMarker()
  end
  phase = PHASE_DRIVE_TO_STRIP
  tasklistLocale.setTasklistTask(goals.driveToStripGoal)
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if phase == PHASE_WAIT_POPUP or not dragStripParkingSpot then return end

  local tutorialVeh = tutorialVehicleId and getObjectByID(tutorialVehicleId) or nil
  if not tutorialVeh then return end

  if phase == PHASE_DRIVE_TO_STRIP then
    if goals.driveToStripGoal.attention and driveGoalStartPos then
      local movedDist = tutorialVeh:getPosition():distance(driveGoalStartPos)
      if movedDist > DRIVE_GOAL_ATTENTION_CLEAR_DISTANCE_M then
        goals.driveToStripGoal.attention = false
      tasklistLocale.setTasklistTask(taskUpdates.driveToStripAttentionOff)
      end
    end
    local dist = tutorialVeh:getPosition():distance(dragStripParkingSpot.pos)
    if dist <= NEAR_STAGING_DISTANCE_M then
      phase = PHASE_PARK_IN_STAGING
      guihooks.trigger("DiscardTasklistItem", goals.driveToStripGoal.id)
      tasklistLocale.setTasklistTask(goals.parkInStagingGoal)
    end
    return
  end

  if not goals.parkInStagingGoal.done and checkParkGoal(dtReal) then
    goals.parkInStagingGoal.done = true
    tasklistLocale.setTasklistTask(goals.parkInStagingGoal)
    clearRoute()
    core_jobsystem.create(function(job)
      job.sleep(1.0)
      career_modules_tutorial.activateStep("06dragStripBasics")
    end, 1)
  end
end

function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  clearRoute()
  guihooks.trigger("ClearTasklist")
  clearStagingVisuals()
end

function M.onDebugMenu(im)
  im.Text("Step 5 - Drive To Drag Strip")
  im.Separator()
  im.Text(string.format("Phase: %s", tostring(phase)))
  if im.Button("Skip Step 5") then
    local spot = dragStripParkingSpot
    if not spot and gameplay_tutorial_setup.tutorialSites then
      spot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["beforeDragStrip"]
    end
    local veh = tutorialVehicleId and getObjectByID(tutorialVehicleId) or getPlayerVehicle(0)
    if spot and veh then
      spawn.safeTeleport(veh, spot.pos, spot.rot)
    end
    clearRoute()
    career_modules_tutorial.activateStep("06dragStripBasics")
  end
end

return M
