-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Decal Spline' -- The global prefix for the decal spline tool.
local editModeKey = 'decalSplineEditMode' -- The edit mode key for this tool.

local minSplineDivisions = 100 -- The minimum number of divisions to use for a decal spline.

local minImportSize = 10.0 -- The minimum size of a mesh spline to import.

local defaultMaterial = 'asphalt_patches' -- The default material to use for the decal spline.

-- Default slider parameters for UI.
local defaultParams = {
  spacing = 0.0,
  jitter = 0.0,
  component1RandomWeight = 1.0,
  component2RandomWeight = 0.0,
  component3RandomWeight = 0.0,
  component4RandomWeight = 0.0,
  rot = 1,
  randomSeed = 41225,
  numRows = 4,
  numCols = 2,
  scale = 1.0,
  frame = 3,
}

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'decalSpline'

-- External modules.
local buffer = require('string.buffer')
local pop = require('editor/decalSpline/populate')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
local abs, min, randomseed = math.abs, math.min, math.randomseed

-- Module state.
local decalSplines = {}
local splineMap = {}
local tmpPoint2I = Point2I(0, 0)


-- Fetches the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Fetches the edit mode key.
local function getEditModeKey() return editModeKey end

-- Fetches the decal splines.
local function getDecalSplines() return decalSplines end

-- Fetches the decal spline map.
local function getSplineMap() return splineMap end

-- Sets the decal spline with the given index.
local function setDecalSpline(spline, idx)
  decalSplines[idx] = spline
  spline.isDirty = true
end

-- Sets the decal splines (full table).
local function setDecalSplines(splines)
  for i = 1, #splines do
    setDecalSpline(splines[i], i)
  end
end

-- Returns the default slider parameters.
local function getDefaultSliderParams() return defaultParams end

-- Adds a new decal spline.
local function addNewDecalSpline()
  -- Ensure we have a unique decal spline name.
  local baseName = string.format(toolPrefixStr .. " %d", #decalSplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new decal spline.
  table.insert(decalSplines, {
    -- The core properties of the decal spline.
    name = uniqueName,
    id = Engine.generateUUID(),
    isDirty = false,
    isLoop = false,
    isLink = false,
    linkId = nil,
    nodes = {},
    widths = {},
    nmls = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    isEnabled = true,
    isAliasRoundRobin = true,
    roadLength = 0.0,
    spacing = defaultParams.spacing,
    jitter = defaultParams.jitter,
    rot1 = defaultParams.rot,
    rot2 = defaultParams.rot,
    rot3 = defaultParams.rot,
    rot4 = defaultParams.rot,
    numRows1 = defaultParams.numRows,
    numCols1 = defaultParams.numCols,
    scale1 = defaultParams.scale,
    frame1 = defaultParams.frame,
    numRows2 = defaultParams.numRows,
    numCols2 = defaultParams.numCols,
    scale2 = defaultParams.scale,
    frame2 = defaultParams.frame,
    numRows3 = defaultParams.numRows,
    numCols3 = defaultParams.numCols,
    scale3 = defaultParams.scale,
    frame3 = defaultParams.frame,
    numRows4 = defaultParams.numRows,
    numCols4 = defaultParams.numCols,
    scale4 = defaultParams.scale,
    frame4 = defaultParams.frame,
    randomSeed = defaultParams.randomSeed,

    -- The properties of component 1.
    component1RandomWeight = defaultParams.component1RandomWeight,
    component1Material = defaultMaterial,

    -- The properties of component 2.
    isComponent2 = false,
    component2RandomWeight = defaultParams.component2RandomWeight,
    component2Material = defaultMaterial,

    -- The properties of component 3.
    isComponent3 = false,
    component3RandomWeight = defaultParams.component3RandomWeight,
    component3Material = defaultMaterial,

    -- The properties of component 4.
    isComponent4 = false,
    component4RandomWeight = defaultParams.component4RandomWeight,
    component4Material = defaultMaterial,
  })

  -- Update the spline map.
  util.computeIdToIdxMap(decalSplines, splineMap)
end

-- Removes the decal spline with the given index.
local function removeDecalSpline(idx)
  local spline = decalSplines[idx]
  pop.tryRemove(spline) -- Remove the decal templates/instances related to this decal spline from the scene.
  table.remove(decalSplines, idx) -- Finally, remove the decal spline from the list.
  util.computeIdToIdxMap(decalSplines, splineMap) -- Update the spline map.
  if #decalSplines < 1 then
    pop.removeFolder()
  end
end

-- Removes a linked decal spline by ID (called from master spline layer removal).
local function removeLinkedDecalSpline(splineId)
  local idx = splineMap[splineId]
  if idx then
    removeDecalSpline(idx)
  end
end

-- Removes all decal splines.
-- [If isIncludeDisabled is true, then all decal splines will be removed, including disabled ones.]
-- [If isIncludeDisabled is false, then only enabled decal splines will be removed.]
local function removeAllDecalSplines(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #decalSplines, 1, -1 do
      local spline = decalSplines[i]
      if spline then
        removeDecalSpline(i)
      end
    end
  else
    for i = #decalSplines, 1, -1 do
      local spline = decalSplines[i]
      if spline and spline.isEnabled and not spline.isLink then -- Only remove enabled and unlinked decal splines.
        removeDecalSpline(i)
      end
    end
  end
end

-- Deep copies the given decal spline.
local function deepCopyDecalSpline(spline)
  local copy = buffer.decode(buffer.encode(spline))
  table.clear(copy.divPoints)
  table.clear(copy.divWidths)
  table.clear(copy.tangents)
  table.clear(copy.binormals)
  table.clear(copy.normals)
  table.clear(copy.discMap)
  return copy
end

-- Deep copies the full decal spline state.
local function deepCopyDecalSplineState()
  local copy = {}
  for i = 1, #decalSplines do
    copy[i] = deepCopyDecalSpline(decalSplines[i])
  end
  return copy
end

-- Splits the selected decal spline into two, at the selected node.
local function splitDecalSpline(selectedSplineIdx, selectedNodeIdx)
  local spline = decalSplines[selectedSplineIdx]
  if not spline then return end

  if spline.isLoop then
    -- Unwrap loop in place starting from the split point, convert to open spline.
    local nodesNew, widthsNew, nmlsNew = geom.splitLoopSplineGeometry(spline.nodes, spline.widths, spline.nmls, selectedNodeIdx)
    spline.nodes, spline.widths, spline.nmls = nodesNew, widthsNew, nmlsNew
    spline.isLoop = false
    spline.isDirty = true

  else
    local copy = deepCopyDecalSpline(spline) -- Deep copy the spline.
    removeDecalSpline(selectedSplineIdx) -- Remove the original.

    -- Add first half.
    addNewDecalSpline()
    local splineA = decalSplines[#decalSplines]
    splineA.name = copy.name .. '_split_A'
    splineA.isDirty = true
    splineA.isLoop = false
    splineA.isLink = false
    splineA.linkId = nil
    splineA.isEnabled = true
    splineA.isAliasRoundRobin = copy.isAliasRoundRobin
    splineA.roadLength = 0.0
    splineA.spacing = copy.spacing
    splineA.jitter = copy.jitter
    splineA.rot1 = copy.rot1
    splineA.rot2 = copy.rot2
    splineA.rot3 = copy.rot3
    splineA.rot4 = copy.rot4
    splineA.numRows1 = copy.numRows1
    splineA.numCols1 = copy.numCols1
    splineA.scale1 = copy.scale1
    splineA.frame1 = copy.frame1
    splineA.numRows2 = copy.numRows2
    splineA.numCols2 = copy.numCols2
    splineA.scale2 = copy.scale2
    splineA.frame2 = copy.frame2
    splineA.numRows3 = copy.numRows3
    splineA.numCols3 = copy.numCols3
    splineA.scale3 = copy.scale3
    splineA.frame3 = copy.frame3
    splineA.numRows4 = copy.numRows4
    splineA.numCols4 = copy.numCols4
    splineA.scale4 = copy.scale4
    splineA.frame4 = copy.frame4
    splineA.randomSeed = copy.randomSeed
    splineA.component1Material = copy.component1Material
    splineA.component2Material = copy.component2Material
    splineA.component3Material = copy.component3Material
    splineA.component4Material = copy.component4Material
    splineA.isComponent2 = copy.isComponent2
    splineA.isComponent3 = copy.isComponent3
    splineA.isComponent4 = copy.isComponent4
    splineA.component1RandomWeight = copy.component1RandomWeight
    splineA.component2RandomWeight = copy.component2RandomWeight
    splineA.component3RandomWeight = copy.component3RandomWeight
    splineA.component4RandomWeight = copy.component4RandomWeight

    splineA.nodes, splineA.widths, splineA.nmls = geom.splitSplineGeometry(copy.nodes, copy.widths, copy.nmls, selectedNodeIdx)

    -- Add second half.
    addNewDecalSpline()
    local splineB = decalSplines[#decalSplines]
    splineB.name = copy.name .. '_split_B'
    splineB.isDirty = true
    splineB.isLoop = false
    splineB.isLink = false
    splineB.linkId = nil
    splineB.isEnabled = true
    splineB.isAliasRoundRobin = copy.isAliasRoundRobin
    splineB.roadLength = 0.0
    splineB.spacing = copy.spacing
    splineB.jitter = copy.jitter
    splineB.rot1 = copy.rot1
    splineB.rot2 = copy.rot2
    splineB.rot3 = copy.rot3
    splineB.rot4 = copy.rot4
    splineB.numRows1 = copy.numRows1
    splineB.numCols1 = copy.numCols1
    splineB.scale1 = copy.scale1
    splineB.frame1 = copy.frame1
    splineB.numRows2 = copy.numRows2
    splineB.numCols2 = copy.numCols2
    splineB.scale2 = copy.scale2
    splineB.frame2 = copy.frame2
    splineB.numRows3 = copy.numRows3
    splineB.numCols3 = copy.numCols3
    splineB.scale3 = copy.scale3
    splineB.frame3 = copy.frame3
    splineB.numRows4 = copy.numRows4
    splineB.numCols4 = copy.numCols4
    splineB.scale4 = copy.scale4
    splineB.frame4 = copy.frame4
    splineB.randomSeed = copy.randomSeed
    splineB.component1Material = copy.component1Material
    splineB.component2Material = copy.component2Material
    splineB.component3Material = copy.component3Material
    splineB.component4Material = copy.component4Material
    splineB.isComponent2 = copy.isComponent2
    splineB.isComponent3 = copy.isComponent3
    splineB.isComponent4 = copy.isComponent4
    splineB.component1RandomWeight = copy.component1RandomWeight
    splineB.component2RandomWeight = copy.component2RandomWeight
    splineB.component3RandomWeight = copy.component3RandomWeight
    splineB.component4RandomWeight = copy.component4RandomWeight

    splineB.nodes, splineB.widths, splineB.nmls = nodes2, widths2, nmls2

    util.computeIdToIdxMap(decalSplines, splineMap)
  end
end

-- Joins two unlooped Decal Splines into one, modifying spline1 and deleting spline2.
local function joinDecalSplines(splineIdx1, nodeIdx1, splineIdx2, nodeIdx2)
  local spline1, spline2 = decalSplines[splineIdx1], decalSplines[splineIdx2]
  if not spline1 or not spline2 then return end

  -- Determine join case and concatenate in correct order.
  local n1, w1, nm1 = spline1.nodes, spline1.widths, spline1.nmls
  local n2, w2, nm2 = spline2.nodes, spline2.widths, spline2.nmls
  local nodesNew, widthsNew, nmlsNew = geom.joinSplineGeometry(n1, w1, nm1, nodeIdx1, n2, w2, nm2, nodeIdx2)
  if not nodesNew then
    return -- Early return if invalid node indices.
  end

  -- Apply joined geometry to spline1.
  spline1.nodes = nodesNew
  spline1.widths = widthsNew
  spline1.nmls = nmlsNew
  spline1.isLoop = false
  spline1.isDirty = true

  -- Remove spline2 directly, safely.
  removeDecalSpline(splineIdx2)

  -- Recompute map.
  util.computeIdToIdxMap(decalSplines, splineMap)
end

-- Undo/redo core function.
local function singleSplineEditUndoRedoCore(data)
  local idx = splineMap[data.id]
  if idx then
    -- Remove the spline if it has less than 2 nodes.
    local spline = decalSplines[idx]
    if #data.nodes < 2 then
      pop.tryRemove(spline)
    end

    -- Update the spline with the new data.
    spline.name = data.name
    spline.isDirty = true -- Set the dirty flag to true.
    spline.isLoop = data.isLoop
    spline.isLink = data.isLink
    spline.linkId = data.linkId

    spline.nodes = data.nodes
    spline.widths = data.widths
    spline.nmls = data.nmls

    spline.isEnabled = data.isEnabled
    spline.isAliasRoundRobin = data.isAliasRoundRobin
    spline.roadLength = data.roadLength
    spline.spacing = data.spacing
    spline.jitter = data.jitter
    spline.rot1 = data.rot1
    spline.rot2 = data.rot2
    spline.rot3 = data.rot3
    spline.rot4 = data.rot4
    spline.numRows1 = data.numRows1
    spline.numCols1 = data.numCols1
    spline.scale1 = data.scale1
    spline.frame1 = data.frame1
    spline.numRows2 = data.numRows2
    spline.numCols2 = data.numCols2
    spline.scale2 = data.scale2
    spline.frame2 = data.frame2
    spline.numRows3 = data.numRows3
    spline.numCols3 = data.numCols3
    spline.scale3 = data.scale3
    spline.frame3 = data.frame3
    spline.numRows4 = data.numRows4
    spline.numCols4 = data.numCols4
    spline.scale4 = data.scale4
    spline.frame4 = data.frame4
    spline.randomSeed = data.randomSeed
    spline.component1Material = data.component1Material
    spline.component2Material = data.component2Material
    spline.component3Material = data.component3Material
    spline.component4Material = data.component4Material
    spline.isComponent2 = data.isComponent2
    spline.isComponent3 = data.isComponent3
    spline.isComponent4 = data.isComponent4
    spline.component1RandomWeight = data.component1RandomWeight
    spline.component2RandomWeight = data.component2RandomWeight
    spline.component3RandomWeight = data.component3RandomWeight
    spline.component4RandomWeight = data.component4RandomWeight

    -- Remove all the decals for the spline.
    pop.tryRemove(spline)
  end
end

-- Handles the undo for a single decal spline.
local function singleSplineEditUndo(decalSplineData)
  local data = decalSplineData.old
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the redo for a single decal spline.
local function singleSplineEditRedo(decalSplineData)
  local data = decalSplineData.new
  if data then
    singleSplineEditUndoRedoCore(data)
  end
end

-- Handles the undo for trans decal spline edits.
local function transSplineEditUndo(data)
  removeAllDecalSplines(true)
  setDecalSplines(data.old)
  for i = 1, #decalSplines do
    decalSplines[i].isDirty = true
  end

  -- Update the spline map.
  util.computeIdToIdxMap(decalSplines, splineMap)
end

-- Handles the redo for trans decal spline edits.
local function transSplineEditRedo(data)
  removeAllDecalSplines(true)
  setDecalSplines(data.new)
  for i = 1, #decalSplines do
    decalSplines[i].isDirty = true
  end

  -- Update the spline map.
  util.computeIdToIdxMap(decalSplines, splineMap)
end

-- Copies the profile of the given decal spline.
local function copyDecalSplineProfile(spline)
  local copy = deepCopyDecalSpline(spline)
  copy.nodes = nil -- Remove the geometry data.
  copy.widths = nil
  copy.nmls = nil
  copy.divPoints = nil
  copy.divWidths = nil
  copy.tangents = nil
  copy.binormals = nil
  copy.normals = nil
  copy.discMap = nil
  return copy
end

-- Pastes the profile to the given decal spline.
local function pasteDecalSplineProfile(spline, profile)
  -- Clean up old decal objects before applying new profile.
  pop.tryRemove(spline)

  spline.isDirty = true
  spline.isAliasRoundRobin = profile.isAliasRoundRobin
  spline.spacing = profile.spacing
  spline.jitter = profile.jitter
  spline.rot1 = profile.rot1
  spline.rot2 = profile.rot2
  spline.rot3 = profile.rot3
  spline.rot4 = profile.rot4
  spline.numRows1 = profile.numRows1
  spline.numCols1 = profile.numCols1
  spline.scale1 = profile.scale1
  spline.frame1 = profile.frame1
  spline.numRows2 = profile.numRows2
  spline.numCols2 = profile.numCols2
  spline.scale2 = profile.scale2
  spline.frame2 = profile.frame2
  spline.numRows3 = profile.numRows3
  spline.numCols3 = profile.numCols3
  spline.scale3 = profile.scale3
  spline.frame3 = profile.frame3
  spline.numRows4 = profile.numRows4
  spline.numCols4 = profile.numCols4
  spline.scale4 = profile.scale4
  spline.frame4 = profile.frame4
  spline.randomSeed = profile.randomSeed
  spline.component1Material = profile.component1Material
  spline.component2Material = profile.component2Material
  spline.component3Material = profile.component3Material
  spline.component4Material = profile.component4Material
  spline.isComponent2 = profile.isComponent2
  spline.isComponent3 = profile.isComponent3
  spline.isComponent4 = profile.isComponent4
  spline.component1RandomWeight = profile.component1RandomWeight
  spline.component2RandomWeight = profile.component2RandomWeight
  spline.component3RandomWeight = profile.component3RandomWeight
  spline.component4RandomWeight = profile.component4RandomWeight
end

-- Serialises a decal spline to a table.
local function serializeDecalSpline(spline)
  local copy = buffer.encode(spline)
  table.clear(spline.divPoints)
  table.clear(spline.divWidths)
  table.clear(spline.tangents)
  table.clear(spline.binormals)
  table.clear(spline.normals)
  table.clear(spline.discMap)
  return copy
end

-- Deserialises a decal spline from a table.
local function deserializeDecalSpline(data, isCreateObject)
  local spline = buffer.decode(data)
  spline.isDirty = true
  return spline
end

-- Updates the geometry and templates/instances of any dirty decal splines.
local function updateDirtyDecalSplines()
  for i = 1, #decalSplines do
    local spline = decalSplines[i]
    if spline.isDirty then
      -- Check if spline has enough nodes to be valid (minimum 2).
      if #spline.nodes < 2 then
        -- Remove all decals and clear secondary geometry when insufficient nodes.
        pop.tryRemove(spline)
        table.clear(spline.divPoints)
        table.clear(spline.divWidths)
        table.clear(spline.tangents)
        table.clear(spline.binormals)
        table.clear(spline.normals)
        table.clear(spline.discMap)
        spline.roadLength = 0.0
      else
        local nodes = spline.nodes
        for j = 1, #nodes do
          util.vertRaycast(nodes[j])
        end
        geom.catmullRomRaycast(spline, minSplineDivisions)
        randomseed(spline.randomSeed)
        pop.tryRemove(spline)
        pop.populateDecalSpline(spline, decalSplines)

        spline.roadLength = util.getPolyLength(spline.nodes) -- Update the spline length.
      end

      spline.isDirty = false
    end
  end
end

-- Converts the given paths (traced from a bitmap) to decal splines.
local function convertPathsToDecalSplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new decal spline.
    addNewDecalSpline()
    local spline = decalSplines[#decalSplines]

    -- Convert the grid points to world space.
    local points = path.points
    local numPoints = #points
    local pointsWS = table.new(numPoints, 0)
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
  log('I', logTag, string.format("Converted %d traced paths to decal splines. %d paths were too small to import.", #paths, #paths - #decalSplines))
end

-- Returns the current list of decal splines.
local function getCurrentDecalSplineList()
  local numSplines = #decalSplines
  local list, ctr = table.new(numSplines, 0), 1
  for i = 1, numSplines do
    local spline = decalSplines[i]
    if spline.isEnabled then
      list[ctr] = { name = spline.name, id = spline.id, type = toolPrefixStr }
      ctr = ctr + 1
    end
  end
  return list
end

-- Returns true if the given decal spline is linked, false otherwise.
local function isLinked(id)
  local spline = decalSplines[splineMap[id]]
  return spline and spline.isLink or false
end

-- Sets the given linked decal spline to be linked or not.
local function setLink(id, groupId, isLink)
  local spline = decalSplines[splineMap[id]]
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

-- Updates the given linked decal spline with the given geometry.
local function updateLinkedDecalSpline(id, points, widths, nmls, isLoop, isConformToTerrain)
  local spline = decalSplines[splineMap[id]]
  if spline then
    spline.nodes, spline.widths, spline.nmls = points, widths, nmls
    spline.isLoop = isLoop -- Propagate the loop state of the master spline to the decal spline.

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

-- Unlinks all decal splines.
local function unlinkAll()
  for i = 1, #decalSplines do
    local spline = decalSplines[i]
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
M.getDecalSplines =                                     getDecalSplines
M.getSplineMap =                                        getSplineMap
M.setDecalSplines =                                     setDecalSplines
M.setDecalSpline =                                      setDecalSpline
M.getDefaultSliderParams =                              getDefaultSliderParams

M.addNewDecalSpline =                                   addNewDecalSpline

M.splitDecalSpline =                                    splitDecalSpline
M.joinDecalSplines =                                    joinDecalSplines

M.removeDecalSpline =                                   removeDecalSpline
M.removeLinkedDecalSpline =                             removeLinkedDecalSpline
M.removeAllDecalSplines =                               removeAllDecalSplines

M.deepCopyDecalSpline =                                 deepCopyDecalSpline
M.deepCopyDecalSplineState =                            deepCopyDecalSplineState
M.copyDecalSplineProfile =                              copyDecalSplineProfile
M.pasteDecalSplineProfile =                             pasteDecalSplineProfile

M.singleSplineEditUndo =                                singleSplineEditUndo
M.singleSplineEditRedo =                                singleSplineEditRedo
M.transSplineEditUndo =                                 transSplineEditUndo
M.transSplineEditRedo =                                 transSplineEditRedo

M.updateDirtyDecalSplines =                             updateDirtyDecalSplines

M.convertPathsToDecalSplines =                          convertPathsToDecalSplines

M.serializeDecalSpline =                                serializeDecalSpline
M.deserializeDecalSpline =                              deserializeDecalSpline
M.deepCopyDecalSplineState =                            deepCopyDecalSplineState

M.getCurrentDecalSplineList =                           getCurrentDecalSplineList
M.isLinked =                                            isLinked
M.setLink =                                             setLink
M.updateLinkedDecalSpline =                             updateLinkedDecalSpline
M.unlinkAll =                                           unlinkAll

return M
