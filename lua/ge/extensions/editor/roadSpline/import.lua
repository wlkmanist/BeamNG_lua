-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local startStepSize = 0.1 -- Starting step size for the exponential search.
local numFineCheckIters = 8 -- Number of fine-grained iterations for edge finding with binary search.
local maxSearchDist = 50.0 -- Maximum lateral distance to search for edges. in meters.
local widthTolerance = 0.1 -- Tolerance for the width variation between the decal road and the reference spline, in meters.

local rdpLightTolerance = 0.5 -- Tolerance for the RDP node simplification algorithm.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local groupMgr = require('editor/roadSpline/groupMgr')
local geom = require('editor/toolUtilities/geom')
local rdp = require('editor/toolUtilities/rdp')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min, max, sqrt, huge = math.abs, math.min, math.max, math.sqrt, math.huge
local globalUp = vec3(0, 0, 1)

-- Module state.
local polygons = {}
local cleanedGroups = {}
local normPositions = {}
local tmpSpline = {
  nodes = {}, widths = {}, nmls = {}, -- Primary geometry.
  divPoints = {}, divWidths = {}, tangents = {}, binormals = {}, normals = {}, -- Secondary geometry.
  discMap = {}, -- Mapping from nodes to div points.
  isLoop = false, -- Whether the spline is a loop or not.
}
local tmp1, pVec, negEdgeTmp, posEdgeTmp = vec3(), vec3(), vec3(), vec3()
local toNode, segmentDir, perpDir = vec3(), vec3(), vec3()
local layerTangent, refTangent, binNeg, pTmp = vec3(), vec3(), vec3(), vec3()


-- Backup the selected decal roads, so we can restore them later (on undo operation).
local function backupDecalRoads(decalRoads)
  local backupDecalRoads = {}
  for i = 1, #decalRoads do
    local road = decalRoads[i]
    local group = road:getGroup()
    local startFade, endFade = road.startEndFade.x, road.startEndFade.y
    local nodeData = {}
    for _, node in ipairs(editor.getNodes(road)) do
      table.insert(nodeData, { pos = node.pos, width = node.width })
    end
    backupDecalRoads[i] = {
      id = road:getID(),
      name = road:getName(),
      groupId = group and group:getID() or nil,
      fields = {
        material = road.material,
        textureLength = road.textureLength,
        renderPriority = road.renderPriority,
        startEndFade = string.format("%s %s", startFade, endFade)
      },
      nodes = nodeData,
    }
  end
  return backupDecalRoads
end

-- Undo function for importing Road Splines.
local function importRoadSplineUndo(data)
  groupMgr.transGroupEditUndo(data)

  local deletedRoads = data.deletedDecalRoads
  if deletedRoads then
    for i = 1, #deletedRoads do
      local entry = deletedRoads[i]
      local obj = createObject("DecalRoad")

      -- Restore fields.
      if entry.fields then
        for k, v in pairs(entry.fields) do
          obj:setField(k, 0, v)
        end
      end

      -- Register by name or fallback.
      if entry.name then
        obj:registerObject(entry.name)
      else
        local fallbackName = Sim.getUniqueName("RestoredDecalRoad")
        obj:registerObject(fallbackName)
        entry.name = fallbackName
      end

      -- Add to parent group.
      local parent = entry.groupId and scenetree.findObjectById(entry.groupId)
      if parent then
        parent:addObject(obj)
      else
        scenetree.MissionGroup:addObject(obj)
      end

      -- Restore nodes.
      if entry.nodes then
        for j, node in ipairs(entry.nodes) do
          editor.addRoadNode(obj:getID(), { pos = node.pos, width = node.width or 10, index = j - 1 })
        end
      end
    end
  end

  -- Update the spline map.
  local updatedGroups = groupMgr.getGroups()
  util.computeIdToIdxMap(updatedGroups, groupMgr.getSplineMap())

  editor.refreshSceneTreeWindow()
end

-- Redo function for importing Road Splines.
local function importRoadSplineRedo(data)
  groupMgr.transGroupEditRedo(data)
  local deletedRoads = data.deletedDecalRoads
  if deletedRoads then
    for i = 1, #deletedRoads do
      local road = deletedRoads[i]
      local name = road.name
      local obj = name and scenetree.findObject(name)
      if obj and Sim.upcast(obj) then
        obj:delete()
      end
    end
  end

  -- Update the spline map.
  local updatedGroups = groupMgr.getGroups()
  util.computeIdToIdxMap(updatedGroups, groupMgr.getSplineMap())

  editor.refreshSceneTreeWindow()
end

-- Checks if a point is inside any of the cached polygons.
local function pointInAnyPolygon(pt, numDecalRoads)
  for j = 1, numDecalRoads do
    if pt:inPolygon(polygons[j]) then
      return true
    end
  end
  return false
end

-- Finds the distance along a given direction until the point exits all polygons,
-- using exponential expansion followed by binary refinement.
local function findEdgeDistance(origin, dir, numDecalRoads)
  -- Exponential search outward (coarse check).
  local low, high, step = 0.0, 0.0, startStepSize
  while high < maxSearchDist do
    pVec:setScaled2(dir, high)
    pTmp:setAdd2(origin, pVec)
    if not pointInAnyPolygon(pTmp, numDecalRoads) then break end
    low = high
    high = high + step
    step = step * 2.0
  end

  -- Binary refine between low and high (fine check).
  for _ = 1, numFineCheckIters do
    local mid = 0.5 * (low + high)
    pVec:setScaled2(dir, mid)
    pTmp:setAdd2(origin, pVec)
    if pointInAnyPolygon(pTmp, numDecalRoads) then
      low = mid
    else
      high = mid
    end
  end

  return low
end

-- Creates layers from the selected decal roads, computing their properties relative to the reference spline.
local function createLayersFromDecalRoads(decalRoads, refNodes, refWidths)
  local layers, numRefNodes = {}, #refNodes
  for _, road in ipairs(decalRoads) do -- Iterate over each decal road in the selection.
    local rawNodes = editor.getNodes(road)
    table.clear(normPositions)
    for j = 1, #rawNodes do
      -- Find closest point on reference polyline to this decal road node.
      local nodePos, minDist, closestNodeIdx = rawNodes[j].pos, huge, 1
      for i = 1, numRefNodes - 1 do
        local dist = nodePos:squaredDistanceToLineSegment(refNodes[i], refNodes[i + 1])
        if dist < minDist then
          minDist, closestNodeIdx = dist, i
        end
      end
      minDist = sqrt(minDist) -- Closest distance between the node and the reference centerline.

      -- Determine sign (which side of reference spline it is on), using dot product with perpendicular direction.
      local closestNode = refNodes[closestNodeIdx]
      toNode:setSub2(nodePos, closestNode)
      segmentDir:setSub2(refNodes[min(closestNodeIdx + 1, numRefNodes)], refNodes[max(1, closestNodeIdx - 1)])
      segmentDir:normalize()
      perpDir:set(-segmentDir.y, segmentDir.x, 0.0)
      local sign = toNode:dot(perpDir) >= 0.0 and -1 or 1

      -- Compute normalised position (lateral offset) using the closest reference node's width.
      normPositions[j] = (sign * minDist * 2.0) / refWidths[closestNodeIdx]
    end

    -- Compute the mean lateral offset value across the decal road.
    local totalPos = 0.0
    for i = 1, #normPositions do
      totalPos = totalPos + normPositions[i]
    end
    local lateralOffset = totalPos / #normPositions

    -- Determine the isTrackWidth flag, by comparing width variation between this decal road and the reference spline.
    local isTrackWidth = true
    for _, node in ipairs(rawNodes) do
      local nodePos, minDist, closestNodeIdx = node.pos, huge, 1
      for i = 1, numRefNodes do -- Find closest reference node for this decal road node.
        local dist = nodePos:distance(refNodes[i])
        if dist < minDist then
          minDist, closestNodeIdx = dist, i
        end
      end
      if abs(node.width - refWidths[closestNodeIdx]) > widthTolerance then
        isTrackWidth = false
        break
      end
    end

    -- Determine isFlip flag by comparing layer and reference spline tangents at every node, then doing a majority vote.
    local flipVotes, totalVotes, numRawNodes = 0, 0, #rawNodes
    for j = 1, numRawNodes do
      local node = rawNodes[j]
      local nodePos, minDist, closestNodeIdx = node.pos, huge, 1
      for i = 1, numRefNodes do -- Find closest reference node for this decal road node.
        local dist = nodePos:distance(refNodes[i])
        if dist < minDist then
          minDist, closestNodeIdx = dist, i
        end
      end
      layerTangent:setSub2(rawNodes[min(numRawNodes, j + 1)].pos, rawNodes[max(1, j - 1)].pos)
      layerTangent:normalize() -- Layer tangent at this node.
      refTangent:setSub2(refNodes[min(closestNodeIdx + 1, numRefNodes)], refNodes[max(closestNodeIdx - 1, 1)])
      refTangent:normalize() -- Reference spline tangent at the closest point.
      if layerTangent:dot(refTangent) < 0 then -- Vote on flip (negative dot product means opposite directions).
        flipVotes = flipVotes + 1
      end
      totalVotes = totalVotes + 1
    end
    local isFlip = flipVotes > totalVotes / 2

    -- Create the layer.
    table.insert(layers, {
      name = 'Imported ' .. tostring(#layers + 1) .. ' ' .. road:getID(),
      id = Engine.generateUUID(),
      isDirty = true,
      isHidden = false,
      decalRoad = nil,
      isEnabled = true,
      isFlip = isFlip,
      material = road.material,
      renderPriority = tonumber(road.renderPriority),
      isTrackWidth = isTrackWidth,
      width = rawNodes[1].width, -- Get the fixed width from the first node.
      position = lateralOffset,
      texLen = tonumber(road.textureLength),
      fadeIn = road.startEndFade.x,
      fadeOut = road.startEndFade.y,
    })
  end

  return layers
end

-- Computes the reference spline for the selection.
-- [This is the estimated centerline of the selection, from which all the other layers will be relative to.]
local function computeReferenceSpline(decalRoads)
  -- Clear the temporary polygon cache.
  for i = 1, #polygons do
    table.clear(polygons[i])
  end

  -- Compute a polygon for each decal road in the given selection.
  local numDecalRoads, longestRoadIdx, longestRoadLength = #decalRoads, 1, 0.0
  for i = 1, numDecalRoads do
    -- Re-format the decal road geometry into a format suitable for our utility functions.
    local rawNodes = editor.getNodes(decalRoads[i])
    table.clear(tmpSpline.nodes); table.clear(tmpSpline.widths); table.clear(tmpSpline.nmls)
    table.clear(tmpSpline.divPoints); table.clear(tmpSpline.divWidths); table.clear(tmpSpline.normals); table.clear(tmpSpline.discMap)
    tmpSpline.isLoop = false -- TODO: Support loops later.
    for j = 1, #rawNodes do
      tmpSpline.nodes[j], tmpSpline.widths[j], tmpSpline.nmls[j] = rawNodes[j].pos, rawNodes[j].width, globalUp
    end

    -- Determine which decal road in the selection is the longest.
    local roadLength = util.getPolyLength(tmpSpline.nodes)
    if roadLength > longestRoadLength then
      longestRoadLength, longestRoadIdx = roadLength, i
    end

    -- Compute the polygon for this decal road, using a smooth polyline.
    geom.catmullRomFree(tmpSpline)
    polygons[i] = polygons[i] or {}
    geom.computeSplinePolygon(tmpSpline, 0.01, polygons[i])
  end

  -- Interpolate the longest road, using Catmull-Rom.
  local rawNodes = editor.getNodes(decalRoads[longestRoadIdx])
  table.clear(tmpSpline.nodes); table.clear(tmpSpline.widths); table.clear(tmpSpline.nmls)
  table.clear(tmpSpline.divPoints); table.clear(tmpSpline.divWidths); table.clear(tmpSpline.normals); table.clear(tmpSpline.discMap)
  for j = 1, #rawNodes do
    tmpSpline.nodes[j], tmpSpline.widths[j], tmpSpline.nmls[j] = rawNodes[j].pos, rawNodes[j].width, globalUp
  end
  geom.catmullRomFree(tmpSpline)

  -- Compute the reference spline, using a two-pass binary search to find the left and right edges at each node of the longest road.
  local refNodes, refWidths, refNmls = {}, {}, {}
  local nodes, binormals, discMap = tmpSpline.nodes, tmpSpline.binormals, tmpSpline.discMap
  for i = 1, #nodes do
    local divIdx = discMap[i]
    local p = nodes[i]
    local binPos = binormals[divIdx]
    binNeg:set(-binPos.x, -binPos.y, -binPos.z)

    -- Find the negative edge at this node.
    local negDist = findEdgeDistance(p, binNeg, numDecalRoads)
    pVec:setScaled2(binNeg, negDist)
    negEdgeTmp:setAdd2(p, pVec)

    -- Find the positive edge at this node.
    local posDist = findEdgeDistance(p, binPos, numDecalRoads)
    pVec:setScaled2(binPos, posDist)
    posEdgeTmp:setAdd2(p, pVec)

    -- Set this node in the reference spline.
    tmp1:set(negEdgeTmp.x + posEdgeTmp.x, negEdgeTmp.y + posEdgeTmp.y, negEdgeTmp.z + posEdgeTmp.z)
    tmp1:setScaled2(tmp1, 0.5)
    refNodes[i] = vec3(tmp1) -- Use midpoint of the two edges as the reference node.
    refWidths[i] = negEdgeTmp:distance(posEdgeTmp) -- Use the distance between the two edges as the width.
    refNmls[i] = vec3(globalUp) -- Use the global up vector as the normal.
  end

  return refNodes, refWidths, refNmls
end

-- Import a Road Spline from the currently selected decal roads.
local function importSelectedIntoNewGroup(decalRoads)
  if #decalRoads == 0 then
    return -- Early return if no decal roads are selected.
  end

  -- Backup the selected decal roads, so we can restore them later (on undo operation).
  local backupDecalRoads = backupDecalRoads(decalRoads)
  local preState = groupMgr.deepCopyAllGroups()

  -- Compute the reference spline for the selection.
  -- [This is the estimated centerline of the selection, from which all the other layers will be relative to]
  local nodes, widths, nmls = computeReferenceSpline(decalRoads)

  -- Create the new road spline.
  local groups = groupMgr.getGroups()
  groupMgr.addNewGroup('Import ' .. tostring(#groups))
  local group = groups[#groups]
  group.isDirty = true

  -- Update the spline map to ensure undo operations can find the imported spline.
  local updatedGroups = groupMgr.getGroups()
  util.computeIdToIdxMap(updatedGroups, groupMgr.getSplineMap())

  -- Set the primary geometry directly from the reference spline.
  rdp.simplifyNodesWidthsNormals(nodes, widths, nmls, rdpLightTolerance)
  group.nodes, group.widths, group.nmls = nodes, widths, nmls

  -- Ensure the road spline has all the auto-generated layers switched off.
  group.isLightTreadMarks, group.isHeavyTreadMarks = false, false
  group.isDamageAsphalt1, group.isDamageAsphalt2, group.isRoadCrack = false, false, false
  group.isRepair1, group.isRepair2, group.isPatches = false, false, false
  group.isRoadCenterLine, group.isRoadEdgeLines, group.isRoadLaneLines = false, false, false
  group.isEdgeBlend1, group.isEdgeBlend2 = false, false

  -- Create the layers from selected decal roads, by interpreting them as being relative to the reference spline.
  group.layers = createLayersFromDecalRoads(decalRoads, nodes, widths)

  -- Delete used decal roads, and clean up parent groups if now empty.
  table.clear(cleanedGroups)
  for i = 1, #decalRoads do
    local road = decalRoads[i]
    if road and Sim.upcast(road) then
      local group = road:getGroup()
      road:delete()
      if group and Sim.upcast(group) and not cleanedGroups[group:getID()] then
        local onlyDecalRoads = true
        for j = 0, group:size() - 1 do
          local sibling = group:at(j)
          if sibling and Sim.upcast(sibling) and sibling:getClassName() ~= "DecalRoad" then
            onlyDecalRoads = false
            break
          end
        end
        if onlyDecalRoads and group:size() == 0 then
          group:delete()
        end
        cleanedGroups[group:getID()] = true
      end
    end
  end

  -- Commit the undo/redo history.
  editor.history:commitAction(
    "Import DecalRoads into Road Spline",
    { old = preState, new = groupMgr.deepCopyAllGroups(), deletedDecalRoads = backupDecalRoads },
    importRoadSplineUndo,
    importRoadSplineRedo,
    true
  )

  editor.refreshSceneTreeWindow()
end

-- Import a Road Spline from the given selection polygon.
local function importFromPolygon(polygon)
  local decalRoadsInPolygon, ctr = {}, 1
  for _, name in pairs(scenetree.findClassObjects("DecalRoad")) do
    local obj = scenetree.findObject(name)
    if obj then
      local nodes = editor.getNodes(obj)
      if nodes and #nodes > 0 then
        for i = 1, #nodes do
          local pos = nodes[i].pos
          if pos:inPolygon(polygon) then
            decalRoadsInPolygon[ctr] = obj
            ctr = ctr + 1
            break -- Only one node needs to be in the polygon to import the whole road.
          end
        end
      end
    end
  end
  importSelectedIntoNewGroup(decalRoadsInPolygon)
end


-- Public interface.
M.importSelectedIntoNewGroup =                          importSelectedIntoNewGroup
M.importFromPolygon =                                   importFromPolygon

return M