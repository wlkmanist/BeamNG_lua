-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")
local buttonInstance = buttonModule.create()
local actionButtonsByPoiId = {}

local function canSetRoute()
  if career_modules_testDrive and career_modules_testDrive.isActive() then
    return false
  end
  return true
end

local function getOrCreateSetRouteButton(poiId)
  actionButtonsByPoiId[poiId] = actionButtonsByPoiId[poiId] or {}
  local cached = actionButtonsByPoiId[poiId].setRoute
  if cached then return cached end

  local meta = buttonInstance.addButton(function()
    if freeroam_bigMapMode and freeroam_bigMapMode.navigateToMission then
      freeroam_bigMapMode.navigateToMission(poiId)
    end
    return true
  end, {
    label = _tr("ui.pause.nearbyActivities.action.setRoute"),
    action = "setRoute",
    poiId = poiId,
  })
  actionButtonsByPoiId[poiId].setRoute = meta
  return meta
end

local function getOrCreateViewButton(poiId)
  actionButtonsByPoiId[poiId] = actionButtonsByPoiId[poiId] or {}
  local cached = actionButtonsByPoiId[poiId].view
  if cached then return cached end

  local meta = buttonInstance.addButton(function()
    log("I", "NearbyActivities", "View nearby activity " .. tostring(poiId))
    if not (freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap) then return false end
    -- autoSelectPoiId is picked up by the Vue bigmap once it has mounted, see getAndClearPendingAutoSelectPoiId
    freeroam_bigMapMode.enterBigMap({instant = true, routeTarget = "pause.bigmap", autoSelectPoiId = poiId})
    return true
  end, {
    label = _tr("ui.pause.nearbyActivities.action.view"),
    action = "view",
    poiId = poiId,
  })
  actionButtonsByPoiId[poiId].view = meta
  return meta
end

local function getActionsForPoi(poiId, isBigMapAllowed)
  local viewBtn = getOrCreateViewButton(poiId)
  local routeBtn = getOrCreateSetRouteButton(poiId)
  return {
    view = {
      buttonId = viewBtn.buttonId,
      label = viewBtn.label,
      action = viewBtn.action,
      icon = "mapWithEmitter",
      uiEvent = "ok",
      disabled = not isBigMapAllowed,
    },
    route = {
      buttonId = routeBtn.buttonId,
      label = routeBtn.label,
      action = routeBtn.action,
      icon = "routeSimple",
      uiEvent = "action_2",
      disabled = not canSetRoute(),
    },
  }
end

function M.executeNearbyActivityAction(buttonId, payload)
  if not buttonId then return false end
  return buttonInstance.executeButton(buttonId, payload)
end

local function prettyPoiType(poiType)
  local names = {
    mission = "ui.pause.nearbyActivities.poiType.mission",
    spawnPoint = "ui.pause.nearbyActivities.poiType.spawnPoint",
    garage = "ui.pause.nearbyActivities.poiType.garage",
    gasStation = "ui.pause.nearbyActivities.poiType.gasStation",
    dealership = "ui.pause.nearbyActivities.poiType.dealership",
    logisticsParking = "ui.pause.nearbyActivities.poiType.logisticsParking",
    logisticsOffice = "ui.pause.nearbyActivities.poiType.logisticsOffice",
    driftSpot = "ui.pause.nearbyActivities.poiType.driftSpot",
    dragstrip = "ui.pause.nearbyActivities.poiType.dragstrip",
    crawl = "ui.pause.nearbyActivities.poiType.crawl",
    playerVehicle = "ui.pause.nearbyActivities.poiType.playerVehicle",
  }
  local key = names[poiType]
  if key then return _tr(key) end
  return tostring(poiType or _tr("ui.pause.nearbyActivities.poiType.activity"))
end

local function getPlayerPos()
  if core_camera and core_camera.getPosition then
    return core_camera.getPosition()
  end
  return nil
end

local function getRawPoiById()
  local byId = {}
  if not gameplay_rawPois or not gameplay_rawPois.getRawPoiListByLevel then
    return byId
  end

  gameplay_rawPois.clear()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  local rawPois = gameplay_rawPois.getRawPoiListByLevel(levelId) or {}
  for _, poi in ipairs(rawPois) do
    if poi and poi.id then
      byId[poi.id] = poi
    end
  end
  return byId
end

local function getDistanceFromPlayer(playerPos, rawPoi)
  if not playerPos or not rawPoi or not rawPoi.markerInfo or not rawPoi.markerInfo.bigmapMarker then
    return nil
  end
  local marker = rawPoi.markerInfo.bigmapMarker
  if not marker.pos then return nil end
  local radius = marker.radius or 0
  return math.max(0, (marker.pos - playerPos):length() - radius)
end

local function sortByDistance(a, b)
  if a.distanceM and b.distanceM then return a.distanceM < b.distanceM end
  if a.distanceM then return true end
  if b.distanceM then return false end
  return tostring(a.id) < tostring(b.id)
end

local function addUniqueSelection(selection, selectedIds, item)
  if not item or selectedIds[item.id] then return false end
  selectedIds[item.id] = true
  table.insert(selection, item)
  return true
end

local function getUnselectedItems(items, selectedIds)
  local remaining = {}
  for _, item in ipairs(items) do
    if not selectedIds[item.id] then
      table.insert(remaining, item)
    end
  end
  return remaining
end

local function addNearestSelections(selection, selectedIds, items, count)
  for _, item in ipairs(items) do
    if count <= 0 then return end
    if addUniqueSelection(selection, selectedIds, item) then
      count = count - 1
    end
  end
end

local function addMediumDistanceSelections(selection, selectedIds, items, count)
  local remaining = getUnselectedItems(items, selectedIds)
  if #remaining == 0 then return end

  local startIndex = math.max(1, math.floor((#remaining - count) / 2) + 1)
  for i = startIndex, #remaining do
    if count <= 0 then return end
    if addUniqueSelection(selection, selectedIds, remaining[i]) then
      count = count - 1
    end
  end
end

local function addRandomSelections(selection, selectedIds, items, count)
  local remaining = getUnselectedItems(items, selectedIds)
  while count > 0 and #remaining > 0 do
    local index = math.random(#remaining)
    if addUniqueSelection(selection, selectedIds, remaining[index]) then
      count = count - 1
    end
    table.remove(remaining, index)
  end
end

local function selectActivityItems(items, maxItems)
  local selection = {}
  local selectedIds = {}
  local targetCount = maxItems or 6

  addNearestSelections(selection, selectedIds, items, math.min(2, targetCount))
  addMediumDistanceSelections(selection, selectedIds, items, math.min(2, targetCount - #selection))
  addRandomSelections(selection, selectedIds, items, targetCount - #selection)

  table.sort(selection, sortByDistance)
  return selection
end

local function getNearbyActivityItems(maxItems, isBigMapAllowed)
  if not freeroam_vueBigMap or not freeroam_vueBigMap.getPoiData then
    return {}
  end

  local playerPos = getPlayerPos()
  local poiData = freeroam_vueBigMap.getPoiData() or {}
  local rawPoiById = getRawPoiById()
  local out = {}

  for poiId, poi in pairs(poiData) do
    if poi.type ~= "spawnPoint" and poi.type ~= "playerVehicle" then
      local rawPoi = rawPoiById[poiId]
      local dist = getDistanceFromPlayer(playerPos, rawPoi)
      if dist then
        local rawId = poi.id or poiId
        table.insert(out, {
          id = tostring(rawId),
          title = _tr(poi.name or tostring(rawId)),
          icon = poi.icon,
          description = prettyPoiType(poi.type),
          actionLabel = _tr("ui.pause.nearbyActivities.action.open"),
          poiType = poi.type,
          distanceM = dist and math.floor(dist + 0.5) or nil,
          actions = getActionsForPoi(rawId, isBigMapAllowed),
        })
      end
    end
  end

  table.sort(out, sortByDistance)
  return selectActivityItems(out, maxItems)
end

function M.getData(context)
  local mode = context and context.mode or "freeroam"
  local nearbyItems = getNearbyActivityItems(6, context and context.isBigMapAllowed)

  if #nearbyItems == 0 then
    nearbyItems = {
      {
        id = "nearby.none",
        title = _tr("ui.pause.nearbyActivities.none.title"),
        description = _tr("ui.pause.nearbyActivities.none.description"),
        actionLabel = _tr("ui.pause.nearbyActivities.none.openMap"),
      },
    }
  end

  return {
    mode = mode,
    sections = {
      {
        id = "nearbyActivities",
        title = _tr("ui.pause.nearbyActivities.sectionTitle"),
        items = nearbyItems,
      },
    },
  }
end

return M
