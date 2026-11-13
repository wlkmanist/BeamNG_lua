-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.__index = C

function C:init()
  self.isFilter = true
  self.hidden = true
  self:onSettingsChanged()
  self:reset()
end

function C:onSettingsChanged()
  self.walkBobScale = clamp(tonumber(settings.getValue('cameraSteadycamWalkBob')) or 1, 0, 2)
  self.standingBobScale = clamp(tonumber(settings.getValue('cameraSteadycamStandingBob')) or 1, 0, 2)
end

function C:reset()
  self.t = 0
  self.bobPhase = 0
  self.phase = vec3(math.random(), math.random(), math.random()) * (2 * math.pi)
end

function C:update(data, walkAmt, dt)
  if data.openxrSessionRunning then return true end

  dt = dt or data.dt
  if dt <= 0 then return true end

  walkAmt = clamp(walkAmt or 0, 0, 1)
  self.t = self.t + dt
  self.bobPhase = self.bobPhase + dt * (4 + walkAmt * 6)

  local walkBobScale = self.walkBobScale * 0.6
  local standingBobScale = self.standingBobScale * 0.6
  local bobUp = 0.035 * walkAmt * walkBobScale * math.abs(math.sin(self.bobPhase))

  local t, ph = self.t, self.phase
  local blendedBobScale = standingBobScale + (walkBobScale - standingBobScale) * walkAmt
  local amp = blendedBobScale * (0.6 + 0.8 * walkAmt)
  if amp == 0 then return true end

  local swayPitch = amp * 0.006 * math.sin(0.8 * t + ph.y) + walkBobScale * 0.020 * walkAmt * math.sin(self.bobPhase + 1.2)
  local swayRoll = amp * 0.012 * math.sin(0.5 * t + ph.z) + walkBobScale * 0.030 * walkAmt * math.sin(self.bobPhase * 0.5)
  local swayYaw = amp * 0.006 * math.sin(0.7 * t + ph.x)

  local still = (1 - walkAmt) * standingBobScale
  if still > 0 then
    local breath = math.sin(t * 1.2 + ph.x)
    local wanderP = math.sin(t * 0.8 + ph.y) + 0.5 * math.sin(t * 1.7 + ph.z)
    local wanderY = math.sin(t * 0.6 + ph.z) + 0.5 * math.sin(t * 1.3 + ph.x)
    bobUp = bobUp + still * 0.016 * breath
    swayPitch = swayPitch + still * (0.012 * breath + 0.014 * wanderP)
    swayYaw = swayYaw + still * 0.016 * wanderY
    swayRoll = swayRoll + still * 0.010 * math.sin(t * 0.5 + ph.z)
  end

  data.res.pos = data.res.pos + vec3(0, 0, bobUp)
  data.res.rot = data.res.rot * quatFromEuler(swayPitch, swayRoll, swayYaw)
  return true
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
