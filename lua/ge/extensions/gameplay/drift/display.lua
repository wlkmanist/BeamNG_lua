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
local score

local wrongWayFlag = false
local outOfBoundsFlag = false
local creepSmoother = newTemporalSmoothingNonLinear(50,10, 0)

local driftDebugUILayout = false

local guiData = {}


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
  if msg == nil or msg == "" then
    return
  end

  duration = duration or flashTime

  ui_appContainers.showApp('topCenter', 'flashMessage')
  guihooks.trigger('TopCenterAppsFlashMessage', { msg = msg, ttl = duration, big = false })
end

local function onDriftCompletedScored(data)
  guiData.realtimeRemainingComboTime = 0
  guiData.realtimeCreep = 0
  creepSmoother:set(0)

  flashMessage(contextTranslate("missions.drift.general.addPoints", {points = data.addedScore}))
  guihooks.trigger("setDriftPersistentDriftScored", data.addedScore, data.combo)

  clearRt()
end

local function onDriftCrash()
  guihooks.trigger("setDriftRealtimeFail", _tr("missions.drift.display.crashed"))
  guiData.realtimeRemainingComboTime = 0
  guiData.realtimeCreep = 0
  guihooks.queueStream("drift", guiData)

  creepSmoother:set(0)
  clearRt()
end

local function onDriftSpinout()
  guihooks.trigger("setDriftRealtimeFail", _tr("missions.drift.display.spinout"))
  guiData.realtimeRemainingComboTime = 0
  guiData.realtimeCreep = 0
  guihooks.queueStream("drift", guiData)


  creepSmoother:set(0)
  clearRt()
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
  score = gameplay_drift_scoring.getScore()
  local scoreOptions = gameplay_drift_scoring.getScoreOptions()
  guiData.context = gameplay_drift_general.getContext()

  --guihooks.trigger("setDriftPermanentAndPotentialScore", score.score, score.potentialScore)
  guiData.permanentScore = score.score
  guiData.potentialScore = score.potentialScore

  if score.cachedScore > 0 then
    --guihooks.trigger("setDriftRealtimeScore", math.floor(score.cachedScore), score.combo)
    guiData.realtimeCachedScoreFloored = math.floor(score.cachedScore)
    guiData.realtimeCombo = score.combo
    --guihooks.trigger("setDriftRemainingComboTime", gameplay_drift_drift.getCurrDriftCompletedTime())
    guiData.realtimeRemainingComboTime = gameplay_drift_drift.getCurrDriftCompletedTime()
    local creepPercent = score.comboCreepup / 100
    if score.combo >= scoreOptions.comboOptions.comboSoftCap then
      creepPercent = 1
    end

    --guihooks.trigger("setDriftRealtimeCreep", creepSmoother:get(creepPercent, dtReal))
    guiData.realtimeCreep = creepSmoother:get(creepPercent, dtReal)
  end
  --guihooks.trigger("setDriftPerformanceFactor", gameplay_drift_scoring.getSteppedDriftPerformanceFactor())
  guiData.realtimePerformanceFactor = gameplay_drift_scoring.getSteppedDriftPerformanceFactor()

  local airspeed =  gameplay_drift_drift.getAirSpeed() or 0
  local angle = gameplay_drift_drift.getCurrDegAngleSigned() or 0
  local isDrifting = gameplay_drift_drift.getIsDrifting()


  if math.abs(angle) < gameplay_drift_drift.getDriftOptions().maxAngle and gameplay_drift_drift.getIsOverSteering() and gameplay_drift_drift.getIsOverMinSpeedForDrift() and not gameplay_drift_drift.getIsInTheAir() and not gameplay_walk.isWalking() then
    --guihooks.trigger("setDriftRealtimeAngle", angle )
    guiData.realtimeAngle = round(angle)
  else
    --guihooks.trigger("setDriftRealtimeAngle", 0)
    guiData.realtimeAngle = 0
  end

  if isDrifting then
    if angle == math.huge or angle == -math.huge or airspeed < 2 then angle = 0 end
    --guihooks.trigger("setDriftRealtimeAirSpeed",airspeed)
    guiData.realtimeAirSpeed = airspeed
  else
    --guihooks.trigger("setDriftRealtimeAirSpeed", 0)
    guiData.realtimeAirSpeed = 0
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

-- "Out of bounds" message has higher priority than the "Wrong way" message
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

local function setDriftAngleUIContainer(value)
  if value then
    ui_appContainers.showApp('topCenter', 'drift')
  else
    ui_appContainers.hideApp('topCenter', 'drift')
  end
end

local function setDriftScoreboardUI(value)
  if value then
    ui_appContainers.showApp('topLeft', 'scoreboard')
  else
    ui_appContainers.hideApp('topLeft', 'scoreboard')
  end
end

local function setDriftTasksUI(value)
  if value then
    ui_appContainers.showApp('topLeft', 'tasks')
  else
    ui_appContainers.hideApp('topLeft', 'tasks')
  end
end

local function setDriftScoresUI(value)
  if value then
    ui_appContainers.showApp('topLeft', 'driftScores')
  else
    ui_appContainers.hideApp('topLeft', 'driftScores')
  end
end

local function enableDriftMissionUI()
  core_gamestate.setGameState('freeroam', 'driftMission', 'freeroam')
  guihooks.trigger('ClearTasklist')

  setDriftAngleUIContainer(true)
  setDriftScoreboardUI(false)
  setDriftTasksUI(true)
  setDriftScoresUI(false)

  driftDebugUILayout = true
end

local function disableDriftUI()
  setDriftAngleUIContainer(false)
  setDriftScoreboardUI(false)
  setDriftTasksUI(false)
  setDriftScoresUI(false)
  ui_appContainers.hideApp('topCenter', 'flashMessage')
  local gs = core_gamestate.getGameState()
  if gs.state ~= 'freeroam' or gs.appLayout ~= 'freeroam' then
    core_gamestate.setGameState('freeroam','freeroam', 'freeroam')
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
  imguiDebug()
  updateApps(dtReal)

  score = gameplay_drift_scoring.getScore()

  displayWrongWay()
  displayOutOfBounds()
  displayRemainingDist()
end

local function onDriftSpotCompleted(data)
  flashMessage(contextTranslate(data.newRecord and "missions.drift.display.newRecord" or "missions.drift.display.driftZoneFinished", {score = data.score}))
end

local function onDriftQuickMessageDisplay(data)
  guihooks.trigger('displayDriftScoreModifier', data.msg )
end

local function onDriftPlVehReset()
  guiData.realtimeCachedScoreFloored = 0
  guiData.realtimeCombo = 0
  guiData.realtimeRemainingComboTime = 0
  guiData.realtimeCreep = 0
  guihooks.queueStream("drift", guiData)
  clearRt()
end

local function onDriftCachedScoreReset()
  guiData.realtimeCachedScoreFloored = 0
  guiData.realtimeCombo = 0
  guihooks.queueStream("drift", guiData)
  clearRt()
end

local function onExtensionUnloaded()
  clearRt()
end

local function onFreeroamDriftZoneNewHighscore()
  flashMessage(_tr("missions.drift.display.newHighscore"))
end

local function onDriftSpotFailed(data)
  flashMessage(_tr(data.reason.msg), 2)
end

local function onDriftScoreWrappedUp(score)
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
    setDriftAngleUIContainer(true)
  elseif context == "inFreeroamCruising" then
    setDriftAngleUIContainer(true)
    setDriftScoresUI(true)
  elseif context == "inFreeroam" then
    disableDriftUI()
  end
end

local function reset()
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

M.onDriftContextChanged = onDriftContextChanged

M.onDriftCachedScoreReset = onDriftCachedScoreReset
M.onExtensionUnloaded = onExtensionUnloaded
M.onFreeroamDriftZoneNewHighscore = onFreeroamDriftZoneNewHighscore
M.onDriftSpotFailed = onDriftSpotFailed

M.getDriftDebugInfo = getDriftDebugInfo
return M