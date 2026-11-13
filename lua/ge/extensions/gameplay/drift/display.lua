-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"gameplay_drift_general", "gameplay_drift_drift", "gameplay_drift_scoring", "ui_apps_genericMissionData", "ui_appContainers"}
local im = ui_imgui
local contextTranslate = core_locales.contextTranslate
local driftDebugInfo = {
  default = false,
  canBeChanged = true
}

local flashTime = 1.5
local msgData = {}

local wrongWayFlag = false
local outOfBoundsFlag = false
local creepSmoothers = {} -- per-vehId

local driftDebugUILayout = false
local driftOwnsGameState = false
local activeDriftApps = {}
local isUnloaded = false

local guiData = { players = {} }
local playerDataPool = {} -- playerKey -> reused table, the stream is pushed every frame

-- The confirmed-score presentation is a phase machine owned here and published on the stream,
-- so the UI never has to reconstruct it from an event that can race the stream update.
local scorePhaseDurations = {
  hold = 0.9,    -- confirmed score sits still
  dwindle = 0.6,    -- counts down to zero
  linger = 0.5,     -- rests at zero before clearing
}
local scorePhaseOrder = {hold = "dwindle", dwindle = "linger", linger = "idle"}
local scorePresentations = {} -- vehId -> {phase, score, timer, id}
local nextConfirmedScoreId = 1

local function getCreepSmoother(vehId)
  if not creepSmoothers[vehId] then
    creepSmoothers[vehId] = newTemporalSmoothingNonLinear(50, 10, 0)
  end
  return creepSmoothers[vehId]
end

local function getScorePresentation(vehId)
  local presentation = scorePresentations[vehId]
  if not presentation then
    presentation = {phase = "idle", score = 0, timer = 0, id = 0}
    scorePresentations[vehId] = presentation
  end
  return presentation
end

local function getScorePresentationDuration()
  return scorePhaseDurations.hold + scorePhaseDurations.dwindle + scorePhaseDurations.linger
end

local function startScorePresentation(vehId, score)
  if not vehId then return end
  local presentation = getScorePresentation(vehId)
  presentation.phase = "hold"
  presentation.score = score or 0
  presentation.timer = 0
  presentation.id = nextConfirmedScoreId
  nextConfirmedScoreId = nextConfirmedScoreId + 1
end

local function getIsScorePresentationActive(vehId)
  local presentation = scorePresentations[vehId]
  return presentation ~= nil and presentation.phase ~= "idle"
end

local function clearScorePresentation(vehId)
  local presentation = scorePresentations[vehId]
  if not presentation then return end
  presentation.phase = "idle"
  presentation.score = 0
  presentation.timer = 0
end

-- returns phase and 0..1 progress within it
local function advanceScorePresentation(vehId, dtReal)
  local presentation = getScorePresentation(vehId)
  if presentation.phase == "idle" then return "idle", 0, 0, presentation.id end

  presentation.timer = presentation.timer + dtReal

  local duration = scorePhaseDurations[presentation.phase]
  while duration and presentation.timer >= duration do
    presentation.timer = presentation.timer - duration
    presentation.phase = scorePhaseOrder[presentation.phase] or "idle"
    if presentation.phase == "idle" then
      clearScorePresentation(vehId)
      return "idle", 0, 0, presentation.id
    end
    duration = scorePhaseDurations[presentation.phase]
  end

  local progress = duration and duration > 0 and (presentation.timer / duration) or 0
  return presentation.phase, math.min(1, progress), presentation.score, presentation.id
end

local function getPlayerData(playerKey)
  if not playerDataPool[playerKey] then
    playerDataPool[playerKey] = {}
  end
  return playerDataPool[playerKey]
end

local function resolvePlayerId(vehId)
  return gameplay_drift_drift.getPlayerIdForVehicle(vehId)
end

local function rtMessage(msg)
  msgData.msg = msg
  msgData.context = "drift"
  guihooks.trigger('ScenarioRealtimeDisplay', msgData)
end

local function clearRt()
  table.clear(msgData)
  msgData.msg = ""
  guihooks.trigger('ScenarioRealtimeDisplay', msgData)
end

local function flashMessage(msg, duration)
  if gameplay_drift_general.getContext() == "inFreeroam" then return end
  if msg == nil or msg == "" then return end
  duration = duration or flashTime
  ui_appContainers.showApp('topCenter', 'flashMessage')
  guihooks.trigger('TopCenterAppsFlashMessage', { msg = msg, ttl = duration, big = false })
end

-- the stream is rebuilt from authoritative state every frame in updateApps, so these
-- handlers only need to reset the smoother (which is state the score doesn't carry)
local function resetCreepSmoother(vehId)
  local smoother = creepSmoothers[vehId]
  if smoother then smoother:set(0) end
end

local function onDriftCompletedScored(data)
  local playerId = resolvePlayerId(data.vehId)
  resetCreepSmoother(data.vehId)
  startScorePresentation(data.vehId, data.addedScore)

  flashMessage(contextTranslate("missions.drift.general.addPoints", {points = data.addedScore}))
  guihooks.trigger("setDriftPersistentDriftScored", data.addedScore, data.combo, playerId)

  clearRt()
end

-- single table payload: guihooks.trigger drops nil arguments and compacts the rest,
-- so positional args with an optional one in the middle would shift the player id
local function triggerRealtimeFail(vehId, reason)
  guihooks.trigger("setDriftRealtimeFail", {reason = reason, playerId = resolvePlayerId(vehId)})
  resetCreepSmoother(vehId)
  clearScorePresentation(vehId) -- the fail message takes over the same display slot
  clearRt()
end

local function onDriftCrash(vehId)
  triggerRealtimeFail(vehId, _tr("missions.drift.display.crashed"))
end

local function onDriftSpinout(vehId)
  triggerRealtimeFail(vehId, _tr("missions.drift.display.spinout"))
end

local function onDonutDriftScored(score)
  flashMessage(contextTranslate("missions.drift.display.donutScored", {score = score}))
  guihooks.trigger("stuntZoneScored",{type = "donut", score = score})
end

local function onNearPoleScored(score)
  flashMessage(contextTranslate("missions.drift.display.nearPoleScored", {score = score}))
  guihooks.trigger("stuntZoneScored",{type = "nearPole", score = score})
end

local function onTightDriftScored(score)
  flashMessage(contextTranslate("missions.drift.display.driftThroughScored", {score = score}))
  guihooks.trigger("stuntZoneScored",{type = "tightDrift", score = score})
end

local function onHitPoleScored(score)
  flashMessage(contextTranslate("missions.drift.display.hitPoleScored", {score = score}))
  guihooks.trigger("stuntZoneScored",{type = "hitPole", score = score})
end

local function updateApps(dtReal)
  local scoreOptions = gameplay_drift_scoring.getScoreOptions()
  local driftOptions = gameplay_drift_drift.getDriftOptions()
  local maxAngle = driftOptions and driftOptions.maxAngle or 180

  guiData.context = gameplay_drift_general.getContext()
  table.clear(guiData.players)

  local trackedVehicles = gameplay_drift_drift.getTrackedVehicles()
  for vehId, state in pairs(trackedVehicles) do
    -- string keys so the stream always serializes as an object, whatever the player indices are
    local playerKey = tostring(state.playerId or 0)
    local score = gameplay_drift_scoring.getScore(vehId)
    local smoother = getCreepSmoother(vehId)
    local pData = getPlayerData(playerKey)

    pData.permanentScore = score.score
    pData.potentialScore = score.potentialScore
    pData.realtimePerformanceFactor = gameplay_drift_scoring.getSteppedDriftPerformanceFactor(vehId)
    pData.realtimeCachedScoreFloored = 0
    pData.realtimeCombo = 0
    pData.realtimeRemainingComboTime = 0
    pData.realtimeCreep = 0
    pData.realtimeAngle = 0
    pData.realtimeAirSpeed = 0

    pData.scorePhase, pData.scorePhaseProgress, pData.confirmedScore, pData.confirmedScoreId =
      advanceScorePresentation(vehId, dtReal)

    if score.cachedScore > 0 then
      pData.realtimeCachedScoreFloored = math.floor(score.cachedScore)
      pData.realtimeCombo = score.combo
      pData.realtimeRemainingComboTime = gameplay_drift_drift.getCurrDriftCompletedTime(vehId)
      local creepPercent = score.comboCreepup / 100
      if score.combo >= scoreOptions.comboOptions.comboSoftCap then
        creepPercent = 1
      end
      pData.realtimeCreep = smoother:get(creepPercent, dtReal)
    else
      smoother:get(0, dtReal) -- keep the smoother decaying while not drifting
    end

    local airspeed = gameplay_drift_drift.getAirSpeed(vehId) or 0
    local angle = gameplay_drift_drift.getCurrDegAngleSigned(vehId) or 0

    if math.abs(angle) < maxAngle and gameplay_drift_drift.getIsOverSteering(vehId) and gameplay_drift_drift.getIsOverMinSpeedForDrift(vehId) and not gameplay_drift_drift.getIsInTheAir(vehId) and not gameplay_walk.isWalking() then
      pData.realtimeAngle = round(angle)
    end

    if gameplay_drift_drift.getIsDrifting(vehId) then
      if angle == math.huge or angle == -math.huge or airspeed < 2 then airspeed = 0 end
      pData.realtimeAirSpeed = airspeed
    end

    guiData.players[playerKey] = pData
  end

  guihooks.queueStream("drift", guiData)
end

local function displayRemainingDist()
  if gameplay_drift_destination and not gameplay_drift_destination.getDisableWrongWayAndDist() then
    local remainingDist = gameplay_drift_destination.getRemainingDist() or 0
    local data = {
      title = "missions.missions.general.distRemaining",
      txt = string.format("%d m", remainingDist),
      meters = remainingDist,
      category = "drift",
      style = "text",
      order = 10,
    }

    ui_apps_genericMissionData.setData(data)
  end
end

local function displayWrongWay()
  if not gameplay_drift_destination then return end

  if gameplay_drift_freeroam_driftSpots and gameplay_drift_freeroam_driftSpots.getIsInFreeroamChallenge() then
    return
  end

  if gameplay_drift_destination.getGoingWrongWay() and not outOfBoundsFlag then
    rtMessage(_tr("missions.drift.general.wrongWayFirst"))
    wrongWayFlag = true
  elseif wrongWayFlag then
    clearRt()
    wrongWayFlag = false
  end
end

local function displayOutOfBounds()
  if not gameplay_drift_bounds then return end

  local isInConcludingPhase = gameplay_drift_freeroam_driftSpots and gameplay_drift_freeroam_driftSpots.getIsInTheConcludingPhase()

  if gameplay_drift_bounds.getIsOutOfBounds() and not isInConcludingPhase then
    rtMessage(_tr("missions.crawl.general.outOfBounds"))
    outOfBoundsFlag = true
  elseif outOfBoundsFlag then
    clearRt()
    outOfBoundsFlag = false
  end
end

local function showDriftApp(container, app)
  if ui_appContainers.getAppVisibility(container, app) then return end
  activeDriftApps[container .. ":" .. app] = {container, app}
  ui_appContainers.showApp(container, app)
end

local function hideDriftApp(container, app)
  activeDriftApps[container .. ":" .. app] = nil
  ui_appContainers.hideApp(container, app)
end

local function setDriftScoreboardUI(value)
  if value then
    showDriftApp('topLeft', 'scoreboard')
  else
    hideDriftApp('topLeft', 'scoreboard')
  end
end

local function setDriftTasksUI(value)
  if value then
    showDriftApp('topLeft', 'tasks')
  else
    hideDriftApp('topLeft', 'tasks')
  end
end

local function setDriftScoresUI(value)
  if value then
    showDriftApp('topLeft', 'driftScores')
  else
    hideDriftApp('topLeft', 'driftScores')
  end
end

local function enableDriftMissionUI()
  core_gamestate.setGameState('freeroam', 'driftMission', 'freeroam')
  driftOwnsGameState = true
  guihooks.trigger('ClearTasklist')

  setDriftScoreboardUI(false)
  setDriftTasksUI(true)
  setDriftScoresUI(false)

  driftDebugUILayout = true
end

local function disableDriftUI()
  for _, entry in pairs(activeDriftApps) do
    ui_appContainers.hideApp(entry[1], entry[2])
  end
  table.clear(activeDriftApps)
  ui_appContainers.hideApp('topCenter', 'flashMessage')

  if driftOwnsGameState then
    local gs = core_gamestate.getGameState()
    if career_career and career_career.isActive() then
      core_gamestate.setGameState('career','career', nil)
    else
      if gs.state ~= 'freeroam' or gs.appLayout ~= 'freeroam' then
        core_gamestate.setGameState('freeroam','freeroam', 'freeroam')
      end
    end
    driftOwnsGameState = false
  end

  driftDebugUILayout = false
end

local function imguiDebug()
  if gameplay_drift_general.getExtensionDebug("gameplay_drift_display") then
    if im.Begin("Drift display") then
      if im.Button("Toggle drift ui layout") then
        if(driftDebugUILayout) then
          disableDriftUI()
        else
          enableDriftMissionUI()
        end
      end
    end
    im.End()
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  -- the hook cache rebuild can still call us in the frame we got unloaded, which would re-push a stale drift stream
  if isUnloaded then return end
  imguiDebug()
  updateApps(dtReal)

  displayWrongWay()
  displayOutOfBounds()
  displayRemainingDist()
end

local function onDriftSpotCompleted(data)
  flashMessage(contextTranslate(data.newRecord and "missions.drift.display.newRecord" or "missions.drift.display.driftZoneFinished", {score = data.score}))
end

local function onDriftQuickMessageDisplay(data)
  local playerId = data.vehId and resolvePlayerId(data.vehId) or 0
  guihooks.trigger('displayDriftScoreModifier', data.msg, playerId)
end

local function onDriftPlVehReset(vehId)
  resetCreepSmoother(vehId)
  clearScorePresentation(vehId)
  clearRt()
end

local function onDriftCachedScoreReset(vehId)
  clearRt()
end

local function onExtensionUnloaded()
  isUnloaded = true
  disableDriftUI()
  clearRt()
  ui_apps_genericMissionData.clearData()
  table.clear(creepSmoothers)
  table.clear(scorePresentations)
  table.clear(playerDataPool)
  table.clear(guiData.players)
  guihooks.queueStream("drift", guiData)
end

local function onVehicleDestroyed(vehId)
  creepSmoothers[vehId] = nil
  scorePresentations[vehId] = nil
end

local function onFreeroamDriftZoneNewHighscore()
  flashMessage(_tr("missions.drift.display.newHighscore"))
end

local function onDriftSpotFailed(data)
  flashMessage(_tr(data.reason.msg), 2)
end

local function onDriftScoreWrappedUp(score, vehId)
  resetCreepSmoother(vehId)
  startScorePresentation(vehId, score)
  flashMessage(contextTranslate("missions.drift.general.extraPointDrift", {score = math.floor(score)}))
end

local function onNewDriftTierReached(tierData)
  flashMessage(string.format("%s", tierData.name))
end


local function onSerialize()
  return {
    driftDebugUILayout = driftDebugUILayout
  }
end

local function onDeserialized(data)
  driftDebugUILayout = data.driftDebugUILayout
end

local function onDriftDebugChanged(value)
  if not value then
    disableDriftUI()
  end
end

local function onDriftContextChanged(context)
  if context == "inChallenge" then
    enableDriftMissionUI()
  elseif context == "inFreeroamChallenge" then
    if gameplay_drift_general.getMultiplayerEnabled() then
      setDriftScoreboardUI(true)
    else
      setDriftScoresUI(true)
    end
    setDriftTasksUI(true)
  elseif context == "inFreeroamCruising" then
    setDriftScoresUI(true)
  elseif context == "inFreeroam" then
    disableDriftUI()
  end
end

local function onExtensionLoaded()
  local ctx = gameplay_drift_general.getContext()
  if ctx then
    onDriftContextChanged(ctx)
  end
end

local function reset()
  table.clear(creepSmoothers)
  table.clear(scorePresentations)
  table.clear(playerDataPool)
  ui_apps_genericMissionData.clearData()
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

M.reset = reset

M.onUpdate = onUpdate
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onDriftDebugChanged = onDriftDebugChanged

M.onDriftPlVehReset = onDriftPlVehReset
M.onDriftCompletedScored = onDriftCompletedScored
M.onDriftCrash = onDriftCrash
M.onDriftSpinout = onDriftSpinout
M.onDriftQuickMessageDisplay = onDriftQuickMessageDisplay
M.onDriftSpotCompleted = onDriftSpotCompleted
M.onDriftScoreWrappedUp = onDriftScoreWrappedUp
M.onNewDriftTierReached = onNewDriftTierReached

M.onDonutDriftScored = onDonutDriftScored
M.onTightDriftScored = onTightDriftScored
M.onHitPoleScored = onHitPoleScored
M.onNearPoleScored = onNearPoleScored

M.onExtensionLoaded = onExtensionLoaded
M.onDriftContextChanged = onDriftContextChanged

M.onDriftCachedScoreReset = onDriftCachedScoreReset
M.onExtensionUnloaded = onExtensionUnloaded
M.onVehicleDestroyed = onVehicleDestroyed
M.onFreeroamDriftZoneNewHighscore = onFreeroamDriftZoneNewHighscore
M.onDriftSpotFailed = onDriftSpotFailed

M.getDriftDebugInfo = getDriftDebugInfo
M.getIsScorePresentationActive = getIsScorePresentationActive
M.getScorePresentationDuration = getScorePresentationDuration
return M
