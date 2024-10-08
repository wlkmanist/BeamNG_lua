-- This Source Code Form is subject to the terms of the bCDDL, var. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'editor_veMain'}

local max = math.max
local min = math.min
local abs = math.abs
local huge = math.huge

local im = ui_imgui

local settingsPath = "/settings/editor/flexbodyDebug_settings.json"

local wndName = "Flexbody Debug"
local wndOpen = false
local mainWndFlags = bit.bor(im.WindowFlags_NoBringToFrontOnFocus)
M.menuEntry = "Flexbody Debug"

local verticesOOBCoordsWindowName = "Vertices Out of Bounds Coords"
local showVerticesOBBCoordsWindow = im.BoolPtr(false)

local verticesLackingNodesWindowName = "Vertices Lacking Nearby Nodes"
local showVerticesLackingNodesWindow = im.BoolPtr(false)

local MODE_DEFAULT = 1
local MODE_PICKING_NODE = 2
local MODE_PICKED_NODE = 3
local MODE_PICKING_VERTEX = 4
local MODE_PICKED_VERTEX = 5
local MODE_SHOW_VERTICES_LACKING_NODES = 6

local inputSuggestWndName = "inputSuggestionPopup"
local inputSuggestWndFlags = bit.bor(
    im.WindowFlags_NoTitleBar,
    im.WindowFlags_NoResize,
    im.WindowFlags_NoMove,
    im.WindowFlags_HorizontalScrollbar,
    im.WindowFlags_NoFocusOnAppearing
)

local maxDistFromCursor = im.FloatPtr(2.0)

local flexbodyInputTextInput = im.ArrayChar(128)
local flexbodyInputTextPopupPos = im.ImVec2(0,0)
local flexbodyInputTextPopupSize = im.ImVec2(0,0)
local flexbodyInputTextPopupOpen = false

local nodeInputTextInput = im.ArrayChar(16)
local nodeInputTextPopupPos = im.ImVec2(0,0)
local nodeInputTextPopupSize = im.ImVec2(0,0)
local nodeInputTextPopupOpen = false

local vertexInputTextInput = im.ArrayChar(16)
local vertexInputTextPopupPos = im.ImVec2(0,0)
local vertexInputTextPopupSize = im.ImVec2(0,0)
local vertexInputTextPopupOpen = false

local vertRenderRadius = 0.01
local vertSelectedRadius = vertRenderRadius * 1.5

local nodeRenderRadius = 0.025
local nodeSelectedRadius = nodeRenderRadius * 1.5

local axesColors = {ColorF(1,0,0,1), ColorF(0,1,0,1), ColorF(0,0,1,1)}

local nodeUsedColor = ColorF(1,0.5,0,1)
local nodeUnusedColor = ColorF(1,0.5,0,0.1)
local nodeSelectedColor = ColorF(1,0,0,1)

local textColor = ColorF(1,1,1,1)
local textBackgroundColor = ColorI(0,0,0,192)

local zeroVec = vec3(0,0,0)

-- Template
local initStateTemplate = {
  mode = MODE_DEFAULT,
  sortedFlexbodiesData = {},
  selectedFlexbody = 0,
  meshVis = im.FloatPtr(1.0),
  hitNodes = {},
  pickedNodesID = {},
  hitVertices = {},
  pickedVerticesID = {},
  spikingData = nil,
}

local initStates = {}
local states = {}
local initVehDatas = {}

local initState = nil
local state = nil
local initVehData = nil

local settings = {}

local currNodesUsed = 0

local prevMaxNodeVertDist = 1
local maxNodeVertDist = 1

local prevMinBounds = vec3(huge,huge,huge)
local prevMaxBounds = vec3(-huge,-huge,-huge)
local minBounds = vec3(huge,huge,huge)
local maxBounds = vec3(-huge,-huge,-huge)

local cacheVertexPositions = {}
local cacheLocInfo = {}

local function saveVehicleSettings()
  settings[vEditor.vehicle:getJBeamFilename()] = deepcopy(state.settings)
  jsonWriteFile(settingsPath, settings)
end

local function getClosestObjectToCamera(cameraPos, hitObjects)
  if next(hitObjects) == nil then return nil end

  local chosenObjData = hitObjects[1]
  if #hitObjects > 1 then
    -- If multiple hit objects, use closest one to camera

    local minDist = (chosenObjData.pos - cameraPos):length()

    for k, objData in ipairs(hitObjects) do
      if k >= 2 then
        local dist = (objData.pos - cameraPos):length()

        if dist < minDist then
          minDist = dist
          chosenObjData = objData
        end
      end
    end
  end

  return chosenObjData
end

local function showPickedFlexbody(alpha)
  if state.selectedFlexbody then
    if alpha then state.meshVis[0] = alpha end

    vEditor.vehicle:setMeshAlpha(0, "", false)
    vEditor.vehicle:setMeshAlpha(state.meshVis[0], state.sortedFlexbodiesData[state.selectedFlexbody].mesh, false)
  end
end

local function selectFlexbody(id, alpha)
  state.selectedFlexbody = id
  table.clear(cacheVertexPositions)
  table.clear(cacheLocInfo)
  table.clear(state.pickedNodesID)
  table.clear(state.pickedVerticesID)
  state.mode = MODE_DEFAULT

  local flexbody = state.sortedFlexbodiesData[id]

  if flexbody then
    vEditor.vehicle:setFlexmeshDebugMode(true)
    showPickedFlexbody(alpha)
  else
    vEditor.vehicle:setFlexmeshDebugMode(false)
  end
end

local function selectNode(id)
  table.clear(state.pickedNodesID)
  table.clear(state.pickedVerticesID)
  state.pickedNodesID[1] = id
  state.mode = MODE_PICKED_NODE
end

local function selectVertex(id)
  table.clear(state.pickedNodesID)
  table.clear(state.pickedVerticesID)
  state.pickedVerticesID[1] = id
  state.mode = MODE_PICKED_VERTEX
end

local function selectVerticesForLackingNodesMode(ids)
  table.clear(state.pickedNodesID)
  table.clear(state.pickedVerticesID)

  for k, id in ipairs(ids) do
    state.pickedVerticesID[k] = id
  end

  state.mode = MODE_SHOW_VERTICES_LACKING_NODES
end

local function pickNode(flexbody, flexbodyObj)
  -- Only pick vertices when not hovering imgui window
  local imguiHovered = im.IsAnyItemHovered() or im.IsWindowHovered(im.HoveredFlags_AnyWindow)
  if imguiHovered then return end

  table.clear(state.hitNodes)

  local ray = getCameraMouseRay()

  local rayStartPos = ray.pos
  local rayDir = ray.dir

  local leftClicked = im.IsMouseClicked(0)

  -- Get list of nodes hovered over by mouse cursor
  for _, nodeID in ipairs(flexbody._group_nodes) do
    local node = vEditor.vdata.nodes[nodeID]
    local nodePos = vEditor.vehicle:getNodeAbsPosition(nodeID)
    local dist, _ = intersectsRay_Sphere(rayStartPos, rayDir, nodePos, nodeRenderRadius)

    if dist and dist < 100 then -- if mouse over node
      table.insert(state.hitNodes, {node = node, pos = nodePos})
    end
  end

  -- Find closest node to camera
  local chosenNodeData = getClosestObjectToCamera(rayStartPos, state.hitNodes)
  if not chosenNodeData then return end

  -- After choosing closest node, if user left clicked then pick it, otherwise highlight it
  local chosenNodeID = chosenNodeData.node.cid
  local chosenNodeName = chosenNodeData.node.name
  local chosenNodePos = chosenNodeData.pos

  if leftClicked then -- on left click
    -- Picked node!
    selectNode(chosenNodeID)
  else -- on hover
    -- Highlight node
    debugDrawer:drawSphere(chosenNodePos, nodeSelectedRadius, nodeSelectedColor)
    debugDrawer:drawTextAdvanced(chosenNodePos, chosenNodeName or chosenNodeID, textColor, true, false, textBackgroundColor)
  end
end

local function pickVertex(flexbody, flexbodyObj)
  -- Only pick vertices when not hovering imgui window
  local imguiHovered = im.IsAnyItemHovered() or im.IsWindowHovered(im.HoveredFlags_AnyWindow)
  if imguiHovered then return end

  table.clear(state.hitVertices)

  local ray = getCameraMouseRay()

  local rayStartPos = ray.pos
  local rayDir = ray.dir

  local leftClicked = im.IsMouseClicked(0)

  local vehPos = vEditor.vehicle:getPosition()
  local vertCount = flexbodyObj:getVertexCount()

  -- Get list of vertices hovered over by mouse cursor
  for i = 0, vertCount - 1 do
    local vertPos = flexbodyObj:getDebugVertexPos(i) + vehPos
    local dist, _ = intersectsRay_Sphere(rayStartPos, rayDir, vertPos, nodeRenderRadius)

    if dist and dist < 100 then -- if mouse over node
      table.insert(state.hitVertices, {vertID = i, pos = vertPos})
    end
  end

  -- Find closest vertex to camera
  local chosenVertData = getClosestObjectToCamera(rayStartPos, state.hitVertices)
  if not chosenVertData then return end

  -- After choosing closest vertex, if user left clicked then pick it, otherwise highlight it
  local chosenVertID = chosenVertData.vertID
  local chosenVertPos = chosenVertData.pos

  if leftClicked then -- on left click
    -- Picked vertex!
    selectVertex(chosenVertID)
  else -- on hover
    -- Highlight vertex
    debugDrawer:drawSphere(chosenVertPos, vertSelectedRadius, nodeSelectedColor)
    debugDrawer:drawTextAdvanced(chosenVertPos, chosenVertID, textColor, true, false, textBackgroundColor)
  end
end

local function verticesLackingNodesModeShowVertexInfoOnHover(flexbody, flexbodyObj)
  -- Only pick vertices when not hovering imgui window
  local imguiHovered = im.IsAnyItemHovered() or im.IsWindowHovered(im.HoveredFlags_AnyWindow)
  if imguiHovered then return end

  table.clear(state.hitVertices)

  local ray = getCameraMouseRay()

  local rayStartPos = ray.pos
  local rayDir = ray.dir

  local vehPos = vEditor.vehicle:getPosition()

  -- Get list of vertices hovered over by mouse cursor
  for _, i in ipairs(state.pickedVerticesID) do
    local vertPos = flexbodyObj:getDebugVertexPos(i) + vehPos
    local dist, _ = intersectsRay_Sphere(rayStartPos, rayDir, vertPos, nodeRenderRadius)

    if dist and dist < 100 then -- if mouse over node
      table.insert(state.hitVertices, {vertID = i, pos = vertPos})
    end
  end

  -- Find closest vertex to camera
  local chosenVertData = getClosestObjectToCamera(rayStartPos, state.hitVertices)
  if not chosenVertData then return end

  -- After choosing closest vertex, if user left clicked then pick it, otherwise highlight it
  local chosenVertID = chosenVertData.vertID
  local chosenVertPos = chosenVertData.pos

  local refPos = vEditor.vdata.nodes[vEditor.vdata.refNodes[0].ref].pos
  local rotInv = quatFromDir(-vEditor.vehicle:getDirectionVector(), vEditor.vehicle:getDirectionVectorUp()):inversed()
  local vertPosLocal = rotInv * flexbodyObj:getDebugVertexPos(chosenVertID) + refPos

  -- Highlight vertex
  debugDrawer:drawSphere(chosenVertPos, vertSelectedRadius, nodeSelectedColor)
  --debugDrawer:drawTextAdvanced(chosenVertPos, chosenVertID, textColor, true, false, textBackgroundColor)
  debugDrawer:drawTextAdvanced(chosenVertPos, string.format("pos: (%.2f, %.2f, %.2f)", vertPosLocal.x, vertPosLocal.y, vertPosLocal.z), textColor, true, false, textBackgroundColor)
end

local function updateVerticesBBox(vertPos)
  minBounds.x = min(minBounds.x, vertPos.x)
  minBounds.y = min(minBounds.y, vertPos.y)
  minBounds.z = min(minBounds.z, vertPos.z)
  maxBounds.x = max(maxBounds.x, vertPos.x)
  maxBounds.y = max(maxBounds.y, vertPos.y)
  maxBounds.z = max(maxBounds.z, vertPos.z)
end

local nodesUsed = {}
local vertCol = ColorF(1, 1, 1, 1)
local lineCol = ColorF(1, 1, 1, 1)

local vehPos = vec3()
local rotInv = quat()
local localVertPos = vec3()
local vertPosLocal = vec3()
local vertPos = vec3()
local tempVec = vec3()
local tempVec2 = vec3()
local nodePos = vec3()

local flexNodePositions = {}

--local renderTotal = 1
--local renderCount = 0

--local p = LuaProfiler("profiler")
local function renderPickedFlexbody(flexbody, flexbodyObj)
  if p then p:start() end
  table.clear(nodesUsed)

  vehPos:set(vEditor.vehicle:getPositionXYZ())
  local refNodeRot = vEditor.vehicle:getRefNodeRotation()
  rotInv:set(refNodeRot.x, refNodeRot.y, refNodeRot.z, refNodeRot.w)
  rotInv:inverse()
  local vertCount = flexbodyObj:getVertexCount()
  --local verticesPickedCount = #state.pickedVerticesID

  table.clear(flexNodePositions)
  for _, nodeID in ipairs(flexbody._group_nodes) do
    flexNodePositions[nodeID] = vEditor.vehicle:getNodeAbsPosition(nodeID)
  end

  local ray = getCameraMouseRay()

  local rayStartPos = ray.pos
  local rayDir = ray.dir
  local rayEndPos = rayStartPos + rayDir * 25

  local maxDist = maxDistFromCursor[0]

  if p then p:add("init") end

  -- Render mesh's vertices
  for i = 0, vertCount - 1 do
    if not cacheLocInfo[i] then
      cacheLocInfo[i] = flexbodyObj:getVertexLocatorInfo(i)
    end
    localVertPos:set(flexbodyObj:getDebugVertexPos(i))

    if p then p:add("Render mesh getDebugVertexPos") end

    local vertLoc = cacheLocInfo[i]
    local vertLocNodes = vertLoc.nodes

    for _, nodeID in pairs(vertLocNodes) do
      if nodeID ~= -1 then
        nodesUsed[nodeID] = true
      end
    end

    vertPos:setAdd2(localVertPos, vehPos)

    local dist = vertPos:squaredDistanceToLineSegment(rayStartPos, rayEndPos)
    if dist > maxDist * maxDist then
      goto continue
    end

    --vertPosLocal:setRotate(rotInv, localVertPos)
    tempVec:setCross(rotInv, localVertPos)
    tempVec:setScaled(2)
    tempVec2:setScaled2(tempVec, -rotInv.w)
    vertPosLocal:setAdd2(localVertPos, tempVec2)
    tempVec2:setCross(rotInv, tempVec)
    vertPosLocal:setAdd(tempVec2)

    if p then p:add("Render mesh init calculations") end

    local renderVertex = true
    local renderLines = true

    if state.mode == MODE_PICKED_NODE then
      renderVertex = false

      for _, nodeID in ipairs(vertLocNodes) do
        if nodeID == state.pickedNodesID[1] then
          renderVertex = true
          break
        end
      end

    elseif state.mode == MODE_PICKED_VERTEX then
      renderVertex = state.pickedVerticesID[1] == i
      renderLines = false

    elseif state.mode == MODE_SHOW_VERTICES_LACKING_NODES then
      renderVertex = false
      renderLines = false

      for _, vertexID in ipairs(state.pickedVerticesID) do
        if vertexID == i then
          renderVertex = true
          break
        end
      end
    end

    if p then p:add("Render mesh logic") end

    -- Update vertex bounding box for mapping vertex position to rgb color
    updateVerticesBBox(vertPosLocal)
    if p then p:add("Render mesh updateVerticesBBox") end

    if renderVertex then
      -- Vertex color based on vertex position
      vertCol.r = (vertPosLocal.x - prevMinBounds.x) / (prevMaxBounds.x - prevMinBounds.x)
      vertCol.g = (vertPosLocal.y - prevMinBounds.y) / (prevMaxBounds.y - prevMinBounds.y)
      vertCol.b = (vertPosLocal.z - prevMinBounds.z) / (prevMaxBounds.z - prevMinBounds.z)

      if state.mode == MODE_PICKED_VERTEX then
        local locCoords = vertLoc.coords
        local coords = string.format("(%.2f, %.2f, %.2f)", locCoords.x, locCoords.y, locCoords.z)

        debugDrawer:drawTextAdvanced(vertPos, tostring(i) .. " " .. coords, textColor, true, false, textBackgroundColor)
      end

      debugDrawer:drawSphere(vertPos, vertRenderRadius, vertCol)

      if p then p:add("Render mesh render vertex") end
    end

    -- Go through each vertex's locator nodes to render lines
    for _, nodeID in pairs(vertLocNodes) do
      if nodeID ~= -1 then
        if renderVertex and renderLines then
          local renderNode = true
          if state.mode == MODE_PICKED_NODE then
            renderNode = state.pickedNodesID[1] == nodeID
          end
          if renderNode then
            nodePos:set(flexNodePositions[nodeID])
            tempVec:setSub2(vertPos, nodePos)
            local dist = tempVec:squaredLength()
            maxNodeVertDist = max(dist, maxNodeVertDist)
            lineCol.r, lineCol.g, lineCol.b, lineCol.a = vertCol.r, vertCol.g, vertCol.b, dist / prevMaxNodeVertDist
            debugDrawer:drawLine(vertPos, nodePos, lineCol)
          end
        end
      end
      if p then p:add("Render mesh render line") end
    end
    ::continue::
  end

  if p then p:finish(true) end

  currNodesUsed = tableSize(nodesUsed)

  prevMaxNodeVertDist = maxNodeVertDist
  maxNodeVertDist = 0

  prevMinBounds:set(minBounds)
  prevMaxBounds:set(maxBounds)
  minBounds:set(huge,huge,huge)
  maxBounds:set(-huge,-huge,-huge)

  -- Render mesh's nodes
  if state.mode == MODE_DEFAULT
  or state.mode == MODE_PICKING_NODE
  or state.mode == MODE_PICKING_VERTEX then
    for _, nodeID in ipairs(flexbody._group_nodes) do
      nodePos:set(flexNodePositions[nodeID])
      local nodeColor = nodesUsed[nodeID] and nodeUsedColor or nodeUnusedColor

      debugDrawer:drawSphere(nodePos, nodeRenderRadius, nodeColor)
    end

  elseif state.mode == MODE_PICKED_NODE then
    local node = vEditor.vdata.nodes[state.pickedNodesID[1]]
    nodePos:set(vEditor.vehicle:getNodeAbsPositionXYZ(state.pickedNodesID[1]))

    debugDrawer:drawTextAdvanced(nodePos, tostring(node.name or node.cid), textColor, true, false, textBackgroundColor)
    debugDrawer:drawSphere(nodePos, nodeRenderRadius, nodeSelectedColor)

  elseif state.mode == MODE_PICKED_VERTEX then
    local loc = flexbodyObj:getVertexLocatorInfo(state.pickedVerticesID[1])

    if loc then
      local locNodes = loc.nodes
      local locCoords = loc.coords

      local refNodeID = locNodes[1]

      if refNodeID ~= -1 then
        local refNodePos = vEditor.vehicle:getNodeAbsPosition(refNodeID)

        for k, nodeID in ipairs(locNodes) do
          if nodeID ~= -1 then
            local node = vEditor.vdata.nodes[nodeID]
            nodePos:set(vEditor.vehicle:getNodeAbsPositionXYZ(nodeID))
            local nodeName = ""

            if k == 1 then
              nodeName = "ref"
              debugDrawer:drawSphere(nodePos, nodeRenderRadius, nodeUsedColor)
            else
              if k == 2 then nodeName = "nx"
              elseif k == 3 then nodeName = "ny"
              elseif k == 4 then nodeName = "nz" end

              local col = axesColors[k - 1]
              debugDrawer:drawLine(refNodePos, nodePos, col)
              debugDrawer:drawSphere(nodePos, nodeRenderRadius, col)
            end

            debugDrawer:drawTextAdvanced(nodePos, nodeName .. ": " .. tostring(node.name or node.cid), textColor, true, false, textBackgroundColor)
          end
        end
      end
    end

  elseif state.mode == MODE_SHOW_VERTICES_LACKING_NODES then
    for _, nodeID in ipairs(flexbody._group_nodes) do
      nodePos:set(vEditor.vehicle:getNodeAbsPositionXYZ(nodeID))
      debugDrawer:drawSphere(nodePos, nodeRenderRadius, nodeUnusedColor)
    end
  end

  -- renderCount = renderCount + 1
  -- if renderCount == renderTotal then
  --   renderCount = 0
  -- end
end

local function removeVehicle(vehID)
  if vehID == -1 then return end

  initVehDatas[vehID] = nil
  initStates[vehID] = nil
  states[vehID] = nil
end

local function switchVehicle(vehID)
  if vehID == -1 then return end

  if not initVehDatas[vehID] then
    local vehData = core_vehicle_manager.getVehicleData(vehID)

    if vehData then
      initVehDatas[vehID] = deepcopy(vehData)
      initStates[vehID] = deepcopy(initStateTemplate)

      local namesToID = {}

      for i = 0, tableSizeC(vehData.vdata.flexbodies) - 1 do
        local flexbody = vehData.vdata.flexbodies[i]

        namesToID[flexbody.mesh] = i
      end

      local sorted = tableKeysSorted(namesToID)

      for _, name in ipairs(sorted) do
        table.insert(initStates[vehID].sortedFlexbodiesData, vehData.vdata.flexbodies[namesToID[name]])
      end

      local vehName = vehData.mainPartName
      local vehSettings = settings[vehName]
      if not vehSettings then
        vehSettings = {favoriteFlexmeshes = {}}
      end

      initStates[vehID].settings = vehSettings

      states[vehID] = deepcopy(initStates[vehID])
    end
  end

  initVehData = initVehDatas[vehID]
  initState = initStates[vehID]
  state = states[vehID]
end

local function onVehicleEditorRenderJBeams(dtReal, dtSim, dtRaw)
  if not (wndOpen and state and vEditor.vehicle and vEditor.vdata) then return end

  local flexbody = state.sortedFlexbodiesData[state.selectedFlexbody]
  if not flexbody then return end

  local flexbodyObj = vEditor.vehicle:getFlexmesh(flexbody.fid)
  if not flexbodyObj then return end

  -- Render picked stuff
  renderPickedFlexbody(flexbody, flexbodyObj)

  -- Pick node on state
  if state.mode == MODE_PICKING_NODE then
    pickNode(flexbody, flexbodyObj)
  elseif state.mode == MODE_PICKING_VERTEX then
    pickVertex(flexbody, flexbodyObj)
  elseif state.mode == MODE_SHOW_VERTICES_LACKING_NODES then
    verticesLackingNodesModeShowVertexInfoOnHover(flexbody, flexbodyObj)
  end
end

local function renderFlexmeshCombobox(pickedFlexbody, pickedFlexbodyObj)
  local pickedName = pickedFlexbody == nil and "None" or pickedFlexbody.mesh

  im.PushItemWidth(150)
  if im.BeginCombo("##flexbodiesCombobox", pickedName, im.ComboFlags_HeightLarge) then
    for i = 0, #state.sortedFlexbodiesData do
      local flexbody = state.sortedFlexbodiesData[i]
      local name = flexbody ~= nil and flexbody.mesh or "None"
      if im.Selectable1(name) then
        selectFlexbody(i)
        break
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()

  im.SameLine()
  im.Text(" or ")
  im.SameLine()

  im.PushItemWidth(125)
  im.InputText("Select by Typing", flexbodyInputTextInput)
  im.PopItemWidth()

  local input = ffi.string(flexbodyInputTextInput)

  flexbodyInputTextPopupOpen = input ~= ""

  if flexbodyInputTextPopupOpen then
    local inputSize = im.GetItemRectSize()

    flexbodyInputTextPopupSize.x = inputSize.x
    flexbodyInputTextPopupSize.y = 100

    flexbodyInputTextPopupPos = im.GetItemRectMin()
    flexbodyInputTextPopupPos.y = flexbodyInputTextPopupPos.y + inputSize.y

    -- Show tooltip of suggestions based on user input
    im.SetNextWindowPos(flexbodyInputTextPopupPos)
    im.SetNextWindowSize(flexbodyInputTextPopupSize)
    if im.Begin(inputSuggestWndName, nil, inputSuggestWndFlags) then
      for i = 0, #state.sortedFlexbodiesData do
        local flexbody = state.sortedFlexbodiesData[i]
        if flexbody then
          local name = flexbody.mesh
          if string.find(name, input, 1, true) then
            if im.Selectable1(name) then
              selectFlexbody(i)
              break
            end
          end
        end
      end
      im.End()
    end
  end

  if im.Button("Favorite") then
    table.insert(state.settings.favoriteFlexmeshes, state.selectedFlexbody)
    saveVehicleSettings()
  end
end

local function renderSelectNodeByID(flexbody, flexbodyObj)
  im.PushItemWidth(50)
  im.InputText("Add Node by ID", nodeInputTextInput)
  im.PopItemWidth()

  local input = ffi.string(nodeInputTextInput)

  nodeInputTextPopupOpen = input ~= ""

  if nodeInputTextPopupOpen then
    local inputSize = im.GetItemRectSize()

    nodeInputTextPopupSize.x = inputSize.x
    nodeInputTextPopupSize.y = 100

    nodeInputTextPopupPos = im.GetItemRectMin()
    nodeInputTextPopupPos.y = nodeInputTextPopupPos.y + inputSize.y

    -- Show tooltip of suggestions based on user input
    im.SetNextWindowPos(nodeInputTextPopupPos)
    im.SetNextWindowSize(nodeInputTextPopupSize)
    if im.Begin(inputSuggestWndName, nil, inputSuggestWndFlags) then

      -- Go through list of flexbody nodes
      for _, nodeID in ipairs(flexbody._group_nodes) do
        local node = vEditor.vdata.nodes[nodeID]
        local nodeName = tostring(node.name or nodeID)

        if string.find(nodeName, input, 1, true) then
          -- on clicking suggestion, select node!
          if im.Selectable1(nodeName) then
            ffi.copy(nodeInputTextInput, "")

            state.pickedNodesID[1] = nodeID
            state.mode = MODE_PICKED_NODE
          end
        end
      end
      im.End()
    end
  end
end

local function renderSelectVertexByID(flexbody, flexbodyObj)
  im.PushItemWidth(50)
  im.InputText("Add Vertex by ID", vertexInputTextInput)
  im.PopItemWidth()

  local input = ffi.string(vertexInputTextInput)

  vertexInputTextPopupOpen = input ~= ""

  if vertexInputTextPopupOpen then
    local inputSize = im.GetItemRectSize()

    vertexInputTextPopupSize.x = inputSize.x
    vertexInputTextPopupSize.y = 100

    vertexInputTextPopupPos = im.GetItemRectMin()
    vertexInputTextPopupPos.y = vertexInputTextPopupPos.y + inputSize.y

    -- Show tooltip of suggestions based on user input
    im.SetNextWindowPos(vertexInputTextPopupPos)
    im.SetNextWindowSize(vertexInputTextPopupSize)
    if im.Begin(inputSuggestWndName, nil, inputSuggestWndFlags) then
      local vertCount = flexbodyObj:getVertexCount()

      -- Go thorugh list of flexmesh vertices
      for i = 0, vertCount - 1 do
        local vertName = tostring(i)

        if string.find(vertName, input, 1, true) then
          -- on clicking suggestion, select vertex!
          if im.Selectable1(vertName) then
            ffi.copy(vertexInputTextInput, "")

            state.pickedVerticesID[1] = i
            state.mode = MODE_PICKED_VERTEX
          end
        end
      end
      im.End()
    end
  end
end

local function renderSingleFlexmeshUI()
  local pickedFlexbody = state.sortedFlexbodiesData[state.selectedFlexbody]
  local pickedFlexbodyObj = pickedFlexbody and vEditor.vehicle:getFlexmesh(pickedFlexbody.fid) or nil

  im.Columns(2, "Two Columns")

  renderFlexmeshCombobox(pickedFlexbody, pickedFlexbodyObj)

  if pickedFlexbody and pickedFlexbodyObj then
    im.PushItemWidth(150)
    if im.SliderFloat("Max Dist from Cursor", maxDistFromCursor, 0.0, 10.0, "%.2f") then end
    --im.PopItemWidth()
    --im.PushItemWidth(150)
    if im.SliderFloat("Mesh Visibility", state.meshVis, 0.0, 1.0, "%.2f") then
      vEditor.vehicle:setMeshAlpha(state.meshVis[0], pickedFlexbody.mesh, false)
    end
    im.PopItemWidth()

    if im.Button("Show picked flexbody") then
      showPickedFlexbody()
    end

    im.Spacing()

    local pickNodeBtnText = state.mode == MODE_PICKING_NODE and "Picking Node..." or "Pick Node"
    if im.Button(pickNodeBtnText) then
      table.clear(state.pickedNodesID)

      if state.mode ~= MODE_PICKING_NODE then
        state.mode = MODE_PICKING_NODE
      else
        state.mode = MODE_DEFAULT
      end
    end
    im.SameLine()
    im.Text("  or ")
    im.SameLine()
    renderSelectNodeByID(pickedFlexbody, pickedFlexbodyObj)

    local pickVertBtnText = state.mode == MODE_PICKING_VERTEX and "Picking Vertex..." or "Pick Vertex"
    if im.Button(pickVertBtnText) then
      table.clear(state.pickedVerticesID)

      if state.mode ~= MODE_PICKING_VERTEX then
        state.mode = MODE_PICKING_VERTEX
      else
        state.mode = MODE_DEFAULT
      end
    end
    im.SameLine()
    im.Text(" or ")
    im.SameLine()
    renderSelectVertexByID(pickedFlexbody, pickedFlexbodyObj)

    if im.Button("Deselect All") then
      state.mode = MODE_DEFAULT
      table.clear(state.pickedNodesID)
      table.clear(state.pickedVerticesID)
    end

    local vertCount = pickedFlexbodyObj:getVertexCount()
    local nodeCount = #pickedFlexbody._group_nodes

    im.Spacing()
    im.Text("Total Vertices Count = " .. vertCount)
    im.Text("Total Nodes Count = " .. nodeCount)
    im.Text("   Unused Nodes Count = " .. (nodeCount - currNodesUsed))
  end

  im.NextColumn()

  im.Text("Favorites")
  for i, id in ipairs(state.settings.favoriteFlexmeshes) do
    local flexbody = state.sortedFlexbodiesData[id]
    local name

    if flexbody == nil then
      name = "None"
    else
      name = flexbody.mesh
    end

    if im.Button(name) then
      selectFlexbody(id)
    end
    im.SameLine()
    if im.Button("X##" .. name) then
      table.remove(state.settings.favoriteFlexmeshes, i)
      saveVehicleSettings()
    end
  end

  im.Columns(1)
end

local function getVerticesWithOOBCoords()
  local count = 0
  local countVec = vec3(0,0,0)

  local res = {}
  local lookup = {}

  local idx = 1

  for i = 1, #state.sortedFlexbodiesData do
    local insertedElement = false

    local flexbody = state.sortedFlexbodiesData[i]
    if flexbody and flexbody.fid then
      local flexbodyObj = vEditor.vehicle:getFlexmesh(flexbody.fid)
      if flexbodyObj then
        local vertCount = flexbodyObj:getVertexCount()

        for j = 0, vertCount - 1 do
          local loc = flexbodyObj:getVertexLocatorInfo(j)

          if loc then
            local locNodes = loc.nodes
            local locCoords = loc.coords

            local refPos = vEditor.vdata.nodes[locNodes[1]].pos
            local nxVec = vEditor.vdata.nodes[locNodes[2]].pos - refPos
            local nyVec = vEditor.vdata.nodes[locNodes[3]].pos - refPos

            --local nzVec = vEditor.vdata.nodes[locNodes[4]] - refPos

            local spikeX, spikeY, spikeZ

            if locCoords.x < -0.5 or locCoords.x > 1.5 then
              spikeX = true
              countVec.x = countVec.x + 1
            end
            if locCoords.y < -0.5 or locCoords.y > 1.5 then
              spikeY = true
              countVec.y = countVec.y + 1
            end
            if locNodes[4] ~= -1 and (locCoords.z < -0.5 or locCoords.z > 1.5) then
              spikeZ = true
              countVec.z = countVec.z + 1
            end

            --if locCoords:length() > 2 then
            if spikeX or spikeY or spikeZ then
              if not res[idx] then
                res[idx] = {}
                lookup[idx] = i
                insertedElement = true
              end

              table.insert(res[idx], {id = j, locCoords = locCoords})
              count = count + 1
            end
          end
        end
      end
    end

    if insertedElement then
      idx = idx + 1
    end
  end

  return {data = res, idxToFlexID = lookup, count = count, countVec = countVec}
end

local function getVerticesLackingNodes()
  local count = 0

  local res = {}
  local lookup = {}

  local idx = 1

  vEditor.vehicle:setFlexmeshDebugMode(true)

  for i = 1, #state.sortedFlexbodiesData do
    local insertedElement = false

    local flexbody = state.sortedFlexbodiesData[i]
    if flexbody and flexbody.fid then
      local flexbodyObj = vEditor.vehicle:getFlexmesh(flexbody.fid)
      if flexbodyObj then
        local vertCount = flexbodyObj:getVertexCount()

        local tbl = {}

        -- Interquartile Range Test to determine vertices that are too far away from nodes
        for j = 0, vertCount - 1 do
          local vertexPos = flexbodyObj:getInitVertexPos(j)
          local minDist = huge

          for _, nodeID in ipairs(flexbody._group_nodes) do
            local dist = (vEditor.vdata.nodes[nodeID].pos - vertexPos):length()

            if dist < minDist then
              minDist = dist
            end
          end

          table.insert(tbl, {minDist, j})
        end

        table.sort(tbl, function(a, b) return a[1] < b[1] end)

        local dists = {}
        local vertexIDs = {}

        for k, v in ipairs(tbl) do
          dists[k] = v[1]
          vertexIDs[k] = v[2]
        end

        local q1 = dists[math.floor(vertCount / 4)]
        local q3 = dists[math.floor(vertCount * 3 / 4)]
        local iqr = q3 - q1
        local upper = q3 + 1.5 * iqr
        --local lower = q1 - 1.5 * iqr

        for k, dist in ipairs(dists) do
          if dist > upper then
            if not res[idx] then
              res[idx] = {}
              lookup[idx] = i
              insertedElement = true
            end

            table.insert(res[idx], vertexIDs[k])
            count = count + 1
          end
        end
      end
    end

    if insertedElement then
      idx = idx + 1
    end
  end

  return {data = res, idxToFlexID = lookup, count = count}
end

local function renderAllFlexmeshesUI()
  if im.Button("Find vertices lacking nearby nodes") then
    state.verticesLackingNodesData = getVerticesLackingNodes()
    showVerticesLackingNodesWindow[0] = true
  end
  if im.Button("(EXPERT!) Find vertices with 'Out of Bounds' coords") then
    state.verticesOOBCoordsData = getVerticesWithOOBCoords()
    showVerticesOBBCoordsWindow[0] = true
  end
end

local function renderVertexOOBCoordsWindow()
  if showVerticesOBBCoordsWindow[0] then
    if im.Begin(verticesOOBCoordsWindowName, showVerticesOBBCoordsWindow) then
      if state.verticesOOBCoordsData then
        local totalVertices = getPlayerVehicle(0):getRootNodeFlexmesh():getVertexCount()

        im.Text("Potential Spiking Vertices Count: " .. string.format("%d / %d", state.verticesOOBCoordsData.count, totalVertices))
        im.Text("Problematic Locators Count (NX,NY,NZ): " .. dumps(state.verticesOOBCoordsData.countVec))
        im.Separator()

        for k, verticesData in ipairs(state.verticesOOBCoordsData.data) do
          local flexID = state.verticesOOBCoordsData.idxToFlexID[k]
          local flexmesh = state.sortedFlexbodiesData[flexID]

          if im.TreeNodeEx1(flexmesh.mesh .. "##" .. tostring(k)) then
            for _, vertData in ipairs(verticesData) do
              local vertID = vertData.id
              local locCoords = vertData.locCoords
              local text = string.format("%d: (%.2f, %.2f, %.2f)", vertID, locCoords.x, locCoords.y, locCoords.z)

              if im.Button(text) then
                selectFlexbody(flexID)
                selectVertex(vertID)
              end
            end

            im.TreePop()
          end
        end
      end
    end
  end
end

local function renderVerticesLackingNodesWindow()
  if showVerticesLackingNodesWindow[0] then
    if im.Begin(verticesLackingNodesWindowName, showVerticesLackingNodesWindow) then
      if state.verticesLackingNodesData then
        local totalVertices = getPlayerVehicle(0):getRootNodeFlexmesh():getVertexCount()

        im.Text("Problematic Vertices Count: " .. string.format("%d / %d", state.verticesLackingNodesData.count, totalVertices))
        im.Separator()

        if im.BeginChild1("##renderVerticesLackingNodesWindowData") then
          for k, verticesData in ipairs(state.verticesLackingNodesData.data) do
            local flexID = state.verticesLackingNodesData.idxToFlexID[k]
            local flexmesh = state.sortedFlexbodiesData[flexID]

            if im.Button(flexmesh.mesh .. "##" .. tostring(k)) then
              selectFlexbody(flexID, 0.5)
              selectVerticesForLackingNodesMode(verticesData)
            end
          end
          im.EndChild()
        end
      end
    end
  end
end

local function onEditorGui(dt)
  if not (vEditor.vehicle and vEditor.vdata) then return end

  -- Initialize initial state with vehicle data
  if not initVehData then
    settings = jsonReadFile(settingsPath) or {}
    switchVehicle(vEditor.vehicle:getID())
  end
  if not state then return end

  if editor.beginWindow(wndName, wndName, mainWndFlags) then
    wndOpen = true

    if im.BeginTabBar("##tabs") then
      if im.BeginTabItem("Single Flexmesh") then
        renderSingleFlexmeshUI()
        im.EndTabItem()
      end
      if im.BeginTabItem("All Flexmeshes") then
        renderAllFlexmeshesUI()
        im.EndTabItem()
      end
      im.EndTabBar()
    end

    renderVertexOOBCoordsWindow()
    renderVerticesLackingNodesWindow()
  else
    wndOpen = false
  end
  editor.endWindow()
end

local function onVehicleSwitched(oldVehicle, newVehicle, player)
  switchVehicle(newVehicle)
end

local function onVehicleSpawned(id)
  removeVehicle(id)
end

local function open()
  editor.showWindow(wndName)
end

local function onEditorToolWindowShow(window)
  if window == wndName then
    wndOpen = true
  end
end

local function onEditorToolWindowHide(window)
  if window == wndName then
    wndOpen = false
  end
end

local function onEditorInitialized()
  editor.registerWindow(wndName, im.ImVec2(200,100))
end

M.onVehicleEditorRenderJBeams = onVehicleEditorRenderJBeams
M.onEditorGui = onEditorGui
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleSpawned = onVehicleSpawned
M.open = open
M.onEditorToolWindowShow = onEditorToolWindowShow
M.onEditorToolWindowHide = onEditorToolWindowHide
M.onEditorInitialized = onEditorInitialized

return M