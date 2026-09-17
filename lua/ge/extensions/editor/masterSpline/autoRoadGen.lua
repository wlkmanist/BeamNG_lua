-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This module is for generating roads between two points, based on a selected road design preset's constraints.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local rdpTol = 9.0 -- The tolerance for the RDP simplification of the spline (the first simplification).
local rdpTolPost = 2.5 -- The tolerance for the RDP simplification (of the final interpolated path nodes and widths).
local relaxZIterations = 10 -- The number of iterations to relax the z-coordinates of the preview nodes to the terrain.
local pushOffDistance = 10.0  -- The distance to push off at each waypoint to minimise self-overlap.
local duplicateNodeTolSq = 0.1 -- The tolerance for duplicate nodes at junctions (squared).
local maxExtraWidthFactor = 0.8  -- eg 0.8 = up to +80% width increase at max curvature (at full blend).
local epsilon = 1e-6 -- A small value to avoid division by zero.
local interpGran = 10 -- The granularity of the final interpolated path nodes and widths.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local render = require('editor/toolUtilities/render')
local geom = require('editor/toolUtilities/geom')
local rdp = require('editor/toolUtilities/rdp')

-- Module constants.
local abs, min, max, floor, acos = math.abs, math.min, math.max, math.floor, math.acos
local searchDirs = {
  { x = 1, y = 0 }, { x = -1, y = 0 }, { x = 0, y = 1 }, { x = 0, y = -1 },
  { x = 1, y = 1 }, { x = -1, y = 1 }, { x = -1, y = -1 }, { x = 1, y = -1 }
}

-- Module state.
local pathNodes, pathWidths = {}, {}
local openSet = require('graphpath').newMinheap()
local nodePool = {}
local visitedArr, costArr, cameFromArr = {}, {}, {}
local terrainZ = {}
local nextNodeIdx = 1
local iStart, iGoal, pt = Point2I(0, 0), Point2I(0, 0), Point2I(0, 0)
local distVec, dir = vec3(), vec3()
local tmp1, tmp2, tmp3 = vec3(), vec3(), vec3()


-- Allocates a new node from the pool.
local function allocNode()
  local node = nodePool[nextNodeIdx]
  if not node then
    node = {}
    nodePool[nextNodeIdx] = node
  end
  nextNodeIdx = nextNodeIdx + 1
  return node
end

-- Resets the node pool.
local function resetNodePool()
  nextNodeIdx = 1
end

-- Returns true if a preview currently exists, otherwise false.
local function isPreview() return #pathNodes > 0 end

-- Clears the current preview.
local function clearPreview()
  table.clear(pathNodes)
  table.clear(pathWidths)
end

-- Evaluates the full slope penalty for a move.
local function getSlopePenalty(dz, dist, max_slope, slopeAvoidance)
  local slope = abs(dz) / (dist + 1e-6)
  local excess = max(0, slope - max_slope)
  local effectiveSlopeAvoidance = slopeAvoidance * slopeAvoidance
  return excess^3 * 300 * effectiveSlopeAvoidance
end

-- Evaluates the radius penalty for a move.
local function getRadiusPenalty(prev_dir, next_dir, dist, min_radius, last_angle)
  if not prev_dir then
    return 0, 0 -- If there is no previous direction, return 0 penalty.
  end
  local dot = prev_dir.x * next_dir.x + prev_dir.y * next_dir.y -- The dot product of the previous and next directions.
  local angle = acos(max(-1, min(1, dot))) -- The angle between the previous and next directions.
  local radius = dist / (angle + 1e-6) -- The radius of the circle that fits the previous and next directions.
  local radius_pen = max(0, (min_radius - radius) / min_radius) -- The penalty for the radius being too small.
  local radius_cost = radius_pen * radius_pen * 50 -- Penalise if the radius is too small.
  local delta_angle = last_angle and (angle - last_angle) or 0 -- The change in angle from the previous move.
  local curve_shift_cost = delta_angle * delta_angle * 20  -- Penalise sudden direction change.
  return radius_cost + curve_shift_cost, angle -- Return the penalty and the new angle.
end

-- Evaluates total penalty for a move.
local function getMovePenalty(prev_dir, dir, dz, dist, max_slope, min_radius, last_angle, slopeAvoidance)
  local slope_pen = getSlopePenalty(dz, dist, max_slope, slopeAvoidance)
  local radius_pen, new_angle = getRadiusPenalty(prev_dir, dir, dist, min_radius, last_angle)
  return dist + slope_pen + radius_pen, new_angle
end

-- Snaps the z-coordinates of the preview nodes to the slope envelope defined by the preset constraint.
local function snapZsToSlopeEnvelope(maxSlope)
  local pStart, pEnd = pathNodes[1], pathNodes[#pathNodes]
  local pStartZ, pEndZ = pStart.z, pEnd.z
  for i = 2, #pathNodes - 1 do
    local p = pathNodes[i]
    local distToStart, distToEnd = p:distance(pStart), p:distance(pEnd)
    local tZ = p.z
    local f1 = pStartZ + (pEndZ - pStartZ) * (distToStart / (distToStart + distToEnd))
    local f2 = maxSlope * min(distToStart, distToEnd)
    local zMin, zMax = f1 - f2, f1 + f2
    p.z = clamp(tZ, zMin, zMax)
  end
end

-- Relaxes the z-coordinates of the preview nodes to the terrain - as much as the preset constraint allows.
local function relaxZsToTerrain(maxSlope)
  -- Get the terrain z-coordinates for each path node.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  table.clear(terrainZ)
  for i = 1, #pathNodes do
    te:worldToGridByPoint2I(pathNodes[i], pt, tb)
    terrainZ[i] = tb:getHeightGrid(pt.x, pt.y)
  end

  -- Iterate through the path nodes, and perform the relaxation.
  local numNodes = #pathNodes
  for _ = 1, relaxZIterations do
    for i = 2, numNodes - 1 do
      local iMinus1, iPlus1 = i - 1, i + 1
      local distPrev = pathNodes[i]:distance(pathNodes[iMinus1])
      local distNext = pathNodes[i]:distance(pathNodes[iPlus1])
      local zPrev, zNext = pathNodes[iMinus1].z, pathNodes[iPlus1].z
      local fPrev, fNext = maxSlope * distPrev, maxSlope * distNext
      local minZ, maxZ = max(zPrev - fPrev, zNext - fNext), min(zPrev + fPrev, zNext + fNext)
      local tZ = clamp(terrainZ[i], minZ, maxZ)
      pathNodes[i].z = pathNodes[i].z * 0.5 + tZ * 0.5
    end
  end
end

-- Applies widening at sharp curves on the preview spline as a post-processing step.
local function applyHairpinWidening(presetParams, blend)
  local numNodes = #pathNodes
  if numNodes < 3 or blend == 0 then
    return -- No nodes, or no blending required.
  end

  local maxGrad = presetParams.maxWidthGradient
  for i = 2, numNodes - 1 do
    -- Compute widening factor (based on curvature).
    local p0, p1, p2 = pathNodes[i - 1], pathNodes[i], pathNodes[i + 1]
    tmp1:set(p0.x, p0.y, 0)
    tmp2:set(p1.x, p1.y, 0)
    tmp3:set(p2.x, p2.y, 0)
    local radius = geom.computeTurningRadius(tmp1, tmp2, tmp3)
    local curvature = radius and radius > 0 and 1 / radius or 0
    local factor = 1.0 + maxExtraWidthFactor * curvature * 100.0
    factor = min(factor, 1.0 + maxExtraWidthFactor)

    -- Enforce max gradient (from preset).
    local prevWidth, nextWidth = pathWidths[i - 1], pathWidths[i + 1]
    local prevDist, nextDist = tmp2:distance(tmp1) + epsilon, tmp2:distance(tmp3) + epsilon
    local maxDeltaPrev, maxDeltaNext = maxGrad * prevDist, maxGrad * nextDist
    local widenedWidth = pathWidths[i] * factor
    if widenedWidth > prevWidth + maxDeltaPrev then
      widenedWidth = prevWidth + maxDeltaPrev
    elseif widenedWidth < prevWidth - maxDeltaPrev then
      widenedWidth = prevWidth - maxDeltaPrev
    end
    if widenedWidth > nextWidth + maxDeltaNext then
      widenedWidth = nextWidth + maxDeltaNext
    elseif widenedWidth < nextWidth - maxDeltaNext then
      widenedWidth = nextWidth - maxDeltaNext
    end

    -- Apply blending (a user-provided fade in range [0, 1]).
    local originalWidth = pathWidths[i]
    local finalWidth = originalWidth * (1.0 - blend) + widenedWidth * blend
    pathWidths[i] = finalWidth
  end
end

-- Generates an auto-generated road preview for a single segment.
local function generateAutoPreviewSegment(posStart, posGoal, autoParams, presetParams)
  -- Get the terrain extents and cell size.
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  local extents = tb:getWorldBox():getExtents()
  local cellSize = tb:getSquareSize()
  local terrainX, terrainY = extents.x * 2, extents.y * 2
  local cellInv = 1.0 / cellSize
  local xRes, yRes = floor(terrainX * cellInv + 1), floor(terrainY * cellInv + 1)
  local stride = xRes

  -- Convert the start and goal positions to grid coordinates.
  te:worldToGridByPoint2I(posStart, iStart, tb)
  te:worldToGridByPoint2I(posGoal, iGoal, tb)
  local sx, sy, gx, gy = iStart.x, iStart.y, iGoal.x, iGoal.y
  local startIdx, goalIdx = sy * stride + sx, gy * stride + gx

  -- Initialise the search state.
  resetNodePool()
  openSet:clear()
  table.clear(visitedArr)
  table.clear(costArr)
  table.clear(cameFromArr)

  -- Add the start node to the open set, to start the search.
  local startNode = allocNode()
  startNode.x, startNode.y, startNode.idx = sx, sy, startIdx
  startNode.cost, startNode.prev, startNode.dir, startNode.angle = 0, nil, nil, nil
  openSet:insert(0, startNode)
  costArr[startIdx] = 0

  -- Iterate through the open set, and generate the path.
  local baseWidth, slopeAvoidance, maxSlope, minRadius = autoParams.baseWidth, autoParams.slopeAvoidance, presetParams.maxSlope, presetParams.minRadius
  while not openSet:empty() do
    local _, current = openSet:pop()
    local cx, cy, cidx = current.x, current.y, current.idx
    if visitedArr[cidx] ~= 1 then
      visitedArr[cidx] = 1
      cameFromArr[cidx] = current.prev
      if cidx == goalIdx then
        break -- If the goal node is reached, break out of the loop.
      end

      -- Check all eight neighbouring cells.
      local cz = tb:getHeightGrid(cx, cy)
      for i = 1, 8 do
        local d = searchDirs[i]
        local nx, ny = cx + d.x, cy + d.y
        if nx >= 0 and ny >= 0 and nx < xRes and ny < yRes then -- Ensure neighbour is within the grid.
          local nidx = ny * stride + nx
          if visitedArr[nidx] ~= 1 then
            -- Score the move to this neighbour.
            local dz = tb:getHeightGrid(nx, ny) - cz
            distVec:set(d.x, d.y, 0)
            local dist = distVec:length() * cellSize
            local moveCost, newAngle = getMovePenalty(current.dir, d, dz, dist, maxSlope, minRadius, current.angle, slopeAvoidance)
            local totalCost = costArr[cidx] + moveCost

            -- If the neighbour has not been visited, or total cost to reach it is less than existing cost, add it to open set.
            if not costArr[nidx] or totalCost < costArr[nidx] then
              costArr[nidx] = totalCost
              local node = allocNode()
              node.x, node.y, node.idx, node.cost, node.prev, node.dir, node.angle = nx, ny, nidx, totalCost, cidx, d, newAngle
              openSet:insert(totalCost, node)
            end
          end
        end
      end
    end
  end

  if not cameFromArr[goalIdx] then
    return {}, {} -- If the goal node is not reachable, return empty tables.
  end

  -- Reconstruct the path from the goal node to the start node.
  local path, cur, strideInv, ctr = {}, goalIdx, 1.0 / stride, 1
  while cur do
    local x = cur % stride
    local y = (cur - x) * strideInv
    pt.x, pt.y = x, y
    path[ctr] = te:gridToWorldByPoint2I(pt, tb)
    ctr = ctr + 1
    cur = cameFromArr[cur]
  end

  -- Reverse the path to get correct order.
  local numNodes = #path
  for i = 1, floor(numNodes * 0.5) do
    local idx = numNodes - i + 1
    path[i], path[idx] = path[idx], path[i]
  end

  -- Create a table of widths for the path, using only the base width as default (will be modified in post).
  local widths = table.new(numNodes, 0)
  for i = 1, numNodes do
    widths[i] = baseWidth
  end

  return path, widths
end

-- Generates an auto-generated road preview for a multi-waypoint spline.
local function generateAutoPreview(spline, autoParams, presetParams)
  local nodes = spline.nodes
  if #nodes < 2 then
    return -- We need at least two nodes to generate a path.
  end

  -- Iterate through the node-to-node segments, and generate the path for each.
  table.clear(pathNodes); table.clear(pathWidths)
  for i = 1, #nodes - 1 do
    local startPos, goalPos = vec3(nodes[i]), vec3(nodes[i + 1])

    -- Apply a small push off to the start position to minimise self-overlap
    if i > 1 then
      dir:set(goalPos.x - startPos.x, goalPos.y - startPos.y, 0)
      local len = dir:length()
      if len > 1e-4 then
        dir:normalize()
        startPos = startPos + dir * pushOffDistance
      end
    end

    -- Generate the path for this segment.
    local segNodes, segWidths = generateAutoPreviewSegment(startPos, goalPos, autoParams, presetParams)

    -- Avoid duplicate node at junction.
    if #pathNodes > 0 and #segNodes > 0 then
      if pathNodes[#pathNodes]:squaredDistance(segNodes[1]) < duplicateNodeTolSq then
        table.remove(segNodes, 1)
        table.remove(segWidths, 1)
      end
    end

    -- Add the nodes and widths for this segment, to the full path.
    for j = 1, #segNodes do
      local idx = #pathNodes + 1
      pathNodes[idx], pathWidths[idx] = segNodes[j], segWidths[j]
    end
  end

  -- Simplify the path by removing unneccesary nodes.
  rdp.simplifyNodesWidths(pathNodes, pathWidths, rdpTol)

  -- Widen the path at sharp curves (eg hairpins).
  applyHairpinWidening(presetParams, autoParams.widthBlend)

  -- Optimise the path elevations, so that the path conforms to the preset, and as close to the terrain as possible.
  local maxSlope = presetParams.maxSlope
  snapZsToSlopeEnvelope(maxSlope)
  relaxZsToTerrain(maxSlope)

  -- Interpolate the path nodes and widths to a fixed granularity.
  pathNodes, pathWidths = geom.catmullRomNodesWidthsOnly(pathNodes, pathWidths, interpGran, false)
  rdp.simplifyNodesWidths(pathNodes, pathWidths, rdpTolPost)
end

-- Creates an auto-generated spline from the preview.
local function createAutoRoad(spline, bankingStrength, autoBankFalloff)
  if #pathNodes < 2 then
    table.clear(pathNodes); table.clear(pathWidths)
    return -- If the path is degenerate, clear it but do not create the spline.
  end

  -- Simplify the path by removing unneccesary nodes.
  rdp.simplifyNodesWidths(pathNodes, pathWidths, rdpTol)

  -- Set the spline primary geometry to the path geometry.
  table.clear(spline.nodes); table.clear(spline.widths); table.clear(spline.nmls)
  for i = 1, #pathNodes do
    local p = pathNodes[i]
    spline.nodes[i], spline.widths[i], spline.nmls[i] = vec3(p), pathWidths[i], vec3(0, 0, 1)
  end
  spline.isDirty = true

  -- Set the auto banking for the spline.
  if bankingStrength > 0.0 then
    spline.isAutoBanking = true
    spline.bankStrength = bankingStrength
    spline.autoBankFalloff = autoBankFalloff
  end

  -- Clear the preview.
  table.clear(pathNodes); table.clear(pathWidths)
end

-- Handles the preview. Called once per frame.
local function handlePreview(spline)
  if not spline or #pathNodes < 1 then
    return -- If the spline is not valid, or the path is degenerate, do not draw the preview.
  end

  -- Draw the preview.
  render.renderPreviewRibbon(pathNodes, pathWidths)
end


-- Public interface.
M.isPreview =                                           isPreview
M.clearPreview =                                        clearPreview

M.generateAutoPreview =                                 generateAutoPreview
M.createAutoRoad =                                      createAutoRoad

M.handlePreview =                                       handlePreview

return M