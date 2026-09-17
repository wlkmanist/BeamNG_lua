-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ffi = require('ffi')
local logTag = 'trafficGatedRoadsEditor'
local toolWindowName = 'trafficGatedRoadsEditor'
local editModeName = 'Edit Traffic Gated Roads'
local im = ui_imgui

local defaultFilePath = '/gameplay/trafficGatedRoads.json'
local filePath = defaultFilePath
local data = { spheres = {} }

-- Selection / drag state
local selectedIdx = nil
local nextId = 1
local mouseInfo = {}
local beginDragRadius = 1.0

-- UI buffers
local nameBuffer = im.ArrayChar(256, "")
local prevSelectedIdx = -1  -- sentinel: never a valid index
local snapToTerrain = im.BoolPtr(true)

-- ==================== gizmo ====================

local function allowGizmo()
  return editor.editMode and editor.editMode.displayName == editModeName
end

local function getSelectedSphere()
  if not selectedIdx then return nil end
  return data.spheres[selectedIdx]
end

local function updateGizmoFromSphere(sphere)
  local q = QuatF(sphere.quat[1], sphere.quat[2], sphere.quat[3], sphere.quat[4])
  local t = q:getMatrix()
  t:setPosition(vec3(sphere.pos[1], sphere.pos[2], sphere.pos[3]))
  editor.setAxisGizmoTransform(t)
end

local function beginDrag()
  local sphere = getSelectedSphere()
  if not sphere then return end
  beginDragRadius = sphere.radius
end

local function endDrag()
end

local function dragging()
  local sphere = getSelectedSphere()
  if not sphere then return end

  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then
    local p = vec3(editor.getAxisGizmoTransform():getColumn(3))
    if snapToTerrain[0] then
      local rayStart = p + vec3(0, 0, 50)
      local dist = castRayStatic(rayStart, vec3(0, 0, -1), 1000, true)
      if dist then
        p.z = (rayStart + vec3(0, 0, -1) * dist).z
      end
    end
    sphere.pos = {p.x, p.y, p.z}
    updateGizmoFromSphere(sphere)

  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then
    local gizmoTransform = editor.getAxisGizmoTransform()
    local rotation = QuatF(0, 0, 0, 1)
    rotation:setFromMatrix(gizmoTransform)
    sphere.quat = {rotation.x, rotation.y, rotation.z, rotation.w}

  elseif editor.getAxisGizmoMode() == editor.AxisGizmoMode_Scale then
    local scl = vec3(worldEditorCppApi.getAxisGizmoScale())
    local s
    if scl.x ~= 1 then
      s = scl.x
    elseif scl.y ~= 1 then
      s = scl.y
    elseif scl.z ~= 1 then
      s = scl.z
    else
      s = 1
    end
    if s < 0 then s = 0 end
    sphere.radius = beginDragRadius * s
  end
end

-- ==================== mouse ====================

local function updateMouseInfo()
  if core_forest and core_forest.getForestObject() then
    core_forest.getForestObject():disableCollision()
  end
  mouseInfo.camPos = core_camera.getPosition()
  local ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(ray.dir)
  mouseInfo.rayCast = cameraMouseRayCast()
  if core_forest and core_forest.getForestObject() then
    core_forest.getForestObject():enableCollision()
  end
  mouseInfo.valid = mouseInfo.rayCast ~= nil
  mouseInfo.down = im.IsMouseClicked(0) and not im.GetIO().WantCaptureMouse
end

local function mouseOverSpheres()
  if not mouseInfo.camPos or not mouseInfo.rayDir then return nil end
  local minDist = math.huge
  local closestIdx = nil
  for i, sphere in ipairs(data.spheres) do
    local pos = vec3(sphere.pos[1], sphere.pos[2], sphere.pos[3])
    local distToCam = (pos - mouseInfo.camPos):length()
    local rayDist = (pos - mouseInfo.camPos):cross(mouseInfo.rayDir):length() / mouseInfo.rayDir:length()
    if rayDist <= sphere.radius and distToCam < minDist then
      minDist = distToCam
      closestIdx = i
    end
  end
  return closestIdx
end

-- ==================== CRUD ====================

local function selectSphere(idx)
  selectedIdx = idx
  if idx and data.spheres[idx] then
    updateGizmoFromSphere(data.spheres[idx])
  end
end

local function addSphere()
  local pos = {0, 0, 0}
  local p
  if mouseInfo.rayCast then
    p = vec3(mouseInfo.rayCast.pos)
  elseif mouseInfo.camPos then
    p = vec3(mouseInfo.camPos)
  end
  if p then
    local rayStart = p + vec3(0, 0, 50)
    local dist = castRayStatic(rayStart, vec3(0, 0, -1), 1000, true)
    if dist then
      p.z = (rayStart + vec3(0, 0, -1) * dist).z
    end
    pos = {p.x, p.y, p.z}
  end
  local sphere = {
    id     = nextId,
    name   = "Sphere " .. nextId,
    pos    = pos,
    quat   = {0, 0, 0, 1},
    radius = 10,
  }
  nextId = nextId + 1
  table.insert(data.spheres, sphere)
  selectSphere(#data.spheres)
end

local function duplicateSphere()
  local src = getSelectedSphere()
  if not src then return end
  local pos = {src.pos[1], src.pos[2], src.pos[3]}
  if mouseInfo.rayCast then
    local p = vec3(mouseInfo.rayCast.pos)
    pos = {p.x, p.y, p.z}
  end
  local sphere = {
    id     = nextId,
    name   = "Sphere " .. nextId,
    pos    = pos,
    quat   = {src.quat[1], src.quat[2], src.quat[3], src.quat[4]},
    radius = src.radius,
  }
  nextId = nextId + 1
  table.insert(data.spheres, sphere)
  selectSphere(#data.spheres)
end

local function deleteSphere(idx)
  if not idx or not data.spheres[idx] then return end
  table.remove(data.spheres, idx)
  if selectedIdx == idx then
    selectedIdx = nil
  elseif selectedIdx and selectedIdx > idx then
    selectedIdx = selectedIdx - 1
  end
end

-- ==================== file I/O ====================

local function newData()
  data = { spheres = {} }
  filePath = defaultFilePath
  selectedIdx = nil
  nextId = 1
end

local function saveData(fp)
  if not fp then fp = filePath end
  jsonWriteFile(fp, data, true)
  filePath = fp
end

local function loadData(fp)
  if not fp then return end
  local loaded = jsonReadFile(fp)
  if not loaded then
    log('E', logTag, 'Unable to read file: ' .. tostring(fp))
    return
  end
  data = loaded
  if not data.spheres then data.spheres = {} end
  filePath = fp
  selectedIdx = nil
  nextId = 1
  for _, s in ipairs(data.spheres) do
    if s.id and s.id >= nextId then
      nextId = s.id + 1
    end
  end
end

-- ==================== GUI ====================

local function onEditorGui()
  if editor.beginWindow(toolWindowName, 'Traffic Gated Roads Editor', im.WindowFlags_MenuBar) then
    if im.BeginMenuBar() then
      if im.BeginMenu('File') then
        im.TextDisabled(filePath)
        im.Separator()
        if im.MenuItem1('New') then
          newData()
        end
        if im.MenuItem1('Open...') then
          editor_fileDialog.openFile(
            function(fileData) loadData(fileData.filepath) end,
            {{'JSON files', '.json'}},
            false,
            filePath
          )
        end
        if filePath == defaultFilePath then im.BeginDisabled() end
        if im.MenuItem1('Save') then
          saveData(filePath)
        end
        if filePath == defaultFilePath then im.EndDisabled() end
        if im.MenuItem1('Save As...') then
          editor_fileDialog.saveFile(
            function(fileData) saveData(fileData.filepath) end,
            {{'JSON files', '.json'}},
            false,
            filePath
          )
        end
        im.EndMenu()
      end
      im.EndMenuBar()
    end

    im.TextDisabled(filePath)

    if filePath == defaultFilePath then im.BeginDisabled() end
    im.PushStyleColor2(im.Col_Button, im.ImVec4(0.2, 0.7, 0.3, 1.0))
    im.PushStyleColor2(im.Col_ButtonHovered, im.ImVec4(0.3, 0.8, 0.4, 1.0))
    im.PushStyleColor2(im.Col_ButtonActive, im.ImVec4(0.1, 0.6, 0.2, 1.0))
    if im.Button("SAVE", im.ImVec2(im.GetContentRegionAvailWidth(), 30)) then
      saveData(filePath)
    end
    im.PopStyleColor(3)
    if filePath == defaultFilePath then im.EndDisabled() end

    if not editor.editMode or editor.editMode.displayName ~= editModeName then
      if im.Button("Switch to Traffic Gated Roads Editmode", im.ImVec2(im.GetContentRegionAvailWidth(), 0)) then
        editor.selectEditMode(editor.editModes.trafficGatedRoadsEditMode)
      end
    end

    -- Mouse state (needed for sphere placement and click-to-select)
    updateMouseInfo()

    -- 3D: draw all spheres
    for i, sphere in ipairs(data.spheres) do
      local pos = vec3(sphere.pos[1], sphere.pos[2], sphere.pos[3])
      local color = (i == selectedIdx) and ColorF(1, 0.6, 0, 0.8) or ColorF(0.2, 0.6, 1, 0.6)
      local bottom = pos - vec3(0, 0, 10)
      local top = pos + vec3(0, 0, 10)
      debugDrawer:drawCylinder(bottom, top, sphere.radius, color)
      debugDrawer:drawCylinder(pos, pos + vec3(0, 0, 11), 0.5, ColorF(0, 0, 0, 0.8))
    end

    -- 3D: gizmo
    if allowGizmo() and selectedIdx then
      editor.updateAxisGizmo(beginDrag, endDrag, dragging)
      editor.drawAxisGizmo()
    end

    if mouseInfo.down then
      if editor.keyModifiers.ctrl then
        addSphere()
      elseif editor.keyModifiers.shift and selectedIdx then
        duplicateSphere()
      elseif not editor.isAxisGizmoHovered() then
        selectSphere(mouseOverSpheres())
      end
    end

    if not im.GetIO().WantCaptureKeyboard and im.IsKeyPressed(im.GetKeyIndex(im.Key_Delete)) then
      deleteSphere(selectedIdx)
    end

    -- Sync name buffer when selection changes
    if prevSelectedIdx ~= selectedIdx then
      prevSelectedIdx = selectedIdx
      local sphere = selectedIdx and data.spheres[selectedIdx]
      if sphere then
        ffi.copy(nameBuffer, sphere.name or "")
      else
        ffi.copy(nameBuffer, "")
      end
    end

    -- ---- UI ----
    im.Text("Spheres (" .. #data.spheres .. ")")
    im.SameLine()
    if im.Button("Add") then
      addSphere()
    end
    im.SameLine()
    if not selectedIdx then im.BeginDisabled() end
    if im.Button("Delete") then
      deleteSphere(selectedIdx)
    end
    if not selectedIdx then im.EndDisabled() end

    im.BeginChild1("SphereList", im.ImVec2(0, 150), true)
    for i, sphere in ipairs(data.spheres) do
      local label = (sphere.name or ("Sphere " .. i)) .. "##s" .. i
      if im.Selectable1(label, i == selectedIdx) then
        selectSphere(i)
      end
    end
    im.EndChild()

    im.Separator()

    local sphere = selectedIdx and data.spheres[selectedIdx]
    if sphere then
      im.Text("Name:")
      im.SameLine()
      im.SetNextItemWidth(-1)
      if im.InputText("##spherename", nameBuffer, 256) then
        sphere.name = ffi.string(nameBuffer)
      end
      im.Text(string.format("Pos:    %.2f, %.2f, %.2f", sphere.pos[1], sphere.pos[2], sphere.pos[3]))
      im.Text(string.format("Radius: %.2f", sphere.radius))
      im.Checkbox("Snap to Terrain", snapToTerrain)
    else
      im.TextDisabled("No sphere selected")
    end
  end
  editor.endWindow()

  if not editor.isWindowVisible(toolWindowName) and editor.editModes and editor.editMode and editor.editMode.displayName == editModeName then
    editor.selectEditMode(nil)
  end
end

-- ==================== lifecycle ====================

local function show()
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
  editor.selectEditMode(editor.editModes.trafficGatedRoadsEditMode)
end

local function onActivate()
  editor.clearObjectSelection()
end

local function onDeactivate()
  editor.clearObjectSelection()
end

local function onEditorInitialized()
  editor.editModes.trafficGatedRoadsEditMode = {
    displayName = editModeName,
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    auxShortcuts = {},
  }
  editor.editModes.trafficGatedRoadsEditMode.auxShortcuts[editor.AuxControl_LMB] = "Select"
  editor.registerWindow(toolWindowName, im.ImVec2(400, 500))
  editor.addWindowMenuItem('Traffic Gated Roads Editor', function() show() end, {groupMenuName = 'Traffic'})
end

local function onEditorToolWindowHide(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.objectSelect)
  end
end

local function onWindowGotFocus(windowName)
  if windowName == toolWindowName then
    editor.selectEditMode(editor.editModes.trafficGatedRoadsEditMode)
  end
end

local function onSerialize()
  return {
    data = data,
    filePath = filePath,
    selectedIdx = selectedIdx,
    nextId = nextId,
  }
end

local function onDeserialized(d)
  if not d then return end
  data = d.data or { spheres = {} }
  if not data.spheres then data.spheres = {} end
  filePath = d.filePath or defaultFilePath
  selectedIdx = d.selectedIdx
  nextId = d.nextId or 1
end

M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onEditorToolWindowHide = onEditorToolWindowHide
M.onWindowGotFocus = onWindowGotFocus
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.show = show
M.loadData = loadData
M.saveData = saveData
M.allowGizmo = function() return editor.editMode and editor.editMode.displayName == editModeName or false end

return M
