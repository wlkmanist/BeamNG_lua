-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}


-- External modules used.
local roadMgr = require('editor/tech/roadArchitect/roads')                                          -- Manages the road structure/handling road calculations.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- Manages the profiles structure/handling profile calculations.
local geom = require('editor/tech/roadArchitect/geometry')                                          -- A module for performing geometric calculations.
local util = require('editor/tech/roadArchitect/utilities')                                         -- A utilities module.

-- Module constants.
local abs, min, max, sqrt = math.abs, math.min, math.max, math.sqrt
local zeroVec = vec3(0, 0)
local tmp0, tmp1, tmp2, tmp3 = vec3(0, 0), vec3(0, 0), vec3(0, 0), vec3(0, 0)
local pS, pE = vec3(0, 0), vec3(0, 0)


-- Projects vector (a) onto vector (b).
local function project(a, b) return (a:dot(b) / b:dot(b)) * b end

-- Compute appropriate Chordal-CR-based tangents for the cubic going through p0-p1-p2-p3.
local function computeTangents(p0, p1, p2, p3)
  local d1 = max(p0:distance(p1), 1e-12)
  local d2 = p1:distance(p2)
  local d3 = max(p2:distance(p3), 1e-12)
  local m = (p1 - p0) / d1 + (p0 - p2) / (d1 + d2)
  local n = (p1 - p3) / (d2 + d3) + (p3 - p2) / d3
  local p12 = p2 - p1
  local t1 = (d2 * m) + p12
  if t1:length() < 1e-5 then
    t1 = p12 * 0.5
  end
  local t2 = (d2 * n) + p12
  if t2:length() < 1e-5 then
    t2 = p12 * 0.5
  end
  return t1, t2
end

-- Fits an explicit cubic polynomial, f(z) through p0-p1-p2-p3.
local function fitExpCubic(p0, p1, p2, p3, length)
  local t1, t2 = computeTangents(p0 - p1, zeroVec, p2 - p1, p3 - p1)
  local t1z, t2z, dz = t1.z, t2.z, p2.z - p1.z
  local lengthSq = length * length
  return {
    a = p1.z,
    b = t1z / length,
    c = ((-2.0 * t1z) - t2z + (3.0 * dz)) / lengthSq,
    d = (t1z + t2z - (2.0 * dz)) / (lengthSq * length) }
end

-- Fits a parametric cubic polynomial through p0-p1-p2-p3.
-- [The Z-dimension is eliminated, so as to produce a 2D poly in (u, v)].
local function fitParaCubic2D(p0, p1, p2, p3)
  tmp0:set(p0.x, p0.y, 0)
  tmp1:set(p1.x, p1.y, 0)
  tmp2:set(p2.x, p2.y, 0)
  tmp3:set(p3.x, p3.y, 0)
  local p0_2d, p1_2d, p2_2d, p3_2d = tmp0 - tmp1, zeroVec, tmp2 - tmp1, tmp3 - tmp1
  local t1, t2 = computeTangents(p0_2d, p1_2d, p2_2d, p3_2d)
  local coeffC, coeffD = (-2.0 * t1) - t2 + (3.0 * p2_2d), t1 + t2 - (2.0 * p2_2d)
  return {
    uA = p1_2d.x, uB = t1.x, uC = coeffC.x, uD = coeffD.x,
    vA = p1_2d.y, vB = t1.y, vC = coeffC.y, vD = coeffD.y }
end

-- Computes the start/end points for linked roads.
local function computeLinkingPoints(road, roads)

  -- Compute the tangent for the road start, if there is a link there.
  if road.isLinkRoad then

    local rD, p = road.renderData[1], nil
    if rD[-1] then
      p = rD[-1][3]
    else
      p = rD[1][4]
    end
    pS:set(p.x, p.y, 0.0)
    local rDataS = roads[roadMgr.map[road.startR]].renderData
    local rSIdx, fIdx = 1, 2
    if road.startLie == 'end' then
      rSIdx = #rDataS
      fIdx = rSIdx - 1
    end
    local t1 = rDataS[fIdx][road.idxL1][road.idxL2]
    tmp2:set(t1.x, t1.y, 0.0)

    -- Compute the tangent for the road end, if there is a link there.
    local rData = road.renderData
    local rD, p = rData[#rData], nil
    if rD[-1] then
      p = rD[-1][3]
    else
      p = rD[1][4]
    end
    pE:set(p.x, p.y, 0.0)
    local rDataE = roads[roadMgr.map[road.endR]].renderData
    local rEIdx, fIdx = 1, 2
    if road.endLie == 'end' then
      rEIdx = #rDataE
      fIdx = rEIdx - 1
    end
    local t4 = rDataE[fIdx][road.idxR1][road.idxR2]
    tmp3:set(t4.x, t4.y, 0.0)
  end

  return tmp2, tmp3
end

-- Converts a spline-based road into OpenDRIVE-compatible geometry.
local function convertRoadToODGeom(r, roads)

  -- Compute the appropriate render data indices for the road reference line.
  local rData, idx1, idx2 = r.renderData, nil, nil
  if rData[1][-1] then
    idx1, idx2 = -1, 3
  else
    idx1, idx2 = 1, 4
  end

  -- Compute the lengths at each div point.
  local lengths, sum, numDivs = { 0.0 }, 0.0, #rData
  for i = 2, numDivs do
    local p1, p2 = rData[i - 1][idx1][idx2], rData[i][idx1][idx2]
    tmp0:set(p1.x, p1.y, 0.0)
    tmp1:set(p2.x, p2.y, 0.0)
    sum = sum + tmp1:distance(tmp0)
    lengths[i] = sum
  end

  -- Create the outgoing geometry structue with some core properties.
  local gData = { length = sum }

  -- For link roads, compute the extra (other road) points, using the linking road data.
  -- [These are used to compute the appropriate tangents at the start/end of the road].
  local t1, t4 = computeLinkingPoints(r, roads)

  -- Iterate over the road line segments, from start to end.
  local isLinkRoad = r.isLinkRoad
  local laneKeys, numDivs = r.laneKeys, #rData
  for i = 2, numDivs do

    -- Compute the four relevant reference line points and fit a parametric cubic through them.
    local iMinus1 = i - 1
    local div1, div2, div3, div4 = rData[max(1, i - 2)], rData[iMinus1], rData[i], rData[min(numDivs, i + 1)]
    local p1, p2, p3, p4 = div1[idx1][idx2], div2[idx1][idx2], div3[idx1][idx2], div4[idx1][idx2]
    if isLinkRoad then
      if i == 2 then
        p1 = t1
      elseif i == numDivs then
        p4 = t4
      end
    end
    local refLineCubic = fitParaCubic2D(p1, p2, p3, p4)

    -- Compute the geodesic length of this line segment.
    tmp0:set(p2.x, p2.y, 0.0)
    tmp1:set(p3.x, p3.y, 0.0)
    local segLength = tmp1:distance(tmp0)

    -- Fit an explicit cubic through the points, for the road elevation encoding.
    local elevCubic = fitExpCubic(p1, p2, p3, p4, segLength)

    -- Fit explicit cubics through each lane width, for the road width encoding.
    local p1x, p1y, p2x, p2y, p3x, p3y, p4x, p4y = p1.x, p1.y, p2.x, p2.y, p3.x, p3.y, p4.x, p4.y
    local profile = r.profile
    local widthCubics = {}
    for key, _ in pairs(laneKeys) do
      local k = laneKeys[key]
      tmp0:set(p1x, p1y, div1[k][9])
      tmp1:set(p2x, p2y, div2[k][9])
      tmp2:set(p3x, p3y, div3[k][9])
      tmp3:set(p4x, p4y, div4[k][9])
      widthCubics[k] = { cubic = fitExpCubic(tmp0, tmp1, tmp2, tmp3, segLength), type = profile[k].type }
    end

    -- Fit explicit cubics through the lateral rotation (super-elevation) encoding.
    tmp0:set(p1x, p1y, div1[idx1][12])
    tmp1:set(p2x, p2y, div2[idx1][12])
    tmp2:set(p3x, p3y, div3[idx1][12])
    tmp3:set(p4x, p4y, div4[idx1][12])
    local superElevCubic = fitExpCubic(tmp0, tmp1, tmp2, tmp3, segLength)

    -- Collect the inner/outer lane height offset data.
    local laneHOffsets = {}
    for key, _ in pairs(laneKeys) do
      local k = laneKeys[key]
      local dk2 = div2[k]
      local lH2, rH2 = dk2[10], dk2[11]
      if k < 0 then
        laneHOffsets[k] = { inner = rH2, outer = lH2 }
      else
        laneHOffsets[k] = { inner = lH2, outer = rH2 }
      end
    end

    -- Populate the geometric data for this line segment.
    local lastLength = lengths[iMinus1]
    gData[iMinus1] = {
      s = lastLength,
      start = p2,
      length = lengths[i] - lastLength,
      refLine = refLineCubic,
      elev = elevCubic,
      widths = widthCubics,
      superElev = superElevCubic,
      laneOffsets = laneHOffsets }
  end
  return gData
end

-- Compute the lane-mapping data between two roads.
-- [Keys are the lanes of first road, values are the corresponding lanes of second road].
local function computeLaneMap(r1, r1Lie, r2, r2Lie)
  local rData1, rData2 = r1.renderData[1], r2.renderData[1]
  local map, laneKeys1, laneKeys2 = {}, r1.laneKeys, r2.laneKeys
  for key1, _ in pairs(laneKeys1) do
    local k1 = laneKeys1[key1]
    local p1 = rData1[k1][7]
    for key2, _ in pairs(laneKeys2) do
      local k2 = laneKeys2[key2]
      if p1:squaredDistance(rData2[k2][7]) < 1e-2 then
        map[k1] = k2
        break
      end
    end
  end
  return map
end

-- Identifies and collates all junctions.
-- [This is anywhere in the road network, where more than two roads meet].
local function computeJunctions(roads)

  -- Iterate over all roads in turn, and check for junctions.
  local map, junctions, jCtr, numRoads = roadMgr.map, {}, 1, #roads
  for i = 1, numRoads do
    local r = roads[i]
    local nodes = r.nodes
    local rStart, rEnd, sLinks, eLinks = nodes[1].p, nodes[#nodes].p, r.isLinkedToS, r.isLinkedToE
    local numSLinks, numELinks = #sLinks, #eLinks

    -- Create a junction for this road start, if there are multiple links there.
    if numSLinks > 1 then
      junctions[jCtr] = { { idx = i, lie = 'start' } }
      for j = 1, numSLinks do
        local rIdx = map[sLinks[j]]
        local rT = roads[rIdx]
        local tNodes = rT.nodes
        local d1 = rStart:squaredDistance(tNodes[1].p)
        local d2 = rStart:squaredDistance(tNodes[#tNodes].p)
        local rLie = 'start'
        if d1 > d2 then
          rLie = 'end'
        end
        junctions[jCtr][j + 1] = { idx = rIdx, lie = rLie, laneMap = computeLaneMap(r, 'start', rT, rLie) }
      end
      jCtr = jCtr + 1
    end

    -- Create a junction for this road end, if there are multiple links there.
    if numELinks > 1 then
      junctions[jCtr] = { { idx = i, lie = 'end' } }
      for j = 1, numELinks do
        local rIdx = map[eLinks[j]]
        local rT = roads[rIdx]
        local tNodes = rT.nodes
        local d1 = rEnd:squaredDistance(tNodes[1].p)
        local d2 = rEnd:squaredDistance(tNodes[#tNodes].p)
        local rLie = 'start'
        if d1 > d2 then
          rLie = 'end'
        end
        junctions[jCtr][j + 1] = { idx = rIdx, lie = rLie, laneMap = computeLaneMap(r, 'end', rT, rLie) }
      end
      jCtr = jCtr + 1
    end
  end

  return junctions
end

-- Determines the lie of a given road, with respect to another given road.
local function determineLie(r1, r1Lie, r2)

  -- If the lie of the first road is the start point.
  if r1Lie == 'start' then
    local p1 = r1.nodes[1].p
    if p1:squaredDistance(r2.nodes[1].p) < p1:squaredDistance(r2.nodes[#r2.nodes].p) then
      return 'start'
    end
    return 'end'
  end

  -- If the lie of the first road is the end point.
  local p1 = r1.nodes[#r1.nodes].p
  if p1:squaredDistance(r2.nodes[1].p) < p1:squaredDistance(r2.nodes[#r2.nodes].p) then
    return 'start'
  end
  return 'end'
end

-- Computes the predecessor and successor data for each road.
-- [The predecessor/successor of a road may be either another road or a junction].
local function computePredSucc(roads, junctions)
  local map, pred, succ, numRoads, numJcts = roadMgr.map, {}, {}, #roads, #junctions
  for i = 1, numRoads do

    -- Compute the predecessors for this road.
    local r = roads[i]
    local sLinks = r.isLinkedToS
    local numSLinks = #sLinks
    if numSLinks == 0 then
      pred[i] = { type = '', id = -1 }
    elseif numSLinks == 1 then
      local rId = map[sLinks[1]]
      pred[i] = { type = 'road', id = rId, lie = determineLie(r, 'start', roads[rId]) }
    elseif numSLinks > 1 then
      for j = 1, numJcts do
        local jctItem = junctions[j][1]
        if jctItem.idx == i and jctItem.lie == 'start' then
          pred[i] = { type = 'junction', id = j }
          break
        end
      end
    end

    -- Compute the successors for this road.
    local eLinks = r.isLinkedToE
    local numELinks = #eLinks
    if numELinks == 0 then
      succ[i] = { type = '', id = -1 }
    elseif numELinks == 1 then
      local rId = map[eLinks[1]]
      succ[i] = { type = 'road', id = rId, lie = determineLie(r, 'end', roads[rId]) }
    elseif numELinks > 1 then
      for j = 1, numJcts do
        local jctItem = junctions[j][1]
        if jctItem.idx == i and jctItem.lie == 'end' then
          succ[i] = { type = 'junction', id = j }
          break
        end
      end
    end
  end
  return pred, succ
end

-- Computes the OpenDRIVE lane type string, from the editor lane type class.
local function getTypeString(type)
  if type == 'road_lane' then return 'driving' end
  if type == 'sidewalk' then return 'walking' end
  if type == 'cycle_lane' then return 'biking' end
  return 'restricted'                                                                               -- Default value (used for islands and concrete).
end

-- Composes and writes the .xodr file to disk.
local function writeXodr(geometry, junctions, pred, succ)
  extensions.editor_fileDialog.saveFile(
    function(data)
      local f = io.open(data.filepath, "w")

      -- Write the .xodr preamble.
      f:write('<?xml version="1.0" standalone="yes"?>\n')
      f:write('<OpenDRIVE>\n')
      f:write('<header revMajor="1" revMinor="8" name="" version="1.00" date="' .. os.date("%Y%m%d%H%M%S") .. '" north="0.0" south="0.0" east="0.0" west="0.0">\n')
      f:write('</header>\n')

      -- Write the roads data.
      local numGeom = #geometry
      for i = 1, numGeom do

        -- Cache the requisite data from the pre-computed structures.
        local geom, pred, succ = geometry[i], pred[i], succ[i]

        -- Road header data.
        f:write('<road rule="RHT" length="' .. tostring(geom.length) .. '" id="' .. tostring(i - 1) .. '" junction="-1" >\n')

        -- Write the connectivity data for this road (predecessor/successor roads).
        f:write('<link>\n')
        local pType = pred.type
        if pType == 'road' then
          f:write('<predecessor elementType="road" elementId="' .. tostring(pred.id - 1) .. '" contactPoint="' .. pred.lie .. '" />\n')
        elseif pType == 'junction' then
          f:write('<predecessor elementType="junction" elementId="' .. tostring(pred.id - 1) .. '" />\n')
        end
        local sType = succ.type
        if sType == 'road' then
          f:write('<successor elementType="road" elementId="' .. tostring(succ.id - 1) .. '" contactPoint="' .. succ.lie .. '" />\n')
        elseif sType == 'junction' then
          f:write('<successor elementType="junction" elementId="' .. tostring(succ.id - 1) .. '" />\n')
        end
        f:write('</link>\n')

        -- Write the reference line data for this road.
        f:write('<type s="0.0000000000000000e+00" type="town" country="DE"/>\n')
        f:write('<planView>\n')
        local numGeom = #geom
        for j = 1, numGeom do
          local g = geom[j]
          local gP, rL = g.start, g.refLine
          local s, pX, pY, length = tostring(g.s), tostring(gP.x), tostring(gP.y), tostring(g.length)
          local Au, Bu, Cu, Du = tostring(rL.uA), tostring(rL.uB), tostring(rL.uC), tostring(rL.uD)
          local Av, Bv, Cv, Dv = tostring(rL.vA), tostring(rL.vB), tostring(rL.vC), tostring(rL.vD)
          f:write('<geometry s="' .. s .. '" x="' .. pX .. '" y="' .. pY .. '" hdg="0.0" length="' .. length .. '">\n')
          f:write('<paramPoly3 aU="' .. Au .. '" bU="' .. Bu .. '" cU="' .. Cu .. '" dU="' .. Du .. '" aV="' .. Av .. '" bV="' .. Bv .. '" cV="' .. Cv .. '" dV="' .. Dv .. '"/>\n')
          f:write('</geometry>\n')
        end
        f:write('</planView>\n')

        -- Write the elevation data for this road.
        f:write('<elevationProfile>\n')
        for j = 1, numGeom do
          local g = geom[j]
          local s, el = tostring(g.s), g.elev
          local Ae, Be, Ce, De = tostring(el.a), tostring(el.b), tostring(el.c), tostring(el.d)
          f:write('<elevation s="' .. s .. '" a="' .. Ae .. '" b="' .. Be .. '" c="' .. Ce .. '" d="' .. De .. '"/>\n')
        end
        f:write('</elevationProfile>\n')

        -- Write the lateral profile data for this road. [We use super-elevation on export].
        f:write('<lateralProfile>\n')
        for j = 1, numGeom do
          local g = geom[j]
          local s, sE = tostring(g.s), g.superElev
          local Ae, Be, Ce, De = tostring(sE.a), tostring(sE.b), tostring(sE.c), tostring(sE.d)
          f:write('<superelevation s="' .. s .. '" a="' .. Ae .. '" b="' .. Be .. '" c="' .. Ce .. '" d="' .. De .. '"/>\n')
        end
        f:write('</lateralProfile>\n')

        -- Write the road lane data.
        f:write('<lanes>\n')
        for j = 1, numGeom do
          local g = geom[j]
          local widths, heights, s = g.widths, g.laneOffsets, tostring(g.s)
          f:write('<laneSection s="' .. s .. '">\n')

          -- Write the left lane data.
          for k = 20, 1, -1 do
            local lW = widths[k]
            if lW then
              local wCubic, type, hData = lW.cubic, lW.type, heights[k]
              local id, typeStr, inner, outer = tostring(k), getTypeString(type), hData.inner, hData.outer
              local Aw, Bw, Cw, Dw = tostring(wCubic.a), tostring(wCubic.b), tostring(wCubic.c), tostring(wCubic.d)
              f:write('<left>\n')
              f:write('<lane id="' .. id .. '" type="' .. typeStr .. '" level="false">\n')
              f:write('<link>\n')
              -- TODO: Could add lane linking info here.
              f:write('</link>\n')
              f:write('<width sOffset="0.0" a="' .. Aw .. '" b="' .. Bw .. '" c="' .. Cw .. '" d="' .. Dw .. '"/>\n')
              f:write('<height sOffset="0.0" inner="' .. inner .. '" outer="' .. outer .. '"/>\n')
              f:write('</lane>\n')
              f:write('</left>\n')
            end
          end

          -- Write the center lane data.
          f:write('<center>\n')
          f:write('<lane id="0" type="driving" level="false">\n')
          f:write('<link>\n')
          f:write('</link>\n')
          f:write('<roadMark sOffset="0.0" type="broken" weight="standard" color="standard" width="0.12" laneChange="both" height="0.02">\n')
          f:write('<type name="broken" width="0.12">\n')
          f:write('<line length="3.0" space="6.0" tOffset="0.0" sOffset="0.0" rule="caution" width="0.12"/>\n')
          f:write('</type>\n')
          f:write('</roadMark>\n')
          f:write('</lane>\n')
          f:write('</center>\n')

          -- Write the right lane data.
          for k = -1, -20, -1 do
            local lW = widths[k]
            if lW then
              local wCubic, type, hData = lW.cubic, lW.type, heights[k]
              local id, typeStr, inner, outer = tostring(k), getTypeString(type), hData.inner, hData.outer
              local Aw, Bw, Cw, Dw = tostring(wCubic.a), tostring(wCubic.b), tostring(wCubic.c), tostring(wCubic.d)
              f:write('<right>\n')
              f:write('<lane id="' .. id .. '" type="' .. typeStr .. '" level="false">\n')
              f:write('<link>\n')
              -- TODO: Could add lane linking info here.
              f:write('</link>\n')
              f:write('<width sOffset="0.0" a="' .. Aw .. '" b="' .. Bw .. '" c="' .. Cw .. '" d="' .. Dw .. '"/>\n')
              f:write('<height sOffset="0.0" inner="' .. inner .. '" outer="' .. outer .. '"/>\n')
              f:write('</lane>\n')
              f:write('</right>\n')
            end
          end

          f:write('</laneSection>\n')
        end
        f:write('</lanes>\n')

        -- Unused tags.
        f:write('<objects>\n')
        f:write('</objects>\n')
        f:write('<signals>\n')
        f:write('</signals>\n')
        f:write('<surface>\n')
        f:write('</surface>\n')

        -- Write the .xodr closing line, for this road.
        f:write('</road>\n')
      end

      -- Write the junction data, in order.
      local numJcts = #junctions
      for i = 1, numJcts do
        local jct = junctions[i]
        local sIdx = tostring(jct[1].idx - 1)
        f:write('<junction name="" id="' .. tostring(i - 1) .. '" type="direct">\n')
        local numConnections = #jct
        for j = 2, numConnections do
          local jC = jct[j]
          local cId, tIdx, tLie, laneMap = tostring(j - 2), tostring(jC.idx - 1), tostring(jC.lie), tostring(jC.laneMap)
          f:write('<connection id="' .. cId .. '" incomingRoad="' .. sIdx .. '" connectingRoad="' .. tIdx .. '" contactPoint="' .. tLie .. '">\n')
          for k = -20, 20 do
            local lMap = laneMap[k]
            if lMap then
              f:write('<laneLink from="' .. tostring(k) .. '" to="' .. tostring(lMap) .. '"/>\n')
            end
          end
          f:write('</connection>\n')
        end
        f:write('</junction>\n')
      end

      -- Write the .xodr closing line.
      f:write('</OpenDRIVE>\n')

      f:close()
    end,
    {{"xodr",".xodr"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Exports the Road Architect network to OpenDRIVE format (.xodr).
local function export()

  -- Remove any empty roads. There is nothing in them to export.
  local roadsIn = roadMgr.roads
  local roads, ctr, numRoadsIn = {}, 1, #roadsIn
  for i = 1, numRoadsIn do
    local r = roadsIn[i]
    if #r.nodes > 0 then
      roads[ctr] = roadsIn[i]
      ctr = ctr + 1
    end
  end

  -- Convert each road into OpenDRIVE-compatible geometry.
  local geometry, numRoads = {}, #roads
  for i = 1, numRoads do
    local r = roads[i]
    geometry[i] = convertRoadToODGeom(r, roads)
  end

  -- Identify and collate all junctions.
  -- [This is anywhere more than two roads meet].
  local junctions = computeJunctions(roads)

  -- Compute the predecessor and successor data for each road.
  -- [The predecessor/successor of a road may be either another road or a junction].
  local pred, succ = computePredSucc(roads, junctions)

  -- Compose and write the .xodr file to disk.
  writeXodr(geometry, junctions, pred, succ)
end


-- Public interface.
M.export =                                                export

return M