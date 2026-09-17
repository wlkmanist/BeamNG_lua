-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"gameplay_drift_general"}

local driftDebugInfo = {
  default = false,
  canBeChanged = false
}

local scoreCopy
local previousPerformanceFactor = 0
local hasDriftSpotStarted = false
local scoreboardHandle = nil

local function onDriftScoreChanged(data)
  if scoreboardHandle and gameplay_drift_general.getContext() == "inFreeroamChallenge" then
    scoreCopy = gameplay_drift_scoring.getScore()
    scoreboardHandle:pushSelfScoreUpdate({potentialScore = scoreCopy.potentialScore, score = scoreCopy.score, driftLevel = gameplay_drift_scoring.getDriftPerformanceFactor()})
  end
end

local function onDriftSpotStarted(data)
  if multiplayer_gameplayScoreboard then
    hasDriftSpotStarted = true
    scoreboardHandle = multiplayer_gameplayScoreboard.startNewScoreboard({entries = {{key = "potentialScore", name = "Potential Score", order = 1, type = "points"}, {key = "driftLevel", name = "", order = 2, type ="verticalBar"}, {key = "score", name = "Score", order = 2, type = "points"}}, orderBy = {key="score", direction="desc"}}, data.lineId)
  end
end

local function functionDriftSpotEnded()
  if scoreboardHandle then
    scoreboardHandle:pushSelfScoreUpdate({driftLevel = 0})
  end
  hasDriftSpotStarted = false
end

local function onDriftSpotFinishLineCrossed()
  if scoreboardHandle then
    functionDriftSpotEnded()
    scoreboardHandle:pushSelfStatus("finishLine")
  end
end

local function onDriftSpotFailed()
  if scoreboardHandle then
    functionDriftSpotEnded()
    scoreboardHandle:pushSelfStatus("disqualified")
  end
end

local function onDriftCrash()
  if scoreboardHandle and gameplay_drift_general.getContext() == "inFreeroamChallenge" then
    scoreboardHandle:pulseSelfColor("red")
  end
end

local function getDriftDebugInfo()
  return driftDebugInfo
end

local function checkIfSendPerformanceFactorUpdate()
  if hasDriftSpotStarted and scoreboardHandle then
    if previousPerformanceFactor ~= gameplay_drift_scoring.getDriftPerformanceFactor() then
      scoreboardHandle:pushSelfScoreUpdate({driftLevel = gameplay_drift_scoring.getDriftPerformanceFactor()})
    end
    previousPerformanceFactor = gameplay_drift_scoring.getDriftPerformanceFactor()
  end
end

local function onUpdate()
  checkIfSendPerformanceFactorUpdate()
end

M.onUpdate = onUpdate
M.onDriftSpotStarted = onDriftSpotStarted
M.onDriftSpotFinishLineCrossed = onDriftSpotFinishLineCrossed
M.onDriftSpotFailed = onDriftSpotFailed
M.onDriftScoreChanged = onDriftScoreChanged
M.onDriftCrash = onDriftCrash

M.getDriftDebugInfo = getDriftDebugInfo



return M
