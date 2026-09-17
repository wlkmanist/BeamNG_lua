-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local markerPrefix = "direction_marker_"
local markerShape = "art/shapes/interface/s_mm_arrow_floating.dae"
local bobbingAmplitude = 0.08

local tmpOffset = vec3()
local tmpPos = vec3()
local tmpForward = vec3()
local markerLocalForward = vec3(0, 1, 0)
local defaultColor = {0, 0.4, 1}

local function asQuat(rot)
  if not rot then
    return quat(0, 0, 0, 1)
  end

  if type(rot) == "table" then
    return quat(rot.x or 0, rot.y or 0, rot.z or 0, rot.w or 1)
  end

  local ok, x, y, z, w = pcall(function()
    return rot.x, rot.y, rot.z, rot.w
  end)
  if ok then
    return quat(x or 0, y or 0, z or 0, w or 1)
  end

  return quat(0, 0, 0, 1)
end

local function applyMarkerColor(marker)
  if not marker then return end
  local arrowColor = (core_groundMarkers and core_groundMarkers.floatingArrowColor) or defaultColor
  local colorStr = string.format("%s %s %s 1", arrowColor[1], arrowColor[2], arrowColor[3])
  marker:setField("instanceColor", 0, colorStr)
  marker:setField("instanceColor1", 0, colorStr)
end

function C:init(id)
  self.id = id
  self.visible = false
  self.pos = nil
  self.rot = quat(0, 0, 0, 1)
  self.scale = vec3(1, 1, 1)
  self.markerId = nil
  self._ids = nil

  self.mode = "hidden"
  self.oldMode = "hidden"
end

function C:update(dt, dtSim)
  if not self.visible or not self.pos then return end

  local marker = self.markerId and scenetree.findObjectById(self.markerId)
  if not marker then return end

  local bobbing = math.sin(os.clock() * 3) * bobbingAmplitude
  tmpForward:setRotate(self.rot, markerLocalForward)
  tmpOffset:set(tmpForward.x * bobbing, tmpForward.y * bobbing, tmpForward.z * bobbing)
  tmpPos:set(self.pos)
  tmpPos:setAdd(tmpOffset)

  marker:setPosRot(tmpPos.x, tmpPos.y, tmpPos.z, self.rot.x, self.rot.y, self.rot.z, self.rot.w)
  marker:setScale(self.scale)
  marker:updateInstanceRenderData()
end

function C:setToCheckpoint(wp)
  if not wp or not wp.pos then return end

  self.pos = vec3(wp.pos)
  self.rot = asQuat(wp.rot)
  self.scale = vec3(1, 1, 1) * (wp.radius or 3)

  local marker = self.markerId and scenetree.findObjectById(self.markerId)
  if marker then
    applyMarkerColor(marker)
    marker:setPosRot(self.pos.x, self.pos.y, self.pos.z, self.rot.x, self.rot.y, self.rot.z, self.rot.w)
    marker:setScale(self.scale)
  end
end

function C:setMode(mode)
  if mode ~= "hidden" then
    self:show()
  else
    self:hide()
  end

  self.oldMode = self.mode
  self.mode = mode
  self:update(0, 0)
end

function C:setVisibility(v)
  self.visible = v

  local marker = self.markerId and scenetree.findObjectById(self.markerId)
  if marker then
    marker.hidden = not v
  end
end

function C:hide() self:setVisibility(false) end
function C:show() self:setVisibility(true) end

function C:createObject(shapeName, objectName)
  local marker = createObject("TSStatic")
  marker:setField("shapeName", 0, shapeName)
  marker:setPosition(vec3(0, 0, 0))
  marker.scale = vec3(1, 1, 1)
  marker:setField("rotation", 0, "1 0 0 0")
  marker.useInstanceRenderData = true
  marker:setField("instanceColor", 0, "1 1 1 1")
  marker:setField("instanceColor1", 0, "1 1 1 1")
  marker:setInternalName("marker")
  marker.canSave = false
  marker.hidden = true
  marker:registerObject(objectName)
  applyMarkerColor(marker)

  local scenarioObjectsGroup = scenetree.ScenarioObjectsGroup
  if scenarioObjectsGroup then
    scenarioObjectsGroup:addObject(marker)
  end

  return marker
end

function C:createMarkers()
  self:clearMarkers()
  self._ids = {}

  if not self.markerId then
    local marker = self:createObject(markerShape, markerPrefix .. self.id)
    self.markerId = marker:getId()
    table.insert(self._ids, self.markerId)
  end
end

function C:clearMarkers()
  for _, id in ipairs(self._ids or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:delete()
    end
  end

  self._ids = nil
  self.markerId = nil
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
