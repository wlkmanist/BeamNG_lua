-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")
local logTag = "tutorial_step3"

local PARK_STATIONARY_SECONDS = 1.0

local headers = {
  firstChallenge = {
    label = "ui.career.tutorial.task.step03.header.firstChallenge",
  },
}

local messages = {
  cameraViewsMessage = {
    id = "step3_drive_around_msg",
    type = "message",
    label = "ui.career.tutorial.task.step03.message.cameraViews",
    actionItems = {
      { action = "switch_camera_next" },
    },
    clear = false
  },
  readyToParkMessage = {
    id = "step3_ready_to_park_msg",
    type = "message",
    label = "ui.career.tutorial.task.step03.message.readyToPark",
    clear = false
  },
}

local goals = {
  parkGoal = { done = false, id = "step3_parkGoal", type = "goal", label = "ui.career.tutorial.task.step03.goal.park.label" },
}

local parkingGoalActive = false
local parkingSpotMarkerId = nil
local parkingSpot = nil
local parkGoalState = {}

local function checkParkGoal(dtReal)
  if not parkingSpot or not gameplay_tutorial_setup.tutorialVehicleId then return false end
  local veh = getObjectByID(gameplay_tutorial_setup.tutorialVehicleId)
  if not veh then return false end
  return gameplay_tutorial_markers.checkParkGoalWithStationaryTime(veh, parkingSpot, dtReal, PARK_STATIONARY_SECONDS, parkGoalState)
end

local function startParkingPhase()
  if parkingGoalActive then return end
  parkingGoalActive = true
  gameplay_tutorial_setup.unblockGearActions()

  local veh = getObjectByID(gameplay_tutorial_setup.tutorialVehicleId)
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', false)
  end
  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.firstChallenge)
  tasklistLocale.setTasklistTask(messages.cameraViewsMessage)
  tasklistLocale.setTasklistTask(messages.readyToParkMessage)
  tasklistLocale.setTasklistTask(goals.parkGoal)

  if not parkingSpotMarkerId and gameplay_tutorial_setup.tutorialSites then
    parkingSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["simpleCourseStart"]
    if parkingSpot then
      local markerPos = vec3(parkingSpot.pos.x, parkingSpot.pos.y, parkingSpot.pos.z + 2)
      parkingSpotMarkerId = gameplay_tutorial_markers.createMarker(markerPos, nil, vec3(1.5, 1.5, 1.5))
      gameplay_tutorial_markers.addParkingSpotDecal(parkingSpot)
    else
      log('W', logTag, 'Parking spot simpleCourseStart not found')
    end
  end
end

local function clearParkingVisuals()
  if parkingSpotMarkerId then
    gameplay_tutorial_markers.removeMarker(parkingSpotMarkerId)
    parkingSpotMarkerId = nil
  end
  if parkingSpot then
    gameplay_tutorial_markers.removeParkingSpotDecal(parkingSpot.name)
  end
end

-- Called when step becomes active
function M.setup(stepData)
  goals.parkGoal.done = false
  parkingGoalActive = false
  parkingSpotMarkerId = nil
  parkingSpot = nil
  parkGoalState = {}

  gameplay_tutorial_bounds.setActiveZones({"evalZone"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(function()
    gameplay_tutorial_setup.placePlayerBackToParkingStart()
  end)

  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.firstChallenge)
  -- beginFirstChallenge was already shown in step01 after shift selection; go straight to parking phase
  startParkingPhase()
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

-- Called every frame while step is active (via extension system)
function M.onUpdate(dtReal, dtSim, dtRaw)
  if not parkingGoalActive or goals.parkGoal.done then return end
  if checkParkGoal(dtReal) then
    goals.parkGoal.done = true
    tasklistLocale.setTasklistTask(goals.parkGoal)
    core_jobsystem.create(function(job)
      job.sleep(1.5)
      career_modules_tutorial.advanceToNextStep()
    end, 1)
  end
end

-- Called when step completes or tutorial ends
function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  guihooks.trigger("ClearTasklist")
  clearParkingVisuals()
  parkingSpot = nil
end

local function skipStep()
  if gameplay_tutorial_setup.tutorialSites and gameplay_tutorial_setup.tutorialVehicleId then
    local veh = getObjectByID(gameplay_tutorial_setup.tutorialVehicleId)
    if veh then
      local targetSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["simpleCourseStart"]
      if targetSpot then
        local vehId = veh:getID()
        local pos = targetSpot.pos
        local rot = targetSpot.rot * quat(0, 0, 1, 0)
        vehicleSetPositionRotation(vehId, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
        log('D', logTag, 'Placed vehicle on parking spot: simpleCourseStart')
      end
    end
  end

  gameplay_tutorial_setup.unblockGearActions()
  local veh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if veh then
    core_vehicleBridge.executeAction(veh, 'setFreeze', false)
  end

  -- Mark all goals as done
  goals.parkGoal.done = true

  clearParkingVisuals()

  -- Clear tasklist and advance
  guihooks.trigger("ClearTasklist")
  career_modules_tutorial.advanceToNextStep()
end

-- Debug menu for this step
function M.onDebugMenu(im)
  im.Text("Step 3 - Basic Maneuvers:")
  im.Separator()
  im.Text(string.format("Parking Goal Active: %s", tostring(parkingGoalActive)))
  im.Separator()

  -- Goal status
  for _, goal in pairs(goals) do
    if goal.done then
      im.TextColored(im.ImVec4(0, 1, 0, 1), goal.label .. ": Completed")
    else
      im.Text(goal.label .. ": Not completed")
    end
  end

  im.Separator()
  if im.Button("Skip Step 3") then
    skipStep()
  end
end

return M
