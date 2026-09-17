-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local function drawSide(a, b, z, clrI)
  debugDrawer:drawTriSolid(
    vec3(a),
    vec3(a + z),
    vec3(b + z),
    clrI
  )
  debugDrawer:drawTriSolid(
    vec3(b + z),
    vec3(b),
    vec3(a),
    clrI
  )
  debugDrawer:drawTriSolid(
    vec3(a),
    vec3(b + z),
    vec3(a + z),
    clrI
  )
  debugDrawer:drawTriSolid(
    vec3(b + z),
    vec3(a),
    vec3(b),
    clrI
  )
end

function C:init(id)
  self.id = id
  self.visible = false

  self.pos = nil
  self.scale = vec3(1, 1, 1) -- kept for API compatibility
  self.parkingSpot = nil

  self.colorTimer = 0
  self.colorLerpDuration = 0.3

  self.mode = 'hidden'
  self.oldMode = 'hidden'
end

function C:update(dt, dtSim)
  self.colorTimer = self.colorTimer + dt
  if self.colorTimer >= self.colorLerpDuration then
    if self.mode == 'hidden' then
      self:hide()
    end
  end

  if not self.visible or not self.parkingSpot then return end

  local clr = {0, 0.4, 1}
  self.currentColor = ColorF(clr[1], clr[2], clr[3], 1)

  if self.parkingSpot and self.parkingSpot.pos and self.parkingSpot.rot and self.parkingSpot.scl then
    local pos = self.parkingSpot.pos
    local rot = self.parkingSpot.rot
    local scl = self.parkingSpot.scl
    local debugHeight = 1.33
    local x = rot * vec3(scl.x / 2, 0, 0)
    local y = rot * vec3(0, scl.y / 2, 0)
    local z = rot * vec3(0, 0, debugHeight / 2)
    local clrI = color(self.currentColor.r * 255, self.currentColor.g * 255, self.currentColor.b * 255, 0.25 * 255)

    drawSide(pos + x + y, pos + x - y, z, clrI)
    drawSide(pos + x - y, pos - x - y, z, clrI)
    drawSide(pos - x - y, pos - x + y, z, clrI)
    drawSide(pos - x + y, pos + x + y, z, clrI)
  end
end

function C:setToCheckpoint(wp)
  if not wp then return end

  self.parkingSpot = nil

  local parkingSpot = nil
  if wp.pos and wp.rot and wp.scl then
    parkingSpot = wp
  elseif wp.parkingSpot and wp.parkingSpot.pos and wp.parkingSpot.rot and wp.parkingSpot.scl then
    parkingSpot = wp.parkingSpot
  end

  if parkingSpot then
    self.parkingSpot = parkingSpot
    self.pos = vec3(parkingSpot.pos)
    self.scale = vec3(1, 1, 1)
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
