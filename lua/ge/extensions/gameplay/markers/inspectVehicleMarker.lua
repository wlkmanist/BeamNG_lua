-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}


local lineColorF = ColorF(1,1,1,1)
local playModeColorI = ColorI(255,255,255,255)
local iconHeightBottom = 1.0
local iconHeightTopOffset = 0.25
local iconRendererObj
local tmpVec = vec3()
local idCounter = 0

local nearDist, farDist = 15,60
local bigScaleDist, smallScaleDist = 100, 1000
local function distanceToHeight(dist)
  return linearScale(dist, nearDist, 700, iconHeightBottom, 500)
end

local zVector = vec3(0,0,1)
local tmpCorner, tmpX, tmpY, tmpZ = vec3(), vec3(), vec3(), vec3()
local tmpNormal = vec3()

function C:init()
  self.id = idCounter
  idCounter = idCounter + 1
  self.numId = idCounter

  self.visible = true
  self.iconPositionSmoother = newTemporalSmoothingNonLinear(10,10)
  self.cruisingSmoother = newTemporalSmoothingNonLinear(10,10)
  self.iconAlphaSmoother = newTemporalSmoothingNonLinear(20,20)
  self.iconDistanceSmoother = newTemporalSmoothingNonLinear(20,20)
end

function C:createObjects()
  self:clearObjects()
end

function C:clearObjects()
  -- floating icon
  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
  if iconRendererObj and self.iconId then
    iconRendererObj:removeIconById(self.iconId)
    self.iconInfo = nil
    self.iconId = nil
  end
end

function C:hide()
  if not self.visible then return end
  self.visible = false

  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
  if iconRendererObj and self.iconInfo then
    playModeColorI.alpha = 0
    self.iconInfo.color = playModeColorI
  end
end

function C:show()
  if self.visible then return end
  self.visible = true
end

local bounce = function (x)
  local n1 = 7.5625
  local d1 = 2.75

  if x < 1 / d1 then
    return 0
  elseif x < 2 / d1 then
    x = x - 1.5 / d1
    return 1-(n1 * x * x + 0.75)
  elseif x < 2.5 / d1 then
    x = x - 2.25 / d1
    return 1-(n1 * x * x + 0.9375)
  else
    x = x - 2.625 / d1
    return 1-(n1 * x * x + 0.984375)
  end
end

function C:update(data)
  if not self.visible then return end

  local distance = 0
  if data.isFreeCam then
    tmpCorner:set(data.camPos)
    tmpCorner:setSub(self.pos)
    distance = tmpCorner:length()
  else
    tmpCorner:set(data.playerPosition)
    tmpCorner:setSub(self.pos)
    distance = tmpCorner:length()
  end

  local cruisingFactor = self.cruisingSmoother:get(((distance > nearDist or data.bigMapActive) and 0 or (1-data.cruisingSpeedFactor)), data.dt)

  local iconHeight
  if not self.focus or data.bigMapActive then
    iconHeight = self.iconPositionSmoother:get(
      (self._inside
        and (data.highestBBPointZ + 0.5 -self.pos.z+iconHeightTopOffset)
        or  ((distance > farDist) and 0 or data.highestBBPointZ-self.pos.z+iconHeightTopOffset))
      * (0.5 + 0.5*cruisingFactor), data.dt)
    self.iconPos = self.pos + vec3(0,0,iconHeight)
  else
    local iconHeightFar = distanceToHeight(distance)
    iconHeight = self.iconPositionSmoother:get(
      (self._inside
        and ((data.highestBBPointZ + 0.5-self.pos.z+iconHeightTopOffset) * (0.5 + 0.5*cruisingFactor))
        or  ((distance > nearDist) and iconHeightFar or data.highestBBPointZ-self.pos.z+iconHeightTopOffset))
      , data.dt)

    -- camera-oriented vectors
    tmpX:set(1,0,0)
    tmpX:setRotate(data.camRot)
    tmpY:set(0,1,0)
    tmpY:setRotate(data.camRot)
    tmpZ:set(0,0,1)
    tmpZ:setRotate(data.camRot)
    -- plane normal vector that points up from the plane constructed from the camera point and the upper edge of the screen
    local fovRadians = core_camera.getFovRad()
    tmpNormal:set(tmpZ)
    tmpNormal:setScaled(math.tan(fovRadians/2))
    tmpNormal:setAdd(tmpY)
    tmpNormal:setScaled(-1)
    tmpNormal:setCross(tmpNormal, tmpX)
    tmpNormal:normalize()

    -- icon position with added height
    self.iconPos:set(self.pos)
    self.iconPos:setAddXYZ(0,0,iconHeight)

    tmpVec:set(self.iconPos)
    tmpVec:setSub(data.camPos)

    tmpZ:setScaled(tmpVec:dot(tmpY) / 25)
    self.iconPos:setAdd(tmpZ)

    -- iconPos with inverse screenspace offset
    self.iconOff:set(self.iconPos)
    tmpVec:set(self.pos)
    tmpVec:setAddXYZ(0,0,iconHeight)
    self.iconOff:setSub(tmpVec)

    -- project icon position on plane
    local dist = intersectsRay_Plane(self.iconPos, zVector, data.camPos, tmpNormal)

    dist = clamp(dist, -iconHeight, 0)
    self.iconPos:setAddXYZ(0,0,dist)
    self.iconPos:setSub(self.iconOff)
  end

  if self.iconInfo then
    local customSize = 1
    if self.focus then
      self.iconOff:normalize()
      self.iconOff:setScaled(bounce((os.clockhp() * 0.9)%1) * 0.4 * linearScale(distance, nearDist, nearDist +3, 1, 0))
      self.iconPos:setAdd(self.iconOff)
      customSize = linearScale(distance, bigScaleDist, smallScaleDist, 1, 0.65)
    end
    self.iconInfo.customSizeFactor = customSize
    self.iconInfo.worldPosition = self.iconPos

    tmpVec:set(data.camPos)
    tmpVec:setSub(self.iconPos)

    local rayLength =  tmpVec:length()
    local iconVisible = castRayStatic(self.iconPos, tmpVec, rayLength, nil) >= rayLength

    if not self.focus then
      lineColorF.alpha = self.iconAlphaSmoother:get((not self.visible or not iconVisible or (distance > farDist) or data.bigMapActive) and 0 or 1, data.dt) * (0.5 + 0.5*cruisingFactor)
    else
      lineColorF.alpha = self.iconAlphaSmoother:get((not self.visible or not iconVisible or data.bigMapActive) and ((not data.bigMapActive and distance < 750) and 0.35 or 0) or 1, data.dt)
    end
    playModeColorI.alpha = lineColorF.alpha * 255
    self.iconInfo.color = playModeColorI

    if lineColorF.alpha < 0.8 and not self.focus then
      debugDrawer:drawLine(self.pos, self.iconPos, lineColorF)
    else
      debugDrawer:drawLineInstance(self.pos, self.iconPos, 1, lineColorF)
    end
  end

  self._inside = false
  if data.playerPosition:squaredDistance(self.pos) <= self.radius*self.radius then
    self._inside = true
  end
  if self._lastFrameInside ~= self._inside then
    self.isInAreaChanged = self._inside and "in" or "out"
  else
    self.isInAreaChanged = nil
  end
  self._lastFrameInside = self._inside
end

function C:setup(cluster)
  iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()

  self.cluster = cluster
  self.pos = cluster.pos
  self.radius = cluster.radius
  self.vehicleHeight = cluster.vehicleHeight
  self.focus = cluster.focus or false

  self._inside = nil

  self.iconPositionSmoother:set(iconHeightBottom)
  self.cruisingSmoother:set(0)

  if iconRendererObj then
    local playModeIconName = self.cluster.icon or "poi_parking_rect"
    local iconId = iconRendererObj:addIcon(string.format("%s-inspectIcon",self.numId), playModeIconName, self.pos)
    self.iconInfo = iconRendererObj:getIconById(iconId)
    self.iconInfo.color = ColorI(255,255,255,0)
    self.iconInfo.customSize = vec3(1,1,1)
    self.iconInfo.drawIconShadow = false
    self.iconId = iconId
  end

  self.iconOff = vec3(0,0,0)
  self.iconPos = vec3(0,0,0)
end

-- Interactivity
function C:interactInPlayMode(interactData, interactableElements)
  if interactData.canInteract then
    if self._inside then
      table.insert(interactableElements, self.cluster.data)
    end
  end
end

local function create(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

-- zoneMarkers are not grouped/merged - each poi will be one cluster.
local function cluster(pois, allClusters)
  for _, poi in ipairs(pois) do
    local cluster = {
      id = 'inspectVehicleMarker#'..poi.id,
      data = poi.data,

      isInspectVehicleMarker = true,

      pos = poi.markerInfo.inspectVehicleMarker.pos,
      radius = poi.markerInfo.inspectVehicleMarker.radius,
      icon = poi.markerInfo.inspectVehicleMarker.icon,
      focus = poi.markerInfo.inspectVehicleMarker.focus,

      visibilityPos = poi.markerInfo.inspectVehicleMarker.pos,
      visibilityRadius = 0,
      create = create,

    }
    table.insert(allClusters, cluster)
  end
end

return {
  create = create,
  cluster = cluster
}
