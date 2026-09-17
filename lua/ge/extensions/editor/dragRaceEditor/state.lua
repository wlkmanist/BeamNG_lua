-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local constants = require('/lua/ge/extensions/editor/dragRaceEditor/constants')
local im = ui_imgui

local M = {}

local State = {
  dragRaceData = nil,
  currentFileDir = constants.CONSTANTS.DEFAULT_FILE_DIR,
  currentFileName = nil,

  selectedLaneIndex = -1,
  selectedFacilityIndex = -1,
  selectedStripIndex = -1,
  mouseInfo = nil,
  hasUnsavedChanges = false,

  transforms = {},
  endCameraTransform = nil,

  zoneEditTarget = nil,
  zoneEditPreviousEditMode = nil,

  usingPrefabs = im.BoolPtr(false),
  hasEndCamera = im.BoolPtr(false),

  search = require('/lua/ge/extensions/editor/util/searchUtil')(),

  undoStack = {},
  redoStack = {},
  maxUndoSteps = 20,

  lastError = nil,
  errorTimeout = 0
}

M.getState = function()
  return State
end

M.setState = function(newState)
  State = newState
end

M.getDragRaceData = function()
  return State.dragRaceData
end

M.setDragRaceData = function(data)
  State.dragRaceData = data
end

M.getSelectedLaneIndex = function()
  return State.selectedLaneIndex
end

M.setSelectedLaneIndex = function(index)
  State.selectedLaneIndex = index
end

M.getSelectedFacilityIndex = function()
  return State.selectedFacilityIndex
end

M.setSelectedFacilityIndex = function(index)
  State.selectedFacilityIndex = index
end

M.getSelectedStripIndex = function()
  return State.selectedStripIndex
end

M.setSelectedStripIndex = function(index)
  State.selectedStripIndex = index
end

M.getMouseInfo = function()
  return State.mouseInfo
end

M.setMouseInfo = function(info)
  State.mouseInfo = info
end

M.getHasUnsavedChanges = function()
  return State.hasUnsavedChanges
end

M.setHasUnsavedChanges = function(value)
  State.hasUnsavedChanges = value
end

M.getTransforms = function()
  return State.transforms
end

M.setTransforms = function(transforms)
  State.transforms = transforms
end

M.getCurrentFileDir = function()
  return State.currentFileDir
end

M.setCurrentFileDir = function(dir)
  State.currentFileDir = dir
end

M.getCurrentFileName = function()
  return State.currentFileName
end

M.setCurrentFileName = function(name)
  State.currentFileName = name
end

M.getUndoStack = function()
  return State.undoStack
end

M.setUndoStack = function(stack)
  State.undoStack = stack
end

M.getRedoStack = function()
  return State.redoStack
end

M.setRedoStack = function(stack)
  State.redoStack = stack
end

M.getMaxUndoSteps = function()
  return State.maxUndoSteps
end

M.getLastError = function()
  return State.lastError
end

M.setLastError = function(error)
  State.lastError = error
end

M.getErrorTimeout = function()
  return State.errorTimeout
end

M.setErrorTimeout = function(timeout)
  State.errorTimeout = timeout
end

M.getUsingPrefabs = function()
  return State.usingPrefabs
end

M.getHasEndCamera = function()
  return State.hasEndCamera
end

M.getSearch = function()
  return State.search
end

M.getZoneEditTarget = function()
  return State.zoneEditTarget
end

M.setZoneEditTarget = function(target)
  State.zoneEditTarget = target
end

M.getZoneEditPreviousEditMode = function()
  return State.zoneEditPreviousEditMode
end

M.setZoneEditPreviousEditMode = function(mode)
  State.zoneEditPreviousEditMode = mode
end

return M
