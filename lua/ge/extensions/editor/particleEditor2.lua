-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'editor_particleEditor2'
local im = ui_imgui
local imUtils = require('ui/imguiUtils')

local toolWindowName = 'particleEditor2'
local renderViewName = 'particleEditor2View'
local emitterFile = 'art/shapes/particles/managedParticleEmitterData.json'
local particleFile = 'art/shapes/particles/managedParticleData.json'
local maxParticlesPerEmitter = 4

local emitters = {}
local particleDatas = {}
local currentEmitter
local currentParticle

local emitterInspector
local particleInspector
local emitterInspectorState = {}
local particleInspectorState = {}

local emitterHiddenFields = {name = true, persistentId = true, parentGroup = true, internalName = true, particles = true}
local particleHiddenFields = {name = true, persistentId = true, parentGroup = true, internalName = true}

local previewActive = false
local previewNode
local previewRv
local previewWidth = 400
local previewHeight = 400
local camYaw = 0
local camPitch = 0.35
local camDist = 8
local previewNodePos = vec3(0, 0, 0)
local camTarget = vec3(previewNodePos)
local previewViewMask = 30
local gridHalfSize = 5
local gridStep = 0.5
local bgColor = {20, 20, 20}

local function clamp(v, lo, hi)
  if v < lo then return lo elseif v > hi then return hi else return v end
end

local function updateDatablockList()
  emitters = {}
  particleDatas = {}
  local set = Sim.getDataBlockSet()
  for index = 0, set:size() - 1 do
    local dataBlock = set:at(index)
    local className = dataBlock:getClassName()
    if className == 'ParticleEmitterData' then
      table.insert(emitters, Sim.upcast(dataBlock))
    elseif className == 'ParticleData' then
      table.insert(particleDatas, Sim.upcast(dataBlock))
    end
  end
end

local function getEmitterParticleNames(emitter)
  local names = {}
  if not emitter then return names end
  for name in (emitter:getField('particles', '') or ''):gmatch('[^\t]+') do
    table.insert(names, name)
  end
  return names
end

local function setEmitterParticleNames(emitter, names)
  emitter:setField('particles', '', table.concat(names, '\t'))
  editor.setDataBlockDirty(emitter)
  emitter:reload()
end

local function selectEmitter(emitter)
  currentEmitter = emitter
  currentParticle = nil
  if emitter then
    local names = getEmitterParticleNames(emitter)
    if names[1] then currentParticle = scenetree.findObject(names[1]) end
    if previewNode then
      previewNode:setField('emitter', 0, emitter:getName())
      previewNode:setEmitterDataBlock(emitter)
    end
  end
end

local function buildInspectorFields(objectId, hiddenFields)
  local raw = editor.getFields(objectId)
  local fields = {}
  if not raw then return fields end
  for name, field in pairs(raw) do
    field.name = field.name or name
    field.hideInInspector = hiddenFields[field.name] or false
    if field.isArray and field.fields then
      for _, sub in pairs(field.fields) do
        sub.value = {}
        for i = 1, (field.elementCount or 0) do
          sub.value[i] = editor.getFieldValue(objectId, sub.name, i - 1)
        end
      end
    elseif (field.elementCount or 1) > 1 then
      field.value = {}
      for i = 1, field.elementCount do
        field.value[i] = editor.getFieldValue(objectId, field.name, i - 1)
      end
    else
      field.value = editor.getFieldValue(objectId, field.name, 0)
    end
    table.insert(fields, field)
  end
  return fields
end

local function ensureInspectorFields(state, object, hiddenFields)
  local objectId = object and object:getID() or nil
  if state.objectId ~= objectId then
    state.fields = objectId and buildInspectorFields(objectId, hiddenFields) or {}
    state.objectId = objectId
  end
end

local function makeFieldSetter(getObject)
  return function(fieldName, newValue, arrayIndex, fieldInfo, editEnded)
    local object = getObject()
    if not object then return end
    local datablockArrayIndex = 0
    if fieldInfo and fieldInfo.elementCount and fieldInfo.elementCount > 1 and arrayIndex and arrayIndex > 0 then
      datablockArrayIndex = arrayIndex - 1
      if type(fieldInfo.value) == 'table' then fieldInfo.value[arrayIndex] = newValue end
    elseif fieldInfo then
      fieldInfo.value = newValue
    end
    editor.setFieldValue(object:getID(), fieldName, tostring(newValue), datablockArrayIndex)
    editor.setDataBlockDirty(object)
    object:reload()
  end
end

local function newEmitter()
  local name = Sim.getUniqueName('newEmitter')
  local id = editor.createDataBlock(name, 'ParticleEmitterData', 'DefaultEmitter', emitterFile)
  updateDatablockList()
  local emitter = scenetree.findObjectById(id)
  if emitter then
    emitter:reload()
    selectEmitter(Sim.upcast(emitter))
  end
end

local function newParticleForEmitter()
  if not currentEmitter then return end
  local names = getEmitterParticleNames(currentEmitter)
  if #names >= maxParticlesPerEmitter then return end
  local name = Sim.getUniqueName('newParticle')
  editor.createDataBlock(name, 'ParticleData', 'DefaultParticle', particleFile)
  updateDatablockList()
  table.insert(names, name)
  setEmitterParticleNames(currentEmitter, names)
  currentParticle = scenetree.findObject(name)
end

local function saveEmitter()
  if not currentEmitter then return end
  editor.saveDataBlockToFile(currentEmitter)
  for _, name in ipairs(getEmitterParticleNames(currentEmitter)) do
    local particle = scenetree.findObject(name)
    if particle then editor.saveDataBlockToFile(particle) end
  end
  editor.showNotification('Saved emitter ' .. currentEmitter:getName())
end

local function saveEmitterToLevel()
  if not currentEmitter then return end
  local levelPath = path.split(getMissionFilename())
  editor.saveDataBlockToFile(currentEmitter, levelPath .. emitterFile)
  for _, name in ipairs(getEmitterParticleNames(currentEmitter)) do
    local particle = scenetree.findObject(name)
    if particle then editor.saveDataBlockToFile(particle, levelPath .. particleFile) end
  end
  editor.showNotification('Saved emitter to level: ' .. levelPath .. emitterFile)
end

local function saveEmitterAs()
  if not currentEmitter then return end
  editor_fileDialog.saveFile(function(data)
    if data.filepath and data.filepath ~= '' then
      editor.saveDataBlockToFile(currentEmitter, data.filepath)
      editor.showNotification('Saved emitter to: ' .. data.filepath)
    end
  end, {{'JSON', '.json'}}, false, '/art/shapes/particles/')
end

local function deleteEmitter()
  if not currentEmitter or currentEmitter:getName() == 'DefaultEmitter' then return end
  editor.removeDataBlockFromFile(currentEmitter)
  updateDatablockList()
  selectEmitter(emitters[1])
end

local function deleteParticle(name)
  if not currentEmitter then return end
  local names = getEmitterParticleNames(currentEmitter)
  if #names <= 1 then return end
  for i, particleName in ipairs(names) do
    if particleName == name then
      table.remove(names, i)
      break
    end
  end
  setEmitterParticleNames(currentEmitter, names)
  currentParticle = names[1] and scenetree.findObject(names[1]) or nil
end

local function createPreviewNode()
  if previewNode then return end
  previewNode = worldEditorCppApi.createObject('ParticleEmitterNode')
  previewNode:setField('dataBlock', 0, 'lightExampleEmitterNodeData1')
  previewNode:registerObject('')
  previewNode:setField('name', 0, 'particleEditor2PreviewNode')
  local forward = editor.getCamera():getTransform():getColumn(1) * 7
  previewNodePos = core_camera.getPosition() + forward
  previewNode:setPosition(previewNodePos)
  previewNode:setRenderEnabled(false)
  camTarget = vec3(previewNodePos)
  camYaw = 0
  camPitch = 0.35
  camDist = 8
  if scenetree.MissionGroup then scenetree.MissionGroup:addObject(previewNode) end
  if currentEmitter then
    previewNode:setField('emitter', 0, currentEmitter:getName())
    previewNode:setEmitterDataBlock(currentEmitter)
  end
end

local function destroyPreview()
  if previewNode then
    previewNode:delete()
    previewNode = nil
  end
  if previewRv then
    RenderViewManagerInstance:destroyView(previewRv)
    previewRv = nil
  end
end

local function cameraForward()
  local cosPitch = math.cos(camPitch)
  return vec3(math.sin(camYaw) * cosPitch, math.cos(camYaw) * cosPitch, -math.sin(camPitch))
end

local function updateRenderView()
  if previewWidth < 2 or previewHeight < 2 then return end
  previewRv = RenderViewManagerInstance:getOrCreateView(renderViewName)
  previewRv.luaOwned = true
  previewRv.namedTexTargetColor = renderViewName
  previewRv.debugDrawBeforeObjects = true
  previewRv.clearColor = ColorI(bgColor[1], bgColor[2], bgColor[3], 255)
  previewRv:maskSet(previewViewMask)
  previewRv.renderCubemap = false
  previewRv.renderEditorIcons = false
  previewRv.renderEditorGizmo = false
  previewRv:clearFocusObjects()
  if previewNode then
    local emitter = scenetree.findObjectById(previewNode:getParticleEmitterId())
    if emitter then
      emitter:setRenderEnabled(false)
      previewRv:addFocusObject(emitter)
    end
  end
  local aspectRatio = previewWidth / previewHeight
  local fov = 60
  previewRv.resolution = Point2I(previewWidth, previewHeight)
  previewRv.viewPort = RectI(0, 0, previewWidth, previewHeight)
  previewRv.frustum = Frustum.construct(false, math.rad(fov), aspectRatio, 0.05, 2000)
  previewRv.fov = fov
  local forward = cameraForward()
  local camPos = camTarget - forward * camDist
  local rot = quat(0, 0, 0, 1)
  rot:setFromDir(forward, vec3(0, 0, 1))
  local mat = QuatF(rot.x, rot.y, rot.z, rot.w):getMatrix()
  mat:setPosition(camPos)
  previewRv.cameraMatrix = mat
end

local function handlePreviewInput()
  if not im.IsItemHovered() then return end
  local io = im.GetIO()
  if im.IsMouseDragging(1) then
    local delta = im.GetMouseDragDelta(1)
    im.ResetMouseDragDelta(1)
    camYaw = camYaw + delta.x * 0.01
    camPitch = clamp(camPitch + delta.y * 0.01, -1.5, 1.5)
  end
  if im.IsMouseDragging(2) then
    local delta = im.GetMouseDragDelta(2)
    im.ResetMouseDragDelta(2)
    local forward = cameraForward()
    local right = forward:cross(vec3(0, 0, 1)):normalized()
    local up = right:cross(forward):normalized()
    local panScale = camDist * 0.002
    camTarget = camTarget + right * (-delta.x * panScale) + up * (delta.y * panScale)
  end
  if io.MouseWheel ~= 0 then
    camDist = clamp(camDist - io.MouseWheel * 0.5, 0.5, 200)
  end
  if im.IsMouseDoubleClicked(0) and previewNode then
    local pos = previewNode:getPosition()
    camTarget = vec3(pos.x, pos.y, pos.z)
    camDist = 8
  end
end

local function drawPreview(paneWidth)
  im.BeginChild1('particleEditor2Preview', im.ImVec2(paneWidth, 0), true)
  local avail = im.GetContentRegionAvail()
  previewWidth = math.max(2, math.floor(avail.x))
  previewHeight = math.max(2, math.floor(avail.y))
  if previewRv then
    local texObj = imUtils.texObj('#' .. renderViewName)
    im.Image(texObj.texId, im.ImVec2(previewWidth, previewHeight))
    handlePreviewInput()
  end
  im.EndChild()
end

local function drawToolbar()
  im.PushItemWidth(im.GetContentRegionAvailWidth() - 4 * (24 * im.uiscale[0]))
  if im.BeginCombo('##emitterSelect', currentEmitter and currentEmitter:getName() or '<none>') then
    for _, emitter in ipairs(emitters) do
      local selected = currentEmitter and currentEmitter:getID() == emitter:getID()
      if im.Selectable1(emitter:getName(), selected) then
        selectEmitter(emitter)
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()
  local buttonSize = im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0])
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.add_circle, buttonSize) then newEmitter() end
  im.tooltip('New emitter')
  im.SameLine()
  if editor.uiIconImageButton(editor.icons.material_save_current, buttonSize) then saveEmitter() end
  im.tooltip('Save emitter to its file')
  im.SameLine()
  local deleteDisabled = not currentEmitter or currentEmitter:getName() == 'DefaultEmitter'
  if deleteDisabled then im.BeginDisabled() end
  if editor.uiIconImageButton(editor.icons.delete, buttonSize) then deleteEmitter() end
  im.tooltip('Delete emitter')
  if deleteDisabled then im.EndDisabled() end
end

local function drawEmitterParticleList()
  if not currentEmitter then return end
  im.TextUnformatted('Particles')
  local names = getEmitterParticleNames(currentEmitter)
  local buttonSize = im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0])
  for i, name in ipairs(names) do
    im.PushID1('particleSlot' .. i)
    im.PushItemWidth(im.GetContentRegionAvailWidth() - 2 * (24 * im.uiscale[0]))
    if im.BeginCombo('##particleSlot', name) then
      for _, particle in ipairs(particleDatas) do
        if im.Selectable1(particle:getName(), particle:getName() == name) then
          names[i] = particle:getName()
          setEmitterParticleNames(currentEmitter, names)
          currentParticle = scenetree.findObject(names[i])
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()
    im.SameLine()
    if editor.uiIconImageButton(editor.icons.edit, buttonSize) then
      currentParticle = scenetree.findObject(name)
    end
    im.tooltip('Edit this particle')
    im.SameLine()
    local removeDisabled = #names <= 1
    if removeDisabled then im.BeginDisabled() end
    if editor.uiIconImageButton(editor.icons.remove_circle, buttonSize) then
      deleteParticle(name)
    end
    im.tooltip('Remove from emitter')
    if removeDisabled then im.EndDisabled() end
    im.PopID()
  end
  if #names < maxParticlesPerEmitter then
    if editor.uiIconImageButton(editor.icons.add_circle, buttonSize) then newParticleForEmitter() end
    im.tooltip('Add a new particle to this emitter')
  end
  im.Separator()
end

local function drawControls()
  im.BeginChild1('particleEditor2Controls', im.ImVec2(0, 0), false)
  drawToolbar()
  im.Separator()
  im.TextUnformatted('Background')
  im.SameLine()
  if editor.uiColorEdit3('##particleEditor2Bg', editor.getTempFloatArray3_TableTable({bgColor[1] / 255, bgColor[2] / 255, bgColor[3] / 255}), im.ColorEditFlags_NoInputs) then
    local val = editor.getTempFloatArray3_TableTable()
    bgColor = {val[1] * 255, val[2] * 255, val[3] * 255}
  end
  im.Separator()
  if not currentEmitter then
    im.TextUnformatted('Create or select an emitter.')
    im.EndChild()
    return
  end
  if im.BeginTabBar('particleEditor2Tabs') then
    if im.BeginTabItem('Emitter') then
      drawEmitterParticleList()
      ensureInspectorFields(emitterInspectorState, currentEmitter, emitterHiddenFields)
      emitterInspector:inspectorGui(emitterInspectorState.fields)
      im.EndTabItem()
    end
    if im.BeginTabItem('Particle') then
      local names = getEmitterParticleNames(currentEmitter)
      im.PushItemWidth(-1)
      if im.BeginCombo('##particleSelect', currentParticle and currentParticle:getName() or '<none>') then
        for _, name in ipairs(names) do
          local selected = currentParticle and currentParticle:getName() == name
          if im.Selectable1(name, selected) then
            currentParticle = scenetree.findObject(name)
          end
        end
        im.EndCombo()
      end
      im.PopItemWidth()
      im.Separator()
      if currentParticle then
        ensureInspectorFields(particleInspectorState, currentParticle, particleHiddenFields)
        particleInspector:inspectorGui(particleInspectorState.fields)
      else
        im.TextUnformatted('This emitter has no particle.')
      end
      im.EndTabItem()
    end
    im.EndTabBar()
  end
  im.EndChild()
end

local function drawMenuBar()
  if im.BeginMenuBar() then
    if im.BeginMenu('File') then
      if im.MenuItem1('New Emitter') then newEmitter() end
      if im.MenuItem1('Save Emitter') then saveEmitter() end
      if im.MenuItem1('Save Emitter As...') then saveEmitterAs() end
      if im.MenuItem1('Save Emitter To Level') then saveEmitterToLevel() end
      im.Separator()
      if im.MenuItem1('Delete Emitter') then deleteEmitter() end
      im.EndMenu()
    end
    im.EndMenuBar()
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, 'Particle Editor 2', im.WindowFlags_MenuBar) then
    drawMenuBar()
    local avail = im.GetContentRegionAvail()
    local paneWidth = math.max(50, math.floor(avail.x * 0.5))
    drawPreview(paneWidth)
    im.SameLine()
    drawControls()
  end
  editor.endWindow()
end

local function drawGrid()
  local origin = previewNodePos
  local col = ColorF(0.4, 0.4, 0.4, 0.5)
  local colAxis = ColorF(0.7, 0.7, 0.7, 0.7)
  debugDrawer:currentRenderViewMaskSet(previewViewMask)
  for i = -gridHalfSize, gridHalfSize, gridStep do
    local lineCol = (i == 0) and colAxis or col
    debugDrawer:drawLine(vec3(origin.x + i, origin.y - gridHalfSize, origin.z), vec3(origin.x + i, origin.y + gridHalfSize, origin.z), lineCol, true)
    debugDrawer:drawLine(vec3(origin.x - gridHalfSize, origin.y + i, origin.z), vec3(origin.x + gridHalfSize, origin.y + i, origin.z), lineCol, true)
  end
  debugDrawer:currentRenderViewMaskClear()
end

local function onPreRender()
  if previewActive and previewNode then drawGrid() end
end

local function onUpdate()
  if not editor or not editor.active then return end
  if previewActive then updateRenderView() end
end

local function onEditorToolWindowShow(windowName)
  if windowName ~= toolWindowName then return end
  previewActive = true
  updateDatablockList()
  createPreviewNode()
  if not currentEmitter and emitters[1] then
    selectEmitter(emitters[1])
  end
end

local function onEditorToolWindowHide(windowName)
  if windowName ~= toolWindowName then return end
  previewActive = false
  destroyPreview()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(900, 600))
  editor.addWindowMenuItem('Particle Editor 2', onWindowMenuItem, {groupMenuName = 'Experimental'})
  emitterInspector = require('editor/api/genericInspector')()
  emitterInspector:initialize(makeFieldSetter(function() return currentEmitter end))
  emitterInspector.valueInspector.selectionClassName = 'ParticleEmitterData'
  particleInspector = require('editor/api/genericInspector')()
  particleInspector:initialize(makeFieldSetter(function() return currentParticle end))
  particleInspector.valueInspector.selectionClassName = 'ParticleData'
end

local function onExtensionUnloaded()
  destroyPreview()
end

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui
M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.onEditorToolWindowShow = onEditorToolWindowShow
M.onEditorToolWindowHide = onEditorToolWindowHide
M.onExtensionUnloaded = onExtensionUnloaded

return M
