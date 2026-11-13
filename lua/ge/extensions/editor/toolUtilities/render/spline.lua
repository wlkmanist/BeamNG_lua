-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Spline/layer wire-frame + surface rendering for the spline-editing tools (the bulk of the old render.lua).
-- Composite module: draws through the leaf primitive modules (spheres / lines / tris / markup) and owns its own
-- scratch vector pool so it doesn't share mutable state with them.

local M = {}

-- Module dependencies.
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')
local spheres = require('editor/toolUtilities/render/spheres')
local lines = require('editor/toolUtilities/render/lines')
local tris = require('editor/toolUtilities/render/tris')
local markup = require('editor/toolUtilities/render/markup')

-- Constants.
local abs, min, max, floor, acos = math.abs, math.min, math.max, math.floor, math.acos
local normalLength = 5.0 -- The length of the normal line, in meters.
local numArcSegments = 16 -- The number of segments to use when drawing an arc.
local numArcSegmentsInv = 1.0 / numArcSegments
local halfWidthForMeshSplineVis = 2.0 -- The half-width to be used for mesh spline layer wire-frame visualisations, in meters.
local masterWireBinormalSpacing = 2 -- The spacing of the binormal lines on master wire rendering, in number of division points.
local homologationBinormalSpacing = 2 -- The spacing of the binormal lines on homologation rendering, in number of division points.
local raycastSurfBinormalSpacing = 2 -- The spacing of the binormal lines on raycast surface rendering, in number of division points.
local zRayLift = 3.0 -- The z-offset to lift the raycast points above the surface, before raycasting to the surface below, in meters.
local zRayOffset = 0.05 -- The z-offset to add to the ribbon points when raycasting to the surface below.
local zFloat = 0.05 -- The z-offset to add to the ribbon points when rendering the main ribbon wire-frame.
local zFloatLayer = 0.075 -- The z-offset to add to the ribbon points when rendering the layer wire-frame.
local globalUp = vec3(0, 0, 1)
local emptyTable = {}
local errorMetricsLookup = {
  [0] = 'eSlopeNorm',
  [1] = 'eRadiusNorm',
  [2] = 'eBankingNorm',
  [3] = 'eWidthNorm',
  [4] = 'eBlindCrestNorm',
  [5] = 'eVertRadiusNorm',
}

-- Scratch pool (owned by this module).
local finalPoints = {}
local bL, bR, tL, tR, tmp1, tmp2, tmp3, tmp4 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tmpA, tmpB, tmpC, pTemp, tmpTgt, tmpDir = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tmpTan, tmpBinormal, tmpOff, latVec1, latVec2 = vec3(), vec3(), vec3(), vec3(), vec3()
local tmpL1, tmpR1, tmpL2, tmpR2, tmpRef = vec3(), vec3(), vec3(), vec3(), vec3()
local swCenter1, swEdge1, swEdge2, tmpScale = vec3(), vec3(), vec3(), vec3()
local tmpPoints = {}
for i = 1, numArcSegments + 1 do
  tmpPoints[i] = vec3()
end
-- Cached terrain block; :getHeight on it is far cheaper than core_terrain.getTerrainHeight (which re-resolves the object every call).
local cachedTerrainBlock = nil

-- Function to draw a circular arc, to some granularity.
local function drawArc(center, isSelectedNode, a, b, axis, twistAngle)
  local distFromCen = normalLength * 0.97
  tmpA:setSub2(a, center) -- Vector from center to a.
  tmpA:normalize()
  tmpB:setSub2(b, center) -- Vector from center to b.
  tmpB:normalize()
  local angle = acos(tmpA:dot(tmpB)) -- The angle between the two vectors.
  local step = -sign2(twistAngle) * angle * numArcSegmentsInv
  for i = 1, numArcSegments + 1 do
    geom.rotateVecAroundAxisInlined(tmpA, axis, step * (i - 1), pTemp)
    tmpC:setScaled2(pTemp, distFromCen)
    tmpPoints[i]:setAdd2(center, tmpC)
  end
  local midIdx = floor(numArcSegments * 0.5)
  for i = 1, numArcSegments do
    lines.drawArcSegment(tmpPoints[i], tmpPoints[i + 1]) -- Draw the arc segments.
    if isSelectedNode and i == midIdx then
      markup.markupTwistAngle(tmpPoints[i], twistAngle)
    end
  end
end

-- Draw the rib points.
local function drawRibPoints(ribs, spline)
  local isHalfSpline = spline.tileSet ~= nil or spline.spacing ~= nil -- Detect if this is a sidewalk spline by checking for sidewalk-specific properties.
  if isHalfSpline then -- For half-splines, only draw right edge (odd-indexed ribs), and draw line from center node to rib point.
    local nodes = spline.nodes
    for j = 2, #ribs, 2 do
      local ribPoint = ribs[j]
      local centerNode = nodes[j * 0.5] -- Map rib index to node index (j=2->1, j=4->2, etc.)
      spheres.drawSphereRib(ribPoint)
      if centerNode then
        lines.drawRibLine(centerNode, ribPoint) -- Draw line from center to rib.
      end
    end
  else -- For full splines, draw both left and right ribs with connecting lines.
    for j = 1, #ribs, 2 do
      local p0, p1 = ribs[j], ribs[j + 1]
      spheres.drawSphereRib(p0)
      spheres.drawSphereRib(p1)
      lines.drawRibLine(p0, p1)
    end
  end
end

-- Draw the bar points.
local function drawBarPoints(bars, elevScale)
  local numBars = #bars
  if numBars > 1 then
    for j = 1, numBars do
      local pBar = bars[j]
      tmp1:set(pBar)
      util.vertRaycast(tmp1)
      local elevation = pBar.z - tmp1.z
      spheres.drawSphereBar(pBar)
      lines.drawDropLineThick(pBar, tmp1, elevation, elevScale)
    end
  end
end

-- Handles the rendering of splines.
-- hiddenNodeSet (optional): a set { [nodeIdx] = true } of selected-spline nodes whose fat sphere / highlight / elevation line are
-- suppressed. Used by heroRoad engineered corners, where a tight bend flings the PI node far off-road and an on-apex grip stands in
-- for it, so the stray node shouldn't also draw. Nil for every other tool.
-- noNames (optional): suppresses the name label on unselected splines. For networks of hundreds of links, where a label per link
-- buries the map in text. The selected spline keeps its own name/length.
local function handleSplineRendering(splines, splineIdx, nodeIdx, isGizmoActive, isUseRot, isShapeLocked, isShowElevation, isShowRibs, elevScale, hiddenNodeSet, noNames)
  -- Resolve the terrain block once per call (not per node): getTerrain() does a scenetree lookup, so keep it out of the loop.
  -- A level load replaces the block while this module lives on, so a cached one may be gone.
  local terrainBlock = cachedTerrainBlock
  if not (terrainBlock and simObjectExists(terrainBlock)) then
    terrainBlock = core_terrain and core_terrain.getTerrain()
    cachedTerrainBlock = terrainBlock
  end
  local nodeFn = spheres.drawSphereNode
  local dullFn = spheres.drawSphereNodeDull
  local highlightFn = spheres.drawSphereHighlightSelected
  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled and not spline.isLink then -- Only render enabled, non-linked splines.
      local nodes = spline.nodes
      local ribs, bars = spline.ribPoints or emptyTable, spline.barPoints or emptyTable
      if i == splineIdx then -- CASE #1: This is the selected spline, so draw the nodes and line segments in bold colours.
        local nNodes = #nodes
        for j = 1, nNodes do
          local node = nodes[j]
          -- Junction-linked tips are drawn smaller/red by drawLinkedTips — skip the fat node sphere.
          local tipLocked = (j == 1 and spline.jctIdStart) or (j == nNodes and spline.jctIdFinish)
          local hideNode = hiddenNodeSet and hiddenNodeSet[j]
          if not tipLocked and not hideNode then
            nodeFn(node)
          end
          if j == nodeIdx and not hideNode then
            tmp1:set(node)
            -- Elevation is measured against the TERRAIN, not a static-collision raycast: a raycast hits the tool's own
            -- collidable mesh (e.g. heroRoad's drivable deck sits right under the node), which rebuilds WITH the node, so
            -- the reading stayed pinned at a tiny constant as you lifted it. getTerrainHeight ignores that mesh. Fall back
            -- to the raycast only where there's no terrain (e.g. space maps).
            -- Sample the cached terrain block directly (much cheaper than core_terrain.getTerrainHeight, which re-resolves the
            -- object every call). No terrain (e.g. space maps) -> fall back to the raycast.
            local th = terrainBlock and terrainBlock:getHeight(tmp1)
            if th then tmp1.z = th else util.vertRaycast(tmp1) end
            local elevation = node.z - tmp1.z
            lines.drawElevDropLine(node, tmp1, elevation, elevScale)
            if isShowElevation and isGizmoActive and editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
              if abs(elevation) < 0.01 then elevation = 0.0 end -- Stops flickering text between 0 and -0 when changing node elevations.
              markup.markupElevation(node, elevation)
            end
          end
          if isGizmoActive and isUseRot and editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
            if not isShapeLocked or j == nodeIdx then
              local p1, p2 = nodes[max(j - 1, 1)], nodes[min(j + 1, #nodes)]
              tmpTgt:setSub2(p2, p1)
              tmpTgt:normalize()
              local normal = spline.nmls[j]
              local dp = globalUp:dot(tmpTgt)
              tmpScale:setScaled2(tmpTgt, dp)
              tmpRef:setSub2(globalUp, tmpScale)-- Stable reference normal (zero-twist) orthogonal to tangent.
              tmpRef:normalize()
              local twistAngle = geom.signedAngleAroundAxis(tmpRef, normal, tmpTgt)
              tmpScale:setScaled2(normal, normalLength)
              tmp1:setAdd2(node, tmpScale) -- True normal.
              lines.drawNormalLine(node, tmp1)
              tmpScale:setScaled2(tmpRef, normalLength)
              tmp2:setAdd2(node, tmpScale) -- Ref normal.
              lines.drawRefNormalLine(node, tmp2)
              tmp3:setSub2(node, tmp1)
              tmp4:setSub2(node, tmp2)
              tmpDir:setCross(tmp3, tmp4)
              tmpDir:normalize()
              drawArc(node, j == nodeIdx, tmp1, tmp2, -sign(twistAngle) * tmpDir, twistAngle)
            end
          end
        end
        if #nodes > 1 then
          local pStart, pEnd = nodes[1], nodes[#nodes]
          local name = spline.name
          local roadLength = spline.roadLength or 0.0
          local freeStart = not spline.jctIdStart
          local freeFinish = not spline.jctIdFinish
          -- Name/length only at free tips — junction mouths already have enough chrome.
          if freeStart then
            markup.markupSplineName(pStart, name)
            markup.markupRoadLength(pStart, roadLength)
          end
          if not spline.isLoop and freeFinish then
            markup.markupRoadLength(pEnd, roadLength)
          end
        end

        -- Draw the node handles.
        if isShowRibs then
        drawRibPoints(ribs, spline) -- Rib points (appear at either side of the node, and control width-related properties).
        end
        drawBarPoints(bars, elevScale) -- Bar points (appear above the node and control height-related properties).
      else -- CASE #2: This is an unselected spline, so draw the nodes and line segments in dull colours.
        local nNodes = #nodes
        for j = 1, nNodes do
          local tipLocked = (j == 1 and spline.jctIdStart) or (j == nNodes and spline.jctIdFinish)
          if not tipLocked then
            dullFn(nodes[j])
          end
        end

        -- Draw the start markup, if there are at least two nodes and the start tip is free.
        if #nodes > 1 and not spline.jctIdStart and not noNames then
          markup.markupSplineName(nodes[1], spline.name)
        end
      end
    end
  end

  -- Render the selected node highlight, if everything is valid.
  if splineIdx and nodeIdx and splines[splineIdx] then
    local spline = splines[splineIdx]
    local n = spline.nodes and #spline.nodes or 0
    local tipLocked = (nodeIdx == 1 and spline.jctIdStart) or (nodeIdx == n and spline.jctIdFinish)
    if nodeIdx >= 1 and nodeIdx <= n and spline.isEnabled and not spline.isLink and not tipLocked
        and not (hiddenNodeSet and hiddenNodeSet[nodeIdx]) then
      highlightFn(spline.nodes[nodeIdx])
    end
  end
end

-- Renders the wire-frame for the given layer.
-- [Layer - The layer to render.]
-- [Spline - The spline which contains the layer.]
local function renderLayer(layer, spline, isRaycast, binormalSpacing)
  local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
  local layerPosition = layer.position
  local numDiv = #divPoints
  for j = 1, numDiv do
    local p = finalPoints[j] or vec3()
    tmpOff:setScaled2(binormals[j], layerPosition * divWidths[j] * 0.5)
    p:setAdd2(divPoints[j], tmpOff)
    if isRaycast then
      tmp1:set(p)
      util.vertRaycast(tmp1)
      p.z = tmp1.z
    end
    finalPoints[j] = p
  end

  -- Draw the wire-frame for the selected layer, to required specification.
  if layer.isTrackWidth and not layer.isLink then -- CASE #1: Width-track layer.
    for j = 1, numDiv - 1, binormalSpacing do
      local jPlusOne = j + binormalSpacing
      if jPlusOne <= numDiv then
        latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
        latVec2:setScaled2(binormals[jPlusOne], divWidths[jPlusOne] * 0.5)
        local p1, p2 = finalPoints[j], finalPoints[jPlusOne] -- The two div points.
        bL:setSub2(p1, latVec1) -- The quadrilateral corner points.
        bL.z = bL.z + zFloat
        bR:setAdd2(p1, latVec1)
        bR.z = bR.z + zFloat
        tL:setSub2(p2, latVec2)
        tL.z = tL.z + zFloat
        tR:setAdd2(p2, latVec2)
        tR.z = tR.z + zFloat

        -- Draw all lines at spacing intervals for performance.
        lines.drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        lines.drawWireFrameLine(bR, tR)
        lines.drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
      end
    end
  else -- CASE #2: Fixed-width layer.
    for j = 1, numDiv - 1, binormalSpacing do
      local jPlusOne = j + binormalSpacing
      if jPlusOne <= numDiv then
        local layerHalfWidth = layer.isLink and halfWidthForMeshSplineVis or (layer.width or 1) * 0.5 -- Special default fixed width for linked splines.
        latVec1:setScaled2(binormals[j], layerHalfWidth)
        latVec2:setScaled2(binormals[jPlusOne], layerHalfWidth)
        local p1, p2 = finalPoints[j], finalPoints[jPlusOne] -- The back and front points for this line segment.
        bL:setAdd2(p1, latVec1)
        bL.z = bL.z + zFloat
        bR:setSub2(p1, latVec1)
        bR.z = bR.z + zFloat
        tL:setAdd2(p2, latVec2)
        tL.z = tL.z + zFloat
        tR:setSub2(p2, latVec2)
        tR.z = tR.z + zFloat

        -- Draw all lines at spacing intervals for performance.
        lines.drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        lines.drawWireFrameLine(bR, tR)
        lines.drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
      end
    end
  end
end

-- Renders the wire-frame for a master spline layer without applying binormal offset.
-- [Layer - The layer to render.]
-- [Spline - The spline which contains the layer.]
local function renderMasterLayer(layer, spline, isRaycast, binormalSpacing)
  local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
  local numDiv = #divPoints
  for j = 1, numDiv do
    local p = finalPoints[j] or vec3()
    p:set(divPoints[j]) -- No binormal offset applied
    if isRaycast then
      tmp1:set(p)
      util.vertRaycast(tmp1)
      p.z = tmp1.z
    end
    finalPoints[j] = p
  end

  -- Draw the wire-frame for the selected layer, to required specification.
  if layer.isTrackWidth then -- CASE #1: Width-track layer.
    for j = 1, numDiv - 1, binormalSpacing do
      local jPlusOne = j + binormalSpacing
      if jPlusOne <= numDiv then
        latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
        latVec2:setScaled2(binormals[jPlusOne], divWidths[jPlusOne] * 0.5)
        local p1, p2 = finalPoints[j], finalPoints[jPlusOne] -- The two div points.
        bL:setSub2(p1, latVec1) -- The quadrilateral corner points.
        bL.z = bL.z + zFloatLayer
        bR:setAdd2(p1, latVec1)
        bR.z = bR.z + zFloatLayer
        tL:setSub2(p2, latVec2)
        tL.z = tL.z + zFloatLayer
        tR:setAdd2(p2, latVec2)
        tR.z = tR.z + zFloatLayer

        -- Draw all lines at spacing intervals for performance
        lines.drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        lines.drawWireFrameLine(bR, tR)
        lines.drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
      end
    end
  else -- CASE #2: Fixed-width layer.
    for j = 1, numDiv - 1, binormalSpacing do
      local jPlusOne = j + binormalSpacing
      if jPlusOne <= numDiv then
        local layerHalfWidth = (layer.width or 1) * 0.5
        latVec1:setScaled2(binormals[j], layerHalfWidth)
        latVec2:setScaled2(binormals[jPlusOne], layerHalfWidth)
        local p1, p2 = finalPoints[j], finalPoints[jPlusOne] -- The back and front points for this line segment.
        bL:setAdd2(p1, latVec1)
        bL.z = bL.z + zFloatLayer
        bR:setSub2(p1, latVec1)
        bR.z = bR.z + zFloatLayer
        tL:setAdd2(p2, latVec2)
        tL.z = tL.z + zFloatLayer
        tR:setSub2(p2, latVec2)
        tR.z = tR.z + zFloatLayer

        -- Draw all lines at spacing intervals for performance
        lines.drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        lines.drawWireFrameLine(bR, tR)
        lines.drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
      end
    end
  end
end

-- Renders the shells of the given splines (just a basic wireframe with markup for when tool is inactive).
local function renderShells(splines)
  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled and not spline.isLink then
      local divPoints = spline.divPoints
      local numDivPoints = #divPoints
      local pts = spline.isPolyline and spline.nodes or divPoints
      local n = #pts
      local last = (spline.isPolyline and spline.isLoop) and n or n - 1
      for j = 1, last do
        lines.drawSplineLineDull(pts[j], pts[j % n + 1])
      end

      local nodes = spline.nodes
      for j = 1, #nodes do
        spheres.drawSphereNodeDull(nodes[j])
      end

      if numDivPoints > 1 then
        markup.markupSplineName(divPoints[1], spline.name) -- One markup at the start tip, to indicate which spline this is.
      end
    end
  end
end

-- Renders the wire-frame for half splines.
local function renderHalfSplineWireFrame(splines, selSplineIdx, binormalSpacing)
  -- Only render wireframe for the selected spline.
  local spline = splines[selSplineIdx]
  if not spline or not spline.isEnabled then
    return -- No spline to render or spline is not enabled.
  end

  local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
  for j = 1, #divPoints - 1, binormalSpacing do
    local jPlusOne = j + binormalSpacing
    if jPlusOne <= #divPoints then
      latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
      latVec2:setScaled2(binormals[jPlusOne], divWidths[jPlusOne] * 0.5)
      local p1, p2 = divPoints[j], divPoints[jPlusOne] -- The two div points.
      swCenter1:set(p1) -- Center point at j.
      swCenter1.z = swCenter1.z + zRayOffset
      swEdge1:setAdd2(p1, latVec1) -- Right edge at j.
      swEdge1.z = swEdge1.z + zRayOffset
      swEdge2:setAdd2(p2, latVec2) -- Right edge at j + 1.
      swEdge2.z = swEdge2.z + zRayOffset

      -- Draw all lines at spacing intervals for performance
      lines.drawWireFrameLine(swEdge1, swEdge2) -- Draw the right edge line.
      lines.drawWireFrameLine(swCenter1, swEdge1) -- Draw the lateral lines.
    end
  end
end

-- Renders a wire-frame outline for the given splines.
local function renderWireframeRibbons(splines)
  if not splines or #splines < 1 then
    return -- Early return if no splines to render.
  end

  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled then
      -- Render the nodes.
      local nodes = spline.nodes
      for j = 1, #nodes do
        spheres.drawSphereNodeDull(nodes[j])
      end

      -- Draw markups.
      local pStart, pEnd = nodes[1], nodes[#nodes]
      markup.markupStart(pStart)
      markup.markupEnd(pEnd)
      markup.markupSplineName(pStart, spline.name)

      -- Render the wireframe surface.
      local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
      for j = 1, #divPoints - 1, masterWireBinormalSpacing do
        local jPlusOne = j + masterWireBinormalSpacing
        if jPlusOne <= #divPoints then
          latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
          latVec2:setScaled2(binormals[jPlusOne], divWidths[jPlusOne] * 0.5)
          local p1 = divPoints[j]
          bL:setSub2(p1, latVec1) -- The quadrilateral bottom left point.
          bL.z = bL.z + zRayOffset
          bR:setAdd2(p1, latVec1) -- The quadrilateral bottom right point.
          bR.z = bR.z + zRayOffset
          local p2 = divPoints[jPlusOne]
          tL:setSub2(p2, latVec2) -- The quadrilateral top left point.
          tL.z = tL.z + zRayOffset
          tR:setAdd2(p2, latVec2) -- The quadrilateral top right point.
          tR.z = tR.z + zRayOffset

          -- Draw all lines at spacing intervals for performance
          lines.drawWireFrameLine3(bL, tL) -- Draw the wire-frame side lines.
          lines.drawWireFrameLine3(bR, tR)
          lines.drawWireFrameLine3(bL, bR) -- Draw the wire-frame front and back lines.
        end
      end
    end
  end
end

-- Renders the wire-frame for Master Splines, with heatmap surface for selected spline.
local function renderHomologatedSurface(splines, selSplineIdx)
  if #splines < 1 then
    return -- Early return if no splines to render.
  end

  -- Rendear each spline in the given collection.
  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled then
      if i == selSplineIdx then -- Heatmap rendering only applies to the selected spline.
        local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
        local visModeIdx = spline.splineAnalysisMode
        local metric = spline[errorMetricsLookup[visModeIdx]]
        for j = 1, #divPoints - 1, homologationBinormalSpacing do
          local jPlus1 = j + homologationBinormalSpacing
          if jPlus1 <= #divPoints then
            latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
            latVec2:setScaled2(binormals[jPlus1], divWidths[jPlus1] * 0.5)
            local p1 = divPoints[j]
            bL:setSub2(p1, latVec1) -- The quadrilateral bottom left point.
            bL.z = bL.z + zRayOffset
            bR:setAdd2(p1, latVec1) -- The quadrilateral bottom right point.
            bR.z = bR.z + zRayOffset
            local p2 = divPoints[jPlus1]
            tL:setSub2(p2, latVec2) -- The quadrilateral top left point.
            tL.z = tL.z + zRayOffset
            tR:setAdd2(p2, latVec2) -- The quadrilateral top right point.
            tR.z = tR.z + zRayOffset

            -- Draw all lines at spacing intervals for performance
            lines.drawWireFrameLine2(bL, tL) -- Render the wire-frame side lines.
            lines.drawWireFrameLine2(bR, tR)
            lines.drawWireFrameLine2(bL, bR) -- Render the wire-frame front and back lines.

            -- Draw the spline surface using a heatmap.
            local t = metric[j] or 0.0
            local r, g, b = util.getHueBasedColour255(t)
            local col = color(r, g, b, 255)
            tris.drawTriCulled(bL, bR, tL, col)
            tris.drawTriCulled(bR, bL, tL, col)
            tris.drawTriCulled(tL, bR, tR, col)
            tris.drawTriCulled(bR, tL, tR, col)
          end
        end
      else -- Non-selected spline.
        local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
        for j = 1, #divPoints - 1, homologationBinormalSpacing do
          local jPlus1 = j + homologationBinormalSpacing
          if jPlus1 <= #divPoints then
            latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
            latVec2:setScaled2(binormals[jPlus1], divWidths[jPlus1] * 0.5)
            local p1 = divPoints[j]
            bL:setSub2(p1, latVec1) -- The quadrilateral bottom left point.
            bL.z = bL.z + zRayOffset
            bR:setAdd2(p1, latVec1) -- The quadrilateral bottom right point.
            bR.z = bR.z + zRayOffset
            local p2 = divPoints[jPlus1]
            tL:setSub2(p2, latVec2) -- The quadrilateral top left point.
            tL.z = tL.z + zRayOffset
            tR:setAdd2(p2, latVec2) -- The quadrilateral top right point.
            tR.z = tR.z + zRayOffset

            -- Draw all lines at spacing intervals for performance
            lines.drawWireFrameLine3(bL, tL)
            lines.drawWireFrameLine3(bR, tR)
            lines.drawWireFrameLine3(bL, bR)
          end
        end
      end
    end
  end
end

-- Renders a quadrilateral surface with raycasted z values.
local function renderDrivePathSurface(spline)
  if not spline then
    return -- Early return if no spline to render.
  end

  local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
  if not spline.isLink then
    for j = 1, #divPoints - 1, raycastSurfBinormalSpacing do
      local jPlus1 = j + raycastSurfBinormalSpacing
      if jPlus1 <= #divPoints then
        latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
        latVec2:setScaled2(binormals[jPlus1], divWidths[jPlus1] * 0.5)
        local p1 = divPoints[j]
        bL:setSub2(p1, latVec1) -- The quadrilateral bottom left point.
        bL.z = bL.z + zRayOffset
        bR:setAdd2(p1, latVec1) -- The quadrilateral bottom right point.
        bR.z = bR.z + zRayOffset
        local p2 = divPoints[jPlus1]
        tL:setSub2(p2, latVec2) -- The quadrilateral top left point.
        tL.z = tL.z + zRayOffset
        tR:setAdd2(p2, latVec2) -- The quadrilateral top right point.
        tR.z = tR.z + zRayOffset
        tmp1:set(bL.x, bL.y, bL.z + zRayLift)
        util.vertRaycast(tmp1)
        bL.z = tmp1.z + zRayOffset
        tmp2:set(bR.x, bR.y, bR.z + zRayLift)
        util.vertRaycast(tmp2)
        bR.z = tmp2.z + zRayOffset
        tmp3:set(tL.x, tL.y, tL.z + zRayLift)
        util.vertRaycast(tmp3)
        tL.z = tmp3.z + zRayOffset
        tmp4:set(tR.x, tR.y, tR.z + zRayLift)
        util.vertRaycast(tmp4)
        tR.z = tmp4.z + zRayOffset

        -- Draw all lines at spacing intervals for performance
        lines.drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        lines.drawWireFrameLine(bR, tR)
        lines.drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
      end
    end
  end
end

-- Renders the give preview ribbon.
local function renderPreviewRibbon(nodes, widths)
  -- Draw the nodes.
  local numNodes = #nodes
  for i = 1, numNodes do
    spheres.drawSphereNode(nodes[i])
  end

  -- Draw the wire frame surface.
  for i = 1, numNodes - 1 do
    local i0, i2, i3 = max(1, i - 1), min(numNodes, i + 1), min(numNodes, i + 2)
    local p0, p1, p2, p3 = nodes[i0], nodes[i], nodes[i2], nodes[i3]

    -- Offset p1.
    tmpTan:setSub2(p2, p0)
    tmpTan:normalize()
    tmpBinormal:set(tmpTan.y, -tmpTan.x, 0)
    tmpBinormal:normalize()
    tmpOff:setScaled2(tmpBinormal, widths[i] * 0.5)
    tmpL1:setSub2(p1, tmpOff)
    tmpR1:setAdd2(p1, tmpOff)

    -- Offset p2.
    tmpTan:setSub2(p3, p1)
    tmpTan:normalize()
    tmpBinormal:set(tmpTan.y, -tmpTan.x, 0)
    tmpBinormal:normalize()
    tmpOff:setScaled2(tmpBinormal, widths[i2] * 0.5)
    tmpL2:setSub2(p2, tmpOff)
    tmpR2:setAdd2(p2, tmpOff)

    -- Draw the wire frame.
    lines.drawPreviewWireLine(tmpL1, tmpR1) -- Width spans.
    lines.drawPreviewWireLine(tmpL1, tmpL2) -- Edges.
    lines.drawPreviewWireLine(tmpR1, tmpR2)
    tris.drawTriPreviewSurface(tmpL1, tmpR1, tmpL2)
    tris.drawTriPreviewSurface(tmpR1, tmpR2, tmpL2)
  end
end

-- Renders polylines for specific spline tools (mesh spline, assembly spline, rail spline, decal spline).
-- Selected splines get thicker, clearer polylines while unselected ones get dull polylines.
local function renderSplinePolylines(splines, selectedSplineIdx)
  if not splines or #splines < 1 then
    return -- Early return if no splines to render.
  end

  local selFn = lines.drawSplineLine
  local dullFn = lines.drawSplineLineUnselected

  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled and not spline.isLink then
      -- A polyline spline ignores its fitted curve, so draw the straight legs it is actually built along.
      local pts = spline.isPolyline and spline.nodes or spline.divPoints
      if pts and #pts > 1 then
        local drawFn = (i == selectedSplineIdx) and selFn or dullFn
        local n = #pts
        local last = (spline.isPolyline and spline.isLoop) and n or n - 1 -- a looping polyline closes back to its first node
        for j = 1, last do
          drawFn(pts[j], pts[j % n + 1])
        end
      end
    end
  end
end


-- Public interface.
M.drawArc = drawArc
M.drawRibPoints = drawRibPoints
M.drawBarPoints = drawBarPoints
M.handleSplineRendering = handleSplineRendering
M.renderLayer = renderLayer
M.renderMasterLayer = renderMasterLayer
M.renderShells = renderShells
M.renderHalfSplineWireFrame = renderHalfSplineWireFrame
M.renderWireframeRibbons = renderWireframeRibbons
M.renderHomologatedSurface = renderHomologatedSurface
M.renderDrivePathSurface = renderDrivePathSurface
M.renderPreviewRibbon = renderPreviewRibbon
M.renderSplinePolylines = renderSplinePolylines

return M