-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local latShrinkFac = 0.1                                                                            -- The amount by which to laterally shrink the decal widths, in meters.
local lonShrinkFac = 0.1                                                                            -- The amount by which to longitudinally shrink the decal widths, in meters.

---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}


-- External modules used.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- Manages the profiles structure/handling profile calculations.

-- Private constants.
local min, max = math.min, math.max
local raised = vec3(0, 0, 0.5)

-- Module state.
local asphaltDecals = {}


-- Compute the road sections from a given road.
-- [This is an array of contiguous sections of road lanes, with start and end lane indices].
local function computeSectionsByType(road, laneType)
  local sections, sCtr, s = {}, 1, nil
  local profile = road.profile
  for i = -20, 11 do                                                                                -- Iterate over all possible lanes, from left to right.
    if i ~= 0 then
      local lane = profile[i]
      if lane and lane.type == laneType then
        if not s then
          s = i                                                                                     -- If we find a lane of the given type, then start a section.
        end
      else
        if s then
          local e = i - 1                                                                           -- If we have started, and find a road not of the given type, then end the section.
          if e == 0 then
            e = -1
          end
          sections[sCtr] = {
            s = s, e = e,
            isOneWay = s * e > 0,                                                                   -- Determine if this section is a one-way road or not.
            lanesL = min(0, e) - min(0, s),                                                         -- Compute the number of left and right lanes in this section.
            lanesR = max(0, e) - max(0, s) }
          sCtr = sCtr + 1
          s = nil
        end
      end
    end
  end
  return sections
end

-- Compute the nodes/widths for the asphalt of a given section of a given road.
-- [The nodes are on the section centerline and the widths respect the section width].
local function computeSectionGeom(road, sStart, sEnd)
  local rData = road.renderData
  local nodes, widths, numDivs = {}, {}, #rData
  for i = 1, numDivs do
    local rD = rData[i]
    local pL, pR = rD[sStart][1], rD[sEnd][2]
    nodes[i], widths[i] = (pL + pR) * 0.5, pR:distance(pL)                                          -- Use the midpoint for this node.
  end
  nodes[1] = nodes[1] + (nodes[2] - nodes[1]):normalized() * lonShrinkFac                           -- Apply some longitudinal shrinkage to the start and end nodes.
  nodes[numDivs] = nodes[numDivs] + (nodes[numDivs - 1] - nodes[numDivs]):normalized() * lonShrinkFac
  return nodes, widths
end

-- Compute the nodes/widths for the road centerline of a given section of a given road.
local function computeCenterlineGeom(road, sStart, sEnd)
  local rData = road.renderData
  local idx1, idx2 = nil, nil                                                                       -- Get the correct indices for the centerline.
  if rData[1][-1] then
    idx1, idx2 = -1, 2
  elseif rData[1][1] then
    idx1, idx2 = 1, 1
  end
  if not idx1 then
    return false, nil, nil                                                                          -- If there is no centerline in this section, return false.
  end
  local nodes, widths, numDivs = {}, {}, #rData
  for i = 1, numDivs do
    nodes[i], widths[i] = rData[i][idx1][idx2], road.centerlineWidth[0]
  end
  nodes[1] = nodes[1] + (nodes[2] - nodes[1]):normalized() * lonShrinkFac                           -- Apply some longitudinal shrinkage to the start and end nodes.
  nodes[numDivs] = nodes[numDivs] + (nodes[numDivs - 1] - nodes[numDivs]):normalized() * lonShrinkFac
  return true, nodes, widths                                                                        -- The centerline exists in this section, so return true.
end

-- Compute the nodes/widths for the road left edge of a given section of a given road.
local function computeLeftEdgeGeom(road, sStart, sEnd)
  local rData = road.renderData
  local nodes, widths, numDivs = {}, {}, #rData
  for i = 1, numDivs do
    local rD = rData[i]
    local pL, pR = rD[sStart][1], rD[sEnd][2]
    local v = pR - pL
    v:normalize()
    nodes[i], widths[i] = pL + v * road.edgeDecalDist[0], road.edgeDecalWidth[0]
  end
  nodes[1] = nodes[1] + (nodes[2] - nodes[1]):normalized() * lonShrinkFac                           -- Apply some longitudinal shrinkage to the start and end nodes.
  nodes[numDivs] = nodes[numDivs] + (nodes[numDivs - 1] - nodes[numDivs]):normalized() * lonShrinkFac
  return nodes, widths
end

-- Compute the nodes/widths for the road right edge of a given section of a given road.
local function computeRightEdgeGeom(road, sStart, sEnd)
  local rData = road.renderData
  local nodes, widths, numDivs = {}, {}, #rData
  for i = 1, numDivs do
    local rD = rData[i]
    local pL, pR = rD[sStart][1], rD[sEnd][2]
    local v = pL - pR
    v:normalize()
    nodes[i], widths[i] = pR + v * road.edgeDecalDist[0], road.edgeDecalWidth[0]
  end
  nodes[1] = nodes[1] + (nodes[2] - nodes[1]):normalized() * lonShrinkFac                           -- Apply some longitudinal shrinkage to the start and end nodes.
  nodes[numDivs] = nodes[numDivs] + (nodes[numDivs - 1] - nodes[numDivs]):normalized() * lonShrinkFac
  return nodes, widths
end

-- Compute the nodes/widths for the road start (junction) line of a given section of a given road.
local function computeRoadStartGeom(road, sStart, sEnd)
  local rData = road.renderData
  local vL = rData[2][sStart][1] - rData[1][sStart][1]
  vL:normalize()
  local vR = rData[2][sEnd][2] - rData[1][sEnd][2]
  vR:normalize()
  local pL = rData[1][sStart][1] + vL * (lonShrinkFac + road.jctLineOffset[0])
  local pR = rData[1][sEnd][2] + vR * (lonShrinkFac + road.jctLineOffset[0])
  local v = pR - pL
  v:normalize()
  local nodes = { pL + v * latShrinkFac, pR - v * latShrinkFac }
  local widths = { road.jctLineWidth[0], road.jctLineWidth[0] }
  return nodes, widths
end

-- Compute the nodes/widths for the road end (junction) line of a given section of a given road.
local function computeRoadEndGeom(road, sStart, sEnd)
  local rData = road.renderData
  local last = #rData
  local last2 = last - 1
  local vL = rData[last2][sStart][1] - rData[last][sStart][1]
  vL:normalize()
  local vR = rData[last2][sEnd][2] - rData[last][sEnd][2]
  vR:normalize()
  local pL = rData[last][sStart][1] + vL * (lonShrinkFac + road.jctLineOffset[0])
  local pR = rData[last][sEnd][2] + vR * (lonShrinkFac + road.jctLineOffset[0])
  local v = pR - pL
  v:normalize()
  local nodes = { pL + v * latShrinkFac, pR - v * latShrinkFac }
  local widths = { road.jctLineWidth[0], road.jctLineWidth[0] }
  return nodes, widths
end

-- Compute the nodes/widths for the lane marking of a given section and lanes of a given road.
local function computeLaneMarkingGeom(road, sStart, sEnd, laneA, laneB)
  local rData = road.renderData
  local nodes, widths, numDivs = {}, {}, #rData
  for i = 1, numDivs do
    nodes[i], widths[i] = rData[i][laneA][2], road.laneMarkingWidth[0]
  end
  nodes[1] = nodes[1] + (nodes[2] - nodes[1]):normalized() * lonShrinkFac                           -- Apply some longitudinal shrinkage to the start and end nodes.
  nodes[numDivs] = nodes[numDivs] + (nodes[numDivs - 1] - nodes[numDivs]):normalized() * lonShrinkFac
  return nodes, widths
end

-- Creates a decal set for the given road.
-- [A decal set contains the main road decal, the centerline decal, road edge decals, lane division decals, and start/end junction line decals].
-- [The user can control the combination of these which will be rendered for the road, using the appropriate Imgui buttons].
local function createDecal(road, rIdx, numRoads)

  -- The decal does not exist, so create a new decal per section.
  local name = road.name
  asphaltDecals[name] = computeSectionsByType(road, 'road_lane')
  local numSections = #asphaltDecals[name]
  for s = 1, numSections do

    -- Create the asphalt road decal for this section.
    local sStart, sEnd = asphaltDecals[name][s].s, asphaltDecals[name][s].e
    local renderPrKeyDecal = rIdx * 2 + 12
    local renderPrKeyRoad = numRoads + rIdx * 2 + 13
    local section = asphaltDecals[name][s]
    asphaltDecals[name][s].road = createObject("DecalRoad")
    local dRoad = asphaltDecals[name][s].road
    --dRoad:setField("improvedSpline", 0, "true")
    dRoad:setField("overObjects", 0, "true")
    dRoad:setField("renderPriority", 0, renderPrKeyRoad)
    dRoad:setField("oneWay", 0, tostring(section.isOneWay))
    dRoad:setField("lanesLeft", 0, section.lanesL)
    dRoad:setField("lanesRight", 0, section.lanesR)
    dRoad:setField("material", 0, "road_asphalt_2lane")
    dRoad:setField("drivability", 0, 1.0)
    dRoad:registerObject("")
    scenetree.MissionGroup:add(dRoad)
    local nodes, widths = computeSectionGeom(road, sStart, sEnd)
    local numNodes, decalId = #nodes, dRoad:getID()
    if sStart > 0 and sEnd > 0 then
      for i = 1, numNodes do                                                                        -- For +ve only sections, we need to flip the node order.
        local idx = numNodes - i + 1
        editor.addRoadNode(decalId, { pos = nodes[idx] + raised, width = widths[idx] - latShrinkFac, index = i - 1 })
      end
    else
      for i = 1, numNodes do
        editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i] - latShrinkFac, index = i - 1 })
      end
    end

    -- Create the road centerline decal for this section.
    -- [This is only required if the road is two-way].
    if road.isRefLineDecal[0] and not section.isOneWay then
      local isCLInSection, nodes, widths = computeCenterlineGeom(road, sStart, sEnd)
      if isCLInSection then                                                                         -- Only create the centerline if it exists in this section.
        asphaltDecals[name][s].centerLine = createObject("DecalRoad")
        local cLine = asphaltDecals[name][s].centerLine
        --cLine:setField("improvedSpline", 0, "true")
        cLine:setField("overObjects", 0, "true")
        cLine:setField("renderPriority", 0, renderPrKeyDecal)
        cLine:setField("material", 0, "m_line_yellow_double")
        cLine:setField("drivability", 0, -1.0)
        cLine:registerObject("")
        scenetree.MissionGroup:add(cLine)
        local numNodes, decalId = #nodes, cLine:getID()
        for i = 1, numNodes do
          editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i], index = i - 1 })
        end
      end
    end

    -- Create the road edge decals.
    if road.isEdgeLineDecal[0] then
      asphaltDecals[name][s].leftEdge = createObject("DecalRoad")
      local lEdge = asphaltDecals[name][s].leftEdge
      --lEdge:setField("improvedSpline", 0, "true")
      lEdge:setField("overObjects", 0, "true")
      lEdge:setField("renderPriority", 0, renderPrKeyDecal)
      lEdge:setField("material", 0, "m_line_white")
      lEdge:setField("drivability", 0, -1.0)
      lEdge:registerObject("")
      scenetree.MissionGroup:add(lEdge)
      local nodes, widths = computeLeftEdgeGeom(road, sStart, sEnd)
      local numNodes, decalId = #nodes, lEdge:getID()
      for i = 1, numNodes do
        editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i], index = i - 1 })
      end

      asphaltDecals[name][s].rightEdge = createObject("DecalRoad")
      local rEdge = asphaltDecals[name][s].rightEdge
      --rEdge:setField("improvedSpline", 0, "true")
      rEdge:setField("overObjects", 0, "true")
      rEdge:setField("renderPriority", 0, renderPrKeyDecal)
      rEdge:setField("material", 0, "m_line_white")
      rEdge:setField("drivability", 0, -1.0)
      rEdge:registerObject("")
      scenetree.MissionGroup:add(rEdge)
      local nodes, widths = computeRightEdgeGeom(road, sStart, sEnd)
      local numNodes, decalId = #nodes, rEdge:getID()
      for i = 1, numNodes do
        editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i], index = i - 1 })
      end
    end

    -- Create the road start (pedestrian crossing) decal.
    if road.isStartLineDecal[0] then
      asphaltDecals[name][s].roadStart = createObject("DecalRoad")
      local rStart = asphaltDecals[name][s].roadStart
      --rStart:setField("improvedSpline", 0, "true")
      rStart:setField("overObjects", 0, "true")
      rStart:setField("renderPriority", 0, renderPrKeyDecal)
      rStart:setField("material", 0, "crossing_white")
      rStart:setField("drivability", 0, -1.0)
      rStart:registerObject("")
      scenetree.MissionGroup:add(rStart)
      local nodes, widths = computeRoadStartGeom(road, sStart, sEnd)
      local numNodes, decalId = #nodes, rStart:getID()
      for i = 1, numNodes do
        editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i], index = i - 1 })
      end
    end

    -- Create the road end (pedestrian crossing) decal.
    if road.isEndLineDecal[0] then
      asphaltDecals[name][s].roadEnd = createObject("DecalRoad")
      local rEnd = asphaltDecals[name][s].roadEnd
      --rEnd:setField("improvedSpline", 0, "true")
      rEnd:setField("overObjects", 0, "true")
      rEnd:setField("renderPriority", 0, renderPrKeyDecal)
      rEnd:setField("material", 0, "crossing_white")
      rEnd:setField("drivability", 0, -1.0)
      rEnd:registerObject("")
      scenetree.MissionGroup:add(rEnd)
      local nodes, widths = computeRoadEndGeom(road, sStart, sEnd)
      local numNodes, decalId = #nodes, rEnd:getID()
      for i = 1, numNodes do
        editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i], index = i - 1 })
      end
    end

    -- Create lane markings, for each lane which is on the same side.
    if road.isLaneDivsDecal[0] then
      asphaltDecals[name][s].laneMarkings = {}
      local lCtr = 1
      for laneB = sStart + 1, sEnd do
        local laneA = laneB - 1
        if laneA ~= 0 and laneB ~= 0 then
          asphaltDecals[name][s].laneMarkings[lCtr] = createObject("DecalRoad")
          local lMarking = asphaltDecals[name][s].laneMarkings[lCtr]
          --lMarking:setField("improvedSpline", 0, "true")
          lMarking:setField("overObjects", 0, "true")
          lMarking:setField("renderPriority", 0, renderPrKeyDecal)
          lMarking:setField("material", 0, "m_line_yellow_discontinue")
          lMarking:setField("drivability", 0, -1.0)
          lMarking:registerObject("")
          scenetree.MissionGroup:add(lMarking)
          local nodes, widths = computeLaneMarkingGeom(road, sStart, sEnd, laneA, laneB)
          local numNodes, decalId = #nodes, lMarking:getID()
          for i = 1, numNodes do
            editor.addRoadNode(decalId, { pos = nodes[i] + raised, width = widths[i], index = i - 1 })
          end
          lCtr = lCtr + 1
        end
      end
    end
  end

end

-- Removes a decal set from the scene.
local function removeDecalFromScene(decal)
  local numSections = #decal
  for s = 1, numSections do
    local d = decal[s]
    if d.road then
      d.road:delete()
    end
    if d.centerLine then
      d.centerLine:delete()
    end
    if d.leftEdge then
      d.leftEdge:delete()
    end
    if d.rightEdge then
      d.rightEdge:delete()
    end
    if d.roadStart then
      d.roadStart:delete()
    end
    if d.roadEnd then
      d.roadEnd:delete()
    end
    if d.laneMarkings then
      local numLaneMarkings = #d.laneMarkings
      for i = 1, numLaneMarkings do
        d.laneMarkings[i]:delete()
      end
    end
  end
end

-- Attempts to removes the decal set with the given name, from the scene (if it exists).
local function tryRemove(name)
  local decal = asphaltDecals[name]
  if decal then
    removeDecalFromScene(decal)
  end
  asphaltDecals[name] = nil
end

-- Attemps to remove all decal sets from the scene.
local function tryRemoveAll()
  for _, decal in pairs(asphaltDecals) do
    removeDecalFromScene(decal)
  end
  table.clear(asphaltDecals)
end


-- Public interface.
M.createDecal =                                           createDecal
M.tryRemove =                                             tryRemove
M.tryRemoveAll =                                          tryRemoveAll

return M