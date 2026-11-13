-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.__index = C

local manualzoom = require('core/cameraModes/manualzoom')

local rotEulerTemp = quat()
local function setRotateEuler(x, y, z, qSource, qDest)
  rotEulerTemp:setFromEuler(0, z, 0)
  qDest:setMul2(rotEulerTemp, qSource)
  rotEulerTemp:setFromEuler(0, 0, x)
  qDest:setMul2(rotEulerTemp, qDest)
  rotEulerTemp:setFromEuler(y, 0, 0)
  qDest:setMul2(rotEulerTemp, qDest)
  return qDest
end

function C:reset()
  self.angularVelocity = vec3(0,0,0)
  self.velocity = vec3(0,0,0)
  self.planarVelocity = vec3(0,0,0)
  if self.planarExternalVelocity then self.planarExternalVelocity:set(0, 0, 0) end
  self.planarExternalInputActive = false
  self.manualzoom = manualzoom()
  self.manualzoom:init(65)
  self.rot.z = 0 -- reset roll
end

function C:setSmoothedCam(smoothed)
  self.smoothed = smoothed and true or false
  if smoothed then
    self.angularForce = 150
    self.angularDrag = 2.5
    self.mass = 10
    self.translationForce = 600
    self.translationDrag = 2
    self.angularVelocity = vec3(0,0,0)
  else
    self.angularForce = 400
    self.angularDrag = 16
    self.mass = 1
    self.translationForce = 250
    self.translationDrag = 17
  end
end

function C:init()
  self.isGlobal = true
  self.group = "world" -- member of the world camera group (cycled with the camera key, entered with the group toggle)
  self.groupOrder = 10
  self.hidden = true
  self.canUseVehicleTriggerCrosshair = true
  self:setSmoothedCam(false)

  self.pos = vec3(0,0,0)
  self.rot = vec3(0,0,0)
  self.newtonTranslation = true
  self.newtonRotation = true
  self.planarTranslation = false
  self.planarTranslationScale = 1
  self.planarTranslationDrag = nil
  self.planarTranslationSpeedMultiplier = nil
  self.planarTranslationFastSpeedMultiplier = nil
  self.planarTranslationResponse = nil
  self.planarExternalVelocity = vec3(0, 0, 0)
  self.planarExternalInputActive = false
  self:reset()
end

function C:setPosition(position)
  self.pos = position
end

function C:setFOV(fovDeg)
  self.manualzoom:init(fovDeg)
end

function C:setNewtonRotation(enabled)
  self.newtonRotation = enabled
end

function C:setNewtonTranslation(enabled)
  self.newtonTranslation = enabled
end

-- Tunables for the camera-control / video-stream UI. Fly speed is context state (shared
-- with the vehicle cams' zoom rate) so it routes through core_camera; the rest are this
-- camera's own.
function C:listParams(ctxId)
  return {
    { key = 'speed', icon = 'fa-gauge-high', title = 'Fly speed', kind = 'range', type = 'int', value = core_camera.getSpeed(ctxId) or 30, default = 30, min = 2, max = 100, step = 1, unit = 'm/s' },
    { key = 'smooth', icon = 'fa-wand-magic-sparkles', title = 'Smoothing', kind = 'bool', type = 'bool', value = self.smoothed == true },
    { key = 'newtonRot', icon = 'fa-arrows-spin', kind = 'bool', value = self.newtonRotation == true },
    { key = 'newtonTrans', icon = 'fa-up-down-left-right', kind = 'bool', value = self.newtonTranslation == true },
    { key = 'fov', icon = 'fa-expand', title = 'Field of view', kind = 'range', type = 'int', value = self.manualzoom and self.manualzoom.fov or 60, default = 60, min = 10, max = 140, step = 1, unit = '°' },
  }
end

function C:setParam(key, value, ctxId)
  if key == 'speed' then core_camera.setSpeed(clamp(tonumber(value) or 30, 2, 100), ctxId)
  elseif key == 'smooth' then self:setSmoothedCam(value and true or false)
  elseif key == 'fov' then self:setFOV(tonumber(value) or 60)
  elseif key == 'newtonRot' then self:setNewtonRotation(value and true or false)
  elseif key == 'newtonTrans' then self:setNewtonTranslation(value and true or false) end
end

function C:setRotation(rotation)
  local eulerYXZ = rotation:toEulerYXZ()
  eulerYXZ.y = -eulerYXZ.y
  self.rot:set(eulerYXZ)
end

function C:clearMotion()
  self.velocity:set(0, 0, 0)
  self.planarVelocity:set(0, 0, 0)
  self.angularVelocity:set(0, 0, 0)
end

function C:clearAngularMotion()
  self.angularVelocity:set(0, 0, 0)
end

function C:setPlanarTranslationInput(velocity, active)
  self.planarExternalInputActive = active == true and velocity ~= nil
  if self.planarExternalInputActive then
    self.planarExternalVelocity:set(velocity)
  else
    self.planarExternalVelocity:set(0, 0, 0)
  end
end

function C:clearPlanarTranslationInput()
  self.planarExternalInputActive = false
  self.planarExternalVelocity:set(0, 0, 0)
end

function C:clearPlanarTranslationMotion()
  self.planarVelocity:set(0, 0, 0)
  self:clearPlanarTranslationInput()
end

function C:onCameraChanged(focused)
  if not focused then return end
  self:reset()
end

local inputVec, acc, forceVec, tempVec = vec3(), vec3(), vec3(), vec3()
local desiredPlanarVelocity = vec3()
local qdir, qdirLook, qyaw = quat(), quat(), quat()

local function adjustedTranslationSpeed(self, data)
  if not self.planarTranslation then
    local modifiedSpeed = data.fastSpeedModifier and data.speed * 3 or data.speed
    return ((modifiedSpeed^2)/30) / 40
  end
  local speedMultiplier = data.fastSpeedModifier
    and (self.planarTranslationFastSpeedMultiplier or 1)
    or (self.planarTranslationSpeedMultiplier or 1)
  return ((data.speed^2)/30) / 40
    * (self.planarTranslationScale or 1)
    * speedMultiplier
end

local function updatePlanarVelocity(self, targetVelocity, hasInput, dt)
  if hasInput then
    local response = self.planarTranslationResponse or self.translationDrag
    local amount = 1 - math.exp(-response * dt)
    self.planarVelocity:set(
      push3(self.planarVelocity)
      + (push3(targetVelocity) - push3(self.planarVelocity)) * amount)
  else
    local drag = self.planarTranslationDrag or self.translationDrag
    self.planarVelocity:setScaled(math.exp(-drag * dt))
  end
end

local function terrainHeight(position)
  if not core_terrain or not core_terrain.getTerrain or not core_terrain.getTerrain() then return nil end
  return core_terrain.getTerrainHeight(position)
end

local function followTerrainHeight(self, previousHeight)
  if not previousHeight then return end
  local currentHeight = core_terrain.getTerrainHeight(self.pos)
  if currentHeight then
    self.pos.z = self.pos.z + (currentHeight - previousHeight)
  end
end

local function updatePlanarTranslation(self, data, adjustedSpeed)
  local previousTerrainHeight = terrainHeight(self.pos)
  qyaw:set(0, 0, 0, 1)
  setRotateEuler(self.rot.x, 0, 0, qyaw, qdirLook)
  tempVec:setRotate(qdirLook, inputVec)
  desiredPlanarVelocity:setScaled2(tempVec, adjustedSpeed * 15)
  local hasKeyboardInput = inputVec:squaredLength() > 0
  local hasExternalInput = self.planarExternalInputActive == true
  if hasExternalInput then
    desiredPlanarVelocity:setAdd(self.planarExternalVelocity)
  end
  updatePlanarVelocity(
    self,
    desiredPlanarVelocity,
    hasKeyboardInput or hasExternalInput,
    data.dt)
  self.pos:set(push3(self.pos) + push3(self.planarVelocity) * data.dt)
  followTerrainHeight(self, previousTerrainHeight)
end

local function updateStandardTranslation(self, data, adjustedSpeed)
  if self.newtonTranslation then
    local force = self.translationForce * adjustedSpeed
    if inputVec:squaredLength() > 0 then
      acc:setScaled2(inputVec, force / self.mass)
    end
    forceVec:setScaled2(acc, data.dt)
    forceVec:set(
      push3(forceVec)
      - push3(self.velocity) * math.min(self.translationDrag * data.dt, 1))
    self.velocity:setAdd(forceVec)
  else
    self.velocity:setScaled2(inputVec, adjustedSpeed * 15)
  end
  tempVec:setRotate(qdir, self.velocity)
  self.pos:set(push3(self.pos) + push3(tempVec) * data.dt)
  updatePlanarVelocity(
    self,
    self.planarExternalVelocity,
    self.planarExternalInputActive,
    data.dt)
  self.pos:set(push3(self.pos) + push3(self.planarVelocity) * data.dt)
end

function C:update(data)
  -- Rotation
  local dtFactor = data.dt * 200
  inputVec:set(
    MoveManager.yawRelative / dtFactor + (MoveManager.yawRight - MoveManager.yawLeft) * 0.07,
    MoveManager.pitchRelative / dtFactor + (MoveManager.pitchUp - MoveManager.pitchDown) * 0.07,
    MoveManager.rollRelative / dtFactor + (MoveManager.rollLeft - MoveManager.rollRight) * 0.07
  )
  if self.newtonRotation then
    acc:set(0,0,0)
    if inputVec:squaredLength() > 0 then
      acc:setScaled2(inputVec, self.angularForce / self.mass)
    end
    forceVec:setScaled2(acc, data.dt) -- Acceleration
    forceVec:set(push3(forceVec) - push3(self.angularVelocity) * math.min(self.angularDrag * data.dt, 1)) -- Drag
    self.angularVelocity:setAdd(forceVec)
  else
    self.angularVelocity:setScaled2(inputVec, 30)
  end

  self.rot:set(push3(self.rot) + push3(self.angularVelocity) * data.dt) -- Rotate
  self.rot.y = clamp(self.rot.y, -1.5706, 1.5706)

  qdir:set(0,0,0,1)
  setRotateEuler(self.rot.x, -self.rot.y, 0, qdir, qdirLook)
  setRotateEuler(0, 0, self.rot.z, qdirLook, qdir)

  -- Translation
  acc:set(0,0,0)
  inputVec:set(
    MoveManager.right - MoveManager.left + MoveManager.absXAxis,
    MoveManager.forward - MoveManager.backward + MoveManager.absYAxis,
    MoveManager.up - MoveManager.down + MoveManager.absZAxis
  )

  local adjustedSpeed = adjustedTranslationSpeed(self, data)
  if self.planarTranslation then
    updatePlanarTranslation(self, data, adjustedSpeed)
  else
    updateStandardTranslation(self, data, adjustedSpeed)
  end
  self:clearPlanarTranslationInput()

  data.res.rot = qdir
  data.res.pos:set(self.pos)

  self.manualzoom:update(data)
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
