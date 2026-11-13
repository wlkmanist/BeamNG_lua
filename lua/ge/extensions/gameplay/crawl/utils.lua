-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_utils"

local gameplay_crawl_boundary = require('ge/extensions/gameplay/crawl/boundary')
local gameplay_crawl_display = require('ge/extensions/gameplay/crawl/display')
local crawlDebugDraw = require('ge/extensions/gameplay/crawl/debugDraw')

-- Lap times integration
local core_lapTimes = nil
if extensions and extensions.core_lapTimes then
  core_lapTimes = extensions.core_lapTimes
end

local infractionPoints = {
  drivingBackwards = 1,
  vehicleFlippedUpright = 5,
  gateTouch = 10,
  vehicleReset = 10,
  boundaryViolation = 10,
  wrongDirection = 10,
  skippedCheckpoint = 10,
  dnf = 50,
  gateCleared = -2,
  bonusGateCleared = -15,
}

local function getDnfThreshold(state)
  local limit = state and state.trail and state.trail.rules and tonumber(state.trail.rules.dnfPointLimit)
  if limit and limit > 0 then
    return limit
  end
  return infractionPoints.dnf
end

local infractionCooldowns = {
  drivingBackwards = 5,
  boundaryViolation = 3,
}

local drivingBackwardsSettings = {
  velocityDotThreshold = -0.5,
  distanceThreshold = 2,
}

local markers = nil
local markerModes = {}
local nodeKeyCache = {}
local crawlStates = {}
local markerSets = {}
local markerSetMode = nil
local markerWaypoints = {}
local markerPhotoModeOpen = false

-- Priority used when aggregating multiple active crawlers' views of the shared 3D gate
-- markers in a shared camera view (see updateCrawlMarkerModes). Higher wins on a given node.
local MARKER_MODE_RANK = {
  inactive = 0,
  final = 1,
  skipped = 2,
  current = 3,
  bonus = 4,
  recovery = 4,
  finished = 5,
}
local crawlerMarkerScratch = {}
local markerModeAggregateVersions = {}
local markerModeAggregateActiveCount = 0
local markerModeAggregateForceDirty = false
local previewSphereColor = ColorF(1,1,1,1)

-- Cached tostring(index) so the per-frame marker update doesn't allocate strings.
local function nodeKey(i)
  local key = nodeKeyCache[i]
  if not key then
    key = tostring(i)
    nodeKeyCache[i] = key
  end
  return key
end
local markersVisibleForPath = nil
local spawnedPrefabIds = {}
local spawningPrefabs = false
local isPreviewMode = false
local pathStatsCache = {}
local dottedPath = {}
local dottedPathTimer = 0
local pauseGuidanceActive = false
local dynamicObjects = {}
local dynamicObjectCollisionData = {}
local debugDrawEnabled = false

local completionDelay = 3
local syncMarkerSetMode

local function getCrawlRecoveryRules(state)
  local recoveryRules = state and state.trail and state.trail.rules and state.trail.rules.recovery
  return recoveryRules and recoveryRules.mode == "lastGate" and recoveryRules or nil
end

local function getPlayerIndexForCrawler(crawlerId)
  if not core_multiseat or not core_multiseat.getJoinedPlayers then return nil end
  for _, player in ipairs(core_multiseat.getJoinedPlayers() or {}) do
    if be:getPlayerVehicleID(player) == crawlerId then
      return player
    end
  end
  return nil
end

local function usePerPlayerMarkerSets(layoutMode)
  if not core_multiseat
    or not core_multiseat.isMultiseatActive
    or not core_multiseat.isMultiseatActive()
  then
    return false
  end
  local hasActiveCrawler = false
  for _, state in pairs(crawlStates) do
    if state and state.active then
      hasActiveCrawler = true
      break
    end
  end
  if not hasActiveCrawler then return false end
  if layoutMode ~= nil then
    return layoutMode == "split"
  end
  if not render_splitScreen or not render_splitScreen.getCurrentConfiguration then
    return false
  end
  local enabled, _, _, mode = render_splitScreen.getCurrentConfiguration()
  return enabled and mode == "split"
end

local function clearMarkerSet(crawlerId)
  local markerSet = markerSets[crawlerId]
  if not markerSet then return end
  for _, marker in pairs(markerSet.markers) do
    marker:clearMarkers()
  end
  markerSets[crawlerId] = nil
end

local function clearMarkerSets()
  for _, markerSet in pairs(markerSets) do
    for _, marker in pairs(markerSet.markers) do
      marker:clearMarkers()
    end
  end
  markerSets = {}
  markerSetMode = nil
  markerPhotoModeOpen = false
end

local function createMarkerSet(crawlerId, viewPlayer)
  local markerSet = {
    viewPlayer = viewPlayer,
    markers = {},
    modes = {},
  }
  local raceMarker = require("scenario/race_marker")
  for _, waypoint in ipairs(markerWaypoints) do
    local marker = raceMarker.createRaceMarker(true, "crawlMarker")
    if marker.setRenderViewPlayer then
      marker:setRenderViewPlayer(viewPlayer)
    end
    marker:setToCheckpoint(waypoint)
    markerSet.markers[waypoint.name] = marker
    markerSet.modes[waypoint.name] = "hidden"
  end
  markerSets[crawlerId] = markerSet
  return markerSet
end

local function syncPlayerMarkerSets()
  local staleCrawlerIds = {}
  for crawlerId, markerSet in pairs(markerSets) do
    local state = crawlStates[crawlerId]
    local player = state and state.active and getPlayerIndexForCrawler(crawlerId) or nil
    if player == nil or markerSet.viewPlayer ~= player then
      staleCrawlerIds[#staleCrawlerIds + 1] = crawlerId
    end
  end
  for _, crawlerId in ipairs(staleCrawlerIds) do
    clearMarkerSet(crawlerId)
  end

  for crawlerId, state in pairs(crawlStates) do
    if state and state.active and not markerSets[crawlerId] then
      local player = getPlayerIndexForCrawler(crawlerId)
      if player ~= nil then
        createMarkerSet(crawlerId, player)
      end
    end
  end
end

local function rebuildMarkerSets(layoutMode)
  if markers then
    markers.onClientEndMission()
    markers = nil
  end
  clearMarkerSets()
  markerModeAggregateForceDirty = true
  if markersVisibleForPath == nil then return end

  if usePerPlayerMarkerSets(layoutMode) then
    markerSetMode = "split"
    syncPlayerMarkerSets()
    return
  end

  markerSetMode = "shared"
  markers = require("scenario/race_marker")
  markers.init()
  markers.setupMarkers(markerWaypoints, "crawlMarker")
  markers.setModes(markerModes)
end

local function hasPenalties(crawlerId)
  local state = crawlStates[crawlerId]
  local rules = state and state.trail and state.trail.rules
  return not rules or rules.penalties ~= false
end

local function applyPenalty(crawlerId, penaltyType, points)
  local state = crawlStates[crawlerId]
  if not state or not state.active or not hasPenalties(crawlerId) then
    return
  end

  if not points then
    points = infractionPoints[penaltyType]
    if not points then
      log('E', logTag, string.format('Unknown penalty/infraction type: %s', penaltyType))
      return
    end
  end

  local oldPoints = state.crawlerData.points or 0
  state.crawlerData.points = (state.crawlerData.points or 0) + points

  if state.crawlerData.points < 0 then
    state.crawlerData.points = 0
  end

  extensions.hook("onCrawlPenaltyScoreChanged", {
    crawlerId = crawlerId,
    penaltyScore = state.crawlerData.points,
    oldPenaltyScore = oldPoints,
  })

  table.insert(state.eventLog, {
    time = state.currentTime,
    type = 'penalty',
    penaltyType = penaltyType,
    points = points,
    totalPoints = state.crawlerData.points
  })
end

local function unloadPrefabs()
  spawningPrefabs = false
  local removedAny = false
  for _, id in ipairs(spawnedPrefabIds) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:delete()
      removedAny = true
    end
  end
  spawnedPrefabIds = {}
  if removedAny then
    be:reloadCollision()
    map.reset()
  end
  dynamicObjects = {}
  dynamicObjectCollisionData = {}

  gameplay_crawl_boundary.cleanupBoundaryMarkers()
end

local function getDynamicObjectsFromPrefab(prefabId, dynamicName)
  if not prefabId or not dynamicName then
    return {}
  end

  local prefab = scenetree.findObjectById(prefabId)
  if not prefab then
    return {}
  end

  local dynamicObjects = {}
  for i = 0, prefab:size() - 1 do
    local child = prefab:at(i)
    local id = child:getID()
    local dF = child:getDynamicFields()
    for _, value in pairs(dF or {}) do
      if type(value) == "string" and value == dynamicName then
        table.insert(dynamicObjects, id)
        break
      end
    end
  end
  return dynamicObjects
end

local function loadPrefabs(prefabFileList)
  if not prefabFileList then return end

  spawningPrefabs = true
  for _, filePath in ipairs(prefabFileList or {}) do
    local _, fn = path.splitWithoutExt(filePath)
    local scenetreeObject = spawnPrefab(Sim.getUniqueName(fn), filePath, 0 .. " " .. 0 .. " " .. 0, "0 0 1 0", "1 1 1", false)
    if not scenetreeObject then
      log('E', logTag, 'Failed to spawn crawl prefab: ' .. tostring(filePath))
      goto continue
    end
    scenetreeObject.canSave = false
    if scenetree.MissionGroup then
      scenetree.MissionGroup:add(scenetreeObject)
    end
    local prefabId = scenetreeObject:getID()
    table.insert(spawnedPrefabIds, prefabId)

    for i = 0, scenetreeObject:size() - 1 do
      local child = scenetreeObject:at(i)
      if child and child.getClassName and child:getClassName() == "BeamNGVehicle" then
        child:setDynDataFieldbyName("autoEnterVehicle", 0, "false")
      end
    end

    local prefabDynamicObjects = getDynamicObjectsFromPrefab(prefabId, "crawlDynamic")
    for _, objId in ipairs(prefabDynamicObjects) do
      table.insert(dynamicObjects, objId)
      dynamicObjectCollisionData[objId] = {
        hasBeenTouched = false
      }
    end
    ::continue::
  end
  spawningPrefabs = false

  if #spawnedPrefabIds > 0 then
    be:reloadCollision()
    map.reset()
  end

  if gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.boundary then
    gameplay_crawl_boundary.spawnBoundaryMarkers(gameplay_crawl_general.activeTrail.boundary, 5.0)
  end
end

local function clearMarkers()
  if markers then
    markers.onClientEndMission()
    markers = nil
  end
  clearMarkerSets()
  markersVisibleForPath = nil
  markerWaypoints = {}
  markerModes = {}
  markerModeAggregateForceDirty = true
  isPreviewMode = false
end

local function clearCrawler(crawlerId)
  if not crawlerId then
    return
  end
  clearMarkerSet(crawlerId)
  crawlStates[crawlerId] = nil
  markerModeAggregateForceDirty = true
  if markersVisibleForPath ~= nil then
    syncMarkerSetMode()
  end
end

-- True when crawlerId is the only currently-active crawler (or the set is otherwise empty).
-- Used to guard calls into core_lapTimes, which is a single global race timer: in split-screen,
-- only the first crawler to join should (re)configure/start it, and only the last one finishing
-- should stop it, so additional players don't reset or cut off everyone else's HUD timer.
local function isSoleActiveCrawler(crawlerId)
  for id, state in pairs(crawlStates) do
    if id ~= crawlerId and state and state.active then
      return false
    end
  end
  return true
end

local function clear(force)
  local shouldClear = true

  if not force then
    -- Don't clear if any active crawl is from mission
    for crawlerId, state in pairs(crawlStates) do
      if state and state.active and state.isFromMission then
        shouldClear = false
        break
      end
    end
  end

  if shouldClear then
    clearMarkers()
    unloadPrefabs()

    for crawlerId, _ in pairs(crawlStates) do
      clearCrawler(crawlerId)
    end
    crawlStates = {}
    gameplay_crawl_general.activeTrail = nil
    extensions.hook("onCrawlCleared")
    dynamicObjects = {}
    dynamicObjectCollisionData = {}

    gameplay_crawl_display.clearPointsMessage()
    gameplay_crawl_display.clearDisqualifiedWaitingMessage()
  end
end

local function onPreviewUpdate(dt)
  dottedPathTimer = dottedPathTimer + dt
  local sinOff = 0.8
  local radiusBase = 0.1
  local radiusMax = 0.33
  for _, pos in ipairs(dottedPath) do
    if dottedPathTimer*100 > pos.distanceFromStart then
      local t = (dottedPathTimer*5 - pos.distanceFromStart/4)
      local radius = math.sin(t)
      if radius > sinOff and t > 0 then
        radius = ((radius-sinOff)/(1-sinOff)) * (radiusMax-radiusBase) + radiusBase
      else
        radius = radiusBase
      end
      debugDrawer:drawSphere(pos.pos, radius, previewSphereColor)
    end
  end
end

local function buildDottedPath(startPos, pathnodes, firstIndex)
  dottedPath = {}
  dottedPathTimer = -1
  local stepDist = 1.5

  local pathPositions = { startPos }
  for i = firstIndex or 1, #pathnodes do
    local pn = pathnodes[i]
    if pn.pos then
      table.insert(pathPositions, pn.pos)
    end
  end

  local currentDist = 0
  local dotPos = vec3()

  for i = 1, #pathPositions - 1 do
    local currentPos = pathPositions[i]
    local nextPos = pathPositions[i + 1]
    if currentPos and nextPos then
      dotPos:set(currentPos)
      local direction = (nextPos - currentPos):normalized()
      local segmentLength = (nextPos - currentPos):length()
      local segmentEndDist = currentDist + segmentLength
      while currentDist < segmentEndDist-stepDist do
        dotPos = dotPos + direction*stepDist

        local terrainHeight = 0
        if core_terrain then
          terrainHeight = core_terrain.getTerrainHeight(dotPos) or dotPos.z
        end
        dotPos.z = terrainHeight + 1

        currentDist = currentDist + stepDist
        table.insert(dottedPath, {
          pos = vec3(dotPos),
          distanceFromStart = currentDist
        })
      end
    end
  end
end

local function setupCrawlMarkers(path)
  if not path then
    log('W', logTag, 'No path available for trail')
    return
  end

  local pathId = path._filePath or path.id or path._id or tostring(path)
  if markersVisibleForPath == pathId then
    return
  elseif markersVisibleForPath ~= nil then
    clearMarkers()
  end
  markersVisibleForPath = pathId

  markerWaypoints = {}
  markerModes = {}
  for i, pn in ipairs(path.nodes or {}) do
    if pn.pos then
      local dir = vec3(0, 1, 0)
      if pn.rotation then
        dir = pn.rotation * vec3(0, 1, 0)
      end

      table.insert(markerWaypoints, {
        name = tostring(i),
        pos = pn.pos,
        radius = pn.radius or 4.0,
        normal = nil,
        delay = 0,
        dir = dir
      })
      markerModes[tostring(i)] = 'hidden'
    end
  end
  if path.nodes and #path.nodes > 0 then
    markerModes[tostring(#path.nodes)] = 'final'
  end

  rebuildMarkerSets()

  dottedPath = {}
  dottedPathTimer = -1
  if path and path.nodes and #path.nodes > 0 then
    buildDottedPath(be:getPlayerVehicle(0):getPosition(), path.nodes)
  end

  isPreviewMode = true

end

local function activateCrawlMarkers()
  if markers and gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.path then
    local path = gameplay_crawl_general.activeTrail.path
    if path.nodes and #path.nodes > 0 then
      markerModes[tostring(1)] = 'current'
      markers.setModes(markerModes)
    end
  end

  markerModeAggregateForceDirty = true
  isPreviewMode = false
end

-- Computes one crawler's view of every node's marker mode into `out` (reused scratch table).
local function computeCrawlerMarkerModes(crawlerId, pathnodes, nodeCount, out)
  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return nil
  end

  local currentIndex = state.currentPathnodeIndex

  -- Initialize all markers as inactive
  for i = 1, nodeCount do
    out[nodeKey(i)] = 'inactive'
  end

  -- Set final node
  out[nodeKey(nodeCount)] = 'final'

  -- Set current/next node with special handling for recovery and bonus checkpoints
  if currentIndex <= nodeCount then
    local currentPathnode = pathnodes[currentIndex]
    if currentPathnode and currentPathnode.flags then
      -- Recovery checkpoints take priority (yellow)
      if currentPathnode.flags.isRecoveryCheckpoint then
        out[nodeKey(currentIndex)] = 'recovery'
      -- Bonus checkpoints (purple)
      elseif currentPathnode.flags.isBonusCheckpoint then
        out[nodeKey(currentIndex)] = 'bonus'
      else
        -- Normal next node (red)
        out[nodeKey(currentIndex)] = 'current'
      end
    else
      -- Normal next node (red)
      out[nodeKey(currentIndex)] = 'current'
    end
  end

  -- Mark completed nodes as finished (green)
  for pathnodeId, _ in pairs(state.completedPathnodes) do
    out[nodeKey(pathnodeId)] = 'finished'
  end

  -- Mark skipped nodes (nodes that were skipped between current and reached)
  if state.skippedPathnodes then
    for skippedId, _ in pairs(state.skippedPathnodes) do
      -- Only mark as skipped if not completed (skipped nodes can be completed later)
      if not state.completedPathnodes[skippedId] then
        out[nodeKey(skippedId)] = 'skipped'
      end
    end
  end

  -- Handle final node special cases
  if currentIndex == nodeCount then
    local finalPathnode = pathnodes[nodeCount]
    if finalPathnode and finalPathnode.flags then
      if finalPathnode.flags.isRecoveryCheckpoint then
        out[nodeKey(currentIndex)] = 'recovery'
      elseif finalPathnode.flags.isBonusCheckpoint then
        out[nodeKey(currentIndex)] = 'bonus'
      else
        out[nodeKey(currentIndex)] = 'final'
      end
    else
      out[nodeKey(currentIndex)] = 'final'
    end

    if state.isCompleted then
      out[nodeKey(currentIndex)] = 'finished'
    end
  end

  return out
end

syncMarkerSetMode = function()
  local desiredMode = usePerPlayerMarkerSets() and "split" or "shared"
  if markerSetMode ~= desiredMode then
    rebuildMarkerSets()
  elseif desiredMode == "split" then
    syncPlayerMarkerSets()
  end
end

local function applyMarkerModes(markerSet, modes)
  for name, marker in pairs(markerSet.markers) do
    local mode = modes[name] or "hidden"
    if markerSet.modes[name] ~= mode then
      markerSet.modes[name] = mode
      marker:setMode(mode)
    end
  end
end

local function updateCrawlMarkerModes()
  local activeTrail = gameplay_crawl_general.activeTrail
  local pathnodes = activeTrail and activeTrail.path and activeTrail.path.nodes
  if not pathnodes or #pathnodes == 0 then
    return
  end
  local nodeCount = #pathnodes

  if markerSetMode == "split" then
    for crawlerId, markerSet in pairs(markerSets) do
      local state = crawlStates[crawlerId]
      if state and state.active then
        local version = state.progressVersion or 0
        if markerSet.progressSig ~= version then
          markerSet.progressSig = version
          local modes = computeCrawlerMarkerModes(crawlerId, pathnodes, nodeCount, crawlerMarkerScratch)
          if modes then
            applyMarkerModes(markerSet, modes)
          end
        end
      end
    end
    return
  end

  -- A shared camera can only display one marker state, so combine all crawlers by priority.
  local dirty = markerModeAggregateForceDirty
  local anyActive = false
  local activeCount = 0
  for crawlerId, state in pairs(crawlStates) do
    if state and state.active then
      anyActive = true
      activeCount = activeCount + 1
      local version = state.progressVersion or 0
      if markerModeAggregateVersions[crawlerId] ~= version then
        dirty = true
        markerModeAggregateVersions[crawlerId] = version
      end
    end
  end
  if activeCount ~= markerModeAggregateActiveCount then
    dirty = true
    markerModeAggregateActiveCount = activeCount
  end
  if not anyActive then
    return
  end
  if not dirty then
    return
  end
  markerModeAggregateForceDirty = false

  for i = 1, nodeCount do
    markerModes[nodeKey(i)] = 'inactive'
  end
  markerModes[nodeKey(nodeCount)] = 'final'

  for crawlerId, state in pairs(crawlStates) do
    if state and state.active then
      local perCrawler = computeCrawlerMarkerModes(crawlerId, pathnodes, nodeCount, crawlerMarkerScratch)
      if perCrawler then
        for i = 1, nodeCount do
          local key = nodeKey(i)
          local candidate = perCrawler[key]
          local candidateRank = MARKER_MODE_RANK[candidate] or 0
          local currentRank = MARKER_MODE_RANK[markerModes[key]] or 0
          if candidateRank >= currentRank then
            markerModes[key] = candidate
          end
        end
      end
    end
  end

  if markers then
    markers.setModes(markerModes)
  end
end

local function showCompletionResults(crawlerId)
  local state = crawlStates[crawlerId]
  if not state then
    return
  end
  local completionTime = state.currentTime
  local points = state.crawlerData.points or 0

  extensions.hook("onCrawlResultsShown", {
    crawlerId = crawlerId,
    time = completionTime,
    points = points
  })
  gameplay_crawl_display.showCrawlCompletedMessage(completionTime, points, crawlerId)
end

-- Create race-like data structure for lap times app (called once at start)
local function createRaceDataStructure(crawlerId, state, path)
  if not core_lapTimes or not path or not path.nodes then
    return nil
  end

  local raceData = {
    time = state.currentTime,
    started = state.crawlStarted,
    suspended = false,
    lapCount = 1, -- Crawl is single lap
    path = {
      pathnodes = {
        sorted = path.nodes
      },
      config = {
        closed = false -- Crawl paths are not closed circuits
      }
    },
    states = {
      [crawlerId] = {
        startTime = 0,
        endTime = nil,
        complete = false,
        currentLap = 0, -- Always 0 for single lap
        currentTimes = {}, -- Current segment times
        historicTimes = {} -- Completed lap times (will have one entry when complete)
      }
    }
  }

  return raceData
end

-- Update race data structure with current state
local function updateRaceDataStructure(crawlerId, state, raceData)
  if not raceData or not raceData.states or not raceData.states[crawlerId] then
    return
  end

  local raceState = raceData.states[crawlerId]

  -- Update basic fields (cheap, every frame)
  raceData.time = state.currentTime
  raceData.started = state.crawlStarted
  raceState.complete = state.isCompleted
  raceState.endTime = state.isCompleted and state.currentTime or nil

  -- The segment list only changes when a node is timed or the crawl completes.
  -- Skip the sort/rebuild on frames where neither changed.
  local timingCount = tableSize(state.pathnodeTimings)
  if state._raceSegCount == timingCount and state._raceSegComplete == state.isCompleted then
    return
  end
  state._raceSegCount = timingCount
  state._raceSegComplete = state.isCompleted

  -- Rebuild current segment times from pathnodeTimings
  raceState.currentTimes = {}
  local sortedPathnodeIndices = {}
  for idx, _ in pairs(state.pathnodeTimings or {}) do
    table.insert(sortedPathnodeIndices, idx)
  end
  table.sort(sortedPathnodeIndices)

  local lastEndTime = 0
  for _, idx in ipairs(sortedPathnodeIndices) do
    local segmentTime = state.pathnodeTimings[idx]
    if segmentTime then
      local segmentInfo = {
        beginTime = lastEndTime,
        endTime = segmentTime,
        duration = segmentTime - lastEndTime
      }
      table.insert(raceState.currentTimes, segmentInfo)
      lastEndTime = segmentTime
    end
  end

  -- If completed, create historic time entry
  if state.isCompleted and #raceState.currentTimes > 0 and #raceState.historicTimes == 0 then
    local firstSegment = raceState.currentTimes[1]
    local lastSegment = raceState.currentTimes[#raceState.currentTimes]
    local lapInfo = {
      lap = 0,
      beginTime = firstSegment.beginTime,
      endTime = lastSegment.endTime,
      duration = lastSegment.endTime - firstSegment.beginTime,
      segmentTimes = {}
    }
    -- Copy segment times
    for _, seg in ipairs(raceState.currentTimes) do
      table.insert(lapInfo.segmentTimes, seg)
    end
    table.insert(raceState.historicTimes, lapInfo)
    raceState.currentTimes = {}
  end
end

local vecY = vec3(0, 1, 0)
local tmpFacing2d = vec3()
local tmpTravel2d = vec3()
local function checkPathnodeReached(pathnodes, crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.active or not state.crawlerData then
    return
  end

  local vehCenter = state.crawlerData.dynamicData.bbCenter
  if not vehCenter then
    return
  end

  local currentIndex = state.currentPathnodeIndex or 1
  if currentIndex > #pathnodes then
    return
  end

  local reachedPathnodeIndex = nil
  local skippedCheckpoints = 0

  local vehDirection = state.crawlerData.dynamicData.vehDirectionVector
  local vehVelocity = state.crawlerData.dynamicData.vehVelocity
  local vehSpeedSq = vehVelocity:squaredLength()

  -- Only check pathnodes near current index (current-1 to current+1 for skipping ahead)
  -- This avoids checking all pathnodes every frame
  local startIdx = math.max(1, currentIndex - 1)
  -- without penalties gates must be passed in order, only bonus gates can be skipped
  local currentNode = pathnodes[currentIndex]
  local canSkip = hasPenalties(crawlerId) or (currentNode.flags and currentNode.flags.isBonusCheckpoint)
  local endIdx = math.min(#pathnodes, currentIndex + (canSkip and 1 or 0))

  for i = startIdx, endIdx do
    local pathnode = pathnodes[i]
    if pathnode and pathnode.pos then
      local radius = pathnode.radius or 4.0
      local radiusSq = radius * radius

      -- 2D (XY) cylindrical check so Z variation on uneven terrain doesn't shrink the effective radius.
      -- Only the vehicle's actual center needs to pass through the gate/checkpoint.
      local dx = vehCenter.x - pathnode.pos.x
      local dy = vehCenter.y - pathnode.pos.y

      if dx * dx + dy * dy <= radiusSq then
        -- Skip if already completed and no rotation (no direction check needed)
        if state.completedPathnodes and state.completedPathnodes[i] and not pathnode.rotation then
          goto continue
        end
        -- Check direction if pathnode has rotation
        -- Must check approach direction, vehicle rotation (facing), and velocity (travel direction)
        local directionValid = true
        if pathnode.rotation then
          local pathnodeForward = pathnode._forward2d
          if not pathnodeForward then
            pathnodeForward = vec3()
            pathnodeForward:setRotate(pathnode.rotation, vecY)
            pathnodeForward.z = 0
            if pathnodeForward:squaredLength() > 1e-8 then
              pathnodeForward:normalize()
            else
              pathnodeForward:set(0, 1, 0)
            end
            pathnode._forward2d = pathnodeForward
          end

          -- Check vehicle facing direction matches pathnode direction
          tmpFacing2d:set(vehDirection.x, vehDirection.y, 0)
          local facingValid = tmpFacing2d:squaredLength() > 1e-8
          if facingValid then
            tmpFacing2d:normalize()
            facingValid = pathnodeForward:dot(tmpFacing2d) > 0.5
          end

          -- Velocity direction check only at speeds where it is reliable (crawl terrain is noisy at low speed)
          local velocityValid = true
          if vehSpeedSq > 1.0 then
            tmpTravel2d:set(vehVelocity.x, vehVelocity.y, 0)
            if tmpTravel2d:squaredLength() > 1e-8 then
              tmpTravel2d:normalize()
              velocityValid = pathnodeForward:dot(tmpTravel2d) > 0.5
            end
          end

          directionValid = facingValid and velocityValid
        end

        -- Only process pathnode if direction is valid (or if no rotation is set)
        if directionValid then
          if not state.completedPathnodes then
            state.completedPathnodes = {}
          end

          if not state.completedPathnodes[i] then
            state.completedPathnodes[i] = true
            state.lastReachedPathnodeIndex = i
            state.pathnodeTimings = state.pathnodeTimings or {}
            state.pathnodeTimings[i] = state.currentTime

            if pathnode.flags and pathnode.flags.isRecoveryCheckpoint then
              state.lastRecoveryCheckpoint = {
                position = pathnode.pos,
                rotation = pathnode.rotation or quat(0, 0, 0, 1),
                index = i,
                time = state.currentTime
              }
              state.lastRecoveryCheckpointIndex = i
            end

            local penaltyReduction = math.abs(infractionPoints.gateCleared)
            applyPenalty(crawlerId, 'gateCleared')
            gameplay_crawl_display.showGateClearedMessage(penaltyReduction, crawlerId)

            if pathnode.flags and pathnode.flags.isBonusCheckpoint then
              local bonusReduction = math.abs(infractionPoints.bonusGateCleared)
              applyPenalty(crawlerId, 'bonusGateCleared')
              gameplay_crawl_display.showBonusCheckpointMessage(bonusReduction, crawlerId)
            end

            if i > currentIndex then
              skippedCheckpoints = 0
              if not state.skippedPathnodes then
                state.skippedPathnodes = {}
              end

              for skippedIdx = currentIndex, i - 1 do
                local skippedPathnode = pathnodes[skippedIdx]
                if skippedPathnode and not (skippedPathnode.flags and skippedPathnode.flags.isBonusCheckpoint) then
                  skippedCheckpoints = skippedCheckpoints + 1
                  -- Mark as skipped for visual indication
                  state.skippedPathnodes[skippedIdx] = true
                end
              end

              if skippedCheckpoints > 0 then
                gameplay_crawl_display.showSkippedCheckpointsMessage(skippedCheckpoints, crawlerId)
                applyPenalty(crawlerId, 'skippedCheckpoint', skippedCheckpoints * infractionPoints.skippedCheckpoint)
              end

              for skippedIdx = currentIndex, i - 1 do
                local skippedPathnode = pathnodes[skippedIdx]
                if skippedPathnode then
                  state.completedPathnodes[skippedIdx] = true
                  state.pathnodeTimings[skippedIdx] = state.currentTime
                end
              end
            end

            if core_lapTimes and state.raceData then
              updateRaceDataStructure(crawlerId, state, state.raceData)
              core_lapTimes.updateSlowFromRace(state.raceData, crawlerId)
            end

            reachedPathnodeIndex = i
            gameplay_crawl_display.showGateReachedMessage(crawlerId)
            break
          end
        end -- Close if directionValid then
      end
      ::continue::
    end
  end

  if reachedPathnodeIndex then
    state.progressVersion = (state.progressVersion or 0) + 1
    if reachedPathnodeIndex == #pathnodes then
      state.isCompleted = true
      state.completionStartTime = state.currentTime
      updateCrawlMarkerModes()
      showCompletionResults(crawlerId)
      gameplay_achievement.unlockAchievement("CHALLENGE_CRAWL")

      -- Update lap times when crawl completes
      if core_lapTimes and state.raceData then
        updateRaceDataStructure(crawlerId, state, state.raceData)
        core_lapTimes.updateSlowFromRace(state.raceData, crawlerId)
        -- Only stop the shared timer if no other crawler is still active on the trail.
        if isSoleActiveCrawler(crawlerId) then
          core_lapTimes.onRaceStop()
        end
      end
    else
      state.currentPathnodeIndex = reachedPathnodeIndex + 1
    end
  end
end

local function stopCrawl(force)
  local shouldClear = true

  if not force then
    for crawlerId, state in pairs(crawlStates) do
      if state and state.active and state.isFromMission then
        shouldClear = false
        break
      end
    end
  end

  -- Stop lap times tracking
  if core_lapTimes and shouldClear then
    core_lapTimes.onRaceStop()
  end

  if shouldClear then
    if gameplay_crawl_boundary and gameplay_crawl_boundary.clearAllExitPoints then
      gameplay_crawl_boundary.clearAllExitPoints()
    end

    clear(force)
  end
end

local function finishCrawler(crawlerId)
  gameplay_crawl_display.clearPointsMessage(crawlerId)
  if gameplay_crawl_boundary and gameplay_crawl_boundary.clearCrawlerExitPoint then
    gameplay_crawl_boundary.clearCrawlerExitPoint(crawlerId)
  end
  clearCrawler(crawlerId)
  local list = gameplay_crawl_general.crawlersData
  if list then
    for i = #list, 1, -1 do
      if list[i] and list[i].id == crawlerId then
        table.remove(list, i)
      end
    end
  end
  if next(crawlStates) == nil then
    stopCrawl(true)
  end
end

local function startCrawl(crawlerId, trail, crawlerData, isFromMission)
  if not crawlerId or not trail then
    log('E', logTag, 'Invalid parameters for startCrawl')
    return false
  end

  local state = {
    active = true,
    trail = trail,
    crawlerData = crawlerData,
    currentPathnodeIndex = 1,
    completedPathnodes = {},
    skippedPathnodes = {}, -- Track nodes that were skipped
    pathnodeTimings = {},
    eventLog = {},
    currentTime = 0,
    isCompleted = false,
    completionStartTime = 0,
    events = {},
    crawlStarted = true,
    lastRecoveryCheckpoint = nil,
    lastRecoveryCheckpointIndex = 0,
    lastReachedPathnodeIndex = 0,
    isDisqualified = false,
    recoveryCount = 0,
    isFromMission = isFromMission or false,
    raceData = nil, -- Race data structure for lap times app
    pendingTeleportCheck = false, -- Flag to check for teleport in next frame
    teleportCheckPos = nil, -- Position to check against for teleport detection
    progressVersion = 0,
  }

  crawlStates[crawlerId] = state

  local path = gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.path

  if path and path.nodes and #path.nodes > 0 then
    setupCrawlMarkers(path)
    activateCrawlMarkers()
    syncMarkerSetMode()

    gameplay_crawl_display.showStartedCrawlMessage(crawlerId)
    gameplay_crawl_display.showPointsMessage(crawlerData.points or 0, crawlerId)
    state.events.crawlStarted = true

    -- Initialize lap times system and create race data structure
    if core_lapTimes then
      local path = gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.path
      if path and path.nodes then
        -- core_lapTimes is a single global race timer/HUD. In split-screen, additional players
        -- join an already-running trail; only the first active crawler should (re)configure and
        -- start it, or every join would reset the timer/lap data for everyone already crawling.
        if isSoleActiveCrawler(crawlerId) then
          core_lapTimes.setConfiguration({
            totalLaps = 1,
            totalSegments = #path.nodes,
            closedCircuit = false
          })
          core_lapTimes.onRaceStart({
            totalLaps = 1,
            totalSegments = #path.nodes,
            pathConfig = { isClosed = false }
          })
        end
        -- Create race data structure once
        state.raceData = createRaceDataStructure(crawlerId, state, path)
        core_lapTimes.updateStaticFromRace(state.raceData, crawlerId)
      end
    end

    return true
  else
    log('E', logTag, 'No valid path for trail')
    return false
  end
end

local function resetCrawlData(crawlerId, force)
  if not crawlerId then
    return false
  end

  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return false
  end

  if state.isFromMission and not force then
    log('W', logTag, 'Cannot reset mission crawl - use flowgraph node instead')
    return false
  end

  state.currentPathnodeIndex = 1
  state.completedPathnodes = {}
  state.skippedPathnodes = {}
  state.lastReachedPathnodeIndex = 0
  state.pathnodeTimings = {}
  state.eventLog = {}
  state.currentTime = 0
  state.isCompleted = false
  state.completionStartTime = 0
  state.events = {}
  state.crawlStarted = false
  state.isDisqualified = false
  state.recoveryCount = 0
  state.progressVersion = (state.progressVersion or 0) + 1

  if state.crawlerData then
    state.crawlerData.points = 0
    if state.crawlerData.infractionData then
      state.crawlerData.infractionData.drivingBackwardsCooldown = 0
      state.crawlerData.infractionData.drivingBackwardsDistance = 0
      state.crawlerData.infractionData.boundaryViolationCooldown = 0
      state.crawlerData.infractionData.recentlyRecovered = false
      state.crawlerData.infractionData.recoveryCooldown = 0
      if not state.crawlerData.infractionData.cooldowns then
        state.crawlerData.infractionData.cooldowns = {}
      end
      if not state.crawlerData.infractionData.violations then
        state.crawlerData.infractionData.violations = {}
      end
    else
      state.crawlerData.infractionData = {
        drivingBackwardsCooldown = 0,
        drivingBackwardsDistance = 0,
        boundaryViolationCooldown = 0,
        recentlyRecovered = false,
        recoveryCooldown = 0,
        cooldowns = {},
        violations = {}
      }
    end
  end

  gameplay_crawl_display.clearPointsMessage(crawlerId)
  gameplay_crawl_display.showPointsMessage(0, crawlerId)

  if gameplay_crawl_boundary and gameplay_crawl_boundary.clearCrawlerExitPoint then
    gameplay_crawl_boundary.clearCrawlerExitPoint(crawlerId)
  end

  -- Clear lap times app when resetting
  if core_lapTimes then
    core_lapTimes.onRaceStop()
  end

  return true
end

local function digestCrawlEvents(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.events then
    return
  end

  local events = state.events

  if events.pathnodeReached then
    table.insert(state.eventLog, {
      type = 'pathnodeReached',
      pathnodeId = events.pathnodeReachedId,
      pathnodeIndex = events.pathnodeReachedIndex,
      time = state.currentTime
    })

    extensions.hook("onCrawlPathnodeReached", {
      crawlerId = crawlerId,
      pathnodeId = events.pathnodeReachedId,
      pathnodeIndex = events.pathnodeReachedIndex,
      time = state.currentTime,
      pathnodeTimings = state.pathnodeTimings
    })

    events.pathnodeReached = false
    events.pathnodeReachedId = nil
    events.pathnodeReachedIndex = nil
  end

  if events.crawlStarted then
    table.insert(state.eventLog, {
      type = 'crawlStarted',
      time = state.currentTime
    })

    events.crawlStarted = false
  end

  if events.disqualified then
    table.insert(state.eventLog, {
      type = 'disqualified',
      time = state.disqualificationTime
    })

    extensions.hook("showDisqualifiedMessage", {
      crawlerId = crawlerId,
      time = state.disqualificationTime
    })

    clear(true)

    events.disqualified = false
    events.disqualificationTime = nil
  end
end

local function setupCrawlerData(veh)
  if not veh then
    log('E', logTag, 'No vehicle available, cannot setup crawler data')
    return
  end
  local cD = {
    id = veh:getID(),
    isPlayable = true,
    isDesc = false,
    descReason = "None",
    isFinished = false,
    lastPoints = 0,
    points = 0,
    time = 0,
    dynamicData = {
      vehPos = vec3(),
      vehDirectionVector = vec3(),
      vehDirectionVectorUp = vec3(),
      vehRot = quat(),
      vehVelocity = vec3(),
      vehObj = veh,
      bbCenter = vec3(),
      wheelOffsets = {},
      currentCorners = {},
    },
    infractionData = {
      drivingBackwardsCooldown = 0,
      drivingBackwardsDistance = 0,
      boundaryViolationCooldown = 0,
      recentlyRecovered = false,
      recoveryCooldown = 0,
    }
  }
  cD.dynamicData.oobb = cD.dynamicData.vehObj:getSpawnWorldOOBB()

  local wCount = veh:getWheelCount()-1
  if wCount > 0 then
    local vehiclePos = veh:getPosition()
    local vRot = quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
    local x,y,z = vRot * vec3(1,0,0),vRot * vec3(0,1,0),vRot * vec3(0,0,1)
    for i=0, wCount do
      local axisNodes = veh:getWheelAxisNodes(i)
      local nodePos = vec3(veh:getNodePosition(axisNodes[1]))
      local pos = vec3(nodePos:dot(x), nodePos:dot(y), nodePos:dot(z))
      table.insert(cD.dynamicData.wheelOffsets, pos)
      table.insert(cD.dynamicData.currentCorners, vRot*pos + vehiclePos)
    end
  end

  core_vehicleBridge.registerValueChangeNotification(veh, "accZSmooth")
  return cD
end

local function updateCrawlerData(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return
  end

  local veh = state.crawlerData.dynamicData.vehObj
  if not veh then
    return
  end

  -- Store previous position before updating (for teleport detection)
  if not state.crawlerData.dynamicData.prevVehPos then
    state.crawlerData.dynamicData.prevVehPos = vec3()
  end
  state.crawlerData.dynamicData.prevVehPos:set(state.crawlerData.dynamicData.vehPos)

  -- Check for pending teleport check (from trackVehReset hook)
  if state.pendingTeleportCheck and state.teleportCheckPos then
    local currentPos = vec3(veh:getPositionXYZ())
    local teleportThreshold = 1.0
    local distance = currentPos:distance(state.teleportCheckPos)

    if distance > teleportThreshold then
      -- Vehicle actually teleported, apply penalty
      M.onVehicleReset(crawlerId)
    end
    -- Clear the pending check
    state.pendingTeleportCheck = false
    state.teleportCheckPos = nil
  end

  state.crawlerData.dynamicData.vehPos:set(veh:getPositionXYZ())
  state.crawlerData.dynamicData.vehDirectionVector:set(veh:getDirectionVectorXYZ())
  state.crawlerData.dynamicData.vehDirectionVectorUp:set(veh:getDirectionVectorUpXYZ())
  state.crawlerData.dynamicData.vehVelocity:set(veh:getVelocityXYZ())
  state.crawlerData.dynamicData.bbCenter:set(be:getObjectOOBBCenterXYZ(crawlerId))

  local vehPos = state.crawlerData.dynamicData.vehPos
  local vehDir = state.crawlerData.dynamicData.vehDirectionVector
  local vehDirUp = state.crawlerData.dynamicData.vehDirectionVectorUp
  local vehRot = state.crawlerData.dynamicData.vehRot
  vehRot:setFromDir(vehDir, vehDirUp)

  for i, corner in ipairs(state.crawlerData.dynamicData.wheelOffsets) do
    state.crawlerData.dynamicData.currentCorners[i]:setRotate(vehRot, corner)
    state.crawlerData.dynamicData.currentCorners[i]:setAdd(vehPos)
  end
end

local tmp1, tmp2 = vec3(), vec3()
local function checkInfractions(crawlerId, dtSim)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return
  end

  local infractionData = state.crawlerData.infractionData
  local vehicleData = map and map.objects and map.objects[crawlerId]
  infractionData.drivingBackwardsCooldown = infractionData.drivingBackwardsCooldown - dtSim
  infractionData.boundaryViolationCooldown = infractionData.boundaryViolationCooldown - dtSim
  infractionData.recoveryCooldown = infractionData.recoveryCooldown - dtSim

  tmp1:set(state.crawlerData.dynamicData.vehDirectionVector)
  tmp2:set(state.crawlerData.dynamicData.vehVelocity)
  tmp1.z = 0
  tmp2.z = 0
  local dot = tmp1:dot(tmp2)
  if dot < drivingBackwardsSettings.velocityDotThreshold then
    -- Don't apply driving backwards penalty if recently recovered to checkpoint
    if infractionData.recoveryCooldown <= 0 then
      if infractionData.drivingBackwardsCooldown <= 0 then
        infractionData.drivingBackwardsDistance = infractionData.drivingBackwardsDistance + dtSim * math.abs(dot)
        if infractionData.drivingBackwardsDistance > drivingBackwardsSettings.distanceThreshold then
          gameplay_crawl_display.showDrivingBackwardsMessage(crawlerId)
          infractionData.drivingBackwardsCooldown = infractionCooldowns.drivingBackwards
          applyPenalty(crawlerId, 'drivingBackwards')
        end
      end
    end
  else
    infractionData.drivingBackwardsDistance = infractionData.drivingBackwardsDistance - dtSim * math.abs(dot)
    if infractionData.drivingBackwardsDistance < 0 then
      infractionData.drivingBackwardsDistance = 0
    end
  end

  local objectCollisions = vehicleData and vehicleData.objectCollisions
  if objectCollisions then
    for _, objId in ipairs(dynamicObjects) do
      local collisionData = dynamicObjectCollisionData[objId]
      if collisionData and not collisionData.hasBeenTouched and objectCollisions[objId] == 1 then
        applyPenalty(crawlerId, 'gateTouch')
        collisionData.hasBeenTouched = true
      end
    end
  end
end

local function onVehicleFlippedUpright(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return
  end
  applyPenalty(crawlerId, 'vehicleFlippedUpright')
  gameplay_crawl_display.showVehicleFlippedUprightMessage(crawlerId)
end

local function onVehicleReset(crawlerId, isGateRecovery)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return
  end

  state.recoveryCount = (state.recoveryCount or 0) + 1

  if isGateRecovery then
    state.pendingTeleportCheck = false
    state.teleportCheckPos = nil
    state.crawlerData.infractionData.recentlyRecovered = true
    state.crawlerData.infractionData.recoveryCooldown = 5.0
    applyPenalty(crawlerId, 'vehicleReset')
    gameplay_crawl_display.showVehicleRecoveredMessage(crawlerId)
  elseif state.isFromMission then
    applyPenalty(crawlerId, 'vehicleFlippedUpright')
    gameplay_crawl_display.showVehicleFlippedUprightMessage(crawlerId)
  else
    applyPenalty(crawlerId, 'dnf', getDnfThreshold(state))
    gameplay_crawl_display.showDNFMessage(crawlerId)
  end
end

local function getGateRecoveryRotation(nodes, index)
  local node = nodes[index]
  if node.rotation then return quat(node.rotation) end

  local otherNode = nodes[index + 1] or nodes[index - 1]
  if otherNode and otherNode.pos then
    local dir = nodes[index + 1] and (otherNode.pos - node.pos) or (node.pos - otherNode.pos)
    dir.z = 0
    if dir:squaredLength() > 0.25 then
      return quatFromDir(dir:normalized(), vec3(0, 0, 1))
    end
  end
  return quat(0, 0, 0, 1)
end

local function getLastGateRecoveryTransform(state)
  local activeTrail = gameplay_crawl_general.activeTrail
  local nodes = activeTrail and activeTrail.path and activeTrail.path.nodes
  if not nodes or #nodes == 0 then return nil, nil end

  local gateIndex = state.lastReachedPathnodeIndex or 0
  local gate = gateIndex > 0 and nodes[gateIndex] or nil
  if gate and gate.pos then
    return vec3(gate.pos), getGateRecoveryRotation(nodes, gateIndex)
  end

  local transform = activeTrail.startingPosition and activeTrail.startingPosition.transform
  if not transform or not transform.position then return nil, nil end
  return vec3(transform.position), quat(transform.rotation or quat(0, 0, 0, 1))
end

local function recoverToLastGate(crawlerId)
  local state = crawlStates[crawlerId]
  local recoveryRules = getCrawlRecoveryRules(state)
  if not recoveryRules or not state.active or state.isCompleted or state.isDisqualified then
    return false
  end

  local veh = state.crawlerData and state.crawlerData.dynamicData and state.crawlerData.dynamicData.vehObj
  local pos, rot = getLastGateRecoveryTransform(state)
  if not veh or not pos or not rot then return false end

  onVehicleReset(crawlerId, true)
  local player = getPlayerIndexForCrawler(crawlerId)
  spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, recoveryRules.repairVehicle ~= false, player)
  if player ~= nil and core_camera then core_camera.resetCamera(player) end
  return true
end

local function applyDNF(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.active or not state.crawlerData then
    return
  end

  if state.isDisqualified then
    return
  end

  gameplay_crawl_display.showDNFMessage(crawlerId)

  local lastRecoveryIndex = state.lastRecoveryCheckpointIndex or 0
  if lastRecoveryIndex > 0 then
    state.currentPathnodeIndex = lastRecoveryIndex
    state.completedPathnodes = {}
    for i = 1, lastRecoveryIndex do
      state.completedPathnodes[i] = true
    end
  else
    state.currentPathnodeIndex = 1
    state.completedPathnodes = {}
  end

  state.progressVersion = (state.progressVersion or 0) + 1
  state.isDisqualified = true

  extensions.hook("onCrawlDisqualified", { crawlerId = crawlerId })

  if not state.isFromMission then
    if not isSoleActiveCrawler(crawlerId) then
      gameplay_crawl_display.showDisqualifiedWaitingMessage(crawlerId)
    end
    finishCrawler(crawlerId)
  end
end

local function onBoundaryViolation(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return
  end

  local infractionData = state.crawlerData.infractionData
  if infractionData.boundaryViolationCooldown > 0 then
    return
  end

  applyPenalty(crawlerId, 'boundaryViolation')
  infractionData.boundaryViolationCooldown = infractionCooldowns.boundaryViolation
  gameplay_crawl_display.showBoundaryViolationMessage(crawlerId)
end


local function updateCrawl(dtSim)
  gameplay_crawl_boundary.updateBoundaryAnimations(dtSim, crawlStates)

  for crawlerId, state in pairs(crawlStates) do
    if not state or not state.active or not state.crawlStarted then
      goto continue
    end

    state.currentTime = state.currentTime + dtSim
    updateCrawlerData(crawlerId)

    local path = gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.path
    local boundary = gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.boundary

    if path and path.nodes then
      checkPathnodeReached(path.nodes, crawlerId)
    end

    if boundary then
      gameplay_crawl_boundary.checkBoundary(boundary, state.crawlerData, crawlStates)
    end

    checkInfractions(crawlerId, dtSim)
    digestCrawlEvents(crawlerId)

    -- Update lap times fast stream (every frame) - just update existing structure
    if core_lapTimes and state.raceData then
      updateRaceDataStructure(crawlerId, state, state.raceData)
      core_lapTimes.updateFastFromRace(state.raceData, crawlerId)
    end

    if state.crawlerData.points ~= state.crawlerData.lastPoints then
      gameplay_crawl_display.showPointsMessage(state.crawlerData.points, crawlerId)
      state.crawlerData.lastPoints = state.crawlerData.points

      if state.crawlerData.points >= getDnfThreshold(state) and not state.isDisqualified then
        applyDNF(crawlerId)
      end
    end

    if state.completionStartTime > 0 then
      local elapsed = state.currentTime - state.completionStartTime
      if elapsed >= completionDelay and not state.isFromMission then
        finishCrawler(crawlerId)
      end
    end

    ::continue::
  end

  -- Update lap times system (sends data to UI)
  if core_lapTimes then
    core_lapTimes.onUpdate(0, dtSim, 0)
  end
end

local function drawMarkers(dtReal, dtSim, dtRaw)
  if markersVisibleForPath == nil then
    return
  end

  updateCrawlMarkerModes()

  if markerSetMode == "split" then
    if photoModeOpen then
      for _, markerSet in pairs(markerSets) do
        for _, marker in pairs(markerSet.markers) do
          marker:hide()
        end
      end
      markerPhotoModeOpen = true
      return
    end

    if markerPhotoModeOpen then
      markerPhotoModeOpen = false
      for _, markerSet in pairs(markerSets) do
        for name, marker in pairs(markerSet.markers) do
          marker:setMode(markerSet.modes[name] or "hidden")
        end
      end
    end

    for _, markerSet in pairs(markerSets) do
      for _, marker in pairs(markerSet.markers) do
        marker:update(dtReal, dtSim)
      end
    end
  elseif markers then
    markers.render(dtReal, dtSim)
  end
end

local function onDrawOnMinimap(td)
  if markerSetMode == "split" then
    local markerSet = markerSets[be:getPlayerVehicleID(0)]
    if not markerSet then return end
    for _, marker in pairs(markerSet.markers) do
      marker:drawOnMinimap(td)
    end
  elseif markers then
    markers.drawOnMinimap(td)
  end
end

local function onSplitScreenChanged(enabled, _playerCount, _layoutId, layoutMode)
  if markersVisibleForPath == nil then return end
  rebuildMarkerSets(enabled and layoutMode or "shared")
end

-- Dev-only overlay: clear waypoint/segment/boundary visualization for the active trail.
local function drawDebugOverlay()
  local activeTrail = gameplay_crawl_general and gameplay_crawl_general.activeTrail
  if not activeTrail then return end

  if activeTrail.path and activeTrail.path.nodes then
    crawlDebugDraw.drawPath(activeTrail.path.nodes, { showSegmentDistance = true })
  end
  if activeTrail.boundary then
    crawlDebugDraw.drawBoundary(activeTrail.boundary)
  end
  if activeTrail.startingPosition then
    crawlDebugDraw.drawStartingPosition(activeTrail.startingPosition)
  end
end

-- While paused, show the preview dots from the player vehicle to the remaining checkpoints.
local function updatePauseGuidance(dtReal)
  if isPreviewMode or photoModeOpen or not simTimeAuthority.getPause() then
    pauseGuidanceActive = false
    return
  end

  if not pauseGuidanceActive then
    local veh = getPlayerVehicle(0)
    local state = veh and crawlStates[veh:getID()]
    local activeTrail = gameplay_crawl_general.activeTrail
    local pathnodes = activeTrail and activeTrail.path and activeTrail.path.nodes
    if not state or not state.active or state.isCompleted or not pathnodes then return end
    buildDottedPath(veh:getPosition(), pathnodes, state.currentPathnodeIndex)
    pauseGuidanceActive = true
  end

  onPreviewUpdate(dtReal)
end

local function onPreRender(dtReal, dtSim, dtRaw)
  if not crawlStates then
    return
  end
  drawMarkers(dtReal, dtSim, dtRaw)
  if isPreviewMode then
    onPreviewUpdate(dtSim)
  end
  updatePauseGuidance(dtReal)
  if debugDrawEnabled then
    drawDebugOverlay()
  end
end

M.setDebugDraw = function(enabled)
  debugDrawEnabled = enabled and true or false
  return debugDrawEnabled
end

M.toggleDebugDraw = function()
  debugDrawEnabled = not debugDrawEnabled
  return debugDrawEnabled
end

M.isDebugDrawEnabled = function()
  return debugDrawEnabled
end

local function calculatePathStats(pathId, pathReversed)
  if not pathId then
    return nil
  end

  if pathStatsCache[pathId] then
    return pathStatsCache[pathId]
  end

  local path = gameplay_crawl_saveSystem.getPathById(pathId)
  if not path or not path.nodes or #path.nodes < 2 then
    return nil
  end

  local totalDistance = 0
  local totalElevationChange = 0
  local stepDistance = 5.0

  local pathnodes = path.nodes
  local pathPositions = {}

  for i, pn in ipairs(pathnodes) do
    if pathReversed then
      i = #pathnodes - i + 1
    end
    if pn.pos then
      table.insert(pathPositions, pn.pos)
    end
  end

  if #pathPositions < 2 then
    return nil
  end

  for i = 1, #pathPositions - 1 do
    local currentPos = pathPositions[i]
    local nextPos = pathPositions[i + 1]

    if currentPos and nextPos then
      local segmentLength = currentPos:distance(nextPos)
      local elevationChange = nextPos.z - currentPos.z

      local numSteps = math.max(1, math.floor(segmentLength / stepDistance))
      local stepSize = segmentLength / numSteps

      for step = 1, numSteps do
        totalDistance = totalDistance + stepSize
        totalElevationChange = totalElevationChange + (elevationChange / numSteps)
      end
    end
  end

  local stats = {
    totalDistance = totalDistance,
    totalElevationChange = totalElevationChange,
    elevationGain = math.max(0, totalElevationChange),
    elevationLoss = math.abs(math.min(0, totalElevationChange))
  }

  pathStatsCache[pathId] = stats


  return stats
end

local function resumeCrawlTimer(crawlerId)
  if not crawlerId then
    return false
  end

  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return false
  end

  if state.crawlStarted then
    return true
  end

  state.crawlStarted = true
  state.events.crawlStarted = true
  gameplay_crawl_display.showStartedCrawlMessage(crawlerId)
  if state.crawlerData then
    gameplay_crawl_display.showPointsMessage(state.crawlerData.points or 0, crawlerId)
  end

  return true
end

local function onSpawnCCallback(objId)
  if not spawningPrefabs or not objId then return end
  local obj = scenetree.findObjectById(objId)
  if obj then
    obj:setDynDataFieldbyName("autoEnterVehicle", 0, "false")
  end
end

M.startCrawl = startCrawl
M.stopCrawl = stopCrawl
M.resetCrawlData = resetCrawlData
M.resumeCrawlTimer = resumeCrawlTimer
M.updateCrawl = updateCrawl
M.drawMarkers = drawMarkers
M.clearMarkers = clearMarkers
M.clear = clear
M.clearCrawler = clearCrawler
M.loadPrefabs = loadPrefabs
M.unloadPrefabs = unloadPrefabs
M.setupCrawlerData = setupCrawlerData
M.onPreRender = onPreRender
M.onDrawOnMinimap = onDrawOnMinimap
M.onSplitScreenChanged = onSplitScreenChanged
M.onSpawnCCallback = onSpawnCCallback
M.onVehicleFlippedUpright = onVehicleFlippedUpright
M.onVehicleReset = onVehicleReset
M.onBoundaryViolation = onBoundaryViolation
M.calculatePathStats = calculatePathStats
M.setupCrawlMarkers = setupCrawlMarkers
M.activateCrawlMarkers = activateCrawlMarkers
M.getDynamicObjectsFromPrefab = getDynamicObjectsFromPrefab

M.getCrawlState = function(crawlerId)
  return crawlStates[crawlerId]
end

M.getCrawlerPosition = function(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return nil
  end
  return state.crawlerData.dynamicData.vehPos
end

M.getCrawlerDirection = function(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return quat(0, 0, 0, 1)
  end

  local veh = state.crawlerData.dynamicData.vehObj
  if not veh then
    return quat(0, 0, 0, 1)
  end

  local vehicleRotation = veh:getRotation()
  local yaw = math.atan2(vehicleRotation.y, vehicleRotation.w) * 2
  return quat(math.cos(yaw * 0.5), 0, 0, math.sin(yaw * 0.5))
end

M.setCrawlState = function(crawlerId, state)
  if crawlerId and state then
    crawlStates[crawlerId] = state
    return true
  end
  return false
end

M.getAllCrawlStates = function()
  return crawlStates
end

M.getActiveCrawlerId = function()
  for crawlerId, state in pairs(crawlStates) do
    if state and state.active then
      return crawlerId
    end
  end
  return nil
end

M.isPreviewMode = function()
  return isPreviewMode
end

M.getDottedPath = function()
  return dottedPath
end

local function getLastRecoveryCheckpoint(crawlerId)
  if not crawlerId then
    return nil
  end

  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return nil
  end

  return state.lastRecoveryCheckpoint
end

local function getLastRecoveryCheckpointIndex(crawlerId)
  if not crawlerId then
    return 0
  end

  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return 0
  end

  return state.lastRecoveryCheckpointIndex
end

local function setRecoveryCheckpoint(crawlerId, checkpoint)
  if not crawlerId or not checkpoint then
    return false
  end

  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return false
  end

  state.lastRecoveryCheckpoint = checkpoint
  state.lastRecoveryCheckpointIndex = checkpoint.index or 0

  if state.crawlerData and state.crawlerData.infractionData then
    state.crawlerData.infractionData.recentlyRecovered = true
    state.crawlerData.infractionData.recoveryCooldown = 5.0
  end

  return true
end

M.infractionPoints = infractionPoints
M.infractionCooldowns = infractionCooldowns
M.drivingBackwardsSettings = drivingBackwardsSettings
M.getLastRecoveryCheckpoint = getLastRecoveryCheckpoint
M.getLastRecoveryCheckpointIndex = getLastRecoveryCheckpointIndex
M.setRecoveryCheckpoint = setRecoveryCheckpoint
M.applyPenalty = applyPenalty
M.hasPenalties = hasPenalties
M.onVehicleReset = onVehicleReset
M.recoverToLastGate = recoverToLastGate
local originalDropPlayerAtCameraNoReset = commands.dropPlayerAtCameraNoReset
if originalDropPlayerAtCameraNoReset then
  commands.dropPlayerAtCameraNoReset = function(player)
    for crawlerId, state in pairs(crawlStates) do
      if state and state.active then
        onVehicleReset(crawlerId)
      end
    end
    return originalDropPlayerAtCameraNoReset(player)
  end
end

local function getCrawlerForRecentInput()
  local inputBindings = extensions and extensions.core_input_bindings
  if not inputBindings or not inputBindings.getRecentDevices
    or not inputBindings.getAssignedPlayers then
    return nil, nil
  end

  local recentDevices = inputBindings.getRecentDevices() or {}
  local assignedPlayers = inputBindings.getAssignedPlayers() or {}
  local device = recentDevices[1]
  local player = device and assignedPlayers[device]
  if player == nil or player < 0 then return nil, nil end

  local crawlerId = be:getPlayerVehicleID(player)
  local state = crawlerId and crawlStates[crawlerId]
  if state and state.active then
    return crawlerId, state
  end

  return nil, nil
end

local function trackVehReset(vehId)
  local crawlerId, state
  if vehId then
    vehId = tonumber(vehId) or vehId
    state = crawlStates[vehId]
    if state and state.active then
      crawlerId = vehId
    end
  else
    crawlerId, state = getCrawlerForRecentInput()
  end
  local recoveryRules = getCrawlRecoveryRules(state)
  if recoveryRules then
    local crawlerData = state and state.crawlerData
    local dynamicData = crawlerData and crawlerData.dynamicData
    local veh = dynamicData and dynamicData.vehObj
    if not veh then return end

    local recoverCommand = string.format(
      "if gameplay_crawl_utils then gameplay_crawl_utils.recoverToLastGate(%d) end",
      crawlerId
    )
    veh:queueLuaCommand(string.format(
      "recovery.cancelRecoveringPreview(); obj:queueGameEngineLua(%q)",
      recoverCommand
    ))
    return
  end

  local function markTeleportCheck(id, crawlState)
    if not crawlState or not crawlState.active or not crawlState.crawlerData or getCrawlRecoveryRules(crawlState) then
      return
    end
    local dynamicData = crawlState.crawlerData.dynamicData
    local veh = dynamicData and dynamicData.vehObj
    if veh then
      crawlState.pendingTeleportCheck = true
      crawlState.teleportCheckPos = vec3(veh:getPositionXYZ())
    end
  end

  if vehId then
    markTeleportCheck(vehId, crawlStates[vehId])
    return
  end

  for id, crawlState in pairs(crawlStates) do
    markTeleportCheck(id, crawlState)
  end
end

M.trackVehReset = trackVehReset

local function onExtensionUnloaded()
  if originalDropPlayerAtCameraNoReset then
    commands.dropPlayerAtCameraNoReset = originalDropPlayerAtCameraNoReset
  end
end

M.onExtensionUnloaded = onExtensionUnloaded

return M