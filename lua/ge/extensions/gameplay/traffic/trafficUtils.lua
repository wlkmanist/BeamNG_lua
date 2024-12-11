-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = 'trafficUtils'

local route = require('gameplay/route/route')()
local tempVec = vec3()

M.defaults = {drivability = 0.25, radius = 1.2}
M.debugMode = false

local function getDefaultValues(startPos, startDir, minDist, maxDist, targetDist) -- returns safe default values, to use with other methods
  startPos = startPos or core_camera.getPosition()
  startDir = startDir or core_camera.getForward()
  minDist = minDist or 20 -- minimum distance from start position
  maxDist = maxDist or 2000 -- maximum distance from start position
  targetDist = targetDist and math.min(targetDist, maxDist) or 0 -- ideal distance (max distance to use visibility raycasts for)
  startDir.z = 0

  return startPos, startDir, minDist, maxDist, targetDist
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

  if options.minDrivability then
    if link.drivability < options.minDrivability then
      return false
    end
  end

  if options.minRadius then
    if mapNodes[n1].radius < options.minRadius or mapNodes[n2].radius < options.minRadius then
      return false
    end
  end

  return true
end

local function checkRayCast(pos, origPos) -- checks if raycast hit static geometry
  origPos = origPos or core_camera.getPosition()
  tempVec:set(pos)
  tempVec.z = tempVec.z + 0.5

  tempVec:set(tempVec - origPos)
  local rayDistMax = tempVec:length()
  tempVec = tempVec / (rayDistMax + 1e-30)
  local rayDist = castRayStatic(origPos, tempVec, rayDistMax)

  return rayDist < rayDistMax
end

local function checkSpawnPoint(pos, origPos, minDist, minVehDist) -- checks a spawn point for any conflicts
  origPos = origPos or core_camera.getPosition()
  minDist = minDist or 80
  minVehDist = minVehDist or 15

  if pos:squaredDistance(origPos) < square(minDist) then
    return false
  end

  local traffic = gameplay_traffic.getTrafficData()
  for _, veh in ipairs(getAllVehicles()) do
    if veh:getActive() then
      local vehId = veh:getId()
      local vehPos = traffic[vehId] and traffic[vehId].pos or veh:getPosition() -- traffic pos value may be more accurate
      -- the following check really needs improvement
      local relSpeed = clamp(veh:getVelocity():dot((pos - vehPos):normalized()), 0, 50)
      local radius = veh:isPlayerControlled() and minDist or minVehDist
      if pos:squaredDistance(vehPos) < square(math.max(radius, relSpeed)) then
        return false
      end
    end
  end

  return true
end

local function finalizeSpawnPoint(pos, dir, mapNode1, mapNode2, options) -- snaps a spawn point to a lane of the road, plus other options
  -- dir, mapNode1, mapNode2, and options are optional
  local mapNodes = map.getMap().nodes

  if not mapNode1 or not mapNode2 or not mapNodes[mapNode1] or not mapNodes[mapNode2] then
    local dist
    mapNode1, mapNode2, dist = map.findClosestRoad(pos)
    if not mapNode1 or dist > 20 then
      if M.debugMode then
        log('W', logTag, 'Failed to find nearby road for spawn point adjustment')
      end
      return pos, dir
    end
  end

  local newPos, newDir = vec3(), vec3()
  options = options or {}

  local p1, p2 = mapNodes[mapNode1].pos, mapNodes[mapNode2].pos

  if not dir or options.legalDirection then
    dir = (p2 - p1):normalized()
    options.legalDirection = true
  end

  local xnorm = clamp(pos:xnormOnLine(p1, p2), 0, 1)
  local radius = lerp(mapNodes[mapNode1].radius, mapNodes[mapNode2].radius, xnorm)
  local normal = mapNodes[mapNode1].normal:slerp(mapNodes[mapNode2].normal, xnorm):normalized()
  local link = mapNodes[mapNode1].links[mapNode2] or mapNodes[mapNode2].links[mapNode1]

  local legalSide = map.getRoadRules().rightHandDrive and -1 or 1
  local roadWidth = radius * 2
  local laneWidth = roadWidth >= 6.1 and 3.05 or 2.4 -- gets modified for very narrow roads

  options.minLane = math.min(0, options.minLane or -10)
  options.maxLane = math.max(0, options.maxLane or 10)
  options.dirRandomization = options.dirRandomization or 0 -- negative = away from you, positive = towards you

  local laneChoice, roadDir, offsetVec

  local laneCount = math.max(1, math.floor(roadWidth / laneWidth)) -- estimated number of lanes (this will change when real lanes exist)
  if not link.oneWay and laneCount % 2 ~= 0 then -- two way roads currently have an even amount of expected lanes
    laneCount = math.max(1, laneCount - 1)
  end

  if options.legalDirection then
    if link.oneWay then
      roadDir = link.inNode == mapNode1 and 1 or -1 -- spawn facing the correct way
    else
      if laneCount == 1 then
        roadDir = 1 -- always spawn facing forwards on narrow roads
      else
        roadDir = options.dirRandomization > math.random() * 2 - 1 and -1 or 1
      end
    end
  else
    roadDir = 1
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

  if options.roadLateralXnorm then -- if this exists, directly adjusts the position along the lateral xnorm (from -1 to 1)
    -- overrides lanes
    offsetVec = dir:cross(normal) * radius * options.roadLateralXnorm
  else
    local offset = (laneChoice - (laneCount * 0.5 + 0.5)) * (roadWidth / laneCount) * legalSide
    offsetVec = dir:cross(normal) * offset
  end
  if options.roadDirection then -- if this exists, directly adjusts the direction (from -1 to 1)
    -- overrides lane direction
    roadDir = options.roadDirection
  end

  newPos:set(pos + offsetVec)
  newDir:set(dir * roadDir)

  return newPos, newDir
end

local function findSpawnPointRadial(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, from random radials away from the origin
  -- all args are optional, will use camera transform by default
  options = options or {}
  startPos, startDir, minDist, maxDist, targetDist = getDefaultValues(startPos, startDir, minDist, maxDist, targetDist)

  local spawnData = {pos = vec3(), dir = vec3()}
  local valid = false
  local mapNodes = map.getMap().nodes
  local currDist = minDist

  options.gap = options.gap or 50
  options.usePrivateRoads = options.usePrivateRoads and true or false
  options.minDrivability = options.minDrivability or M.defaults.drivability
  options.minRadius = options.minRadius or M.defaults.halfWidth

  if M.debugMode then
    log('I', logTag, 'Spawn search params: minDist = '..minDist..', maxDist = '..maxDist..', targetDist = '..targetDist)
  end

  --[[ here, points from a radius will be checked until a valid road to spawn on has been found ]]--

  repeat
    local angleRad = math.rad(math.random() * 360)
    spawnData.dir:set(math.sin(angleRad), math.cos(angleRad), 0)
    spawnData.pos:setAdd2(startPos, spawnData.dir * currDist)

    local n1, n2 = map.findClosestRoad(spawnData.pos)
    if checkRoad(n1, n2, options) then
      local p1, p2 = mapNodes[n1].pos, mapNodes[n2].pos
      spawnData.pos = linePointFromXnorm(p1, p2, clamp(spawnData.pos:xnormOnLine(p1, p2), 0, 1))

      if currDist >= targetDist or checkRayCast(spawnData.pos, startPos) then
      local roadDir = (p2 - p1):normalized()
        if spawnData.dir:dot(roadDir) < 0 then
          roadDir = -roadDir
        end
        spawnData.dir:set(roadDir)

        if checkSpawnPoint(spawnData.pos, nil, minDist) then
          spawnData.n1, spawnData.n2 = n1, n2
          valid = true

          if M.debugMode then
            log('I', logTag, 'Spawn point found at distance: '..tostring(spawnData.pos:distance(startPos)))
          end
        end
      end
    end

    currDist = currDist + options.gap
  until (valid or currDist > maxDist)

  if not valid and M.debugMode then
    log('W', logTag, 'Failed to validate spawn point')
  end

  return spawnData, valid
end

local function findSpawnPointOnLine(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, from an extended line
  -- all args are optional, will use camera transform by default
  options = options or {}
  startPos, startDir, minDist, maxDist, targetDist = getDefaultValues(startPos, startDir, minDist, maxDist, targetDist)

  local spawnData = {pos = vec3(), dir = vec3()}
  local valid = false
  local mapNodes = map.getMap().nodes
  local currDist = minDist

  options.gap = options.gap or 50
  options.usePrivateRoads = options.usePrivateRoads and true or false
  options.minDrivability = options.minDrivability or M.defaults.drivability
  options.minRadius = options.minRadius or M.defaults.halfWidth

  if M.debugMode then
    log('I', logTag, 'Spawn search params: minDist = '..minDist..', maxDist = '..maxDist..', targetDist = '..targetDist)
  end

  --[[ here, points from a line will be checked until a valid road to spawn on has been found ]]--

  repeat
    spawnData.dir:set(startDir)
    spawnData.pos:setAdd2(startPos, spawnData.dir * currDist)

    local n1, n2 = map.findClosestRoad(spawnData.pos)
    if checkRoad(n1, n2, options) then
      local p1, p2 = mapNodes[n1].pos, mapNodes[n2].pos
      spawnData.pos = linePointFromXnorm(p1, p2, clamp(spawnData.pos:xnormOnLine(p1, p2), 0, 1))

      if currDist >= targetDist or checkRayCast(spawnData.pos, startPos) then
      local roadDir = (p2 - p1):normalized()
        if spawnData.dir:dot(roadDir) < 0 then
          roadDir = -roadDir
        end
        spawnData.dir:set(roadDir)

        if checkSpawnPoint(spawnData.pos, nil, minDist) then
          spawnData.n1, spawnData.n2 = n1, n2
          valid = true

          if M.debugMode then
            log('I', logTag, 'Spawn point found at distance: '..tostring(spawnData.pos:distance(startPos)))
          end
        end
      end
    end

    currDist = currDist + options.gap
  until (valid or currDist > maxDist)

  if not valid and M.debugMode then
    log('W', logTag, 'Failed to validate spawn point')
  end

  return spawnData, valid
end

local function findSpawnPointOnRoute(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, from a route that starts at the origin
  -- all args are optional, will use camera transform by default
  options = options or {}
  startPos, startDir, minDist, maxDist, targetDist = getDefaultValues(startPos, startDir, minDist, maxDist, targetDist)

  local spawnData = {pos = vec3(), dir = vec3()}
  local valid = false
  local mapNodes = map.getMap().nodes
  local currDist = minDist

  options.gap = options.gap or 20
  options.usePrivateRoads = options.usePrivateRoads and true or false
  options.minDrivability = options.minDrivability or M.defaults.drivability
  options.minRadius = options.minRadius or M.defaults.halfWidth
  options.pathRandomization = options.pathRandomization or 0.5

  if M.debugMode then
    log('I', logTag, 'Spawn search params: minDist = '..minDist..', maxDist = '..maxDist..', targetDist = '..targetDist)
  end

  route:clear()
  route.dirMult = 1

  --[[ here, a path will be generated along the road ahead, and points between the minimum distance and maximum distance
  will be tested and validated before returning a new spawn point ]]--

  local n1, n2 = map.findClosestRoad(startPos)
  if n1 then
    local p1, p2 = mapNodes[n1].pos, mapNodes[n2].pos
    if (p2 - p1):dot(startDir) < 0 then
      n1, n2 = n2, n1
      p1, p2 = p2, p1
    end

    if options.route then
      -- perhaps this should exist outside of the initial if statement?
      route:setupPathMultiWaypoints(options.route)
    else
      -- spawn point is along path in direction set by startDir, with possible branching
      local path = map.getGraphpath():getRandomPathG(n1, startDir, maxDist, options.pathRandomization, 1, false)
      route:setupPathMultiWaypoints(path)
    end

    if M.debugMode then
      if route.path[1] then
        log('I', logTag, 'Spawn search route length: '..string.format('%0.2f', route.path[1].distToTarget))
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
    spawnData.pos:set(road.pos or firstPos)
    spawnData.dir:set((mapNodes[n2].pos - mapNodes[n1].pos):normalized())
  else
    return spawnData, valid
  end

  repeat
    if checkRoad(n1, n2, options) then
      local p1, p2 = mapNodes[n1].pos, mapNodes[n2].pos

      if currDist >= targetDist or checkRayCast(spawnData.pos, startPos) then
        if checkSpawnPoint(spawnData.pos, nil, minDist) then
          spawnData.n1, spawnData.n2 = n1, n2
          valid = true

          if M.debugMode then
            log('I', logTag, 'Spawn point found at distance: '..tostring(spawnData.pos:distance(startPos)))
          end
        end
      end
    end

    if not valid then
      local road = route:stepAhead(options.gap) or {}
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
    log('W', logTag, 'Failed to validate spawn point')
  end

  return spawnData, valid
end

local function findSpawnPointActual(startPos, startDir, minDist, maxDist, targetDist, options) -- returns a spawn point, never nil; forces teleportation
  local spawnData, isOnRoute = findSpawnPointOnRoute(startPos, startDir, minDist, maxDist, targetDist, options)

  if not isOnRoute then
    spawnData = findSpawnPointRadial(startPos, startDir, 200, 2000, 0, options)
  end

  return spawnData, isOnRoute
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
    for k, v in pairs(filters) do
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

M.checkSpawnPoint = checkSpawnPoint
M.finalizeSpawnPoint = finalizeSpawnPoint
M.findSpawnPoint = findSpawnPointOnRoute
M.findSpawnPointOnRoute = findSpawnPointOnRoute
M.findSpawnPointOnLine = findSpawnPointOnLine
M.findSpawnPointRadial = findSpawnPointRadial
M.findSafeSpawnPoint = findSpawnPointActual

M.placeTrafficVehicles = placeTrafficVehicles
M.getNearestTrafficVehicle = getNearestTrafficVehicle

return M