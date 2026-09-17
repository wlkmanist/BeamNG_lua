-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")
local logTag = "tutorial_step1"

local PHASE_WAIT_LOADING_SCREEN = "waitLoadingScreen"
local PHASE_GET_IN_CAR = "getInCar"
local PHASE_WAIT_BASIC_CONTROLS_POPUP = "waitBasicControlsPopup"
local PHASE_CONTROLS = "controls"
local PHASE_SHIFT_MODE = "shiftMode"
local PHASE_WAIT_BEGIN_FIRST_CHALLENGE = "waitBeginFirstChallenge"

local phase = PHASE_GET_IN_CAR
local vehicleMarkerId = nil
local startupInstantResetDone = false
local controlsCompleteScheduled = false

local headers = {
  approachVehicle = { label = "ui.career.tutorial.task.step01.header.approachVehicle" },
  basicControls = { label = "ui.career.tutorial.task.step01.header.basicControls" },
}

-- Goal state
local goals = {
  getInCarGoal = { done = false, id = "step1_getInCarGoal", type = "goal", label = "ui.career.tutorial.task.step01.goal.getInCar.label", subtext = "ui.career.tutorial.task.step01.goal.getInCar.subtext", actionItems = { { action = "toggleWalkingMode" } }, attention = true },
  throttleGoal = { done = false, id = "step1_throttleGoal", type = "goal", label = "ui.career.tutorial.task.step01.goal.throttle.label", actionItems = { { action = "accelerate" } }, attention = true },
  brakeGoal = { done = false, id = "step1_brakeGoal", type = "goal", label = "ui.career.tutorial.task.step01.goal.brake.label", actionItems = { { action = "brake" } }, attention = true },
  steerGoal = { done = false, id = "step1_steerGoal", type = "goal", label = "ui.career.tutorial.task.step01.goal.steer.label", actionItems = { { action = "steer_left", showIfController = false }, { action = "steer_right", showIfController = false }, { action = "steering", showIfController = true } }, attention = true },
}


-- Called when step becomes active
function M.setup(stepData)
  startupInstantResetDone = false
  controlsCompleteScheduled = false
  phase = PHASE_WAIT_LOADING_SCREEN
  -- Reset goals
  for _, goal in pairs(goals) do
    goal.done = false
  end
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(function()
    gameplay_tutorial_setup.placePlayerBackToParkingStart()
  end)

  gameplay_tutorial_bounds.setActiveZones({"evalZone"})

  gameplay_tutorial_damageTracker.setEnabled(true)

  core_recoveryPrompt.setDefaultsForTutorial()

  ui_appContainers.setAppVisibility("topLeft", "tasks", true)


end

function M.onCareerTutorialLeftBounds()
  -- Keep one startup-safe instant reset, then use fade for all subsequent OOB resets (walking or driving).
  if gameplay_tutorial_setup.isOutOfBoundsResetAllowed() or startupInstantResetDone then
    gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
  else
    startupInstantResetDone = true
    gameplay_tutorial_setup.placePlayerBackToParkingStart()
  end
end

-- Called every frame while step is active (via extension system)
function M.onUpdate(dtReal, dtSim, dtRaw)
  if not gameplay_tutorial_setup.vehicleSetupComplete or ui_router.isLoadingScreenActive() then
    return
  end
  if phase == PHASE_WAIT_LOADING_SCREEN then
    phase = PHASE_GET_IN_CAR
    career_modules_tutorialPopups.introPopupSequence({"v2/tutorialStart", "v2/approachVehicle"}, true)
    return
  end
  if phase == PHASE_GET_IN_CAR and not goals.getInCarGoal.done then
    if not gameplay_walk.isWalking() then
      goals.getInCarGoal.done = true
      tasklistLocale.setTasklistTask(goals.getInCarGoal)

      -- Remove vehicle marker
      if vehicleMarkerId and gameplay_tutorial_markers then
        gameplay_tutorial_markers.removeMarker(vehicleMarkerId)
        vehicleMarkerId = nil
      end

      core_camera.setByName(0,"driver")

      phase = PHASE_WAIT_BASIC_CONTROLS_POPUP
      core_jobsystem.create(function(job)
        job.sleep(0.5)
        career_modules_tutorialPopups.introPopup("v2/basicControls", true)
      end, 1)
    end
  end

  if phase == PHASE_CONTROLS then
    local throttle = core_vehicleBridge.getCachedVehicleData(gameplay_tutorial_setup.tutorialVehicleId, 'throttle_input') or 0
    local brake = core_vehicleBridge.getCachedVehicleData(gameplay_tutorial_setup.tutorialVehicleId, 'brake_input') or 0
    local steering = core_vehicleBridge.getCachedVehicleData(gameplay_tutorial_setup.tutorialVehicleId, 'steering_input') or 0
    if not goals.throttleGoal.done and throttle > 0.75 then
      goals.throttleGoal.done = true
      tasklistLocale.setTasklistTask(goals.throttleGoal)
    end
    if not goals.brakeGoal.done and brake > 0.75 then
      goals.brakeGoal.done = true
      tasklistLocale.setTasklistTask(goals.brakeGoal)
    end
    if not goals.steerGoal.done and math.abs(steering) > 0.5 then
      goals.steerGoal.done = true
      tasklistLocale.setTasklistTask(goals.steerGoal)
    end
    if not controlsCompleteScheduled and goals.throttleGoal.done and goals.brakeGoal.done and goals.steerGoal.done then
      controlsCompleteScheduled = true
      core_jobsystem.create(function(job)
        job.sleep(1)
        phase = PHASE_SHIFT_MODE
        guihooks.trigger("ClearTasklist")
        extensions.ui_popup.openDrivingAssistsPopup()
        return
      end, 1)
    end
  end
end

-- Called when step completes or tutorial ends
function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  startupInstantResetDone = false
  -- Remove vehicle marker if still active
  if vehicleMarkerId and gameplay_tutorial_markers then
    gameplay_tutorial_markers.removeMarker(vehicleMarkerId)
    vehicleMarkerId = nil
  end
end

-- Called when intro popup is closed (once per page; tasklist runs only after the last page, approachVehicle)
function M.onIntroPopupCareerClosed(id)
  if id == "v2/approachVehicle" then
    guihooks.trigger("ClearTasklist")
    tasklistLocale.setTasklistHeader(headers.approachVehicle)
    gameplay_tutorial_setup.blockedActionsTemplates.walkingMode = false
    gameplay_tutorial_setup.setupBlockedActions()
    gameplay_tutorial_setup.activateOutOfBoundsSystem()
    tasklistLocale.setTasklistTask(goals.getInCarGoal)
    gameplay_tutorial_damageTracker.showRepairTask()
    local veh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
    if veh and gameplay_tutorial_markers then
      vehicleMarkerId = gameplay_tutorial_markers.createMarkerAboveVehicle(veh)
    end
    return
  end

  if id == "v2/basicControls" and phase == PHASE_WAIT_BASIC_CONTROLS_POPUP then
    phase = PHASE_CONTROLS
    gameplay_tutorial_setup.setOutOfBoundsResetAllowed(true)
    local veh = getObjectByID(gameplay_tutorial_setup.tutorialVehicleId)
    if veh then
      core_vehicleBridge.registerValueChangeNotification(veh, 'throttle_input')
      core_vehicleBridge.registerValueChangeNotification(veh, 'brake_input')
      core_vehicleBridge.registerValueChangeNotification(veh, 'steering_input')
      core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 3)
      core_vehicleBridge.executeAction(veh, 'shiftToGearIndex', 0)
    end
    guihooks.trigger("ClearTasklist")
    tasklistLocale.setTasklistHeader(headers.basicControls)
    tasklistLocale.setTasklistTask(goals.throttleGoal)
    tasklistLocale.setTasklistTask(goals.brakeGoal)
    tasklistLocale.setTasklistTask(goals.steerGoal)
    gameplay_tutorial_damageTracker.showRepairTask()
  end

  if id == "v2/beginFirstChallenge" and phase == PHASE_WAIT_BEGIN_FIRST_CHALLENGE then
    career_modules_tutorial.activateStep("02moveOff")
  end
end

-- Called from GearboxSelect.vue when user confirms shift mode (lua.extensions.hook)
function M.onShiftModeSelectedViaPopup(data)
  if phase ~= PHASE_SHIFT_MODE then return end
  phase = PHASE_WAIT_BEGIN_FIRST_CHALLENGE
  guihooks.trigger("ClearTasklist")
  local veh = getObjectByID(gameplay_tutorial_setup.tutorialVehicleId)
  if veh then
    core_vehicleBridge.executeAction(veh, 'setGearboxMode', data.mode)
  end
  log("I", logTag, string.format("Settings: gearboxMode %s, autoClutch %s", settings.getValue("defaultGearboxBehavior", "none?"), settings.getValue("autoClutch", true)))
  career_modules_tutorialPopups.introPopup("v2/beginFirstChallenge", true)
end

-- Skip step 1 - advance to completion state
local function skipStep()
  -- Remove vehicle marker
  if vehicleMarkerId and gameplay_tutorial_markers then
    gameplay_tutorial_markers.removeMarker(vehicleMarkerId)
    vehicleMarkerId = nil
  end

  local veh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if veh then
    if gameplay_walk and gameplay_walk.isWalking() then
      gameplay_walk.getInVehicle(veh)
      commands.setGameCamera()
    end
    core_camera.setByName(0, "driver")
    core_vehicleBridge.executeAction(veh, 'setGearboxMode', settings.getValue("defaultGearboxBehavior", "none?"))
    core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', 3)
    core_vehicleBridge.executeAction(veh, 'shiftToGearIndex', 0)
  end

  -- Mark all goals as done
  for _, goal in pairs(goals) do
    goal.done = true
  end

  -- Clear tasklist and advance
  guihooks.trigger("ClearTasklist")
  career_modules_tutorial.advanceToNextStep()
end

-- Debug menu for this step
function M.onDebugMenu(im)
  im.Separator()
  if im.Button("Skip Step 1") then
    skipStep()
  end
end

return M
