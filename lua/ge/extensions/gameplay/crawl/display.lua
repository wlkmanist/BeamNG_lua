-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_display"

local crawlUILayout = "crawl"

local function setCrawlUILayout(value)
  -- if value then
  --   core_gamestate.setGameState('freeroam', crawlUILayout, 'freeroam')
  -- else
  --   core_gamestate.setGameState('freeroam', 'freeroam', 'freeroam')
  -- end
end

local function onCrawlStarted()
  log('D', logTag, 'Crawl started, changing UI layout to crawl')
  setCrawlUILayout(true)
end

local function onCrawlComplete()
  setCrawlUILayout(false)
end

local function onCrawlResultsShown()

end

local function onExtensionLoaded()

end

local function onExtensionUnloaded()
  setCrawlUILayout(false)
end

local function showPointsMessage(points)
  if not multiplayer_sessionManager or not multiplayer_sessionManager.isSessionHost() then
    ui_message({txt="ui.crawl.penaltyPoints", context={points=points}}, 600, "points")
  end
end

local function clearPointsMessage()
  ui_message("", nil, "points")
end

local function showCrawlCompletedMessage(time, points)
  ui_message("ui.crawl.crawlCompleted", nil, "crawlCompleted")
  ui_message({txt="ui.crawl.crawlResults", context={time=string.format("%.3f", time), points=points}}, 10, "crawlCompleted")
end

local function showSkippedCheckpointsMessage(skippedCount)
  ui_message({txt="ui.crawl.skippedCheckpoints", context={skippedCount=skippedCount, penaltyPoints=skippedCount * gameplay_crawl_utils.infractionPoints.skippedCheckpoint}}, nil, "skippedCheckpoints")
end

local function showGateReachedMessage()
  ui_message("ui.crawl.gateReached", nil, "gateReached")
end

local function showStartedCrawlMessage()
  ui_message("ui.crawl.startedCrawl", nil, "startedCrawl")
end

local function showDisqualifiedMessage()
  ui_message("ui.crawl.disqualified", nil, "disqualified")
end

local function showDrivingBackwardsMessage()
  ui_message({txt="ui.crawl.drivingBackwards", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.drivingBackwards}}, nil, "drivingBackwards")
end

local function showVehicleFlippedUprightMessage()
  ui_message({txt="ui.crawl.vehicleFlippedUpright", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.vehicleFlippedUpright}}, nil, "vehicleFlippedUpright")
end

local function showVehicleResetMessage()
  ui_message({txt="ui.crawl.vehicleReset", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.vehicleReset}}, nil, "vehicleReset")
end

local function showBoundaryViolationMessage()
  ui_message({txt="ui.crawl.boundaryViolation", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.boundaryViolation}}, nil, "boundaryViolation")
end

local function showBonusCheckpointMessage(penaltyPoints)
  ui_message({txt="ui.crawl.bonusCheckpoint", context={penaltyPoints=penaltyPoints}}, nil, "bonusCheckpoint")
end

local function showGateClearedMessage(penaltyPoints)
  ui_message({txt="ui.crawl.gateCleared", context={penaltyPoints=penaltyPoints}}, nil, "gateCleared")
end

local function showDNFMessage()
  ui_message("ui.crawl.dnf", nil, "dnf")
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onCrawlStarted = onCrawlStarted
M.onCrawlComplete = onCrawlComplete
M.onCrawlResultsShown = onCrawlResultsShown

M.showPointsMessage = showPointsMessage
M.clearPointsMessage = clearPointsMessage
M.showCrawlCompletedMessage = showCrawlCompletedMessage
M.showSkippedCheckpointsMessage = showSkippedCheckpointsMessage
M.showGateReachedMessage = showGateReachedMessage
M.showStartedCrawlMessage = showStartedCrawlMessage
M.showDisqualifiedMessage = showDisqualifiedMessage
M.showDrivingBackwardsMessage = showDrivingBackwardsMessage
M.showVehicleFlippedUprightMessage = showVehicleFlippedUprightMessage
M.showVehicleResetMessage = showVehicleResetMessage
M.showBoundaryViolationMessage = showBoundaryViolationMessage
M.showBonusCheckpointMessage = showBonusCheckpointMessage
M.showGateClearedMessage = showGateClearedMessage
M.showDNFMessage = showDNFMessage

return M