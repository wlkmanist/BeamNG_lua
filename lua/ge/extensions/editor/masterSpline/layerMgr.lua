-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local sliderDefaults = { -- The default values for the slider properties, for use in the tool's front end.
  defaultPaintMargin = 0.0,
  defaultLateralPosition = 0.0,
  defaultDOI = 70.0,
  defaultTerraMargin = 5.0,
  defaultTerraFalloff = 1.5,
  defaultTerraRoughness = 0.1,
  defaultTerraScale = 0.5,
  defaultBankStrength = 0.5,
  defaultAutoBankFalloff = 0.6,
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- Module dependencies.
local buffer = require('string.buffer')
local meshSplineLink = require('editor/meshSpline/splineMgr')
local assemblySplineLink = require('editor/assemblySpline/splineMgr')
local decalSplineLink = require('editor/decalSpline/splineMgr')
local roadSplineLink = require('editor/roadSpline/groupMgr')
local rdp = require('editor/toolUtilities/rdp')

-- Module constants.
local meshSplineStr = meshSplineLink.getToolPrefixStr()
local assemblySplineStr = assemblySplineLink.getToolPrefixStr()
local decalSplineStr = decalSplineLink.getToolPrefixStr()
local roadSplineStr = roadSplineLink.getToolPrefixStr()
local defaultLinkType = meshSplineStr

-- Module state.
local tmp1 = vec3()


-- A jump table for updating a linked spline.
local linkUpdateJumpTable = {
  [meshSplineStr] = meshSplineLink.updateLinkedMeshSpline,
  [assemblySplineStr] = assemblySplineLink.updateLinkedAssemblySpline,
  [decalSplineStr] = decalSplineLink.updateLinkedDecalSpline,
  [roadSplineStr] = roadSplineLink.updateLinkedRoadSpline,
}

-- A jump table for removing a linked spline.
local linkRemoveJumpTable = {
  [meshSplineStr] = meshSplineLink.removeLinkedMeshSpline,
  [assemblySplineStr] = assemblySplineLink.removeLinkedAssemblySpline,
  [decalSplineStr] = decalSplineLink.removeLinkedDecalSpline,
  [roadSplineStr] = roadSplineLink.removeLinkedRoadSpline,
}


-- Returns the default values for the slider properties, for use in the tool's front end.
local function getSliderDefaults() return sliderDefaults end

-- Deep copies a layer.
local function deepCopyLayer(layer) return buffer.decode(buffer.encode(layer)) end

-- Deep copies all layers.
local function deepCopyAllLayers(layers) return buffer.decode(buffer.encode(layers)) end

-- Updates the linked layer geometry by sending the nodes to the linked object.
local function updateLinkedLayer(masterSpline, layerIdx)
  local nodes, widths, nmls = masterSpline.nodes, masterSpline.widths, masterSpline.nmls
  if #nodes < 2 then
    local layer = masterSpline.layers[layerIdx]
    if layer.linkedSplineId then -- Set the linked spline dirty, so its objects are cleaned up.
      linkUpdateJumpTable[layer.linkType](layer.linkedSplineId, {}, {}, {}, masterSpline.isLoop, masterSpline.isConformToTerrain)
    end
    return -- Early return if there are insufficient nodes.
  end

  -- Laterally offset the discretized geometry data being passed to the linked object.
  -- Use per-layer persistent buffers to avoid cross-layer aliasing and heavy per-frame allocations.
  local layer = masterSpline.layers[layerIdx]
  local divPoints, divWidths, binormals = masterSpline.divPoints, masterSpline.divWidths, masterSpline.binormals
  local layerBufP, layerBufW, layerBufN = layer.pBuf or {}, layer.wBuf or {}, layer.nBuf or {}
  layer.pBuf, layer.wBuf, layer.nBuf = layerBufP, layerBufW, layerBufN
  local layerPositionHalfWidth, ctr = layer.position * 0.5, 1

  for i = 1, #divPoints do
    local binormal = binormals[i]
    tmp1:setScaled2(binormal, layerPositionHalfWidth * divWidths[i]) -- Apply the lateral offset to every discretiaed point in this layer.
    layerBufP[ctr] = layerBufP[ctr] or vec3()
    layerBufP[ctr]:setAdd2(divPoints[i], tmp1) -- Store the transformed data using get-or-create pattern.
    layerBufW[ctr] = divWidths[i] -- Store the discretized width.
    layerBufN[ctr] = layerBufN[ctr] or vec3()
    layerBufN[ctr]:set(masterSpline.normals[i])  -- Store the discretized normal using get-or-create pattern.
    ctr = ctr + 1
  end

  -- Trim any stale entries beyond ctr-1 in the layer buffers.
  for k = #layerBufP, ctr, -1 do
    layerBufP[k], layerBufW[k], layerBufN[k] = nil, nil, nil
  end

  -- Create temporary copies for RDP simplification (since it modifies in-place).
  local tempPoints, tempWidths, tempNormals = {}, {}, {}
  for i = 1, ctr - 1 do
    tempPoints[i] = vec3(layerBufP[i])
    tempWidths[i] = layerBufW[i]
    tempNormals[i] = vec3(layerBufN[i])
  end

  -- Apply RDP simplification to reduce point count while maintaining accuracy.
  rdp.simplifyNodesWidthsNormals(tempPoints, tempWidths, tempNormals, 0.25)

  -- If the layer is set to be flipped, flip the simplified geometry.
  local pSend, wSend, nSend = tempPoints, tempWidths, tempNormals
  if layer.isFlip then
    local pFlip, wFlip, nFlip = layer.pFlip or {}, layer.wFlip or {}, layer.nFlip or {}
    layer.pFlip, layer.wFlip, layer.nFlip = pFlip, wFlip, nFlip
    local count = #tempPoints
    for i = 1, count do
      local srcIdx = count - i + 1
      pFlip[i] = pFlip[i] or vec3()
      pFlip[i]:set(tempPoints[srcIdx])
      wFlip[i] = tempWidths[srcIdx]
      nFlip[i] = nFlip[i] or vec3()
      nFlip[i]:set(tempNormals[srcIdx])
    end
    for k = #pFlip, count + 1, -1 do
      pFlip[k], wFlip[k], nFlip[k] = nil, nil, nil
    end
    pSend, wSend, nSend = pFlip, wFlip, nFlip
  end

  -- Update the nodes of the linked spline with the simplified offset geometry.
  linkUpdateJumpTable[layer.linkType](layer.linkedSplineId, pSend, wSend, nSend, masterSpline.isLoop, masterSpline.isConformToTerrain)

  local layer = masterSpline.layers[layerIdx]
  layer.isDirty = false
end

-- Updates the properties of all layers.
local function updateAllLayers(masterSpline)
  for i = 1, #masterSpline.layers do
    updateLinkedLayer(masterSpline, i)
  end
end

-- Updates the properties of only the dirty layers.
local function updateOnlyDirtyLayers(masterSpline)
  local layers = masterSpline.layers
  for i = 1, #layers do
    local layer = layers[i]
    if layer.isDirty then
      updateLinkedLayer(masterSpline, i)
      layer.isDirty = false
    end
  end
end

-- Removes a layer at the given index.
local function removeLayer(idx, masterSpline)
  local masterSplineLayers = masterSpline.layers
  local layer = masterSplineLayers[idx]
  local linkedSplineId = layer.linkedSplineId
  if linkedSplineId then
    linkRemoveJumpTable[layer.linkType](linkedSplineId)
  end
  table.remove(masterSplineLayers, idx)
end

-- Removes all layers and their linked splines.
local function removeAllLayers(masterSpline)
  local layers = masterSpline.layers
  for i = #layers, 1, -1 do
    local layer = layers[i]
    local linkedSplineId = layer.linkedSplineId
    if linkedSplineId then
      linkRemoveJumpTable[layer.linkType](linkedSplineId)
    end
    table.remove(layers, i)
  end
end

-- Adds a new layer.
local function addNewLayer(spline)
  spline.layers[#spline.layers + 1] = {
    name = string.format("New Layer %d", #spline.layers + 1),
    id = Engine.generateUUID(),
    isDirty = true,
    isLink = false,
    linkType = defaultLinkType,
    linkedSplineId = nil,
    linkedSplineName = nil,
    isFlip = false,
    position = sliderDefaults.defaultLateralPosition,
 }
end

-- Serialises a layer to a table.
local function serializeLayer(layer)
  return {
    name = layer.name,
    id = layer.id,
    isLink = layer.isLink,
    linkType = layer.linkType,
    linkedSplineId = layer.linkedSplineId,
    linkedSplineName = layer.linkedSplineName,
    isFlip = layer.isFlip,
    isTrackWidth = layer.isTrackWidth,
    position = layer.position,
  }
end

-- Deserialises a layer from a table.
local function deserializeLayer(data)
  return {
    name = data.name,
    id = data.id or Engine.generateUUID(),
    isDirty = true,
    isLink = data.isLink == true,
    linkType = data.linkType or defaultLinkType,
    linkedSplineId = data.linkedSplineId,
    linkedSplineName = data.linkedSplineName,
    isFlip = data.isFlip == true,
    isTrackWidth = data.isTrackWidth == true,
    position = data.position or sliderDefaults.defaultLateralPosition,
  }
end


-- Public interface.
M.getSliderDefaults =                                  getSliderDefaults

M.deepCopyLayer =                                      deepCopyLayer
M.deepCopyAllLayers =                                  deepCopyAllLayers

M.updateAllLayers =                                    updateAllLayers
M.updateOnlyDirtyLayers =                              updateOnlyDirtyLayers

M.removeLayer =                                        removeLayer
M.removeAllLayers =                                    removeAllLayers
M.addNewLayer =                                        addNewLayer

M.serializeLayer =                                     serializeLayer
M.deserializeLayer =                                   deserializeLayer

return M