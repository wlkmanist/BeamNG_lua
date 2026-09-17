-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Editor extension that adds a "convert light class" button to the top of the
-- object inspector. When a single PointLight or SpotLight is selected it lets
-- you swap the object to the other light class in-place: the new object keeps
-- the same SimObject id, name, parent group, transform and every field that
-- both classes share. The conversion is a single, fully reversible undo step.

local M = {}
-- Depend on the inspector so this loads after it and the header gui hook + the
-- object/history apis we use are guaranteed to be available.
M.dependencies = {"editor_inspector"}

local logTag = "editor_lightClassConverter"
local imgui = ui_imgui

-- maps a light class to the class it converts into, and a human readable label
local conversionTargets = {
  PointLight = {className = "SpotLight", label = "Spot Light"},
  SpotLight = {className = "PointLight", label = "Point Light"},
}

local transformFields = {"position", "rotation", "scale"}

-- the light reach is the same quantity under class specific names, "radius" on
-- PointLight and "range" on SpotLight, so the bulk field copy always drops it
-- and the converted light silently falls back to the class default. shadows are
-- gated on the reach (the camera must sit inside it), so losing it also kills
-- the shadow, we map it across explicitly instead.
local reachFieldByClass = {PointLight = "radius", SpotLight = "range"}

-- "intensity" and "brightness" are two linked representations of the same
-- quantity: the engine keeps them in sync, and "intensity" is stored in a
-- class specific unit (lumens for PointLight, candelas for SpotLight). Copying
-- both raw across a class change makes the engine re-sync them with a different
-- factor every time, so the values snowball on each conversion. We skip them in
-- the bulk copy and re-apply "brightness" (the actual render value) last, so the
-- engine derives a fresh, consistent "intensity" for the target class instead.
local photometricFields = {brightness = true, intensity = true}

-- collect everything we need to faithfully rebuild this object, either as the
-- original class (undo, via the serialized blob) or as the target class (the
-- shared fields are filtered against the target class when applied).
local function gatherObjectState(objId)
  local obj = scenetree.findObjectById(objId)
  if not obj then return nil end

  local state = {
    id = objId,
    name = obj:getName(),
    className = obj:getClassName(),
    fields = editor.copyFields(objId), -- shared static + array + dynamic fields (skips transform/name/persistentId/parentGroup)
    -- full serialization so undo can restore the original object exactly
    serialized = "[" .. obj:serialize(true, -1) .. "]",
  }

  for _, fieldName in ipairs(transformFields) do
    state[fieldName] = editor.getFieldValue(objId, fieldName)
  end

  -- captured separately and re-applied last (see photometricFields note)
  state.brightness = editor.getFieldValue(objId, "brightness")

  local group = obj:getGroup()
  state.parentId = group and group:getID() or nil

  return state
end

-- (re)create the object as `targetClass`, reusing the original id, name, parent
-- group and transform, then copy over every field the target class also has.
local function createLightFromState(targetClass, state)
  if state.id then
    SimObject.setForcedId(state.id)
  end

  local newObj = createObject(targetClass)
  if not newObj then
    editor.logError(logTag .. ": failed to create object of class " .. tostring(targetClass))
    return nil
  end
  newObj:registerObject(state.name or "")

  local parent = state.parentId and scenetree.findObjectById(state.parentId) or scenetree.MissionGroup
  if parent then
    parent:addObject(newObj.obj)
  end

  local newId = newObj:getId()

  for _, fieldName in ipairs(transformFields) do
    if state[fieldName] and state[fieldName] ~= "" then
      editor.setFieldValue(newId, fieldName, state[fieldName])
    end
  end

  -- only paste shared static/array fields that actually exist on the target
  -- class, so we don't pollute it with leftover dynamic fields (e.g. a
  -- PointLight's "radius" ending up on a SpotLight).
  local validFields = editor.getFields(newId) or {}
  local toPaste = {fields = {}, arrayElements = {}, dynamicFields = state.fields.dynamicFields}

  for fieldName, value in pairs(state.fields.fields) do
    if validFields[fieldName] and not photometricFields[fieldName] then
      toPaste.fields[fieldName] = value
    end
  end
  for _, element in ipairs(state.fields.arrayElements) do
    if validFields[element.fieldName] and not photometricFields[element.fieldName] then
      table.insert(toPaste.arrayElements, element)
    end
  end

  editor.pasteFields(toPaste, newId)

  -- carry the light reach across the class change (see reachFieldByClass note)
  local sourceReach = state.fields.fields[reachFieldByClass[state.className]]
  local targetReachField = reachFieldByClass[targetClass]
  if sourceReach and sourceReach ~= "" and targetReachField and validFields[targetReachField] then
    editor.setFieldValue(newId, targetReachField, sourceReach)
  end

  -- re-apply brightness last so it stays authoritative: the engine derives a
  -- consistent intensity for the new class from it, keeping the rendered light
  -- identical and preventing the intensity/brightness values from snowballing.
  if validFields["brightness"] and state.brightness and state.brightness ~= "" then
    editor.setFieldValue(newId, "brightness", state.brightness)
  end

  return newId
end

-- (re)select every converted object so the highlight/gizmo follow the swap;
-- the ids are preserved by the conversion so this works for undo and redo alike.
local function reselectConverted(actionData)
  local ids = {}
  for _, entry in ipairs(actionData.objects) do
    table.insert(ids, entry.id)
  end
  editor.selectObjects(ids, editor.SelectMode_New)
end

local function convertRedo(actionData)
  for _, entry in ipairs(actionData.objects) do
    -- remove the current object (original class on first run / after an undo)
    editor.deleteObject(entry.id)
    -- rebuild it as the target class, keeping the same id
    createLightFromState(entry.targetClass, entry.originalState)
    extensions.hook("onEditorObjectAdded", entry.id)
  end
  reselectConverted(actionData)
  editor.setDirty()
end

local function convertUndo(actionData)
  for _, entry in ipairs(actionData.objects) do
    -- remove the converted object and restore the original from its serialization
    editor.deleteObject(entry.id)
    SimObject.setForcedId(entry.id)
    Sim.deserializeObjectsFromText(entry.originalState.serialized, true, true)

    local obj = scenetree.findObjectById(entry.id)
    if obj and not obj:getGroup() and entry.originalState.parentId then
      local parent = scenetree.findObjectById(entry.originalState.parentId)
      if parent then parent:addObject(obj) end
    end

    extensions.hook("onEditorObjectAdded", entry.id)
  end
  reselectConverted(actionData)
  editor.setDirty()
end

-- convert every object in objIds to targetClass as a single, atomic undo step
local function convertLights(objIds, targetClass)
  local objects = {}
  for _, objId in ipairs(objIds) do
    local originalState = gatherObjectState(objId)
    if originalState then
      table.insert(objects, {id = objId, targetClass = targetClass, originalState = originalState})
    else
      editor.logError(logTag .. ": could not read object state for id " .. tostring(objId))
    end
  end

  if tableIsEmpty(objects) then return end

  editor.history:commitAction("ConvertLightClass", {objects = objects}, convertUndo, convertRedo)
end

-- rendered at the top of the object inspector window (see the
-- "onEditorInspectorHeaderGui" hook fired by editor_inspector)
local function onEditorInspectorHeaderGui(inspectorInfo)
  -- respect a locked inspector's own selection, else use the live selection
  local selection = (inspectorInfo and inspectorInfo.selection and inspectorInfo.selection.object) or editor.selection.object
  if not selection or tableIsEmpty(selection) then return end

  -- only offer the conversion when every selected object is the same
  -- convertible light class (a homogeneous PointLight or SpotLight selection)
  local commonClass = nil
  local anyLocked = false
  local ids = {}
  for _, id in ipairs(selection) do
    local obj = scenetree.findObjectById(id)
    if not obj or not obj.getClassName then return end
    local className = obj:getClassName()
    if not conversionTargets[className] then return end
    if commonClass == nil then
      commonClass = className
    elseif commonClass ~= className then
      return
    end
    if obj:isLocked() then anyLocked = true end
    table.insert(ids, id)
  end
  if not commonClass then return end

  local target = conversionTargets[commonClass]
  local count = tableSize(ids)

  if anyLocked then
    imgui.TextColored(imgui.ImVec4(1, 0.8, 0, 1),
      (count > 1 and "Some selected lights are" or "Light is") .. " locked, cannot convert.")
    return
  end

  local buttonLabel = count > 1
    and ("Convert " .. count .. " To " .. target.label .. "s")
    or ("Convert To " .. target.label)

  imgui.PushStyleColor2(imgui.Col_Button, imgui.ImVec4(0.18, 0.42, 0.62, 1))
  imgui.PushStyleColor2(imgui.Col_ButtonHovered, imgui.ImVec4(0.24, 0.54, 0.78, 1))
  if imgui.Button(buttonLabel, imgui.ImVec2(-1, 0)) then
    convertLights(ids, target.className)
  end
  imgui.PopStyleColor(2)
  if imgui.IsItemHovered() then
    imgui.SetTooltip("Replace the selected " .. commonClass .. "(s) with " .. target.className ..
      "(s),\nkeeping the same id, name, transform and shared properties.")
  end
  imgui.Separator()
end

M.onEditorInspectorHeaderGui = onEditorInspectorHeaderGui

return M
