-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility class for rendering splines with debugDraw. This is used across various spline-editing tools.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local cullDist = 600.0 -- The distance to cull the rendering of splines, in meters.

local sphereScalePivot = 30.0 -- Distance in meters where sphere scaling transitions from linear to sqrt.
local sphereScaleSlope = 1.0 / math.sqrt(sphereScalePivot) -- This prevents spheres from becoming too large (blooming) when the camera is close (<30m).

local halfWidthForMeshSplineVis = 2.0 -- The half-width to be used for mesh spline layer wire-frame visualisations, in meters.

local masterWireBinormalSpacing = 2 -- The spacing of the binormal lines on master wire rendering, in number of division points.
local homologationBinormalSpacing = 2 -- The spacing of the binormal lines on homologation rendering, in number of division points.
local raycastSurfBinormalSpacing = 2 -- The spacing of the binormal lines on raycast surface rendering, in number of division points.
-- Ribbon wire (TN): the longitudinal edges stay at the caller's spacing so curves read smoothly, but the
-- lateral "rung" (bL->bR) is by far the most numerous line and only exists to convey width/orientation, so
-- draw it every this-many divisions instead of every one. A handful of rungs per link reads the same and
-- cuts the ribbon line count hard on dense splines.
local ribbonRungSpacing = 12
-- The ribbon wireframe is the heaviest debug pass (every non-link group, every frame), so it culls tighter
-- than the general 'cullDist': its radius is a local in renderRibbonWireFrame (kept out of module scope to
-- stay under Lua's 200-upvalue limit).

local normalLength = 5.0 -- The length of the normal line, in meters.
local numArcSegments = 16 -- The number of segments to use when drawing an arc.

local velocityGran = 10 -- The granularity of the velocity rendering.

local zRayLift = 3.0 -- The z-offset to lift the raycast points above the surface, before raycasting to the surface below, in meters.
local zRayOffset = 0.05 -- The z-offset to add to the ribbon points when raycasting to the surface below.

local zFloat = 0.05 -- The z-offset to add to the ribbon points when rendering the main ribbon wire-frame.
local zFloatLayer = 0.075 -- The z-offset to add to the ribbon points when rendering the layer wire-frame.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local dbgDraw = require('utils/debugDraw')
local geom = require('editor/toolUtilities/geom')
local styleCore = require('editor/toolUtilities/style')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min, max, floor = math.abs, math.min, math.max, math.floor
local sin, acos, sqrt, deg = math.sin, math.acos, math.sqrt, math.deg
local cullDistSq = cullDist * cullDist
local numArcSegmentsInv = 1.0 / numArcSegments
local globalUp = vec3(0, 0, 1)
local emptyTable = {}
local style = styleCore.getStyle()
local errorMetricsLookup = {
  [0] = 'eSlopeNorm',
  [1] = 'eRadiusNorm',
  [2] = 'eBankingNorm',
  [3] = 'eWidthNorm',
  [4] = 'eBlindCrestNorm',
  [5] = 'eVertRadiusNorm',
}

-- Module state.
local finalPoints = {}
local bL, bR, tL, tR, tmp1, tmp2, tmp3, tmp4 = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tmpA, tmpB, tmpC, pTemp, tmpTgt, tmpDir = vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
local tmpTan, tmpBinormal, tmpOff, latVec1, latVec2 = vec3(), vec3(), vec3(), vec3(), vec3()
local tmpL1, tmpR1, tmpL2, tmpR2, tmpRef = vec3(), vec3(), vec3(), vec3(), vec3()
local swCenter1, swEdge1, swEdge2, tmpScale = vec3(), vec3(), vec3(), vec3()
local offsetP0, offsetP1 = vec3(), vec3()
local depthBase, depthHandle = vec3(), vec3()
local bridgeClusterCol = ColorF(1.0, 0.74, 0.27, 1.0)
local tunnelClusterCol = ColorF(0.63, 0.43, 1.0, 1.0)
local tunnelClusterHoverCol = ColorF(0.63, 0.43, 1.0, 0.65)
local foregroundSplineCol = ColorF(0.31, 0.51, 0.78, 1.0)
local tmpPoints = {}
for i = 1, numArcSegments + 1 do
  tmpPoints[i] = vec3()
end


-- Various functions to draw spheres.
local function getSphereScale(d)
  return d < sphereScalePivot and d * sphereScaleSlope or sqrt(d)
end

local function drawSphereCulled(p, scale, col)
  local camPos = core_camera.getPosition()
  if p:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawSphere(p, getSphereScale(p:distance(camPos)) * scale, col)
  end
end
local function drawSphereRib(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereRib + style.ribGlowScale), style.colourRibGlow) -- Glow pass.
  drawSphereCulled(p, style.sphereRib, style.colourRibHandle) -- Core pass.
end
local function drawSphereBar(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereBar + style.barGlowScale), style.colourBarGlow) -- Glow pass.
  drawSphereCulled(p, style.sphereBar, style.colourBarHandle) -- Core pass.
end
local function drawSphereBarHover(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereBar + style.barGlowScale
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourBarGlow)
  drawSphereCulled(p, style.sphereBar, style.colourBarHandle)
end
local function drawSphereHighlightHover(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereNodeHover
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourHighlightSelected or style.colourHighlight)
end

local function drawSphereHighlightHoverFixed(p, radius)
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, radius * k, style.colourHighlightSelected or style.colourHighlight)
end

local function drawSphereHighlightSelected(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereNodeHover
  local t = os.clock() * style.highlightPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightScaleMin + (style.highlightScaleMax - style.highlightScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourHighlight)
end

local function drawSphereHighlightSelectedFixed(p, radius)
  local t = os.clock() * style.highlightPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightScaleMin + (style.highlightScaleMax - style.highlightScaleMin) * s
  dbgDraw.drawSphere(p, radius * k, style.colourHighlight)
end

local function drawPathNode(p) drawSphereCulled(p, style.sphereNode, style.colourPathNode) end
local function drawSelectedNavGraphNode(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.bigNode
  local t = os.clock() * style.highlightPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightScaleMin + (style.highlightScaleMax - style.highlightScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourPathNodeBig)
end
local function drawHoverNavGraphNode(p)
  local camPos = core_camera.getPosition()
  local d = p:distance(camPos)
  local baseScale = style.sphereNode
  local t = os.clock() * style.highlightHoverPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.highlightHoverScaleMin + (style.highlightHoverScaleMax - style.highlightHoverScaleMin) * s
  dbgDraw.drawSphere(p, getSphereScale(d) * (baseScale * k), style.colourNodeGlow)
end
local function drawSphereNode(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereNode + style.nodeGlowScale), style.colourNodeGlow) -- Glow pass.
  dbgDraw.drawSphere(p, dScale * style.sphereNode, style.colourNode) -- Core pass.
end
local function drawSphereNodeLocked(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  local s = style.sphereNodeLocked or style.sphereRib
  dbgDraw.drawSphere(p, dScale * (s + style.ribGlowScale), style.colourNodeLockedGlow)
  dbgDraw.drawSphere(p, dScale * s, style.colourNodeLocked)
end
local function drawSphereJunction(p)
  local camPos = core_camera.getPosition()
  local dScale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, dScale * (style.sphereNode + style.nodeGlowScale), style.colourJunctionGlow)
  dbgDraw.drawSphere(p, dScale * style.sphereNode, style.colourJunction)
end
local function drawSphereJunctionDull(p)
  drawSphereCulled(p, style.sphereNodeDull, style.colourJunctionDull)
end
local function drawSphereImmediate(p, scale, col) dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * scale, col) end
local function drawSphereCursor(p, isActive)
  local camPos = core_camera.getPosition()
  local col = isActive and style.colourMousePos or style.colourMousePosInactive
  local distance = p:distance(camPos)
  local clampedDistance = min(distance, 100.0) -- Clamp max 100m.
  dbgDraw.drawSphere(p, getSphereScale(clampedDistance) * style.sphereMousePos, col)
end -- Not culled.

local function drawForceFieldSphere(centre, radius)
  if not centre or not radius or radius <= 0 then return end
  debugDrawer:drawSphere(centre, radius, ColorF(0.31, 0.51, 0.78, 0.15))
end

local function drawLineImmediate(p0, p1, thickness, col) dbgDraw.drawLineInstance_MinArg(p0, p1, thickness, col) end
local function drawSphereNodeDull(p) drawSphereCulled(p, style.sphereNodeDull, style.colourNodeDull) end
local function drawSphereHighlight(p) drawSphereCulled(p, style.sphereNodeHover, style.colourHighlight) end

-- Various functions to draw lines between two points.
local function drawLineCulled(p0, p1, thickness, col)
  local camPos = core_camera.getPosition()
  if p0:squaredDistance(camPos) < cullDistSq and p1:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawLineInstance_MinArg(p0, p1, thickness, col)
  end
end

local function drawForegroundLine(p0, p1, col)
  debugDrawer:drawLine(p0, p1, col, false)
end

local function drawSphereNodeForeground(p)
  local camPos = core_camera.getPosition()
  local scale = getSphereScale(p:distance(camPos))
  dbgDraw.drawSphere(p, scale * (style.sphereNode + style.nodeGlowScale), style.colourNodeGlow, false)
  dbgDraw.drawSphere(p, scale * style.sphereNode, style.colourNode, false)
end

local function drawSphereHighlightForeground(p)
  dbgDraw.drawSphere(p, getSphereScale(p:distance(core_camera.getPosition())) * style.sphereNodeHover, style.colourHighlight, false)
end

local function drawSplineLineForeground(p0, p1)
  drawForegroundLine(p0, p1, foregroundSplineCol)
end

local function drawSpanClusterWireframe(groups, junctions, cluster, role)
  if not cluster then return end
  local groupSet, jctSet = {}, {}
  for i = 1, #cluster.groupIds do groupSet[cluster.groupIds[i]] = true end
  for i = 1, #cluster.jctIds do jctSet[cluster.jctIds[i]] = true end
  local col = role == 'bridge' and bridgeClusterCol or tunnelClusterCol
  local verticalOffset = role == 'tunnel'
    and (cluster.clearHeightM or 5.0)
    or -(cluster.deckDepthM or 0.5)
  for i = 1, #groups do
    local g = groups[i]
    if groupSet[g.id] then
      local points, widths, binormals = g.divPoints, g.divWidths, g.binormals
      for j = 1, #points - 1 do
        local p1, p2 = points[j], points[j + 1]
        local w1, w2 = (widths[j] or 0) * 0.5, (widths[j + 1] or 0) * 0.5
        latVec1:setScaled2(binormals[j], w1)
        latVec2:setScaled2(binormals[j + 1], w2)
        tmpL1:setSub2(p1, latVec1)
        tmpR1:setAdd2(p1, latVec1)
        tmpL2:setSub2(p2, latVec2)
        tmpR2:setAdd2(p2, latVec2)
        tmpA:set(tmpL1)
        tmpB:set(tmpR1)
        tmpC:set(tmpL2)
        tmp4:set(tmpR2)
        tmpA.z, tmpB.z = tmpA.z + verticalOffset, tmpB.z + verticalOffset
        tmpC.z, tmp4.z = tmpC.z + verticalOffset, tmp4.z + verticalOffset
        drawForegroundLine(tmpL1, tmpL2, col)
        drawForegroundLine(tmpR1, tmpR2, col)
        drawForegroundLine(tmpA, tmpC, col)
        drawForegroundLine(tmpB, tmp4, col)
        if j == 1 or j % 4 == 0 then
          drawForegroundLine(tmpL1, tmpR1, col)
          drawForegroundLine(tmpA, tmpB, col)
          drawForegroundLine(tmpL1, tmpA, col)
          drawForegroundLine(tmpR1, tmpB, col)
        end
      end
      if #points > 0 then
        local j = #points
        latVec1:setScaled2(binormals[j], (widths[j] or 0) * 0.5)
        tmpL1:setSub2(points[j], latVec1)
        tmpR1:setAdd2(points[j], latVec1)
        tmpA:set(tmpL1)
        tmpB:set(tmpR1)
        tmpA.z, tmpB.z = tmpA.z + verticalOffset, tmpB.z + verticalOffset
        drawForegroundLine(tmpL1, tmpR1, col)
        drawForegroundLine(tmpA, tmpB, col)
        drawForegroundLine(tmpL1, tmpA, col)
        drawForegroundLine(tmpR1, tmpB, col)
      end
    end
  end
  for i = 1, #junctions do
    local jct = junctions[i]
    if jctSet[jct.id] then
      debugDrawer:drawSphere(jct.pos, 0.5, col, false)
    end
  end
end

local function drawTunnelNodesForeground(groups, cluster, selectedGroup)
  local groupSet = {}
  if cluster then
    for i = 1, #cluster.groupIds do groupSet[cluster.groupIds[i]] = true end
  elseif selectedGroup and selectedGroup.isTunnel then
    groupSet[selectedGroup.id] = true
  else
    return
  end
  local camPos = core_camera.getPosition()
  for i = 1, #groups do
    local g = groups[i]
    if groupSet[g.id] then
      local nodes = g.nodes
      for j = 1, #nodes do
        local p = nodes[j]
        local scale = getSphereScale(p:distance(camPos))
        dbgDraw.drawSphere(p, scale * (style.sphereNode + style.nodeGlowScale), style.colourTunnelWireDull, false)
        dbgDraw.drawSphere(p, scale * style.sphereNode, style.colourTunnelNode, false)
        if j > 1 then drawForegroundLine(nodes[j - 1], p, tunnelClusterHoverCol) end
      end
    end
  end
end
local function drawWireFrameLine(p0, p1)
  offsetP0:set(p0)
  p0.z = p0.z + 0.05
  offsetP1:set(p1)
  p1.z = p1.z + 0.05
  drawLineCulled(offsetP0, offsetP1, 2, style.colourLayerWire) -- Core pass.
end
local function drawWireFrameLine2(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourLayerWire2)
end
local function drawWireFrameLine3(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourLayerWire3)
end
local function drawPreviewWireLine(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourPreviewWire)
end
local function drawRibLine(p0, p1)
  dbgDraw.drawLineInstance_MinArg(p0, p1, style.ribLineGlowThickness, style.colourRibGlow) -- Glow pass.
  drawLineCulled(p0, p1, style.ribThickness, style.colourRibLine) -- Core pass.
end
local function drawActiveSegLine(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourLayerWire)
end
local function drawGroundLine(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourGround)
end
local function drawGroundLineDull(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourGroundDull)
end
local function drawDropLine(p0, p1, v, lim) drawLineCulled(p0, p1, style.dropThickness, util.getBlueToRedColour(v, 0, lim)) end
local function drawDropLineThick(p0, p1, v, lim) drawLineCulled(p0, p1, style.dropThicknessThicker, util.getBlueToRedColour(v, 0, lim)) end
local function drawDropLineDull(p0, p1) drawLineCulled(p0, p1, style.dropThicknessDull, style.colourDropDull) end
-- Soft elev drop for selected nodes / junction centres (thin, translucent).
local function drawElevDropLine(p0, p1, v, lim)
  local t = max(0, min(1, abs(v) / max(lim or 100, 1e-6)))
  local col = color(floor(70 + t * 160 + 0.5), floor(110 - t * 50 + 0.5), floor(210 - t * 130 + 0.5), 110)
  drawLineCulled(p0, p1, style.dropThickness, col)
end
local function drawNormalLine(p0, p1) drawLineCulled(p0, p1, style.normalThickness, style.colourNormal) end
local function drawRefNormalLine(p0, p1) drawLineCulled(p0, p1, style.normalRefThickness, style.colourRefNormal) end
local function drawNavLine(p0, p1) drawLineCulled(p0, p1, style.splineThickness, style.colourNav) end
local function drawPathLine(p0, p1) drawLineCulled(p0, p1, style.splineThickness, style.colourPath) end
local function drawBarCeilingLine(p0, p1, v, lim) drawLineCulled(p0, p1, style.dropThickness, util.getBlueToRedColour(v, 0, lim)) end
local function drawSplineLineLinked(p0, p1) drawLineCulled(p0, p1, style.splineThickness, style.colourSplineLinked) end
local function drawSplineLineDull(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourSplineDull)
end
local function drawSplineLineUnselected(p0, p1)
  drawLineCulled(p0, p1, 2, style.colourSplineDull)
end
local function drawSplineLine(p0, p1)
  dbgDraw.drawLineInstance_MinArg(p0, p1, 4, style.colourSplineGlow) -- Glow pass.
  dbgDraw.drawLineInstance_MinArg(p0, p1, 2, style.colourSpline) -- Core pass.
end -- Not culled.
local function drawArcSegment(p0, p1) dbgDraw.drawLineInstance_MinArg(p0, p1, style.arcSegThickness, style.colourArcSeg) end -- Not culled.
local function drawJoinLine(p0, p1)
  local t = os.clock() * style.loopPulseHz
  local s = 0.5 + 0.5 * sin(6.283185307179586 * t)
  local k = style.loopScaleMin + (style.loopScaleMax - style.loopScaleMin) * s
  dbgDraw.drawLineInstance_MinArg(p0, p1, style.loopThickness * k, style.colourLoop)
end -- Not culled.

-- Various functions to draw triangles, up to some culling distance.
local function drawTriCulled(a, b, c, col)
  local camPos = core_camera.getPosition()
  if a:squaredDistance(camPos) < cullDistSq and b:squaredDistance(camPos) < cullDistSq and c:squaredDistance(camPos) < cullDistSq then
    dbgDraw.drawTriSolid(a, b, c, col, true)
  end
end
local function drawTriNotSelectedSurface(a, b, c) drawTriCulled(a, b, c, style.colourNotSelectedSurf) end
local function drawTriPreviewSurface(a, b, c) drawTriCulled(a, b, c, style.colourPreviewSurf) end
local function drawTriActiveSurface(a, b, c) drawTriCulled(a, b, c, style.colourActiveSurf) end

-- Various functions to draw text markups, up to some culling distance.
-- Text markups cull at a shorter distance (250 m; 250*250 squared) than geometry, so labels don't flood.
local function drawMarkupCulled(pos, text)
  if pos:squaredDistance(core_camera.getPosition()) < 62500 then
    dbgDraw.drawTextAdvanced(pos, text, style.textForeground, true, false, style.textBackground, false, false)
  end
end
local function drawMarkupCulledAlwaysShow(pos, text)
  if pos:squaredDistance(core_camera.getPosition()) < 62500 then
    dbgDraw.drawTextAdvanced(pos, text, style.textForeground, true, false, style.textBackground, false, false)
  end
end
local function drawMarkupCulledInvertedCols(pos, text)
  if pos:squaredDistance(core_camera.getPosition()) < 62500 then
    dbgDraw.drawTextAdvanced(pos, text, style.textBackground, true, false, style.textForeground, false, false)
  end
end

-- Text markup helpers (no automatic brackets/wrapping).
local function markupText(pos, text) drawMarkupCulled(pos, text) end
local function markupLines(pos, lines)
  if not lines or #lines == 0 then return end
  drawMarkupCulled(pos, table.concat(lines, "\n"))
end
local function markupStack(pos, lines)
  if not lines or #lines == 0 then return end
  for i = 1, #lines do
    drawMarkupCulled(pos, lines[i])
  end
end
local function markupDrag(pos) drawMarkupCulled(pos, '[Click To Select, Drag To Move]') end
local function markupLinkedTip(pos) drawMarkupCulled(pos, '[Linked — Drag Away Or Use Detach Button]') end
local function markupSelectSpline(pos) drawMarkupCulled(pos, '[Click To Select Spline]') end
local function markupSelectedSplineDisabled(pos) drawMarkupCulled(pos, '[Spline Disabled. Cannot Edit]') end
local function markupSelectOrAdd(pos) drawMarkupCulled(pos, "[Select A Spline Or Click 'Add']") end
local function markupAddNode(pos) drawMarkupCulled(pos, '[Click To Add Node]') end
local function markupInsertNode(pos) drawMarkupCulled(pos, '[Click To Insert Node]') end
local function markupRoadLength(pos, l) drawMarkupCulledInvertedCols(pos, string.format('[Length = %.2f m]', l)) end
local function markupAdjustWidth(pos) drawMarkupCulled(pos, '[Drag To Adjust Width. Hold SHIFT For Precision]') end
local function markupAdjustBar(pos) drawMarkupCulled(pos, '[Drag To Adjust Height. Hold SHIFT For Precision]') end
local function markupAdjustDepth(pos) drawMarkupCulled(pos, '[Drag To Adjust Depth. Hold SHIFT For Precision]') end
local function markupWidthDisplay(pos, w) drawMarkupCulled(pos, string.format('[Width = %.2f m]', w)) end
local function markupDepthDisplay(pos, d) drawMarkupCulled(pos, string.format('[d = %.2f m]', d)) end
local function markupAddPolygonNode(pos) drawMarkupCulled(pos, '[Click To Add Node. Double-Click To Finish]') end
local function markupStart(pos) drawMarkupCulledInvertedCols(pos, '[Start]') end
local function markupEnd(pos) drawMarkupCulledInvertedCols(pos, '[End]') end
local function markupAddPairLeft(pos) drawMarkupCulled(pos, '[Add Pair: Click 1st Node]') end
local function markupPairFirstNode(pos) drawMarkupCulled(pos, '[Pair: First Node]') end
local function markupPairSecondNode(pos) drawMarkupCulled(pos, '[Left Click: Add 2nd Node. Right Click: Cancel Pair]') end
local function markupNode1(pos) drawMarkupCulled(pos, 'Node [1]') end
local function markupNode2(pos) drawMarkupCulled(pos, 'Node [2]') end
local function markupNode3(pos) drawMarkupCulled(pos, 'Node [3]') end
local function markupSplineName(pos, str) drawMarkupCulled(pos, string.format('[%s]', str)) end
local function markupActiveSurf(pos) drawMarkupCulled(pos, '[Active Surface (2D)]') end
local function markupVolume(pos) drawMarkupCulled(pos, '[Active Volume (3D)]') end
local function markupElevation(pos, elev) drawMarkupCulled(pos, string.format('[Elevation = %.2f m]', elev)) end
local function markupTwistAngle(pos, angleDeg) drawMarkupCulled(pos, string.format('[Twist Angle = %.2f deg]', angleDeg)) end
local function markupVelocity(pos, vel, isBarsLimit, unitsStr)drawMarkupCulled(pos, string.format('[%s = %.2f %s]', isBarsLimit and 'Limit' or 'Velocity', vel, unitsStr)) end
local function markupGraphNodeHover(pos) drawMarkupCulled(pos, '[Click To Add/Remove From Path]') end
local function markupGraphFreeSpace(pos) drawMarkupCulled(pos, '[Click NavGraph Node To Add To Path]') end
local function markupPathNode(pos, i) drawMarkupCulled(pos, string.format('Path Node [%d]', i)) end
local function markupLoop(pos) drawMarkupCulled(pos, '[Hold SHIFT + Drop To Form Loop]') end
local function markupJoin(pos) drawMarkupCulled(pos, '[Hold SHIFT + Drop To Join]') end
local function markupJoinDrop(pos) drawMarkupCulled(pos, '[Drop To Join]') end
local function markupLinkedSplineCannotAdd(pos) drawMarkupCulled(pos, '[Linked Spline - Cannot Add Nodes]') end
local function markupLoopedSplineCannotAdd(pos) drawMarkupCulled(pos, '[Looped Spline - Cannot Add Here]') end
local function markupObstacleDistance(pos, dist) drawMarkupCulledAlwaysShow(pos, string.format('[Obstacle: %.1f m]', dist)) end
local function markupObstacleDistanceWithElevation(pos, dist, elevDiff) drawMarkupCulledAlwaysShow(pos, string.format('[Obstacle: %.1f m; dZ = %.1fm]', dist, elevDiff)) end
local function markupAngleAndDistance(pos, dist, angleRad) drawMarkupCulledAlwaysShow(pos, string.format('%.1f m; %.1f°', dist, deg(angleRad))) end
local function markupAngleDistanceWithElevation(pos, dist, angleRad, elevDiff) drawMarkupCulledAlwaysShow(pos, string.format('%.1f m; %.1f°; dZ = %.1fm', dist, deg(angleRad), elevDiff)) end

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
    drawArcSegment(tmpPoints[i], tmpPoints[i + 1]) -- Draw the arc segments.
    if isSelectedNode and i == midIdx then
      markupTwistAngle(tmpPoints[i], twistAngle)
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
      drawSphereRib(ribPoint)
      if centerNode then
        drawRibLine(centerNode, ribPoint) -- Draw line from center to rib.
      end
    end
  else -- For full splines, draw both left and right ribs with connecting lines.
    for j = 1, #ribs, 2 do
      local p0, p1 = ribs[j], ribs[j + 1]
      drawSphereRib(p0)
      drawSphereRib(p1)
      drawRibLine(p0, p1)
    end
  end
end

-- Draw the bar points.
local function drawBarPoints(bars, elevScale)
  local numBars = #bars
  if numBars > 1 then
    for j = 1, numBars do
      local pBar = bars[j]
      drawSphereBar(pBar)
      tmp1:set(pBar)
      util.vertRaycast(tmp1)
      local elevation = pBar.z - tmp1.z
      drawDropLineThick(pBar, tmp1, elevation, elevScale)
    end
  end
end

-- Handles the rendering of splines.
local function handleSplineRendering(splines, splineIdx, nodeIdx, isGizmoActive, isUseRot, isShapeLocked, isShowElevation, isShowRibs, elevScale)
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
          if not tipLocked then
            drawSphereNode(node)
          end
          if j == nodeIdx then
            tmp1:set(node)
            util.vertRaycast(tmp1)
            local elevation = node.z - tmp1.z
            drawElevDropLine(node, tmp1, elevation, elevScale)
            if isShowElevation and isGizmoActive and editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
              if abs(elevation) < 0.01 then elevation = 0.0 end -- Stops flickering text between 0 and -0 when changing node elevations.
              markupElevation(node, elevation)
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
              drawNormalLine(node, tmp1)
              tmpScale:setScaled2(tmpRef, normalLength)
              tmp2:setAdd2(node, tmpScale) -- Ref normal.
              drawRefNormalLine(node, tmp2)
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
            markupSplineName(pStart, name)
            markupRoadLength(pStart, roadLength)
          end
          if not spline.isLoop and freeFinish then
            markupRoadLength(pEnd, roadLength)
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
            drawSphereNodeDull(nodes[j])
          end
        end

        -- Draw the start markup, if there are at least two nodes and the start tip is free.
        if #nodes > 1 and not spline.jctIdStart then
          markupSplineName(nodes[1], spline.name)
        end
      end
    end
  end

  -- Render the selected node highlight, if everything is valid.
  if splineIdx and nodeIdx and splines[splineIdx] then
    local spline = splines[splineIdx]
    local n = spline.nodes and #spline.nodes or 0
    local tipLocked = (nodeIdx == 1 and spline.jctIdStart) or (nodeIdx == n and spline.jctIdFinish)
    if nodeIdx <= n and spline.isEnabled and not spline.isLink and not tipLocked then
      drawSphereHighlightSelected(spline.nodes[nodeIdx])
    end
  end
end

-- Transport-network junction centres (green spheres + elevation like road nodes).
local function drawTransportJunctions(junctions, selectedIdx, elevScale, isGizmoActive)
  if not junctions then return end
  elevScale = elevScale or 100.0
  selectedIdx = selectedIdx or 0
  for i = 1, #junctions do
    local jct = junctions[i]
    local selected = i == selectedIdx
    local roleCol = nil
    if jct.isBridge then
      roleCol = selected and style.colourBridgeNode or style.colourBridgeNodeDull
    elseif jct.isTunnel then
      roleCol = selected and style.colourTunnelNode or style.colourTunnelNodeDull
    end
    if selected then
      if roleCol then
        drawSphereCulled(jct.pos, style.sphereNode, roleCol)
      else
        drawSphereJunction(jct.pos)
      end
      drawSphereHighlightSelected(jct.pos)
      tmp1:set(jct.pos)
      util.vertRaycast(tmp1)
      local elevation = jct.pos.z - tmp1.z
      drawElevDropLine(jct.pos, tmp1, elevation, elevScale)
      if isGizmoActive and editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
        if abs(elevation) < 0.01 then elevation = 0.0 end
        markupElevation(jct.pos, elevation)
      end
    else
      if roleCol then
        drawSphereCulled(jct.pos, style.sphereNodeDull, roleCol)
      else
        drawSphereJunctionDull(jct.pos)
      end
    end
  end
end

-- Red locked road tips linked to a junction (overdraw normal node spheres).
local function drawLinkedTips(groups)
  if not groups then return end
  for gi = 1, #groups do
    local g = groups[gi]
    local nodes = g.nodes
    if nodes and #nodes >= 1 then
      if g.jctIdStart then drawSphereNodeLocked(nodes[1]) end
      if g.jctIdFinish then drawSphereNodeLocked(nodes[#nodes]) end
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
        drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        drawWireFrameLine(bR, tR)
        drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
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
        drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        drawWireFrameLine(bR, tR)
        drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
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
        drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        drawWireFrameLine(bR, tR)
        drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
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
        drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        drawWireFrameLine(bR, tR)
        drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
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
      local wireCol = nil
      if spline.isBridge then
        wireCol = style.colourBridgeWireDull
      elseif spline.isTunnel then
        wireCol = style.colourTunnelWireDull
      end

      -- Bridge/tunnel: same ribbon wireframe as roads, role-coloured (no fill).
      if wireCol and numDivPoints > 1 and spline.divWidths and spline.binormals then
        local divWidths, binormals = spline.divWidths, spline.binormals
        for j = 1, numDivPoints - 1, masterWireBinormalSpacing do
          local jPlusOne = min(j + masterWireBinormalSpacing, numDivPoints)
          latVec1:setScaled2(binormals[j], divWidths[j] * 0.5)
          latVec2:setScaled2(binormals[jPlusOne], divWidths[jPlusOne] * 0.5)
          local p1, p2 = divPoints[j], divPoints[jPlusOne]
          bL:setSub2(p1, latVec1)
          bL.z = bL.z + zRayOffset
          bR:setAdd2(p1, latVec1)
          bR.z = bR.z + zRayOffset
          tL:setSub2(p2, latVec2)
          tL.z = tL.z + zRayOffset
          tR:setAdd2(p2, latVec2)
          tR.z = tR.z + zRayOffset
          drawLineCulled(bL, tL, 2, wireCol)
          drawLineCulled(bR, tR, 2, wireCol)
          drawLineCulled(bL, bR, 2, wireCol)
        end
      else
        for j = 1, numDivPoints - 1 do
          drawSplineLineDull(divPoints[j], divPoints[j + 1])
        end
      end

      local nodes = spline.nodes
      for j = 1, #nodes do
        drawSphereNodeDull(nodes[j])
      end

      if numDivPoints > 1 then
        markupSplineName(divPoints[1], spline.name) -- One markup at the start tip, to indicate which spline this is.
      end
    end
  end
end

-- Renders the wire-frame for ribbon splines.
local function renderRibbonWireFrame(splines, selSplineIdx, binormalSpacing)
  if not splines or #splines < 1 then
    return -- Early return if no splines.
  end

  local spacing = binormalSpacing or masterWireBinormalSpacing
  local ribbonCullDistSq = 300.0 * 300.0 -- Tighter than the general cullDist; this is the heaviest pass.
  -- Fetch the camera once per frame (not once per line): this pass emits thousands of ribbon lines and the
  -- old per-line drawLineCulled did a core_camera.getPosition() + distance test for every one of them.
  local camPos = core_camera.getPosition()
  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled and not spline.isLink then
      local selected = i == selSplineIdx
      local col
      if spline.isBridge then
        col = selected and style.colourBridgeWire or style.colourBridgeWireDull
      elseif spline.isTunnel then
        col = selected and style.colourTunnelWire or style.colourTunnelWireDull
      else
        col = selected and style.colourLayerWire2 or style.colourLayerWire3
      end
      local divPoints, divWidths, binormals = spline.divPoints, spline.divWidths, spline.binormals
      -- Optional reference-line extents (TN): leftExtM / rightExtM; else symmetric half-width.
      local fixedL, fixedR = spline.leftExtM, spline.rightExtM
      -- Rung cadence in loop iterations (each iteration advances 'spacing' divisions).
      local rungEvery = max(1, floor(ribbonRungSpacing / spacing + 0.5))
      local iter, drewAny = 0, false
      for j = 1, #divPoints - 1, spacing do
        local jPlusOne = j + spacing
        if jPlusOne <= #divPoints then
          local p1, p2 = divPoints[j], divPoints[jPlusOne] -- The two div points.
          -- One cull test per segment (three lines share it) against the tighter ribbon radius.
          if p1:squaredDistance(camPos) < ribbonCullDistSq or p2:squaredDistance(camPos) < ribbonCullDistSq then
            local l1 = fixedL or (divWidths[j] * 0.5)
            local r1 = fixedR or (divWidths[j] * 0.5)
            local l2 = fixedL or (divWidths[jPlusOne] * 0.5)
            local r2 = fixedR or (divWidths[jPlusOne] * 0.5)
            latVec1:setScaled2(binormals[j], l1)
            bL:setSub2(p1, latVec1)
            bL.z = bL.z + zRayOffset
            latVec1:setScaled2(binormals[j], r1)
            bR:setAdd2(p1, latVec1)
            bR.z = bR.z + zRayOffset
            latVec2:setScaled2(binormals[jPlusOne], l2)
            tL:setSub2(p2, latVec2)
            tL.z = tL.z + zRayOffset
            latVec2:setScaled2(binormals[jPlusOne], r2)
            tR:setAdd2(p2, latVec2)
            tR.z = tR.z + zRayOffset

            dbgDraw.drawLineInstance_MinArg(bL, tL, 2, col) -- Longitudinal edges (smooth).
            dbgDraw.drawLineInstance_MinArg(bR, tR, 2, col)
            if (iter % rungEvery) == 0 then
              dbgDraw.drawLineInstance_MinArg(bL, bR, 2, col) -- Lateral binormal line (sparse).
            end
            drewAny = true
          end
          iter = iter + 1
        end
      end
      -- Cap the far end with one rung so the ribbon reads as closed (tL/tR hold the last drawn segment's end).
      if drewAny then
        dbgDraw.drawLineInstance_MinArg(tL, tR, 2, col)
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
      drawWireFrameLine(swEdge1, swEdge2) -- Draw the right edge line.
      drawWireFrameLine(swCenter1, swEdge1) -- Draw the lateral lines.
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
        drawSphereNodeDull(nodes[j])
      end

      -- Draw markups.
      local pStart, pEnd = nodes[1], nodes[#nodes]
      markupStart(pStart)
      markupEnd(pEnd)
      markupSplineName(pStart, spline.name)

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
          drawWireFrameLine3(bL, tL) -- Draw the wire-frame side lines.
          drawWireFrameLine3(bR, tR)
          drawWireFrameLine3(bL, bR) -- Draw the wire-frame front and back lines.
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
            drawWireFrameLine2(bL, tL) -- Render the wire-frame side lines.
            drawWireFrameLine2(bR, tR)
            drawWireFrameLine2(bL, bR) -- Render the wire-frame front and back lines.

            -- Draw the spline surface using a heatmap.
            local t = metric[j] or 0.0
            local r, g, b = util.getHueBasedColour255(t)
            local col = color(r, g, b, 255)
            drawTriCulled(bL, bR, tL, col)
            drawTriCulled(bR, bL, tL, col)
            drawTriCulled(tL, bR, tR, col)
            drawTriCulled(bR, tL, tR, col)
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
            drawWireFrameLine3(bL, tL)
            drawWireFrameLine3(bR, tR)
            drawWireFrameLine3(bL, bR)
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
        drawWireFrameLine(bL, tL) -- Draw the wire-frame side lines.
        drawWireFrameLine(bR, tR)
        drawWireFrameLine(bL, bR) -- Draw the wire-frame front and back lines.
      end
    end
  end
end

-- Renders the give preview ribbon.
local function renderPreviewRibbon(nodes, widths)
  -- Draw the nodes.
  local numNodes = #nodes
  for i = 1, numNodes do
    drawSphereNode(nodes[i])
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
    drawPreviewWireLine(tmpL1, tmpR1) -- Width spans.
    drawPreviewWireLine(tmpL1, tmpL2) -- Edges.
    drawPreviewWireLine(tmpR1, tmpR2)
    drawTriPreviewSurface(tmpL1, tmpR1, tmpL2)
    drawTriPreviewSurface(tmpR1, tmpR2, tmpL2)
  end
end

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
    drawDropLine(tmp2, tmp1, elev, elevScale)
    drawBarCeilingLine(tmp2, tmp4, elev, elevScale)
  end

  -- Render the velocity markups.
  for i = 1, #spline.barPoints do
    local finalVel, units = valsMs[i], 'm/s'
    if unitsInt == 1 then
      finalVel, units = util.msToMph(valsMs[i]), 'mph'
    elseif unitsInt == 2 then
      finalVel, units = util.msToKph(valsMs[i]), 'kph'
    end
    markupVelocity(spline.barPoints[i], finalVel, isBarsLimit, units)
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
    drawDropLine(tmp2, tmp1, elev, elevScale)
    drawBarCeilingLine(tmp2, tmp4, elev, elevScale)
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
    markupVelocity(spline.barPoints[i], finalVel, isBarsLimit, units)
  end
end

-- Indicate to the user visually that a loop is possible, between start/end of the same spline.
local function renderCandidateLoop(node1, node2)
  drawSphereHighlightHover(node1)
  drawSphereHighlightHover(node2)
  drawJoinLine(node1, node2) -- Draw a special line to indicate that a loop is possible.
  tmp1:setAdd2(node1, node2)
  tmp1:setScaled(0.5) -- Mid point.
  markupLoop(tmp1) -- Text markup to indicate that a loop is possible.
end

-- Indicate to the user visually that a join is possible, between two separate splines.
-- [joinWithoutShift] - when true, markup omits SHIFT (transportNetwork joins on drop alone).
local function renderCandidateJoin(node1, node2, joinWithoutShift)
  drawSphereHighlightHover(node1)
  drawSphereHighlightHover(node2)
  drawJoinLine(node1, node2) -- Draw a special line to indicate that a loop is possible.
  tmp1:setAdd2(node1, node2)
  tmp1:setScaled(0.5) -- Mid point.
  if joinWithoutShift then
    markupJoinDrop(tmp1)
  else
    markupJoin(tmp1)
  end
end

-- Renders the given ribbon.
-- [Ribbons are splines which are placed in L-R pairs, and have segments comprising of adjacent 8-point boxes.]
-- [They can have active surfaces (top or bottom), and closest segments.
-- They are used for dynamic audio emitter placement, for example.]
-- [ribbon - The ribbon to render.]
-- [pMouse - The current mouse position.]
-- [isSelectedRibbon - Whether the ribbon is selected, or not.]
-- [selectedNodeIdx - The index of the selected ribbon node, if it exists.]
-- [placedLeftNode - The left node position, if it has been placed by the user.]
-- [bestCursorSeg - The index of the closest segment, if it exists.]
-- [isDragging - Whether the node is being dragged, or not.]
local function handleRibbonRendering(ribbons, selectedRibbonIdx, selectedNodeIdx, placedLeftNode, hoveredRibbonIdx, bestCursorSeg, isDragging)
  local pMouse = util.mouseOnMapPos()

  -- Iterate over each ribbon, in turn.
  for i = 1, #ribbons do
    local ribbon = ribbons[i]

    -- If the user has placed a left node for a pair, then render it.
    if placedLeftNode then
      local pLeft = placedLeftNode.p
      drawSphereNode(pLeft) -- Draw the left node.
      drawSphereHighlight(pLeft) -- Highlight the left node.
      drawSplineLineDull(pLeft, pMouse) -- Line from the left node to the mouse position.
    end

    -- Render the ribbon nodes.
    local nodes = ribbon.nodes
    local numNodes = #nodes
    if numNodes >= 1 then

      -- Render the ribbon nodes for all enabled ribbons, and for hovered disabled ribbons.
      local isSelectedRibbon = i == selectedRibbonIdx
      local isHoveredRibbon = i == hoveredRibbonIdx
      if ribbon.isEnabled or isHoveredRibbon then
        local sphereFn = drawSphereNodeDull
        if isSelectedRibbon or isHoveredRibbon then
          sphereFn = drawSphereNode
        end
        for j = 1, numNodes do
          sphereFn(nodes[j])
        end
      end

      -- Highlight the selected node, on the selected ribbon.
      if isSelectedRibbon and ribbon.isEnabled then
        if nodes[selectedNodeIdx] then
          drawSphereHighlightSelected(nodes[selectedNodeIdx])
        end
      end

      -- Render depth bar handles for the selected ribbon.
      if isSelectedRibbon and ribbon.isEnabled and ribbon.depths and ribbon.barPoints and #ribbon.barPoints == numNodes then
      local depths = ribbon.depths
      local barPoints = ribbon.barPoints
      local isUpRibbon = ribbon.isUpRibbon
      if isUpRibbon == nil then
        isUpRibbon = ribbon.isUpPrism
      end
        for j = 1, numNodes do
          local pNode = nodes[j]
          local depth = depths[j] or 0.0
          depthBase:set(pNode)
          if not isUpRibbon then
            depthBase.z = depthBase.z + depth
          end
          depthHandle:set(barPoints[j])
          dbgDraw.drawLineInstance_MinArg(depthBase, depthHandle, style.barThickness, style.colourBarHandle)
          drawSphereBar(depthHandle)
        end
      end

      -- Render the segments of this ribbon.
      if (ribbon.isEnabled or isHoveredRibbon) and numNodes > 3 then -- We can only render segments if there are at least four nodes.
      local isTopActive, isUpRibbon, isAmbient, isQuadAndVolume = ribbon.isTopActive, ribbon.isUpRibbon, ribbon.isAmbient, ribbon.isQuadAndVolume
      if isUpRibbon == nil then
        isUpRibbon = ribbon.isUpPrism
      end
        local isActiveSurfTop = true
        local depths, numSegs = ribbon.depths, ribbon.numSegs
        for j = 1, numSegs do
          -- Choose the appropriate styling, depending on whether a surface is active/not active, or ribbon is selected/not selected.
          local lineFn, triFn1, triFn2 = drawSplineLine, drawTriNotSelectedSurface, drawTriNotSelectedSurface
          if not isAmbient then
            if isTopActive then
              if isUpRibbon then
                triFn1 = drawTriActiveSurface -- The ribbon is directed upwards, and has the top surface active.
                isActiveSurfTop = true
              else
                triFn2 = drawTriActiveSurface -- The ribbon is directed upwards, and has the bottom surface active.
                isActiveSurfTop = false
              end
            else
              if isUpRibbon then
                triFn2 = drawTriActiveSurface -- The ribbon is directed downwards, and has the bottom surface active.
                isActiveSurfTop = false
              else
                triFn1 = drawTriActiveSurface -- The ribbon is directed downwards, and has the top surface active.
                isActiveSurfTop = true
              end
            end
          end
          if isQuadAndVolume then
            triFn1, triFn2 = drawTriActiveSurface, drawTriActiveSurface -- Override # 1: 2D quad and volume ribbons with top and bottom surfaces the same.
          end
          if isSelectedRibbon and (not isDragging) and j == bestCursorSeg then
            lineFn = drawActiveSegLine -- Override # 2: Highlight the closest segment in a special colour.
          end
          if (not isSelectedRibbon) and (not isHoveredRibbon) then
            lineFn, triFn1, triFn2 = drawSplineLineDull, drawTriNotSelectedSurface, drawTriNotSelectedSurface -- Override # 3: Unselected ribbons are drawn in dull colors.
          elseif isHoveredRibbon and (not isSelectedRibbon) then
            triFn1, triFn2 = drawTriPreviewSurface, drawTriPreviewSurface -- Override # 4: Hovered ribbons are drawn in a special preview colour.
          end

          -- The active surface (either top or bottom).
          local twoSegIdx = j * 2
          local i1, i2, i3, i4 = twoSegIdx - 1, twoSegIdx, twoSegIdx + 1, twoSegIdx + 2
          local lB_B, lF_B, rB_B, rF_B = nodes[i1], nodes[i2], nodes[i3], nodes[i4]
          lineFn(lB_B, lF_B)
          lineFn(rB_B, rF_B)
          lineFn(lB_B, rB_B)
          lineFn(lF_B, rF_B)
          triFn1(lB_B, lF_B, rB_B)
          triFn1(lB_B, rB_B, lF_B)
          triFn1(lF_B, rF_B, rB_B)
          triFn1(lF_B, rB_B, rF_B)

          -- Cache 'active surface' markup point 1.
          if j == 1 then
            tmp1:setAdd2(lB_B, rF_B)
            tmp1:setScaled(0.5) -- Mid point.
          end

          -- The non-active surface (the other surface).
          local d1, d2, d3, d4 = depths[i1], depths[i2], depths[i3], depths[i4]
          if not isUpRibbon then
            d1, d2, d3, d4 = -d1, -d2, -d3, -d4
          end
          bL:set(lB_B)
          bL.z = bL.z - d1
          bR:set(lF_B)
          bR.z = bR.z - d2
          tL:set(rB_B)
          tL.z = tL.z - d3
          tR:set(rF_B)
          tR.z = tR.z - d4
          lineFn(bL, bR)
          lineFn(tL, tR)
          lineFn(bL, tL)
          lineFn(bR, tR)
          triFn2(bL, bR, tL)
          triFn2(bL, tL, bR)
          triFn2(bR, tR, tL)
          triFn2(bR, tL, tR)

          -- The vertical side lines.
          lineFn(lB_B, bL)
          lineFn(lF_B, bR)
          lineFn(rB_B, tL)
          lineFn(rF_B, tR)

          -- Cache 'active surface' markup point 1.
          if j == 1 then
            tmp2:setAdd2(bL, tR)
            tmp2:setScaled(0.5) -- Mid point.
          end
        end

        -- Markup the active surface/volume, if appropriate.
        if isQuadAndVolume or isAmbient then
          tmp3:setAdd2(tmp1, tmp2)
          tmp3:setScaled(0.5) -- Mid point.
          markupVolume(tmp3)
        elseif isActiveSurfTop then
          markupActiveSurf(tmp1)
        else
          markupActiveSurf(tmp2)
        end
      end
    end
  end
end

-- Renders the nav graph.
local function renderNavGraph(navGraph, hoverNode)
  if not navGraph then
    return -- No nav graph to render.
  end

  -- Render the sphere-to-sphere ribbons.
  local lines = navGraph.lines
  for i = 1, #lines do
    local line = lines[i]
    local pL, pR, qL, qR, cL, cR = line.pL, line.pR, line.qL, line.qR, line.cL, line.cR
    drawTriCulled(pR, pL, qR, style.colourNavGraphRibbon) -- Ribbon surface with navgraph color.
    drawTriCulled(pL, qL, qR, style.colourNavGraphRibbon)
    drawNavLine(cL, cR) -- Center line between the two spheres.
  end

  -- Render the nav graph nodes with glow like spline nodes.
  local nodes = navGraph.nodes
  for _, v in pairs(nodes) do
    if hoverNode and v == hoverNode then
      -- Render hovered node with pulsing effect
      drawHoverNavGraphNode(v)
    else
      -- Render normal node
      local camPos = core_camera.getPosition()
      local dScale = getSphereScale(v:distance(camPos))
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
    drawPathNode(graphNodes[path[i]])
  end
  for i = 1, pathLength - 1 do
    local p0, p1 = graphNodes[path[i]], graphNodes[path[i + 1]]
    drawPathLine(p0, p1)
  end
end

-- Renders the chosen navGraph nodes with special indicators.
local function renderChosenNodes(nodes, graphData)
  local graphNodes = graphData.nodes
  for i = 1, #nodes do
    local p = graphNodes[nodes[i]]
    drawSelectedNavGraphNode(p) -- Larger sphere to show it is part of the selection and not just the path. Thus it can be removed.
    markupPathNode(p, i) -- Markup to index the node on screen.
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

-- Renders polylines for specific spline tools (mesh spline, assembly spline, rail spline, decal spline).
-- Selected splines get thicker, clearer polylines while unselected ones get dull polylines.
local function renderSplinePolylines(splines, selectedSplineIdx)
  if not splines or #splines < 1 then
    return -- Early return if no splines to render.
  end

  for i = 1, #splines do
    local spline = splines[i]
    if spline.isEnabled and not spline.isLink then
      local divPoints = spline.divPoints
      if divPoints and #divPoints > 1 then
        if i == selectedSplineIdx then -- Selected spline: draw polyline with thicker, clearer lines.
          for j = 1, #divPoints - 1 do
            drawSplineLine(divPoints[j], divPoints[j + 1])
          end
        else-- Unselected spline: draw polyline with duller lines.
          for j = 1, #divPoints - 1 do
            drawSplineLineUnselected(divPoints[j], divPoints[j + 1])
          end
        end
      end
    end
  end
end


-- Public interface.
M.drawSphereCulled =                                    drawSphereCulled
M.drawSphereCursor =                                    drawSphereCursor
M.drawForceFieldSphere =                                drawForceFieldSphere
M.drawSphereNode =                                      drawSphereNode
M.drawSphereNodeForeground =                            drawSphereNodeForeground
M.drawSphereNodeLocked =                                drawSphereNodeLocked
M.drawSphereJunction =                                  drawSphereJunction
M.drawSphereJunctionDull =                              drawSphereJunctionDull
M.drawSphereRib =                                       drawSphereRib
M.drawSphereBarHover =                                  drawSphereBarHover
M.drawSphereNodeDull =                                  drawSphereNodeDull
M.drawSphereHighlight =                                 drawSphereHighlight
M.drawSphereHighlightForeground =                       drawSphereHighlightForeground
M.drawSphereHighlightHover =                            drawSphereHighlightHover
M.drawSphereHighlightHoverFixed =                       drawSphereHighlightHoverFixed
M.drawSphereHighlightSelected =                         drawSphereHighlightSelected
M.drawSphereHighlightSelectedFixed =                    drawSphereHighlightSelectedFixed

M.drawLineCulled =                                      drawLineCulled
M.drawLineImmediate =                                   drawLineImmediate
M.drawForegroundLine =                                  drawForegroundLine
M.drawSplineLine =                                      drawSplineLine
M.drawSplineLineForeground =                            drawSplineLineForeground
M.drawSplineLineDull =                                  drawSplineLineDull
M.drawWireFrameLine =                                   drawWireFrameLine
M.drawRibLine =                                         drawRibLine
M.drawSplineLineLinked =                                drawSplineLineLinked
M.drawDropLine =                                        drawDropLine
M.drawDropLineThick =                                   drawDropLineThick
M.drawDropLineDull =                                    drawDropLineDull
M.markupElevation =                                     markupElevation
M.drawNormalLine =                                      drawNormalLine
M.drawRefNormalLine =                                   drawRefNormalLine
M.drawGroundLine =                                      drawGroundLine
M.drawGroundLineDull =                                  drawGroundLineDull
M.drawArcSegment =                                      drawArcSegment
M.drawSphereImmediate =                                 drawSphereImmediate

M.drawTriCulled =                                       drawTriCulled
M.drawTriNotSelectedSurface =                           drawTriNotSelectedSurface
M.drawTriActiveSurface =                                drawTriActiveSurface

M.markupDrag =                                          markupDrag
M.markupLinkedTip =                                     markupLinkedTip
M.markupAddNode =                                       markupAddNode
M.markupInsertNode =                                    markupInsertNode
M.markupAdjustWidth =                                   markupAdjustWidth
M.markupAdjustBar =                                     markupAdjustBar
M.markupAdjustDepth =                                   markupAdjustDepth
M.markupWidthDisplay =                                  markupWidthDisplay
M.markupDepthDisplay =                                  markupDepthDisplay
M.markupVelocity =                                      markupVelocity
M.markupText =                                          markupText
M.markupLines =                                         markupLines
M.markupStack =                                         markupStack
M.markupAddPolygonNode =                                markupAddPolygonNode
M.markupStart =                                         markupStart
M.markupEnd =                                           markupEnd
M.markupSplineName =                                    markupSplineName
M.markupAddPairLeft =                                   markupAddPairLeft
M.markupPairFirstNode =                                 markupPairFirstNode
M.markupPairSecondNode =                                markupPairSecondNode
M.markupNode1 =                                         markupNode1
M.markupNode2 =                                         markupNode2
M.markupNode3 =                                         markupNode3
M.markupSelectSpline =                                  markupSelectSpline
M.markupSelectedSplineDisabled =                        markupSelectedSplineDisabled
M.markupSelectOrAdd =                                   markupSelectOrAdd
M.markupActiveSurf =                                    markupActiveSurf
M.markupVolume =                                        markupVolume
M.markupGraphFreeSpace =                                markupGraphFreeSpace
M.markupGraphNodeHover =                                markupGraphNodeHover
M.markupObstacleDistance =                              markupObstacleDistance
M.markupObstacleDistanceWithElevation =                 markupObstacleDistanceWithElevation
M.markupAngleAndDistance =                              markupAngleAndDistance
M.markupAngleDistanceWithElevation =                    markupAngleDistanceWithElevation
M.markupLinkedSplineCannotAdd =                         markupLinkedSplineCannotAdd
M.markupLoopedSplineCannotAdd =                         markupLoopedSplineCannotAdd

M.drawArc =                                             drawArc

M.drawRibPoints =                                       drawRibPoints
M.drawBarPoints =                                       drawBarPoints

M.handleSplineRendering =                               handleSplineRendering
M.drawTransportJunctions =                              drawTransportJunctions
M.drawLinkedTips =                                      drawLinkedTips
M.drawSpanClusterWireframe =                            drawSpanClusterWireframe
M.drawTunnelNodesForeground =                           drawTunnelNodesForeground
M.renderLayer =                                         renderLayer
M.renderMasterLayer =                                   renderMasterLayer
M.renderShells =                                        renderShells
M.renderRibbonWireFrame =                               renderRibbonWireFrame
M.renderHalfSplineWireFrame =                           renderHalfSplineWireFrame
M.renderWireframeRibbons =                              renderWireframeRibbons
M.renderHomologatedSurface =                            renderHomologatedSurface
M.renderDrivePathSurface =                              renderDrivePathSurface
M.renderPreviewRibbon =                                 renderPreviewRibbon
M.renderVelocities =                                    renderVelocities
M.renderVelocitiesGraph =                               renderVelocitiesGraph
M.renderCandidateLoop =                                 renderCandidateLoop
M.renderCandidateJoin =                                 renderCandidateJoin

M.renderRibbon =                                        handleRibbonRendering
M.renderWorldGraphNodes =                               renderWorldGraphNodes
M.renderWorldGraphNodeBackdrops =                       renderWorldGraphNodeBackdrops

M.renderNavGraph =                                      renderNavGraph
M.renderGraphPath =                                     renderGraphPath
M.renderChosenNodes =                                   renderChosenNodes
M.renderSplinePolylines =                               renderSplinePolylines
M.drawSplineLineUnselected =                            drawSplineLineUnselected

return M