-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local function lerp(a, b, t)
  return a + (b - a) * t
end

-- called when this object is created. initialize variables here (but dont spawn objects)
function C:init(id)
  self.id = id
  self.visible = false

  self.pos = nil
  self.scale = vec3(1, 1, 1) -- kept for API compatibility
  self.zone = nil

  self.colorTimer = 0
  self.colorLerpDuration = 0.3

  self.mode = 'hidden'
  self.oldMode = 'hidden'
  self.fenceHeight = 0.33
  self.countdownRemaining = nil
  self.countdownTotal = nil
  self.countdownDone = false
  self.rising = false
  self.currentColor = ColorF(0, 0.4, 1, 1)
end

-- called every frame to update the visuals.
function C:update(dt, dtSim)
  self.colorTimer = self.colorTimer + dt
  if self.colorTimer >= self.colorLerpDuration then
    if self.mode == 'hidden' then
      self:hide()
    end
  end

  if not self.visible or not self.zone then return end

  local blue = {0, 0.4, 1}
  local yellow = {1.0, 0.9, 0.1}
  local orange = {1.0, 0.55, 0.1}
  local darkOrange = {0.68, 0.28, 0.05}

  local targetColor = blue
  if self.rising then
    targetColor = darkOrange
  elseif self.countdownDone then
    -- Snap to dark orange once countdown is complete.
    self.currentColor = ColorF(darkOrange[1], darkOrange[2], darkOrange[3], 1)
    targetColor = nil
  elseif self.countdownTotal and self.countdownTotal > 0 and self.countdownRemaining ~= nil then
    local t = clamp(1 - (self.countdownRemaining / self.countdownTotal), 0, 1)
    targetColor = {
      lerp(yellow[1], orange[1], t),
      lerp(yellow[2], orange[2], t),
      lerp(yellow[3], orange[3], t)
    }

  end

  if targetColor then
    local a = clamp((dt or 0) * 4, 0, 1)
    self.currentColor = ColorF(
      lerp(self.currentColor.r, targetColor[1], a),
      lerp(self.currentColor.g, targetColor[2], a),
      lerp(self.currentColor.b, targetColor[3], a),
      1
    )
  end

  if self.zone and self.zone.drawDebug then
    -- Draw only boundary/outline, no overhead mesh object.
    self.zone:drawDebug('faded', {self.currentColor.r, self.currentColor.g, self.currentColor.b, 0.25}, self.fenceHeight or 0.33)
  end
end

-- setting it to represent checkpoints.
-- supports regular waypoint data (with pos/radius) and zone objects.
function C:setToCheckpoint(wp)
  if not wp then return end

  self.zone = nil

  local zone = nil
  if wp.drawDebug and wp.vertices then
    zone = wp
  elseif wp.zone and wp.zone.drawDebug then
    zone = wp.zone
  end

  if zone then
    self.zone = zone
    if zone.center then
      self.pos = vec3(zone.center)
    elseif zone.vertices and zone.vertices[1] and zone.vertices[1].pos then
      self.pos = vec3(zone.vertices[1].pos)
    end
    if self.pos and core_terrain.getTerrain() and core_terrain.getTerrainHeight(self.pos) > 0 then
      self.pos.z = core_terrain.getTerrainHeight(self.pos) + 2
    end
    self.scale = vec3(1, 1, 1) * (wp.radius or 1.5)
  else
    self.pos = wp.pos and vec3(wp.pos) or self.pos
    self.scale = vec3(1, 1, 1) * (wp.radius or 1.5)
  end
end

function C:setMode(mode)
  if mode ~= 'hidden' then
    self:show()
  else
    self:hide()
  end
  self.oldMode = self.mode
  self.mode = mode
  self.colorTimer = 0

  self:update(0, 0)
end

function C:setFenceHeight(h)
  self.fenceHeight = h or self.fenceHeight
end

function C:setCountdown(remaining, total, done)
  self.countdownRemaining = remaining
  self.countdownTotal = total
  self.countdownDone = done or false
end

function C:setRising(v)
  self.rising = v and true or false
end

-- visibility management
function C:setVisibility(v)
  self.visible = v
end

function C:hide() self:setVisibility(false) end
function C:show() self:setVisibility(true) end

-- kept for API compatibility with other marker types.
function C:createMarkers()
  self._ids = self._ids or {}
end

function C:clearMarkers()
  self._ids = nil
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
