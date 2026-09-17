-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Script-driven free camera. Pose owned every frame — drive via core_camera:
--   core_camera.setByName('scriptedFree', false, { pos=..., yawDeg=..., locked=true })
--   core_camera.getGlobalCameras().scriptedFree:setPose(...) / :setTarget({...}) / :setLocked(...)
-- locked=true: script owns position (no WASD). allowLookWhenLocked=true: mouse look still works.
-- driveRot=false: setPose/setTarget ignore rotation (user aims while path drives pos).

local C = {}
C.__index = C

local function clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

local function lerpAngleDeg(a, b, t)
  local d = (b - a + 540) % 360 - 180
  return a + d * t
end

local function easeValue(u, ease)
  u = clamp01(u)
  if not ease or ease == "linear" then
    return u
  end
  if ease == "smoothstep" or ease == "easeInOut" then
    return u * u * (3 - 2 * u)
  end
  if ease == "easeIn" then
    return u * u * u
  end
  if ease == "easeOut" then
    local t = 1 - u
    return 1 - t * t * t
  end
  return u
end

local function yawPitchRollToQuat(yawDeg, pitchDownDeg, rollDeg)
  local yaw = math.rad(yawDeg or 0)
  local pitch = math.rad(pitchDownDeg or 0)
  local roll = math.rad(rollDeg or 0)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local sy, cy = math.sin(yaw), math.cos(yaw)
  local fwd = vec3(sy * cp, cy * cp, -sp)
  if fwd:squaredLength() < 1e-12 then
    fwd = vec3(0, 1, 0)
  else
    fwd:normalize()
  end
  local up0 = vec3(0, 0, 1) - fwd * vec3(0, 0, 1):dot(fwd)
  if up0:squaredLength() < 1e-12 then
    up0 = vec3(1, 0, 0) - fwd * vec3(1, 0, 0):dot(fwd)
  end
  up0:normalize()
  if math.abs(roll) > 1e-8 then
    local c, s = math.cos(roll), math.sin(roll)
    up0 = up0 * c + fwd:cross(up0) * s
    up0:normalize()
  end
  return quatFromDir(fwd, up0)
end

local function dirToYawPitch(dir)
  if not dir or dir:squaredLength() < 1e-12 then
    return 0, 0
  end
  local d = dir:normalized()
  local yaw = math.deg(math.atan2(d.x, d.y))
  local pitchDown = math.deg(math.asin(clamp( -d.z, -1, 1)))
  return yaw, pitchDown
end

function C:init()
  self.isGlobal = true
  self.hidden = true
  self.pos = vec3(0, 0, 0)
  self.yawDeg = 0
  self.pitchDeg = 0 -- + looks down (same as setFreeCameraYawPitchRollDeg)
  self.rollDeg = 0
  self.locked = false
  self.driveRot = true -- setPose/setTarget apply yaw/pitch/roll
  self.allowLookWhenLocked = false -- mouse look while locked (scripted path / fly-to)
  self.manualSpeed = 30
  self.lookSens = 2.2
  self.fov = 65
  self.allowLook = true
  self.allowMove = true
  -- Continuous follow smoothing (seconds to ~63%). 0 = snap on setPose.
  self.smoothPos = 0
  self.smoothRot = 0
  self.goalPos = vec3(0, 0, 0)
  self.goalYawDeg = 0
  self.goalPitchDeg = 0
  self.goalRollDeg = 0
  self.goalFov = 65
  self.anim = nil
end

function C:setCustomData(data)
  data = data or {}
  if data.pos then self:setPosition(data.pos) end
  if data.yawDeg ~= nil then self.yawDeg = data.yawDeg end
  if data.pitchDeg ~= nil then self.pitchDeg = data.pitchDeg end
  if data.rollDeg ~= nil then self.rollDeg = data.rollDeg end
  if data.locked ~= nil then self.locked = data.locked and true or false end
  if data.driveRot ~= nil then self.driveRot = data.driveRot and true or false end
  if data.allowLookWhenLocked ~= nil then self.allowLookWhenLocked = data.allowLookWhenLocked and true or false end
  if data.manualSpeed ~= nil then self.manualSpeed = data.manualSpeed end
  if data.lookSens ~= nil then self.lookSens = data.lookSens end
  if data.fov ~= nil then self.fov = data.fov end
  if data.allowLook ~= nil then self.allowLook = data.allowLook and true or false end
  if data.allowMove ~= nil then self.allowMove = data.allowMove and true or false end
  if data.smoothPos ~= nil then self.smoothPos = data.smoothPos end
  if data.smoothRot ~= nil then self.smoothRot = data.smoothRot end
  self.goalPos:set(self.pos)
  self.goalYawDeg = self.yawDeg
  self.goalPitchDeg = self.pitchDeg
  self.goalRollDeg = self.rollDeg
  self.goalFov = self.fov
end

function C:setPosition(position)
  if not position then
    return
  end
  self.pos:set(position)
  self.goalPos:set(position)
end

function C:setRotation(rotation)
  if not rotation then
    return
  end
  local euler = rotation:toEulerYXZ()
  self.yawDeg = math.deg(euler.x)
  self.pitchDeg = math.deg(-euler.y)
  self.rollDeg = math.deg(euler.z or 0)
  self.goalYawDeg = self.yawDeg
  self.goalPitchDeg = self.pitchDeg
  self.goalRollDeg = self.rollDeg
end

function C:setYawPitchRollDeg(yawDeg, pitchDownDeg, rollDeg)
  if yawDeg ~= nil then
    self.yawDeg = yawDeg
    self.goalYawDeg = yawDeg
  end
  if pitchDownDeg ~= nil then
    self.pitchDeg = pitchDownDeg
    self.goalPitchDeg = pitchDownDeg
  end
  if rollDeg ~= nil then
    self.rollDeg = rollDeg
    self.goalRollDeg = rollDeg
  end
end

function C:setPose(pos, yawDeg, pitchDeg, rollDeg)
  self.anim = nil
  local sp = self.smoothPos or 0
  local sr = self.smoothRot or 0
  if pos then
    if sp > 0 then
      self.goalPos:set(pos)
    else
      self.pos:set(pos)
      self.goalPos:set(pos)
    end
  end
  if self.driveRot ~= false and (yawDeg ~= nil or pitchDeg ~= nil or rollDeg ~= nil) then
    local y = yawDeg ~= nil and yawDeg or self.yawDeg
    local p = pitchDeg ~= nil and pitchDeg or self.pitchDeg
    local r = rollDeg ~= nil and rollDeg or self.rollDeg
    if sr > 0 then
      self.goalYawDeg, self.goalPitchDeg, self.goalRollDeg = y, p, r
    else
      self.yawDeg, self.pitchDeg, self.rollDeg = y, p, r
      self.goalYawDeg, self.goalPitchDeg, self.goalRollDeg = y, p, r
    end
  end
end

--- Continuous smoothing times (seconds). 0 = instant setPose.
function C:setSmooth(posSec, rotSec)
  if posSec ~= nil then self.smoothPos = math.max(0, posSec) end
  if rotSec ~= nil then self.smoothRot = math.max(0, rotSec) end
end

function C:setLocked(locked)
  self.locked = locked and true or false
end

function C:setDriveRot(enabled)
  self.driveRot = enabled and true or false
end

function C:setAllowLookWhenLocked(enabled)
  self.allowLookWhenLocked = enabled and true or false
end

function C:setManualSpeed(mps)
  self.manualSpeed = tonumber(mps) or self.manualSpeed
end

function C:setFOV(fovDeg)
  self.fov = tonumber(fovDeg) or self.fov
  self.goalFov = self.fov
end

function C:getPose()
  return self.pos, self.yawDeg, self.pitchDeg, self.rollDeg
end

function C:getQuat()
  return yawPitchRollToQuat(self.yawDeg, self.pitchDeg, self.rollDeg)
end

function C:isAnimating()
  return self.anim ~= nil
end

function C:cancelTarget()
  self.anim = nil
end

local function resolveTargetAngles(self, opts, toPos)
  if opts.lookAt then
    return dirToYawPitch(opts.lookAt - toPos)
  end
  if opts.dir then
    return dirToYawPitch(opts.dir)
  end
  if opts.rot then
    local euler = opts.rot:toEulerYXZ()
    return math.deg(euler.x), math.deg(-euler.y), math.deg(euler.z or 0)
  end
  return opts.yawDeg, opts.pitchDeg, opts.rollDeg
end

--- Timed blend to a pose. opts:
---   pos, dir|lookAt|yawDeg/pitchDeg/rollDeg/rot, time|duration, ease, fov, onDone, lockDuring
--- ease: linear | smoothstep | easeInOut | easeIn | easeOut
--- Rotation is skipped when driveRot is false (unless opts.forceRot).
function C:setTarget(opts)
  opts = opts or {}
  local duration = tonumber(opts.time or opts.duration) or 0
  local toPos = opts.pos and vec3(opts.pos) or vec3(self.pos)
  local applyRot = self.driveRot ~= false or opts.forceRot
  local y, p, r = self.yawDeg, self.pitchDeg, self.rollDeg
  if applyRot then
    local ry, rp, rr = resolveTargetAngles(self, opts, toPos)
    y = ry ~= nil and ry or y
    p = rp ~= nil and rp or p
    r = rr ~= nil and rr or r
  end
  local toFov = opts.fov ~= nil and opts.fov or self.fov

  if duration <= 0 then
    self.anim = nil
    local prevDrive = self.driveRot
    if not applyRot then self.driveRot = false end
    self:setPose(toPos, applyRot and y or nil, applyRot and p or nil, applyRot and r or nil)
    self.driveRot = prevDrive
    if opts.fov ~= nil then
      self:setFOV(toFov)
    end
    if opts.onDone then
      opts.onDone()
    end
    return
  end

  self.anim = {
    t = 0,
    duration = duration,
    fromPos = vec3(self.pos),
    toPos = toPos,
    fromYaw = self.yawDeg,
    fromPitch = self.pitchDeg,
    fromRoll = self.rollDeg,
    fromFov = self.fov,
    toFov = toFov,
    toYaw = y,
    toPitch = p,
    toRoll = r,
    applyRot = applyRot,
    ease = opts.ease or "smoothstep",
    onDone = opts.onDone,
    lockDuring = opts.lockDuring ~= false,
  }
  if self.anim.lockDuring then
    self.locked = true
  end
end

local function applyAnim(self, dt)
  local a = self.anim
  if not a then
    return false
  end
  a.t = a.t + dt
  local u = easeValue(a.t / a.duration, a.ease)
  self.pos:set(a.fromPos + (a.toPos - a.fromPos) * u)
  if a.applyRot ~= false then
    self.yawDeg = lerpAngleDeg(a.fromYaw, a.toYaw, u)
    self.pitchDeg = a.fromPitch + (a.toPitch - a.fromPitch) * u
    self.rollDeg = a.fromRoll + (a.toRoll - a.fromRoll) * u
  end
  self.fov = a.fromFov + (a.toFov - a.fromFov) * u
  self.goalPos:set(self.pos)
  self.goalYawDeg, self.goalPitchDeg, self.goalRollDeg = self.yawDeg, self.pitchDeg, self.rollDeg
  self.goalFov = self.fov
  if a.t >= a.duration then
    self.pos:set(a.toPos)
    if a.applyRot ~= false then
      self.yawDeg, self.pitchDeg, self.rollDeg = a.toYaw, a.toPitch, a.toRoll
    end
    self.fov = a.toFov
    self.goalPos:set(a.toPos)
    self.goalYawDeg, self.goalPitchDeg, self.goalRollDeg = self.yawDeg, self.pitchDeg, self.rollDeg
    self.goalFov = a.toFov
    local cb = a.onDone
    self.anim = nil
    if cb then
      cb()
    end
  end
  return true
end

local function applyFollowSmooth(self, dt, posOnly)
  local sp = self.smoothPos or 0
  local sr = 0
  if not posOnly and self.driveRot ~= false then
    sr = self.smoothRot or 0
  end
  if sp > 0 then
    local a = 1 - math.exp(-dt / sp)
    self.pos:set(self.pos + (self.goalPos - self.pos) * a)
  else
    self.pos:set(self.goalPos)
  end
  if sr > 0 then
    local a = 1 - math.exp(-dt / sr)
    self.yawDeg = lerpAngleDeg(self.yawDeg, self.goalYawDeg, a)
    self.pitchDeg = self.pitchDeg + (self.goalPitchDeg - self.pitchDeg) * a
    self.rollDeg = self.rollDeg + (self.goalRollDeg - self.rollDeg) * a
  elseif self.driveRot ~= false and not posOnly then
    self.yawDeg, self.pitchDeg, self.rollDeg = self.goalYawDeg, self.goalPitchDeg, self.goalRollDeg
  end
end

local function applyLookInput(self, dt)
  if self.allowLook == false then
    return false
  end
  local sens = self.lookSens or 2.2
  local dyaw = (MoveManager.yawRelative or 0) * sens
    + ((MoveManager.yawRight or 0) - (MoveManager.yawLeft or 0)) * 90 * dt
  local dpitch = -(MoveManager.pitchRelative or 0) * sens
    + ((MoveManager.pitchDown or 0) - (MoveManager.pitchUp or 0)) * 60 * dt
  local droll = ((MoveManager.rollRight or 0) - (MoveManager.rollLeft or 0)) * 60 * dt
  if (dyaw * dyaw + dpitch * dpitch + droll * droll) < 1e-12 then
    return false
  end
  self.yawDeg = self.yawDeg + dyaw
  self.pitchDeg = self.pitchDeg + dpitch
  self.rollDeg = self.rollDeg + droll
  if self.pitchDeg > 85 then self.pitchDeg = 85 end
  if self.pitchDeg < -85 then self.pitchDeg = -85 end
  self.goalYawDeg, self.goalPitchDeg, self.goalRollDeg = self.yawDeg, self.pitchDeg, self.rollDeg
  return true
end

function C:update(data)
  local dt = data.dt or 0
  if dt > 0.05 then
    dt = 0.05
  end

  local animating = false
  if self.anim and dt > 0 then
    animating = applyAnim(self, dt)
  end

  if animating or dt <= 0 then
    data.res.pos:set(self.pos)
    data.res.rot = yawPitchRollToQuat(self.yawDeg, self.pitchDeg, self.rollDeg)
    data.res.fov = self.fov or 65
    return true
  end

  local lookOk = (not self.locked) or self.allowLookWhenLocked
  if lookOk then
    applyLookInput(self, dt)
  end

  if self.locked then
    -- Script owns position; rotation is user (allowLookWhenLocked) and/or driveRot goals.
    applyFollowSmooth(self, dt, self.allowLookWhenLocked and self.driveRot == false)
  else
    if self.allowMove ~= false then
      local mx = (MoveManager.right or 0) - (MoveManager.left or 0) + (MoveManager.absXAxis or 0)
      local my = (MoveManager.forward or 0) - (MoveManager.backward or 0) + (MoveManager.absYAxis or 0)
      local mz = (MoveManager.up or 0) - (MoveManager.down or 0) + (MoveManager.absZAxis or 0)
      if (mx * mx + my * my + mz * mz) > 1e-8 then
        local yaw = math.rad(self.yawDeg)
        local pitch = math.rad(self.pitchDeg)
        local cp, sp = math.cos(pitch), math.sin(pitch)
        local sy, cy = math.sin(yaw), math.cos(yaw)
        local fwd = vec3(sy * cp, cy * cp, -sp)
        local right = vec3(cy, -sy, 0)
        local speed = self.manualSpeed or 30
        if data.fastSpeedModifier then
          speed = speed * 5
        end
        self.pos:set(self.pos + fwd * (my * speed * dt) + right * (mx * speed * dt) + vec3(0, 0, mz * speed * dt))
        self.goalPos:set(self.pos)
      end
    end
  end

  data.res.pos:set(self.pos)
  data.res.rot = yawPitchRollToQuat(self.yawDeg, self.pitchDeg, self.rollDeg)
  data.res.fov = self.fov or 65
  return true
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
