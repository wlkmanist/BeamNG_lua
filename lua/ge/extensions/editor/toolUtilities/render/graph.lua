-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Speed-bar and AI navgraph rendering (roadArchitect / drivePath lineage): velocity bars/graph, navgraph node
-- picking and the world AI graph overlay. Split out of render.lua because only the graph/velocity tools use it.
-- Composite module: draws through the leaf primitive modules and owns its own scratch pool.

local M = {}

local geom = require('editor/toolUtilities/geom')
local styleCore = require('editor/toolUtilities/style')
local util = require('editor/toolUtilities/util')
local dbgDraw = require('utils/debugDraw')
local spheres = require('editor/toolUtilities/render/spheres')
local lines = require('editor/toolUtilities/render/lines')
local tris = require('editor/toolUtilities/render/tris')
local markup = require('editor/toolUtilities/render/markup')

-- Constants.
local velocityGran = 10 -- The granularity of the velocity rendering.
local style = styleCore.getStyle()

-- Scratch pool (owned by this module).
local tmp1, tmp2, tmp3, tmp4 = vec3(), vec3(), vec3(), vec3()

-- Renders the velocities for the given spline.
-- [spline - The spline to render the velocities for.]
-- [isBarsLimit - Whether the velocities are limits, or actual values.]
-- [unitsInt - The units to render the velocities in.]
local function renderVelocities(spline, isBarsLimit, unitsInt, elevScale)
  if not spline or #spline.nodes < 2 then
    return -- Early return if no spline or too short to render.
  end

  -- Render the bar ceiling spline.
  local valsMs = isBarsLimit and spline.velLimits or spline.vels
  local barScale = geom.getBarScale()
  local pts, vals = geom.catmullRomNodesWidthsOnly(spline.barPoints, valsMs, velocityGran, spline.isLoop)
  for j = 1, #pts - 1 do
    local p0, p1 = pts[j], pts[j + 1]
    tmp1:set(p0.x, p0.y, p0.z)
    util.vertRaycast(tmp1)
    tmp2:set(p0.x, p0.y, tmp1.z + vals[j] * barScale)
    tmp3:set(p1.x, p1.y, p1.z)
    util.vertRaycast(tmp3)
    tmp4:set(p1.x, p1.y, tmp3.z + vals[j + 1] * barScale)
    local elev = tmp2.z - tmp1.z
    lines.drawDropLine(tmp2, tmp1, elev, elevScale)
    lines.drawBarCeilingLine(tmp2, tmp4, elev, elevScale)
  end

  -- Render the velocity markups.
  for i = 1, #spline.barPoints do
    local finalVel, units = valsMs[i], 'm/s'
    if unitsInt == 1 then
      finalVel, units = util.msToMph(valsMs[i]), 'mph'
    elseif unitsInt == 2 then
      finalVel, units = util.msToKph(valsMs[i]), 'kph'
    end
    markup.markupVelocity(spline.barPoints[i], finalVel, isBarsLimit, units)
  end
end

-- Renders the velocities for the given graph path.
-- [spline - The spline to render the velocities for.]
-- [unitsInt - The units to render the velocities in.]
-- [elevScale - The scale factor for elevation markups.]
-- [isBarsLimit - Whether to use velLimits (true) or vels (false) for bar heights.]
local function renderVelocitiesGraph(spline, unitsInt, elevScale, isBarsLimit)
  if not spline or #spline.graphNodes < 2 then
    return -- Early return if no spline or too short to render.
  end

  -- Determine which points to use for rendering the spline path
  local pathPoints, pathVals
  if spline.divPoints and #spline.divPoints > 1 then
    -- Use the computed navgraph path for smooth spline rendering
    pathPoints = spline.divPoints
    -- For navgraph path, we need to interpolate velocities along the path
    local valsMs = isBarsLimit and spline.velLimits or spline.vels
    if not valsMs or #valsMs == 0 then
      valsMs = spline.vels
    end
    if not valsMs or #valsMs == 0 then
      valsMs = {}
      for i = 1, #spline.graphNodes do
        valsMs[i] = 30.0
      end
    end

    -- Interpolate velocities between selected nodes.
    pathVals = {}
    local numPathPoints = #pathPoints
    local numSelectedNodes = #spline.graphNodes

    -- Find which navgraph path points correspond to selected nodes.
    local selectedNodeIndices = {}
    for i = 1, numSelectedNodes do
      local selectedNodeKey = spline.graphNodes[i]
      for j = 1, numPathPoints do
        if spline.graphPath[j] == selectedNodeKey then
          selectedNodeIndices[i] = j
          break
        end
      end
    end

    -- Interpolate velocities between selected nodes.
    for i = 1, numPathPoints do
      -- Find the two selected nodes that bound this path point.
      local leftNodeIdx, rightNodeIdx = nil, nil
      local leftDist, rightDist = math.huge, math.huge

      for j = 1, numSelectedNodes do
        local selectedIdx = selectedNodeIndices[j]
        if selectedIdx then
          if selectedIdx <= i and (i - selectedIdx) < leftDist then
            leftNodeIdx = j
            leftDist = i - selectedIdx
          end
          if selectedIdx >= i and (selectedIdx - i) < rightDist then
            rightNodeIdx = j
            rightDist = selectedIdx - i
          end
        end
      end

      -- Interpolate between the bounding nodes
      if leftNodeIdx and rightNodeIdx and leftNodeIdx ~= rightNodeIdx then
        -- Linear interpolation between two different nodes
        local leftVel = valsMs[leftNodeIdx] or 30.0
        local rightVel = valsMs[rightNodeIdx] or 30.0
        local leftPathIdx = selectedNodeIndices[leftNodeIdx]
        local rightPathIdx = selectedNodeIndices[rightNodeIdx]
        local t = (i - leftPathIdx) / (rightPathIdx - leftPathIdx)
        pathVals[i] = leftVel + (rightVel - leftVel) * t
      elseif leftNodeIdx then
        -- At or after the last selected node, use its velocity
        pathVals[i] = valsMs[leftNodeIdx] or 30.0
      elseif rightNodeIdx then
        -- At or before the first selected node, use its velocity
        pathVals[i] = valsMs[rightNodeIdx] or 30.0
      else
        -- Fallback (shouldn't happen)
        pathVals[i] = 30.0
      end
    end
  else
    -- Fallback to using just the selected nodes
    pathPoints = spline.barPoints
    local valsMs = isBarsLimit and spline.velLimits or spline.vels
    if not valsMs or #valsMs == 0 then
      valsMs = spline.vels
    end
    if not valsMs or #valsMs == 0 then
      valsMs = {}
      for i = 1, #spline.barPoints do
        valsMs[i] = 30.0
      end
    end
    pathVals = valsMs
  end

  -- Render the bar ceiling spline using the path points
  local barScale = geom.getBarScale()
  local pts, vals = geom.catmullRomNodesWidthsOnly(pathPoints, pathVals, velocityGran, spline.isLoop)
  for j = 1, #pts - 1 do
    local p0, p1 = pts[j], pts[j + 1]
    tmp1:set(p0.x, p0.y, p0.z)
    util.vertRaycast(tmp1)
    tmp2:set(p0.x, p0.y, tmp1.z + vals[j] * barScale)
    tmp3:set(p1.x, p1.y, p1.z)
    util.vertRaycast(tmp3)
    tmp4:set(p1.x, p1.y, tmp3.z + vals[j + 1] * barScale)
    local elev = tmp2.z - tmp1.z
    lines.drawDropLine(tmp2, tmp1, elev, elevScale)
    lines.drawBarCeilingLine(tmp2, tmp4, elev, elevScale)
  end

  -- Render the velocity markups only at selected nodes (barPoints)
  local valsMs = isBarsLimit and spline.velLimits or spline.vels
  if not valsMs or #valsMs == 0 then
    valsMs = spline.vels
  end
  if not valsMs or #valsMs == 0 then
    valsMs = {}
    for i = 1, #spline.barPoints do
      valsMs[i] = 30.0
    end
  end
  for i = 1, #spline.barPoints do
    local finalVel, units = valsMs[i], 'm/s'
    if unitsInt == 1 then
      finalVel, units = util.msToMph(valsMs[i]), 'mph'
    elseif unitsInt == 2 then
      finalVel, units = util.msToKph(valsMs[i]), 'kph'
    end
    markup.markupVelocity(spline.barPoints[i], finalVel, isBarsLimit, units)
  end
end

-- Renders the nav graph.
local function renderNavGraph(navGraph, hoverNode)
  if not navGraph then
    return -- No nav graph to render.
  end

  -- Render the sphere-to-sphere ribbons.
  local lns = navGraph.lines
  for i = 1, #lns do
    local line = lns[i]
    local pL, pR, qL, qR, cL, cR = line.pL, line.pR, line.qL, line.qR, line.cL, line.cR
    tris.drawTriCulled(pR, pL, qR, style.colourNavGraphRibbon) -- Ribbon surface with navgraph color.
    tris.drawTriCulled(pL, qL, qR, style.colourNavGraphRibbon)
    lines.drawNavLine(cL, cR) -- Center line between the two spheres.
  end

  -- Render the nav graph nodes with glow like spline nodes.
  local nodes = navGraph.nodes
  for _, v in pairs(nodes) do
    if hoverNode and v == hoverNode then
      -- Render hovered node with pulsing effect
      spheres.drawHoverNavGraphNode(v)
    else
      -- Render normal node
      local camPos = core_camera.getPosition()
      local dScale = spheres.getSphereScale(v:distance(camPos))
      dbgDraw.drawSphere(v, dScale * (style.sphereNode + style.nodeGlowScale), style.colourNodeGlow) -- Glow pass.
      dbgDraw.drawSphere(v, dScale * style.sphereNode, style.colourNode) -- Core pass.
    end
  end
end

-- Renders the given graph path.
local function renderGraphPath(path, graphData)
  local graphNodes = graphData.nodes
  local pathLength = #path
  for i = 1, pathLength do
    spheres.drawPathNode(graphNodes[path[i]])
  end
  for i = 1, pathLength - 1 do
    local p0, p1 = graphNodes[path[i]], graphNodes[path[i + 1]]
    lines.drawPathLine(p0, p1)
  end
end

-- Renders the chosen navGraph nodes with special indicators.
local function renderChosenNodes(nodes, graphData)
  local graphNodes = graphData.nodes
  for i = 1, #nodes do
    local p = graphNodes[nodes[i]]
    spheres.drawSelectedNavGraphNode(p) -- Larger sphere to show it is part of the selection and not just the path. Thus it can be removed.
    markup.markupPathNode(p, i) -- Markup to index the node on screen.
  end
end

local function renderWorldGraphNodes(graph, drawRadiusMeters)
  if not graph or not graph.nodeCount or graph.nodeCount < 1 then
    return
  end
  local kdNodes = graph.kdNodes
  if not kdNodes then
    return
  end

  local camPos = core_camera.getPosition()
  local rSq = drawRadiusMeters * drawRadiusMeters

  local nodeX, nodeY, nodeZ, nodeDepth = graph.nodeX, graph.nodeY, graph.nodeZ, graph.nodeDepth
  local nodeGroupId = graph.nodeGroupId
  local groupCols = graph.groupCols
  local defaultCol = graph.defaultNodeCol or style.colourNode
  local sphereRadius = graph.sphereRadius or 1.5
  local tmp = tmp4
  local zLift = 0.05 -- reduce z-fighting on terrain lines

  local qx0, qy0 = camPos.x - drawRadiusMeters, camPos.y - drawRadiusMeters
  local qx1, qy1 = camPos.x + drawRadiusMeters, camPos.y + drawRadiusMeters

  -- Draw spheres at top points (nodeZ + nodeDepth) within view radius.
  for id in kdNodes:queryNotNested(qx0, qy0, -1.7e308, qx1, qy1, 1.7e308) do
    local x = nodeX[id]
    local y = nodeY[id]
    local dx = x - camPos.x
    local dy = y - camPos.y
    if dx * dx + dy * dy <= rSq then
      local zT = (nodeZ[id] or 0.0) + (nodeDepth[id] or 0.0) + zLift
      tmp:set(x, y, zT)
      local col = defaultCol
      if nodeGroupId then
        local gid = nodeGroupId[id]
        if gid and groupCols and groupCols[gid] then
          col = groupCols[gid]
        end
      end
      dbgDraw.drawSphere(tmp, sphereRadius, col)
    end
  end
end

local function renderWorldGraphNodeBackdrops(graph, drawRadiusMeters, nodeIds, nodeIdCount, sphereRadiusMul, col)
  if not graph or not graph.nodeCount or graph.nodeCount < 1 then
    return
  end
  if not nodeIds or not nodeIdCount or nodeIdCount < 1 then
    return
  end
  local camPos = core_camera.getPosition()
  local rSq = drawRadiusMeters * drawRadiusMeters

  local nodeX, nodeY, nodeZ, nodeDepth = graph.nodeX, graph.nodeY, graph.nodeZ, graph.nodeDepth
  local sphereRadius = graph.sphereRadius or 1.5
  local tmp = tmp4
  local zLift = 0.05 -- reduce z-fighting on terrain lines

  local mul = sphereRadiusMul or 1.6
  col = col or style.colourNodeDull

  for i = 1, nodeIdCount do
    local id = nodeIds[i] or 0
    if id > 0 then
      local x = nodeX[id]
      local y = nodeY[id]
      local dx = x - camPos.x
      local dy = y - camPos.y
      if dx * dx + dy * dy <= rSq then
        local zT = (nodeZ[id] or 0.0) + (nodeDepth[id] or 0.0) + zLift
        tmp:set(x, y, zT)
        dbgDraw.drawSphere(tmp, sphereRadius * mul, col)
      end
    end
  end
end


-- Public interface.
M.renderVelocities = renderVelocities
M.renderVelocitiesGraph = renderVelocitiesGraph
M.renderNavGraph = renderNavGraph
M.renderGraphPath = renderGraphPath
M.renderChosenNodes = renderChosenNodes
M.renderWorldGraphNodes = renderWorldGraphNodes
M.renderWorldGraphNodeBackdrops = renderWorldGraphNodeBackdrops

return M