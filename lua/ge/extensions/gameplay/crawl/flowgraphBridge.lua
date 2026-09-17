-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_flowgraph_bridge"

M.dependencies = { 'gameplay_crawl_saveSystem', 'gameplay_crawl_general', 'gameplay_crawl_utils', 'gameplay_crawl_boundary', 'gameplay_crawl_display' }

local function getActiveCrawlerId()
  local allStates = gameplay_crawl_utils.getAllCrawlStates()
  for crawlerId, state in pairs(allStates) do
    if state and state.active then
      return crawlerId
    end
  end
  return nil
end

M.loadCrawlTrail = function(trailId)
  if not trailId then
    log('E', logTag, 'No trail ID provided for loading')
    return nil
  end

  local trail = gameplay_crawl_saveSystem.getTrailById(trailId)
  if not trail then
    log('E', logTag, 'Failed to load trail: ' .. tostring(trailId))
    return nil
  end

  return trail
end

M.setupCrawl = function(vehicleId, trail)
  if not trail then
    log('E', logTag, 'No trail provided for setup')
    return false
  end

  local veh = nil
  if vehicleId then
    veh = scenetree.findObjectById(vehicleId)
  else
    veh = be:getPlayerVehicle(0)
  end

  if not veh then
    log('E', logTag, 'No valid vehicle found')
    return false
  end

  if gameplay_crawl_general.activeTrail then
    gameplay_crawl_utils.stopCrawl(true)
  end

  if gameplay_crawl_general.setupCrawl(trail, veh, true) then
    return true
  else
    log('E', logTag, 'general.setupCrawl returned false')
    return false
  end
end

M.startCrawl = function(vehicleId, trail)
  local veh = nil
  if vehicleId then
    veh = scenetree.findObjectById(vehicleId)
  else
    local crawlersData = gameplay_crawl_general.crawlersData or {}
    if crawlersData[1] and crawlersData[1].dynamicData and crawlersData[1].dynamicData.vehObj then
      veh = crawlersData[1].dynamicData.vehObj
    elseif crawlersData[1] and crawlersData[1].id then
      veh = scenetree.findObjectById(crawlersData[1].id)
    else
      veh = be:getPlayerVehicle(0)
    end
  end

  if not veh then
    log('E', logTag, 'No valid vehicle found - make sure Setup Crawl was called first')
    return false
  end

  local activeCrawlerId = getActiveCrawlerId()
  if activeCrawlerId then
    local state = gameplay_crawl_utils.getCrawlState(activeCrawlerId)
    if state and state.active and not state.crawlStarted then
      if gameplay_crawl_utils.resumeCrawlTimer(activeCrawlerId) then
        return true
      end
    end
  end

  if not trail then
    if not gameplay_crawl_general.activeTrail then
      log('E', logTag, 'No active trail found - Setup Crawl must be called before Start Crawl')
      return false
    end
    trail = gameplay_crawl_general.activeTrail.trail
  end

  if gameplay_crawl_general.startCrawlFlowgraph(trail, veh) then
    return true
  else
    log('E', logTag, 'startCrawlFlowgraph returned false')
    return false
  end
end

M.stopCrawl = function()
  if not gameplay_crawl_general.activeTrail then
    return false
  end

  gameplay_crawl_utils.stopCrawl(true)
  return true
end

M.resetCrawl = function()
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return false
  end

  local veh = scenetree.findObjectById(activeCrawlerId)
  if not veh then
    log('E', logTag, 'Crawler vehicle not found')
    return false
  end

  if not gameplay_crawl_utils.resetCrawlData(activeCrawlerId, true) then
    return false
  end

  local activeTrail = gameplay_crawl_general.activeTrail
  if activeTrail and activeTrail.startingPosition then
    local startingPos = activeTrail.startingPosition.transform
    if startingPos and startingPos.position then
      local pos = startingPos.position
      local rot = startingPos.rotation or quat(0, 0, 0, 1)

      spawn.safeTeleport(veh, pos, rot, nil, nil, nil, nil, true)
    else
      return false
    end
  else
    return false
  end

  return true
end

M.getCrawlEndData = function()
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return nil
  end

  local state = gameplay_crawl_utils.getCrawlState(activeCrawlerId)
  if not state or not state.active then
    return nil
  end

  return {
    time = state.currentTime,
    points = state.crawlerData.points or 0,
    completed = state.isCompleted or false,
    pathnodesCompleted = state.completedPathnodes or {},
    pathnodeTimings = state.pathnodeTimings or {},
    disqualified = state.isDisqualified or false,
    recoveries = state.recoveryCount or 0
  }
end

M.getCrawlRuntimeData = function()
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return nil
  end

  local state = gameplay_crawl_utils.getCrawlState(activeCrawlerId)
  if not state or not state.active then
    return nil
  end

  return {
    currentTime = state.currentTime,
    currentPathnodeIndex = state.currentPathnodeIndex or 1,
    points = state.crawlerData.points or 0,
    isCompleted = state.isCompleted or false,
    disqualified = state.isDisqualified or false,
    crawlerPosition = gameplay_crawl_utils.getCrawlerPosition(activeCrawlerId),
    crawlerDirection = gameplay_crawl_utils.getCrawlerDirection(activeCrawlerId),
    vehicleId = activeCrawlerId
  }
end

M.getTrailInfo = function(trailId)
  local trail = nil
  if trailId then
    trail = gameplay_crawl_saveSystem.getTrailById(trailId)
  elseif gameplay_crawl_general.activeTrail then
    trail = gameplay_crawl_general.activeTrail.trail
  end

  if not trail then
    return nil
  end

  return {
    name = trail.name,
    description = trail.description,
    pathId = trail.pathId,
    boundaryId = trail.boundaryId,
    startingPositionId = trail.startingPositionId,
    pathReversed = trail.pathReversed or false,
    rules = trail.rules or {},
    prefabs = trail.prefabs or {},
    metadata = trail.metadata or {}
  }
end


M.isCrawlActive = function()
  return gameplay_crawl_general.activeTrail ~= nil
end

M.getActiveCrawlerId = function()
  return getActiveCrawlerId()
end

M.getAllTrails = function()
  return gameplay_crawl_saveSystem.getAllTrails()
end

M.getAllStartingPositions = function()
  return gameplay_crawl_saveSystem.getAllStartingPositions()
end

M.getPlayerTrailStats = function(trailId)
  return gameplay_crawl_saveSystem.getPlayerTrailStats(trailId)
end

M.getDynamicObjectsFromPrefab = function(prefabId, dynamicName)
  return gameplay_crawl_utils.getDynamicObjectsFromPrefab(prefabId, dynamicName)
end

M.applyPenalty = function(penaltyType)
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return
  end

  local points = gameplay_crawl_utils.infractionPoints[penaltyType]
  if not points then
    return
  end

  gameplay_crawl_utils.applyPenalty(activeCrawlerId, penaltyType, points)
end

local penaltyTypes = {
  'boundaryViolation',
  'drivingBackwards',
  'gateTouch',
  'vehicleReset',
  'wrongDirection',
  'skippedCheckpoint',
  'vehicleFlippedUpright',
  'dnf',
}

M.getPenaltyTypes = function()
  return penaltyTypes
end

M.getLastRecoveryCheckpoint = function()
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return nil
  end

  return gameplay_crawl_utils.getLastRecoveryCheckpoint(activeCrawlerId)
end

M.getLastRecoveryCheckpointIndex = function()
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return 0
  end

  return gameplay_crawl_utils.getLastRecoveryCheckpointIndex(activeCrawlerId)
end

M.setRecoveryCheckpoint = function(checkpoint)
  local activeCrawlerId = getActiveCrawlerId()
  if not activeCrawlerId then
    return false
  end

  return gameplay_crawl_utils.setRecoveryCheckpoint(activeCrawlerId, checkpoint)
end

local function onCrawlStarted()
end

local function onCrawlResultsShown(eventData)
end

local function onCrawlPathnodeReached(eventData)
end

M.onCrawlStarted = onCrawlStarted
M.onCrawlResultsShown = onCrawlResultsShown
M.onCrawlPathnodeReached = onCrawlPathnodeReached

M.cleanup = function()
  if gameplay_crawl_general.activeTrail then
    M.stopCrawl()
  end
end

return M
