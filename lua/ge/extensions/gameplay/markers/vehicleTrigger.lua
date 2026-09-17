-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local vecZero = vec3(0,0,0)
local quatZero = quat(0,0,0,0)
local vecX = vec3(1,0,0)
local vecY = vec3(0,1,0)
local vecZ = vec3(0,0,1)
local lineColorF = ColorF(1,1,1,1)
local playModeColorI = ColorI(255,255,255,255)
local iconRendererObj
local iconWorldSize = 20
local tmpVec = vec3()
local maxVisibleDistance = 15
local screenObjTemp = nil

function C:init()
  self.visible = true
end

function C:setup(cluster)
  self.pos = cluster.pos or vecZero
  self.rot = cluster.rot or quatZero
  self.scl = cluster.scl or vecZero

  self.cluster = cluster
  self.iconOffsetHeight = 1.45
  self.iconLift = 0.25

  self.doors = {}
  self.iconLift = cluster.iconLift or 0.25
  self.iconOffsetHeight = cluster.iconOffsetHeight or 1.45

  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
  for idx, ntuple in ipairs(cluster.doors or {}) do
    local area = scenetree.findObject(ntuple[1])
    local icon = scenetree.findObject(ntuple[2])
    if area and icon then
      local pos, rot, scl = area:getPosition(), quat(area:getRotation()), area:getScale()
      local zVec, yVec, xVec = rot*vecZ*scl.z, rot*vecY*scl.y, rot*vecX*scl.x
      local iconPos = icon:getPosition()

      local doorData = {
         areaPos = pos,
         xVec = xVec, yVec = yVec, zVec = zVec,
         iconPos = iconPos,
         iconPosSmoother = newTemporalSmoothingNonLinear(10,10),
         iconAlphaSmoother = newTemporalSmoothingNonLinear(20,20),
         overlap = false,
         maxVisibleDistance = ntuple[3] or maxVisibleDistance
      }
      if (cluster.screens or {})[idx] then
        local screenObj = scenetree.findObject((cluster.screens or {})[idx])
        if screenObj then
          doorData.screenObjId = screenObj:getId()
          doorData.screenTimer = 0
          screenObj:setHidden(true)
        end
      end

      if iconRendererObj then
        local iconId = iconRendererObj:addIcon(string.format("%s-vtIcon-%d",cluster.id, idx), cluster.icon, iconPos)
        local iconInfo = iconRendererObj:getIconById(iconId)
        iconInfo.color = ColorI(255,255,255,0)
        iconInfo.customSize = iconWorldSize
        iconInfo.drawIconShadow = false

        doorData.iconId = iconId
        doorData.iconInfo = iconInfo
      end

      table.insert(self.doors, doorData)
    end
  end
end

function C:update(data)
  if not self.visible then return end

  local anyOverlap = false
  if data.veh then
    for _, door in ipairs(self.doors or {}) do
      local overlap = overlapsOBB_OBB(data.bbCenter, data.bbHalfAxis0, data.bbHalfAxis1, data.bbHalfAxis2, door.areaPos, door.xVec, door.yVec, door.zVec)
      anyOverlap = anyOverlap or overlap
    end
  end

  for idx, area in ipairs(self.doors or {}) do
    screenObjTemp = scenetree.findObjectById(area.screenObjId) or nil

    if anyOverlap and not area.overlap then
      if screenObjTemp then
        Engine.Audio.playOnce('AudioGui','event:>UI>Career>Computer', {position = vec3(self.pos.x, self.pos.y, self.pos.z)})
      end
      area.overlap = true
    end
    if not anyOverlap and area.overlap then
      area.overlap = false
    end
    if screenObjTemp then
      if area.overlap then
        area.screenTimer = 5
      end
      area.screenTimer = area.screenTimer - data.dt
      screenObjTemp:setHidden(area.screenTimer < 0)
    end

    area.overlap = anyOverlap

    local iconInfo = area.iconInfo
    if iconInfo then
      local iconPos = iconInfo.worldPosition
      tmpVec:set(data.camPos)
      tmpVec:setSub(iconPos)
      local rayLength = tmpVec:length()

      local visible = rayLength < area.maxVisibleDistance and castRayStatic(iconPos, tmpVec, rayLength, nil) >= rayLength

      local smootherVal = area.iconPosSmoother:get((not data.bigMapActive and anyOverlap) and 1 or 0, data.dt)
      tmpVec:set(0,0,self.iconOffsetHeight + smootherVal*self.iconLift)
      tmpVec:setAdd(area.iconPos)
      iconInfo.worldPosition = tmpVec
      playModeColorI.alpha = area.iconAlphaSmoother:get((not data.bigMapActive and visible) and 1 or 0, data.dt) * 255
      iconInfo.color = playModeColorI
      if smootherVal > 0.1 then
        debugDrawer:drawLine(area.iconPos + vec3(0,0,self.iconOffsetHeight - smootherVal * self.iconOffsetHeight), tmpVec, lineColorF)
      end
    end
  end

  if anyOverlap ~= self.isInAreaLastFrame then
    if anyOverlap then self.isInAreaChanged = "in" end
    if not anyOverlap then self.isInAreaChanged = "out" end
  else
    self.isInAreaChanged = nil
  end
  self.isInAreaLastFrame = anyOverlap

  self.anyOverlap = anyOverlap
end

function C:createObjects()
  self:clearObjects()
end

function C:hide()
  if not self.visible then return end
  self.visible = false
  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
  if iconRendererObj then
    for idx, area in ipairs(self.doors or {}) do
      playModeColorI.alpha = 0
      area.iconInfo.color = playModeColorI
    end
  end
  for idx, area in ipairs(self.doors or {}) do
    if area.screenObjId then
      screenObjTemp = scenetree.findObjectById(area.screenObjId)
      if screenObjTemp then screenObjTemp:setHidden(true) end
    end
  end
end

function C:show()
  if self.visible then return end
  self.visible = true
end

function C:clearObjects()
  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
  if iconRendererObj then
    for idx, area in ipairs(self.doors or {}) do
      iconRendererObj:removeIconById(area.iconId)
    end
  end
  for idx, area in ipairs(self.doors or {}) do
    if area.screenObjId then
      screenObjTemp = scenetree.findObjectById(area.screenObjId)
      if screenObjTemp then screenObjTemp:setHidden(true) end
    end
  end
  self.doors = nil
end

function C:interactInPlayMode(interactData, interactableElements)
  if interactData.canInteract and self.anyOverlap then
    for _, elem in ipairs(self.cluster.elemData) do
      table.insert(interactableElements, elem)
    end
  end
end

function C:instantFade(visible)
end

function C:setHidden(value)
end

-- minimap
function C:drawOnMinimap(td)
  for _, door in ipairs(self.doors or {}) do
    ui_apps_minimap_utils.simpleCircle(door.iconPos)
  end
end

local function create(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

local function cluster(pois, allClusters)
  for _, poi in ipairs(pois) do
    local vt = poi.markerInfo.vehicleTrigger
    local c = {
      id = 'vehicleTrigger#' .. poi.id,
      doors = vt.doors,
      iconLift = vt.iconLift,
      icon = vt.icon or "poi_exclamationmark_round",
      iconOffsetHeight = vt.iconOffsetHeight,
      pos = vt.pos,
      radius = vt.radius or 6,
      screens = vt.screens,
      visibilityPos = vt.pos,
      visibilityRadius = vt.radius or 6,
      elemData = { poi.data },
      create = create,
    }
    table.insert(allClusters, c)
  end
end

return {
  create = create,
  cluster = cluster
}
