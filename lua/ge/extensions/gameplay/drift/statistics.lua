local M = {}

local function getStat(name)
  return gameplay_statistic.metricGet(name) and gameplay_statistic.metricGet(name).value or 0
end

local function setNewMaxStat(name, value)
  local stat = getStat(name)
  if value > stat then gameplay_statistic.metricSet(name, value) end
end

local function onDriftCompleted(data)
  gameplay_statistic.metricAdd("drift/rightDrifts", data.chainDriftData.rightDrifts)
  gameplay_statistic.metricAdd("drift/leftDrifts", data.chainDriftData.leftDrifts)

  setNewMaxStat("drift/maxDriftDistance.length", data.chainDriftData.totalDriftDistance)
  setNewMaxStat("drift/maxDriftTime.time", data.chainDriftData.totalDriftTime)
  setNewMaxStat("drift/maxChainedDrifts", data.chainDriftData.chainedDrifts)
end

local function onDriftCompletedScored(addedScore)
  gameplay_statistic.metricAdd("drift/totalScore", addedScore)
  setNewMaxStat("drift/maxDriftScore", addedScore)
end

local function onDriftSpinout()
  gameplay_statistic.metricAdd("drift/spinOuts", 1)
end

local function onDriftCrash(hasCachedScore)
  if hasCachedScore then
    gameplay_statistic.metricAdd("drift/crashes", 1)
  end
end

M.onDriftCrash = onDriftCrash
M.onDriftCompleted = onDriftCompleted
M.onDriftCompletedScored = onDriftCompletedScored
M.onDriftSpinout = onDriftSpinout

return M