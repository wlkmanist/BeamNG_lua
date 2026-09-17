-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'core_vehicleActivePooling'}

local logTag = "parking"

local targetRadius = 50 -- radius of dynamic target point
local searchRadius = 200 -- radius of search point to query for parking spots
local searchPointDist = 200 -- distance ahead of focus point to set search point
local keepActiveRadius = 50 -- parked cars stay active within this radius
local keepClearRadius = 120 -- parked cars avoid activating within this radius
local parkedVehIds, parkedVehData = {}, {}
local trackedVehData = {} -- parking tracking, can be used with the player vehicle
local currParkingSpots = {} -- cached parking spots, updated periodically
local queuedIndex = 1

-- common functions --
local min = math.min
local max = math.max
local random = math.random

--------
local sites, vehPool, vars
local aheadPos, lastPos, debugPos, tempVec = vec3(), vec3(), vec3(), vec3()
local focus
local active = false
local resetFlag = false
local nearSpawnMode = false
local parkingSpotsAmount = 0
local respawnDelay = 0

M.debugLevel = 0

local function loadSites() -- loads sites data containing parking spots
  -- by default, the file "city.sites.json" in the root folder of the current level will be used
  if not gameplay_city then return end
  gameplay_city.loadSites()
  sites = gameplay_city.getSites()
  parkingSpotsAmount = sites and #sites.parkingSpots.sorted or 0
end

local function setSites(data) -- sets sites data, can override the default sites data
  if type(data) == "string" then
    if FS:fileExists(data) then
      sites = gameplay_sites_sitesManager.loadSites(data)
    end
  elseif type(data) == "table" and data.parkingSpots then -- assuming that given data is valid sites data
    sites = data
  else
    sites = nil
  end
  parkingSpotsAmount = sites and #sites.parkingSpots.sorted or 0
end

local function setState(val) -- activates or deactivates the parking system
  active = val and true or false
  if active then
    if not sites then
      loadSites()
    end
    focus = gameplay_traffic.getFocus()
    aheadPos:set(focus.pos)
    lastPos:set(aheadPos)
  end
end

local function getState()
  return active
end

local function getParkingSpots() -- returns a table of all current parking spots
  if not sites then
    loadSites()
  end
  return sites and sites.parkingSpots
end

local function setMapmgrTracking(vehId, state) -- enables or disables mapmgr tracking for a parked vehicle (details in comments below)
  if not vehId or not parkedVehData[vehId] or not parkedVehData[vehId].parkingSpotId then return end

  local parkingSpot = sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId]
  if not parkingSpot or parkingSpot.missing then return end

  if state == nil then state = parkingSpot.customFields.tags.street end -- by default, enable tracking if parking spot street tag is present
  if state then -- enables tracking, so that active traffic can dodge this vehicle
    getObjectByID(vehId):queueLuaCommand("mapmgr.enableTracking()")
  else -- disables tracking, to optimize performance
    getObjectByID(vehId):queueLuaCommand("mapmgr.disableTracking()")
  end
end

local function moveToParkingSpot(vehId, parkingSpot, lowPrecision) -- assigns a parked vehicle to a parking spot
  local obj = getObjectByID(vehId)
  local width, length = obj.initialNodePosBB:getExtents().x - 0.1, obj.initialNodePosBB:getExtents().y
  local backwards, offsetPos, offsetRot

  if parkingSpot.customFields.tags.forwards then
    backwards = false
  elseif parkingSpot.customFields.tags.backwards then
    backwards = true
  else
    backwards = random() > 0.75 + vars.neatness * 0.25 -- backwards direction is less common by default
  end

  if not parkingSpot.customFields.tags.perfect then -- randomize position and rotation slightly
    local offsetVal = 1 - square(vars.neatness)
    local xGap, yGap = max(0, parkingSpot.scl.x - width), max(0, parkingSpot.scl.y - length)
    local xRandom, yRandom = randomGauss3() / 3 - 0.5, clamp(randomGauss3() / 3 - (backwards and 0.75 or 0.25), -0.5, 0.5)
    offsetPos = vec3(xRandom * offsetVal * xGap, yRandom * offsetVal * yGap, 0)
    offsetRot = quatFromEuler(0, 0, (randomGauss3() / 3 - 0.5) * offsetVal * 0.25)
  end

  local options = {
    skipVehicleIntersectionCheck = true
  }
  parkingSpot:moveResetVehicleTo(vehId, lowPrecision, backwards, offsetPos, offsetRot, true, false, nil, options)
  if M.debugLevel > 0 then
    log("I", logTag, string.format("Teleported vehId %d to parking spot %d", vehId, parkingSpot.id))
  end

  getObjectByID(vehId):queueLuaCommand("electrics.setIgnitionLevel(0)")

  if parkedVehData[vehId] then
    if parkedVehData[vehId].parkingSpotId then
      sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
    end

    if parkedVehData[vehId].randomPaint then
      core_vehicle_manager.setVehiclePaintsNames(vehId, core_vehiclePaints.getRandomPaintsByVehicle(vehId))
    end

    parkingSpot.vehicle = vehId -- parking spot contains this vehicle
    parkedVehData[vehId].parkingSpotId = parkingSpot.id -- vehicle is assigned to this parking spot
    parkedVehData[vehId].activeRadius = 0
    parkedVehData[vehId]._teleport = nil

    setMapmgrTracking(vehId)
  end
end

local defaultParkingSpotSize = vec3(2.5, 6, 3)
local function checkDimensions(vehId) -- checks if the vehicle would fit in a standard sized parking spot
  local obj = getObjectByID(vehId)
  if not obj then return false end

  local extents = obj.initialNodePosBB:getExtents()
  return  extents.x <= defaultParkingSpotSize.x and
          extents.y <= defaultParkingSpotSize.y and
          extents.z <= defaultParkingSpotSize.z
end

local function checkParkingSpot(vehId, parkingSpot, minDist, maxDist) -- checks if a parking spot is ready to use for a parked vehicle
  local obj = getObjectByID(vehId or 0)
  minDist = minDist or 0
  maxDist = maxDist or 1e12

  if not parkingSpot or parkingSpot.missing then return false end

  local dist = parkingSpot.pos:squaredDistance(focus.pos)
  if dist < square(minDist) or dist > square(maxDist) then
    return false
  end

  if parkingSpot.vehicle or parkingSpot.customFields.tags.banned or parkingSpot:hasAnyVehicles() or not obj then
    return false
  end

  for _, veh in ipairs(getAllVehicles()) do
    if veh:getActive() then
      local trafficClearRadius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) -- custom radius that prevents parked cars from respawning too near
      if trafficClearRadius then
        tempVec:set(be:getObjectPositionXYZ(veh:getId()))
        if parkingSpot.pos:squaredDistance(tempVec) <= square(trafficClearRadius) then
          return false
        end
      end
    end
  end

  if parkingSpot:vehicleFits(vehId) then
    -- ensure that the parking spot is not too oversized for the vehicle
    local size = obj.initialNodePosBB:getExtents()
    local psSize = parkingSpot.scl
    if size.x / psSize.x < 0.5 or size.y / psSize.y < 0.5 then
      return false
    end
  else
    return false
  end

  return true
end

local function findParkingSpots(pos, minRadius, maxRadius) -- finds and returns a sorted array of parking spot objects and distances
  if not sites then return {} end
  pos = pos or core_camera.getPosition()
  minRadius = minRadius or 0
  maxRadius = maxRadius or searchRadius

  local psList = sites:getRadialParkingSpots(pos, minRadius, maxRadius)
  -- each entry in psList contains: v.ps (parking spot object), v.squaredDistance (squared distance to parking spot)

  if M.debugLevel > 0 then
    log("I", logTag, string.format("Found and validated %d parking spots in area", #psList))
  end
  table.sort(psList, function(a, b) return a.squaredDistance < b.squaredDistance end) -- sorts from closest to farthest

  return psList
end

local function updateParkingSpots(psList, pos) -- updates the distances of the parking spots in the cached list
  if not psList or type(psList[1]) ~= "table" then return psList end
  for i, v in ipairs(psList) do
    psList[i].squaredDistance = pos:squaredDistance(v.ps.pos)
  end

  table.sort(psList, function(a, b) return a.squaredDistance < b.squaredDistance end) -- sorts from closest to farthest
  return psList
end

local emptyFilters = {}
local defaultFilters = {useProbability = true}
local function filterParkingSpots(psList, filters) -- filter the sorted list of parking spots (as returned by findParkingSpots)
  if not psList or type(psList[1]) ~= "table" then return psList end
  filters = filters or defaultFilters

  local psCount = #psList
  local timeDay = 0

  if filters.useProbability then
    local timeObj = core_environment.getTimeOfDay()
    if timeObj and timeObj.time then
      timeDay = timeObj.time
    end
  end

  for i = psCount, 1, -1 do
    local ps = psList[i].ps
    local remove = false

    if ps.customFields.tags.banned then
      remove = true
    end

    if filters.standardSize then
      if ps.scl.x > 3 or ps.scl.y > 8 then -- arbitrary width and length limits for standard parking spots
        remove = true
      end
    end

    if filters.checkVehicles then -- strict but slow check for other vehicles occupying this spot
      if ps:hasAnyVehicles() then
        remove = true
      end
    end

    if filters.useProbability then
      local prob = ps.customFields:has("probability") and ps.customFields:get("probability") or vars.baseProbability
      if type(prob) ~= "number" then prob = 1 end
      prob = prob * vars.baseProbability

      local dayValue = 0.25 + math.abs(timeDay - 0.5) * 1.5 -- max 1 for midday, min 0.25 for midnight
      local timeDayCoef = dayValue

      if ps.customFields.tags.nightTime then
        local nightValue = 1 - math.abs(timeDay - 0.5) * 1.5 -- opposite of dayValue
        if ps.customFields.tags.dayTime then
          timeDayCoef = max(timeDayCoef, nightValue)
        else
          timeDayCoef = nightValue
        end
      end
      prob = prob * timeDayCoef

      if prob <= random() then
        remove = true
      end
    end

    if remove then
      table.remove(psList, i)
    end
  end

  if M.debugLevel > 0 then
    log("I", logTag, string.format("Filtered and accepted %d / %d parking spots", #psList, psCount))
  end

  return psList
end

local function getRandomParkingSpots(originPos, minDist, maxDist, targetCount, filters) -- returns a list of random parking spots, with a bias for origin position
  if not sites then return {} end
  originPos = originPos or core_camera.getPosition()
  minDist = minDist or 0
  maxDist = maxDist or 10000
  local radius = max(minDist, 100)
  local psList, psCount

  if not targetCount or targetCount <= 0 then -- targetCount is optional
    targetCount = math.huge
    radius = maxDist
  end

  repeat -- find enough parking spots in the area
    psList = findParkingSpots(originPos, minDist, radius)
    psList = filterParkingSpots(psList, filters)
    psCount = #psList
    radius = radius * 2
  until (psCount >= targetCount or radius >= maxDist)

  if psCount == 0 then return {} end
  if targetCount == math.huge then
    targetCount = max(1, math.ceil(psCount / 4)) -- auto minimum count
  end

  local psMainList, psAltList = {}, {} -- main list contains the most favorable parking spots, alt list contains all others
  local ratio = min(0.95, 1 - (targetCount / psCount)) -- ratio of selectable parking spots

  for i, ps in ipairs(psList) do
    if random() >= lerp(ratio, 1, square(i / psCount)) then -- value is lower for nearer parking spots (lower index means shorter distance)
      table.insert(psMainList, ps)
    else
      table.insert(psAltList, ps)
    end
  end

  psList = arrayConcat(psMainList, psAltList)
  return psList
end

local function forceTeleport(vehId, pos, minDist, maxDist) -- forces a parked car to teleport to a new parking spot
  if not vars.enableRespawn then return end
  if not parkedVehData[vehId] or parkedVehData[vehId].ignoreForceTeleport then return end

  pos = pos or core_camera.getPosition()

  local psList = getRandomParkingSpots(pos, minDist, maxDist, 1, {checkVehicles = true})
  local psId = nil
  for _, psData in ipairs(psList) do
    local ps = psData.ps
    if checkParkingSpot(vehId, ps, minDist, maxDist) then
      psId = ps.id
      if parkedVehData[vehId].parkingSpotId then
        sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
        parkedVehData[vehId].parkingSpotId = nil
      end

      moveToParkingSpot(vehId, ps, not getObjectByID(vehId):isReady())
      break
    end
  end

  if not psId then
    gameplay_traffic.forceTeleport(vehId, nil, nil, 10000, 10000) -- out of map; this should be unlikely
  end
end

local function scatterParkedCars(vehIds, minDist, maxDist) -- randomly teleports all parked vehicles to parking spots
  vehIds = vehIds or parkedVehIds
  local psList = getRandomParkingSpots(focus and focus.pos, minDist, maxDist, #vehIds, {checkVehicles = true})
  for i, vehId in ipairs(vehIds) do
    if psList[i] and checkParkingSpot(vehId, psList[i].ps, minDist, maxDist) then
      moveToParkingSpot(vehId, psList[i].ps, not getObjectByID(vehId):isReady())
    else
      forceTeleport(vehId, nil, minDist, maxDist) -- alternative method (not efficient if this needs to be called)
    end
  end
end

local function enableTracking(vehId, autoDisable) -- enables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  if not getObjectByID(vehId) then return end

  setState(true)

  trackedVehData[vehId] = {
    isOversized = checkDimensions(vehId),
    autoDisableTracking = autoDisable and true or false,
    inside = false,
    preParked = false,
    parked = false,
    event = "none",
    aheadPos = vec3(),
    focusPos = vec3(),
    maxDist = 80,
    parkingTimer = 0
  }
end

local function disableTracking(vehId) -- disables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  trackedVehData[vehId] = nil
end

local function getTrackingData()
  return trackedVehData
end

local function getCurrentParkingSpot(vehId) -- returns the parking spot id of a properly parked vehicle (no tracked data needed)
  vehId = vehId or be:getPlayerVehicleID(0)
  if not getObjectByID(vehId) then return end

  if trackedVehData[vehId] then
    if trackedVehData[vehId].preParked then
      return trackedVehData[vehId].parkingSpotId -- existing tracked data
    end
  else
    local obj = getObjectByID(vehId)
    if not obj then return end

    local psList = findParkingSpots(obj:getPosition(), 0, 15)
    if psList[1] and psList[1].ps:vehicleFits(vehId) and psList[1].ps:checkParking(vehId, vars.precision) then
      return psList[1].ps.id
    end
  end
end

local function resetParkingVars() -- resets parking variables to default
  vars = {
    precision = 0.8, -- parking precision required for valid parking
    neatness = 0, -- generated parked vehicle precision
    radiusCoef = 1, -- active radius multiplier
    baseProbability = 0.75, -- probability coefficient for spawning in parking spots (usually from 0 to 1; default 0.75 for nice scattering in parking lots)
    activeAmount = math.huge, -- number of active (visible) vehicles at a time
    enableRespawn = true  -- master respawn state; if false, disables all methods of respawning vehicles
  }
end
resetParkingVars()

local function setParkingVars(data, reset) -- sets parking related variables
  if reset then resetParkingVars() end
  if type(data) ~= "table" then return end

  if data.radiusCoef then
    data.radiusCoef = clamp(data.radiusCoef, 0.25, 1000)
    for _, veh in pairs(parkedVehData) do
      veh.activeRadius = 0
    end
  end

  vars = tableMerge(vars, data)

  if data.activeAmount and vehPool then
    vehPool:setMaxActiveAmount(data.activeAmount)
    vehPool:setAllVehs(true)
  end
end

local function setActiveAmount(amount) -- sets the maximum amount of active (visible) vehicles
  amount = amount or math.huge
  setParkingVars({activeAmount = amount})
end

local function getParkingVars() -- gets parking related variables
  return vars
end

local function getParkedCarsAmount(activeOnly)
  return activeOnly and min(vars.activeAmount, #parkedVehIds) or #parkedVehIds
end

local function getParkedCarsList()
  return parkedVehIds
end

local function getParkedCarsData()
  return parkedVehData
end

local function getVehicleSpawnData(obj)
  local metallicPaintData = obj:getMetallicPaintData() or {}
  return {
    model = obj.jbeam or obj.JBeam or obj:getField('JBeam', '0'),
    config = obj.partConfig,
    pos = obj:getPosition(),
    rot = quatFromDir(vec3(obj:getDirectionVector()), vec3(obj:getDirectionVectorUp())),
    paint = createVehiclePaint(obj.color, metallicPaintData[1]),
    paint2 = createVehiclePaint(obj.colorPalette0, metallicPaintData[2]),
    paint3 = createVehiclePaint(obj.colorPalette1, metallicPaintData[3]),
    licenseText = obj:getDynDataFieldbyName("licenseText", 0),
    vehicleName = obj:getField('name', '')
  }
end

local function spawnVehicleFromData(data)
  if not data or not data.model then return end
  local options = {
    config = data.config,
    pos = data.pos,
    rot = data.rot,
    paint = data.paint,
    paint2 = data.paint2,
    paint3 = data.paint3,
    licenseText = data.licenseText,
    vehicleName = data.vehicleName,
    autoEnterVehicle = false,
    canSpawnAnotherVehicleCheck = false,
    centeredPosition = true
  }
  local veh = core_vehicles.spawnNewVehicle(data.model, options)
  return veh and veh:getID()
end

local bbCenter, vehDirection, bbHalfExtents = vec3(), vec3(), vec3()
local result = {}
local function trackParking(vehId) -- tracks parking status of a driving vehicle
  local valid = false
  table.clear(result)
  result.cornerCount = 0
  local obj = getObjectByID(vehId or 0)
  if not obj then return valid, result end

  local vehData = trackedVehData[vehId]
  bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  vehDirection:set(obj:getDirectionVectorXYZ())
  bbHalfExtents:set(be:getObjectOOBBHalfExtentsXYZ(vehId))

  vehDirection:setScaled(bbHalfExtents.y)
  vehData.aheadPos:setAdd2(bbCenter, vehDirection) -- tracks the position ahead of the vehicle

  local maxDist = M.debugLevel >= 3 and 400 or vehData.maxDist
  if vehData.focusPos:squaredDistance(vehData.aheadPos) >= square(maxDist * 0.5) then -- focus pos and nearby parking spots low frequency update
    vehData.psList = findParkingSpots(vehData.aheadPos, 0, maxDist)
    vehData.psList = filterParkingSpots(vehData.psList, emptyFilters)
    vehData.focusPos:set(vehData.aheadPos)
  end

  vehData.psList = updateParkingSpots(vehData.psList, vehData.aheadPos) or {}

  if M.debugLevel > 0 then
    for _, v in ipairs(vehData.psList) do
      local ps = v.ps
      local psDirVec = vec3(0, 1, 0):rotated(ps.rot)
      local dColor = ps.vehicle and ColorF(1, 0.5, 0.5, 0.2) or ColorF(1, 1, 1, 0.2)
      if ps.vehicle == vehId then dColor = ColorF(0.5, 1, 0.5, 0.2) end
      debugDrawer:drawSquarePrism(ps.pos - psDirVec * ps.scl.y * 0.5, ps.pos + psDirVec * ps.scl.y * 0.5, Point2F(0.6, ps.scl.x), Point2F(0.6, ps.scl.x), dColor)
    end
  end

  local bestPs
  for _, v in ipairs(vehData.psList) do -- nearest parking spot
    if v.ps:vehicleFits(vehId) and (not v.ps.vehicle or v.ps.vehicle == vehId) then
      bestPs = v.ps
      break
    end
  end

  if bestPs then
    result.parkingSpotId = bestPs.id
    result.parkingSpot = bestPs

    if not bestPs.vertices[1] then bestPs:calcVerts() end
    valid, result.corners = bestPs:checkParking(vehId, vars.precision) -- checks if all vehicle corners are inside the parking spot with respect to the precision
    for _, v in ipairs(result.corners) do
      if v then
        result.cornerCount = result.cornerCount + 1
      end
    end

    if M.debugLevel >= 2 then
      for i, v in ipairs(result.corners) do
        local dColor = v and ColorF(0.3, 1, 0.3, 0.5) or ColorF(1, 0.3, 0.3, 0.5)
        debugDrawer:drawCylinder(bestPs.vertices[i], bestPs.vertices[i] + vec3(0, 0, 10), 0.05, dColor)
      end
    end
  end

  return valid, result
end

local function processNextSpawn(vehId, ignorePool) -- processes the next vehicle to respawn
  if not vars.enableRespawn then return end
  local oldId, newId = vehId, vehId

  if not ignorePool then
    local inactiveId = vehPool.inactiveVehs[1]
    if inactiveId then
      if #vehPool.activeVehs < vehPool.maxActiveAmount then -- amount of active vehicles is less than the expected limit
        newId = inactiveId
      else
        oldId, newId = vehPool:cycle(oldId, inactiveId) -- cycles the pool
      end
    end
  end

  local addedDist = nearSpawnMode and 0 or square(math.abs(focus.speed or 0) * 0.15)
  local actualClearRadius = nearSpawnMode and 0 or keepClearRadius
  actualClearRadius = clamp(actualClearRadius + addedDist, 15, 300) -- view distance, adjusted by speed

  for _, psData in ipairs(currParkingSpots) do
    local ps = psData.ps
    if checkParkingSpot(newId, ps, actualClearRadius) then -- prevents respawn if player is too near to parking spot
      vehPool:setVeh(newId, true)
      moveToParkingSpot(newId, ps)
      break
    end
  end
end

local function insertVehicle(vehId) -- inserts a new vehicle into the parked cars table
  local obj = getObjectByID(vehId)
  if obj then
    if obj.ignoreParking then
      log('I', logTag, string.format('Ignoring parking vehicle due to blocking flag: %d', vehId))
      return
    end

    if not vehPool then
      vehPool = core_vehicleActivePooling.createPool({name = "autoParking"})
    end

    obj.uiState = 0
    obj.playerUsable = false
    obj:setDynDataFieldbyName("ignoreTraffic", 0, "true")
    obj:setDynDataFieldbyName("isParked", 0, "true")
    gameplay_walk.addVehicleToBlacklist(vehId)

    table.insert(parkedVehIds, vehId)
    vehPool:insertVeh(vehId)

    local psId = getCurrentParkingSpot(vehId)
    if psId then
      sites.parkingSpots.objects[psId].vehicle = vehId -- saves the vehicle id to this spot
    end

    parkedVehData[vehId] = {
      parkingSpotId = psId, -- current parking spot id
      activeRadius = 0, -- radius that keeps the vehicle active if player is near
      randomPaint = true -- randomizes paint after respawning
    }

    setMapmgrTracking(vehId)
  end
end

local function removeVehicle(vehId) -- removes a vehicle from the parked cars table
  if parkedVehData[vehId] then
    parkedVehData[vehId] = nil
    parkedVehIds = tableKeysSorted(parkedVehData)
  end
end

local function deleteVehicles(amount)
  amount = amount or #parkedVehIds
  for i = amount, 1, -1 do
    local vehId = parkedVehIds[i] or 0
    local obj = getObjectByID(vehId)
    if obj then
      obj:delete()
      table.remove(parkedVehIds, i)
      parkedVehData[vehId] = nil
    end
  end
end

local function activate(vehIds) -- activates a group of vehicles, to allow them to teleport to new parking spots
  setState(true)
  if not sites or not vehIds then
    setState(false)
    return
  end

  for _, vehId in ipairs(vehIds) do
    insertVehicle(vehId)
  end

  if not parkedVehIds[1] then
    setState(false)
    return
  end

  extensions.hook("onParkingVehiclesActivated", parkedVehIds)

  local amount, activeAmount = getParkedCarsAmount(), getParkedCarsAmount(true)
  log('I', logTag, string.format('Parking system started with %d active / %d total vehicles', activeAmount, amount))
end

local function deactivate() -- deactivates all parked vehicles
  setState(false)
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  if vehPool then
    vehPool:deletePool(true)
    vehPool = nil
  end
  extensions.hook("onParkingVehiclesDeactivated")
end

local function setupVehicles(amount, options) -- spawns and prepares simple parked vehicles
  options = options or {}

  if not options.keepCurrent then
    deleteVehicles() -- clear current parked vehicles
  end

  if not sites then
    loadSites()
  end

  amount = amount or -1
  if amount == -1 then
    amount = settings.getValue("trafficParkedAmount")
    if amount == 0 then
      setMaxVehicleAmountForTraffic() -- fix parking amount if zero
      amount = settings.getValue("trafficParkedAmount") -- get fixed amount
    end
  end

  local group
  if type(options.vehGroup) == "table" then
    group = options.vehGroup
  else
    local params = gameplay_traffic_trafficUtils.getBaseGroupParams()
    params.allConfigs = true
    params.filters.Type = {propparked = 1}
    params.minPop = 0

    group = core_multiSpawn.createGroup(amount, params)
  end

  if amount <= 0 then
    log("I", logTag, "Parked vehicle amount to spawn is zero, now ignoring parked cars")
    return false
  elseif not group or not group[1] then
    log("I", logTag, "Parked vehicle group is empty!")
    return false
  end

  local transforms
  local psList = getRandomParkingSpots(options.pos, nil, nil, amount, {checkVehicles = true, standardSize = true})
  if psList[1] then
    lastPos:set(psList[1].ps.pos) -- initial setting of lastPos
    if psList[amount] then
      transforms = {}
      for _, ps in ipairs(psList) do
        table.insert(transforms, {pos = ps.ps.pos, rot = ps.ps.rot})
      end
    end
  else
    if not options.bypassChecks then
      log("I", logTag, "No parking spots found, now ignoring parked cars")
      return false
    end
  end

  if gameplay_traffic.getFocus().auto and be:getPlayerVehicleID(0) ~= -1 then
    gameplay_traffic.setFocus('vehicle', {vehId = be:getPlayerVehicleID(0)})
  end

  core_multiSpawn.spawnGroup(group, amount, {name = "autoParking", mode = "roadBehind", gap = 50, customTransforms = transforms, randomPaints = true})

  return true
end

local function resetAll() -- resets everything
  active = false
  sites = nil
  parkingSpotsAmount = 0
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  table.clear(trackedVehData)
  if vehPool then
    vehPool:deletePool(true)
    vehPool = nil
  end
  resetParkingVars()
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == "autoParking" then
    activate(vehList)
  end
end

local function onVehicleResetted(vehId)
  if active and getObjectByID(vehId):isPlayerControlled() then
    resetFlag = true
    respawnDelay = 0.1 -- small value but above zero
  end
end

local function onVehicleDestroyed(vehId)
  if parkedVehData[vehId] then
    table.remove(parkedVehIds, arrayFindValueIndex(parkedVehIds, vehId))
    if sites and parkedVehData[vehId].parkingSpotId then
      sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
    end
    parkedVehData[vehId] = nil
  end
  if trackedVehData[vehId] then
    disableTracking(vehId)
  end
end

local function onVehicleActiveChanged(vehId, active)
  if vehPool and parkedVehData[vehId] then
    if not active then
      parkedVehData[vehId]._teleport = true
    else
      if parkedVehData[vehId]._teleport then -- force teleport if flag exists
        for _, otherVeh in ipairs(getAllVehicles()) do
          local otherId = otherVeh:getId()
          if otherVeh:getActive() and not parkedVehData[otherId] then
            local radius = otherVeh:isPlayerControlled() and 100 or 20
            if otherVeh:getPosition():squaredDistance(getObjectByID(vehId):getPosition()) < square(radius) then
              forceTeleport(vehId, nil, 100)
              break
            end
          end
        end
      end
    end
  end
end

local vehPos = vec3()
local function onUpdate(dt, dtSim)
  if not active or not sites or not be:getEnabled() or (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then return end

  tempVec:set(focus.dirVec)
  tempVec.z = 0
  tempVec:normalize()
  tempVec:setScaled2(tempVec, clamp(focus.speed * 2, 10, 100))
  aheadPos:setAdd2(focus.pos, tempVec)
  aheadPos.z = 0

  for vehId, data in pairs(trackedVehData) do
    local valid, pData = trackParking(vehId)
    data.parkingSpotId = pData.parkingSpotId
    data.parkingSpot = pData.parkingSpot

    if not valid then
      data.parkingTimer = 0
    end

    if pData.cornerCount >= 2 then -- at least two vehicle corners
      data.lastParkingSpotId = data.parkingSpotId
    end

    if not data.inside and pData.cornerCount > 0 then -- entered parking spot bounds
      data.inside = true
      data.event = "enter"
      extensions.hook("onVehicleParkingStatus", vehId, data)
    elseif data.inside and pData.cornerCount == 0 then -- exited parking spot bounds
      data.inside = false
      data.event = "exit"
      extensions.hook("onVehicleParkingStatus", vehId, data)
    end

    if data.lastParkingSpotId then
      if not data.parked and valid then
        data.preParked = true
        data.parkingTimer = data.parkingTimer + dtSim
        if data.parkingTimer >= 0.5 then -- valid parking (after a small delay)
          data.parked = true
          data.event = "valid"
          sites.parkingSpots.objects[data.lastParkingSpotId].vehicle = vehId
          extensions.hook("onVehicleParkingStatus", vehId, data)

          if data.autoDisableTracking then
            disableTracking(vehId)
          end
        end
      elseif data.preParked and not valid then -- invalid parking
        data.preParked = false
        data.parked = false
        data.event = data.inside and "invalid" or "exit"
        sites.parkingSpots.objects[data.lastParkingSpotId].vehicle = nil
        extensions.hook("onVehicleParkingStatus", vehId, data)
      end
    end
  end

  local parkedVehCount = #parkedVehIds
  if not parkedVehIds[1] or parkedVehCount >= parkingSpotsAmount then return end -- unable to teleport vehicles to new parking spots

  -- only search for parking spots whenever needed (whenever look ahead point is far enough from the last position)
  local targetOffsetDistSq = aheadPos:squaredDistance(lastPos)
  local actualTargetRadius = targetRadius * vars.radiusCoef
  if vars.baseProbability > 0 and respawnDelay == 0 and (targetOffsetDistSq > square(actualTargetRadius) or resetFlag) then -- updates parking spots if away from focus position
    local actualSearchPointDist = searchPointDist

    if commands.isFreeCamera() then
      local height = max(-1e6, be:getSurfaceHeightBelow(focus.pos))
      height = focus.pos.z - height
      height = clamp(square(height) / 15, 0, 200)
      actualSearchPointDist = actualSearchPointDist + height
    end

    tempVec:set(focus.dirVec)
    tempVec.z = 0
    tempVec:normalize()

    if resetFlag then -- player vehicle teleported
      aheadPos:set(focus.pos) -- parking spot search point is at the player vehicle
      aheadPos.z = 0
      nearSpawnMode = true
      resetFlag = false
    else
      tempVec:setScaled2(tempVec, actualSearchPointDist) -- parking spot search point is ahead of the player vehicle
      aheadPos:setAdd2(focus.pos, tempVec)
      aheadPos.z = 0
    end

    currParkingSpots = findParkingSpots(aheadPos, 0, searchRadius)
    currParkingSpots = filterParkingSpots(currParkingSpots)

    if M.debugLevel >= 3 then
      debugPos:set(aheadPos)
    end

    if not nearSpawnMode then
      tempVec:resize(clamp(focus.speed * 2, 10, 100)) -- speed based search vector
    end
    aheadPos:setAdd2(focus.pos, tempVec)
    aheadPos.z = 0
    lastPos:set(aheadPos) -- set the position of the dynamic target point

    for _, vehId in ipairs(parkedVehIds) do
      parkedVehData[vehId].searchFlag = false -- reset search flag for all parked cars
    end

    respawnDelay = respawnDelay + 0.3
  end

  if nearSpawnMode and respawnDelay == 0 then nearSpawnMode = false end -- disables near spawn mode after a small delay

  if M.debugLevel >= 3 then
    local vecUpHigh = vec3(0, 0, 1000)
    local tempColor = respawnDelay > 0 and ColorF(1, 1, 1, 0.5) or ColorF(0, 1, 0, 0.5)
    debugDrawer:drawCylinder(aheadPos, aheadPos + vecUpHigh, 0.25, ColorF(1, 1, 0, 0.5))
    debugDrawer:drawCylinder(lastPos, lastPos + vecUpHigh, 0.25, tempColor)
    if core_terrain.getTerrain() then
      lastPos.z = core_terrain.getTerrainHeight(lastPos)
      debugDrawer:drawCylinder(lastPos, lastPos + vec3(0, 0, 1), targetRadius * vars.radiusCoef, ColorF(0, 1, 0, 0.1))
      lastPos.z = 0

      debugPos.z = core_terrain.getTerrainHeight(debugPos)
      debugDrawer:drawCylinder(debugPos, debugPos + vec3(0, 0, 0.5), searchRadius, ColorF(0, 1, 1, 0.1))
      debugPos.z = 0
    end
  end

  -- cycle through array of parked vehicles one at a time, to save on performance
  local currId = parkedVehIds[queuedIndex] or 0
  local currVeh = parkedVehData[currId]
  if be:getObjectActive(currId) and not currVeh.ignoreTeleport then
    vehPos:set(be:getObjectPositionXYZ(currId))

    tempVec:setSub2(vehPos, focus.pos)
    local actualActiveRadius = max(30, keepActiveRadius * vars.radiusCoef)
    -- here, the vehicle stays active within a looser radius if the player was close to it
    currVeh.activeRadius = max(actualActiveRadius, keepClearRadius - tempVec:length(), currVeh.activeRadius)

    if not currVeh.searchFlag and currParkingSpots[1] then
      tempVec:normalize()

      local activeRadius = currVeh.activeRadius + focus.speed
      activeRadius = activeRadius + max(0, focus.dirVec:dot(tempVec)) * 150
      if square(activeRadius) < focus.pos:squaredDistance(vehPos) then -- focus pos is outside the active radius
        local valid = true

        for _, veh in ipairs(getAllVehicles()) do
          if not veh.isTraffic and not veh.isParked and map.objects[veh:getId()] then
            local mapData = map.objects[veh:getId()]
            local trafficClearRadius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) or actualActiveRadius
            if vehPos:squaredDistance(mapData.pos) < square(trafficClearRadius) then -- prevents respawning if too close
              valid = false
              break
            end
          end
        end

        if valid then
          processNextSpawn(currId)
          currVeh.searchFlag = true -- stop searching until next parking spot query
        end
      end
    end

    if currVeh._teleport then
      forceTeleport(currId, nil, 100)
    end
  end

  queuedIndex = queuedIndex + 1
  if queuedIndex > parkedVehCount then
    queuedIndex = 1
  end

  if respawnDelay > 0 then
    respawnDelay = max(0, respawnDelay - dtSim) -- prevents rapid parking spot searching or respawning
  end
end

local function onClientStartMission()
end

local function onClientEndMission()
  resetAll()
end

local function onSerialize(options)
  options = type(options) == "table" and options or {}
  local vehicleSpawnData, vehicleSpawnOrder
  if options.despawnVehicles then
    vehicleSpawnData = {}
    vehicleSpawnOrder = {}
    if options.debugVehicleStashing then
      log("D", logTag, "Serializing parked vehicles for mission despawn stash")
    end
    for _, vehId in ipairs(parkedVehIds) do
      local obj = getObjectByID(vehId)
      if obj and vehId ~= options.exceptVehicleId then
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Capturing parked vehicle for mission despawn stash: %d", vehId))
        end
        vehicleSpawnData[vehId] = getVehicleSpawnData(obj)
        table.insert(vehicleSpawnOrder, vehId)
      elseif obj and vehId == options.exceptVehicleId and options.debugVehicleStashing then
        log("D", logTag, string.format("Skipping mission player vehicle parking despawn: %d", vehId))
      end
    end
  end

  local data = {active = active, debugLevel = M.debugLevel, parkedVehIds = deepcopy(parkedVehIds), trackedVehIds = tableKeys(trackedVehData), vars = deepcopy(vars), vehicleSpawnData = vehicleSpawnData, vehicleSpawnOrder = vehicleSpawnOrder}
  resetAll()

  if vehicleSpawnOrder then
    for _, vehId in ipairs(vehicleSpawnOrder) do
      local obj = getObjectByID(vehId)
      if obj then
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Deleting parked vehicle after mission stash capture: %d", vehId))
        end
        obj:delete()
      end
    end
  end

  return data
end

local function onDeserialized(data, options)
  options = type(options) == "table" and options or {}
  local idMap = {}
  if options.respawnVehicles and data.vehicleSpawnData then
    if options.debugVehicleStashing then
      log("D", logTag, "Respawning parked vehicles from mission stash")
    end
    for _, oldId in ipairs(data.vehicleSpawnOrder or tableKeysSorted(data.vehicleSpawnData)) do
      local newId = spawnVehicleFromData(data.vehicleSpawnData[oldId])
      if newId then
        idMap[oldId] = newId
        if options.debugVehicleStashing then
          log("D", logTag, string.format("Respawned parked vehicle from mission stash: oldId=%d newId=%d", oldId, newId))
        end
      else
        log("W", logTag, string.format("Unable to respawn serialized parked vehicle: %d", oldId))
      end
    end
  end

  local restoredParkedVehIds = {}
  for _, vehId in ipairs(data.parkedVehIds or {}) do
    table.insert(restoredParkedVehIds, idMap[vehId] or vehId)
  end

  activate(restoredParkedVehIds)
  for _, v in ipairs(data.trackedVehIds or {}) do
    enableTracking(idMap[v] or v)
  end
  setParkingVars(data.vars)
  active = data.active
  M.debugLevel = data.debugLevel
end

-- public interface
M.setSites = setSites
M.setState = setState
M.getState = getState
M.setupVehicles = setupVehicles
M.insertVehicle = insertVehicle
M.removeVehicle = removeVehicle
M.processVehicles = activate
M.activate = activate
M.deactivate = deactivate
M.deleteVehicles = deleteVehicles
M.getParkedCarsAmount = getParkedCarsAmount
M.getParkingAmount = getParkedCarsAmount
M.getParkedCarsList = getParkedCarsList
M.getParkedCarsData = getParkedCarsData
M.enableTracking = enableTracking
M.disableTracking = disableTracking
M.resetAll = resetAll

M.getTrackingData = getTrackingData
M.getParkingSpots = getParkingSpots
M.findParkingSpots = findParkingSpots
M.filterParkingSpots = filterParkingSpots
M.getRandomParkingSpots = getRandomParkingSpots
M.checkParkingSpot = checkParkingSpot
M.moveToParkingSpot = moveToParkingSpot
M.getCurrentParkingSpot = getCurrentParkingSpot
M.forceTeleport = forceTeleport
M.scatterParkedCars = scatterParkedCars
M.setActiveAmount = setActiveAmount
M.setParkingVars = setParkingVars
M.getParkingVars = getParkingVars

M.onUpdate = onUpdate
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M