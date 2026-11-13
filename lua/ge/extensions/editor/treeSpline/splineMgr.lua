-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

-- User constants.
local toolPrefixStr = 'Tree Spline' -- The global prefix for the tree spline tool.
local editModeKey = 'treeSplineEditMode' -- The edit mode key for this tool.

local minSplineDivisions = 20 -- Minimum divisions per segment (rows don't need the mesh tools' density).

------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

local M = {}

-- External modules.
local buffer = require('string.buffer')
local session = require('editor/toolUtilities/session') -- Shared Save/Load Session helper (itemToTable + vec3 rehydrate).
local pop = require('editor/treeSpline/populate')
local scatter = require('editor/toolUtilities/foliageScatter')
local geom = require('editor/toolUtilities/geom')
local util = require('editor/toolUtilities/util')

-- Module constants.
-- The persisted foliage fields (everything except geometry + runtime item handles). Kept in one place so the
-- undo core, deep copy and serialize all agree on exactly what a tree spline 'is'.
local foliageFields = {
  'species', 'speciesWeights', 'class', 'spacingM', 'posVariance', 'scaleVariance',
  'alignToNormal', 'slopeMaxDeg', 'seed', 'avoidInfrastructure',
}

-- Module state.
local treeSplines = {}
local splineMap = {}


local function drapedLists(out)
  for i = 1, #treeSplines do
    if treeSplines[i].items then out[#out + 1] = treeSplines[i].items end
  end
end
scatter.addDraped(drapedLists)

-- Fetches the tool prefix string.
local function getToolPrefixStr() return toolPrefixStr end

-- Fetches the edit mode key.
local function getEditModeKey() return editModeKey end

-- Returns the list of tree splines.
local function getTreeSplines() return treeSplines end

-- Returns the id -> index map.
local function getSplineMap() return splineMap end

-- Numeric distribution defaults for a fresh tree spline (no scenetree access, safe to read at module load).
local function getFoliageParamDefaults()
  local dist = scatter.getDefaultDistribution()
  return {
    class = dist.class,
    spacingM = dist.spacingM,
    posVariance = 0.25,      -- slot jitter as a fraction of spacing (0 = perfectly even row)
    scaleVariance = dist.scaleVariance,
    alignToNormal = dist.alignToNormal,
    slopeMaxDeg = 89.0,      -- rows follow the ground; default to accepting all slopes
    seed = dist.seed,
  }
end

-- Builds the default foliage distribution for a fresh tree spline (a single ticked species so it plants).
local function makeFoliageDefaults()
  local defs = getFoliageParamDefaults()
  local species = scatter.defaultSpeciesSelection() -- set { name = true }
  local weights = {}
  for nm, on in pairs(species) do if on then weights[nm] = 1.0 end end
  defs.species = species
  defs.speciesWeights = weights
  return defs
end

-- Adds a new (empty) tree spline; the user then clicks on the terrain to place its nodes.
local function addNewTreeSpline()
  local baseName = string.format(toolPrefixStr .. " %d", #treeSplines + 1)
  local uniqueName = util.generateUniqueName(baseName, toolPrefixStr)
  local id = Engine.generateUUID()

  local spline = {
    name = uniqueName,
    id = id,
    isDirty = false,
    isLoop = false,
    isEnabled = true,
    isConformToTerrain = true, -- Tree rows always drape onto the surface; kept for serialize/undo parity with the other spline tools.
    isLink = false,            -- true while linked as a Master Spline child (geometry is then master-driven).
    linkId = nil,              -- id of the owning Master Spline group when linked.
    gwSource = false,          -- true if created by the GroundWorks importer (re-import clears only its own rows)
    gwHedge = false,           -- gwSource row that came from a hedge barrier (cleared by the barrier import, not veg)
    avoidInfrastructure = false, -- consult the shared occupancy mask during scatter (keep the row off roads/water/etc)
    nodes = {},
    widths = {},
    nmls = {},
    divPoints = {},
    divWidths = {},
    tangents = {},
    binormals = {},
    normals = {},
    discMap = {},
    roadLength = 0.0,
    items = {}, -- planted forest item handles (runtime only)
    count = 0,
  }
  local defs = makeFoliageDefaults()
  for k, v in pairs(defs) do spline[k] = v end
  treeSplines[#treeSplines + 1] = spline

  util.computeIdToIdxMap(treeSplines, splineMap)
  return #treeSplines
end

-- Removes the tree spline (and its planted instances) at the given index.
local function removeTreeSpline(idx)
  local spline = treeSplines[idx]
  if not spline then return end
  pop.tryRemove(spline)
  table.remove(treeSplines, idx)
  util.computeIdToIdxMap(treeSplines, splineMap)
end

-- Removes all tree splines and their planted instances.
local function removeAllTreeSplines(isIncludeDisabled)
  for i = #treeSplines, 1, -1 do
    if isIncludeDisabled or (treeSplines[i].isEnabled and not treeSplines[i].isLink) then
      pop.tryRemove(treeSplines[i])
      table.remove(treeSplines, i)
    end
  end
  util.computeIdToIdxMap(treeSplines, splineMap)
end

-- Deep copies a single tree spline (geometry + runtime handles stripped: they rebuild from nodes/params).
local function deepCopyTreeSpline(spline)
  local copy = buffer.decode(buffer.encode({
    name = spline.name, id = spline.id,
    isDirty = spline.isDirty, isLoop = spline.isLoop, isEnabled = spline.isEnabled,
    isConformToTerrain = spline.isConformToTerrain,
    isLink = spline.isLink, linkId = spline.linkId,
    gwSource = spline.gwSource, gwHedge = spline.gwHedge, avoidInfrastructure = spline.avoidInfrastructure,
    nodes = spline.nodes, widths = spline.widths, nmls = spline.nmls,
    roadLength = spline.roadLength,
    species = spline.species, speciesWeights = spline.speciesWeights, class = spline.class,
    spacingM = spline.spacingM, posVariance = spline.posVariance, scaleVariance = spline.scaleVariance,
    alignToNormal = spline.alignToNormal, slopeMaxDeg = spline.slopeMaxDeg, seed = spline.seed,
  }))
  copy.divPoints, copy.divWidths, copy.tangents = {}, {}, {}
  copy.binormals, copy.normals, copy.discMap = {}, {}, {}
  copy.items, copy.count = {}, 0
  return copy
end

-- Deep copies the whole tree spline list (for trans-spline undo/redo).
local function deepCopyTreeSplineState()
  local copy = {}
  for i = 1, #treeSplines do copy[i] = deepCopyTreeSpline(treeSplines[i]) end
  return copy
end

-- Copies the split source's foliage params + conform onto a freshly-added half spline.
local function fillSplitHalf(dst, src, nodes, widths, nmls, suffix)
  dst.name = src.name .. suffix
  dst.isConformToTerrain = src.isConformToTerrain
  dst.isLoop = false
  for i = 1, #foliageFields do dst[foliageFields[i]] = deepcopy(src[foliageFields[i]]) end
  dst.nodes, dst.widths, dst.nmls = nodes, widths, nmls
  dst.isDirty = true
end

-- Splits the selected tree spline into two at the selected node (open splines), or unwraps a loop in place.
-- Both halves inherit the source's foliage params + conform setting. Returns the new selected index.
local function splitTreeSpline(selIdx, nodeIdx)
  local spline = treeSplines[selIdx]
  if not spline then return selIdx end

  if spline.isLoop then
    spline.nodes, spline.widths, spline.nmls = geom.splitLoopSplineGeometry(spline.nodes, spline.widths, spline.nmls, nodeIdx)
    spline.isLoop = false
    spline.isDirty = true
    return selIdx
  end

  local copy = deepCopyTreeSpline(spline)
  local nodes1, widths1, nmls1, nodes2, widths2, nmls2 = geom.splitSplineGeometry(copy.nodes, copy.widths, copy.nmls, nodeIdx)
  removeTreeSpline(selIdx)

  local iA = addNewTreeSpline()
  fillSplitHalf(treeSplines[iA], copy, nodes1, widths1, nmls1, '_split_A')
  local iB = addNewTreeSpline()
  fillSplitHalf(treeSplines[iB], copy, nodes2, widths2, nmls2, '_split_B')
  return #treeSplines
end

-- Replaces a single tree spline record (used by the object-select undo path in splineInput).
local function setTreeSpline(spline, idx)
  if not idx or not treeSplines[idx] then return end
  pop.tryRemove(treeSplines[idx])
  spline.divPoints, spline.divWidths, spline.tangents = {}, {}, {}
  spline.binormals, spline.normals, spline.discMap = {}, {}, {}
  spline.items, spline.count = {}, 0
  spline.isDirty = true
  treeSplines[idx] = spline
  util.computeIdToIdxMap(treeSplines, splineMap)
end

-- Replaces the whole tree spline list (used by trans-spline undo/redo).
local function setTreeSplines(splines)
  treeSplines = splines or {}
  util.computeIdToIdxMap(treeSplines, splineMap)
end

-- Applies the given data snapshot onto the live spline of the same id (node/param edit undo/redo core).
local function singleSplineEditUndoRedoCore(data)
  local idx = splineMap[data.id]
  if not idx then return end
  local spline = treeSplines[idx]

  if #data.nodes < 2 then pop.tryRemove(spline) end

  spline.name = data.name
  spline.isLoop = data.isLoop
  spline.isEnabled = data.isEnabled
  spline.isConformToTerrain = data.isConformToTerrain
  spline.isLink = data.isLink
  spline.linkId = data.linkId
  spline.nodes = data.nodes
  spline.widths = data.widths
  spline.nmls = data.nmls
  spline.roadLength = data.roadLength
  for i = 1, #foliageFields do spline[foliageFields[i]] = data[foliageFields[i]] end
  spline.isDirty = true
end

-- Undo/redo for a single tree spline edit.
local function singleSplineEditUndo(splineData) if splineData.old then singleSplineEditUndoRedoCore(splineData.old) end end
local function singleSplineEditRedo(splineData) if splineData.new then singleSplineEditUndoRedoCore(splineData.new) end end

-- Undo/redo for trans-spline edits (add / remove / reorder across the whole list).
local function transSplineEditUndo(data)
  removeAllTreeSplines(true)
  setTreeSplines(data.old)
  for i = 1, #treeSplines do treeSplines[i].isDirty = true end
end
local function transSplineEditRedo(data)
  removeAllTreeSplines(true)
  setTreeSplines(data.new)
  for i = 1, #treeSplines do treeSplines[i].isDirty = true end
end

-- Profile copy/paste (foliage params only; splineInput needs these callbacks). Geometry is left untouched.
local function copyTreeSplineProfile(spline)
  local profile = {}
  for i = 1, #foliageFields do profile[foliageFields[i]] = spline[foliageFields[i]] end
  return deepcopy(profile)
end

local function pasteTreeSplineProfile(spline, profile)
  if not profile then return end
  for i = 1, #foliageFields do
    if profile[foliageFields[i]] ~= nil then spline[foliageFields[i]] = deepcopy(profile[foliageFields[i]]) end
  end
  spline.isDirty = true
end

-- Serialize / deserialize (session hot-reload persistence via the tool's onSerialize/onDeserialized).
local function serializeTreeSpline(spline)
  return buffer.encode({
    name = spline.name, id = spline.id,
    isLoop = spline.isLoop, isEnabled = spline.isEnabled, isConformToTerrain = spline.isConformToTerrain,
    isLink = spline.isLink, linkId = spline.linkId,
    gwSource = spline.gwSource, gwHedge = spline.gwHedge, avoidInfrastructure = spline.avoidInfrastructure,
    nodes = spline.nodes, widths = spline.widths, nmls = spline.nmls, roadLength = spline.roadLength,
    species = spline.species, speciesWeights = spline.speciesWeights, class = spline.class,
    spacingM = spline.spacingM, posVariance = spline.posVariance, scaleVariance = spline.scaleVariance,
    alignToNormal = spline.alignToNormal, slopeMaxDeg = spline.slopeMaxDeg, seed = spline.seed,
    keptObjects = spline.keptObjects, -- Lua reload only: a locked spline's trees, left in the forest (see treeSpline onSerialize).
  })
end

-- Portable plain table for a session file (see toolUtilities/session). serializeTreeSpline already whitelists just the primary
-- fields (no derived geometry / runtime handles), so decode its blob to a plain table; jsonWriteFile flattens the vec3 nodes.
local function serializeTreeSplineToTable(spline)
  return buffer.decode(serializeTreeSpline(spline))
end

-- `data` is either the editor's buffer-encoded blob (string) or a plain table straight from a JSON session file. Either way the
-- derived scratch/scatter tables are (re)initialised; on the JSON path node positions arrive as plain {x,y,z} so rehydrate them.
local function deserializeTreeSpline(data)
  local spline = type(data) == 'table' and data or buffer.decode(data)
  spline.divPoints, spline.divWidths, spline.tangents = {}, {}, {}
  spline.binormals, spline.normals, spline.discMap = {}, {}, {}
  spline.items, spline.count = {}, 0
  spline.isDirty = true
  spline.nodes = spline.nodes or {}
  spline.nmls = spline.nmls or {}
  session.rehydrateVec3Array(spline.nodes)
  session.rehydrateVec3Array(spline.nmls)
  if spline.keptObjects then
    pop.adopt(spline, spline.keptObjects)
    spline.keptObjects = nil
  end
  return spline
end

-- Recompute the spline id -> index map (called by the shared session helper after a load appends the loaded splines).
local function recomputeIdMap() util.computeIdToIdxMap(treeSplines, splineMap) end

-- Full-state snapshot as plain data (all splines) for onSerialize.
local function getState()
  local out = {}
  for i = 1, #treeSplines do out[i] = serializeTreeSpline(treeSplines[i]) end
  return out
end

-- Restores the whole tree spline list from a plain snapshot (flags all dirty so they re-scatter).
local function setState(state)
  removeAllTreeSplines(true)
  if not state then return end
  for i = 1, #state do treeSplines[i] = deserializeTreeSpline(state[i]) end
  util.computeIdToIdxMap(treeSplines, splineMap)
end

-- Rebuilds geometry and re-plants any dirty tree splines. Safe to call every frame.
local function updateDirtyTreeSplines()
  local rebuiltAny = false -- did any spline actually rebuild this pass? (-> the document has an unsaved edit).
  for i = 1, #treeSplines do
    local spline = treeSplines[i]
    if spline.isDirty then
      rebuiltAny = true
      local nodes = spline.nodes
      if #nodes < 2 then
        pop.tryRemove(spline)
        table.clear(spline.divPoints)
        table.clear(spline.divWidths)
        table.clear(spline.tangents)
        table.clear(spline.binormals)
        table.clear(spline.normals)
        table.clear(spline.discMap)
        spline.roadLength = 0.0
        spline.count = 0
      else
        -- Tree rows always drape onto the surface below (2D on terrain, like roadSpline) -- also when linked to a Master Spline.
        for j = 1, #nodes do util.vertRaycast(nodes[j]) end
        geom.catmullRomRaycast(spline, minSplineDivisions)
        -- A locked spline whose trees are planted is not re-planted: the tool does not move them.
        if spline.isEnabled or #(spline.items or {}) == 0 then pop.populateTreeSpline(spline) end
        spline.roadLength = util.getPolyLength(nodes)
      end
      spline.isDirty = false
    end
  end
  if rebuiltAny then session.markEdited('treeSpline') end -- fold this pass's edits into the Save/Save As dirty state (load guard swallows a fresh load's rebuild).
end

-- Returns the current list of tree splines (for Master Spline linking; each entry carries the type prefix).
local function getCurrentTreeSplineList()
  local list, ctr = {}, 1
  for i = 1, #treeSplines do
    local spline = treeSplines[i]
    if spline.isEnabled then
      list[ctr] = { name = spline.name, id = spline.id, type = toolPrefixStr }
      ctr = ctr + 1
    end
  end
  return list
end

-- Returns true if the given tree spline is linked, false otherwise.
local function isLinked(id)
  local spline = treeSplines[splineMap[id]]
  return spline and spline.isLink or false
end

-- Sets the given tree spline to be linked (or not) to a Master Spline group.
local function setLink(id, groupId, isLink)
  local spline = treeSplines[splineMap[id]]
  if spline then
    spline.isLink = isLink
    spline.linkId = isLink and groupId or nil
    pop.tryRemove(spline)
    spline.isDirty = true
  end
end

-- Updates the given linked tree spline with the geometry pushed from the Master Spline. Tree rows always drape onto the surface
-- (2D on terrain, like roadSpline), so the master's conform flag is intentionally ignored.
local function updateLinkedTreeSpline(id, points, widths, nmls, isLoop, isConformToTerrain)
  local spline = treeSplines[splineMap[id]]
  if spline then
    spline.nodes, spline.widths, spline.nmls = points, widths, nmls
    spline.isLoop = isLoop
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

-- Removes a linked tree spline by id (called from Master Spline layer removal).
local function removeLinkedTreeSpline(splineId)
  local idx = splineMap[splineId]
  if idx then
    removeTreeSpline(idx)
  end
end

-- Unlinks all tree splines.
local function unlinkAll()
  for i = 1, #treeSplines do
    local spline = treeSplines[i]
    if spline.isLink then
      spline.isLink = false
      spline.linkId = nil
    end
    spline.isDirty = true
  end
end


-- Public interface.
M.getToolPrefixStr = getToolPrefixStr
M.getEditModeKey = getEditModeKey
M.getTreeSplines = getTreeSplines
M.getSplineMap = getSplineMap
M.getFoliageParamDefaults = getFoliageParamDefaults
M.makeFoliageDefaults = makeFoliageDefaults
M.addNewTreeSpline = addNewTreeSpline
M.removeTreeSpline = removeTreeSpline
M.removeAllTreeSplines = removeAllTreeSplines
M.deepCopyTreeSpline = deepCopyTreeSpline
M.deepCopyTreeSplineState = deepCopyTreeSplineState
M.splitTreeSpline = splitTreeSpline
M.setTreeSpline = setTreeSpline
M.setTreeSplines = setTreeSplines
M.singleSplineEditUndo = singleSplineEditUndo
M.singleSplineEditRedo = singleSplineEditRedo
M.transSplineEditUndo = transSplineEditUndo
M.transSplineEditRedo = transSplineEditRedo
M.copyTreeSplineProfile = copyTreeSplineProfile
M.pasteTreeSplineProfile = pasteTreeSplineProfile
M.serializeTreeSpline = serializeTreeSpline
M.deserializeTreeSpline = deserializeTreeSpline
M.serializeTreeSplineToTable = serializeTreeSplineToTable
M.recomputeIdMap = recomputeIdMap
M.getState = getState
M.setState = setState
M.updateDirtyTreeSplines = updateDirtyTreeSplines

M.getCurrentTreeSplineList = getCurrentTreeSplineList
M.isLinked = isLinked
M.setLink = setLink
M.updateLinkedTreeSpline = updateLinkedTreeSpline
M.removeLinkedTreeSpline = removeLinkedTreeSpline
M.unlinkAll = unlinkAll

return M