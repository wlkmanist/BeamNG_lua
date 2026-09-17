-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local im = ui_imgui

local toolWindowName = "copyToSelectedTransforms"
local toolName = "Copy To Selected"

-- State
local baseId = nil
local targetIds = {}
local lastError = nil

-- Options
local includeRotation = im.BoolPtr(false)
local includeScale    = im.BoolPtr(false)
local useSimGroup     = im.BoolPtr(false)
local selectCreated   = im.BoolPtr(true)
local useRelativeRotation = im.BoolPtr(false)

local childLinkFieldName = "child"
local maxChildLinkFieldsToScan = 1024

-- Per-target local offset (in target local space)
local offsetX, offsetY, offsetZ = im.FloatPtr(0), im.FloatPtr(0), im.FloatPtr(0)

-- Helpers
local function validObj(id)
  return id and scenetree.findObjectById(id)
end

local function getSelectionList()
  local list = {}
  if editor.selection and editor.selection.object then
    for _, id in ipairs(editor.selection.object) do
      if validObj(id) then table.insert(list, id) end
    end
  end
  return list
end

local function getFirstSelection()
  local list = getSelectionList()
  return list[1]
end

local function buildTransformData(ids, skipId)
  local data = {}
  for _, id in ipairs(ids) do
    if id ~= skipId then
      local o = scenetree.findObjectById(id)
      if o then
        table.insert(data, {
          pos = o:getPosition(),
          transform = o:getTransform(),
          scale = o:getScale(),
          id = id
        })
      end
    end
  end
  return data
end

local function getCustomField(obj, fieldName, index)
  if not obj or not fieldName then return nil end
  index = index or 0

  if obj.getDynDataFieldbyName then
    local ok, value = pcall(obj.getDynDataFieldbyName, obj, fieldName, index)
    if ok then return value end
  end

  if obj.getField then
    local ok, value = pcall(obj.getField, obj, fieldName, index)
    if ok then return value end
  end

  return nil
end

local function setCustomField(obj, fieldName, index, value)
  if not obj or not fieldName then return false end
  index = index or 0
  value = tostring(value or "")

  if obj.setDynDataFieldbyName then
    local ok = pcall(obj.setDynDataFieldbyName, obj, fieldName, index, value)
    if ok then return true end
  end

  if obj.setField then
    local ok = pcall(obj.setField, obj, fieldName, index, value)
    if ok then return true end
  end

  return false
end

local function isEmptyCustomFieldValue(value)
  return value == nil or tostring(value) == ""
end

local function findFirstFreeCustomFieldIndex(obj, fieldName)
  for i = 0, maxChildLinkFieldsToScan - 1 do
    local value = getCustomField(obj, fieldName, i)
    if isEmptyCustomFieldValue(value) then
      return i
    end
  end

  return nil
end

local function getCreatedCopyLinkName(obj)
  if not obj or not obj.getName then return nil end

  local name = obj:getName()
  if name and name ~= "" then
    return name
  end

  return nil
end

local function linkCreatedCopyToTarget(targetId, newObj, fieldEdits)
  local target = scenetree.findObjectById(targetId)
  if not target or not newObj then return end

  local copyName = getCreatedCopyLinkName(newObj)
  if not copyName or copyName == "" then return end

  local index = findFirstFreeCustomFieldIndex(target, childLinkFieldName)
  if index == nil then
    log("W", "copyToSelectedTransforms", string.format(
      "Could not add child link to target %s: no free '%s' custom field index found.",
      tostring(targetId),
      tostring(childLinkFieldName)
    ))
    return
  end

  local before = getCustomField(target, childLinkFieldName, index)

  if setCustomField(target, childLinkFieldName, index, copyName) then
    if fieldEdits then
      table.insert(fieldEdits, {
        targetId = targetId,
        fieldName = childLinkFieldName,
        index = index,
        before = before,
        after = copyName,
      })
    end
  end
end

local function getAxisDirFromTransform(m, axisIdx)
  local v = m:getColumn(axisIdx)
  local dir = vec3(v.x, v.y, v.z)
  local len = dir:length()
  if len < 1e-9 then return vec3(0,0,0) end
  return dir / len
end

local function quatFromMatrixAxes(m)
  -- Build a quaternion from forward(+Y) and up(+Z) axes
  local fwd = getAxisDirFromTransform(m, 1)
  local up  = getAxisDirFromTransform(m, 2)
  return quatFromDir(fwd, up)
end

local function getLocalOffsetVector(td, lx, ly, lz)
  if (lx == 0) and (ly == 0) and (lz == 0) then return vec3(0,0,0) end
  local dx = getAxisDirFromTransform(td.transform, 0) * lx
  local dy = getAxisDirFromTransform(td.transform, 1) * ly
  local dz = getAxisDirFromTransform(td.transform, 2) * lz
  return dx + dy + dz
end

local function getIdsOfClass(className)
  local out = {}
  local objects = scenetree.findClassObjects(className)
  if objects then
    for _, v in ipairs(objects) do
      local o = scenetree.findObject(v)
      if o and o.getId then
        table.insert(out, o:getId())
      end
    end
    return out
  end
  local function canGroup(g)
    return g and g.getClassName and g.getCount and g.getObject
  end
  local function scanGroup(outTbl, grp)
    if not canGroup(grp) then return end
    local n = grp:getCount()
    for i = 0, n - 1 do
      local o = grp:getObject(i)
      if o then
        local cls = (o.className) or (o.getClassName and o:getClassName()) or ""
        if cls == "SimGroup" then
          scanGroup(outTbl, o)
        elseif cls == className then
          table.insert(outTbl, o:getId())
        end
      end
    end
  end
  scanGroup(out, scenetree.MissionGroup)
  return out
end

local function normalizePath(path)
  if not path then return "" end

  -- optional: make slashes consistent
  path = path:gsub("\\", "/")

  -- remove one or more leading slashes
  path = path:gsub("^/+", "")

  return path
end

local function findAllSame(refId, sameMeshForTSStatic)
  local ref = scenetree.findObjectById(refId)
  if not ref then return {} end
  local className = ref.className or (ref.getClassName and ref:getClassName()) or ""
  local candidates = getIdsOfClass(className)
  if sameMeshForTSStatic and className == "TSStatic" then
    local targetShape = normalizePath(ref:getField("shapeName", 0))
    local filtered = {}
    for _, id in ipairs(candidates) do
      local o = scenetree.findObjectById(id)
      if o then
        local shapeName = normalizePath(o:getField("shapeName", 0))
        if shapeName == targetShape then
          table.insert(filtered, id)
        end
      end
    end
    return filtered
  end
  return candidates
end

-- Creation with optional forced IDs for redo
local function createCopies(baseId_, tdata, params, presetIds, presetGroupId)
  local base = scenetree.findObjectById(baseId_)
  if not base or not tdata or #tdata == 0 then return end

  local newGroup
  local groupId
  if params.useSimGroup then
    if presetGroupId then SimObject.setForcedId(presetGroupId) end
    newGroup = createObject("SimGroup")
    newGroup:registerObject(Sim.getUniqueName("CopiedObjects"))
    scenetree.MissionGroup:addObject(newGroup)
    groupId = newGroup:getId()
  end

  local baseParentGroup = scenetree.findObjectById(tonumber(base:getField("parentGroup", 0)))
  local grp = newGroup or baseParentGroup or scenetree.MissionGroup

  local memento = editor.saveSimObjectMemento(base)
  local newIds = {}
  local fieldEdits = {}

  for i, td in ipairs(tdata) do
    if presetIds and presetIds[i] then SimObject.setForcedId(presetIds[i]) end
    local newObj = editor.restoreSimObjectMemento(memento)
    grp:addObject(newObj)
    linkCreatedCopyToTarget(td.id, newObj, fieldEdits)

    local localOff = getLocalOffsetVector(td, params.offsetX or 0, params.offsetY or 0, params.offsetZ or 0)
    local finalPos = td.pos + localOff

    if params.includeRotation then
      newObj:setTransform(td.transform)
      newObj:setPosition(finalPos)
    else
      if params.useRelativeRotation then
        local baseQ    = quatFromMatrixAxes(newObj:getTransform())
        local targetQ  = quatFromMatrixAxes(td.transform)
        local finalQ   = targetQ * baseQ
        local mat      = QuatF(finalQ.x, finalQ.y, finalQ.z, finalQ.w):getMatrix()
        mat:setPosition(finalPos)
        newObj:setTransform(mat)
      else
        newObj:setPosition(finalPos)
      end
    end

    if params.includeScale then
      newObj:setScale(td.scale)
    end

    table.insert(newIds, newObj:getId())
  end

  if params.selectCreated and #newIds > 0 then
    editor.clearObjectSelection()
    editor.selection.object = editor.selection.object or {}
    for _, id in ipairs(newIds) do
      if validObj(id) then table.insert(editor.selection.object, id) end
    end
    extensions.hook("onEditorObjectSelectionChanged")
  end

  return newIds, groupId, fieldEdits
end

-- Undo/Redo
local function createUndo(data)
  for _, edit in ipairs(data.fieldEdits or {}) do
    local target = scenetree.findObjectById(edit.targetId)
    if target then
      setCustomField(target, edit.fieldName, edit.index or 0, edit.before or "")
    end
  end

  for _, id in ipairs(data.objectIds or {}) do
    if validObj(id) then editor.deleteObject(id) end
  end

  if data.groupId and validObj(data.groupId) then
    editor.deleteObject(data.groupId)
  end

  editor.clearObjectSelection()
end

local function createRedo(data)
  data.objectIds, data.groupId, data.fieldEdits = createCopies(
    data.baseId,
    data.tdata,
    data.params,
    data.objectIds,
    data.groupId
  )
end

-- Create action
local function runCreate()
  lastError = nil
  if not validObj(baseId) then lastError = "Pick a valid Base object."; return end
  if not targetIds or #targetIds == 0 then lastError = "No target objects selected."; return end

  local tdata = buildTransformData(targetIds, baseId)
  if #tdata == 0 then lastError = "No valid target transforms."; return end

  local params = {
    includeRotation   = includeRotation[0],
    includeScale      = includeScale[0],
    useSimGroup       = useSimGroup[0],
    selectCreated     = selectCreated[0],
    useRelativeRotation = useRelativeRotation[0],
    offsetX = offsetX[0],
    offsetY = offsetY[0],
    offsetZ = offsetZ[0],
  }

  local actionData = {
    baseId = baseId,
    tdata = deepcopy(tdata),
    params = deepcopy(params),
    objectIds = nil,
    groupId = nil,
    fieldEdits = nil,
  }
  editor.history:commitAction("Copy Object To Selected Transforms", actionData, createUndo, createRedo)
end

-- UI
local function onEditorGui()
  if editor.beginWindow(toolWindowName, toolName) then
    -- Base
    im.TextUnformatted("Base Object")
    im.Indent()
    local baseStr = "none"
    if validObj(baseId) then
      local obj = scenetree.findObjectById(baseId)
      baseStr = string.format("%s [%s]", tostring(obj:getName()), tostring(baseId))
      if editor.uiIconImageButton(editor.icons.check_circle, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0])) then
        editor.selectEditMode(editor.editModes.objectSelect)
        editor.selectObjectById(baseId)
        editor.fitViewToSelectionSmooth()
      end
      im.SameLine()
    end
    im.TextUnformatted(baseStr)
    im.SameLine()
    if im.Button("Pick From Selection##base") then
      local id = getFirstSelection()
      if id then baseId = id; lastError = nil else lastError = "Select one object in the SceneTree first." end
    end
    im.Unindent()

    im.Separator()

    -- Targets
    im.TextUnformatted("Target Objects")
    im.Indent()
    im.TextUnformatted(string.format("Targets: %d", #targetIds))
    im.SameLine()
    if im.Button("Use Current Selection##targets") then
      targetIds = getSelectionList()
      lastError = nil
    end
    im.SameLine()
    if im.Button("Clear##targets") then
      table.clear(targetIds)
    end

    local refId = (#targetIds > 0) and targetIds[1] or getFirstSelection()
    if not refId then im.BeginDisabled() end
    if im.Button("Use same Class") then
      if refId then targetIds = findAllSame(refId, false) end
    end
    im.SameLine()
    if im.Button("Use same TSStatic Mesh") then
      if refId then targetIds = findAllSame(refId, true) end
    end
    if not refId then
      im.EndDisabled()
      im.SameLine()
      im.TextColored(im.ImVec4(1, 1, 0, 1), "Pick a reference (target or selection)")
    end
    im.Unindent()

    im.Separator()

    -- Options
    im.TextUnformatted("Options")
    im.Indent()
    im.Checkbox("Apply Target Rotation", includeRotation)
    if not includeRotation[0] then
      im.Checkbox("Relative Rotation (target * base)", useRelativeRotation)
      im.tooltip("When not aligning to target, compose rotations as targetRot * baseRot.")
    end
    im.Checkbox("Apply Target Scale", includeScale)
    im.Checkbox("Put Copies Into New Folder", useSimGroup)
    im.Checkbox("Select Created", selectCreated)
    im.Unindent()

    im.Separator()

    -- Target local offsets
    im.TextUnformatted("Target Local Offset (m)")
    im.Indent()
    im.PushItemWidth(120)
    im.SliderFloat("Local X##lox", offsetX, -50, 50, "%.2f")
    im.SameLine()
    im.SliderFloat("Local Y##loy", offsetY, -50, 50, "%.2f")
    im.SameLine()
    im.SliderFloat("Local Z##loz", offsetZ, -50, 50, "%.2f")
    im.PopItemWidth()
    im.Unindent()

    im.Separator()

    local canCreate = validObj(baseId) and (#targetIds > 0)
    if not canCreate then im.BeginDisabled() end
    if im.Button("Create Copies") then runCreate() end
    if not canCreate then im.EndDisabled() end
    if lastError then
      im.SameLine()
      im.TextColored(im.ImVec4(1, 1, 0, 1), lastError)
    end

    -- Live preview
    if #targetIds > 0 then
      local tdata = buildTransformData(targetIds, baseId) or {}
      local color = ColorF(0.2, 0.8, 1, 0.7)
      for _, td in ipairs(tdata) do
        if td.pos and td.transform then
          local lOff = getLocalOffsetVector(td, offsetX[0], offsetY[0], offsetZ[0])
          debugDrawer:drawSphere(td.pos + lOff, 0.25, color)
        end
      end
    end
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.addWindowMenuItem(toolName, onWindowMenuItem)
  editor.registerWindow(toolWindowName, im.ImVec2(560, 520))
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
return M