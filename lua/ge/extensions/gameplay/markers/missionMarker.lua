-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
local iconRendererObj = nil
local iconWorldSize = 20
local idCounter = 0

-- Draw the mission icon with the Skia icon system (render_skiaIcons) instead of the C++
-- atlas icon renderer. Read once per marker in setup, so flipping it only affects markers
-- created afterwards - reload the level (or the markers) to switch.
local useSkiaIcons = false
-- The preset supplies the shape and colour; the motive comes from the mission's own
-- iconFontIcon, or this fallback for the few mission types that do not declare one.
local skiaIconPreset = "mission"
local skiaIconFallbackMotive = "flag"
-- World height in metres, then clamped as a fraction of the viewport height so a distant
-- marker stays readable and a close one does not fill the screen.
local skiaIconSize = 1
local skiaIconMinScreen = 0.045
local skiaIconMaxScreen = 0.12

local function skiaIcons()
  if not render_skiaIcons then extensions.load("render_skiaIcons") end
  return render_skiaIcons
end

local layers = require("ui/apps/minimap/layers")

local iconMesh = "art/shapes/interface/s_poi_circle.dae"
local iconMeshPrefix = "missionMarkerMesh_"

-- default height for icon
local iconHeightBottom = 1.2
local iconHeightTop = 0.25
local iconLift = 0.25
local iconOffsetHeight = 1.45

-- how quickly and where the marker should fade
local decalAlphaRate = 1/0.6
local markerShowDistance = 40
-- how quickly and where the icon should fade
local iconAlphaRate = 1/0.4
local iconShowDistanceBase = 50
-- how quickly the cruising smoother should transition
local cruisingSmootherRate = 1/0.4
local cruisingRadius = 0.25
local markerFullRadiusDistance = 10
-- how quickly to fade out everything because we are in bigmap
local bigmapAlphaRate = 1/0.4

-- Reusable vectors and colors
local lineColorF = ColorF(1,1,1,1)
local playModeColorI = ColorI(255,255,255,255)
local tmpVec = vec3()

local hardcodedRadius = 1.2

-- called when this object is created. initialize variables here (but dont spawn objects)
function C:init()
  self.id = idCounter
  idCounter = idCounter + 1

  -- abstract data for center, border etc
  self.pos = nil
  self.radius = hardcodedRadius -- Fixed radius of 1.5m

  -- ids of spawned objects
  self.iconMeshId = nil
  self.decalAlphaSmoother = newTemporalSmoothing()
  self.ringAlphaSmoother = newTemporalSmoothing()
  self.bigMapSmoother = newTemporalSmoothing()
  self.iconAlphaSmoother = newTemporalSmoothing()
  self.iconPositionSmoother = newTemporalSmoothingNonLinear(10,10)
  self.cruisingSmoother = newTemporalSmoothingNonLinear(10,10)

  self.visible = true
end

local function inverseLerp(min, max, value)
  if math.abs(max - min) < 1e-30 then return min end
  return (value - min) / (max - min)
end

function C:playerIsInArea(data)
  if not data.veh then return false end

  -- Get vehicle bounding box data
  local bbCenter = data.bbCenter
  local bbHalfAxis0 = data.bbHalfAxis0
  local bbHalfAxis1 = data.bbHalfAxis1
  local bbHalfAxis2 = data.bbHalfAxis2

  -- Check if vehicle OBB overlaps with marker sphere
  return overlapsOBB_Sphere(bbCenter, bbHalfAxis0, bbHalfAxis1, bbHalfAxis2, self.pos, self.radius)
end

-- called every frame to update the visuals.
function C:update(data)
  if not self.visible then return end
  profilerPushEvent("Mission Marker")

  --debugDrawer:drawSphere(self.pos, self.radius, ColorF(1,0,0,0.25))

  -- Check if player is in area once at the start
  local isInArea = self:playerIsInArea(data)

  -- get the 2d distance to the marker to adjust the height
  local distance2d = math.max(0, data.camPos:distance(self.pos) - self.radius)
  local bigMapActive = data.bigMapActive

  -- 3d distance to the marker
  local distanceFromMarker = math.max(0, self.pos:distance(commands.isFreeCamera() and data.camPos or data.playerPosition) - self.radius)
  local distanceToCamera = self.pos:distance(data.camPos)

  -- alpha values for the icon and marker
  local iconShowDistance = self.cluster.focus and iconShowDistanceBase*2 or iconShowDistanceBase
  local missionIconAlphaDist = ((distanceFromMarker <= iconShowDistance) and 1 or 0)
  -- The atlas icon draws over everything, so it needs an occlusion ray to hide itself behind
  -- geometry. The Skia billboard does not, so the skia path skips the ray entirely.
  if not self.skiaIcon then
    local iconInfo = self.iconDataById[self.missionIconId]
    if iconInfo and not isInArea then
      tmpVec:set(iconInfo.worldPosition)
      tmpVec:setSub(data.camPos)
      tmpVec.z = tmpVec.z + iconHeightBottom*(missionIconAlphaDist)
      local rayLength = tmpVec:length()
      local hitDist = castRayStatic(data.camPos, tmpVec, rayLength, nil)
      --simpleDebugText3d(string.format("distanceFromMarker: %0.3f, missionIconAlphaDist: %s, focus: %s, hitDist: %0.4f, rayLength: %0.4f", distanceFromMarker, missionIconAlphaDist, self.cluster.focus, hitDist, rayLength), iconInfo.worldPosition, 1)
      if hitDist < rayLength then
        missionIconAlphaDist = 0
      end
    end
  end

  -- this is a global alpha scale for all markers. goes to 0 when in bigmap
  local bigMapAlpha = clamp(self.bigMapSmoother:getWithRateUncapped(bigMapActive and 0 or 1, data.dt, bigmapAlphaRate), 0,1)
  local missionIconAlpha = clamp(self.iconAlphaSmoother:getWithRateUncapped(missionIconAlphaDist * data.globalAlpha, data.dt, iconAlphaRate), 0,1) * bigMapAlpha
  --simpleDebugText3d(string.format("bigMapActive: %s, bigmapalpha: %s, missionIconAlpha: %s, missionIconAlphaDist: %s, globalAlpha: %s, focus: %s", bigMapActive, bigMapAlpha, missionIconAlpha, missionIconAlphaDist, data.globalAlpha, self.cluster.focus), self.pos, 1)

  local radiusInterpolationDest = distanceFromMarker > math.max(markerFullRadiusDistance, self.radius) and 1 or data.cruisingSpeedFactor
  local smoothedCruisingFactor = self.cruisingSmoother:get(radiusInterpolationDest, data.dt)

  -- Update icon position and visuals. render_skiaIcons owns the fade, so it only wants the
  -- on/off target and a dt; globalAlpha is 0/1 (it drops while a mission is in the
  -- foreground) and bigmap is a straight on/off, so both read as gates here.
  if self.skiaIcon then
    local showIcon = missionIconAlphaDist > 0 and data.globalAlpha > 0 and not bigMapActive
    self.skiaIcon:setVisible(showIcon)
    if showIcon or self.skiaIcon:visibility() > 0 then
      local iconHeight = self.iconPositionSmoother:get(
        (isInArea
        and (data.highestBBPointZ-self.pos.z+iconHeightTop)
        or ((distance2d > iconShowDistance) and 0 or iconHeightBottom))
        * (1), data.dt)

      tmpVec:set(0,0,iconHeight)
      tmpVec:setAdd(self.pos)
      self.skiaIcon:update(tmpVec, render_skiaIcons.screenBoundedScale(tmpVec, skiaIconSize, skiaIconMinScreen, skiaIconMaxScreen), data.dt)

      if missionIconAlpha < 0.8 then
        debugDrawer:drawLine(self.pos, tmpVec, lineColorF)
      else
        debugDrawer:drawLineInstance(self.pos, tmpVec, 1, lineColorF)
      end
    end
  elseif self.missionIconId and (missionIconAlpha > 0 or self.missionIconAlphaLastFrame > 0) then
    local iconInfo = self.iconDataById[self.missionIconId]
    if iconInfo then
      local iconHeight = self.iconPositionSmoother:get(
        (isInArea
        and (data.highestBBPointZ-self.pos.z+iconHeightTop)
        or ((distance2d > iconShowDistance) and 0 or iconHeightBottom))
        * (1), data.dt)

      tmpVec:set(0,0,iconHeight)
      tmpVec:setAdd(self.pos)
      iconInfo.worldPosition = tmpVec

      playModeColorI.alpha = missionIconAlpha * 255
      iconInfo.color = playModeColorI
      --iconInfo.color = ColorI(255,255,255,0)

      if missionIconAlpha < 0.8 then
        debugDrawer:drawLine(self.pos, tmpVec, lineColorF)
      else
        debugDrawer:drawLineInstance(self.pos, tmpVec, 1, lineColorF)
      end
    end
  end

  -- Update icon mesh position and visuals
  if self.iconMeshId and (missionIconAlpha > 0 or self.missionIconAlphaLastFrame > 0) then
    local meshObj = scenetree.findObjectById(self.iconMeshId)
    if meshObj then
      local iconHeight = self.iconPositionSmoother:get(
        (isInArea
        and (data.highestBBPointZ-self.pos.z+iconHeightTop)
        or ((distance2d > iconShowDistance) and 0 or iconHeightBottom))
        * (1), data.dt)

      -- Set position
      tmpVec:set(0,0,iconHeight)
      tmpVec:setAdd(self.pos)
      meshObj:setPosition(tmpVec)

      -- Make mesh face camera (only on XY plane)
      local toCamera = (data.camPos - tmpVec):z0():normalized()
      local rot = quatFromDir(toCamera):toTorqueQuat()
      meshObj:setField('rotation', 0, rot.x .. ' ' .. rot.y .. ' ' .. rot.z .. ' ' .. rot.w)

      -- Set alpha
      meshObj.instanceColor = ColorF(72/255,125/255,249/255,missionIconAlpha):asLinear4F()
      meshObj.instanceColor2 = ColorF(1,1,1,missionIconAlpha):asLinear4F()
      meshObj.instanceColor3 = ColorF(1,1,1,missionIconAlpha):asLinear4F()
      meshObj:updateInstanceRenderData()
    end
  end
  --simpleDebugText3d(string.format("missionIconAlpha: %0.3f", missionIconAlpha), self.pos)

  -- Update ground decal
  if self.groundDecalData then
    local decalAlphaSample = (distanceFromMarker <= markerShowDistance and 1 or 0) * data.globalAlpha * bigMapAlpha
    local decalAlpha = clamp(self.decalAlphaSmoother:getWithRateUncapped((bigMapActive) and 0 or decalAlphaSample, data.dt, decalAlphaRate),0,1)
    -- Dot decal always shows with normal alpha
    self.groundDecalData[1].color.alpha = clamp(decalAlpha*2.5,0,1)

    -- Ring decal only shows when player is in area, with its own smoother
    local ringAlphaSample = isInArea and 1 or 0
    local ringAlpha = clamp(self.ringAlphaSmoother:getWithRateUncapped(ringAlphaSample, data.dt, decalAlphaRate),0,1)
    self.groundDecalData[2].color.alpha = clamp(ringAlpha*2.5,0,1)
  end

  local isInAreaNow = data.isWalking and isInArea

  if isInAreaNow ~= self.isInArea then
    if isInAreaNow then self.isInAreaChanged = "in" end
    if not isInAreaNow then self.isInAreaChanged = "out" end
  else
    self.isInAreaChanged = nil
  end
  self.isInArea = isInAreaNow

  self.decalAlphaLastFrame = decalAlpha
  self.missionIconAlphaLastFrame = missionIconAlpha
  profilerPopEvent("Mission Marker")
end

function C:setup(cluster)
  self.pos = cluster.pos
  self.radius = hardcodedRadius -- Fixed radius of 1.5m
  self.cluster = cluster
  self.type = "missionMarker"

  -- setting up the icon
  self.iconDataById = {}
  if useSkiaIcons then
    local s = skiaIcons()
    if s then
      -- A stacked cluster of differing mission types shows its count instead of an icon, so
      -- `text` and `motive` are mutually exclusive here.
      self.skiaIcon = s.getIcon({
        preset = skiaIconPreset,
        motive = cluster.iconFontIcon or skiaIconFallbackMotive,
        text = cluster.markerText,
      })
      self.skiaIcon:setVisible(false, true) -- it fades in once the player is close enough
    end
  else
    iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
    if iconRendererObj then
      tmpVec:set(0,0,iconHeightBottom)
      tmpVec:setAdd(self.pos)
      self.missionIconId = iconRendererObj:addIcon(cluster.id, cluster.icon or "poi_exclamationmark", tmpVec)
      local iconInfo = iconRendererObj:getIconById(self.missionIconId)
      iconInfo.color = ColorI(255,255,255,255)
      iconInfo.customSize = iconWorldSize
      iconInfo.drawIconShadow = false
      self.iconDataById[self.missionIconId] = iconInfo
    end
  end

  -- setting up the smoothers
  self.decalAlphaSmoother:set(0)
  self.ringAlphaSmoother:set(0)
  self.iconAlphaSmoother:set(0)
  self.iconPositionSmoother:set(iconHeightBottom)
  self.cruisingSmoother:set(1)
  self.bigMapSmoother:set(0)

  self.decalAlphaLastFrame = 1
  self.missionIconAlphaLastFrame = 1

  -- setting up the ground decal
  self.groundDecalData = {
    { -- [1] = dot decal
      texture = 'art/shapes/missions/dot_128.color.png',
      position = self.pos,
      forwardVec = vec3(1, 0, 0),
      color = ColorF(1.5,1.5,1.5,0),
      scale = vec3(self.radius*0.7, self.radius*0.7, 1),
      fadeStart = 1000,
      fadeEnd = 1500
    },
    { -- [2] = ring decal
      texture = 'art/shapes/missions/outline_512.color.png',
      position = self.pos,
      forwardVec = vec3(1, 0, 0),
      color = ColorF(1.5,1.5,1.5,0),
      scale = vec3(self.radius*2.7, self.radius*2.7, 1),
      fadeStart = 1000,
      fadeEnd = 1500
    }
  }
end

function C:createObject(shapeName, objectName)
  local obj = createObject('TSStatic')
  obj:setField('shapeName', 0, shapeName)
  obj:setPosition(vec3(0, 0, 0))
  obj.scale = vec3(1, 1, 1)
  obj:setField('rotation', 0, '1 0 0 0')
  obj.useInstanceRenderData = true
  obj:setField('instanceColor', 0, '1 1 1 0')
  obj:setField('instanceColor2', 0, '1 1 1 0')
  obj.canSave = false
  obj:registerObject(objectName)

  return obj
end

function C:createObjects()
  self:clearObjects()

  -- Create icon mesh object
  --[[
  if not self.iconMeshId then
    local meshObj = self:createObject(iconMesh, iconMeshPrefix..self.id)
    self.iconMeshId = meshObj:getId()
  end
  ]]
end

function C:hide()
  if not self.visible then return end
  self.visible = false
  self.decalAlphaSmoother:reset()
  self.iconAlphaSmoother:reset()
  self.iconPositionSmoother:reset()

  -- hiding the icon. C:update stops running while hidden, so snap it instead of fading.
  if self.skiaIcon then
    self.skiaIcon:setVisible(false, true)
  else
    iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
    if iconRendererObj then
      for id, data in pairs(self.iconDataById or {}) do
        data.color = ColorI(0,0,0,0)
      end
    end
  end

  -- hiding the icon mesh
  if self.iconMeshId then
    local meshObj = scenetree.findObjectById(self.iconMeshId)
    if meshObj then
      meshObj.instanceColor = ColorF(1,1,1,0):asLinear4F()
      meshObj.instanceColor2 = ColorF(1,1,1,0):asLinear4F()
      meshObj:updateInstanceRenderData()
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
  if self.skiaIcon then
    self.skiaIcon:release() -- back into the pool, for the next marker of the same look
    self.skiaIcon = nil
  elseif next(self.iconDataById or {}) then
    iconRendererObj = gameplay_playmodeMarkers.getIconRendererObj()
    if iconRendererObj then
      for id, _ in pairs(self.iconDataById or {}) do
        iconRendererObj:removeIconById(id)
      end
    end
  end

  -- Clear icon mesh object
  if self.iconMeshId then
    local meshObj = scenetree.findObjectById(self.iconMeshId)
    if meshObj then
      meshObj:delete()
    end
  end

  self.missionIconId = nil
  self.iconMeshId = nil
  self.iconDataById = {}
end

-- Interactivity
function C:interactInPlayMode(interactData, interactableElements)
  if interactData.canInteract then
    if self:playerIsInArea(interactData) then
      for _, elem in ipairs(self.cluster.elemData) do
        table.insert(interactableElements, elem)
      end
    end
  end
end

-- minimap
local radius, strikeWidth = 6, 2
local fillColor = color(72,125,249,255)
local strikeColor = color(255,255,255,255)
function C:drawOnMinimap(td, dpi)
  local worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset = ui_apps_minimap_utils.getWorldToMapTransform()
  td:triangleMarker(self.pos.x, self.pos.y, radius, 2, strikeWidth, dpi, fillColor, strikeColor, worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layers.GAMEPLAY_MARKERS)
end

local quadtree = require('quadtree')
local function idSort(a,b) return a.id < b.id end
local function dateSort(a,b) return tonumber(a.data.date) > tonumber(b.data.date) end
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
    radius = hardcodedRadius, -- Fixed radius of 1.5m
    icon = "",
    containedIdsLookup = {},
    elemData = {},
    create = create,
    visibleBySetting = "showMissionMarkers",
  }
  local containsMissions = false
  local count = 0
  local mixedTypes = false
  table.sort(pois, dateSort)
  for i, poi in ipairs(pois) do
    local mi = poi.markerInfo.missionMarker
    cluster.pos = cluster.pos + mi.pos
    cluster.rot = mi.rot
    cluster.icon = mi.icon
    if i > 1 and mi.iconFontIcon ~= cluster.iconFontIcon then mixedTypes = true end
    cluster.iconFontIcon = mi.iconFontIcon
    cluster.containedIds[i] = poi.id
    cluster.id = cluster.id..poi.id
    cluster.containedIdsLookup[poi.id] = true
    count = count + 1
    cluster.elemData[i] = poi.data
  end
  cluster.pos = cluster.pos / count
  cluster.visibilityPos = cluster.pos
  cluster.visibilityRadius = cluster.radius + 5

  if count > 1 then
    cluster.icon = string.format("mission_no-%02d_triangle",math.min(count, 9))
    -- Missions that all share an icon still read fine as that icon, so only a cluster of
    -- differing types falls back to showing how many are stacked here.
    if mixedTypes then cluster.markerText = count > 9 and "9+" or tostring(count) end
  end
  return cluster
end

-- Mission markers are clustered with the original clustering algorithm - when they overlap, they merge.
local function cluster(pois, allClusters)
  local poiList = {}
  for i, poi in ipairs(pois) do poiList[i] = poi end
  table.sort(poiList, idSort)

  -- preload all elements into a qt for quick clustering
  local qt = quadtree.newQuadtree()
  local count = 0
  for i, poi in ipairs(poiList) do
    qt:preLoad(i, quadtree.pointBBox(poi.markerInfo.missionMarker.pos.x, poi.markerInfo.missionMarker.pos.y, 1.5)) -- Fixed radius of 1.5m
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
      for id in qt:query(quadtree.pointBBox(pmi.pos.x, pmi.pos.y, 1.5)) do -- Fixed radius of 1.5m
        local candidate = poiList[id]

        candidate._qtId = id
        if pmi.pos:squaredDistance(candidate.markerInfo.missionMarker.pos) < square(1.5 + 1.5) then -- Fixed radius of 1.5m
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