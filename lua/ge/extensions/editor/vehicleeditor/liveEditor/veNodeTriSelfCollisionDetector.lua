-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = extensions.ui_imgui
local wndName = "Node Triangle Self Collision Detector"
M.menuEntry = "Node Triangle Self Collision Detector"

local jbeamTableSchema = require('jbeam/tableSchema')

local sqrt = math.sqrt

local windowOpen = im.BoolPtr(false)

local orangeColor = ColorF(1,0.5,0,1)
local blackColor = ColorF(0,0,0,1)

local greenColor255 = color(0,255,0,255)

local nodeCollisionRadiusPtr = im.FloatPtr(0.025)

local vehsResultData = {}

local tempNodePositions = {}
local tempNodePositionsUpdated = {}
local tempTriPos = vec3()

local function getTempNodePosition(nodeId)
  if not tempNodePositions[nodeId] then
    tempNodePositions[nodeId] = vec3()
  end
  if not tempNodePositionsUpdated[nodeId] then
    tempNodePositions[nodeId]:set(vEditor.vehicle:getNodeAbsPositionXYZ(nodeId))
    tempNodePositionsUpdated[nodeId] = true
  end
  return tempNodePositions[nodeId]
end

local function onVehicleEditorRenderJBeams(dtReal, dtSim, dtRaw)
  if not (windowOpen[0] and vEditor.vehicle and vEditor.vdata) then return end

  local resultData = vehsResultData[vEditor.vehicle:getID()]

  if resultData then
    local vdata = vEditor.vdata
    local nodes = vdata.nodes
    local triangles = vdata.triangles

    for nodeId, tris in pairs(resultData.nodeTriPairs) do
      local node = nodes[nodeId]
      local nodePos = getTempNodePosition(nodeId)
      debugDrawer:drawSphere(nodePos, resultData.nodeCollisionRadius, orangeColor)
      local nodeText = node.name and string.format("Node: %d (%s)", nodeId, node.name) or tostring(nodeId)
      debugDrawer:drawText(nodePos, nodeText, blackColor)

      for triId, nodeTriData in pairs(tris) do
        local tri = triangles[triId]
        local triPos1, triPos2, triPos3 = getTempNodePosition(tri.id1), getTempNodePosition(tri.id2), getTempNodePosition(tri.id3)
        tempTriPos:set(triPos1)
        tempTriPos:setAdd(triPos2)
        tempTriPos:setAdd(triPos3)
        tempTriPos:setScaled(1/3)
        debugDrawer:drawTriSolid(triPos1, triPos2, triPos3, greenColor255)

        local triNode1, triNode2, triNode3 = nodes[tri.id1], nodes[tri.id2], nodes[tri.id3]
        local triNode1Text = triNode1.name and string.format("%d (%s)", tri.id1, triNode1.name) or tostring(tri.id1)
        local triNode2Text = triNode2.name and string.format("%d (%s)", tri.id2, triNode2.name) or tostring(tri.id2)
        local triNode3Text = triNode3.name and string.format("%d (%s)", tri.id3, triNode3.name) or tostring(tri.id3)
        local triText = string.format("Triangle: %s - %s - %s", triNode1Text, triNode2Text, triNode3Text)
        debugDrawer:drawText(tempTriPos, triText, blackColor)
      end
    end

    table.clear(tempNodePositionsUpdated)
  else
    if next(tempNodePositions) then
      table.clear(tempNodePositions)
    end
  end
end

local function analyze()
  local veh = vEditor.vehicle
  local vdata = vEditor.vdata

  local nodeCollisionRadius = nodeCollisionRadiusPtr[0]

  local resultData = {
    nodeCollisionRadius = nodeCollisionRadius,
    nodeTriPairs = {}
  }

  local nodeCollisionRadiusSqr = nodeCollisionRadius * nodeCollisionRadius

  local couplerNodes = {}

  for k,v in pairs(vdata) do
    if type(v) == 'table' then
      if v.couplerNodes then
        local couplerNodesCopy = deepcopy(v.couplerNodes)
        local newCouplerNodePairs = {}
        jbeamTableSchema.processTableWithSchemaDestructive(couplerNodesCopy, newCouplerNodePairs)
        for _, couplerNodePair in ipairs(newCouplerNodePairs) do
          couplerNodes[couplerNodePair.cid1] = true
          couplerNodes[couplerNodePair.cid2] = true
        end
      end
    end
  end

  for triId = 0, tableSizeC(vdata.triangles) - 1 do
    local tri = vdata.triangles[triId]
    local triNode1Id, triNode2Id, triNode3Id = tri.id1, tri.id2, tri.id3

    -- skip if the triangle is NONCOLLIDABLE (2 or "NONCOLLIDABLE")
    if tri.triangleType == 2 or tri.triangleType == "NONCOLLIDABLE" then
      goto skipTri
    end

    local triNode1, triNode2, triNode3 = vdata.nodes[triNode1Id], vdata.nodes[triNode2Id], vdata.nodes[triNode3Id]
    local triPos1, triPos2, triPos3 = veh:getNodeAbsPosition(triNode1Id), veh:getNodeAbsPosition(triNode2Id), veh:getNodeAbsPosition(triNode3Id)

    for nodeId = 0, tableSizeC(vdata.nodes) - 1 do
      local node = vdata.nodes[nodeId]

      -- skip if the node is part of the triangle
      if triNode1Id == nodeId or triNode2Id == nodeId or triNode3Id == nodeId then
        goto skipNode
      end

      -- skip if the node has collision disabled or self collision disabled
      if node.collision == false or not node.selfCollision then
        goto skipNode
      end

      -- skip if the node is a coupler node
      if couplerNodes[nodeId] or node.couplerTag or node.tag then
        goto skipNode
      end

      local firstNodeGroup = node.firstGroup

      -- skip if the node's 1st group is part of any of the triangle's nodes' 1st group
      if triNode1.firstGroup == firstNodeGroup or triNode2.firstGroup == firstNodeGroup or triNode3.firstGroup == firstNodeGroup then
        goto skipNode
      end

      local nodePos = veh:getNodeAbsPosition(nodeId)
      local closestPoint = nodePos:triangleClosestPoint(triPos1, triPos2, triPos3)
      local distSqr = nodePos:squaredDistance(closestPoint)

      if distSqr <= nodeCollisionRadiusSqr then
        local dist = sqrt(distSqr)
        resultData.nodeTriPairs[nodeId] = resultData.nodeTriPairs[nodeId] or {}
        resultData.nodeTriPairs[nodeId][triId] = {
          dist = dist,
        }

        local nodeText = node.name and string.format("%d (%s)", nodeId, node.name) or tostring(nodeId)
        local triNode1Text = triNode1.name and string.format("%d (%s)", tri.id1, triNode1.name) or tostring(tri.id1)
        local triNode2Text = triNode2.name and string.format("%d (%s)", tri.id2, triNode2.name) or tostring(tri.id2)
        local triNode3Text = triNode3.name and string.format("%d (%s)", tri.id3, triNode3.name) or tostring(tri.id3)
        local triText = string.format("%s - %s - %s", triNode1Text, triNode2Text, triNode3Text)
        print(string.format("Node %s is colliding with triangle %s at distance %.3f m", nodeText, triText, dist))
      end

      ::skipNode::
    end

    ::skipTri::
  end

  vehsResultData[veh:getID()] = resultData
end

local function onUpdate()
  if windowOpen[0] ~= true then return end

  if not vEditor or not vEditor.vehicle then return end
  if im.Begin(wndName, windowOpen) then
    im.SliderFloat('Node Collision Radius', nodeCollisionRadiusPtr, 0.025, 0.1, '%.3f m')
    im.Text("(0.025 m is actual collision radius)")

    im.Spacing()

    if im.Button("Start Analysis") then
      analyze()
    end

    im.SameLine()

    if im.Button("Clear Results") then
      table.clear(vehsResultData)
    end
    im.Text("Results get printed to the console.")
  end
  im.End()
end

local function open()
  windowOpen[0] = true
end

local function onSerialize()
  return {
    windowOpen = windowOpen[0],
    nodeCollisionRadius = nodeCollisionRadiusPtr[0],
    vehsResultData = vehsResultData,
  }
end

local function onDeserialized(data)
  windowOpen[0] = data.windowOpen
  nodeCollisionRadiusPtr[0] = data.nodeCollisionRadius
  vehsResultData = data.vehsResultData
end

M.open = open

M.onVehicleEditorRenderJBeams = onVehicleEditorRenderJBeams
M.onUpdate = onUpdate

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M