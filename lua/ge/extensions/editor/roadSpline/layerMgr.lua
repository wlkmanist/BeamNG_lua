-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local maxDecalRoadPoints = 100 -- The number of divPoints before we chunk a decal road.

local simplifyTol = 0.25 -- Tolerance for the RDP node simplification algorithm.
local defaultDecalRoadDetail = 1.0 -- The default value for the detail (number of binormal subdivisions) of the 'improvedSpline'decal road.

local defaultMaterial = "road_invisible"

local defaultFullLengthWidth = 5.0
local laneWidth = 5.0

local lightTreadMarksTexLen = 5
local lightTreadMaterial = 'm_tread_marks_clean'
local lightTreadStr = "Light Tread Marks"

local heavyTreadMarksTexLen = 5
local heavyTreadMaterial = 'road_rubber_double'
local heavyTreadStr = "Heavy Tread Marks"

local roadCrackTexLen = 15
local roadCrackMaterial = 'm_asphalt_cracks_02'
local roadCrackStr = "Road Crack"

local repair1TexLen = 25
local repair1Material = 'repair1'
local repair1Str = "Repair 1"

local repair2TexLen = 25
local repair2Material = 'repair2'
local repair2Str = "Repair 2"

local patchesTexLen = 45
local patchesMaterial = 'road_patches1'
local patchesStr = "Patches"

local damageAsphalt1TexLen = 10
local damageAsphalt1Material = 'm_asphalt_damaged_01'
local damageAsphalt1Str = "Damage Asphalt 1"

local damageAsphalt2TexLen = 25
local damageAsphalt2Material = 'm_asphalt_damaged_02'
local damageAsphalt2Str = "Damage Asphalt 2"

local roadCenterLineMaterial = 'm_line_white_discontinue'
local roadCenterLineStr = "Center Line"
local defaultCenterlineWidth = 0.2
local defaultCenterlineTexLen = 5.0

local roadEdgeLineMaterial = 'm_line_white'
local roadEdgeLineStr = "Edge Line"
local defaultEdgeLineWidth = 0.25

local roadLaneLineMaterial = 'm_line_white_discontinue'
local roadLaneLineStr = "Lane Line"
local defaultLaneLineWidth = 0.2

local roadEdgeBlend1Material = 'm_road_asphalt_edge'
local roadEdgeBlend1Str = "Edge Blend 1"
local defaultEdgeBlend1Width = 1.0
local defaultEdgeBlend1TexLen = 10.0
local defaultEdgeBlend1LatPos = 1.1

local roadEdgeBlend2Material = 'm_road_edge_dirt'
local roadEdgeBlend2Str = "Edge Blend 2"
local defaultEdgeBlend2Width = 2.0
local defaultEdgeBlend2TexLen = 10.0
local defaultEdgeBlend2LatPos = 1.25

local roadEdgeBlend3Material = 'm_road_asphalt_edge_grass'
local roadEdgeBlend3Str = "Edge Blend 3"
local defaultEdgeBlend3Width = 3.0
local defaultEdgeBlend3TexLen = 10.0
local defaultEdgeBlend3LatPos = 1.35

-- The default values for the slider properties, so they can be reset to their default values.
local sliderDefaults = {
  defaultWidth = 10.0,
  defaultLateralPosition = 0.0,
  defaultRenderPriority = 10,
  defaultTexLength = 10.0,
  defaultFadeIn = 1.0,
  defaultFadeOut = 1.0,
  defaultPaintMargin = 0.0,
  defaultPaintMaterialIdx = 0,
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local buffer = require('string.buffer')
local rdp = require('editor/toolUtilities/rdp')
local util = require('editor/toolUtilities/util')

-- Module constants.
local min, max, floor, ceil = math.min, math.max, math.floor, math.ceil

-- Module state.
local tmp1 = vec3()


-- Returns the default values for the slider properties, for use in the tool's front end.
local function getSliderDefaults() return sliderDefaults end

-- Deep copies a layer.
local function deepCopyLayer(layer)
  table.clear(layer.pClipped)
  table.clear(layer.wClipped)
  table.clear(layer.pFlip)
  table.clear(layer.wFlip)
  return buffer.decode(buffer.encode(layer))
end

-- Deep copies all layers.
local function deepCopyAllLayers(layers)
  local copy = {}
  for i = 1, #layers do
    copy[i] = deepCopyLayer(layers[i])
  end
  return copy
end

-- Removes all decal roads associated with a layer (for chunked layers).
local function removeAllDecalRoadsForLayer(layer)
  if layer.decalRoadIds then
    for i = 1, #layer.decalRoadIds do
      local decalRoad = scenetree.findObjectById(layer.decalRoadIds[i])
      if decalRoad then
        decalRoad:delete()
      end
    end
    layer.decalRoadIds = nil
  end
end

-- Initialise layer.decalRoadIds if it doesn't exist
local function ensureLayerDecalRoadIds(layer)
  if not layer.decalRoadIds then
    layer.decalRoadIds = {}
  end
end

-- Removes the decal road object associated with the given layer, if it exists.
local function removeDecalRoadInLayer(layer)
  if layer.decalRoadId then
    local decalRoad = scenetree.findObjectById(layer.decalRoadId)
    if decalRoad then
      decalRoad:delete()
    end
    layer.decalRoadId = nil
  end
  -- Also remove chunked DecalRoads if they exist
  removeAllDecalRoadsForLayer(layer)
end

-- Clears chunk data for a group.
local function clearGroupChunks(group)
  table.clear(group.chunkStartIndices)
  table.clear(group.chunkEndIndices)
  group.numChunks = 0
end

-- Adds a chunk to a group.
local function addGroupChunk(group, startIdx, endIdx)
  group.numChunks = group.numChunks + 1
  group.chunkStartIndices[group.numChunks] = startIdx
  group.chunkEndIndices[group.numChunks] = endIdx
end

-- Creates a DecalRoad from a range of divPoints.
local function createDecalRoadFromRange(layer, group, startIdx, endIdx, folder, startFade, endFade)
  local decalRoad = createObject("DecalRoad")
  decalRoad:setField("improvedSpline", 0, "true")
  decalRoad:setField("overObjects", 0, "true")
  decalRoad:setField("detail", 0, defaultDecalRoadDetail)
  decalRoad:setField("textureLength", 0, layer.texLen)
  decalRoad:setField("renderPriority", 0, layer.renderPriority)
  decalRoad:setField("drivability", 0, -1.0)
  decalRoad:setField("material", 0, layer.material)
  decalRoad:setField("overObjects", 0, tostring(layer.isOverObjects))
  decalRoad:setField('startEndFade', 0, string.format("%f %f", startFade, endFade)) -- Apply fade parameters for this chunk.

  local name = Sim.getUniqueName(layer.name .. "_chunk")
  decalRoad:registerObject(name)
  folder:addObject(decalRoad)

  -- Apply the appropriate lateral offset to each node in the range.
  local divPoints, divWidths, binormals = group.divPoints, group.divWidths, group.binormals
  local layerPositionHalfWidth = layer.position * 0.5

  for i = startIdx, endIdx do
    tmp1:setScaled2(binormals[i], layerPositionHalfWidth * divWidths[i])
    local offsetPoint = divPoints[i] + tmp1
    local width = layer.isTrackWidth and divWidths[i] or layer.width
    decalRoad:insertNodeNoRegen(offsetPoint, width, i - startIdx)
  end

  decalRoad:regenerate()
  return decalRoad
end

-- Updates the decal road object associated with the given layer.
local function updateLayer(group, layerIdx, groupIdx)
  -- Check if the spline has enough nodes to create a valid decal road (minimum 2 nodes).
  if #group.nodes < 2 then
    -- Remove the decal road if there are insufficient nodes.
    local layer = group.layers[layerIdx]
    removeDecalRoadInLayer(layer)
    return
  end

  -- Get the Road Spline's scene tree folder.
  local folder = scenetree.findObjectById(group.sceneTreeFolderId)

  -- Create the decal road object, if it doesn't exist.
  local layer = group.layers[layerIdx]

  -- Ensure the layer has the decalRoadIds array (for backward compatibility)
  ensureLayerDecalRoadIds(layer)

  if not layer.decalRoadId or not scenetree.findObjectById(layer.decalRoadId) then
    local drtest = scenetree.findObjectById(layer.decalRoadId)
    if not drtest or drtest:getClassName() ~= "DecalRoad" then -- Even if there is an id, we need to ensure it is a decal road object.
      local newDecalRoad = createObject("DecalRoad")
      newDecalRoad:setField("improvedSpline", 0, "true")
      newDecalRoad:setField("overObjects", 0, "true")
      newDecalRoad:setField("detail", 0, defaultDecalRoadDetail)
      local name = Sim.getUniqueName(layer.name) -- Get a unique name for the decal road object.
      newDecalRoad:registerObject(name)
      layer.decalRoadId = newDecalRoad:getId()
      folder:addObject(newDecalRoad)
      editor.setDirty()
    end
  end

  -- Update the properties of the decal road object.
  local dRoad = scenetree.findObjectById(layer.decalRoadId)
  dRoad:setField("textureLength", 0, layer.texLen)
  dRoad:setField("renderPriority", 0, layer.renderPriority)
  dRoad:setField("drivability", 0, -1.0)
  dRoad:setField("material", 0, layer.material)
  dRoad:setField("overObjects", 0, tostring(layer.isOverObjects))
  dRoad:setField('startEndFade', 0, string.format("%f %f", layer.fadeIn, layer.fadeOut))

  -- Get the secondary geometry arrays.
  local divPoints, divWidths, binormals = group.divPoints, group.divWidths, group.binormals

  if #divPoints > maxDecalRoadPoints then
    -- Remove ALL existing DecalRoads (single and chunked) for this layer
    removeDecalRoadInLayer(layer)

    -- Clear existing chunks and create new ones
    clearGroupChunks(group)

    -- Create chunks as index ranges with shared boundary points
    for i = 1, ceil(#divPoints / maxDecalRoadPoints) do
      local startIdx = (i-1) * maxDecalRoadPoints + 1
      local endIdx = min(i * maxDecalRoadPoints, #divPoints)

      -- Share boundary points with previous chunk (except first chunk)
      if i > 1 then
        startIdx = startIdx - 1
      end

      addGroupChunk(group, startIdx, endIdx)
    end

    -- Create DecalRoad for each chunk
    ensureLayerDecalRoadIds(layer)
    for chunkNum = 1, group.numChunks do
      local startIdx, endIdx = group.chunkStartIndices[chunkNum], group.chunkEndIndices[chunkNum]

      -- Apply fade: start fade to first chunk, end fade to last chunk, no fade for middle chunks.
      local startFade, endFade = 0.0, 0.0
      if chunkNum == 1 then
        startFade = layer.fadeIn
      end
      if chunkNum == group.numChunks then
        endFade = layer.fadeOut
      end

      local decalRoad = createDecalRoadFromRange(layer, group, startIdx, endIdx, folder, startFade, endFade)
      layer.decalRoadIds[chunkNum] = decalRoad:getId()
    end

    layer.isDirty = false
    return
  end

  -- Normal single DecalRoad creation (existing code)
  -- If we were previously chunked, remove all chunked DecalRoads
  if group.numChunks > 0 then
    removeAllDecalRoadsForLayer(layer)
    clearGroupChunks(group)
  end

  -- Apply the appropriate lateral offset to each node.
  local layerPositionHalfWidth = layer.position * 0.5
  local pClipped, wClipped, ctr = layer.pClipped, layer.wClipped, 1

  for i = 1, #divPoints do
    tmp1:setScaled2(binormals[i], layerPositionHalfWidth * divWidths[i])
    pClipped[ctr] = pClipped[ctr] or vec3()
    pClipped[ctr]:setAdd2(divPoints[i], tmp1)
    wClipped[ctr] = divWidths[i]
    ctr = ctr + 1
  end

  -- Trim any stale entries beyond ctr-1 in the buffers.
  for k = #pClipped, ctr, -1 do
    pClipped[k], wClipped[k] = nil, nil
  end

  -- If the layer is set to be flipped, flip the nodes, widths, tangents, and binormals.
  if layer.isFlip then
    local pFlip, wFlip, ctr = layer.pFlip, layer.wFlip, 1

    for i = #pClipped, 1, -1 do
      pFlip[ctr] = pFlip[ctr] or vec3()
      pFlip[ctr]:set(pClipped[i])
      wFlip[ctr] = wClipped[i]
      ctr = ctr + 1
    end

    -- Trim any stale entries beyond ctr-1 in the flip buffers.
    for k = #pFlip, ctr, -1 do
      pFlip[k], wFlip[k] = nil, nil
    end

    pClipped, wClipped = pFlip, wFlip
  end

  -- Simplify the nodes and widths.
  rdp.simplifyNodesWidths(pClipped, wClipped, simplifyTol)

  -- Clear all the nodes from the decal road object, but do not regenerate the geometry.
  for i = #editor.getNodes(dRoad) - 1, 0, -1 do
    dRoad:deleteNodeNoRegen(i)
  end

  -- Set the nodes in the decal road object.
  if layer.isTrackWidth then
    for i = 1, #pClipped do
      dRoad:insertNodeNoRegen(pClipped[i], wClipped[i], i - 1)
    end
  else
    local layerWidth = layer.width
    for i = 1, #pClipped do
      dRoad:insertNodeNoRegen(pClipped[i], layerWidth, i - 1)
    end
  end

  -- Regenerate the geometry of the decal road object, now that it has been fully switched.
  dRoad:regenerate()

  layer.isDirty = false
end

-- Updates the properties of all layers.
local function updateAllLayers(group, groupIdx)
  local layers = group.layers
  for i = 1, #layers do
    local layer = layers[i]
    if layer.isEnabled then
      updateLayer(group, i, groupIdx)
    else
      removeDecalRoadInLayer(layer) -- Remove the decal road object associated with the given layer.
    end
  end
end

-- Updates the properties of only the dirty layers.
local function updateOnlyDirtyLayers(group, groupIdx)
  local layers = group.layers
  for i = 1, #layers do
    local layer = layers[i]
    if layer.isDirty then
      if layer.isEnabled then
        updateLayer(group, i, groupIdx)
      else
        removeDecalRoadInLayer(layer) -- Remove the decal road object associated with the given layer.
      end
      layer.isDirty = false
    end
  end
end

-- Removes a layer at the given index.
local function removeLayer(idx, group)
  local layers = group.layers
  local layer = layers[idx]
  removeDecalRoadInLayer(layer)
  table.remove(layers, idx) -- Remove the layer from the list.
end

-- Removes all layers.
local function removeAllLayers(group)
  for i = #group.layers, 1, -1 do
    removeLayer(i, group)
  end
end

-- Removes all hidden layers.
local function removeAllHiddenLayers(group)
  local layers = group.layers
  for i = #layers, 1, -1 do
    if layers[i].isHidden then
      removeLayer(i, group)
    end
  end
end

-- Adds a new layer.
local function addNewLayer(group)
  group.layers[#group.layers + 1] = {
    name = string.format("New Layer %d", #group.layers + 1),
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = false,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = defaultMaterial,
    isFlip = false,
    isTrackWidth = true,
    isOverObjects = false,
    width = sliderDefaults.defaultWidth,
    position = sliderDefaults.defaultLateralPosition,
    texLen = sliderDefaults.defaultTexLength,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,

    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},

    decalRoadIds = {},
  }
end

-- Duplicates a layer at the given index.
local function duplicateLayer(idx, group)
  local layer = group.layers[idx]
  local newLayer = deepCopyLayer(layer)
  newLayer.id = Engine.generateUUID()
  newLayer.name = layer.name .. " (Copy)"
  table.insert(group.layers, idx + 1, newLayer)
end

-- Switches off all auto layers.
local function switchOffAllAutoLayers(selGroup)
  selGroup.isLightTreadMarks = false
  selGroup.isHeavyTreadMarks = false
  selGroup.isDamageAsphalt1 = false
  selGroup.isDamageAsphalt2 = false
  selGroup.isRoadCrack = false
  selGroup.isRepair1 = false
  selGroup.isRepair2 = false
  selGroup.isPatches = false
  selGroup.isRoadCenterLine = false
  selGroup.isRoadEdgeLines = false
  selGroup.isRoadLaneLines = false
  selGroup.isEdgeBlend1 = false
  selGroup.isEdgeBlend2 = false
  selGroup.isEdgeBlend3 = false

  selGroup.isDirty = true
end

-- Adds new full road layers, per lane.
local function addFullLengthLayers(group, searchString, material, texLen)
  -- Add a layer for each left lane.
  local currentWidth, _ = util.getMinMaxWidth(group)
  local currentHalfWidthOfRoad = currentWidth * 0.5
  local numLeftLanes = max(1, floor(currentHalfWidthOfRoad / 5.0)) -- Ensure at least 1 lane
  local numRightLanes = numLeftLanes
  for i = 1, numLeftLanes do
    group.layers[#group.layers + 1] = {
      name = string.format("%s - Left %d", searchString, i),
      id = Engine.generateUUID(),
      isDirty = true,
      isHidden = true,
      decalRoadId = nil,
      renderPriority = sliderDefaults.defaultRenderPriority,
      isEnabled = true,
      material = material,
      isFlip = false,
      isTrackWidth = false,
      isOverObjects = false,
      width = defaultFullLengthWidth,
      position = ((-i * laneWidth) + 2.5) / currentHalfWidthOfRoad, -- We use a fixed width of 5.0 for the layer.
      texLen = texLen,
      fadeIn = sliderDefaults.defaultFadeIn,
      fadeOut = sliderDefaults.defaultFadeOut,
      pClipped = {},
      wClipped = {},
      pFlip = {},
      wFlip = {},
      decalRoadIds = {},
    }
  end

  -- Add a layer for each right lane.
  for i = 1, numRightLanes do
    group.layers[#group.layers + 1] = {
      name = string.format("%s - Right %d", searchString, i),
      id = Engine.generateUUID(),
      isDirty = true,
      isHidden = true,
      decalRoadId = nil,
      renderPriority = sliderDefaults.defaultRenderPriority,
      isEnabled = true,
      material = material,
      isFlip = false,
      isTrackWidth = false,
      isOverObjects = false,
      width = defaultFullLengthWidth,
      position = ((i * laneWidth) - 2.5) / currentHalfWidthOfRoad,
      texLen = texLen,
      fadeIn = sliderDefaults.defaultFadeIn,
      fadeOut = sliderDefaults.defaultFadeOut,
      pClipped = {},
      wClipped = {},
      pFlip = {},
      wFlip = {},
      decalRoadIds = {},
    }
  end
end

-- Removes all layers matching the given search string.
local function removeMatchingLayers(group, searchString)
  local layers = group.layers
  for i = #layers, 1, -1 do
    if string.find(layers[i].name, searchString) then
      removeLayer(i, group)
    end
  end
end

-- Add/remove functions for various detail layers.
local function addLightTreadMarksLayers(group) addFullLengthLayers(group, lightTreadStr, lightTreadMaterial, lightTreadMarksTexLen) end
local function removeLightTreadMarksLayers(group) removeMatchingLayers(group, lightTreadStr) end
local function addHeavyTreadMarksLayers(group) addFullLengthLayers(group, heavyTreadStr, heavyTreadMaterial, heavyTreadMarksTexLen) end
local function removeHeavyTreadMarksLayers(group) removeMatchingLayers(group, heavyTreadStr) end
local function addRoadCrackLayers(group) addFullLengthLayers(group, roadCrackStr, roadCrackMaterial, roadCrackTexLen) end
local function removeRoadCrackLayers(group) removeMatchingLayers(group, roadCrackStr) end
local function addRepair1Layers(group) addFullLengthLayers(group, repair1Str, repair1Material, repair1TexLen) end
local function removeRepair1Layers(group) removeMatchingLayers(group, repair1Str) end
local function addRepair2Layers(group) addFullLengthLayers(group, repair2Str, repair2Material, repair2TexLen) end
local function removeRepair2Layers(group) removeMatchingLayers(group, repair2Str) end
local function addPatchesLayers(group) addFullLengthLayers(group, patchesStr, patchesMaterial, patchesTexLen) end
local function removePatchesLayers(group) removeMatchingLayers(group, patchesStr) end
local function addRoadDamageAsphalt1Layers(group) addFullLengthLayers(group, damageAsphalt1Str, damageAsphalt1Material, damageAsphalt1TexLen) end
local function removeRoadDamageAsphalt1Layers(group) removeMatchingLayers(group, damageAsphalt1Str) end
local function addRoadDamageAsphalt2Layers(group) addFullLengthLayers(group, damageAsphalt2Str, damageAsphalt2Material, damageAsphalt2TexLen) end
local function removeRoadDamageAsphalt2Layers(group) removeMatchingLayers(group, damageAsphalt2Str) end

-- Adds new road center line layers.
local function addRoadCenterLineLayers(group)
  group.layers[#group.layers + 1] = {
    name = roadCenterLineStr,
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadCenterLineMaterial,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultCenterlineWidth,
    position = 0.0,
    texLen = defaultCenterlineTexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the road center line layers.
local function removeRoadCenterLineLayers(group) removeMatchingLayers(group, roadCenterLineStr) end

-- Adds new road edge lines layers.
local function addRoadEdgeLinesLayers(group)
  group.layers[#group.layers + 1] = {
    name = roadEdgeLineStr .. " - Left",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeLineMaterial,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeLineWidth,
    position = -1.0,
    texLen = sliderDefaults.defaultTexLength,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeLineStr .. " - Right",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeLineMaterial,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeLineWidth,
    position = 1.0,
    texLen = sliderDefaults.defaultTexLength,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the road edge lines layers.
local function removeRoadEdgeLinesLayers(group) removeMatchingLayers(group, roadEdgeLineStr) end

-- Adds new road lane lines layers.
local function addRoadLaneLinesLayers(group)
  local minHalfWidthOfRoad = util.getMinMaxWidth(group) * 0.5
  local numLeftLanes = floor(minHalfWidthOfRoad / 5.0) - 1
  local numRightLanes = numLeftLanes
    for i = 1, numLeftLanes do
    group.layers[#group.layers + 1] = {
      name = string.format("%s - Left %d", roadLaneLineStr, i),
      id = Engine.generateUUID(),
      isDirty = true,
      isHidden = true,
      decalRoadId = nil,
      renderPriority = sliderDefaults.defaultRenderPriority,
      isEnabled = true,
      material = roadLaneLineMaterial,
      isFlip = false,
      isTrackWidth = false,
      isOverObjects = false,
      width = defaultLaneLineWidth,
      position = (-i * laneWidth) / minHalfWidthOfRoad,
      texLen = sliderDefaults.defaultTexLength,
      fadeIn = sliderDefaults.defaultFadeIn,
      fadeOut = sliderDefaults.defaultFadeOut,
      pClipped = {},
      wClipped = {},
      pFlip = {},
      wFlip = {},
      decalRoadIds = {},
    }
  end
  for i = 1, numRightLanes do
    group.layers[#group.layers + 1] = {
      name = string.format("%s - Right %d", roadLaneLineStr, i),
      id = Engine.generateUUID(),
      isDirty = true,
      isHidden = true,
      decalRoadId = nil,
      renderPriority = sliderDefaults.defaultRenderPriority,
      isEnabled = true,
      material = roadLaneLineMaterial,
      isFlip = false,
      isTrackWidth = false,
      isOverObjects = false,
      width = defaultLaneLineWidth,
      position = (i * laneWidth) / minHalfWidthOfRoad,
      texLen = sliderDefaults.defaultTexLength,
      fadeIn = sliderDefaults.defaultFadeIn,
      fadeOut = sliderDefaults.defaultFadeOut,
      pClipped = {},
      wClipped = {},
      pFlip = {},
      wFlip = {},
      decalRoadIds = {},
    }
  end
end

-- Removes the road lane lines layers.
local function removeRoadLaneLinesLayers(group) removeMatchingLayers(group, roadLaneLineStr) end

-- Adds new edge blend 1 layers.
local function addEdgeBlend1Layers(group)
  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend1Str .. " - Left",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority - 1,
    isEnabled = true,
    material = roadEdgeBlend1Material,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeBlend1Width,
    position = -defaultEdgeBlend1LatPos,
    texLen = defaultEdgeBlend1TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend1Str .. " - Right",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority - 1,
    isEnabled = true,
    material = roadEdgeBlend1Material,
    isFlip = true,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeBlend1Width,
    position = defaultEdgeBlend1LatPos,
    texLen = defaultEdgeBlend1TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the edge blend 1 layers.
local function removeEdgeBlend1Layers(group) removeMatchingLayers(group, roadEdgeBlend1Str) end

-- Adds new edge blend 2 layers.
local function addEdgeBlend2Layers(group)
  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend2Str .. " - Left",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend2Material,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeBlend2Width,
    position = -defaultEdgeBlend2LatPos,
    texLen = defaultEdgeBlend2TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend2Str .. " - Right",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend2Material,
    isFlip = true,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeBlend2Width,
    position = defaultEdgeBlend2LatPos,
    texLen = defaultEdgeBlend2TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the edge blend 2 layers.
local function removeEdgeBlend2Layers(group) removeMatchingLayers(group, roadEdgeBlend2Str) end

-- Adds new edge blend 3 layers.
local function addEdgeBlend3Layers(group)
  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend3Str .. " - Left_A",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend3Material,
    isFlip = false,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeBlend3Width,
    position = -defaultEdgeBlend3LatPos,
    texLen = defaultEdgeBlend3TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }

  group.layers[#group.layers + 1] = {
    name = roadEdgeBlend3Str .. " - Right_A",
    id = Engine.generateUUID(),
    isDirty = true,
    isHidden = true,
    decalRoadId = nil,
    renderPriority = sliderDefaults.defaultRenderPriority,
    isEnabled = true,
    material = roadEdgeBlend3Material,
    isFlip = true,
    isTrackWidth = false,
    isOverObjects = false,
    width = defaultEdgeBlend3Width,
    position = defaultEdgeBlend3LatPos,
    texLen = defaultEdgeBlend3TexLen,
    fadeIn = sliderDefaults.defaultFadeIn,
    fadeOut = sliderDefaults.defaultFadeOut,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end

-- Removes the edge blend 3 layers.
local function removeEdgeBlend3Layers(group) removeMatchingLayers(group, roadEdgeBlend3Str) end

-- Serialises a layer to a table.
local function serializeLayer(layer)
  return {
    name = layer.name,
    id = layer.id,
    isHidden = layer.isHidden,
    isEnabled = layer.isEnabled,
    material = layer.material,
    isFlip = layer.isFlip,
    isTrackWidth = layer.isTrackWidth,
    isOverObjects = layer.isOverObjects,
    width = layer.width,
    position = layer.position,
    texLen = layer.texLen,
    fadeIn = layer.fadeIn,
    fadeOut = layer.fadeOut,
    renderPriority = layer.renderPriority,
  }
end

-- Deserialises a layer from a table.
local function deserializeLayer(data)
  return {
    name = data.name or "?",
    id = data.id or Engine.generateUUID(),
    isDirty = true, -- Set to dirty. The objects will be added in the next update.
    decalRoadId = nil,
    isHidden = data.isHidden == true,
    isEnabled = data.isEnabled ~= false,
    material = data.material,
    isFlip = data.isFlip == true,
    isTrackWidth = data.isTrackWidth == true,
    isOverObjects = data.isOverObjects == true,
    width = data.width or sliderDefaults.defaultWidth,
    position = data.position or sliderDefaults.defaultLateralPosition,
    texLen = data.texLen or sliderDefaults.defaultTexLength,
    fadeIn = data.fadeIn or sliderDefaults.defaultFadeIn,
    fadeOut = data.fadeOut or sliderDefaults.defaultFadeOut,
    renderPriority = data.renderPriority or sliderDefaults.defaultRenderPriority,
    pClipped = {},
    wClipped = {},
    pFlip = {},
    wFlip = {},
    decalRoadIds = {},
  }
end


-- Public interface.
M.getSliderDefaults =                                  getSliderDefaults

M.deepCopyLayer =                                      deepCopyLayer
M.deepCopyAllLayers =                                  deepCopyAllLayers

M.updateAllLayers =                                    updateAllLayers
M.updateOnlyDirtyLayers =                              updateOnlyDirtyLayers

M.removeDecalRoadInLayer =                             removeDecalRoadInLayer
M.removeLayer =                                        removeLayer
M.removeAllLayers =                                    removeAllLayers
M.removeAllHiddenLayers =                              removeAllHiddenLayers
M.addNewLayer =                                        addNewLayer
M.duplicateLayer =                                     duplicateLayer

M.switchOffAllAutoLayers =                             switchOffAllAutoLayers
M.addLightTreadMarksLayers =                           addLightTreadMarksLayers
M.removeLightTreadMarksLayers =                        removeLightTreadMarksLayers
M.addHeavyTreadMarksLayers =                           addHeavyTreadMarksLayers
M.removeHeavyTreadMarksLayers =                        removeHeavyTreadMarksLayers
M.addRoadCrackLayers =                                 addRoadCrackLayers
M.removeRoadCrackLayers =                              removeRoadCrackLayers
M.addRepair1Layers =                                   addRepair1Layers
M.removeRepair1Layers =                                removeRepair1Layers
M.addRepair2Layers =                                   addRepair2Layers
M.removeRepair2Layers =                                removeRepair2Layers
M.addPatchesLayers =                                   addPatchesLayers
M.removePatchesLayers =                                removePatchesLayers
M.addRoadDamageAsphalt1Layers =                        addRoadDamageAsphalt1Layers
M.removeRoadDamageAsphalt1Layers =                     removeRoadDamageAsphalt1Layers
M.addRoadDamageAsphalt2Layers =                        addRoadDamageAsphalt2Layers
M.removeRoadDamageAsphalt2Layers =                     removeRoadDamageAsphalt2Layers

M.addRoadCenterLineLayers =                            addRoadCenterLineLayers
M.removeRoadCenterLineLayers =                         removeRoadCenterLineLayers
M.addRoadEdgeLinesLayers =                             addRoadEdgeLinesLayers
M.removeRoadEdgeLinesLayers =                          removeRoadEdgeLinesLayers
M.addRoadLaneLinesLayers =                             addRoadLaneLinesLayers
M.removeRoadLaneLinesLayers =                          removeRoadLaneLinesLayers
M.addEdgeBlend1Layers =                                addEdgeBlend1Layers
M.removeEdgeBlend1Layers =                             removeEdgeBlend1Layers
M.addEdgeBlend2Layers =                                addEdgeBlend2Layers
M.removeEdgeBlend2Layers =                             removeEdgeBlend2Layers
M.addEdgeBlend3Layers =                                addEdgeBlend3Layers
M.removeEdgeBlend3Layers =                             removeEdgeBlend3Layers

M.serializeLayer =                                     serializeLayer
M.deserializeLayer =                                   deserializeLayer

return M