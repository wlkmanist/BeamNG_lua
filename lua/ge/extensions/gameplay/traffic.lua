-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'gameplay_parking', 'gameplay_police', 'gameplay_taxi', 'gameplay_traffic_trafficUtils', 'core_vehicleActivePooling'}

local logTag = 'traffic'

local traffic, trafficAiVehsList, trafficIdsSorted = {}, {}, {}
local mapNodes
local vehPool
local removeTraffic
local trafficVehicle = require('gameplay/traffic/vehicle')

-- const vectors --
local vecUp = vec3(0, 0, 1)
local vecY = vec3(0, 1, 0)

-- common functions --
local min = math.min
local max = math.max
local random = math.random

--------
local state = 'off'
local spawnProcess = {}
local spawnPointPos, spawnPointDirVec = vec3(), vec3()
local tempVec = vec3()
local vars, focus

local auxiliaryData = { -- additional data for traffic
  activeChanged = false, -- active state changed flag
  activeAmount = 0, -- actual active vehicle count
  queuedVehicle = 0, -- current traffic vehicle index
  dynamicSpawnDist = 0, -- dynamic respawn distance ahead for all traffic vehicles
  dynamicSpawnDir = 0, -- dynamic respawn direction bias for all traffic vehicles
  sampleTimer = 0 -- timer for sampling the current traffic conditions
}
-- dynamicSpawnDist and dynamicSpawnDir improve the quality of the perceived traffic density and direction in different areas

local debugColors = { -- used for debug mode
  black = ColorF(0, 0, 0, 1),
  white = ColorF(1, 1, 1, 1),
  green = ColorF(0.2, 1, 0.2, 1),
  red = ColorF(0.5, 0, 0, 1),
  blackAlt = ColorI(0, 0, 0, 255),
  greenAlt = ColorI(0, 64, 0, 255)
}

M.debugMode = false -- visual and logging debug mode
M.showMessages = true -- if enabled, UI messages can be automatically shown

local specialVehicleProviders = {}
local reservedVehicleCount = 0 -- total reserved vehicles appended to the spawn group
local reservedSpawnGroups = {}
local cancelledReservedSpawns = {}
local reservedSpawnSerial = 0

local function registerSpecialVehicleProvider(provider)
  if not provider.name then
    log('E', logTag, 'Special vehicle provider must have a name')
    return
  end
  for i, p in ipairs(specialVehicleProviders) do
    if p.name == provider.name then
      specialVehicleProviders[i] = provider
      return
    end
  end
  table.insert(specialVehicleProviders, provider)
end

local function unregisterSpecialVehicleProvider(name)
  for i, p in ipairs(specialVehicleProviders) do
    if p.name == name then
      table.remove(specialVehicleProviders, i)
      return
    end
  end
end

local function ensureReservedVehicles(providerName, count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  if count == 0 or reservedSpawnGroups[providerName] then return false end
  cancelledReservedSpawns[providerName] = nil

  local existing = 0
  for _, veh in pairs(traffic) do
    if veh.reserved == providerName then existing = existing + 1 end
  end
  local missing = count - existing
  if missing <= 0 then
    extensions.hook('onTrafficReservedVehiclesReady', providerName)
    return true
  end

  local spawnCount = math.min(missing, 4)
  local provider
  for _, candidate in ipairs(specialVehicleProviders) do
    if candidate.name == providerName then
      provider = candidate
      break
    end
  end
  if not provider then return false end

  local buildFn = provider.buildReservedGroup or provider.buildGroup
  local group = buildFn and buildFn(spawnCount, {}) or nil
  if not group or not group[1] then return false end
  if not core_multiSpawn then extensions.load('core_multiSpawn') end
  if not core_multiSpawn then return false end
  for index = 1, math.min(spawnCount, #group) do
    group[index] = deepcopy(group[index])
    group[index].spawnMeta = 'reserved:' .. providerName
  end

  reservedSpawnSerial = reservedSpawnSerial + 1
  local groupName =
    'autoTrafficReserve_' .. tostring(providerName) .. '_' .. tostring(reservedSpawnSerial)
  reservedSpawnGroups[providerName] = groupName
  core_multiSpawn.spawnGroup(group, spawnCount, {
    name = groupName,
    mode = 'traffic',
    gap = 20,
    randomPaints = true
  })
  return true
end

local function removeReservedVehicles(providerName)
  if reservedSpawnGroups[providerName] then
    cancelledReservedSpawns[providerName] = true
  end
  local ids = {}
  for id, veh in pairs(traffic) do
    if veh.reserved == providerName then ids[#ids + 1] = id end
  end
  for _, id in ipairs(ids) do
    local object = getObjectByID(id)
    removeTraffic(id, true)
    if object then object:delete() end
  end
  return #ids
end

-- Reserved/claimed model (two independent tags):
--   reserved = providerName  : sticky for the vehicle's whole life; it belongs to a provider's reserve.
--   claimed  = providerName  : protects a vehicle from being pooled by the traffic system, still teleports/repairs.

-- Called at the first natural teleport/recycle of a reserved and not claimed vehicle.
local function setVehToDormant(id)
  local veh = traffic[id]
  if not veh then return end
  veh.enableRespawn = false
  veh.enableAutoPooling = false
  veh.activeProbability = 0
  if vehPool then vehPool:setVeh(id, false) end
end

-- applies in-service pooling protection
local function applyClaimProtection(id, providerName)
  local veh = traffic[id]
  if not veh then return end
  veh.claimed = providerName
  veh.enableRespawn = true
  veh.enableAutoPooling = false
end

-- clears in-service pooling protection
local function releaseClaim(id)
  local veh = traffic[id]
  if not veh then return end
  veh.claimed = nil
  veh.enableAutoPooling = true
end

-- puts up to `count` dormant reserves of a provider into service and activates them. Returns the ids.
local function useReservedVehicle(providerName, count, onClaim, filter)
  count = count or 1
  local claimed = {}
  for id, veh in pairs(traffic) do
    if veh.reserved == providerName and not veh.claimed and
       (not filter or filter(id, veh)) then
      veh.activeProbability = 1
      applyClaimProtection(id, providerName)
      if onClaim then onClaim(id, veh) end
      if vehPool then vehPool:setVeh(id, true, true) end -- forceInsert: the active pool is usually full, so guarantee activation
      table.insert(claimed, id)
      --log('I', logTag, string.format('Put reserved vehicle %d into service for provider "%s"', id, providerName))
      if #claimed >= count then break end
    end
  end
  return claimed
end

-- returns in-service reserves to the dormant pool. They keep driving normally until traffic next
-- teleports/pools them out of sight, where they deactivate instead of respawning (setVehToDormant).
local function returnReservedVehicle(ids, immediate)
  if type(ids) ~= 'table' then ids = {ids} end
  for _, id in ipairs(ids) do
    if traffic[id] then
      releaseClaim(id)
      if immediate then setVehToDormant(id) end
      --log('I', logTag, string.format('Returned vehicle %d to the reserved pool', id))
    end
  end
end

local function recycleReservedVehicle(providerName, id, spawnData)
  local veh = traffic[id]
  local object = getObjectByID(id)
  if not veh or not object or veh.reserved ~= providerName or veh.claimed or
     type(spawnData) ~= 'table' or type(spawnData.config) ~= 'string' then
    return false
  end

  local model = spawnData.model or object.jbeam
  local config = spawnData.config
  if not string.endswith(config, '.pc') then
    config = string.format('vehicles/%s/%s.pc', model, config)
  end
  local options = {
    model = model,
    config = config,
    pos = vec3(object:getPosition()),
    rot = quat(0, 0, 1, 0) * quat(object:getRefNodeRotation()),
    safeSpawn = false
  }
  object:setDynDataFieldbyName('autoEnterVehicle', 0, 'false')
  spawn.setVehicleObject(object, options)

  veh = traffic[id]
  if not veh then return false end
  veh.reserved = providerName
  veh.claimed = nil
  veh:setRole('empty')
  setVehToDormant(id)
  return true
end

-- protects a non-reserved vehicle while a provider uses it (same protections as a claimed reserve)
local function protectNonReservedVehicle(id, providerName)
  applyClaimProtection(id, providerName)
end

-- removes protection from a non-reserved vehicle, returning it to normal traffic
local function unprotectNonReservedVehicle(id)
  releaseClaim(id)
end

local function getAmountFromSettings() -- gets saved or calculated amount of vehicles
  local amount = settings.getValue('trafficAmount') -- get amount from gameplay settings
  if amount == 0 then
    setMaxVehicleAmountForTraffic() -- fix traffic amount if zero
    amount = settings.getValue('trafficAmount') -- get fixed amount
  end
  return amount
end

local function getIdealSpawnAmount(amount, enforceLimit) -- gets the ideal amount of vehicles to spawn based on current world state
  if not amount or amount < 0 then
    amount = getAmountFromSettings()
  end

  local vehCount = 0
  if enforceLimit then -- if true, subtracts the current active vehicle count
    for _, veh in ipairs(getAllVehiclesByType()) do
      if veh.isParked ~= 'true' and veh:getActive() then -- ignore parked vehicles and inactive vehicles
        vehCount = vehCount + 1
      end
    end
  end

  return amount - vehCount
end

local function getState() -- returns traffic system state
  return state
end

local function getTrafficAmount(activeOnly) -- returns current amount of AI traffic (optionally only active vehicles)
  return activeOnly and min(vars.activeAmount, #trafficAiVehsList) or #trafficAiVehsList
end

local function getTrafficList() -- returns traffic list of ids
  return trafficAiVehsList
end

local function getTrafficData() -- returns the full traffic table
  return traffic
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

local function getTrafficVars()
  return vars
end

local function setFocus(mode, data) -- sets the focus point to use for checking and respawning traffic
  -- The focus system is used by the traffic and parking systems to check if vehicles should be kept active or teleported
  -- It can use the default camera, any player vehicle, or a custom transform
  focus = focus or {pos = vec3(), dirVec = vec3(), speed = 0} -- initializes here
  if not mode or mode == 'camera' then -- resets focus (default mode is camera)
    focus.mode = 'camera'
    focus.pos:set(core_camera.getPositionXYZ())
    focus.dirVec:set(core_camera.getForwardXYZ())
    focus.speed = 0 -- scales direction vector (looks ahead)
    if not mode then
      focus.auto = true -- automatically changes mode by default (e.g. player switched vehicle)
      return
    end
  end

  data = data or {}
  if mode == 'vehicle' then
    focus.mode = 'vehicle'
    focus.vehId = data.vehId or be:getPlayerVehicleID(0)
  elseif mode == 'custom' then
    focus.mode = 'custom'
    focus.pos:set(data.pos)
    focus.dirVec:set(data.dir)
    focus.speed = data.speed
  end

  if data.auto ~= nil then
    focus.auto = data.auto -- if true, mode automatically changes, for example if the player vehicle is switched
  end
end
setFocus()

local function getFocus() -- returns the focus point
  if not focus then setFocus() end -- just in case
  return focus
end

local function getNextSpawnPoint(id, spawnData, placeData) -- sets the new spawn point of a vehicle
  --[[
  ---- TRAFFIC SPAWNING THEORY ----
  This assumes that the current method of running a constant amount of active vehicles is true.
  Vehicles will try to respawn along a route ahead of the focus point (usually the player). If this fails, an alternative radial search will be done.
  The goal is to try to have somewhat realistic traffic density for the current road and area.
  For roads that have a lower count of connected branches in the area: Spawn point distance can be increased, to reduce traffic density.
  For roads that have a lower drivability: Spawn point can randomly be ignored, and the vehicle will be spawned on an outer road.
  Note: Narrow roads get a forced drivability reduction applied to them, to discourage spawning.
  ]]--

  if id and getObjectByID(id) then
    if not spawnData then
      local spawnValue = traffic[id] and traffic[id].respawn.spawnValue or 1
      if spawnValue > 0 then -- respawning is enabled
        spawnValue = clamp(spawnValue, 0.05, 5)
        spawnPointPos:set(focus.pos)
        spawnPointDirVec:set(focus.dirVec)

        local distCoef = 1 / linearScale(spawnValue, 1, 5, 1, 9)
        local addedDist = min(120, square(focus.speed * lerp(0.09, 0.15, distCoef))) -- affects spawn point distance and deviation
        addedDist = addedDist + random() * auxiliaryData.dynamicSpawnDist * distCoef -- distance ahead plus distance scattering

        local reverseProb = focus.speed < 5 and 0.3 or 0 -- player is stationary or slow (includes walking)
        if reverseProb > 0 and random() < reverseProb then -- if condition met, search for a spawn point behind the focus point
          spawnPointDirVec:setScaled(-1)
          addedDist = 0
        end

        distCoef = min(4, 2 + auxiliaryData.activeAmount * 0.4) -- lower max distance coefficient for fewer vehicles

        local baseValue = clamp(50 + 50 / spawnValue, 50, 400) -- base value to use for initial distance
        local minDist = baseValue + addedDist -- spawn search initial distance
        local maxDist = clamp(minDist * distCoef, 200, 1600) -- spawn search final distance
        local targetDist = clamp(lerp(minDist, maxDist, 0.5), 120, 500) -- spawn search visible distance (static raycast, with distance limit to save on performance)
        local spawnRandomValue = traffic[id] and traffic[id].respawn.spawnRandomization or 1 -- spawn search scatter randomness
        local lateralDist = spawnRandomValue * clamp(auxiliaryData.activeAmount * 1.5, 10, 20) -- side offset (scales with traffic amount)

        if lateralDist ~= 0 then -- adjacent roads may be used with lateral offset to start position
          tempVec:setCross(spawnPointDirVec, vecUp)
          tempVec:setScaled(lerp(-lateralDist, lateralDist, random()))
          spawnPointPos:setAdd(tempVec)
        end

        local params = {}
        params.gapSpeedCoef = 1.08 -- speed limit based gap coefficient
        params.gapVehCoef = 3 -- vehicle conflict based gap coefficient
        params.pathRandomization = clamp((80 - focus.speed) / 80, 0, spawnRandomValue) -- pathfinder randomization (inversely scales with speed)

        --local minDrivability = 0.5
        --if traffic[id] and traffic[id].drivability then
          --minDrivability = traffic[id].drivability
        --end
        -- roads with a drivability < 1 will have a much lower chance of being usable (minimum is 0.3)
        -- stronger probability curve with more vehicles
        -- weaker probability curve with fewer vehicles (encourages spawning on lesser roads)
        local power = clamp(math.floor(math.log10(auxiliaryData.activeAmount) * 4), 1, 10) -- power affects the probability curve
        params.minDrivability = clamp(1 - math.pow(random(), power) * 0.7, 0.5, 1) -- minimum drivability is 0.5 (ideally smooth dirt roads)

        spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(spawnPointPos, spawnPointDirVec, minDist, maxDist, targetDist, params)
      end
    end
  end

  if spawnData then
    if not placeData then
      local roadDir = traffic[id] and traffic[id].respawn.spawnDirBias or 0
      if math.abs(roadDir) < 0.6 and (focus.speed < 5 or focus.dirVec:dot(tempVec) < 0) then
        roadDir = 0.6 -- vehicles respawning behind you should mostly drive towards you
      else
        if math.abs(auxiliaryData.dynamicSpawnDir) > math.abs(roadDir) then
          roadDir = auxiliaryData.dynamicSpawnDir -- smart direction scattering
        end
      end
      roadDir = roadDir > random() * 2 - 1 and -1 or 1 -- randomized result: negative = away from you, positive = towards you
      placeData = {roadDir = roadDir}
    end
    placeData.legalDirection = true

    local pos, dir = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, placeData)
    local normal = map.surfaceNormal(pos, 1)
    local rot = quatFromDir(vecY:rotated(quatFromDir(dir, normal)), normal)

    if traffic[id] and spawnData.n1 and spawnData.n2 then
      -- speed boost after respawning
      if traffic[id].hasTrailer then
        traffic[id].respawnSpeed = -1 -- this seems to help with attaching trailer
      else
        local link = mapNodes[spawnData.n1].links[spawnData.n2] or mapNodes[spawnData.n2].links[spawnData.n1]
        if link then
          local nearIntersection = map.getNodeLinkCount(spawnData.n2) > 2 and pos:squaredDistance(mapNodes[spawnData.n2].pos) < 400
          traffic[id].respawnSpeed = clamp(max(dir:dot(vecUp) * 25, (link.speedLimit - 8.333) * 0.5), 1.389, nearIntersection and 1.389 or 13.889) -- thruster speed boost
        end
      end
    end

    return pos, rot
  end
end

local function respawnVehicle(id, pos, rot, strict) -- moves the vehicle to a new position and rotation (intended for traffic vehicles)
  local obj = id and getObjectByID(id)
  if not obj or not pos or not rot then return end

  if not strict then
    spawn.safeTeleport(obj, pos, rot, true, nil, false) -- this is slower, but prevents vehicles from spawning inside static geometry
  else
    rot = rot * quat(0, 0, 1, 0)
    obj:setPositionRotation(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
    obj:autoplace(false)
    obj:resetBrokenFlexMesh()
  end

  if traffic[id] then
    traffic[id].pos = vec3(pos) -- instantly updates the position this frame
    traffic[id]._teleport = nil
    traffic[id]:onRespawn()
  end
end

local function forceTeleport(id, pos, dir, minDist, maxDist, targetDist) -- force teleports a traffic vehicle
  if not vars.enableRespawn then return end
  if traffic[id] and traffic[id].ignoreForceTeleport then return end
  if traffic[id] and traffic[id].reserved and not traffic[id].claimed then -- a returned reserve: park it dormant instead of teleporting
    setVehToDormant(id)
    return
  end

  local vehObj = getObjectByID(id)
  if vehObj and vehObj:getActive() then
    mapNodes = map.getMap().nodes

    pos = pos or core_camera.getPosition()
    dir = dir or core_camera.getForward()
    minDist = minDist or 100
    maxDist = maxDist or 500
    targetDist = targetDist or min(minDist * 2, lerp(minDist, maxDist, 0.5))

    local options = {}
    if traffic[id] and traffic[id]._teleport == 'near' then
      minDist = focus.speed
      targetDist = 0
      options.minDrivability = 0.4 + random() * 0.6 -- discourages low drivability roads for this mode
    end

    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(pos, dir, minDist, maxDist, targetDist, options)
    local newPos, newRot = gameplay_traffic_trafficUtils.finalizeSpawnPoint(spawnData.pos, spawnData.dir, spawnData.n1, spawnData.n2, {legalDirection = true})
    newRot = quatFromDir(newRot, map.surfaceNormal(newPos))
    respawnVehicle(id, newPos, newRot)
  end
end

local function scatterTraffic(vehIds, minDist, maxDist) -- teleports a group of vehicles away from the current place
  vehIds = vehIds or trafficAiVehsList -- all AI-controlled traffic by default
  for _, id in ipairs(vehIds) do
    forceTeleport(id, nil, nil, minDist, maxDist)
  end
end

local function setRandomPlates(vehIds, probability) -- randomly sets special vanity plates for a list of vehicles
  -- currently might fail if input or target charset doesn't match
  probability = probability or 0.1
  vehIds = vehIds or trafficAiVehsList
  local vanityPlates = {}

  for _, path in ipairs(FS:findFiles('settings/', '*.vanityplates.json', -1, true, false)) do
    local data = jsonReadFile(path) or {}
    if data.data then -- and data.locale == 'default' then
      arrayConcat(vanityPlates, data.data)
    end
  end

  if tableIsEmpty(vanityPlates) then return end
  arrayShuffle(vanityPlates)

  for _, id in ipairs(vehIds) do
    if random() <= probability and vanityPlates[1] then
      core_vehicles.setPlateText(vanityPlates[1], id)
      table.remove(vanityPlates, 1)
    end
  end
end

local function updateActiveAmount() -- updates the active amount of vehicles
  local activeCount = 0
  for id, veh in pairs(traffic) do
    if veh.isAi and be:getObjectActive(id) then
      activeCount = activeCount + 1
    end
  end

  if auxiliaryData.activeAmount ~= activeCount then
    extensions.hook('onTrafficAmountChanged', activeCount, auxiliaryData.activeAmount) -- current and previous amounts
    auxiliaryData.activeAmount = activeCount
  end

  auxiliaryData.activeChanged = false -- resets previously set flag
end

local function createTrafficPool(idList) -- sets the main traffic vehicle pooling object
  -- this manages the active and inactive simulation states of the vehicles, as well as enforcing a maximum amount of active vehicles at any point in time
  if not core_vehicleActivePooling then extensions.load('core_vehicleActivePooling') end
  vehPool = core_vehicleActivePooling.createPool({name = 'autoTraffic'})

  if idList then
    for _, id in ipairs(idList) do
      vehPool:insertVeh(id)
    end
  end
end

local function deleteTrafficPool() -- deletes the traffic pool and resets variables
  if vehPool then
    vehPool:deletePool(true)
    vehPool = nil
  end
end

local function updateTrafficPool() -- updates the main traffic vehicle pooling object
  if not vehPool then return end
  -- bump the active ceiling by the number of active reserved vehicles to avoid pooling other vehicles.
  local inServiceReserveCount = 0
  for _, veh in pairs(traffic) do
    if veh.reserved and veh.claimed then inServiceReserveCount = inServiceReserveCount + 1 end
  end
  vehPool:setMaxActiveAmount(vars.activeAmount + inServiceReserveCount)
  vehPool:setAllVehs(true)
  -- re-deactivate dormant reserves the pool may have activated by setAllVehs above.
  for id, veh in pairs(traffic) do
    if veh.reserved and not veh.claimed and not veh.enableRespawn then
      vehPool:setVeh(id, false)
    end
  end
  updateActiveAmount()
end

local function getNextVehFromPool() -- returns the next usable inactive vehicle, or nil if none found
  if vehPool then
    local pool = vehPool
    if vehPool.prevPoolId and core_vehicleActivePooling.getPoolById(vehPool.prevPoolId) then -- alternate vehicle pool for cycling (currently unused)
      pool = core_vehicleActivePooling.getPoolById(vehPool.prevPoolId)
    end

    for _, id in ipairs(pool.inactiveVehs) do
      if traffic[id] and not (traffic[id].reserved and not traffic[id].claimed) then -- dormant reserves are only woken by useReservedVehicle
        local activeProbability = traffic[id].enableRespawn and traffic[id].activeProbability or 0
        if activeProbability >= random() then -- vehicles are less likely to get activated if they have a lower probability value
          return id
        end
      end
    end
  end
end

local function processNextSpawn(id, ignorePool) -- processes the next vehicle respawn action
  if not next(map.getMap().nodes) then return end
  if traffic[id] and traffic[id].reserved and not traffic[id].claimed then -- a returned reserve: park it dormant instead of respawning
    setVehToDormant(id)
    return
  end
  if not vars.enableRespawn then
    if traffic[id].state ~= 'active' then
      traffic[id]:onRefresh() -- refreshes the vehicle in place
      return
    end
  end

  local newPos, newRot
  local oldId, newId = id, id
  local tempId

  if not ignorePool and traffic[id].enableAutoPooling then
    tempId = getNextVehFromPool()
    if tempId then
      if #vehPool.activeVehs < vehPool.maxActiveAmount then -- amount of active vehicles is less than the expected limit
        newId = tempId
      else
        oldId, newId = vehPool:crossCycle(vehPool.prevPoolId, oldId, tempId) -- cycles the pool; if a previous pool exists, use a vehicle from there
      end
    end
  end

  newPos, newRot = getNextSpawnPoint(newId)
  local veh = traffic[newId]
  if newPos then
    vehPool:setVeh(newId, true)
    respawnVehicle(newId, newPos, newRot)
  else
    if not tempId then
      veh:onRefresh() -- refreshes the vehicle in place (only if it didn't get cycled)
    else
      vehPool:setVeh(newId, true)
      forceTeleport(newId, nil, -focus.dirVec) -- force teleports the vehicle behind the player view (not an ideal solution)
    end
  end
end

local function refreshVehicles() -- resets core traffic vehicle data
  for _, veh in pairs(traffic) do
    veh:onRefresh()
  end
end

local function resetTrafficVars() -- resets traffic variables to default
  vars = {
    spawnValue = 1, -- traffic respawn frequency (from 0 to 3)
    spawnDirBias = 0.2, -- traffic respawn direction bias (from -1 to 1, negative is away from you, positive is towards you)
    activeAmount = math.huge, -- number of active (visible) vehicles at a time
    baseAggression = 0.35, -- old default: 0.3
    speedLimit = -1, -- global speed limit; overrides road speed limits
    aiMode = 'traffic',
    aiAware = 'auto',
    aiDebug = 'off',
    enableRespawn = true, -- master respawn state; if false, disables all methods of respawning vehicles
    enableRandomEvents = false -- enables events such as police randomly chasing AI suspects
  }

  refreshVehicles()
end
resetTrafficVars()

local function setTrafficVars(data, reset) -- sets various traffic variables
  if reset then resetTrafficVars() end
  if type(data) ~= 'table' then return end

  for k, v in pairs(data) do
    if k == 'aiMode' or k == 'aiDebug' or k == 'aiAware' then
      data[k] = type(v) == 'string' and string.lower(v) or v
    end
  end

  vars = tableMerge(vars, data)

  for _, id in ipairs(trafficAiVehsList) do
    local veh = traffic[id]

    if veh then
      if data.aiMode then
        veh:setAiMode(data.aiMode)
      end
      if data.aiAware or data.speedLimit or data.baseAggression then
        veh:setAiParameters(data)
      end
      if data.spawnValue then
        veh.respawn.spawnValue = data.spawnValue
        auxiliaryData.dynamicSpawnDist = 0 -- resets distance scattering
      end
      if data.spawnDirBias then
        veh.respawn.spawnDirBias = data.spawnDirBias
        auxiliaryData.dynamicSpawnDir = 0 -- resets direction scattering
      end

      if data.aiMode then
        -- here is special logic that sets or unsets roles if a different AI mode is set
        -- in other words, this enables modes such as 'flee' or 'chase' to work seamlessly for all vehicles
        if data.aiMode == 'traffic' and veh.roleName == 'empty' then
          veh:setRole(veh._tempRole) -- restores the previous role (or auto role if no previous role was set)
          veh._tempRole = nil
        elseif data.aiMode ~= 'traffic' and veh.roleName ~= 'empty' then
          veh._tempRole = veh.roleName
          veh:setRole('empty') -- prevents role logic from changing AI mode internally
        end
      end
    end
  end

  if data.aiDebug then
    M.debugMode = data.aiDebug == 'traffic'
    gameplay_traffic_trafficUtils.debugMode = M.debugMode
    refreshVehicles()
  end
  if data.activeAmount and vehPool and state == 'on' then -- state needs to be on (not loading) for this to work
    updateTrafficPool()
  end
end

local function setDebugMode(value) -- sets the module debug mode
  value = value and 'traffic' or 'off'
  setTrafficVars({aiDebug = value})
end

local function setActiveAmount(amount) -- sets the maximum amount of active (visible) vehicles
  amount = amount or math.huge
  setTrafficVars({activeAmount = amount})
end

local function insertTraffic(id, ignoreAi, ignoreVehPool) -- inserts a new vehicle into the traffic table
  -- ignoreAi prevents AI and respawn logic from getting applied to the given vehicle
  -- ignoreVehPool prevents the vehicle from becoming deactivated due to the vehicle pooling system (maybe needs another way to handle this)
  local obj = getObjectByID(id)

  if obj and not traffic[id] then
    traffic[id] = trafficVehicle({id = id})
    if not traffic[id] then -- traffic vehicle object creation failed
      return
    end

    if not ignoreAi then
      table.insert(trafficAiVehsList, id)
      gameplay_walk.addVehicleToBlacklist(id)

      obj:setDynDataFieldbyName('isTraffic', 0, 'true') -- this can be used by other systems to quickly check if this vehicle is only meant for traffic
      obj.playerUsable = settings.getValue('trafficEnableSwitching') and true or false

      if not vehPool then
        createTrafficPool()
      end
      if not ignoreVehPool then
        vehPool:insertVeh(id)
      end

      traffic[id]:setAiMode(obj.aiMode or vars.aiMode) -- object ai mode can overwrite traffic default ai mode
    end

    local meta = obj:getDynDataFieldbyName('spawnMeta', 0)
    if meta then
      local providerName = meta:match('^reserved:(.+)')
      if providerName then
        traffic[id].reserved = providerName
        if not traffic[id].claimed then
          traffic[id].enableRespawn = false
          traffic[id].enableAutoPooling = false
          traffic[id].activeProbability = 0
        end
      end
    end

    trafficIdsSorted = tableKeysSorted(traffic)
    auxiliaryData.activeChanged = true
    extensions.hook('onTrafficVehicleAdded', id)
  end
end

removeTraffic = function(id, stopAi) -- remove a vehicle from the traffic table
  if traffic[id] then
    local obj = getObjectByID(id)
    local idx = arrayFindValueIndex(trafficAiVehsList, id)
    if idx then table.remove(trafficAiVehsList, idx) end

    if obj then
      traffic[id].role:resetAction()
      obj:setMeshAlpha(1, '')
      obj.playerUsable = true
      obj.uiState = 1

      if stopAi and traffic[id].isAi then
        obj:queueLuaCommand('ai.setMode("stop")')
      end
      if vehPool then
        vehPool:removeVeh(id)
      end
    end

    traffic[id] = nil
    trafficIdsSorted = tableKeysSorted(traffic)
    auxiliaryData.activeChanged = true
    extensions.hook('onTrafficVehicleRemoved', id)
  end
end

local function checkPlayer(id) -- checks if the player data needs to be inserted
  -- the player vehicle should ideally be included in the traffic table at all times
  if state == 'on' then
    local obj = getObjectByID(id)

    if obj and obj:isPlayerControlled() and not obj.ignoreTraffic then
      if traffic[id] then
        if traffic[id].alpha ~= 1 then -- if vehicle was invisible, show it
          obj:setMeshAlpha(1, '')
          traffic[id].alpha = 1
        end
      else
        insertTraffic(id, true)
      end
      if focus.auto then
        setFocus('vehicle', {vehId = id}) -- updates the focus data with the new id
      end
    end
  end
end

local function onVehicleSpawned(id)
  if traffic[id] then -- if vehicle is replaced, update its traffic role and properties
    traffic[id]:applyModelConfigData()
    traffic[id]:setRole(traffic[id].autoRole)
    traffic[id]:resetAll()
  end
  if spawnProcess.watchdogTimer then spawnProcess.watchdogTimer = 0 end -- spawn progress resets the completion watchdog
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleSwitched(oldId, newId)
  checkPlayer(newId)
end

local function onVehicleResetted(id)
  checkPlayer(id)
  if traffic[id] then
    traffic[id]:onVehicleResetted()
  end
end

local spawnWatchdogTimeout = 8 -- seconds of no progress before the spawn watchdog force-finishes, so the traffic spawn loading screen can never get permanently stuck

local function finishTrafficSpawn() -- completes the traffic spawn process, dismissing the loading screen if one was shown
  if spawnProcess.waitForUi then
    guihooks.trigger('app:waiting', false)
    guihooks.trigger('QuickAccessMenu')
  end
  table.clear(spawnProcess)
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleDestroyed(id)
  if spawnProcess.pendingIds and spawnProcess.pendingIds[id] then -- a vehicle we were waiting on got deleted; stop waiting on it
    spawnProcess.pendingIds[id] = nil
    spawnProcess.pendingCount = spawnProcess.pendingCount - 1
    if spawnProcess.pendingCount <= 0 then
      finishTrafficSpawn()
    end
  end

  removeTraffic(id)
  if vehPool then vehPool._updateFlag = true end
end

local function onVehicleActiveChanged(vehId, active)
  if traffic[vehId] and traffic[vehId].isAi then
    if not active then
      traffic[vehId].alpha = 0
      getObjectByID(vehId):setMeshAlpha(0, '')
      if not traffic[vehId]._teleport then
        traffic[vehId]._teleport = 'default'
      end
    else
      if traffic[vehId]._teleport then -- force teleport if flag exists
        if gameplay_traffic_trafficUtils.checkSpawnPoint(traffic[vehId].pos) then -- if current position is safe, then no teleport needed
          traffic[vehId]:onRefresh()
        else
          forceTeleport(vehId)
        end
      end
    end
  end
end

local function deleteVehicles() -- deletes all traffic vehicles
  for _, veh in ipairs(getAllVehiclesByType()) do
    local id = veh:getId()
    if traffic[id] and (traffic[id].isAi or veh.isTraffic == 'true') then
      removeTraffic(id)
      veh:delete()
    end
  end
end

local function activate(vehList) -- activates traffic mode, and adds specified vehicles to the traffic table
  if type(vehList) ~= 'table' then -- for backwards compatibility
    vehList = {}

    -- NOTE: If vehList is empty, all vehicles get activated, even unintended ones; this may need to be reconsidered in the future
    for _, veh in ipairs(getAllVehiclesByType()) do
      if not veh.isParked then
        table.insert(vehList, veh:getId())
      end
    end
  end

  if not vehList[1] then
    return
  end

  table.sort(vehList, function(a, b) return a < b end)

  for _, id in ipairs(vehList) do
    if type(id) == 'number' then
      map.request(id, -1) -- force mapmgr to read map (performance optimization)
      insertTraffic(id, getObjectByID(id):isPlayerControlled())
    end
  end
end

local function deactivate(stopAi) -- deactivates traffic mode for all vehicles
  for _, id in ipairs(tableKeysSorted(traffic)) do
    removeTraffic(id, stopAi)
  end
end

local function spawnTraffic(amount, groupData, options) -- spawns and processes a group array of vehicles to use as traffic
  amount = amount or max(1, getAmountFromSettings() - #getAllVehiclesByType()) -- if amount nil, automatically sets a limited amount to save performance
  groupData = groupData or core_multiSpawn.createGroup(amount)
  options = type(options) == 'table' and options or {}
  state = 'spawning'

  return core_multiSpawn.spawnGroup(groupData, amount, {name = 'autoTraffic', mode = options.mode or 'traffic', gap = options.gap or 20,
  pos = options.pos, dir = options.dir, randomPaints = true})
end

local function setupTraffic(amount, options) -- prepares a group of vehicles for traffic
  amount = amount or -1
  options = type(options) == 'table' and options or {}

  local trafficGroup
  local activeAmount = options.activeAmount or amount

  if not options.keepCurrent then
    deleteVehicles() -- clear current traffic
  end

  if type(options.vehGroup) == 'table' then -- directly sets a vehicle group to be used for traffic; may overwrite other parameters
    trafficGroup = options.vehGroup
    log('I', logTag, 'Applying custom traffic group')
  end

  if amount == -1 then -- auto amount
    local amountFromSettings = getAmountFromSettings()
    amount = getIdealSpawnAmount(amountFromSettings) -- maxAmount automatically accounts for currently spawned non-traffic vehicles
    activeAmount = amount

    if settings.getValue('trafficExtraVehicles') then
      amount = amount + max(0, settings.getValue('trafficExtraAmount')) -- extra traffic vehicles that will be pooled (NEW: ignores old -1 flag value)
    end
  else
    if options.autoAdjustAmount then
      amount = getIdealSpawnAmount(amount) -- adjust for amount of existing active vehicles
    end
  end

  if not trafficGroup then -- if predefined vehicle group does not exist, create it
    if amount >= 1 then
      if not trafficGroup then
        local fileData, fileName
        local fileMode = options.autoLoadFromFile and not (settings.getValue('trafficSimpleVehicles') or options.simpleVehs)
        if fileMode then
          fileData, fileName = gameplay_traffic_trafficUtils.getTrafficGroupFromFile({name = 'traffic'}) -- level specific civilian vehicles
          if fileData then
            fileData = core_multiSpawn.fitGroup(fileData, amount)
            log('I', logTag, string.format('Loaded traffic group from file: %s', fileName or ''))
          end
        end

        trafficGroup = fileData or gameplay_traffic_trafficUtils.createTrafficGroup(amount, options.allMods, options.allConfigs, options.simpleVehs)
      end
      if not trafficGroup[1] then
        for i = 1, amount do
          table.insert(trafficGroup, {model = 'pickup'}) -- default traffic vehicle
        end
      end

      extensions.hook('onTrafficSpecialVehiclesProviders')

      -- allocate special vehicle slots from providers
      local maxSpecialRatio = 0.4
      local maxSpecial = math.floor(amount * maxSpecialRatio)
      local budgetRemaining = maxSpecial

      local sorted = {}
      for _, p in ipairs(specialVehicleProviders) do table.insert(sorted, p) end
      table.sort(sorted, function(a, b) return (a.priority or 0) > (b.priority or 0) end)

      reservedVehicleCount = 0

      for _, provider in ipairs(sorted) do
        if amount >= (provider.minTotalAmount or 0) and (provider.guaranteed or budgetRemaining > 0) then
          local guaranteed = provider.guaranteed or 0
          local desired = provider.getDesiredCount and provider.getDesiredCount(amount, options) or guaranteed
          if desired and desired > 0 then
            local allocated = guaranteed + min(max(desired - guaranteed, 0), budgetRemaining)
            local group = provider.buildGroup(allocated, options)
            if group then
              local injected = 0
              for i = 1, min(allocated, #group) do
                if group[i] and #trafficGroup > 0 then
                  table.insert(trafficGroup, 1, group[i])
                  table.remove(trafficGroup, #trafficGroup)
                  injected = injected + 1
                end
              end
              budgetRemaining = budgetRemaining - max(injected - guaranteed, 0)
              log('I', logTag, string.format('Special vehicle provider "%s": requested %d, allocated %d', provider.name, desired, injected))
            end
          end
        end

        -- append reserved vehicles as extra (not replacing regular traffic)
        local reserved = provider.reserved or 0
        if reservedSpawnGroups[provider.name] then
          reserved = 0
        else
          for _, veh in pairs(traffic) do
            if veh.reserved == provider.name then reserved = math.max(0, reserved - 1) end
          end
        end
        if reserved > 0 then
          local buildFn = provider.buildReservedGroup or provider.buildGroup
          local group = buildFn(reserved, options)
          if group then
            for i = 1, min(reserved, #group) do
              if group[i] then
                local entry = deepcopy(group[i])
                entry.spawnMeta = 'reserved:' .. provider.name
                table.insert(trafficGroup, entry)
                reservedVehicleCount = reservedVehicleCount + 1
              end
            end
            log('I', logTag, string.format('Special vehicle provider "%s": reserved %d vehicles', provider.name, min(reserved, #group)))
          end
        end
      end
    end
  end

  if amount > 0 and trafficGroup and trafficGroup[1] then
    spawnProcess.trafficGroup = trafficGroup
    spawnProcess.trafficAmount = amount + reservedVehicleCount
    spawnProcess.reservedVehicleCount = reservedVehicleCount

    local multiSpawnOptions = {}
    multiSpawnOptions.pos = options.pos
    multiSpawnOptions.rot = options.rot
    if next(multiSpawnOptions) then spawnProcess.multiSpawnOptions = multiSpawnOptions end

    state = 'loading'

    setTrafficVars({aiMode = 'traffic', activeAmount = activeAmount})
    if focus.auto and be:getPlayerVehicleID(0) ~= -1 then
      setFocus('vehicle', {vehId = be:getPlayerVehicleID(0)})
    end
  else
    if amount <= 0 then
      log('I', logTag, 'Traffic amount to spawn is zero, now ignoring traffic')
    else
      log('I', logTag, 'Traffic vehicle group is empty')
    end
    --ui_message('ui.traffic.spawnLimit', 5, 'traffic', 'traffic')
    return false
  end

  return true
end

local function setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, parkingOptions, extraOptions) -- helps with setting up traffic and/or parking at the same time
  -- use M.onTrafficOrParkingReady to listen for when traffic and/or parking is ready
  trafficAmount = trafficAmount or 0
  parkingAmount = parkingAmount or 0

  spawnProcess.parkingSetup = gameplay_parking.setupVehicles(parkingAmount, parkingOptions) -- spawn parked vehicles first, if applicable
  spawnProcess.trafficSetup = gameplay_traffic.setupTraffic(trafficAmount, trafficOptions) -- then spawn traffic

  if not spawnProcess.trafficSetup and not spawnProcess.parkingSetup then -- there's nothing to spawn...
    table.clear(spawnProcess)
    extensions.hook('onTrafficOrParkingReady')
  else
    spawnProcess.vehGroups = {autoTraffic = spawnProcess.trafficSetup and 1 or nil, autoParking = spawnProcess.parkingSetup and 1 or nil} -- multispawn queue
  end

  return spawnProcess.trafficSetup, spawnProcess.parkingSetup
end

local function setupTrafficWaitForUi(useTraffic, useParked, options) -- this is called from the pause menu and displays a loading screen
  options = type(options) == 'table' and options or {}
  spawnProcess.trafficAmount = useTraffic and -1 or 0
  spawnProcess.parkingAmount = useParked and -1 or 0
  spawnProcess.trafficOptions = options
  spawnProcess.waitForUi = true
  spawnProcess.watchdogTimer = 0 -- start the safety watchdog as soon as the loading screen is shown
  setTrafficVars({aiMode = 'traffic', enableRandomEvents = true})

  if useTraffic and not settings.getValue('trafficParkedVehicles') then
    spawnProcess.parkingAmount = 0
  end

  guihooks.trigger('app:waiting', true) -- shows the loading icon
end

local function setupCustomTraffic(amount, params) -- spawns a group of vehicles for traffic, with custom parameters
  if type(params) ~= 'table' then params = {} end
  if not amount or amount < 0 then amount = getAmountFromSettings() end

  spawnTraffic(amount, core_multiSpawn.createGroup(amount, params))
end

-- spawns and de-spawns traffic vehicles in freeroam
-- keepInMemory allows instantenous reactivation at the expense of RAM consumption when traffic is disabled
local function toggle(keepInMemory)
  if core_gamestate.state.state == 'freeroam' and not core_input_actionFilter.isActionBlocked('toggleTraffic') then
    if state == 'off' then
      setupTraffic()
    elseif state == 'on' then
      if keepInMemory then
        if vars.activeAmount == 0 then
          vars.activeAmount = vars.prevActiveAmount or getAmountFromSettings()
          updateTrafficPool()
        else
          vars.prevActiveAmount = vars.activeAmount
          if vars.prevActiveAmount <= 0 then vars.prevActiveAmount = getAmountFromSettings() end
          vars.activeAmount = 0

          for id, veh in pairs(traffic) do
            veh._teleport = 'near'
          end
          updateTrafficPool()
        end
      else
        deleteVehicles()
      end
    end
  end
end

local function freezeState(options) -- stops the traffic, police, and parking systems, and returns the state data
  local trafficData = M.onSerialize(options)
  local policeData = gameplay_police.onSerialize()
  local parkingData = gameplay_parking.onSerialize(options)
  return trafficData, policeData, parkingData
end

local function unfreezeState(trafficData, policeData, parkingData, options) -- reverts the traffic and parking systems
  if not trafficData and not parkingData then
    log('I', logTag, 'No traffic or parking data found, now ignoring traffic')
    return
  end
  if trafficData then
    M.onDeserialized(trafficData, options)
    scatterTraffic()
  end
  if policeData then
    gameplay_police.onDeserialized(policeData)
  end
  if parkingData then
    gameplay_parking.onDeserialized(parkingData, options)
  end
end

local function doTraffic(dt, dtSim) -- active traffic logic
  if not vehPool then
    createTrafficPool(trafficAiVehsList)
  end

  local vehCount = 0
  local aiVehsListSize = #trafficAiVehsList
  for i, id in ipairs(trafficIdsSorted) do -- ensures consistent order of vehicles
    vehCount = vehCount + 1
    local veh = traffic[id]
    if veh then
      veh:onUpdate(dt, dtSim)

      if veh.isAi and be:getObjectActive(id) then
        if veh.state == 'reset' then
          veh:onRefresh()

          if vars.enableRandomEvents and vars.aiMode == 'traffic' and veh.respawnCount > 0 then
            veh.role:tryRandomEvent()
          end
        end

        if i == auxiliaryData.queuedVehicle then -- checks one vehicle per frame, as an optimization
          if veh._teleport then
            forceTeleport(id)
          else
            if veh.state == 'active' then
              veh:tryRespawn(aiVehsListSize)
            elseif veh.state == 'queued' then
              processNextSpawn(id)
            end
          end

          veh.otherCollisionFlag = nil -- resets collision flag from previous frame(s)
        end
      end
    end
  end

  auxiliaryData.queuedVehicle = auxiliaryData.queuedVehicle + 1
  if auxiliaryData.queuedVehicle > vehCount then
    auxiliaryData.queuedVehicle = 1
  end

  auxiliaryData.sampleTimer = auxiliaryData.sampleTimer + dtSim
  if auxiliaryData.sampleTimer > 5 then -- every 5 seconds, sample the current traffic conditions if there is a need to set dynamic spawn parameters
    -- adjust global respawn distance based on road network density
    local n1, n2 = map.findClosestRoad(focus.pos)
    if n1 and n2 then
      local radius = min(mapNodes[n1].radius, mapNodes[n2].radius)
      local branchNodes = map.getGraphpath():getBranchNodesAround(n1, 200) -- expected minimum of 2 nodes
      local branchNodeCount = branchNodes and #branchNodes or 20
      local maxDist = auxiliaryData.activeAmount * 50 -- stronger effect if there are more vehicles
      maxDist = maxDist * max(0.5, 6 - radius) -- radius coefficient (radius of 5 = coefficient of 1)
      auxiliaryData.dynamicSpawnDist = min(1000, maxDist / branchNodeCount) -- distance scattering is affected by radius and local road network density
      local link = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
      if link and link.oneWay then -- reduce scattering if the road might be a highway
        auxiliaryData.dynamicSpawnDist = auxiliaryData.dynamicSpawnDist * 0.25
      end
    end

    -- adjust global respawn direction based on current traffic ahead on the road
    local outboundCount = 0
    for id, veh in pairs(traffic) do
      if veh.state == 'active' then
        local dotDir = sign2(focus.dirVec:dot(veh.dirVec))
        if dotDir == 1 then
          outboundCount = outboundCount + 1
        end
      end
    end

    if auxiliaryData.activeAmount <= 2 then
      auxiliaryData.dynamicSpawnDir = 0
    else
      auxiliaryData.dynamicSpawnDir = lerp(-1, 1, outboundCount / auxiliaryData.activeAmount) -- favors opposite direction compared to the majority of vehicles
    end

    auxiliaryData.sampleTimer = 0
  end
end

local function trackAIAllVeh(mode) -- triggers when the player sets an AI mode for all vehicles
  mode = mode or 'traffic'
  setTrafficVars({aiMode = string.lower(mode)})
end

local function onVehicleMapmgrUpdate(id) -- each spawned vehicle reports here once its mapmgr is ready; complete when all pending ones have reported
  if spawnProcess.pendingIds and spawnProcess.pendingIds[id] then
    spawnProcess.pendingIds[id] = nil
    spawnProcess.pendingCount = spawnProcess.pendingCount - 1
    spawnProcess.watchdogTimer = 0 -- a vehicle reporting in counts as progress
    if spawnProcess.pendingCount <= 0 then
      finishTrafficSpawn()
    end
  end
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if groupName == 'autoParking' then
    if not spawnProcess.trafficSetup and spawnProcess.waitForUi then
      guihooks.trigger('app:waiting', false)
      guihooks.trigger('QuickAccessMenu')
    end
  end

  if groupName == 'autoTraffic' then
    spawnProcess.vehList = vehList
    setRandomPlates(vehList)
    activate(spawnProcess.vehList)

    -- deactivate all reserved vehicles
    if (spawnProcess.reservedVehicleCount or 0) > 0 and vehPool then
      for id, veh in pairs(traffic) do
        if veh.reserved and not veh.claimed then
          vehPool:setVeh(id, false)
        end
      end
    end

    -- build the set of vehicles whose mapmgr readiness we wait on before completing
    -- reserved/deactivated vehicles are excluded: their VM is dormant so they never report a mapmgr update
    local pendingIds, pendingCount = {}, 0
    for _, id in ipairs(spawnProcess.vehList) do
      if not (traffic[id] and traffic[id].reserved) then
        pendingIds[id] = true
        pendingCount = pendingCount + 1
      end
    end
    spawnProcess.pendingIds = pendingIds
    spawnProcess.pendingCount = pendingCount
    spawnProcess.watchdogTimer = 0 -- group finished spawning: reset watchdog for the mapmgr-readiness wait
  end

  for providerName, pendingGroupName in pairs(reservedSpawnGroups) do
    if groupName == pendingGroupName then
      if cancelledReservedSpawns[providerName] then
        for _, id in ipairs(vehList) do
          local object = getObjectByID(id)
          if object then object:delete() end
        end
        cancelledReservedSpawns[providerName] = nil
      else
        activate(vehList)
        for _, id in ipairs(vehList) do
          if traffic[id] and traffic[id].reserved == providerName then
            setVehToDormant(id)
          end
        end
        extensions.hook('onTrafficReservedVehiclesReady', providerName)
      end
      reservedSpawnGroups[providerName] = nil
      break
    end
  end

  if spawnProcess.vehGroups and spawnProcess.vehGroups[groupName] then -- initialized from setupTrafficHelper
    spawnProcess.vehGroups[groupName] = nil
    if not next(spawnProcess.vehGroups) then
      spawnProcess.vehGroups = nil
      extensions.hook('onTrafficOrParkingReady')

      if not spawnProcess.trafficSetup then
        table.clear(spawnProcess) -- it's ok to clear the table here
      end
    end
  end
end

local function onUpdate(dtReal, dtSim)
  if state == 'loading' then
    spawnTraffic(spawnProcess.trafficAmount, spawnProcess.trafficGroup, spawnProcess.multiSpawnOptions)
  end

  if spawnProcess.watchdogTimer then -- safety net: measures time since the last spawn progress, so a stalled spawn can't wedge the loading screen
    if spawnProcess.pendingIds and spawnProcess.pendingCount <= 0 then -- nothing active to wait on (e.g. everything spawned was reserved)
      finishTrafficSpawn()
    else
      spawnProcess.watchdogTimer = spawnProcess.watchdogTimer + dtReal
      if spawnProcess.watchdogTimer > spawnWatchdogTimeout then
        finishTrafficSpawn()
      end
    end
  end

  -- these hooks activate the frame after the first or last traffic vehicle gets inserted or removed
  -- this frame delay solves some timing issues
  if state ~= 'on' and trafficAiVehsList[1] then
    extensions.hook('onTrafficStarted')
  end
  if state == 'on' and not trafficAiVehsList[1] then
    extensions.hook('onTrafficStopped')
  end

  if state == 'on' or gameplay_parking.getState() or M.forceFocus then -- always updates focus data while traffic or parking systems are running
    if focus.mode == 'vehicle' then
      focus.vehId = focus.vehId or be:getPlayerVehicleID(0)
      if map.objects[focus.vehId] then
        focus.pos:set(map.objects[focus.vehId].pos)
        focus.dirVec:set(map.objects[focus.vehId].vel) -- uses velocity vector instead of direction vector
        focus.speed = focus.dirVec:length()
        if focus.speed < 1 then
          focus.dirVec:set(map.objects[focus.vehId].dirVec) -- uses direction vector if the vehicle is stationary
        else
          focus.dirVec:setScaled(1 / max(1e-12, focus.speed)) -- normalizes the vector
          focus.speed = min(80, focus.speed) -- limited to prevent huge values if teleported
        end
      end
    end

    local isFreeCam = commands.isFreeCamera() or core_camera.getActiveCamName() == 'path'
    if focus.mode == 'camera' or (focus.mode == 'vehicle' and focus.auto and (not map.objects[focus.vehId] or isFreeCam or focus.speed < 5)) then
      -- uses the free camera logic to keep traffic vehicles active when at low focus.speed values
      focus.pos:set(core_camera.getPositionXYZ())
      focus.dirVec:set(core_camera.getForwardXYZ())
      if isFreeCam then
        local freeCam = core_camera.getGlobalCameras().free
        local height = max(-1e6, be:getSurfaceHeightBelow(focus.pos))
        focus.speed = freeCam.velocity:length() + clamp(square(focus.pos.z - height) / 15, 0, 200)
      end
    end
  end

  if state == 'on' then
    if vehPool and vehPool._updateFlag and not spawnProcess.vehList then -- ignores update if spawn process is still running
      updateTrafficPool()
      vehPool._updateFlag = nil
    end

    if be:getEnabled() and not (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then
      doTraffic(dtReal, dtSim)
    end
  end

  if auxiliaryData.activeChanged and not spawnProcess.vehList then -- force update the active amount
    updateActiveAmount()
  end
end

local function onPreRender(dt)
  if not M.debugMode then return end

  tempVec:setAdd2(focus.pos, focus.dirVec)
  tempVec.z = tempVec.z - 1
  for id, veh in pairs(traffic) do
    if be:getObjectActive(id) then
      local lineColor = veh.camVisible and debugColors.green or debugColors.white
      local txtColor = debugColors.white
      local bgColor = veh.isPlayerControlled and debugColors.greenAlt or debugColors.blackAlt
      if veh.state == 'fadeIn' then lineColor = debugColors.red end

      if veh.debugLine then
        debugDrawer:drawLine(veh.pos, tempVec, lineColor)
      end

      if veh.debugText then
        debugDrawer:drawTextAdvanced(veh.pos, string.format('[%d]: %d m, %d km/h', veh.id, math.floor(veh.focusDist), math.floor((veh.speed or 0) * 3.6)), txtColor, true, false, bgColor)
      end
    end
  end
end

local function onTrafficStarted()
  state = 'on'
  mapNodes = map.getMap().nodes
  auxiliaryData.queuedVehicle = 0
  auxiliaryData.dynamicSpawnDist = 0
  auxiliaryData.dynamicSpawnDir = 0

  if not vehPool then
    createTrafficPool(trafficAiVehsList)
  end

  vehPool._updateFlag = true -- acts like a frame delay for the vehicle pooling system

  if vars.aiMode ~= 'traffic' then -- forces vehicles to refresh their AI modes and roles
    setTrafficVars({aiMode = vars.aiMode})
  end

  if gameplay_walk.isWalking() then -- check for player unicycle
    checkPlayer(be:getPlayerVehicleID(0))
  end
  for _, veh in ipairs(getAllVehiclesByType()) do -- check for player vehicles to insert into traffic
    checkPlayer(veh:getId())
  end

  local amount, activeAmount = getTrafficAmount(), getTrafficAmount(true)
  log('I', logTag, string.format('Traffic system started with %d active / %d total vehicles', activeAmount, amount))
  if not next(mapNodes) then
    log('I', logTag, 'Traffic is ready, but currently no road network exists; this is normal if the level just loaded')
  end
end

local function onTrafficStopped()
  deleteTrafficPool()
  table.clear(traffic)
  table.clear(trafficAiVehsList)
  state = 'off'
end

local function onClientStartMission()
end

local function onClientEndMission()
  onTrafficStopped()
  table.clear(reservedSpawnGroups)
  table.clear(cancelledReservedSpawns)
  resetTrafficVars()
  setFocus()
end

local function onUiWaitingState() -- callback for when the waiting UI is shown
  local sp = spawnProcess
  if sp.waitForUi and not sp.trafficSetup and not sp.parkingSetup then
    setupTrafficHelper(sp.trafficAmount, sp.trafficOptions, sp.parkingAmount, sp.parkingOptions)

    if not sp.trafficSetup and not sp.parkingSetup then -- if there is nothing to spawn, reset the waiting UI
      table.clear(sp)
      guihooks.trigger('app:waiting', false)
      guihooks.trigger('QuickAccessMenu')
      state = 'off'

      log('I', logTag, 'Zero traffic vehicles and parked vehicles were spawned')
      ui_message('ui.apps.traffic.notSupported', 5, 'traffic', 'traffic')
    end
  end
end

local function onSerialize(options)
  options = type(options) == 'table' and options or {}
  local trafficData = {}
  local vehicleSpawnData, vehicleSpawnOrder
  if options.despawnVehicles then
    vehicleSpawnData = {}
    vehicleSpawnOrder = {}
    if options.debugVehicleStashing then
      log('D', logTag, 'Serializing traffic vehicles for mission despawn stash')
    end
  end

  for _, veh in pairs(traffic) do
    table.insert(trafficData, veh:onSerialize())
    if vehicleSpawnData then
      local obj = getObjectByID(veh.id)
      if obj and veh.id ~= options.exceptVehicleId and (veh.isAi or obj.isTraffic == 'true') then
        if options.debugVehicleStashing then
          log('D', logTag, string.format('Capturing traffic vehicle for mission despawn stash: %d', veh.id))
        end
        vehicleSpawnData[veh.id] = getVehicleSpawnData(obj)
        table.insert(vehicleSpawnOrder, veh.id)
      elseif obj and veh.id == options.exceptVehicleId and options.debugVehicleStashing then
        log('D', logTag, string.format('Skipping mission player vehicle traffic despawn: %d', veh.id))
      end
    end
  end
  local data = {state = state, traffic = deepcopy(trafficData), vars = deepcopy(vars), vehicleSpawnData = vehicleSpawnData, vehicleSpawnOrder = vehicleSpawnOrder}
  onTrafficStopped()
  mapNodes = nil

  if vehicleSpawnOrder then
    for _, id in ipairs(vehicleSpawnOrder) do
      local obj = getObjectByID(id)
      if obj then
        if options.debugVehicleStashing then
          log('D', logTag, string.format('Deleting traffic vehicle after mission stash capture: %d', id))
        end
        obj:delete()
      end
    end
  end

  return data
end

local function onDeserialized(data, options)
  options = type(options) == 'table' and options or {}
  vars = data.vars
  local idMap = {}
  if options.respawnVehicles and data.vehicleSpawnData then
    if options.debugVehicleStashing then
      log('D', logTag, 'Respawning traffic vehicles from mission stash')
    end
    for _, oldId in ipairs(data.vehicleSpawnOrder or tableKeysSorted(data.vehicleSpawnData)) do
      local newId = spawnVehicleFromData(data.vehicleSpawnData[oldId])
      if newId then
        idMap[oldId] = newId
        if options.debugVehicleStashing then
          log('D', logTag, string.format('Respawned traffic vehicle from mission stash: oldId=%d newId=%d', oldId, newId))
        end
      else
        log('W', logTag, string.format('Unable to respawn serialized traffic vehicle: %d', oldId))
      end
    end
  end

  if data.state == 'on' then
    for _, veh in pairs(data.traffic) do
      local oldId = veh.id
      if idMap[oldId] or (veh.role and veh.role.targetId and idMap[veh.role.targetId]) or (veh.pursuit and veh.pursuit.targetId and idMap[veh.pursuit.targetId]) then
        veh = deepcopy(veh)
        veh.id = idMap[oldId] or oldId
        if veh.tracking then
          veh.tracking.vehId = veh.id
        end
        if veh.role then
          veh.role.id = veh.id
          if veh.role.targetId and idMap[veh.role.targetId] then
            veh.role.targetId = idMap[veh.role.targetId]
          end
        end
        if veh.pursuit and veh.pursuit.targetId and idMap[veh.pursuit.targetId] then
          veh.pursuit.targetId = idMap[veh.pursuit.targetId]
        end
        if veh.collisions then
          local collisions = {}
          for collisionId, collision in pairs(veh.collisions) do
            collisions[idMap[collisionId] or collisionId] = collision
          end
          veh.collisions = collisions
        end
      end
      insertTraffic(veh.id, not veh.isAi)
      if traffic[veh.id] then
        traffic[veh.id]:onDeserialized(veh)
      end
    end
    updateTrafficPool()
  end
end

-- public interface
M.spawnTraffic = spawnTraffic
M.setupTraffic = setupTraffic
M.setupTrafficHelper = setupTrafficHelper
M.setupTrafficWaitForUi = setupTrafficWaitForUi
M.setupCustomTraffic = setupCustomTraffic
M.insertTraffic = insertTraffic
M.removeTraffic = removeTraffic
M.deleteVehicles = deleteVehicles
M.activate = activate
M.deactivate = deactivate
M.toggle = toggle
M.refreshVehicles = refreshVehicles

M.getFocus = getFocus
M.setFocus = setFocus
M.respawnVehicle = respawnVehicle
M.forceTeleport = forceTeleport
M.forceTeleportAll = scatterTraffic
M.scatterTraffic = scatterTraffic
M.setDebugMode = setDebugMode
M.getTrafficVars = getTrafficVars
M.setTrafficVars = setTrafficVars
M.setActiveAmount = setActiveAmount
M.getIdealSpawnAmount = getIdealSpawnAmount

M.getState = getState
M.freezeState = freezeState
M.unfreezeState = unfreezeState
M.getNumOfTraffic = getTrafficAmount
M.getTrafficAmount = getTrafficAmount
M.getTrafficAiVehIds = getTrafficList
M.getTrafficList = getTrafficList
M.getTrafficData = getTrafficData
M.getTraffic = getTrafficData

M.onUpdate = onUpdate
M.onPreRender = onPreRender
M.trackAIAllVeh = trackAIAllVeh
M.onVehicleMapmgrUpdate = onVehicleMapmgrUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onUiWaitingState = onUiWaitingState
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.registerSpecialVehicleProvider = registerSpecialVehicleProvider
M.unregisterSpecialVehicleProvider = unregisterSpecialVehicleProvider
M.ensureReservedVehicles = ensureReservedVehicles
M.removeReservedVehicles = removeReservedVehicles
M.useReservedVehicle = useReservedVehicle
M.returnReservedVehicle = returnReservedVehicle
M.recycleReservedVehicle = recycleReservedVehicle
M.protectNonReservedVehicle = protectNonReservedVehicle
M.unprotectNonReservedVehicle = unprotectNonReservedVehicle

return M