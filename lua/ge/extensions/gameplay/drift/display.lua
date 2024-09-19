local M = {}

M.dependencies = {"gameplay_drift_general"}

local flashTime = 1.5
local driftContext
local msgData = {}
local score

local function rtMessage(msg)
  if driftContext ~= "inChallenge" then return end

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
  if driftContext ~= "inChallenge" then return end
  duration = duration or flashTime

  guihooks.trigger('ScenarioFlashMessage', {{msg, flashTime, 0, false}} )
end

local function onDriftCompletedScored(addedScore, cachedScore, combo)
  flashMessage(string.format("+ %i points", addedScore))
  clearRt()
end

local function onDriftCompleted(chainDriftData)
end

local function onDriftCrash(hasCachedScore)
  if hasCachedScore then
    flashMessage("Drift failed : crashed!")
    clearRt()
  end
end

local function onDriftSpinout()
  flashMessage("Drift failed : spun out!")
  clearRt()
end

local function onDonutDriftScored(score)
  flashMessage(string.format("Donut! + %i points", score))
end

local function onNearPoleScored(score)
  flashMessage(string.format("Near pole drift! + %i points", score))
end

local function onTightDriftScored(score)
  flashMessage(string.format("Drift through! + %i points", score))
end

local function onHitPoleScored(score)
  flashMessage(string.format("Pole hit! + %i points", score))
end


local function onNearStuntZoneFirst(stuntZone)
  local id ="missions.drift.general." .. stuntZone.data.zoneData.type .. "Help"
  flashMessage(translateLanguage(id, id))
end


local function onUpdate()
  driftContext = gameplay_drift_general.getContext()
  score = gameplay_drift_scoring.getScore()
  if score.cachedScore > 0 then
    rtMessage(string.format("Drift : %i * %0.1f", score.cachedScore, score.combo))
  end
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

M.onDriftPlVehReset = onDriftPlVehReset
M.onUpdate = onUpdate
M.onDriftCompletedScored = onDriftCompletedScored
M.onDriftCompleted = onDriftCompleted
M.onDriftCrash = onDriftCrash
M.onDriftSpinout = onDriftSpinout

M.onDonutDriftScored = onDonutDriftScored
M.onTightDriftScored = onTightDriftScored
M.onHitPoleScored = onHitPoleScored
M.onNearPoleScored = onNearPoleScored

M.onNearStuntZoneFirst = onNearStuntZoneFirst

M.onDriftCachedScoreReset = onDriftCachedScoreReset
M.onExtensionUnloaded = onExtensionUnloaded
return M