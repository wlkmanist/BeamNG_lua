-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Vehicle data cache
local vehicleCache = {} -- vehId -> {pos, valid}

-- Initialize cache entry for a vehicle
local function initVehicleCache(vehId)
  if not vehicleCache[vehId] then
    vehicleCache[vehId] = {
      pos = vec3(),
      valid = false
    }
  end
  return vehicleCache[vehId]
end

-- Update vehicle cache for a specific vehicle
function M.updateVehicleCache(veh)
  if not veh then return end

  local vehId = veh:getID()
  if not vehId then return end

  local cache = initVehicleCache(vehId)

  -- Update position using set API (no allocation)
  cache.pos:set(veh:getPositionXYZ())

  cache.valid = true
end

-- Update cache for all vehicles in a list
function M.updateVehicleCacheList(vehicles)
  if not vehicles then return end

  for _, veh in ipairs(vehicles) do
    M.updateVehicleCache(veh)
  end
end

-- Get cached vehicle position (returns cached vec3, don't modify!)
function M.getCachedVehiclePosition(veh)
  if not veh then return nil end

  local vehId = veh:getID()
  if not vehId then return nil end

  local cache = vehicleCache[vehId]
  if not cache or not cache.valid then
    -- Cache miss, update it
    M.updateVehicleCache(veh)
    cache = vehicleCache[vehId]
  end

  return cache and cache.pos or nil
end

-- Clear vehicle cache
function M.clearVehicleCache()
  vehicleCache = {}
end

-- Format time in seconds to HH:MM:SS or MM:SS
function M.formatTime(seconds)
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local secs = math.floor(seconds % 60)

  if hours > 0 then
    return string.format("%d:%02d:%02d", hours, minutes, secs)
  else
    return string.format("%d:%02d", minutes, secs)
  end
end

-- Find site object by type and ID
function M.findSiteObject(sites, siteType, siteId)
  if not sites then return nil end

  if siteType == "location" then
    return sites.locations.byName[siteId] or sites.locations.objects[tonumber(siteId)]
  elseif siteType == "zone" then
    return sites.zones.byName[siteId] or sites.zones.objects[tonumber(siteId)]
  elseif siteType == "parkingSpot" then
    return sites.parkingSpots.byName[siteId] or sites.parkingSpots.objects[tonumber(siteId)]
  end

  return nil
end

-- Get vehicle IDs from goal (normalize vehicleId to vehicleIds array)
function M.getVehicleIds(goal)
  return goal.vehicleIds or (goal.vehicleId and {goal.vehicleId} or {})
end

-- Check if vehicle is in parking spot (uses parkingSpot:checkParking)
function M.checkVehicleInParkingSpot(veh, parkingSpot)
  if not veh or not parkingSpot then return false end

  local vehId = veh:getID()
  if not vehId then return false end

  -- Use the parking spot's checkParking function
  local valid = parkingSpot:checkParking(vehId, 0.8)

  return valid
end

-- Check if vehicle is in area (unified function for location, zone, parkingSpot)
function M.checkVehicleInArea(veh, siteObj, areaType)
  if not veh or not siteObj then return false end

  if areaType == "location" then
    local vehPos = M.getCachedVehiclePosition(veh)
    if not vehPos then return false end
    local distance = vehPos:distance(siteObj.pos)
    return distance <= siteObj.radius
  elseif areaType == "zone" then
    return siteObj:containsVehicle(veh, false)
  elseif areaType == "parkingSpot" then
    return M.checkVehicleInParkingSpot(veh, siteObj)
  end

  return false
end

-- Resolve relative path to absolute path based on base path
function M.resolvePath(basePath, relativePath)
  if not relativePath then return nil end

  -- If already absolute, return as is
  if string.sub(relativePath, 1, 1) == '/' then
    return relativePath
  end

  -- Get directory of base file
  local dir, _, _ = path.split(basePath)
  if not dir then return nil end

  -- Combine paths (ensure proper separator)
  local fullPath = dir .. relativePath
  -- Normalize path separators
  fullPath = fullPath:gsub('//', '/')
  return fullPath
end

-- Find target area by ID in delivery data
function M.findTargetArea(delivery, areaId)
  if not delivery or not delivery.targetAreas then return nil end
  for _, area in ipairs(delivery.targetAreas) do
    if area.id == areaId then
      return area
    end
  end
  return nil
end

-- Find vehicle by ID in delivery data
function M.findVehicle(delivery, vehicleId)
  if not delivery or not delivery.vehicles then return nil end
  for _, vehicle in ipairs(delivery.vehicles) do
    if vehicle.id == vehicleId then
      return vehicle
    end
  end
  return nil
end

-- Get vehicle object by delivery vehicle ID (returns upcasted vehicle)
function M.getVehicleObjectByDeliveryId(vehicleId)
  local vehId = gameplay_freeformDelivery_setup.getVehicleId(vehicleId)
  if not vehId then return nil end

  local veh = getObjectByID(vehId)
  if not veh then return nil end

  return Sim.upcast(veh)
end

-- Get vehicle position by delivery vehicle ID (uses cached position)
function M.getVehiclePositionByDeliveryId(vehicleId)
  local veh = M.getVehicleObjectByDeliveryId(vehicleId)
  if not veh then return nil end
  return M.getCachedVehiclePosition(veh)
end

-- Get player vehicle (upcasted)
function M.getPlayerVehicle()
  local veh = getPlayerVehicle(0)
  if not veh then return nil end
  return Sim.upcast(veh)
end

-- Get player position (handles both vehicle and walking)
function M.getPlayerPosition()
  local veh = M.getPlayerVehicle()
  if veh then
    return M.getCachedVehiclePosition(veh)
  end

  -- Check if player is walking
  if gameplay_walk and gameplay_walk.isWalking() then
    return gameplay_walk.getPosition()
  end

  return nil
end

-- Get parking information for a vehicle in a parking spot (uses parkingSpot:checkParking only)
function M.getParkingInfo(veh, parkingSpot)
  if not veh or not parkingSpot then return nil end

  local vehId = veh:getID()
  if not vehId then return nil end

  -- Use the parking spot's checkParking function
  local valid, corners = parkingSpot:checkParking(vehId, 0.8)

  -- Count corners in spot
  local cornerCount = 0
  if corners then
    for _, v in ipairs(corners) do
      if v then
        cornerCount = cornerCount + 1
      end
    end
  end

  -- Only return info if vehicle has at least some corners in the spot
  if cornerCount == 0 then return nil end

  return {
    valid = valid,
    cornerCount = cornerCount,
    corners = corners,
    spotSize = { x = parkingSpot.scl.x, y = parkingSpot.scl.y, z = parkingSpot.scl.z }
  }
end

return M
