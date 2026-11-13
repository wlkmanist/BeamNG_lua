-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local objectHistoryActions = require("editor/api/objectHistoryActions")()

local dragState = nil
local finishedThisFrame = false
local completionThisFrame = nil
local currentOptions = {}

local function copyMatrix(matrix)
  return matrix * MatrixF(true)
end

local function transformsDiffer(first, second)
  for column = 0, 3 do
    if (vec3(first:getColumn(column)) - vec3(second:getColumn(column))):length() > 0.0001 then
      return true
    end
  end
  return false
end

local function scalesDiffer(first, second)
  return first and second and (vec3(first) - vec3(second)):length() > 0.0001
end

local function refreshEditorState()
  if editor.computeSelectionBBox then editor.computeSelectionBBox() end
  if editor.updateObjectSelectionAxisGizmo then editor.updateObjectSelectionAxisGizmo() end
end

local function refreshSelectionBounds()
  if editor.computeSelectionBBox then editor.computeSelectionBBox(false) end
end

local function updatePrefabOffset(obj, objectId)
  local prefabInstance = Engine.Prefab.findContainingPrefabInstance(obj)
  if not prefabInstance then return end
  prefabInstance = Sim.upcast(prefabInstance)
  if prefabInstance and prefabInstance.updateChildOffsetTransform then
    prefabInstance:updateChildOffsetTransform(objectId)
  end
end

local function setObjectTransformUndo(actionData)
  objectHistoryActions.setObjectTransformUndo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then updatePrefabOffset(obj, actionData.objectId) end
  extensions.hook("onEditorObjectSelectionTransformChanged")
end

local function setObjectTransformRedo(actionData)
  objectHistoryActions.setObjectTransformRedo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then updatePrefabOffset(obj, actionData.objectId) end
  extensions.hook("onEditorObjectSelectionTransformChanged")
end

local function setObjectScaleUndo(actionData)
  objectHistoryActions.setObjectScaleUndo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then updatePrefabOffset(obj, actionData.objectId) end
  extensions.hook("onEditorObjectSelectionTransformChanged")
end

local function setObjectScaleRedo(actionData)
  objectHistoryActions.setObjectScaleRedo(actionData)
  local obj = scenetree.findObjectById(actionData.objectId)
  if obj then updatePrefabOffset(obj, actionData.objectId) end
  extensions.hook("onEditorObjectSelectionTransformChanged")
end

local function objectSupportsMode(obj, mode)
  if not obj or not obj.getTransform or not editor.canManipulateObject(obj) then return false end
  if mode == editor.AxisGizmoMode_Translate and obj.getField and obj:getField("position", 0) == "" then
    return false
  end
  if mode == editor.AxisGizmoMode_Rotate and obj.getField and obj:getField("rotation", 0) == "" then
    return false
  end
  if mode == editor.AxisGizmoMode_Scale
    and (not obj.getScale or obj.getField and obj:getField("scale", 0) == "") then
    return false
  end
  return true
end

local function selectedObjectsSupportMode()
  local selectedIds = editor.selection.object
  if not selectedIds or tableIsEmpty(selectedIds) then return false end
  local mode = editor.getAxisGizmoMode()
  for _, objectId in ipairs(selectedIds) do
    if not objectSupportsMode(scenetree.findObjectById(objectId), mode) then return false end
  end
  return true
end

local function capturedSelectionMatches()
  if not dragState then return true end
  local selectedIds = editor.selection.object or {}
  if #selectedIds ~= #dragState.objects then return false end
  local selected = {}
  for _, id in ipairs(selectedIds) do selected[id] = true end
  for _, entry in ipairs(dragState.objects) do
    if not selected[entry.id] then return false end
    local obj = scenetree.findObjectById(entry.id)
    if not objectSupportsMode(obj, dragState.mode) then return false end
  end
  return true
end

local function restoreDragState()
  if not dragState then return end
  for _, entry in ipairs(dragState.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      obj:setTransform(copyMatrix(entry.transform))
      if entry.scale and obj.setScale then obj:setScale(vec3(entry.scale)) end
      updatePrefabOffset(obj, entry.id)
    end
  end
  dragState = nil
  refreshEditorState()
end

local function beginDrag()
  local objects = {}
  local transforms = {}
  for _, objectId in ipairs(editor.selection.object or {}) do
    local obj = scenetree.findObjectById(objectId)
    if not obj or not obj.getTransform or not editor.canManipulateObject(obj) then return end
    local transform = copyMatrix(obj:getTransform())
    objects[#objects + 1] = {
      id = objectId,
      transform = transform,
      scale = obj.getScale and vec3(obj:getScale()) or nil
    }
    transforms[#transforms + 1] = transform
  end
  if #objects == 0 then return end

  dragState = {
    objects = objects,
    initialTransforms = transforms,
    initialGizmoTransform = copyMatrix(editor.getAxisGizmoTransform()),
    mode = editor.getAxisGizmoMode(),
    options = {
      gridSnapEnabled = currentOptions.gridSnapEnabled,
      gridRelative = currentOptions.gridRelative,
      gridSize = currentOptions.gridSize
    },
    rawTranslation = vec3(0, 0, 0),
    appliedTranslation = vec3(0, 0, 0),
    moved = false
  }
end

local function drag()
  if not dragState then return end
  dragState.moved = true

  if dragState.mode == editor.AxisGizmoMode_Translate then
    dragState.rawTranslation = dragState.rawTranslation
      + vec3(worldEditorCppApi.getAxisGizmoTranslateOffset())
    local desiredTranslation = vec3(dragState.rawTranslation)
    local options = dragState.options
    if options.gridSnapEnabled and options.gridSize and options.gridSize > 0 then
      if options.gridRelative then
        desiredTranslation.x = round(desiredTranslation.x / options.gridSize) * options.gridSize
        desiredTranslation.y = round(desiredTranslation.y / options.gridSize) * options.gridSize
        desiredTranslation.z = round(desiredTranslation.z / options.gridSize) * options.gridSize
      else
        local desiredPivot = dragState.initialGizmoTransform:getColumn(3) + desiredTranslation
        if math.abs(desiredTranslation.x) > 0.000001 then
          desiredPivot.x = round(desiredPivot.x / options.gridSize) * options.gridSize
        end
        if math.abs(desiredTranslation.y) > 0.000001 then
          desiredPivot.y = round(desiredPivot.y / options.gridSize) * options.gridSize
        end
        if math.abs(desiredTranslation.z) > 0.000001 then
          desiredPivot.z = round(desiredPivot.z / options.gridSize) * options.gridSize
        end
        desiredTranslation = desiredPivot - dragState.initialGizmoTransform:getColumn(3)
      end
    end
    local delta = desiredTranslation - dragState.appliedTranslation
    dragState.appliedTranslation = desiredTranslation
    for _, entry in ipairs(dragState.objects) do
      local obj = scenetree.findObjectById(entry.id)
      if obj then
        local transform = copyMatrix(obj:getTransform())
        transform:setPosition(transform:getColumn(3) + delta)
        obj:setTransform(transform)
      end
    end
    local gizmoTransform = copyMatrix(dragState.initialGizmoTransform)
    gizmoTransform:setPosition(
      dragState.initialGizmoTransform:getColumn(3) + desiredTranslation)
    editor.setAxisGizmoTransform(gizmoTransform)
  elseif dragState.mode == editor.AxisGizmoMode_Rotate then
    editor.rotateObjectSelection(
      editor.getAxisGizmoTransform(),
      editor.getAxisGizmoTransform():getColumn(3),
      dragState.initialTransforms,
      dragState.initialGizmoTransform)
  elseif dragState.mode == editor.AxisGizmoMode_Scale then
    editor.scaleObjectSelection(
      vec3(worldEditorCppApi.getAxisGizmoScaleOffset()),
      editor.getAxisGizmoTransform():getColumn(3))
  end
  refreshSelectionBounds()
end

local function endDrag()
  if not dragState then return end
  local completed = dragState
  dragState = nil
  local changes = {}

  for _, entry in ipairs(completed.objects) do
    local obj = scenetree.findObjectById(entry.id)
    if obj then
      local transformChanged = transformsDiffer(obj:getTransform(), entry.transform)
      local newScale = obj.getScale and vec3(obj:getScale()) or nil
      changes[#changes + 1] = {
        entry = entry,
        obj = obj,
        transformChanged = transformChanged,
        newScale = newScale,
        scaleChanged = scalesDiffer(newScale, entry.scale)
      }
    end
  end

  local hasChanges = false
  for _, change in ipairs(changes) do
    if change.transformChanged or change.scaleChanged then
      hasChanges = true
      break
    end
  end
  if not hasChanges then
    refreshEditorState()
    finishedThisFrame = true
    return
  end

  local historyName = completed.mode == editor.AxisGizmoMode_Scale
    and "EasySelectNativeScale"
    or "EasySelectNativeTransform"
  if not editor.history:beginTransaction(historyName) then
    dragState = completed
    restoreDragState()
    finishedThisFrame = true
    return
  end

  for _, change in ipairs(changes) do
    local entry = change.entry
    if change.transformChanged then
      editor.history:commitAction(
        "SetObjectTransform",
        {
          objectId = entry.id,
          newTransform = editor.matrixToTable(change.obj:getTransform()),
          oldTransform = editor.matrixToTable(entry.transform)
        },
        setObjectTransformUndo,
        setObjectTransformRedo,
        true)
    end
    if change.scaleChanged then
      editor.history:commitAction(
        "SetObjectScale",
        {
          objectId = entry.id,
          newScale = change.newScale,
          oldScale = vec3(entry.scale)
        },
        setObjectScaleUndo,
        setObjectScaleRedo,
        true)
    end
    updatePrefabOffset(change.obj, entry.id)
  end
  editor.history:endTransaction(true)
  editor.setDirty()
  refreshEditorState()
  extensions.hook("onEditorObjectSelectionTransformChanged")
  completionThisFrame = {
    mode = completed.mode,
    anchorDistance = completed.mode == editor.AxisGizmoMode_Translate
      and completed.appliedTranslation:length()
      or 0
  }
  finishedThisFrame = true
end

local function updateWithEzSnap(options)
  local traditionalGridSize = worldEditorCppApi.getGridSize()
  local traditionalRotateSize = worldEditorCppApi.getRotateSnapAngle()
  local altSnapEnabled = editor.keyModifiers.lAlt == true
  local traditionalGridEnabled = editor.getPreference("snapping.general.snapToGrid") == true
    or altSnapEnabled
  local traditionalRotateEnabled = editor.getPreference("snapping.general.rotateSnapEnabled") == true
    or altSnapEnabled

  currentOptions = options
  worldEditorCppApi.setGridSnap(false, options.gridSize or traditionalGridSize)
  worldEditorCppApi.setRotateSnap(
    options.rotateSnapEnabled == true,
    options.rotateSnapSize or traditionalRotateSize)
  local ok, updateError = pcall(editor.updateAxisGizmo, beginDrag, endDrag, drag)
  worldEditorCppApi.setGridSnap(traditionalGridEnabled, traditionalGridSize)
  worldEditorCppApi.setRotateSnap(traditionalRotateEnabled, traditionalRotateSize)
  currentOptions = {}
  if not ok then error(updateError) end
end

local function finishClickWithoutDrag()
  if dragState and not dragState.moved and not ui_imgui.IsMouseDown(0) then
    dragState = nil
    refreshEditorState()
    finishedThisFrame = true
  end
end

function M.draw(options)
  finishedThisFrame = false
  completionThisFrame = nil
  if not capturedSelectionMatches() then
    M.reset()
    finishedThisFrame = true
    return false
  end
  if not selectedObjectsSupportMode() then
    worldEditorCppApi.setAxisGizmoSelectedElement(-1)
    return false
  end
  options = options or {}
  updateWithEzSnap(options)
  finishClickWithoutDrag()
  editor.drawAxisGizmo()
  return true
end

function M.isInteracting()
  return dragState ~= nil
end

function M.consumeFinished()
  local finished = finishedThisFrame
  local completion = completionThisFrame
  finishedThisFrame = false
  completionThisFrame = nil
  return finished, completion
end

function M.reset()
  restoreDragState()
  finishedThisFrame = false
  completionThisFrame = nil
  if editor.cancelAxisGizmoInteraction then
    editor.cancelAxisGizmoInteraction()
  else
    worldEditorCppApi.setAxisGizmoSelectedElement(-1)
  end
end

return M
