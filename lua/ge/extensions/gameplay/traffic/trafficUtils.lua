-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- A collection of utility functions used by the traffic system

local M = {}
local logTag = 'trafficUtils'

local route = require('gameplay/route/route')()
local countryRef = {usa = 'United States', germany = 'Germany', italy = 'Italy', france = 'France', japan = 'Japan'} -- temporary country list
local rolesCache = {}
local baseValues = { -- values used in other traffic modules
  minDrivability = 0.5,
  minRadius = 1.2,
  lowDamage = 1000,
  highDamage = 30000,
  lowSpeed = 2.5
}

local aheadPos, camPos, tempPos, tempDir = vec3(), vec3(), vec3(), vec3() -- general temporary vectors
local p1, p2 = vec3(), vec3() -- map node positions

M.debugMode = false

local function getLevelInfo() -- returns the level infos
  local fileName = path.getPathLevelInfo(getCurrentLevelIdentifier() or '')
  local info = jsonReadFile(fileName)
  local country = 'default'
  local region
  if info then
    if info.country then
      country = string.split(info.country, "%w+") -- splits the translation string, if applicable
      if type(country) == 'table' and country[1] then
        country = string.lower(country[#country])
      else
        country = 'default'
      end
    end
    region = info.region
  end
  return {country = countryRef[country] or 'default', region = region}
end

local function getBaseValues() -- returns traffic utility values
  return baseValues
end

local function getBaseGroupParams() -- returns base group generation parameters
  local levelInfos = getLevelInfo()
  local groupParams = {filters = {Type = {car = 1, truck = 0.6}}, country = levelInfos.country, maxYear = 0, minPop = 50}
  if levelInfos.region and settings.getValue('trafficSmartSelections') then
    groupParams.filters.Region = {[levelInfos.region] = 1, default = 1}
  end
  return groupParams
end

local function createTrafficGroup(amount, allMods, allConfigs, simpleVehs) -- creates a traffic group with the use of some player settings
  allConfigs = true
  simpleVehs = settings.getValue('trafficSimpleVehicles')
  allMods = settings.getValue('trafficAllowMods')

  local params = getBaseGroupParams()
  params.allMods = allMods
  params.modelPopPower = settings.getValue('trafficSmartSelections') and 1 or 0
  params.configPopPower = settings.getValue('trafficSmartSelections') and 1 or 0

  if simpleVehs then
    params.allConfigs = true
    params.filters.Type = {proptraffic = 1}
    params.minPop = 0
  else
    params.allConfigs = allConfigs
    params.filters['Config Type'] = {Police = 0, other = 1} -- no police cars

    if params.allMods and params.filters.Type then
      params.filters.Type.automation = 1
      params.minPop = 0
    end
  end

  return core_multiSpawn.createGroup(amount, params)
end

local function createPoliceGroup(amount, allMods) -- creates a group of police vehicles
  allMods = settings.getValue('trafficAllowMods')

  local params = getBaseGroupParams()

  params.allMods = allMods
  params.allConfigs = true
  params.minPop = 0
  params.modelPopPower = 1
  params.configPopPower = 1

  if params.allMods and params.filters.Type then
    params.filters.Type.automation = 1
  end
  if params.country ~= 'default' then
    params.filters.Country = {[params.country] = 100, other = 0.1} -- other is 0.1 (not 0) just in case no country matches
  end
  params.filters['Config Type'] = {police = 1}

  return core_multiSpawn.createGroup(amount, params)
end

local function getTrafficGroupFromFile(options) -- returns an existing vehicle group file
  options = options or {}
  local group, fileName
  local dir = path.split(getMissionFilename()) or '/levels/'
  local files = FS:findFiles(dir, '*.vehGroup.json', 0, true, true) -- vehGroup files in the level directory
  if not files[1] or options.useCustom then
    files = FS:findFiles('/vehicleGroups/', '*.vehGroup.json', -1, true, true) -- vehGroup files in the vehicle groups directory
  end

  if options.name then -- file simple name (e.g. "traffic", "police", etc.)
    local filteredFiles = {}
    local nameStr = string.lower(options.name)
    for _, v in ipairs(files) do
      local _, fn = path.splitWithoutExt(v)
      if string.find(fn, nameStr) then
        table.insert(filteredFiles, v)
      end
    end
    files = filteredFiles
  end

  if files[1] then
    fileName = files[math.random(#files)] -- if multiple files exist, select one randomly
    group = jsonReadFile(fileName)
    if group then
      group = group.data -- assumes that group data exists (might fail!)
    end
  end

  return group, fileName
end

local function getDefaultSpawnParams(startPos, startDir, minDist, maxDist, targetDist) -- returns safe default values, to use with other methods
  startPos = startPos or core_camera.getPosition()
  startDir = startDir or core_camera.getForward()
  minDist = minDist or 20 -- minimum distance from start position
  maxDist = maxDist or 2000 -- maximum distance from start position
  targetDist = targetDist and math.min(targetDist, maxDist) or 0 -- ideal distance (max distance to use visibility raycasts for)
  startDir.z = 0

  return startPos, startDir, minDist, maxDist, targetDist
end

local function getRoleConstructor(roleName) -- gets the role constructor module
  if not rolesCache[roleName] then
    if not FS:fileExists('/lua/ge/extensions/gameplay/traffic/roles/'..roleName..'.lua') then
      log('W', logTag, 'Traffic role does not exist: '..roleName)
      roleName = 'standard'
    end
    rolesCache[roleName] = require('/lua/ge/extensions/gameplay/traffic/roles/'..roleName) -- caches the role constructor
  end
  return rolesCache[roleName]
end

local function getAheadPos(pos, dir, scale, useZ0) -- returns a position ahead of the given position, direction, and scale
  -- this is generally used to check distances between non-player vehicles and traffic vehicles, at a low performance cost
  if scale == 0 then return pos end

  aheadPos:set(pos)
  tempDir:set(dir)
  if useZ0 then
    tempDir.z = 0
    tempDir:normalize()
  end
  tempDir:setScaled(scale)

  aheadPos:setAdd(tempDir)
  return aheadPos -- uses cached vector, so copy this in the calling function if needed
end

local function checkRoad(n1, n2, options) -- checks if a road is usable for spawning traffic
  local mapNodes = map.getMap().nodes
  if not n1 or not n2 or not mapNodes[n1] or not mapNodes[n2] then return false end

  local link = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
  if not link then return false end

  options = options or {}

  if not options.usePrivateRoads and link.type == 'private' then
    return false
  end

  local drivability = link.drivability
  local radius = math.min(mapNodes[n1].radius, mapNodes[n2].radius)
  local margin = link.oneWay and 2.4 - radius or 3 - radius -- narrow road threshold
  if margin > 0 then
    drivability = math.min(drivability, 1 - margin * 0.3) -- alter drivability due to narrow road
    -- e.g. a 5 m wide road will have an effective drivability value of 0.85
  end

  if options.minDrivability then
    if drivability < options.minDrivability then
      return false
    end
  end

  if options.minRadius then
    if radius < options.minRadius then
      return false
    end
  end

  return true
end

local function checkRayCast(pos, zOffset) -- checks if raycast from camera position to given position hits static geometry
  zOffset = zOffset or 0.5

  tempPos:set(pos)
  tempPos.z = tempPos.z + zOffset
  camPos:set(core_camera.getPositionXYZ())

  tempDir:setSub2(tempPos, camPos)
  local rayDistMax = tempDir:length()
  tempDir:setScaled(1 / math.max(1e-12, rayDistMax))
  local rayDist = castRayStatic(camPos, tempDir, rayDistMax)

  return rayDist < rayDistMax
end

local function checkUsability(pos, origPos, minDist, maxDist, n1, n2) -- checks if position on road is usable
  origPos = origPos or core_camera.getPosition()
  minDist = minDist or 80
  maxDist = maxDist or 1e12

  -- check for minimum and maximum distance from the origin
  local dist = pos:squaredDistance(origPos)
  if dist < square(minDist) or dist > square(maxDist) then
    return false
  end

  -- check for intersection road nodes, if applicable
  if n1 or n2 then
    local mapNodes = map.getMap().nodes
    if (n1 and map.getNodeLinkCount(n1) > 2 and pos:squaredDistance(mapNodes[n1].pos) <= square(mapNodes[n1].radius))
    or (n2 and map.getNodeLinkCount(n2) > 2 and pos:squaredDistance(mapNodes[n2].pos) <= square(mapNodes[n2].radius)) then
      return false
    end
  end

  return true
end

local function checkVehicles(pos, vehDist) -- checks for possible conflicts with other vehicles
  vehDist = vehDist or 15
  local traffic = gameplay_traffic.getTrafficData()
  for _, veh in ipairs(getAllVehicles()) do
    if veh:getActive() then
      local vehId = veh:getId()

      local relSpeed = 0
      local mapData = map.objects[vehId]
      if mapData then
        tempPos:set(mapData.pos)
        tempDir:setSub2(pos, tempPos) -- vector to the spawn point
        tempDir:normalize()
        relSpeed = clamp(mapData.vel:dot(tempDir), 0, 50)
        local gravity = core_environment.getGravity()
        relSpeed = square(relSpeed * 1.25) / (2 * math.max(0.1, math.abs(gravity)) * sign2(gravity) * -1) -- modified relative speed formula
      end

      local radius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) -- custom traffic radius property
      if radius then
        tempPos:set(mapData and mapData.pos or veh:getPosition()) -- just in case mapData is not available
        tempDir:set(mapData and mapData.dirVec or veh:getDirectionVector())
        tempPos:set(getAheadPos(tempPos, tempDir, radius * 0.5, true))
      else
        if traffic[vehId] then
          tempPos:set(traffic[vehId].pos) -- precise traffic vehicle position
        else
          tempPos:set(veh:getPositionXYZ())
        end
        radius = vehDist
      end

      if pos:squaredDistance(tempPos) < square(math.max(radius, relSpeed)) then
        return false
      end
    end
  end

  return true
end

local function checkSpawnPoint(pos, origPos, minDist, maxDist, minVehDist, n1, n2) -- checks a spawn point usability and vehicle conflicts
  return checkUsability(pos, origPos, minDist, maxDist, n1, n2) and checkVehicles(pos, minVehDist)
end

local function finalizeSpawnPoint(pos, dir, mapNode1, mapNode2, options) -- snaps a spawn point to a lane of the road, plus other options
  -- dir, mapNode1, mapNode2, and options are optional
  local mapNodes = map.getMap().nodes

  if not mapNode1 or not mapNode2 or not mapNodes[mapNode1] or not mapNodes[mapNode2] then
    local dist
    mapNode1, mapNode2, dist = map.findClosestRoad(pos)
    if not mapNode1 or dist > 30 then
      if M.debugMode then
        log('W', logTag, 'Failed to find nearby road for spawn point adjustment')
      end
      return pos, dir
    end
  end

  local newPos, newDir = vec3(), vec3()
  options = options or {}

  p1:set(mapNodes[mapNode1].pos)
  p2:set(mapNodes[mapNode2].pos)

  if not dir or options.legalDirection then
    if not dir then dir = vec3() end
    dir:setSub2(p2, p1)
    dir:normalize()
    options.legalDirection = true -- defaults to true if no direction is provided
  end

  local xnorm = clamp(pos:xnormOnLine(p1, p2), 0, 1)
  local radius = lerp(mapNodes[mapNode1].radius, mapNodes[mapNode2].radius, xnorm)
  local normal = mapNodes[mapNode1].normal:slerp(mapNodes[mapNode2].normal, xnorm):normalized()
  local link = mapNodes[mapNode1].links[mapNode2] or mapNodes[mapNode2].links[mapNode1]

  local legalSide = map.getRoadRules().rightHandDrive and -1 or 1
  local roadWidth = radius * 2
  local laneWidth = roadWidth >= 6.1 and 3.05 or 2.2 -- gets modified for very narrow roads

  options.minLane = math.min(0, options.minLane or -10)
  options.maxLane = math.max(0, options.maxLane or 10)
  options.roadDir = sign2(options.roadDir or math.random() * 2 - 1) -- negative = away from you, positive = towards you

  local laneChoice, roadDir, offsetVec

  local laneCount = math.max(1, math.floor(roadWidth / laneWidth)) -- estimated number of lanes (this will change when real lanes exist)
  if not link.oneWay and laneCount % 2 ~= 0 then -- two way roads currently have an even amount of expected lanes
    laneCount = math.max(1, laneCount - 1)
  end

  if options.legalDirection then
    if link.oneWay then
      roadDir = link.inNode == mapNode1 and 1 or -1 -- spawn facing the correct way
    else
      roadDir = laneCount == 1 and 1 or options.roadDir
    end
  else
    roadDir = options.roadDir
  end

  if link.oneWay then
    laneChoice = math.random(laneCount)
  else
    if laneCount == 1 then
      laneChoice = 1
    else
      if options.legalDirection then
        local minLane = roadDir == -1 and 1 or math.max(1, math.floor(laneCount * 0.5) + 1)
        local maxLane = roadDir == -1 and math.max(1, math.floor(laneCount * 0.5)) or laneCount
        laneChoice = math.random(math.max(minLane, options.minLane), math.min(maxLane, options.maxLane))
      else
        laneChoice = math.random(math.max(1, options.minLane), math.min(laneCount, options.maxLane))
      end
    end
  end

  if options.roadLateralXnorm then -- overrides lanes by directly adjusting the position along the lateral xnorm (from -1 to 1)
    offsetVec = dir:cross(normal) * radius * options.roadLateralXnorm
  else
    local offset = (laneChoice - (laneCount * 0.5 + 0.5)) * (roadWidth / laneCount) * legalSide
    offsetVec = dir:cross(normal) * offset
  end

  newPos:setAdd2(pos, offsetVec)
  newDir:setScaled2(dir, roadDir)

  return newPos, newDir
end

local function findSpawnPointRadial(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, from random radials away from the origin
  -- all args are optional, will use camera transform by default
  options = options or {}
  startPos, startDir, minDist, maxDist, targetDist = getDefaultSpawnParams(startPos, startDir, minDist, maxDist, targetDist)

  local spawnData = {pos = vec3(), dir = vec3()}
  local valid = false
  local mapNodes = map.getMap().nodes
  local currDist = minDist

  options.gap = options.gap or 50
  options.usePrivateRoads = options.usePrivateRoads and true or false
  options.minDrivability = options.minDrivability or baseValues.minDrivability
  options.minRadius = options.minRadius or baseValues.minRadius

  if M.debugMode then
    log('I', logTag, string.format('Spawn search params: minDist = %d, maxDist = %d, targetDist = %d', minDist, maxDist, targetDist))
  end

  --[[
  ---- RADIAL SEARCH ----
  Points from a radius will be checked until a valid road to spawn on has been found.
  ]]--

  repeat
    local angleRad = math.rad(math.random() * 360)
    spawnData.dir:set(math.sin(angleRad), math.cos(angleRad), 0)
    spawnData.dir:setScaled(currDist)
    spawnData.pos:setAdd2(startPos, spawnData.dir)

    local n1, n2 = map.findClosestRoad(spawnData.pos)
    if checkRoad(n1, n2, options) then
      p1:set(mapNodes[n1].pos)
      p2:set(mapNodes[n2].pos)
      spawnData.pos:set(linePointFromXnorm(p1, p2, clamp(spawnData.pos:xnormOnLine(p1, p2), 0, 1)))

      if currDist >= targetDist or checkRayCast(spawnData.pos) then
        tempDir:setSub2(p2, p1)
        tempDir:normalize()
        if spawnData.dir:dot(tempDir) < 0 then
          tempDir:setScaled(-1)
        end
        spawnData.dir:set(tempDir)

        if checkSpawnPoint(spawnData.pos, startPos, minDist, maxDist, 15, n1, n2) then
          spawnData.n1, spawnData.n2 = n1, n2
          valid = true

          if M.debugMode then
            log('I', logTag, string.format('Spawn point found at distance: %d', math.floor(spawnData.pos:distance(startPos))))
          end
        end
      end
    end

    currDist = currDist + options.gap
  until (valid or currDist > maxDist)

  if not valid then
    spawnData.dir:normalize()
    if M.debugMode then
      log('W', logTag, 'Failed to validate spawn point (radial method)')
    end
  end

  return spawnData, valid
end

local function findSpawnPointOnLine(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, from an extended line
  -- all args are optional, will use camera transform by default
  options = options or {}
  startPos, startDir, minDist, maxDist, targetDist = getDefaultSpawnParams(startPos, startDir, minDist, maxDist, targetDist)

  local spawnData = {pos = vec3(), dir = vec3()}
  local valid = false
  local mapNodes = map.getMap().nodes
  local currDist = minDist

  options.gap = options.gap or 50
  options.usePrivateRoads = options.usePrivateRoads and true or false
  options.minDrivability = options.minDrivability or baseValues.minDrivability
  options.minRadius = options.minRadius or baseValues.minRadius

  if M.debugMode then
    log('I', logTag, string.format('Spawn search params: minDist = %d, maxDist = %d, targetDist = %d', minDist, maxDist, targetDist))
  end

  --[[
  ---- LINE SEARCH ----
  Points from a line will be checked until a valid road to spawn on has been found.
  ]]--

  repeat
    spawnData.dir:set(startDir)
    spawnData.dir:setScaled(currDist)
    spawnData.pos:setAdd2(startPos, spawnData.dir)

    local n1, n2 = map.findClosestRoad(spawnData.pos)
    if checkRoad(n1, n2, options) then
      p1:set(mapNodes[n1].pos)
      p2:set(mapNodes[n2].pos)
      spawnData.pos:set(linePointFromXnorm(p1, p2, clamp(spawnData.pos:xnormOnLine(p1, p2), 0, 1)))

      if currDist >= targetDist or checkRayCast(spawnData.pos) then
        tempDir:setSub2(p2, p1)
        tempDir:normalize()
        if spawnData.dir:dot(tempDir) < 0 then
          tempDir:setScaled(-1)
        end
        spawnData.dir:set(tempDir)

        if checkSpawnPoint(spawnData.pos, startPos, minDist, maxDist, 15, n1, n2) then
          spawnData.n1, spawnData.n2 = n1, n2
          valid = true

          if M.debugMode then
            log('I', logTag, string.format('Spawn point found at distance: %d', math.floor(spawnData.pos:distance(startPos))))
          end
        end
      end
    end

    currDist = currDist + options.gap
  until (valid or currDist > maxDist)

  if not valid then
    spawnData.dir:normalize()
    if M.debugMode then
      log('W', logTag, 'Failed to validate spawn point (line method)')
    end
  end

  return spawnData, valid
end

local function findSpawnPointOnRoute(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, from a route that starts at the origin
  -- all args are optional, will use camera transform by default
  options = options or {}
  startPos, startDir, minDist, maxDist, targetDist = getDefaultSpawnParams(startPos, startDir, minDist, maxDist, targetDist)

  local spawnData = {pos = vec3(), dir = vec3()}
  local valid = false
  local mapNodes = map.getMap().nodes
  local currDist = minDist

  options.gap = options.gap or 20
  options.usePrivateRoads = options.usePrivateRoads and true or false
  options.minDrivability = options.minDrivability or baseValues.minDrivability
  options.minRadius = options.minRadius or baseValues.minRadius
  options.pathRandomization = options.pathRandomization or 0.5

  if M.debugMode then
    log('I', logTag, string.format('Spawn search params: minDist = %d, maxDist = %d, targetDist = %d', minDist, maxDist, targetDist))
  end

  route:clear()
  route.dirMult = 1

  --[[
  ---- ROUTE SEARCH ----
  A path will be generated along the road ahead, and points between the minimum distance and maximum distance will be tested and validated.
  ]]--

  local n1, n2 = map.findClosestRoad(startPos)
  if n1 then
    p1:set(mapNodes[n1].pos)
    p2:set(mapNodes[n2].pos)
    tempDir:setSub2(p2, p1)
    if tempDir:dot(startDir) < 0 then -- if true, swap the nodes
      n1, n2 = n2, n1
      p1:set(mapNodes[n1].pos)
      p2:set(mapNodes[n2].pos)
    end

    if options.route then
      -- perhaps this should exist outside of the initial if statement?
      route:setupPathMultiWaypoints(options.route)
    else
      -- spawn point is along path in direction set by startDir, with possible branching
      local path = map.getGraphpath():getRandomPathG(n1, startDir, maxDist, options.pathRandomization, 1, false)
      --route:setupPathMultiWaypoints(path)
      for _, wp in ipairs(path) do
        table.insert(route.path, {pos = map.getMap().nodes[wp].pos, wp = wp, linkCount = map.getNodeLinkCount(wp)}) -- optimized route path creation
      end
      route:calcDistance()
    end

    if M.debugMode then
      if route.path[1] then
        log('I', logTag, string.format('Spawn search route length: %0.2f', route.path[1].distToTarget))
      else
        log('W', logTag, 'Failed to generate valid route')
      end
    end

    local firstDist = minDist
    if route.path[1] and route.path[2] then
      local xnorm = clamp(startPos:xnormOnLine(route.path[1].pos, route.path[2].pos), 0, 1)
      firstDist = firstDist + (route.path[1].distToTarget - route.path[2].distToTarget) * xnorm
    end

    local road = route:stepAhead(firstDist, true) or {} -- if nil, uses previous values as safety
    n1 = road.n1 or n1
    n2 = road.n2 or n2
    spawnData.pos:set(road.pos or mapNodes[n2].pos)
    spawnData.dir:set((mapNodes[n2].pos - mapNodes[n1].pos):normalized())
  else
    return spawnData, valid
  end

  repeat
    local vehConflict = false
    if checkRoad(n1, n2, options) then
      p1:set(mapNodes[n1].pos)
      p2:set(mapNodes[n2].pos)

      if currDist >= targetDist or checkRayCast(spawnData.pos) then
        if checkUsability(spawnData.pos, startPos, minDist, maxDist, n1, n2) then
          if checkVehicles(spawnData.pos, 15) then
            spawnData.n1, spawnData.n2 = n1, n2
            valid = true

            if M.debugMode then
              log('I', logTag, string.format('Spawn point found at distance: %d', math.floor(spawnData.pos:distance(startPos))))
            end
          else
            vehConflict = true
          end
        end
      end
    end

    if not valid then
      local gap = options.gap
      if options.gapVehCoef or options.gapSpeedCoef then -- spawn point spacing modifiers
        local link = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
        if link and link.speedLimit then
          if vehConflict and options.gapVehCoef then
            gap = clamp(link.speedLimit * options.gapVehCoef, 20, 50)
          elseif options.gapSpeedCoef then
            gap = clamp(link.speedLimit * options.gapSpeedCoef, 20, 50)
          end
        end
      end

      local road = route:stepAhead(gap) or {}
      if road then
        n1 = road.n1 or n1
        n2 = road.n2 or n2
        spawnData.pos:set(road.pos)
        spawnData.dir:set((mapNodes[n2].pos - mapNodes[n1].pos):normalized())
      end
    end

    currDist = currDist + options.gap
  until (valid or currDist > maxDist)

  if not valid and M.debugMode then
    log('W', logTag, 'Failed to validate spawn point (route method)')
  end

  return spawnData, valid
end

local function findSpawnPointActual(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, never nil; forces teleportation
  -- priority: route ahead first, then nearby roads (radial), then far away roads (radial), then max distance
  local spawnData, valid = findSpawnPointOnRoute(startPos, startDir, minDist, maxDist, targetDist, options)

  if not valid then
    -- some of this feels hacky; will look into this another time
    spawnData, valid = findSpawnPointRadial(startPos, startDir, 200, 1000, 0, options) -- small radial search
    if not valid then
      options = options or {}
      options.minDrivability = 0.5
      spawnData, valid = findSpawnPointRadial(startPos, startDir, 200, 2000, 0, options) -- large radial search, more permissive options
      if not valid then
        spawnData, valid = findSpawnPointRadial(startPos, startDir, 10000, 12000, 0, options) -- temporary solution?
        spawnData.pos.z = 1 -- above ground plane
      end
    end
  end

  return spawnData, valid
end

local function placeTrafficVehicles(pos, dir, options) -- teleports all AI traffic vehicles to the given position, and lines them up
  options = options or {}
  options.pos = pos or core_camera.getPosition()
  options.dir = dir or core_camera.getForward()
  options.mode = options.mode or 'roadAhead'
  options.gap = options.gap or 15
  core_multiSpawn.placeGroup(gameplay_traffic.getTrafficAiVehIds(), options)
end

local function getNearestTrafficVehicle(pos, filters) -- returns the nearest traffic vehicle to the given position
  filters = filters or {}
  pos = pos or core_camera.getPosition()

  local bestId
  local bestDist = math.huge
  for _, id in ipairs(gameplay_traffic.getTrafficAiVehIds()) do
    local veh = gameplay_traffic.getTraffic()[id]
    local valid = true
    for k, v in pairs(filters) do -- optional filters by traffic vehicle properties
      if veh[k] ~= nil and veh[k] ~= v then
        valid = false
        break
      end
    end

    if valid then
      local otherPos = veh.pos
      local dist = pos:squaredDistance(otherPos)
      if dist < bestDist then
        bestId = id
        bestDist = dist
      end
    end
  end

  return bestId, math.sqrt(bestDist)
end

local function setTrafficSpeedFromApp(speed, mode) -- traffic app uses this function to convert and set the traffic speed limit
  speed = speed or 0
  mode = mode or 'auto'
  if mode == 'km/h' then
    speed = speed * 0.2778
  elseif mode == 'mph' then
    speed = speed * 0.447
  elseif mode == 'auto' then
    speed = -1
  end
  gameplay_traffic.setTrafficVars({speedLimit = speed})
  return speed
end

M.checkSpawnPoint = checkSpawnPoint
M.finalizeSpawnPoint = finalizeSpawnPoint
M.findSpawnPoint = findSpawnPointOnRoute
M.findSpawnPointOnRoute = findSpawnPointOnRoute
M.findSpawnPointOnLine = findSpawnPointOnLine
M.findSpawnPointRadial = findSpawnPointRadial
M.findSafeSpawnPoint = findSpawnPointActual

M.getAheadPos = getAheadPos
M.getBaseValues = getBaseValues
M.getBaseGroupParams = getBaseGroupParams
M.getLevelInfo = getLevelInfo
M.createTrafficGroup = createTrafficGroup
M.createPoliceGroup = createPoliceGroup
M.getTrafficGroupFromFile = getTrafficGroupFromFile
M.getRoleConstructor = getRoleConstructor
M.placeTrafficVehicles = placeTrafficVehicles
M.getNearestTrafficVehicle = getNearestTrafficVehicle
M.setTrafficSpeedFromApp = setTrafficSpeedFromApp

return M