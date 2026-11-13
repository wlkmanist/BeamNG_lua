-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_display"

local crawlUILayout = "crawl"
local crawlerPlayers = {}
local playersWithMessages = {}

local penaltyCategories = {
  points = true,
  skippedCheckpoints = true,
  drivingBackwards = true,
  vehicleFlippedUpright = true,
  vehicleReset = true,
  vehicleRecovered = true,
  boundaryViolation = true,
  bonusCheckpoint = true,
  gateCleared = true,
  dnf = true,
}

local function setCrawlUILayout(value)
  -- if value then
  --   core_gamestate.setGameState('freeroam', crawlUILayout, 'freeroam')
  -- else
  --   core_gamestate.setGameState('freeroam', 'freeroam', 'freeroam')
  -- end
end

local function isMultiseatActive()
  return core_multiseat
    and core_multiseat.isMultiseatActive
    and core_multiseat.isMultiseatActive()
    or false
end

local function getPlayerIndexForVehicle(vehId)
  if vehId == nil or not core_multiseat or not core_multiseat.getJoinedPlayers then return nil end
  for _, player in ipairs(core_multiseat.getJoinedPlayers() or {}) do
    local playerVehId = be:getPlayerVehicleID(player)
    if playerVehId and playerVehId ~= -1 and playerVehId == vehId then
      return player
    end
  end
  return nil
end

local function rememberPlayer(playerIndex)
  if playerIndex == nil then return end
  playersWithMessages[playerIndex] = true
end

local function resolvePlayerIndex(crawlerId)
  local playerIndex = crawlerPlayers[crawlerId]
  if playerIndex ~= nil then return playerIndex end
  playerIndex = getPlayerIndexForVehicle(crawlerId)
  if playerIndex ~= nil then
    crawlerPlayers[crawlerId] = playerIndex
  end
  return playerIndex
end

local function resetMessagePlayers()
  table.clear(crawlerPlayers)
  table.clear(playersWithMessages)
end

local function sendMessage(msg, ttl, category, icon, player)
  guihooks.trigger('Message', {
    msg = msg,
    ttl = ttl or 5,
    category = category or '',
    icon = icon,
    player = player,
  })
  rememberPlayer(player)
end

-- Same toast as ui_message, but targeted at one split-screen panel when a crawlerId is known.
-- With no crawlerId, broadcasts to remembered and currently joined players so a full teardown still clears toasts.
local function showMessage(msg, ttl, category, icon, crawlerId)
  local isClear = msg == ""
  if not isClear and penaltyCategories[category] and not gameplay_crawl_utils.hasPenalties(crawlerId) then return end
  if isMultiseatActive() or next(playersWithMessages) or next(crawlerPlayers) then
    if crawlerId ~= nil then
      local playerIndex = resolvePlayerIndex(crawlerId)
      if playerIndex == nil then
        -- Vehicle no longer maps to a joined player (e.g. switched away from mid-teardown).
        -- Drop silently instead of falling back to a global broadcast that would spam/clear
        -- every other split-screen player's panel for a message that isn't theirs.
        return
      end
      sendMessage(msg, ttl, category, icon, playerIndex)
      return
    end

    local sent = {}
    for playerIndex in pairs(playersWithMessages) do
      sendMessage(msg, ttl, category, icon, playerIndex)
      sent[playerIndex] = true
    end
    if isMultiseatActive() then
      local playerIndices = core_multiseat.getJoinedPlayers and core_multiseat.getJoinedPlayers() or {}
      for i = 1, #playerIndices do
        local playerIndex = playerIndices[i]
        if not sent[playerIndex] then
          sendMessage(msg, ttl, category, icon, playerIndex)
        end
      end
    end
    ui_message(msg, ttl, category, icon)
    if isClear then
      resetMessagePlayers()
    end
    return
  end
  ui_message(msg, ttl, category, icon)
end

local function clearMessage(category, crawlerId)
  showMessage("", nil, category, nil, crawlerId)
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
  resetMessagePlayers()
end

local function showPointsMessage(points, crawlerId)
  if not multiplayer_sessionManager or not multiplayer_sessionManager.isSessionHost() then
    showMessage({txt="ui.crawl.penaltyPoints", context={points=points}}, 600, "points", nil, crawlerId)
  end
end

local function clearPointsMessage(crawlerId)
  clearMessage("points", crawlerId)
end

local function showCrawlCompletedMessage(time, points, crawlerId)
  showMessage("ui.crawl.crawlCompleted", nil, "crawlCompleted", nil, crawlerId)
  if gameplay_crawl_utils.hasPenalties(crawlerId) then
    showMessage({txt="ui.crawl.crawlResults", context={time=string.format("%.3f", time), points=points}}, 10, "crawlCompleted", nil, crawlerId)
  end
end

local function showSkippedCheckpointsMessage(skippedCount, crawlerId)
  showMessage({txt="ui.crawl.skippedCheckpoints", context={skippedCount=skippedCount, penaltyPoints=skippedCount * gameplay_crawl_utils.infractionPoints.skippedCheckpoint}}, nil, "skippedCheckpoints", nil, crawlerId)
end

local function showGateReachedMessage(crawlerId)
  showMessage("ui.crawl.gateReached", nil, "gateReached", nil, crawlerId)
end

local function showStartedCrawlMessage(crawlerId)
  showMessage("ui.crawl.startedCrawl", nil, "startedCrawl", nil, crawlerId)
end

local function showDisqualifiedMessage(eventData)
  local crawlerId = type(eventData) == "table" and eventData.crawlerId or eventData
  showMessage("ui.crawl.disqualified", nil, "disqualified", nil, crawlerId)
end

local function showDisqualifiedWaitingMessage(crawlerId)
  showMessage("ui.crawl.disqualifiedWaiting", 600, "disqualifiedWaiting", nil, crawlerId)
end

local function clearDisqualifiedWaitingMessage(crawlerId)
  clearMessage("disqualifiedWaiting", crawlerId)
end

local function showDrivingBackwardsMessage(crawlerId)
  showMessage({txt="ui.crawl.drivingBackwards", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.drivingBackwards}}, nil, "drivingBackwards", nil, crawlerId)
end

local function showVehicleFlippedUprightMessage(crawlerId)
  showMessage({txt="ui.crawl.vehicleFlippedUpright", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.vehicleFlippedUpright}}, nil, "vehicleFlippedUpright", nil, crawlerId)
end

local function showVehicleResetMessage(crawlerId)
  showMessage({txt="ui.crawl.vehicleReset", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.vehicleReset}}, nil, "vehicleReset", nil, crawlerId)
end

local function showVehicleRecoveredMessage(crawlerId)
  showMessage({txt="ui.crawl.vehicleRecovered", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.vehicleReset}}, nil, "vehicleRecovered", nil, crawlerId)
end

local function showBoundaryViolationMessage(crawlerId)
  showMessage({txt="ui.crawl.boundaryViolation", context={penaltyPoints=gameplay_crawl_utils.infractionPoints.boundaryViolation}}, nil, "boundaryViolation", nil, crawlerId)
end

local function showBonusCheckpointMessage(penaltyPoints, crawlerId)
  showMessage({txt="ui.crawl.bonusCheckpoint", context={penaltyPoints=penaltyPoints}}, nil, "bonusCheckpoint", nil, crawlerId)
end

local function showGateClearedMessage(penaltyPoints, crawlerId)
  showMessage({txt="ui.crawl.gateCleared", context={penaltyPoints=penaltyPoints}}, nil, "gateCleared", nil, crawlerId)
end

local function showDNFMessage(crawlerId)
  showMessage("ui.crawl.dnf", nil, "dnf", nil, crawlerId)
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
M.showDisqualifiedWaitingMessage = showDisqualifiedWaitingMessage
M.clearDisqualifiedWaitingMessage = clearDisqualifiedWaitingMessage
M.showDrivingBackwardsMessage = showDrivingBackwardsMessage
M.showVehicleFlippedUprightMessage = showVehicleFlippedUprightMessage
M.showVehicleResetMessage = showVehicleResetMessage
M.showVehicleRecoveredMessage = showVehicleRecoveredMessage
M.showBoundaryViolationMessage = showBoundaryViolationMessage
M.showBonusCheckpointMessage = showBonusCheckpointMessage
M.showGateClearedMessage = showGateClearedMessage
M.showDNFMessage = showDNFMessage

return M
