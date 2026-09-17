-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility module containing an optimised implementation of the Ramer-Douglas-Peucker algorithm.
-- This algorithm is used to simplify polylines with excessive points.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local defaultTol = 6.0 -- The default tolerance used for the RDP algorithms.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module state.
local simplifiedIdxList = {}
local stackI, stackK = {}, {}


-- Performs a Ramer-Douglas-Peucker (RDP) simplification of the given polyline.
-- [Uses line segment instead of infinite line].
local function rdpIndices(nodes, startIdx, endIdx, tol, retListP)
  -- Clear cache/stacks.
  local retList = retListP or {}
  local retListCount = 0
  table.clear(retList)
  table.clear(stackI)
  table.clear(stackK)
  local stackCtr = 1
  stackI[stackCtr], stackK[stackCtr] = startIdx, endIdx

  -- Execute until the stack is empty.
  local tolSq = tol * tol
  retListCount = retListCount + 1
  retList[retListCount] = startIdx -- Always keep the first point.
  while stackCtr > 0 do
    -- Pop current segment [i, k] from stack.
    local i, k = stackI[stackCtr], stackK[stackCtr]
    stackCtr = stackCtr - 1

    -- Find the point with the largest distance to the line segment.
    local maxDistSq, index = -1, -1
    local pStart, pEnd = nodes[i], nodes[k]
    for j = i + 1, k - 1 do
      local distSq = nodes[j]:squaredDistanceToLineSegment(pStart, pEnd)
      if distSq > maxDistSq then
        maxDistSq, index = distSq, j
      end
    end

    -- If the maximum distance exceeds tolerance, keep this point and split.
    if maxDistSq > tolSq then
      stackCtr = stackCtr + 1
      stackI[stackCtr], stackK[stackCtr] = index, k -- Push right segment [index, k].
      stackCtr = stackCtr + 1
      stackI[stackCtr], stackK[stackCtr] = i, index -- Push left segment [i, index].
    else
      retListCount = retListCount + 1
      retList[retListCount] = k -- If no split, we have fully simplified this segment; keep the end point.
    end
  end

  return retList
end

-- Simplifies the given nodes, in place.
local function simplifyNodes(nodes, tol)
  local numNodes = #nodes
  if numNodes <= 2 then
    return numNodes -- No simplification possible.
  end

  rdpIndices(nodes, 1, numNodes, tol or defaultTol, simplifiedIdxList) -- Execute RDP on the polyline.

  -- In-place compaction.
  local newCount = #simplifiedIdxList
  for i = 1, newCount do
    nodes[i] = nodes[simplifiedIdxList[i]]
  end

  -- Remove the remaining nodes.
  for i = newCount + 1, numNodes do
    nodes[i] = nil
  end

  return newCount
end

-- Simplifies the given nodes (and their corresponding widths), in place.
local function simplifyNodesWidths(nodes, widths, tol)
  local numNodes = #nodes
  if numNodes <= 2 then
    return numNodes -- No simplification possible.
  end

  rdpIndices(nodes, 1, numNodes, tol or defaultTol, simplifiedIdxList) -- Execute RDP on the polyline.

  -- In-place compaction.
  local newCount = #simplifiedIdxList
  for i = 1, newCount do
    local idx = simplifiedIdxList[i]
    nodes[i], widths[i] = nodes[idx], widths[idx]
  end

  -- Remove the remaining nodes (and their corresponding widths).
  for i = newCount + 1, numNodes do
    nodes[i], widths[i] = nil, nil
  end

  return newCount
end

-- Simplifies the given nodes (and their corresponding widths and normal vectors), in place.
local function simplifyNodesWidthsNormals(nodes, widths, normals, tol)
  local numNodes = #nodes
  if numNodes <= 2 then
    return numNodes -- No simplification possible.
  end

  rdpIndices(nodes, 1, numNodes, tol or defaultTol, simplifiedIdxList) -- Execute RDP on the polyline.

  -- In-place compaction.
  local newCount = #simplifiedIdxList
  for i = 1, newCount do
    local idx = simplifiedIdxList[i]
    nodes[i], widths[i], normals[i] = nodes[idx], widths[idx], normals[idx]
  end

  -- Remove the remaining nodes (and their corresponding widths and normals).
  for i = newCount + 1, numNodes do
    nodes[i], widths[i], normals[i] = nil, nil, nil
  end

  return newCount
end

-- Simplifies the given nodes (and their corresponding velocities), in place.
local function simplifyNodesVels(nodes, velocities, tol)
  local numNodes = #nodes
  if numNodes <= 2 then
    return numNodes -- No simplification possible.
  end

  rdpIndices(nodes, 1, numNodes, tol or defaultTol, simplifiedIdxList) -- Execute RDP on the polyline.

  -- In-place compaction.
  local newCount = #simplifiedIdxList
  for i = 1, newCount do
    local idx = simplifiedIdxList[i]
    nodes[i], velocities[i] = nodes[idx], velocities[idx]
  end

  -- Remove the remaining nodes (and their corresponding velocities).
  for i = newCount + 1, numNodes do
    nodes[i], velocities[i] = nil, nil
  end

  return newCount
end

-- Simplifies the given nodes (and their corresponding widths, velocities and velocity limits), in place.
local function simplifyNodesWidthsVelVelLimits(nodes, widths, velocities, velLimits, tol)
  local numNodes = #nodes
  if numNodes <= 2 then
    return numNodes -- No simplification possible.
  end

  rdpIndices(nodes, 1, numNodes, tol or defaultTol, simplifiedIdxList) -- Execute RDP on the polyline.

  -- In-place compaction.
  local newCount = #simplifiedIdxList
  for i = 1, newCount do
    local idx = simplifiedIdxList[i]
    nodes[i], widths[i], velocities[i], velLimits[i] = nodes[idx], widths[idx], velocities[idx], velLimits[idx]
  end

  -- Remove the remaining nodes (and their corresponding widths, velocities and velocity limits).
  for i = newCount + 1, numNodes do
    nodes[i], widths[i], velocities[i], velLimits[i] = nil, nil, nil, nil
  end

  return newCount
end


-- Public interface.
M.rdpIndices =                                          rdpIndices

M.simplifyNodes =                                       simplifyNodes
M.simplifyNodesWidths =                                 simplifyNodesWidths
M.simplifyNodesWidthsNormals =                          simplifyNodesWidthsNormals
M.simplifyNodesVels =                                   simplifyNodesVels
M.simplifyNodesWidthsVelVelLimits =                     simplifyNodesWidthsVelVelLimits

return M