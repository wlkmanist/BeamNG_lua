-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.__index = C
local safetyDistance = 0.1 -- camera will move this distance closer to the target, to help against stuff clipping into view from behind the camera

-- These are the assumed dimensions of the nearClip plane. TODO these could also be calculated using nearClip, window size and fov
local nearClipHalfWidth = 0.2
local nearClipHalfHeight = 0.1

local upVec = vec3(0, 0, 1)
local fwdVec = vec3(0, 1, 0)

-- per-instance state (each camera/renderview has its own collision filter), so split-screen
-- views don't share one distance and yank each other's zoom around
function C:init()
  self.lastDistance = nil
  self.lastNearClipCenter = nil
  self.rayIndex = 1
  self.checkAllCorners = true
  self.isFilter = true
  self.hidden = true
  self.smoother = nil
  self.collidingCamDist = nil
  self:onSettingsChanged()
end

function C:onSettingsChanged()
  self.enabled = settings.getValue('cameraCollision', true)
end

local dirTemp = vec3()
-- Catches geometry that the corner rays cannot see, one corner per call so these rays are round robined too
function C:isObstacleInFrontOfCam(rayDestinations, cornerIdx)
  local cornerPos = rayDestinations[cornerIdx]
  -- Test if we passed through a wall completely in one frame
  if self.lastNearClipCenter then
    dirTemp:setSub2(cornerPos, self.lastNearClipCenter)
    local rayDist = dirTemp:length()
    if castRayStatic(self.lastNearClipCenter, dirTemp, rayDist) < rayDist then
      return true
    end
  end
  -- Test the near clip plane edge starting at this corner for intersecting geometry
  dirTemp:setSub2(rayDestinations[(cornerIdx % 4) + 1], cornerPos)
  local dirLength = dirTemp:length()
  return castRayStatic(cornerPos, dirTemp, dirLength) < dirLength
end

local rayDestinations = {vec3(), vec3(), vec3(), vec3()}
local camDir, camRight, camUp, dir, nearClipCenter, rayStart, newCamPos = vec3(), vec3(), vec3(), vec3(), vec3(), vec3(), vec3()
function C:update(data)
  if not self.enabled then return end
  local assumedNearClipDist = data.res.nearClip - safetyDistance
  camDir:setRotate(data.res.rot, fwdVec)
  camUp:setRotate(data.res.rot, upVec)
  camDir:normalize()
  camUp:resize(nearClipHalfHeight)
  camRight:setCross(camDir, camUp)
  camRight:resize(nearClipHalfWidth)

  dir:set(push3(data.res.pos) - data.res.targetPos)
  local dirLength = dir:length()

  -- Calculate nearClip dimensions
  nearClipCenter:set(push3(data.res.targetPos) + push3(dir) * ((dirLength - assumedNearClipDist) / dirLength))

  -- set the ray destinations
  rayDestinations[1]:set(nearClipCenter); rayDestinations[1]:setAdd(camUp); rayDestinations[1]:setAdd(camRight)
  rayDestinations[2]:set(nearClipCenter); rayDestinations[2]:setSub(camUp); rayDestinations[2]:setAdd(camRight)
  rayDestinations[3]:set(nearClipCenter); rayDestinations[3]:setSub(camUp); rayDestinations[3]:setSub(camRight)
  rayDestinations[4]:set(nearClipCenter); rayDestinations[4]:setAdd(camUp); rayDestinations[4]:setSub(camRight)

  local closestHit = dirLength
  local hitRegistered = false

  -- Round robin: as long as nothing collides, only one corner is checked per frame. The frame one of
  -- its rays hits something, all 4 corners are cast right away and keep being cast every frame, until
  -- a frame comes back clean and we fall back to the round robin
  if not self.checkAllCorners then
    local cornerIdx = self.rayIndex
    self.rayIndex = (cornerIdx % 4) + 1
    rayStart:setSub2(rayDestinations[cornerIdx], dir)
    local distHit = castRayStatic(rayStart, dir, closestHit)
    if distHit < closestHit then
      closestHit = distHit
      self.checkAllCorners = true
    else
      self.checkAllCorners = self:isObstacleInFrontOfCam(rayDestinations, cornerIdx)
    end
  end

  if self.checkAllCorners then
    -- Make 4 parallel raycasts from the targetPos to the camera pos and position the camera based on the closest hit
    for i = 1, 4 do
      rayStart:setSub2(rayDestinations[i], dir)
      local distHit = castRayStatic(rayStart, dir, closestHit)
      if distHit < closestHit then
        closestHit = distHit
      end
    end
    hitRegistered = closestHit < dirLength
    self.checkAllCorners = hitRegistered
    closestHit = math.max(closestHit, 0.5)
  end

  if not self.smoother or not self.smoother.get then -- nil, or metatable stripped by a GE-reload deserialize
    self.smoother = newTemporalSmoothingNonLinear(1, 7, 0)
    self.smoother:set(closestHit)
  end

  local smoothedDistance = closestHit
  if self.lastDistance then
    local camDestDiff = (closestHit - self.lastDistance)
    if camDestDiff >= 0 then
      smoothedDistance = self.smoother:get(closestHit, data.dtReal)
    else
      self.smoother:set(smoothedDistance)
    end
  end

  self.lastDistance = smoothedDistance
  self.lastNearClipCenter = self.lastNearClipCenter or vec3()
  self.lastNearClipCenter:set(nearClipCenter)
  newCamPos:setScaled2(dir, 1 / (dirLength + 1e-30))
  newCamPos:setScaled(smoothedDistance + assumedNearClipDist)
  newCamPos:setAdd(data.res.targetPos)
  if hitRegistered then
    self.collidingCamDist = newCamPos:distance(data.res.targetPos)
  else
    self.collidingCamDist = nil
  end
  data.res.pos = newCamPos
end

function C:onVehicleSwitched()
  self:init()
end

function C:collidingCamDistance()
  return self.collidingCamDist
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
