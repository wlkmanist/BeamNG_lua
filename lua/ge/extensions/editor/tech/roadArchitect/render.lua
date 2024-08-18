-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local zeroWidthTol = 1e-3                                                                           -- A tolerance used to determine if a line has zero width, or not.
local dowelLength = 1.0                                                                             -- The length of the dowel sections used in link roads, in meters.
local laneInfoDivStep = 10                                                                          -- The number of lateral division between each lane number marking.

local linkSplineGran = 100                                                                          -- The granularity of the link spline visualisation, when making road links.
local linkSplineSmoothingVal = 0.5                                                                  -- The amount of smoothing for the link spline visualisation, in [0, 1].

local groupPolygonElevVec = vec3(0, 0, 5)                                                           -- A vector used when rendering group creation 'fences' (polygons).

local dowelZVec = vec3(0, 0, -0.05)                                                                 -- A small vertical offset vectors used to draw dowels a little lower in z.

local refLineThickness = 8                                                                          -- The thickness of the road reference line, when drawn.
local roadThickness = 2                                                                             -- The thickness of the road outline mesh, when drawn.
local linkSplineThickness = 7                                                                       -- The thickness of the link spline visualisation.
local groupPolygonThickness = 7                                                                     -- The thickness of the group polygon polyline.
local groupPolygonThicknessTr = 3                                                                   -- The thickness of the group polygon polyline closing line segment.

local roadColor = color(0, 0, 255, 255)                                                             -- The colour of road visualisations, when drawn.
local tunnelColor = color(150, 150, 150, 255)                                                       -- The colour of tunnel visualisations, when drawn.
local refLineColor = color(255, 255, 127, 255)                                                      -- The colour of the road road reference line, when drawn.
local linkSplineColor = color(255, 0, 255, 127)                                                     -- The colour of the road link spline visualisation.
local nodeHighlightColor = color(0, 0, 255, 255)                                                    -- The colour of the highlight at each road reference node.
local laneStartHighlightColor = color(0, 255, 0, 255)                                               -- The colour of the highlight at each lane start point.
local laneEndHighlightColor = color(255, 0, 0, 255)                                                 -- The colour of the highlight at each lane end point.
local groupPolygonColor = color(255, 0, 255, 255)                                                   -- The colour of the group polygon polyline.
local groupPolygonColorTr = color(127, 127, 127, 255)                                               -- The colour of the closing line segment of the group polygon polyline.
local textA = color(25, 25, 25, 255)                                                                -- The markup text foreground colour.
local textB = color(255, 255, 255, 192)                                                             -- The markup text background colour.
local laneDirColor = color(255, 0, 0, 128)                                                          -- The lane direction markup colour.
local laneColours = {                                                                               -- The lane type colours, in the road surface visualisation.
  road_lane = color(128, 126, 120, 255),
  sidewalk = color(50, 50, 50, 255),
  cycle_lane = color(100, 100, 100, 255),
  curb = color(145, 117, 103, 255),
  lamp_post_L = color(0, 0, 150),
  lamp_post_R = color(0, 0, 150),
  lamp_post_D = color(0, 0, 150),
  crash_L = color(0, 0, 75),
  crash_R = color(0, 0, 75),
  concrete = color(0, 150, 0),
  bollards = color(0, 150, 150),
  fence = color(0, 75, 0) }

local nodeCullLimit = 200.0                                                                         -- The max distance at which to draw the nodes, in meters.
local secondaryCullLimit = 100.0                                                                    -- The max distance at which to draw the secondary details, in meters.
local textRenderLimit = 100.0                                                                       -- The max distance at which text will appear (lane numbering, node numbering).

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- Manages the profiles structure/handles profile calculations.
local util = require('editor/tech/roadArchitect/utilities')                                         -- A utilities module.
local dbgDraw = require('utils/debugDraw')

-- Private constants.
local min, max = math.min, math.max
local sin, cos, sqrt, twoPi = math.sin, math.cos, math.sqrt, math.pi * 2.0
local tmp0 = vec3(0, 0)
local up = vec3(0, 0, 1)
local linkSplineGranInv = 1.0 / linkSplineGran
local textRenderLimSq = textRenderLimit * textRenderLimit
local nodeCullLimitSq = nodeCullLimit * nodeCullLimit
local secondaryCullLimSq = secondaryCullLimit * secondaryCullLimit


-- Rotates vector v around unit axis k, by angle theta (in radians).
-- [This function uses the standard Rodrigues formula].
local function rotateVecAroundAxis(v, k, theta)
  local c = cos(theta)
  return v * c + k:cross(v) * sin(theta) + k * k:dot(v) * (1.0 - c)
end

-- Render the surface mesh.
-- [This consists of a triangulated covering of the road surface, bottom and sides].
local function renderRoadSurface(renderData, laneKeys, camPos, isDowelS, isDowelE)
  local numDivs, numLaneKeys = #renderData, #laneKeys
  for k = 1, numLaneKeys do
    local laneKey = laneKeys[k]
    local col = laneColours[renderData[1][laneKey][8]]
    if col then
      for j = 2, numDivs do
        local div1, div2 = renderData[j - 1], renderData[j]
        local ld1, ld2 = div1[laneKey], div2[laneKey]
        local b1, b2, b3, b4 = ld1[1], ld1[2], ld1[3], ld1[4]
        local f1, f2, f3, f4 = ld2[1], ld2[2], ld2[3], ld2[4]
        dbgDraw.drawTriSolid(b1, b2, f1, col, true)                                                 -- Top quad (the primary faces).
        dbgDraw.drawTriSolid(b1, f1, b2, col, true)
        dbgDraw.drawTriSolid(b2, f2, f1, col, true)
        dbgDraw.drawTriSolid(b2, f1, f2, col, true)

        -- Only draw the secondary faces (bottom and sides) if sufficiently close to the camera.
        if b4:squaredDistance(camPos) < secondaryCullLimSq then
          dbgDraw.drawTriSolid(b4, b3, f4, col, true)                                               -- Bottom quad.
          dbgDraw.drawTriSolid(b4, f4, b3, col, true)
          dbgDraw.drawTriSolid(b3, f3, f4, col, true)
          dbgDraw.drawTriSolid(b3, f4, f3, col, true)
          dbgDraw.drawTriSolid(b2, b3, f2, col, true)                                               -- Left side quad.
          dbgDraw.drawTriSolid(b2, f2, b3, col, true)
          dbgDraw.drawTriSolid(b3, f3, f2, col, true)
          dbgDraw.drawTriSolid(b3, f2, f3, col, true)
          dbgDraw.drawTriSolid(b1, b4, f1, col, true)                                               -- Right side quad.
          dbgDraw.drawTriSolid(b1, f1, b4, col, true)
          dbgDraw.drawTriSolid(b4, f4, f1, col, true)
          dbgDraw.drawTriSolid(b4, f1, f4, col, true)
          dbgDraw.drawTriSolid(b1, b2, b4, col, true)                                               -- Front quad.
          dbgDraw.drawTriSolid(b1, b4, b2, col, true)
          dbgDraw.drawTriSolid(b2, b4, b3, col, true)
          dbgDraw.drawTriSolid(b2, b3, b4, col, true)
          dbgDraw.drawTriSolid(f1, f2, f4, col, true)                                               -- Back quad.
          dbgDraw.drawTriSolid(f1, f4, f2, col, true)
          dbgDraw.drawTriSolid(f2, f4, f3, col, true)
          dbgDraw.drawTriSolid(f2, f3, f4, col, true)
        end
      end

      -- Draw the start dowel, if required.
      -- [These hide the gaps between road joins, and also appear in the procedural mesh versions of the roads upon finalise].
      if isDowelS then

        -- The start dowel.
        local b = renderData[1][laneKey]
        local prot = b[5]:cross(b[6]) * dowelLength
        local b1, b2, b3, b4 = b[1] + prot + dowelZVec, b[2] + prot + dowelZVec, b[3] + prot, b[4] + prot
        local f1, f2, f3, f4 = b[1] + dowelZVec, b[2] + dowelZVec, b[3], b[4]
        dbgDraw.drawTriSolid(b1, b2, f1, col, true)                                                 -- Top quad (the primary faces).
        dbgDraw.drawTriSolid(b1, f1, b2, col, true)
        dbgDraw.drawTriSolid(b2, f2, f1, col, true)
        dbgDraw.drawTriSolid(b2, f1, f2, col, true)

        -- Only draw the secondary faces (bottom and sides) if sufficiently close to the camera.
        if b4:squaredDistance(camPos) < secondaryCullLimSq then
          dbgDraw.drawTriSolid(b4, b3, f4, col, true)                                               -- Bottom quad.
          dbgDraw.drawTriSolid(b4, f4, b3, col, true)
          dbgDraw.drawTriSolid(b3, f3, f4, col, true)
          dbgDraw.drawTriSolid(b3, f4, f3, col, true)
          dbgDraw.drawTriSolid(b2, b3, f2, col, true)                                               -- Left side quad.
          dbgDraw.drawTriSolid(b2, f2, b3, col, true)
          dbgDraw.drawTriSolid(b3, f3, f2, col, true)
          dbgDraw.drawTriSolid(b3, f2, f3, col, true)
          dbgDraw.drawTriSolid(b1, b4, f1, col, true)                                               -- Right side quad.
          dbgDraw.drawTriSolid(b1, f1, b4, col, true)
          dbgDraw.drawTriSolid(b4, f4, f1, col, true)
          dbgDraw.drawTriSolid(b4, f1, f4, col, true)
          dbgDraw.drawTriSolid(b1, b2, b4, col, true)                                               -- Front quad.
          dbgDraw.drawTriSolid(b1, b4, b2, col, true)
          dbgDraw.drawTriSolid(b2, b4, b3, col, true)
          dbgDraw.drawTriSolid(b2, b3, b4, col, true)
          dbgDraw.drawTriSolid(f1, f2, f4, col, true)                                               -- Back quad.
          dbgDraw.drawTriSolid(f1, f4, f2, col, true)
          dbgDraw.drawTriSolid(f2, f4, f3, col, true)
          dbgDraw.drawTriSolid(f2, f3, f4, col, true)
        end
      end

      -- Draw the end dowel, if required.
      if isDowelE then

        -- The end dowel.
        local f = renderData[numDivs][laneKey]
        local prot = f[5]:cross(f[6]) * dowelLength
        local b1, b2, b3, b4 = f[1] + dowelZVec, f[2] + dowelZVec, f[3], f[4]
        local f1, f2, f3, f4 = f[1] - prot + dowelZVec, f[2] - prot + dowelZVec, f[3] - prot, f[4] - prot
        dbgDraw.drawTriSolid(b1, b2, f1, col, true)                                                 -- Top quad (the primary faces).
        dbgDraw.drawTriSolid(b1, f1, b2, col, true)
        dbgDraw.drawTriSolid(b2, f2, f1, col, true)
        dbgDraw.drawTriSolid(b2, f1, f2, col, true)

        -- Only draw the secondary faces (bottom and sides) if sufficiently close to the camera.
        if b4:squaredDistance(camPos) < secondaryCullLimSq then
          dbgDraw.drawTriSolid(b4, b3, f4, col, true)                                               -- Bottom quad.
          dbgDraw.drawTriSolid(b4, f4, b3, col, true)
          dbgDraw.drawTriSolid(b3, f3, f4, col, true)
          dbgDraw.drawTriSolid(b3, f4, f3, col, true)
          dbgDraw.drawTriSolid(b2, b3, f2, col, true)                                               -- Left side quad.
          dbgDraw.drawTriSolid(b2, f2, b3, col, true)
          dbgDraw.drawTriSolid(b3, f3, f2, col, true)
          dbgDraw.drawTriSolid(b3, f2, f3, col, true)
          dbgDraw.drawTriSolid(b1, b4, f1, col, true)                                               -- Right side quad.
          dbgDraw.drawTriSolid(b1, f1, b4, col, true)
          dbgDraw.drawTriSolid(b4, f4, f1, col, true)
          dbgDraw.drawTriSolid(b4, f1, f4, col, true)
          dbgDraw.drawTriSolid(b1, b2, b4, col, true)                                               -- Front quad.
          dbgDraw.drawTriSolid(b1, b4, b2, col, true)
          dbgDraw.drawTriSolid(b2, b4, b3, col, true)
          dbgDraw.drawTriSolid(b2, b3, b4, col, true)
          dbgDraw.drawTriSolid(f1, f2, f4, col, true)                                               -- Back quad.
          dbgDraw.drawTriSolid(f1, f4, f2, col, true)
          dbgDraw.drawTriSolid(f2, f4, f3, col, true)
          dbgDraw.drawTriSolid(f2, f3, f4, col, true)
        end
      end
    end
  end
end

-- Renders the road outline mesh (wireframe).
local function renderRoadOutline(renderData, laneKeys, camPos)

  -- The front cross-sectional lines.
  local div1 = renderData[1]
  local numDivs, numLaneKeys = #renderData, #laneKeys
  for k = 1, numLaneKeys do
    local laneKey = laneKeys[k]
    local ld1 = div1[laneKey]
    if ld1[8] ~= 'island' then                                                                      -- Do not draw the outline for island lanes.
      dbgDraw.drawLineInstance_MinArg(ld1[1], ld1[2], roadThickness, roadColor)                     -- Draw the primary cross section quadrilateral lines for div1.

      -- If sufficiently close to the camera, draw all the lines of the cross section.
      if ld1[2]:squaredDistance(camPos) < secondaryCullLimSq then
        dbgDraw.drawLineInstance_MinArg(ld1[2], ld1[3], roadThickness, roadColor)                   -- Draw the secondary cross section quadrilateral lines for div1.
        dbgDraw.drawLineInstance_MinArg(ld1[3], ld1[4], roadThickness, roadColor)
        dbgDraw.drawLineInstance_MinArg(ld1[4], ld1[1], roadThickness, roadColor)
      end
    end
  end

  -- The line segment cross sectional lines, and lines joining to previous cross section.
  for j = 2, numDivs do
    local div1, div2 = renderData[j - 1], renderData[j]
    for k = 1, numLaneKeys do
      local laneKey = laneKeys[k]
      local ld1, ld2 = div1[laneKey], div2[laneKey]
      if ld1[8] ~= 'island' then                                                                    -- Do not draw the outline for island lanes.
        dbgDraw.drawLineInstance_MinArg(ld2[1], ld2[2], roadThickness, roadColor)                   -- Draw the primary cross section quadrilateral lines for div2.

        dbgDraw.drawLineInstance_MinArg(ld1[1], ld2[1], roadThickness, roadColor)                   -- Draw the primary joining lines from div1 to div2 (top lines).
        dbgDraw.drawLineInstance_MinArg(ld1[2], ld2[2], roadThickness, roadColor)

        -- If sufficiently close to the camera, draw all the lines of the cuboid.
        if ld1[2]:squaredDistance(camPos) < secondaryCullLimSq then
          dbgDraw.drawLineInstance_MinArg(ld2[2], ld2[3], roadThickness, roadColor)                 -- Draw the secondary cross section quadrilateral lines for div2.
          dbgDraw.drawLineInstance_MinArg(ld2[3], ld2[4], roadThickness, roadColor)
          dbgDraw.drawLineInstance_MinArg(ld2[4], ld2[1], roadThickness, roadColor)

          dbgDraw.drawLineInstance_MinArg(ld1[3], ld2[3], roadThickness, roadColor)                 -- Draw the secondary joining lines from div1 to div2 (bottom lines).
          dbgDraw.drawLineInstance_MinArg(ld1[4], ld2[4], roadThickness, roadColor)
        end
      end
    end
  end
end

-- Renders the road centerline.
local function renderRoadCenterline(renderData, laneKeys, camPos, isGroupMode)
  local numDivs = #renderData
  for j = 2, numDivs do
    local div1, div2 = renderData[j - 1], renderData[j]
    if div1[-1] then                                                                                -- Either lane '-1' or lane '1' must exist, so use whichever the road has.
      if isGroupMode or div1[-1][2]:squaredDistance(camPos) < secondaryCullLimSq then
        dbgDraw.drawLineInstance_MinArg(div1[-1][2], div2[-1][2], refLineThickness, refLineColor)
      end
    elseif div1[1] then
      if isGroupMode or div1[1][1]:squaredDistance(camPos) < secondaryCullLimSq then
        dbgDraw.drawLineInstance_MinArg(div1[1][1], div2[1][1], refLineThickness, refLineColor)
      end
    end
  end
end

-- Renders the node spheres (or square prisms for locked nodes).
local function renderNodeSpheres(nodes, camPos)
  local numNodes = #nodes
  for j = 1, numNodes do
    local node = nodes[j]
    local pos = node.p
    if pos:squaredDistance(camPos) < nodeCullLimitSq then
      local cam2Pos = sqrt(pos:distance(camPos))
      if node.isLocked then
        local nDist = 0.175 * cam2Pos
        local sqC = Point2F(nDist, nDist)
        tmp0:set(0, 0, nDist)
        dbgDraw.drawSquarePrism(pos - tmp0, pos + tmp0, sqC, sqC, nodeHighlightColor)
      else
        dbgDraw.drawSphere(pos, 0.1 * cam2Pos, nodeHighlightColor)
      end
    end
  end
end

-- Renders the lane end midpoint spheres (for link connections).
local function renderLaneEndMidpointSpheres(renderData, laneKeys, camPos)
  local numDivs, numLaneKeys = #renderData, #laneKeys
  local divS, divE = renderData[1], renderData[numDivs]
  for k = 1, numLaneKeys do
    local lane = laneKeys[k]
    local dSLane, dELane = divS[lane], divE[lane]
    if dSLane[9] > zeroWidthTol then                                                                -- Only display lane start sphere if the width is non-zero.
      local posS = dSLane[7]
      if posS:squaredDistance(camPos) < secondaryCullLimSq then
        dbgDraw.drawSphere(posS, 0.07 * sqrt(posS:distance(camPos)), laneStartHighlightColor)
      end
    end
    if dELane[9] > zeroWidthTol then                                                                -- Only display the lane end sphere if the width is non-zero.
      local posE = dELane[7]
      if posE:squaredDistance(camPos) < secondaryCullLimSq then
        dbgDraw.drawSphere(posE, 0.07 * sqrt(posE:distance(camPos)), laneEndHighlightColor)
      end
    end
  end
end

-- Renders the node numbering.
local function renderNodeNumbering(nodes, camPos)
  local numNodes = #nodes
  for j = 1, numNodes do
    local pos = nodes[j].p
    if pos:squaredDistance(camPos) < secondaryCullLimSq then
      dbgDraw.drawTextAdvanced(pos, tostring(j), textA, true, false, textB)
    end
  end
end

-- Renders the lane numbering.
local function renderLaneNumbering(renderData, laneKeys, isGroupMode, camPos)
  local numDivs, numLaneKeys = #renderData, #laneKeys
  if not isGroupMode then                                                                           -- Do not display lane numbering in group auditions.
    for j = 1, numDivs, laneInfoDivStep do                                                          -- Lane numbers will appear at every n lateral divisions.
      local div = renderData[j]
      for k = 1, numLaneKeys do
        local lane = laneKeys[k]
        local pos = div[lane][7]
        if pos:squaredDistance(camPos) < textRenderLimSq then
          dbgDraw.drawTextAdvanced(pos, tostring(lane), textA, true, false, textB)
        end
      end
    end
  end
end

-- Renders the lane direction triangles.
local function renderLaneDirectionTriangles(renderData, laneKeys, isGroupMode, camPos)
  local numDivs, numLaneKeys = #renderData, #laneKeys
  for j = 1, numDivs do
    local divM, div, divP = renderData[max(1, j - 1)], renderData[j], renderData[min(numDivs, j + 1)]
    for k = 1, numLaneKeys do
      local lane = laneKeys[k]
      local dL = div[lane]
      if dL[8] == 'road_lane' then                                                                  -- Only draw direction triangles for road lanes.
        local tgt, lat = divM[lane][7] - divP[lane][7], dL[2] - dL[1]
        tgt:normalize()
        lat:normalize()
        local p3 = (dL[1] + dL[2]) * 0.5
        if isGroupMode or p3:squaredDistance(camPos) < secondaryCullLimSq then
          if lane > 0 then
            local dPL = divP[lane]
            local p1, p2 = dPL[2], dPL[1]
            dbgDraw.drawTriSolid(p1, p2, p3, laneDirColor, true)
            dbgDraw.drawTriSolid(p1, p3, p2, laneDirColor, true)
          else
            local dML = divM[lane]
            local p1, p2 = dML[1], dML[2]
            dbgDraw.drawTriSolid(p1, p2, p3, laneDirColor, true)
            dbgDraw.drawTriSolid(p1, p3, p2, laneDirColor, true)
          end
        end
      end
    end
  end
end

-- Renders highlights at the selected lane-end midpoints (when designing a road link).
local function renderSelectedLaneEndMidpointHighlights(roads, map, link)
  local r1Idx, r2Idx = map[link.r1Name], map[link.r2Name]
  local r1, r2 = roads[r1Idx], roads[r2Idx]
  local l1, l2, lie1, lie2 = link.l1, link.l2, link.r1Lie, link.r2Lie
  if r1 then
    for i = -20, 20 do
      if l1[i] then
        if lie1 == 'start' then
          util.drawSphereHighlight(r1.renderData[1][i][7])
        else
          util.drawSphereHighlight(r1.renderData[#r1.renderData][i][7])
        end
      end
    end
  end
  if r2 then
    for i = -20, 20 do
      if l2[i] then
        if lie2 == 'start' then
          util.drawSphereHighlight(r2.renderData[1][i][7])
        else
          util.drawSphereHighlight(r2.renderData[#r2.renderData][i][7])
        end
      end
    end
  end
end

-- Render the road link edge spline (when designing a road link).
local function renderRoadLinkEdgeSpline(roads, map, link)
  local r1Idx, r2Idx = map[link.r1Name], map[link.r2Name]
  local r1, r2 = roads[r1Idx], roads[r2Idx]
  local l1, l2, lie1, lie2 = link.l1, link.l2, link.r1Lie, link.r2Lie
  if r1 and r2 then
    local rD1, rD2 = r1.renderData, r2.renderData
    local numDivs1, numDivs2 = #rD1, #rD2
    local l1MinKey, l1MaxKey = profileMgr.getMinMaxLaneKeys(l1)
    local l2MinKey, l2MaxKey = profileMgr.getMinMaxLaneKeys(l2)
    local p1, p2, p3, p4, o1, o2, o3, o4 = nil, nil, nil, nil, nil, nil, nil, nil
    if lie1 == 'start' and lie2 == 'start' then
      p1, p2, p3, p4 = rD1[2][l1MinKey][1], rD1[1][l1MinKey][1], rD2[1][l2MinKey][1], rD2[2][l2MinKey][1]
      o1, o2, o3, o4 = rD1[2][l1MaxKey][2], rD1[1][l1MaxKey][2], rD2[1][l2MaxKey][2], rD2[2][l2MaxKey][2]
      local pLast, oLast = o2, p2
      for j = 1, linkSplineGran do
        local q = j * linkSplineGranInv
        local p = catmullRomChordal(o1, o2, p3, p4, q, linkSplineSmoothingVal)
        local o = catmullRomChordal(p1, p2, o3, o4, q, linkSplineSmoothingVal)
        dbgDraw.drawLineInstance_MinArg(pLast, p, linkSplineThickness, linkSplineColor)
        dbgDraw.drawLineInstance_MinArg(oLast, o, linkSplineThickness, linkSplineColor)
        pLast, oLast = p, o
      end
    elseif lie1 == 'start' and lie2 == 'end' then
      local last2 = numDivs2 - 1
      p1, p2, p3, p4 = rD1[2][l1MinKey][1], rD1[1][l1MinKey][1], rD2[numDivs2][l2MinKey][1], rD2[last2][l2MinKey][1]
      o1, o2, o3, o4 = rD1[2][l1MaxKey][2], rD1[1][l1MaxKey][2], rD2[numDivs2][l2MaxKey][2], rD2[last2][l2MaxKey][2]
      local pLast, oLast = p2, o2
      for j = 1, linkSplineGran do
        local q = j * linkSplineGranInv
        local p = catmullRomChordal(p1, p2, p3, p4, q, linkSplineSmoothingVal)
        local o = catmullRomChordal(o1, o2, o3, o4, q, linkSplineSmoothingVal)
        dbgDraw.drawLineInstance_MinArg(pLast, p, linkSplineThickness, linkSplineColor)
        dbgDraw.drawLineInstance_MinArg(oLast, o, linkSplineThickness, linkSplineColor)
        pLast, oLast = p, o
      end
    elseif lie1 == 'end' and lie2 == 'start' then
      local last2 = numDivs1 - 1
      p1, p2, p3, p4 = rD1[last2][l1MinKey][1], rD1[numDivs1][l1MinKey][1], rD2[1][l2MinKey][1], rD2[2][l2MinKey][1]
      o1, o2, o3, o4 = rD1[last2][l1MaxKey][2], rD1[numDivs1][l1MaxKey][2], rD2[1][l2MaxKey][2], rD2[2][l2MaxKey][2]
      local pLast, oLast = p2, o2
      for j = 1, linkSplineGran do
        local q = j * linkSplineGranInv
        local p = catmullRomChordal(p1, p2, p3, p4, q, linkSplineSmoothingVal)
        local o = catmullRomChordal(o1, o2, o3, o4, q, linkSplineSmoothingVal)
        dbgDraw.drawLineInstance_MinArg(pLast, p, linkSplineThickness, linkSplineColor)
        dbgDraw.drawLineInstance_MinArg(oLast, o, linkSplineThickness, linkSplineColor)
        pLast, oLast = p, o
      end
    else
      local last1, last2 = numDivs1 - 1, numDivs2 - 1
      p1, p2, p3, p4 = rD1[last1][l1MinKey][1], rD1[numDivs1][l1MinKey][1], rD2[numDivs2][l2MinKey][1], rD2[last2][l2MinKey][1]
      o1, o2, o3, o4 = rD1[last1][l1MaxKey][2], rD1[numDivs1][l1MaxKey][2], rD2[numDivs2][l2MaxKey][2], rD2[last2][l2MaxKey][2]
      local pLast, oLast = o2, p2
      for j = 1, linkSplineGran do
        local q = j * linkSplineGranInv
        local p = catmullRomChordal(o1, o2, p3, p4, q, linkSplineSmoothingVal)
        local o = catmullRomChordal(p1, p2, o3, o4, q, linkSplineSmoothingVal)
        dbgDraw.drawLineInstance_MinArg(pLast, p, linkSplineThickness, linkSplineColor)
        dbgDraw.drawLineInstance_MinArg(oLast, o, linkSplineThickness, linkSplineColor)
        pLast, oLast = p, o
      end
    end
  end
end

-- Renders the group polygon/fence (when user is creating a group).
local function renderGroupPolygonFence(gPolygon)
  local gPolygonLen = #gPolygon
  for i = 1, gPolygonLen do
    local p = gPolygon[i]
    util.drawGroupSphere(p)
    dbgDraw.drawTextAdvanced(p, tostring(i), textA, true, false, textB)
  end
  for i = 2, gPolygonLen do
    local p1, p2 = gPolygon[i - 1], gPolygon[i]
    local p3, p4 = p1 + groupPolygonElevVec, p2 + groupPolygonElevVec
    dbgDraw.drawLineInstance_MinArg(p1, p2, groupPolygonThickness, groupPolygonColor)
    dbgDraw.drawLineInstance_MinArg(p3, p4, groupPolygonThickness, groupPolygonColor)
    dbgDraw.drawLineInstance_MinArg(p1, p3, groupPolygonThickness, groupPolygonColor)
    dbgDraw.drawLineInstance_MinArg(p2, p4, groupPolygonThickness, groupPolygonColor)
  end
  if gPolygonLen > 2 then
    local p1, p2 = gPolygon[1], gPolygon[gPolygonLen]
    local p3, p4 = p1 + groupPolygonElevVec, p2 + groupPolygonElevVec
    dbgDraw.drawLineInstance_MinArg(p1, p2, groupPolygonThicknessTr, groupPolygonColorTr)
    dbgDraw.drawLineInstance_MinArg(p3, p4, groupPolygonThicknessTr, groupPolygonColorTr)
    dbgDraw.drawLineInstance_MinArg(p1, p3, groupPolygonThicknessTr, groupPolygonColorTr)
    dbgDraw.drawLineInstance_MinArg(p2, p4, groupPolygonThicknessTr, groupPolygonColorTr)
  end
end

-- Renders the node highlights for a multi-selection.
local function renderMultiSelectNodes(roads, multi)
  for i = 1, #multi do
    local m = multi[i]
    util.drawSphereHighlight(roads[m.r].nodes[m.n].p)
  end
end

-- Renders a road tunnel.
local function renderTunnel(rData, t, camPos)

  -- Determine the pipe center and lateral edge indices.
  local rD1, cIdx1, cIdx2, lIdx, rIdx = rData[1], -1, 3, nil, nil
  if not rD1[-1] then
    cIdx1, cIdx2 = 1, 4
  end
  for i = -20, 20 do
    if rD1[i] then
      lIdx = i
      break
    end
  end
  for i = 20, -20, -1 do
    if rD1[i] then
      rIdx = i
      break
    end
  end

  -- Compute the ring at each longitudinal point in the given section.
  local iStart, iEnd, radGran, radOffset = t.s, t.e, t.radGran, t.radOffset
  local thickness, zOffsetFromRoad = t.thickness, t.zOffsetFromRoad
  local protrudeS, protrudeE = t.protrudeS, t.protrudeE
  local theta, zVec, roadLen, rGranP1 = twoPi / radGran, up * zOffsetFromRoad, #rData, radGran + 1
  local ringsI, ringsO = {}, {}
  local numRings = iEnd - iStart + 1
  for i = 1, numRings do
    local idx = iStart - 1 + i
    local rD = rData[idx]
    local rTan = rData[min(roadLen, idx + 1)][cIdx1][cIdx2] - rData[max(1, idx - 1)][cIdx1][cIdx2]
    rTan:normalize()                                                                                -- The road unit tangent vector.
    local rDLeft = rD[lIdx]
    local rNorm = rDLeft[5]                                                                         -- The road unit normal vector.
    local rLeft, rRight = rDLeft[4], rD[rIdx][3]                                                    -- The left-most and right-most lateral road points.
    local rCen = (rLeft + rRight) * 0.5                                                             -- The road lateral center.
    if i == 1 then
      rCen = rCen - rTan * protrudeS                                                                -- Protrude the start point, if required.
    elseif i == numRings then
      rCen = rCen + rTan * protrudeE                                                                -- Protrude the end point, if required.
    end
    local rWidth = rLeft:distance(rRight)                                                           -- The (lateral) road width at this longitudinal point.
    local nOff = rWidth + radOffset                                                                 -- The normal offset, based on the radii.
    local normWithRInner, normWithROuter = rNorm * (nOff - thickness), rNorm * (nOff + thickness)   -- The full normal offset vectors.
    local pCen = rCen + zVec                                                                        -- The pipe center.
    local ringI, ringO = {}, {}
    local zI = min(rLeft.z, rRight.z)
    local zO = zI - thickness
    for j = 1, rGranP1 do                                                                           -- Compute the cross-sectional rings of points aroung this lon. point.
      local angle = (j - 1) * theta
      ringI[j] = pCen + rotateVecAroundAxis(normWithRInner, rTan, angle)
      ringO[j] = pCen + rotateVecAroundAxis(normWithROuter, rTan, angle)
      ringI[j].z = max(ringI[j].z, zI)
      ringO[j].z = max(ringO[j].z, zO)
    end
    ringsI[i], ringsO[i] = ringI, ringO
  end

  -- Create the vertex arrays.
  local numRings = #ringsI
  local vertsO, vertsI, ctr = {}, {}, 1
  for i = 1, numRings do
    local ringI, ringO = ringsI[i], ringsO[i]
    for j = 1, rGranP1 do
      vertsI[ctr], vertsO[ctr] = ringI[j], ringO[j]
      ctr = ctr + 1
    end
  end

  -- Draw the faces.
  local numRingsMinus1, rGranP1, numVerts = numRings - 1, radGran + 1, #vertsO
  for i = 1, numRingsMinus1 do
    local i1 = min(numVerts, (i - 1) * rGranP1 + 1)
    local i2 = min(numVerts, i1 + 1)
    local i3 = min(numVerts, i1 + rGranP1)
    local i4 = min(numVerts, i2 + rGranP1)
    for j = 1, radGran do
      local tA, tB, tC, tD = vertsO[i1], vertsO[i2], vertsO[i3], vertsO[i4]
      dbgDraw.drawTriSolid(tA, tC, tB, tunnelColor, true)                                           -- Outer faces.
      dbgDraw.drawTriSolid(tA, tB, tC, tunnelColor, true)
      dbgDraw.drawTriSolid(tC, tD, tB, tunnelColor, true)
      dbgDraw.drawTriSolid(tC, tB, tD, tunnelColor, true)
      dbgDraw.drawLineInstance_MinArg(tA, tB, roadThickness, roadColor)
      dbgDraw.drawLineInstance_MinArg(tC, tD, roadThickness, roadColor)
      dbgDraw.drawLineInstance_MinArg(tA, tC, roadThickness, roadColor)
      dbgDraw.drawLineInstance_MinArg(tB, tD, roadThickness, roadColor)
      if tA:squaredDistance(camPos) < secondaryCullLimSq then
        tA, tB, tC, tD = vertsI[i1], vertsI[i2], vertsI[i3], vertsI[i4]
        dbgDraw.drawTriSolid(tA, tC, tB, tunnelColor, true)                                         -- Inner faces.
        dbgDraw.drawTriSolid(tA, tB, tC, tunnelColor, true)
        dbgDraw.drawTriSolid(tC, tD, tB, tunnelColor, true)
        dbgDraw.drawTriSolid(tC, tB, tD, tunnelColor, true)
        dbgDraw.drawLineInstance_MinArg(tA, tB, roadThickness, roadColor)
        dbgDraw.drawLineInstance_MinArg(tC, tD, roadThickness, roadColor)
        dbgDraw.drawLineInstance_MinArg(tA, tC, roadThickness, roadColor)
        dbgDraw.drawLineInstance_MinArg(tB, tD, roadThickness, roadColor)
      end
      i1, i2, i3, i4 = min(numVerts, i1 + 1), min(numVerts, i2 + 1), min(numVerts, i3 + 1), min(numVerts, i4 + 1)
    end
  end

  -- Start cap vertices.
  local capVertsS, ctr = {}, 1
  for i = 1, rGranP1 do
    capVertsS[ctr] = { x = vertsO[i].x, y = vertsO[i].y, z = vertsO[i].z }
    capVertsS[ctr + 1] = { x = vertsI[i].x, y = vertsI[i].y, z = vertsI[i].z }
    ctr = ctr + 2
  end

  -- Start cap faces.
  if vertsO[1]:squaredDistance(camPos) < secondaryCullLimSq then
    local vIdx = 1
    local numVerts = #capVertsS
    for i = 1, radGran do
      local tA, tB, tC, tD = capVertsS[min(numVerts, vIdx)], capVertsS[min(numVerts, vIdx + 2)], capVertsS[min(numVerts, vIdx + 3)], capVertsS[min(numVerts, vIdx + 1)]
      dbgDraw.drawTriSolid(tB, tD, tA, tunnelColor, true)
      dbgDraw.drawTriSolid(tB, tA, tD, tunnelColor, true)
      dbgDraw.drawTriSolid(tC, tD, tB, tunnelColor, true)
      dbgDraw.drawTriSolid(tC, tB, tD, tunnelColor, true)
      dbgDraw.drawLineInstance_MinArg(tA, tD, roadThickness, roadColor)
      vIdx = vIdx + 2
    end
  end

  -- End cap vertices
  local capVertsE, ctr, numVertsO = {}, 1, #vertsO
  for i = 1, rGranP1 do
    local idx = numVertsO - i + 1
    capVertsE[ctr] = { x = vertsO[idx].x, y = vertsO[idx].y, z = vertsO[idx].z }
    capVertsE[ctr + 1] = { x = vertsI[idx].x, y = vertsI[idx].y, z = vertsI[idx].z }
    ctr = ctr + 2
  end

  -- End cap faces.
  if vertsO[#vertsO]:squaredDistance(camPos) < secondaryCullLimSq then
    local vIdx = 1
    local numVerts = #capVertsE
    for i = 1, radGran do
      local tA, tB, tC, tD = capVertsE[min(numVerts, vIdx)], capVertsE[min(numVerts, vIdx + 2)], capVertsE[min(numVerts, vIdx + 3)], capVertsE[min(numVerts, vIdx + 1)]
      dbgDraw.drawTriSolid(tB, tD, tA, tunnelColor, true)
      dbgDraw.drawTriSolid(tB, tA, tD, tunnelColor, true)
      dbgDraw.drawTriSolid(tC, tD, tB, tunnelColor, true)
      dbgDraw.drawTriSolid(tC, tB, tD, tunnelColor, true)
      dbgDraw.drawLineInstance_MinArg(tA, tD, roadThickness, roadColor)
      vIdx = vIdx + 2
    end
  end
end

-- Renders all appropriate markups for roads which request them.
local function drawRoadMarkups(isGroupMode, isProfileMode, isCreateGroup, isMultiSelect, isMultiDone, isBulldoze, gPolygon, multi, isLinkMode, roads, map, link)
  local camPos = core_camera.getPosition()
  local numRoads = #roads
  for i = 1, numRoads do
    local r = roads[i]
    local nodes, isLinkRoad, isDowelS, isDowelE = r.nodes, r.isLinkRoad, r.isDowelS, r.isDowelE
    if (not r.isHidden or isGroupMode or isProfileMode) and #nodes > 0 then
      local renderData, laneKeys, numNodes = r.renderData, r.laneKeys, #nodes

      -- Only render the following, if there exists at least two nodes on the road.
      if numNodes > 1 then

        -- Draw the surface mesh, if requested.
        if r.isDisplayRoadSurface[0] then
          renderRoadSurface(renderData, laneKeys, camPos, isDowelS, isDowelE)
        end

        -- Draw the road outline, if requested.
        if r.isDisplayRoadOutline[0] then
          renderRoadOutline(renderData, laneKeys, camPos)
        end

        -- Draw the road reference line (centre line), if requested to do so.
        if r.isDisplayRefLine[0] then
          renderRoadCenterline(renderData, laneKeys, camPos, isGroupMode)
        end

        -- Draw the lane markups, if requested to do so.
        if r.isDisplayLaneInfo[0] and renderData then
          renderLaneNumbering(renderData, laneKeys, isGroupMode, camPos)                              -- Display the lane numbering.
          renderLaneDirectionTriangles(renderData, laneKeys, isGroupMode, camPos)                     -- Display the lane direction arrows.
        end

        -- Draw the road tunnels, if required.
        local tunnels = r.tunnels
        local numTunnels = #tunnels
        for tI = 1, numTunnels do
          renderTunnel(renderData, tunnels[tI], camPos)
        end
      end

      -- Only render the following if the editor is not in 'link mode' and is not editing a link.
      if not isLinkMode and not isLinkRoad then
        if r.isDisplayNodeSpheres[0] then
          renderNodeSpheres(nodes, camPos)                                                            -- Draw small highlights at each reference node, if requested to do so.
        end
        if r.isDisplayNodeNumbers[0] then
          renderNodeNumbering(nodes, camPos)                                                          -- Draw the node numbering, if requested to do so.
        end
      end

      -- Draw the start and end lane connection spheres.
      -- [These appear at every lane at the start and end positions of road, to allow linking].
      if isLinkMode and renderData then
        renderLaneEndMidpointSpheres(renderData, laneKeys, camPos)
      end
    end
  end

  -- If the user is creating a link, render the appropriate assistance.
  if link and link.isActive then
    renderSelectedLaneEndMidpointHighlights(roads, map, link)                                       -- Draw the selected lane end points.
    renderRoadLinkEdgeSpline(roads, map, link)                                                      -- Draw a line between the two link roads.
  end

  -- If the user is creating a group (drawing a perimeter polygon with the mouse).
  if isCreateGroup or isMultiSelect or isBulldoze then
    renderGroupPolygonFence(gPolygon)
  end

  -- If the user has created a multi-selection, highlight all relevant nodes.
  if isMultiDone then
    renderMultiSelectNodes(roads, multi)
  end
end


-- Public interface.
M.drawRoadMarkups =                                       drawRoadMarkups

return M