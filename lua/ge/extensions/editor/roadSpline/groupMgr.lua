-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = "Road Spline" -- The global prefix for the road spline tool.
local editModeKey = "roadSplineEditor" -- The edit mode key for this tool.

local minSplineDivisions = 20 -- The minimum number of subdivisions to use for a Road Spline.

local minImportSize = 10.0 -- The minimum size of a Road Spline to import.

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}
local logTag = 'roadSplineEditor'

-- Module dependencies.
local buffer = require('string.buffer')
local layerMgr = require('editor/roadSpline/layerMgr')
local geom = require('editor/toolUtilities/geom')
local engineeredGeom = require('editor/toolUtilities/engineeredGeom')
local curveWiden = require('editor/toolUtilities/curveWiden')
local util = require('editor/toolUtilities/util')
local paint = require('editor/toolUtilities/terrainPainter')
local session = require('editor/toolUtilities/session')
local splineLock = require('editor/toolUtilities/splineLock')

-- Module constants.
local abs, min = math.abs, math.min
local defaultProperties = layerMgr.getSliderDefaults()

-- Module state.
local groups = {}
local groupMap = {}
local lockApplied = {} -- group id -> the lock state last applied to its DecalRoads (see splineLock.sync).
local tmpPoint2I = Point2I(0, 0)


-- Gets the current road splines array.
local function getGroups() return groups end

-- Gets the group id -> index map.
local function getIdToIdxMap() return groupMap end

-- Gets the prefix string for the tool.
local function getToolPrefixStr() return toolPrefixStr end

-- Gets the edit mode key for the road spline tool.
local function getEditModeKey() return editModeKey end

-- Adds a group to the groups array.
local function addGroupToGroupArray(group)
  -- Ensure we have a unique group name.
  local baseName = group.name or string.format(toolPrefixStr .. " %d", #groups + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)

  -- Create a new folder for the group.
  if not group.sceneTreeFolderId or not scenetree.findObjectById(group.sceneTreeFolderId) then
    local newFolder = createObject("SimGroup")
    local folderNameId = Engine.generateUUID()
    newFolder:registerObject(string.format("%s - %s", uniqueName, folderNameId))
    newFolder.cansave = false -- Transient while editing; the Bake button flips the folder to canSave=true.
    scenetree.MissionGroup:addObject(newFolder)
    group.sceneTreeFolderId = newFolder:getId()
  end

  -- Add the group to the groups collection.
  table.insert(groups, group)
end

-- Removes the group at the given index.
local function removeGroup(idx)
  local group = groups[idx]
  if group then
    lockApplied[group.id] = nil
    paint.revert(group) -- Revert any terrain painting, if active.
    layerMgr.removeAllLayers(group) -- Remove all layers associated with the group.
    table.clear(group.chunkStartIndices)
    table.clear(group.chunkEndIndices)
    group.numChunks = 0
    if group.sceneTreeFolderId then
      local folder = scenetree.findObjectById(group.sceneTreeFolderId)
      if folder then
        folder:delete() -- Delete the folder associated with the group, if it exists.
      end
    end
    table.remove(groups, idx) -- Remove the group from the groups collection.
  end
  util.computeIdToIdxMap(groups, groupMap) -- Recompute the group id -> index map.
end

-- Calls fn(decalRoad) for each of the group's DecalRoads (the splineLock `each`).
local function eachObject(group, fn)
  local layers = group.layers
  if layers then for i = 1, #layers do layerMgr.eachLayerRoad(layers[i], fn) end end
end

-- Brings the group's DecalRoads in line with its lock state (see splineLock.lua). A locked rebuild remakes its auto layers'
-- roads, so it always re-applies. Terrain painting is baked into the terrain either way.
local function syncLockState(group)
  if not group.isEnabled then lockApplied[group.id] = nil end
  splineLock.sync(lockApplied, group, toolPrefixStr, function(fn) eachObject(group, fn) end)
end

-- A locked road whose DecalRoads exist is not rebuilt (the tool does not move them, nor repaint the terrain): its lock state is
-- applied. Returns true if so.
local function keepLocked(group)
  local each = function(fn) eachObject(group, fn) end
  if group.isEnabled or not splineLock.hasAny(each) then return false end
  splineLock.sync(lockApplied, group, toolPrefixStr, each)
  for _, layer in ipairs(group.layers or {}) do layer.isDirty = false end
  return true
end

-- Lua reload: a locked road's DecalRoad ids per layer id, for adopt() to pick up again (the roads, folder and terrain paint
-- stay in the scene as they are).
local function release(group)
  local ids = {}
  for _, layer in ipairs(group.layers or {}) do
    ids[layer.id] = { id = layer.decalRoadId, ids = layer.decalRoadIds and deepcopy(layer.decalRoadIds) or {} }
  end
  return ids
end

-- Takes back the DecalRoads release() listed (those still in the scene), as they are.
local function adopt(group, ids)
  local function alive(id) return id and scenetree.findObjectById(id) and id or nil end
  for _, layer in ipairs(group.layers or {}) do
    local k = ids[layer.id]
    if k then
      layer.decalRoadId = alive(k.id)
      layer.decalRoadIds = {}
      for i = 1, #k.ids do layer.decalRoadIds[#layer.decalRoadIds + 1] = alive(k.ids[i]) end
    end
  end
  lockApplied[group.id] = not group.isEnabled
end

-- Finds a live road spline (group) by id (nil if not present).
local function findGroup(id)
  local idx = groupMap[id]
  return idx and groups[idx] or nil
end

-- Removes a linked road spline by ID (called from master spline layer removal).
local function removeLinkedRoadSpline(splineId)
  local idx = groupMap[splineId]
  if idx then
    removeGroup(idx)
  end
end

-- Removes all groups from the session.
local function removeAllGroups(isIncludeDisabled)
  if isIncludeDisabled then
    for i = #groups, 1, -1 do
      local group = groups[i]
      if group then
        removeGroup(i)
      end
    end
    table.clear(groups)
  else
    for i = #groups, 1, -1 do
      local group = groups[i]
      if group.isEnabled and not group.isLink then -- Only remove enabled and unlinked groups.
        removeGroup(i)
      end
    end
  end
end

-- Removes all auto-generated (hidden) layers, then recreates them.
local function recreateAutoGeneratedLayers(group)
  -- Remove all auto-generated layers.
  layerMgr.removeAllHiddenLayers(group)

  -- Recreate the auto-generated decal road layers.
  if group.isLightTreadMarks then layerMgr.addLightTreadMarksLayers(group) end
  if group.isHeavyTreadMarks then layerMgr.addHeavyTreadMarksLayers(group) end
  if group.isRepair1 then layerMgr.addRepair1Layers(group) end
  if group.isRepair2 then layerMgr.addRepair2Layers(group) end
  if group.isDamageAsphalt1 then layerMgr.addRoadDamageAsphalt1Layers(group) end
  if group.isDamageAsphalt2 then layerMgr.addRoadDamageAsphalt2Layers(group) end
  if group.isRoadCrack then layerMgr.addRoadCrackLayers(group) end
  if group.isPatches then layerMgr.addPatchesLayers(group) end
  if group.isRoadCenterLine then layerMgr.addRoadCenterLineLayers(group) end
  if group.isRoadEdgeLines then layerMgr.addRoadEdgeLinesLayers(group) end
  if group.isRoadLaneLines then layerMgr.addRoadLaneLinesLayers(group) end
  if group.isEdgeBlend1 then layerMgr.addEdgeBlend1Layers(group) end
  if group.isEdgeBlend2 then layerMgr.addEdgeBlend2Layers(group) end
  if group.isEdgeBlend3 then layerMgr.addEdgeBlend3Layers(group) end

  -- Mark the group as dirty so the layers get properly updated and rendered
  group.isDirty = true
end

-- Updates the dirty groups. When dragging is true (a live corner-knob / node drag), valid groups only re-sample their geometry +
-- rib points -- enough for the ribbon wireframe to track the drag -- and the heavy paint/decal rebuild is deferred by leaving the
-- group dirty, so it rebuilds once on release instead of every frame (mirrors the hero-road drag path; stops the knob-drag jitter).
local function updateDirtyGroups(dragging)
  local rebuiltAny = false -- did any group/layer actually rebuild this pass? (-> the document has an unsaved edit).
  for i = 1, #groups do
    local group = groups[i]
    if group.isDirty then
      rebuiltAny = true
      -- Check if group has enough nodes to be valid (minimum 2).
      if #group.nodes < 2 then
        -- Remove all layers and clear secondary geometry when insufficient nodes.
        layerMgr.removeAllLayers(group)
        -- Clear secondary geometry arrays
        table.clear(group.ribPoints)
        table.clear(group.divPoints)
        table.clear(group.divWidths)
        table.clear(group.tangents)
        table.clear(group.binormals)
        table.clear(group.normals)
        table.clear(group.discMap)
        table.clear(group.chunkStartIndices)
        table.clear(group.chunkEndIndices)
        group.numChunks = 0
        group.roadLength = 0.0
      else
        local isKept = keepLocked(group)
        if not isKept then paint.revert(group) end -- Revert any terrain painting.
        local nodes = group.nodes
        for j = 1, #nodes do
          util.vertRaycast(nodes[j])
        end
        -- Engineered mode builds a clothoid centerline (draped to terrain via the raycast Z mode); spline mode uses Catmull-Rom.
        -- Linked children are forced to spline: their nodes are the master's dense sampled centerline, not authorable corner PIs.
        local didEngineer = not group.isLink and engineeredGeom.sampleInto(group, { zMode = 'raycast', lonRes = minSplineDivisions })
        if not didEngineer then
          geom.catmullRomRaycast(group, minSplineDivisions) -- Update the secondary (discretised) geometry properties.
        else
          curveWiden.applyDivWidthWiden(group) -- widen divWidths through tight engineered corners (no-op on gentle roads).
        end
        geom.updateRibPointsRaycast(group) -- Update the rib points.
        -- Engineered roads cut corners, so their true length is the built centerline, not the node polyline.
        groups[i].roadLength = didEngineer and util.getPolyLength(group.divPoints) or util.getPolyLength(group.nodes)

        -- Mid-drag: the spline + ribs above already followed, so the ribbon wireframe tracks the drag live. Skip the heavy
        -- paint/decal rebuild and leave the group dirty so it rebuilds ONCE on release (every frame is what made it jitter/lag).
        if not dragging and not isKept then
          -- Update the terrain painting, if active.
          if group.isPainting then
            paint.paint(group)
          end

          -- Regenerate auto-generated layers to ensure they cover the current road width.
          recreateAutoGeneratedLayers(group)

          layerMgr.updateAllLayers(group, i) -- Update all the layers.
          syncLockState(group)
        end
      end

      if not dragging then groups[i].isDirty = false end -- keep dirty mid-drag so the deferred rebuild fires on release.
    else
      -- The group is not dirty, but it may contain dirty layers (a marking edit) -- that still counts as a document change.
      local layers = group.layers
      if layers then for li = 1, #layers do if layers[li].isDirty then rebuiltAny = true; break end end end
      layerMgr.updateOnlyDirtyLayers(group, i) -- The group is not dirty, but it may contain dirty layers.
    end
  end
  if rebuiltAny then session.markEdited('roadSpline') end -- fold this pass's edits into the Save/Save As dirty state (load guard swallows a fresh load's rebuild).
end

-- Sets the width of the group to a fixed value at every node.
local function setFixedWidth(group, width)
  for i = 1, #group.widths do
    group.widths[i] = width
  end
  group.isDirty = true
end

-- Adds a new group.
local function addNewGroup(name)
  -- Ensure we have a unique group name.
  local baseName = name or string.format(toolPrefixStr .. " %d", #groups + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
  local id = Engine.generateUUID()

  -- Create a new folder for the group.
  local newFolder = createObject("SimGroup")
  newFolder:registerObject(string.format("%s - %s", uniqueName, id))
  newFolder.cansave = false -- Transient while editing; saves with the level while the road is locked.
  scenetree.MissionGroup:addObject(newFolder)

  -- Create the new group.
  local newGroup = {
    name = uniqueName,
    id = id,
    isLoop = false,
    sceneTreeFolderId = newFolder:getId(),
    isEnabled = true,
    isDirty = false,
    isLink = false,
    linkId = nil,
    roadLength = 0.0,
    -- Default a NEW road to engineered (clothoid) corners; horizontal design only (roadSpline drapes Z to terrain). Old sessions
    -- keep their saved mode -- deserialize's applyDefaults only backfills 'spline' when the field is absent, so this never flips them.
    geometryMode = 'engineered',
    engRadiusM = engineeredGeom.CONTROLS.radius.default,
    engTransM = engineeredGeom.CONTROLS.transition.default,
    engVertLenM = engineeredGeom.CONTROLS.vertical.default,
    nodes = {},
    widths = {},
    nmls = {},
    ribPoints = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    layers = {},
    isOverObjects = false,
    isLightTreadMarks = true,
    isHeavyTreadMarks = false,
    isDamageAsphalt1 = false,
    isDamageAsphalt2 = false,
    isRoadCrack = false,
    isRepair1 = false,
    isRepair2 = false,
    isPatches = false,
    isRoadCenterLine = true,
    isRoadEdgeLines = true,
    isRoadLaneLines = false,
    isEdgeBlend1 = true,
    isEdgeBlend2 = false,
    isEdgeBlend3 = false,

    -- Placement/size of the auto-generated edge decals. Road-level (not layer) properties: offset is a lateral
    -- position multiplier where 1.0 == the road edge (scales with road width), width is the decal width in metres.
    edgeLineOffset = 1.0,
    edgeLineWidth = 0.25,
    edgeBlend1Offset = 1.1,
    edgeBlend1Width = 1.0,
    edgeBlend2Offset = 1.25,
    edgeBlend2Width = 2.0,
    edgeBlend3Offset = 1.35,
    edgeBlend3Width = 3.0,

    -- Terrain painting properties.
    isPainting = false,
    paintMargin = 0.0,
    paintMaterialIdx = defaultProperties.defaultPaintMaterialIdx,

    -- Paint data arrays.
    paintedDataX = {},
    paintedDataY = {},
    paintedDataVals = {},
    paintedDataBoxXMin = 0,
    paintedDataBoxXMax = 0,
    paintedDataBoxYMin = 0,
    paintedDataBoxYMax = 0,

    -- Chunk data for long splines.
    chunkStartIndices = {},
    chunkEndIndices = {},
    numChunks = 0,
  }

  engineeredGeom.applyDefaults(newGroup)

  -- Create the initial auto-generated (hidden) layers.
  recreateAutoGeneratedLayers(newGroup)

  -- Add the new group to the groups collection.
  table.insert(groups, newGroup)

  -- Recompute the group id -> index map.
  util.computeIdToIdxMap(groups, groupMap)
end

-- Copies the layer profile from the given group (only the layers).
local function copyGroupProfile(sourceGroup)
  local profile = {
    layers = {},
    isOverObjects = sourceGroup.isOverObjects,
    isLightTreadMarks = sourceGroup.isLightTreadMarks,
    isHeavyTreadMarks = sourceGroup.isHeavyTreadMarks,
    isRoadCrack = sourceGroup.isRoadCrack,
    isRepair1 = sourceGroup.isRepair1,
    isRepair2 = sourceGroup.isRepair2,
    isPatches = sourceGroup.isPatches,
    isDamageAsphalt1 = sourceGroup.isDamageAsphalt1,
    isDamageAsphalt2 = sourceGroup.isDamageAsphalt2,
    isRoadCenterLine = sourceGroup.isRoadCenterLine,
    isRoadEdgeLines = sourceGroup.isRoadEdgeLines,
    isRoadLaneLines = sourceGroup.isRoadLaneLines,
    isEdgeBlend1 = sourceGroup.isEdgeBlend1,
    isEdgeBlend2 = sourceGroup.isEdgeBlend2,
    isEdgeBlend3 = sourceGroup.isEdgeBlend3,
    edgeLineOffset = sourceGroup.edgeLineOffset,
    edgeLineWidth = sourceGroup.edgeLineWidth,
    edgeBlend1Offset = sourceGroup.edgeBlend1Offset,
    edgeBlend1Width = sourceGroup.edgeBlend1Width,
    edgeBlend2Offset = sourceGroup.edgeBlend2Offset,
    edgeBlend2Width = sourceGroup.edgeBlend2Width,
    edgeBlend3Offset = sourceGroup.edgeBlend3Offset,
    edgeBlend3Width = sourceGroup.edgeBlend3Width,
  }

  local layers, ctr = sourceGroup.layers, 1
  for i = 1, #layers do
    local layer = layers[i]
    if not layer.isHidden then -- Do not copy any auto-generated layers.
      -- serializeLayer, NOT deepCopyLayer: a profile is saved to JSON and reloaded into other sessions, so it
      -- must hold only authorable fields and NONE of the runtime DecalRoad scene ids. Carrying decalRoadId /
      -- decalRoadIds made pasted layers share (or fight over) existing scene roads -- e.g. only the first road's
      -- textureLength/length appeared to apply, and duplicates rendered wrong or vanished.
      profile.layers[ctr] = layerMgr.serializeLayer(layer)
      ctr = ctr + 1
    end
  end

  return profile
end

-- Pastes a layer profile onto the given group.
local function pasteGroupProfile(targetGroup, profile)
  layerMgr.removeAllLayers(targetGroup)

  for i = 1, #profile.layers do
    -- deserializeLayer gives each pasted layer a clean slate (decalRoadId = nil, empty decalRoadIds, isDirty),
    -- so every layer builds its OWN fresh DecalRoad(s) instead of inheriting stale/shared scene ids from the
    -- profile. This is what makes per-layer texLen/width/direction all apply, not just the first layer's.
    targetGroup.layers[i] = layerMgr.deserializeLayer(profile.layers[i])
  end

  targetGroup.isOverObjects = profile.isOverObjects or false
  targetGroup.isLightTreadMarks = profile.isLightTreadMarks or false
  targetGroup.isHeavyTreadMarks = profile.isHeavyTreadMarks or false
  targetGroup.isRoadCrack = profile.isRoadCrack or false
  targetGroup.isRepair1 = profile.isRepair1 or false
  targetGroup.isRepair2 = profile.isRepair2 or false
  targetGroup.isPatches = profile.isPatches or false
  targetGroup.isDamageAsphalt1 = profile.isDamageAsphalt1 or false
  targetGroup.isDamageAsphalt2 = profile.isDamageAsphalt2 or false
  targetGroup.isRoadCenterLine = profile.isRoadCenterLine or false
  targetGroup.isRoadEdgeLines = profile.isRoadEdgeLines or false
  targetGroup.isRoadLaneLines = profile.isRoadLaneLines or false
  targetGroup.isEdgeBlend1 = profile.isEdgeBlend1 or false
  targetGroup.isEdgeBlend2 = profile.isEdgeBlend2 or false
  targetGroup.isEdgeBlend3 = profile.isEdgeBlend3 or false
  -- Edge decal placement/size. Defaults keep older profiles (saved before these existed) valid, and guarantee the
  -- slider UI always reads a non-nil number.
  targetGroup.edgeLineOffset = profile.edgeLineOffset or 1.0
  targetGroup.edgeLineWidth = profile.edgeLineWidth or 0.25
  targetGroup.edgeBlend1Offset = profile.edgeBlend1Offset or 1.1
  targetGroup.edgeBlend1Width = profile.edgeBlend1Width or 1.0
  targetGroup.edgeBlend2Offset = profile.edgeBlend2Offset or 1.25
  targetGroup.edgeBlend2Width = profile.edgeBlend2Width or 2.0
  targetGroup.edgeBlend3Offset = profile.edgeBlend3Offset or 1.35
  targetGroup.edgeBlend3Width = profile.edgeBlend3Width or 3.0
  targetGroup.isOverObjects = profile.isOverObjects or false

  targetGroup.isDirty = true

  -- Recreate the auto-generated layers.
  recreateAutoGeneratedLayers(targetGroup)
end

-- Deep copies the given group.
local function deepCopyGroup(group)
  local copy = buffer.decode(buffer.encode(group))
  table.clear(copy.divPoints)
  table.clear(copy.divWidths)
  table.clear(copy.tangents)
  table.clear(copy.binormals)
  table.clear(copy.normals)
  table.clear(copy.discMap)
  copy.divCurv = nil -- derived engineered curvature; rebuilt by the dirty pass.
  return copy
end

-- Deep copies the full group state.
local function deepCopyAllGroups()
  local copy = {}
  for i = 1, #groups do
    copy[i] = deepCopyGroup(groups[i])
  end
  return copy
end

-- Splits the given group at the selected node index.
local function splitGroup(group, groupIdx, selectedNodeIdx)
  -- Revert any terrain painting, if active.
  paint.revert(group)

  if group.isLoop then
    -- Use the helper function for loop spline geometry splitting (carries the per-corner overrides through the reorder).
    local cornersNew
    group.nodes, group.widths, group.nmls, cornersNew = geom.splitLoopSplineGeometry(group.nodes, group.widths, group.nmls, selectedNodeIdx, group.corners)
    group.corners = cornersNew -- keep per-corner overrides (radius etc.) node-aligned; geom returns a dense array.
    group.isLoop = false
    group.isDirty = true
  else
    -- Carry the per-corner overrides (radius etc.) through the split so each half keeps its own settings, on the right nodes.
    local nodes1, widths1, nmls1, nodes2, widths2, nmls2, corners1, corners2 =
      geom.splitSplineGeometry(group.nodes, group.widths, group.nmls, selectedNodeIdx, group.corners)

    -- Prepare copies.
    local group1 = deepCopyGroup(group)
    group1.name = group.name .. " (1)"
    group1.id = Engine.generateUUID()
    group1.nodes = nodes1
    group1.widths = widths1
    group1.nmls = nmls1
    group1.corners = corners1 -- keep this half's per-corner overrides (dense, node-aligned).
    group1.isDirty = true

    local group2 = deepCopyGroup(group)
    group2.name = group.name .. " (2)"
    group2.id = Engine.generateUUID()
    group2.nodes = nodes2
    group2.widths = widths2
    group2.nmls = nmls2
    group2.corners = corners2 -- keep this half's per-corner overrides (dense, node-aligned).
    group2.isDirty = true

    -- Remove the old group and add the new ones.
    removeGroup(groupIdx)
    addGroupToGroupArray(group1)
    addGroupToGroupArray(group2)
  end

  -- Recompute the group id -> index map.
  util.computeIdToIdxMap(groups, groupMap)
end

-- Joins two unlooped road group splines into one, modifying group1 and deleting group2.
local function joinRoadSplines(groupIdx1, nodeIdx1, groupIdx2, nodeIdx2)
  local group1, group2 = groups[groupIdx1], groups[groupIdx2]
  if not group1 or not group2 then
    return
  end

  -- Join the two groups (carries both roads' per-corner overrides through the join, index-aligned to the joined node list).
  local nodesNew, widthsNew, nmlsNew, cornersNew =
    geom.joinSplineGeometry(group1.nodes, group1.widths, group1.nmls, nodeIdx1, group2.nodes, group2.widths, group2.nmls, nodeIdx2, group1.corners, group2.corners)
  if not nodesNew then
    return -- Early return if invalid node indices.
  end

  -- Apply joined geometry to group1.
  group1.nodes = nodesNew
  group1.widths = widthsNew
  group1.nmls = nmlsNew
  group1.corners = cornersNew -- keep both roads' per-corner overrides (dense, node-aligned).
  group1.isLoop = false
  group1.isDirty = true

  -- Remove group2 directly to avoid index shift issues.
  removeGroup(groupIdx2)

  -- Recompute the ID-to-Index map for consistency.
  util.computeIdToIdxMap(groups, groupMap)
end

-- Converts the given paths (traced from a bitmap) to Road Splines.
local function convertPathsToRoadSplines(paths)
  local tb = extensions.editor_terrainEditor.getTerrainBlock()
  local te = extensions.editor_terrainEditor.getTerrainEditor()
  for i = 1, #paths do
    local path = paths[i]

    -- Create a new Road Spline.
    addNewGroup()
    local group = groups[#groups]

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
      group.nodes, group.widths = pointsWS, path.widths -- Set the nodes and widths directly.
      for j = 1, numPoints do
        group.nmls[j] = geom.getTerrainNormal(pointsWS[j]) -- Compute the normals for each node.
      end
    end
  end
  log('I', logTag, string.format("Converted %d traced paths to Road Splines. %d paths were too small to import.", #paths, #paths - #groups))
end

-- Serialises a group.
local function serializeGroup(group)
  if group.isEnabled then paint.revert(group) end -- Revert any terrain painting, if active (a locked road keeps it).
  table.clear(group.divPoints)
  table.clear(group.divWidths)
  table.clear(group.tangents)
  table.clear(group.binormals)
  table.clear(group.normals)
  table.clear(group.discMap)
  table.clear(group.ribPoints)
  group.divCurv = nil -- derived engineered curvature; rebuilt by the dirty pass.
  return buffer.encode(group)
end

-- Serialises a group to a portable plain table for a session file (see toolUtilities/session). Deep-copied through the codec so
-- the live group is never mutated; derived geometry is emptied (rebuilt by the dirty pass), and runtime scene handles dropped.
local function serializeGroupToTable(group)
  local t = session.itemToTable(group,
    { 'divPoints', 'divWidths', 'tangents', 'binormals', 'normals', 'discMap', 'divCurv', 'ribPoints', 'chunkStartIndices', 'chunkEndIndices' },
    { 'sceneTreeFolderId', 'numChunks' })
  if group.layers then
    -- Emit clean, authored-only layers (same as the profile copy path): drops the per-layer runtime geometry buffers
    -- (pClipped/wClipped/pFlip/wFlip) and DecalRoad handles. Keeping them bloats the file to megabytes AND reloads as stale
    -- plain {x,y,z} tables that crash buildLayerPolyline (vec3 methods on a plain table) on the load's dirty pass.
    t.layers = {}
    for i = 1, #group.layers do t.layers[i] = layerMgr.serializeLayer(group.layers[i]) end
  end
  return t
end

-- Deserialises a group. `data` is either the editor's buffer-encoded blob (string) or a plain table straight from a JSON
-- session file -- the same backfill path serves both. On the JSON path the runtime scratch tables are missing and node
-- positions arrive as plain {x,y,z}, so guarantee the tables exist and rehydrate them to vec3 before the first build.
local function deserializeGroup(data, isCreateObject)
  local group = type(data) == 'table' and data or buffer.decode(data)
  group.isDirty = true

  group.nodes = group.nodes or {}
  group.widths = group.widths or {}
  group.nmls = group.nmls or {}
  group.ribPoints = group.ribPoints or {}
  group.divPoints = group.divPoints or {}
  group.divWidths = group.divWidths or {}
  group.tangents = group.tangents or {}
  group.binormals = group.binormals or {}
  group.normals = group.normals or {}
  group.discMap = group.discMap or {}
  group.layers = group.layers or {}
  -- Rehydrate every layer to a clean slate (fresh empty vec3 buffers, isDirty, empty decalRoadIds). Both load paths need this:
  -- a JSON session brings plain {x,y,z} buffers, and the buffer path loses the layer's runtime handles too. This also rescues
  -- older bloated session files (the stale per-layer buffers are discarded here rather than fed to buildLayerPolyline).
  for i = 1, #group.layers do group.layers[i] = layerMgr.deserializeLayer(group.layers[i]) end
  group.chunkStartIndices = group.chunkStartIndices or {}
  group.chunkEndIndices = group.chunkEndIndices or {}
  group.numChunks = group.numChunks or 0
  session.rehydrateVec3Array(group.nodes)
  session.rehydrateVec3Array(group.nmls)
  engineeredGeom.applyDefaults(group) -- backfill geometryMode + design lengths for roads saved before engineered mode existed.

  -- Backfill edge-decal properties for roads saved before these fields existed, so the builders and the slider
  -- UI always see valid numbers (FloatPtr(nil) would crash the UI).
  group.edgeLineOffset = group.edgeLineOffset or 1.0
  group.edgeLineWidth = group.edgeLineWidth or 0.25
  group.edgeBlend1Offset = group.edgeBlend1Offset or 1.1
  group.edgeBlend1Width = group.edgeBlend1Width or 1.0
  group.edgeBlend2Offset = group.edgeBlend2Offset or 1.25
  group.edgeBlend2Width = group.edgeBlend2Width or 2.0
  group.edgeBlend3Offset = group.edgeBlend3Offset or 1.35
  group.edgeBlend3Width = group.edgeBlend3Width or 3.0

  -- Create a new scene tree folder for the road spline, if requested. A locked road kept across a Lua reload keeps its own.
  if group.keptObjects and group.sceneTreeFolderId and scenetree.findObjectById(group.sceneTreeFolderId) then
    -- Kept folder: nothing to create.
  elseif isCreateObject then
    local newFolder = createObject("SimGroup")
    newFolder:registerObject(string.format("%s - %s", group.name, group.id))
    newFolder.cansave = not group.isEnabled -- Transient while editing; a locked road's folder saves with the level.
    scenetree.MissionGroup:addObject(newFolder)
    group.sceneTreeFolderId = newFolder:getId()
  end

  return group
end

-- Undo/redo core for single group changes.
local function singleGroupUndoRedoCore(data)
  local idx = groupMap[data.id]
  if idx then
    local group = groups[idx]
    paint.revert(group) -- Revert any terrain painting, if active.
    layerMgr.removeAllLayers(group) -- Remove all layers associated with the group.
    group.layers = layerMgr.deepCopyAllLayers(data.layers) -- Need to deep copy all layers from the undo/redo history.
    group.name = data.name
    group.id = data.id
    group.isLoop = data.isLoop
    group.isDirty = true -- Set the dirty flag to true.
    group.isEnabled = data.isEnabled
    group.isLink = data.isLink
    group.linkId = data.linkId
    group.nodes = data.nodes
    group.widths = data.widths
    group.nmls = data.nmls
    group.roadLength = data.roadLength
    group.geometryMode = data.geometryMode
    group.engRadiusM = data.engRadiusM
    group.engTransM = data.engTransM
    group.engVertLenM = data.engVertLenM
    group.curveWidenMaxM = data.curveWidenMaxM
    group.curveWidenRunoffM = data.curveWidenRunoffM
    group.corners = data.corners
    group.isOverObjects = data.isOverObjects
    group.isLightTreadMarks = data.isLightTreadMarks
    group.isHeavyTreadMarks = data.isHeavyTreadMarks
    group.isDamageAsphalt1 = data.isDamageAsphalt1
    group.isDamageAsphalt2 = data.isDamageAsphalt2
    group.isRoadCrack = data.isRoadCrack
    group.isRepair1 = data.isRepair1
    group.isRepair2 = data.isRepair2
    group.isPatches = data.isPatches
    group.isRoadCenterLine = data.isRoadCenterLine
    group.isRoadEdgeLines = data.isRoadEdgeLines
    group.isRoadLaneLines = data.isRoadLaneLines
    group.isEdgeBlend1 = data.isEdgeBlend1
    group.isEdgeBlend2 = data.isEdgeBlend2
    group.isEdgeBlend3 = data.isEdgeBlend3
    group.edgeLineOffset = data.edgeLineOffset
    group.edgeLineWidth = data.edgeLineWidth
    group.edgeBlend1Offset = data.edgeBlend1Offset
    group.edgeBlend1Width = data.edgeBlend1Width
    group.edgeBlend2Offset = data.edgeBlend2Offset
    group.edgeBlend2Width = data.edgeBlend2Width
    group.edgeBlend3Offset = data.edgeBlend3Offset
    group.edgeBlend3Width = data.edgeBlend3Width

    -- Terrain painting properties.
    group.isPainting = data.isPainting
    group.paintMargin = data.paintMargin
    group.paintMaterialIdx = data.paintMaterialIdx
    group.paintedDataX = util.fastArrayCopy(data.paintedDataX)
    group.paintedDataY = util.fastArrayCopy(data.paintedDataY)
    group.paintedDataVals = util.fastArrayCopy(data.paintedDataVals)
    group.paintedDataBoxXMin = data.paintedDataBoxXMin
    group.paintedDataBoxXMax = data.paintedDataBoxXMax
    group.paintedDataBoxYMin = data.paintedDataBoxYMin
    group.paintedDataBoxYMax = data.paintedDataBoxYMax

    -- Special case for when the group has been renamed.
    if data.isUpdateSceneTree then
      if group.sceneTreeFolderId then
        local folder = scenetree.findObjectById(group.sceneTreeFolderId)
        if folder then
          folder:setName(group.name)
        end
      end
      editor.refreshSceneTreeWindow()
    end
  end
end

-- Handles the undo/redo for single group edits.
local function singleGroupEditUndo(data) singleGroupUndoRedoCore(data.old) end
local function singleGroupEditRedo(data) singleGroupUndoRedoCore(data.new) end

-- Undo/redo core for trans-group edits.
local function transGroupUndoRedoCore(data)
  paint.revertAll(groups) -- Revert any terrain painting, if active.
  removeAllGroups(true) -- Remove all groups.
  for i = 1, #data do
    addGroupToGroupArray(deepCopyGroup(data[i])) -- Add the given groups.
  end
  util.computeIdToIdxMap(groups, groupMap) -- Recompute the group id -> index map.

  -- Set the isDirty flag for all restored groups to ensure proper updates.
  for i = 1, #groups do
    groups[i].isDirty = true
  end
end

-- Handles the undo/redo for trans-group edits.
local function transGroupEditUndo(groupsData) transGroupUndoRedoCore(groupsData.old) end
local function transGroupEditRedo(groupsData) transGroupUndoRedoCore(groupsData.new) end

-- Recompute the group id -> index map (called by the shared session helper after a load appends the loaded roads).
local function recomputeIdMap() util.computeIdToIdxMap(groups, groupMap) end

-- Returns the current list of Road Splines.
local function getCurrentRoadSplineList()
  local list, ctr = {}, 1
  for i = 1, #groups do
    local group = groups[i]
    if group.isEnabled then
      list[ctr] = { name = group.name, id = group.id, type = toolPrefixStr }
      ctr = ctr + 1
    end
  end
  return list
end

-- Returns true if the given Road Spline is linked, false otherwise.
local function isLinked(id)
  local group = groups[groupMap[id]]
  return group and group.isLink or false
end

-- Sets the given Road Spline to be linked or not.
local function setLink(id, groupId, isLink)
  local group = groups[groupMap[id]]
  if group then
    group.isLink = isLink
    if isLink then
      group.linkId = groupId
    else
      group.linkId = nil
    end
    group.isDirty = true
  end
end

-- Updates the given linked Road Spline with the given geometry.
local function updateLinkedRoadSpline(id, points, widths, nmls, isLoop, isConformToTerrain)
  local group = groups[groupMap[id]]
  if group then
    group.nodes, group.widths, group.nmls = points, widths, nmls
    group.isLoop = isLoop -- Propagate the loop state of the master spline to the linked spline.
    group.isDirty = true
  end
end

-- Unlinks all Road Splines.
local function unlinkAll()
  for i = 1, #groups do
    local group = groups[i]
    if group.isLink then
      group.isLink = false
      group.linkId = nil
    end
    group.isDirty = true
  end
end


-- Public interface.
M.getGroups =                                          getGroups
M.getIdToIdxMap =                                      getIdToIdxMap
M.getToolPrefixStr =                                   getToolPrefixStr
M.getEditModeKey =                                     getEditModeKey
M.addGroupToGroupArray =                               addGroupToGroupArray

M.removeGroup =                                        removeGroup
M.findGroup =                                          findGroup
M.release =                                            release
M.adopt =                                              adopt
M.removeLinkedRoadSpline =                             removeLinkedRoadSpline
M.removeAllGroups =                                    removeAllGroups

M.updateDirtyGroups =                                  updateDirtyGroups

M.setFixedWidth =                                      setFixedWidth
M.recreateAutoGeneratedLayers =                        recreateAutoGeneratedLayers

M.addNewGroup =                                        addNewGroup

M.copyGroupProfile =                                   copyGroupProfile
M.pasteGroupProfile =                                  pasteGroupProfile
M.deepCopyGroup =                                      deepCopyGroup
M.deepCopyAllGroups =                                  deepCopyAllGroups

M.splitGroup =                                         splitGroup
M.joinRoadSplines =                                    joinRoadSplines

M.convertPathsToRoadGroups =                           convertPathsToRoadSplines

M.serializeGroup =                                     serializeGroup
M.deserializeGroup =                                   deserializeGroup
M.serializeGroupToTable =                              serializeGroupToTable
M.recomputeIdMap =                                     recomputeIdMap

M.singleGroupEditUndo =                                singleGroupEditUndo
M.singleGroupEditRedo =                                singleGroupEditRedo
M.transGroupEditUndo =                                 transGroupEditUndo
M.transGroupEditRedo =                                 transGroupEditRedo

M.getCurrentRoadSplineList =                           getCurrentRoadSplineList
M.isLinked =                                           isLinked
M.setLink =                                            setLink
M.updateLinkedRoadSpline =                             updateLinkedRoadSpline
M.unlinkAll =                                          unlinkAll

return M