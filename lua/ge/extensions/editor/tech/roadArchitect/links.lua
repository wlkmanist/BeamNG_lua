-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}


-- External modules used.
local roadMgr = require('editor/tech/roadArchitect/roads')                                          -- Manages the road structure/handling road calculations.
local profileMgr = require('editor/tech/roadArchitect/profiles')                                    -- Manages the profiles structure.
local geom = require('editor/tech/roadArchitect/geometry')                                          -- The Road Architect geometry module.
local util = require('editor/tech/roadArchitect/utilities')                                         -- The Road Architect utilities module.

-- Private constants.
local min, max = math.min, math.max

-- Module state.
local link = {                                                                                      -- A table for storing a road linkage which is currently being built.
  isActive = false,                                                                                 -- A flag indicating if the link is active (the user is creating a link).
  r1Name = nil,                                                                                     -- The name of the first road of the link (link start).
  r1Lie = nil,                                                                                      -- The connection point of the first link road { 'start', 'end' }.
  r2Name = nil,                                                                                     -- The name of the second road of the link (link end).
  r2Lie = nil,                                                                                      -- The connection point of the first link road { 'start', 'end' }.
  l1 = {},                                                                                          -- The collection of adjacent lanes which comprise the first road.
  l2 = {} }                                                                                         -- The collection of adjacent lanes which comprise the second road.


-- Clears the link structure.
local function clearLink()
  link.isActive, link.r1Name, link.r2Name, link.r1Lie, link.r2Lie = false, nil, nil, nil, nil
  table.clear(link.l1)
  table.clear(link.l2)
end

-- Computes the intermediate width (inclusive) between two lanes in a collection.
local function intermediateWidthBetweenLanes(l1, l2, lanes, node)
  local nodeWidths = node.widths
  if l1 < l2 then
    local endIdx, wSum = l2 - 1, 0.0
    for i = l1 + 1, endIdx do
      local laneWidth = nodeWidths[i]
      if laneWidth then
        wSum = wSum + laneWidth[0]
      end
    end
    return wSum
  end
  local endIdx, wSum = l1 - 1, 0.0
  for i = l2 + 1, endIdx do
    local laneWidth = nodeWidths[i]
    if laneWidth then
      wSum = wSum + laneWidth[0]
    end
  end
  return wSum
end

-- Determines whether the given lane is adjacent to lanes from that road which are already in the link.
local function isLaneAdjacent(lIdx, lanes, profile)

  -- First, determine if the lanes are truly adjacent in the numerical sense.
  local m, p = lIdx - 1, lIdx + 1
  if m == 0 then
    m = -1
  end
  if p == 0 then
    p = 1
  end
  if lanes[m] or lanes[p] then
    return true
  end

  -- The lanes are not truly adjacent, but maybe there is no width between them, in which case we allow it.
  for k, _ in pairs(lanes) do
    if intermediateWidthBetweenLanes(lIdx, k, lanes, profile) < 1e-3 then
      return true
    end
  end

  -- There is no adjacency condition which has been satisfied, so return false.
  return false
end

-- Determines if a link lanes collection is empty or not.
local function isLinkLanesEmpty(lanes)
  for i = -20, 20 do
    if lanes[i] then
      return false
    end
  end
  return true
end

-- Determines if the lane with the given index is bounded on either side in a lane array.
local function isBounded(lIdx, lanes)
  local l, u = lIdx - 1, lIdx + 1
  if l == 0 then
    l = -1
  end
  if u == 0 then
    u = 1
  end
  return lanes[l] and lanes[u]
end

-- Carefully removes the given lane from the given link.
local function removeLaneFromLink(lIdx, side, link)
  local l1, l2 = link.l1, link.l2
  if side == 1 and l1[lIdx] and not isBounded(lIdx, l1) then
    l1[lIdx] = nil
    if isLinkLanesEmpty(l1) then
      link.r1Name, link.r1Lie = nil, nil
    end
  elseif side == 2 and l2[lIdx] and not isBounded(lIdx, l2) then
    l2[lIdx] = nil
    if isLinkLanesEmpty(l2) then
      link.r2Name, link.r2Lie = nil, nil
    end
  end
  if not link.r1Name and not link.r2Name then                                                       -- If neither road exists now, deactivate the link.
    link.isActive = false
  elseif not link.r1Name and link.r2Name then                                                       -- If no road 1, but a road 2 exists, switch them so there is only a road 1.
    link.r1Name, link.r1Lie, link.l1 = link.r2Name, link.r2Lie, link.l2
    link.r2Name, link.r2Lie, link.l2 = nil, nil, {}
  end
end

-- Determines whether the two given types are compatible or not.
local function isTypeMatched(t1, t2)
  if t1 == t2 then
    return true
  end
  if (t1 == 'lamp_post_L' or t1 == 'lamp_post_R' or t1 == 'lamp_post_D') and (t2 == 'lamp_post_L' or t2 == 'lamp_post_R' or t2 == 'lamp_post_D') then
    return true
  end
  if (t1 == 'curb_L' or t1 == 'curb_R') and (t2 == 'curb_L' or t2 == 'curb_R') then
    return true
  end
  if (t1 == 'crash_L' or t1 == 'crash_R') and (t2 == 'crash_L' or t2 == 'crash_R') then
    return true
  end
  return false
end

-- Determines whether or not the current link is valid wrt lane connectivity, and can be created.
local function isLinkValid(link)

  -- Ensure that the link is active and that the roads and lies are set.
  -- [If they are not, then the link is not valid yet].
  local roads = roadMgr.roads
  local lie1, lie2, name1, name2 = link.r1Lie, link.r2Lie, link.r1Name, link.r2Name
  if link.isActive and name1 and name2 and lie1 and lie2 then
    local map = roadMgr.map
    local r1Idx, r2Idx = map[name1], map[name2]
    local r1, r2 = roads[r1Idx], roads[r2Idx]
    local prof1, prof2 = r1.profile, r2.profile

    -- Count the number of left and right lanes in the link lanes 1 collection.
    local types1, dir1, ctr, lanes = {}, {}, 1, link.l1
    for i = -20, 20 do
      local ln = lanes[i]
      if ln then
        types1[ctr], dir1[ctr] = prof1[i].type, sign2(i)
        ctr = ctr + 1
      end
    end
    local types2, dir2, ctr, lanes = {}, {}, 1, link.l2
    for i = -20, 20 do
      local ln = lanes[i]
      if ln then
        types2[ctr], dir2[ctr] = prof2[i].type, sign2(i)
        ctr = ctr + 1
      end
    end

    -- Ensure we have the same number of lanes in each set.
    local numT1, numT2 = #types1, #types2
    if numT1 ~= numT2 then
      return false
    end

    -- Check that there is a match in in/out numbers, across all lane types.
    -- [This depends upon the case; either roads in same direction, or roads opposing].

    -- We have a flipped case start/start or end/end, so compare lane types in reverse order.
    if (lie1 == 'start' and lie2 == 'start') or (lie1 == 'end' and lie2 == 'end') then
      for i = 1, numT1 do
        local j = numT1 - i + 1
        if not isTypeMatched(types1[i], types2[j]) or dir1[i] == dir2[j] then
          return false
        end
      end
      return true
    end

    -- We do not have a flipped case, so compare lane types in the same direction.
    for i = 1, numT1 do
      if not isTypeMatched(types1[i], types2[i]) or dir1[i] ~= dir2[i] then
        return false
      end
    end
    return true
  end

  -- The link is not valid yet since all the data is not present.
  return false
end

-- Creates a new link between the two given roads.
-- [The link has been validated by this point].
local function createLink()

  -- Cache the relevant link data.
  local roads = roadMgr.roads
  local r1Name, r1Lie, l1 = link.r1Name, link.r1Lie, link.l1
  local r2Name, r2Lie, l2 = link.r2Name, link.r2Lie, link.l2
  local map = roadMgr.map
  local r1Idx, r2Idx = map[r1Name], map[r2Name]
  local l1MinKey, l1MaxKey = profileMgr.getMinMaxLaneKeys(l1)
  local l2MinKey, l2MaxKey = profileMgr.getMinMaxLaneKeys(l2)

  -- Compute some properties from the roads.
  local r1, r2 = roads[r1Idx], roads[r2Idx]
  local nodes1, nodes2 = r1.nodes, r2.nodes
  local numNodes1, numNodes2 = #nodes1, #nodes2

  -- Filter by linking case.
  local poly, f1, f2, f3, f4, nd1, nd2 = {}, nil, nil, nil, nil, nil, nil
  local wTrue1, wTrue2, rot1, rot2, off1, off2 = nil, nil, nil, nil, nil, nil
  local hLTrue1, hLTrue2, hRTrue1, hRTrue2 = nil, nil, nil, nil
  local isFlipped1, isFlipped2 = false, false
  local idxL0a_1, idxL0a_2, idxL0a_l2, idxL0a_l = nil, nil, nil, nil                                                -- Contribution masks for each relevant point, for optimisation:
  local idxL0b_1, idxL0b_2, idxL0b_l2, idxL0b_l = nil, nil, nil, nil                                                -- [1 = first, 2 = second, l2 = second last, l = last].
  local idxR0a_1, idxR0a_2, idxR0a_l2, idxR0a_l = nil, nil, nil, nil
  local idxR0b_1, idxR0b_2, idxR0b_l2, idxR0b_l = nil, nil, nil, nil
  if r1Lie == 'start' and r2Lie == 'start' then                                                                     -- [Case #1]: Join the START of road 1 to the START of road 2.
    idxL0a_1, idxL0a_2, idxL0a_l2, idxL0a_l = 0, 1, 0, 0
    idxL0b_1, idxL0b_2, idxL0b_l2, idxL0b_l = 1, 0, 0, 0
    idxR0a_1, idxR0a_2, idxR0a_l2, idxR0a_l = 1, 0, 0, 0
    idxR0b_1, idxR0b_2, idxR0b_l2, idxR0b_l = 0, 1, 0, 0
    f1, f2, f3, f4 = r1.renderData[2], r1.renderData[1], r2.renderData[1], r2.renderData[2]
    nd1, nd2 = nodes1[1], nodes2[1]
    wTrue1, wTrue2 = nd1.widths, nd2.widths
    hLTrue1, hLTrue2, hRTrue1, hRTrue2 = nd1.heightsR, nd2.heightsL, nd1.heightsL, nd2.heightsR
    rot1, rot2, off1, off2 = -nd1.rot[0], nd2.rot[0], -nd1.offset, nd2.offset
    isFlipped1 = true
  elseif r1Lie == 'start' and r2Lie == 'end' then                                                                   -- [Case #2]: Join the START of road 1 to the END of road 2.
    local last = #r2.renderData
    idxL0a_1, idxL0a_2, idxL0a_l2, idxL0a_l = 0, 1, 0, 0
    idxL0b_1, idxL0b_2, idxL0b_l2, idxL0b_l = 1, 0, 0, 0
    idxR0a_1, idxR0a_2, idxR0a_l2, idxR0a_l = 0, 0, 0, 1
    idxR0b_1, idxR0b_2, idxR0b_l2, idxR0b_l = 0, 0, 1, 0
    f1, f2, f3, f4 = r1.renderData[2], r1.renderData[1], r2.renderData[last], r2.renderData[last - 1]
    nd1, nd2 = nodes1[1], nodes2[numNodes2]
    wTrue1, wTrue2 = nd1.widths, nd2.widths
    hLTrue1, hLTrue2, hRTrue1, hRTrue2 = nd1.heightsR, nd2.heightsR, nd1.heightsL, nd2.heightsL
    rot1, rot2, off1, off2 = -nd1.rot[0], -nd2.rot[0], -nd1.offset, -nd2.offset
    isFlipped1, isFlipped2 = true, true
  elseif r1Lie == 'end' and r2Lie == 'start' then                                                                   -- [Case #3]: Join the END of road 1 to the START of road 2.
    local last = #r1.renderData
    idxL0a_1, idxL0a_2, idxL0a_l2, idxL0a_l = 0, 0, 1, 0
    idxL0b_1, idxL0b_2, idxL0b_l2, idxL0b_l = 0, 0, 0, 1
    idxR0a_1, idxR0a_2, idxR0a_l2, idxR0a_l = 1, 0, 0, 0
    idxR0b_1, idxR0b_2, idxR0b_l2, idxR0b_l = 0, 1, 0, 0
    f1, f2, f3, f4 = r1.renderData[last - 1], r1.renderData[last], r2.renderData[1], r2.renderData[2]
    nd1, nd2 = nodes1[numNodes1], nodes2[1]
    wTrue1, wTrue2 = nd1.widths, nd2.widths
    hLTrue1, hLTrue2, hRTrue1, hRTrue2 = nd1.heightsL, nd2.heightsL, nd1.heightsR, nd2.heightsR
    rot1, rot2, off1, off2 = nd1.rot[0], nd2.rot[0], nd1.offset, nd2.offset
  else                                                                                                              -- [Case #4]: Join the END of road 1 to the END of road 2.
    local last, last2 = #r1.renderData, #r2.renderData
    idxL0a_1, idxL0a_2, idxL0a_l2, idxL0a_l = 0, 0, 1, 0
    idxL0b_1, idxL0b_2, idxL0b_l2, idxL0b_l = 0, 0, 0, 1
    idxR0a_1, idxR0a_2, idxR0a_l2, idxR0a_l = 0, 0, 0, 1
    idxR0b_1, idxR0b_2, idxR0b_l2, idxR0b_l = 0, 0, 1, 0
    f1, f2, f3, f4 = r1.renderData[last - 1], r1.renderData[last], r2.renderData[last2], r2.renderData[last2 - 1]
    nd1, nd2 = nodes1[numNodes1], nodes2[numNodes2]
    wTrue1, wTrue2 = nd1.widths, nd2.widths
    hLTrue1, hLTrue2, hRTrue1, hRTrue2 = nd1.heightsL, nd2.heightsR, nd1.heightsR, nd2.heightsL
    rot1, rot2, off1, off2 = nd1.rot[0], -nd2.rot[0], nd1.offset, -nd2.offset
    isFlipped2 = true
  end

  -- Create a custom profile for this link road.
  local customProfile = profileMgr.createCustomLinkProfile(link, r1.profile, r1Lie)

  -- Re-map the lane width indices to match the custom profile lane width indices.
  local orderedLanes, numMatches = profileMgr.getOrderedLanes(customProfile)
  local w1Mapped, hL1Mapped, hR1Mapped = util.reMapWAndH(wTrue1, hLTrue1, hRTrue1, orderedLanes, l1MinKey, numMatches)
  local w2Mapped, hL2Mapped, hR2Mapped = util.reMapWAndH(wTrue2, hLTrue2, hRTrue2, orderedLanes, l2MinKey, numMatches)

  -- Flip the width values, as required.
  if isFlipped1 then
    w1Mapped, hL1Mapped, hR1Mapped = util.flipWAndH(w1Mapped, hL1Mapped, hR1Mapped)
  end
  if isFlipped2 then
    w2Mapped, hL2Mapped, hR2Mapped = util.flipWAndH(w2Mapped, hL2Mapped, hR2Mapped)
  end

  -- Compute the number of lanes from the left, at which the reference line lies on the new custom profile.
  local nfl = 0
  for i = -20, -1 do
    if customProfile[i] then
      nfl = nfl + 1
    end
  end

  -- Compute the appropriate points p1, p2, p3, p4 from roads r1 and r2 respectively.
  local idxL1, idxL2, idxR1, idxR2 = nil, nil, nil, nil
  if r1Lie == 'end' and r2Lie == 'start' then
    if l1MinKey > 0 and l2MinKey > 0 then
      idxL1, idxL2, idxR1, idxR2 = l1MinKey, 4, l2MinKey, 4
    else
      idxL1, idxL2, idxR1, idxR2 = l1MinKey + nfl - 1, 3, l2MinKey + nfl - 1, 3
    end
  elseif r1Lie == 'start' and r2Lie == 'end' then
    if l1MinKey > 0 and l2MinKey > 0 then
      idxL1, idxL2, idxR1, idxR2 = l1MinKey, 4, l2MinKey, 4
    else
      idxL1, idxL2, idxR1, idxR2 = l1MaxKey - nfl, 3, l2MaxKey - nfl, 3
      if idxL1 == 0 then
        idxL1 = -1
      end
      if idxR1 == 0 then
        idxR1 = -1
      end
    end
  elseif r1Lie == 'start' and r2Lie == 'start' then
    if l1MinKey * l1MaxKey > 0 then
      if l1MinKey < 0 then
        idxL1, idxL2 = l1MaxKey - nfl, 3
        if idxL1 < l1MinKey then
          idxL1, idxL2 = l1MinKey, 4
        end
      else
        idxL1, idxL2 = l1MinKey, 4
      end
    else
      idxL1, idxL2 = l1MaxKey - nfl, 3
      if idxL1 == 0 then
        idxL1 = -1
      end
    end
    if l2MinKey > 0 then
      idxR1, idxR2 = l2MinKey, 4
    else
      idxR1, idxR2 = l2MinKey + nfl - 1, 3
    end
  else
    if l1MinKey > 0 then
      idxL1, idxL2 = l1MinKey, 4
    else
      idxL1, idxL2 = l1MinKey + nfl - 1, 3
    end
    if l2MinKey * l2MaxKey > 0 then
      if l2MinKey < 0 then
        idxR1, idxR2 = l2MaxKey - nfl, 3
        if idxR1 < l2MinKey then
          idxR1, idxR2 = l2MinKey, 4
        end
      else
        idxR1, idxR2 = l2MinKey, 4
      end
    else
      idxR1, idxR2 = l2MaxKey - nfl, 3
      if idxR1 == 0 then
        idxR1 = -1
      end
    end
  end
  local p1, p2, p3, p4 = f1[idxL1][idxL2], f2[idxL1][idxL2], f3[idxR1][idxR2], f4[idxR1][idxR2]
  poly = geom.fitSpline(p1, p2, p3, p4, w1Mapped, w2Mapped, hL1Mapped, hL2Mapped, hR1Mapped, hR2Mapped, rot1, rot2, off1, off2)

  local rotSign1, rotSign2 = 1, 1
  if isFlipped1 then
    rotSign1 = -1
  end
  if isFlipped2 then
    rotSign2 = -1
  end

  -- Create the new linking road shell.
  local lR = roadMgr.createRoadFromProfile(customProfile)
  lR.isLinkRoad = true
  lR.isDowelS, lR.isDowelE = true, true
  lR.idxL0a_1, lR.idxL0a_2, lR.idxL0a_l2, lR.idxL0a_l = idxL0a_1, idxL0a_2, idxL0a_l2, idxL0a_l     -- Contribution masks for fitting the spline (relates to each relevant point).
  lR.idxL0b_1, lR.idxL0b_2, lR.idxL0b_l2, lR.idxL0b_l = idxL0b_1, idxL0b_2, idxL0b_l2, idxL0b_l
  lR.idxR0a_1, lR.idxR0a_2, lR.idxR0a_l2, lR.idxR0a_l = idxR0a_1, idxR0a_2, idxR0a_l2, idxR0a_l
  lR.idxR0b_1, lR.idxR0b_2, lR.idxR0b_l2, lR.idxR0b_l = idxR0b_1, idxR0b_2, idxR0b_l2, idxR0b_l
  lR.idxL1, lR.idxL2, lR.idxR1, lR.idxR2 = idxL1, idxL2, idxR1, idxR2                               -- The renderData lane and cross-sectional point indices.
  lR.w1, lR.w2 = w1Mapped, w2Mapped                                                                 -- The linked road width data.
  lR.hL1, lR.hL2, lR.hR1, lR.hR2 = hL1Mapped, hL2Mapped, hR1Mapped, hR2Mapped                       -- The linked road relative height offset data.
  lR.rot1, lR.rot2 = rotSign1, rotSign2                                                             -- The linked road rotational sign data.
  lR.nodes = poly
  lR.startR, lR.startLie = r1Name, r1Lie
  lR.endR, lR.endLie = r2Name, r2Lie
  lR.l1, lR.l2 = l1, l2
  lR.isLinkedToS[1], lR.isLinkedToE[1] = r1Name, r2Name

  -- Add knowledge of the linking to the tributory roads.
  local linkRName = lR.name
  if r1Lie == 'start' then
    r1.isLinkedToS[#r1.isLinkedToS + 1] = linkRName
  else
    r1.isLinkedToE[#r1.isLinkedToE + 1] = linkRName
  end
  if r2Lie == 'start' then
    r2.isLinkedToS[#r2.isLinkedToS + 1] = linkRName
  else
    r2.isLinkedToE[#r2.isLinkedToE + 1] = linkRName
  end

  -- Clear the link structure, ready to be used again.
  link.r1Name, link.r1Lie, link.r2Name, link.r2Lie = nil, nil, nil, nil
  link.l1, link.l2, link.isActive = {}, {}, false

  -- Finally, add the road to the collection of roads.
  roads[#roads + 1] = lR

  -- Re-compute the road map.
  roadMgr.recomputeMap()
end


-- Public interface.
M.link =                                                  link

M.clearLink =                                             clearLink
M.isLaneAdjacent =                                        isLaneAdjacent
M.removeLaneFromLink =                                    removeLaneFromLink
M.isLinkValid =                                           isLinkValid
M.createLink =                                            createLink

return M