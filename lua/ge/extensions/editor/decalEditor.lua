-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_decalEditor'
local actionMapName = "DecalEditor"
local editModeName = "Edit Decal"
local toolWindowName = "decalEditor"
local roadRiverGui = extensions.editor_roadRiverGui
local im = ui_imgui
local minFloatValue = -1000000000
local maxFloatValue = 1000000000

local currentSelectionDuplicated = false

local selectedInstances = {}
local selectedTemplate
local activeTab = "Templates"

local originalSizes
local originalNormals
local originalTangents
local originalPositions
local originalGizmoPos

local hiddenTemplates = {"DummyDecal", "tireTrackDecal"}

local function isSelected(instance)
  return instance and selectedInstances[instance.id] == true
end

local debugDrawDistance = 250.0
local debugTextDistance = 50.0
local sphereAlpha = 0.25

local hoveredSphereId = nil

-- cache base colors per id (store rgb only, alpha applied at draw)
local colorCacheRGB = {}
local function baseRGBForId(id)
  local rgb = colorCacheRGB[id]
  if not rgb then
    local r = math.abs(math.sin(id * 12.9898)) % 1
    local g = math.abs(math.sin(id * 78.233 )) % 1
    local b = math.abs(math.sin(id * 45.164 )) % 1
    rgb = {r, g, b}
    colorCacheRGB[id] = rgb
  end
  return rgb[1], rgb[2], rgb[3]
end

local function dist2(ax, ay, az, bx, by, bz)
  local dx = ax - bx; local dy = ay - by; local dz = az - bz
  return dx*dx + dy*dy + dz*dz
end

local function vdot(a, b) return a.x*b.x + a.y*b.y + a.z*b.z end
local function vlen(v) return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z) end
local function vnorm(v)
  local l = vlen(v)
  if l > 0 then return vec3(v.x / l, v.y / l, v.z / l) end
  return vec3(0,0,1)
end

local function rayIntersectsSphere(rayOrigin, rayDir, center, radius)
  local oc = vec3(rayOrigin.x - center.x, rayOrigin.y - center.y, rayOrigin.z - center.z)
  local b = vdot(oc, rayDir)
  local c = vdot(oc, oc) - radius*radius
  local disc = b*b - c
  if disc < 0 then return nil end
  local s = math.sqrt(disc)
  local t = -b - s
  if t < 0 then t = -b + s end
  if t < 0 then return nil end
  return t
end

-- Spatial grid
local grid = {}
local gridCellSize = 50.0
local gridDirty = true
local lastDecalCount = -1

local function cellKey(ix, iy, iz)
  return tostring(ix) .. "|" .. tostring(iy) .. "|" .. tostring(iz)
end

local function gridInsert(inst)
  local s = gridCellSize
  local ix = math.floor(inst.position.x / s)
  local iy = math.floor(inst.position.y / s)
  local iz = math.floor(inst.position.z / s)
  local key = cellKey(ix, iy, iz)
  local bucket = grid[key]
  if not bucket then
    bucket = {}
    grid[key] = bucket
  end
  bucket[#bucket + 1] = inst
end

local function rebuildGrid()
  grid = {}
  local N = editor.getDecalInstanceVecSize()
  for i = 0, N - 1 do
    local inst = editor.getDecalInstance(i)
    if inst then
      gridInsert(inst)
    end
  end
  gridDirty = false
  lastDecalCount = N
end

local function forCellsInSphere(campos, radius, fn)
  local s = gridCellSize
  local minx = math.floor((campos.x - radius) / s)
  local maxx = math.floor((campos.x + radius) / s)
  local miny = math.floor((campos.y - radius) / s)
  local maxy = math.floor((campos.y + radius) / s)
  local minz = math.floor((campos.z - radius) / s)
  local maxz = math.floor((campos.z + radius) / s)
  for ix = minx, maxx do
    for iy = miny, maxy do
      for iz = minz, maxz do
        local bucket = grid[cellKey(ix, iy, iz)]
        if bucket then fn(bucket) end
      end
    end
  end
end

-- Per-frame visible list (from grid)
local debugVisibleIds = {}
local debugVisibleDist2 = {}
local debugVisibleCount = 0

local function buildVisibleListFromGrid(campos)
  debugVisibleCount = 0
  local radius = debugDrawDistance
  local dd2 = radius * radius
  forCellsInSphere(campos, radius, function(bucket)
    for j = 1, #bucket do
      local inst = bucket[j]
      local ok = true
      local id
      ok, id = pcall(function() return inst.id end)
      if ok and id then
        local live = editor.getDecalInstance(id)
        if live then
          local d2 = dist2(campos.x, campos.y, campos.z, live.position.x, live.position.y, live.position.z)
          if d2 <= dd2 then
            debugVisibleCount = debugVisibleCount + 1
            debugVisibleIds[debugVisibleCount] = id
            debugVisibleDist2[debugVisibleCount] = d2
          end
        else
          gridDirty = true
        end
      else
        gridDirty = true
      end
    end
  end)
end

local function pickSphereUnderMouse(hit, campos)
  hoveredSphereId = nil
  if not hit or not hit.pos then return end
  local rayOrigin = campos
  local rayDir = vnorm(vec3(hit.pos.x - rayOrigin.x, hit.pos.y - rayOrigin.y, hit.pos.z - rayOrigin.z))
  local bestT = math.huge
  for i = 1, debugVisibleCount do
    local id = debugVisibleIds[i]
    local inst = id and editor.getDecalInstance(id) or nil
    if inst then
      local r = inst.size * 0.5
      local t = rayIntersectsSphere(rayOrigin, rayDir, inst.position, r)
      if t and t < bestT then
        bestT = t
        hoveredSphereId = id
      end
    else
      gridDirty = true
    end
  end
end

local function drawDebugSpheres(campos)
  if sphereAlpha <= 0.0 then return end -- hide spheres and text if alpha is 0
  local tdist2 = debugTextDistance * debugTextDistance
  for i = 1, debugVisibleCount do
    local id = debugVisibleIds[i]
    local d2 = debugVisibleDist2[i]
    local inst = id and editor.getDecalInstance(id) or nil
    if inst then
      local r = inst.size * 0.5
      -- color with current alpha
      local rr, gg, bb = baseRGBForId(inst.id)
      local col = ColorF(rr, gg, bb, sphereAlpha)
      if hoveredSphereId and hoveredSphereId == inst.id then
        col = ColorF(1.0, 1.0, 0.25, sphereAlpha)
      elseif selectedInstances[inst.id] == true then
        col = ColorF(0.15, 0.85, 0.2, sphereAlpha)
      end
      debugDrawer:drawSphere(inst.position, r, col)
      if d2 <= tdist2 then
        local dist = math.sqrt(d2)
        debugDrawer:drawTextAdvanced(inst.position, String('Name: ' .. inst.template:getName()), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
        debugDrawer:drawTextAdvanced(inst.position, String('ID: ' .. tostring(inst.id)), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
        debugDrawer:drawTextAdvanced(inst.position, String('Dist: ' .. string.format("%0.1f", dist) .. ' m'), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192))
      end
    else
      gridDirty = true
    end
  end
end
-- END DEBUG SPHERES

local function displayMaterialPreview(material)
  local fileName = material:getField('diffuseMap', 0) -- This sometimes contains the path and sometimes not, so we have to check
  local actualFilenameWithPath = fileName

  -- Check if it exists with the other file ending
  local _, _, ext = path.split(fileName)
  local fileNameNoExt = string.sub(fileName, 1, -(ext:len() + 1))
  if not FS:fileExists(fileNameNoExt .. "png") and not FS:fileExists(fileNameNoExt .. "dds") then
    -- We have to create the correct path ourselves
    local materialFilename = material:getFilename()
    local folderPath = string.match(materialFilename, "(.*/)")
    actualFilenameWithPath = folderPath .. fileName
  end

  local image = editor.texObj(actualFilenameWithPath)
  if image.size.y > 0 and image.size.x > 0 then
    im.Image(
      image.texId,
      im.ImVec2(200, image.size.y / (image.size.x / 200)),
      im.ImVec2Zero,
      im.ImVec2One,
      im.ImColorByRGB(255,255,255,255).Value,
      im.ImColorByRGB(255,255,255,255).Value
    )
  end
end

local cubePoints =
{
  vec3(-0.5, -0.5, -0.5), vec3(-0.5, -0.5, 0.5), vec3(-0.5, 0.5, -0.5), vec3(-0.5, 0.5, 0.5),
  vec3(0.5, -0.5, -0.5), vec3(0.5, -0.5, 0.5), vec3(0.5, 0.5, -0.5), vec3(0.5, 0.5, 0.5)
}

local function updateGizmoPos()
  if tableIsEmpty(selectedInstances) then return end
  local firstInstance
  local averagePos = vec3(0,0,0)
  local count = 0
  for id, _ in pairs(selectedInstances) do
    local inst = editor.getDecalInstance(id)
    if inst then
      if not firstInstance then firstInstance = inst end
      averagePos = averagePos + inst.position
      count = count + 1
    else
      selectedInstances[id] = nil
    end
  end
  if count == 0 then return end
  averagePos = averagePos / count
  if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local and count == 1 then
    editor.setAxisGizmoTransform(firstInstance:getWorldMatrix())
  else
    -- Set gizmo to instance position
    local gizmoHelperTransform = MatrixF(true)
    gizmoHelperTransform:setPosition(averagePos)
    editor.setAxisGizmoTransform(gizmoHelperTransform)
  end
end

local function onEditorAxisGizmoAligmentChanged()
  if (not tableIsEmpty(selectedInstances)) and editor.editMode and (editor.editMode.displayName == editor.editModes.decalEditMode.displayName) then
    updateGizmoPos()
  end
end

local function drawSelectionBBox(transMatrix, color)
  -- 8 corner points of the box
  for i = 1, 8 do
    -- 3 lines per corner point
    for j = 1, 3 do
      local startPt = vec3(cubePoints[i].x, cubePoints[i].y, cubePoints[i].z);
      local endPt = vec3(startPt.x, startPt.y, startPt.z);
      if j == 1 then
        endPt.x = 0
      end
      if j == 2 then
        endPt.y = 0
      end
      if j == 3 then
        endPt.z = 0
      end
      startPt = transMatrix:mulP3F(startPt)
      endPt = transMatrix:mulP3F(endPt)
      debugDrawer:drawLine(startPt, endPt, color)
    end
  end
end

local function drawSelectedInstanceBBox(inst, color)
  -- if this SimObject is not a visual sceneobject with a transform, then ignore it
  local transMatrix = inst:getWorldMatrix()
  local bBox = inst:getWorldBox()
  local boxScale = bBox:getExtents()
  local boxCenter = bBox:getCenter()

  transMatrix:scale(boxScale)
  transMatrix:setPosition(boxCenter)
  drawSelectionBBox(transMatrix, color)
end

local function getTemplateById(id)
  for index=0, editor.getDecalTemplates():size()-1 do
    local template = editor.getDecalTemplates():at(index)
    if template:getID() == id then
      return template
    end
  end
end
-- isSelected defined earlier (to be used by debug functions)

local function selectSingleInstance(instance)
  selectedInstances = {}
  if instance then
    selectedInstances[instance.id] = true
  end
  updateGizmoPos()
end

local function addToSelection(instance)
  if instance then
    selectedInstances[instance.id] = true
    updateGizmoPos()
  end
end

local function removeFromSelection(instance)
  if instance then
    selectedInstances[instance.id] = nil
    updateGizmoPos()
  end
end

local function clearTemplateSelection()
  selectedTemplate = nil
  editor.clearObjectSelection()
end

-- Create template
local function createTemplateActionUndo(actionData)
  local template = scenetree.findObjectById(actionData.id)
  if selectedTemplate and selectedTemplate:getID() == template:getID() then
    clearTemplateSelection()
  end
  editor.deleteDecalTemplate(template)
end

local function createTemplateActionRedo(actionData)
  if actionData.id then
    SimObject.setForcedId(actionData.id)
  end
  actionData.id = editor.createDecalTemplate()
  if actionData.fields then
    editor.pasteFields(actionData.fields, actionData.id)
    editor.setFieldValue(actionData.id, "name", actionData.name)
  else
    actionData.fields = editor.copyFields(actionData.id)
    actionData.name = editor.getFieldValue(actionData.id, "name")
  end
end

-- Delete template
local function deleteTemplateActionUndo(actionData)
  SimObject.setForcedId(actionData.id)
  editor.createDecalTemplate()
  editor.pasteFields(actionData.fields, actionData.id)
  editor.setFieldValue(actionData.id, "name", actionData.name)
  local template = scenetree.findObjectById(actionData.id)

  for _,instanceData in ipairs(actionData.instancesData) do
    local instance = editor.addDecalInstanceWithTanForceId(instanceData.position, instanceData.normal,
                          instanceData.tangent, template, instanceData.size, instanceData.textureRectIdx, 3, 1, instanceData.id)
  end
  gridDirty = true
end

local function deleteTemplateActionRedo(actionData)
  local template = scenetree.findObjectById(actionData.id)

  if selectedTemplate and selectedTemplate:getID() == template:getID() then
    clearTemplateSelection()
  end
  editor.deleteDecalTemplate(template)
  gridDirty = true
end

-- Clear selection
local function clearSelectionActionUndo(actionData)
  selectedInstances = deepcopy(actionData.oldSelection)
  updateGizmoPos()
end

local function clearSelectionActionRedo(actionData)
  selectSingleInstance()
end

-- Add instance to Selection
local function addInstToSelectionActionUndo(actionData)
  removeFromSelection(actionData.instance)
end

local function addInstToSelectionActionRedo(actionData)
  addToSelection(actionData.instance)
end

-- Select single instance
local function selectSingleInstanceActionUndo(actionData)
  selectedInstances = deepcopy(actionData.oldSelection)
  updateGizmoPos()
end

local function selectSingleInstanceActionRedo(actionData)
  selectSingleInstance(actionData.instance)
end

-- Remove instance from Selection
local function removeInstFromSelectionActionUndo(actionData)
  addToSelection(actionData.instance)
end

local function removeInstFromSelectionActionRedo(actionData)
  removeFromSelection(actionData.instance)
end

-- Position instance
local function positionInstancesActionUndo(actionData)
  for id, oldPosition in pairs(actionData.oldPositions) do
    local instance = editor.getDecalInstance(id)
    instance.position = oldPosition
    editor.notifyDecalModified(instance)
  end
  updateGizmoPos()
  gridDirty = true
end

local function positionInstancesActionRedo(actionData)
  for id, newPosition in pairs(actionData.newPositions) do
    local instance = editor.getDecalInstance(id)
    instance.position = newPosition
    editor.notifyDecalModified(instance)
  end
  updateGizmoPos()
  gridDirty = true
end

-- Rotate instance
local function rotateInstancesActionUndo(actionData)
  for id, _ in pairs(actionData.oldTangents) do
    local instance = editor.getDecalInstance(id)
    instance.tangent = actionData.oldTangents[id]
    instance.normal = actionData.oldNormals[id]
    instance.position = actionData.oldPositions[id]
    editor.notifyDecalModified(instance)
  end
  updateGizmoPos()
  gridDirty = true
end

local function rotateInstancesActionRedo(actionData)
  for id, _ in pairs(actionData.newTangents) do
    local instance = editor.getDecalInstance(id)
    instance.tangent = actionData.newTangents[id]
    instance.normal = actionData.newNormals[id]
    instance.position = actionData.newPositions[id]
    editor.notifyDecalModified(instance)
  end
  updateGizmoPos()
  gridDirty = true
end

-- Change instance size
local function changeInstancesSizeActionUndo(actionData)
  for id, _ in pairs(actionData.oldSizes) do
    local instance = editor.getDecalInstance(id)
    instance.size = actionData.oldSizes[id]
    if actionData.oldPositions then
      instance.position = actionData.oldPositions[id]
    end
    editor.notifyDecalModified(instance)
  end
  gridDirty = true
end

local function changeInstancesSizeActionRedo(actionData)
  for id, _ in pairs(actionData.newSizes) do
    local instance = editor.getDecalInstance(id)
    instance.size = actionData.newSizes[id]
    if actionData.newPositions then
      instance.position = actionData.newPositions[id]
    end
    editor.notifyDecalModified(instance)
  end
  gridDirty = true
end

-- Change instance tiling
local function changeInstancesTilingActionUndo(actionData)
  for id, tiling in pairs(actionData.oldTilings) do
    local instance = editor.getDecalInstance(id)
    if instance then
      instance.tiling = Point2F(tiling.x, tiling.y)
      editor.notifyDecalModified(instance)
    end
  end
  gridDirty = true
end

local function changeInstancesTilingActionRedo(actionData)
  for id, tiling in pairs(actionData.newTilings) do
    local instance = editor.getDecalInstance(id)
    if instance then
      instance.tiling = Point2F(tiling.x, tiling.y)
      editor.notifyDecalModified(instance)
    end
  end
  gridDirty = true
end

-- Replace instance template (swap datablock by deleting and recreating the instance,
-- so the old datablock's baked geometry is freed cleanly)
local function recreateInstanceWithTemplate(data, templateId, textureRectIdx)
  local template = templateId and Sim.upcast(scenetree.findObjectById(templateId))
  if not template then return nil end
  local inst = editor.getDecalInstance(data.id)
  if inst then
    editor.deleteDecalInstance(inst)
  end
  local newInst = editor.addDecalInstanceWithTanForceId(data.position, data.normal, data.tangent,
                          template, 1, textureRectIdx, 3, 1, data.id)
  if newInst then
    newInst.size = data.size
    newInst.tiling = Point2F(data.tiling.x, data.tiling.y)
    editor.notifyDecalModified(newInst)
  end
  return newInst
end

local function replaceInstancesTemplateActionUndo(actionData)
  selectedInstances = {}
  for _, data in ipairs(actionData.instances) do
    local newInst = recreateInstanceWithTemplate(data, data.oldTemplateId, data.textureRectIdx)
    if newInst then selectedInstances[newInst.id] = true end
  end
  updateGizmoPos()
  gridDirty = true
end

local function replaceInstancesTemplateActionRedo(actionData)
  selectedInstances = {}
  for _, data in ipairs(actionData.instances) do
    local newInst = recreateInstanceWithTemplate(data, actionData.newTemplateId, 0)
    if newInst then selectedInstances[newInst.id] = true end
  end
  updateGizmoPos()
  gridDirty = true
end

local function replaceSelectedInstancesWithTemplate()
  if not selectedTemplate then return end
  local instances = {}
  for id, _ in pairs(selectedInstances) do
    local inst = editor.getDecalInstance(id)
    if inst then
      table.insert(instances, {
        id = id,
        position = inst.position,
        normal = inst.normal,
        tangent = inst.tangent,
        size = inst.size,
        tiling = {x = inst.tiling.x, y = inst.tiling.y},
        textureRectIdx = inst.textureRectIdx,
        oldTemplateId = inst.template:getID()
      })
    end
  end
  if tableIsEmpty(instances) then return end
  editor.history:commitAction("ReplaceDecalInstancesTemplate",
              {instances = instances, newTemplateId = selectedTemplate:getID()},
              replaceInstancesTemplateActionUndo, replaceInstancesTemplateActionRedo)
end

-- Delete instance
local function deleteInstanceActionUndo(actionData)
  selectedInstances = {}
  for _,instanceData in ipairs(actionData.instancesData) do
    local instance = editor.addDecalInstanceWithTanForceId(instanceData.position, instanceData.normal, instanceData.tangent, instanceData.template, instanceData.size, instanceData.textureRectIdx, 3, 1, instanceData.id)
    selectedInstances[instance.id] = true
  end
  updateGizmoPos()
  gridDirty = true
end

local function deleteInstanceActionRedo(actionData)
  for _,instanceData in ipairs(actionData.instancesData) do
    local instance = editor.getDecalInstance(instanceData.id)
    editor.deleteDecalInstance(instance)
  end
  selectSingleInstance()
  updateGizmoPos()
  gridDirty = true
end

-- Create instance
local function createInstanceActionUndo(actionData)
  local instance = editor.getDecalInstance(actionData.instanceData.id)
  if isSelected(instance) then
    selectSingleInstance()
  end
  editor.deleteDecalInstance(instance)
  updateGizmoPos()
  gridDirty = true
end

local function createInstanceActionRedo(actionData)
  local instance
  if actionData.instanceData.id then
    instance = editor.addDecalInstanceWithTanForceId(actionData.instanceData.position, actionData.instanceData.normal,
                            actionData.instanceData.tangent, actionData.instanceData.template, 1,
                            actionData.instanceData.textureRectIdx, 3, 1, actionData.instanceData.id)
  else
    instance = editor.addDecalInstance(actionData.instanceData.position, actionData.instanceData.normal,
                            0, actionData.instanceData.template, 1,
                            actionData.instanceData.textureRectIdx, 3, 1)
  end
  actionData.instanceData.id = instance.id
  actionData.instanceData.tangent = instance.tangent
  actionData.instanceData.textureRectIdx = instance.textureRectIdx
  selectSingleInstance(instance)
  updateGizmoPos()
  gridDirty = true
end

-- Duplicate instances
local function duplicateInstancesActionUndo(actionData)
  for id, instanceData in pairs(actionData.instancesData) do
    local instance = editor.getDecalInstance(id)
    editor.deleteDecalInstance(instance)
  end
  gridDirty = true
end

local function duplicateInstancesActionRedo(actionData)
  selectedInstances = {}
  for id, instanceData in pairs(actionData.instancesData) do
    local instance = editor.addDecalInstanceWithTanForceId(instanceData.position, instanceData.normal, instanceData.tangent, instanceData.template, instanceData.size, instanceData.textureRectIdx, 3, 1, instanceData.id)
    selectedInstances[instance.id] = true
  end
  gridDirty = true
end

local templateSelectionIndex = im.IntPtr(0)
local function displayTemplates()
  if not selectedTemplate then
    templateSelectionIndex = im.IntPtr(-1)
  end

  if editor.uiIconImageButton(editor.icons.add_circle, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0]), nil, nil, nil) then
    editor.history:commitAction("CreateDecalTemplate", {}, createTemplateActionUndo, createTemplateActionRedo)
  end
  im.tooltip("Create Decal Template")
  im.SameLine()

  local disabled = false
  if not selectedTemplate then im.BeginDisabled() disabled = true end
  if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0]), nil, nil, nil) then
    local instancesData = {}
    for index=0, editor.getDecalInstanceVecSize() - 1 do
      local inst = editor.getDecalInstance(index)
      if inst and (inst.template:getName() == selectedTemplate:getName()) then
        local instance = {position = inst.position, normal = inst.normal, tangent = inst.tangent,
                          size = inst.size / inst.template.size,
                          textureRectIdx = inst.textureRectIdx, id = inst.id}
        table.insert(instancesData, instance)
      end
    end
    editor.history:commitAction("DeleteDecalTemplate",
                {fields = editor.copyFields(selectedTemplate:getID()), id = selectedTemplate:getID(),
                name = editor.getFieldValue(selectedTemplate:getID(), "name"), instancesData = instancesData},
                deleteTemplateActionUndo, deleteTemplateActionRedo)
    selectedTemplate = nil
  end
  if disabled then im.EndDisabled() disabled = false end
  im.tooltip("Delete Template")
  im.SameLine()

  if not selectedTemplate or not editor.isDecalDirty(selectedTemplate) then im.BeginDisabled() disabled = true end
  if editor.uiIconImageButton(editor.icons.material_save_current, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0]), nil, nil, nil) then
    editor.saveDecal(selectedTemplate)
  end
  if disabled then im.EndDisabled() disabled = false end
  im.tooltip("Save current Template")
  im.SameLine()

  if editor.uiIconImageButton(editor.icons.material_save_all, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0]), nil, nil, nil) then
    editor.saveDecals()
  end
  im.tooltip("Save all Templates")

  if editor.hasDirtyDecalTemplates() then
    im.SameLine()
    im.TextColored(im.ImVec4(1, 0.3, 0, 1), "< Decal Templates not saved")
  end

  local templates = {}
  local names = {}
  for index=0, editor.getDecalTemplates():size()-1 do
    local template = editor.getDecalTemplates():at(index)
    local name = template:__tostring()
    if not tableContains(hiddenTemplates, name) then
      table.insert(templates, template)
      if editor.isDecalDirty(template) then
        name = name .. "*"
      end
      table.insert(names, name)
    end
  end

  local avail = im.GetContentRegionAvail()
  im.PushItemWidth(avail.x)
  if im.ListBox1("", templateSelectionIndex, im.ArrayCharPtrByTbl(names), table.getn(names), avail.y/21) then
    editor.selectObjectById(templates[templateSelectionIndex[0]+1]:getID())
    selectedTemplate = Sim.upcast(templates[templateSelectionIndex[0]+1])
    updateGizmoPos()
  end
end

local function clickedOnInstance(instance)
  local oldSelection = deepcopy(selectedInstances)
  if not instance then
    if not tableIsEmpty(selectedInstances) then
      editor.history:commitAction("ClearDecalSelection", {oldSelection = oldSelection}, clearSelectionActionUndo, clearSelectionActionRedo)
    end
    return
  end

  if editor.keyModifiers.ctrl then
    if isSelected(instance) then
      editor.history:commitAction("RemoveDecalInstFromSelection", {instance = instance}, removeInstFromSelectionActionUndo, removeInstFromSelectionActionRedo)
    else
      editor.history:commitAction("AddDecalInstToSelection", {instance = instance}, addInstToSelectionActionUndo, addInstToSelectionActionRedo)
    end
  else
    if not (isSelected(instance) and tableSize(selectedInstances) == 1) then
      editor.history:commitAction("SelectSingleInst", {instance = instance, oldSelection = oldSelection}, selectSingleInstanceActionUndo, selectSingleInstanceActionRedo)
    end
  end
end

local function onDeleteSelection()
  local instancesData = {}
  for id, _ in pairs(selectedInstances) do
    local selectedInstance = editor.getDecalInstance(id)
    if selectedInstance then
      local instance = {
        position = selectedInstance.position,
        normal = selectedInstance.normal,
        tangent = selectedInstance.tangent,
        template = deepcopy(selectedInstance.template),
        size = selectedInstance.size / selectedInstance.template.size,
        textureRectIdx = selectedInstance.textureRectIdx,
        id = id
      }
      table.insert(instancesData, instance)
    else
      selectedInstances[id] = nil
    end
  end
  editor.history:commitAction("DeleteDecalInstance", {instancesData = instancesData}, deleteInstanceActionUndo, deleteInstanceActionRedo)
end

local function focusCameraOnInstance(instance)
  if not instance then return end
  local targetPos = vec3(instance.position)
  local dist = math.max(instance.size, 1.0) * 2.5
  local camPos = targetPos + vec3(instance.normal) * dist
  local rot = quatFromDir(targetPos - camPos)
  core_camera.setPosRot(0, camPos.x, camPos.y, camPos.z, rot.x, rot.y, rot.z, rot.w)
end

local setWidth = true
local settingPosition = false
local position = im.ArrayFloat(3)
local size = im.FloatPtr(0)
local originalPosition
local input4FloatValue = im.ArrayFloat(4)
local settingTiling = false
local tiling = im.ArrayFloat(2)
local originalTilingValue

local function displayInstances()
  local instances = {}

  for index=0, editor.getDecalInstanceVecSize()-1 do
    local inst = editor.getDecalInstance(index)
    if inst then
      if not instances[inst.template:__tostring()] then
        instances[inst.template:__tostring()] = {}
      end
      table.insert(instances[inst.template:__tostring()], inst)
    end
  end
  local templateNamesSorted = {}
  for templateName, templateInstances in pairs(instances) do
    table.insert(templateNamesSorted, templateName)
  end
  table.sort(templateNamesSorted)

  local disabled = false
  if tableIsEmpty(selectedInstances) then im.BeginDisabled() disabled = true end
  if editor.uiIconImageButton(editor.icons.delete, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0]), nil, nil, nil) then
    onDeleteSelection()
  end
  if disabled then im.EndDisabled() end
  im.tooltip("Delete Instance")

  im.BeginChild1("Instances", im.ImVec2(0,300), true)
  for _, templateName in ipairs(templateNamesSorted) do
    if im.TreeNode1(templateName) then
      for _, instance in ipairs(instances[templateName]) do
        local flags = bit.bor(im.TreeNodeFlags_Leaf, isSelected(instance) and im.TreeNodeFlags_Selected or 0)
        if im.TreeNodeEx1(instance.id .. " " .. templateName .. '##'.. instance.id, flags) then
          im.TreePop()
        end
        if im.IsItemClicked() then
          clickedOnInstance(instance)
        end
        if im.IsItemHovered() and im.IsMouseDoubleClicked(0) then
          focusCameraOnInstance(instance)
        end
      end
      im.TreePop()
    end
  end
  im.EndChild()

  if tableSize(selectedInstances) == 1 then
    local selectedId
    for id, _ in pairs(selectedInstances) do
      selectedId = id
      break
    end

    local selectedInstance = editor.getDecalInstance(selectedId)
    if not selectedInstance then
      selectedInstances[selectedId] = nil
      return
    end

    im.BeginChild1("Instance Properties", im.ImVec2(0,0), true)
    im.Text("Instance Properties")

    local tmpl = selectedInstance.template
    local label = tmpl:__tostring()
    local material = tmpl.material and scenetree.findObject(tmpl.material) or nil
    if material then
      displayMaterialPreview(material)
    end

    local canReplace = selectedTemplate ~= nil
    if not canReplace then im.BeginDisabled() end
    if im.Button("Replace With Current Template") then
      replaceSelectedInstancesWithTemplate()
    end
    if not canReplace then im.EndDisabled() end
    if selectedTemplate then
      im.tooltip("Swap this decal's datablock to the selected template: " .. selectedTemplate:__tostring())
    else
      im.tooltip("Select a template in the Templates tab first")
    end

    im.Columns(2)
    if setWidth then
      im.SetColumnWidth(0, 80)
      setWidth = false
    end
    im.Text("Instance")
    im.NextColumn()
    im.Text(label)
    im.NextColumn()

    im.TextUnformatted("Id")
    im.NextColumn()
    im.TextUnformatted(tostring(selectedInstance.id))
    im.NextColumn()

    im.TextUnformatted("Uid")
    im.NextColumn()
    im.TextUnformatted(tostring(selectedInstance.uid))
    im.NextColumn()

    im.Text("Position")
    im.NextColumn()

    if not settingPosition then
      position[0] = selectedInstance.position.x
      position[1] = selectedInstance.position.y
      position[2] = selectedInstance.position.z
    end

    local positionSliderEditEnded = im.BoolPtr(false)
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    if editor.uiDragFloat3(string.format("##pos_%d_%s", selectedInstance.id, label), position, 0.1, minFloatValue, maxFloatValue,
                          "%0." .. editor.getPreference("ui.general.floatDigitCount") .. "f", 1, positionSliderEditEnded) then
      settingPosition = true
      if not originalPosition then
        originalPosition = vec3(position[0], position[1], position[2])
      end
    end
    im.PopItemWidth()

    if positionSliderEditEnded[0] then
      local oldPositions = {}
      local newPositions = {}
      oldPositions[selectedInstance.id] = originalPosition
      newPositions[selectedInstance.id] = vec3(position[0], position[1], position[2])
      editor.history:commitAction("PositionDecalInstances",
                  {oldPositions = oldPositions, newPositions = newPositions, id = selectedInstance.id},
                  positionInstancesActionUndo, positionInstancesActionRedo)
      originalPosition = nil
      settingPosition = false
    end

    im.NextColumn()
    im.Text("Rotation")
    local worldQuat = selectedInstance:getWorldMatrix():toQuatF()
    local euler = worldQuat:toEuler()

    input4FloatValue[0] = math.deg(euler.x)
    input4FloatValue[1] = math.deg(euler.y)
    input4FloatValue[2] = math.deg(euler.z)

    im.NextColumn()
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    if editor.uiInputFloat3(string.format("##rot_%d_%s", selectedInstance.id, label), input4FloatValue, "%.1f", im.InputTextFlags_EnterReturnsTrue, nil) then
      local decalRot = quatFromEuler(math.rad(input4FloatValue[0]), math.rad(input4FloatValue[1]), math.rad(input4FloatValue[2]))
      selectedInstance.normal = decalRot:__mul(vec3(0,0,1))
      selectedInstance.tangent = decalRot:__mul(vec3(1,0,0))
      editor.notifyDecalModified(selectedInstance)
      updateGizmoPos()
    end
    im.PopItemWidth()

    im.NextColumn()
    im.Text("Size")
    im.NextColumn()

    size = im.FloatPtr(selectedInstance.size)
    local originalSize = size[0]
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    if editor.uiInputFloat(string.format("##size_%d_%s", selectedInstance.id, label), size, 0.1, 1.0, "%0." .. editor.getPreference("ui.general.floatDigitCount") .. "f", nil) then
      local oldSizes = {}
      local newSizes = {}
      oldSizes[selectedInstance.id] = originalSize
      newSizes[selectedInstance.id] = size[0]
      editor.history:commitAction("ChangeDecalInstancesSize", {oldSizes = oldSizes, newSizes = newSizes}, changeInstancesSizeActionUndo, changeInstancesSizeActionRedo)
    end
    im.PopItemWidth()

    im.NextColumn()
    im.Text("Tiling")
    im.NextColumn()

    if not settingTiling then
      tiling[0] = selectedInstance.tiling.x
      tiling[1] = selectedInstance.tiling.y
    end

    local tilingEditEnded = im.BoolPtr(false)
    im.PushItemWidth(im.GetContentRegionAvailWidth())
    if editor.uiDragFloat2(string.format("##tiling_%d_%s", selectedInstance.id, label), tiling, 0.05, 0.0, maxFloatValue,
                          "%0." .. editor.getPreference("ui.general.floatDigitCount") .. "f", 1, tilingEditEnded) then
      settingTiling = true
      if not originalTilingValue then
        originalTilingValue = {x = selectedInstance.tiling.x, y = selectedInstance.tiling.y}
      end
      selectedInstance.tiling = Point2F(tiling[0], tiling[1])
      editor.notifyDecalModified(selectedInstance)
    end
    im.PopItemWidth()
    im.tooltip("Per-instance UV tile count. Set to 0 to inherit the template's tiling.")

    if tilingEditEnded[0] then
      local oldTilings = {}
      local newTilings = {}
      oldTilings[selectedInstance.id] = originalTilingValue or {x = tiling[0], y = tiling[1]}
      newTilings[selectedInstance.id] = {x = tiling[0], y = tiling[1]}
      editor.history:commitAction("ChangeDecalInstancesTiling", {oldTilings = oldTilings, newTilings = newTilings}, changeInstancesTilingActionUndo, changeInstancesTilingActionRedo)
      originalTilingValue = nil
      settingTiling = false
    end

    im.EndChild()
  end
end

local function onEditorInspectorHeaderGui(inspectorInfo)
  if not editor.editMode or (editor.editMode.displayName ~= editModeName) then
    return
  end

  if selectedTemplate and selectedTemplate.material then
    local material = scenetree.findObject(selectedTemplate.material)
    if material then
      displayMaterialPreview(material)
    end
  end
end

local function rotateAround(instance, euler, rotationPoint)
  local rot = quatFromEuler(euler.x, euler.y, euler.z)

  -- Rotate the decals
  if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local and tableSize(selectedInstances) == 1 then
    local gizmoTransform = editor.getAxisGizmoTransform()
    local rotation = gizmoTransform:toQuatF()

    instance.normal = quat(rotation):__mul(vec3(0,0,1))
    instance.tangent = quat(rotation):__mul(vec3(1,0,0))
  else
    local gizmoRot = rot
    instance.normal = gizmoRot:__mul(vec3(originalNormals[instance.id]))
    instance.tangent = gizmoRot:__mul(vec3(originalTangents[instance.id]))
  end

  -- Rotate the positions
  local point = vec3(originalPositions[instance.id].x, originalPositions[instance.id].y, originalPositions[instance.id].z)
  point = point - rotationPoint
  point = rot * point
  point = point + rotationPoint
  instance.position = point
  editor.notifyDecalModified(instance)
end

local function gizmoBeginDrag()
  -- Reset scale
  originalGizmoPos = editor.getAxisGizmoTransform():getColumn(3)

  if editor.keyModifiers.shift then
    local copiedInstances = {}
    for id, _ in pairs(selectedInstances) do
      local inst = editor.getDecalInstance(id)
      if inst then
        local copiedInstance = editor.addDecalInstanceWithTan(
          inst.position, inst.normal, inst.tangent, inst.template, 1, inst.textureRectIdx, 3, 1
        )
        copiedInstance.size = inst.size
        copiedInstances[copiedInstance.id] = true
      else
        selectedInstances[id] = nil
      end
    end
    selectedInstances = copiedInstances
    currentSelectionDuplicated = true
  end

  originalSizes = {}
  originalNormals = {}
  originalTangents = {}
  originalPositions = {}
  for id, _ in pairs(selectedInstances) do
    local inst = editor.getDecalInstance(id)
    if inst then
      originalSizes[id] = inst.size
      originalNormals[id] = inst.normal
      originalTangents[id] = inst.tangent
      originalPositions[id] = inst.position
    else
      selectedInstances[id] = nil
    end
  end
end

local function gizmoEndDrag()
  local newPositions = {}
  local newTangents = {}
  local newNormals = {}
  local newSizes = {}

  if currentSelectionDuplicated then
    local instancesData = {}
    for id, _ in pairs(selectedInstances) do
      local inst = editor.getDecalInstance(id)
      if inst then
        local data = {
          position = inst.position,
          normal = inst.normal,
          tangent = inst.tangent,
          template = deepcopy(inst.template),
          size = inst.size / inst.template.size,
          textureRectIdx = inst.textureRectIdx,
          id = id
        }
        instancesData[id] = data
        editor.deleteDecalInstance(inst)
      else
        selectedInstances[id] = nil
      end
    end
    editor.history:commitAction(
      "DuplicateDecalInstances",
      { instancesData = instancesData },
      duplicateInstancesActionUndo,
      duplicateInstancesActionRedo
    )
    currentSelectionDuplicated = false
  else
    for id, _ in pairs(selectedInstances) do
      local inst = editor.getDecalInstance(id)
      if inst then
        newPositions[id] = inst.position
        newTangents[id]  = inst.tangent
        newNormals[id]   = inst.normal
        newSizes[id]     = inst.size
      else
        selectedInstances[id] = nil
      end
    end

    if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
      editor.history:commitAction(
        "PositionDecalInstances",
        { oldPositions = originalPositions, newPositions = newPositions },
        positionInstancesActionUndo,
        positionInstancesActionRedo,
        true
      )
    elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
      editor.history:commitAction(
        "RotateDecalInstances",
        {
          oldNormals = originalNormals,
          oldTangents = originalTangents,
          oldPositions = originalPositions,
          newNormals = newNormals,
          newTangents = newTangents,
          newPositions = newPositions
        },
        rotateInstancesActionUndo,
        rotateInstancesActionRedo,
        true
      )
    elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
      editor.history:commitAction(
        "ChangeDecalInstancesSize",
        {
          oldSizes = originalSizes,
          oldPositions = originalPositions,
          newSizes = newSizes,
          newPositions = newPositions
        },
        changeInstancesSizeActionUndo,
        changeInstancesSizeActionRedo,
        true
      )
    end
  end

  originalSizes = nil
  originalNormals = nil
  originalTangents = nil
  originalPositions = nil
  originalGizmoPos = nil
  updateGizmoPos()
  gridDirty = true
end

local function scalePoint(point, scale)
  return vec3(point.x * scale, point.y * scale, point.z * scale)
end

local function drawProjectionArrow(decalInstance)
      local arrowLength = 2.0
      local bBox = decalInstance:getWorldBox()
      local arrowStartPos = bBox:getCenter()
      local arrowEndPos = bBox:getCenter() - decalInstance.normal * arrowLength
      local arrowColor = ColorI(0, 0, 255, 255)
      debugDrawer:drawArrow(arrowStartPos, arrowEndPos, arrowColor, false)
end

local function gizmoDragging()
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local delta = editor.getAxisGizmoTransform():getColumn(3) - originalGizmoPos
    for id, _ in pairs(selectedInstances) do
      local inst = editor.getDecalInstance(id)
      if inst then
        inst.position = originalPositions[id] + delta
        editor.notifyDecalModified(inst)
      else
        selectedInstances[id] = nil
      end
    end

  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    local euler = editor.getAxisGizmoTransform():toQuatF():toEuler()
    local rotPoint = editor.getAxisGizmoTransform():getColumn(3)

    for id, _ in pairs(selectedInstances) do
      local inst = editor.getDecalInstance(id)
      if inst then
        rotateAround(inst, euler, rotPoint)
      else
        selectedInstances[id] = nil
      end
    end

  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    local scale = editor.getAxisGizmoScale()
    local avgScale = (scale.x + scale.y) * 0.5

    for id, _ in pairs(selectedInstances) do
      local inst = editor.getDecalInstance(id)
      if inst then
        inst.size = (originalSizes[id] * avgScale)
        inst.position = originalGizmoPos + scalePoint((originalPositions[id] - originalGizmoPos), avgScale)
        editor.notifyDecalModified(inst)
      else
        selectedInstances[id] = nil
      end
    end
  end
end

local time = 0

local function onUpdate()
  local res = cameraMouseRayCast()
  local campos = core_camera.getPosition()

  -- Ensure grid up-to-date if decal count changed or flagged dirty
  local N = editor.getDecalInstanceVecSize()
  if gridDirty or N ~= lastDecalCount then
    rebuildGrid()
  end

  -- Build visible list from grid
  buildVisibleListFromGrid(campos)

  -- Hover/pick via spheres
  if res and res.pos and not (im.IsAnyItemHovered() or im.IsWindowHovered(im.HoveredFlags_AnyWindow)) then
    pickSphereUnderMouse(res, campos)
    if im.IsMouseClicked(0) then
      if not editor.isAxisGizmoHovered() then
        if hoveredSphereId then
          local hoveredInst = editor.getDecalInstance(hoveredSphereId)
          if hoveredInst then
            clickedOnInstance(hoveredInst)
          else
            hoveredSphereId = nil
            gridDirty = true
          end
        else
          if selectedTemplate and activeTab == "Templates" then
            local instanceData = {
              position = res.pos,
              normal   = res.normal,
              tangent  = 0,
              template = deepcopy(selectedTemplate)
            }
            editor.history:commitAction(
              "CreateDecalInstance",
              { instanceData = instanceData },
              createInstanceActionUndo,
              createInstanceActionRedo
            )
          end
        end
      end
    end
  end

  -- Draw spheres for all visible decals
  drawDebugSpheres(campos)

  if not tableIsEmpty(selectedInstances) then
    editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)
    editor.drawAxisGizmo()
  end
end

local function onExtensionLoaded()
  log('D', logTag, "initialized")
end

local function onActivate()
  log('I', logTag, "onActivate")
  clearTemplateSelection()
  editor.showWindow(toolWindowName)
end

local function onDeactivate()
  log('I', logTag, "onDeactivate")
  editor.hideWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.editModes.decalEditMode =
  {
    displayName = editModeName,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    onUpdate = onUpdate,
    onDeleteSelection = onDeleteSelection,
    actionMap = actionMapName,
    icon = editor.icons.create_decal,
    iconTooltip = "Decal Editor",
    auxShortcuts = {},
    hideObjectIcons = true
  }
  editor.editModes.decalEditMode.auxShortcuts[bit.bor(editor.AuxControl_Ctrl, editor.AuxControl_LMB)] = "Multiselection"
  editor.editModes.decalEditMode.auxShortcuts["Shift + Drag Gizmo"] = "Duplicate decals"
  editor.registerWindow(toolWindowName, im.ImVec2(400,600))
end

local function onEditorBeforeSaveLevel()
  editor.saveDecals()
end

local function onEditorInspectorFieldChanged(selectedIds, fieldName, fieldValue, arrayIndex)
  for i = 1, #selectedIds do
    local template = scenetree.findObjectById(selectedIds[i])
    if template:getClassName() == "DecalData" then
      scenetree.decalPersistMan:setDirty(template, editor.getDecalDataFilePath())

      -- Update the decal instances
      for index=0, editor.getDecalInstanceVecSize() - 1 do
        local inst = editor.getDecalInstance(index)
        if inst and (inst.template:getName() == template:getName()) then
          editor.notifyDecalModified(inst)
        end
      end
    end
  end
  if editor.editMode and (editor.editMode.displayName == editor.editModes.decalEditMode.displayName) then
    updateGizmoPos()
  end
end

local function onEditorGui()
  if not editor.editMode or (editor.editMode.displayName ~= editModeName) then
    return
  end

  if editor.beginWindow(toolWindowName, "Decal Editor", nil, true) then

    local saPtr = im.FloatPtr(sphereAlpha)
    if im.SliderFloat("Gizmo sphere alpha", saPtr, 0.0, 1.0, "%.2f") then
      sphereAlpha = saPtr[0]
    end

    if im.BeginTabBar("decal editor##") then
      if im.BeginTabItem("Templates") then
        activeTab = "Templates"
        displayTemplates()
        im.EndTabItem()
      end
      if im.BeginTabItem("Instances") then
        activeTab = "Instances"
        displayInstances()
        im.EndTabItem()
      end
      im.EndTabBar()
    end

  end
  editor.endWindow()
end

M.onEditorInitialized = onEditorInitialized
M.onExtensionLoaded = onExtensionLoaded
M.onEditorBeforeSaveLevel = onEditorBeforeSaveLevel
M.onEditorInspectorHeaderGui = onEditorInspectorHeaderGui
M.onEditorInspectorFieldChanged = onEditorInspectorFieldChanged
M.onEditorAxisGizmoAligmentChanged = onEditorAxisGizmoAligmentChanged
M.onEditorGui = onEditorGui

return M
