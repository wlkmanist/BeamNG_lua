-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- Module constants.
local toolPrefixStr = 'Assembly Spline' -- The global prefix for the assembly spline tool.
local editModeKey = 'assemblySplineEditMode' -- The edit mode key for this tool.

local minSplineDivisions = 100 -- The minimum number of subdivisions to use for a assembly spline.

local minImportSize = 10.0 -- The minimum size of a assembly spline to import.

-- The wooden fence preset.
local woodenFencePreset = {
  name = 'Wooden Fence',
  kitFolderPath = 'assets/meshes/props/assembly_kit/ak_wood_fence_001/',
  spacing = 0.0,
  verticalOffset = 0.0,
  normalMode = 2, -- Terrain up.
  sag = 0.0,
  preRot = 0,
  jitterForward = 0.0,
  jitterRight = 0.0,
  jitterUp = 0.0,
  splineRandomSeed = 0,
}

-- The telegraph pole preset.
local telegraphPolePreset = {
  name = 'Telegraph Pole',
  kitFolderPath = 'assets/meshes/props/assembly_kit/ak_wood_pole_old_001/',
  spacing = 30.0,
  verticalOffset = 0.0,
  normalMode = 1, -- Global up.
  sag = 0.0,
  preRot = 1, -- 90 degrees around Z.
  jitterForward = 0.0,
  jitterRight = 0.0,
  jitterUp = 0.0,
  splineRandomSeed = 0,
}

-- The metal crash barrier preset.
local metalCrashBarrierPreset = {
  name = 'Metal Crash Barrier',
  kitFolderPath = 'assets/meshes/props/assembly_kit/ak_guardrail_001/',
  spacing = 0.0,
  verticalOffset = 0.0,
  normalMode = 2, -- Terrain up.
  sag = 0.0,
  preRot = 2, -- 180 degrees around Z.
  jitterForward = 0.0,
  jitterRight = 0.0,
  jitterUp = 0.0,
  splineRandomSeed = 0,
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'assemblySpline'

-- External modules.
local buffer = require('string.buffer')
local pop = require('editor/assemblySpline/populate')
local mol = require('editor/assemblySpline/molecule')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min = math.abs, math.min
local presetsByStr = {
  ['telegraph_pole'] = telegraphPolePreset,
  ['wooden_fence'] = woodenFencePreset,
  ['metal_crash_barrier'] = metalCrashBarrierPreset,
}

-- Module state.
local assemblySplines = {}
local splineMap = {}
local tmpPoint2I = Point2I(0, 0)


-- Fetches the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Fetches the edit mode key.
local function getEditModeKey() return editModeKey end

-- Fetches the assembly splines.
local function getAssemblySplines() return assemblySplines end

-- Fetches the assembly spline map.
local function getSplineMap() return splineMap end

-- Sets the assembly spline with the given index.
local function setAssemblySpline(spline, idx)
  assemblySplines[idx] = spline

  -- Ensure we have a unique assembly spline name.
  local baseName = spline.name
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new scene tree folder for the assembly spline.
  if not spline.sceneTreeFolderId or not scenetree.findObjectById(spline.sceneTreeFolderId) then
    local newFolder = createObject("SimGroup")
    local folderNameId = Engine.generateUUID()
    newFolder:registerObject(string.format("%s - %s", uniqueName, folderNameId))
    scenetree.MissionGroup:addObject(newFolder)
    spline.sceneTreeFolderId = newFolder:getId()
  end
  spline.isDirty = true
end

-- Sets the assembly splines (full table).
local function setAssemblySplines(splines)
  for i = 1, #splines do
    setAssemblySpline(splines[i], i)
  end
end

-- Returns the default slider parameters (from the wooden fence preset).
local function getDefaultSliderParams()
  return {
    spacing = woodenFencePreset.spacing,
    verticalOffset = woodenFencePreset.verticalOffset,
    normalMode = woodenFencePreset.normalMode,
    sag = woodenFencePreset.sag,
    preRot = woodenFencePreset.preRot,
    jitterForward = woodenFencePreset.jitterForward,
    jitterRight = woodenFencePreset.jitterRight,
    jitterUp = woodenFencePreset.jitterUp,
    splineRandomSeed = woodenFencePreset.splineRandomSeed,
  }
end

-- Sets the given spline to the given preset.
local function setPreset(spline, presetStr)
  if not spline or not presetStr then
    return -- No spline or preset string provided.
  end

  -- Remove any existing meshes from the scene.
  pop.tryRemove(spline)

  -- Set the preset data in the spline.
  local preset = presetsByStr[presetStr]
  if preset then
    -- Set the kit folder path and regenerate the mesh kit and molecule description.
    spline.kitFolderPath = preset.kitFolderPath
    spline.meshKit = mol.getAssemblyKit(spline.kitFolderPath)
    spline.moleculeDescription = mol.buildMolecule(spline.meshKit, spline)

    -- Set the preset parameters.
    spline.spacing = preset.spacing
    spline.verticalOffset = preset.verticalOffset
    spline.normalMode = preset.normalMode
    spline.sag = preset.sag
    spline.preRot = preset.preRot
    spline.jitterForward = preset.jitterForward
    spline.jitterRight = preset.jitterRight
    spline.jitterUp = preset.jitterUp
    spline.splineRandomSeed = preset.splineRandomSeed
  end

  spline.isDirty = true
end

-- Adds a new assembly spline.
local function addNewAssemblySpline()
  -- Ensure we have a unique assembly spline name.
  local baseName = string.format(toolPrefixStr .. " %d", #assemblySplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
  local id = Engine.generateUUID()

  -- Create a new scene tree folder for the assembly spline.
  local newFolder = createObject("SimGroup")
  newFolder:registerObject(string.format("%s - %s", uniqueName, id))
  scenetree.MissionGroup:addObject(newFolder)

  -- Create a static mesh for the assembly spline.
  table.insert(assemblySplines, {
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

    spacing = woodenFencePreset.spacing, -- Spline properties.
    verticalOffset = woodenFencePreset.verticalOffset,
    isConformToTerrain = true,
    normalMode = woodenFencePreset.normalMode,
    sag = woodenFencePreset.sag,
    preRot = woodenFencePreset.preRot,
    jitterForward = woodenFencePreset.jitterForward,
    jitterRight = woodenFencePreset.jitterRight,
    jitterUp = woodenFencePreset.jitterUp,
    splineRandomSeed = woodenFencePreset.splineRandomSeed,

    roadLength = 0.0,

    kitFolderPath = woodenFencePreset.kitFolderPath, -- Mesh kit/molecule properties.
    meshKit = {},
    moleculeDescription = {},
    rigidEnabledStates = {},
    bridgeEnabledStates = {},
    isImported = false,
    importedKit = {},
  })

  -- Load the default kit and build the molecule.
  local spline = assemblySplines[#assemblySplines]
  spline.meshKit = mol.getAssemblyKit(woodenFencePreset.kitFolderPath)

  -- Check if the kit was loaded successfully
  if spline.meshKit and #spline.meshKit > 0 then
    spline.kitFolderPath = woodenFencePreset.kitFolderPath
    spline.moleculeDescription = mol.buildMolecule(spline.meshKit, spline)
    spline.isDirty = true
  else -- If kit loading failed, log a warning and set empty kit.
    log('W', logTag, string.format('Failed to load default kit from path: %s', woodenFencePreset.kitFolderPath))
    spline.meshKit = {}
    spline.moleculeDescription = {}
    spline.kitFolderPath = nil
  end

  -- Update the spline map.
  util.computeIdToIdxMap(assemblySplines, splineMap)
end

-- Removes the assembly spline with the given index.
local function removeAssemblySpline(idx)
  local spline = assemblySplines[idx]
  pop.tryRemove(spline) -- Remove the static meshes related to this assembly spline from the scene.
  if spline.sceneTreeFolderId then
    local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
    if folder and simObjectExists(folder) then
      folder:delete() -- Remove the scene tree folder for the assembly spline.
    end
  end
  table.remove(assemblySplines, idx) -- Finally, remove the assembly spline from the list.

  -- Update the spline map.
  util.computeIdToIdxMap(assemblySplines, splineMap)
end

-- Removes a linked assembly spline by ID (called from master spline layer removal).
local function removeLinkedAssemblySpline(splineId)
  local idx = splineMap[splineId]
  if idx then
    removeAssemblySpline(idx)
  end
end

-- Removes all assembly splines.
-- [If isIncludeDisabled is true, then all assembly splines will be removed, including disabled ones.]
-- [If isIncludeDisabled is false, then only enabled assembly splines will be removed.]
local function removeAllAssemblySplines(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #assemblySplines, 1, -1 do
      local spline = assemblySplines[i]
      if spline then
        removeAssemblySpline(i)
      end
    end
  else
    for i = #assemblySplines, 1, -1 do
      local spline = assemblySplines[i]
      if spline and spline.isEnabled and not spline.isLink then -- Only remove enabled and unlinked assembly splines.
        removeAssemblySpline(i)
      end
    end
  end
end

-- Deep copies the given assembly spline.
local function deepCopyAssemblySpline(spline)
  local copy = buffer.decode(buffer.encode(spline))
  table.clear(copy.divPoints)
  table.clear(copy.divWidths)
  table.clear(copy.tangents)
  table.clear(copy.binormals)
  table.clear(copy.normals)
  table.clear(copy.discMap)
  return copy
end

-- Deep copies the full assembly spline state.
local function deepCopyAssemblySplineState()
  local copy = {}
  for i = 1, #assemblySplines do
    copy[i] = deepCopyAssemblySpline(assemblySplines[i])
  end
  return copy
end

-- Splits the selected assembly spline into two, at the selected node.
local function splitAssemblySpline(selectedSplineIdx, selectedNodeIdx)
  local spline = assemblySplines[selectedSplineIdx]
  if not spline then
    return -- Early return if the spline is invalid.
  end

  if spline.isLoop then
    -- Unwrap loop in place starting from the split point, convert to open spline.
    local nodesNew, widthsNew, nmlsNew = geom.splitLoopSplineGeometry(spline.nodes, spline.widths, spline.nmls, selectedNodeIdx)
    spline.nodes, spline.widths, spline.nmls = nodesNew, widthsNew, nmlsNew
    spline.isLoop = false
    spline.isDirty = true
  else
    local copy = deepCopyAssemblySpline(spline)
    removeAssemblySpline(selectedSplineIdx)

    -- Add first half (A)
    addNewAssemblySpline()
    local splineA = assemblySplines[#assemblySplines]
    splineA.name = copy.name .. '_split_A'
    splineA.isDirty = true
    splineA.isLoop = false
    splineA.isLink = false
    splineA.linkId = nil
    splineA.isEnabled = true

    splineA.spacing = copy.spacing
    splineA.verticalOffset = copy.verticalOffset
    splineA.normalMode = copy.normalMode
    splineA.sag = copy.sag
    splineA.isConformToTerrain = copy.isConformToTerrain
    splineA.preRot = copy.preRot
    splineA.jitterForward = copy.jitterForward
    splineA.jitterRight = copy.jitterRight
    splineA.jitterUp = copy.jitterUp
    splineA.splineRandomSeed = copy.splineRandomSeed

    splineA.roadLength = 0.0

    splineA.kitFolderPath = copy.kitFolderPath
    splineA.meshKit = deepcopy(copy.meshKit)
    splineA.moleculeDescription = deepcopy(copy.moleculeDescription)
    splineA.rigidEnabledStates = deepcopy(copy.rigidEnabledStates)
    splineA.bridgeEnabledStates = deepcopy(copy.bridgeEnabledStates)
    splineA.isImported = copy.isImported
    splineA.importedKit = deepcopy(copy.importedKit)

    local nodes1, widths1, nmls1, nodes2, widths2, nmls2 = geom.splitSplineGeometry(copy.nodes, copy.widths, copy.nmls, selectedNodeIdx)

    splineA.nodes, splineA.widths, splineA.nmls = nodes1, widths1, nmls1

    -- Add second half (B)
    addNewAssemblySpline()
    local splineB = assemblySplines[#assemblySplines]
    splineB.name = copy.name .. '_split_B'
    splineB.isDirty = true
    splineB.isLoop = false
    splineB.isLink = false
    splineB.linkId = nil
    splineB.isEnabled = true

    splineB.spacing = copy.spacing
    splineB.verticalOffset = copy.verticalOffset
    splineB.normalMode = copy.normalMode
    splineB.sag = copy.sag
    splineB.isConformToTerrain = copy.isConformToTerrain
    splineB.preRot = copy.preRot
    splineB.jitterForward = copy.jitterForward
    splineB.jitterRight = copy.jitterRight
    splineB.jitterUp = copy.jitterUp
    splineB.splineRandomSeed = copy.splineRandomSeed

    splineB.roadLength = 0.0

    splineB.kitFolderPath = copy.kitFolderPath
    splineB.meshKit = deepcopy(copy.meshKit)
    splineB.moleculeDescription = deepcopy(copy.moleculeDescription)
    splineB.rigidEnabledStates = deepcopy(copy.rigidEnabledStates)
    splineB.bridgeEnabledStates = deepcopy(copy.bridgeEnabledStates)
    splineB.isImported = copy.isImported
    splineB.importedKit = deepcopy(copy.importedKit)

    splineB.nodes, splineB.widths, splineB.nmls = nodes2, widths2, nmls2

    util.computeIdToIdxMap(assemblySplines, splineMap)
  end
end

-- Joins two unlooped Assembly Splines into one, modifying spline1 and deleting spline2.
local function joinAssemblySplines(splineIdx1, nodeIdx1, splineIdx2, nodeIdx2)
  local spline1, spline2 = assemblySplines[splineIdx1], assemblySplines[splineIdx2]
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
  removeAssemblySpline(splineIdx2)

  -- Recompute map for stability
  util.computeIdToIdxMap(assemblySplines, splineMap)
end

-- Undo/redo core function.
local function singleSplineEditUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx then
    -- Remove the spline if it has less than 2 nodes.
    local spline = assemblySplines[idx]
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

    spline.spacing = data.spacing
    spline.verticalOffset = data.verticalOffset
    spline.sag = data.sag
    spline.normalMode = data.normalMode
    spline.isConformToTerrain = data.isConformToTerrain
    spline.preRot = data.preRot
    spline.jitterForward = data.jitterForward
    spline.jitterRight = data.jitterRight
    spline.jitterUp = data.jitterUp
    spline.splineRandomSeed = data.splineRandomSeed

    spline.roadLength = data.roadLength

    spline.kitFolderPath = data.kitFolderPath
    spline.meshKit = data.meshKit
    spline.moleculeDescription = data.moleculeDescription
    spline.rigidEnabledStates = data.rigidEnabledStates
    spline.bridgeEnabledStates = data.bridgeEnabledStates
    spline.isImported = data.isImported
    spline.importedKit = data.importedKit

    -- Special case for when the assembly spline has been renamed.
    if data.isUpdateSceneTree then
      local folder = scenetree.findObjectById(spline.sceneTreeFolderId)
      if folder then
        folder:setName(spline.name)
      end
      editor.refreshSceneTreeWindow()
    end
  end
end

-- Handles the undo for a single assembly spline.
local function singleSplineEditUndo(assemblySplineData)
  local data = assemblySplineData.old
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the redo for a single assembly spline.
local function singleSplineEditRedo(assemblySplineData)
  local data = assemblySplineData.new
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the undo for trans assembly spline edits.
local function transSplineEditUndo(data)
  removeAllAssemblySplines(true)
  setAssemblySplines(data.old)
  for i = 1, #assemblySplines do
    assemblySplines[i].isDirty = true
  end

  -- Update the spline map.
  util.computeIdToIdxMap(assemblySplines, splineMap)
end

-- Handles the redo for trans assembly spline edits.
local function transSplineEditRedo(data)
  removeAllAssemblySplines(true)
  setAssemblySplines(data.new)
  for i = 1, #assemblySplines do
    assemblySplines[i].isDirty = true
  end

  -- Update the spline map.
  util.computeIdToIdxMap(assemblySplines, splineMap)
end

-- Core function for the object select undo/redo.
local function objectSelectUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx and assemblySplines[idx] then
    pop.tryRemove(assemblySplines[idx])
    assemblySplines[idx] = data
    assemblySplines[idx].isDirty = true
    util.computeIdToIdxMap(assemblySplines, splineMap)
  end
end

-- Undo callback for object select operations.
local function objectSelectUndo(data) objectSelectUndoRedoCore(data.old) end

-- Redo callback for object select operations.
local function objectSelectRedo(data) objectSelectUndoRedoCore(data.new) end

-- Copies the profile of the given assembly spline.
local function copyAssemblySplineProfile(spline)
  local copy = deepCopyAssemblySpline(spline)
  copy.name = nil
  copy.id = nil
  copy.isDirty = nil
  copy.isEnabled = nil
  copy.isLoop = nil
  copy.isLink = nil
  copy.linkId = nil
  copy.sceneTreeFolderId = nil
  copy.nodes = nil
  copy.widths = nil
  copy.nmls = nil
  copy.divPoints = nil
  copy.divWidths = nil
  copy.tangents = nil
  copy.binormals = nil
  copy.normals = nil
  copy.discMap = nil
  copy.roadLength = nil
  return copy
end

-- Pastes the profile to the given assembly spline.
local function pasteAssemblySplineProfile(spline, profile)
  -- Clean up old assembly objects before applying new profile.
  pop.tryRemove(spline)

  spline.isDirty = true
  spline.spacing = profile.spacing
  spline.verticalOffset = profile.verticalOffset
  spline.normalMode = profile.normalMode
  spline.sag = profile.sag
  spline.isConformToTerrain = profile.isConformToTerrain
  spline.preRot = profile.preRot
  spline.jitterForward = profile.jitterForward
  spline.jitterRight = profile.jitterRight
  spline.jitterUp = profile.jitterUp
  spline.splineRandomSeed = profile.splineRandomSeed
  spline.kitFolderPath = profile.kitFolderPath
  spline.meshKit = profile.meshKit
  spline.moleculeDescription = profile.moleculeDescription
  spline.rigidEnabledStates = profile.rigidEnabledStates
  spline.bridgeEnabledStates = profile.bridgeEnabledStates
  spline.isImported = profile.isImported
  spline.importedKit = profile.importedKit
end

-- Serializes an assembly spline to a table.
local function serializeAssemblySpline(spline)
  table.clear(spline.divPoints)
  table.clear(spline.divWidths)
  table.clear(spline.tangents)
  table.clear(spline.binormals)
  table.clear(spline.normals)
  table.clear(spline.discMap)
  return buffer.encode(spline)
end

-- Deserializes an assembly spline from a table.
local function deserializeAssemblySpline(data, isCreateObject)
  local spline = buffer.decode(data)
  spline.isDirty = true

  -- Create a new scene tree folder for the assembly spline, if requested.
  if isCreateObject then
    -- Ensure we have a unique assembly spline name.
    local baseName = string.format(toolPrefixStr .. " %d", #assemblySplines + 1)
    local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

    -- Create a new scene tree folder for the assembly spline.
    local newFolder = createObject("SimGroup")
    newFolder:registerObject(string.format("%s - %s", uniqueName, spline.id))
    scenetree.MissionGroup:addObject(newFolder)
    spline.sceneTreeFolderId = newFolder:getId()
  end
  return spline
end

-- Updates the geometry and meshes of any dirty assembly splines.
local function updateDirtyAssemblySplines()
  for i = 1, #assemblySplines do
    local spline = assemblySplines[i]
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
      else
        if spline.isConformToTerrain then
          for j = 1, #nodes do
            util.vertRaycast(nodes[j])
          end
          geom.catmullRomRaycast(spline, minSplineDivisions)
        else
          geom.catmullRomFree(spline, minSplineDivisions)
        end
        pop.populateAssemblySpline(spline, i, spline.moleculeDescription)

        spline.roadLength = util.getPolyLength(nodes) -- Update the spline length.
      end

      spline.isDirty = false
    end
  end
end

-- Converts the given paths (traced from a bitmap) to assembly splines.
local function convertPathsToAssemblySplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new assembly spline.
    addNewAssemblySpline()
    local spline = assemblySplines[#assemblySplines]

    -- Convert the grid points to world space.
    local points = path.points
    local pointsWS, numPoints = {}, #points
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
  log('I', logTag, string.format("Converted %d traced paths to assembly splines. %d paths were too small to import.", #paths, #paths - #assemblySplines))
end

-- Returns the current list of assembly splines.
local function getCurrentAssemblySplineList()
  local numSplines = #assemblySplines
  local list, ctr = {}, 1
  for i = 1, numSplines do
    local spline = assemblySplines[i]
    if spline.isEnabled then
      list[ctr] = { name = spline.name, id = spline.id, type = toolPrefixStr }
      ctr = ctr + 1
    end
  end
  return list
end

-- Returns true if the given assembly spline is linked, false otherwise.
local function isLinked(id)
  local spline = assemblySplines[splineMap[id]]
  return spline and spline.isLink or false
end

-- Sets the given linked assembly spline to be linked or not.
local function setLink(id, groupId, isLink)
  local spline = assemblySplines[splineMap[id]]
  if spline then
    spline.isLink = isLink
    if isLink then
      spline.linkId = groupId
    else
      spline.linkId = nil
    end
    pop.tryRemove(spline)
    spline.isDirty = true
  end
end

-- Updates the given linked assembly spline with the given geometry.
local function updateLinkedAssemblySpline(id, points, widths, nmls, isLoop, isConformToTerrain)
  local spline = assemblySplines[splineMap[id]]
  if spline then
    spline.nodes, spline.widths, spline.nmls = points, widths, nmls
    spline.isLoop = isLoop -- Propagate the loop state of the master spline to the linked spline.
    spline.isConformToTerrain = isConformToTerrain -- Propagate the conform to surface below state of the master spline to the linked spline.

    -- If there are insufficient nodes, clear secondary geometry and remove existing objects.
    if #points < 2 then
      table.clear(spline.divPoints)
      table.clear(spline.divWidths)
      table.clear(spline.tangents)
      table.clear(spline.binormals)
      table.clear(spline.normals)
      table.clear(spline.discMap)
      pop.tryRemove(spline)
    end

    spline.isDirty = true
  end
end

-- Unlinks all assembly splines.
local function unlinkAll()
  for i = 1, #assemblySplines do
    local spline = assemblySplines[i]
    if spline.isLink then
      spline.isLink = false
      spline.linkId = nil
    end
    spline.isDirty = true
  end
end


-- Public interface.
M.getToolPrefixStr =                                    getToolPrefixStr
M.getEditModeKey =                                      getEditModeKey
M.getAssemblySplines =                                  getAssemblySplines
M.getSplineMap =                                        getSplineMap
M.setAssemblySplines =                                  setAssemblySplines
M.setAssemblySpline =                                   setAssemblySpline
M.getDefaultSliderParams =                              getDefaultSliderParams
M.setPreset =                                           setPreset

M.addNewAssemblySpline =                                addNewAssemblySpline

M.splitAssemblySpline =                                 splitAssemblySpline
M.joinAssemblySplines =                                 joinAssemblySplines

M.removeAssemblySpline =                                removeAssemblySpline
M.removeLinkedAssemblySpline =                          removeLinkedAssemblySpline
M.removeAllAssemblySplines =                            removeAllAssemblySplines

M.deepCopyAssemblySpline =                              deepCopyAssemblySpline
M.deepCopyAssemblySplineState =                         deepCopyAssemblySplineState
M.copyAssemblySplineProfile =                           copyAssemblySplineProfile
M.pasteAssemblySplineProfile =                          pasteAssemblySplineProfile

M.singleSplineEditUndo =                                singleSplineEditUndo
M.singleSplineEditRedo =                                singleSplineEditRedo
M.transSplineEditUndo =                                 transSplineEditUndo
M.transSplineEditRedo =                                 transSplineEditRedo
M.objectSelectUndo =                                    objectSelectUndo
M.objectSelectRedo =                                    objectSelectRedo

M.updateDirtyAssemblySplines =                          updateDirtyAssemblySplines

M.convertPathsToAssemblySplines =                       convertPathsToAssemblySplines

M.serializeAssemblySpline =                             serializeAssemblySpline
M.deserializeAssemblySpline =                           deserializeAssemblySpline
M.deepCopyAssemblySplineState =                         deepCopyAssemblySplineState

M.getCurrentAssemblySplineList =                        getCurrentAssemblySplineList
M.isLinked =                                            isLinked
M.setLink =                                             setLink
M.updateLinkedAssemblySpline =                          updateLinkedAssemblySpline
M.unlinkAll =                                           unlinkAll

return M