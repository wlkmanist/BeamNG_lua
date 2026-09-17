-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Software TrackIR for the workbench "Virtual Camera" panel. A hidden running camera
-- filter (runningOrder), so it applies on top of EVERY camera mode - path, free,
-- relative, onboard, driver, orbit - exactly like hardware TrackIR. It is driven by the
-- colocated workbench plugin (com.beamng.virtualCamera.lua) over the websocket bridge
-- via core_camera.globalCameraFunction('phoneHeadTrack', ...). Inert (zero offset)
-- unless the panel arms it, so it has no effect on normal gameplay or other cameras.

local C = {}
C.__index = C

local deg2rad = math.pi / 180
local function clamp(v, lo, hi) return math.min(hi, math.max(lo, v)) end

-- camera-local euler axes: x = pitch (right), y = roll (forward), z = yaw (up).
-- NB: quat() with no args is (1,0,0,0) in BeamNG = a 180 deg flip about X, not identity,
-- so seed a real identity quat - a zero offset must be a true no-op.
local function buildOffset(yaw, pitch, roll)
  local q = quat(0, 0, 0, 1)
  q = quatFromEuler(0, 0, yaw) * q
  q = quatFromEuler(0, roll, 0) * q
  q = quatFromEuler(pitch, 0, 0) * q
  return q
end

function C:init()
  self.isGlobal = true
  self.isFilter = true
  self.hidden = true
  self.runningOrder = 0.55 -- just after trackir (0.5), before fallback (0.6) / gameengine (1.0)

  self.armed = false
  self.smoothing = 0.35      -- 0..1 (rotation)
  self.fovSmoothing = 0.3    -- 0..1
  self.target = vec3(0, 0, 0)  -- yaw, pitch, roll (radians)
  self.cur = vec3(0, 0, 0)
  self.fovTarget = 0           -- additive FOV offset (degrees)
  self.fovCur = 0
  self.level = false           -- auto-level: keep the horizon level (zero roll)
  self.sinceMsg = 1            -- seconds since the last update from the panel (stale guard)
end

-- driven by the workbench plugin via core_camera.globalCameraFunction:
function C:setArmed(a) self.armed = a and true or false; self.sinceMsg = 0 end
function C:setConfig(smoothing, fovSmoothing)
  if type(smoothing) == 'number' then self.smoothing = clamp(smoothing, 0, 1) end
  if type(fovSmoothing) == 'number' then self.fovSmoothing = clamp(fovSmoothing, 0, 1) end
end
function C:setTarget(yaw, pitch, roll)
  self.target:set((tonumber(yaw) or 0) * deg2rad, (tonumber(pitch) or 0) * deg2rad, (tonumber(roll) or 0) * deg2rad)
  self.sinceMsg = 0
end
function C:setFov(offset) self.fovTarget = clamp(tonumber(offset) or 0, -80, 80); self.sinceMsg = 0 end
function C:setLevel(on) self.level = on and true or false end

function C:update(data)
  if data.openxrSessionRunning then return true end -- don't fight VR head tracking
  local dt = data.dt or data.dtReal or 0
  self.sinceMsg = self.sinceMsg + (data.dtReal or dt)
  local active = self.armed and self.sinceMsg < 0.5

  -- FOV: ease toward the target (or zero) and add on top of the camera's own FOV
  local tauF = self.fovSmoothing * 0.6
  local aF = (tauF > 0 and dt > 0) and (1 - math.exp(-dt / tauF)) or 1
  self.fovCur = self.fovCur + ((active and self.fovTarget or 0) - self.fovCur) * aF
  if math.abs(self.fovCur) > 0.01 then
    data.res.fov = clamp((data.res.fov or 60) + self.fovCur, 10, 120)
  end

  -- rotation: ease toward the target (or zero), then pre-multiply (camera-local head-look)
  local tau = self.smoothing * 0.4
  local a = (tau > 0 and dt > 0) and (1 - math.exp(-dt / tau)) or 1
  local tx = active and self.target.x or 0
  local ty = active and self.target.y or 0
  local tz = active and self.target.z or 0
  self.cur:set(self.cur.x + (tx - self.cur.x) * a, self.cur.y + (ty - self.cur.y) * a, self.cur.z + (tz - self.cur.z) * a)
  if math.abs(self.cur.x) + math.abs(self.cur.y) + math.abs(self.cur.z) > 1e-4 then
    data.res.rot = buildOffset(self.cur.x, self.cur.y, self.cur.z) * data.res.rot
  end

  -- auto-level: rebuild the rotation from its forward with world up, zeroing roll while
  -- keeping the look direction. Applied while armed so it levels the base camera too.
  if active and self.level then
    local fwd = data.res.rot * vec3(0, 1, 0)
    if fwd:squaredLength() > 1e-6 then data.res.rot = quatFromDir(fwd, vec3(0, 0, 1)) end
  end
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
