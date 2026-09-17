-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local outlineShape = "art/shapes/interface/park_outline_marker.dae"
local groundDecalTexture = "art/shapes/interface/parkDecalStripes.png"

local decalFadeStart, decalFadeEnd = 3.5, 6
local colorRate = 8 -- temporal smoothing rate for color transitions

local outlineAlphaOverride = 1.0
local outlineHeight = 1.2
local outlineStackCount = 3
local decalAlphaMul = 0.9

function C:init(id)
  self.id = tostring(id or "parkingraceSpotMarker")
  self.visible = false

  self.pos = vec3(0, 0, 0)
  self.rot = quat(0, 0, 0, 1)
  self.scl = vec3(2.5, 5, 0.5)

  self.targetColor = {1, 1, 1, 1}
  self.currentColor = {1, 1, 1, 1}

  self.colorSmootherR = newTemporalSmoothingNonLinear(colorRate, colorRate, 1)
  self.colorSmootherG = newTemporalSmoothingNonLinear(colorRate, colorRate, 1)
  self.colorSmootherB = newTemporalSmoothingNonLinear(colorRate, colorRate, 1)
  self.colorSmootherA = newTemporalSmoothingNonLinear(colorRate, colorRate, 1)

  self.outlineIds = {}
  self.groundDecalData = nil
  self._decalsArr = {nil}
end

function C:createMarkers()
  self:clearMarkers()

  for i = 1, outlineStackCount do
    local outline = createObject("TSStatic")
    outline:setField("shapeName", 0, outlineShape)
    outline:setPosition(vec3(0, 0, 0))
    outline.scale = vec3(1, 1, 1)
    outline.useInstanceRenderData = true
    outline:setField("instanceColor", 0, "1 1 1 1")
    outline:setField("collisionType", 0, "None")
    outline:setField("decalType", 0, "None")
    outline.canSave = false
    outline.hidden = true
    outline:registerObject(self.id .. "_outline_" .. i)
    self.outlineIds[i] = outline:getId()
  end

  -- Decal data is filled in by setSpot() and color is updated each frame.
  self.groundDecalData = {
    texture = groundDecalTexture,
    position = vec3(self.pos),
    forwardVec = self.rot * vec3(0, 1, 0),
    color = ColorF(1, 1, 1, 0.35),
    scale = vec3(self.scl.x, self.scl.y, 1),
    fadeStart = decalFadeStart,
    fadeEnd = decalFadeEnd,
  }
  self._decalsArr[1] = self.groundDecalData
end

function C:clearMarkers()
  for i, id in ipairs(self.outlineIds) do
    -- The underlying TSStatic may already be gone if the level/scene was torn
    -- down before us, so re-resolve via scenetree before calling :delete().
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:delete()
    end
    self.outlineIds[i] = nil
  end
  self.groundDecalData = nil
  self._decalsArr[1] = nil
end

-- Configure the marker for a parking spot: pos (vec3), rot (quat), scl (vec3).
-- pos is the spot center, scl is the FULL spot size on each axis.
function C:setSpot(pos, rot, scl)
  if pos then self.pos:set(pos) end
  if rot then self.rot = quat(rot.x, rot.y, rot.z, rot.w) end
  if scl then self.scl:set(scl) end

  local tq = self.rot:toTorqueQuat()
  local rotStr = tq.x .. " " .. tq.y .. " " .. tq.z .. " " .. tq.w
  for _, id in ipairs(self.outlineIds) do
    local outline = scenetree.findObjectById(id)
    if outline then
      outline:setPositionXYZ(self.pos.x, self.pos.y, self.pos.z)
      outline:setField("rotation", 0, rotStr)
      -- Mirror parkingMarker.lua's XY scaling convention so existing art
      -- assets line up with the spot footprint, but use a real vertical
      -- height so the outline reads as a fence, not a paper-thin border.
      outline:setScaleXYZ(self.scl.x, self.scl.y / 2.05, outlineHeight)
    end
  end

  if self.groundDecalData then
    self.groundDecalData.position:set(self.pos)
    self.groundDecalData.forwardVec = self.rot * vec3(0, 1, 0)
    self.groundDecalData.scale:set(self.scl.x, self.scl.y, 1)
  end
end

-- Set the target color (smoothed). Accepts either {r,g,b,a} or a ColorF-like
-- table with .r/.g/.b/.a fields.
function C:setColor(color)
  if not color then return end
  self.targetColor[1] = color[1] or color.r or self.targetColor[1]
  self.targetColor[2] = color[2] or color.g or self.targetColor[2]
  self.targetColor[3] = color[3] or color.b or self.targetColor[3]
  self.targetColor[4] = color[4] or color.a or self.targetColor[4]
end

function C:setVisibility(v)
  self.visible = v
  for _, id in ipairs(self.outlineIds) do
    local outline = scenetree.findObjectById(id)
    if outline then outline.hidden = not v end
  end
end

function C:show() self:setVisibility(true) end
function C:hide() self:setVisibility(false) end

function C:update(dt)
  if not self.visible then return end

  self.currentColor[1] = self.colorSmootherR:get(self.targetColor[1], dt)
  self.currentColor[2] = self.colorSmootherG:get(self.targetColor[2], dt)
  self.currentColor[3] = self.colorSmootherB:get(self.targetColor[3], dt)
  self.currentColor[4] = self.colorSmootherA:get(self.targetColor[4], dt)

  local clr = ColorF(self.currentColor[1], self.currentColor[2], self.currentColor[3], outlineAlphaOverride)
  local linClr = clr:asLinear4F()
  for _, id in ipairs(self.outlineIds) do
    local outline = scenetree.findObjectById(id)
    if outline then
      outline.instanceColor = linClr
      outline:updateInstanceRenderData()
    end
  end

  if self.groundDecalData and Engine and Engine.Render and Engine.Render.DynamicDecalMgr then
    self.groundDecalData.color = ColorF(
      self.currentColor[1],
      self.currentColor[2],
      self.currentColor[3],
      (self.currentColor[4] or 1) * decalAlphaMul
    )
    Engine.Render.DynamicDecalMgr.addDecals(self._decalsArr, 1)
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
