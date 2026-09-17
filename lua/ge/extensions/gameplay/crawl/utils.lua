-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "crawl_utils"

local gameplay_crawl_boundary = require('ge/extensions/gameplay/crawl/boundary')
local gameplay_crawl_display = require('ge/extensions/gameplay/crawl/display')
local crawlDebugDraw = require('ge/extensions/gameplay/crawl/debugDraw')
local recovery = require('vehicle/recovery')

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
local isPreviewMode = false
local pathStatsCache = {}
local dottedPath = {}
local dottedPathTimer = 0
local dynamicObjects = {}
local dynamicObjectCollisionData = {}
local debugDrawEnabled = false

local completionDelay = 3

local function applyPenalty(crawlerId, penaltyType, points)
  local state = crawlStates[crawlerId]
  if not state or not state.active then
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
  for _, id in ipairs(spawnedPrefabIds) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:delete()
    end
  end
  spawnedPrefabIds = {}
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

  for _, filePath in ipairs(prefabFileList or {}) do
    local _, fn = path.splitWithoutExt(filePath)
    local scenetreeObject = spawnPrefab(Sim.getUniqueName(fn), filePath, 0 .. " " .. 0 .. " " .. 0, "0 0 1 0", "1 1 1", false)
    scenetreeObject.canSave = false
    if scenetree.MissionGroup then
      scenetree.MissionGroup:add(scenetreeObject)
    end
    local prefabId = scenetreeObject:getID()
    table.insert(spawnedPrefabIds, prefabId)

    local prefabDynamicObjects = getDynamicObjectsFromPrefab(prefabId, "crawlDynamic")
    for _, objId in ipairs(prefabDynamicObjects) do
      table.insert(dynamicObjects, objId)
      dynamicObjectCollisionData[objId] = {
        hasBeenTouched = false
      }
    end
  end

  if gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.boundary then
    gameplay_crawl_boundary.spawnBoundaryMarkers(gameplay_crawl_general.activeTrail.boundary, 5.0)
  end
end

local function clearMarkers()
  if markers then
    markers.onClientEndMission()
    markers = nil
    markersVisibleForPath = nil
  end
  markerModes = {}
  isPreviewMode = false
end

local function clearCrawler(crawlerId)
  if not crawlerId then
    return
  end
  crawlStates[crawlerId] = nil
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
  end
end

local function onPreviewUpdate(dtSim)
  dottedPathTimer = dottedPathTimer + dtSim
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
      debugDrawer:drawSphere(pos.pos, radius, ColorF(1,1,1,1))
    end
  end
end

local function setupCrawlMarkers(path)
  local pathId = path._filePath or path.id or path._id or tostring(path)
  if markersVisibleForPath == pathId then
    return
  elseif markersVisibleForPath ~= nil then
    markers.onClientEndMission()
  end
  markersVisibleForPath = pathId

  if not markers then
    markers = require('scenario/race_marker')
    markers.init()
  end

  if not path then
    log('W', logTag, 'No path available for trail')
    return
  end

  local wps = {}
  local markerModes = {}
  for i, pn in ipairs(path.nodes or {}) do
    if pn.pos then
      local dir = vec3(0, 1, 0)
      if pn.rotation then
        dir = pn.rotation * vec3(0, 1, 0)
      end

      table.insert(wps, {
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

  markers.setupMarkers(wps,'crawlMarker')
  markers.setModes(markerModes)

  dottedPath = {}
  dottedPathTimer = -1
  local stepDist = 1.5

  if path and path.nodes and #path.nodes > 0 then
    local pathnodes = path.nodes
    local pathPositions = { be:getPlayerVehicle(0):getPosition()}
    for i, pn in ipairs(pathnodes) do
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

  isPreviewMode = false
end

local function updateCrawlMarkerModes(trail, crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.active then
    return
  end

  local currentIndex = state.currentPathnodeIndex
  local pathnodes = gameplay_crawl_general.activeTrail.path.nodes

  -- Dirty-flag: marker modes only change when the current index, completion/skip sets,
  -- or completed state change. Skip the rebuild + setModes call when nothing changed.
  local completedCount = state.completedPathnodes and tableSize(state.completedPathnodes) or 0
  local skippedCount = state.skippedPathnodes and tableSize(state.skippedPathnodes) or 0
  local sig = string.format("%d:%d:%d:%d", currentIndex or 0, completedCount, skippedCount, state.isCompleted and 1 or 0)
  if state._markerModeSig == sig then
    return
  end
  state._markerModeSig = sig

  local nodeCount = #pathnodes

  -- Initialize all markers as inactive
  for i = 1, nodeCount do
    markerModes[nodeKey(i)] = 'inactive'
  end

  -- Set final node
  markerModes[nodeKey(nodeCount)] = 'final'

  -- Set current/next node with special handling for recovery and bonus checkpoints
  if currentIndex <= nodeCount then
    local currentPathnode = pathnodes[currentIndex]
    if currentPathnode and currentPathnode.flags then
      -- Recovery checkpoints take priority (yellow)
      if currentPathnode.flags.isRecoveryCheckpoint then
        markerModes[nodeKey(currentIndex)] = 'recovery'
      -- Bonus checkpoints (purple)
      elseif currentPathnode.flags.isBonusCheckpoint then
        markerModes[nodeKey(currentIndex)] = 'bonus'
      else
        -- Normal next node (red)
        markerModes[nodeKey(currentIndex)] = 'current'
      end
    else
      -- Normal next node (red)
      markerModes[nodeKey(currentIndex)] = 'current'
    end
  end

  -- Mark completed nodes as finished (green)
  for pathnodeId, _ in pairs(state.completedPathnodes) do
    markerModes[nodeKey(pathnodeId)] = 'finished'
  end

  -- Mark skipped nodes (nodes that were skipped between current and reached)
  if state.skippedPathnodes then
    for skippedId, _ in pairs(state.skippedPathnodes) do
      -- Only mark as skipped if not completed (skipped nodes can be completed later)
      if not state.completedPathnodes[skippedId] then
        markerModes[nodeKey(skippedId)] = 'skipped'
      end
    end
  end

  -- Handle final node special cases
  if currentIndex == nodeCount then
    local finalPathnode = pathnodes[nodeCount]
    if finalPathnode and finalPathnode.flags then
      if finalPathnode.flags.isRecoveryCheckpoint then
        markerModes[nodeKey(currentIndex)] = 'recovery'
      elseif finalPathnode.flags.isBonusCheckpoint then
        markerModes[nodeKey(currentIndex)] = 'bonus'
      else
        markerModes[nodeKey(currentIndex)] = 'final'
      end
    else
      markerModes[nodeKey(currentIndex)] = 'final'
    end

    if state.isCompleted then
      markerModes[nodeKey(currentIndex)] = 'finished'
    end
  end

  markers.setModes(markerModes)
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
  gameplay_crawl_display.showCrawlCompletedMessage(completionTime, points)
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
  local timingCount = tableSize(state.pathnodeTimings or {})
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

  -- Cache vehicle data (doesn't change per pathnode)
  local vehPos = state.crawlerData.dynamicData.vehPos
  local vehDirection = state.crawlerData.dynamicData.vehDirectionVector:normalized()
  local vehVelocity = state.crawlerData.dynamicData.vehVelocity
  local vehSpeed = vehVelocity:length()
  local vehTravelDir = vehSpeed > 0.1 and vehVelocity:normalized() or nil

  -- Only check pathnodes near current index (current-1 to current+1 for skipping ahead)
  -- This avoids checking all pathnodes every frame
  local startIdx = math.max(1, currentIndex - 1)
  local endIdx = math.min(#pathnodes, currentIndex + 1)

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
          -- Cache the node's forward vector; rotation is fixed for the duration of a crawl.
          local pathnodeForward = pathnode._forward
          if not pathnodeForward then
            pathnodeForward = pathnode.rotation * vec3(0, 1, 0)
            pathnode._forward = pathnodeForward
          end

          -- Check vehicle facing direction matches pathnode direction
          local facingDot = pathnodeForward:dot(vehDirection)
          local facingValid = facingDot > 0.5

          -- Velocity direction check only at speeds where it is reliable (crawl terrain is noisy at low speed)
          local velocityValid = true
          if vehSpeed > 1.0 and vehTravelDir then
            local velocityDot = pathnodeForward:dot(vehTravelDir)
            velocityValid = velocityDot > 0.5
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
            state.pathnodeTimings = state.pathnodeTimings or {}
            state.pathnodeTimings[i] = state.currentTime

            -- Update lap times when pathnode is reached
            if core_lapTimes and state.raceData then
              updateRaceDataStructure(crawlerId, state, state.raceData)
              core_lapTimes.updateSlowFromRace(state.raceData, crawlerId)
            end

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
            gameplay_crawl_display.showGateClearedMessage(penaltyReduction)

            if pathnode.flags and pathnode.flags.isBonusCheckpoint then
              local bonusReduction = math.abs(infractionPoints.bonusGateCleared)
              applyPenalty(crawlerId, 'bonusGateCleared')
              gameplay_crawl_display.showBonusCheckpointMessage(bonusReduction)
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
                gameplay_crawl_display.showSkippedCheckpointsMessage(skippedCheckpoints)
                applyPenalty(crawlerId, 'skippedCheckpoint', skippedCheckpoints * infractionPoints.skippedCheckpoint)
              end

              for skippedIdx = currentIndex, i - 1 do
                local skippedPathnode = pathnodes[skippedIdx]
                if skippedPathnode then
                  state.completedPathnodes[skippedIdx] = true
                  state.pathnodeTimings[skippedIdx] = state.currentTime
                end
              end

              -- Update lap times after skipped checkpoints are processed
              if core_lapTimes and state.raceData then
                updateRaceDataStructure(crawlerId, state, state.raceData)
                core_lapTimes.updateSlowFromRace(state.raceData, crawlerId)
              end
            end

            reachedPathnodeIndex = i
            gameplay_crawl_display.showGateReachedMessage()
            break
          end
        end -- Close if directionValid then
      end
      ::continue::
    end
  end

  if reachedPathnodeIndex then
    if reachedPathnodeIndex == #pathnodes then
      state.isCompleted = true
      state.completionStartTime = state.currentTime
      updateCrawlMarkerModes(state.trail, crawlerId)
      showCompletionResults(crawlerId)
      gameplay_achievement.unlockAchievement("CHALLENGE_CRAWL")

      -- Update lap times when crawl completes
      if core_lapTimes and state.raceData then
        updateRaceDataStructure(crawlerId, state, state.raceData)
        core_lapTimes.updateSlowFromRace(state.raceData, crawlerId)
        core_lapTimes.onRaceStop()
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
    gameplay_crawl_display.clearPointsMessage()

    if gameplay_crawl_boundary and gameplay_crawl_boundary.clearAllExitPoints then
      gameplay_crawl_boundary.clearAllExitPoints()
    end

    clear(force)
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
    isDisqualified = false,
    recoveryCount = 0,
    isFromMission = isFromMission or false,
    raceData = nil, -- Race data structure for lap times app
    pendingTeleportCheck = false, -- Flag to check for teleport in next frame
    teleportCheckPos = nil -- Position to check against for teleport detection
  }

  crawlStates[crawlerId] = state

  local path = gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.path

  if path and path.nodes and #path.nodes > 0 then
    setupCrawlMarkers(path)
    activateCrawlMarkers()

    gameplay_crawl_display.showStartedCrawlMessage()
    gameplay_crawl_display.showPointsMessage(crawlerData.points or 0)
    state.events.crawlStarted = true

    -- Initialize lap times system and create race data structure
    if core_lapTimes then
      local path = gameplay_crawl_general.activeTrail and gameplay_crawl_general.activeTrail.path
      if path and path.nodes then
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
        -- Create race data structure once
        state.raceData = createRaceDataStructure(crawlerId, state, path)
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
  state.pathnodeTimings = {}
  state.eventLog = {}
  state.currentTime = 0
  state.isCompleted = false
  state.completionStartTime = 0
  state.events = {}
  state.crawlStarted = false
  state.isDisqualified = false
  state.recoveryCount = 0

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

  gameplay_crawl_display.clearPointsMessage()
  gameplay_crawl_display.showPointsMessage(0)

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
  state.crawlerData.dynamicData.vehDirectionVector:set(veh:getDirectionVector())
  state.crawlerData.dynamicData.vehDirectionVectorUp:set(veh:getDirectionVectorUp())
  state.crawlerData.dynamicData.vehRot:set(veh:getRotation())
  state.crawlerData.dynamicData.vehVelocity:set(veh:getVelocity())
  state.crawlerData.dynamicData.bbCenter:set(be:getObjectOOBBCenterXYZ(crawlerId))

  local vehPos = state.crawlerData.dynamicData.vehPos
  local vehDir = state.crawlerData.dynamicData.vehDirectionVector
  local vehDirUp = state.crawlerData.dynamicData.vehDirectionVectorUp
  local vehRot = quatFromDir(vehDir, vehDirUp)

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

  local veh = state.crawlerData.dynamicData.vehObj
  local infractionData = state.crawlerData.infractionData
  local vehicleData = map.objects[crawlerId]
  infractionData.drivingBackwardsCooldown = infractionData.drivingBackwardsCooldown - dtSim
  infractionData.boundaryViolationCooldown = infractionData.boundaryViolationCooldown - dtSim
  infractionData.recoveryCooldown = infractionData.recoveryCooldown - dtSim

  tmp1:set(veh:getDirectionVectorXYZ())
  tmp2:set(veh:getVelocityXYZ())
  tmp1.z = 0
  tmp2.z = 0
  local dot = tmp1:dot(tmp2)
  if dot < drivingBackwardsSettings.velocityDotThreshold then
    -- Don't apply driving backwards penalty if recently recovered to checkpoint
    if infractionData.recoveryCooldown <= 0 then
      if infractionData.drivingBackwardsCooldown <= 0 then
        infractionData.drivingBackwardsDistance = infractionData.drivingBackwardsDistance + dtSim * math.abs(dot)
        if infractionData.drivingBackwardsDistance > drivingBackwardsSettings.distanceThreshold then
          gameplay_crawl_display.showDrivingBackwardsMessage()
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

  if vehicleData.objectCollisions then
    local objectCollisions = vehicleData.objectCollisions
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
  gameplay_crawl_display.showVehicleFlippedUprightMessage()
end

local function onVehicleReset(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.crawlerData then
    return
  end

  state.recoveryCount = (state.recoveryCount or 0) + 1

  if state.isFromMission then
    applyPenalty(crawlerId, 'vehicleFlippedUpright')
    gameplay_crawl_display.showVehicleFlippedUprightMessage()
  else
    applyPenalty(crawlerId, 'dnf')
    gameplay_crawl_display.showDNFMessage()
  end
end

local function applyDNF(crawlerId)
  local state = crawlStates[crawlerId]
  if not state or not state.active or not state.crawlerData then
    return
  end

  if state.isDisqualified then
    return
  end

  gameplay_crawl_display.showDNFMessage()

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

  state.isDisqualified = true

  extensions.hook("onCrawlDisqualified")

  if not state.isFromMission then
    stopCrawl(true)
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
  gameplay_crawl_display.showBoundaryViolationMessage()
end


local function updateCrawl(dtSim)
  gameplay_crawl_boundary.updateBoundaryAnimations(dtSim)

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
      core_lapTimes.updateStaticFromRace(state.raceData, crawlerId)
    end

    if state.crawlerData.points ~= state.crawlerData.lastPoints then
      gameplay_crawl_display.showPointsMessage(state.crawlerData.points)
      state.crawlerData.lastPoints = state.crawlerData.points

      if state.crawlerData.points >= infractionPoints.dnf and not state.isDisqualified then
        applyDNF(crawlerId)
      end
    end

    if state.completionStartTime > 0 then
      local elapsed = state.currentTime - state.completionStartTime
      if elapsed >= completionDelay and not state.isFromMission then
        stopCrawl()
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

  for crawlerId, state in pairs(crawlStates) do
    if state.active then
      updateCrawlMarkerModes(state.trail, crawlerId)
    end
  end

  if markers then
    markers.render(dtReal, dtSim)
  end
end

local function onDrawOnMinimap(td)
  if markers then
    markers.drawOnMinimap(td)
  end
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

local function onPreRender(dtReal, dtSim, dtRaw)
  if not crawlStates then
    return
  end
  drawMarkers(dtReal, dtSim, dtRaw)
  if isPreviewMode then
    onPreviewUpdate(dtSim)
  end
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
  gameplay_crawl_display.showStartedCrawlMessage()
  if state.crawlerData then
    gameplay_crawl_display.showPointsMessage(state.crawlerData.points or 0)
  end

  return true
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
M.onVehicleReset = onVehicleReset
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

local originalStartRecovering = recovery.startRecovering
if originalStartRecovering then
  recovery.startRecovering = function(useAltMode)
    for crawlerId, state in pairs(crawlStates) do
      if state and state.active then
        onVehicleReset(crawlerId)
      end
    end
    return originalStartRecovering(useAltMode)
  end
end

local function trackVehReset()
  for crawlerId, state in pairs(crawlStates) do
    if state and state.active and state.crawlerData then
      local veh = state.crawlerData.dynamicData.vehObj
      if veh then
        -- Store current position to check against in next frame
        -- This allows us to detect if the vehicle actually teleported
        -- (since the hook is called before the teleport happens)
        state.pendingTeleportCheck = true
        state.teleportCheckPos = vec3(veh:getPositionXYZ())
      end
    end
  end
end

M.trackVehReset = trackVehReset

-- Restore the globals we wrapped at load time so they don't persist after the extension is unloaded
local function onExtensionUnloaded()
  if originalDropPlayerAtCameraNoReset then
    commands.dropPlayerAtCameraNoReset = originalDropPlayerAtCameraNoReset
  end
  if originalStartRecovering then
    recovery.startRecovering = originalStartRecovering
  end
end

M.onExtensionUnloaded = onExtensionUnloaded

return M