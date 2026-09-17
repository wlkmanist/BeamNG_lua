-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local function getStat(name)
  return gameplay_statistic.metricGet(name) and gameplay_statistic.metricGet(name).value or 0
end

local function setNewMaxStat(name, value)
  local stat = getStat(name)
  if value > stat then gameplay_statistic.metricSet(name, value) end
end

local function onDriftCompleted(data)
  if not data.chainDriftData then return end

  gameplay_statistic.metricAdd("drift/rightDrifts", data.chainDriftData.rightDrifts)
  gameplay_statistic.metricAdd("drift/leftDrifts", data.chainDriftData.leftDrifts)

  setNewMaxStat("drift/maxDriftDistance.length", data.chainDriftData.totalDriftDistance)
  setNewMaxStat("drift/maxDriftTime.time", data.chainDriftData.totalDriftTime)
  setNewMaxStat("drift/maxChainedDrifts", data.chainDriftData.chainedDrifts)
end

local function onDriftCompletedScored(data)
  gameplay_statistic.metricAdd("drift/totalScore", data.addedScore)
  setNewMaxStat("drift/maxDriftScore", data.addedScore)
  if data.addedScore >= 20000 then
    gameplay_achievement.unlockAchievement("DRIFT_SINGLE")
  end
  local totalScore = gameplay_statistic.metricGet("drift/totalScore", false)
  if totalScore and totalScore.value >= 1000000 then
    gameplay_achievement.unlockAchievement("DRIFT_TOTAL")
  end
end

local function onDriftSpinout()
  gameplay_statistic.metricAdd("drift/spinOuts", 1)
end

local function onDriftCrash()
  gameplay_statistic.metricAdd("drift/crashes", 1)
end

M.onDriftCrash = onDriftCrash
M.onDriftCompleted = onDriftCompleted
M.onDriftCompletedScored = onDriftCompletedScored
M.onDriftSpinout = onDriftSpinout

return M