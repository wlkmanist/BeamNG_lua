-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local toolPrefixStr = 'Sidewalk Spline' -- The global prefix for the sidewalk spline tool.
local editModeKey = 'sidewalkSplineEditMode' -- The edit mode key for this tool.

local minSplineDivisions = 100 -- The minimum number of subdivisions to use for a sidewalk spline.

-- Default slider parameters for UI.
local defaultParams = {
  verticalOffset = 0.0, -- The vertical offset of the sidewalk spline.
  jitterAmount = 0.0, -- The amount of jitter (rotation randomization) applied to pieces.
  alignmentWeight = 25.0, -- The weight of alignment vs distance in piece scoring (higher = prioritise orientation).
  splineRandomSeed = 0, -- The random seed for the sidewalk spline piece placement and variation.
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local buffer = require('string.buffer')
local kit = require('editor/sidewalkSpline/kit')
local pop = require('editor/sidewalkSpline/populate')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')


-- Module state.
local sidewalkSplines = {}
local splineMap = {}
local copiedProfile = nil


-- Fetches the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Fetches the edit mode key.
local function getEditModeKey() return editModeKey end

-- Fetches the sidewalk splines.
local function getSidewalkSplines() return sidewalkSplines end

-- Fetches the sidewalk spline map.
local function getSplineMap() return splineMap end

-- Sets the sidewalk spline with the given index.
local function setSidewalkSpline(spline, idx)
  sidewalkSplines[idx] = spline

  -- Ensure we have a unique sidewalk spline name.
  local baseName = spline.name
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new scene tree folder for the sidewalk spline.
  if not spline.sceneTreeFolderId or not scenetree.findObjectById(spline.sceneTreeFolderId) then
    local newFolder = createObject("SimGroup")
    local folderNameId = Engine.generateUUID()
    newFolder:registerObject(string.format("%s - %s", uniqueName, folderNameId))
    scenetree.MissionGroup:addObject(newFolder)
    spline.sceneTreeFolderId = newFolder:getId()
  end
  spline.isDirty = true
end

-- Sets the sidewalk splines (full table).
local function setSidewalkSplines(splines)
  for i = 1, #splines do
    setSidewalkSpline(splines[i], i)
  end
end

-- Returns the default slider parameters.
local function getDefaultSliderParams() return defaultParams end

-- Adds a new sidewalk spline.
local function addNewSidewalkSpline()
  -- Ensure we have a unique sidewalk spline name.
  local baseName = string.format(toolPrefixStr .. " %d", #sidewalkSplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
  local id = Engine.generateUUID()

  -- Create a new scene tree folder for the sidewalk spline.
  local newFolder = createObject("SimGroup")
  newFolder:registerObject(string.format("%s - %s", uniqueName, id))
  scenetree.MissionGroup:addObject(newFolder)

  -- Create a new sidewalk spline.
  table.insert(sidewalkSplines, {
    name = uniqueName, -- Core properties.
    id = id,
    isLoop = false,
    sceneTreeFolderId = newFolder:getId(),
    isDirty = false,
    isEnabled = true,

    isLink = false, -- Linking properties (for use with Master Spline tool).
    linkId = nil,

    nodes = {}, -- Primary geometry.
    widths = {},
    nmls = {},

    divPoints = {}, -- Secondary geometry.
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},

    discMap = {}, -- Map from node to div point.

    verticalOffset = defaultParams.verticalOffset,
    isConformToTerrain = false,
    jitterAmount = defaultParams.jitterAmount,
    alignmentWeight = defaultParams.alignmentWeight,
    splineRandomSeed = defaultParams.splineRandomSeed,

    pieceDistribution = {}, -- Distribution settings per piece: {[pieceIndex] = {isRandom = false, baseWeight = 1.0, varWeights = {}}}.

    roadLength = 0.0,

    kitFolderPath = nil, -- Mesh kit properties.
    meshKit = {},
    kitDescription = {},
    pieceEnabledStates = {},
    distributionGroups = {},
    isImported = false,
    importedKit = {},
  })

  -- Update the spline map.
  util.computeIdToIdxMap(sidewalkSplines, splineMap)
end

-- Removes the sidewalk spline with the given index.
local function removeSidewalkSpline(idx)
  if idx <= 0 or idx > #sidewalkSplines then
    return -- Early return if invalid index.
  end

  local spline = sidewalkSplines[idx]
  pop.tryRemove(spline) -- Remove the meshes from the world.

  -- Remove the scene tree folder.
  if spline.sceneTreeFolderId then
    local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
    if folder then
      folder:delete()
    end
  end

  table.remove(sidewalkSplines, idx)
  util.computeIdToIdxMap(sidewalkSplines, splineMap)
end

-- Removes all sidewalk splines.
-- [If isIncludeDisabled is false, then only enabled sidewalk splines will be removed.]
local function removeAllSidewalkSplines(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #sidewalkSplines, 1, -1 do
      local spline = sidewalkSplines[i]
      if spline then
        removeSidewalkSpline(i)
      end
    end
  else
    for i = #sidewalkSplines, 1, -1 do
      local spline = sidewalkSplines[i]
      if spline and spline.isEnabled and not spline.isLink then -- Only remove enabled and unlinked sidewalk splines.
        removeSidewalkSpline(i)
      end
    end
  end
end

-- Deep copies the given sidewalk spline.
local function deepCopySidewalkSpline(spline)
  local copy = buffer.decode(buffer.encode(spline))
  table.clear(copy.divPoints)
  table.clear(copy.divWidths)
  table.clear(copy.tangents)
  table.clear(copy.binormals)
  table.clear(copy.normals)
  table.clear(copy.discMap)
  return copy
end

-- Deep copies the full sidewalk spline state.
local function deepCopySidewalkSplineState()
  local copy = {}
  for i = 1, #sidewalkSplines do
    copy[i] = deepCopySidewalkSpline(sidewalkSplines[i])
  end
  return copy
end

-- Splits a sidewalk spline at the given node index.
local function splitSidewalkSpline(splineIdx, nodeIdx)
  local spline = sidewalkSplines[splineIdx]
  if not spline or nodeIdx <= 1 or nodeIdx >= #spline.nodes then
    return -- Invalid split position.
  end

  local copy = deepCopySidewalkSpline(spline)

  -- Modify first spline (A) to end at split point.
  spline.name = copy.name .. '_split_A'
  spline.isDirty = true
  spline.isLoop = false
  spline.isLink = false
  spline.linkId = nil
  spline.isEnabled = true

  spline.verticalOffset = copy.verticalOffset
  spline.isConformToTerrain = copy.isConformToTerrain
  spline.jitterAmount = copy.jitterAmount
  spline.alignmentWeight = copy.alignmentWeight
  spline.splineRandomSeed = copy.splineRandomSeed
  spline.pieceDistribution = deepcopy(copy.pieceDistribution)
  spline.roadLength = 0.0

  spline.kitFolderPath = copy.kitFolderPath
  spline.meshKit = deepcopy(copy.meshKit)
  spline.kitDescription = deepcopy(copy.kitDescription)
  spline.pieceEnabledStates = deepcopy(copy.pieceEnabledStates)
  spline.distributionGroups = deepcopy(copy.distributionGroups)
  spline.isImported = copy.isImported
  spline.importedKit = deepcopy(copy.importedKit)

  local nodes1, widths1, nmls1, nodes2, widths2, nmls2 = geom.splitSplineGeometry(copy.nodes, copy.widths, copy.nmls, nodeIdx)

  spline.nodes, spline.widths, spline.nmls = nodes1, widths1, nmls1

  -- Add second half (B).
  addNewSidewalkSpline()
  local splineB = sidewalkSplines[#sidewalkSplines]
  splineB.name = copy.name .. '_split_B'
  splineB.isDirty = true
  splineB.isLoop = false
  splineB.isLink = false
  splineB.linkId = nil
  splineB.isEnabled = true

  splineB.verticalOffset = copy.verticalOffset
  splineB.isConformToTerrain = copy.isConformToTerrain
  splineB.jitterAmount = copy.jitterAmount
  splineB.alignmentWeight = copy.alignmentWeight
  splineB.splineRandomSeed = copy.splineRandomSeed
  splineB.roadLength = 0.0

  splineB.kitFolderPath = copy.kitFolderPath
  splineB.meshKit = deepcopy(copy.meshKit)
  splineB.kitDescription = deepcopy(copy.kitDescription)
  splineB.pieceEnabledStates = deepcopy(copy.pieceEnabledStates)
  splineB.distributionGroups = deepcopy(copy.distributionGroups)
  splineB.isImported = copy.isImported
  splineB.importedKit = deepcopy(copy.importedKit)

  splineB.nodes, splineB.widths, splineB.nmls = nodes2, widths2, nmls2

  util.computeIdToIdxMap(sidewalkSplines, splineMap)
end

-- Joins two unlooped Sidewalk Splines into one, modifying spline1 and deleting spline2.
local function joinSidewalkSplines(splineIdx1, nodeIdx1, splineIdx2, nodeIdx2)
  local spline1, spline2 = sidewalkSplines[splineIdx1], sidewalkSplines[splineIdx2]
  if not spline1 or not spline2 then
    return -- Early return if invalid splines.
  end

  -- Determine join case and concatenate in correct order.
  local n1, w1, nm1 = spline1.nodes, spline1.widths, spline1.nmls
  local n2, w2, nm2 = spline2.nodes, spline2.widths, spline2.nmls
  local nodesNew, widthsNew, nmlsNew = geom.joinSplineGeometry(n1, w1, nm1, nodeIdx1, n2, w2, nm2, nodeIdx2)
  if not nodesNew then
    return -- Early return if invalid join case.
  end

  -- Apply joined geometry to spline1.
  spline1.nodes = nodesNew
  spline1.widths = widthsNew
  spline1.nmls = nmlsNew
  spline1.isLoop = false
  spline1.isDirty = true

  -- Remove spline2 safely and directly
  removeSidewalkSpline(splineIdx2)

  -- Recompute map for stability
  util.computeIdToIdxMap(sidewalkSplines, splineMap)
end

-- Undo/redo core function.
local function singleSplineEditUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx then
    -- Remove the spline if it has less than 2 nodes.
    local spline = sidewalkSplines[idx]
    if #data.nodes < 2 then
      pop.tryRemove(spline)
    end

    -- Update the spline with the new data.
    spline.name = data.name
    spline.isDirty = true -- Set the dirty flag to true.
    spline.isEnabled = data.isEnabled
    spline.isLoop = data.isLoop
    spline.isLink = data.isLink
    spline.linkId = data.linkId

    spline.nodes = data.nodes
    spline.widths = data.widths
    spline.nmls = data.nmls

    spline.verticalOffset = data.verticalOffset
    spline.jitterAmount = data.jitterAmount or data.playAmount or defaultParams.jitterAmount
    spline.alignmentWeight = data.alignmentWeight or defaultParams.alignmentWeight
    spline.isConformToTerrain = data.isConformToTerrain
    spline.splineRandomSeed = data.splineRandomSeed
    spline.pieceDistribution = data.pieceDistribution

    spline.roadLength = data.roadLength

    spline.kitFolderPath = data.kitFolderPath
    spline.meshKit = data.meshKit
    spline.kitDescription = data.kitDescription
    spline.pieceEnabledStates = data.pieceEnabledStates
    spline.distributionGroups = data.distributionGroups
    spline.isImported = data.isImported
    spline.importedKit = data.importedKit

    -- Special case for when the sidewalk spline has been renamed.
    if data.isUpdateSceneTree then
      local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
      if folder then
        folder:setName(spline.name)
      end
      editor.refreshSceneTreeWindow()
    end
  end
end

-- Handles the undo for a single sidewalk spline.
local function singleSplineEditUndo(sidewalkSplineData)
  local data = sidewalkSplineData.old
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the redo for a single sidewalk spline.
local function singleSplineEditRedo(sidewalkSplineData)
  local data = sidewalkSplineData.new
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the undo for trans-sidewalkspline edits.
local function transSplineEditUndo(data)
  removeAllSidewalkSplines(true)
  setSidewalkSplines(data.old)
  for i = 1, #sidewalkSplines do
    sidewalkSplines[i].isDirty = true
  end

  -- Update the spline map.
  util.computeIdToIdxMap(sidewalkSplines, splineMap)
end

-- Handles the redo for trans-sidewalkspline edits.
local function transSplineEditRedo(data)
  removeAllSidewalkSplines(true)
  setSidewalkSplines(data.new)
  for i = 1, #sidewalkSplines do
    sidewalkSplines[i].isDirty = true
  end

  -- Update the spline map.
  util.computeIdToIdxMap(sidewalkSplines, splineMap)
end

-- Core function for the object select undo/redo.
local function objectSelectUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx and sidewalkSplines[idx] then
    pop.tryRemove(sidewalkSplines[idx])
    sidewalkSplines[idx] = data
    sidewalkSplines[idx].isDirty = true
    util.computeIdToIdxMap(sidewalkSplines, splineMap)
  end
end

-- Undo callback for object select operations.
local function objectSelectUndo(data) objectSelectUndoRedoCore(data.old) end

-- Redo callback for object select operations.
local function objectSelectRedo(data) objectSelectUndoRedoCore(data.new) end

-- Copies a sidewalk spline profile.
local function copySidewalkSplineProfile(spline)
  copiedProfile = {
    verticalOffset = spline.verticalOffset,
    isConformToTerrain = spline.isConformToTerrain,
    jitterAmount = spline.jitterAmount,
    alignmentWeight = spline.alignmentWeight,
    splineRandomSeed = spline.splineRandomSeed,
    pieceDistribution = deepcopy(spline.pieceDistribution),
    kitFolderPath = spline.kitFolderPath,
    pieceEnabledStates = deepcopy(spline.pieceEnabledStates),
  }
end

-- Pastes a sidewalk spline profile.
local function pasteSidewalkSplineProfile(spline)
  if not copiedProfile then
    return -- Early return if no copied profile.
  end

  -- Clean up old sidewalk objects before applying new profile.
  pop.tryRemove(spline)

  spline.verticalOffset = copiedProfile.verticalOffset
  spline.isConformToTerrain = copiedProfile.isConformToTerrain
  spline.jitterAmount = copiedProfile.jitterAmount
  spline.alignmentWeight = copiedProfile.alignmentWeight
  spline.splineRandomSeed = copiedProfile.splineRandomSeed
  spline.pieceDistribution = deepcopy(copiedProfile.pieceDistribution)
  spline.kitFolderPath = copiedProfile.kitFolderPath

  if copiedProfile.pieceEnabledStates then
    spline.pieceEnabledStates = deepcopy(copiedProfile.pieceEnabledStates)
  end

  -- Reload kit if path was copied.
  if spline.kitFolderPath then
    spline.meshKit = kit.getSidewalkKit(spline.kitFolderPath)
    spline.kitDescription = kit.buildSidewalkKit(spline.meshKit, spline)
    spline.distributionGroups = kit.buildDistributionGroups(spline)
  end
end

-- Returns true if there is a copied profile.
local function hasCopiedProfile()
  return copiedProfile ~= nil
end

-- Copies profile template data.
local function copyProfileTemplate(spline)
  return {
    verticalOffset = spline.verticalOffset,
    isConformToTerrain = spline.isConformToTerrain,
    jitterAmount = spline.jitterAmount,
    alignmentWeight = spline.alignmentWeight,
    splineRandomSeed = spline.splineRandomSeed,
    pieceDistribution = deepcopy(spline.pieceDistribution),
    kitFolderPath = spline.kitFolderPath,
    pieceEnabledStates = deepcopy(spline.pieceEnabledStates),
  }
end

-- Pastes profile template data.
local function pasteProfileTemplate(spline, templateData)
  if not templateData then
    return -- Early return if no template data.
  end

  spline.verticalOffset = templateData.verticalOffset or defaultParams.verticalOffset
  spline.isConformToTerrain = templateData.isConformToTerrain ~= false
  spline.jitterAmount = templateData.jitterAmount or templateData.playAmount or defaultParams.jitterAmount
  spline.alignmentWeight = templateData.alignmentWeight or defaultParams.alignmentWeight
  spline.splineRandomSeed = templateData.splineRandomSeed or defaultParams.splineRandomSeed
  spline.pieceDistribution = deepcopy(templateData.pieceDistribution)
  spline.kitFolderPath = templateData.kitFolderPath

  if templateData.pieceEnabledStates then
    spline.pieceEnabledStates = deepcopy(templateData.pieceEnabledStates)
  end

  -- Reload kit if path was provided.
  if spline.kitFolderPath then
    spline.meshKit = kit.getSidewalkKit(spline.kitFolderPath)
    spline.kitDescription = kit.buildSidewalkKit(spline.meshKit, spline)
    spline.distributionGroups = kit.buildDistributionGroups(spline)
  end
end

-- Serialises a sidewalk spline.
local function serializeSidewalkSpline(spline)
  local copy = buffer.encode(spline)
  table.clear(spline.divPoints)
  table.clear(spline.divWidths)
  table.clear(spline.tangents)
  table.clear(spline.binormals)
  table.clear(spline.normals)
  table.clear(spline.discMap)
  return copy
end

-- Deserialises a sidewalk spline.
local function deserializeSidewalkSpline(data, isFromFile)
  local spline = buffer.decode(data)
  spline.isDirty = true

  -- Reload kit if path was provided (fixes mesh disappearance after deserialize).
  if spline.kitFolderPath then
    spline.meshKit = kit.getSidewalkKit(spline.kitFolderPath)
    spline.kitDescription = kit.buildSidewalkKit(spline.meshKit, spline)
    spline.distributionGroups = kit.buildDistributionGroups(spline)
  end

  -- Create scene tree folder.
  if isFromFile then
    local uniqueName = util.generateUniqueName(spline.name, toolPrefixStr)
    local newFolder = createObject("SimGroup")
    newFolder:registerObject(string.format("%s - %s", uniqueName, spline.id))
    scenetree.MissionGroup:addObject(newFolder)
    spline.sceneTreeFolderId = newFolder:getId()
  end

  return spline
end

-- Builds the arc-length table for a sidewalk spline (using secondary geometry).
local function buildArcLengthTable(spline)
  local divPoints = spline.divPoints
  local numDivPoints = divPoints and #divPoints or 0
  if numDivPoints < 2 then
    spline.arcLengths = nil
    spline.totalLength = 0.0
    return
  end

  local arcLengths = spline.arcLengths or {}
  local totalLength = 0.0
  arcLengths[1] = 0.0
  for i = 2, numDivPoints do
    local pPrev = divPoints[i - 1]
    local pCur = divPoints[i]
    local segVec = pCur - pPrev
    local segLength = segVec:length()
    totalLength = totalLength + segLength
    arcLengths[i] = totalLength
  end

  spline.arcLengths = arcLengths
  spline.totalLength = totalLength
end

-- Updates the geometry and meshes of any dirty sidewalk splines.
local function updateDirtySidewalkSplines()
  for i = 1, #sidewalkSplines do
    local spline = sidewalkSplines[i]
    if spline.isDirty then
      -- Check if spline has enough nodes to be valid (minimum 2).
      local nodes = spline.nodes
      if #nodes < 2 then
        -- Remove all meshes and clear secondary geometry when insufficient nodes.
        pop.tryRemove(spline)
        table.clear(spline.divPoints)
        table.clear(spline.divWidths)
        table.clear(spline.tangents)
        table.clear(spline.binormals)
        table.clear(spline.normals)
        table.clear(spline.discMap)
        spline.roadLength = 0.0
        spline.arcLengths = nil
        spline.totalLength = 0.0
      else
        if spline.isConformToTerrain then
          for j = 1, #nodes do
            util.vertRaycast(nodes[j])
          end
          geom.catmullRomRaycast(spline, minSplineDivisions) -- Ensure the secondary geometry is updated and conforms to the terrain.
        else
          geom.catmullRomFree(spline, minSplineDivisions) -- Ensure the secondary geometry is updated, but remains free in 3D (not conformed to the terrain).
        end

        -- Rebuild distribution groups if missing (e.g., after toggling enable states).
        if not spline.distributionGroups then
          spline.distributionGroups = kit.buildDistributionGroups(spline)
          if spline.kitDescription then
            spline.kitDescription.distributionGroups = spline.distributionGroups
          end
        end

        pop.populateSidewalkSpline(spline, i)

        spline.roadLength = util.getPolyLength(nodes) -- Update the spline length.
        buildArcLengthTable(spline)
      end

      spline.isDirty = false
    end
  end
end

-- Public interface.
M.getToolPrefixStr =                                    getToolPrefixStr
M.getEditModeKey =                                      getEditModeKey
M.getSidewalkSplines =                                  getSidewalkSplines
M.getSplineMap =                                        getSplineMap
M.setSidewalkSpline =                                   setSidewalkSpline
M.setSidewalkSplines =                                  setSidewalkSplines
M.getDefaultSliderParams =                              getDefaultSliderParams

M.addNewSidewalkSpline =                                addNewSidewalkSpline
M.removeSidewalkSpline =                                removeSidewalkSpline
M.removeAllSidewalkSplines =                            removeAllSidewalkSplines

M.deepCopySidewalkSpline =                              deepCopySidewalkSpline
M.deepCopySidewalkSplineState =                         deepCopySidewalkSplineState

M.splitSidewalkSpline =                                 splitSidewalkSpline
M.joinSidewalkSplines =                                 joinSidewalkSplines

M.singleSplineEditUndo =                                singleSplineEditUndo
M.singleSplineEditRedo =                                singleSplineEditRedo
M.transSplineEditUndo =                                 transSplineEditUndo
M.transSplineEditRedo =                                 transSplineEditRedo
M.objectSelectUndo =                                    objectSelectUndo
M.objectSelectRedo =                                    objectSelectRedo

M.copySidewalkSplineProfile =                           copySidewalkSplineProfile
M.pasteSidewalkSplineProfile =                          pasteSidewalkSplineProfile
M.hasCopiedProfile =                                    hasCopiedProfile

M.copyProfileTemplate =                                 copyProfileTemplate
M.pasteProfileTemplate =                                pasteProfileTemplate

M.serializeSidewalkSpline =                             serializeSidewalkSpline
M.deserializeSidewalkSpline =                           deserializeSidewalkSpline

M.updateDirtySidewalkSplines =                          updateDirtySidewalkSplines

return M