-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = "Master Spline" -- The global prefix string for the tool.
local editModeKey = "masterSpline" -- The edit mode key for this tool.

local minSplineDivisions = 10 -- The minimum number of subdivisions to use for a Master Spline spline.

local minImportSize = 10.0 -- The minimum size of a mesh spline to import.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'masterSpline'

-- Module dependencies.
local buffer = require('string.buffer')
local layerMgr = require('editor/masterSpline/layerMgr')
local homologation = require('editor/masterSpline/homologation')
local jumps = require('editor/masterSpline/jumpTables')
local roadDesignStandards = require('editor/toolUtilities/roadDesignStandards')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')
local meshSplineLink = require('editor/meshSpline/splineMgr')
local assemblySplineLink = require('editor/assemblySpline/splineMgr')
local decalSplineLink = require('editor/decalSpline/splineMgr')
local roadSplineLink = require('editor/roadSpline/groupMgr')

-- Module constants.
local abs, min, max = math.abs, math.min, math.max
local sliderDefaults = layerMgr.getSliderDefaults()
local roadDesignPresets = roadDesignStandards.getPresetStrings()
local defaultRoadDesignPreset = roadDesignPresets[1]
local setLinkJumpTable = jumps.setLinkJumpTable
local setNameJumpTable = jumps.setNameJumpTable
local createJumpTable = jumps.createJumpTable
local getLastCreatedSplineJumpTable = jumps.getLastCreatedSplineJumpTable
local restoreJumpTable = jumps.restoreJumpTable
local unlinkJumpTable = jumps.unlinkJumpTable
local removeJumpTable = jumps.removeJumpTable
local setLinkedSplineDirtyJumpTable = jumps.setLinkedSplineDirtyJumpTable

-- Module state.
local masterSplines = {}
local splineMap = {}
local tmpPoint2I = Point2I(0, 0)


-- Returns the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Returns the edit mode key.
local function getEditModeKey() return editModeKey end

-- Gets the array of Master Splines.
local function getMasterSplines() return masterSplines end

-- Gets the Master Spline id -> index map.
local function getIdToIdxMap() return splineMap end

-- Sets isDirty flag for all linked splines in a master spline.
local function setLinkedSplinesDirty(masterSpline)
  for _, layer in ipairs(masterSpline.layers) do
    if layer.linkedSplineId and setLinkedSplineDirtyJumpTable[layer.linkType] then
      setLinkedSplineDirtyJumpTable[layer.linkType](layer.linkedSplineId)
    end
  end
end

-- Adds a new Master Spline.
local function addNewMasterSpline(name)
  -- Ensure we have a unique name.
  local baseName = name or string.format(toolPrefixStr .. " %d", #masterSplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create the new Master Spline.
  local newSpline = {
    name = uniqueName,
    id = Engine.generateUUID(),
    isEnabled = true,
    isDirty = false,
    isLoop = false,
    isConformToTerrain = false,

    isAutoBanking = false,
    bankStrength = sliderDefaults.defaultBankStrength,
    autoBankFalloff = sliderDefaults.defaultAutoBankFalloff,

    nodes = {}, -- Primary geometry arrays.
    widths = {},
    nmls = {},

    ribPoints = {}, -- Secondary geometry arrays.
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    layers = {},

    pFlip = {},
    wFlip = {},
    nFlip = {},

    roadLength = 0.0, -- The cached length approximation of the road.

    splineAnalysisMode = 0, -- The visualisation mode for the homologation.
    homologationPreset = defaultRoadDesignPreset, -- The homologation preset.
    isOptimising = false, -- Whether the Master Spline is being optimized live.
    eSlopeNorm = {}, -- Normalised error values [0, 1].
    slopeWorstDivIdx = nil,
    slopeWorstNorm = 0.0,
    eRadiusNorm = {},
    radiusWorstDivIdx = nil,
    radiusWorstNorm = 0.0,
    eBankingNorm = {},
    eWidthNorm = {},
  }

  -- Add the new Master Spline to the Master Splines collection.
  table.insert(masterSplines, newSpline)

  -- Recompute the Master Spline id -> index map.
  util.computeIdToIdxMap(masterSplines, splineMap)

  return newSpline
end

-- Adds a Master Spline to the Master Splines array.
local function addToMasterSplineArray(spline) table.insert(masterSplines, spline) end

-- Removes the Master Spline at the given index.
local function removeMasterSpline(idx)
  local spline = masterSplines[idx]
  if spline then
    layerMgr.removeAllLayers(spline) -- Remove all layers associated with the Master Spline.
    table.remove(masterSplines, idx) -- Remove the Master Spline from the Master Splines collection.
  end
  util.computeIdToIdxMap(masterSplines, splineMap) -- Recompute the Master Spline id -> index map.
end

-- Removes all Master Splines from the session.
local function removeAllMasterSplines()
  for i = #masterSplines, 1, -1 do
    removeMasterSpline(i)
  end
  table.clear(masterSplines)
end

-- Updates the dirty Master Splines.
local function updateDirtyMasterSplines(isSplineAnalysisEnabled)
  for i = 1, #masterSplines do
    local spline = masterSplines[i]
    if spline.isDirty then

      -- Check if we have less than 2 nodes - if so, clean up and skip processing
      if #spline.nodes < 2 then
        -- Clear all secondary geometry.
        table.clear(spline.ribPoints)
        table.clear(spline.divPoints)
        table.clear(spline.divWidths)
        table.clear(spline.tangents)
        table.clear(spline.binormals)
        table.clear(spline.normals)
        table.clear(spline.discMap)
        spline.roadLength = 0.0
        layerMgr.updateAllLayers(spline)
        masterSplines[i].isDirty = false
      else
        -- Update the secondary (discretised) geometry properties.
        if spline.isConformToTerrain then
          local nodes, nmls = spline.nodes, spline.nmls
          local terrain = core_terrain.getTerrain()
          if terrain then
            for j = 1, #nodes do
              local node = nodes[j]
              node.z = terrain:getHeight(node) -- Update the node height to what the local terrain has.
              nmls[j] = geom.getTerrainNormal(node) -- Update the normal to what the local terrain has.
            end
          end
          geom.catmullRomConformToTerrain(spline, minSplineDivisions)
        else
          if spline.isAutoBanking then
            geom.catmullRomFreeWithBanking(spline, minSplineDivisions, spline.bankStrength)
          else
            geom.catmullRomFree(spline, minSplineDivisions)
          end
        end
        geom.updateRibPointsFree(spline) -- Update the rib points.

        -- Update the homologation data, if active.
        if isSplineAnalysisEnabled and #spline.divPoints > 2 then
          homologation.analyseSpline(spline)
        end

        -- Update all the layers.
        layerMgr.updateAllLayers(spline)
        masterSplines[i].isDirty = false

        -- Update the road length.
        masterSplines[i].roadLength = util.getPolyLength(spline.nodes)
      end
    else
      layerMgr.updateOnlyDirtyLayers(spline) -- The Master Spline is not dirty, but it may contain dirty layers.
    end
  end
end

-- Manages the Live Optimise of the selected Master Spline only.
local function manageLiveOptimise(selectedSplineIdx)
  local spline = masterSplines[selectedSplineIdx]
  if spline and spline.isOptimising and #spline.divPoints > 2 then
    local numIter = homologation.getOptimisationIterationsPerFrame()
    homologation.optimiseSpline(spline, numIter)
  end
end

-- Deep copies the given master spline.
local function deepCopyMasterSpline(spline) return buffer.decode(buffer.encode(spline)) end

-- Deep copies the full master spline state.
local function deepCopyAllMasterSplines() return buffer.decode(buffer.encode(masterSplines)) end

-- Captures the state of all linked splines across all master splines.
local function captureLinkedSplinesState()
  local linkedSplines = {
    meshSpline = {},
    assemblySpline = {},
    decalSpline = {},
    roadSpline = {}
  }

  -- Collect all linked spline IDs by type
  local meshSplineIds = {}
  local assemblySplineIds = {}
  local decalSplineIds = {}
  local roadSplineIds = {}

  for _, masterSpline in ipairs(masterSplines) do
    for _, layer in ipairs(masterSpline.layers) do
      if layer.linkedSplineId and layer.linkType then
        if layer.linkType == meshSplineLink.getToolPrefixStr() then
          table.insert(meshSplineIds, layer.linkedSplineId)
        elseif layer.linkType == assemblySplineLink.getToolPrefixStr() then
          table.insert(assemblySplineIds, layer.linkedSplineId)
        elseif layer.linkType == decalSplineLink.getToolPrefixStr() then
          table.insert(decalSplineIds, layer.linkedSplineId)
        elseif layer.linkType == roadSplineLink.getToolPrefixStr() then
          table.insert(roadSplineIds, layer.linkedSplineId)
        end
      end
    end
  end

  -- Deep copy only the linked splines
  local meshSplines = meshSplineLink.getMeshSplines()
  local meshSplineMap = meshSplineLink.getSplineMap()
  for _, id in ipairs(meshSplineIds) do
    local idx = meshSplineMap[id]
    if idx and meshSplines[idx] then
      table.insert(linkedSplines.meshSpline, meshSplineLink.deepCopyMeshSpline(meshSplines[idx]))
    end
  end

  local assemblySplines = assemblySplineLink.getAssemblySplines()
  local assemblySplineMap = assemblySplineLink.getSplineMap()
  for _, id in ipairs(assemblySplineIds) do
    local idx = assemblySplineMap[id]
    if idx and assemblySplines[idx] then
      table.insert(linkedSplines.assemblySpline, assemblySplineLink.deepCopyAssemblySpline(assemblySplines[idx]))
    end
  end

  local decalSplines = decalSplineLink.getDecalSplines()
  local decalSplineMap = decalSplineLink.getSplineMap()
  for _, id in ipairs(decalSplineIds) do
    local idx = decalSplineMap[id]
    if idx and decalSplines[idx] then
      table.insert(linkedSplines.decalSpline, decalSplineLink.deepCopyDecalSpline(decalSplines[idx]))
    end
  end

  local roadSplines = roadSplineLink.getGroups()
  local roadSplineMap = roadSplineLink.getIdToIdxMap()
  for _, id in ipairs(roadSplineIds) do
    local idx = roadSplineMap[id]
    if idx and roadSplines[idx] then
      table.insert(linkedSplines.roadSpline, roadSplineLink.deepCopyGroup(roadSplines[idx]))
    end
  end

  return linkedSplines
end

-- Captures the full trans tier state including both master splines and linked splines.
local function captureTransTierState()
  return {
    masterSplines = deepCopyAllMasterSplines(),
    linkedSplines = captureLinkedSplinesState()
  }
end

-- Splits the given Master Spline at the selected node index.
local function splitMasterSpline(spline, splineIdx, selectedNodeIdx)
  if spline.isLoop then -- To split a loop, we need to re-place all the primary geometry starting at the split point then going round the cycle.
    spline.nodes, spline.widths, spline.nmls = geom.splitLoopSplineGeometry(spline.nodes, spline.widths, spline.nmls, selectedNodeIdx)
    spline.isLoop = false
    spline.isDirty = true
  else -- Split nodes and widths.
    local nodes1, widths1, nmls1, nodes2, widths2, nmls2 = geom.splitSplineGeometry(spline.nodes, spline.widths, spline.nmls, selectedNodeIdx)

    -- Prepare copies.
    local spline1 = deepCopyMasterSpline(spline)
    spline1.name = spline.name .. " (1)"
    spline1.id = Engine.generateUUID()
    spline1.isLoop = false
    spline1.nodes = nodes1
    spline1.widths = widths1
    spline1.nmls = nmls1
    spline1.isDirty = true
    -- Clear layers - we'll handle them properly below
    spline1.layers = {}

    local spline2 = deepCopyMasterSpline(spline)
    spline2.name = spline.name .. " (2)"
    spline2.id = Engine.generateUUID()
    spline2.isLoop = false
    spline2.nodes = nodes2
    spline2.widths = widths2
    spline2.nmls = nmls2
    spline2.isDirty = true

    -- Clear layers - we'll handle them properly below.
    spline2.layers = {}

    -- Handle layers - do a full deep copy of all layers.
    for i = 1, #spline.layers do
      local originalLayer = spline.layers[i]
      local layer1 = layerMgr.deepCopyLayer(originalLayer)
      local layer2 = layerMgr.deepCopyLayer(originalLayer)

      -- Generate new ids for both layers.
      layer1.id = Engine.generateUUID()
      layer2.id = Engine.generateUUID()

      -- Deep copy the linked splines if they exist
      if originalLayer.linkType and originalLayer.linkedSplineId then
        -- Get the existing linked spline data
        local existingSpline = nil
        if originalLayer.linkType == meshSplineLink.getToolPrefixStr() then
          local meshSplines = meshSplineLink.getMeshSplines()
          local meshSplineMap = meshSplineLink.getSplineMap()
          local idx = meshSplineMap[originalLayer.linkedSplineId]
          if idx and meshSplines[idx] then
            existingSpline = meshSplines[idx]
          end
        elseif originalLayer.linkType == assemblySplineLink.getToolPrefixStr() then
          local assemblySplines = assemblySplineLink.getAssemblySplines()
          local assemblySplineMap = assemblySplineLink.getSplineMap()
          local idx = assemblySplineMap[originalLayer.linkedSplineId]
          if idx and assemblySplines[idx] then
            existingSpline = assemblySplines[idx]
          end
        elseif originalLayer.linkType == decalSplineLink.getToolPrefixStr() then
          local decalSplines = decalSplineLink.getDecalSplines()
          local decalSplineMap = decalSplineLink.getSplineMap()
          local idx = decalSplineMap[originalLayer.linkedSplineId]
          if idx and decalSplines[idx] then
            existingSpline = decalSplines[idx]
          end
        elseif originalLayer.linkType == roadSplineLink.getToolPrefixStr() then
          local roadSplines = roadSplineLink.getGroups()
          local roadSplineMap = roadSplineLink.getIdToIdxMap()
          local idx = roadSplineMap[originalLayer.linkedSplineId]
          if idx and roadSplines[idx] then
            existingSpline = roadSplines[idx]
          end
        end

        if existingSpline then
          -- Create copies using the direct tool functions.
          local spline1Copy = nil
          local spline2Copy = nil

          if originalLayer.linkType == meshSplineLink.getToolPrefixStr() then
            spline1Copy = meshSplineLink.deepCopyMeshSpline(existingSpline)
            spline2Copy = meshSplineLink.deepCopyMeshSpline(existingSpline)
            -- Generate new ids for the copied splines.
            spline1Copy.id = Engine.generateUUID()
            spline2Copy.id = Engine.generateUUID()
            -- Add to mesh spline arrays.
            local meshSplines = meshSplineLink.getMeshSplines()
            meshSplines[#meshSplines + 1] = spline1Copy
            meshSplines[#meshSplines + 1] = spline2Copy
            util.computeIdToIdxMap(meshSplines, meshSplineLink.getSplineMap())
          elseif originalLayer.linkType == assemblySplineLink.getToolPrefixStr() then
            spline1Copy = assemblySplineLink.deepCopyAssemblySpline(existingSpline)
            spline2Copy = assemblySplineLink.deepCopyAssemblySpline(existingSpline)
            -- Generate new ids for the copied splines.
            spline1Copy.id = Engine.generateUUID()
            spline2Copy.id = Engine.generateUUID()
            -- Add to assembly spline arrays.
            local assemblySplines = assemblySplineLink.getAssemblySplines()
            assemblySplines[#assemblySplines + 1] = spline1Copy
            assemblySplines[#assemblySplines + 1] = spline2Copy
            util.computeIdToIdxMap(assemblySplines, assemblySplineLink.getSplineMap())
          elseif originalLayer.linkType == decalSplineLink.getToolPrefixStr() then
            spline1Copy = decalSplineLink.deepCopyDecalSpline(existingSpline)
            spline2Copy = decalSplineLink.deepCopyDecalSpline(existingSpline)
            -- Generate new ids for the copied splines.
            spline1Copy.id = Engine.generateUUID()
            spline2Copy.id = Engine.generateUUID()
            -- Add to decal spline arrays.
            local decalSplines = decalSplineLink.getDecalSplines()
            decalSplines[#decalSplines + 1] = spline1Copy
            decalSplines[#decalSplines + 1] = spline2Copy
            util.computeIdToIdxMap(decalSplines, decalSplineLink.getSplineMap())
          elseif originalLayer.linkType == roadSplineLink.getToolPrefixStr() then
            spline1Copy = roadSplineLink.deepCopyGroup(existingSpline)
            spline2Copy = roadSplineLink.deepCopyGroup(existingSpline)
            -- Generate new ids for the copied splines.
            spline1Copy.id = Engine.generateUUID()
            spline2Copy.id = Engine.generateUUID()
            -- Clear the sceneTreeFolderId so addGroupToGroupArray creates fresh folders.
            spline1Copy.sceneTreeFolderId = nil
            spline2Copy.sceneTreeFolderId = nil
            -- Add to road spline arrays.
            roadSplineLink.addGroupToGroupArray(spline1Copy)
            roadSplineLink.addGroupToGroupArray(spline2Copy)
            util.computeIdToIdxMap(roadSplineLink.getGroups(), roadSplineLink.getIdToIdxMap())
          end

          if spline1Copy and spline2Copy then
            -- Update layer references to point to the new copied splines.
            layer1.linkedSplineId = spline1Copy.id
            layer1.linkedSplineName = spline1Copy.name
            layer2.linkedSplineId = spline2Copy.id
            layer2.linkedSplineName = spline2Copy.name

            -- Link the new splines to their respective master splines.
            jumps.setLinkJumpTable[originalLayer.linkType](spline1Copy.id, spline1.id, true)
            jumps.setLinkJumpTable[originalLayer.linkType](spline2Copy.id, spline2.id, true)
          end
        end
      end

      -- Add both layers - they now have their own copied linked splines.
      table.insert(spline1.layers, layer1)
      table.insert(spline2.layers, layer2)

      -- Mark layers as dirty.
      layer1.isDirty = true
      layer2.isDirty = true
    end

    -- Remove the old Master Spline and add the new ones.
    removeMasterSpline(splineIdx)
    addToMasterSplineArray(spline1)
    addToMasterSplineArray(spline2)
  end

  -- Recompute the Master Spline id -> index map.
  util.computeIdToIdxMap(masterSplines, splineMap)
end

-- Joins two unlooped Master Splines into one, modifying spline1 and deleting spline2.
local function joinMasterSplines(splineIdx1, nodeIdx1, splineIdx2, nodeIdx2)
  local spline1, spline2 = masterSplines[splineIdx1], masterSplines[splineIdx2]
  if not spline1 or not spline2 then
    return -- Early return if invalid splines.
  end

  -- Determine join case and concatenate in correct order.
  local n1, w1, nm1 = spline1.nodes, spline1.widths, spline1.nmls
  local n2, w2, nm2 = spline2.nodes, spline2.widths, spline2.nmls
  local nodesNew, widthsNew, nmlsNew = geom.joinSplineGeometry(n1, w1, nm1, nodeIdx1, n2, w2, nm2, nodeIdx2)
  if not nodesNew then
    return -- Early return if invalid node indices.
  end

  -- Apply joined geometry to spline1
  spline1.nodes = nodesNew
  spline1.widths = widthsNew
  spline1.nmls = nmlsNew
  spline1.isLoop = false
  spline1.isDirty = true

  -- Remove spline2.
  removeMasterSpline(splineIdx2)

  -- Recompute map for consistency.
  util.computeIdToIdxMap(masterSplines, splineMap)
end

-- Serialises a Master Spline.
local function serializeMasterSpline(spline)
  -- Serialise the nodes and nmls.
  local serializedNodes, serializedNmls, splineNodes, splineNmls = {}, {}, spline.nodes, spline.nmls
  for i = 1, #splineNodes do
    local p = splineNodes[i]
    serializedNodes[i] = { x = p.x, y = p.y, z = p.z }
    local n = splineNmls[i]
    serializedNmls[i] = { x = n.x, y = n.y, z = n.z }
  end

  -- Serialise the layers.
  local serializedLayers, splineLayers = {}, spline.layers
  for i = 1, #splineLayers do
    serializedLayers[i] = layerMgr.serializeLayer(splineLayers[i])
  end

  -- Serialise the Master Spline properties.
  return {
    name = spline.name,
    id = spline.id,
    isLoop = spline.isLoop,
    isEnabled = spline.isEnabled,
    isConformToTerrain = spline.isConformToTerrain,
    splineAnalysisMode = spline.splineAnalysisMode,
    homologationPreset = spline.homologationPreset,
    isAutoBanking = spline.isAutoBanking,
    bankStrength = spline.bankStrength,
    autoBankFalloff = spline.autoBankFalloff,
    nodes = serializedNodes,
    widths = spline.widths or {},
    nmls = serializedNmls,
    layers = serializedLayers,
  }
end

-- Deserialises a Master Spline.
local function deserializeMasterSpline(data)
  -- Deserialise the nodes.
  local nodes = data.nodes or {}
  local deserializedNodes = {}
  for i = 1, #nodes do
    local p = nodes[i]
    deserializedNodes[i] = vec3(p.x, p.y, p.z)
  end

  -- Deserialise the normals.
  local nmls = data.nmls or {}
  local deserializedNmls = {}
  for i = 1, #nmls do
    local n = nmls[i]
    deserializedNmls[i] = vec3(n.x, n.y, n.z)
  end

  -- Deserialise the layers.
  local splineLayers = data.layers or {}
  local deserializedLayers = {}
  for i = 1, #splineLayers do
    deserializedLayers[i] = layerMgr.deserializeLayer(splineLayers[i])
  end

  -- Deserialise the Master Spline properties.
  return {
    name = data.name or "?",
    id = data.id or Engine.generateUUID(),
    isDirty = true,
    isEnabled = (data.isEnabled == true or data.isEnabled == 1) and true or false,
    isLoop = (data.isLoop == true or data.isLoop == 1) and true or false,

    isConformToTerrain = (data.isConformToTerrain == true or data.isConformToTerrain == 1) and true or false,
    isAutoBanking = (data.isAutoBanking == true or data.isAutoBanking == 1) and true or false,
    bankStrength = data.bankStrength or 1.0,
    autoBankFalloff = data.autoBankFalloff or sliderDefaults.defaultAutoBankFalloff,

    roadLength = 0.0,

    splineAnalysisMode = data.splineAnalysisMode or 0, -- The visualisation mode for the homologation.
    homologationPreset = data.homologationPreset or defaultRoadDesignPreset, -- The homologation preset.
    isOptimising = false,
    eSlopeNorm = {}, -- The homologation data will be regenerated on next update.
    slopeWorstDivIdx = nil,
    slopeWorstNorm = 0.0,
    eRadiusNorm = {},
    radiusWorstDivIdx = nil,
    radiusWorstNorm = 0.0,
    eBankingNorm = {},
    eWidthNorm = {},

    nodes = deserializedNodes, -- The primary geometry arrays are deserialised.
    widths = data.widths or {},
    nmls = deserializedNmls,

    ribPoints = {}, -- The secondary geometry arrays will be regenerated on update.
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},

    pFlip = {}, -- Work arrays for layer geometry processing.
    wFlip = {},
    nFlip = {},

    layers = deserializedLayers,
  }
end

-- Updates all links to the given Master Spline, but nothing outside that.
local function updateLinksToThisSpline(spline)
  local splineId, layers = spline.id, spline.layers

  -- First, unlink each spline directly using existing maps (no allocations).
  for j = 1, #layers do
    local layer = layers[j]
    if layer.linkedSplineId then
      unlinkJumpTable[layer.linkType](layer.linkedSplineId)
    end
  end

  -- Then, re-link the layers.
  for j = 1, #layers do
    local layer = layers[j]
    setLinkJumpTable[layer.linkType](layer.linkedSplineId, splineId, true)
    layer.isDirty = true
  end
end

-- Undo/redo core for light Master Spline changes.
local function lightMasterSplineUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx then
    local spline = masterSplines[idx]

    -- Copy the data into the existing spline object.
    spline.name = data.name
    spline.id = data.id
    spline.isEnabled = data.isEnabled
    spline.isLoop = data.isLoop
    spline.nodes = data.nodes
    spline.widths = data.widths
    spline.nmls = data.nmls
    spline.isConformToTerrain = data.isConformToTerrain
    spline.isAutoBanking = data.isAutoBanking
    spline.bankStrength = data.bankStrength
    spline.autoBankFalloff = data.autoBankFalloff or sliderDefaults.defaultAutoBankFalloff
    spline.splineAnalysisMode = data.splineAnalysisMode
    spline.homologationPreset = data.homologationPreset
    spline.isOptimising = data.isOptimising

    -- Clear secondary geometry arrays to force regeneration.
    spline.ribPoints = {}
    spline.divPoints = {}
    spline.divWidths = {}
    spline.tangents = {}
    spline.binormals = {}
    spline.normals = {}
    spline.discMap = {}

    -- Copy layers.
    spline.layers = layerMgr.deepCopyAllLayers(data.layers)

    -- Set isDirty flag for all linked splines.
    setLinkedSplinesDirty(spline)

    spline.isDirty = true
  end
end

-- Handles the undo/redo for light Master Spline changes.
local function lightSplineUndo(data) lightMasterSplineUndoRedoCore(data.old) end

-- Handles the redo for light Master Spline changes.
local function lightSplineRedo(data) lightMasterSplineUndoRedoCore(data.new) end

-- Undo/redo core for single Master Spline changes.
local function singleMasterSplineUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx then
    local spline = masterSplines[idx]

    layerMgr.removeAllLayers(spline) -- Remove all layers and their linked splines.

    spline.name = data.name
    spline.id = data.id
    spline.isDirty = true -- Set the dirty flag to true.
    spline.isEnabled = data.isEnabled
    spline.isLoop = data.isLoop

    spline.nodes = data.nodes -- The primary geometry arrays are deserialised.
    spline.widths = data.widths
    spline.nmls = data.nmls

    spline.ribPoints = {} -- The secondary geometry arrays will be regenerated on next update.
    spline.divPoints = {}
    spline.divWidths = {}
    spline.tangents = {}
    spline.binormals = {}
    spline.normals = {}
    spline.discMap = {}

    spline.layers = layerMgr.deepCopyAllLayers(data.layers) -- Need to deep copy all layers from the undo/redo history.

    spline.isConformToTerrain = data.isConformToTerrain
    spline.isAutoBanking = data.isAutoBanking
    spline.bankStrength = data.bankStrength
    spline.autoBankFalloff = data.autoBankFalloff

    spline.splineAnalysisMode = data.splineAnalysisMode
    spline.homologationPreset = data.homologationPreset -- The homologation preset.
    spline.isOptimising = data.isOptimising
    spline.eSlopeNorm = {} -- The homologation data will be regenerated on next update.
    spline.slopeWorstDivIdx = nil
    spline.slopeWorstNorm = 0.0
    spline.eRadiusNorm = {}
    spline.radiusWorstDivIdx = nil
    spline.radiusWorstNorm = 0.0
    spline.eBankingNorm = {}
    spline.eWidthNorm = {}

    -- Re-link the layers.
    updateLinksToThisSpline(spline)

    -- Set the isDirty flag to ensure proper updates.
    spline.isDirty = true

    -- Set isDirty flag for all linked splines.
    setLinkedSplinesDirty(spline)
  end
end

-- Handles the undo/redo for single Master Spline edits.
local function singleMasterSplineEditUndo(data) singleMasterSplineUndoRedoCore(data.old) end

-- Undo/redo core for trans-Master Spline edits.
local function transMasterSplineUndoRedoCore(stateData)
  -- Step 1: Smart unlinking - unlink currently linked splines using existing jump table.
  for i = 1, #masterSplines do
    local layers = masterSplines[i].layers
    for j = 1, #layers do
      local layer = layers[j]
      if layer.linkedSplineId then
        unlinkJumpTable[layer.linkType](layer.linkedSplineId)
      end
    end
  end

  -- Step 2: Restore linked splines if they exist in the state.
  if stateData.linkedSplines then
    -- Restore mesh splines
    for _, meshSpline in ipairs(stateData.linkedSplines.meshSpline) do
      if not meshSplineLink.isLinked(meshSpline.id) then
        local spline = meshSplineLink.deepCopyMeshSpline(meshSpline)
        local meshSplines = meshSplineLink.getMeshSplines()
        meshSplines[#meshSplines + 1] = spline
        util.computeIdToIdxMap(meshSplines, meshSplineLink.getSplineMap())
      end
    end

    -- Restore assembly splines
    for _, assemblySpline in ipairs(stateData.linkedSplines.assemblySpline) do
      if not assemblySplineLink.isLinked(assemblySpline.id) then
        local spline = assemblySplineLink.deepCopyAssemblySpline(assemblySpline)
        local assemblySplines = assemblySplineLink.getAssemblySplines()
        assemblySplines[#assemblySplines + 1] = spline
        util.computeIdToIdxMap(assemblySplines, assemblySplineLink.getSplineMap())
      end
    end

    -- Restore decal splines
    for _, decalSpline in ipairs(stateData.linkedSplines.decalSpline) do
      if not decalSplineLink.isLinked(decalSpline.id) then
        local spline = decalSplineLink.deepCopyDecalSpline(decalSpline)
        local decalSplines = decalSplineLink.getDecalSplines()
        decalSplines[#decalSplines + 1] = spline
        -- Set a unique name to avoid conflicts.
        if setNameJumpTable[decalSplineLink.getToolPrefixStr()] then
          local baseName = decalSpline.name or "Decal Spline"
          local uniqueName = baseName .. " - " .. string.sub(spline.id, 1, 8)
          setNameJumpTable[decalSplineLink.getToolPrefixStr()](spline.id, uniqueName)
        end
        util.computeIdToIdxMap(decalSplines, decalSplineLink.getSplineMap())
      end
    end

    -- Restore road splines
    for _, roadSpline in ipairs(stateData.linkedSplines.roadSpline) do
      if not roadSplineLink.isLinked(roadSpline.id) then
        local spline = roadSplineLink.deepCopyGroup(roadSpline)
        -- Clear the sceneTreeFolderId so addGroupToGroupArray creates fresh folders.
        spline.sceneTreeFolderId = nil
        roadSplineLink.addGroupToGroupArray(spline)
        util.computeIdToIdxMap(roadSplineLink.getGroups(), roadSplineLink.getIdToIdxMap())
      end
    end
  end

  -- Step 3: Remove and restore master splines.
  removeAllMasterSplines() -- Remove all Master Splines.
  for i = 1, #stateData.masterSplines do
    addToMasterSplineArray(deepCopyMasterSpline(stateData.masterSplines[i])) -- Add the given Master Spline.
  end
  util.computeIdToIdxMap(masterSplines, splineMap) -- Recompute the Master Spline id -> index map.

  -- Step 4: Smart re-linking - link only what the restored state requires.
  for i = 1, #masterSplines do
    local spline = masterSplines[i]
    local splineId = spline.id
    local layers = spline.layers
    for j = 1, #layers do
      local layer = layers[j]
      if layer.linkedSplineId then
        setLinkJumpTable[layer.linkType](layer.linkedSplineId, splineId, true)
        layer.isDirty = true
      end
    end
  end

  -- Step 5: Set the isDirty flag for all master splines to ensure proper updates.
  for i = 1, #masterSplines do
    masterSplines[i].isDirty = true
    setLinkedSplinesDirty(masterSplines[i]) -- Set isDirty flag for all linked splines.
  end
end

-- Handles the undo/redo for trans-Master Spline edits.
local function transMasterSplineEditUndo(splinesData) 
  transMasterSplineUndoRedoCore(splinesData.old) 
end

-- Redefine the redo functions to include enhanced functionality.
local function singleMasterSplineEditRedo(data)
  singleMasterSplineUndoRedoCore(data.new)

  -- Recreate any linked splines that were deleted during the action.
  local spline = masterSplines[splineMap[data.new.id]]
  if spline then
    for _, layer in ipairs(spline.layers) do
      if layer.linkedSplineId and not (meshSplineLink.isLinked(layer.linkedSplineId) or assemblySplineLink.isLinked(layer.linkedSplineId) or decalSplineLink.isLinked(layer.linkedSplineId) or roadSplineLink.isLinked(layer.linkedSplineId)) then
        -- The linked spline was deleted, create a new default one.
        if createJumpTable[layer.linkType] then
          createJumpTable[layer.linkType]()
          local newSpline = getLastCreatedSplineJumpTable[layer.linkType]()
          if newSpline then
            layer.linkedSplineId = newSpline.id
            layer.linkedSplineName = newSpline.name
            if setNameJumpTable[layer.linkType] then
              setNameJumpTable[layer.linkType](newSpline.id, layer.name)
            end
            setLinkJumpTable[layer.linkType](newSpline.id, spline.id, true)
          end
        end
      end
    end
  end
end

local function transMasterSplineEditRedo(splinesData)
  transMasterSplineUndoRedoCore(splinesData.new)
end

-- Layer-specific undo/redo operations for adding layers.
local function undoLayerAdd(data)
  local idx = splineMap[data.masterSplineId]
  if idx then
    local spline = masterSplines[idx]

    -- Remove the layer from the master spline's layer table.
    table.remove(spline.layers, data.layerIndex)

    -- Remove the linked spline and unlink it.
    local linkedSplineData = data.linkedSplineData
    if linkedSplineData then
      local type = linkedSplineData.type
      if removeJumpTable[type] then
        removeJumpTable[type](linkedSplineData.id)
      end
    end

    -- Set master spline dirty.
    spline.isDirty = true
  end
end

local function redoLayerAdd(data)
  local idx = splineMap[data.masterSplineId]
  if idx then
    local spline = masterSplines[idx]

    -- Create a new layer with default values.
    local newLayer = {
      name = "[link] Layer " .. (#spline.layers + 1),
      id = data.linkedSplineData.id,
      isDirty = true,
      isLink = false,
      linkType = nil,
      linkedSplineId = nil,
      linkedSplineName = nil,
      isFlip = false,
      position = 0.0,
      isTrackWidth = false,
    }

    -- Insert the layer at the specified index.
    table.insert(spline.layers, data.layerIndex, newLayer)

    -- Restore the linked spline and relink it.
    local linkedSplineData = data.linkedSplineData
    if linkedSplineData then
      if restoreJumpTable[linkedSplineData.type] then
        local restoredSpline = restoreJumpTable[linkedSplineData.type](linkedSplineData.data)
        if restoredSpline then
          -- Update the layer with the restored spline info.
          newLayer.linkType = linkedSplineData.type
          newLayer.linkedSplineId = restoredSpline.id
          newLayer.linkedSplineName = restoredSpline.name

          -- Relink the spline to the master spline.
          setLinkJumpTable[linkedSplineData.type](restoredSpline.id, spline.id, true)
        end
      end
    end

    -- Set master spline dirty.
    spline.isDirty = true
  end
end

-- Layer-specific undo/redo operations for removing layers.
local function undoLayerRemove(data)
  local idx = splineMap[data.masterSplineId]
  if idx then
    local spline = masterSplines[idx]

    -- Create a new layer with default values.
    local newLayer = {
      name = "[link] Layer " .. (#spline.layers + 1),
      id = data.linkedSplineData.id,
      isDirty = true,
      isLink = false,
      linkType = nil,
      linkedSplineId = nil,
      linkedSplineName = nil,
      isFlip = false,
      position = 0.0,
      isTrackWidth = false,
    }

    -- Insert the layer at the specified index.
    table.insert(spline.layers, data.layerIndex, newLayer)

    -- Restore the linked spline and relink it.
    local linkedSplineData = data.linkedSplineData
    if linkedSplineData then
      if restoreJumpTable[linkedSplineData.type] then
        local restoredSpline = restoreJumpTable[linkedSplineData.type](linkedSplineData.data)
        if restoredSpline then
          -- Update the layer with the restored spline info.
          newLayer.linkType = linkedSplineData.type
          newLayer.linkedSplineId = restoredSpline.id
          newLayer.linkedSplineName = restoredSpline.name

          -- Relink the spline to the master spline.
          setLinkJumpTable[linkedSplineData.type](restoredSpline.id, spline.id, true)
        end
      end
    end

    -- Set master spline dirty.
    spline.isDirty = true
  end
end

local function redoLayerRemove(data)
  local idx = splineMap[data.masterSplineId]
  if idx then
    local spline = masterSplines[idx]

    -- Remove the layer from the master spline's layer table.
    table.remove(spline.layers, data.layerIndex)

    -- Remove the linked spline and unlink it.
    local linkedSplineData = data.linkedSplineData
    if linkedSplineData then
      local type = linkedSplineData.type
      if removeJumpTable[type] then
        removeJumpTable[type](linkedSplineData.id)
      end
    end

    -- Set master spline dirty.
    spline.isDirty = true
  end
end

-- Updates a linked spline's name to match a layer name.
local function updateLinkedSplineName(splineId, linkType, newName) setNameJumpTable[linkType](splineId, newName) end

-- Undo callback for adding a new master spline.
local function undoAddNewMasterSpline(data)
  -- Remove the master spline by id.
  local idx = splineMap[data.masterSplineId]
  if idx then
    removeMasterSpline(idx)
  end
end

-- Redo callback for adding a new master spline.
local function redoAddNewMasterSpline(data)
  local newSpline = addNewMasterSpline()
  newSpline.id = data.masterSplineId
  util.computeIdToIdxMap(masterSplines, splineMap)
end

-- Unlinks all splines from the given Master Spline (separated so as not to be called with undo/redo).
local function unlinkAllSplines(masterSpline)
  local layers = masterSpline.layers
  for i = 1, #layers do
    local layer = layers[i]
    unlinkJumpTable[layer.linkType](layer.linkedSplineId) -- Unlink the spline from the Master Spline.
  end
end

-- Converts the given paths (traced from a bitmap) to Master Splines.
local function convertPathsToMasterSplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new Master Spline.
    addNewMasterSpline()
    local spline = masterSplines[#masterSplines]

    -- Convert the grid points to world space.
    local points = path.points
    local numPoints = #points
    local pointsWS = {}
    for j = 1, numPoints do
      local pointGrid = points[j]
      tmpPoint2I.x, tmpPoint2I.y = pointGrid.x, pointGrid.y
      pointsWS[j] = te:gridToWorldByPoint2I(tmpPoint2I, tb)
    end

    -- If the path is sufficiently large, then import it.
    local aabb = geom.getAABB(pointsWS)
    if min(abs(aabb.xMax - aabb.xMin), abs(aabb.yMax - aabb.yMin)) > minImportSize then
      spline.nodes, spline.widths = pointsWS, path.widths -- Set the nodes and widths directly.
      for j = 1, numPoints do
        spline.nmls[j] = geom.getTerrainNormal(pointsWS[j]) -- Compute the normals for each node.
      end
    end
  end
  log('I', logTag, string.format("Converted %d traced paths to Master Splines. %d paths were too small to import.", #paths, #paths - #masterSplines))
end


-- Public interface.
M.getToolPrefixStr =                                    getToolPrefixStr
M.getEditModeKey =                                      getEditModeKey

M.getMasterSplines =                                    getMasterSplines
M.getIdToIdxMap =                                       getIdToIdxMap

M.addToMasterSplineArray =                              addToMasterSplineArray

M.removeMasterSpline =                                  removeMasterSpline
M.removeAllMasterSplines =                              removeAllMasterSplines

M.updateDirtyMasterSplines =                            updateDirtyMasterSplines

M.manageLiveOptimise =                                  manageLiveOptimise

M.addNewMasterSpline =                                  addNewMasterSpline

M.deepCopyMasterSpline =                                deepCopyMasterSpline
M.deepCopyAllMasterSplines =                            deepCopyAllMasterSplines
M.captureLinkedSplinesState =                           captureLinkedSplinesState
M.captureTransTierState =                               captureTransTierState

M.splitMasterSpline =                                   splitMasterSpline
M.joinMasterSplines =                                   joinMasterSplines

M.convertPathsToMasterSplines =                         convertPathsToMasterSplines

M.serializeMasterSpline =                               serializeMasterSpline
M.deserializeMasterSpline =                             deserializeMasterSpline

M.lightSplineUndo =                                     lightSplineUndo
M.lightSplineRedo =                                     lightSplineRedo
M.singleMasterSplineEditUndo =                          singleMasterSplineEditUndo
M.singleMasterSplineEditRedo =                          singleMasterSplineEditRedo
M.undoLayerAdd =                                        undoLayerAdd
M.redoLayerAdd =                                        redoLayerAdd
M.undoLayerRemove =                                     undoLayerRemove
M.redoLayerRemove =                                     redoLayerRemove
M.undoAddNewMasterSpline =                              undoAddNewMasterSpline
M.redoAddNewMasterSpline =                              redoAddNewMasterSpline
M.transMasterSplineEditUndo =                           transMasterSplineEditUndo
M.transMasterSplineEditRedo =                           transMasterSplineEditRedo

M.updateLinkedSplineName =                              updateLinkedSplineName
M.unlinkAllSplines =                                    unlinkAllSplines

return M