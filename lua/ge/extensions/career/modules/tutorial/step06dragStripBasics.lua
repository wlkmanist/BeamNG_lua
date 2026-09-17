-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tasklistLocale = require("/lua/ge/extensions/career/modules/tutorial/tasklistLocale")
local logTag = "tutorial_step6"

local DQ_POPUP_DELAY_S = 0.15
local PREFAB_SWAP_DELAY_S = 0.5
local START_LINE_MARKER_HIDE_DISTANCE_M = 5.0
local APPROACH_COACHING_TRIGGER_DISTANCE_M = 15.0
local RESET_COACHING_AFTER_FAILED_ATTEMPTS = 3
local POPUP_PAUSE_TAG = "tutorialDragStripCoaching"
local TIMETRIAL_STYLE_BULLETTIME_START = 0.1
local TIMETRIAL_STYLE_BULLETTIME_END = 0.75
local TIMETRIAL_STYLE_BULLETTIME_DURATION_S = 2.0

local PHASE_WAIT_INTRO = "waitIntroPopup"
local PHASE_ACTIVE = "active"
local PHASE_WAIT_DQ_POPUP = "waitDqPopup"
local PHASE_WAIT_FALSESTART_RESTAGE = "waitFalseStartRestage"
local PHASE_WAIT_TIMESLIP_POPUP = "waitTimeslipPopup"

local RETURN_GOAL_LABEL_DEFAULT = "ui.career.tutorial.task.step06.goal.returnToStaging.label"
local RETURN_GOAL_SUBTEXT_DEFAULT = nil

local headers = {
  dragStrip = { label = "ui.career.tutorial.task.step06.header.dragStrip" },
}

local goals = {
  stageGoal = {
    done = false,
    id = "step6_stageGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step06.goal.stage.label",
  },
  raceStartGoal = {
    done = false,
    id = "step6_raceStartGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step06.goal.raceStart.label",
  },
  finishGoal = {
    done = false,
    id = "step6_finishGoal",
    type = "goal",
    label = "ui.career.tutorial.task.step06.goal.finish.label",
  },
  returnToStagingGoal = {
    done = false,
    id = "step6_returnToStagingGoal",
    type = "goal",
    label = RETURN_GOAL_LABEL_DEFAULT,
    subtext = RETURN_GOAL_SUBTEXT_DEFAULT,
  },
}

local tutorialVehicleId = nil
local advanceScheduled = false
local tutorialPopupClosed = false
local directionMarkerIds = {}
local returnParkingSpotMarkerId = nil
local stagingParkingSpot = nil
local dragStartLineSpot = nil
local dragStartLineMarkerId = nil
local internalPhase = PHASE_WAIT_INTRO
local dqPopupId = nil
local dqResetLane = nil
local dqPopupPending = false
local coachingPopupId = nil
local coachingPauseActive = false
local pendingCountdownReleaseSlowmo = false
local coachingApproachSeen = false
local coachingCountdownSeen = false
local failedAttemptsSinceCoachingReset = 0
local countdownReleaseBulletTimeActive = false
local countdownReleaseBulletTimeElapsed = 0
local timeslipPopupScheduled = false

local dragGuideSpotNames = {
  "dragGuide1",
  "dragGuide2",
  "dragGuide3",
}
local POPUP_WELCOME_ID = "v2/dragStripWelcome"
local POPUP_APPROACH_ID = "v2/dragTreeStages"
local POPUP_COUNTDOWN_ID = "v2/dragTreeCountdown"
local POPUP_TIMESLIP_ID = "v2/dragStripTimeslipIntro"
local APPROACH_POPUP_SEQUENCE_IDS = { "v2/dragStripStageCar", "v2/dragTreeStages" }

local function isPlayerInTutorialBounds()
  if not gameplay_tutorial_bounds or not gameplay_tutorial_bounds.isInBounds then
    return true
  end
  return gameplay_tutorial_bounds.isInBounds()
end

local function clearRouteToStaging()
  core_groundMarkers.setPath(nil)
end

local function clearDirectionMarkers()
  if not gameplay_tutorial_markers then
    directionMarkerIds = {}
    return
  end
  for _, markerId in ipairs(directionMarkerIds) do
    gameplay_tutorial_markers.removeMarker(markerId)
  end
  directionMarkerIds = {}
end

local function clearReturnParkingMarker()
  if returnParkingSpotMarkerId then
    gameplay_tutorial_markers.removeMarker(returnParkingSpotMarkerId)
    returnParkingSpotMarkerId = nil
  end
  if stagingParkingSpot then
    gameplay_tutorial_markers.removeParkingSpotDecal(stagingParkingSpot.name)
  end
end

local function clearDragStartLineMarker()
  if dragStartLineMarkerId and gameplay_tutorial_markers then
    gameplay_tutorial_markers.removeMarker(dragStartLineMarkerId)
  end
  dragStartLineMarkerId = nil
end

local function setupDragStartLineMarker()
  if dragStartLineMarkerId then return end
  if not dragStartLineSpot or not gameplay_tutorial_markers then return end
  local p = dragStartLineSpot.pos
  dragStartLineMarkerId = gameplay_tutorial_markers.createMarker(vec3(p.x, p.y, p.z + 2), nil, vec3(1.5, 1.5, 1.5))
end

local function showGoals()
  tasklistLocale.setTasklistHeader(headers.dragStrip)
  tasklistLocale.setTasklistTask(goals.stageGoal)
  tasklistLocale.setTasklistTask(goals.raceStartGoal)
  tasklistLocale.setTasklistTask(goals.finishGoal)
  setupDragStartLineMarker()
end

local function setCoachingPause(active)
  if active then
    if coachingPauseActive then return end
    simTimeAuthority.pushPauseRequest(POPUP_PAUSE_TAG)
    coachingPauseActive = true
    return
  end
  if not coachingPauseActive then return end
  simTimeAuthority.popPauseRequest(POPUP_PAUSE_TAG)
  coachingPauseActive = false
end

local function runCountdownReleaseSlowmo()
  countdownReleaseBulletTimeActive = true
  countdownReleaseBulletTimeElapsed = 0
  simTimeAuthority.setInstant(TIMETRIAL_STYLE_BULLETTIME_START)
end

local function openCoachingPopup(id, slowmoAfterClose)
  if not id then return end
  pendingCountdownReleaseSlowmo = slowmoAfterClose and true or false
  coachingPopupId = id
  setCoachingPause(true)
  career_modules_tutorialPopups.introPopup(id, true)
end

local function openCoachingPopupSequence(ids, endId, slowmoAfterClose)
  if type(ids) ~= "table" or #ids == 0 then return end
  pendingCountdownReleaseSlowmo = slowmoAfterClose and true or false
  coachingPopupId = endId
  setCoachingPause(true)
  career_modules_tutorialPopups.introPopupSequence(ids, true)
end

local function showReturnToStagingGoal()
  guihooks.trigger("ClearTasklist")
  tasklistLocale.setTasklistHeader(headers.dragStrip)
  tasklistLocale.setTasklistTask(goals.returnToStagingGoal)
end

local function markGoalDone(goal)
  if goal.done then return end
  goal.done = true
  tasklistLocale.setTasklistTask(goal)
end

local function scheduleAdvance()
  if advanceScheduled then return end
  advanceScheduled = true
  core_jobsystem.create(function(job)
    job.sleep(1.0)
    career_modules_tutorial.advanceToNextStep()
  end, 1)
end

local function setupDirectionMarkers()
  if not gameplay_tutorial_setup.tutorialSites then return end

  local parkingSpots = gameplay_tutorial_setup.tutorialSites.parkingSpots
  local byName = parkingSpots and parkingSpots.byName
  if not byName then return end

  clearDirectionMarkers()

  for _, spotName in ipairs(dragGuideSpotNames) do
    local parkingSpot = byName[spotName]
    if parkingSpot then
      local markerId = gameplay_tutorial_markers.createDirectionMarkerFromParkingSpot(parkingSpot)
      if markerId then
        table.insert(directionMarkerIds, markerId)
      end
    end
  end
end

local function showDragExplanationPopup()
  openCoachingPopup(POPUP_WELCOME_ID, false)
end

local function resetAttemptState(keepIntroClosed)
  goals.stageGoal.done = false
  goals.raceStartGoal.done = false
  goals.finishGoal.done = false
  goals.returnToStagingGoal.done = false
  goals.returnToStagingGoal.label = RETURN_GOAL_LABEL_DEFAULT
  goals.returnToStagingGoal.subtext = RETURN_GOAL_SUBTEXT_DEFAULT
  dqPopupId = nil
  dqResetLane = nil
  dqPopupPending = false
  coachingPopupId = nil
  pendingCountdownReleaseSlowmo = false
  timeslipPopupScheduled = false
  tutorialPopupClosed = keepIntroClosed and true or false
  if keepIntroClosed then
    internalPhase = PHASE_ACTIVE
  else
    internalPhase = PHASE_WAIT_INTRO
  end
end

local function restartAttempt()
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end

  -- Regular retry path: keep gameplay active and avoid replaying intro coaching by default.
  resetAttemptState(true)
  clearRouteToStaging()
  clearReturnParkingMarker()
  setupDirectionMarkers()
  showGoals()
end

local function restartAttemptFromOob()
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end

  -- OOB reset should never replay intro popups.
  resetAttemptState(true)
  tutorialPopupClosed = true
  clearRouteToStaging()
  clearReturnParkingMarker()
  setupDirectionMarkers()
  showGoals()
end

local function resetToStep6Start()
  local sites = gameplay_tutorial_setup.tutorialSites
  local spot = sites and sites.parkingSpots and sites.parkingSpots.byName and sites.parkingSpots.byName["dragStripResetSpot"] or nil
  local tutorialVeh = tutorialVehicleId and getObjectByID(tutorialVehicleId) or nil
  if not tutorialVeh then
    tutorialVeh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  end
  if not tutorialVeh or not spot then return end

  spawn.safeTeleport(tutorialVeh, spot.pos, spot.rot, nil, nil, nil, nil, false)
  tutorialVeh:queueLuaCommand('obj:requestReset(RESET_PHYSICS)')
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_walk.getInVehicle(tutorialVeh)
  end
  clearRouteToStaging()
  clearReturnParkingMarker()
  core_jobsystem.create(function(job)
    job.sleep(0.1)
    if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
    if gameplay_drag_dragBridge then
      gameplay_drag_dragBridge.reset()
      gameplay_drag_dragBridge.startDragRaceActivity(dqResetLane or 1)
    end
  end, 1)
end

local function beginReturnToStagingPhase()
  if internalPhase ~= PHASE_WAIT_DQ_POPUP then return end
  dqPopupPending = false
  goals.returnToStagingGoal.done = false
  clearDirectionMarkers()
  clearDragStartLineMarker()
  clearRouteToStaging()
  internalPhase = PHASE_WAIT_FALSESTART_RESTAGE
  goals.returnToStagingGoal.label = RETURN_GOAL_LABEL_DEFAULT
  goals.returnToStagingGoal.subtext = RETURN_GOAL_SUBTEXT_DEFAULT
  clearReturnParkingMarker()
  showReturnToStagingGoal()
end

local function getTutorialRacerData()
  if not tutorialVehicleId then return nil end
  if gameplay_drag_dragBridge and gameplay_drag_dragBridge.getDragRaceData then
    local dragData = gameplay_drag_dragBridge.getDragRaceData()
    if dragData and dragData.vehicleId == tutorialVehicleId then
      return dragData
    end
  end
  return nil
end

local function getDqPopupId(reason)
  if type(reason) ~= "string" then
    return "v2/dragDisqualifyLeaveLane"
  end
  local reasonLower = string.lower(reason)
  if string.find(reasonLower, "jump", 1, true) then
    return "v2/dragDisqualifyFalseStart"
  end
  return "v2/dragDisqualifyLeaveLane"
end

local function beginDisqualificationFlow(reason)
  if internalPhase ~= PHASE_ACTIVE or dqPopupPending then return end
  local racerData = getTutorialRacerData()
  failedAttemptsSinceCoachingReset = failedAttemptsSinceCoachingReset + 1
  if failedAttemptsSinceCoachingReset >= RESET_COACHING_AFTER_FAILED_ATTEMPTS then
    failedAttemptsSinceCoachingReset = 0
    coachingApproachSeen = false
    coachingCountdownSeen = false
  end
  dqPopupId = getDqPopupId(reason)
  dqResetLane = racerData and racerData.lane or dqResetLane or 1
  dqPopupPending = true
  internalPhase = PHASE_WAIT_DQ_POPUP
  setCoachingPause(false)
  clearDirectionMarkers()
  clearDragStartLineMarker()
  clearRouteToStaging()

  core_jobsystem.create(function(job)
    job.sleep(DQ_POPUP_DELAY_S)
    if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
    if internalPhase ~= PHASE_WAIT_DQ_POPUP then return end
    if not dqPopupId then return end
    career_modules_tutorialPopups.introPopup(dqPopupId, true)
  end, 1)
end

function M.setup(stepData)
  resetAttemptState()
  tutorialVehicleId = gameplay_tutorial_setup.tutorialVehicleId
  advanceScheduled = false
  directionMarkerIds = {}
  returnParkingSpotMarkerId = nil
  stagingParkingSpot = nil
  dragStartLineSpot = nil
  dragStartLineMarkerId = nil
  coachingPopupId = nil
  coachingPauseActive = false
  pendingCountdownReleaseSlowmo = false
  coachingApproachSeen = false
  coachingCountdownSeen = false
  failedAttemptsSinceCoachingReset = 0
  countdownReleaseBulletTimeActive = false
  countdownReleaseBulletTimeElapsed = 0
  timeslipPopupScheduled = false

  gameplay_tutorial_bounds.setActiveZones({"drivingToDragBounds", "dragStripBounds"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(resetToStep6Start)

  local sites = gameplay_tutorial_setup.tutorialSites
  local spotsByName = sites and sites.parkingSpots and sites.parkingSpots.byName
  stagingParkingSpot = spotsByName and spotsByName["beforeDragStrip"] or nil
  dragStartLineSpot = spotsByName and spotsByName["dragStartLine"] or nil
  if not stagingParkingSpot then
    log("W", logTag, "Parking spot beforeDragStrip not found in step06 setup")
  end
  if not dragStartLineSpot then
    log("W", logTag, "Parking spot dragStartLine not found in step06 setup")
  end

  guihooks.trigger("ClearTasklist")
  showDragExplanationPopup()
  core_jobsystem.create(function(job)
    job.sleep(PREFAB_SWAP_DELAY_S)
    if career_modules_tutorial.getCurrentStep() == "06dragStripBasics" then
      -- Hide swap during welcome popup: move strip from closed-arrival to open-drive state.
      gameplay_tutorial_setup.setActivePrefabs({
        startingArea = false,
        tutorialTrackOpen = false,
        tutorialTrackClosed = false,
        driveToDragStripGuidesClosed = false,
        driveToDragStripGuidesOpen = true,
        dragStripStartLine = true
      })
    end
  end, 1)

  setupDirectionMarkers()
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

function M.onIntroPopupCareerClosed(id)
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end

  if id == coachingPopupId then
    coachingPopupId = nil
    setCoachingPause(false)
    if pendingCountdownReleaseSlowmo then
      pendingCountdownReleaseSlowmo = false
      runCountdownReleaseSlowmo()
    end
  end

  if id == POPUP_WELCOME_ID and internalPhase == PHASE_WAIT_INTRO then
    tutorialPopupClosed = true
    internalPhase = PHASE_ACTIVE
    failedAttemptsSinceCoachingReset = 0
    showGoals()
    return
  end

  if id == POPUP_APPROACH_ID then
    coachingApproachSeen = true
    return
  end

  if id == POPUP_COUNTDOWN_ID then
    coachingCountdownSeen = true
    return
  end

  if id == POPUP_TIMESLIP_ID and internalPhase == PHASE_WAIT_TIMESLIP_POPUP then
    scheduleAdvance()
    return
  end

  if id == dqPopupId and internalPhase == PHASE_WAIT_DQ_POPUP then
    -- Only auto-reset for leave-lane (far from start), not false start (still at start line)
    if dqPopupId == "v2/dragDisqualifyLeaveLane" then
      -- Auto-reset using OOB system: this properly resets the drag race and teleports
      -- Don't count leave-lane as a failed attempt since we auto-recover
      if failedAttemptsSinceCoachingReset > 0 then
        failedAttemptsSinceCoachingReset = failedAttemptsSinceCoachingReset - 1
      end
      -- Keep phase and dqPopupPending during entire reset to prevent re-trigger
      gameplay_tutorial_setup.runOutOfBoundsResetWithFade(resetToStep6Start)
      -- After OOB fade completes, restart the attempt and clear DQ flag
      core_jobsystem.create(function(job)
        job.sleep(2.5)  -- Wait for fade out + reset + fade in to complete
        if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
        restartAttemptFromOob()
        dqPopupPending = false
      end, 1)
    else
      -- False start: just show return-to-staging task (they're already near the start)
      beginReturnToStagingPhase()
    end
  end
end

-- Drag hook from gameplay_drag_utils: phase transition for a specific racer.
-- We use this to complete the staging goal once the player moves from stage to countdown.
function M.onRacerPhaseTransition(vehId, oldPhase, newPhase, newPhaseName)
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
  if not tutorialPopupClosed then return end
  if not tutorialVehicleId or vehId ~= tutorialVehicleId then return end
  if not isPlayerInTutorialBounds() then return end
  if newPhaseName == "countdown" or newPhase == 2 then
    clearDragStartLineMarker()
    markGoalDone(goals.stageGoal)
    if not coachingCountdownSeen then
      coachingCountdownSeen = true
      openCoachingPopup(POPUP_COUNTDOWN_ID, true)
    end
  end
end

-- Drag hook from gameplay_drag_utils/general when race actually starts (green).
function M.dragRaceStarted(vehId)
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
  if not tutorialPopupClosed then return end
  if internalPhase ~= PHASE_ACTIVE then return end
  if not tutorialVehicleId or vehId ~= tutorialVehicleId then return end
  if not isPlayerInTutorialBounds() then return end
  -- If staging event was missed, race start implies staging happened.
  clearDragStartLineMarker()
  markGoalDone(goals.stageGoal)
  markGoalDone(goals.raceStartGoal)
end

-- Drag hook from gameplay_drag_utils when player reaches race end timer.
function M.dragRaceEndLineReached(vehId)
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
  if not tutorialPopupClosed then return end
  if internalPhase ~= PHASE_ACTIVE then return end
  if not tutorialVehicleId or vehId ~= tutorialVehicleId then return end
  if not isPlayerInTutorialBounds() then return end

  local racerData = getTutorialRacerData()
  if racerData and racerData.isDisqualified then
    beginDisqualificationFlow(racerData.disqualificationReason)
    return
  end

  markGoalDone(goals.finishGoal)
  internalPhase = PHASE_WAIT_TIMESLIP_POPUP
  if timeslipPopupScheduled then return end
  timeslipPopupScheduled = true
  core_jobsystem.create(function(job)
    job.sleep(2.0)
    if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
    if internalPhase ~= PHASE_WAIT_TIMESLIP_POPUP then return end
    -- Ensure career layout so the tutorial popup is visible (drag/time trial UI can take over otherwise).
    if core_gamestate then
      core_gamestate.setGameState("career", "career", nil)
    end
    career_modules_tutorialPopups.introPopup(POPUP_TIMESLIP_ID, true)
    -- Keep popup visible first, then quickly clear strip guide prefabs for the handoff.
    job.sleep(PREFAB_SWAP_DELAY_S)
    if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
    if internalPhase ~= PHASE_WAIT_TIMESLIP_POPUP then return end
    gameplay_tutorial_setup.setActivePrefabs({
      driveToDragStripGuidesClosed = false,
      driveToDragStripGuidesOpen = false
    })
  end, 1)
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end

  if countdownReleaseBulletTimeActive then
    countdownReleaseBulletTimeElapsed = countdownReleaseBulletTimeElapsed + dtReal
    local a = math.min(1, countdownReleaseBulletTimeElapsed / TIMETRIAL_STYLE_BULLETTIME_DURATION_S)
    local value = TIMETRIAL_STYLE_BULLETTIME_START + (TIMETRIAL_STYLE_BULLETTIME_END - TIMETRIAL_STYLE_BULLETTIME_START) * (a * a)
    simTimeAuthority.setInstant(value)
    if a >= 1 then
      simTimeAuthority.setInstant(1)
      countdownReleaseBulletTimeActive = false
      countdownReleaseBulletTimeElapsed = 0
    end
  end

  if not tutorialPopupClosed then return end
  if not isPlayerInTutorialBounds() then return end

  if internalPhase == PHASE_ACTIVE then
    if not coachingApproachSeen and dragStartLineSpot and tutorialVehicleId then
      local veh = getObjectByID(tutorialVehicleId)
      if veh and veh:getPosition():distance(dragStartLineSpot.pos) <= APPROACH_COACHING_TRIGGER_DISTANCE_M then
        coachingApproachSeen = true
        openCoachingPopupSequence(APPROACH_POPUP_SEQUENCE_IDS, POPUP_APPROACH_ID, false)
        -- Remove start line prefab after popup is visible to prevent lag
        core_jobsystem.create(function(job)
          job.sleep(0.5)
          if career_modules_tutorial.getCurrentStep() == "06dragStripBasics" then
            gameplay_tutorial_setup.setActivePrefabs({ dragStripStartLine = false })
          end
        end, 1)
        return
      end
    end
    if dragStartLineMarkerId and tutorialVehicleId then
      local veh = getObjectByID(tutorialVehicleId)
      if veh and dragStartLineSpot and veh:getPosition():distance(dragStartLineSpot.pos) <= START_LINE_MARKER_HIDE_DISTANCE_M then
        clearDragStartLineMarker()
      end
    end
    local racerData = getTutorialRacerData()
    if racerData and racerData.isDisqualified then
      beginDisqualificationFlow(racerData.disqualificationReason)
      return
    end
    return
  end

end

-- Drag hook fired when racers are set up for a new staging attempt.
function M.onDragRacersSetup(data)
  if career_modules_tutorial.getCurrentStep() ~= "06dragStripBasics" then return end
  if internalPhase ~= PHASE_WAIT_FALSESTART_RESTAGE then return end
  if not tutorialPopupClosed then return end

  markGoalDone(goals.returnToStagingGoal)
  guihooks.trigger("ClearTasklist")
  clearRouteToStaging()
  clearReturnParkingMarker()
  core_jobsystem.create(function(job)
    job.sleep(1.0)
    restartAttempt()
  end, 1)
end

function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  setCoachingPause(false)
  simTimeAuthority.setInstant(1)
  countdownReleaseBulletTimeActive = false
  countdownReleaseBulletTimeElapsed = 0
  timeslipPopupScheduled = false
  clearRouteToStaging()
  guihooks.trigger("ClearTasklist")
  clearDirectionMarkers()
  clearDragStartLineMarker()
  clearReturnParkingMarker()
  returnParkingSpotMarkerId = nil
  stagingParkingSpot = nil
  dragStartLineSpot = nil
end

function M.onDebugMenu(im)
  im.Text("Step 6 - Drag Strip Basics")
  im.Separator()
  im.Text(string.format("Internal phase: %s", tostring(internalPhase)))
  im.Text(string.format("Tutorial popup closed: %s", tutorialPopupClosed and "Yes" or "No"))
  im.Text(string.format("Staged: %s", goals.stageGoal.done and "Done" or "Pending"))
  im.Text(string.format("Race started: %s", goals.raceStartGoal.done and "Done" or "Pending"))
  im.Text(string.format("Finished: %s", goals.finishGoal.done and "Done" or "Pending"))
  im.Text(string.format("Return to staging: %s", goals.returnToStagingGoal.done and "Done" or "Pending"))
  if im.Button("Skip Step 6") then
    if not tutorialPopupClosed then
      tutorialPopupClosed = true
      internalPhase = PHASE_ACTIVE
      showGoals()
    end
    markGoalDone(goals.stageGoal)
    markGoalDone(goals.raceStartGoal)
    markGoalDone(goals.finishGoal)
    scheduleAdvance()
  end
end

return M
