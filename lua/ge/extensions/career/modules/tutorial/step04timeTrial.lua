-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "tutorial_step4"
local PREFAB_SWAP_DELAY_S = 0.5

local TUTORIAL_MISSION_ID = "west_coast_usa/timeTrial/tutorialSimple"
local TUTORIAL_ADVANCED_MISSION_ID = "west_coast_usa/timeTrial/tutorialAdvanced"
local PHASE_WAIT_INTRO = "waitIntro"
local PHASE_SIMPLE_MISSION = "simpleMission"
local PHASE_WAIT_CHOICE_POPUP = "waitChoicePopup"
local PHASE_WAIT_POST_SIMPLE_POPUP_CLOSE = "waitPostSimplePopupClose"
local PHASE_WAIT_CHOICE_SELECTION = "waitChoiceSelection"
local PHASE_ADVANCED_MISSION = "advancedMission"
local POST_SIMPLE_TRIAL_POPUP_ID = "v2/timeTrialAssessmentComplete"

local phase = PHASE_WAIT_INTRO
local tutorialFinishSpot = nil
local activeTutorialRace = nil
local currentRouteKey = nil
local oobRestartInProgress = false
local pendingPostSimpleAssessmentPopup = false

local function clearRouteToTutorialFinish()
  core_groundMarkers.setPath(nil)
  currentRouteKey = nil
end

local function setRouteToTutorialFinish()
  if not tutorialFinishSpot then
    return
  end
  core_groundMarkers.setPath(tutorialFinishSpot.pos)
end

local function isTutorialSimpleRace(race)
  return race and race.saveFileSuffix == TUTORIAL_MISSION_ID
end

local function appendPathnode(routePoints, routeIds, usedIds, pathnode)
  if not pathnode or not pathnode.pos or not pathnode.id then return end
  if usedIds[pathnode.id] then return end
  usedIds[pathnode.id] = true
  table.insert(routePoints, pathnode.pos)
  table.insert(routeIds, tostring(pathnode.id))
end

local function setRouteFromRace(race)
  if not race then return end

  local playerVeh = getPlayerVehicle(0)
  if not playerVeh then return end

  local state = race.states and race.states[playerVeh:getID()] or nil
  if not state then return end

  local routePoints = {}
  local routeIds = {}
  local usedIds = {}

  -- For non-branching races, this ordered segment list follows the authored race path.
  if race.path and race.path.config and race.path.pathnodes and (not race.path.branching) and state.nonBranchingShiftedPathnodes then
    for _, segId in ipairs(state.nonBranchingShiftedPathnodes) do
      local graphElem = race.path.config.graph[segId]
      local nodeId = graphElem and graphElem.targetNode or nil
      local pathnode = nodeId and race.path.pathnodes.objects[nodeId] or nil
      appendPathnode(routePoints, routeIds, usedIds, pathnode)
    end
  end

  if #routePoints == 0 then
    for _, entry in ipairs(state.nextPathnodes or {}) do
      appendPathnode(routePoints, routeIds, usedIds, entry[1])
    end
    for _, entry in ipairs(state.overNextPathnodes or {}) do
      appendPathnode(routePoints, routeIds, usedIds, entry[1])
    end
  end

  if #routePoints > 0 then
    local newRouteKey = table.concat(routeIds, ",")
    if currentRouteKey ~= newRouteKey then
      core_groundMarkers.setPath(routePoints)
      currentRouteKey = newRouteKey
    end
    return
  end

  -- Player has reached the finish (TC_out); clear markers so we don't show route to finalPosFwd parking spot
  if currentRouteKey ~= "finish" then
    core_groundMarkers.setPath(nil)
    currentRouteKey = "finish"
  end
end

local function startTutorialMission()
  local mission = gameplay_missions_missions.getMissionById(TUTORIAL_MISSION_ID)
  if mission then
    gameplay_missions_missionManager.start(mission, {})
  else
    log('E', logTag, 'Mission not found: ' .. TUTORIAL_MISSION_ID)
  end
end

local function deactivateTutorialVehicle()
  local tutorialVeh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if tutorialVeh then
    tutorialVeh:setActive(0)
  end
end

local function ensurePlayerInTutorialVehicle()
  local tutorialVeh = gameplay_tutorial_setup.tutorialVehicleId and getObjectByID(gameplay_tutorial_setup.tutorialVehicleId) or nil
  if not tutorialVeh then return end
  tutorialVeh:setActive(1)
  if gameplay_walk and gameplay_walk.isWalking() then
    gameplay_tutorial_setup.placePlayerBackInTutorialVehicle()
  end
end

-- Called when step becomes active
function M.setup(stepData)
  gameplay_tutorial_bounds.setActiveZones({"timeTrialBounds"})
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(function()
    gameplay_tutorial_setup.placePlayerBackToParkingStart()
  end)

  phase = PHASE_WAIT_INTRO
  activeTutorialRace = nil
  currentRouteKey = nil
  oobRestartInProgress = false
  pendingPostSimpleAssessmentPopup = false
  tutorialFinishSpot = nil
  if gameplay_tutorial_setup.tutorialSites then
    tutorialFinishSpot = gameplay_tutorial_setup.tutorialSites.parkingSpots.byName["simpleTimeTrialFinish"]
    if not tutorialFinishSpot then
      log('W', logTag, 'Parking spot not found: simpleTimeTrialFinish')
    end
  end
  ensurePlayerInTutorialVehicle()
  career_modules_tutorialPopups.introPopup("v2/simpleTimeTrial", true)
end

function M.onIntroPopupCareerClosed(id)
  if id == POST_SIMPLE_TRIAL_POPUP_ID then
    if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
    if phase ~= PHASE_WAIT_POST_SIMPLE_POPUP_CLOSE then return end
    pendingPostSimpleAssessmentPopup = false
    phase = PHASE_WAIT_CHOICE_SELECTION
    extensions.ui_popup.openOptionalChallengeSelectionPopup()
    return
  end

  if id ~= "v2/simpleTimeTrial" then return end
  if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
  if phase ~= PHASE_WAIT_INTRO then return end
  ensurePlayerInTutorialVehicle()
  phase = PHASE_SIMPLE_MISSION
  startTutorialMission()
  core_jobsystem.create(function(job)
    job.sleep(PREFAB_SWAP_DELAY_S)
    if career_modules_tutorial.getCurrentStep() == "04timeTrial" then
      -- During time trial: keep starting area, switch to open track prefab.
      gameplay_tutorial_setup.setActivePrefabs({ startingArea = true, tutorialTrackClosed = false, tutorialTrackOpen = true })
    end
  end, 1)
end

function M.onUpdate(dtReal, dtSim, dtRaw)
  if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
  if phase ~= PHASE_SIMPLE_MISSION then return end
  if not activeTutorialRace then
    local fgId = gameplay_missions_missionManager.getForegroundMissionId()
    if fgId == TUTORIAL_MISSION_ID and currentRouteKey ~= "finish" then
      core_groundMarkers.setPath(tutorialFinishSpot and tutorialFinishSpot.pos or nil)
      currentRouteKey = "finish"
    end
    return
  end
  setRouteFromRace(activeTutorialRace)
end

function M.onAnyMissionChanged(state, mission)
  if not mission or career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then
    return
  end
  if state == "started" and mission.id == TUTORIAL_MISSION_ID then
    oobRestartInProgress = false
    activeTutorialRace = mission.race
    currentRouteKey = nil
  elseif state == "stopped" then
    if mission.id == TUTORIAL_MISSION_ID then
      clearRouteToTutorialFinish()
      activeTutorialRace = nil
      currentRouteKey = nil
      -- OOB timeout restart triggers a stop/start cycle; do not treat it as tutorial completion.
      if phase == PHASE_SIMPLE_MISSION and not oobRestartInProgress then
        pendingPostSimpleAssessmentPopup = true
        phase = PHASE_WAIT_CHOICE_POPUP
      end
    elseif mission.id == TUTORIAL_ADVANCED_MISSION_ID then
      deactivateTutorialVehicle()
      career_modules_tutorial.playedAdvancedTimeTrial = true
      career_modules_tutorial.advanceToNextStep()
    end
  end
end

function M.onCareerTutorialOutOfBoundsTimedOut()
  if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
  local fgId = gameplay_missions_missionManager.getForegroundMissionId()
  if fgId ~= TUTORIAL_MISSION_ID and fgId ~= TUTORIAL_ADVANCED_MISSION_ID then return end

  oobRestartInProgress = true
  ui_message(_tr("ui.career.tutorial.task.step04.message.leftEvaluationZone"))
  gameplay_tutorial_setup.showOutOfBoundsWarning()

  -- Mirror the mission details "Restart" action: run restart recovery action, then restart mission.
  core_recoveryPrompt.buttonPressed("restartMission", {type = "none"})
end

function M.onRaceStarted(data)
  if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
  local race = data and data.race or nil
  if not isTutorialSimpleRace(race) then return end
  activeTutorialRace = race
  currentRouteKey = nil
  oobRestartInProgress = false
  setRouteFromRace(race)
end

function M.onRacePathnodeReached(data)
  if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
  local race = data and data.race or nil
  if not isTutorialSimpleRace(race) then return end
  activeTutorialRace = race
  setRouteFromRace(race)
end

function M.onScreenFadeState(state)
  -- Mission stop fades back into gameplay; wait for fade-from-black completion before opening handoff popup.
  if state ~= 3 or phase ~= PHASE_WAIT_CHOICE_POPUP then return end
  -- Mission stop restores the generic freeroam layout; switch back to the career layout for the tutorial handoff popup.
  core_gamestate.setGameState("career", "career", nil)
  if pendingPostSimpleAssessmentPopup then
    phase = PHASE_WAIT_POST_SIMPLE_POPUP_CLOSE
    career_modules_tutorialPopups.introPopup(POST_SIMPLE_TRIAL_POPUP_ID, true)
    return
  end
  phase = PHASE_WAIT_CHOICE_SELECTION
  extensions.ui_popup.openOptionalChallengeSelectionPopup()
end

-- Called from OptionalChallengeSelect.vue when user confirms (lua.extensions.hook)
function M.onCareerTutorialAdvancedOrDragSelection(choice)
  if career_modules_tutorial.getCurrentStep() ~= "04timeTrial" then return end
  if phase ~= PHASE_WAIT_CHOICE_SELECTION then return end
  if choice == "advancedTimeTrial" then
    phase = PHASE_ADVANCED_MISSION
    local mission = gameplay_missions_missions.getMissionById(TUTORIAL_ADVANCED_MISSION_ID)
    if mission then
      gameplay_missions_missionManager.start(mission, {})
    else
      log('E', logTag, 'Mission not found: ' .. TUTORIAL_ADVANCED_MISSION_ID)
      deactivateTutorialVehicle()
      career_modules_tutorial.advanceToNextStep()
    end
  else
    deactivateTutorialVehicle()
    career_modules_tutorial.advanceToNextStep()
  end
end

function M.onCareerTutorialLeftBounds()
  gameplay_tutorial_setup.runCurrentStepOutOfBoundsReset()
end

function M.cleanup()
  gameplay_tutorial_setup.setOutOfBoundsResetHandler(nil)
  phase = PHASE_WAIT_INTRO
  oobRestartInProgress = false
  pendingPostSimpleAssessmentPopup = false
  clearRouteToTutorialFinish()
  activeTutorialRace = nil
  currentRouteKey = nil
  local fgId = gameplay_missions_missionManager.getForegroundMissionId()
  if fgId == TUTORIAL_MISSION_ID or fgId == TUTORIAL_ADVANCED_MISSION_ID then
    local mission = gameplay_missions_missions.getMissionById(fgId)
    if mission then
      gameplay_missions_missionManager.stop(mission, {ignoreFade = true})
    end
  end
end

-- Skip step 4
function M.onDebugMenu(im)
  im.Text("Step 4 - Time Trial")
  im.Separator()
  if im.Button("Skip Step 4") then
    local fgId = gameplay_missions_missionManager.getForegroundMissionId()
    if fgId == TUTORIAL_MISSION_ID or fgId == TUTORIAL_ADVANCED_MISSION_ID then
      local mission = gameplay_missions_missions.getMissionById(fgId)
      if mission then
        gameplay_missions_missionManager.stop(mission, {ignoreFade = true})
      end
    end
    deactivateTutorialVehicle()
    career_modules_tutorial.advanceToNextStep()
  end
end

return M
