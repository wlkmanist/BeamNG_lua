-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Simple pacenote generator based on left/right direction changes from driveline points.

local M = {}
local logTag = 'pacenoteGenerator'

local sqrt, acos, deg, abs = math.sqrt, math.acos, math.deg, math.abs

M.defaultParams = {
  lookAheadContext = 7,
  straightThreshold = 5.0,
  mergeDistanceThreshold = 0.2,
  maxSimplifyIterations = 10
}

local function sign(value)
  return value >= 0 and 1 or -1
end

-- Calculate circle properties from 3 points
-- Returns: center position and angle
local function circleCenterAndAngle(p1, p2, p3)
  local d1 = p1 - p3
  local d2 = p2 - p3
  local asql = d1:squaredLength()
  local bsql = d2:squaredLength()
  local adotb = d1:dot(d2)

  -- Calculate lengths
  local d1l = sqrt(asql)
  local d2l = sqrt(bsql)

  -- Calculate center
  local condVec = d1:cross(d2)
  local condVecSqLen = condVec:squaredLength()
  local center = p3 + ((bsql * (asql - adotb)) * d1 - (asql * (adotb - bsql)) * d2) / (2 * condVecSqLen + 1e-30)

  -- Calculate angle
  local angleCos = adotb / (d1l * d2l + 1e-30)
  local angleRad = acos(clamp(angleCos, -1, 1))
  local angle = deg(angleRad) * 2

  return center, angle
end

-- Compute direction and angle data for each node
local function computeNodeData(route, params)
  for i = 2, #route - 1 do
    local n = route[i]
    local context = params.lookAheadContext
    local ip1 = clamp(i - context, 1, #route)
    local ip2 = clamp(i + context, 1, #route)
    local p1, p2, p3 = route[ip1].pos, route[i].pos, route[ip2].pos

    -- Work in 2D (ignore Z for direction calculation)
    local p1z, p2z, p3z = p1:z0(), p2:z0(), p3:z0()

    local center, angle = circleCenterAndAngle(p1z, p2z, p3z)
    center.z = p2.z
    n.center = center
    n.nextPos = route[i + 1].pos
    n.length = n.pos:distance(n.nextPos)

    n.radius = p1:distance(center)

    -- Generator-only straight filtering. Structured pacenotes still only emit
    -- left/right corner directions; straight-ish spans are not returned.
    local cross = (p3z - p2z):cross(p2z - p1z).z
    if abs(angle) < params.straightThreshold then
      n.direction = ""
      n.angle = 0
    else
      n.direction = cross > 0 and " right" or " left"
      n.angle = angle * sign(cross) -- positive angle is right, negative is left
    end
  end
end

-- Aggregate data for a corner (multiple nodes)
local function computeCornerData(corner)
  if not corner then return end
  if not next(corner.nodes) then return end

  corner.length = 0
  corner.angle = 0

  for _, n in ipairs(corner.nodes) do
    corner.length = corner.length + n.length
    corner.angle = corner.angle + n.angle
  end

  -- Use first node's direction as corner direction
  corner.direction = corner.nodes[1].direction
end

-- Split route into corners based on direction changes
local function splitRouteIntoCorners(route)
  local corners = {}
  local corner

  for i = 2, #route - 3 do
    local nCurr = route[i]
    local nNext = route[i + 1]
    corner = corner or { nodes = {} }
    table.insert(corner.nodes, nCurr)

    -- Split when direction changes.
    if nCurr.direction ~= nNext.direction then
      computeCornerData(corner)
      table.insert(corners, corner)
      corner = nil
    end
  end

  return corners
end

-- Merge consecutive corners with same direction
local function simplifyConsecutive(corners)
  local nodesMoved = 0
  local i = 1

  while i < #corners do
    local corner = corners[i]
    local cornerNext = corners[i + 1]

    if corner.direction == cornerNext.direction then
      -- Merge cornerNext into corner
      for _, node in ipairs(cornerNext.nodes) do
        nodesMoved = nodesMoved + 1
        table.insert(corner.nodes, node)
      end
      computeCornerData(corner)
      table.remove(corners, i + 1)
    else
      i = i + 1
    end
  end

  return nodesMoved
end

-- Merge straight spans that continue along the same line. This is only used by
-- devtool generation to avoid turning straight-ish driveline sections into
-- pacenote candidates.
local function simplifyStraightsExtendNext(corners, distanceThreshold)
  local movedTotal = 0
  local i = 0

  while i < #corners do
    i = i + 1
    local corner = corners[i]

    if corner.direction ~= "" then goto continue end

    local p1 = corner.nodes[1].pos
    local p2 = corner.nodes[#corner.nodes].pos

    local stillInline = true
    local movedCurr = 0
    local j = i + 1

    while j <= #corners do
      local cornerNext = corners[j]
      local movedNext = 0
      local k = 1

      while k <= #cornerNext.nodes do
        local node = cornerNext.nodes[k]
        local dist = node.pos:distanceToLine(p1, p2)

        if dist > distanceThreshold then
          stillInline = false
          break
        end

        table.insert(corner.nodes, node)
        table.remove(cornerNext.nodes, k)
        movedNext = movedNext + 1
      end

      movedCurr = movedCurr + movedNext
      if movedNext > 0 then computeCornerData(cornerNext) end
      if #cornerNext.nodes == 0 then table.remove(corners, j) end
      if not stillInline then break end
    end

    movedTotal = movedTotal + movedCurr
    if movedCurr > 0 then computeCornerData(corner) end
    ::continue::
  end

  return movedTotal
end

-- Simplify corners by merging consecutive segments
local function simplifyCorners(corners, params)
  log("I", logTag, string.format("Simplifying %d corners:", #corners))

  for i = 1, params.maxSimplifyIterations do
    local n = 0
    n = n + simplifyStraightsExtendNext(corners, params.mergeDistanceThreshold)
    n = n + simplifyConsecutive(corners)

    log("I", logTag, string.format(" - Phase %d: %d corners (%d nodes reassigned)", i, #corners, n))

    if n == 0 then break end -- Nothing left to do
  end
end

-- Main function: detect corners from a list of driveline points
-- @param pointList: array of driveline points with .pos property
-- @param params: optional parameter table (uses defaultParams if nil)
-- @return table with `sections` for debug drawing and `corners` for pacenote generation.
function M.detectCorners(pointList, params)
  -- Use default params if not provided
  params = params or {}
  params.lookAheadContext = params.lookAheadContext or M.defaultParams.lookAheadContext
  params.straightThreshold = params.straightThreshold or M.defaultParams.straightThreshold
  params.mergeDistanceThreshold = params.mergeDistanceThreshold or M.defaultParams.mergeDistanceThreshold
  params.maxSimplifyIterations = params.maxSimplifyIterations or M.defaultParams.maxSimplifyIterations

  if not pointList or #pointList < 3 then
    log("E", logTag, "detectCorners: pointList too short or nil")
    return { sections = {}, corners = {} }
  end

  -- Convert pointList to route format
  local route = {}
  for i, point in ipairs(pointList) do
    -- Handle both formats: tables with .pos property or direct vec3 objects
    local pos = point.pos or point
    table.insert(route, {
      pos = vec3(pos),
      id = i
    })
  end

  if #route < 3 then
    log("E", logTag, "detectCorners: route too short after conversion")
    return { sections = {}, corners = {} }
  end

  -- Compute node data (direction, angle)
  computeNodeData(route, params)

  -- Split into corners based on direction changes
  local corners = splitRouteIntoCorners(route)

  -- Simplify by merging consecutive segments
  simplifyCorners(corners, params)

  -- Format output. `sections` keeps straight spans for debug drawing;
  -- `corners` is the filtered input for generated pacenotes.
  local sections = {}
  local cornerCandidates = {}
  for _, corner in ipairs(corners) do
    if corner.nodes and #corner.nodes > 0 then
      local section = {
        pos = corner.nodes[1].pos,
        posEnd = corner.nodes[#corner.nodes].pos,
        direction = corner.direction,
        angle = corner.angle,
        length = corner.length,
        nodes = corner.nodes
      }
      table.insert(sections, section)
      if corner.direction ~= "" then
        table.insert(cornerCandidates, section)
      end
    end
  end

  log("I", logTag, string.format("Detected %d corners in %d sections from %d driveline points", #cornerCandidates, #sections, #pointList))

  return {
    sections = sections,
    corners = cornerCandidates,
  }
end

return M

