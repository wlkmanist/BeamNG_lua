-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local rdpDeviationTolerance = 30
local minCheckpointDistance = 30
local defaultCheckpointDistance = 130
local defaultMinDrivability = 0.35
local defaultRouteSmoothness = 2

local preferredAngleBySmoothness = { 55, 15, 0 }
local angleToleranceBySmoothness = { 30, 15, 10 }
local uturnThresholdBySmoothness = { -0.85, -0.625, -0.30 }
local unvisitedAngleBonus = 10
local drivabilityAngleBonus = 38
local drivabilityDeficitRamp = 8
local defaultLookaheadDistance = 300
local uturnLookbackDistance = 20
local scoringLookbackDistance = 30

local drivabilityPenalty = 10
local maxSubdivisionDepth = 10

local minCheckpointRadius = 4
local maxCheckpointRadius = 13

local cornerShiftEnabled = true
local cornerShiftDistance = 10
local cornerShiftAngleThreshold = 45
local cornerAngleSampleDistance = 5
local cornerShiftMinGap = 15

-- Road graphs sample long straights very sparsely, so the walked path is resampled to
-- an even spacing. Every later phase picks positions by array index, and only stays
-- geometrically accurate while those indices are evenly spread along the route.
local pathResampleSpacing = 8

local kinkSmoothingEnabled = true
local kinkMaxDeviation = 15

local groundMarkerDivergenceTolerance = 10
-- Phase 3 stops bisecting once a segment can no longer be halved without dropping below
-- this, so it doubles as the floor on checkpoint spacing that Phase 3 is allowed to create.
-- Deliberately below minCheckpointDistance: Phase 2 already spaces checkpoints 30-60m
-- apart, so a floor of 30 would only let Phase 3 split 60m+ gaps and make it a near no-op.
local minSubdivisionSegmentLength = 20

local function getRoadName(nodeKey)
  return nodeKey:match("^(.+)_") or nodeKey
end

local function buildRoadAdjacency(mapNodes, minDrivability)
  local adj = {}
  for nodeName, node in pairs(mapNodes) do
    if not adj[nodeName] then adj[nodeName] = {} end
    if node.links then
      for neighborName, linkData in pairs(node.links) do
        if type(linkData) == 'table' and linkData.drivability and linkData.drivability < minDrivability then
          goto continueLink
        end

        if type(linkData) == 'table' and linkData.oneWay then
          if not adj[linkData.inNode] then adj[linkData.inNode] = {} end
          adj[linkData.inNode][linkData.outNode] = true
          if not adj[linkData.outNode] then adj[linkData.outNode] = {} end
        else
          adj[nodeName][neighborName] = true
          if not adj[neighborName] then adj[neighborName] = {} end
          adj[neighborName][nodeName] = true
        end

        ::continueLink::
      end
    end
  end
  return adj
end

local function findDeadEndSpurNodes(adj)
  local degree = {}
  for nodeKey, neighbors in pairs(adj) do
    local count = 0
    for _ in pairs(neighbors) do count = count + 1 end
    degree[nodeKey] = count
  end

  local queue = {}
  for nodeKey, deg in pairs(degree) do
    if deg <= 1 then
      table.insert(queue, nodeKey)
    end
  end

  local deadEndNodes = {}
  local head = 1
  while head <= #queue do
    local nodeKey = queue[head]
    head = head + 1

    if deadEndNodes[nodeKey] or degree[nodeKey] > 1 then goto continueQueue end

    deadEndNodes[nodeKey] = true
    for neighborKey, _ in pairs(adj[nodeKey] or {}) do
      if not deadEndNodes[neighborKey] then
        degree[neighborKey] = degree[neighborKey] - 1
        if degree[neighborKey] <= 1 then
          table.insert(queue, neighborKey)
        end
      end
    end

    ::continueQueue::
  end

  -- Un-mark spur roots: nodes that still have at least one live neighbor.
  -- These connect a spur to the main network and are valid traversal points.
  for nodeKey, _ in pairs(deadEndNodes) do
    for neighborKey, _ in pairs(adj[nodeKey] or {}) do
      if not deadEndNodes[neighborKey] then
        deadEndNodes[nodeKey] = nil
        break
      end
    end
  end

  return deadEndNodes
end

local function hasOnwardPath(nodeKey, comingFromKey, adj, mapNodes, remainingDistance)
  if remainingDistance <= 0 then return true end
  local neighbors = adj[nodeKey]
  if not neighbors then return false end
  local nodePos = mapNodes[nodeKey].pos
  for neighborKey, _ in pairs(neighbors) do
    if neighborKey ~= comingFromKey then
      if hasOnwardPath(neighborKey, nodeKey, adj, mapNodes, remainingDistance - nodePos:distance(mapNodes[neighborKey].pos)) then
        return true
      end
    end
  end
  return false
end

local function findNearestConnectedNode(pos, mapNodes, adjacency)
  local bestKey = nil
  local bestDistSq = math.huge
  for nodeName, node in pairs(mapNodes) do
    if adjacency[nodeName] and next(adjacency[nodeName]) then
      local dSq = pos:squaredDistance(node.pos)
      if dSq < bestDistSq then
        bestDistSq = dSq
        bestKey = nodeName
      end
    end
  end
  return bestKey
end

local function findStartNodes(startPos, startDir, mapNodes, adj)
  if startDir then
    local firstKey, secondKey = map.findBestRoad(startPos, startDir)
    local aheadKey, behindKey = firstKey, secondKey
    if mapNodes[firstKey] and mapNodes[secondKey] then
      if (mapNodes[secondKey].pos - startPos):dot(startDir) > (mapNodes[firstKey].pos - startPos):dot(startDir) then
        aheadKey, behindKey = secondKey, firstKey
      end
      if adj[aheadKey] and next(adj[aheadKey]) then
        return aheadKey, behindKey
      end
    end
  end

  return findNearestConnectedNode(startPos, mapNodes, adj), nil
end

local function filterUturns(candidates, currentDir, mapNodes, fromPos, uturnThreshold)
  if not currentDir or #candidates == 0 then return candidates end
  local filtered = {}
  for _, key in ipairs(candidates) do
    local candidateDir = (mapNodes[key].pos - fromPos):normalized()
    if currentDir:dot(candidateDir) >= uturnThreshold then
      table.insert(filtered, key)
    end
  end
  return filtered
end

local function getLinkDrivability(mapNodes, fromKey, toKey)
  local node = mapNodes[fromKey]
  if node and node.links then
    local linkData = node.links[toKey]
    if type(linkData) == 'table' and linkData.drivability then
      return linkData.drivability
    end
  end
  return 1
end

local function classifyBand(drivability, bandBoundaries)
  if drivability < bandBoundaries[1] then return "trail"
  elseif drivability <= bandBoundaries[2] then return "dirt"
  else return "tarmac" end
end

local function getBandDeficit(bandName, bandDistances, totalDistance, targetRatios, availableBands)
  if not targetRatios or totalDistance < 1 then return 0 end
  local targetRatio = targetRatios[bandName] or 0
  if bandName == "dirt" and availableBands and not availableBands.trail then
    targetRatio = targetRatio + (targetRatios.trail or 0)
  end
  if targetRatio <= 0 then return 0 end
  local actualRatio = (bandDistances[bandName] or 0) / totalDistance
  return math.max(0, targetRatio - actualRatio)
end

local function pickByClosestAngle(candidates, currentDir, mapNodes, fromKey, preferredAngleRad, toleranceRad, visitedNodes, targetRatios, bandBoundaries, bandDistances, totalDistance)
  if #candidates == 1 then return candidates[1] end
  local fromPos = mapNodes[fromKey].pos
  if not currentDir then return candidates[math.random(#candidates)] end

  local unvisitedBonusRad = math.rad(unvisitedAngleBonus)
  local drivBonusRad = math.rad(drivabilityAngleBonus)
  local availableBands
  if targetRatios and bandBoundaries then
    availableBands = {}
    for _, key in ipairs(candidates) do
      local driv = getLinkDrivability(mapNodes, fromKey, key)
      availableBands[classifyBand(driv, bandBoundaries)] = true
    end
  end
  local scored = {}
  for _, candidateKey in ipairs(candidates) do
    local candidateDir = (mapNodes[candidateKey].pos - fromPos):normalized()
    local dot = math.max(-1, math.min(1, currentDir:dot(candidateDir)))
    local angle = math.acos(dot)
    local deviation = math.abs(angle - preferredAngleRad)
    if not visitedNodes[candidateKey] then
      deviation = math.max(0, deviation - unvisitedBonusRad)
    end
    if targetRatios and bandBoundaries then
      local driv = getLinkDrivability(mapNodes, fromKey, candidateKey)
      local band = classifyBand(driv, bandBoundaries)
      local deficit = getBandDeficit(band, bandDistances, totalDistance, targetRatios, availableBands)
      deviation = math.max(0, deviation - drivBonusRad * math.min(1, deficit * drivabilityDeficitRamp))
    end
    table.insert(scored, { key = candidateKey, deviation = deviation })
  end

  table.sort(scored, function(a, b) return a.deviation < b.deviation end)
  local bestDeviation = scored[1].deviation

  local tiePool = {}
  for _, s in ipairs(scored) do
    if s.deviation <= bestDeviation + toleranceRad then
      table.insert(tiePool, s.key)
    end
  end

  return tiePool[math.random(#tiePool)]
end

local function computeLookbackDirection(walkHistory, currentPos, lookbackDistance)
  if #walkHistory < 1 then return nil end
  local currentCumDist = walkHistory[#walkHistory].cumDist
  local targetCumDist = currentCumDist - lookbackDistance
  local lookbackPos = walkHistory[1].pos
  for i = #walkHistory, 1, -1 do
    if walkHistory[i].cumDist <= targetCumDist then
      lookbackPos = walkHistory[i].pos
      break
    end
  end
  local dx = currentPos.x - lookbackPos.x
  local dy = currentPos.y - lookbackPos.y
  local dz = currentPos.z - lookbackPos.z
  if dx * dx + dy * dy + dz * dz > 1 then
    return (currentPos - lookbackPos):normalized()
  end
  return nil
end

local function pointToSegmentDistance(point, segStart, segEnd)
  local sdx = segEnd.x - segStart.x
  local sdy = segEnd.y - segStart.y
  local sdz = segEnd.z - segStart.z
  local segLenSq = sdx * sdx + sdy * sdy + sdz * sdz
  if segLenSq < 1e-10 then return point:distance(segStart) end

  local dx = point.x - segStart.x
  local dy = point.y - segStart.y
  local dz = point.z - segStart.z
  local t = math.max(0, math.min(1, (dx * sdx + dy * sdy + dz * sdz) / segLenSq))

  local ex = dx - sdx * t
  local ey = dy - sdy * t
  local ez = dz - sdz * t
  return math.sqrt(ex * ex + ey * ey + ez * ez)
end

-- Removes short lateral kinks caused by overlapping road topology.
-- Detects nodes on a "foreign" road that deviate from the line between neighbors.
local function smoothTopologyKinks(walkedNodeKeys, walkedPositions)
  if #walkedPositions <= 2 then return walkedNodeKeys, walkedPositions end

  local keep = {}
  for i = 1, #walkedPositions do keep[i] = true end

  local i = 2
  while i < #walkedPositions do
    local road = getRoadName(walkedNodeKeys[i])

    local prevRoad = getRoadName(walkedNodeKeys[i - 1])
    if road ~= prevRoad then
      local kinkEnd = i
      while kinkEnd < #walkedPositions and getRoadName(walkedNodeKeys[kinkEnd]) ~= prevRoad do
        kinkEnd = kinkEnd + 1
      end

      local afterRoad = getRoadName(walkedNodeKeys[kinkEnd])
      if afterRoad == prevRoad then
        local segStart = walkedPositions[i - 1]
        local segEnd = walkedPositions[kinkEnd]
        local maxDev = 0
        for j = i, kinkEnd - 1 do
          local dev = pointToSegmentDistance(walkedPositions[j], segStart, segEnd)
          if dev > maxDev then maxDev = dev end
        end

        if maxDev < kinkMaxDeviation then
          for j = i, kinkEnd - 1 do
            keep[j] = false
          end
          i = kinkEnd + 1
          goto continueSmooth
        end
      end
    end

    i = i + 1
    ::continueSmooth::
  end

  local smoothedKeys = {}
  local smoothedPositions = {}
  for idx = 1, #walkedPositions do
    if keep[idx] then
      table.insert(smoothedKeys, walkedNodeKeys[idx])
      table.insert(smoothedPositions, walkedPositions[idx])
    end
  end

  return smoothedKeys, smoothedPositions
end

-- Splits any segment longer than maxSpacing into evenly spaced interpolated points.
local function densifyWalkedPath(walkedNodeKeys, walkedPositions, adj, maxSpacing)
  if #walkedPositions < 2 or maxSpacing <= 0 then return walkedNodeKeys, walkedPositions, nil, 0 end

  local outKeys = { walkedNodeKeys[1] }
  local outPositions = { walkedPositions[1] }
  local isRealNode = { true }
  local skippedGaps = 0

  for i = 2, #walkedPositions do
    local prevKey, key = walkedNodeKeys[i - 1], walkedNodeKeys[i]
    local a, b = walkedPositions[i - 1], walkedPositions[i]
    local segLen = a:distance(b)
    local isGraphEdge = adj[prevKey] and adj[prevKey][key]

    if segLen > maxSpacing then
      if isGraphEdge then
        local steps = math.ceil(segLen / maxSpacing)
        for s = 1, steps - 1 do
          local t = s / steps
          table.insert(outPositions, a + (b - a) * t)
          table.insert(outKeys, t < 0.5 and prevKey or key)
          table.insert(isRealNode, false)
        end
      else
        skippedGaps = skippedGaps + 1
      end
    end

    table.insert(outPositions, b)
    table.insert(outKeys, key)
    table.insert(isRealNode, true)
  end

  return outKeys, outPositions, isRealNode, skippedGaps
end

local function rdpCollectKeyIndices(points, startIdx, endIdx, tolerance, keepIndices)
  if endIdx - startIdx <= 1 then return end

  local maxDist = 0
  local maxIdx = startIdx
  for i = startIdx + 1, endIdx - 1 do
    local dist = pointToSegmentDistance(points[i], points[startIdx], points[endIdx])
    if dist > maxDist then
      maxDist = dist
      maxIdx = i
    end
  end

  if maxDist > tolerance then
    keepIndices[maxIdx] = true
    rdpCollectKeyIndices(points, startIdx, maxIdx, tolerance, keepIndices)
    rdpCollectKeyIndices(points, maxIdx, endIdx, tolerance, keepIndices)
  end
end

local function selectCheckpointIndices(positions, tolerance, minDist, maxDist)
  if #positions <= 2 then
    local result = {}
    for i = 1, #positions do result[i] = i end
    return result
  end

  local cumDist = { [1] = 0 }
  for i = 2, #positions do
    cumDist[i] = cumDist[i - 1] + positions[i]:distance(positions[i - 1])
  end

  local keepSet = { [1] = true, [#positions] = true }
  rdpCollectKeyIndices(positions, 1, #positions, tolerance, keepSet)

  local keepList = {}
  for idx in pairs(keepSet) do table.insert(keepList, idx) end
  table.sort(keepList)

  local spaced = { keepList[1] }
  for i = 2, #keepList do
    local gap = cumDist[keepList[i]] - cumDist[spaced[#spaced]]
    if gap >= minDist or keepList[i] == #positions then
      table.insert(spaced, keepList[i])
    end
  end

  local final = { spaced[1] }
  for i = 2, #spaced do
    local prevIdx = final[#final]
    local nextIdx = spaced[i]
    local gap = cumDist[nextIdx] - cumDist[prevIdx]

    if gap > maxDist then
      local targetDist = cumDist[prevIdx] + maxDist
      for j = prevIdx + 1, nextIdx - 1 do
        if cumDist[j] >= targetDist and (cumDist[nextIdx] - cumDist[j]) >= minDist then
          table.insert(final, j)
          targetDist = cumDist[j] + maxDist
        end
      end
    end

    table.insert(final, nextIdx)
  end

  return final
end

local function buildCumulativeDistances(positions)
  local cumDist = { [1] = 0 }
  for i = 2, #positions do
    cumDist[i] = cumDist[i - 1] + positions[i]:distance(positions[i - 1])
  end
  return cumDist
end

-- Interpolated point at targetDist along the walked polyline, ignoring node placement.
local function positionAtDistance(walkedPositions, cumDist, targetDist)
  local n = #walkedPositions
  if targetDist <= 0 then return vec3(walkedPositions[1]) end
  if targetDist >= cumDist[n] then return vec3(walkedPositions[n]) end
  for i = 2, n do
    if cumDist[i] >= targetDist then
      local segLen = cumDist[i] - cumDist[i - 1]
      local t = segLen > 1e-6 and (targetDist - cumDist[i - 1]) / segLen or 0
      local a, b = walkedPositions[i - 1], walkedPositions[i]
      return a + (b - a) * t
    end
  end
  return vec3(walkedPositions[n])
end

-- Turn angle in degrees at idx, sampled sampleDist meters behind and ahead along the path.
-- The spans shorten near the path ends, where there is less path to sample.
local function sampleTurnAngle(walkedPositions, cumDist, idx, sampleDist)
  local here = cumDist[idx]
  local behindSpan = math.min(sampleDist, here)
  local aheadSpan = math.min(sampleDist, cumDist[#walkedPositions] - here)
  if behindSpan < 1e-3 or aheadSpan < 1e-3 then return 0 end

  local dirIn = walkedPositions[idx] - positionAtDistance(walkedPositions, cumDist, here - behindSpan)
  local dirOut = positionAtDistance(walkedPositions, cumDist, here + aheadSpan) - walkedPositions[idx]
  local lenIn, lenOut = dirIn:length(), dirOut:length()
  if lenIn < 1e-6 or lenOut < 1e-6 then return 0 end

  local dot = math.max(-1, math.min(1, (dirIn / lenIn):dot(dirOut / lenOut)))
  return math.deg(math.acos(dot))
end

-- A* can only start and end on real graph nodes, so querying it with an interpolated
-- position makes it snap outward, potentially far beyond the range being checked. Widening
-- the range to the enclosing real nodes keeps both endpoints inside the compared polyline.
local function expandToRealNodes(isRealNode, fromIdx, toIdx, lastIdx)
  if not isRealNode then return fromIdx, toIdx end
  while fromIdx > 1 and not isRealNode[fromIdx] do fromIdx = fromIdx - 1 end
  while toIdx < lastIdx and not isRealNode[toIdx] do toIdx = toIdx + 1 end
  return fromIdx, toIdx
end

local function doesGroundMarkerDiverge(walkedPositions, isRealNode, fromIdx, toIdx, minDrivability)
  fromIdx, toIdx = expandToRealNodes(isRealNode, fromIdx, toIdx, #walkedPositions)
  if toIdx - fromIdx < 1 then return false end

  local mapNodes = map.getMap().nodes
  local astarPath = map.getPointToPointPath(walkedPositions[fromIdx], walkedPositions[toIdx], minDrivability, 1, 1, drivabilityPenalty, nil, 1)
  if not astarPath or #astarPath < 1 then return true end

  local tolerance = groundMarkerDivergenceTolerance
  for _, nodeKey in ipairs(astarPath) do
    local nodePos = mapNodes[nodeKey] and mapNodes[nodeKey].pos
    if not nodePos then return true end

    local minDist = math.huge
    for wi = fromIdx, toIdx - 1 do
      local d = pointToSegmentDistance(nodePos, walkedPositions[wi], walkedPositions[wi + 1])
      if d < minDist then
        minDist = d
        if d <= tolerance then break end
      end
    end

    if minDist > tolerance then
      return true
    end
  end

  return false
end

-- Walker index nearest the halfway distance between two indices. Bisecting the index
-- range instead would land wherever the nodes happen to be densest, not mid-segment.
local function midIndexByDistance(cumDist, fromIdx, toIdx)
  local targetDist = (cumDist[fromIdx] + cumDist[toIdx]) * 0.5
  for wi = fromIdx + 1, toIdx - 1 do
    if cumDist[wi] >= targetDist then
      local prevGap = targetDist - cumDist[wi - 1]
      local thisGap = cumDist[wi] - targetDist
      if prevGap < thisGap and wi - 1 > fromIdx then return wi - 1 end
      return wi
    end
  end
  return toIdx - 1
end

local function ensureGroundMarkerConsistency(walkedPositions, isRealNode, cumDist, checkpointIndices, minDrivability, job)
  local resultSet = {}
  for _, idx in ipairs(checkpointIndices) do
    resultSet[idx] = true
  end

  local queue = {}
  local head = 1
  for i = 2, #checkpointIndices do
    table.insert(queue, { checkpointIndices[i - 1], checkpointIndices[i], 0 })
  end

  while head <= #queue do
    local fromIdx = queue[head][1]
    local toIdx = queue[head][2]
    local depth = queue[head][3]
    head = head + 1

    local canSplit = toIdx - fromIdx > 1
      and depth < maxSubdivisionDepth
      and (cumDist[toIdx] - cumDist[fromIdx]) >= 2 * minSubdivisionSegmentLength

    if canSplit and doesGroundMarkerDiverge(walkedPositions, isRealNode, fromIdx, toIdx, minDrivability) then
      local midIdx = midIndexByDistance(cumDist, fromIdx, toIdx)
      -- Both halves must still clear the floor; the midpoint snaps to a node, so the
      -- split is only approximately even.
      local firstHalf = cumDist[midIdx] - cumDist[fromIdx]
      local secondHalf = cumDist[toIdx] - cumDist[midIdx]
      if midIdx > fromIdx and midIdx < toIdx
        and firstHalf >= minSubdivisionSegmentLength
        and secondHalf >= minSubdivisionSegmentLength then
        resultSet[midIdx] = true
        table.insert(queue, { fromIdx, midIdx, depth + 1 })
        table.insert(queue, { midIdx, toIdx, depth + 1 })
      end
    end

    if job then job.yield() end
  end

  local result = {}
  for idx in pairs(resultSet) do
    table.insert(result, idx)
  end
  table.sort(result)

  return result
end

local function generateRaceRoute(startPos, targetDistanceMeters, startDir, minDrivability, routeSmoothness, lookAheadDistance, job, seed, targetRatios, bandBoundaries, checkpointDistance)
  checkpointDistance = checkpointDistance or defaultCheckpointDistance
  minDrivability = minDrivability or defaultMinDrivability
  lookAheadDistance = lookAheadDistance or defaultLookaheadDistance

  math.randomseed(seed or os.time())

  routeSmoothness = math.max(1, math.min(3, routeSmoothness or defaultRouteSmoothness))
  local preferredAngleRad = math.rad(preferredAngleBySmoothness[routeSmoothness])
  local toleranceRad = math.rad(angleToleranceBySmoothness[routeSmoothness])
  local uturnThreshold = uturnThresholdBySmoothness[routeSmoothness]

  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes
  if not mapNodes or not next(mapNodes) then return nil end

  timeprobeStart()

  local adj = buildRoadAdjacency(mapNodes, minDrivability)
  local deadEndSpurNodes = findDeadEndSpurNodes(adj)

  local startKey, behindStartKey = findStartNodes(startPos, startDir, mapNodes, adj)
  if not startKey then return nil end

  local graphMs = (timeprobe(true) or 0) * 1000
  if job then job.yield() end
  timeprobeStart()

  -- Phase 1: Node-by-node graph walk
  local walkedNodeKeys = { startKey }
  local walkedPositions = { vec3(mapNodes[startKey].pos.x, mapNodes[startKey].pos.y, mapNodes[startKey].pos.z) }

  local currentKey = startKey
  local previousKey = behindStartKey
  local visitedNodes = { [startKey] = true }
  local totalDistance = 0
  local bandDistances = { trail = 0, dirt = 0, tarmac = 0 }
  local walkHistory = { { pos = mapNodes[startKey].pos, cumDist = 0 } }

  while totalDistance < targetDistanceMeters do
    local node = mapNodes[currentKey]
    local neighbors = adj[currentKey]
    if not neighbors or not next(neighbors) then break end

    local uturnDir = computeLookbackDirection(walkHistory, node.pos, uturnLookbackDistance) or startDir
    local scoringDir = computeLookbackDirection(walkHistory, node.pos, scoringLookbackDistance) or startDir

    local mainCandidates = {}
    local deadEndCandidates = {}
    for neighborKey, _ in pairs(neighbors) do
      if neighborKey ~= previousKey and hasOnwardPath(neighborKey, currentKey, adj, mapNodes, lookAheadDistance) then
        if deadEndSpurNodes[neighborKey] then
          table.insert(deadEndCandidates, neighborKey)
        else
          table.insert(mainCandidates, neighborKey)
        end
      end
    end

    local candidates = filterUturns(mainCandidates, uturnDir, mapNodes, node.pos, uturnThreshold)
    if #candidates == 0 then candidates = mainCandidates end
    if #candidates == 0 then
      candidates = filterUturns(deadEndCandidates, uturnDir, mapNodes, node.pos, uturnThreshold)
      if #candidates == 0 then candidates = deadEndCandidates end
    end
    if #candidates == 0 and previousKey then candidates = { previousKey } end
    if #candidates == 0 then break end

    local bestKey = pickByClosestAngle(candidates, scoringDir, mapNodes, currentKey, preferredAngleRad, toleranceRad, visitedNodes, targetRatios, bandBoundaries, bandDistances, totalDistance)
    if not bestKey then break end

    local bestPos = vec3(mapNodes[bestKey].pos.x, mapNodes[bestKey].pos.y, mapNodes[bestKey].pos.z)

    local dist = node.pos:distance(mapNodes[bestKey].pos)
    totalDistance = totalDistance + dist
    if bandBoundaries then
      local driv = getLinkDrivability(mapNodes, currentKey, bestKey)
      local band = classifyBand(driv, bandBoundaries)
      bandDistances[band] = bandDistances[band] + dist
    end
    table.insert(walkHistory, { pos = mapNodes[bestKey].pos, cumDist = totalDistance })

    table.insert(walkedNodeKeys, bestKey)
    table.insert(walkedPositions, bestPos)

    previousKey = currentKey
    currentKey = bestKey
    visitedNodes[bestKey] = true
  end

  local walkMs = (timeprobe(true) or 0) * 1000
  local walkNodeCount = #walkedPositions

  if #walkedPositions < 2 then
    log('W', 'raceRouteGen', string.format('Route generation failed, walk stopped after %d nodes at %s', walkNodeCount, startKey))
    return nil
  end
  if job then job.yield() end

  -- Phase 1.5: Smooth topology kinks (removes short detours onto overlapping roads)
  local kinkMs = 0
  if kinkSmoothingEnabled then
    timeprobeStart()
    walkedNodeKeys, walkedPositions = smoothTopologyKinks(walkedNodeKeys, walkedPositions)
    kinkMs = (timeprobe(true) or 0) * 1000
  end
  local kinkNodeCount = #walkedPositions
  if job then job.yield() end

  -- Phase 1.75: Even out node spacing so index-based phases stay geometrically accurate.
  -- The coarse path is what gets returned and broadcast; the dense one is internal only.
  local coarsePositions = walkedPositions
  local isRealNode = nil
  local resampleMs, skippedGaps = 0, 0
  if pathResampleSpacing > 0 then
    timeprobeStart()
    walkedNodeKeys, walkedPositions, isRealNode, skippedGaps = densifyWalkedPath(walkedNodeKeys, walkedPositions, adj, pathResampleSpacing)
    resampleMs = (timeprobe(true) or 0) * 1000
  end
  if job then job.yield() end

  -- Phase 2: RDP checkpoint selection (concentrates checkpoints at corners)
  timeprobeStart()
  local checkpointIndices = selectCheckpointIndices(walkedPositions, rdpDeviationTolerance, minCheckpointDistance, checkpointDistance)
  local rdpMs = (timeprobe(true) or 0) * 1000
  local rdpCount = #checkpointIndices
  if job then job.yield() end

  -- Phase 2.5: Shift sharp-corner checkpoints back onto the approach
  local walkerCumDist = buildCumulativeDistances(walkedPositions)

  local shiftedCount = 0
  if cornerShiftEnabled and cornerShiftDistance > 0 and #checkpointIndices > 2 then
    for ci = 2, #checkpointIndices - 1 do
      local idx = checkpointIndices[ci]

      if sampleTurnAngle(walkedPositions, walkerCumDist, idx, cornerAngleSampleDistance) >= cornerShiftAngleThreshold then
        -- Work in distance space. The shift must clear cornerShiftMinGap from the previous
        -- checkpoint, otherwise the two gates end up stacked on top of each other.
        local prevIdx = checkpointIndices[ci - 1]
        local apexCumDist = walkerCumDist[idx]
        local floorCumDist = walkerCumDist[prevIdx] + cornerShiftMinGap
        local targetCumDist = math.max(floorCumDist, apexCumDist - cornerShiftDistance)

        -- Nearest node to the target rather than the last one before it, so the
        -- realised shift stays within half a resample step of cornerShiftDistance.
        if targetCumDist < apexCumDist then
          local shiftedIdx = idx
          local bestError = math.huge
          for wi = idx - 1, prevIdx + 1, -1 do
            if walkerCumDist[wi] >= floorCumDist then
              local err = math.abs(walkerCumDist[wi] - targetCumDist)
              if err < bestError then
                bestError = err
                shiftedIdx = wi
              end
            end
          end

          if shiftedIdx ~= idx then
            checkpointIndices[ci] = shiftedIdx
            shiftedCount = shiftedCount + 1
          end
        end
      end
    end
  end

  -- Phase 3: A* validation (ensures ground markers follow the walker's route)
  timeprobeStart()
  local validatedIndices = ensureGroundMarkerConsistency(walkedPositions, isRealNode, walkerCumDist, checkpointIndices, minDrivability, job)
  local validateMs = (timeprobe(true) or 0) * 1000

  -- Build output arrays, skipping the start node (player is already there)
  local firstIdx = (validatedIndices[1] == 1 and #validatedIndices > 2) and 2 or 1
  local checkpoints = {}
  local checkpointRadii = {}
  local checkpointNormals = {}
  for i = firstIdx, #validatedIndices do
    local idx = validatedIndices[i]
    table.insert(checkpoints, walkedPositions[idx])
    local node = mapNodes[walkedNodeKeys[idx]]
    local roadWidth = (node.radius or minCheckpointRadius) * 2
    local clampedRadius = math.max(minCheckpointRadius, math.min(maxCheckpointRadius, roadWidth - 3))
    table.insert(checkpointRadii, clampedRadius)

    local behindPos = positionAtDistance(walkedPositions, walkerCumDist, walkerCumDist[idx] - 5)
    local dir = (walkedPositions[idx] - behindPos):z0()
    local len = dir:length()
    table.insert(checkpointNormals, len > 1e-6 and (dir / len) or vec3(1, 0, 0))
  end

  local bandScale = totalDistance > 0 and 100 / totalDistance or 0
  -- log('I', 'raceRouteGen', string.format(
  --   'Route: %.0f m, %d checkpoints, %.0f%%/%.0f%%/%.0f%% trail/dirt/tarmac | nodes %d walk, %d kink, %d resample (%d sparse gaps) | cp %d rdp, %d shifted, %d validated | %.1f ms (graph %.1f, walk %.1f, kink %.1f, resample %.1f, rdp %.1f, validate %.1f)',
  --   totalDistance, #checkpoints,
  --   bandDistances.trail * bandScale, bandDistances.dirt * bandScale, bandDistances.tarmac * bandScale,
  --   walkNodeCount, kinkNodeCount, #walkedPositions, skippedGaps,
  --   rdpCount, shiftedCount, #validatedIndices,
  --   graphMs + walkMs + kinkMs + resampleMs + rdpMs + validateMs,
  --   graphMs, walkMs, kinkMs, resampleMs, rdpMs, validateMs))

  return coarsePositions, checkpoints, checkpointRadii, checkpointNormals, totalDistance
end

local function pickRandomRoadPoint()
  local mapData = map.getMap()
  local mapNodes = mapData and mapData.nodes

  if mapNodes and next(mapNodes) then
    local nodeKeys = {}
    for k, _ in pairs(mapNodes) do
      table.insert(nodeKeys, k)
    end
    if #nodeKeys > 0 then
      local node = mapNodes[nodeKeys[math.random(#nodeKeys)]]
      return vec3(node.pos.x, node.pos.y, node.pos.z)
    end
  end

  local terrain = core_terrain.getTerrain()
  if terrain then
    local worldBox = terrain:getWorldBox()
    local minE = worldBox.minExtents
    local maxE = worldBox.maxExtents
    return vec3(
      minE.x + math.random() * (maxE.x - minE.x),
      minE.y + math.random() * (maxE.y - minE.y),
      (minE.z + maxE.z) / 2
    )
  end

  return vec3(0, 0, 0)
end

M.maxCheckpointRadius = maxCheckpointRadius
-- ground marker routing has to use these, otherwise phase 3 validates a route the player never gets
M.defaultMinDrivability = defaultMinDrivability
M.drivabilityPenalty = drivabilityPenalty
M.generateRaceRoute = generateRaceRoute
M.pickRandomRoadPoint = pickRandomRoadPoint

return M
