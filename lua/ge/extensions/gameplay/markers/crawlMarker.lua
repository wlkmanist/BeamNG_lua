-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local C = {}
local markerIndexCorrection = { { 3, 4, 2, 1 }, { 1, 2, 4, 3 } }
local vecZero = vec3(0,0,0)
local vecOne = vec3(1,1,1)
local quatZero = quat(0,0,0,0)
local vecX = vec3(1,0,0)
local vecY = vec3(0,1,0)
local vecZ = vec3(0,0,1)
local lineColorF = ColorF(1,1,1,1)
local playModeColorI = ColorI(255,255,255,255)
local iconHeightBottom = 1.25
local iconHeightTop = 2.5
local iconRendererObj
local iconWorldSize = 20
local tmpVec = vec3()
local maxVisibleDistance = 35
local screenObjTemp = nil
function C:init()
  self.visible = true
end

function C:setup(cluster)
  self.pos = cluster.pos or vecZero
  self.rot = cluster.rot or quatZero
  self.scl = cluster.scl or vecZero

  self.cluster = cluster
  -- hardcoded values for crawl markers
  self.iconOffsetHeight = 0.5
  self.iconLift = 1.0

  self.triggerArea = {}

  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()

  local triggerData = {
     areaPos = cluster.pos,
     radius = cluster.radius or 2.0, -- sphere radius
     iconPos = cluster.iconPos,
     iconPosSmoother = newTemporalSmoothingNonLinear(10,10),
     iconAlphaSmoother = newTemporalSmoothingNonLinear(20,20),
     overlap = false,
     maxVisibleDistance = maxVisibleDistance
  }

  if iconRendererObj then
    local iconId = iconRendererObj:addIcon(string.format("%s-gsIcon",cluster.id), cluster.icon, cluster.iconPos)
    local iconInfo = iconRendererObj:getIconById(iconId)
    iconInfo.color = ColorI(255,255,255,255)
    iconInfo.customSize = iconWorldSize
    iconInfo.drawIconShadow = false

    triggerData.iconId = iconId
    triggerData.iconInfo = iconInfo

  end

  self.triggerArea = triggerData
end

function C:update(data)
  if not self.visible or not data.veh then return end

  local anyOverlap = false
  local area = self.triggerArea
  if area then
    --simpleDebugText3d(idx, area.iconPos, 0.25)

    -- Check sphere overlap - no walking requirement
    local distance = (data.bbCenter - area.areaPos):length()
    local overlap = distance < area.radius
    anyOverlap = overlap

    if overlap and not area.overlap then
      area.overlap = true
    end
    if not overlap and area.overlap then
      area.overlap = false
    end

    area.overlap = overlap

    local iconInfo = area.iconInfo
    if iconInfo then
      local iconPos = iconInfo.worldPosition
      tmpVec:set(data.camPos)
      tmpVec:setSub(iconPos)
      local rayLength = tmpVec:length()

      local visible = rayLength < area.maxVisibleDistance and castRayStatic(iconPos, tmpVec, rayLength, nil) >= rayLength

      local smootherVal = area.iconPosSmoother:get((not data.bigMapActive and overlap) and 1 or 0, data.dt)
      tmpVec:set(0,0,self.iconOffsetHeight + smootherVal*self.iconLift)
      tmpVec:setAdd(area.iconPos)
      iconInfo.worldPosition = tmpVec
      playModeColorI.alpha = area.iconAlphaSmoother:get((not data.bigMapActive and visible) and 1 or 0, data.dt) * 255
      iconInfo.color = playModeColorI
      if smootherVal > 0.1 then
        --lineColorF.a = area.iconAlphaSmoother:value()
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
    local area = self.triggerArea
    if area and area.iconInfo then
      playModeColorI.alpha = 0
      area.iconInfo.color = playModeColorI
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
    local area = self.triggerArea
    if area and area.iconId then
      iconRendererObj:removeIconById(area.iconId)
    end
  end
  self.triggerArea = nil
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


function C:drawAxisBox(corner, x, y, z, clr)
  clr = clr or ColorI(128,64,64,32)
  -- draw all faces in a loop
  for _, face in ipairs({{x,y,z},{x,z,y},{y,z,x}}) do
    local a,b,c = face[1],face[2],face[3]
    -- spokes
    debugDrawer:drawLine((corner    ), (corner+c    ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a  ), (corner+c+a  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+b  ), (corner+c+b  ), ColorF(0,0,0,0.75))
    debugDrawer:drawLine((corner+a+b), (corner+c+a+b), ColorF(0,0,0,0.75))
    -- first side
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+a  ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner+b  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    -- back of first side
    debugDrawer:drawTriSolid(
      vec3(corner+a  ),
      vec3(corner    ),
      vec3(corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(corner    ),
      vec3(corner+b  ),
      vec3(corner+a+b),
      clr)
    -- other side
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+a  ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner+b  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    -- back of other side
    debugDrawer:drawTriSolid(
      vec3(c+corner+a  ),
      vec3(c+corner    ),
      vec3(c+corner+a+b),
      clr)
    debugDrawer:drawTriSolid(
      vec3(c+corner    ),
      vec3(c+corner+b  ),
      vec3(c+corner+a+b),
      clr)
  end
end

-- minimap
function C:drawOnMinimap(td)
  local trigger = self.triggerArea
  if trigger then
    ui_apps_minimap_utils.simpleCircle(trigger.iconPos)
  end
end


local function create(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

-- crawlmarker are clustered if the area and icon names are identical
local function cluster(pois, allClusters)
  local poisByObjectNames = {}
  for _, poi in ipairs(pois) do
    local cm = poi.markerInfo.crawlMarker
    local name = tostring(cm.pos)..tostring(cm.iconPos)
    poisByObjectNames[name] = poisByObjectNames[name] or {}
    table.insert(poisByObjectNames[name], poi)
  end
  for key, poisInCluster in pairs(poisByObjectNames) do
    local cm = poisInCluster[1].markerInfo.crawlMarker
    local cluster = {
      id = 'crawlMarker#'..key,
      pos = cm.pos,
      radius = cm.radius,
      iconPos = cm.iconPos,
      icon = cm.icon or "mission_rockcrawling01_triangle",
      visibilityPos = cm.pos,
      visibilityRadius = cm.radius,
      elemData = {},
      create = create,
    }
    for _, poi in ipairs(poisInCluster) do
      table.insert(cluster.elemData, poi.data)
    end
    table.insert(allClusters, cluster)
  end
end

return {
  create = create,
  cluster = cluster
}