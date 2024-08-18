-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This module manages general locations and identifications of facilities on a map. It uses map info and sites data to return parking spots and other objects.

-- Feel free to move this module in the future, if needed.

local M = {}
local missingPreview = "/ui/modules/gameContext/noPreview.jpg"

local facilitiesByLevel = {}

local facilityTypeToListName = {
  garage = "garages",
  gasStation = "gasStations",
  dealership = "dealerships",
  computer = "computers",
  privateSeller = "privateSellers",
  deliveryProvider = "deliveryProviders"
}

local facilityTypeToUiLabelSingular = {
  garage = "Garage",
  gasStation = "Gas Station",
  dealership = "Dealership",
  computer = "Computer",
  privateSeller = "Private Seller",
  deliveryProvider = "Delivery Provider"
}


-- helper function for checking if files exist
local function fileExistsDefault(path, fallbackPath)
  if path == nil then return fallbackPath end
  if type(path) ~= "table" then path = {path} end
  for _, p in ipairs(path) do
    if FS:fileExists(p) then return p end
  end
  return fallbackPath
end


-- parses and sanitizes a singular facility entry and adds it to the facilitiesTypeList.
local function parseFacility(f, type, facilitiesTypeList, levelDir, fileDir, fileName, index)
  -- sanitize
  f.id = f.id or (string.format("%s%s-%s-%d",fileDir, fileName, type, index))
  f.type = type
  f.preview = f.preview or 'defaultFacility.jpg'
  f.preview = fileExistsDefault({fileDir..f.preview, levelDir.. f.preview}, missingPreview)
  f.sitesFile = f.sitesFile or "facilities.sites.json"
  f.sitesFile = fileExistsDefault({fileDir..f.sitesFile, levelDir.. f.sitesFile}, levelDir.."facilities.sites.json")
  f.zoneNames = f.zoneNames or {}
  f.parkingSpotNames = f.parkingSpotNames or {}
  table.insert(facilitiesTypeList, f)
end

-- this funcion can parse *.facilities.json, but also the info.json in a level folder.
local function parseFacilitiyFile(file, facilities, levelDir)
  if not FS:fileExists(file) then return end
  local fileDir, fn, _ = path.split(file, true)
  local data = jsonReadFile(file)
  for type, listKey in pairs(facilityTypeToListName) do
    for i, f in ipairs(data[listKey] or {}) do
      parseFacility(f, type, facilities[listKey], levelDir, fileDir, fn, i)
    end
  end
end

local function getFacilities(levelName)
  if not facilitiesByLevel[levelName] then

    -- init facility table
    facilitiesByLevel[levelName] = {}
    for _, listKey in pairs(facilityTypeToListName) do facilitiesByLevel[levelName][listKey] = {} end

    -- parse info.json of the level
    local levelInfo = core_levels.getLevelByName(levelName)
    if levelInfo then
      parseFacilitiyFile(levelInfo.dir.."/info.json", facilitiesByLevel[levelName], levelInfo.misFilePath)

      -- parse any other facility files inside the levels /facilities folder
      for _,file in ipairs(FS:findFiles(levelInfo.dir.."/facilities/", '*.facilities.json', -1, false, true)) do
        parseFacilitiyFile(file, facilitiesByLevel[levelName], levelInfo.misFilePath)
      end
    end
    log("D","",string.format("Loaded facilities on level %s (%d garages, %d gasStations, %d dealerships)",levelName, #facilitiesByLevel[levelName].garages, #facilitiesByLevel[levelName].gasStations, #facilitiesByLevel[levelName].dealerships))
  end
  return facilitiesByLevel[levelName]
end

-- returns a single facility element.
local function getFacility(type, id)
  local levelName = getCurrentLevelIdentifier()
  if not levelName or levelName == '' then log("E","","Tried to get facility without level!") return end

  local facilities = getFacilities(levelName)
  local listName = facilityTypeToListName[type] or "none"
  if listName == "none" then log("E","","Tried to get facility of type " .. dumps(type)..", which is not a valid type! ("..dumps(tableKeysSorted(facilityTypeToListName))) end

  for _, f in ipairs(facilities[listName]) do
    if f.id == id then
      return f
    end
  end
  log("E","","Could not find facility with id " .. dumps(id))
end

local function getFacilitiesByType(type, levelName)
  levelName = levelName or getCurrentLevelIdentifier()
  if not levelName or levelName == '' then log("E","","Tried to get facility without level!") return end

  local facilities = getFacilities(levelName)
  local listName = facilityTypeToListName[type] or "none"
  if listName == "none" then log("E","","Tried to get facilities of type " .. dumps(type)..", which is not a valid type! ("..dumps(tableKeysSorted(facilityTypeToListName))) end

  return facilities[listName]
end



local function getGarage(id) return getFacility("garage", id) end
local function getGasStation(id) return getFacility("gasStation", id) end
local function getDealership(id) return getFacility("dealership", id) end


local function getAverageDoorPositionForFacility(facility)
  local center, count = vec3(0,0,0), 0

  for _, pair in ipairs(facility.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facility " .. facility.id)
    end
  end

  if count > 0 then
    return center / count
  else
    log("E","","Dealership has no doors and thus no position! " .. facility.id)
    return vec3()
  end
end


local function getParkingSpotsForFacility(facility)
  if not facility.sitesFile then log("E","","Facility has not sites file: " .. dumpsz(facility,1)) return end
  local sites = gameplay_sites_sitesManager.loadSites(facility.sitesFile)
  local spots = {}
  if sites then
    for _, parkingSpotName in ipairs(facility.parkingSpotNames) do
      local spot = sites.parkingSpots.byName[parkingSpotName]
      if spot and not spot.missing then
        table.insert(spots, spot)
      else
        log("W","","Missing Spot for facility" .. dumps(facility.id).."?: " .. dumps(parkingSpotName) .. " of " .. dumps(tableKeys(sites.parkingSpots.byName)))
      end
    end
  else
    log("W","","Could not find sites file for facility: " .. dumps(facility.sitesFile))
  end
  return spots
end



-- POI integration
local function getZonesForFacility(facility)
  if not facility.sitesFile then log("E","","Facility has not sites file: " .. dumpsz(facility,1)) return end
  local sites = gameplay_sites_sitesManager.loadSites(facility.sitesFile)
  local zones = {}
  if sites then
    for _, zoneName in ipairs(facility.zoneNames) do
      local zone = sites.zones.byName[zoneName]
      if zone and not zone.missing then
        table.insert(zones, zone)
      else
        log("W","","Missing Zone for facility" .. dumps(facility.id).."?: " .. dumps(zoneName) .. " of " .. dumps(tableKeys(sites.zones.byName)))
      end
    end
  else
    log("W","","Could not find sites file for facility: " .. dumps(facility.sitesFile))
  end
  return zones
end

local function getGaragePosRot(poi, veh)
  veh = veh or getPlayerVehicle(0)
  local garage = getGarage(poi.id) -- TODO: implement "default garage" property for level
  if not garage then return end
  local parkingSpots = getParkingSpotsForFacility(garage)
  local parkingSpot = gameplay_sites_sitesManager.getBestParkingSpotForVehicleFromList(veh:getID(), parkingSpots)
  if parkingSpot then
    return parkingSpot.pos, parkingSpot.rot
  end
  return nil, nil
end

local function teleportToGarage(garageId, veh, resetVeh)
  local pos, rot = getGaragePosRot({id = garageId}, veh)
  if pos and rot then
    spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, resetVeh)
    veh:resetBrokenFlexMesh()
    if core_groundMarkers.currentlyHasTarget() then
      freeroam_bigMapMode.setNavFocus(core_groundMarkers.endWP[1])
    end
    core_camera.resetCamera(0)
  end
  extensions.hook("onTeleportedToGarage",garageId, veh)
end
M.teleportToGarage = teleportToGarage

local function extractZoneData(facility)
  local success = false
  local zones = {}
  local pos, radius = vec3(), 5
  local zones = getZonesForFacility(facility)
  if zones then
    local aabb = {
      xMin = math.huge, xMax = -math.huge,
      yMin = math.huge, yMax = -math.huge,
      zMin = math.huge, zMax = -math.huge,
      invalid = true}
    for _, zone in ipairs(zones) do
      for i, v in ipairs(zone.vertices) do
        aabb.xMin = math.min(aabb.xMin, v.pos.x)
        aabb.xMax = math.max(aabb.xMax, v.pos.x)
        aabb.yMin = math.min(aabb.yMin, v.pos.y)
        aabb.yMax = math.max(aabb.yMax, v.pos.y)
        aabb.zMin = math.min(aabb.zMin, v.pos.z)
        aabb.zMax = math.max(aabb.zMax, v.pos.z)
        aabb.invalid = false
      end
    end
    if not aabb.invalid then
      pos = vec3((aabb.xMin + aabb.xMax)/2, (aabb.yMin + aabb.yMax)/2, (aabb.zMin + aabb.zMax)/2)
      pos.z = core_terrain.getTerrainHeight(pos) or pos.z
      radius = math.sqrt(((aabb.xMax - aabb.xMin)/2) * ((aabb.xMax - aabb.xMin)/2) + ((aabb.yMax - aabb.yMin)/2) * ((aabb.yMax - aabb.yMin)/2))
      success =true
    else
      log("E","","AABB is invalid: " .. dumps(aabb))
    end
  end
  return success, pos, radius, zones
end

local facilityPoiDefaults = {
  garage = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = true,
    quickTravelPosRotFunction = getGaragePosRot,
    clusterType = 'zoneMarker',
  },
  gasStation = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'gasStationMarker',
  },
  dealership = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  computer = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
  deliveryProvider = {
    clusterInBigMap = true,
    clusterInPlayMode = false,
    interactableInPlayMode = true,
    quickTravelAvailable = false,
    clusterType = 'walkingMarker',
  },
}

M.zoneMarkerFormatFacility = function(f, elements, bigMapIcon)
  local success, pos, radius, zones = extractZoneData(f)
  if success then
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},

      markerInfo = {
        zoneMarker = {zones = zones, pos = pos, radius = radius},
        bigmapMarker = { pos = pos, icon = f.icon,  name = f.name, description = f.description, thumbnail = f.preview, previews = {f.preview}, quickTravelPosRotFunction = getGaragePosRot}
      },
    }
    table.insert(elements, e)
  else
    log("E","","Could not load facility zone data! " .. dumps(data.id))
  end
end


M.walkingMarkerFormatFacility = function(f, elements)

  local center, count = vec3(0,0,0), 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      center = center + obj:getPosition()
      count = count + 1
    else
      log("W","","Couldnt not find object " .. pair[1] .. " in scenetree for facilitiy " .. f.id)
    end
  end
  center = center / count

  local maxDistSqr = 0
  for _, pair in ipairs(f.doors or {}) do
    local obj = scenetree.findObject(pair[1])
    if obj then
      maxDistSqr = math.max(maxDistSqr, (obj:getPosition()-center):squaredLength() + square(pair[3] or 6))
    end
  end

  if count > 0 then
    local e = {
      id = f.id,
      data = {type = f.type, facility = f},
      markerInfo = {
        walkingMarker = { doors = deepcopy(f.doors), iconOffsetHeight = f.iconOffsetHeight, iconLift = f.iconLift, icon = f.playModeIconName or f.icon, pos = center, radius = math.sqrt(maxDistSqr), screens = f.screens},
        bigmapMarker = { pos = center, icon = f.icon or f.playModeIconName, name = f.name, description = f.description, thumbnail = f.preview, previews = {f.preview}}
      }
    }
    table.insert(elements, e)
  else
    log("E","","No objects found for facilitiy " .. f.id .. " ! " .. dumps(f.doors))
  end
end


local function formatFacilityToRawPoi(f, elements)
  if not f then return end
  local e = M[facilityPoiDefaults[f.type].clusterType.."FormatFacility"](f, elements)
  if e then
    -- put in the default values for this facility, if the facility itself did not define it
    for key, value in pairs(facilityPoiDefaults[f.type]) do
      e[key] = f[key]
      if e[key] == nil then
        e[key] = value
      end
    end
    table.insert(elements, e)
  end
end
M.formatFacilityToRawPoi = formatFacilityToRawPoi

local function onGetRawPoiListForLevel(levelIdentifier, elements)
  local facilities = getFacilities(levelIdentifier)
  if career_career.isActive() then
    for i, dealership in ipairs(facilities.dealerships or {}) do
      M.walkingMarkerFormatFacility(dealership, elements)
    end
    for i, computer in ipairs(facilities.computers or {}) do
      M.walkingMarkerFormatFacility(computer, elements)
    end
    --for i, garage in ipairs(facilities.garages or {}) do
      --M.zoneMarkerFormatFacility(garage, elements, "poi_garage_2")
    --end
  end
end
M.onGetRawPoiListForLevel = onGetRawPoiListForLevel



local function onActivityAcceptGatherData(elemData, activityData)
  for _, elem in ipairs(elemData) do
    if elem.facility then
      local data = {
        icon = elem.facility.playModeIconName or elem.facility.icon,
        heading = elem.facility.name,
        preheadings = {facilityTypeToUiLabelSingular[elem.facility.type]},
        sorting = {
          type = elem.type,
          id = elem.id
        }
      }
      if elem.type == "garage" then
        data.buttonLabel = "ui.career.openGarageTitle"
        data.buttonFun = function() gameplay_garageMode.start(true) end
        table.insert(activityData, data)
      end
      -- gasStations are handled in gasStations.lua now
      if elem.type == "dealership" then
        data.buttonLabel = "Open Dealership"
        data.buttonFun = function() career_modules_vehicleShopping.openShop(elem.facility.id) end
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        table.insert(activityData, data)
      end
      if elem.type == "computer" then
        data.props = {}
        for _, prop in ipairs(elem.facility.activityAcceptProps or {}) do
          table.insert(data.props,{
            icon = prop.icon or "checkmark",
            keyLabel = prop.keyLabel,
            valueLabel = prop.valueLabel,
          })
        end
        data.buttonLabel = "Use Computer"
        data.buttonFun = function()
          if career_career.isActive() then
            career_modules_computer.openMenu(elem.facility)
          end
        end
        table.insert(activityData, data)
      end
    end
  end
end
M.onActivityAcceptGatherData = onActivityAcceptGatherData

M.getFacilities = getFacilities
M.getFacility = getFacility
M.getFacilitiesByType = getFacilitiesByType
M.getGarage = getGarage
M.getGasStation = getGasStation
M.getDealership = getDealership
M.getAverageDoorPositionForFacility = getAverageDoorPositionForFacility
M.getParkingSpotsForFacility = getParkingSpotsForFacility
M.getZonesForFacility = getZonesForFacility
M.getGaragePosRot = getGaragePosRot

return M
