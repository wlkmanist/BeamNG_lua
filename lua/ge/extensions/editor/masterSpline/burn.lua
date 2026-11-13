-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Master Spline lock. A Master Spline owns a stack of linked child splines (mesh / assembly / road / tree / decal). Locking
-- (the Burn button, or the lock toggle) locks the master and every linked child: they stay in their tools, uneditable, and
-- their generated content saves with the level (see toolUtilities/splineLock.lua). Unlocking hands it all back.
local M = {}

-- Module dependencies.
local sm = require('editor/masterSpline/splineMgr')
local jumps = require('editor/masterSpline/jumpTables')
local splineLock = require('editor/toolUtilities/splineLock')

-- Module constants.
local setLockedJumpTable = jumps.setLockedJumpTable
local eachObjectJumpTable = jumps.eachObjectJumpTable


-- Lock/unlock the master with this id and all its linked children. As with a single spline (see bake.lua), an unlock records
-- each child's hand edits into `data.records`, and a lock puts back the last record (the unlock it undoes).
local function setLockedById(masterId, isLocked, data)
  local spline = sm.getMasterSplines()[sm.getIdToIdxMap()[masterId]]
  if not spline then return end
  spline.isEnabled = not isLocked
  if not isLocked then data.records = {} end
  local layers = spline.layers
  for i = 1, #layers do
    local layer = layers[i]
    local id = layer.linkedSplineId
    local fn = id and layer.linkType and setLockedJumpTable[layer.linkType]
    if fn then
      local eachFn = eachObjectJumpTable[layer.linkType]
      local each = eachFn and function(f) eachFn(id, f) end
      if each and not isLocked then data.records[id] = splineLock.capture(each) end
      fn(id, isLocked)
      if each and isLocked and data.records and data.records[id] then splineLock.restore(data.records[id], each) end
    end
  end
  if editor.setDirty then editor.setDirty() end -- what saves with the level just changed.
end

local function doUndo(data) setLockedById(data.masterSplineId, not data.isLocked, data) end
local function doRedo(data) setLockedById(data.masterSplineId, data.isLocked, data) end

-- Lock/unlock the master at list index `idx` as one undoable transaction.
local function setLocked(idx, isLocked)
  local spline = sm.getMasterSplines()[idx]
  if not spline then return end
  local data = { masterSplineId = spline.id, isLocked = isLocked }
  doRedo(data)
  editor.history:commitAction(isLocked and "Lock Master Spline" or "Unlock Master Spline", data, doUndo, doRedo, true)
end

-- Burn = lock.
local function run(idx) setLocked(idx, true) end


-- Public interface.
M.run = run
M.setLocked = setLocked

return M
