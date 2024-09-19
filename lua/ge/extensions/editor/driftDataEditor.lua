  -- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui
local ffi = require('ffi')
local whiteColorF = ColorF(1,1,1,1)
local blackColorI = ColorI(0,0,0,192)

-- main working data
local toolWindowName = "Drift data editor"
local currentFileDir = "/gameplay/temp/"
local currentFileName
local driftData = nil
local autoSelectElement = nil

-- editor data
local selectedElementIndex = 1
local mouseInfo

local defaultPointsCopy
local stuntZonesPresets = {
    driftThrough = {absolute = false, presets = {1000, 1500, 2000}},
    donut = {absolute = true, presets = {250, 500, 750}},
    hitPole = {absolute = false, presets = {500, 1000, 1500}},
    nearPole = {absolute = false, presets = {500, 1000, 1500}},
}

local function getNewDriftData()
  return {
    stuntZones = {}
  }
end

local function moveStuntZoneOrder(t, old, new)
  local value = t[old]
  if new < old then
     table.move(t, new, old - 1, new + 1)
  else
     table.move(t, old + 1, new, old)
  end
  t[new] = value
  M.selectElement(new)
end

local function drawDriftData()
  im.Columns(2,'mainDrift')
  -- element selector and "New"
  im.BeginChild1("element select", im.GetContentRegionAvail(), 1)
  im.Text("Drift Stunt Zones:")
  for i, elem in ipairs(driftData.stuntZones) do
    if im.Selectable1(string.format("%d - %s", i, elem.type), i == selectedElementIndex) then
      -- select element
      M.selectElement(i)
    end
  end

  im.EndChild()

  im.NextColumn()

  -- element detail
  im.BeginChild1("element detail", im.GetContentRegionAvail(), 1)

  -- header bar
  if im.Button("Delete") then
    table.remove(driftData.stuntZones, selectedElementIndex)
    -- deletion
  end
  im.SameLine()
  if selectedElementIndex - 1 >= 1 then
    if im.Button("Move Up") then
      moveStuntZoneOrder(driftData.stuntZones, selectedElementIndex, selectedElementIndex - 1)
    end
    im.SameLine()
  end
  if selectedElementIndex + 1 <= #driftData.stuntZones then
    if im.Button("Move Down") then
      moveStuntZoneOrder(driftData.stuntZones, selectedElementIndex, selectedElementIndex + 1)
    end
  end
  im.Separator()
  M.drawElementDetail(driftData.stuntZones[selectedElementIndex])
  im.EndChild()

  im.NextColumn()
  im.Columns(0)

  -- then debug drawing
  for i, elem in ipairs(driftData.stuntZones) do
    if elem.type == "donut" then
      debugDrawer:drawTextAdvanced(elem.pos, String(string.format("%d - %s", i, elem.type)), whiteColorF, true, false, blackColorI)

      debugDrawer:drawSphere(elem.pos, elem.scl, ColorF(0,1,0,0.2))
    end

    if elem.type == "driftThrough" then
      debugDrawer:drawTextAdvanced(elem.pos, String(string.format("%d - %s", i, elem.type)), whiteColorF, true, false, blackColorI)
      local x, y, z = elem.rot * vec3(elem.scl.x,0,0), elem.rot * vec3(0,elem.scl.y,0), elem.rot * vec3(0,0,elem.scl.z)
      local scl = (x+y+z)/2
      M.drawAxisBox(((-scl*2)+elem.pos),x*2,y*2,z*2,color(0,0,255,0.2*255))
      --local scl = (x+y+z)
      --M.drawAxisBox((-scl+elem.pos),x*2,y*2,z*2,color(0,0,255,0.2*255))
    end

    if elem.type == "hitPole" then
      debugDrawer:drawTextAdvanced(elem.pos, String(string.format("%d - %s", i, elem.type)), whiteColorF, true, false, blackColorI)

      debugDrawer:drawCylinder(elem.pos, elem.pos + vec3(0,0,3), 0.2,  ColorF(1,0,0,0.2))
    end
  end
end

local transform
local function drawElementDetail(elem)
  if not elem then return end

  if transform and transform:update(mouseInfo) then
    elem.pos = transform.allowTranslate and transform.pos or nil
    elem.rot = transform.allowRotate and transform.rot or nil
    elem.scl = transform.allowScale and transform.scl or nil
  end
  if elem.cooldown then
    local rv = im.IntPtr(elem.cooldown)
    if im.InputInt ("Cooldown", rv) then
      elem.cooldown = rv[0]
    end
  end
  if not elem.score then
    elem.score = defaultPointsCopy[elem.type]
  else
    local stuntZonePreset = stuntZonesPresets[elem.type] -- find preset for this stunt zone type

    -- build the string from the stunt zone type presets that will be fed to the Combo2
    local s = ""
    for _, n in ipairs(stuntZonePreset.presets) do
      s = s .. tostring(n) .. "\0"
    end

    -- the Combo2 needs a intPtr for the current chosen option
    local presetPtr = im.IntPtr((tableFindKey(stuntZonePreset.presets, elem.score) or 2) - 1)
    if im.Combo2(stuntZonePreset.absolute and "Points" or "Max points", presetPtr, s) then
      elem.score = stuntZonePreset.presets[tonumber(presetPtr[0]) + 1]
    end
  end
end

local function selectElement(index)
  selectedElementIndex = index
  local elem = driftData.stuntZones[selectedElementIndex]
  local label = string.format("%d-%s",index, elem.type)

  transform = nil

  if elem.type == "donut" then
    transform = require('/lua/ge/extensions/editor/util/transformUtil')(label, label)
    transform.allowTranslate = true
    transform.allowRotate = false
    transform.allowScale = true
    transform:setOneDimensionalScale(true)
    transform:set(elem.pos, nil, elem.scl)
    transform:enableEditing()
  end

  if elem.type == "driftThrough" then
    transform = require('/lua/ge/extensions/editor/util/transformUtil')(label, label)
    transform.allowTranslate = true
    transform.allowRotate = true
    transform.allowScale = true
    transform:setOneDimensionalScale(false)
    transform:set(elem.pos, elem.rot, elem.scl)
    transform:enableEditing()
  end

  if elem.type == "hitPole" then
    transform = require('/lua/ge/extensions/editor/util/transformUtil')(label, label)
    transform.allowTranslate = true
    transform.allowRotate = false
    transform.allowScale = false
    transform:set(elem.pos, nil, nil)
    transform:enableEditing()
  end
end

------------------------
-- menu/saving/window --
------------------------

local function saveDriftData(savePath)
  jsonWriteFile(savePath, driftData, true)
  local dir, filename, ext = path.split(savePath)
  currentFileDir = dir
  currentFileName = filename
end

local function loadDriftData(filename)
  if not filename then
    return
  end
  local json = jsonReadFile(filename)
  if not json then
    log('E', logTag, 'unable to find driftData file: ' .. tostring(filename))
    return
  end

  -- "cast" scl, pos and rot to vec/quat
  for _, elem in ipairs(json.stuntZones or {}) do
    if elem.pos and type(elem.pos) == "table" and elem.pos.x and elem.pos.y and elem.pos.z then elem.pos = vec3(elem.pos) end
    if elem.rot and type(elem.rot) == "table" and elem.rot.x and elem.rot.y and elem.rot.z and elem.rot.w then elem.rot = quat(elem.rot) end
    if elem.scl and type(elem.scl) == "table" and elem.scl.x and elem.scl.y and elem.scl.z then elem.scl = vec3(elem.scl) end
    if elem.scl and type(elem.scl) == "number" then end
  end

  local dir, filename, ext = path.split(filename)
  currentFileDir = dir
  currentFileName = filename

  driftData = json

  M.selectElement(1)
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName,toolWindowName, im.WindowFlags_MenuBar) then
    defaultPointsCopy = gameplay_drift_scoring.getScoreOptions().defaultPoints

    -- menu bar to load/save/etc
    if im.BeginMenuBar() then
      if im.BeginMenu("File") then

        if im.MenuItem1("Load...") then
          editor_fileDialog.openFile(function(data) loadDriftData(data.filepath) end, {{"driftData Files",".driftData.json"}}, false, currentFileDir)
        end
        local canSave = currentFileDir and currentFileName and driftData
        if not canSave then im.BeginDisabled() end
        if im.MenuItem1("Save") then
          saveDriftData(currentFileDir .. currentFileName)
        end
        if not canSave then im.EndDisabled() end
        if im.MenuItem1("Save as...") then
          extensions.editor_fileDialog.saveFile(function(data) saveDriftData(data.filepath) end, {{"driftData Files",".driftData.json"}}, false, currentFileDir)
        end
        if im.MenuItem1("Clear") then
          currentFileDir = "/gameplay/temp/"
          currentFileName = nil
          driftData = getNewDriftData()
        end
        if im.MenuItem1("Create Stunt Zones around Vehicle") then
          local obj = scenetree.findObjectById(be:getPlayerVehicleID(0))
          if obj then
            local pos = obj:getPosition()
            driftData = { stuntZones = {{type = "donut", pos = pos + vec3(10, 0, 0), scl = 10},{type = "driftThrough", rot = quat(0, 0, 0, 1), pos = pos + vec3(10, 20, 0), scl = vec3(8, 1, 1)},{type = "hitPole", pos = pos + vec3(-10, 0, 0)}}}
          end
        end
        im.EndMenu()
      end

      if im.BeginMenu("Add new stunt zone...") then
        if im.MenuItem1("Add Donut") then
          local obj = scenetree.findObjectById(be:getPlayerVehicleID(0))
          if obj then
            local pos = obj:getPosition()
            table.insert(driftData.stuntZones,
            {
              type = "donut",
              cooldown = 8,
              pos = pos + vec3(10, 0, 0),
              scl = 10,
              score = shallowcopy(defaultPointsCopy.donutPoints)
            })
            autoSelectElement = #driftData.stuntZones
          end
        end
        if im.MenuItem1("Add Drift Through") then
          local obj = scenetree.findObjectById(be:getPlayerVehicleID(0))
          if obj then
            local pos = obj:getPosition()
            table.insert(driftData.stuntZones,
            {
              type = "driftThrough",
              cooldown = 8,
              rot = quat(0, 0, 0, 1),
              pos = pos + vec3(10, 20, 0),
              scl = vec3(8, 1, 1),
              score = shallowcopy(defaultPointsCopy.driftThroughPoints)
            })
            autoSelectElement = #driftData.stuntZones
          end
        end
        if im.MenuItem1("Add Hit Pole") then
          local obj = scenetree.findObjectById(be:getPlayerVehicleID(0))
          if obj then
            local pos = obj:getPosition()
            table.insert(driftData.stuntZones,
            {
              type = "hitPole",
              pos = pos + vec3(-10, 0, 0),
              score = shallowcopy(defaultPointsCopy.hitPolePoints)
            })
            autoSelectElement = #driftData.stuntZones
          end
        end
        im.EndMenu()
      end
      im.EndMenuBar()

    end

    if #driftData.stuntZones > 0 then
      M.updateMouseInfo()
      if autoSelectElement then
        M.selectElement(autoSelectElement)
      end
      drawDriftData()
    end
    autoSelectElement = nil
    editor.endWindow()
  end
end


local function show()
  editor.clearObjectSelection()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  editor.registerWindow(toolWindowName, im.ImVec2(1500,700))
  editor.addWindowMenuItem("Drift data editor", function() show() end, {groupMenuName="Gameplay"})
  if driftData == nil then
    driftData = getNewDriftData()
  end
end

local function onSerialize()
  local ret = {
    selectedElementIndex = selectedElementIndex,
    currentFileDir = currentFileDir,
    currentFileName = currentFileName,
    driftData = driftData,
  }
  return ret
end

local function onDeserialized(data)
  currentFileDir = data.currentFileDir or currentFileDir
  currentFileName = data.currentFileName or currentFileName
  driftData = data.driftData or driftData
  if data.selectedElementIndex then
    autoSelectElement = data.selectedElementIndex
  end
end


M.updateMouseInfo = function()
  if not mouseInfo then mouseInfo = {} end
  if core_forest.getForestObject() then core_forest.getForestObject():disableCollision() end
  mouseInfo.camPos = core_camera.getPosition()
  mouseInfo.ray = getCameraMouseRay()
  mouseInfo.rayDir = vec3(mouseInfo.ray.dir)
  mouseInfo.rayCast = cameraMouseRayCast()
  mouseInfo.valid = mouseInfo.rayCast and true or false

  if core_forest.getForestObject() then core_forest.getForestObject():enableCollision() end
  if not mouseInfo.valid then
    mouseInfo.down = false
    mouseInfo.hold = false
    mouseInfo.up   = false
    mouseInfo.closestNodeHovered = nil
  else
    mouseInfo.down =  im.IsMouseClicked(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.hold = im.IsMouseDown(0) and not im.GetIO().WantCaptureMouse
    mouseInfo.up =  im.IsMouseReleased(0) and not im.GetIO().WantCaptureMouse
    if mouseInfo.down then
      mouseInfo.hold = false
      mouseInfo._downPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._downNormal = vec3(mouseInfo.rayCast.normal)
    end
    if mouseInfo.hold then
      mouseInfo._holdPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._holdNormal = vec3(mouseInfo.rayCast.normal)
    end
    if mouseInfo.up then
      mouseInfo._upPos = vec3(mouseInfo.rayCast.pos)
      mouseInfo._upNormal = vec3(mouseInfo.rayCast.normal)
    end
  end
end

-- helper function
M.drawAxisBox = function(corner, x, y, z, clr)
  -- draw all faces in a loop
  for _, face in ipairs({{x,y,z},{x,z,y},{y,z,x}}) do
    local a,b,c = face[1],face[2],face[3]
    -- spokes
    debugDrawer:drawLine((corner    ), (corner+c    ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a  ), (corner+c+a  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+b  ), (corner+c+b  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a+b), (corner+c+a+b), ColorF(0,0,0,0.75))
    -- first side
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+a  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+b  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    -- back of first side
    debugDrawer:drawTriSolid(
      vec3(corner+a  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+b  ),
      vec3(corner+a+b),
      clr)
    -- other side
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+a  ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+b  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    -- back of other side
    debugDrawer:drawTriSolid(
      vec3(c+corner+a  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+b  ),
      vec3(c+corner+a+b),
      clr)
  end
end

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.show = show

M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui
M.drawElementDetail = drawElementDetail

-- INTERNAL
M.selectElement = selectElement
return M