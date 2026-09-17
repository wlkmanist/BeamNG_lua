-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local p = nil -- Profiler instance (assigned in update function)

local markers = {}
local activeDelivery = nil
local groundDecals = {}
local decalCount = 0
local parkingSpotDecals = {} -- Store decal data per parking spot
local parkingSpotVehicles = {} -- Cache: areaId -> {vehicleId = true}
local createAttentionMarker = require("scenario/raceMarkers/attention")
local createZoneAttentionMarker = require("scenario/raceMarkers/zoneAttention")
local createParkingAttentionMarker = require("scenario/raceMarkers/parkingAttention")
local routeMarker = nil
local routeZoneMarker = nil
local routeParkingMarker = nil
local routeMarkerId = 0
local ATTENTION_MARKER_HEIGHT_OFFSET = 2
local ATTENTION_MARKER_SCALE = 1.5
-- Color RGB values (stored separately to avoid ColorF property access issues)
local parkedColorRGB = {r = 0, g = 1, b = 0} --
local partialParkedColorRGB = {r = 1, g = 1, b = 0} -- Yellow for partial parking (1-3 corners)
local blockedColorRGB = {r = 0.929427, g = 0.219431, b = 0.137123} -- bng-add-red-500
local unparkedColorRGB = {r = 1, g = 1, b = 1} -- White for not parked

local function drawLocationMarker(location, completed)
  -- Use module-level p variable

  if not location then return end

  local color = completed and ColorF(0, 1, 0, 0.3) or ColorF(1, 1, 0, 0.3)
  debugDrawer:drawSphere(location.pos, location.radius, color)
  if p then p:add("draw location sphere") end

  -- Draw text label
  if location.name then
    debugDrawer:drawTextAdvanced(location.pos + vec3(0, 0, location.radius + 2),
                                 String(location.name),
                                 ColorF(1, 1, 1, 1),
                                 true, false,
                                 ColorI(0, 0, 0, 192))
    if p then p:add("draw location text") end
  end
end

local function drawZoneMarker(zone, completed)
  -- Use module-level p variable

  if not zone then return end

  local color = completed and ColorF(0, 1, 0, 0.5) or ColorF(1, 1, 0, 0.5)
  zone:drawDebug('normal', {color.x, color.y, color.z, 0.5})
  if p then p:add("draw zone") end
end

local function drawParkingSpotDebug(parkingSpot, completed)
  -- Use module-level p variable

  if not parkingSpot then return end

  local color = completed and ColorF(0, 1, 0, 0.3) or ColorF(1, 1, 0, 0.3)

  -- Draw bounding box (debug visualization)
  local halfSize = vec3(parkingSpot.scl.x / 2, parkingSpot.scl.y / 2, parkingSpot.scl.z / 2)
  local corners = {
    parkingSpot.pos + parkingSpot.rot * vec3(-halfSize.x, -halfSize.y, 0),
    parkingSpot.pos + parkingSpot.rot * vec3(halfSize.x, -halfSize.y, 0),
    parkingSpot.pos + parkingSpot.rot * vec3(halfSize.x, halfSize.y, 0),
    parkingSpot.pos + parkingSpot.rot * vec3(-halfSize.x, halfSize.y, 0)
  }
  if p then p:add("calculate parking spot corners") end

  -- Draw rectangle outline
  for i = 1, 4 do
    local next = (i % 4) + 1
    debugDrawer:drawLine(corners[i], corners[next], color)
  end
  if p then p:add("draw parking spot lines") end

  -- Draw text label
  if parkingSpot.name then
    debugDrawer:drawTextAdvanced(parkingSpot.pos + vec3(0, 0, parkingSpot.scl.z / 2 + 1),
                                 String(parkingSpot.name),
                                 ColorF(1, 1, 1, 1),
                                 true, false,
                                 ColorI(0, 0, 0, 192))
    if p then p:add("draw parking spot text") end
  end
end

local function isVehicleParkedInSpot(vehicleId, parkingSpot)
  -- Use module-level p variable

  if p then p:add("get vehicle ID") end
  local veh = gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleId)
  if p then p:add("get object by ID") end
  if not veh then return false end

  local result = gameplay_freeformDelivery_utils.checkVehicleInParkingSpot(veh, parkingSpot)
  if p then p:add("check vehicle in spot") end
  return result
end

local function getAssociatedVehiclesForParkingSpot(areaId)
  -- Use cached associations
  return parkingSpotVehicles[areaId] or {}
end

local function updateParkingSpotDecalColor(areaId)
  -- Use module-level p variable

  local decalData = parkingSpotDecals[areaId]
  if not decalData then return end

  local marker = markers[areaId]
  if not marker or marker.type ~= "parkingSpot" then return end

  -- Build parking status from all delivery vehicles.
  -- States: "none", "partial", "full", "blocked" (wrong vehicle only).
  local parkingState = "none"
  if activeDelivery and areaId and activeDelivery.vehicles then
    local hasCorrectOverlap = false
    local hasWrongOverlap = false
    local associatedVehicles = getAssociatedVehiclesForParkingSpot(areaId)
    if p then p:add("get associated vehicles") end
    for _, vehicleDef in ipairs(activeDelivery.vehicles) do
      local vehicleId = vehicleDef.id
      local veh = vehicleId and gameplay_freeformDelivery_utils.getVehicleObjectByDeliveryId(vehicleId)
      if veh then
        local parkingInfo = gameplay_freeformDelivery_utils.getParkingInfo(veh, marker.siteObj)
        if parkingInfo then
          if associatedVehicles[vehicleId] then
            hasCorrectOverlap = true
            if parkingInfo.cornerCount == 4 then
              parkingState = "full"
              break -- Fully parked, no need to check other vehicles
            elseif parkingInfo.cornerCount >= 1 and parkingState ~= "full" then
              parkingState = "partial" -- At least partial, but keep checking for full
            end
          else
            hasWrongOverlap = parkingInfo.cornerCount == 4 or hasWrongOverlap
          end
        end
      end
      if p then p:add("vehicle parking check") end
    end
    if not hasCorrectOverlap and hasWrongOverlap then
      parkingState = "blocked"
    end
  end

  -- Store parking state
  decalData.parkingState = parkingState
  if p then p:add("update decal color") end
end

local function clearRouteMarker()
  if routeMarker then
    routeMarker:clearMarkers()
  end
  routeMarker = nil
  if routeZoneMarker then
    routeZoneMarker:clearMarkers()
  end
  routeZoneMarker = nil
  if routeParkingMarker then
    routeParkingMarker:clearMarkers()
  end
  routeParkingMarker = nil
end

function M.setRouteMarker(pos, zone, parkingSpot)
  if not pos then return false end

  clearRouteMarker()

  routeMarkerId = routeMarkerId + 1
  routeMarker = createAttentionMarker and createAttentionMarker(routeMarkerId)
  if not routeMarker then
    clearRouteMarker()
    return false
  end

  if not pos then
    clearRouteMarker()
    return false
  end

  local checkpointData = {
    pos = vec3(pos.x, pos.y, pos.z + ATTENTION_MARKER_HEIGHT_OFFSET),
    radius = ATTENTION_MARKER_SCALE
  }

  routeMarker:createMarkers()
  routeMarker:setToCheckpoint(checkpointData)
  routeMarker.baseScale = routeMarker.scale and vec3(routeMarker.scale) or nil

  routeMarker:setMode('default')
  routeMarker:show()

  if zone and createZoneAttentionMarker then
    routeMarkerId = routeMarkerId + 1
    routeZoneMarker = createZoneAttentionMarker(routeMarkerId)
    if routeZoneMarker then
      routeZoneMarker:createMarkers()
      routeZoneMarker:setToCheckpoint(zone)
      routeZoneMarker:setMode('default')
      routeZoneMarker:show()
    end
  end

  if parkingSpot and createParkingAttentionMarker then
    routeMarkerId = routeMarkerId + 1
    routeParkingMarker = createParkingAttentionMarker(routeMarkerId)
    if routeParkingMarker then
      routeParkingMarker:createMarkers()
      routeParkingMarker:setToCheckpoint(parkingSpot)
      routeParkingMarker:setMode('default')
      routeParkingMarker:show()
    end
  end

  return true
end

function M.hideRouteMarker()
  if routeMarker then
    routeMarker:hide()
  end
  if routeZoneMarker then
    routeZoneMarker:hide()
  end
  if routeParkingMarker then
    routeParkingMarker:hide()
  end
end

function M.setup(delivery)
  if not delivery then return end

  activeDelivery = delivery
  markers = {}
  parkingSpotDecals = {}
  parkingSpotVehicles = {} -- Clear cache

  -- Pre-compute parking spot vehicle associations
  if delivery.goals then
    for _, goal in ipairs(delivery.goals) do
      if goal.type == "placement" and goal.targetAreaId then
        local vehicleIds = gameplay_freeformDelivery_utils.getVehicleIds(goal)
        if not parkingSpotVehicles[goal.targetAreaId] then
          parkingSpotVehicles[goal.targetAreaId] = {}
        end
        for _, vid in ipairs(vehicleIds) do
          parkingSpotVehicles[goal.targetAreaId][vid] = true
        end
      end
    end
  end

  -- Create markers for each target area
  for _, targetArea in ipairs(delivery.targetAreas or {}) do
    local siteObj = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, targetArea.type, targetArea.siteId)
    if siteObj then
      markers[targetArea.id] = {
        targetArea = targetArea,
        siteObj = siteObj,
        type = targetArea.type
      }

      -- Create decal data for parking spots
      if targetArea.type == "parkingSpot" then
        local decalFadeStart, decalFadeEnd = 50, 200
        parkingSpotDecals[targetArea.id] = {
          texture = 'art/shapes/interface/parkDecalStripes.png',
          position = siteObj.pos,
          forwardVec = siteObj.rot * vec3(0, 1, 0),
          parkingState = "none", -- Track parking status: "none", "partial", "full"
          scale = vec3(siteObj.scl.x, siteObj.scl.y, 1),
          fadeStart = decalFadeStart,
          fadeEnd = decalFadeEnd
        }
      end
    end
  end
end

function M.update(dtReal, dtSim, dtRaw, profiler)
  p = profiler -- Assign to module-level variable for local functions

  if not activeDelivery then return end

  if p then p:add("markers initialization") end

  -- Reset decal collection
  decalCount = 0
  table.clear(groundDecals)

  if p then p:add("reset decals") end

  -- Check if debug is enabled
  local debugConfig = gameplay_freeformDelivery_freeformDelivery.debug
  local debugEnabled = debugConfig.enabled

  if p then p:add("debug check") end

  -- Draw markers for each target area
  for areaId, marker in pairs(markers) do
    if p then p:add("marker loop: " .. areaId) end

    local allComplete = gameplay_freeformDelivery_goals.areAllGoalsInAreaComplete(areaId)

    if p then p:add("check goal completion: " .. areaId) end

    -- Draw marker based on type
    if marker.type == "location" then
      if debugEnabled and debugConfig.targetAreas and debugConfig.targetAreas.location then
        drawLocationMarker(marker.siteObj, allComplete)
      end
    elseif marker.type == "zone" then
      if debugEnabled and debugConfig.targetAreas and debugConfig.targetAreas.zone then
        drawZoneMarker(marker.siteObj, allComplete)
      end
    elseif marker.type == "parkingSpot" then
      -- Update decal color if needed (parking status may have changed)
      updateParkingSpotDecalColor(areaId)

      -- Draw debug visualization if enabled
      if debugEnabled and debugConfig.targetAreas and debugConfig.targetAreas.parkingSpot then
        drawParkingSpotDebug(marker.siteObj, allComplete)
      end
    end
    ::continue::
  end

  if p then p:add("marker loop complete") end

  -- Get player position for distance calculation
  local playerPos = gameplay_freeformDelivery_utils.getPlayerPosition()
  if not playerPos then
    -- Fallback to camera position
    if core_camera then
      playerPos = core_camera.getPosition()
    end
  end

  if p then p:add("get player position") end

  -- Collect parking spot decals (only if goal is active and within 300m)
  decalCount = 0
  for areaId, decalData in pairs(parkingSpotDecals) do
    -- Check if there's an active goal for this parking spot
    local hasActiveGoal = false
    local areaGoals = gameplay_freeformDelivery_goals.getGoalsByTargetArea(areaId)
    for _, goal in ipairs(areaGoals) do
      if gameplay_freeformDelivery_goals.isGoalActive(goal.id) then
        hasActiveGoal = true
        break
      end
    end

    if p then p:add("check active goal for: " .. areaId) end

    -- Only draw if goal is active
    if hasActiveGoal and playerPos then
      -- Calculate distance from player to parking spot
      local marker = markers[areaId]
      if marker and marker.siteObj then
        local distance = playerPos:distance(marker.siteObj.pos)

        if p then p:add("distance check: " .. distance) end

        -- Only draw if within 300m
        if distance <= 300 then
          -- Calculate transparency based on distance (lerp from 300m to 250m)
          local alpha = 1.0
          if distance > 250 then
            -- Lerp from 0.2 at 300m to 1.0 at 250m
            local t = (distance - 250) / 50.0  -- t goes from 0 (at 250m) to 1 (at 300m)
            alpha = 0.2 + (1.0 - 0.2) * (1.0 - t)  -- Inverse lerp: 1.0 at 250m, 0.2 at 300m
          end

          -- Get base color RGB based on parking status
          local colorRGB = unparkedColorRGB
          if decalData.parkingState == "full" then
            colorRGB = parkedColorRGB
          elseif decalData.parkingState == "partial" then
            colorRGB = partialParkedColorRGB
          elseif decalData.parkingState == "blocked" then
            colorRGB = blockedColorRGB
          end

          -- Create new ColorF with adjusted alpha
          local decalCopy = {
            texture = decalData.texture,
            position = decalData.position,
            forwardVec = decalData.forwardVec,
            color = ColorF(colorRGB.r, colorRGB.g, colorRGB.b, alpha),
            scale = decalData.scale,
            fadeStart = decalData.fadeStart,
            fadeEnd = decalData.fadeEnd
          }

          decalCount = decalCount + 1
          groundDecals[decalCount] = decalCopy

          if p then p:add("add decal with alpha: " .. alpha) end
        end
      end
    end
  end
  if p then p:add("collect decals: " .. decalCount) end

  -- Draw all ground decals together at the end
  if decalCount > 0 then
    Engine.Render.DynamicDecalMgr.addDecals(groundDecals, decalCount)
    if p then p:add("render decals: " .. decalCount) end
  end

  if routeMarker and routeMarker.update then
    routeMarker:update(dtReal, dtSim)
  end
  if routeZoneMarker and routeZoneMarker.update then
    routeZoneMarker:update(dtReal, dtSim)
  end
  if routeParkingMarker and routeParkingMarker.update then
    routeParkingMarker:update(dtReal, dtSim)
  end
end

function M.cleanup()
  markers = {}
  activeDelivery = nil
  parkingSpotDecals = {}
  parkingSpotVehicles = {}
  clearRouteMarker()
end

return M
