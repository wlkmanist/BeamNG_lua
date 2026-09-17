-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local scoreboardHandle = nil

local function onCrawlStarted(trail)
  ui_appContainers.showApp('topLeft', 'scoreboard')
  scoreboardHandle = multiplayer_gameplayScoreboard.startNewScoreboard(
    {entries = {{key = "penaltyScore", name = _tr("missions.crawl.progressLabels.pointsAchieved"), order = 1, type = "points"}}, orderBy = {key="penaltyScore", direction="asc"}},
    trail.id
  )
  scoreboardHandle:pushSelfScoreUpdate({penaltyScore = 0})
end

local function endCrawlFreeroam()
  ui_appContainers.hideApp('topLeft', 'scoreboard')
end

local function onCrawlPenaltyScoreChanged(eventData)
  if not scoreboardHandle or not eventData or eventData.penaltyScore == nil then
    return
  end

  local delta = eventData.penaltyScore - eventData.oldPenaltyScore

  if delta and delta > 0 then
    scoreboardHandle:pulseSelfColor("red")
  elseif delta and delta < 0 then
    scoreboardHandle:pulseSelfColor("green")
  end

  scoreboardHandle:pushSelfScoreUpdate({penaltyScore = eventData.penaltyScore})
end

local function onCrawlDisqualified()
  if scoreboardHandle then
    scoreboardHandle:pushSelfStatus("disqualified")
  end
  endCrawlFreeroam()
end

local function onCrawlResultsShown(eventData)
  if scoreboardHandle then
    if eventData and eventData.points ~= nil then
      scoreboardHandle:pushSelfScoreUpdate({penaltyScore = eventData.points})
    end
    scoreboardHandle:pushSelfStatus("finishLine")
  end
end

M.onCrawlDisqualified = onCrawlDisqualified
M.onCrawlStarted = onCrawlStarted
M.onCrawlPenaltyScoreChanged = onCrawlPenaltyScoreChanged
M.onCrawlResultsShown = onCrawlResultsShown
return M
