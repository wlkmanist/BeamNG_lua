-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function getPlayerVehicleObject()
  return getPlayerVehicle and getPlayerVehicle(0) or nil
end

local function tr(value)
  if type(value) ~= "string" or value == "" then return nil end
  return _tr and _tr(value) or value
end

local function getPlayerPosition()
  local veh = getPlayerVehicleObject()
  if veh then
    local ok, pos = pcall(function() return veh:getPosition() end)
    if ok and pos then return pos end
  end

  if core_camera and type(core_camera.getPosition) == "function" then
    local ok, pos = pcall(core_camera.getPosition)
    if ok and pos then return pos end
  end

  if core_camera and type(core_camera.getPositionXYZ) == "function" then
    local ok, x, y, z = pcall(core_camera.getPositionXYZ)
    if ok and x then return vec3(x, y, z) end
  end

  return nil
end

local function getLicensePlateText(veh)
  if not veh then return nil end

  if core_vehicles and type(core_vehicles.getVehicleLicenseText) == "function" then
    local ok, text = pcall(core_vehicles.getVehicleLicenseText, veh)
    if ok and type(text) == "string" and text ~= "" then
      return text
    end
  end

  local ok, text = pcall(function() return veh:getDynDataFieldbyName("licenseText", 0) end)
  if ok and type(text) == "string" and text ~= "" then
    return text
  end

  return nil
end

local function getCurrentLevelData()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not levelId or levelId == "" then
    return nil, nil
  end

  local title = core_levels and core_levels.getLevelTitle and core_levels.getLevelTitle(levelId) or nil
  if title and title ~= "" then
    return levelId, tr(title) or title
  end

  local levelInfo = core_levels and core_levels.getLevelByName and core_levels.getLevelByName(levelId) or nil
  if not levelInfo and core_levels and core_levels.getList then
    local wanted = string.lower(levelId)
    for _, lvl in ipairs(core_levels.getList() or {}) do
      if string.lower(tostring(lvl.levelName or "")) == wanted then
        levelInfo = lvl
        break
      end
    end
  end

  title = levelInfo and tr(levelInfo.title or levelInfo.name or levelInfo.levelName) or levelId
  return levelId, title or levelId
end

local function getLocationName(pos, fallback)
  if pos and gameplay_city and type(gameplay_city.getHighestPrioZone) == "function" then
    local location = gameplay_city.getHighestPrioZone(pos)
    if location and location.name then
      return tr(location.name) or tostring(location.name)
    end
  end

  return fallback
end

local function getNearestSpeedLimit(pos)
  if not pos or not map or type(map.findClosestRoad) ~= "function" or type(map.getMap) ~= "function" then
    return nil
  end

  local n1, n2, dist = map.findClosestRoad(pos, 120)
  local mapData = map.getMap()
  local edge = mapData and mapData.graph and n1 and n2 and (
    (mapData.graph[n1] and mapData.graph[n1][n2]) or
    (mapData.graph[n2] and mapData.graph[n2][n1])
  ) or nil

  local speedLimit = edge and tonumber(edge.speedLimit) or nil
  if not speedLimit or speedLimit <= 0 or speedLimit == math.huge or speedLimit > 200 then
    return nil, dist
  end

  return speedLimit, dist
end

local function getLevelTime()
  if not core_environment or type(core_environment.getTimeOfDay) ~= "function" then
    return nil
  end

  local ok, timeOfDay = pcall(core_environment.getTimeOfDay)
  if not ok or type(timeOfDay) ~= "table" then
    return nil
  end

  return {
    time = tonumber(timeOfDay.time),
    year = tonumber(timeOfDay.year),
    month = tonumber(timeOfDay.month),
    day = tonumber(timeOfDay.day),
  }
end

function M.getData()
  local veh = getPlayerVehicleObject()
  local pos = getPlayerPosition()
  local levelId, mapName = getCurrentLevelData()
  local locationName = getLocationName(pos, mapName)
  local speedLimit, roadDistance = getNearestSpeedLimit(pos)

  return {
    mapId = levelId or "",
    mapName = mapName or "",
    locationName = locationName or "",
    levelTime = getLevelTime() or {},
    licensePlate = getLicensePlateText(veh) or "",
    roadDistance = roadDistance,
    speedLimit = speedLimit,
    position = pos and {
      x = pos.x,
      y = pos.y,
      z = pos.z,
    } or nil,
  }
end

return M
