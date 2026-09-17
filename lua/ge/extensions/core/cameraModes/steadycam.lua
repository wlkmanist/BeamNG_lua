-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Steadycam: a first-person on-foot camera. Walk with WASD, look with the mouse,
-- sprint with the camera-fast modifier, jump with space. Gravity + a downward
-- raycast keep the operator standing on whatever ground is below (small ledges are
-- climbed, taller ones block, bigger drops make it fall). Turn grounding off
-- (groundWalk = false) for a free vertical fly instead.

local C = {}
C.__index = C

local manualzoom = require('core/cameraModes/manualzoom')

local up = vec3(0, 0, 1)
local downVec = vec3(0, 0, -1)
local fwd, move, origin = vec3(), vec3(), vec3()

-- world ground height under (x,y), searched downward from fromZ; nil if nothing within reach
local function groundZ(x, y, fromZ)
  local reach = 500
  origin:set(x, y, fromZ)
  local hit = castRayStatic(origin, downVec, reach)
  if hit >= reach then return nil end
  return fromZ - hit
end

function C:init()
  self.icon = "personSolid"
  self.isGlobal = true        -- not a per-vehicle camera slot
  self.group = "world"        -- lives in the world camera group
  self.groupOrder = 30        -- after free (10) and smoothFree (20)
  self.hidden = true
  -- tunables (exposed as camera-control / video-stream params and persisted)
  self.walkSpeed = self.walkSpeed or 2.45 -- m/s on foot
  self.groundWalk = self.groundWalk ~= false -- raycast grounding + gravity on by default
  self.manualzoom = manualzoom()
  self:onSettingsChanged()
  -- fixed feel constants (kept internal to avoid knob sprawl)
  self.runMult   = 2.0   -- sprint multiplier (camera-fast modifier)
  self.gravity   = 14    -- m/s^2, snappier than reality for a game feel
  self.jumpSpeed = 5.5   -- m/s, ~1.1 m hop
  self.stepHeight = 0.4  -- climb ledges up to this; taller ones are walls
  self.radius    = 0.35  -- body radius for wall stops
  self.mouseSens = 0.3
  self.keyLookRate = 1.75 -- rad/s for key/pad look
  self.lookSmooth = 16   -- look easing rate (1/s); lower = smoother/floatier
  self.moveSmooth = 6    -- walk accel / turn easing rate (1/s); lower = more body momentum
  self:reset()
end

function C:onSettingsChanged()
  self.eyeHeight = clamp(tonumber(settings.getValue('cameraSteadycamEyeHeight')) or 1.7, 1.0, 2.5)
  self.walkBobScale = clamp(tonumber(settings.getValue('cameraSteadycamWalkBob')) or 1, 0, 2)
  self.standingBobScale = clamp(tonumber(settings.getValue('cameraSteadycamStandingBob')) or 1, 0, 2)
  local configuredFov = clamp(tonumber(settings.getValue('cameraSteadycamFov')) or 60, 10, 140)
  if self.configuredFov ~= configuredFov then
    self.configuredFov = configuredFov
    self.manualzoom:init(configuredFov, 10, 140)
  end
end

function C:reset()
  self.pos = self.pos or vec3()
  self.yaw = self.yaw or 0
  self.pitch = self.pitch or 0
  self.yawSmooth, self.pitchSmooth = self.yaw, self.pitch
  self.vel = self.vel or vec3()
  self.vel:set(0, 0, 0)
  self.vz = 0
  self.grounded = false
  self.prevUp = 0
  self.bobPhase = 0
  self.t = 0
  self.phase = vec3(math.random(), math.random(), math.random()) * (2 * math.pi) -- random handheld sway offsets
  self.manualzoom:reset()
end

-- seeded by enterGroupCam on entry so we start where the view already was (no snap)
function C:setPosition(p) self.pos:set(p); self.vel:set(0, 0, 0); self.vz = 0; self.grounded = false end
function C:setRotation(q)
  fwd:set(0, 1, 0); fwd:setRotate(q) -- camera forward is +Y
  self.yaw = math.atan2(fwd.x, fwd.y)
  self.pitch = clamp(math.asin(clamp(fwd.z, -1, 1)), -1.5, 1.5)
  self.yawSmooth, self.pitchSmooth = self.yaw, self.pitch
end
function C:setFOV(fov)
  self.configuredFov = clamp(tonumber(fov) or self.configuredFov or 60, 10, 140)
  self.manualzoom:init(self.configuredFov, 10, 140)
end

-- push a tiny action map so space = jump while active, without disturbing the
-- vehicle's parking brake or the free camera elsewhere (see driver.lua)
function C:onCameraChanged(focused)
  if focused then
    pushActionMap("Steadycam")
    self.grounded = false
  else
    popActionMap("Steadycam")
  end
end

-- tunables for the camera-control / video-stream UI
function C:listParams()
  return {
    { key = 'height',     icon = 'fa-ruler-vertical', kind = 'range', value = self.eyeHeight, default = 1.7, min = 1.0, max = 2.5, step = 0.1 },
    { key = 'walkSpeed',  icon = 'fa-person-walking', kind = 'range', value = self.walkSpeed, min = 1,   max = 12,  step = 0.5 },
    { key = 'walkBob',    icon = 'fa-person-walking', kind = 'range', value = self.walkBobScale, default = 1, min = 0, max = 2, step = 0.1 },
    { key = 'standingBob', icon = 'fa-person', kind = 'range', value = self.standingBobScale, default = 1, min = 0, max = 2, step = 0.1 },
    { key = 'groundWalk', icon = 'fa-shoe-prints',    kind = 'bool',  value = self.groundWalk == true },
    { key = 'fov',        icon = 'fa-expand',         title = 'Field of view', kind = 'range', type = 'int', value = self.manualzoom.fov, default = 60, min = 10, max = 140, step = 1, unit = '°' },
  }
end

function C:setParam(key, value)
  if key == 'height' then self.eyeHeight = clamp(tonumber(value) or self.eyeHeight, 1.0, 2.5)
  elseif key == 'walkSpeed' then self.walkSpeed = clamp(tonumber(value) or self.walkSpeed, 1, 12)
  elseif key == 'walkBob' then self.walkBobScale = clamp(tonumber(value) or self.walkBobScale, 0, 2)
  elseif key == 'standingBob' then self.standingBobScale = clamp(tonumber(value) or self.standingBobScale, 0, 2)
  elseif key == 'groundWalk' then self.groundWalk = value and true or false
  elseif key == 'fov' then self:setFOV(tonumber(value) or self.manualzoom.fov) end
end

function C:serialize()
  return { fov = self.manualzoom.fov, height = self.eyeHeight, walkSpeed = self.walkSpeed,
           walkBob = self.walkBobScale, standingBob = self.standingBobScale, groundWalk = self.groundWalk }
end

function C:deserialize(s)
  if type(s) ~= 'table' then return end
  if s.fov then self:setFOV(s.fov) end
  if s.height then self.eyeHeight = s.height end
  if s.walkSpeed then self.walkSpeed = s.walkSpeed end
  if s.walkBob then self.walkBobScale = s.walkBob elseif s.bob then self.walkBobScale = s.bob / 0.6 end
  if s.standingBob then self.standingBobScale = s.standingBob elseif s.bob then self.standingBobScale = s.bob / 0.6 end
  if s.groundWalk ~= nil then self.groundWalk = s.groundWalk end
end

function C:update(data)
  data.res.collisionCompatible = false
  local dt = data.dt
  if dt <= 0 then dt = 1e-4 end
  self.t = self.t + dt

  -- look: mouse deltas (frame-cleared, already FOV-scaled) + key/pad rotate axes
  self.yaw = self.yaw + MoveManager.yawRelative * self.mouseSens
            + (MoveManager.yawRight - MoveManager.yawLeft) * self.keyLookRate * dt
  self.pitch = self.pitch + MoveManager.pitchRelative * self.mouseSens
            + (MoveManager.pitchUp - MoveManager.pitchDown) * self.keyLookRate * dt
  self.pitch = clamp(self.pitch, -1.5, 1.5)

  -- ease the displayed look toward the input target (fps-independent) so aim and
  -- the walk frame share one smooth, floaty orientation
  local rot = 1 - math.exp(-dt * self.lookSmooth)
  self.yawSmooth = self.yawSmooth + (self.yaw - self.yawSmooth) * rot
  self.pitchSmooth = self.pitchSmooth + (self.pitch - self.pitchSmooth) * rot

  local sy, cy = math.sin(self.yawSmooth), math.cos(self.yawSmooth)

  -- desired walk velocity in the look's horizontal frame: forward=(sin,cos), right=(cos,-sin)
  local mf = MoveManager.forward - MoveManager.backward + MoveManager.absYAxis
  local mr = MoveManager.right - MoveManager.left + MoveManager.absXAxis
  move:set(sy * mf + cy * mr, cy * mf - sy * mr, 0)
  local speed = self.walkSpeed * (data.fastSpeedModifier and self.runMult or 1)
  local inLen = move:length()
  if inLen > 0 then move:setScaled(math.min(inLen, 1) * speed / inLen) end -- target velocity (diagonals capped)

  -- ease velocity toward target so starts/stops and left<->forward turns carry body momentum
  local accel = 1 - math.exp(-dt * self.moveSmooth)
  self.vel.x = self.vel.x + (move.x - self.vel.x) * accel
  self.vel.y = self.vel.y + (move.y - self.vel.y) * accel

  local stepDist = 0
  local velLen = math.sqrt(self.vel.x * self.vel.x + self.vel.y * self.vel.y)
  if velLen > 1e-5 then
    move:set(self.vel.x / velLen, self.vel.y / velLen, 0) -- unit travel direction
    stepDist = velLen * dt
    if self.groundWalk then -- stop short of walls (ray at hip height so curbs below stepHeight don't block)
      origin:set(self.pos.x, self.pos.y, self.pos.z - self.eyeHeight + self.stepHeight + 0.1)
      local hit = castRayStatic(origin, move, stepDist + self.radius)
      stepDist = math.min(stepDist, math.max(0, hit - self.radius))
    end
    self.pos.x = self.pos.x + move.x * stepDist
    self.pos.y = self.pos.y + move.y * stepDist
  end

  if self.groundWalk then
    -- jump on the rising edge of the up axis (space via the Steadycam map, or PageUp)
    local upAxis = MoveManager.up
    if self.grounded and upAxis > 0.5 and self.prevUp <= 0.5 then
      self.vz = self.jumpSpeed
      self.grounded = false
    end
    self.prevUp = upAxis

    self.vz = self.vz - self.gravity * dt
    local newZ = self.pos.z + self.vz * dt
    local gz = groundZ(self.pos.x, self.pos.y, self.pos.z + self.stepHeight)
    local feetZ = gz and (gz + self.eyeHeight)
    -- while grounded, stick to ground that dips up to a step below the feet, so
    -- slopes/curbs are followed smoothly instead of free-falling each frame
    local stepDown = self.grounded and feetZ and (self.pos.z - feetZ) <= self.stepHeight
    if feetZ and self.vz <= 0 and (newZ <= feetZ or stepDown) then
      -- stand / land / step down; don't auto-climb past a step (taller rises blocked)
      self.pos.z = (feetZ - self.pos.z > self.stepHeight) and self.pos.z or feetZ
      self.vz = 0
      self.grounded = true
    elseif feetZ then
      self.pos.z = newZ
      self.grounded = false
    else
      self.vz = 0 -- no ground below (void): hover rather than fall forever
      self.grounded = false
    end
  else
    -- free vertical fly
    self.pos.z = self.pos.z + (MoveManager.up - MoveManager.down + MoveManager.absZAxis) * speed * dt
    self.vz, self.grounded = 0, false
  end

  -- footstep head-bob (vertical) + handheld "steadycam" sway, all scaled by bob
  local walkAmt = self.grounded and clamp(stepDist / dt / self.walkSpeed, 0, 1) or 0
  self.bobPhase = self.bobPhase + dt * (4 + walkAmt * 6)
  local walkBobScale = self.walkBobScale * 0.6
  local standingBobScale = self.standingBobScale * 0.6
  local bobUp = 0.035 * walkAmt * walkBobScale * math.abs(math.sin(self.bobPhase))

  -- gentle always-on handheld life (grows while walking), random per-axis phase
  local t, ph = self.t, self.phase
  local blendedBobScale = standingBobScale + (walkBobScale - standingBobScale) * walkAmt
  local amp = blendedBobScale * (0.6 + 0.8 * walkAmt)
  local swayPitch = amp * 0.006 * math.sin(0.8 * t + ph.y) + walkBobScale * 0.020 * walkAmt * math.sin(self.bobPhase + 1.2)
  local swayRoll  = amp * 0.012 * math.sin(0.5 * t + ph.z) + walkBobScale * 0.030 * walkAmt * math.sin(self.bobPhase * 0.5)
  local swayYaw   = amp * 0.006 * math.sin(0.7 * t + ph.x)

  -- standing still: someone holding a phone up to film -> slow breathing + big slow handheld wander
  local still = (1 - walkAmt) * standingBobScale
  if still > 0 then
    local breath  = math.sin(t * 1.2 + ph.x)                                  -- ~5s breath cycle
    local wanderP = math.sin(t * 0.8 + ph.y) + 0.5 * math.sin(t * 1.7 + ph.z) -- slow arms-drift, non-repeating
    local wanderY = math.sin(t * 0.6 + ph.z) + 0.5 * math.sin(t * 1.3 + ph.x)
    bobUp     = bobUp     + still * 0.016 * breath
    swayPitch = swayPitch + still * (0.012 * breath + 0.014 * wanderP)
    swayYaw   = swayYaw   + still * 0.016 * wanderY
    swayRoll  = swayRoll  + still * 0.010 * math.sin(t * 0.5 + ph.z)
  end

  local cp = math.cos(self.pitchSmooth)
  fwd:set(sy * cp, cy * cp, math.sin(self.pitchSmooth))
  local q = quatFromDir(fwd, up)
  if amp ~= 0 then q = q * quatFromEuler(swayPitch, swayRoll, swayYaw) end

  data.res.pos:set(self.pos.x, self.pos.y, self.pos.z + bobUp)
  data.res.rot = q
  data.res.fov = self.manualzoom.fov
  self.manualzoom:update(data)
  data.res.targetPos:set(self.pos.x + fwd.x * 10, self.pos.y + fwd.y * 10, self.pos.z + fwd.z * 10)
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
