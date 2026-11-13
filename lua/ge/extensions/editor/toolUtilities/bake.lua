-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared "Bake" helper for the custom spline editor tools. While a spline is owned by its tool, its generated scene
-- objects (TSStatic meshes / DecalRoads / river) are TRANSIENT (canSave=false) so they never save with the level -- the
-- tool rebuilds them from the spline on every dirty pass. Baking COMMITS one spline's generated objects to the level:
-- it flips them (and their SimGroup folder) to canSave=true, drops the spline from the tool WITHOUT deleting anything,
-- and from then on they are plain scene-tree objects that persist like any other. The spline is gone from the tool, so
-- there is nothing left to regenerate them.
--
-- Everything tool-SPECIFIC (where the pool lives, how to burn/detach it, the tool's state snapshot) stays in the tool
-- and is passed in through a small `spec` table, the same way `session.lua` works -- so each tool wires this in a few
-- lines. The whole operation is ONE undoable history transaction (no confirmation dialog: undo is the safety net).
--
-- spec fields:
--   toolId          (string)  unique id; used for the button id and undo text.
--   displayName     (string)  human label for the undo text, e.g. 'Mesh Spline'. Defaults to toolId.
--   iconColor       (imvec4)  (optional) button colour.
--   iconSize        (imvec2)  (optional) button size; defaults to 36x36.
--   bakeIcon                  (optional) icon override; defaults to a flame icon.
--   getBakeTarget   ()        -> the currently-selected, bakeable spline (enabled, not linked, >= 2 nodes) or nil. The
--                              button is only active when this returns a spline.
--   rebuildNow      (spline)  force a final dirty rebuild so the live pool exactly matches the spline before burning.
--   burn            (spline)  -> a flat name manifest of the burned objects, and optionally a list of the forest items it
--                              planted in their place. Flip the spline's generated objects (and folder) to canSave=true.
--                              Cliff reuses kitPlacer.commitSink; mesh/assembly/road/river iterate their own pool, set
--                              canSave=true and collect getName(); rail plants its pieces into the forest.
--   detach          (spline)  drop the spline's entries from the tool's LIVE pool WITHOUT deleting objects (e.g.
--                              staticMeshes[id]=nil), so the tool no longer owns/rebuilds/deletes them.
--   finalizeFolder  (spline)  -> the folder's object id. Set the spline's SimGroup folder canSave=true.
--   removeFromTool  (spline)  remove the spline from the tool's item list and recompute its id map. MUST NOT delete the
--                              generated objects or the folder (they were just burned).
--   captureState    ()        -> a full tool-list snapshot for undo (the tool's deepCopy-all).
--   restoreState    (snapshot) restore the tool list from a snapshot, mark items dirty and recompute the id map (this
--                              re-inserts the baked spline and regenerates its transient meshes).
--   findSpline      (id)      -> a live spline by id (used by redo to re-find the restored spline).
--
-- LOCK mode: a spec with `setLockedById` does not remove anything. Baking LOCKS the spline instead: it stays in its tool,
-- uneditable, and its generated objects save with the level and collide (see splineLock.lua). Unlocking hands the same
-- objects back to the tool. The remove-based fields above are then unused.
--   setLockedById   (id, isLocked) set the spline's isEnabled = not isLocked and rebuild it now.
--   eachObjectById  (id, fn)  (optional) the splineLock `each` for the spline with this id. When given, an unlock records its
--                              objects' hand edits first, and undoing the unlock puts them back (see splineLock.capture).

local M = {}

-- Module dependencies.
local kitPlacer = require('editor/toolUtilities/kitPlacer')
local scatter = require('editor/toolUtilities/foliageScatter')
local splineLock = require('editor/toolUtilities/splineLock')

-- Module constants.
local im = ui_imgui


-- Runs the tool-specific bake steps for `spline`, recording the burned-object manifest and folder id into `data` (so a
-- later undo can delete exactly those objects, and a later redo re-bakes the same spline).
local function doBake(spec, spline, data)
  spec.rebuildNow(spline)                     -- final rebuild so the pool matches the spline exactly.
  local names, items = spec.burn(spline)      -- flip generated objects to canSave=true, collect their names.
  data.manifest, data.items = names or {}, items
  spec.detach(spline)                         -- tool stops owning them (no delete).
  data.folderId = spec.finalizeFolder(spline) -- folder canSave=true so it saves with the level.
  spec.removeFromTool(spline)                 -- drop the spline from the tool (no object/folder deletion).
  -- A tool's live preview never collides.
  be:reloadCollision()
end

-- Take one bake back out of the level: delete the burned objects and planted items, and reset their folder to transient.
-- `data` is what doBake (or burnById) recorded.
local function unburn(data)
  if kitPlacer.removeBurned(data.manifest) > 0 then be:reloadCollision() end -- their hulls go with them
  if data.items and #data.items > 0 then
    local forest = core_forest and core_forest.getForestObject()
    scatter.removeItems(forest and forest:getData(), data.items)
    if editor then editor.forestDirty = true end
    be:reloadCollision()
  end
  if data.folderId then
    local folder = scenetree.findObjectById(data.folderId)
    if folder then folder.cansave = false end -- the tool will repopulate this folder with transient meshes.
  end
end

-- Undo: take the bake back out, then restore the whole tool state so the spline comes back and the tool regenerates its
-- transient meshes.
local function undo(data)
  unburn(data)
  data.spec.restoreState(data.old)
end

-- Redo: the spline is back in the tool (from the undo). Re-run the bake on it, refreshing the manifest/folder id.
local function redo(data)
  local spec = data.spec
  local spline = spec.findSpline(data.splineId)
  if spline then doBake(spec, spline, data) end
end

-- An unlock records the objects' hand edits into `data` before resetting them; a lock puts back the last record (the unlock it
-- undoes). The record is retaken on every unlock, so undo/redo always restores the state that unlock found.
local function applyLock(spec, data, isLocked)
  local id, each = data.splineId, nil
  if spec.eachObjectById then each = function(fn) spec.eachObjectById(id, fn) end end
  if each and not isLocked then data.record = splineLock.capture(each) end
  spec.setLockedById(id, isLocked)
  if each and isLocked and data.record then splineLock.restore(data.record, each) end
  if editor.setDirty then editor.setDirty() end -- what saves with the level just changed.
end
local function lockUndo(data) applyLock(data.spec, data, not data.isLocked) end
local function lockRedo(data) applyLock(data.spec, data, data.isLocked) end

-- Locks/unlocks `spline` as one undoable history transaction. Used by both the flame button and the tool's lock toggle.
local function setLocked(spec, spline, isLocked)
  local data = { spec = spec, splineId = spline.id, isLocked = isLocked }
  lockRedo(data)
  editor.history:commitAction((isLocked and "Lock " or "Unlock ") .. (spec.displayName or spec.toolId), data, lockUndo, lockRedo, true)
end

-- Draws the flame button for `spline`; a click runs the whole bake as one undoable history transaction (no dialog). btnId
-- defaults to the tool's top-row id; the per-row variant passes a per-spline id. Returns true when a bake ran.
local function drawBakeButton(spec, spline, size, btnId)
  local icon = spec.bakeIcon or editor.icons.local_fire_department or editor.icons.whatshot
  local clicked = editor.uiIconImageButton(icon, size, spec.iconColor, nil, nil, btnId or (spec.toolId .. '_bakeBtn'))
  if spec.setLockedById then
    im.tooltip('Bake: lock this spline. Its generated objects save with the level and collide; it stays in the tool and can be unlocked again. Undoable.')
    if clicked then setLocked(spec, spline, true) end
    return false -- nothing was removed from the tool's list.
  end
  im.tooltip('Bake: commit this spline\'s generated objects to the scene as permanent, saveable objects and remove the spline from the tool. Undoable.')
  if clicked then
    local data = { spec = spec, splineId = spline.id, old = spec.captureState() }
    doBake(spec, spline, data)
    editor.history:commitAction("Bake " .. (spec.displayName or spec.toolId), data, undo, redo, true)
  end
  return clicked
end

-- Column variant: draws the Bake button as ONE column cell (call after the tool's other top-row column cells; the caller
-- must widen its im.Columns count by 1). When there is no bakeable spline selected the cell is a blank Dummy, matching
-- how these tools blank other unavailable buttons.
local function renderButton(spec)
  local size = spec.iconSize or im.ImVec2(36, 36)
  local spline = spec.getBakeTarget and spec.getBakeTarget() or nil
  if spline then drawBakeButton(spec, spline, size) else im.Dummy(size) end
  im.NextColumn()
end

-- Inline variant: draws the Bake button (or a blank Dummy) with NO column handling, for tools whose top row is a plain
-- im.SameLine sequence. The caller adds its own im.SameLine() beforehand to keep it on the same row.
local function renderButtonInline(spec)
  local size = spec.iconSize or im.ImVec2(36, 36)
  local spline = spec.getBakeTarget and spec.getBakeTarget() or nil
  if spline then drawBakeButton(spec, spline, size) else im.Dummy(size) end
end

-- Is THIS spline bakeable? Defaults to the shared rule (enabled, not linked, >= 2 nodes); a spec may override with canBake.
local function canBake(spec, spline)
  if spec.canBake then return spec.canBake(spline) end
  return spline and spline.isEnabled and not spline.isLink and spline.nodes and #spline.nodes >= 2 and true or false
end

-- Master-Spline propagation: bake the spline with `id` (typically a LINKED child) WITHOUT opening its own history
-- transaction -- the Master Spline wraps the whole multi-tool burn in one action. Returns { manifest, folderId } so the
-- Master's undo can delete exactly these objects and reset the folder. Returns nil when the id isn't found.
local function burnById(spec, id)
  local spline = spec.findSpline and spec.findSpline(id)
  if not spline then return nil end
  local data = {}
  doBake(spec, spline, data)
  return { manifest = data.manifest, items = data.items, folderId = data.folderId }
end

-- Row variant: draws the Bake button for ONE list row's spline (small icon, spec's red colour), or a blank Dummy when that
-- spline isn't bakeable. A click bakes it immediately and returns true -- the caller MUST then editor.endWindow() + return,
-- exactly like its delete button does, because the bake mutated the tool's item list mid-iteration. Draw this as its own
-- column cell (widen the row's im.Columns count by 1) and follow it with im.NextColumn() like the other row buttons.
local function rowButton(spec, spline)
  local size = spec.rowIconSize or im.ImVec2(24, 24)
  if canBake(spec, spline) then
    return drawBakeButton(spec, spline, size, spec.toolId .. '_bakeRow' .. tostring(spline.id))
  end
  im.Dummy(size)
  return false
end


-- Public interface.
M.renderButton = renderButton
M.renderButtonInline = renderButtonInline
M.rowButton = rowButton
M.burnById = burnById
M.unburn = unburn
M.setLocked = setLocked

return M