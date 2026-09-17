-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { 'gameplay_freeformDelivery_utils', 'gameplay_freeformDelivery_goals', 'gameplay_freeformDelivery_markers' }
local logTag = "freeformDelivery_routes"

local activeDelivery = nil
local routes = {} -- List of available routes from delivery JSON
local currentRoute = nil -- Current active route (targetAreaId or vehicleId)

local bigmapGroups = {}

local Text = {
  delivery = "missions.freeformDelivery.common.bigmapGroup.delivery.label",
  otherLocations = "missions.freeformDelivery.common.bigmapGroup.otherLocations.label",
  otherVehicles = "ui.menu.vehicleSelector.tileGroups.otherVehicles",
  relevantLocationsVehicles = "missions.freeformDelivery.common.bigmapGroup.relevantLocationsVehicles.label",
  unknownRoute = "missions.freeformDelivery.common.route.unknown",
  deliveryTargetDescription = "missions.freeformDelivery.common.bigmap.description.deliveryTarget",
  deliveryVehicleDescription = "missions.freeformDelivery.common.bigmap.description.deliveryVehicle",
  goalsHeader = "missions.freeformDelivery.common.bigmap.description.goalsHeader",
}

local function translateText(text)
  if text == nil then return nil end
  if core_locales and core_locales.translateWithOrWithoutContext then
    return core_locales.translateWithOrWithoutContext(text)
  end
  if type(text) == "table" and text.txt then
    return _tr(text.txt)
  end
  if type(text) == "string" then
    return _tr(text)
  end
  return text
end

local function contextTranslate(key, vars)
  if core_locales and core_locales.contextTranslate then
    return core_locales.contextTranslate(key, vars)
  end
  return _tr(key)
end

local function isPlayerInTargetArea(delivery, targetAreaId)
  local veh = gameplay_freeformDelivery_utils.getPlayerVehicle()
  if not veh then return false end

  local targetArea = gameplay_freeformDelivery_utils.findTargetArea(delivery, targetAreaId)
  if not targetArea then return false end

  local siteObj = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, targetArea.type, targetArea.siteId)
  if not siteObj then return false end

  return gameplay_freeformDelivery_utils.checkVehicleInArea(veh, siteObj, targetArea.type)
end

local function getMatchingLocationParams(route, delivery)
  -- Check if route has params array
  if not route.params or type(route.params) ~= "table" then
    return nil
  end

  -- Check if player is in any target area
  if not delivery.targetAreas then return nil end

  for _, targetArea in ipairs(delivery.targetAreas) do
    if isPlayerInTargetArea(delivery, targetArea.id) then
      -- Check if route has location-specific params for this area
      for _, paramEntry in ipairs(route.params) do
        if paramEntry.targetAreaId == targetArea.id then
          return paramEntry
        end
      end
    end
  end

  return nil
end

local function getDefaultParams(route)
  -- Check if route has params array
  if not route.params or type(route.params) ~= "table" then
    return nil
  end

  -- Find default entry (no targetAreaId)
  for _, paramEntry in ipairs(route.params) do
    if not paramEntry.targetAreaId then
      return paramEntry
    end
  end

  return nil
end

local function getRouteParams(route, delivery)
  -- First check location matching
  local locationParams = getMatchingLocationParams(route, delivery)
  if locationParams then
    return locationParams
  end

  -- Fallback to default params (no targetAreaId)
  local defaultParams = getDefaultParams(route)
  if defaultParams then
    return defaultParams
  end

  return nil
end

local function getTargetAreaPosition(delivery, targetAreaId)
  local targetArea = gameplay_freeformDelivery_utils.findTargetArea(delivery, targetAreaId)
  if not targetArea then return nil end

  local siteObj = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, targetArea.type, targetArea.siteId)
  if not siteObj then return nil end

  if targetArea.type == "location" then
    return siteObj.pos
  elseif targetArea.type == "zone" then
    -- Use zone center if available, otherwise compute from vertices
    if siteObj.center then
      return siteObj.center
    elseif siteObj.vertices and #siteObj.vertices > 0 then
      local center = vec3(0, 0, 0)
      for _, vertex in ipairs(siteObj.vertices) do
        if type(vertex) == "table" and vertex.pos then
          center = center + vec3(vertex.pos)
        elseif type(vertex) == "table" and #vertex >= 3 then
          center = center + vec3(vertex[1], vertex[2], vertex[3])
        end
      end
      local avgCenter = center / #siteObj.vertices
      if core_terrain.getTerrain() and core_terrain.getTerrainHeight(avgCenter) > 0 then
        avgCenter.z = core_terrain.getTerrainHeight(avgCenter)
      end
      return avgCenter
    end
    return nil
  elseif targetArea.type == "parkingSpot" then
    return siteObj.pos
  end

  return nil
end

local function getVehiclePosition(delivery, vehicleId)
  return gameplay_freeformDelivery_utils.getVehiclePositionByDeliveryId(vehicleId)
end

local function loadRaceFile(raceFilePath, delivery)
  if not raceFilePath then return nil end

  -- Resolve path relative to delivery file if needed
  local resolvedPath = gameplay_freeformDelivery_utils.resolvePath(delivery._basePath, raceFilePath)
  if not resolvedPath then
    log('W', logTag, 'Could not resolve race file path: ' .. tostring(raceFilePath))
    return nil
  end

  -- Load race.json file
  local raceData = jsonReadFile(resolvedPath)
  if not raceData then
    log('W', logTag, 'Could not load race file: ' .. tostring(resolvedPath))
    return nil
  end

  -- Create race path object
  local RacePath = require('/lua/ge/extensions/gameplay/race/path')
  local racePath = RacePath()
  racePath:onDeserialized(raceData)

  return racePath
end

local function applyRouteParams(options, params)
  if not params then return end

  if params.cutOffDrivability ~= nil then
    options.cutOffDrivability = params.cutOffDrivability
  end
  if params.dirMult ~= nil then
    options.dirMult = params.dirMult
  end
  if params.penaltyAboveCutoff ~= nil then
    options.penaltyAboveCutoff = params.penaltyAboveCutoff
  end
  if params.penaltyBelowCutoff ~= nil then
    options.penaltyBelowCutoff = params.penaltyBelowCutoff
  end
  if params.wD ~= nil then
    options.wD = params.wD
  end
  if params.wZ ~= nil then
    options.wZ = params.wZ
  end
  -- Handle "penalty" as alias for penaltyAboveCutoff
  if params.penalty ~= nil and params.penaltyAboveCutoff == nil then
    options.penaltyAboveCutoff = params.penalty
  end
end

-- Get waypoint positions from waypoint names
local function getWaypointPositions(waypointNames)
  if not waypointNames or #waypointNames == 0 then
    return {}
  end

  local waypoints = {}
  local mapData = map and map.getMap()

  if not mapData or not mapData.nodes then
    log('W', logTag, 'Map data not available for waypoint lookup')
    return {}
  end

  for _, wpName in ipairs(waypointNames) do
    if type(wpName) == "string" then
      local node = mapData.nodes[wpName]
      if node and node.pos then
        table.insert(waypoints, wpName) -- Pass as string, setPath will look it up
      else
        log('W', logTag, 'Waypoint not found in map: ' .. tostring(wpName))
      end
    end
  end

  return waypoints
end

-- Get waypoints from race path
local function getWaypointsFromRacePath(racePath)
  if not racePath then return {} end

  local waypoints = {}
  if racePath.pathnodes and racePath.pathnodes.sorted then
    for _, pathnode in ipairs(racePath.pathnodes.sorted) do
      if pathnode.pos then
        -- Convert pos to vec3 if needed
        local pos = pathnode.pos
        if type(pos) == "table" and #pos >= 3 then
          pos = vec3(pos[1], pos[2], pos[3])
        end
        table.insert(waypoints, pos)
      end
    end
  end

  return waypoints
end

-- Build and set a route: waypoints + final position + options
local function buildRoute(waypoints, finalPosition, options)
  if not core_groundMarkers then return false end

  -- Build path: waypoints + final position
  local path = {}

  -- Add waypoints
  if waypoints and #waypoints > 0 then
    for _, wp in ipairs(waypoints) do
      table.insert(path, wp)
    end
  end

  -- Add final position if provided
  if finalPosition then
    table.insert(path, finalPosition)
  end

  if #path == 0 then
    log('W', logTag, 'Route has no waypoints or final position')
    return false
  end

  -- Set default options
  local routeOptions = {
    step = 3,
    clearPathOnReachingTarget = false
  }

  -- Merge provided options
  if options then
    for k, v in pairs(options) do
      routeOptions[k] = v
    end
  end

  -- Set path
  core_groundMarkers.setPath(path, routeOptions)

  return true
end

-- Common route building logic
local function buildRouteToTarget(targetPos, routeType, targetId, route, zoneForMarker, parkingSpotForMarker)
  if not activeDelivery then return false end

  -- Get route parameters (location-specific or default)
  local params = route and getRouteParams(route, activeDelivery) or nil

  -- Build waypoints list
  local waypoints = {}

  -- Check if params specify a race file
  if params and params.raceFile then
    local racePath = loadRaceFile(params.raceFile, activeDelivery)
    if racePath then
      local raceWaypoints = getWaypointsFromRacePath(racePath)
      if #raceWaypoints == 0 then
        log('W', logTag, 'Race path has no waypoints')
        return false
      end
      -- Add race waypoints
      for _, wp in ipairs(raceWaypoints) do
        table.insert(waypoints, wp)
      end
      log('I', logTag, 'Route includes ' .. #raceWaypoints .. ' waypoint(s) from race file')
    end
  end

  -- Add waypoints from waypoint names if specified
  if params and not params.raceFile and params.waypointNames and #params.waypointNames > 0 then
    local namedWaypoints = getWaypointPositions(params.waypointNames)
    if #namedWaypoints > 0 then
      for _, wp in ipairs(namedWaypoints) do
        table.insert(waypoints, wp)
      end
      log('I', logTag, 'Route includes ' .. #namedWaypoints .. ' waypoint(s) from names')
    end
  end

  -- Build route options
  local options = {}
  if params then
    applyRouteParams(options, params)
  end

  -- Build and set route
  if not buildRoute(waypoints, targetPos, options) then
    return false
  end

  -- Store current route
  currentRoute = {
    type = routeType,
    id = targetId
  }

  -- Update tasklist route message
  gameplay_freeformDelivery_tasklist.updateRouteMessage()

  -- Always create overhead route marker; add zone boundary marker when zoneForMarker is set.
  gameplay_freeformDelivery_markers.setRouteMarker(targetPos, zoneForMarker, parkingSpotForMarker)

  return true
end

-- Set route to a target area
function M.setRouteToTargetArea(targetAreaId, route)
  if not core_groundMarkers then return false end

  local targetArea = gameplay_freeformDelivery_utils.findTargetArea(activeDelivery, targetAreaId)
  if not targetArea then
    log('W', logTag, 'Could not find target area: ' .. tostring(targetAreaId))
    return false
  end

  local siteObj = gameplay_freeformDelivery_utils.findSiteObject(activeDelivery.sites, targetArea.type, targetArea.siteId)
  if not siteObj then
    log('W', logTag, 'Could not find site object for target area: ' .. tostring(targetAreaId))
    return false
  end

  local targetPos = getTargetAreaPosition(activeDelivery, targetAreaId)
  if not targetPos then
    log('W', logTag, 'Could not get position for target area: ' .. tostring(targetAreaId))
    return false
  end

  local zoneForMarker = nil
  local parkingSpotForMarker = nil
  if targetArea.type == "zone" then
    zoneForMarker = siteObj
  elseif targetArea.type == "parkingSpot" then
    parkingSpotForMarker = siteObj
  end

  if buildRouteToTarget(targetPos, 'targetArea', targetAreaId, route, zoneForMarker, parkingSpotForMarker) then
    log('I', logTag, 'Route set to target area: ' .. tostring(targetAreaId))
    return true
  end

  return false
end

-- Set route to a vehicle
function M.setRouteToVehicle(vehicleId, route)
  if not core_groundMarkers then return false end

  local targetPos = getVehiclePosition(activeDelivery, vehicleId)
  if not targetPos then
    log('W', logTag, 'Could not get position for vehicle: ' .. tostring(vehicleId))
    return false
  end

  if buildRouteToTarget(targetPos, 'vehicle', vehicleId, route) then
    log('I', logTag, 'Route set to vehicle: ' .. tostring(vehicleId))
    return true
  end

  return false
end

-- Get route display name
function M.getRouteName(route)
  if route.targetAreaId then
    local targetArea = gameplay_freeformDelivery_utils.findTargetArea(activeDelivery, route.targetAreaId)
    if targetArea then
      return translateText(targetArea.name) or route.targetAreaId
    end
    return route.targetAreaId
  elseif route.vehicleId then
    local vehicle = gameplay_freeformDelivery_utils.findVehicle(activeDelivery, route.vehicleId)
    if vehicle then
      return translateText(vehicle.name) or vehicle.id
    end
    return route.vehicleId
  end
  return _tr(Text.unknownRoute)
end

-- Get route by index
function M.getRoute(index)
  if not routes or index < 1 or index > #routes then
    return nil
  end
  return routes[index]
end

-- Get all available routes
function M.getRoutes()
  return routes
end

-- Get current active route
function M.getCurrentRoute()
  return currentRoute
end

-- Get route count
function M.getRouteCount()
  return routes and #routes or 0
end

-- Get all target areas (for POI generation)
function M.getTargetAreas()
  if not activeDelivery then return {} end
  return activeDelivery.targetAreas or {}
end

-- Get all vehicles (for POI generation)
function M.getVehicles()
  if not activeDelivery then return {} end
  return activeDelivery.vehicles or {}
end

-- Get target area position (public API)
function M.getTargetAreaPosition(targetAreaId)
  if not activeDelivery then return nil end
  return getTargetAreaPosition(activeDelivery, targetAreaId)
end

-- Get vehicle position (public API)
function M.getVehiclePosition(vehicleId)
  if not activeDelivery then return nil end
  return getVehiclePosition(activeDelivery, vehicleId)
end

-- Clear current route
function M.clearRoute()
  gameplay_freeformDelivery_markers.hideRouteMarker()

  if not core_groundMarkers then return false end

  -- Clear route visualization
  core_groundMarkers.resetAll()

  -- Clear current route
  currentRoute = nil

  -- Update tasklist route message
  gameplay_freeformDelivery_tasklist.updateRouteMessage()

  log('I', logTag, 'Route cleared by player')
  return true
end

function M.setup(delivery)
  if not delivery then return end

  activeDelivery = delivery
  routes = delivery.routes or {}

  bigmapGroups = delivery.bigmapGroups or {}
  -- check if all routes and vehicles have a bigmapGroup key. if any are left out, create a fallback group "Other Locations" and "Other Vehicles"
  for _, route in ipairs(routes) do
    if not route.bigmapGroups or not next(route.bigmapGroups) then
      route.bigmapGroups = { "otherLocations" }
    end
  end
  for _, vehicle in ipairs(delivery.vehicles) do
    if not vehicle.bigmapGroups or not next(vehicle.bigmapGroups) then
      vehicle.bigmapGroups = { "otherVehicles" }
    end
  end

  table.insert(bigmapGroups, {id = "otherLocations", label = Text.otherLocations})
  table.insert(bigmapGroups, {id = "otherVehicles", label = Text.otherVehicles})

  log('I', logTag, 'Routes system initialized with ' .. #routes .. ' routes')
end

local function checkRouteArrival()
  if not currentRoute or not activeDelivery then return end

  local veh = gameplay_freeformDelivery_utils.getPlayerVehicle()
  if not veh then return end

  local arrived = false
  local arrivalMessage = ""

  if currentRoute.type == 'targetArea' then
    -- Check if player is in the target area
    if isPlayerInTargetArea(activeDelivery, currentRoute.id) then
      arrived = true
      local targetArea = gameplay_freeformDelivery_utils.findTargetArea(activeDelivery, currentRoute.id)
      arrivalMessage = 'Arrived at ' .. (targetArea and (targetArea.name or currentRoute.id) or currentRoute.id)
    end
  elseif currentRoute.type == 'vehicle' then
    -- Check if player is within 10m of target vehicle
    local targetPos = getVehiclePosition(activeDelivery, currentRoute.id)
    if targetPos then
      local vehPos = gameplay_freeformDelivery_utils.getCachedVehiclePosition(veh)
      if vehPos then
        local distance = vehPos:distance(targetPos)
        if distance <= 10 then
          arrived = true
          arrivalMessage = 'Arrived at ' .. currentRoute.id
        end
      end
    end
  end

  if arrived then
    -- Hide route marker (marker object is fully removed during delivery cleanup).
    gameplay_freeformDelivery_markers.hideRouteMarker()

    -- Clear route
    if core_groundMarkers then
      core_groundMarkers.resetAll()
    end

    -- Clear current route
    currentRoute = nil

    -- Update tasklist route message
    gameplay_freeformDelivery_tasklist.updateRouteMessage()

    log('I', logTag, 'Route completed: ' .. arrivalMessage)
  end
end

function M.update(dtReal, dtSim, dtRaw, profiler)
  checkRouteArrival()
end

function M.cleanup()
  -- Clear route
  if core_groundMarkers then
    core_groundMarkers.resetAll()
  end

  activeDelivery = nil
  routes = {}
  currentRoute = nil

  -- Update tasklist route message (to clear it)
  gameplay_freeformDelivery_tasklist.updateRouteMessage()
end

local function translateLabel(label)
  if label == nil or label == "" then return label end
  return translateText(label)
end

-- Get goals related to a target area or vehicle (for POI generation)
local function getRelatedGoals(targetAreaId, vehicleId)
  local relatedGoals = {}
  local allGoals = gameplay_freeformDelivery_goals.getAllGoals() or gameplay_freeformDelivery_goals.getGoals() or {}

  for goalId, goal in pairs(allGoals) do
    local isRelated = false

    -- Check if goal is related to target area
    if targetAreaId and goal.targetAreaId == targetAreaId then
      isRelated = true
    end

    -- Check if goal is related to vehicle
    if vehicleId then
      local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goal)
      for _, vid in ipairs(vehicleIds) do
        if vid == vehicleId then
          isRelated = true
          break
        end
      end
    end

    if isRelated then
      local state = gameplay_freeformDelivery_goals.getGoalState(goalId)
      local goalLabel = translateLabel(goal.label) or goalId
      table.insert(relatedGoals, {
        id = goalId,
        label = goalLabel,
        completed = state and state.completed or false,
        order = goal.order or 0
      })
    end
  end

  table.sort(relatedGoals, function(a, b)
    local aOrder = tonumber(a.order) or 0
    local bOrder = tonumber(b.order) or 0
    if aOrder ~= bOrder then
      return aOrder < bOrder
    end

    local aLabel = string.lower(tostring(a.label or ""))
    local bLabel = string.lower(tostring(b.label or ""))
    if aLabel ~= bLabel then
      return aLabel < bLabel
    end

    return tostring(a.id or "") < tostring(b.id or "")
  end)

  return relatedGoals
end

local function getBigmapMedia(preview, thumbnail)
  local previews = nil
  if preview then
    previews = {preview}
  end
  return previews, thumbnail
end

local function resolveCouplerAttachedRoute(routeSpec)
  if type(routeSpec) ~= "table" then
    return nil
  end

  if not routeSpec.targetAreaId and not routeSpec.vehicleId then
    return nil
  end

  local matchedRoute = nil
  for _, route in ipairs(routes or {}) do
    if routeSpec.targetAreaId and route.targetAreaId == routeSpec.targetAreaId then
      matchedRoute = route
      break
    end
    if routeSpec.vehicleId and route.vehicleId == routeSpec.vehicleId then
      matchedRoute = route
      break
    end
  end

  if not matchedRoute then
    return routeSpec
  end

  -- Start from route list data (keeps shared params/waypoints), then apply explicit coupler route overrides.
  local resolvedRoute = deepcopy(matchedRoute)
  for key, value in pairs(routeSpec) do
    resolvedRoute[key] = value
  end
  return resolvedRoute
end

local function applyCouplerAttachedRouteForVehicle(otherVehId)
  if not activeDelivery then return end

  local spawnedVehicles = gameplay_freeformDelivery_setup.getSpawnedVehicles()
  local spawnedVehicleData = spawnedVehicles and spawnedVehicles[otherVehId]
  local deliveryVehicle = spawnedVehicleData and spawnedVehicleData.deliveryVehicle
  if not deliveryVehicle then return end

  local routeSpec = deliveryVehicle.couplerAttachedRoute
  if not routeSpec then return end

  local route = resolveCouplerAttachedRoute(routeSpec)
  if not route then
    log('W', logTag, 'Could not resolve couplerAttachedRoute for vehicle: ' .. tostring(deliveryVehicle.id))
    return
  end

  if route.targetAreaId then
    M.setRouteToTargetArea(route.targetAreaId, route)
    return
  end

  if route.vehicleId then
    M.setRouteToVehicle(route.vehicleId, route)
    return
  end

  log('W', logTag, 'couplerAttachedRoute has no targetAreaId/vehicleId for vehicle: ' .. tostring(deliveryVehicle.id))
end

local function getCouplerAttachedRouteForVehicle(otherVehId)
  if not activeDelivery then return nil end

  local spawnedVehicles = gameplay_freeformDelivery_setup.getSpawnedVehicles()
  local spawnedVehicleData = spawnedVehicles and spawnedVehicles[otherVehId]
  local deliveryVehicle = spawnedVehicleData and spawnedVehicleData.deliveryVehicle
  if not deliveryVehicle then return nil end

  local routeSpec = deliveryVehicle.couplerAttachedRoute
  if not routeSpec then return nil end

  local route = resolveCouplerAttachedRoute(routeSpec)
  if not route then
    log('W', logTag, 'Could not resolve couplerAttachedRoute for vehicle: ' .. tostring(deliveryVehicle.id))
    return nil
  end

  return route
end

local function doesRouteMatchCurrent(route)
  if not route or not currentRoute then return false end

  if route.targetAreaId and currentRoute.type == "targetArea" and currentRoute.id == route.targetAreaId then
    return true
  end

  if route.vehicleId and currentRoute.type == "vehicle" and currentRoute.id == route.vehicleId then
    return true
  end

  return false
end

-- Format delivery data to POI elements for bigmap
local function formatDeliveryToRawPoi(elements)
  -- Check if delivery is active
  local mainDelivery = gameplay_freeformDelivery_freeformDelivery
  local isActive = mainDelivery.isActive()
  local currentDelivery = mainDelivery.getCurrentDelivery()

  if not isActive or not currentDelivery then return end

  local currentlyActiveGoals = {}
  for goalId, goal in pairs(gameplay_freeformDelivery_goals.getGoals()) do
    currentlyActiveGoals[goalId] = true
  end

  -- Add POIs for routes (target areas and vehicles from routes)
  local allPois = {}
  if routes and #routes > 0 then
    for i, route in ipairs(routes) do
      local routeName = M.getRouteName(route)
      local targetPos = nil
      local poiId = nil
      local poiType = nil
      local icon = route.icon or "location2"
      local relatedGoals = {}
      local customNavigationFunction = nil
      local preview = nil
      local thumbnail = nil
      local customGroupTags = deepcopy(route.bigmapGroups)

      if route.targetAreaId then
        local targetArea = gameplay_freeformDelivery_utils.findTargetArea(currentDelivery, route.targetAreaId)
        targetPos = M.getTargetAreaPosition(route.targetAreaId)
        poiId = string.format("delivery-targetArea-%s", route.targetAreaId)
        poiType = "deliveryTargetArea"
        for _, goalId in ipairs(targetArea.relevantGoals or {}) do
          if currentlyActiveGoals[goalId] then
            table.insert(customGroupTags, "delivery_relevant")
            break
          end
        end
        icon = route.icon or "location2"
        relatedGoals = getRelatedGoals(route.targetAreaId, nil)
        preview = targetArea and targetArea.preview or nil
        thumbnail = targetArea and targetArea.thumbnail or nil
        customNavigationFunction = function(poi)
          M.setRouteToTargetArea(route.targetAreaId, route)
          return targetPos
        end
      elseif route.vehicleId then
        local vehicleData = gameplay_freeformDelivery_utils.findVehicle(currentDelivery, route.vehicleId)
        targetPos = M.getVehiclePosition(route.vehicleId)
        poiId = string.format("delivery-vehicle-%s", route.vehicleId)
        poiType = "deliveryVehicle"
        for _, goalId in ipairs(vehicleData.relevantGoals or {}) do
          if currentlyActiveGoals[goalId] then
            table.insert(customGroupTags, "delivery_relevant")
            break
          end
        end
        icon = route.icon or "boxTruckFast"
        relatedGoals = getRelatedGoals(nil, route.vehicleId)
        preview = vehicleData and vehicleData.preview or nil
        thumbnail = vehicleData and vehicleData.thumbnail or nil
        customNavigationFunction = function(poi)
          M.setRouteToVehicle(route.vehicleId, route)
          return targetPos
        end
      end

      if targetPos and poiId then
        -- Build description with goal information (BBCode for rich text in UI)
        local description = contextTranslate(Text.deliveryTargetDescription, { name = routeName })
        if #relatedGoals > 0 then
          description = description .. _tr(Text.goalsHeader)
          local goalTexts = {}
          for _, goal in ipairs(relatedGoals) do
            local status = goal.completed and "[color=#65D46E]✓[/color]" or "[color=#CFD3D8]○[/color]"
            table.insert(goalTexts, string.format("\n%s %s", status, goal.label))
          end
          description = description .. table.concat(goalTexts, "")
        end
        local previews, resolvedThumbnail = getBigmapMedia(preview, thumbnail)

        table.insert(allPois, {
          id = poiId,
          data = { type = poiType, id = route.targetAreaId or route.vehicleId, customGroupTags = customGroupTags, order = i },
          customNavigationFunction = customNavigationFunction,
          markerInfo = {
            bigmapMarker = {
              pos = targetPos,
              name = routeName,
              description = description,
              thumbnail = resolvedThumbnail,
              previews = previews,
              icon = "poi_exclamationmark_round",
              cardIcon = icon,
              groupTags = { delivery = true },
            }
          }
        })
      end
    end
  end

  -- Add POIs for all vehicles (even if not in routes)
  local vehicles = M.getVehicles()
  local routeVehicleIds = {}
  -- Track which vehicles are already in routes
  if routes then
    for _, route in ipairs(routes) do
      if route.vehicleId then
        routeVehicleIds[route.vehicleId] = true
      end
    end
  end

  for i, vehicleData in ipairs(vehicles) do
    -- Skip if already added as a route
    if routeVehicleIds[vehicleData.id] then
      goto continue
    end

    local vehiclePos = M.getVehiclePosition(vehicleData.id)
    if vehiclePos then
      local vehicleName = translateText(vehicleData.name) or vehicleData.id
      local poiId = string.format("delivery-vehicle-%s", vehicleData.id)
      local relatedGoals = getRelatedGoals(nil, vehicleData.id)

      -- Build description with goal information (BBCode for rich text in UI)
      local description = contextTranslate(Text.deliveryVehicleDescription, { name = vehicleName })
      if #relatedGoals > 0 then
        description = description .. _tr(Text.goalsHeader)
        local goalTexts = {}
        for _, goal in ipairs(relatedGoals) do
          local status = goal.completed and "[color=#65D46E]✓[/color]" or "[color=#CFD3D8]○[/color]"
          table.insert(goalTexts, string.format("\n%s %s", status, goal.label))
        end
        description = description .. table.concat(goalTexts, "")
      end
      local previews, thumbnail = getBigmapMedia(vehicleData.preview, vehicleData.thumbnail)
      local customGroupTags = deepcopy(vehicleData.bigmapGroups)
      for _, goalId in ipairs(vehicleData.relevantGoals or {}) do
        if currentlyActiveGoals[goalId] then
          table.insert(customGroupTags, "delivery_relevant")
          break
        end
      end
      table.insert(allPois, {
        id = poiId,
        data = { type = "deliveryVehicle", customGroupTags = customGroupTags, enterable = vehicleData.enterable, order = i },
        customNavigationFunction = function(poi)
          M.setRouteToVehicle(vehicleData.id)
          return vehiclePos
        end,
        markerInfo = {
          bigmapMarker = {
            pos = vehiclePos,
            name = vehicleName,
            description = description,
            thumbnail = thumbnail,
            previews = previews,
            icon = "poi_exclamationmark_round",
            cardIcon = "boxTruckFast",
            groupTags = { delivery = true },
          }
        }
      })
    end
    ::continue::
  end

  local enterableVehicles, nonEnterableVehicles, targetAreas = {}, {}, {}
  for _, poi in ipairs(allPois) do
    if poi.data.type == "deliveryVehicle" and poi.data.enterable then
      table.insert(enterableVehicles, poi)
    elseif poi.data.type == "deliveryVehicle" and not poi.data.enterable then
      table.insert(nonEnterableVehicles, poi)
    elseif poi.data.type == "deliveryTargetArea" then
      table.insert(targetAreas, poi)
    end
  end
  local sortByOrder = function(a,b) return a.data.order < b.data.order end
  table.sort(enterableVehicles, sortByOrder)
  table.sort(targetAreas, sortByOrder)
  table.sort(nonEnterableVehicles, sortByOrder)

  table.clear(allPois)

  arrayConcat(allPois, enterableVehicles)
  arrayConcat(allPois, targetAreas)
  arrayConcat(allPois, nonEnterableVehicles)

  for i, poi in ipairs(allPois) do
    poi.data.order = i
    table.insert(elements, poi)
  end
end


local function sortByOrderThenId(a, b)
  if a.order and b.order then
    return a.order < b.order
  elseif a.order and not b.order then
    return true
  elseif not a.order and b.order then
    return false
  else
    return a.id < b.id
  end

end
-- Bigmap handlers
function M.onBigmapBuildGroupData(groupData)
  groupData.delivery_relevant = {
    label = _tr(Text.relevantLocationsVehicles),
    icon = "routeSimple",
    elements = {},
    sortFunction = sortByOrderThenId,
    openByDefault = true
  }
  for _, group in ipairs(bigmapGroups) do
    groupData[group.id] = {
      label = translateText(group.label),
      icon = group.icon,
      elements = {},
      sortFunction = sortByOrderThenId
    }
  end
end

function M.onBigmapBuildCustomGroupStructures(customGroupStructures)
  local structure = {
    key = "delivery",
    icon = "boxTruckFast",
    title = _tr(Text.delivery),
    groupIds = { "delivery_relevant" }
  }
  for _, group in ipairs(bigmapGroups) do
    table.insert(structure.groupIds, group.id)
  end
  table.insert(customGroupStructures, structure)
end

function M.onGetRawPoiListForLevel(levelIdentifier, elements)
  formatDeliveryToRawPoi(elements)
end

function M.onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
  if not activeDelivery then return end
  if not be then return end

  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then return end

  if playerVehId == objId1 then
    applyCouplerAttachedRouteForVehicle(objId2)
  elseif playerVehId == objId2 then
    applyCouplerAttachedRouteForVehicle(objId1)
  end
end

function M.onCouplerDetached(objId1, objId2, nodeId, obj2nodeId, breakForce)
  if not activeDelivery or not currentRoute then return end
  if not be then return end

  local playerVehId = be:getPlayerVehicleID(0)
  if not playerVehId then return end

  local otherVehId = nil
  if playerVehId == objId1 then
    otherVehId = objId2
  elseif playerVehId == objId2 then
    otherVehId = objId1
  else
    return
  end

  local couplerRoute = getCouplerAttachedRouteForVehicle(otherVehId)
  if doesRouteMatchCurrent(couplerRoute) then
    M.clearRoute()
    log('I', logTag, 'Cleared couplerAttachedRoute after uncoupling from vehicle: ' .. tostring(otherVehId))
  end
end

return M
