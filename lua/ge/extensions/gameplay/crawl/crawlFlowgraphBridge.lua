-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_flowgraph_bridge"

M.dependencies = { 'gameplay_crawl_saveSystem', 'gameplay_crawl_general', 'gameplay_crawl_utils', 'gameplay_crawl_boundary', 'gameplay_crawl_display' }
local bridgeState = {
  activeTrail = nil,
  activeCrawlerId = nil,
  isActive = false
}

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

  log('D', logTag, 'Loaded trail: ' .. trail.name)
  return trail
end

M.configureCrawl = function(trail)
  if not trail then
    log('E', logTag, 'No trail provided for configuration')
    return false
  end

  local boundary = gameplay_crawl_saveSystem.getBoundaryById(trail.boundaryId)
  local path = gameplay_crawl_saveSystem.getPathById(trail.pathId)
  local startingPosition = gameplay_crawl_saveSystem.getStartingPositionById(trail.startingPositionId)

  if not boundary or not path then
    log('E', logTag, 'Missing required boundary or path data for trail: ' .. trail.name)
    return false
  end

  bridgeState.activeTrail = {
    trail = trail,
    boundary = boundary,
    path = path,
    startingPosition = startingPosition,
    prefabs = trail.prefabs or {}
  }

  log('D', logTag, 'Configured crawl for trail: ' .. trail.name)
  return true
end

M.startCrawl = function(vehicleId)
  if not bridgeState.activeTrail then
    log('E', logTag, 'No active trail configured')
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

  gameplay_crawl_general.startCrawl(bridgeState.activeTrail.trail, veh)

  bridgeState.activeCrawlerId = veh:getID()
  bridgeState.isActive = true

  log('D', logTag, 'Started crawl for vehicle: ' .. bridgeState.activeCrawlerId)
  return true
end

M.stopCrawl = function()
  if not bridgeState.isActive then
    log('W', logTag, 'No active crawl to stop')
    return false
  end

  gameplay_crawl_utils.stopCrawl()

  bridgeState.activeTrail = nil
  bridgeState.activeCrawlerId = nil
  bridgeState.isActive = false

  log('D', logTag, 'Stopped crawl')
  return true
end

M.resetCrawl = function()
  if not bridgeState.isActive or not bridgeState.activeCrawlerId then
    log('W', logTag, 'No active crawl to reset')
    return false
  end

  local veh = scenetree.findObjectById(bridgeState.activeCrawlerId)
  if not veh then
    log('E', logTag, 'Crawler vehicle not found')
    return false
  end

  gameplay_crawl_utils.resetCrawlData(bridgeState.activeCrawlerId)

  if bridgeState.activeTrail and bridgeState.activeTrail.startingPosition then
    local startingPos = bridgeState.activeTrail.startingPosition.transform
    if startingPos and startingPos.position then
      local pos = startingPos.position
      local rot = startingPos.rotation or quat(0, 0, 0, 1)

      if bridgeState.activeTrail.path and bridgeState.activeTrail.path.nodes and #bridgeState.activeTrail.path.nodes > 0 then
        local firstNode = bridgeState.activeTrail.path.nodes[1]
        if firstNode and firstNode.rotation then
          rot = firstNode.rotation
        end
      end

      spawn.safeTeleport(veh, pos, rot, nil, nil, nil, nil, true)

      log('D', logTag, 'Reset crawler to starting position using safe teleport')
    else
      log('E', logTag, 'No valid starting position found')
      return false
    end
  else
    log('E', logTag, 'No active trail or starting position data')
    return false
  end

  gameplay_crawl_utils.stopCrawl()

  bridgeState.activeTrail = nil
  bridgeState.activeCrawlerId = nil
  bridgeState.isActive = false

  log('D', logTag, 'Crawl reset and stopped')
  return true
end

M.getCrawlEndData = function()
  if not bridgeState.isActive or not bridgeState.activeCrawlerId then
    return nil
  end

  local state = gameplay_crawl_utils.getCrawlState(bridgeState.activeCrawlerId)
  if not state or not state.active then
    return nil
  end

  return {
    time = state.currentTime,
    points = state.crawlerData.points or 0,
    completed = state.isCompleting or false,
    pathnodesCompleted = state.completedPathnodes or {},
    pathnodeTimings = state.pathnodeTimings or {},
    disqualified = state.events.disqualified or false
  }
end

M.getCrawlRuntimeData = function()
  if not bridgeState.isActive or not bridgeState.activeCrawlerId then
    return nil
  end

  local state = gameplay_crawl_utils.getCrawlState(bridgeState.activeCrawlerId)
  if not state or not state.active then
    return nil
  end

  return {
    currentTime = state.currentTime,
    currentPathnodeIndex = state.currentPathnodeIndex or 1,
    points = state.crawlerData.points or 0,
    isCompleted = state.isCompleted or false,
    disqualified = state.events.disqualified or false,
    crawlerPosition = gameplay_crawl_utils.getCrawlerPosition(bridgeState.activeCrawlerId),
    crawlerDirection = gameplay_crawl_utils.getCrawlerDirection(bridgeState.activeCrawlerId),
    vehicleId = bridgeState.activeCrawlerId
  }
end

M.getTrailInfo = function(trailId)
  local trail = nil
  if trailId then
    trail = gameplay_crawl_saveSystem.getTrailById(trailId)
  elseif bridgeState.activeTrail then
    trail = bridgeState.activeTrail.trail
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
  return bridgeState.isActive
end

M.getActiveCrawlerId = function()
  return bridgeState.activeCrawlerId
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
  if not bridgeState.isActive or not bridgeState.activeCrawlerId then
    return
  end

  local points = gameplay_crawl_utils.infractionPoints[penaltyType]
  if not points then
    return
  end

  gameplay_crawl_utils.applyPenalty(bridgeState.activeCrawlerId, penaltyType, points)
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

M.getLastRecoveryCheckpointIndex = function()
  if not bridgeState.isActive or not bridgeState.activeCrawlerId then
    return 0
  end

  return gameplay_crawl_utils.getLastRecoveryCheckpointIndex(bridgeState.activeCrawlerId)
end

M.setRecoveryCheckpoint = function(checkpoint)
  if not bridgeState.isActive or not bridgeState.activeCrawlerId then
    return false
  end

  return gameplay_crawl_utils.setRecoveryCheckpoint(bridgeState.activeCrawlerId, checkpoint)
end

local function onCrawlStarted()
  log('D', logTag, 'Crawl started event received')
end

local function onCrawlResultsShown(eventData)
  log('I', logTag, 'Crawl results shown: Time=' .. eventData.time .. ', Points=' .. eventData.points)
end

local function onCrawlPathnodeReached(eventData)
  log('D', logTag, 'Pathnode reached: ' .. eventData.pathnodeIndex .. ' at time ' .. eventData.time)
end

M.onCrawlStarted = onCrawlStarted
M.onCrawlResultsShown = onCrawlResultsShown
M.onCrawlPathnodeReached = onCrawlPathnodeReached

M.cleanup = function()
  if bridgeState.isActive then
    M.stopCrawl()
  end
  bridgeState.activeTrail = nil
  bridgeState.activeCrawlerId = nil
  bridgeState.isActive = false
  log('D', logTag, 'Bridge cleanup completed')
end

return M
