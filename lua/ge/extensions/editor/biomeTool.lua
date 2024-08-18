-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local u_32_max_int = 4294967295
local logTag = 'biome_tool'
local toolWindowName = "biomeTool"
local editModeName = "Edit Biome"
local imgui = ui_imgui
local ffi = require('ffi')
local windows = {}
local currentWindow = {}
local testingWindow
local allFiles = {}
local searchText = imgui.ArrayChar(256, "")
local searchText_Items_Modify = imgui.ArrayChar(256, "")
local searchText_Meshes_Generate = imgui.ArrayChar(256, "")
local sinkRadiusText = imgui.ArrayChar(256, "1")

local roadRiverGui = extensions.editor_roadRiverGui
local mouseInfo = {}
local nameText = imgui.ArrayChar(1024, "")
local groupItemsBoolPtr = imgui.BoolPtr(1)
local selectAllBoolPtr = imgui.BoolPtr(0)
local layerGlobalIndices = {}
local exclusionZoneIndices = {}
local selectAreaPopupIndex = imgui.IntPtr(0)
local isDrawingLassoArea = false
local valueInspector = require("editor/api/valueInspector")()

local forest

local layerCreateMtlComboIndex = imgui.IntPtr(0)
local layerCreateMtlComboItemsTbl = {}
local layerCreateMtlComboItems = imgui.ArrayCharPtrByTbl(layerCreateMtlComboItemsTbl)

local createLayerTypeIndex = imgui.IntPtr(1)

local layerDeleteComboIndex = imgui.IntPtr(0)
local layerDeleteMtlComboItemsTbl = {}
local layerDeleteMtlComboItems = imgui.ArrayCharPtrByTbl(layerDeleteMtlComboItemsTbl)

local layerBlendingComboItemsTbl = {"Add", "Delete", "Replace"}
local layerBlendingComboItems = imgui.ArrayCharPtrByTbl(layerBlendingComboItemsTbl)
local terrainBlock = nil
local maskFilePath = imgui.ArrayChar(256,"")
local editAreaIndex = nil
local renameEditEnded = imgui.BoolPtr(false)
local renameTextValue = imgui.ArrayChar(500)
local areaMaterialIndex = 0
local areaType_enum = {
  lasso = 0,
  terrain_material = 1
}

local layerType_enum = {
  lasso = 0,
  terrain_material = 1,
  terrain_mask = 2,
  random = 3,
  any = 4
}

local lassoBlending_enum = {
  add = 0,
  delete = 1,
  replace = 2,
}

local enum_forestObjType = {
  forestBrush = 1,
  forestBrushElement = 2,
  forestItemData = 3
}

local enum_forestBrushItemZone = {
  central = 1,
  falloff = 2
}

local noneBrushItemName = "- NONE -"

local fieldInfoTemplate = {
  { name = "TerrainMaterial", label = "Terrain material", val = 1, type = "int", layerType = layerType_enum.any},
  { name = "TerrainMask", label = "Terrain mask", val = "", type = "string", layerType = layerType_enum.any},
  { name = "ForestDensity", label = "Forest density (0 to 1)", val = 1, minValue = 0, maxValue = 1, type = "float", layerType = layerType_enum.any},
  { name = "SlopeInfluence", label = "Slope influence (-1 to 1)", val = 0, minValue = -1, maxValue = 1, type = "float", layerType = layerType_enum.any},
  { name = "SlopeRange", label = "Slope range (0 to 90)", val = {0, 90}, minValue = 0, maxValue = 90, type = "float", layerType = layerType_enum.any},
  { name = "BordersFalloff", label = "Border falloff (-10 to 10)", val = 0, minValue = -10, maxValue = 10, type = "int", layerType = layerType_enum.any},
  { name = "BordersDensity", label = "Border Density (0 to 1)", val = 1, minValue = 0, maxValue = 1, type = "float", layerType = layerType_enum.any},
  { name = "VegetationFalloff", label = "Vegetation falloff (-10 to 10)", val = 0, minValue = -10, maxValue = 10, type = "float", layerType = layerType_enum.any},

  --lasso only
  { name = "BlendingMethod", label = "Blending method", val = lassoBlending_enum.add, type = "int", layerType = layerType_enum.lasso},
  --{ name = "DeleteForest", label = "Delete forest", val = lassoBlending_enum.add, type = "bool", layerType = layerType_enum.lasso},

  --Random only
  { name = "RA_Size", label = "Random area size (0 to 1)", val = 0, minValue = 0, maxValue = 1, type = "float", layerType = layerType_enum.random},
  { name = "RA_SizeVar", label = "Random area size variation (0 to 1)", val = 0, minValue = 0, maxValue = 1, type = "float", layerType = layerType_enum.random},
  { name = "RA_Density", label = "Random area density (0 to 1)", val = 0, minValue = 0, maxValue = 1, type = "float", layerType = layerType_enum.random},
  { name = "RA_Seed", label = "Random area seed", val = 0, type = "int", layerType = layerType_enum.random}
}

local areaListFilter = imgui.ImGuiTextFilter()
local var = {}
var.areas = {}
var.areas.layerBlendingComboIndexTbl = {}
var.areas.areaGlobalIndex = 1
var.areas.areaInfoTbl = {}
var.areas.fieldInfoTbl = {}
var.areas.forestBrushSelectedItems = {}
var.forestBrushes = {}
var.lassoAreas = {}
var.lassoPLNodes = {}
var.lassoPLLineSegments = {}
var.lassoHoveredNode = {}
var.lassoActionHoveredNodeIndex = nil
var.lassoActionSelectedNodeIndex = nil
var.lassoSelectionEnded = false
var.lassoSelectionItemsCalculated = false
var.mouseButtonHeldOnLassoNode = false
var.shouldRenderCompletionSphere = false
var.lassoDrawActionCompleted = false
var.lassoAreaSelectedNode = {}
var.selectedAreaID = nil
var.lassoAreasGroupedMeshTable = {}
var.isGroupMeshesEnabled = true
var.groupSelectedIndices_Modify = {}
var.itemsSelectedIndices_Modify = {}
var.groupSelectedIndices_Generate = {}
var.itemsSelectedIndices_Generate = {}
var.selectAllEnabled = false
var.selectedLayerID = nil
var.forestBrushGroup = {}
var.buttonColor_active = imgui.GetStyleColorVec4(imgui.Col_ButtonActive)
var.buttonColor_inactive = imgui.GetStyleColorVec4(imgui.Col_Button)
var.forestBrushTool = nil
var.itemsToDelete = {}
var.enum_lassoDrawType = {inclusionZone = 0, exclusionZone = 1}
var.lassoDrawInfo = {type = var.enum_lassoDrawType.inclusionZone, areaID = nil, layerID = nil}
var.areas.exclusionZones = {}
var.enum_hoveredNodeAreaType = {lassoAction = 0, inclusionZone = 1, exclusionZone = 2}
var.hoveredNodeAreaType = var.enum_hoveredNodeAreaType.lassoAction

local function resetSelectedItemIndices(areaID)
  if var.groupSelectedIndices_Modify[areaID] then
    var.groupSelectedIndices_Modify[areaID] = {}
  end
end

local function resetSelectedGroupIndices(areaID)
  if var.itemsSelectedIndices_Modify[areaID] then
    var.itemsSelectedIndices_Modify[areaID] = {}
  end
end

local function getAreaByID(areaID)
  local area = nil
  if areaID == nil then return nil end
  for _, areaItem in ipairs(var.areas.areaInfoTbl) do
    if areaItem.areaID == areaID then
      area = areaItem
      break
    end
  end
  return area
end

local function resetAreaGroupedItemCount(areaID)
  for _, entriesInfo in ipairs(var.lassoAreasGroupedMeshTable) do
    if entriesInfo.areaID == areaID then
      entriesInfo.meshEntries = {}
      break
    end
  end
end

local function findItemInGroupedMeshTbl(areaID, itemName)
  local entry = {areaID = nil, meshEntry = nil}
  for _, entriesInfo in ipairs(var.lassoAreasGroupedMeshTable) do
    if entriesInfo.areaID == areaID then
      entry.areaID = entriesInfo.areaID
      for _, meshEntry in ipairs(entriesInfo.meshEntries) do
        if meshEntry.shapeFilePath == itemName then
          entry.meshEntry = meshEntry
          break
        end
      end
      break
    end
  end
  return entry
end

local function getGroupMeshEntriesForArea(areaID)
  local meshEntries = {}
  for _, entriesInfo in ipairs(var.lassoAreasGroupedMeshTable) do
    if entriesInfo.areaID == areaID then
      meshEntries = entriesInfo.meshEntries
      break
    end
  end
  return meshEntries
end

local function findAreaInGroupedMeshTbl(areaID)
  local area = nil
  for _, areaItem in ipairs(var.lassoAreasGroupedMeshTable) do
    if areaItem.areaID == areaID then
      area = areaItem
    end
  end
  return area
end

local function incrementGroupedMeshCount(areaID, forestItem)
  local tblMeshEntry = findItemInGroupedMeshTbl(areaID, forestItem:getData():getShapeFile())
  if tblMeshEntry.areaID == nil then
    local meshEntry = {
      shapeFilePath = tostring(forestItem:getData():getShapeFile()),
      name = tostring(forestItem:getData():getName()),
      count = 1
    }
    local entryInfo = {
      areaID = areaID,
      meshEntries = {meshEntry}
    }
    table.insert(var.lassoAreasGroupedMeshTable, entryInfo)
  elseif tblMeshEntry.meshEntry == nil then
    local areaEntry = findAreaInGroupedMeshTbl(areaID)
    local meshEntry = {
      shapeFilePath = tostring(forestItem:getData():getShapeFile()),
      name = tostring(forestItem:getData():getName()),
      count = 1
    }
    table.insert(areaEntry.meshEntries, meshEntry)
  else
    tblMeshEntry.meshEntry.count = tblMeshEntry.meshEntry.count + 1
  end
end

local function groupItemsByMesh(areaID)
  local area = getAreaByID(areaID)
  if area then
    resetAreaGroupedItemCount(areaID)
    for _, item in ipairs(area.items) do
      incrementGroupedMeshCount(areaID, item)
    end
  end
end

local function calculateLassoSelectionOnArea(areaID)
  local area = getAreaByID(areaID)
  if area == nil then return end

  local lassoNodes2D = {}
  for _, node in ipairs(area.nodes) do
    table.insert(lassoNodes2D, Point2F(node.pos.x, node.pos.y))
  end

  local forestItems = var.forestData:getItemsPolygon(lassoNodes2D)
  if not forestItems then return end
  area.items = {}

  for _, item in ipairs(forestItems) do
    table.insert(area.items, item)
  end
  groupItemsByMesh(areaID)
end

local function getLayers(areaID)
  local layers = {}
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID then
      layers = area.layers
      break
    end
  end
  return layers
end

local function getLassoNodeUnderCursor()
  local camPos = core_camera.getPosition()
  local ray = getCameraMouseRay()
  local rayDir = ray.dir
  local minNodeDist = u_32_max_int
  local hoveredNodeIndex = nil
  local hoveredNodeLayerID = nil
  local hoveredNodeExZoneID = nil
  local hoveredNodeAreaType = var.enum_hoveredNodeAreaType.lassoAction

  for nodeIndex, node in ipairs(var.lassoPLNodes) do
    local distNodeToCam = (node.pos - camPos):length()
    if distNodeToCam < minNodeDist then
      local nodeRayDistance = (node.pos - camPos):cross(rayDir):length() / rayDir:length()
      local sphereRadius = (camPos - node.pos):length() * roadRiverGui.nodeSizeFactor
      if nodeRayDistance <= sphereRadius then
        hoveredNodeLayerID = -1
        hoveredNodeIndex = nodeIndex
        minNodeDist = distNodeToCam
      end
    end
  end
  if hoveredNodeIndex ~= nil then
    hoveredNodeAreaType = var.enum_hoveredNodeAreaType.lassoAction
    return {index = hoveredNodeIndex, layerID = hoveredNodeLayerID, areaType = hoveredNodeAreaType}
  end

  if not var.selectedAreaID then return nil end
  local layers = getLayers(var.selectedAreaID)
  for layerIndex, layer in ipairs(layers) do
    if layer.layerType == layerType_enum.lasso then
      for index, node in ipairs(layer.lassoNodes) do
        local distNodeToCam = (node.pos - camPos):length()
        if distNodeToCam < minNodeDist then
          local nodeRayDistance = (node.pos - camPos):cross(rayDir):length() / rayDir:length()
          local sphereRadius = (camPos - node.pos):length() * roadRiverGui.nodeSizeFactor
          if nodeRayDistance <= sphereRadius then
            hoveredNodeLayerID = layerIndex
            hoveredNodeIndex = index
            minNodeDist = distNodeToCam
          end
        end
      end
    end
  end
  if hoveredNodeIndex ~= nil then
    hoveredNodeAreaType = var.enum_hoveredNodeAreaType.inclusionZone
    return {index = hoveredNodeIndex, layerID = hoveredNodeLayerID, areaType = hoveredNodeAreaType}
  end

  for _, zonesEntry in ipairs(var.areas.exclusionZones) do
    for _, data in ipairs(zonesEntry.zoneData) do
      for nodeIndex, node in ipairs(data.nodes) do
        local distNodeToCam = (node.pos - camPos):length()
        if distNodeToCam < minNodeDist then
          local nodeRayDistance = (node.pos - camPos):cross(rayDir):length() / rayDir:length()
          local sphereRadius = (camPos - node.pos):length() * roadRiverGui.nodeSizeFactor
          if nodeRayDistance <= sphereRadius then
            hoveredNodeLayerID = zonesEntry.layerID
            hoveredNodeIndex = nodeIndex
            hoveredNodeExZoneID = data.ID
            minNodeDist = distNodeToCam
          end
        end
      end
    end
  end
  if hoveredNodeIndex ~= nil then
    hoveredNodeAreaType = var.enum_hoveredNodeAreaType.exclusionZone
  end

  return hoveredNodeIndex == nil and nil or {index = hoveredNodeIndex, layerID = hoveredNodeLayerID, exclusionZoneID = hoveredNodeExZoneID, areaType = hoveredNodeAreaType}
end

local function castRayDown(startPoint, endPoint)
  if not endPoint then
    endPoint = startPoint - vec3(0,0,100)
  end
  local res = Engine.castRay((startPoint + vec3(0,0,1)), endPoint, true, false)
  if not res then
    res = Engine.castRay((startPoint + vec3(0,0,100)), (startPoint - vec3(0,0,1000)), true, false)
  end
  return res
end

local function drawLassoLineSegmented(areaID, originNode, targetNode, lassoAreaType)
  originNode.pos = vec3(originNode.pos.x, originNode.pos.y, originNode.pos.z)
  targetNode.pos = vec3(targetNode.pos.x, targetNode.pos.y, targetNode.pos.z)
  local length = (originNode.pos - targetNode.pos):length()
  local segmentsCount = length / 4.0
  local directionVector = (targetNode.pos - originNode.pos):normalized()

  local lastPos = originNode.pos
  local lineSegments = {}
  for index = 1, segmentsCount + 1, 1 do
    local tempTarget = (index < segmentsCount) and (lastPos + (directionVector * 4.0)) or targetNode.pos
    local tempLineBegin = lastPos
    local tempLineEnd = tempTarget

    if originNode.isUpdated or targetNode.isUpdated then
      local rayCastBegin = castRayDown(lastPos + vec3(0,0,100))
      local rayCastEnd = castRayDown(tempTarget + vec3(0,0,100))
      if rayCastBegin then
        tempLineBegin = vec3(lastPos.x,lastPos.y,rayCastBegin.pt.z)
      end
      if rayCastEnd then
        tempLineEnd = vec3(tempTarget.x,tempTarget.y,rayCastEnd.pt.z)
      end
    else
      local areaLineSegments =  var.lassoPLLineSegments[areaID]
      if areaLineSegments and areaLineSegments[originNode.nodeID] then
        local currentLassoSegments = areaLineSegments[originNode.nodeID]
        if currentLassoSegments[index] then
          tempLineBegin = currentLassoSegments[index].startPos
          tempLineEnd = currentLassoSegments[index].endPos
        end
      end
    end

    if originNode.isUpdated or targetNode.isUpdated then
      local segment = {startPos = tempLineBegin, endPos = tempLineEnd}
      table.insert(lineSegments, segment)
    end
    local lineWidth = editor.getPreference("gizmos.general.lineThicknessScale") * 4
    local lineColor = ColorF(0,0,1,0.5)
    local renderColor = (lassoAreaType == var.enum_lassoDrawType.inclusionZone) and ColorF(0,0,1,0.5) or ColorF(1,0,0,0.5)

    debugDrawer:drawLineInstance(tempLineBegin, tempLineEnd, lineWidth, renderColor, false)
    lastPos = lastPos + (directionVector * 4.0)
  end
  -- cache segments bw updated nodes so that we don't raycast on every frame
  -- when there is no update in node positions
  if originNode.isUpdated or targetNode.isUpdated then
    local areaLineSegments =  var.lassoPLLineSegments[areaID]
    if areaLineSegments == nil then areaLineSegments = {} end
    areaLineSegments[originNode.nodeID] = lineSegments
  end
end

local function getAreaLayerGlobalIdx(areaID)
  local layerIndex = 0
  local indexFound = false
  for _, layerGlobalIndexInfo  in ipairs(layerGlobalIndices) do
    if layerGlobalIndexInfo.areaID == areaID then
      layerIndex = layerGlobalIndexInfo.layerGlobalIndex
      indexFound = true
      break
    end
  end
  if not indexFound then
    table.insert(layerGlobalIndices, {areaID = areaID, layerGlobalIndex = 0})
  end
  return layerIndex
end

local function incAreaLayerGlobalIdx(areaID)
  local indexFound = false
  for _, layerGlobalIndexInfo  in ipairs(layerGlobalIndices) do
    if layerGlobalIndexInfo.areaID == areaID then
      layerGlobalIndexInfo.layerGlobalIndex = layerGlobalIndexInfo.layerGlobalIndex + 1
      indexFound = true
      break
    end
  end
  if not indexFound then
    table.insert(layerGlobalIndices, {areaID = areaID, layerGlobalIndex = 0})
  end
end

local function incExZoneGlobalIdx(areaID, layerID)
  local indexFound = false
  for _, zoneIndexInfo  in ipairs(exclusionZoneIndices) do
    if zoneIndexInfo.areaID == areaID and zoneIndexInfo.layerID == layerID  then
      zoneIndexInfo.zoneIndex = zoneIndexInfo.zoneIndex + 1
      indexFound = true
      break
    end
  end
end

local function getExZoneGlobalIdx(areaID, layerID)
  local zoneIndex = 1
  local indexFound = false
  for _, zoneIndexInfo  in ipairs(exclusionZoneIndices) do
    if zoneIndexInfo.areaID == areaID and zoneIndexInfo.layerID == layerID then
      zoneIndex = zoneIndexInfo.zoneIndex
      indexFound = true
      break
    end
  end
  if not indexFound then
    table.insert(exclusionZoneIndices, {areaID = areaID, layerID = layerID, zoneIndex = 1})
  end

  incExZoneGlobalIdx(areaID, layerID)
  return zoneIndex
end

local function deleteExZone(areaID, layerID)
  for _, exZoneData in ipairs(var.areas.exclusionZones) do
    if exZoneData.areaID == areaID and exZoneData.layerID == layerID then
      for index, zone in ipairs(exZoneData.zoneData) do
        if zone.isSelected then
          table.remove(exZoneData.zoneData, index)
        end
      end
    end
  end
end

local function deleteLayer(areaID, layerID)
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID then
      for index, layer in ipairs(area.layers) do
        if layer.layerID == layerID then
          table.remove(area.layers, index)
          break
        end
      end
      break
    end
  end
  deleteExZone(areaID, layerID)
end


local function insertFieldInfo(areaID, layerID, fieldData)
  for _, fieldInfo in ipairs(var.areas.fieldInfoTbl) do
    if fieldInfo.layerID == layerID and fieldInfo.areaID == areaID then
      table.insert(fieldInfo.fieldsData, fieldData)
    end
  end
end

local function getLayer(areaID, layerID)
  local layerInfo = nil
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID then
      for _, layer in ipairs(area.layers) do
        if layer.layerID == layerID then
          layerInfo = layer
          break
        end
      end
      break
    end
  end
  return layerInfo
end

local function populateForestBrushes()
  var.forestBrushGroup = scenetree.findObject("ForestBrushGroup")
  var.forestBrushes = {}
  if var.forestBrushGroup then
    local forestBrushGroupSize = var.forestBrushGroup:size() - 1
    for i = 0, forestBrushGroupSize do
      local obj = var.forestBrushGroup:at(i)
      local internalName = obj:getInternalName()
      if internalName then
        local item = {
          id = obj:getId(),
          internalName = internalName,
          type = (obj:getClassName() == "ForestBrush") and enum_forestObjType.forestBrush or enum_forestObjType.forestBrushElement,
          elements = {},
          open = false,
          selected = false
        }
        table.insert(var.forestBrushes, item)
      end
    end
  end
end

local function getAreaType(areaID)
  local areaType =  areaType_enum.lasso
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if areaID == area.areaID then
      areaType = area.areaType
      break
    end
  end
  return areaType
end

local function getLayerType(areaID, layerID)
  local layerType = nil
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID then
      for _, layer in ipairs(area.layers) do
        if layer.layerID == layerID then
          layerType = layer.layerType
          break
        end
      end
      break
    end
  end
  return layerType
end

local function getBlendingMethodStr(blendingEnum)
  local blendingMethodStr = ""
  if blendingEnum == lassoBlending_enum.add then
    blendingMethodStr = "Add"
  elseif blendingEnum == lassoBlending_enum.delete then
    blendingMethodStr = "Delete"
  else
    blendingMethodStr = "Replace"
  end
  return blendingMethodStr
end

local function selectForestBrush(areaID, layerID, internalName, zoneType)
  local itemFound = false
  for _, selectedItemsInfo in ipairs(var.areas.forestBrushSelectedItems) do
    if selectedItemsInfo.areaID == areaID and selectedItemsInfo.layerID == layerID  and
      selectedItemsInfo.zoneType == (zoneType or enum_forestBrushItemZone.central) then
      table.insert(selectedItemsInfo.selectedItems, internalName)
      itemFound = true
    end
  end

  if not itemFound then
    local brushZoneType = zoneType or enum_forestBrushItemZone.central
    local selectionData = {areaID = areaID, layerID = layerID, zoneType = brushZoneType, selectedItems = {internalName}}
    table.insert(var.areas.forestBrushSelectedItems, selectionData)
  end
end

local function addLayer(areaID, layerType, materialName, lassoNodes, maskPath)
  local layerID = nil
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID then
      local layerIndex =  getAreaLayerGlobalIdx(area.areaID)
      incAreaLayerGlobalIdx(area.areaID)
      local layer = {
        layerType = layerType,
        layerID = layerIndex + 1,
        layerName = "Layer "..tostring(layerIndex + 1),
        exclusionZones = {}
      }

      if layerType == layerType_enum.terrain_material then
        layer.materialName = materialName
      elseif layerType == layerType_enum.terrain_mask then
        layer.maskFilePath = maskPath
      elseif layerType == layerType_enum.lasso then
        layer.lassoNodes = deepcopy(lassoNodes)
      end

      layerID = layerIndex + 1
      table.insert(area.layers, layer)
      selectForestBrush(areaID, layerID, noneBrushItemName, enum_forestBrushItemZone.falloff)
      selectForestBrush(areaID, layerID, noneBrushItemName, enum_forestBrushItemZone.central)
      break
    end
  end
  table.insert(var.areas.fieldInfoTbl, {areaID = areaID, layerID = layerID, fieldsData = {}})

  for _, fieldInfo in ipairs(fieldInfoTemplate) do
    if getLayerType(areaID, layerID) == layerType_enum.terrain_mask then
      if fieldInfo.name == "TerrainMaterial" then
        goto continue
      end
    end
    if getLayerType(areaID, layerID) == layerType_enum.terrain_material then
      if fieldInfo.name == "TerrainMask" then
        goto continue
      end
    end
    if getAreaType(var.selectedAreaID) == areaType_enum.lasso then
      if fieldInfo.name == "TerrainMask" or fieldInfo.name == "TerrainMaterial" then
        goto continue
      end
    end
    if fieldInfo.layerType == layerType_enum.any or layerType == fieldInfo.layerType then
      local fieldData = {
        name = fieldInfo.name,
        label = fieldInfo.label,
        val = fieldInfo.val,
        minValue = fieldInfo.minValue,
        maxValue = fieldInfo.maxValue,
        type = fieldInfo.type,
        layerType = fieldInfo.layerType
      }
      local layer = getLayer(areaID, layerID)
      if fieldInfo.name == "TerrainMaterial" then
        fieldData.val = layer.materialName or ""
      elseif fieldInfo.name == "TerrainMask" then
        fieldData.val = layer.maskFilePath
      elseif fieldInfo.name == "BlendingMethod" then
        fieldData.val = getBlendingMethodStr(fieldData.val)
      end
      insertFieldInfo(areaID, layerID, fieldData)
    end
    ::continue::
  end
  populateForestBrushes()
end

local function getLayerTypeStr(areaID, layerID)
  local layerName = ""
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID then
      for _, layer in ipairs(area.layers) do
        if layer.layerID == layerID then
          if layer.layerType == layerType_enum.lasso then
            layerName = "Lasso"
          elseif layer.layerType == layerType_enum.random then
            layerName = "Random"
          elseif layer.layerType == layerType_enum.terrain_mask then
            layerName = "Terrain Mask"
          elseif layer.layerType == layerType_enum.terrain_material then
            layerName = "Terrain Material"
          end
          break
        end
      end
      break
    end
  end
  return layerName
end

local function resetDrawActionVariables()
  var.shouldRenderCompletionSphere = false
  var.lassoSelectionEnded = false
  var.lassoSelectionItemsCalculated = false
  var.lassoPLNodes = {}
end

local function drawLassoPolylineAction()
  local numNodes = #var.lassoPLNodes
  var.shouldRenderCompletionSphere = false
  if var.lassoActionHoveredNodeIndex == 1 and numNodes > 2 then
    if var.lassoSelectionEnded then
      var.shouldRenderCompletionSphere = false;
    else
      if editor.keyModifiers.alt then
        var.shouldRenderCompletionSphere = true;
      else
        var.shouldRenderCompletionSphere = false;
      end
    end
  end

  -- draw cursor sphere
  if editor.keyModifiers.alt and not var.shouldRenderCompletionSphere then
    local hit
    if imgui.GetIO().WantCaptureMouse == false then
      hit = cameraMouseRayCast(false, imgui.flags(SOTTerrain))
    end
    if hit then
      local sphereRadius = (core_camera.getPosition() - hit.pos):length() * roadRiverGui.nodeSizeFactor
      debugDrawer:drawSphere(hit.pos, sphereRadius, roadRiverGui.highlightColors.node, false)
      if not tableIsEmpty(var.lassoPLNodes) then
        local tempNode = {pos = hit.pos, isUpdated = true}
        --vec3(itemPos.x, itemPos.y, itemPos.z
        drawLassoLineSegmented(var.drawActionAreaID, var.lassoPLNodes[numNodes], tempNode, var.lassoDrawInfo.type)
      end
    end
  end

  if tableIsEmpty(var.lassoPLNodes) then return end

  for index, node in ipairs(var.lassoPLNodes) do
    local nodeColor = roadRiverGui.highlightColors.node
    if var.lassoActionHoveredNodeIndex == index then
      nodeColor = roadRiverGui.highlightColors.hoveredNode
    elseif var.lassoActionSelectedNodeIndex == index then
      nodeColor = roadRiverGui.highlightColors.selectedNode
    end
    -- Skip first node if we should render completion sphere
    if index == 1 and var.shouldRenderCompletionSphere then
      goto continue
    else
      local sphereRadius = (core_camera.getPosition() - node.pos):length() * roadRiverGui.nodeSizeFactor
      debugDrawer:drawSphere(node.pos, sphereRadius, nodeColor, false)
    end
    if index > 1 then
      drawLassoLineSegmented(var.drawActionAreaID, var.lassoPLNodes[index - 1], node, var.lassoDrawInfo.type)
    end
    ::continue::
  end

  -- finally draw the closing line if selection ended
  if var.lassoSelectionEnded then
    drawLassoLineSegmented(var.drawActionAreaID, var.lassoPLNodes[numNodes], var.lassoPLNodes[1], var.lassoDrawInfo.type)
  end

  -- draw completion line and sphere
  if var.lassoSelectionEnded == false and editor.keyModifiers.alt then
    if var.shouldRenderCompletionSphere then
      local sphereRadius = (core_camera.getPosition() - var.lassoPLNodes[1].pos):length() * roadRiverGui.nodeSizeFactor * 2
      debugDrawer:drawSphere(var.lassoPLNodes[1].pos, sphereRadius,  ColorF(0,1,0,0.5), false)
      var.lassoPLNodes[1].isUpdated = true
      drawLassoLineSegmented(var.drawActionAreaID, var.lassoPLNodes[numNodes], var.lassoPLNodes[1], var.lassoDrawInfo.type)
    end
  end

  for _, node in ipairs(var.lassoPLNodes) do
    node.isUpdated = false
  end
end

local function getLassoNodes(areaID, layerID)
  local lassoNodes = {}
  local layers = getLayers(areaID)
  for _, layer in ipairs(layers) do
    if layer.layerType == layerType_enum.lasso and layer.layerID == layerID then
      for _, node in ipairs(layer.lassoNodes) do
        table.insert(lassoNodes, node.pos)
      end
      break
    end
  end
  return lassoNodes
end

local function drawLassoLayers(areaID)
  -- Draw Inclusion Zones
  local layers = getLayers(areaID)
  for _, layer in ipairs(layers) do
    if layer.layerType == layerType_enum.lasso then
      local numNodes = #layer.lassoNodes
      if numNodes == 0 then break end
      for index, node in ipairs(layer.lassoNodes) do
        local nodeColor = roadRiverGui.highlightColors.node
        if var.lassoHoveredNode.exZoneID == nil then
          if var.lassoHoveredNode.index == index and  var.lassoHoveredNode.layerID == layer.layerID then
            nodeColor = roadRiverGui.highlightColors.hoveredNode
          elseif var.lassoAreaSelectedNode.index == index and var.lassoAreaSelectedNode.layerID == layer.layerID then
            nodeColor = roadRiverGui.highlightColors.selectedNode
          end
        end
        local sphereRadius = (core_camera.getPosition() - node.pos):length() * roadRiverGui.nodeSizeFactor
        debugDrawer:drawSphere(node.pos, sphereRadius, nodeColor, false)

        if index > 1 then
          drawLassoLineSegmented(areaID, layer.lassoNodes[index - 1], node, var.enum_lassoDrawType.inclusionZone)
        end
      end
      -- finally draw the closing line
      drawLassoLineSegmented(areaID, layer.lassoNodes[numNodes], layer.lassoNodes[1], var.enum_lassoDrawType.inclusionZone)
      for _, node in ipairs(layer.lassoNodes) do
        node.isUpdated = false
      end
    end
  end

  -- Draw Exclusion Zones
  for _, zone in ipairs(var.areas.exclusionZones) do
    if zone.areaID == areaID then
      for _, zoneData in ipairs(zone.zoneData) do
        local zoneNodes = zoneData.nodes
        local numNodes = #zoneNodes
        if numNodes == 0 then break end
        for index, node in ipairs(zoneNodes) do
          local nodeColor = roadRiverGui.highlightColors.node
          if var.lassoHoveredNode.exZoneID == zoneData.ID and  var.lassoHoveredNode.layerID == zone.layerID and var.lassoHoveredNode.index == index then
            nodeColor = roadRiverGui.highlightColors.hoveredNode
          end

          local sphereRadius = (core_camera.getPosition() - node.pos):length() * roadRiverGui.nodeSizeFactor
          debugDrawer:drawSphere(node.pos, sphereRadius, nodeColor, false)

          if index > 1 then
            drawLassoLineSegmented(areaID, zoneNodes[index - 1], node, var.enum_lassoDrawType.exclusionZone)
          end
        end
        -- finally draw the closing line
        drawLassoLineSegmented(areaID, zoneNodes[numNodes], zoneNodes[1], var.enum_lassoDrawType.exclusionZone)
        for _, node in ipairs(zoneNodes) do
          node.isUpdated = false
        end
      end
    end
  end
end

local function changeAreaName(areaID, newName)
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if areaID == area.areaID then
      area.areaName = newName
      break
    end
  end
end

local function drawAreasList()
  imgui.Text("Areas")
  local flags = imgui.flags(imgui.WindowFlags_NoScrollWithMouse, imgui.WindowFlags_NoScrollbar, imgui.WindowFlags_ChildWindow)
  imgui.BeginChild1("AreasPanel", imgui.ImVec2(imgui.GetContentRegionAvail().x, 150), flags)
  if imgui.BeginPopupModal("Delete Area") then
    imgui.TextUnformatted("Are you sure you want to delete the area?")
    if imgui.Button("Cancel") then
      imgui.CloseCurrentPopup()
    end
    imgui.SameLine()
    if imgui.Button("OK") then
      for index, area in ipairs(var.areas.areaInfoTbl) do
          if var.selectedAreaID == area.areaID then
            table.remove(var.areas.areaInfoTbl, index)
          end
      end
      for index, area in ipairs(var.areas.fieldInfoTbl) do
        if var.selectedAreaID == area.areaID then
          table.remove(var.areas.fieldInfoTbl, index)
        end
      end
      var.selectedAreaID = nil
      imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
  end

  if imgui.BeginPopupModal("Create Area") then
    imgui.TextUnformatted("Please Select the Area type:")
    if imgui.RadioButton2("Terrain Material Area", selectAreaPopupIndex, 0) then
      selectAreaPopupIndex = imgui.IntPtr(0)
    end
    if imgui.RadioButton2("Lasso Area", selectAreaPopupIndex, 1) then
      selectAreaPopupIndex = imgui.IntPtr(1)
    end

    if imgui.Button("Cancel") then
      imgui.CloseCurrentPopup()
    end
    imgui.SameLine()

    editor_terrainEditor.updateMaterialLibrary()
    layerCreateMtlComboItemsTbl = {}

    if terrainBlock then
      local mtls = terrainBlock:getMaterials()
      for index, mtl in ipairs(mtls) do
        table.insert(layerCreateMtlComboItemsTbl, mtl.internalName)
      end
    end

    if imgui.Button("OK") then
      local area = {
        areaID    = var.areas.areaGlobalIndex,
        areaName = "Area",
        areaType = selectAreaPopupIndex[0] == 0 and areaType_enum.terrain_material or areaType_enum.lasso,
        layers = {},
        items = {},
        materialName = selectAreaPopupIndex[0] == 0 and layerCreateMtlComboItemsTbl[layerCreateMtlComboIndex[0] + 1] or nil
      }
      table.insert(var.areas.areaInfoTbl, area)
      var.selectedAreaID = area.areaID
      var.areas.areaGlobalIndex = var.areas.areaGlobalIndex + 1
      if selectAreaPopupIndex[0] == 0 then
        createLayerTypeIndex[0] = layerType_enum.terrain_material
      else
        createLayerTypeIndex[0] = layerType_enum.lasso
      end
      imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
  end

  if imgui.Button("Create Area") then
    imgui.OpenPopup("Create Area")
    --[[
    local area = {
      areaID   = var.areas.areaGlobalIndex,
      areaName = "Area",
      areaType = selectAreaPopupIndex[0] == 0 and areaType_enum.terrain_material or areaType_enum.lasso,
      layers = {},
      items = {},
      materialName = selectAreaPopupIndex[0] == 0 and layerCreateMtlComboItemsTbl[layerCreateMtlComboIndex[0] + 1] or nil
    }
    table.insert(var.areas.areaInfoTbl, area)
    var.selectedAreaID = area.areaID
    var.areas.areaGlobalIndex = var.areas.areaGlobalIndex + 1
    createLayerTypeIndex[0] = layerType_enum.terrain_material
    ]]
  end
  imgui.SameLine()
  if var.selectedAreaID == nil then
    imgui.BeginDisabled()
  end

  if imgui.Button("Delete Area") then
    imgui.OpenPopup("Delete Area")
  end

  if var.selectedAreaID == nil then
    imgui.EndDisabled()
  end

  editor.uiInputText('', searchText)
  imgui.SameLine()
  if imgui.SmallButton("x") then
    searchText = imgui.ArrayChar(256, '')
  end
  imgui.Separator()
  local filter = string.lower(ffi.string(searchText))
  if filter == '' then
  end

  local renderAreaNameFunc = function(area, index)
    local areaTypeStr = (area.areaType == areaType_enum.terrain_material) and "Terrain Material" or "Lasso"
    if editAreaIndex == index then
      ffi.copy(renameTextValue, area.areaName)
      editor.uiInputText("", renameTextValue, ffi.sizeof(renameTextValue), imgui.InputTextFlags_AutoSelectAll, nil, nil, renameEditEnded)
      if renameEditEnded[0] then
        local newName = ffi.string(renameTextValue)
        changeAreaName(area.areaID, newName)
        editAreaIndex = nil
      end
    else
      if imgui.Selectable1(area.areaName.. " (".. areaTypeStr ..")##"..tostring(area.areaID), var.selectedAreaID == area.areaID) then
        editAreaIndex = (var.selectedAreaID == area.areaID) and index or nil
        var.selectedAreaID = area.areaID
        if area.areaType == areaType_enum.lasso then
          createLayerTypeIndex[0] = layerType_enum.lasso
        else
          local layersAvailable = not tableIsEmpty(getLayers(var.selectedAreaID))
          if layersAvailable then
            createLayerTypeIndex[0] = layerType_enum.random
          else
            createLayerTypeIndex[0] = layerType_enum.terrain_mask
          end
        end
      end
    end
  end

  imgui.BeginChild1("AreasList", imgui.ImVec2(imgui.GetContentRegionAvail().x, 80), imgui.WindowFlags_ChildWindow)
  for index, area in ipairs(var.areas.areaInfoTbl) do
    if string.find(string.lower(area.areaName), filter) then
      if var.selectedAreaID == area.areaID then imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(0, 1, 0, 0.5)) end
      renderAreaNameFunc(area, index)
      if var.selectedAreaID == area.areaID then imgui.PopStyleColor() end
    end
  end
  imgui.Separator()
  imgui.EndChild()
  imgui.EndChild()
end

local function getAreaName(areaID)
  local areaName = ""
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if areaID == area.areaID then
      areaName = area.areaName
      break
    end
  end
  return areaName
end

local function indexOf(table, value)
  if not table then return -1 end
  for i,v in ipairs(table) do
    if v == value then return i end
  end
  return -1
end

local function getLayerName(areaID, layerID)
  local layerName = ""
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if areaID == area.areaID then
      for _, layer in ipairs(area.layers) do
        if layerID == layer.layerID then
          layerName = layer.name
        end
      end
    end
  end
  return layerName
end

local function isForestBrushSelected(areaID, layerID, internalName, zoneType)
  local selected = false
  for _, selectedItemsInfo in ipairs(var.areas.forestBrushSelectedItems) do
    if selectedItemsInfo.areaID == areaID and selectedItemsInfo.layerID == layerID  and
      selectedItemsInfo.zoneType == (zoneType or enum_forestBrushItemZone.central) then
      selected = (indexOf(selectedItemsInfo.selectedItems, internalName) ~= -1)
      break
    end
  end
  return selected
end

local function getForestBrushSelection(areaID, layerID, zoneType)
  local selectionInfo = {}
  if isForestBrushSelected(areaID, layerID, noneBrushItemName, zoneType) then
    return selectionInfo
  end
  for _, selectedItemsInfo in ipairs(var.areas.forestBrushSelectedItems) do
    if selectedItemsInfo.areaID == areaID and selectedItemsInfo.layerID == layerID and
       selectedItemsInfo.zoneType == (zoneType or enum_forestBrushItemZone.central) then
        selectionInfo = selectedItemsInfo.selectedItems
      break
    end
  end
  return selectionInfo
end

local function deselectForestBrush(areaID, layerID, internalName, zoneType)
  for _, selectedItemsInfo in ipairs(var.areas.forestBrushSelectedItems) do
    if selectedItemsInfo.areaID == areaID and selectedItemsInfo.layerID == layerID  and
      selectedItemsInfo.zoneType == (zoneType or enum_forestBrushItemZone.central) then
      local index = indexOf(selectedItemsInfo.selectedItems, internalName)
      if index ~= -1 then
        table.remove(selectedItemsInfo.selectedItems, index)
      end
      break
    end
  end
end

local function clearForestBrushSelection(areaID, layerID, zoneType)
  for _, selectedItemsInfo in ipairs(var.areas.forestBrushSelectedItems) do
    if selectedItemsInfo.areaID == areaID and selectedItemsInfo.layerID == layerID  and
      selectedItemsInfo.zoneType == (zoneType or enum_forestBrushItemZone.central) then
      selectedItemsInfo.selectedItems = {}
      break
    end
  end
end

local function getElementsForBrush(brushName)
  local forestBrushElements = {}
  local forestBrushElementIds = scenetree.findClassObjects("ForestBrushElement")
  for _, id in ipairs(forestBrushElementIds) do
    local fbe = scenetree.findObject(id)
    if fbe then
      local groupName = fbe:getGroup():getInternalName()
      if groupName == brushName then
        local fbeName = fbe:getInternalName()
        forestBrushElements[fbe:getId()] = fbeName
      end
    else
      editor.logWarn("Missing forest brush element ID: " .. tostring(id))
    end
  end
  return forestBrushElements
end

local function getForestBrushElementsFromSelection(areaID, layerID, zoneType)
  local forestBrushElements = {}
  local brushSelection = getForestBrushSelection(areaID, layerID, zoneType)
  for _, brushName in ipairs(brushSelection) do
    local elements = getElementsForBrush(brushName)
    for id, elementName in pairs(elements) do
      forestBrushElements[id] = elementName
    end
  end
  return forestBrushElements
end

local function getForestDensity(areaID, layerID)
  local density = nil
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "ForestDensity"then
          density = fieldData.val
          break
        end
      end
      break
    end
  end
  return density
end

local function getBorderDensity(areaID, layerID)
  local density = nil
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "BordersDensity"then
          density = fieldData.val
          break
        end
      end
      break
    end
  end
  return density
end

local function getForestBorderFallOff(areaID, layerID)
  local density = nil
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "BordersFalloff"then
          density = fieldData.val
          break
        end
      end
      break
    end
  end
  return density
end

local function getForestVegetationFallOff(areaID, layerID)
  local density = nil
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "VegetationFalloff"then
          density = fieldData.val
          break
        end
      end
      break
    end
  end
  return density
end

local function removeItemsActionUndo(actionData)
  for _, item in ipairs(actionData.items) do
    editor.addForestItem(var.forestData, item)
  end
end

local function removeItemsActionRedo(actionData)
  for _, item in ipairs(actionData.items) do
    editor.removeForestItem(forest:getData(), item)
  end
end

local function removeItems(items)
  if tableIsEmpty(items) then return end
  editor.history:commitAction("RemoveForestItems", {items = items}, removeItemsActionUndo, removeItemsActionRedo)
end

local function setFieldValue(fieldName, fieldValue, customData)
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == customData.areaID and item.layerID == customData.layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == fieldName then
          local clampedValue = clamp(fieldValue, fieldData.minValue or -math.huge, fieldData.maxValue or math.huge)
          fieldData.val = clampedValue
        end
      end
    end
  end
end

local function pasteLayerFieldValue(fieldName, copiedValue, arrayIndex, customData)
  local clampedValue = clamp(copiedValue, customData.minValue or -math.huge, customData.maxValue or math.huge)
  setFieldValue(fieldName, clampedValue, customData)
end

local function isExclusionZoneSelected(areaID, layerID, zoneID)
  for _, zone in ipairs(var.areas.exclusionZones) do
    if zone.areaID == areaID and zone.layerID == layerID then
      for _, zoneData in ipairs(zone.zoneData) do
        if zoneData.ID == zoneID then
          return zoneData.isSelected
        end
      end
    end
  end
  return false
end


local function isAnyZoneSelected(areaID, layerID)
  for _, zone in ipairs(var.areas.exclusionZones) do
    if zone.areaID == areaID and zone.layerID == layerID then
      for _, zoneData in ipairs(zone.zoneData) do
        if zoneData.isSelected then
          return zoneData.isSelected
        end
      end
    end
  end
  return false
end

local function setZoneSelected(areaID, layerID, zoneID, select)
  for _, zone in ipairs(var.areas.exclusionZones) do
    if zone.areaID == areaID and zone.layerID == layerID then
      for _, zoneData in ipairs(zone.zoneData) do
        if zoneData.ID == zoneID then
          zoneData.isSelected = select
        end
      end
    end
  end
end

local function deselectExclusionZone(areaID, layerID, zoneID)
  setZoneSelected(areaID, layerID, zoneID, false)
end

local function selectExclusionZone(areaID, layerID, zoneID)
  setZoneSelected(areaID, layerID, zoneID, true)
end


local function clearExZoneSelection(areaID, layerID)
  for _, zone in ipairs(var.areas.exclusionZones) do
    if zone.areaID == areaID and zone.layerID == layerID then
      for _, zoneData in ipairs(zone.zoneData) do
        zoneData.isSelected = false
      end
    end
  end
end

-- Add Items
local function addItemsActionUndo(actionData)
  for _, item in ipairs(actionData.items) do
    editor.removeForestItem(var.forestData, item)
  end
end

local function addItemsActionRedo(actionData)
  for _, item in ipairs(actionData.items) do
    editor.addForestItem(var.forestData, item)
  end
end

local function replaceItemsActionUndo(actionData)
  for _, item in ipairs(actionData.newItems) do
    editor.removeForestItem(var.forestData, item)
  end
  for _, item in ipairs(actionData.oldItems) do
    editor.addForestItem(var.forestData, item)
  end
end

local function replaceItemsActionRedo(actionData)
  for _, item in ipairs(actionData.oldItems) do    
    editor.removeForestItem(var.forestData, item)
    print("remove Forest item")
  end
  for _, item in ipairs(actionData.newItems) do
    editor.addForestItem(var.forestData, item)
  end
end

local function getBlendingMethod(areaID, layerID)
  local blendingMethodPtr = 0
  local itemFound = false
  for _, blendingData in ipairs(var.areas.layerBlendingComboIndexTbl) do
    if blendingData.areaID == areaID and blendingData.layerID == layerID then
      blendingMethodPtr = blendingData.blendingMethod
      itemFound = true
      break
    end
  end
  if not itemFound then
    table.insert(var.areas.layerBlendingComboIndexTbl, {areaID = areaID, layerID = layerID, blendingMethod = lassoBlending_enum.add})
  end
  return blendingMethodPtr
end

local function setBlendingMethod(areaID, layerID, method)
  local itemFound = false
  for _, blendingData in ipairs(var.areas.layerBlendingComboIndexTbl) do
    if blendingData.areaID == areaID and blendingData.layerID == layerID then
      blendingData.blendingMethod = method
      itemFound = true
      break
    end
  end
  if not itemFound then
    table.insert(var.areas.layerBlendingComboIndexTbl, {areaID = areaID, layerID = layerID, blendingMethod = method})
  end
end

local function getForestDensity(areaID, layerID)
  local density = nil
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "ForestDensity"then
          density = fieldData.val
          break
        end
      end
      break
    end
  end
  return density
end

local function getSlopeRange(areaID, layerID)
  local slopeRange = {0, 90}
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "SlopeRange"then
          slopeRange = fieldData.val
          break
        end
      end
      break
    end
  end
  return slopeRange
end

local function setSlopeRange(areaID, layerID, range)
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "SlopeRange"then
          fieldData.val = range
          break
        end
      end
      break
    end
  end
end

local function getSlopeInfluence(areaID, layerID)
  local slopeInfluence = 0
  for _, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        if fieldData.name == "SlopeInfluence"then
          slopeInfluence = fieldData.val
          break
        end
      end
      break
    end
  end
  return slopeInfluence
end

local function drawLayerPanel(areaID, layerID)
  local layer = getLayer(areaID, layerID)

  imgui.BeginChild1("LayerActionsPanel"..layerID, imgui.ImVec2(imgui.GetContentRegionAvail().x, 40 * imgui.uiscale[0]), imgui.WindowFlags_ChildWindow)
  imgui.Text("Actions: ")
  imgui.SameLine()
--[[if imgui.Button("Delete Items") then
    local lassoNodes2D = {}
    var.itemsToDelete = {}
    local lassoNodes = getLassoNodes(areaID, layerID)
    for _, node in ipairs(lassoNodes) do
      table.insert(lassoNodes2D, Point2F(node.x, node.y))
    end

    local forestItems = var.forestData:getItemsPolygon(lassoNodes2D)
    if not forestItems then return end
    var.itemsToDelete = forestItems
    imgui.OpenPopup("Delete Items")
  end
  if imgui.BeginPopupModal("Delete Items") then
    imgui.TextUnformatted("Are you sure you want to delete \n forest items inside the area?")
    if imgui.Button("Cancel") then
      imgui.CloseCurrentPopup()
    end
    imgui.SameLine()
    if imgui.Button("OK") then
      removeItems(var.itemsToDelete)
      imgui.CloseCurrentPopup()
    end
    imgui.EndPopup()
  end
  imgui.SameLine()
--]]


  --if tableIsEmpty(centralElements) then
   -- imgui.BeginDisabled()
  --end
  if imgui.Button("Conform to Terrain ##"..tostring(areaID)..tostring(layerID)) then
    local centralElements = getForestBrushElementsFromSelection(areaID, layerID)
    local falloffElements = getForestBrushElementsFromSelection(areaID, layerID, enum_forestBrushItemZone.falloff)
    local lassoNodes = getLassoNodes(areaID, layerID)
    local forestDensity = getForestDensity(areaID, layerID) or 1.0
    local borderFallOff = getForestBorderFallOff(areaID, layerID) or 1.0
    local borderDensity = getBorderDensity(areaID, layerID) or 1.0
    local vegetationFalloff = getForestVegetationFallOff(areaID, layerID) or 1.0
    local slopeInfluence = getSlopeInfluence(areaID, layerID) or 0
    local slopeRange = getSlopeRange(areaID, layerID) or {0, 90}
    local slopeVal = {slopeInfluence, slopeRange}
    local exclusionZones = {}
    for _, zone in ipairs(var.areas.exclusionZones) do
      if zone.areaID == var.lassoDrawInfo.areaID and zone.layerID == var.lassoDrawInfo.layerID then
        for _, data in ipairs(zone.zoneData) do
          local nodes = {}
          for _, node in ipairs(data.nodes) do
            table.insert(nodes, node.pos)
          end
            table.insert(exclusionZones, nodes)
        end
      end
    end

    local items = {}
    if getAreaType(areaID) == areaType_enum.terrain_material then
      if getLayerType(areaID, layerID) == layerType_enum.terrain_mask then
        items = var.forestBrushTool:fillBiomeMaterialArea(layer.maskFilePath, -1, lassoNodes, centralElements, falloffElements, exclusionZones or {}, forestDensity, borderFallOff, vegetationFalloff, borderDensity, slopeVal)
      else
        items = var.forestBrushTool:fillBiomeMaterialArea("", areaMaterialIndex, lassoNodes, centralElements, falloffElements, exclusionZones or {}, forestDensity, borderFallOff, vegetationFalloff, borderDensity, slopeVal)
      end
      if not tableIsEmpty(items) then
        editor.history:commitAction("AddForestItems", {items = items}, addItemsActionUndo, addItemsActionRedo, true)
      end
    elseif getAreaType(areaID) == areaType_enum.lasso then
      local blendingMethod = getBlendingMethod(areaID, layerID)
      if blendingMethod == lassoBlending_enum.add then
        items = var.forestBrushTool:fillBiomeLassoArea(lassoNodes, centralElements, falloffElements, exclusionZones or {}, forestDensity, borderFallOff, vegetationFalloff, borderDensity, slopeVal)
        if not tableIsEmpty(items) then
          editor.history:commitAction("AddForestItems", {items = items}, addItemsActionUndo, addItemsActionRedo, true)
        end
      elseif blendingMethod == lassoBlending_enum.delete then
        local lassoNodes2D = {}
        var.itemsToDelete = {}
        local lassoNodes = getLassoNodes(areaID, layerID)
        for _, node in ipairs(lassoNodes) do
          table.insert(lassoNodes2D, Point2F(node.x, node.y))
        end
        local forestItems = var.forestData:getItemsPolygon(lassoNodes2D)
        if not forestItems then return end
        var.itemsToDelete = forestItems
        removeItems(var.itemsToDelete)
      elseif blendingMethod == lassoBlending_enum.replace then
        local lassoNodes2D = {}
        local lassoNodes = getLassoNodes(areaID, layerID)
        for _, node in ipairs(lassoNodes) do
          table.insert(lassoNodes2D, Point2F(node.x, node.y))
        end
        local itemsToDelete = var.forestData:getItemsPolygon(lassoNodes2D)
        local eraseExistingItems = true
        local newForestItems = var.forestBrushTool:fillBiomeLassoArea(lassoNodes, centralElements, falloffElements, exclusionZones or {}, forestDensity, borderFallOff, vegetationFalloff, borderDensity, eraseExistingItems)
        editor.history:commitAction("ReplaceForestItems", {oldItems = itemsToDelete, newItems = newForestItems}, replaceItemsActionUndo, replaceItemsActionRedo, true)
      end
    end
  end
  --if tableIsEmpty(elements) then
  --  imgui.EndDisabled()
  --end
imgui.EndChild()
  imgui.Columns(2, layerID .. "LayersColumn")
  imgui.BeginChild1("LayerMainPanel"..layerID, imgui.ImVec2(imgui.GetContentRegionAvail().x, 240 * imgui.uiscale[0]), imgui.WindowFlags_ChildWindow)
  imgui.Text("Layer Properties:")
  imgui.BeginChild1("LayerPanel"..layerID, imgui.ImVec2(imgui.GetContentRegionAvail().x, 180 * imgui.uiscale[0]), imgui.WindowFlags_ChildWindow)
  for index, item in ipairs(var.areas.fieldInfoTbl) do
    if item.areaID == areaID and item.layerID == layerID then
      for _, fieldData in ipairs(item.fieldsData) do
        valueInspector:valueEditorGui(fieldData.name, tostring(fieldData.val) or "", index,      fieldData.label, nil,       fieldData.type or "", fieldData.type or "", {areaID = item.areaID, layerID = item.layerID}, pasteLayerFieldValue, nil)
        imgui.Separator()
        imgui.NextColumn()
      end
      break
    end
  end
  imgui.EndChild()
  imgui.EndChild()

  imgui.NextColumn()

  imgui.BeginChild1("LayerForestBrushesFrame"..layerID..areaID, imgui.ImVec2(imgui.GetContentRegionAvail().x,  240 * imgui.uiscale[0]), true, imgui.WindowFlags_ChildWindow)
  imgui.Columns(3, layerID .. "BrushesColumn")
  imgui.Text("Forest Brushes (Central):")
  imgui.BeginChild1("LayerForestBrushes"..layerID..areaID, imgui.ImVec2(imgui.GetContentRegionAvail().x, 180 * imgui.uiscale[0]), imgui.WindowFlags_ChildWindow)

  imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1, 0, 0, 1))
  imgui.PushStyleColor2(imgui.Col_Button, (isForestBrushSelected(areaID, layerID, noneBrushItemName)) and var.buttonColor_active or var.buttonColor_inactive)
  editor.uiIconImage(editor.icons.forest_brushelement, imgui.ImVec2(math.ceil(imgui.GetFontSize()), math.ceil(imgui.GetFontSize())))
  imgui.SameLine()
  local textPos = imgui.GetCursorPos()
  if imgui.Button("##NoneCentral", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), math.ceil(imgui.GetFontSize()))) then
    clearForestBrushSelection(areaID, layerID)
    selectForestBrush(areaID, layerID, noneBrushItemName)
  end
  imgui.SetCursorPos(textPos)
  imgui.Text("- NONE -")
  imgui.PopStyleColor()
  imgui.PopStyleColor()

  for index, item in ipairs(var.forestBrushes) do
    imgui.PushStyleColor2(imgui.Col_Button, (isForestBrushSelected(areaID, layerID, item.internalName)) and var.buttonColor_active or var.buttonColor_inactive)
    editor.uiIconImage(editor.icons.forest_brushelement, imgui.ImVec2(math.ceil(imgui.GetFontSize()), math.ceil(imgui.GetFontSize())))
    imgui.SameLine()
    local textPos = imgui.GetCursorPos()
    if imgui.Button("##"..item.internalName, imgui.ImVec2(imgui.GetContentRegionAvailWidth(), math.ceil(imgui.GetFontSize()))) then
      if editor.keyModifiers.ctrl then
        if isForestBrushSelected(areaID, layerID, item.internalName) then
          deselectForestBrush(areaID, layerID, item.internalName)
        else
          selectForestBrush(areaID, layerID, item.internalName)
          deselectForestBrush(areaID, layerID, noneBrushItemName)
        end
      else
        clearForestBrushSelection(areaID, layerID)
        selectForestBrush(areaID, layerID, item.internalName)
        deselectForestBrush(areaID, layerID, noneBrushItemName)
      end
    end
    imgui.SetCursorPos(textPos)
    imgui.Text(item.internalName)
    imgui.PopStyleColor()
  end
  imgui.EndChild()

  imgui.NextColumn()
  imgui.Text("Forest Brushes (Falloff):")
  imgui.BeginChild1("LayerFalloffForestBrushes"..layerID..areaID, imgui.ImVec2(imgui.GetContentRegionAvail().x, 180 * imgui.uiscale[0]), imgui.WindowFlags_ChildWindow)

  imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1, 0, 0, 1))
  imgui.PushStyleColor2(imgui.Col_Button, (isForestBrushSelected(areaID, layerID, noneBrushItemName, enum_forestBrushItemZone.falloff)) and var.buttonColor_active or var.buttonColor_inactive)
  editor.uiIconImage(editor.icons.forest_brushelement, imgui.ImVec2(math.ceil(imgui.GetFontSize()), math.ceil(imgui.GetFontSize())))
  imgui.SameLine()
  local textPos = imgui.GetCursorPos()
  if imgui.Button("##NoneCentral", imgui.ImVec2(imgui.GetContentRegionAvailWidth(), math.ceil(imgui.GetFontSize()))) then
    clearForestBrushSelection(areaID, layerID, enum_forestBrushItemZone.falloff)
    selectForestBrush(areaID, layerID, noneBrushItemName, enum_forestBrushItemZone.falloff)
  end
  imgui.SetCursorPos(textPos)
  imgui.Text("- NONE -")
  imgui.PopStyleColor()
  imgui.PopStyleColor()

  for index, item in ipairs(var.forestBrushes) do
    imgui.PushStyleColor2(imgui.Col_Button, (isForestBrushSelected(areaID, layerID, item.internalName, enum_forestBrushItemZone.falloff)) and var.buttonColor_active or var.buttonColor_inactive)
    editor.uiIconImage(editor.icons.forest_brushelement, imgui.ImVec2(math.ceil(imgui.GetFontSize()), math.ceil(imgui.GetFontSize())))
    imgui.SameLine()
    local textPos = imgui.GetCursorPos()
    if imgui.Button("##Falloff"..item.internalName, imgui.ImVec2(imgui.GetContentRegionAvailWidth(), math.ceil(imgui.GetFontSize()))) then
      if editor.keyModifiers.ctrl then
        if isForestBrushSelected(areaID, layerID, item.internalName, enum_forestBrushItemZone.falloff) then
          deselectForestBrush(areaID, layerID, item.internalName, enum_forestBrushItemZone.falloff)
        else
          selectForestBrush(areaID, layerID, item.internalName, enum_forestBrushItemZone.falloff)
          deselectForestBrush(areaID, layerID, noneBrushItemName, enum_forestBrushItemZone.falloff)
        end
      else
        clearForestBrushSelection(areaID, layerID, enum_forestBrushItemZone.falloff)
        selectForestBrush(areaID, layerID, item.internalName, enum_forestBrushItemZone.falloff)
        deselectForestBrush(areaID, layerID, noneBrushItemName, enum_forestBrushItemZone.falloff)
      end
    end
    imgui.SetCursorPos(textPos)
    imgui.Text(item.internalName)
    imgui.PopStyleColor()
  end
  imgui.EndChild()

  imgui.NextColumn()
  imgui.Text("Exclusion Zones:")
  imgui.BeginChild1("LayerExclusionZones"..tostring(layerID)..tostring(areaID), imgui.ImVec2(imgui.GetContentRegionAvail().x, 180 * imgui.uiscale[0]), imgui.WindowFlags_ChildWindow)
    for _, zoneItem in ipairs(var.areas.exclusionZones) do
      if zoneItem.areaID == areaID and zoneItem.layerID == layerID then
        for _, zoneData in ipairs(zoneItem.zoneData) do
          local isZoneSelected = isExclusionZoneSelected(zoneItem.areaID, zoneItem.layerID, zoneData.ID)
          imgui.PushStyleColor2(imgui.Col_Button, isZoneSelected and var.buttonColor_active or var.buttonColor_inactive)
          editor.uiIconImage(editor.icons.branding_watermark, imgui.ImVec2(math.ceil(imgui.GetFontSize()), math.ceil(imgui.GetFontSize())))
          imgui.SameLine()
          local textPos = imgui.GetCursorPos()
          if imgui.Button("##".."Zone "..tostring(zoneData.ID), imgui.ImVec2(imgui.GetContentRegionAvailWidth(), math.ceil(imgui.GetFontSize()))) then
            if editor.keyModifiers.ctrl then
              if isZoneSelected then
                deselectExclusionZone(areaID, layerID, zoneData.ID)
              else
                selectExclusionZone(areaID, layerID, zoneData.ID)
              end
            else
              clearExZoneSelection(areaID, layerID)
              selectExclusionZone(areaID, layerID, zoneData.ID)
            end
          end
          imgui.SetCursorPos(textPos)
          imgui.Text("Zone "..tostring(zoneData.ID))
          imgui.PopStyleColor()
        end
      end
    end

  imgui.EndChild()

  local shouldDisableDel = not isAnyZoneSelected(areaID, layerID)
  if shouldDisableDel then
    imgui.BeginDisabled()
  end
  if imgui.Button("Delete Zone") then
    deleteExZone(areaID, layerID)
  end
  if shouldDisableDel then
    imgui.EndDisabled()
  end

  imgui.SameLine()
  if var.lassoDrawInfo.type == var.enum_lassoDrawType.exclusionZone then
    imgui.BeginDisabled()
  end
  if imgui.Button("Create Zone") then
    var.lassoDrawInfo.areaID = areaID
    var.lassoDrawInfo.layerID = layerID
    var.lassoDrawInfo.type = var.enum_lassoDrawType.exclusionZone
    isDrawingLassoArea = true
  end
  if var.lassoDrawInfo.type == var.enum_lassoDrawType.exclusionZone then
    imgui.EndDisabled()
    imgui.SameLine()
    local noAreaText = "Now please draw the exclusion lasso area!"
    imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1, 0, 0, 1));
    imgui.Text(noAreaText)
    imgui.PopStyleColor()
  end

  imgui.EndChild()


  imgui.Columns(1)
end

local function getLayerIDByIndex(areaID, layerIndex)
  local layerID = nil
  for _, area in ipairs(var.areas.areaInfoTbl) do
    if area.areaID == areaID and area.layers[layerIndex] then
      layerID = area.layers[layerIndex].layerID
      break
    end
  end
  return layerID
end

local function drawLayersList(areaID)
  if imgui.CollapsingHeader1("Edit Layers", imgui.TreeNodeFlags_DefaultOpen) then
    imgui.BeginChild1("CreateLayer", imgui.ImVec2(imgui.GetContentRegionAvail().x, 160), imgui.WindowFlags_ChildWindow)
    imgui.Text("Create Layer:")
    imgui.SameLine()
    local xPos = imgui.GetCursorPos().x

    local layersAvailable = not tableIsEmpty(getLayers(var.selectedAreaID))
    if not layersAvailable and getAreaType(var.selectedAreaID) == areaType_enum.terrain_material then
      imgui.BeginDisabled()
    end
    
    if getAreaType(var.selectedAreaID) ~= areaType_enum.terrain_material then
      if imgui.RadioButton2("Lasso", createLayerTypeIndex, layerType_enum.lasso) then
        createLayerTypeIndex[0] = layerType_enum.lasso
      end
    end
    if not layersAvailable and getAreaType(var.selectedAreaID) == areaType_enum.terrain_material then
      imgui.EndDisabled()
    end

    if getAreaType(var.selectedAreaID) == areaType_enum.terrain_material then
      imgui.SetCursorPosX(xPos)
      if layersAvailable then
        imgui.BeginDisabled()
      end
      if imgui.RadioButton2("Terrain Material", createLayerTypeIndex, layerType_enum.terrain_material) then
        createLayerTypeIndex[0] = layerType_enum.terrain_material
        layerCreateMtlComboItemsTbl = {}
        if terrainBlock then
          local mtls = terrainBlock:getMaterials()
          for index, mtl in ipairs(mtls) do
            table.insert(layerCreateMtlComboItemsTbl, mtl.internalName)
          end
        end
      end

      if createLayerTypeIndex[0] ~= layerType_enum.terrain_material then
        imgui.BeginDisabled()
      end

      layerCreateMtlComboItems = imgui.ArrayCharPtrByTbl(layerCreateMtlComboItemsTbl)
      imgui.SameLine()
      local comboXPos = imgui.GetCursorPos().x
      if imgui.Combo1("##terrainmaterials", layerCreateMtlComboIndex, layerCreateMtlComboItems) then
      end

      if createLayerTypeIndex[0] ~= layerType_enum.terrain_material then
        imgui.EndDisabled()
      end


      imgui.SetCursorPosX(xPos)
      if imgui.RadioButton2("Terrain Mask", createLayerTypeIndex, layerType_enum.terrain_mask) then
        createLayerTypeIndex[0] = layerType_enum.terrain_mask
      end

      if createLayerTypeIndex[0] ~= layerType_enum.terrain_mask then
        imgui.BeginDisabled()
      end
      imgui.SameLine()
      imgui.SetCursorPosX(comboXPos)

      imgui.InputText("##SearchPaths", maskFilePath, nil, imgui.InputTextFlags_ReadOnly)
      imgui.SameLine()
      if editor.uiIconImageButton(
        editor.icons.folder,
        imgui.ImVec2(22, 22)
      ) then
        editor_fileDialog.openFile(
          function(data)
            maskFilePath = imgui.ArrayChar(256, data.filepath)
          end,
          {{"Images",{".png", ".jpg"}},{"PNG", ".png"}, {"JPG", ".jpg"}},
          false, "/")
      end
      if createLayerTypeIndex[0] ~= layerType_enum.terrain_mask then
        imgui.EndDisabled()
      end

      if layersAvailable then
        imgui.EndDisabled()
      end

      imgui.SetCursorPosX(xPos)
      if not layersAvailable or true then
        imgui.BeginDisabled()
      end
      if imgui.RadioButton2("Random", createLayerTypeIndex, layerType_enum.random) then
        createLayerTypeIndex[0] = layerType_enum.random
      end
      if not layersAvailable or true then
        imgui.EndDisabled()
      end
    end

    imgui.SetCursorPosX(xPos)

    if isDrawingLassoArea then
      imgui.BeginDisabled()
    end
    if imgui.Button("Create Layer") then
      if terrainBlock then
        local mtls = terrainBlock:getMaterials()
        for index, mtl in ipairs(mtls) do
          if selectAreaPopupIndex[0] == 0 and layerCreateMtlComboItemsTbl[layerCreateMtlComboIndex[0] + 1] == mtl.internalName then
            areaMaterialIndex = index-1
          end
        end
      end

      local materialName = nil
      if getAreaType(var.selectedAreaID) == areaType_enum.terrain_material then
        materialName = layerCreateMtlComboItemsTbl[layerCreateMtlComboIndex[0] + 1]
      else
        materialName = "-"
      end

      if #getLayers(var.selectedAreaID) == 1 then
        createLayerTypeIndex[0] = layerType_enum.lasso
      end

      if createLayerTypeIndex[0] == layerType_enum.terrain_material then
        addLayer(var.selectedAreaID, createLayerTypeIndex[0], materialName, nil, nil)
      elseif createLayerTypeIndex[0] == layerType_enum.terrain_mask then
        addLayer(var.selectedAreaID, createLayerTypeIndex[0], nil, nil, ffi.string(maskFilePath))
      else
        isDrawingLassoArea = true
        var.lassoDrawInfo.type = var.enum_lassoDrawType.inclusionZone
      end
    end

    if isDrawingLassoArea then
      imgui.EndDisabled()
      imgui.SameLine()
      local noAreaText = "Now please draw the lasso selection!"
      imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1, 0, 0, 1));
      imgui.Text(noAreaText)
      imgui.PopStyleColor()
    end
    imgui.EndChild()

    imgui.BeginChild1("DeleteLayer", imgui.ImVec2(imgui.GetContentRegionAvail().x, 80), imgui.WindowFlags_ChildWindow)
    imgui.Text("Delete Layer:")
    local noLayers = tableIsEmpty(getLayers(var.selectedAreaID))
    if noLayers then
      imgui.BeginDisabled()
    end
    imgui.SameLine()

    layerDeleteMtlComboItemsTbl = {}
    for _, layer in ipairs(getLayers(var.selectedAreaID)) do
      table.insert(layerDeleteMtlComboItemsTbl, layer.layerName)
    end

    layerDeleteMtlComboItems = imgui.ArrayCharPtrByTbl(layerDeleteMtlComboItemsTbl)
    imgui.Combo1("##layersDelete", layerDeleteComboIndex, layerDeleteMtlComboItems)

    imgui.SameLine()
    if imgui.Button("Delete Layer") then
      imgui.OpenPopup("Delete Layer")
    end

    if imgui.BeginPopupModal("Delete Layer") then
      local layerName = layerDeleteMtlComboItemsTbl[layerDeleteComboIndex[0] + 1]
      imgui.TextUnformatted("Are you sure you want to delete \""..layerName.."\"?")
      if imgui.Button("Cancel") then
        imgui.CloseCurrentPopup()
      end
      imgui.SameLine()
      if imgui.Button("OK") then
        deleteLayer(var.selectedAreaID, getLayerIDByIndex(var.selectedAreaID, layerDeleteComboIndex[0] + 1))
        imgui.CloseCurrentPopup()
      end
      imgui.EndPopup()
    end

    if noLayers then
      imgui.EndDisabled()
    end
    imgui.EndChild()
  end

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
  local filter = ""

  if imgui.CollapsingHeader1("Layers in "..getAreaName(var.selectedAreaID), imgui.TreeNodeFlags_DefaultOpen) then
    imgui.BeginChild1("LayersList", imgui.ImVec2(imgui.GetContentRegionAvail().x, imgui.GetContentRegionAvail().y - 4), imgui.WindowFlags_ChildWindow)
    if tableIsEmpty(getLayers(var.selectedAreaID)) then
      local noAreaText = "N O   L A Y E R S   I N   T H E   A R E A !"
      imgui.SetCursorPos(imgui.ImVec2(imgui.GetContentRegionAvail().x/2 - imgui.CalcTextSize(noAreaText).x/2, imgui.GetContentRegionAvail().y/2))
      imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1, 0, 0, 1));
      editor.uiTextColoredWithFont(imgui.ImVec4(1, 0, 0, 1), noAreaText, "cairo_bold")
      imgui.PopStyleColor()
    else
      for _, layer in ipairs(getLayers(var.selectedAreaID)) do
        if imgui.CollapsingHeader1(layer.layerName.." ("..getLayerTypeStr(var.selectedAreaID, layer.layerID)..")" .. '##', imgui.TreeNodeFlags_DefaultOpen) then
          drawLayerPanel(var.selectedAreaID, layer.layerID)
        end
      end
    end
    imgui.EndChild()
  end
end

local function setItemTransformUndo(actionData)
  for index, item in ipairs(actionData.items) do
    actionData.items[index] = editor.updateForestItem(var.forestData, item:getKey(), item:getPosition(), item:getData(), editor.tableToMatrix(actionData.oldTransforms[index]), item:getScale())
  end
end

local function setItemTransformRedo(actionData)
  for index, item in ipairs(actionData.items) do
    actionData.items[index] = editor.updateForestItem(var.forestData, item:getKey(), item:getPosition(), item:getData(), editor.tableToMatrix(actionData.newTransforms[index]), item:getScale())
  end
end

local function drawAreaPanel2(areaID)
  local areaType = getAreaType(areaID)
  local areaName = getAreaName(areaID)
  local areaTypeStr = areaType == areaType_enum.terrain_material and "Terrain Material" or "Lasso"
  imgui.Text(areaName.." ("..areaTypeStr..")")
  imgui.BeginChild1("ModifyPanel", imgui.ImVec2((imgui.GetContentRegionAvail().x - 6), imgui.GetContentRegionAvail().y -2), true)
  drawLayersList()
  imgui.EndChild()
end

local function drawAreaPanel(areaID)
  imgui.Text("Area "..tostring(var.selectedAreaID))
  imgui.BeginChild1("ModifyPanel", imgui.ImVec2((imgui.GetContentRegionAvail().x - 6), imgui.GetContentRegionAvail().y -2), true)

  local textSuffix = numOfItemsInArea and " ("..tostring(numOfItemsInArea)..")" or ""
  imgui.Text("Forest Items In Area"..textSuffix)
  imgui.SetCursorPos(cursorPos)

  local childFlags = bit.bor(imgui.WindowFlags_HorizontalScrollbar, imgui.WindowFlags_AlwaysVerticalScrollbar)
  imgui.BeginChild1("ItemsList", imgui.ImVec2(200, 400), true, childFlags)
  if editor.uiInputText('', searchText_Items_Modify) then
    resetSelectedItemIndices(selectedArea.areaID)
    resetSelectedGroupIndices(selectedArea.areaID)
  end
  imgui.SameLine()
  if imgui.SmallButton("x") then
    searchText_Items_Modify = imgui.ArrayChar(256, '')
  end

  selectAllBoolPtr[0] = var.selectAllEnabled
  groupItemsBoolPtr[0] = var.isGroupMeshesEnabled
  if imgui.Checkbox("##groupMeshesEnabled", groupItemsBoolPtr) then
    var.isGroupMeshesEnabled = groupItemsBoolPtr[0]
    if var.isGroupMeshesEnabled then
      groupItemsByMesh()
    end
  end
  imgui.SameLine()
  imgui.Text("Group Items")
  imgui.Separator()
  local modify_filter = string.lower(ffi.string(searchText_Items_Modify))
  if modify_filter == '' then
  end

  if selectedArea then
    if not var.groupSelectedIndices_Modify[selectedArea.areaID] then
      var.groupSelectedIndices_Modify[selectedArea.areaID] = {}
    end
    if not var.itemsSelectedIndices_Modify[selectedArea.areaID] then
      var.itemsSelectedIndices_Modify[selectedArea.areaID] = {}
    end
    if var.isGroupMeshesEnabled then
      for _, entryInfo in ipairs(var.lassoAreasGroupedMeshTable) do
        if entryInfo.areaID == selectedArea.areaID then
          for index, meshEntry in ipairs(entryInfo.meshEntries) do
            if string.find(string.lower(meshEntry.name), modify_filter) then
              if imgui.Selectable1(tostring(meshEntry.name).."("..tostring(meshEntry.count)..")"..'##'..tostring(index), indexOf(var.groupSelectedIndices_Modify[selectedArea.areaID], index) ~= -1) then
                if var.selectAllEnabled then
                  table.insert(var.groupSelectedIndices_Modify[selectedArea.areaID], index)
                else
                  if editor.keyModifiers.ctrl then
                    if indexOf(var.groupSelectedIndices_Modify[selectedArea.areaID], index) == -1 then
                      table.insert(var.groupSelectedIndices_Modify[selectedArea.areaID], index)
                    else
                      table.remove(var.groupSelectedIndices_Modify[selectedArea.areaID], index)
                    end
                  else
                    var.groupSelectedIndices_Modify[selectedArea.areaID] = {index}
                  end
                end
              end
            end
          end
          break
        end
      end
    else
      for index, item in ipairs(selectedArea.items) do
        if string.find(string.lower(item:getData():getName()), modify_filter) then
          if imgui.Selectable1(tostring(item:getData():getName()) .. '##'..tostring(index),indexOf(var.itemsSelectedIndices_Modify[selectedArea.areaID], index) ~= -1) then
            if editor.keyModifiers.ctrl then
              if indexOf(var.itemsSelectedIndices_Modify[selectedArea.areaID], index) == -1 then
                table.insert(var.itemsSelectedIndices_Modify[selectedArea.areaID], index)
              else
                table.remove(var.itemsSelectedIndices_Modify[selectedArea.areaID], index)
              end
            else
              var.itemsSelectedIndices_Modify[selectedArea.areaID] = {index}
            end

            if var.selectAllEnabled then
              table.insert(var.itemsSelectedIndices_Modify[selectedArea.areaID], index)
            end
          end
        end
      end
    end
  end
  imgui.Separator()
  imgui.EndChild()

  imgui.SetCursorPos(imgui.ImVec2(cursorPos.x + 206, cursorPos.y - fontSize))
  imgui.Text("Placement Constraints")
  imgui.SetCursorPos(imgui.ImVec2(cursorPos.x + 206, cursorPos.y))
  imgui.BeginChild1("PlacementConstraintsPanel ", imgui.ImVec2(200, 400), true)
  imgui.Text("Sink radius:")
  imgui.SameLine()
  editor.uiInputText('', sinkRadiusText)
  imgui.EndChild()

  imgui.SetCursorPos(imgui.ImVec2(cursorPos.x + 412 , cursorPos.y - fontSize))
  imgui.Text("Actions")
  imgui.SetCursorPos(imgui.ImVec2(cursorPos.x + 412 , cursorPos.y))

  local shouldDisableActionButtons = false

  if var.isGroupMeshesEnabled then
    if tableIsEmpty(var.groupSelectedIndices_Modify[var.selectedAreaID]) then
      shouldDisableActionButtons = true
    end
  else
    if tableIsEmpty(var.itemsSelectedIndices_Modify[var.selectedAreaID])then
      shouldDisableActionButtons = true
    end
  end

  if var.selectAllEnabled then
    shouldDisableActionButtons = false
  end

  imgui.BeginChild1("ActionsPanel ", imgui.ImVec2(200, 400), true)
  if shouldDisableActionButtons then
    imgui.BeginDisabled()
  end

  local shouldConform = false
  local conformSelected = false

  if imgui.Button("Conform To Terrain") then
    shouldConform = true
  end

  if shouldConform then
    local oldTransforms = {}
    local newTransforms = {}
    local itemsToModify = {}
    if selectedArea then
      if var.isGroupMeshesEnabled then
        for _, entryInfo in ipairs(var.lassoAreasGroupedMeshTable) do
          if entryInfo.areaID == selectedArea.areaID then
            for index, meshEntry in ipairs(entryInfo.meshEntries) do
              if arrayFindValueIndex(var.groupSelectedIndices_Modify[selectedArea.areaID], index) then
                for _, item in ipairs(selectedArea.items) do
                  if item:getData():getShapeFile() == meshEntry.shapeFilePath then
                    local itemPos = item:getPosition()
                    local objectTerrainHeight = core_terrain.getTerrainHeight(vec3(itemPos.x, itemPos.y, itemPos.z + 1000)) or 0
                    table.insert(oldTransforms, editor.matrixToTable(item:getTransform()))

                    local transform = MatrixF(true)
                    transform:setColumn4F(0, item:getTransform():getColumn4F(0))
                    transform:setColumn4F(1, item:getTransform():getColumn4F(1))
                    transform:setColumn4F(2, item:getTransform():getColumn4F(2))
                    transform:setPosition(vec3(itemPos.x, itemPos.y, objectTerrainHeight - tonumber(ffi.string(sinkRadiusText))))

                    table.insert(newTransforms, editor.matrixToTable(transform))
                    table.insert(itemsToModify, item)
                  end
                end
              end
            end
          end
        end
      else
        for index, item in ipairs(selectedArea.items) do
          if arrayFindValueIndex(var.itemsSelectedIndices_Modify[selectedArea.areaID], index) then
            local itemPos = item:getPosition()
            local objectTerrainHeight = core_terrain.getTerrainHeight(vec3(itemPos.x, itemPos.y, itemPos.z + 1000)) or 0
            table.insert(oldTransforms, editor.matrixToTable(item:getTransform()))

            local transform = MatrixF(true)
            transform:setColumn4F(0, item:getTransform():getColumn4F(0))
            transform:setColumn4F(1, item:getTransform():getColumn4F(1))
            transform:setColumn4F(2, item:getTransform():getColumn4F(2))
            transform:setPosition(vec3(itemPos.x, itemPos.y, objectTerrainHeight - tonumber(ffi.string(sinkRadiusText))))

            table.insert(newTransforms, editor.matrixToTable(transform))
            table.insert(itemsToModify, item)
          end
        end
      end
      editor.history:commitAction("ConformToTerrain", {items = itemsToModify, newTransforms = newTransforms, oldTransforms = oldTransforms}, setItemTransformUndo, setItemTransformRedo)
    end
  end

  imgui.tooltip("Conform Selected Items to Terrain")
  if imgui.Button("Delete Selected") then
    local delItems = {}
    if var.isGroupMeshesEnabled then
      for _, selectedGroupIndex in ipairs(var.groupSelectedIndices_Modify[selectedArea.areaID]) do
        local meshEntries = getGroupMeshEntriesForArea(selectedArea.areaID)
        for index, meshEntry in ipairs(meshEntries) do
          if selectedGroupIndex == index then
            for _, item in ipairs(selectedArea.items) do
              if item:getData():getShapeFile() == meshEntry.shapeFilePath then
                table.insert(delItems, item)
              end
            end
          end
        end
      end
    else
      for _, index in ipairs(var.itemsSelectedIndices_Modify[selectedArea.areaID]) do
        table.insert(delItems, selectedArea.items[index])
      end
    end

    removeItems(delItems)
    calculateLassoSelectionOnArea(selectedArea.areaID)
    var.itemsSelectedIndices_Modify[selectedArea.areaID] = {}
    var.groupSelectedIndices_Modify[selectedArea.areaID] = {}
  end
  if shouldDisableActionButtons then
    imgui.EndDisabled()
  end

  if var.selectedAreaID == nil then
    imgui.BeginDisabled()
  end

  if imgui.Button("Clear Area") then
    removeItems(selectedArea.items)
    calculateLassoSelectionOnArea(selectedArea.areaID)
  end
  if var.selectedAreaID == nil then
    imgui.EndDisabled()
  end
  imgui.EndChild()

  imgui.EndChild()
  imgui.SetCursorPos(imgui.ImVec2(cursorPos.x , imgui.GetCursorPos().y + fontSize))
  imgui.Text("Generate Area")
  imgui.BeginChild1("GeneratePanel", imgui.ImVec2((imgui.GetContentRegionAvail().x - 6), panelHeight), true)

  imgui.Text("Select Forest Meshes")
  imgui.SetCursorPos(imgui.ImVec2(cursorPos.x, cursorPos.y))
  imgui.BeginChild1("ItemsList", imgui.ImVec2(200 * imgui.uiscale[0], 400), true)

  editor.uiInputText('', searchText_Meshes_Generate)
  imgui.SameLine()
  if imgui.SmallButton("x") then
    searchText_Meshes_Generate = imgui.ArrayChar(256, '')
  end
  imgui.Separator()
  local generate_items_filter = string.lower(ffi.string(searchText_Meshes_Generate))
  for index, item in ipairs(var.forestItemData) do
    local obj = scenetree.findObjectById(item.id)
    if obj and string.find(string.lower(obj.name), generate_items_filter) then
      if imgui.Selectable1(obj.name .. '##'..tostring(index), false) then
      end
    end
  end
  imgui.EndChild()
end

local function drawWindow()
  if editor.beginWindow(toolWindowName, "Biome Tool") then
    local selectedArea = getAreaByID(var.selectedAreaID)
    drawAreasList()
    imgui.BeginChild1("MainPanel", imgui.GetContentRegionAvail(), true)

    if var.selectedAreaID == nil then
      local txtSfx = "S E L E C T E D !"
      if tableIsEmpty(var.areas.areaInfoTbl) then txtSfx = "A V A I L A B L E !" end
      local noAreaText = "N O   A R E A   " .. txtSfx
      imgui.SetCursorPos(imgui.ImVec2(imgui.GetContentRegionAvail().x/2 - imgui.CalcTextSize(noAreaText).x/2, imgui.GetContentRegionAvail().y/2))
      imgui.PushStyleColor2(imgui.Col_Text, imgui.ImVec4(1, 0, 0, 1));
      editor.uiTextColoredWithFont(imgui.ImVec4(1, 0, 0, 1), noAreaText, "cairo_bold")
      imgui.PopStyleColor()
    else
      drawAreaPanel2(var.selectedAreaID)
    end

    imgui.EndChild()
  end
  editor.endWindow()
end

local function updateNodePosInArea(layerID, nodeIndex, exZoneID, pos)
  if exZoneID then
    for _, zoneEntry in ipairs(var.areas.exclusionZones) do
      if zoneEntry.layerID == layerID then
        for _, data in ipairs(zoneEntry.zoneData) do
          if data.ID == exZoneID then
            data.nodes[nodeIndex].pos = pos
            data.nodes[nodeIndex].isUpdated = true
          end
        end
      end
    end
  else
    local layers = getLayers(var.selectedAreaID)
    for _, layer in ipairs(layers) do
      if layer.layerType == layerType_enum.lasso and layer.layerID == layerID then
          layer.lassoNodes[nodeIndex].pos = pos
          layer.lassoNodes[nodeIndex].isUpdated = true
      end
    end
  end
end

local function onEditorGui()
  if not editor.editMode or (editor.editMode.displayName ~= editModeName) then
    return
  end
  drawWindow()
  if isDrawingLassoArea then
    drawLassoPolylineAction()
  end

  local hit
  if imgui.GetIO().WantCaptureMouse == false then
    hit = cameraMouseRayCast(false, imgui.flags(SOTTerrain))
  end

  if var.selectedAreaID then
    drawLassoLayers(var.selectedAreaID)
  end

  if not imgui.IsMouseDown(0) then
    local hoveredNodeInfo = getLassoNodeUnderCursor()
    if hoveredNodeInfo then
      var.lassoHoveredNode = {}
      var.lassoActionHoveredNodeIndex = nil
      if hoveredNodeInfo.layerID == -1 then
        var.lassoActionHoveredNodeIndex = hoveredNodeInfo.index
      else
        var.lassoHoveredNode.index = hoveredNodeInfo.index
        var.lassoHoveredNode.layerID = hoveredNodeInfo.layerID
        var.lassoHoveredNode.exZoneID = hoveredNodeInfo.exclusionZoneID
      end
    end
  end

  if editor.keyModifiers.alt then
    if imgui.IsMouseClicked(0) and isDrawingLassoArea
        and editor.isViewportHovered()
        and not editor.isAxisGizmoHovered() then
      if var.lassoActionHoveredNodeIndex == 1 and #var.lassoPLNodes > 2 then
        var.lassoSelectionEnded = true
        isDrawingLassoArea = false

        if var.lassoDrawInfo.type == var.enum_lassoDrawType.inclusionZone then
          addLayer(var.selectedAreaID, layerType_enum.lasso, nil, var.lassoPLNodes, nil, nil)
        else
          local entryFound = false
          local areaID = 1
          for _, zone in ipairs(var.areas.exclusionZones) do
            if zone.areaID == var.lassoDrawInfo.areaID and zone.layerID == var.lassoDrawInfo.layerID then
              local data = {isSelected = false, ID = getExZoneGlobalIdx(var.lassoDrawInfo.areaID, var.lassoDrawInfo.layerID), nodes = deepcopy(var.lassoPLNodes)}
              areaID = data.ID
              table.insert(zone.zoneData, data)
              entryFound = true
            end
          end

          if not entryFound then
            local zoneDataTbl = {isSelected = false, ID = getExZoneGlobalIdx(var.lassoDrawInfo.areaID, var.lassoDrawInfo.layerID), nodes = deepcopy(var.lassoPLNodes)}
            areaID = zoneDataTbl.ID
            table.insert(var.areas.exclusionZones, {areaID = var.lassoDrawInfo.areaID, layerID = var.lassoDrawInfo.layerID, zoneData = {zoneDataTbl}})
          end
          clearExZoneSelection(var.lassoDrawInfo.areaID, var.lassoDrawInfo.layerID)
          selectExclusionZone(var.lassoDrawInfo.areaID, var.lassoDrawInfo.layerID, areaID)
          var.lassoDrawInfo.type = var.enum_lassoDrawType.inclusionZone
        end
        resetDrawActionVariables()
      elseif hit then
        local node = {
          nodeID    = #var.lassoPLNodes + 1,
          pos       = hit.pos,
          isUpdated = false
        }
        table.insert(var.lassoPLNodes, node)
      end
    end
  else
    if hit then
      if imgui.IsMouseClicked(0)
          and editor.isViewportHovered()
          and not editor.isAxisGizmoHovered() then
        if var.lassoHoveredNode.index ~= nil then
          var.mouseButtonHeldOnLassoNode = true
          if var.lassoHoveredNode.layerID == -1 then
            var.lassoActionSelectedNodeIndex = var.lassoHoveredNode.index
          else
            var.lassoAreaSelectedNode = {}
            var.lassoAreaSelectedNode.index = var.lassoHoveredNode.index
            var.lassoAreaSelectedNode.layerID = var.lassoHoveredNode.layerID
          end
        end
      end
      if imgui.IsMouseReleased(0) then
        var.mouseButtonHeldOnLassoNode = false
        var.lassoAreaSelectedNode = {}
      end
      if var.mouseButtonHeldOnLassoNode and imgui.IsMouseDragging(0) then
        updateNodePosInArea(var.lassoHoveredNode.layerID, var.lassoHoveredNode.index, var.lassoHoveredNode.exZoneID, hit.pos)
      end
    end
  end
end

local function show()
  editor.clearObjectSelection()
  editor.selectEditMode(editor.editModes.biomeEditMode)
  editor.showWindow(toolWindowName)
end

local function onActivate()
  editor.clearObjectSelection()
  editor_terrainEditor.updateMaterialLibrary()
  for _, win in ipairs(windows) do
    if win.onEditModeActivate then
      win:onEditModeActivate()
    end
  end
end

local function onDeactivate()
  for _, win in ipairs(windows) do
    if win.onEditModeDeactivate then
      win:onEditModeDeactivate()
    end
  end
  editor.clearObjectSelection()
end

local function initialize()
  -- ForestItemData
  local forestItemDataNames = scenetree.findClassObjects("TSForestItemData")
  var.forestItemData = {}
  for k, forestItemDataId in ipairs(forestItemDataNames) do
    local cobj = scenetree.findObject(forestItemDataId)
    if cobj then
      local item = {
        pos = k,
        id = cobj:getId(),
        dirty = false,
        selected = false
      }
      table.insert(var.forestItemData, item)
    end
  end
  var.forestBrushTool = ForestBrushTool()
  local forest = core_forest.getForestObject()
  if forest then
    var.forestData = forest:getData()
    var.forestBrushTool:setActiveForest(forest)
  else
    log('I', '', "There's no Forest object.")
  end
end

local function getFieldsData(areaID, layerID)
  local data = nil
  for _, info in ipairs(var.areas.fieldInfoTbl) do
    if info.areaID == areaID and info.layerID == layerID then
      data = info.fieldsData
    end
  end
  return data
end

local function getMaterialName(index)
  local materialName = ""
  for id, mtl in pairs(editor_terrainEditor.getMaterialsInJson()) do
    if id == index then
      materialName = mtl.internalName
      break
    end
  end
  return materialName
end

local function getLayerTerrainMaterial(areaID, layerID)
  local materialName = nil
  local fieldsData = getFieldsData(areaID, layerID)
  for _, fieldData in ipairs(fieldsData) do
    if fieldData.name == "TerrainMaterial" then
      materialName = fieldData.val
    end
  end
  return materialName
end

local editingPos = false
local range = imgui.ArrayFloat(2)
local function biomeToolCustomFieldEditor(objectIds, fieldValue, fieldName, fieldLabel, fieldDesc, fieldType, fieldTypeName, customData, pasteCallback, contextMenuUI)
  local fieldVal = fieldValue

  if fieldName == "TerrainMaterial" then
    fieldVal = getLayerTerrainMaterial(customData.areaID, customData.layerID)
    imgui.BeginDisabled()
    editor.uiInputText('', editor.getTempCharPtr(fieldVal))
    imgui.EndDisabled()
  elseif fieldName == "BlendingMethod" then
    local blendingMethodPtr = imgui.IntPtr(0)
    blendingMethodPtr[0] = getBlendingMethod(customData.areaID, customData.layerID)
    if imgui.Combo1("##layersDelete", blendingMethodPtr, layerBlendingComboItems) then
      setBlendingMethod(customData.areaID, customData.layerID, blendingMethodPtr[0])
    end
  end

  if fieldName == "SlopeRange" then
    local shouldDisableRange = (getSlopeInfluence(customData.areaID, customData.layerID) == 0.0)
    if shouldDisableRange then
      imgui.BeginDisabled()
    end
    if not editingPos then
      range = imgui.TableToArrayFloat(getSlopeRange(customData.areaID, customData.layerID))
    end
    local positionSliderEditEnded = imgui.BoolPtr(false)
    if editor.uiDragFloat2("##" .."SlopeRange"..tostring(customData.areaID)..tostring(customData.layerID), 
      range, 0.2, -1000000000, 100000000, "%0." .. editor.getPreference("ui.general.floatDigitCount") .. "f", 1, positionSliderEditEnded) then
        editingPos = true
    end
    if positionSliderEditEnded[0] == true then
      setSlopeRange(customData.areaID, customData.layerID, {range[0], range[1]})
      editingPos = false
    end
    if shouldDisableRange then
      imgui.EndDisabled()
    end
  end
  --fieldName == "VegetationFalloff"  
end

local function getLevelPathAndName()
  local path = '/levels/'
  local name = ""
  local i = 1
  for str in string.gmatch(getMissionFilename(),"([^/]+)") do
    if i == 2 then
      path = path .. str
      name = str
    end
    i = i + 1
  end
  return path, name
end

local function onEditorInitialized()
  local levelPath, levelName = getLevelPathAndName()
  local levelDataPath = string.format("%s/%s", levelPath, "/art/biomeTool.json")

  if FS:fileExists(levelDataPath) then
    var.areas = jsonReadFile(levelDataPath)
  end
  populateForestBrushes()
  
  editor.registerWindow(toolWindowName, imgui.ImVec2(400, 400))
  editor.editModes.biomeEditMode =
  {
    displayName = editModeName,
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    auxShortcuts = {},
  }
  editor.addWindowMenuItem("Biome Tool", function() show() end, {groupMenuName="Experimental"})
  editor.registerCustomFieldInspectorEditor("BiomeTool", "TerrainMaterial", biomeToolCustomFieldEditor)
  editor.registerCustomFieldInspectorEditor("BiomeTool", "BlendingMethod", biomeToolCustomFieldEditor)
  editor.registerCustomFieldInspectorEditor("BiomeTool", "SlopeRange", biomeToolCustomFieldEditor)
  editor.registerCustomFieldInspectorEditor("BiomeTool", "VegetationFalloff", biomeToolCustomFieldEditor)

  valueInspector.selectionClassName = "BiomeTool"
  valueInspector.setValueCallback = function(fieldName, fieldValue, arrayIndex, customData, editEnded)
    if customData then
      setFieldValue(fieldName, fieldValue, customData)
    end
  end

  forest = core_forest and core_forest.getForestObject()
  if forest then
    var.forestData = forest:getData()
  end

  editor_terrainEditor.updateMaterialLibrary()
  terrainBlock = getObjectByClass("TerrainBlock")
  initialize()
end

local function onEditorToolWindowHide(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.objectSelect)
  end
end

local function onWindowGotFocus(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.biomeEditMode)
  end
end

local function onEditorAfterSaveLevel()
  if tableIsEmpty(var.areas) then return end
  local levelPath, levelName = getLevelPathAndName()
  local levelDataPath = string.format("%s/%s", levelPath, "/art/biomeTool.json")
  if FS:fileExists("/art/biomeTool.json") then
    FS:removeFile(currentPath)
  end
  jsonWriteFile(levelDataPath, var.areas, true)
end

M.onEditorAfterSaveLevel = onEditorAfterSaveLevel
M.onEditorGui = onEditorGui
M.onEditorToolWindowHide = onEditorToolWindowHide
M.onEditorToolWindowGotFocus = onWindowGotFocus

M.onEditorInitialized = onEditorInitialized
M.onExtensionLoaded = onExtensionLoaded

return M