-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "parking"

local areaRadius = 200 -- radius to search within for parking spots
local lookDist = 300 -- distance ahead of camera to start query of parking spots
local stepDist = 50 -- distance until the next parking spot query refresh
local parkedVehIds, parkedVehData = {}, {}
local trackedVehData = {}
local currParkingSpots = {}
local queuedIndex = 1

-- common functions --
local min = math.min
local max = math.max
local random = math.random

local sites, vehPool, vars
local focusPos = vec3()
local active = false
local worldLoaded = false
local parkingSpotsAmount = 0
local respawnTicks = 0

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
  if active and not sites then
    loadSites()
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

local function moveToParkingSpot(vehId, parkingSpot, lowPrecision) -- assigns a parked vehicle to a parking spot
  local obj = be:getObjectByID(vehId)
  local width, length = obj.initialNodePosBB:getExtents().x - 0.1, obj.initialNodePosBB:getExtents().y
  local backwards, offsetPos, offsetRot

  if parkingSpot.customFields.tags.forwards then
    backwards = false
  elseif parkingSpot.customFields.tags.backwards then
    backwards = true
  else
    backwards = random() > 0.75 + vars.neatness * 0.25
  end

  if not parkingSpot.customFields.tags.perfect then -- randomize position and rotation slightly
    local offsetVal = 1 - square(vars.neatness)
    local xGap, yGap = max(0, parkingSpot.scl.x - width), max(0, parkingSpot.scl.y - length)
    local xRandom, yRandom = randomGauss3() / 3 - 0.5, clamp(randomGauss3() / 3 - (backwards and 0.75 or 0.25), -0.5, 0.5)
    offsetPos = vec3(xRandom * offsetVal * xGap, yRandom * offsetVal * yGap, 0)
    offsetRot = quatFromEuler(0, 0, (randomGauss3() / 3 - 0.5) * offsetVal * 0.25)
  end

  parkingSpot:moveResetVehicleTo(vehId, lowPrecision, backwards, offsetPos, offsetRot, true, false)
  if M.debugLevel > 0 then
    log("I", logTag, "Teleported vehId "..vehId.." to parking spot "..parkingSpot.id)
  end

  --core_vehicleBridge.executeAction(be:getObjectByID(vehId), "setIgnitionLevel", 0)
  be:getObjectByID(vehId):queueLuaCommand("electrics.setIgnitionLevel(0)")
  core_vehicle_manager.setVehiclePaintsNames(vehId, {getRandomPaint(vehId, 0.75)})

  if parkedVehData[vehId] then
    if parkedVehData[vehId].parkingSpotId then
      sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
    end

    if parkingSpot.customFields.tags.street then -- enables tracking, so that AI can try to avoid this vehicle
      if not map.objects[vehId] then be:getObjectByID(vehId):queueLuaCommand("mapmgr.enableTracking()") end
    else -- disables tracking, to optimize performance
      be:getObjectByID(vehId):queueLuaCommand("mapmgr.disableTracking()")
    end

    parkingSpot.vehicle = vehId -- parking spot contains this vehicle
    parkedVehData[vehId].parkingSpotId = parkingSpot.id -- vehicle is assigned to this parking spot
    parkedVehData[vehId].radiusCoef = 1
    parkedVehData[vehId]._teleport = nil
    respawnTicks = 5
  end
end

local defaultParkingSpotSize = vec3(2.5, 6, 3)
local function checkDimensions(vehId) -- checks if the vehicle would fit in a standard sized parking spot
  local obj = be:getObjectByID(vehId)
  if not obj then return false end

  local extents = obj.initialNodePosBB:getExtents()
  return  extents.x <= defaultParkingSpotSize.x and
          extents.y <= defaultParkingSpotSize.y and
          extents.z <= defaultParkingSpotSize.z
end

local function checkParkingSpot(vehId, parkingSpot) -- checks if a parking spot is ready to use for a parked vehicle
  local obj = be:getObjectByID(vehId or 0)

  if parkingSpot.vehicle or parkingSpot.ignoreOthers or parkingSpot.customFields.tags.ignoreOthers or parkingSpot:hasAnyVehicles() or not obj then
    return false
  end

  if parkingSpot:vehicleFits(vehId) then
    -- ensures that the parking spot is not too oversized for the vehicle
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

local function findParkingSpots(pos, minRadius, maxRadius) -- finds and returns a sorted array having the squared distances and parking spot objects
  if not sites then return {} end
  pos = pos or core_camera.getPosition()
  minRadius = minRadius or 0
  maxRadius = maxRadius or areaRadius

  local psList = sites:getRadialParkingSpots(pos, minRadius, maxRadius)

  if M.debugLevel > 0 then
    log("I", logTag, "Found and validated "..#psList.." parking spots in area")
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
local function filterParkingSpots(psList, filters) -- filters the sorted list of parking spots (as returned by findParkingSpots)
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

    if filters.checkVehicles then -- strict but slow check for other vehicles occupying this spot
      if ps:hasAnyVehicles() then
        remove = true
      end
    end

    if filters.useProbability then
      local prob = ps.customFields:has("probability") and ps.customFields:get("probability") or 1
      if type(prob) ~= "number" then prob = 1 end
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
    log("I", logTag, "Filtered and accepted "..#psList.." / "..psCount.." parking spots")
  end

  return psList
end

local function forceTeleport(vehId, psList, minDist, maxDist) -- forces a parked car to teleport to a new parking spot
  if not parkedVehData[vehId] then return end
  minDist = minDist or 0
  maxDist = maxDist or 10000
  psList = psList or findParkingSpots(core_camera.getPosition(), minDist, maxDist)

  for _, psData in ipairs(psList) do
    local ps = psData.ps
    if psData.squaredDistance >= square(minDist) and psData.squaredDistance <= square(maxDist) and checkParkingSpot(vehId, ps) then
      if parkedVehData[vehId].parkingSpotId then
        sites.parkingSpots.objects[parkedVehData[vehId].parkingSpotId].vehicle = nil
        parkedVehData[vehId].parkingSpotId = nil
      end

      moveToParkingSpot(vehId, ps, not be:getObjectByID(vehId):isReady())
      break
    end
  end
end

local function getRandomParkingSpots(originPos, minDist, maxDist, minCount, filters) -- returns a list of random parking spots, with a bias for origin position
  if not sites then return {} end
  minDist = minDist or 0
  maxDist = maxDist or 10000
  local radius = max(minDist, 100)
  local psList, psCount
  if not minCount then
    minCount = math.huge
    radius = maxDist
  end

  repeat
    psList = findParkingSpots(originPos or core_camera.getPosition(), minDist, radius)
    psList = filterParkingSpots(psList, filters)
    psCount = #psList
    radius = radius * 2
  until psCount >= minCount or radius >= maxDist

  if minCount == math.huge then
    minCount = max(1, math.ceil(psCount / 4)) -- auto minimum count
  end
  if psCount < minCount then return {} end

  local finalPsList = {}
  local selected = {}
  local ratio = min(0.95, 1 - (minCount / psCount))
  local fallbackValue = 1

  repeat
    for i, ps in ipairs(psList) do
      local minValue = min(fallbackValue, lerp(ratio, 1, square(i / psCount))) -- minValue is lower for nearer parking spots
      if not selected[ps.ps.name] and random() >= minValue then
        selected[ps.ps.name] = 1
        table.insert(finalPsList, ps)
      end
      if finalPsList[minCount] then break end
    end

    fallbackValue = fallbackValue / 2
  until finalPsList[minCount]

  return finalPsList, psList
end

local function scatterParkedCars(vehIds, minDist, maxDist) -- randomly teleports all parked vehicles to parking spots
  vehIds = vehIds or parkedVehIds
  local randomPsList, psList = getRandomParkingSpots(core_camera.getPosition(), minDist, maxDist, #vehIds)
  if not psList then return end

  randomPsList = arrayConcat(psList, randomPsList)

  for _, id in ipairs(vehIds) do
    forceTeleport(id, randomPsList)
  end
end

local function enableTracking(vehId, autoDisable) -- enables parking spot tracking for a driving vehicle
  vehId = vehId or be:getPlayerVehicleID(0)
  if not be:getObjectByID(vehId) then return end

  setState(true)

  trackedVehData[vehId] = {
    isOversized = checkDimensions(vehId),
    autoDisableTracking = autoDisable and true or false,
    inside = false,
    preParked = false,
    parked = false,
    event = "none",
    frontPos = vec3(),
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
  if not be:getObjectByID(vehId) then return end

  if trackedVehData[vehId] then
    if trackedVehData[vehId].preParked then
      return trackedVehData[vehId].parkingSpotId -- existing tracked data
    end
  else
    local obj = be:getObjectByID(vehId)
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
    parkingDelay = 0.5, -- time delay until a vehicle is considered parked
    baseProbability = 1, -- base probability for spawning in parking spots (usually from 0 to 1)
    activeAmount = math.huge
  }
end
resetParkingVars()

local function setParkingVars(data) -- sets parking related variables
  if type(data) ~= "table" then
    if not data then resetParkingVars() end
    return
  end

  vars = tableMerge(vars, data)

  if vars.activeAmount and vehPool then
    vehPool:setMaxActiveAmount(vars.activeAmount)
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

local bbCenter, vehDirection, bbHalfExtents = vec3(), vec3(), vec3()
local function trackParking(vehId) -- tracks parking status of a driving vehicle
  local valid = false
  local result = {
    cornerCount = 0
  }
  local obj = be:getObjectByID(vehId or 0)
  if not obj then return valid, result end

  local vehData = trackedVehData[vehId]
  bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  vehDirection:set(obj:getDirectionVectorXYZ())
  bbHalfExtents:set(be:getObjectOOBBHalfExtentsXYZ(vehId))

  vehDirection:setScaled(bbHalfExtents.y)
  vehData.frontPos:setAdd2(bbCenter, vehDirection)

  local maxDist = M.debugLevel >= 3 and 400 or vehData.maxDist
  if vehData.focusPos:squaredDistance(vehData.frontPos) >= square(maxDist * 0.5) then -- focus pos and nearby parking spots low frequency update
    vehData.psList = findParkingSpots(vehData.frontPos, 0, maxDist)
    vehData.psList = filterParkingSpots(vehData.psList, emptyFilters)
    vehData.focusPos:set(vehData.frontPos)
  end

  vehData.psList = updateParkingSpots(vehData.psList, vehData.frontPos) or {}

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
    valid, result.corners = bestPs:checkParking(vehId, vars.precision)
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

  local psCount = #currParkingSpots
  local startIdx = math.ceil(psCount * square(random())) -- bias towards lower start index, and therefore closest parking spots to target point
  for i = startIdx, psCount + startIdx - 1 do
    local idx = i % psCount
    if idx == 0 then idx = psCount end
    local ps = currParkingSpots[idx].ps
    -- consider using a static raycast
    if ps.pos:squaredDistance(core_camera.getPosition()) > square(areaRadius * 0.5) and checkParkingSpot(newId, ps) then
      vehPool:setVeh(newId, true)
      moveToParkingSpot(newId, ps)
      break
    end
  end
end

local function processVehicles(vehIds, ignoreScatter) -- activates a group of vehicles, to allow them to teleport to new parking spots
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  if vehPool then
    core_vehiclePoolingManager.deletePool(vehPool.id)
    vehPool = nil
  end
  if not vehIds then return end

  setState(true)
  if not sites then active = false return end

  for _, id in ipairs(vehIds) do
    local obj = be:getObjectByID(id)
    if obj then
      if not vehPool then
        vehPool = core_vehiclePoolingManager.createPool()
        vehPool.name = "parkedCars"
      end

      parkedVehData[id] = {
        radiusCoef = 1 -- coefficient for keeping the vehicle at its current spot
      }

      obj.uiState = 0
      obj.playerUsable = false
      obj:setDynDataFieldbyName("ignoreTraffic", 0, "true")
      obj:setDynDataFieldbyName("isParked", 0, "true")
      gameplay_walk.addVehicleToBlacklist(id)

      table.insert(parkedVehIds, id)
      vehPool:insertVeh(id)
    end
  end

  if not parkedVehIds[1] then return end

  if worldLoaded and not ignoreScatter then
    scatterParkedCars(vehIds)
  end
  extensions.hook("onParkingVehiclesActivated", parkedVehIds)
  log("I", logTag, "Processed and teleported "..#parkedVehIds.." parked vehicles")
end

local function deleteVehicles(amount)
  amount = amount or #parkedVehIds
  for i = amount, 1, -1 do
    local id = parkedVehIds[i] or 0
    local obj = be:getObjectByID(id)
    if obj then
      obj:delete()
      table.remove(parkedVehIds, i)
      parkedVehData[id] = nil
    end
  end
end

local function setupVehicles(amount, options) -- spawns and prepares simple parked vehicles
  options = options or {}
  if not options.ignoreDelete then
    deleteVehicles()
  end

  if not sites then
    loadSites()
  end

  amount = amount or -1
  if amount == -1 then
    amount = settings.getValue("trafficParkedAmount")
    if amount == 0 then -- auto amount
      amount = clamp(gameplay_traffic.getIdealSpawnAmount(nil, true), 4, 16)
    end
  end

  local group
  if type(options.vehGroup) == "table" then
    group = options.vehGroup
  else
    local params = {filters = {}}

    params.allConfigs = true
    params.filters.Type = {propparked = 1}
    params.minPop = 0

    group = core_multiSpawn.createGroup(amount, params)
  end

  if amount <= 0 or not group or not group[1] then
    if amount <= 0 then
      log("W", logTag, "Parked vehicle amount to spawn is zero!")
    else
      log("W", logTag, "Parked vehicle group is undefined!")
    end
    return false
  end

  local transforms
  local psList = getRandomParkingSpots(options.pos, nil, nil, amount, {checkVehicles = true})
  if psList[1] then
    if psList[amount] then
      transforms = {}
      for _, ps in ipairs(psList) do
        table.insert(transforms, {pos = ps.ps.pos, rot = ps.ps.rot})
      end
    else
      M.queueTeleport = true
    end
  else
    if not options.ignoreParkingSpots then
      log("W", logTag, "No parking spots found, skipping parked cars...")
      return false
    end
  end

  core_multiSpawn.spawnGroup(group, amount, {name = "autoParking", mode = "roadBehind", gap = 50, customTransforms = transforms, instant = not worldLoaded, ignoreAdjust = not worldLoaded})

  return true
end

local function getParkedCarsList(override)
  if override then
    local list = {}
    for _, v in ipairs(getAllVehicles()) do
      if v.isParked == "true" then
        table.insert(list, v:getId())
      end
    end
    return list
  else
    return parkedVehIds
  end
end

local function getParkedCarsData()
  return parkedVehData
end

local function resetAll() -- resets everything
  active = false
  sites = nil
  parkingSpotsAmount = 0
  table.clear(parkedVehIds)
  table.clear(parkedVehData)
  table.clear(trackedVehData)
  resetParkingVars()
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == "autoParking" then
    processVehicles(vehList, true)
  end
end

local function onVehicleDestroyed(id)
  if parkedVehData[id] then
    table.remove(parkedVehIds, arrayFindValueIndex(parkedVehIds, id))
    if sites and parkedVehData[id].parkingSpotId then
      sites.parkingSpots.objects[parkedVehData[id].parkingSpotId].vehicle = nil
    end
    parkedVehData[id] = nil
  end
  if trackedVehData[id] then
    disableTracking(id)
  end
end

local function onVehicleActiveChanged(vehId, active)
  if vehPool and parkedVehData[vehId] then
    if not active then
      parkedVehData[vehId]._teleport = true
    else
      if parkedVehData[vehId]._teleport then -- if flag did not get unset
        for _, otherVeh in ipairs(getAllVehicles()) do
          local otherId = otherVeh:getId()
          if otherVeh:getActive() and not parkedVehData[otherId] then
            local radius = otherVeh:isPlayerControlled() and 100 or 20
            if otherVeh:getPosition():squaredDistance(be:getObjectByID(vehId):getPosition()) < square(radius) then
              forceTeleport(vehId, nil, 100)
              break
            end
          end
        end
      end
    end
  end
end

local function onUpdate(dt, dtSim)
  if not active or not sites or not be:getEnabled() or freeroam_bigMapMode.bigMapActive() then return end

  local camPos = core_camera.getPosition()
  local camDirVec = core_camera.getForward()
  local playerPos = map.objects[be:getPlayerVehicleID(0)] and map.objects[be:getPlayerVehicleID(0)].pos or camPos

  if not worldLoaded and parkedVehIds[1] and camPos.z ~= 0 then
    --scatterParkedCars()
    worldLoaded = true
  end
  if M.queueTeleport then
    scatterParkedCars()
    M.queueTeleport = false
  end

  for id, data in pairs(trackedVehData) do
    local valid, pData = trackParking(id)
    data.parkingSpotId = pData.parkingSpotId
    data.parkingSpot = pData.parkingSpot

    if not valid then
      data.parkingTimer = 0
    end

    if pData.cornerCount >= 2 then -- at least two corners
      data.lastParkingSpotId = data.parkingSpotId
    end

    if not data.inside and pData.cornerCount > 0 then -- entered parking spot bounds
      data.inside = true
      data.event = "enter"
      extensions.hook("onVehicleParkingStatus", id, data)
    elseif data.inside and pData.cornerCount == 0 then -- exited parking spot bounds
      data.inside = false
      data.event = "exit"
      extensions.hook("onVehicleParkingStatus", id, data)
    end

    if data.lastParkingSpotId then
      if not data.parked and valid then
        data.preParked = true
        data.parkingTimer = data.parkingTimer + dtSim
        if data.parkingTimer >= vars.parkingDelay then -- valid parking (after a small delay)
          data.parked = true
          data.event = "valid"
          sites.parkingSpots.objects[data.lastParkingSpotId].vehicle = id
          extensions.hook("onVehicleParkingStatus", id, data)

          if data.autoDisableTracking then
            disableTracking(id)
          end
        end
      elseif data.preParked and not valid then -- invalid parking
        data.preParked = false
        data.parked = false
        data.event = data.inside and "invalid" or "exit"
        sites.parkingSpots.objects[data.lastParkingSpotId].vehicle = nil
        extensions.hook("onVehicleParkingStatus", id, data)
      end
    end
  end

  local parkedVehCount = #parkedVehIds
  if not parkedVehIds[1] or parkedVehCount >= parkingSpotsAmount then return end -- unable to teleport vehicles to new parking spots

  -- only search for parking spots whenever needed
  if vars.baseProbability > 0 and focusPos:squaredDistance(camPos) >= square(stepDist) then
    -- consider using a smoother for the look direction, similar to the traffic system
    local aheadPos = camPos + camDirVec:z0():normalized() * (lookDist + stepDist) + camDirVec:cross(vec3(0, 0, 1)):z0():normalized() * random(-50, 50)
    currParkingSpots = findParkingSpots(aheadPos, 0, areaRadius)
    currParkingSpots = filterParkingSpots(currParkingSpots)
    focusPos:set(camPos)
    stepDist = clamp(lerp(stepDist, 50 - #currParkingSpots * 0.5, 0.5), 10, 50) -- smaller step distance if there are more parking spots

    for _, id in ipairs(parkedVehIds) do
      parkedVehData[id].searchFlag = false -- reset search flag for all vehicles
    end
  end

  -- cycle through array of parked vehicles one at a time, to save on performance
  local currId = parkedVehIds[queuedIndex]
  local currVeh = parkedVehData[currId]
  local obj = be:getObjectByID(currId or 0)
  if obj and obj:getActive() then
    local pos = obj:getPosition()
    local dtCoef = max(0.4, parkedVehCount * 0.1)
    currVeh.radiusCoef = lerp(currVeh.radiusCoef, clamp(80 / pos:distance(camPos + camDirVec * 15), 1, 6), dtSim * dtCoef) -- stronger value while player or camera is near target

    if not currVeh.searchFlag and currParkingSpots[1] then
      if vars.baseProbability == 1 or vars.baseProbability >= random() then
        local dirValue = max(0, camDirVec:dot((pos - camPos):normalized()) * areaRadius) -- higher value while looking at target vehicle
        if pos:squaredDistance(camPos) > square(areaRadius * currVeh.radiusCoef * 0.5 + dirValue) and pos:squaredDistance(playerPos) > square(areaRadius * 0.5) then
          processNextSpawn(currId) -- respawn the next available vehicle
        end
      end

      currVeh.searchFlag = true -- stop searching until next parking spot query
    end

    if currVeh._teleport then
      forceTeleport(currId, nil, 100)
    end
  end

  queuedIndex = queuedIndex + 1
  if queuedIndex > parkedVehCount then
    queuedIndex = 1
  end

  if respawnTicks > 0 then
    respawnTicks = respawnTicks - 1 -- optimization to prevent rapid succession of respawning vehicles
  end
end

local function onClientStartMission()
  if not sites then
    worldLoaded = true
  end
end

local function onClientEndMission()
  resetAll()
  worldLoaded = false
end

local function onSerialize()
  local data = {active = active, debugLevel = M.debugLevel, parkedVehIds = deepcopy(parkedVehIds), trackedVehIds = tableKeys(trackedVehData), vars = deepcopy(vars)}
  resetAll()
  return data
end

local function onDeserialized(data)
  worldLoaded = true
  processVehicles(data.parkedVehIds, true)
  for _, v in ipairs(data.trackedVehIds) do
    enableTracking(v)
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
M.processVehicles = processVehicles
M.deleteVehicles = deleteVehicles
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
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M