-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local borderPrefix = "MissionMarkerBorder_"
local decalRoadPrefix = "MissionMarkerDecalRoad_"
local columnPrefix = "MissionMarkerColumn_"
local baseShape = "art/shapes/interface/checkpoint_marker_base.dae"
local columnShape = "art/shapes/interface/single_faded_column.dae"
local bigMapColumnShape = "art/shapes/interface/single_faded_column_b.dae"
local upVector = vec3(0,0,1)

local idCounter = 0

-- icon renderer
local iconRendererName = "markerIconRenderer"
local iconWorldSize = 20

-- default height for columns
local columnHeight = 3.5 --m
-- factor because the columnObject is not 1m high
local columnScl = 1/30
-- how quickly and where the marker should fade
local markerAlphaRate = 1/0.75
local markerShowDistance = 25
-- how quickly and where the icon should fade
local iconAlphaRate = 1/0.4
local iconShowDistance = 70
-- how quickly the cruising smoother should transition
local cruisingSmootherRate = 1/0.4
local cruisingRadius = 0.25
local markerFullRadiusDistance = 10
-- how quickly to fade out everything because we are in bigmap
local bigmapAlphaRate = 1/0.4

-- called when this object is created. initialize variables here (but dont spawn objects)
function C:init()
  self.id = idCounter
  idCounter = idCounter + 1

  -- abstract data for center, border etc
  self.pos = nil
  self.radius = nil

  -- ids of spawned objects
  self.borderId = nil
  self.columnId = nil
  self.iconRendererId = nil
  self.markerAlphaSmoother = newTemporalSmoothing()
  self.bigMapSmoother = newTemporalSmoothing()
  self.iconAlphaSmoother = newTemporalSmoothing()
  self.stretchSmoother = newTemporalSmoothing()
  self.cruisingSmoother = newTemporalSmoothing()

  self.visible = true
end

local function inverseLerp(min, max, value)
 if math.abs(max - min) < 1e-30 then return min end
 return (value - min) / (max - min)
end

local missionIconColor = ColorF(0,0,1,1):asLinear4F()
local missionColumnColor = ColorF(1.5,1.5,1.5,1):asLinear4F()

local camPos2d, markerPos2d = vec3(), vec3()
local tmpVec = vec3()
local vecZero = vec3(0,0,0)

local missionColorI = ColorI(255,255,255,255)
local borderObj, columnObj, iconRendererObj

-- called every frame to update the visuals.
function C:update(data)
  if not self.visible then return end
  profilerPushEvent("Mission Marker")

  profilerPushEvent("Mission Marker PreCalculation")
  -- get the 2d distance to the marker to adjust the height
  camPos2d:set(data.camPos)
  camPos2d.z = 0
  markerPos2d:set(self.pos)
  markerPos2d.z = 0
  local distance2d = math.max(0,camPos2d:distance(markerPos2d) - self.radius)

  -- desired height is the actual height of the icon
  local desiredHeight = (1+1*clamp(inverseLerp(20,70, distance2d), 0,1)) * columnHeight
  local bigMapActive = data.bigMapActive

  -- 3d distance to the marker
  local distanceFromMarker = math.max(0,self.pos:distance(commands.isFreeCamera() and data.camPos or data.playerPosition) - self.radius)
  local distanceToCamera = self.pos:distance(data.camPos)

  -- alpha values for the icon and marker
  local missionIconAlphaDist = ((distanceFromMarker <= (self.focus and iconShowDistance*2 or iconShowDistance)) and 0.7 or 0)
  local iconInfo = self.iconDataById[self.missionIconId]
  if iconInfo then
    tmpVec:set(iconInfo.worldPosition)
    tmpVec:setSub(data.camPos)
    local rayLength = tmpVec:length()
    local hitDist = castRayStatic(data.camPos, tmpVec, rayLength, nil)
    if hitDist < rayLength then
      missionIconAlphaDist = 0
    end
  end

  -- this is a global alpha scale for all markers. goes to 0 when in bigmap
  local bigMapAlpha = clamp(self.bigMapSmoother:getWithRateUncapped(bigMapActive and 0 or 1, data.dt, bigmapAlphaRate), 0,1)

  local missionIconAlpha = clamp(self.iconAlphaSmoother:getWithRateUncapped(missionIconAlphaDist * data.globalAlpha, data.dt, iconAlphaRate), 0,1) * bigMapAlpha
  local markerAlphaSample = (0.7 * (distanceFromMarker <= self.radius and 1 or 0) * data.parkingSpeedFactor)
                          + (0.3 * (distanceFromMarker <= markerShowDistance and 1 or 0))
  markerAlphaSample = markerAlphaSample * data.globalAlpha * bigMapAlpha

  local missionMarkerAlpha = clamp(self.markerAlphaSmoother:getWithRateUncapped((bigMapActive --[[ or not self.visibleInPlayMode]]) and 0 or markerAlphaSample, data.dt, markerAlphaRate),0,1) * bigMapAlpha


  local radiusInterpolationDest = distanceFromMarker > math.max(markerFullRadiusDistance, self.radius) and 1 or data.cruisingSpeedFactor
  local smoothedCruisingFactor = self.cruisingSmoother:getWithRateUncapped(radiusInterpolationDest, data.dt, cruisingSmootherRate)
  local shownRadius = (1-smoothedCruisingFactor)*self.radius + smoothedCruisingFactor*cruisingRadius

  profilerPopEvent("Mission Marker PreCalculation")
  --print(string.format("pmma: %0.2f ", missionMarkerAlpha))

  -- updating the actual objects
  borderObj = scenetree.findObjectById(self.borderId)
  if borderObj and (missionMarkerAlpha > 0 or self.missionMarkerAlphaLastFrame > 0) then
    missionIconColor.w = missionMarkerAlpha -- use W instead of alpha because asLinear4F
    borderObj.instanceColor = missionIconColor
    borderObj:setScaleXYZ(shownRadius*2, shownRadius*2, self.radius*2)
    borderObj:updateInstanceRenderData()
  end
  if self.groundDecalData and (missionMarkerAlpha > 0 and self.missionMarkerAlphaLastFrame > 0) then
    self.groundDecalData.color.alpha = clamp(missionMarkerAlpha*2.5,0,1)*(1-smoothedCruisingFactor)
  end
  -- interpolating the middle columns size and radius so it has the same on-screen size
  columnObj = scenetree.findObjectById(self.columnId)
  if columnObj and (missionIconAlpha > 0 or self.missionIconAlphaLastFrame > 0) then
    missionColumnColor.w = missionIconAlpha -- use W instead of alpha because asLinear4F
    columnObj.instanceColor = missionColumnColor
    columnObj:setPositionXYZ(self.pos.x, self.pos.y, self.pos.z - desiredHeight/2)
    local sideRadius = math.max(distanceToCamera/30,0.15)
    columnObj:setScaleXYZ(sideRadius, sideRadius, 1.5*desiredHeight*columnScl)
    columnObj:updateInstanceRenderData()
  end

  profilerPushEvent("Mission Marker Icons")
  -- updating the icons
  if self.missionIconId and (missionIconAlpha > 0 or self.missionIconAlphaLastFrame > 0) then
    local iconInfo = self.iconDataById[self.missionIconId]
    if iconInfo then
      tmpVec:set(0,0,desiredHeight)
      tmpVec:setAdd(self.pos)
      iconInfo.worldPosition = tmpVec
      missionColorI.alpha = missionIconAlpha * 255
      iconInfo.color = missionColorI
    end
  end

  profilerPopEvent("Mission Marker Icons")

  self.missionMarkerAlphaLastFrame = missionMarkerAlpha
  self.missionIconAlphaLastFrame = missionIconAlpha
  profilerPopEvent("Mission Marker")
end


function C:setup(cluster)
  self.pos = cluster.pos
  self.radius = cluster.radius
  self.cluster = cluster
  self.type = "missionMarker"
  -- setting the objects to the correct position/size
  borderObj = scenetree.findObjectById(self.borderId)
  if borderObj then
    borderObj:setPosition(vec3(self.pos))
    borderObj:setScale(vec3(cluster.radius*2, cluster.radius*2, cluster.radius*2))
    borderObj.instanceColor = ColorF(0,0,1,1):asLinear4F()
    borderObj:updateInstanceRenderData()
  end
  columnObj = scenetree.findObjectById(self.columnId)
  if columnObj then
    columnObj:setPosition(vec3(self.pos - vec3(0,0,columnHeight/2)))
    columnObj:setScale(vec3(0.1,0.1, 1.5*columnHeight*columnScl))
    columnObj.instanceColor = ColorF(1,1,1,1):asLinear4F()
    columnObj:updateInstanceRenderData()
  end



  -- setting up the icon

  iconRendererObj = scenetree.findObjectById(self.iconRendererId)
  if iconRendererObj then
    self.iconDataById = {}
    self.missionIconId = iconRendererObj:addIcon(cluster.id, cluster.icon or "poi_exclamationmark", self.pos + vec3(0,0,columnHeight))
    local iconInfo = iconRendererObj:getIconById(self.missionIconId)
    iconInfo.color = ColorI(255,255,255,255)
    iconInfo.customSize = iconWorldSize
    iconInfo.drawIconShadow = false
    self.iconDataById[self.missionIconId] = iconInfo
  end
    --self.visibleInPlayMode = cluster.visibleInPlayMode


  -- setting up the smoothers
  self.markerAlphaSmoother:set(0)
  self.iconAlphaSmoother:set(0)
  self.stretchSmoother:set(0)
  self.cruisingSmoother:set(1)
  self.bigMapSmoother:set(0)

  self.missionMarkerAlphaLastFrame = 1
  self.missionIconAlphaLastFrame = 1


  -- setting up the ground decal
  self.groundDecalData = {
    texture = 'art/shapes/missions/dotted_ring_5m.png',
    position = self.pos,
    forwardVec = vec3(1, 0, 0),
    color = ColorF(1.5,1.5,1.5,0 ),
    scale = vec3(self.radius*2.25, self.radius*2.25, 3),
    fadeStart = 100,
    fadeEnd = 200
  }
end

-- marker management
function C:createObject(shapeName, objectName)
  local marker = createObject('TSStatic')
  marker:setField('shapeName', 0, shapeName)
  marker:setPosition(vec3(0, 0, 0))
  marker.scale = vec3(1, 1, 1)
  marker:setField('rotation', 0, '1 0 0 0')
  marker.useInstanceRenderData = true
  marker:setField('instanceColor', 0, '1 1 1 1')
  marker.canSave = false
  --marker.hidden = true
  marker:registerObject(objectName)

  return marker
end

-- creates neccesary objects
function C:createObjects()
  self:clearObjects()
  self._ids = {}
  if not self.borderId then
    self.borderId  = self:createObject(baseShape,borderPrefix..self.id):getId()
    table.insert(self._ids, self.borderId)
  end

  if not self.columnId then
    self.columnId = self:createObject(columnShape, columnPrefix..self.id):getId()
    table.insert(self._ids, self.columnId)
  end

  --global (for this file) renderer
  iconRendererObj = scenetree.findObject(iconRendererName)
  if not iconRendererObj then
    iconRendererObj = createObject("BeamNGWorldIconsRenderer")
    iconRendererObj:registerObject(iconRendererName);
    iconRendererObj.maxIconScale = 2
    iconRendererObj.mConstantSizeIcons = true
    iconRendererObj.canSave = false
    iconRendererObj:loadIconAtlas("core/art/gui/images/iconAtlas.png", "core/art/gui/images/iconAtlas.json");
  end
  self.iconRendererId = iconRendererObj:getId()
  self.iconDataById = {}
end

function C:setHidden(value)
end

local linearInvisible = ColorF(0,0,0,0):asLinear4F()
function C:hide()
  if not self.visible then return end
  self.visible = false
  self.markerAlphaSmoother:reset()
  self.iconAlphaSmoother:reset()
  self.stretchSmoother:reset()

   -- hiding all that there is
  borderObj = scenetree.findObjectById(self.borderId)
  if borderObj then
    borderObj.instanceColor = linearInvisible
    borderObj:updateInstanceRenderData()
  end

  columnObj = scenetree.findObjectById(self.columnId)
  if columnObj then
    columnObj.instanceColor = linearInvisible
    columnObj:updateInstanceRenderData()
  end

  -- updating the icon
  iconRendererObj = scenetree.findObject(self.iconRendererId)
  if iconRendererObj then
    for id, data in pairs(self.iconDataById or {}) do
      data.color = ColorI(0,0,0,0)
    end
  end
end

function C:show()
  if self.visible then return end
  self.visible = true
end

function C:instantFade(visible)
end

function C:setVisibilityInBigmap(vis, instant)
end

-- destorys/cleans up all objects created by this
function C:clearObjects()
  for _, id in ipairs(self._ids or {}) do
    local obj = scenetree.findObjectById(id)
    if obj then
      obj:delete()
    end
  end
  if self.iconRendererId then
    iconRendererObj = scenetree.findObject(self.iconRendererId)
    if iconRendererObj then
      for id, _ in pairs(self.iconDataById or {}) do
        iconRendererObj:removeIconById(id)
      end
    end
  end

  self.missionIconId = nil
  self._ids = nil
  self.borderId = nil
  self.decalId = nil

  self.iconRendererId = nil
  self.iconDataById = {}
end


-- Interactivity
function C:interactInPlayMode(interactData, interactableElements)
  if interactData.canInteract then
    if interactData.vehPos:distance(self.pos) <= self.radius then
      for _, elem in ipairs(self.cluster.elemData) do
        table.insert(interactableElements, elem)
      end
    end
  end
end

local quadtree = require('quadtree') -- change to KD Tree?
local function idSort(a,b) return a.id < b.id end
local function create(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
local function merge(pois, idPrefix)
  local cluster = {
    id = "missionMarker#",
    containedIds = {},
    pos = vec3(),
    rot = quat(),
    radius = 0,
    icon = "",
    containedIdsLookup = {},
    elemData = {},
    create = create,
  }
  local containsMissions = false
  local count = 0
  for i, poi in ipairs(pois) do
    cluster.pos = cluster.pos + poi.markerInfo.missionMarker.pos
    cluster.rot = poi.markerInfo.missionMarker.rot
    cluster.radius = cluster.radius + poi.markerInfo.missionMarker.radius
    cluster.icon = poi.markerInfo.missionMarker.icon
    cluster.containedIds[i] = poi.id
    cluster.id = cluster.id..poi.id
    cluster.containedIdsLookup[poi.id] = true
    count = count + 1
    cluster.elemData[i] = poi.data
  end
  cluster.pos = cluster.pos / count
  cluster.radius = cluster.radius / count
  cluster.visibilityPos = cluster.pos
  cluster.visibilityRadius = cluster.radius + 5

  if count > 1 then
    cluster.icon = string.format("mission_no-%02d_triangle",math.min(count, 9))
  end
  return cluster
end
-- Mission markers are clustered with the original clustering algorithm - when they overlap, they merge.
local function cluster(pois, allClusters)
  local poiList = {}
  for i, poi in ipairs(pois) do poiList[i] = poi end
  table.sort(pois, idSort)

  -- preload all elements into a qt for quick clustering
  local qt = quadtree.newQuadtree()
  local count = 0
  for i, poi in ipairs(poiList) do
    qt:preLoad(i, quadtree.pointBBox(poi.markerInfo.missionMarker.pos.x, poi.markerInfo.missionMarker.pos.y, poi.markerInfo.missionMarker.radius))
    count = i
  end
  qt:build()

  --go through the list and check for closeness to cluster
  for index = 1, count do
    local cur = poiList[index]
    if cur then
      local cluster = {}
      local pmi = cur.markerInfo.missionMarker
      -- find all the list that potentially overlap with cur, and get all the ones that actually overlap into cluster list
      for id in qt:query(quadtree.pointBBox(pmi.pos.x, pmi.pos.y, pmi.radius)) do
        local candidate = poiList[id]

        candidate._qtId = id
        if pmi.pos:squaredDistance(candidate.markerInfo.missionMarker.pos) < square(pmi.radius + candidate.markerInfo.missionMarker.radius) then
          table.insert(cluster, candidate)
        end
      end

      -- remove all the elements in the cluster from the qt and the locations list
      for _, c in ipairs(cluster) do
        qt:remove(c._qtId, poiList[c._qtId].markerInfo.missionMarker.pos.x, poiList[c._qtId].markerInfo.missionMarker.pos.y)
        poiList[c._qtId] = false
      end

      table.sort(cluster, idSort)
      table.insert(allClusters, merge(cluster))
    end
  end
end
return {
  create = create,
  cluster = cluster
}