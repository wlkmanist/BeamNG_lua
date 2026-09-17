-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local manualzoom = require('core/cameraModes/manualzoom')

local C = {}
C.__index = C

local relativeCameraLightLowIntensityLm = 500
local relativeCameraLightMediumIntensityLm = 2500
local relativeCameraLightHighIntensityLm = 5000
local relativeCameraLightRadius = 20

local function rotateEuler(x, y, z, q)
  q = q or quat()
  q = quatFromEuler(0, z, 0) * q
  q = quatFromEuler(0, 0, x) * q
  q = quatFromEuler(y, 0, 0) * q
  return q
end

function C:init()
  self.resetCameraOnVehicleReset = false
  self.disabledByDefault = true
  self.canUseVehicleTriggerCrosshair = true
  self.lightIntensity = 0
  self.camMaxDist = math.huge
  self.mustResetCam = -1

  self.slots = {} -- stored position/rotations
  self.slotNameIndexMap = {}

  self.manualzoom = manualzoom()
  self:onVehicleCameraConfigChanged()
  self:reset()
end

function C:onVehicleCameraConfigChanged()
  if not self.refNodes or not self.refNodes.ref or not self.refNodes.left or not self.refNodes.back then
    log('D', 'core_camera.relative', 'No refNodes found, using default fallback')
    self.refNodes = { ref=0, left=1, back=2 }
  end

  self.vehicleCameraConfigJustChanged = true
end

function C:_updateLight(intensity)
  if intensity ~= nil then
    self.lightIntensity = intensity
  end
  self.lightIntensity = math.max(0, self.lightIntensity)
  if not scenetree.relativecameralight then
    local l = createObject('PointLight')
    l.canSave  = false
    l.radius = relativeCameraLightRadius
    l:registerObject('relativecameralight')
  end
  scenetree.relativecameralight.isEnabled = self.lightIntensity > 0
  scenetree.relativecameralight.intensity = self.lightIntensity
  scenetree.relativecameralight:postApply()
end

function C:sendMenus()
  core_quickAccess.addEntry({level = '/root/sandbox/', uniqueID = "camera", icon = "camera", ignoreAsRecentAction = true, ["goto"] = '/root/sandbox/camera/', title = "Relative Camera"})

  core_quickAccess.addEntry({ level = '/root/sandbox/camera/',
    originalActionInfo = {level = "/root/sandbox/", uniqueID = "camera"},
    generator = function(entries)
    if not self.focused then return {} end
    local tmp = { title = 'Light', icon = 'lightGarageG11', priority = 10, onSelect = function()
      if self.lightIntensity <= 0 then
        self.lightIntensity = relativeCameraLightLowIntensityLm
      elseif self.lightIntensity < relativeCameraLightMediumIntensityLm then
        self.lightIntensity = relativeCameraLightMediumIntensityLm
      elseif self.lightIntensity < relativeCameraLightHighIntensityLm then
        self.lightIntensity = relativeCameraLightHighIntensityLm
      else
        self.lightIntensity = 0
      end
      self:_updateLight()
      ui_message('Light intensity: ' .. math.ceil(self.lightIntensity) .. ' lm' , 10, 'cameramode')
      return {'reload'}
    end}
    if self.lightIntensity > 0 then tmp.color = '#ff6600' end
    table.insert(entries, tmp)
    local nearClipLabel = self.nearClip and (self.nearClip.." m") or "level defined"
    table.insert(entries, { title = 'Near Clip: ' .. nearClipLabel, icon = 'radial_near_clip_value', priority = 10,
      originalActionInfo = {level = "/root/sandbox/", uniqueID = "camera"},
      onSelect = function()
      if self.nearClip == nil then
        self.nearClip = 0.0005
      elseif self.nearClip >= 0 and self.nearClip < 0.01 then
        self.nearClip = 0.01
      elseif self.nearClip >= 0.01 and self.nearClip < 0.1 then
        self.nearClip = 0.1
      elseif self.nearClip >= 0.1 then
        self.nearClip = nil
      end
      ui_message('Near clip: '..nearClipLabel, 10, 'cameramode')
      return {'reload'}
    end})
    tmp = { title = 'Slots', iconName = 'radial_slots', priority = 50, ["goto"] = '/sandbox/camera/slots/', originalActionInfo = {level = "/root/sandbox/", uniqueID = "camera"}, }
    if self.slots[1] then
      tmp.color = '#ff6600'
    end
    table.insert(entries, tmp)
  end})

  core_quickAccess.addEntry({ level = '/root/sandbox/camera/slots/', uniqueID = 'slots',
    originalActionInfo = {level = "/root/sandbox/", uniqueID = "camera"},
    generator = function(entries)
    if not self.focused then return {} end

    for i = 1, 10 do
      local tmp = { title = tostring(i), iconName = 'movieCamera', priority = i, onSelect = function()
        if self.slots[i] == nil then
          self:saveSlot(i)
        else
          self:loadSlot(i)
        end
        return {'reload'}
      end}
      if self.slots[i] then
        -- existing?
        tmp.desc = "Load position from this slot"
        tmp.color = '#ff6600'
        -- use name if existing :)
        if self.slots[i].name then
          tmp.title = self.slots[i].name
        end
      else
        -- not existing?
        tmp.title = tmp.title.." (empty)"
        tmp.desc = "Save position into this slot"
      end
      table.insert(entries, tmp)
    end
  end})
end

function C:restoreLightInfo()
  if self.storedLightIntensity ~= nil then
    self:_updateLight(self.storedLightIntensity)
    self.storedLightIntensity = nil
  end
end

function C:saveSlot(slot)
  self.slots[slot] = {
    pos = vec3(self.pos),
    rot = vec3(self.rot),
    fov = self.manualzoom.fov
  }
  ui_message('Camera position stored in slot ' .. tostring(slot), 10, 'cameramode')
end

function C:loadSlot(slot)
  if type(slot) == 'string' then
    --print(">> slot " .. tostring(slot) .. " is ID " .. tostring(self.slotNameIndexMap[slot]))
    slot = self.slotNameIndexMap[slot] -- convert name to ID
    if not slot then return false end
  end
  if not self.slots[slot] then
    ui_message('Slot ' .. tostring(slot) .. ' empty'  , 10, 'cameramode')
    return false
  end

  -- load
  local slot = self.slots[slot]
  self.pos = slot.pos
  self.rot = slot.rot
  self.manualzoom:init(slot.fov)
  return true
end

function C:setFOV(fov)
  self.manualzoom:init(fov)
end

function C:setRotation(rot)
  self.rot = rot
end

function C:setOffset(pos)
  self.pos = pos
end

-- Persist/restore this camera's own state for the video-stream views (see core_camera
-- get/setContextCameraState): the free offset on the car, look rotation, zoom and light.
function C:serialize()
  return {
    pos = self.pos and { x = self.pos.x, y = self.pos.y, z = self.pos.z } or nil,
    rot = self.rot and { x = self.rot.x, y = self.rot.y, z = self.rot.z } or nil,
    fov = self.manualzoom and self.manualzoom.fov or nil,
    light = self.lightIntensity,
    nearClip = self.nearClip,
  }
end

function C:deserialize(s)
  if type(s) ~= 'table' then return end
  if s.pos then self.pos = vec3(s.pos.x, s.pos.y, s.pos.z); self.resetPos = vec3(s.pos.x, s.pos.y, s.pos.z) end
  if s.rot then self.rot = vec3(s.rot.x, s.rot.y, s.rot.z); self.resetRot = vec3(s.rot.x, s.rot.y, s.rot.z) end
  if s.fov and self.manualzoom then self.manualzoom:init(s.fov) end
  if s.nearClip ~= nil then self.nearClip = s.nearClip end
  if s.light and s.light > 0 then self:_updateLight(s.light) elseif s.light ~= nil then self.lightIntensity = s.light end
  self.mustResetCam = -1 -- keep the restored pose instead of recomputing the default on the next update
end

-- Tunables for the camera-control / video-stream UI: light intensity, near-clip preset,
-- the 10 position slots and FOV.
function C:listParams()
  local slots = {}
  for i = 1, 10 do slots[i] = self.slots[i] ~= nil end
  return {
    { key = 'light', icon = 'fa-lightbulb', kind = 'range', value = self.lightIntensity, min = 0, max = relativeCameraLightHighIntensityLm, step = 500, unit = 'lm' },
    { key = 'nearClip', icon = 'fa-scissors', kind = 'choice', value = self.nearClip or 'auto', options = {
      { value = 'auto', label = 'Auto' }, { value = 0.0005, label = '0.5mm' }, { value = 0.01, label = '1cm' }, { value = 0.1, label = '10cm' } } },
    { key = 'slots', icon = 'fa-bookmark', kind = 'slots', value = slots },
    { key = 'fov', icon = 'fa-expand', title = 'Field of view', kind = 'range', type = 'int', value = self.manualzoom and self.manualzoom.fov or 60, default = 60, min = 10, max = 140, step = 1, unit = '°' },
  }
end

function C:setParam(key, value)
  if key == 'light' then self:_updateLight(tonumber(value) or 0)
  elseif key == 'nearClip' then self.nearClip = (value == 'auto' or value == nil) and nil or tonumber(value)
  elseif key == 'fov' then self:setFOV(tonumber(value) or (self.manualzoom and self.manualzoom.fov) or 60)
  elseif key == 'slots' then
    local i = tonumber(value)
    if i then if self.slots[i] then self:loadSlot(i) else self:saveSlot(i) end end
  end
end

function C:hotkey(hotkey, modifier)
  if not self.focused then return end
  if modifier == 0 then
    self:loadSlot(hotkey)
  elseif modifier == 1 then
    self:saveSlot(hotkey)
  end
end

function C:storeLightInfo()
  self.storedLightIntensity = self.lightIntensity
  self:_updateLight(0)
end

function C:onCameraChanged(focused)
  if focused then
    self:sendMenus()
    self:restoreLightInfo()
  else
    self:storeLightInfo()
  end
end

function C:reset()
  self.pos = self.resetPos
  self.rot = self.resetRot
  self.manualzoom:reset()
  self.factorSmoother = newTemporalSmoothing(50,50)
  self.dxSmoother = newTemporalSmoothing(10,7)
  self.dySmoother = newTemporalSmoothing(10,7)
  self.dzSmoother = newTemporalSmoothing(10,7)
end

function C:setMaxDistance(d)
  self.camMaxDist = d or math.huge
end

function C:update(data)
  local ref  = vec3(data.veh:getNodePosition(self.refNodes.ref))
  local left = vec3(data.veh:getNodePosition(self.refNodes.left))
  local back = vec3(data.veh:getNodePosition(self.refNodes.back))

  -- check if we must reset the camera
  if self.vehicleCameraConfigJustChanged then
    self.vehicleCameraConfigJustChanged = false
    local vehicleName = data.veh:getField('JBeam','0')
    if self.lastVehicleName ~= nil and self.lastVehicleName ~= vehicleName then
      self.mustResetCam = 1 -- spawnWorldOOBBRearPoint is not valid after a vehicle change until 1 frame later
    end
    self.lastVehicleName = vehicleName
  end

  if self.mustResetCam == 0 then
    self.pos = nil
    self.resetPos = nil
    self.manualzoom:reset()
  end

  self.mustResetCam = math.max(self.mustResetCam - 1, -1)
  if self.pos == nil or self.rot == nil then
    if #self > 0 then -- onboard/relative cameras were defined
      for k, cr in ipairs(self) do
        if cr.name then
          table.insert(self.slots, cr)
          self.slotNameIndexMap[cr.name] = #self.slots
        else
          log("W","","Relative camera #"..dumps(k)..": missing node name: "..dumps(cr))
        end
      end
      self:loadSlot(1)
    end
    if self.pos == nil then
      local nx = (left-ref):normalized()
      local ny = (back-ref):normalized()
      local nz = nx:cross(ny):normalized()
      local carPos = vec3(data.veh:getSpawnWorldOOBBRearPoint())
      local pos = data.pos - carPos
      pos = vec3(pos:dot(nx), pos:dot(ny), pos:dot(nz))
      pos.z = ref.z
      local offset = vec3(0,-0.5,0)
      self.pos = pos + offset
    end
    self.rot = self.rot or vec3(0,180,0)
  end

  if self.resetPos == nil then
    self.resetPos = vec3(self.pos) -- copy
    self.resetRot = vec3(self.rot) -- copy
  end

  -- update input
  local dx = self.dxSmoother:getCapped(MoveManager.right   - MoveManager.left,     data.dt)
  local dy = self.dySmoother:getCapped(MoveManager.forward - MoveManager.backward, data.dt)
  local dz = self.dzSmoother:getCapped(MoveManager.up      - MoveManager.down,     data.dt)
  local modifiedSpeed = data.fastSpeedModifier and data.speed * 3 or data.speed

  -- Distance-based speed multiplier
  local distanceFromRef = self.pos:length()
  local speedMultiplier = 1.0
  if distanceFromRef > 2.0 then
    local t = math.min((distanceFromRef - 2.0) / (5.0 - 2.0), 1.0)
    speedMultiplier = 1.0 + t * (5.0 - 1.0)
  end

  local adjustedSpeed = modifiedSpeed * speedMultiplier
  local dtPosFactor = self.factorSmoother:getUncapped(adjustedSpeed / 80, data.dt)
  local pd = dtPosFactor * data.dt * vec3(dx, dy, dz)

  local rdx = MoveManager.yawRelative   + 10*data.dt*(MoveManager.yawRight - MoveManager.yawLeft  )
  local rdy = MoveManager.pitchRelative + 10*data.dt*(MoveManager.pitchUp - MoveManager.pitchDown)
  local rdz = MoveManager.rollRelative + 10*data.dt*(MoveManager.rollLeft - MoveManager.rollRight)
  self.rot = self.rot + 7*vec3(rdx, rdy, rdz)

  local dir = (ref - back):normalized()
  local up = dir:cross(left):normalized()
  local qdir = quatFromDir(dir, up)

  if dir:squaredLength() == 0 or up:squaredLength() == 0 then
    data.res.pos = data.pos
    data.res.rot = quatFromDir(vec3(0,1,0), vec3(0, 0, 1))
    if self.nearClip then data.res.nearClip = self.nearClip end
    return false
  end

  local camOffset = qdir * self.pos

  local qdirLook = rotateEuler(-math.rad(self.rot.x), -math.rad(self.rot.y), 0) --math.rad(self.rot.z))
  local qdirLook2 = rotateEuler(0, 0, math.rad(self.rot.z), qdirLook)
  qdir = qdirLook2 * qdir

  local newPos = self.pos + qdirLook * pd
  local distance = newPos:distance(ref)
  if self.camMaxDist and distance < self.camMaxDist then
    self.pos = self.pos + qdirLook * pd
  end

  local pos = data.pos + camOffset

  self.manualzoom:update(data)

  -- application
  data.res.pos = pos + ref -- add the relative position of the reference to keep the accuracy
  data.res.rot = qdir
  if self.nearClip then data.res.nearClip = self.nearClip end

  if self.lightIntensity > 0 then
    local lightPos = pos -- + qdirLook * vec3(0.01, 0.01, -0.02)
    scenetree.relativecameralight:setPosRot(lightPos.x, lightPos.y, lightPos.z, data.res.rot.x, data.res.rot.y, data.res.rot.z, data.res.rot.w)
  end

  return true
end

function C:setRefNodes(centerNodeID, leftNodeID, backNodeID)
  self.refNodes = self.refNodes or {}
  self.refNodes.ref = centerNodeID
  self.refNodes.left = leftNodeID
  self.refNodes.back = backNodeID
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
