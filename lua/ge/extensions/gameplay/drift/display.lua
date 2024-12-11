local M = {}

M.dependencies = {"gameplay_drift_general"}

local flashTime = 1.5
local msgData = {}
local score

local wrongWayFlag = false
local outOfBoundsFlag = false
local creepSmoother = newTemporalSmoothingNonLinear(50,10, 0)

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
  duration = duration or flashTime

  guihooks.trigger('DriftFlashMessage', {{msg, flashTime, 0, false}} )
end

local function onDriftCompletedScored(data)
  guihooks.trigger("setDriftRemainingComboTime", 0)
  guihooks.trigger("setDriftRealtimeCreep", 0)
  creepSmoother:set(0)

  flashMessage(string.format("+ %i points", data.addedScore))
  guihooks.trigger("setDriftPersistentDriftScored", data.addedScore, data.cachedScore, data.combo)
  clearRt()
end

local function onDriftCrash(hasCachedScore)
  if hasCachedScore then
    guihooks.trigger("setDriftRealtimeFail", "Crashed!")
    clearRt()
  end
end

local function onDriftSpinout()
  guihooks.trigger("setDriftRealtimeFail", "Spinout!")
  clearRt()
end

local function onDonutDriftScored(score)
  flashMessage(string.format("Donut! + %i points", score))
  guihooks.trigger("stuntZoneScored",{type = "donut", score = score})
end

local function onNearPoleScored(score)
  flashMessage(string.format("Near pole drift! + %i points", score))
  guihooks.trigger("stuntZoneScored",{type = "nearPole", score = score})
end

local function onTightDriftScored(score)
  flashMessage(string.format("Drift through! + %i points", score))
  guihooks.trigger("stuntZoneScored",{type = "tightDrift", score = score})
end

local function onHitPoleScored(score)
  flashMessage(string.format("Pole hit! + %i points", score))
  guihooks.trigger("stuntZoneScored",{type = "hitPole", score = score})
end


local function onNearStuntZoneFirst(stuntZone)
  local id ="missions.drift.general." .. stuntZone.data.zoneData.type .. "Help"
  flashMessage(translateLanguage(id, id))
end


local function updateApps(dtReal)

  score = gameplay_drift_scoring.getScore()
  local scoreOptions = gameplay_drift_scoring.getScoreOptions()


  if score.cachedScore > 0 then
    guihooks.trigger("setDriftRealtimeScore", math.floor(score.cachedScore), score.combo)
    guihooks.trigger("setDriftRemainingComboTime", gameplay_drift_drift.getCurrDriftCompletedTime())
    local creepPercent = score.comboCreepup / 100
    if score.combo >= scoreOptions.maxCombo then
      creepPercent = 1
    end

    guihooks.trigger("setDriftRealtimeCreep", creepSmoother:get(creepPercent, dtReal))
  end

  local airspeed =  gameplay_drift_drift.getAirSpeed() or 0
  local angle = gameplay_drift_drift.getCurrDegAngleSigned() or 0
  local isDrifting = gameplay_drift_drift.getIsDrifting()

  if isDrifting then
    if angle == math.huge or angle == -math.huge or airspeed < 2 then angle = 0 end
    guihooks.trigger("setDriftRealtimeAngle", angle )
    guihooks.trigger("setDriftRealtimeAirSpeed",airspeed)
  else
    guihooks.trigger("setDriftRealtimeAngle", 0)
    guihooks.trigger("setDriftRealtimeAirSpeed", 0)
  end



  local activeData = gameplay_drift_drift.getDriftActiveData()

  if activeData then
  else

  end

  --[[
  - dynamic app:
   - current cached score + multiplier
   - current score "velocity" (normalized)
   - current multiplier creep (creepup value normalized 0-1)
   - remaining time for drift (normalized 0-1)

   - variety score (normalized 0-1)

   - vehicle rotation (in degree)
   - left wall distance and right wall distance  (normalized 0 = off 1 = "best") (based of vehicle direction)
   - vehicle speed (airspeed)

   -drift is active (boolean)


   - static app
    - current total score (updated when changed) (score)
    - push new score to stack (score + multiplier)

  ]]


end

local function displayRemainingDist()
  if gameplay_drift_destination and not gameplay_drift_destination.getDisableWrongWayAndDist() then
    guihooks.trigger('SetGenericMissionData',{
      title = "missions.missions.general.distRemaining",
      txt = string.format("%d m", math.floor(gameplay_drift_destination.getRemainingDist() or 0)),
      category = "flowgraph",
      style = "text",
      order = 10,
    })
  end
end

local function displayWrongWay()
  if not gameplay_drift_destination then return end

  if gameplay_drift_freeroam_freeroam and gameplay_drift_freeroam_freeroam.getIsInFreeroamChallenge() then
    return
  end

  if gameplay_drift_destination.getGoingWrongWay() and not outOfBoundsFlag then
    rtMessage(translateLanguage("missions.drift.general.wrongWayFirst", "missions.drift.general.wrongWayFirst"))
    wrongWayFlag = true
  elseif wrongWayFlag then
    clearRt()
    wrongWayFlag = false
  end
end

-- "Out of bounds" message has higher priority than the "Wrong way" message
local function displayOutOfBounds()
  if not gameplay_drift_bounds then return end

  if gameplay_drift_freeroam_freeroam and gameplay_drift_freeroam_freeroam.getIsInFreeroamChallenge() then
    return
  end

  if gameplay_drift_bounds.getIsOutOfBounds() then
    rtMessage(translateLanguage("missions.crawl.general.outOfBounds", "missions.crawl.general.outOfBounds"))
    outOfBoundsFlag = true
  elseif outOfBoundsFlag then
    clearRt()
    outOfBoundsFlag = false
  end
end

local function displayScore()
  local context = gameplay_drift_general.getContext()
  if context == "inChallenge" or context == "inFreeroamChallenge" then
    guihooks.trigger('SetGenericMissionData',{
      title = "missions.missions.general.points",
      txt = score.score,
      category = "missions.missions.general.points",
      style = "text",
      order = 5,
    })
  end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  updateApps(dtReal)

  score = gameplay_drift_scoring.getScore()

  displayScore()
  displayWrongWay()
  displayOutOfBounds()
  displayRemainingDist()
end

local function onFreeroamChallengeCompleted(data)
  core_jobsystem.create(function(job)
    rtMessage(string.format(data.newRecord and "New record! Score: %i" or "Drift zone finished! Score: %i", data.score))
    job.sleep(data.duration)
    clearRt()
  end
  )
end

local function onDriftQuickMessage(data)
  flashMessage(data.msg, data.displayTime)
end

local function onDriftPlVehReset()
  clearRt()
end

local function onDriftCachedScoreReset()
  clearRt()
end

local function onExtensionUnloaded()
  clearRt()
end

local function onFreeroamDriftZoneNewHighscore()
  flashMessage("New Highscore!")
end

local function onFreeroamChallengeTerminated(reason, msgDisplayTime)
  core_jobsystem.create(function(job)
    rtMessage(reason.msg)
    job.sleep(msgDisplayTime)
    clearRt()
    end
  )
end

local function onDriftScoreWrappedUp(score)
  flashMessage(string.format("+ %i points for current drift", math.floor(score)))
end

local function reset()
  guihooks.trigger('SetGenericMissionDataResetAll')
end

M.reset = reset

M.onDriftPlVehReset = onDriftPlVehReset
M.onUpdate = onUpdate
M.onDriftCompletedScored = onDriftCompletedScored
M.onDriftCrash = onDriftCrash
M.onDriftSpinout = onDriftSpinout
M.onDriftQuickMessage = onDriftQuickMessage
M.onFreeroamChallengeCompleted = onFreeroamChallengeCompleted
M.onDriftScoreWrappedUp = onDriftScoreWrappedUp

M.onDonutDriftScored = onDonutDriftScored
M.onTightDriftScored = onTightDriftScored
M.onHitPoleScored = onHitPoleScored
M.onNearPoleScored = onNearPoleScored

M.onNearStuntZoneFirst = onNearStuntZoneFirst

M.onDriftCachedScoreReset = onDriftCachedScoreReset
M.onExtensionUnloaded = onExtensionUnloaded
M.onFreeroamDriftZoneNewHighscore = onFreeroamDriftZoneNewHighscore
M.onFreeroamChallengeTerminated = onFreeroamChallengeTerminated
return M