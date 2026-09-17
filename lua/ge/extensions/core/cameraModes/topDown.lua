-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--- This is an example of a custom camera mode :D

local C = {}
C.__index = C

function C:init()
  self.disabledByDefault = true
  self.veloSmoother = newExponentialSmoothing(50, 1)
  self.vel = 0
  self.alignToCar = self.alignToCar or false -- false: north up (fixed); true: rotate with the vehicle heading
  self.tilt = self.tilt or 0                 -- degrees away from straight-down (0); 45 + ortho = isometric
  self.ortho = self.ortho or false           -- orthographic projection instead of perspective
  -- frame-rate independent low-pass on the tracked point and heading, so suspension/engine
  -- vibration isn't amplified into hectic frame motion by the camera's long boom (see update)
  self.posSmoothX = newTemporalSmoothingNonLinear(6)
  self.posSmoothY = newTemporalSmoothingNonLinear(6)
  self.posSmoothZ = newTemporalSmoothingNonLinear(6)
  self.dirSmoothX = newTemporalSmoothingNonLinear(6)
  self.dirSmoothY = newTemporalSmoothingNonLinear(6)
  self.snap = true
  C:onVehicleCameraConfigChanged()
end

function C:onVehicleCameraConfigChanged()
  self.fov = self.fov or 20
end

function C:update(data)
  -- horizontal velocity of the vehicle (engine-provided, double precision, zeroed on teleport).
  -- smooth the speed as it's too spiky otherwise, which results in bad camera movement
  local vel = data.vel:z0()
  local speed = vel:length()
  if data.dtSim > 0 then self.vel = self.veloSmoother:get(speed) end

  -- lead the camera toward where the car actually moves (velocity), not the way it points, so
  -- the lookahead doesn't swing around when the car spins, slides or reverses; the direction is
  -- dropped while crawling (it's just noise at near-zero speed)
  local dt = data.dt
  local moveDir = speed > 1 and vel:normalized() or vec3(0, 0, 0)
  local targetPos = data.pos + moveDir * math.min(10, 0.5 * self.vel)

  -- low-pass the tracked point; snap on (re)activation, teleport or any large jump so we never
  -- smear the camera across it
  local px, py, pz = self.posSmoothX, self.posSmoothY, self.posSmoothZ
  local snap = self.snap or data.teleported or (vec3(px:value(), py:value(), pz:value()) - targetPos):length() > 50
  if snap then px:set(targetPos.x); py:set(targetPos.y); pz:set(targetPos.z); self.snap = false end
  targetPos = vec3(px:get(targetPos.x, dt), py:get(targetPos.y, dt), pz:get(targetPos.z, dt))

  -- what sits at the top of the frame: north (fixed) by default, or the vehicle heading when
  -- aligned to the car
  local upRef
  if self.alignToCar then
    local ref  = vec3(data.veh:getNodePosition(self.refNodes.ref))
    local back = vec3(data.veh:getNodePosition(self.refNodes.back))
    upRef = (ref - back):z0():normalized()
    -- heading jitter is what swings the long boom around, so low-pass it too; renormalize, and
    -- fall back to the raw heading if smoothing ever collapses the vector (e.g. a ~180deg flip)
    if snap then self.dirSmoothX:set(upRef.x); self.dirSmoothY:set(upRef.y) end
    local sm = vec3(self.dirSmoothX:get(upRef.x, dt), self.dirSmoothY:get(upRef.y, dt), 0)
    if sm:length() > 1e-4 then upRef = sm:normalized() end
  else
    upRef = vec3(0, 1, 0) -- north (+Y)
  end

  -- tilt from straight-down (0deg) toward that direction so the camera leans into the view; it
  -- orbits the target at a constant distance, keeping the car's on-screen size as tilt changes
  local t = math.rad(self.tilt)
  local s, c = math.sin(t), math.cos(t)
  local fwd = upRef * s - vec3(0, 0, 1) * c   -- look direction (straight down at tilt 0)
  local camUp = upRef * c + vec3(0, 0, 1) * s -- perpendicular to fwd, so it becomes screen up
  local camPos = targetPos - fwd * (self.vel * 0.9 + 50)

  -- set the data, this needs to happen
  data.res.pos = camPos -- required, vec3()
  data.res.rot = quatFromDir(fwd, camUp) -- required, quat()
  data.res.fov = self.fov -- required
  data.res.targetPos = targetPos -- this is optional
  data.res.ortho = self.ortho -- orthographic projection (honoured by the render-view path)
  return true
end

function C:setRefNodes(centerNodeID, leftNodeID, backNodeID)
  self.refNodes = self.refNodes or {}
  self.refNodes.ref = centerNodeID
  self.refNodes.left = leftNodeID
  self.refNodes.back = backNodeID
end

-- Persist/restore this camera's own state for the video-stream views (see core_camera
-- get/setContextCameraState): the heading-alignment choice and zoom.
function C:serialize()
  return { alignToCar = self.alignToCar, fov = self.fov, tilt = self.tilt, ortho = self.ortho }
end

function C:deserialize(s)
  if type(s) ~= 'table' then return end
  if s.alignToCar ~= nil then self.alignToCar = s.alignToCar and true or false end
  if s.fov then self.fov = s.fov end
  if s.tilt then self.tilt = s.tilt end
  if s.ortho ~= nil then self.ortho = s.ortho and true or false end
end

-- Tunables for the camera-control / video-stream UI: heading alignment, tilt away from
-- straight-down, orthographic projection and FOV.
function C:listParams()
  return {
    { key = 'align', icon = 'fa-compass', kind = 'bool', value = self.alignToCar == true },
    { key = 'tilt', icon = 'fa-angle-down', kind = 'range', value = self.tilt, min = 0, max = 80, step = 1 },
    { key = 'ortho', icon = 'fa-vector-square', kind = 'bool', value = self.ortho == true },
    { key = 'fov', icon = 'fa-expand', title = 'Field of view', kind = 'range', type = 'int', value = self.fov, default = 20, min = 10, max = 140, step = 1, unit = '°' },
  }
end

function C:setParam(key, value)
  if key == 'align' then self.alignToCar = value and true or false
  elseif key == 'tilt' then self.tilt = clamp(tonumber(value) or 0, 0, 80)
  elseif key == 'ortho' then self.ortho = value and true or false
  elseif key == 'fov' then self.fov = tonumber(value) or self.fov end
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
