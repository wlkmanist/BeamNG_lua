-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local ezObjectSelect = require("editor/ezObjectSelect/controller")
local toolWindowName = "ezObjectSelect"
local editModeKey = "ezObjectSelect"
local modeName = "Easy Select"
local editMode = nil
local activationFailed = false

local function isActiveMode()
  return editMode and editor.editMode == editMode
end

local function callObjectSelect(callbackName, ...)
  local objectSelect = editor.editModes and editor.editModes.objectSelect or nil
  local callback = objectSelect and objectSelect[callbackName] or nil
  if callback then return callback(...) end
end

local function activate()
  activationFailed = not ezObjectSelect.activate()
  if activationFailed then return end
  editor.showWindow(toolWindowName)
end

local function deactivate()
  activationFailed = false
  ezObjectSelect.deactivate()
  editor.hideWindow(toolWindowName)
end

local function update()
  if activationFailed then
    activationFailed = false
    editor.selectEditMode(editor.editModes.objectSelect or nil)
    return false
  end
  return ezObjectSelect.update() == true
end

local function registerEditMode()
  editMode = {
    displayName = modeName,
    icon = editor.icons.goat,
    iconTooltip = modeName,
    actionMap = "EZObjectSelect",
    hideObjectIcons = true,
    onActivate = activate,
    onDeactivate = deactivate,
    onUpdate = update,
    onCut = function() return callObjectSelect("onCut") end,
    onCopy = function() return callObjectSelect("onCopy") end,
    onPaste = function() return callObjectSelect("onPaste") end,
    onDuplicate = function() return callObjectSelect("onDuplicate") end,
    onSelectAll = function() return callObjectSelect("onSelectAll") end,
    onDeselect = function() return callObjectSelect("onDeselect") end,
    onDeleteSelection = function() return callObjectSelect("onDeleteSelection") end,
    auxShortcuts = {}
  }
  editMode.auxShortcuts[
    bit.bor(editor.AuxControl_Ctrl, editor.AuxControl_MWheel)
  ] = "Cycle overlapping objects"
  editMode.auxShortcuts[
    bit.bor(editor.AuxControl_Shift, editor.AuxControl_MWheel)
  ] = "Rotate selection around world Z"
  editMode.auxShortcuts[
    bit.bor(editor.AuxControl_Ctrl, editor.AuxControl_Shift, editor.AuxControl_MWheel)
  ] = "Rotate selection around world Z in 1 degree increments"
  editor.editModes[editModeKey] = editMode
end

local function onEditorInitialized()
  if ezObjectSelect.loadPreferences then ezObjectSelect.loadPreferences() end
  if ezObjectSelect.resetInputFilters then ezObjectSelect.resetInputFilters() end
  editor.registerWindow(
    toolWindowName,
    im.ImVec2(390 * im.uiscale[0], 460 * im.uiscale[0]))
  registerEditMode()
end

local function onEditorGui()
  if not isActiveMode() then return end
  ezObjectSelect.drawScreenDebug()
  if editor.beginWindow(toolWindowName, modeName) then
    ezObjectSelect.drawWorkspace()
  end
  editor.endWindow()
end

local function onExtensionUnloaded()
  if editor and isActiveMode() then
    editor.selectEditMode(editor.editModes.objectSelect or nil)
  else
    ezObjectSelect.deactivate()
  end
  if ezObjectSelect.resetInputFilters then ezObjectSelect.resetInputFilters() end
  if editor and editor.unregisterWindow then editor.unregisterWindow(toolWindowName) end
  if editor and editor.editModes then editor.editModes[editModeKey] = nil end
  editMode = nil
end

local function invalidateSelectionCache(reason)
  if ezObjectSelect.isActive() then ezObjectSelect.invalidateSelectionCache(reason) end
end

function M.onExtensionLoaded()
  if ezObjectSelect.loadPreferences then ezObjectSelect.loadPreferences() end
  if ezObjectSelect.resetInputFilters then ezObjectSelect.resetInputFilters() end
end

function M.requestTransformShortcut()
  if isActiveMode() then ezObjectSelect.requestTransformShortcut() end
end

function M.requestRotateShortcut()
  if isActiveMode() then ezObjectSelect.requestRotateShortcut() end
end

function M.requestScaleShortcut()
  if isActiveMode() then ezObjectSelect.requestScaleShortcut() end
end

function M.requestFocusShortcut()
  if isActiveMode() then ezObjectSelect.requestFocusShortcut() end
end

function M.requestNumpadPreset(preset)
  if isActiveMode() then ezObjectSelect.requestNumpadPreset(preset) end
end

function M.onEditorObjectAdded()
  invalidateSelectionCache("objectAdded")
end

function M.onEditorPrefabExploded()
  invalidateSelectionCache("prefabExploded")
end

function M.onEditorInspectorFieldChanged()
  invalidateSelectionCache("inspectorFieldChanged")
end

function M.onEditorInspectorDynFieldChanged()
  invalidateSelectionCache("inspectorDynFieldChanged")
end

function M.onEditorPreferenceValueChanged(path, value)
  if path == "gizmos.general.highlightSelectedMeshes" and isActiveMode() then
    ezObjectSelect.refreshSelectedTint()
  elseif ezObjectSelect.onEditorPreferenceValueChanged then
    ezObjectSelect.onEditorPreferenceValueChanged(path, value)
  end
end

function M.onEditorAxisGizmoModeChanged(mode)
  if isActiveMode() then ezObjectSelect.onAxisGizmoModeChanged(mode) end
end

function M.onEditorAxisGizmoAligmentChanged()
  if isActiveMode() then ezObjectSelect.onAxisGizmoAlignmentChanged() end
end

local function onEditorRegisterPreferences(prefsRegistry)
  if ezObjectSelect.onEditorRegisterPreferences then
    ezObjectSelect.onEditorRegisterPreferences(prefsRegistry)
  end
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui
M.onEditorRegisterPreferences = onEditorRegisterPreferences
M.onExtensionUnloaded = onExtensionUnloaded

return M
