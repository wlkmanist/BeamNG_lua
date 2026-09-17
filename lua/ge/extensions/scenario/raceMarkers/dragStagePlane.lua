-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local white = color(255, 255, 255, 102)
local blue = color(26, 89, 255, 102)
local red = color(255, 0, 0, 102)

function C:init(id)
  self.id = id
  self.visible = false
  self.mode = "hidden"
  self.center = vec3()
  self.across = vec3(1, 0, 0)
  self.up = vec3(0, 0, 1)
  self.normal = vec3(0, 1, 0)
  self.distanceToCar = 0
  self.isValidStage = false
  self.halfWidth = 2
  self.height = 0.5
  self.showDistance = 25
  self.planeHeight = 0.15
end

function C:createMarkers()
  self._ids = self._ids or {}
end

function C:clearMarkers()
  self._ids = nil
end

function C:setToCheckpoint(wp)
  if not wp then return end
  if wp.pos then
    self.center = vec3(wp.pos)
  end
end

function C:setPlane(center, across, up, halfWidth, height)
  if center then
    self.center = vec3(center)
  end
  if across and across:length() > 1e-6 then
    self.across = vec3(across):normalized()
  end
  if up and up:length() > 1e-6 then
    self.up = vec3(up):normalized()
  end
  if halfWidth then
    self.halfWidth = math.max(0.05, halfWidth)
  end
  if height then
    self.height = math.max(0.05, height)
  end
end

function C:getShowDistance()
  return self.showDistance
end

function C:updateFromStaging(stageTransform, distanceToStage, isValidStage)
  if not stageTransform then return nil end
  local halfWidth = math.max(2.75, ((stageTransform.scale and stageTransform.scale.x) or 4) * 0.65)
  self:setPlane(stageTransform.position, stageTransform.x, vec3(0, 0, 1), halfWidth, self.planeHeight)
  if stageTransform.y and stageTransform.y:length() > 1e-6 then
    self.normal = vec3(stageTransform.y):normalized()
  end
  self.distanceToCar = distanceToStage or 0
  self.isValidStage = isValidStage and true or false
end

function C:setMode(mode)
  self.mode = mode or "hidden"
  if self.mode == "hidden" then
    self:hide()
  else
    self:show()
  end
end

function C:setVisibility(v)
  self.visible = v and true or false
end

function C:hide()
  self:setVisibility(false)
end

function C:show()
  self:setVisibility(true)
end

local A = vec3() -- start line left (bottom)
local B = vec3() -- start line right (bottom)
local Cp = vec3() -- player line left (bottom)
local Dp = vec3() -- player line right (bottom)
local AInset = vec3()
local BInset = vec3()
local CInset = vec3()
local DInset = vec3()
local AInsetTop = vec3()
local CInsetTop = vec3()
local ATop = vec3()
local BTop = vec3()
local CTop = vec3()
local DTop = vec3()
local insetDistance = 0.4
local regularMarkerSpacing = 1

local function drawDoubleSidedFace(a, b, c, d, col)
  -- front side
  debugDrawer:drawTriSolid(a, b, c, col)
  debugDrawer:drawTriSolid(c, d, a, col)
  -- back side
  debugDrawer:drawTriSolid(b, a, c, col)
  debugDrawer:drawTriSolid(d, c, a, col)
end

local markerBase = vec3()
local markerInset = vec3()
local markerBaseTop = vec3()
local markerInsetTop = vec3()

function C:update(dt, dtSim)
  if not self.visible then return end

  A:set(self.center - self.across * self.halfWidth)
  B:set(self.center + self.across * self.halfWidth)
  AInset:set(A + self.across * insetDistance)
  BInset:set(B - self.across * insetDistance)
  local offset = self.normal * self.distanceToCar
  Cp:set(A + offset)
  Dp:set(B + offset)
  CInset:set(Cp + self.across * insetDistance)
  DInset:set(Dp - self.across * insetDistance)

  ATop:set(A + self.up * self.height)
  BTop:set(B + self.up * self.height)
  CTop:set(Cp + self.up * self.height)
  DTop:set(Dp + self.up * self.height)
  AInsetTop:set(AInset + self.up * self.height)
  CInsetTop:set(CInset + self.up * self.height)

  local col = white
  if self.isValidStage then
    col = blue
  elseif self.distanceToCar > 0 then
    -- Past the stage line: show overshoot in red.
    col = red
  end

  -- AB: start line face
  drawDoubleSidedFace(A, ATop, AInsetTop, AInset, col)
  -- CD: player line face
  drawDoubleSidedFace(Cp, CTop, CInsetTop, CInset, col)

  -- AC + BD: side faces
  drawDoubleSidedFace(A, ATop, CTop, Cp, col)
  --drawDoubleSidedFace(B, BTop, DTop, Dp, col)

  local ac = Cp - A
  local acLen = ac:length()
  if acLen > 1e-4 then
    local acDir = ac / acLen
    local markerInsetDistance = insetDistance * 0.5
    local t = regularMarkerSpacing
    while t <= acLen + 1e-6 do
      markerBase:set(A + acDir * t)
      markerInset:set(markerBase + self.across * markerInsetDistance)
      markerBaseTop:set(markerBase + self.up * self.height)
      markerInsetTop:set(markerInset + self.up * self.height)
      drawDoubleSidedFace(markerBase, markerBaseTop, markerInsetTop, markerInset, col)
      t = t + regularMarkerSpacing
    end
  end


end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
