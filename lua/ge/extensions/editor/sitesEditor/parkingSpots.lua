-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local im = ui_imgui

local transformUtil

local function radToDeg(x) return x * 180 / math.pi end
local function degToRad(x) return x * math.pi / 180 end

-- helper: quaternion -> euler XYZ (radians)
local function quatToEulerXYZ(q)
  local x, y, z, w = q.x, q.y, q.z, q.w
  local sinr_cosp = 2 * (w * x + y * z)
  local cosr_cosp = 1 - 2 * (x * x + y * y)
  local ex = math.atan2(sinr_cosp, cosr_cosp)

  local sinp = 2 * (w * y - z * x)
  local ey
  if math.abs(sinp) >= 1 then
    ey = (sinp > 0) and (math.pi / 2) or (-math.pi / 2)
  else
    ey = math.asin(sinp)
  end

  local siny_cosp = 2 * (w * z + x * y)
  local cosy_cosp = 1 - 2 * (y * y + z * z)
  local ez = math.atan2(siny_cosp, cosy_cosp)

  return ex, ey, ez
end

local function makeUniqueName(list, base)
  local taken = {}
  for _, o in ipairs(list.sorted) do
    if o.name then taken[o.name] = true end
  end
  if not base or base == "" then base = "Parking Spot" end
  if not taken[base] then return base end
  local i = 1
  while true do
    local cand = string.format("%s (%d)", base, i)
    if not taken[cand] then return cand end
    i = i + 1
  end
end

local psVehScales = {
  Car = vec3(2.5, 6, 3),
  LargeCar = vec3(3.25, 8, 4),
  Bus = vec3(4, 14, 8)
}

local C = {}
C.windowDescription = 'Parking Spots'

function C:init(sitesEditor, key)
  self.sitesEditor = sitesEditor
  self.key = key
  self.current = nil

  -- multiSpot data
  self.isMultiSpot = im.BoolPtr(false)
  self.multiSpotData = { spotAmount = im.IntPtr(1), spotOffset = im.FloatPtr(0), spotDirection = "Left", spotRotation = im.FloatPtr(0) }

  -- Euler degrees buffer for InputFloat3
  self.fItemRot = im.ArrayFloat(3)

  -- drag/dup state
  self.wasDragging = false
  self.didCtrlDuplicateThisDrag = false

  self.pendingGizmoMode = editor.AxisGizmoMode_Translate
  self.gizmoSetupCountdown = 0

  function C:requestGizmo(mode)
    self.pendingGizmoMode = mode or self.pendingGizmoMode
    self.gizmoSetupCountdown = 3
  end

  transformUtil = require('/lua/ge/extensions/editor/util/transformUtil')("Edit Sites", "Transform")
end

function C:setSites(sites)
  for _, ps in ipairs(sites.parkingSpots.sorted) do -- fixes rotations due to auto rotation adjustments of multispots
    if ps.rotOrig then
      ps.rot = quat(ps.rotOrig)
      ps.rotOrig = nil
    end
  end

  self.sites = sites
  self.list = sites[self.key]
  self.current = nil
end

function C:select(ps)
  self.current = ps
  if self.current ~= nil then
    self:setTransform()
    transformUtil:enableEditing(0)
    self:requestGizmo(editor.AxisGizmoMode_Translate)
    self.isMultiSpot[0] = self.current.isMultiSpot or false
    self.multiSpotData.spotAmount[0] = self.current.multiSpotData.spotAmount or 1
    self.multiSpotData.spotOffset[0] = self.current.multiSpotData.spotOffset or 0
    self.multiSpotData.spotDirection = self.current.multiSpotData.spotDirection or "Left"
    self.multiSpotData.spotRotation[0] = self.current.multiSpotData.spotRotation or 0
  end
end

function C:hitTest(mouseInfo, objects)
  local minNodeDist = 4294967295
  local closestNode = nil
  if mouseInfo.down then
    for idx, node in pairs(objects) do
      local tmpSpotAmount = 1
      if node.isMultiSpot then
        tmpSpotAmount = node.multiSpotData.spotAmount or 1
      end
      for i = 0, tmpSpotAmount - 1 do
        local rot = node.rot
        local dirVec
        if node.multiSpotData.spotDirection == "Left" then
          dirVec = rot * vec3(-i * (node.scl.x + node.multiSpotData.spotOffset), 0, 0)
        elseif node.multiSpotData.spotDirection == "Right" then
          dirVec = rot * vec3(i * (node.scl.x + node.multiSpotData.spotOffset), 0, 0)
        elseif node.multiSpotData.spotDirection == "Front" then
          dirVec = rot * vec3(0, i * (node.scl.y + node.multiSpotData.spotOffset), 0)
        elseif node.multiSpotData.spotDirection == "Back" then
          dirVec = rot * vec3(0, -i * (node.scl.y + node.multiSpotData.spotOffset), 0)
        end
        rot = quatFromEuler(0, 0, node.multiSpotData.spotRotation) * rot
        local pos = node.pos + dirVec
        local rotated = (node.scl * 0.5):rotated(rot)
        local minDist, maxDist = intersectsRay_OBB(mouseInfo.camPos, mouseInfo.rayDir:normalized(), pos, vec3(rotated.x, 0, 0), vec3(0, rotated.y, 0), vec3(0, 0, rotated.z))
        if minDist > 0 and maxDist > 0 and minDist < maxDist and minDist < minNodeDist then -- camera needs to be outside of bounding box to select object
          minNodeDist = minDist
          closestNode = node
        end
      end
    end

    return closestNode
  end
end

local function createUndo(data)
  if not data.id and data.self.current then
    data.id = data.self.current.id
  end
  if data.id and data.list.objects[data.id] and not data.list.objects[data.id].missing then
    data.list:remove(data.id)
  end
end

local function createRedo(data)
  local lastName = data.list.sorted[#data.list.sorted]
  if lastName then
    lastName = lastName.name
  else
    lastName = nil
  end
  local ps = data.list:create()

  if lastName then
    --ps.name = lastName
  end
  ps:set(data.pos, nil, psVehScales["Car"])
  transformUtil:enableEditing(0)

  if data.ps then
    ps:onDeserialized(data.ps)
  end
  data.ps = ps:onSerialize()
  data.id = ps.id
  data.self.current = ps
  data.self:requestGizmo(editor.AxisGizmoMode_Translate)
  data.list:buildNamesDir()
end

local function duplicateRedo(data)
  local ps = data.list:create()
  if data.ps then
    ps:onDeserialized(data.ps)
  end
  if not data.name then
    local base = data.baseName or ps.name or "Parking Spot"
    data.name = makeUniqueName(data.list, base)
  end
  ps.name = data.name
  data.ps = ps:onSerialize()
  data.id = ps.id
  data.self.current = ps
  data.list:buildNamesDir()
end

function C:create(pos)
  editor.history:commitAction("Create Parking Spot",
    { self = self, list = self.list, pos = pos },
    createUndo, createRedo)
  return self.current
end

function C:remove(ps)
  editor.history:commitAction("Remove Parking Spot",
    { self = self, list = self.list, ps = ps and ps:onSerialize(), id = ps and ps.id },
    createRedo, createUndo)
end

function C:setTransform()
  transformUtil:set(self.current.pos, self.current.rot, self.current.scl)
end

function C:updateFromTransform()
  self.current.pos = transformUtil.pos
  self.current.rot = transformUtil.rot
  self.current.scl = transformUtil.scl
end

local function updateTransformUndo(data)
  data.self.current = data.objects[data.id]
  if data.self.current then
    data.self.current.pos = data.old.pos
    data.self.current.rot = data.old.rot
    data.self.current.scl = data.old.scl
    data.self:setTransform()
  end
end

local function updateTransformRedo(data)
  data.self.current = data.objects[data.id]
  if data.self.current then
    data.self.current.pos = data.new.pos
    data.self.current.rot = data.new.rot
    data.self.current.scl = data.new.scl
    data.self:setTransform()
  end
end

function C:updateTransform()
  local old = {pos = transformUtil.beginDragPos or self.current.pos, rot = transformUtil.beginDragRot or self.current.rot, scl = transformUtil.beginDragScl or self.current.scl}
  local new = {pos = vec3(transformUtil.pos), rot = quat(transformUtil.rot), scl = vec3(transformUtil.scl)}
  editor.history:commitAction("Update Transform of "..self.current.name,
    { self = self, objects = self.sites[self.key].objects, id = self.current.id, old = old, new = new },
    updateTransformUndo, updateTransformRedo)
end

function C:updateMultiSpot()
  if self.current then
    self.current.isMultiSpot = self.isMultiSpot[0]
    self.current.multiSpotData.spotAmount = self.multiSpotData.spotAmount[0]
    self.current.multiSpotData.spotOffset = self.multiSpotData.spotOffset[0]
    self.current.multiSpotData.spotDirection = self.multiSpotData.spotDirection
    self.current.multiSpotData.spotRotation = self.multiSpotData.spotRotation[0]
  end
end

function C:_beginCtrlDuplicate()
  local ser = self.current:onSerialize()
  editor.history:commitAction("Duplicate Parking Spot",
    { self = self, list = self.list, ps = ser, baseName = self.current.name },
    createUndo, duplicateRedo)
  self.didCtrlDuplicateThisDrag = true
end

function C:drawElement(ps, mouseInfo)
  local function ensureGizmo(self)
    -- if another tool hid/disabled the gizmo, kick the setup again
    if editor.getAxisGizmoMode and editor.AxisGizmoMode_None and editor.getAxisGizmoMode() == editor.AxisGizmoMode_None then
      self.gizmoSetupCountdown = math.max(self.gizmoSetupCountdown, 2)
    end
    if self.gizmoSetupCountdown > 0 then
      -- make sure transformUtil has the latest target transform
      self:setTransform()
      -- enable editing and axis gizmo
      transformUtil:enableEditing(0)
      if editor.setAxisGizmoVisible then editor.setAxisGizmoVisible(true) end
      if editor.setAxisGizmoMode and editor.getAxisGizmoMode and editor.getAxisGizmoMode() ~= self.pendingGizmoMode then
        editor.setAxisGizmoMode(self.pendingGizmoMode)
      end
      self.gizmoSetupCountdown = self.gizmoSetupCountdown - 1
    end
  end
  local dirty = false
  self.current = ps

  ensureGizmo(self)
  local startedDrag = transformUtil.isDragging and not self.wasDragging
  local endedDrag = (not transformUtil.isDragging) and self.wasDragging

  if startedDrag then
    local io = im.GetIO()
    if io.KeyCtrl and not self.didCtrlDuplicateThisDrag then
      self:_beginCtrlDuplicate()
    end
  end

  if transformUtil:update(mouseInfo) then -- if change was detected
    if transformUtil.isDragging then
      self:updateFromTransform()
    else
      self:updateTransform()
      transformUtil:resetDragging()
    end
  end

  if endedDrag then
    self.didCtrlDuplicateThisDrag = false
  end
  self.wasDragging = transformUtil.isDragging

  im.PushItemWidth(90)

  local currScale = "Custom"
  for name, vehScale in pairs(psVehScales) do
    if self.current.scl == vehScale then
      currScale = name
      break
    end
  end
  if im.BeginCombo("##psScaleSelect", currScale) then
    for name, vehScale in pairs(psVehScales) do
      if im.Selectable1(name) then
        currScale = name
        self.current.scl = vehScale
        self:setTransform()
        dirty = true
      end
    end
    im.EndCombo()
  end
  im.PopItemWidth()
  local ex, ey, ez = quatToEulerXYZ(self.current.rot)
  self.fItemRot[0] = radToDeg(ex or 0)
  self.fItemRot[1] = radToDeg(ey or 0)
  self.fItemRot[2] = radToDeg(ez or 0)
  local fmt = "%0." .. (editor.getPreference and editor.getPreference("ui.general.floatDigitCount") or 2) .. "f"
  if im.InputFloat3("Angle Rotation##Rotation", self.fItemRot, fmt, im.InputTextFlags_EnterReturnsTrue) then
    local rx = degToRad(self.fItemRot[0])
    local ry = degToRad(self.fItemRot[1])
    local rz = degToRad(self.fItemRot[2])
    local old = {pos = vec3(self.current.pos), rot = quat(self.current.rot), scl = vec3(self.current.scl)}
    self.current.rot = quatFromEuler(rx, ry, rz)
    self:setTransform()
    local newT = {pos = vec3(self.current.pos), rot = quat(self.current.rot), scl = vec3(self.current.scl)}
    editor.history:commitAction("Rotate Parking Spot",
      { self = self, objects = self.sites[self.key].objects, id = self.current.id, old = old, new = newT },
      updateTransformUndo, updateTransformRedo)
  end

  im.Spacing()
  if im.Checkbox("Is MultiSpot", self.isMultiSpot) then
    dirty = true
  end

  if self.isMultiSpot[0] then
    im.PushItemWidth(90)
    if im.BeginCombo("##spotDirectionSelect", self.multiSpotData.spotDirection) then
      for _, dir in ipairs({ "Left", "Right", "Front", "Back" }) do
        if im.Selectable1(dir) then
          self.multiSpotData.spotDirection = dir
          dirty = true
        end
      end
      im.EndCombo()
    end
    im.PopItemWidth()
    im.SameLine()
    im.Text("Direction")
    if im.SliderInt("Amount of Spots", self.multiSpotData.spotAmount, 1, 25) then
      dirty = true
    end

    if im.SliderFloat("Offset", self.multiSpotData.spotOffset, 0, 5, "%.3f", 0.001) then
      dirty = true
    end

    if im.SliderFloat("Spot Rotation", self.multiSpotData.spotRotation, -1.55, 1.55, "%.2f", 0.01) then
      dirty = true
    end
  end

  if dirty then
    self:updateMultiSpot()
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
