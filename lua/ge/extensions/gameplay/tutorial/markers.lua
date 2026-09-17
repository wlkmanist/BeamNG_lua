-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "gameplay_tutorial_markers"

local PARKING_TOLERANCE = 0.8
local STATIONARY_VELOCITY_MS = 0.1
local FACING_DOT_THRESHOLD = 0.7
local MARKER_HEIGHT_OFFSET = 2
local DEFAULT_MARKER_SCALE = 1.5
local STATIONARY_REQUIRED_SECONDS = 1.0
local MARKER_DISTANCE_SCALE_START_M = 30
local MARKER_DISTANCE_SCALE_END_M = 250
local MARKER_DISTANCE_SCALE_MAX_FACTOR = 3.5
local DIRECTION_MARKER_PARKING_Z_OFFSET = 1.75
local DIRECTION_MARKER_DEFAULT_SCALE = 2

local createMarker = require("scenario/raceMarkers/attention")
local createDirectionMarker = require("scenario/raceMarkers/directionMarker")
local markers = {}
local markers_index = 0
local parkingSpotDecals = {}
local parkingSpotVehicles = {}
local groundDecals = {}
local decalCount = 0
local defaultParkingSpotVehicleGetter = nil

function M.setDefaultParkingSpotVehicleGetter(getter)
  defaultParkingSpotVehicleGetter = getter
end

local function getNewMarkerId()
  markers_index = markers_index + 1
  return markers_index
end

function M.createMarker(pos, rot, scale)
  if not createMarker then
    log("E", logTag, "Failed to load attention marker")
    return nil
  end

  local markerId = getNewMarkerId()
  local marker = createMarker(markerId)

  if not marker then
    log("E", logTag, "Failed to create marker")
    return nil
  end

  marker:createMarkers()
  marker.pos = vec3(pos)
  marker.scale = scale and vec3(scale) or vec3(1, 1, 1)
  marker.baseScale = vec3(marker.scale)

  if rot then
    marker.rot = quat(rot)
  end

  if marker.left then
    marker.left:setPosition(vec3(0, 0, 1.75) + marker.pos)
    marker.left:setScale(marker.scale)
  end

  marker:setMode("default")
  marker:show()
  markers[markerId] = marker

  log("D", logTag, "Created marker " .. markerId .. " at position " .. tostring(pos))
  return markerId
end

function M.createMarkerAboveVehicle(vehicle, scale)
  if not vehicle or not createMarker then return nil end
  local pos = vehicle:getPosition()
  local markerPos = vec3(pos.x, pos.y, pos.z + MARKER_HEIGHT_OFFSET)
  return M.createMarker(markerPos, nil, scale or vec3(DEFAULT_MARKER_SCALE, DEFAULT_MARKER_SCALE, DEFAULT_MARKER_SCALE))
end

function M.createDirectionMarkerFromParkingSpot(parkingSpot, scale)
  if not parkingSpot or not parkingSpot.pos or not parkingSpot.rot then
    log("E", logTag, "Invalid parkingSpot for direction marker")
    return nil
  end
  if not createDirectionMarker then
    log("E", logTag, "Failed to load directionMarker")
    return nil
  end

  local markerId = getNewMarkerId()
  local marker = createDirectionMarker(markerId)
  if not marker then
    log("E", logTag, "Failed to create direction marker")
    return nil
  end

  marker:createMarkers()

  local markerPos = vec3(parkingSpot.pos)
  markerPos.z = markerPos.z + DIRECTION_MARKER_PARKING_Z_OFFSET
  local markerScale = scale and vec3(scale) or vec3(DIRECTION_MARKER_DEFAULT_SCALE, DIRECTION_MARKER_DEFAULT_SCALE, DIRECTION_MARKER_DEFAULT_SCALE)
  marker:setToCheckpoint({
    pos = markerPos,
    rot = parkingSpot.rot,
    radius = markerScale.x
  })
  marker.baseScale = vec3(marker.scale)
  marker:setMode("default")
  marker:show()

  markers[markerId] = marker
  log("D", logTag, "Created direction marker " .. markerId .. " from parking spot " .. tostring(parkingSpot.name))
  return markerId
end

function M.removeMarker(markerId)
  if not markerId or not markers[markerId] then
    log("W", logTag, "Marker " .. tostring(markerId) .. " not found")
    return false
  end

  local marker = markers[markerId]
  marker:clearMarkers()
  markers[markerId] = nil
  log("D", logTag, "Removed marker " .. markerId)
  return true
end

function M.clearAllMarkers()
  for _, marker in pairs(markers) do
    marker:clearMarkers()
  end
  markers = {}
  log("D", logTag, "Cleared all markers")
end

function M.addParkingSpotDecal(parkingSpot)
  if not parkingSpot then return end

  local decalFadeStart, decalFadeEnd = 50, 200
  parkingSpotDecals[parkingSpot.name or "unknown"] = {
    texture = "art/shapes/interface/parkDecalStripes.png",
    position = parkingSpot.pos,
    forwardVec = parkingSpot.rot * vec3(0, 1, 0),
    parkingState = "none",
    scale = vec3(parkingSpot.scl.x, parkingSpot.scl.y, 1),
    fadeStart = decalFadeStart,
    fadeEnd = decalFadeEnd,
    parkingSpot = parkingSpot
  }

  log("D", logTag, "Added parking spot decal: " .. (parkingSpot.name or "unknown"))
end

function M.removeParkingSpotDecal(parkingSpotName)
  parkingSpotDecals[parkingSpotName] = nil
  parkingSpotVehicles[parkingSpotName] = nil
  log("D", logTag, "Removed parking spot decal: " .. tostring(parkingSpotName))
end

function M.setParkingSpotVehicle(parkingSpotName, vehicle)
  parkingSpotVehicles[parkingSpotName] = vehicle
end

function M.checkVehicleInParkingSpot(vehicle, parkingSpot)
  if not vehicle or not parkingSpot then
    return false, false, false
  end

  local vehId = vehicle:getID()
  if not vehId then return false, false, false end

  local vehicleData = map.objects[vehId]
  if not vehicleData then return false, false, false end

  local velocity = vehicleData.vel:length()
  local isStationary = velocity < STATIONARY_VELOCITY_MS
  local isParked = parkingSpot:checkParking(vehId, PARKING_TOLERANCE)

  local isFacingCorrect = false
  if isParked then
    local vehicleForward = vehicleData.dirVec
    local spotForward = parkingSpot.rot * vec3(0, 1, 0)
    local dot = vehicleForward:dot(spotForward)
    isFacingCorrect = dot >= FACING_DOT_THRESHOLD
  end

  return isParked, isFacingCorrect, isStationary
end

function M.checkParkGoalWithStationaryTime(vehicle, parkingSpot, dtReal, requiredSeconds, state)
  if not vehicle or not parkingSpot then return false end
  requiredSeconds = requiredSeconds or STATIONARY_REQUIRED_SECONDS
  state = state or {}
  if state.stationaryTimer == nil then state.stationaryTimer = 0 end
  if state.wasStationary == nil then state.wasStationary = false end
  local isParked, isFacingCorrect, isStationary = M.checkVehicleInParkingSpot(vehicle, parkingSpot)
  if isParked and isFacingCorrect and isStationary then
    if not state.wasStationary then
      state.stationaryTimer = 0
      state.wasStationary = true
    end
    state.stationaryTimer = state.stationaryTimer + dtReal
    if state.stationaryTimer >= requiredSeconds then
      return true
    end
  else
    state.stationaryTimer = 0
    state.wasStationary = false
  end
  return false
end

local function updateParkingSpotDecalColor(parkingSpotName, vehicle)
  local decalData = parkingSpotDecals[parkingSpotName]
  if not decalData then return end

  local parkingState = "none"
  if vehicle and decalData.parkingSpot then
    local isParked, isFacingCorrect = M.checkVehicleInParkingSpot(vehicle, decalData.parkingSpot)
    if isParked then
      parkingState = isFacingCorrect and "full" or "partial"
    end
  end

  decalData.parkingState = parkingState
end

function M.update(dt, dtSim)
  local playerPos = nil
  if core_camera then
    playerPos = core_camera.getPosition()
  end

  for _, marker in pairs(markers) do
    if marker.baseScale then
      if playerPos and marker.pos then
        local distance = playerPos:distance(marker.pos)
        local t = clamp((distance - MARKER_DISTANCE_SCALE_START_M) / (MARKER_DISTANCE_SCALE_END_M - MARKER_DISTANCE_SCALE_START_M), 0, 1)
        local scaleFactor = 1 + t * (MARKER_DISTANCE_SCALE_MAX_FACTOR - 1)
        marker.scale = vec3(
          marker.baseScale.x * scaleFactor,
          marker.baseScale.y * scaleFactor,
          marker.baseScale.z * scaleFactor
        )
      else
        marker.scale = vec3(marker.baseScale)
      end
    end
    if marker.update then
      marker:update(dt, dtSim)
    end
  end

  decalCount = 0
  table.clear(groundDecals)
  for parkingSpotName, decalData in pairs(parkingSpotDecals) do
    if playerPos then
      local distance = playerPos:distance(decalData.position)
      if distance <= 300 then
        local alpha = 1.0
        if distance > 250 then
          local t = (distance - 250) / 50.0
          alpha = 0.2 + (1.0 - 0.2) * (1.0 - t)
        end

        local vehicle = parkingSpotVehicles[parkingSpotName]
        if not vehicle and defaultParkingSpotVehicleGetter then
          vehicle = defaultParkingSpotVehicleGetter()
        end
        if vehicle then
          updateParkingSpotDecalColor(parkingSpotName, vehicle)
        end

        local colorRGB = { r = 2.5, g = 2.5, b = 2.5 }
        if decalData.parkingState == "full" then
          colorRGB = { r = 0, g = 2.5, b = 0 }
        elseif decalData.parkingState == "partial" then
          colorRGB = { r = 2.5, g = 2.5, b = 0 }
        end

        decalCount = decalCount + 1
        groundDecals[decalCount] = {
          texture = decalData.texture,
          position = decalData.position,
          forwardVec = decalData.forwardVec,
          color = ColorF(colorRGB.r, colorRGB.g, colorRGB.b, alpha),
          scale = decalData.scale,
          fadeStart = decalData.fadeStart,
          fadeEnd = decalData.fadeEnd
        }
      end
    end
  end

  if decalCount > 0 then
    Engine.Render.DynamicDecalMgr.addDecals(groundDecals, decalCount)
  end
end

function M.cleanup()
  M.clearAllMarkers()
  parkingSpotDecals = {}
  parkingSpotVehicles = {}
  groundDecals = {}
  decalCount = 0
end

return M
