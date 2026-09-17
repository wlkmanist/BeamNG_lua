-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_object_tool'
local imgui = ui_imgui
local objectHistoryActions = require("editor/api/objectHistoryActions")()
local copyObjectsArray = {}

local raycastMode = false
local clickedHoveredObject = false
local doingRectSelection = false
local mouseDown = false

local mouseDragStartPos = nil
local objectsInRect = {}
local duplicationDrag

local bboxColor = ColorF(0.9, 0.5, 0, 1)
local bboxColorLocked = ColorF(0.9, 0, 0, 1)

local cubePoints =
{
  vec3(-0.5, -0.5, -0.5),
  vec3(-0.5, -0.5, 0.5),
  vec3(-0.5, 0.5, -0.5),
  vec3(-0.5, 0.5, 0.5),
  vec3(0.5, -0.5, -0.5),
  vec3(0.5, -0.5, 0.5),
  vec3(0.5, 0.5, -0.5),
  vec3(0.5, 0.5, 0.5)
}

local axisGizmoEventState = {
  mouseDown = false,
  objectSelectionManipulated = false,
  dragAndDuplicate = false,
  oldTransforms = {},
  oldScales = {},
  objectHeights = {},
  objects = {}
}

--TODO: this could be done in C++
local function drawSelectionBBox(objMat, color)
  local pts = {}
  -- 8 corner points of the box
  for i = 1, 8 do
    pts[i] = objMat:mulP3F(vec3(cubePoints[i].x, cubePoints[i].y, cubePoints[i].z))
  end

  local thickness = 4 * editor.getPreference("gizmos.general.lineThicknessScale")

  debugDrawer:drawLineInstance(pts[1], pts[5], thickness, color)
  debugDrawer:drawLineInstance(pts[2], pts[6], thickness, color)
  debugDrawer:drawLineInstance(pts[3], pts[7], thickness, color)
  debugDrawer:drawLineInstance(pts[4], pts[8], thickness, color)

  debugDrawer:drawLineInstance(pts[1], pts[2], thickness, color)
  debugDrawer:drawLineInstance(pts[3], pts[4], thickness, color)
  debugDrawer:drawLineInstance(pts[1], pts[3], thickness, color)
  debugDrawer:drawLineInstance(pts[2], pts[4], thickness, color)

  debugDrawer:drawLineInstance(pts[7], pts[8], thickness, color)
  debugDrawer:drawLineInstance(pts[5], pts[6], thickness, color)
  debugDrawer:drawLineInstance(pts[5], pts[7], thickness, color)
  debugDrawer:drawLineInstance(pts[6], pts[8], thickness, color)
end

local function drawSelectedObjectBBox(obj, color)
  -- if this SimObject is not a visual sceneobject with a transform, then ignore it
  if not obj["getTransform"] then return end

  --TODO: take this special case out of here
  if obj:isSubClassOf("BeamNGVehicle") then
    -- The vehicles are special, display the position and the rotation of the reference nodes instead
    local veh = Sim.upcast(obj)
    local pos = veh:getPosition()
    local rot = quat(veh:getRefNodeRotation())
    local scl = 1
    if not editor.getPreference("gizmos.general.fixedRefnodeVisualization") then
      local distance = (core_camera.getPosition() - pos):length()
      scl = clamp(distance / 15, 0.0, 1.75) + 0.125
    end
    local alpha = 0.5
    debugDrawer:drawSphere(pos, 0.3 * scl, ColorF(1, 0, 1, 1 * alpha))
    debugDrawer:drawCylinder(pos, pos + (rot * vec3(0, -2 * scl, 0)), 0.1 * scl, ColorF(1, 0, 0, 1 * alpha))
    debugDrawer:drawCylinder(pos, pos + (rot * vec3(0, 0, 2 * scl)), 0.1 * scl, ColorF(0, 0, 1, 1 * alpha))
    debugDrawer:drawCylinder(pos, pos + (rot * vec3(2 * scl, 0, 0)), 0.1 * scl, ColorF(0, 1, 0, 1 * alpha))
    return
  end

  local objMat = obj:getTransform()
  local objBox = obj:getObjBox()
  local objScale = obj:getScale()
  local boxScale = objBox:getExtents()
  local boxCenter = obj:getWorldBox():getCenter()

  objMat:scale(objScale)
  objMat:scale(boxScale)
  objMat:setPosition(boxCenter)
  drawSelectionBBox(objMat, color)
end

local initialGizmoScale = vec3(1, 1, 1)
local function updateObjectSelectionAxisGizmo()
  if editor.selection.object and not tableIsEmpty(editor.selection.object) then
    local xform = MatrixF(true)
    local obj = scenetree.findObjectById(editor.selection.object[#editor.selection.object])
    if not obj then return end
    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      -- we use last object's transform when local gizmo alignment, for the selection
      if obj and obj.getTransform then
        xform = obj:getTransform()
      end
    end
    if obj and obj.getPosition then
      if tableSize(editor.selection.object) > 1 then
        if editor.getPreference("snapping.general.snapToGrid") and editor.getPreference("snapping.grid.useLastObjectSelected") and obj.getPosition then
          xform:setPosition(obj:getPosition())
        else
          xform:setPosition(editor.objectSelectionBBox:getCenter())
        end
      else
        if editor.getPreference("gizmos.general.useObjectBoxCenter") then
          xform:setPosition(editor.getSelectionCentroid())
        else
          xform:setPosition(obj:getPosition())
        end
      end
    end
    editor.setAxisGizmoTransform(xform, initialGizmoScale)
  end
end

local function getMementoFromSelection()
  local mementos = {}
  for _, id in ipairs(editor.selection.object) do
    local obj = scenetree.findObjectById(id)
    if obj then
      --editor.logDebug("Copy id " .. tostring(obj:getId()));
      local memento = editor.saveSimObjectMemento(obj)
      table.insert(mementos, memento)
    end
  end
  return mementos
end

local function getParentIds(objectIDs)
  local parentIds = {}
  for i, id in ipairs(objectIDs) do
    local obj = scenetree.findObjectById(id)
    parentIds[i] = tonumber(obj:getField("parentGroup", 0))
  end
  return parentIds
end

local function pasteObjects(objectMementos, objectIDs, parentIds)
  if not parentIds then
    parentIds = getParentIds(editor.selection.object)
  end

  local newObjectIDs = {}
  local missionGroup = scenetree.MissionGroup
  for i, v in ipairs(objectMementos) do
    if objectIDs and objectIDs[i] then
      SimObject.setForcedId(objectIDs[i])
    end

    local obj = editor.restoreSimObjectMemento(v)

    if obj then
      if obj:getClassName() == "Prefab" then
        local pos = Sim.upcast(obj):getTransform():getColumn(3)
        local posString = "" .. pos.x .. " " .. pos.y .. " " .. pos.z
        local rot = Sim.upcast(obj):getRotation()
        local rotString = "" .. rot.x .. " " .. rot.y .. " " .. rot.z .. " " .. rot.w
        local scale = Sim.upcast(obj):getScale()
        local scaleString = "" .. scale.x .. " " .. scale.y .. " " .. scale.z
        local name = obj:getName()
        local filename = Sim.upcast(obj):getField('filename', '')
        obj:delete()
        if objectIDs and objectIDs[i] then
          SimObject.setForcedId(objectIDs[i])
        end
        obj = spawnPrefab(name, filename, posString, rotString, scaleString)
        if obj then
          obj.loadMode = 0
        end
      end
      if obj then
        local newGroup = nil
        if parentIds and parentIds[i] then newGroup = scenetree.findObjectById(tonumber(parentIds[i])) end
        local grp = editor.resolveAddGroup(newGroup or missionGroup)
        grp:addObject(obj)
        table.insert(newObjectIDs, obj:getId())
        if obj:isSubClassOf("DecalRoad") then -- regenerate, so the BB is correct immediately
          Sim.upcast(obj):regenerate()
        end
      end
    end
  end
  editor.clearObjectSelection()
  editor.selectObjects(newObjectIDs, editor.SelectMode_Add)
  editor.setDirty()
  return newObjectIDs
end

local function pasteObjectsRedo(actionData)
  if not actionData.parentIds then
    actionData.parentIds = getParentIds(editor.selection.object)
  end
  actionData.objectIds = pasteObjects(actionData.objects, actionData.objectIds, actionData.parentIds)
end

local function pasteObjectsUndo(actionData)
  for _, id in ipairs(actionData.objectIds) do
    editor.deleteObject(id)
  end
  editor.clearObjectSelection()
end

local function pasteAndPositionRedo(actionData)
  if not actionData.parentIds then
    actionData.parentIds = getParentIds(editor.selection.object)
  end
  actionData.objectIds = pasteObjects(actionData.objects, actionData.objectIds, actionData.parentIds)
  for i, id in ipairs(actionData.objectIds) do
    scenetree.findObjectById(id):setPosition(actionData.newPositions[i])
  end
  editor.selectObjects(actionData.objectIds, editor.SelectMode_New)
end

local pasteAndPositionUndo = pasteObjectsUndo

local function duplicateSelectionAtCamera()
  if editor.selection.object and editor.selection.object[1] then
    local camDir = core_camera.getQuat() * vec3(0,1,0)
    camDir = camDir * 10
    local targetPos = core_camera.getPosition() + camDir
    local newPositions = {}
    local delta = targetPos - editor.getAxisGizmoTransform():getColumn(3)
    for i, id in ipairs(editor.selection.object) do
      table.insert(newPositions, scenetree.findObjectById(editor.selection.object[i]):getPosition() + delta)
    end
    editor.history:commitAction("DuplicateObjectsAtCamera", {objects = getMementoFromSelection(), newPositions = newPositions}, pasteAndPositionUndo, pasteAndPositionRedo)
  end
end

local function repositionSelectionRedo(actionData)
  editor.clearObjectSelection()
  for i, id in ipairs(actionData.objects) do
    scenetree.findObjectById(id):setPosition(actionData.newPositions[i])
  end
  -- Reselects objects the first time
  actionData.nCount = actionData.nCount or 0
  if actionData.nCount == 0 then
    editor.selectObjects(actionData.objects, editor.SelectMode_New)
  end
  actionData.nCount = actionData.nCount + 1
end

local function repositionSelectionUndo(actionData)
  editor.clearObjectSelection()
  for i, id in ipairs(actionData.objects) do
    scenetree.findObjectById(id):setPosition(actionData.oldPositions[i])
  end
end

local function moveSelectionAtCamera()
  -- There must be at least 1 object selected
  if (editor.selection.object and editor.selection.object[1]) == nil then return end
  -- Calculates new positions and prepares history action data
  local camDir = core_camera.getQuat() * vec3(0,1,0)
  camDir = camDir * 10
  local targetPos = core_camera.getPosition() + camDir
  local delta = targetPos - editor.getAxisGizmoTransform():getColumn(3)
  local selectedObjects = {}  -- filtered selection
  local oldPositions = {}     -- old position tracker for undo
  local newPositions = {}     -- new position tracker for redo
  for i, id in ipairs(editor.selection.object) do
    local obj = scenetree.findObjectById(id)
    if obj:getClassName() ~= 'SimGroup' then   -- ignores groups
      table.insert(selectedObjects, id)
      local oldPosition = obj:getPosition()
      table.insert(oldPositions, oldPosition)  -- backs up old position
      table.insert(newPositions, oldPosition + delta)
    end
  end
  -- Adds history action
  if #selectedObjects ~= 0 then
    editor.history:commitAction(
      "MoveSelectionAtCamera",
      {
        objects = selectedObjects, --editor.selection.object,
        newPositions = newPositions,
        oldPositions = oldPositions
      },
      repositionSelectionUndo, repositionSelectionRedo)
  end
end

local function gizmoBeginDrag()
  axisGizmoEventState.oldTransforms = {}
  axisGizmoEventState.objectHeights = {}
  axisGizmoEventState.oldScales = {}
  local objectBBs = {}
  axisGizmoEventState.objects = {}
  axisGizmoEventState.dragAndDuplicate = false

  local objects = {}
  for i = 1, tableSize(editor.selection.object) do
    objects[i] = scenetree.findObjectById(editor.selection.object[i])
    if not editor.canManipulateObject(objects[i]) then
      return
    end
  end

  for i = 1, tableSize(editor.selection.object) do
    local obj = objects[i]
    if obj.getTransform then
      table.insert(axisGizmoEventState.objects, obj)
      table.insert(axisGizmoEventState.oldTransforms, obj:getTransform())
      table.insert(objectBBs, obj:getWorldBox())
      table.insert(axisGizmoEventState.objectHeights, obj:getObjBox().maxExtents.z)
      table.insert(axisGizmoEventState.oldScales, obj:getScale())
    end
  end
  -- lets check if we want to drag and duplicate the selection
  local shiftDown = editor.keyModifiers.shift

  if shiftDown and not tableIsEmpty(axisGizmoEventState.objects) then
    axisGizmoEventState.dragAndDuplicate = true
  end
  axisGizmoEventState.initialGizmoTransform = editor.getAxisGizmoTransform()
  if worldEditorCppApi.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    editor.beginGizmoTranslate(axisGizmoEventState.oldTransforms, objectBBs, axisGizmoEventState.objectHeights, axisGizmoEventState.objects)
  end
end

local function gizmoDragging()
  if axisGizmoEventState.dragAndDuplicate and editor.keyModifiers.shift then
    -- ok, we duplicate
    axisGizmoEventState.dragAndDuplicate = false
    editor.duplicate()

    axisGizmoEventState.objects = {}
    for i = 1, tableSize(editor.selection.object) do
      local obj = scenetree.findObjectById(editor.selection.object[i])
      if obj and obj.getTransform then
        table.insert(axisGizmoEventState.objects, obj)
      end
    end
  end

  local objects = {}
  for i = 1, tableSize(editor.selection.object) do
    objects[i] = scenetree.findObjectById(editor.selection.object[i])
    if not editor.canManipulateObject(objects[i]) then
      return
    end
  end

  if worldEditorCppApi.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local newTransforms = editor.getTransformsGizmoTranslate(axisGizmoEventState.objects, axisGizmoEventState.objectHeights)
    for index, transform in ipairs(newTransforms) do
      local obj = objects[index]
      if obj then
        obj:setTransform(transform)
      end
    end
  elseif worldEditorCppApi.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    editor.rotateObjectSelection(editor.getAxisGizmoTransform(), editor.getAxisGizmoTransform():getColumn(3), axisGizmoEventState.oldTransforms, axisGizmoEventState.initialGizmoTransform)
  elseif worldEditorCppApi.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    local delta = worldEditorCppApi.getAxisGizmoScaleOffset()
    editor.scaleObjectSelection(delta, editor.getAxisGizmoTransform():getColumn(3))
  end
end

local function getMementoFromManipulableSelection()
  local mementos = {}
  for _, id in ipairs(editor.selection.object) do
    local obj = scenetree.findObjectById(id)
    if obj then
      if editor.canManipulateObject(obj) then
        local memento = editor.saveSimObjectMemento(obj)
        table.insert(mementos, memento)
      end
    end
  end
  return mementos
end

local function gizmoEndDrag()
  local objects = {}
  for i = 1, tableSize(editor.selection.object) do
    objects[i] = scenetree.findObjectById(editor.selection.object[i])
    if not editor.canManipulateObject(objects[i]) then
      updateObjectSelectionAxisGizmo()
      return
    end
  end

  -- set the final transforms
  if duplicationDrag then
    local duplicableObjects = getMementoFromManipulableSelection()
    if not tableIsEmpty(duplicableObjects) then
      editor.history:commitAction("DuplicateObjects", {objects = duplicableObjects, objectIds = deepcopy(editor.selection.object), parentIds = getParentIds(editor.selection.object)}, pasteObjectsUndo, pasteObjectsRedo, true)
      editor.computeSelectionBBox()
    end
    duplicationDrag = false
  elseif worldEditorCppApi.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    editor.history:beginTransaction("ScaleObjectSelection")
    for i = 1, tableSize(editor.selection.object) do
      local obj = objects[i]
      local objId = obj:getId()
      if obj and obj:getClassName() ~= "SimSet" and obj:getClassName() ~= "SimGroup" and obj.getScale then
        editor.history:commitAction("SetObjectScale", {objectId = objId, newScale = obj:getScale(), oldScale = axisGizmoEventState.oldScales[i]}, objectHistoryActions.setObjectScaleUndo, objectHistoryActions.setObjectScaleRedo, true)
        editor.history:commitAction("SetObjectTransform", {objectId = objId, newTransform = editor.matrixToTable(obj:getTransform()), oldTransform = editor.matrixToTable(axisGizmoEventState.oldTransforms[i])}, objectHistoryActions.setObjectTransformUndo, objectHistoryActions.setObjectTransformRedo, true)
      end
    end
    editor.history:endTransaction()
  else
    editor.history:beginTransaction("TransformObjectSelection")
    for i = 1, tableSize(editor.selection.object) do
      local obj = objects[i]
      local objId = obj:getId()
      if obj and obj:getClassName() ~= "SimSet" and obj:getClassName() ~= "SimGroup" and obj.getTransform then
        editor.history:commitAction("SetObjectTransform", {objectId = objId, newTransform = editor.matrixToTable(obj:getTransform()), oldTransform = editor.matrixToTable(axisGizmoEventState.oldTransforms[i])}, objectHistoryActions.setObjectTransformUndo, objectHistoryActions.setObjectTransformRedo, true)
      end
    end
    editor.history:endTransaction()
  end
  editor.setDirty()

  local gizmoMode = worldEditorCppApi.getAxisGizmoMode()
  if gizmoMode == editor.AxisGizmoMode_Translate or gizmoMode == editor.AxisGizmoMode_Rotate or gizmoMode == editor.AxisGizmoMode_Scale then
    local newTransforms = editor.getTransformsGizmoTranslate(axisGizmoEventState.objects, axisGizmoEventState.objectHeights)
    for index, transform in ipairs(newTransforms) do
      local obj = axisGizmoEventState.objects[index]
      if obj then
        local objId = obj:getId()
        local prefabInstance = Engine.Prefab.findContainingPrefabInstance(obj)
        if prefabInstance then
          prefabInstance = Sim.upcast(prefabInstance)
          prefabInstance:updateChildOffsetTransform(objId)
        end
      end
    end
  end

  -- reset variables
  axisGizmoEventState.oldTransforms = {}
  axisGizmoEventState.oldScales = {}
  updateObjectSelectionAxisGizmo()
end

local function drawObjectSelectionGizmos()
  --debugDrawer:currentRenderViewMaskSet(1)
  if editor.selection.object and not tableIsEmpty(editor.selection.object) then
    local boxColor
    -- draw a box for each object
    local drawGizmo = not raycastMode
    for i = 1, tableSize(editor.selection.object) do
      local obj = scenetree.findObjectById(editor.selection.object[i])
      if obj then
        if obj.getTransform then
          if editor.getPreference("gizmos.general.drawSelectionBoundingBox") then
            if obj:isLocked() then boxColor = bboxColorLocked else boxColor = bboxColor end
            drawSelectedObjectBBox(obj, boxColor)
          end
        else
          drawGizmo = false
        end

        if drawGizmo then
          if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
            if obj:getField('position','0') == "" then drawGizmo = false end
          elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
            if obj:getField('rotation','0') == "" then drawGizmo = false end
          elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
            if obj:getField('scale','0') == "" then drawGizmo = false end
          end
        end
      end
    end

    if drawGizmo then
      -- draw big selection box
      if editor.getPreference("gizmos.general.drawSelectionBoundingBox") then
        if tableSize(editor.selection.object) > 1 then
          local mtx = MatrixF(true)
          mtx:setPosition(editor.objectSelectionBBox:getCenter())
          local scl = editor.objectSelectionBBox:getExtents()
          mtx:scale(scl)
          drawSelectionBBox(mtx, bboxColor)
        end
      end

      editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)
      editor.drawAxisGizmo()
    end
  end
  --debugDrawer:currentRenderViewMaskClear()
end

local function objectToolActivate()
  editor.clearObjectSelection()
  updateObjectSelectionAxisGizmo()
  worldEditorCppApi.setAxisGizmoSelectedElement(-1)
end

local function objectToolDeactivate()
  editor.clearObjectSelection()
end

local function drawFrustumRect(frustum)
  local topLeftFrustum = vec3(frustum:getNearLeft() * 2, frustum:getNearDist() * 2, frustum:getNearTop() * 2)
  local topRightFrustum = vec3(frustum:getNearRight() * 2, frustum:getNearDist() * 2, frustum:getNearTop() * 2)
  local bottomLeftFrustum = vec3(frustum:getNearLeft() * 2, frustum:getNearDist() * 2, frustum:getNearBottom() * 2)
  local bottomRightFrustum = vec3(frustum:getNearRight() * 2, frustum:getNearDist() * 2, frustum:getNearBottom() * 2)

  local pos = core_camera.getPosition()
  local q = core_camera.getQuat()
  local topLeftWorld, bottomRightWorld = (q * topLeftFrustum) + pos, (q * bottomRightFrustum) + pos
  local topRightWorld, bottomLeftWorld = (q * topRightFrustum) + pos, (q * bottomLeftFrustum) + pos

  -- Draw the selection rectangle
  debugDrawer:drawLine(topLeftWorld, topRightWorld, ColorF(1, 0, 0, 1))
  debugDrawer:drawLine(topRightWorld, bottomRightWorld, ColorF(1, 0, 0, 1))
  debugDrawer:drawLine(bottomRightWorld, bottomLeftWorld, ColorF(1, 0, 0, 1))
  debugDrawer:drawLine(bottomLeftWorld, topLeftWorld, ColorF(1, 0, 0, 1))
end

local function filterObjects(objects)
  local filteredIndices = {}
  for index, object in ipairs(objects) do
    local className = object:getClassName()
    local name = object:getName()

    if className == "TerrainBlock"
      or className == "WaterPlane"
      or className == "Forest"
      or name == "gameCamera"
      or not editor.isObjectSelectable(object) then
      table.insert(filteredIndices, index)
    end
  end

  for index = #filteredIndices, 1, -1 do
    table.remove(objects, filteredIndices[index])
  end
end

local currentObjectToAlign
local angleAroundUpValue = 0
local draggingObjectToAlign = false
-- per-object align: {obj, id, initialTransform, scale, offsetFromPivot}; pivot follows mouse, each object aligns to normal at its position
local alignToSurfaceObjects = {}
local alignToSurfaceInitialPivot = nil -- vec3, selection pivot at drag start

-- raycast down through a world position to get surface hit (pt, norm)
local function raycastDownAtPosition(pos, rayLen)
  rayLen = rayLen or 500
  local origin = vec3(pos) + vec3(0, 0, rayLen)
  local target = vec3(pos) - vec3(0, 0, rayLen)
  local res = Engine.castRay(origin, target, true, true)
  if not res then return nil end
  return { pt = vec3(res.pt), norm = vec3(res.norm) }
end

-- find the edit mode that declares it edits the given SimObject class (via editObjectClass)
local function getEditModeForObjectClass(className)
  if not className then return nil end
  for _, mode in pairs(editor.editModes) do
    if mode ~= editor.editModes.objectSelect and mode.editObjectClass == className then
      return mode
    end
  end
  return nil
end

local function objectToolUpdate()
  local res = getCameraMouseRay()
  local objectIdByIconClick = editor.objectIconHitId
  local hoveredObjectID = 0
  local rayCastInfo = nil
  local defaultFlags = bit.bor(SOTTerrain, SOTWater, SOTStaticShape, SOTStaticObject, SOTPlayer, SOTItem, SOTVehicle, SOTForest)

  if not worldEditorCppApi.getClassIsSelectable("TSStatic") then
    defaultFlags = bit.band(defaultFlags, bit.bnot(SOTStaticShape))
  end

  if editor.getPreference("gizmos.general.objectHoverHighlight") then
    rayCastInfo = cameraMouseRayCast(true, defaultFlags)
    if not rayCastInfo then
      rayCastInfo = cameraMouseRayCast(false, defaultFlags)
    end
  end

  if not editor.isAxisGizmoHovered()
    and not imgui.GetIO().WantCaptureMouse
    and not imgui.IsAnyItemActive() then
    local hID = 0

    if rayCastInfo and rayCastInfo.object then
      hID = rayCastInfo.object:getID()
    end

    hoveredObjectID = hID or editor.objectIconHoverId
  end

  worldEditorCppApi.setHoveredObjectId(hoveredObjectID)

  local ctrlDown = editor.keyModifiers.ctrl
  local shiftDown = editor.keyModifiers.shift
  local altDown = editor.keyModifiers.alt
  local selectMode = editor.SelectMode_New

  if ctrlDown then selectMode = editor.SelectMode_Toggle end
  if altDown then selectMode = editor.SelectMode_Remove end
  if shiftDown then selectMode = editor.SelectMode_Add end

  -- double-click an object with a dedicated edit mode -> switch to that edit mode
  if imgui.IsMouseDoubleClicked(0)
      and not ctrlDown and not altDown and not shiftDown
      and editor.isViewportHovered()
      and not editor.isAxisGizmoHovered()
      and not imgui.GetIO().WantCaptureMouse
      and not imgui.IsAnyItemActive() then
    if core_forest.getForestObject() and not worldEditorCppApi.getClassIsSelectable("Forest") then core_forest.getForestObject():disableCollision() end
    local dblCastInfo = cameraMouseRayCast(true, defaultFlags)
    if not dblCastInfo then
      dblCastInfo = cameraMouseRayCast(false, defaultFlags)
    end
    if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end

    if dblCastInfo and dblCastInfo.object then
      local dblObject = dblCastInfo.object
      -- resolve owning prefab so double-clicking a prefab child doesn't misfire
      local prefab = getOwningPrefab(dblObject)
      if prefab then
        dblObject = prefab
      else
        prefab = getOwningPrefabInstance(dblObject)
        if prefab and prefab:getClassName() == "PrefabInstance" and not editor.isObjectSelected(prefab:getID()) then
          dblObject = prefab
        end
      end

      local editMode = getEditModeForObjectClass(dblObject:getClassName())
      if editMode and editor.isObjectSelectable(dblObject) and not editor.editingObjectName then
        mouseDown = false
        clickedHoveredObject = false
        local id = dblObject:getID()
        -- switch modes first: leaving objectSelect clears the selection (objectToolDeactivate),
        -- so select the object afterwards so the target mode reads the fresh selection
        editor.selectEditMode(editMode)
        editor.selectObjectById(id, editor.SelectMode_New)
        return
      end
    end

    -- Decal roads have no collision and are not returned by the raycast above, so pick them
    -- by testing the clicked terrain position against each road's footprint (containsPoint
    -- returns a node index, or -1 when the position is not on the road).
    if dblCastInfo and dblCastInfo.pos and not editor.editingObjectName then
      local roadEditMode = getEditModeForObjectClass("DecalRoad")
      if roadEditMode then
        local hitPos = vec3(dblCastInfo.pos)
        for _, roadName in ipairs(scenetree.findClassObjects("DecalRoad") or {}) do
          local road = scenetree.findObject(roadName)
          if road and road.containsPoint and editor.isObjectSelectable(road)
              and not getOwningPrefab(road)
              and road:containsPoint(hitPos) ~= -1 then
            mouseDown = false
            clickedHoveredObject = false
            local id = road:getID()
            editor.selectEditMode(roadEditMode)
            editor.selectObjectById(id, editor.SelectMode_New)
            return
          end
        end
      end
    end

    -- Rivers and mesh roads are mesh-based and are not reliably returned by the
    -- flagged raycast above (their editors pick them with a flags-less cast), so
    -- do a flags-less cast to catch any class that declares a dedicated edit mode.
    if not editor.editingObjectName then
      local meshCastInfo = cameraMouseRayCast(false)
      if meshCastInfo and meshCastInfo.object then
        local meshObject = meshCastInfo.object
        local meshEditMode = getEditModeForObjectClass(meshObject:getClassName())
        if meshEditMode and editor.isObjectSelectable(meshObject) and not getOwningPrefab(meshObject) then
          mouseDown = false
          clickedHoveredObject = false
          local id = meshObject:getID()
          editor.selectEditMode(meshEditMode)
          editor.selectObjectById(id, editor.SelectMode_New)
          return
        end
      end
    end
  end

  if imgui.IsMouseDown(0) and not mouseDown then
    mouseDown = true
  end

  -- when not in Ctrl+Alt align mode, clear zoom block so camera wheel works normally
  local inAlignToSurfaceMode = editor.selection.object and altDown and ctrlDown and #editor.selection.object > 0
  if not inAlignToSurfaceMode and not draggingObjectToAlign then
    editor.disableCameraZoom = false
  end

  -- align selection to surface: pivot follows mouse drag; each object aligns to normal at its position (Ctrl+Alt+drag)
  if imgui.IsMouseClicked(0) or imgui.IsMouseDown(0) or draggingObjectToAlign then
    if editor.selection.object and altDown and ctrlDown and #editor.selection.object then
      -- block camera zoom as soon as Ctrl+Alt+selection is active so wheel is used for angle, not zoom
      editor.disableCameraZoom = true
      if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end

      -- build list of objects to align (manipulable, with transform, skip TerrainBlock)
      local objectsToAlign = {}
      for i = 1, tableSize(editor.selection.object) do
        local id = editor.selection.object[i]
        local o = scenetree.findObjectById(id)
        if o and o.getTransform and o.getScale and o:getClassName() ~= "TerrainBlock" and editor.canManipulateObject(o) then
          table.insert(objectsToAlign, { obj = o, id = id })
        end
      end
      if tableIsEmpty(objectsToAlign) then return end

      if not currentObjectToAlign then
        currentObjectToAlign = true
        draggingObjectToAlign = true
        alignToSurfaceObjects = {}
        local pivotPos = (tableSize(objectsToAlign) == 1) and vec3(objectsToAlign[1].obj:getPosition()) or vec3(editor.objectSelectionBBox:getCenter())
        alignToSurfaceInitialPivot = pivotPos
        for _, entry in ipairs(objectsToAlign) do
          local o, id = entry.obj, entry.id
          o:disableCollision()
          local pos = vec3(o:getPosition())
          local initMtx = o:getTransform()
          -- store initial XY heading (yaw) so we preserve direction while aligning to surface normal
          local forward = vec3(initMtx:getColumn(1))
          local initialYaw = math.atan2(forward.y, forward.x)
          table.insert(alignToSurfaceObjects, {
            obj = o, id = id,
            initialTransform = initMtx,
            scale = o:getScale(),
            offsetFromPivot = pos - pivotPos,
            initialYaw = initialYaw
          })
        end
      end

      -- mouse raycast: pivot follows cursor so selection drags with the mouse
      local mouseHit = cameraMouseRayCast(true, defaultFlags)
      if not mouseHit then mouseHit = cameraMouseRayCast(false, defaultFlags) end
      local pivotPos = (mouseHit and mouseHit.pos) and vec3(mouseHit.pos) or alignToSurfaceInitialPivot

      -- shared rotation around normal (mouse wheel)
      angleAroundUpValue = angleAroundUpValue + imgui.GetIO().MouseWheel * 5 -- TODO: add to prefs
      local mtxCorrection = MatrixF(0)
      local mtxAngleAroundUp = MatrixF(0)
      mtxCorrection:setFromEuler(vec3((90 * math.pi) / 180.0, 0, 0))
      mtxAngleAroundUp:setFromEuler(vec3(0, 0, (angleAroundUpValue * math.pi) / 180.0))

      if not imgui.IsMouseDown(0) and draggingObjectToAlign then
        draggingObjectToAlign = false
        currentObjectToAlign = nil
        angleAroundUpValue = 0
        editor.disableCameraZoom = false
        alignToSurfaceInitialPivot = nil
        editor.history:beginTransaction("AlignObjectToSurface")
        for _, entry in ipairs(alignToSurfaceObjects) do
          entry.obj:enableCollision()
          local newTransform = entry.obj:getTransform()
          editor.history:commitAction("SetObjectTransform", { objectId = entry.id, newTransform = editor.matrixToTable(newTransform), oldTransform = editor.matrixToTable(entry.initialTransform) }, objectHistoryActions.setObjectTransformUndo, objectHistoryActions.setObjectTransformRedo, true)
          editor.history:commitAction("SetObjectScale", { objectId = entry.id, newScale = entry.scale, oldScale = entry.scale }, objectHistoryActions.setObjectScaleUndo, objectHistoryActions.setObjectScaleRedo, true)
        end
        editor.history:endTransaction()
        alignToSurfaceObjects = {}
      else
        -- align to surface normal, preserving initial XY heading: build forward in tangent plane with that exact XY angle
        for _, entry in ipairs(alignToSurfaceObjects) do
          local desiredPos = pivotPos + entry.offsetFromPivot
          local hit = raycastDownAtPosition(desiredPos)
          if hit then
            local n = hit.norm
            -- forward in tangent plane such that atan2(fwd.y, fwd.x) = initialYaw (project (cos,sin,0) onto tangent plane)
            local cx = math.cos(entry.initialYaw)
            local cy = math.sin(entry.initialYaw)
            local ndot = n.x * cx + n.y * cy
            local fz = (math.abs(n.z) >= 1e-6) and (-ndot / n.z) or 0
            local fwd = vec3(cx, cy, fz)
            local flen = math.sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z)
            if flen >= 1e-6 then
              fwd.x, fwd.y, fwd.z = fwd.x / flen, fwd.y / flen, fwd.z / flen
            else
              fwd = vec3(cx, cy, 0)
              local l2 = math.sqrt(cx * cx + cy * cy)
              if l2 >= 1e-6 then fwd.x, fwd.y = cx / l2, cy / l2 end
            end
            -- right = fwd x n (negate n x fwd to avoid X mirror); columns 0,1,2 = right, forward, up
            local rx = fwd.y * n.z - fwd.z * n.y
            local ry = fwd.z * n.x - fwd.x * n.z
            local rz = fwd.x * n.y - fwd.y * n.x
            local rlen = math.sqrt(rx * rx + ry * ry + rz * rz)
            if rlen >= 1e-6 then
              rx, ry, rz = rx / rlen, ry / rlen, rz / rlen
            else
              rx, ry, rz = 1, 0, 0
            end
            local mtx = MatrixF(0)
            mtx:setColumn(0, vec3(rx, ry, rz))
            mtx:setColumn(1, fwd)
            mtx:setColumn(2, vec3(n.x, n.y, n.z))
            mtx:setPosition(hit.pt)
            mtx = mtx:mul(mtxAngleAroundUp)
            mtx:setPosition(hit.pt)
            entry.obj:setTransform(mtx)
            entry.obj:setScaleXYZ(entry.scale.x, entry.scale.y, entry.scale.z)
          end
        end
      end
      updateObjectSelectionAxisGizmo()
      return
    end
  end

  -- selecting objects (skip while file dialog is open, or for a short time after it closed)
  local fileDialogJustClosed = (editor.fileDialogVisibleAtFrameStart == true) and not editor.isWindowVisible("fileDialog")
  local fileDialogSkipTimeAfterClose = 0.5
  local now = os.clock()
  local fileDialogClosedRecently = editor.fileDialogClosedTime and (now - editor.fileDialogClosedTime < fileDialogSkipTimeAfterClose)
  if editor.fileDialogClosedTime and now - editor.fileDialogClosedTime >= fileDialogSkipTimeAfterClose then
    editor.fileDialogClosedTime = nil
  end
  if imgui.IsMouseReleased(0)
      and mouseDown
      and not fileDialogJustClosed
      and not fileDialogClosedRecently
      and (res or objectIdByIconClick)
      and not editor.isAxisGizmoHovered()
      and editor.isViewportHovered()
      and not imgui.GetIO().WantCaptureMouse
      and not imgui.IsAnyItemActive()
      and not editor.isWindowVisible("fileDialog") then
    mouseDown = false
    if objectIdByIconClick and objectIdByIconClick ~= 0 then
      local object = scenetree.findObjectById(objectIdByIconClick)
      if worldEditorCppApi.getClassIsSelectable(object:getClassName())
         and editor.isObjectSelectable(object) then
        if not editor.editingObjectName then
          local oldSelection = deepcopy(editor.selection.object)
          editor.selectObjectById(objectIdByIconClick, selectMode)
          objectHistoryActions.selectObjectsWithUndo(editor.selection.object, oldSelection)
        else
          editor.postNameChangeSelectObjectId = objectIdByIconClick
        end
      end
    else
      local hoveredObject = nil

      if not doingRectSelection
          and imgui.IsMouseReleased(0)
          and not fileDialogJustClosed
          and not fileDialogClosedRecently
          and not imgui.GetIO().WantCaptureMouse
          and editor.isViewportHovered()
          and not editor.isAxisGizmoHovered()
          and not editor.isWindowVisible("fileDialog") then
        if core_forest.getForestObject() and not worldEditorCppApi.getClassIsSelectable("Forest") then core_forest.getForestObject():disableCollision() end

        rayCastInfo = cameraMouseRayCast(true, defaultFlags)
        if not rayCastInfo then
          rayCastInfo = cameraMouseRayCast(false, defaultFlags)
        end

        if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end

        if rayCastInfo then
          hoveredObject = rayCastInfo.object

          -- Get the top level prefab as the hovered object - We have 2 forms old Prefab (V1) and new PrefabInstance (Prefab V2)
          -- Prefab V1
          local prefab = getOwningPrefab(hoveredObject)
          if prefab then
            hoveredObject = prefab
          else
            -- check if it belongs to prefab v2 prefabInstance
            prefab = getOwningPrefabInstance(hoveredObject)
            -- hoveredObject is the actual object in the scene.
            -- If the prefab instance is already selected, then leaving hoveredObject alone will allow the user to select a child of the prefab
            if prefab and prefab:getClassName() == "PrefabInstance" then
              local prefabIsSelected = editor.isObjectSelected(prefab:getID())
              if not prefabIsSelected then
                hoveredObject = prefab
              end
            end
          end

          -- Validate that the object has valid bounds before selecting
          if hoveredObject and hoveredObject.getWorldBox then
            local wb = hoveredObject:getWorldBox()
            if wb and (wb.minExtents.x == -math.huge or wb.maxExtents.x == math.huge or
                       wb.minExtents.y == -math.huge or wb.maxExtents.y == math.huge or
                       wb.minExtents.z == -math.huge or wb.maxExtents.z == math.huge) then
              -- Invalid bounds, try to get bounds from objBox instead
              if hoveredObject.getObjBox then
                local objBox = hoveredObject:getObjBox()
                if objBox and objBox.minExtents and objBox.maxExtents then
                  -- Object has valid objBox, it should work
                else
                  -- No valid bounds, skip selection
                  hoveredObject = nil
                end
              else
                -- No getObjBox method, skip selection
                hoveredObject = nil
              end
            end
          end
        end
      end
      if hoveredObject and editor.isObjectSelectable(hoveredObject) then
        if not editor.editingObjectName then
          local oldSelection = deepcopy(editor.selection.object)
          editor.selectObjectById(hoveredObject:getID(), selectMode)
          objectHistoryActions.selectObjectsWithUndo(editor.selection.object, oldSelection)
        else
          editor.postNameChangeSelectObjectId = hoveredObject:getID()
        end
        clickedHoveredObject = true
      else
        if not doingRectSelection then
          -- just clear selection if we want a new one
          if selectMode == editor.SelectMode_New then
            local oldSelection = deepcopy(editor.selection.object)
            editor.clearObjectSelection()
            objectHistoryActions.selectObjectsWithUndo({}, oldSelection)
          end
        end
      end
    end
    updateObjectSelectionAxisGizmo()
  end

  if clickedHoveredObject and imgui.IsMouseReleased(0) then
    mouseDown = false
    clickedHoveredObject = false
  end

  if clickedHoveredObject and raycastMode and imgui.IsMouseDragging(0, 1) then
    if core_forest.getForestObject() and not worldEditorCppApi.getClassIsSelectable("Forest") then core_forest.getForestObject():disableCollision() end
    local selectedObjects = {}
    for i = 1, tableSize(editor.selection.object) do
      local obj = scenetree.findObjectById(editor.selection.object[i])
      table.insert(selectedObjects, obj)
      obj:disableCollision()
    end
    local rayCastInfo = cameraMouseRayCast(true, defaultFlags)
    if not rayCastInfo then
      rayCastInfo = cameraMouseRayCast(false, defaultFlags)
    end
    if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end
    for _, obj in ipairs(selectedObjects) do
      obj:enableCollision()
      if rayCastInfo then
        obj:setPosition(rayCastInfo.pos)
      end
    end
  end

  if res and not raycastMode then
    drawObjectSelectionGizmos()
  end

  -- set the mouse start pos for rect selection (if the gizmo is not hovered)
  if imgui.IsMouseClicked(0)
      and editor.isViewportHovered()
      and not imgui.GetIO().WantCaptureMouse
      and not editor.isAxisGizmoHovered() then
    mouseDragStartPos = imgui.GetMousePos()
  end

  -- select by rect
  if not (clickedHoveredObject and raycastMode) and imgui.IsMouseDragging(0) and mouseDragStartPos then
    doingRectSelection = true
    local delta = imgui.GetMouseDragDelta(0)
    local topLeft2I = editor.screenToClient(Point2I(mouseDragStartPos.x, mouseDragStartPos.y))
    local topLeft = vec3(topLeft2I.x, topLeft2I.y, 0)
    local bottomRight = (topLeft + vec3(delta.x, delta.y, 0))

    local frustum
    objectsInRect, frustum = editor.getObjectsByRectangle({topLeft = topLeft, bottomRight = bottomRight})

    drawFrustumRect(frustum)
    filterObjects(objectsInRect)

    local color

    if selectMode == editor.SelectMode_New then color = ColorF(1, 1, 0.3, 1)
    elseif selectMode == editor.SelectMode_Add then color = ColorF(0.3, 1, 0.3, 1)
    elseif selectMode == editor.SelectMode_Remove then color = ColorF(1, 0.3, 0.3, 1)
    elseif selectMode == editor.SelectMode_Toggle then color = ColorF(0, 1, 1, 1) end

    for _, object in ipairs(objectsInRect) do
      drawSelectedObjectBBox(object, color)
    end
  end

  if mouseDragStartPos
    and doingRectSelection
    and imgui.IsMouseReleased(0)
    and not imgui.GetIO().WantCaptureMouse then
      mouseDown = false
      mouseDragStartPos = nil
      doingRectSelection = false
      local oldSelection = deepcopy(editor.selection.object)
      editor.selectObjectsByRef(objectsInRect, selectMode)
      objectHistoryActions.selectObjectsWithUndo(editor.selection.object, oldSelection)
      objectsInRect = {}
  end

  -- just nil the mouse drag start position if we released the mouse (and not started to rect select)
  if mouseDragStartPos and imgui.IsMouseReleased(0) then
    mouseDragStartPos = nil
  end
end

local function onEditorAxisGizmoAligmentChanged()
  if not editor.editMode or (editor.editMode.displayName ~= editor.editModes.objectSelect.displayName) then
    return
  end
  updateObjectSelectionAxisGizmo()
end

local function onDeleteSelection()
  if not editor.isViewportFocused() then return end
  -- give a warning notification that there are locked objects in the selection
  local hasLockedObjects = false
  if editor.selection and editor.selection.object then
    for _, objId in ipairs(editor.selection.object) do
      local obj = scenetree.findObjectById(objId)
      if obj and obj.isLocked and obj:isLocked() then
        hasLockedObjects = true
        break
      end
    end
  end

  if hasLockedObjects then
    editor.showNotification("Some locked objects were not deleted!", nil, nil, 5)
  end

  objectHistoryActions.deleteSelectedObjectsWithUndo()
  editor.setDirty()
end

local function copySelectionToClipboard()
  copyObjectsArray = getMementoFromSelection()
  --TODO: the problem with this clipboard is that it will hold these objects until paste objects is
  -- done, we should use the system clipboard
end

local function onCut()
  if not editor.isViewportFocused() then return end
  if not editor.selection.object or tableIsEmpty(editor.selection.object) then return end
  --TODO cut objects to clipboard
end

local function onCopy()
  if not editor.isViewportFocused() then return end
  if not editor.selection.object or tableIsEmpty(editor.selection.object) then return end
  copySelectionToClipboard()
end

local function onPaste()
  if not editor.isViewportFocused() then return end
  local objects = deepcopy(copyObjectsArray)

  -- Use the group of the current selection as the group to put the pasted objects into
  local parentIds = {}
  local groupID
  if editor.selection.object and editor.selection.object[1] then
    groupID = scenetree.findObjectById(editor.selection.object[1]):getField("parentGroup", 0)
  end
  for i = 1, #objects do
    parentIds[i] = groupID
  end

  editor.history:commitAction("PasteObjects", {objects = objects, parentIds = parentIds}, pasteObjectsUndo, pasteObjectsRedo)
end

local function duplicateSceneObjects()
  if editor.selection.object and editor.selection.object[1] then
    if imgui.IsMouseDown(0) then
      pasteObjects(getMementoFromManipulableSelection())
      duplicationDrag = true
    else
      editor.history:commitAction("DuplicateObjects", {objects = getMementoFromSelection()}, pasteObjectsUndo, pasteObjectsRedo)
    end
  end
end

local function onDuplicate()
  if not editor.isViewportFocused() then return end
  duplicateSceneObjects()
end

local function onDeselect()
  editor.deselectObjectSelection()
end

local function hiddenObjectIconsUI(cat, subCat, item)
  imgui.Separator()
  local classes = worldEditorCppApi.getObjectClassNames()
  local hiddenObjectIconClasses = editor.getPreference("gizmos.objectIcons.hiddenObjectIconClasses")
  imgui.TextUnformatted("Hidden Object Icons (select to hide):")
  imgui.Separator()
  imgui.BeginChild1("icon object classes", imgui.ImVec2(0, 200))
  for k = 1, tableSize(classes) do
    imgui.PushID1(tostring(k))
    local isSel = tableContains(hiddenObjectIconClasses, classes[k])
    if imgui.Selectable1(classes[k], isSel) then
      if isSel then
        local key = tableFindKey(hiddenObjectIconClasses, classes[k])
        table.remove(hiddenObjectIconClasses, key)
      else
        table.insert(hiddenObjectIconClasses, classes[k])
      end
      editor.setPreference(item.path, hiddenObjectIconClasses)
    end
    imgui.PopID()
  end
  imgui.EndChild()
end

local function registerApi()
  --TODO: maybe move these to object.lua
  editor.updateObjectSelectionAxisGizmo = updateObjectSelectionAxisGizmo
  editor.drawSelectedObjectBBox = drawSelectedObjectBBox
  editor.drawSelectionBBox = drawSelectionBBox
  editor.duplicateSelectionAtCamera = duplicateSelectionAtCamera
  editor.duplicateSceneObjects = duplicateSceneObjects
  editor.moveSelectionAtCamera = moveSelectionAtCamera
end

local function iconBackgroundTypeFromString(value)
  if value == "None" then return 0 end
  if value == "Circle" then return 1 end
  if value == "Square" then return 2 end
end

local function onEditorPreferenceValueChanged(path, value)
  if path == "gizmos.general.useObjectBoxCenter" then worldEditorCppApi.setUseObjectsBoxCenter(value) end
  if path == "gizmos.general.drawObjectIcons" then worldEditorCppApi.setDrawObjectIcons(value) end
  if path == "gizmos.general.drawObjectsText" then worldEditorCppApi.setDrawObjectsText(value) end
  if path == "gizmos.objectIcons.drawIconShadow" then worldEditorCppApi.setDrawIconShadow(value) end
  if path == "gizmos.objectIcons.constantSizeIcons" then worldEditorCppApi.setConstantSizeIcons(value) end
  if path == "gizmos.objectIcons.constantSizeIconScale" then worldEditorCppApi.setConstantSizeIconScale(value) end
  if path == "gizmos.objectIcons.iconWorldScale" then worldEditorCppApi.setIconWorldScale(value) end
  if path == "gizmos.objectIcons.fadeIcons" then worldEditorCppApi.setFadeIcons(value) end
  if path == "gizmos.objectIcons.useIconColor" then worldEditorCppApi.setUseIconColor(value) end
  if path == "gizmos.objectIcons.randomIconColorSeed" then worldEditorCppApi.setRandomIconColorSeed(value) end
  if path == "gizmos.objectIcons.fadeIconsDistance" then worldEditorCppApi.setFadeIconsDistance(value) end
  if path == "gizmos.objectIcons.iconBackgroundType" then worldEditorCppApi.setIconBackgroundType(iconBackgroundTypeFromString(value)) end
  if path == "gizmos.objectIcons.iconBackgroundScale" then worldEditorCppApi.setIconBackgroundScale(value) end
  if path == "gizmos.objectIcons.monoIconColor" then worldEditorCppApi.setMonoIconColor(value) end
  if path == "gizmos.objectIcons.selectedIconColor" then worldEditorCppApi.setSelectedIconColor(value) end
  if path == "gizmos.objectIcons.iconShadowColor" then worldEditorCppApi.setIconShadowColor(value) end
  if path == "gizmos.objectIcons.iconBackgroundColor" then worldEditorCppApi.setIconBackgroundColor(value) end
  if path == "gizmos.objectIcons.selectedIconBackgroundColor" then worldEditorCppApi.setSelectedIconBgColor(value) end
  if path == "gizmos.objectIcons.objectTextBackgroundColor" then worldEditorCppApi.setObjectTextBackgroundColor(value) end
  if path == "gizmos.objectIcons.objectTextColor" then worldEditorCppApi.setObjectTextColor(value) end
  if path == "gizmos.objectIcons.iconShadowOffset" then worldEditorCppApi.setIconShadowOffset(value) end
  if path == "gizmos.general.fineMoveScalar" then worldEditorCppApi.setFineMoveScalar(value) end
  if path == "gizmos.general.lineThicknessScale" then worldEditorCppApi.setGizmoLineThicknessScale(value) end
  if path == "gizmos.general.objectHoverHighlight" then worldEditorCppApi.setHoveredObjectId(0) end
  if path == "gizmos.general.highlightSelectedMeshes" then
    worldEditorCppApi.setAxisGizmoHighlightSelectedMeshes(value)
    if editor.selection and editor.selection.object then
      for _, objId in ipairs(editor.selection.object) do
        local obj = scenetree.findObjectById(objId)
        if obj and obj.updateInstanceRenderData then
          obj:updateInstanceRenderData()
        end
      end
    end
  end
  if path == "gizmos.general.drawGizmoPlane" then
    worldEditorCppApi.setAxisGizmoRenderPlane(value)
    worldEditorCppApi.setAxisGizmoRenderPlaneHashes(value)
    worldEditorCppApi.setAxisGizmoRenderMoveGrid(value)
  end
  if path == "gizmos.general.gizmoPlaneSize" then worldEditorCppApi.setGizmoPlaneSize(value) end
  if path == "gizmos.general.gizmoPlaneColor" then worldEditorCppApi.setGizmoPlaneColor(value) end
  if path == "gizmos.general.gizmoPlaneGridColor" then worldEditorCppApi.setGizmoPlaneGridLineColor(value) end
  if path == "gizmos.general.fineRotationScalar" then worldEditorCppApi.setFineRotationScalar(value) end
  if path == "gizmos.general.fineScaleScalar" then worldEditorCppApi.setFineScaleScalar(value) end

  if string.find(path, "snapping.general") then
    -- setup snapping into engine
    editor.setAxisGizmoTranslateSnap(editor.getPreference("snapping.general.snapToGrid"), editor.getPreference("snapping.general.gridSize"))
    editor.setAxisGizmoRotateSnap(editor.getPreference("snapping.general.rotateSnapEnabled"), editor.getPreference("snapping.general.rotateSnapSize"))
  end

  if path == "gizmos.objectIcons.hiddenObjectIconClasses" then
    local hiddenObjectIconClasses = editor.getPreference("gizmos.objectIcons.hiddenObjectIconClasses")
    local classes = worldEditorCppApi.getObjectClassNames()
    for _, val in ipairs(classes) do
      worldEditorCppApi.setHideIconClass(val, tableContains(hiddenObjectIconClasses, val))
    end
  end

  if string.find(path, "gizmos.") then
    if editor.updateObjectSelectionAxisGizmo then
      editor.updateObjectSelectionAxisGizmo()
    end
  end
end

local function onEditorRegisterPreferences(prefsRegistry)
  prefsRegistry:registerCategory("gizmos")
  prefsRegistry:registerSubCategory("gizmos", "general")
  prefsRegistry:registerSubCategory("gizmos", "brush")
  prefsRegistry:registerSubCategory("gizmos", "objectIcons")

  prefsRegistry:registerCategory("snapping")
  prefsRegistry:registerSubCategory("snapping", "general")
  prefsRegistry:registerSubCategory("snapping", "terrain")
  prefsRegistry:registerSubCategory("snapping", "grid")

  local highlightShortcut = core_input_bindings and core_input_bindings.getControlForAction("editorToggleSelectionHighlight")
  local highlightSelectedMeshesDesc = "Highlight the selected meshes"
  if highlightShortcut then
    highlightSelectedMeshesDesc = highlightSelectedMeshesDesc .. " (toggle shortcut: " .. highlightShortcut .. ")"
  end

  prefsRegistry:registerPreferences("gizmos", "general",
  {
    -- {name = {type, default value, desc, label (nil for auto Sentence Case), min, max, hidden, advanced, customUiFunc, enumLabels}}
    {useObjectBoxCenter = {"bool", false, "Use the object bounding box center as axis gizmo position, else use the pivot"}},
    {drawObjectIcons = {"bool", true, "Draw the object type icons in the world space"}},
    {drawObjectsText = {"bool", false, "Draw the object type name as text in the world space"}},
    {drawGizmoPlane = {"bool", true, "Draw the gizmo plane"}},
    {gizmoPlaneSize = {"float", 500.0, "Value used for gizmo plane size"}},
    {gizmoPlaneColor = {"ColorI", ColorI(255, 255, 255, 20), "Gizmo plane color"}},
    {gizmoPlaneGridColor = {"ColorI", ColorI(255, 255, 255, 40), "Gizmo Plane Grid color"}},
    {fineMoveScalar = {"float", 0.02, "Value used for fine moving as multiplier"}},
    {fineRotationScalar = {"float", 0.02, "Value used for fine rotation as multiplier"}},
    {fineScaleScalar = {"float", 0.02, "Value used for fine scaling as multiplier"}},
    {localCoordinatesModeDefault = {"bool", false, "Set local coordinates mode as default"}},
    {fixedRefnodeVisualization = {"bool", false, "Refnode Visualization having a fixed size."}},
    {lineThicknessScale = {"float", 1, "The scale factor for the lines used in the gizmos"}},
    {drawSelectionBoundingBox = {"bool", true, "Draw the selection's bounding box also (aside object highlighting)"}},
    {objectHoverHighlight = {"bool", false, "Highlight the currently hovered object (expensive)", "Object Hover Highlight (expensive)"}},
    {highlightSelectedMeshes = {"bool", true, highlightSelectedMeshesDesc}},
  })

  prefsRegistry:registerPreferences("gizmos", "brush",
  {
    -- {name = {type, default value, desc, label (nil for auto Sentence Case), min, max, hidden, advanced, customUiFunc, enumLabels}}
    {marginSize = {"float", 0.2, "The brush edge/margin size, used by terrain, forest editors"}},
    {createBrushColor = {"ColorF", ColorF(0, 0, 1, 0.5), "Color of the creating brush modes"}},
    {deleteBrushColor = {"ColorF", ColorF(1, 0, 0, 0.5), "Color of the deleting brush modes"}},
  })

  prefsRegistry:registerPreferences("gizmos", "objectIcons",
  {
    -- {name = {type, default value, desc, label (nil for auto Sentence Case), min, max, hidden, advanced, customUiFunc, enumLabels}}
    {drawIconShadow = {"bool", true, "Draw a shadow under the object icons"}},
    {constantSizeIcons = {"bool", true, "Draw the object type icons with a constant screen size"}},
    {constantSizeIconScale = {"float", 0.8, "The scale of the constant size icons"}},
    {iconWorldScale = {"float", 0.2, "The scale of the icons when rendered in world size"}},
    {fadeIcons = {"bool", true, "Fade the icons based on their distance to the camera"}},
    {useIconColor = {"bool", false, "Draw the object icons with different colors"}},
    {randomIconColorSeed = {"float", 0, "The color random seed used for coloured icon rendering"}},
    {fadeIconsDistance = {"float", 30, "The distance from where icons will start to fade out"}},
    {fadeIconsDistanceModifySpeed = {"float", 10, "The multiplier speed for fade icon distance when it is modified"}},
    {iconBackgroundType = {"enum", "None", "The icon background shape type", nil, nil, nil, nil, nil, nil, {"None", "Circle", "Square"}}},
    {iconBackgroundScale = {"float", 1.4, "The icon background scale factor"}},
    {monoIconColor = {"ColorI", ColorI(255, 255, 255, 255), "The color of the icons when using a single color for all"}},
    {selectedIconColor = {"ColorI", ColorI(255, 128, 0, 255), "The color of a selected icon"}},
    {iconShadowColor = {"ColorI", ColorI(0, 0, 0, 255), "The object icon's shadow color"}},
    {iconBackgroundColor = {"ColorI", ColorI(0, 255, 255, 255), "The object icon's background color"}},
    {selectedIconBackgroundColor = {"ColorI", ColorI(178, 102, 0, 255), "Selected object icon's background color"}},
    {objectTextBackgroundColor = {"ColorI", ColorI(0, 0, 0, 255), "World space object name text background color"}},
    {objectTextColor = {"ColorI", ColorI(255, 255, 255, 255), "World space object name text color"}},
    {iconShadowOffset = {"Point2F", Point2F(3, 3), "The offset in pixels, for the shadow of the object icons"}},
    {hiddenObjectIconClasses = {"table", {"TSStatic"}, nil, nil, nil, nil, nil, nil, hiddenObjectIconsUI}},
  })

  prefsRegistry:registerPreferences("snapping", "general",
  {
    {snapToGrid = {"bool", false, "Snap objects to the grid"}},
    {gridSize = {"float", 1, "Grid size used for snapping objects to"}},
    {rotateSnapEnabled = {"bool", false, "Snap objects to fixed angles when rotating"}},
    {rotateSnapSize = {"float", 15, "Rotate snap angle step when rotating"}},
  })

  prefsRegistry:registerPreferences("snapping", "terrain",
  {
    {enabled = {"bool", false, "Snap objects to the terrain"}},
    {keepHeight = {"bool", false, "Keep the relative height when snapping"}},
    {snapToCenter = {"bool", false, "Snap objects to the center of their bounding box"}},
    {snapToBB = {"bool", false, "Snap objects to the bottom of their bounding box", "Snap To Bounding Box"}},
    {relRotation = {"bool", false, "Use relative rotation to terrain when snapping", "Relative Rotation"}},
    {indObjects = {"bool", false, "When snapping, snap each objects in the selection individually not as a group", "Treat Objects Individually"}},
    {useRayCast = {"bool", false, "Use raycast to find objects below to snap on"}},
  })

  prefsRegistry:registerPreferences("snapping", "grid",
  {
    {useLastObjectSelected = {"bool", false, "Use the last object selected as reference object for grid snapping"}},
  })

end

local function extendedSceneTreeObjectMenuItems(node)
  moveSelectionAtCamera()
end

local function onEditorInitialized()
  editor.editModes.objectSelect =
  {
    displayName = "Manipulate Object(s)",
    onActivate = objectToolActivate,
    onDeactivate = objectToolDeactivate,
    onUpdate = objectToolUpdate,
    onToolbar = nil,
    actionMap = "ObjectTool",
    onCut = onCut,
    onCopy = onCopy,
    onPaste = onPaste,
    onDeselect = onDeselect,
    onDeleteSelection = onDeleteSelection,
    onDuplicate = onDuplicate,
    icon = editor.icons.mode_edit,
    iconTooltip = "Object Select",
    auxShortcuts = {}
  }

  editor.editModes.objectSelect.auxShortcuts[editor.AuxControl_Copy] = "Copy objects"
  editor.editModes.objectSelect.auxShortcuts[editor.AuxControl_Paste] = "Paste objects"
  editor.editModes.objectSelect.auxShortcuts[editor.AuxControl_Cut] = "Cut objects"
  editor.editModes.objectSelect.auxShortcuts[editor.AuxControl_Duplicate] = "Duplicate objects"
  editor.editModes.objectSelect.auxShortcuts[editor.AuxControl_Delete] = "Delete objects"
  editor.editModes.objectSelect.auxShortcuts[bit.bor(editor.AuxControl_Shift, editor.AuxControl_Duplicate)] = "Duplicate at cam pos"
  editor.editModes.objectSelect.auxShortcuts["Shift + Drag Gizmo"] = "Duplicate objects"
  editor.editModes.objectSelect.auxShortcuts[bit.bor(editor.AuxControl_Ctrl, editor.AuxControl_Alt)] = "Align object to surfaces on LMB down + Wheel (rotates around up axis)"
  editor.editModes.objectSelect.auxShortcuts[bit.bor(editor.AuxControl_Ctrl)] = "Fine Rotation/Scale"
  registerApi()

  if editor.getPreference("gizmos.general.localCoordinatesModeDefault") then
    editor.setAxisGizmoAlignment(editor.AxisGizmoAlignment_Local)
  end

  editor.addExtendedSceneTreeObjectMenuItem({
    title = "Move Selection At Camera",
    extendedSceneTreeObjectMenuItems = extendedSceneTreeObjectMenuItems,
  })
  editor.addExtendedSceneTreeObjectMenuItem({
    title = "Align Objects Individually To The Grid",
    extendedSceneTreeObjectMenuItems = function()
      for _, id in ipairs(editor.selection.object or {}) do
        local xform = MatrixF(true)
        local obj = scenetree.findObjectById(id)
        if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
          -- we use last object's transform when local gizmo alignment, for the selection
          if obj and obj.getTransform then
            xform = obj:getTransform()
          end
        end
        local pos = obj:getPosition()
        pos.x = round(pos.x / editor.getPreference("snapping.general.gridSize")) * editor.getPreference("snapping.general.gridSize")
        pos.y = round(pos.y / editor.getPreference("snapping.general.gridSize")) * editor.getPreference("snapping.general.gridSize")
        pos.z = round(pos.z / editor.getPreference("snapping.general.gridSize")) * editor.getPreference("snapping.general.gridSize")
        xform:setPosition(pos)
        obj:setTransform(xform)
      end
    end
  })
end

local function onEditorInspectorFieldChanged(selectedIds, fieldName, fieldValue, arrayIndex)
  local selectedId = selectedIds[1]
  if selectedId and fieldName == "startTime" then
    local object = scenetree.findObjectById(selectedId)
    if object and object:getClassName() == "TimeOfDay" then
      local tod = core_environment.getTimeOfDay()
      if tod then
        tod.time = tod.startTime
        core_environment.setTimeOfDay(tod)
      end
    end
  end
end

local function onEditorEditModeActivated(editMode)
  -- restore this edit mode's gizmo state
  if editMode.axisGizmoRestoreState then
    worldEditorCppApi.setAxisGizmoRenderPlane(editMode.axisGizmoRestoreState.renderPlane)
    worldEditorCppApi.setAxisGizmoRenderPlaneHashes(editMode.axisGizmoRestoreState.renderPlaneHashes)
    worldEditorCppApi.setAxisGizmoRenderMoveGrid(editMode.axisGizmoRestoreState.renderMoveGrid)
    worldEditorCppApi.setAxisGizmoHideDisabledTranslateAxes(editMode.axisGizmoRestoreState.hideDisabledTranslateAxes)
    worldEditorCppApi.setAxisGizmoHideDisabledRotateAxes(editMode.axisGizmoRestoreState.hideDisabledRotateAxes)
    worldEditorCppApi.setAxisGizmoHideDisabledScaleAxes(editMode.axisGizmoRestoreState.hideDisabledScaleAxes)
    worldEditorCppApi.setAxisGizmoTranslateProfileFlags(editMode.axisGizmoRestoreState.translateProfileFlags)
    worldEditorCppApi.setAxisGizmoRotateProfileFlags(editMode.axisGizmoRestoreState.rotateProfileFlags)
    worldEditorCppApi.setAxisGizmoScaleProfileFlags(editMode.axisGizmoRestoreState.scaleProfileFlags)
    worldEditorCppApi.setAxisGizmoAlignment(editMode.axisGizmoRestoreState.gizmoAlignment)
    worldEditorCppApi.setAxisGizmoMode(editMode.axisGizmoRestoreState.gizmoMode)
  end
end

local function onEditorEditModeDeactivated(editMode)
  -- save this edit mode's gizmo state
  editMode.axisGizmoRestoreState = {
    renderPlane = worldEditorCppApi.getAxisGizmoRenderPlane(),
    renderPlaneHashes = worldEditorCppApi.getAxisGizmoRenderPlaneHashes(),
    renderMoveGrid = worldEditorCppApi.getAxisGizmoRenderMoveGrid(),
    hideDisabledTranslateAxes = worldEditorCppApi.getAxisGizmoHideDisabledTranslateAxes(),
    hideDisabledRotateAxes = worldEditorCppApi.getAxisGizmoHideDisabledRotateAxes(),
    hideDisabledScaleAxes = worldEditorCppApi.getAxisGizmoHideDisabledScaleAxes(),
    translateProfileFlags = worldEditorCppApi.getAxisGizmoTranslateProfileFlags(),
    rotateProfileFlags = worldEditorCppApi.getAxisGizmoRotateProfileFlags(),
    scaleProfileFlags = worldEditorCppApi.getAxisGizmoScaleProfileFlags(),
    gizmoAlignment = worldEditorCppApi.getAxisGizmoAlignment(),
    gizmoMode = worldEditorCppApi.getAxisGizmoMode()
  }
end

M.onEditorInitialized = onEditorInitialized
M.onEditorPreferenceValueChanged = onEditorPreferenceValueChanged
M.onEditorAxisGizmoAligmentChanged = onEditorAxisGizmoAligmentChanged
M.onEditorRegisterPreferences = onEditorRegisterPreferences
M.onEditorInspectorFieldChanged = onEditorInspectorFieldChanged
M.onEditorEditModeActivated = onEditorEditModeActivated
M.onEditorEditModeDeactivated = onEditorEditModeDeactivated

return M