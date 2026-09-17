-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max
local pow = math.pow
local ceil = math.ceil
local floor = math.floor
local random = math.random
local huge = math.huge

local M = {}

local logTag = 'multiSpawn'

local groupId = 0
local spawningBusy = false
local queue = {}
local defaultOptions = {model = 'pickup'}
local defaultFilters = {Type = {car = 1, truck = 1}}

local tempPosA, tempPosB, tempDirVec = vec3(), vec3(), vec3()

local vecUp = vec3(0, 0, 1)
local vecY = vec3(0, 1, 0)

M.startEngines = true -- this system will always spawn vehicles with their engines on by default
M.useFullData = false -- if true, inserts population values and other data into the group table

local function shuffleIntegers(num, total) -- creates and shuffles list of integers
  local array, list = {}, {}
  for i = 1, num do
    table.insert(array, i)
  end
  array = arrayShuffle(array)

  for i = 1, total do
    local mod = i % num
    local idx = i <= num and i or (mod > 0 and mod or num) -- looping index
    table.insert(list, array[idx])
  end

  return list
end

local function binarySearchRange(tbl, key, target) -- returns the index of the target range (binary search)
  local l, n = 1, #tbl
  local m

  while l <= n do
    m = floor((l + n) * 0.5)
    local range = tbl[m][key]

    if range[2] <= target then -- rangeMax
      l = m + 1
    elseif range[1] > target then -- rangeMin
      n = m - 1
    else
      return m
    end
  end

  return m
end

local function getNewId() -- returns the unique id of the current group spawn job
  groupId = groupId + 1
  return groupId
end

local function getIndexRandomPop(vehData) -- returns the index by using a random population value and finding the corresponding data value
  local randNum = random() * vehData.popTotal
  for i, v in ipairs(vehData) do
    if randNum < v.pop then
      return i
    else
      randNum = randNum - v.pop
    end
  end

  return 1 -- random index failed, just return 1
end

local function getPopulationFactor(config, params) -- returns the weighted factor from the given filters
  params = params or {}
  params.filters = params.filters or {}
  local factor = 1

  if params.maxYear then
    if type(config.Years) == 'table' then
      config.yearMax = config.Years.max
    end
    if params.maxYear <= 0 then -- this auto sets year
      params.maxYear = os.date('*t').year -- current year (unsure about if this should be used)
    end

    if config.yearMax then
      if config.yearMax > params.maxYear then
        return 0
      else
        factor = min(1, square((100 - max(0, params.maxYear - config.yearMax)) / 100))
      end
    end
  end

  for k, filter in pairs(params.filters) do -- each inner table pair should have a coefficient: {Type = {car = 1, truck = 0.4}}
    if type(filter) == 'table' then
      local configValue = config[k] or 'default' -- unsure about this actually
      if type(configValue) == 'string' then configValue = string.lower(configValue) end

      if type(configValue) == 'table' then
        local filterKeyFound = false
        for k, v in pairs(configValue) do
          if type(filter[k]) == 'number' then -- filter value
            factor = factor * filter[k]
            filterKeyFound = true
          end
        end
        if not filterKeyFound then
          factor = type(filter.other) == 'number' and factor * filter.other or 0 -- if 'other' exists, use it; otherwise, factor becomes 0
        end
      else
        if type(filter[configValue]) == 'number' then -- filter value
          factor = factor * filter[configValue]
        else
          factor = type(filter.other) == 'number' and factor * filter.other or 0 -- if 'other' exists, use it; otherwise, factor becomes 0
        end
      end
    end
    if factor <= 0 then return 0 end
  end
  return factor
end

local function isOfficialSource(vehData) -- checks if vehicle model or config is official
  return (vehData and vehData.aggregates and vehData.aggregates.Source and vehData.aggregates.Source['BeamNG - Official'])
end

local function getInstalledVehicleData(params) -- gets all vehicles and creates the initial data
  params = params or {allMods = false, allConfigs = true}
  params.filters = params.filters or deepcopy(defaultFilters)
  local minPop = params.minPop or 0
  local vehData, configData = {}, {}

  for _, model in pairs(core_vehicles.getModelList().models) do
    local officialModel = isOfficialSource(model)
    if params.allMods or officialModel then
      table.clear(configData)
      local defaultConfig = model.default_pc
      local defaultPop, defaultPopFactor = 0, 1

      local country = model.Country and string.lower(model.Country) or 'default'
      if country ~= 'default' then
        if not vehData.countryCounts then vehData.countryCounts = {} end
        vehData.countryCounts[country] = (vehData.countryCounts[country] or 0) + 1 -- counts each country of origin entry (ratios will affect probability of selection)
      end

      for _, config in pairs(core_vehicles.getModel(model.key).configs) do
        local officialConfig = isOfficialSource(config)
        if params.allMods or officialConfig then
          local configCopy = deepcopy(config)

          if type(configCopy.Population) ~= 'number' then
            if not officialModel or not officialConfig then
              configCopy.Population = 10000 -- improves chance of selecting mod configs, if applicable (old: 5000)
            else
              configCopy.Population = 0
            end
          end
          local popValue = configCopy.Population

          if popValue >= minPop then
            configCopy.Name = model.Name -- enables filtering by name
            configCopy.Type = config.Type or model.Type -- this way is not good, "Type" should only be a model property
            configCopy.Country = model.Country -- improves selection of domestic models
            configCopy['Derby Class'] = model['Derby Class'] -- enables filtering by class

            local popFactor = getPopulationFactor(configCopy, params)
            if popFactor > 0 then -- population value must be greater than zero to enable entry into table
              if popValue > defaultPop then -- searches for the maximum population value to apply to model data
                defaultPop = popValue
                defaultPopFactor = popFactor
              end

              if params.allConfigs or config.key == defaultConfig then
                table.insert(configData, {
                  config = config.key,
                  popBase = popValue,
                  popFactor = popFactor
                })
              end
            end
          end
        end
      end

      if configData[1] then
        table.insert(vehData, {
          model = model.key,
          country = country,
          popBase = defaultPop,
          popFactor = defaultPopFactor,
          configData = deepcopy(configData)
        })
      end
    end
  end

  return vehData
end

local function setPopulationData(vehData, country, popPower) -- sets the relative population value for each vehicle
  if not popPower or popPower <= 0 then
    popPower = 1
  else
    popPower = min(2, popPower)
  end
  vehData.popTotal = 0

  for _, v in ipairs(vehData) do
    local countryFactor = 1
    if country and vehData.countryCounts and vehData.countryCounts[v.country] and v.country ~= country then
      countryFactor = 0.25 / max(1, vehData.countryCounts[v.country]) -- this decreases the probability weight of vehicles from other countries
    end

    if v.popBase * v.popFactor > 0 then
      v.pop = round(pow(v.popBase * v.popFactor, popPower) * countryFactor) -- popPower modifies the probability weight of each vehicle to improve the randomness of selections
      vehData.popTotal = vehData.popTotal + v.pop
    else
      v.pop = 0
    end
  end

  return vehData
end

local function buildGroup(vehData, amount, modelPopPower, configPopPower, popDecreaseFactor) -- randomly builds the vehicle group from the installed vehicle data
  local newGroup, shuffledList = {}, {}
  local modelIdx, configIdx
  popDecreaseFactor = popDecreaseFactor or 0.05 -- whenever a vehicle is inserted, multiply its population values by this amount to reduce probability

  -- if not population power value, use simple randomization; else, use range-based randomization
  if not modelPopPower or modelPopPower <= 0 then
    shuffledList = shuffleIntegers(#vehData, amount)
  else
    table.sort(vehData, function(a, b) return a.pop > b.pop end) -- for optimized index searching
  end

  for i = 1, amount do
    if not modelPopPower then -- first, randomly pick model
      modelIdx = shuffledList[i] or 1
    else
      modelIdx = getIndexRandomPop(vehData)
      -- modelIdx = binarySearchRange(data, 'range', data[#data]['range'][2] * random())
    end

    local model = vehData[modelIdx]
    if model and model.configData then
      if not configPopPower or configPopPower <= 0 then -- then, randomly pick config
        configIdx = random(#model.configData)
      else
        table.sort(model.configData, function(a, b) return a.pop > b.pop end)
        configIdx = getIndexRandomPop(model.configData)
        -- configIdx = cLength > 0 and binarySearchRange(model.configData, 'range', model.configData[cLength]['range'][2] * random()) or 1
      end

      local config = model.configData[configIdx]
      if config then
        local entry = {model = model.model, config = config.config}
        if M.useFullData then
          entry.modelPop = model.pop
          entry.configPop = config.pop
        end
        table.insert(newGroup, entry)

        local newPop = max(1, ceil(model.pop * popDecreaseFactor))
        vehData.popTotal = vehData.popTotal - (model.pop - newPop)
        model.pop = newPop

        newPop = max(1, ceil(config.pop * popDecreaseFactor))
        model.configData.popTotal = model.configData.popTotal - (config.pop - newPop)
        config.pop = newPop
      end
    end
  end

  return newGroup
end

local function createGroup(amount, params) -- creates a group array from a table of parameters
  -- params = {allMods, allConfigs, filters, country, modelPopPower, configPopPower}
  params = params or {}
  amount = amount or 10 -- default group size
  params.filters = params.filters or deepcopy(defaultFilters)
  -- default filters: Type = selects valid road vehicles
  -- special filters: maxYear = latest year to allow for selection

  if params.country then params.country = string.lower(params.country) end
  local vehData = getInstalledVehicleData(params)

  if not vehData[1] then
    log('I', logTag, 'No vehicle data found from filters, now returning empty group')
    return {}
  end

  -- set population data for models, then for its configs
  vehData = setPopulationData(vehData, params.country, params.modelPopPower)
  for _, v in ipairs(vehData) do
    v.configData = setPopulationData(v.configData, nil, params.configPopPower)
  end

  return buildGroup(vehData, amount, params.modelPopPower, params.configPopPower, params.popDecreaseFactor)
end

local function vehIdsToGroup(vehIds) -- converts a list of vehicle ids to a group array of vehicle data
  local res = {}
  if not vehIds then return res end

  for _, id in ipairs(vehIds) do
    local data = {}
    local vehData = core_vehicle_manager.getVehicleData(id)
    if vehData then
      local config = vehData.config
      data.model = config.model or string.match(config.partConfigFilename, 'vehicles/([%w|_|%-|%s]+)') -- model might be nil for some reason

      if data.model then
        data.config = string.match(config.partConfigFilename, '/*([%w_%-]+).pc')
        data.paint, data.paint2, data.paint3 = config.paints[1], config.paints[2], config.paints[3]
        data.paintName, data.paintName2, data.paintName3 = '(Custom)', '(Custom)', '(Custom)' -- assumes custom paints (can't assert paint names)
        table.insert(res, data)
      end
    end
  end

  return res
end

local function spawnedVehsToGroup(ignorePlayer, ignoreTraffic) -- converts all currently spawned vehicles to a group array of vehicle data
  local vehIds = {}

  for _, v in ipairs(getAllVehiclesByType()) do
    if not (ignorePlayer and v:getID() == be:getPlayerVehicleID(0)) then
      if not (ignoreTraffic and (v.isTraffic or v.isParked)) then
        table.insert(vehIds, v:getID())
      end
    end
  end

  return vehIdsToGroup(vehIds)
end

local function getLineTransform(pos, lineDir, lineDist, vehDir, ignoreSnap) -- returns a spawn point on any terrain
  local newPos, newDir = vec3(pos), vec3(lineDir)
  vehDir = vehDir or vec3(newDir) -- uses line direction by default

  newDir:setScaled(lineDist)
  newPos:setAdd(newDir)
  if ignoreSnap then return newPos, vehDir end

  newPos.z = newPos.z + 4 -- up vector offset
  local z = be:getSurfaceHeightBelow(newPos)

  if z >= -1e6 then
    newPos.z = z
  elseif core_terrain.getTerrain() then
    newPos.z = core_terrain.getTerrainHeight(newPos)
  else
    newPos.z = pos.z - 4
  end

  return newPos, vehDir
end

local function getRoadTransform(route, startDist, routeDist, side, legalSide, forward) -- returns a spawn point on a road
  if not route then return end

  local newPos, newDir = vec3(), vec3()
  legalSide = legalSide or 1
  local mapNodes = map.getMap().nodes

  local n1, n2, xnorm = map.getNodesFromPathDist(route, startDist + routeDist)
  tempPosA:set(mapNodes[n1].pos)
  tempPosB:set(mapNodes[n2].pos)
  local radius = lerp(mapNodes[n1].radius, mapNodes[n2].radius, xnorm)

  -- segment direction vector
  tempDirVec:setSub2(tempPosB, tempPosA)
  tempDirVec:normalize()
  newDir:set(tempDirVec)

  if forward then
    newDir:setScaled(forward)
  else -- smart direction based on current road
    local link = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
    if link.oneWay then
      newDir:setScaled(link.inNode == n1 and 1 or -1)
    else
      newDir:setScaled(sign2(side * legalSide))
    end
  end

  -- forwards offset
  newPos:setLerp(tempPosA, tempPosB, xnorm)

  -- side offset
  tempDirVec.z = 0
  tempDirVec:normalize()
  tempDirVec:setCross(tempDirVec, vecUp)
  tempDirVec:setScaled(radius * side)

  newPos:setAdd(tempDirVec)

  return newPos, newDir
end

local spawnModes = {
  roadAhead = function (data) -- road ahead, facing away from start
    return getRoadTransform(data.route, data.startDist, data.step * data.gap, data.legalSide * 0.5, 1, 1)
  end,
  roadBehind = function (data) -- road behind, facing towards start
    return getRoadTransform(data.route, data.startDist, data.step * data.gap, data.legalSide * -0.5, 1, -1)
  end,
  roadAheadAlt = function (data) -- road ahead, facing towards start
    return getRoadTransform(data.route, data.startDist, data.step * data.gap, data.legalSide * -0.5, 1, -1)
  end,
  roadBehindAlt = function (data) -- road ahead, facing away from start
    return getRoadTransform(data.route, data.startDist, data.step * data.gap, data.legalSide * 0.5, 1, 1)
  end,
  traffic = function (data) -- smart traffic formation
    return getRoadTransform(data.route, data.startDist, data.step * data.gap, data.laneSide * 0.5, data.legalSide)
  end,
  raceGrid = function (data) -- race grid formation
    local laneSide = data.step % 2 == 0 and data.laneSide or -data.laneSide
    return getRoadTransform(data.route, data.startDist, floor(data.step / 2) * data.gap, laneSide * 0.5, 1, 1)
  end,
  raceGridAlt = function (data) -- race grid formation, shifted so that the next point is diagonal
    local laneSide = data.step % 2 == 0 and data.laneSide or -data.laneSide
    return getRoadTransform(data.route, data.startDist, data.step * data.gap, laneSide * 0.5, 1, 1)
  end,
  lineLeft = function (data)
    tempDirVec:setScaled2(data.dir, -1)
    tempDirVec.z = 0
    tempDirVec:setCross(tempDirVec, vecUp)
    return getLineTransform(data.pos, tempDirVec, data.step * data.gap, data.dir)
  end,
  lineRight = function (data)
    tempDirVec:set(data.dir)
    tempDirVec.z = 0
    tempDirVec:setCross(tempDirVec, vecUp)
    return getLineTransform(data.pos, tempDirVec, data.step * data.gap, data.dir)
  end,
  lineBehind = function (data)
    tempDirVec:setScaled2(data.dir, -1)
    return getLineTransform(data.pos, tempDirVec, data.step * data.gap, data.dir)
  end,
  lineAhead = function (data)
    return getLineTransform(data.pos, data.dir, data.step * data.gap, data.dir)
  end,
  lineAbove = function (data)
    return getLineTransform(data.pos, vecUp, data.step * data.gap, data.dir, true)
  end
}

local function workSpawnVehicles(job, spawnData, spawnOptions) -- processes vehicles to be spawned
  local vehIds = {}
  for i, data in ipairs(spawnData) do
    if i > 1 and spawnOptions.canSpawnAnotherVehicleCheck ~= false and not canSpawnAnotherVehicle() then
      -- always allow the 1st vehicle to spawn, guaranteeing at least one vehicle to exist, avoiding an entire category of issues from external code logic (which often assumes a non-empty list)
      log("W", logTag, string.format("Vehicle group spawning aborted after %d / %d vehicles due to risk of running out of memory: '%s'", i - 1, #spawnData, dumps(spawnOptions.name)))
      break
    end

    log('I', logTag, string.format('Vehicle group spawning in progress (%d / %d)', i, #spawnData))
    local veh = spawn.spawnVehicle(data.model, data.config, data.pos, data.rot, data)

    if veh then
      table.insert(vehIds, veh:getId())
      veh:setDynDataFieldbyName('vehicleGroup', 0, tostring(spawnOptions.name))
      if data.spawnMeta then -- generic caller-defined classification, forwarded onto the vehicle (domain-agnostic)
        veh:setDynDataFieldbyName('spawnMeta', 0, tostring(data.spawnMeta))
      end
    else
      log('W', logTag, 'Vehicle failed to load; skipping this group entry')
    end

    -- important: do not cache vehicle pointers across frames via yield
    if job then
      job.yield()
    end
  end

  if job then
    job.sleep(0.001) -- final frame delay, to ensure vehicle positions are ready
  end

  spawningBusy = false
  log('I', logTag, string.format('Vehicle group spawning completed: %s', spawnOptions.name or ''))
  extensions.hook('onVehicleGroupSpawned', vehIds, groupId, spawnOptions.name)

  if queue[1] then -- next vehicle group to instantly spawn
    local args = queue[1]
    table.remove(queue, 1)
    M.spawnGroup(unpack(args))
  end
end

local function createSpawnPositions(amount, options) -- creates a list of smart spawn positions for vehicles to use
  options = options or {}
  amount = amount or 20
  local transformData = {}

  local mode = options.mode or 'roadAhead'
  local gap = options.gap or 15
  if options.func or mode == 'road' then mode = 'roadAhead' end -- default mode

  local pos, dir = vec3(), vec3()
  local mapNodes = map.getMap().nodes
  local playerVehId = be:getPlayerVehicleID(0)
  local playerFocus = playerVehId ~= -1 and not commands.isFreeCamera()

  local start
  if options.pos then
    pos:set(options.pos)
    if options.dir then
      dir:set(options.dir)
    elseif options.rot then -- quat to dir
      dir:set(vecY:rotated(options.rot))
    end
    start = 0
  else
    if playerFocus then
      pos:set(be:getObjectOOBBCenterXYZ(playerVehId))
      dir:set(getObjectByID(playerVehId):getDirectionVectorXYZ())
      start = 1 -- slot 0 is reserved for player vehicle
    else
      pos:set(core_camera.getPositionXYZ())
      dir:set(core_camera.getForwardXYZ())
      start = 0
    end
  end

  if mode == 'traffic' and not options.pos and gameplay_traffic_trafficUtils then
    -- if traffic mode is active, find a safe spawn point near the camera
    log('I', logTag, 'Multispawn mode is traffic, now finding an ideal spawn point...')
    local spawnData = gameplay_traffic_trafficUtils.findSafeSpawnPoint(nil, nil, 0, 500, 0)
    pos:set(spawnData.pos)
    dir:set(spawnData.dir)
  end

  start = options.startIndex or start -- custom start index

  local route
  local maxLength = 200 + gap * amount
  local dist = 0
  local lane = 1
  local n1, n2 = map.findClosestRoad(pos)
  local legalSide = map.getRoadRules().rightHandDrive and -1 or 1

  if mode == 'roadBehind' or mode == 'roadBehindAlt' then -- TODO: uhh, avoid this hardcode
    dir:setScaled(-1)
  end

  if n1 then
    tempPosA:set(mapNodes[n1].pos)
    tempPosB:set(mapNodes[n2].pos)
    tempDirVec:setSub2(tempPosB, tempPosA)
    if tempDirVec:dot(dir) < 0 then -- flip nodes if reverse direction
      n1, n2 = n2, n1
      tempPosA:set(mapNodes[n2].pos)
      tempPosB:set(mapNodes[n1].pos)
    end

    route = map.getGraphpath():getRandomPathG(n1, dir, maxLength, nil, nil, false) -- generally produces a straight path ahead
    if route then
      tempPosA:set(mapNodes[route[1]].pos)
      tempPosB:set(mapNodes[route[2]].pos)
      tempPosB:setLerp(tempPosA, tempPosB, clamp(pos:xnormOnLine(tempPosA, tempPosB), 0, 1))
      dist = tempPosB:distance(tempPosA) -- distance from start node to origin point

      tempDirVec:set(dir)
      tempDirVec.z = 0
      tempDirVec:setCross(tempDirVec, vecUp)
      lane = tempDirVec:dot((pos - tempPosB):z0()) >= 0 and 1 or -1 -- positive if on right side of road
    end
  end

  for i = 1, amount do
    local newPos, newDir
    local newRot = quat()
    local step = i + start - 1
    local funcData = {step = step, route = route, startDist = dist, gap = gap, laneSide = lane, legalSide = legalSide, pos = pos, dir = dir}

    if options.func then -- custom spawn function
      newPos, newDir = options.func(funcData)
    elseif spawnModes[mode] then -- predefined spawn function
      newPos, newDir = spawnModes[mode](funcData)
    else -- default line method
      newPos, newDir = spawnModes.lineAhead(funcData)
    end

    if not newPos or not newDir then -- fallback method, this result should never fail
      newPos, newDir = spawnModes.lineAhead(funcData)
    end

    newDir.z = 0
    newRot:setFromDir(newDir, vecUp)
    newRot:setFromDir(vecY:rotated(newRot), vecUp)

    transformData[i] = {pos = newPos, rot = newRot}
  end

  return transformData
end

local function spawnProcessedGroup(spawnData, spawnOptions) -- sets the spawn points of multiple vehicles
  if not scenetree.MissionGroup then
    log('W', logTag, 'MissionGroup does not exist!')
    return
  end

  if not spawnData or not next(spawnData) then
    log('W', logTag, 'Vehicle spawn options array is empty!')
    return
  end

  if spawnOptions.mode == 'road' then spawnOptions.mode = 'roadAhead' end
  if spawnOptions.mode == 'lineAbove' then spawnOptions.cling = false end

  local transformData
  if spawnOptions and type(spawnOptions.customTransforms) == 'table' and #spawnOptions.customTransforms >= #spawnData then
    transformData = spawnOptions.customTransforms
  else
    transformData = createSpawnPositions(#spawnData, spawnOptions)
  end

  for i, v in ipairs(spawnData) do
    v.cling = spawnOptions.cling
    v.autoEnterVehicle = false
    v.pos = transformData[i].pos
    v.rot = transformData[i].rot
    spawnData[i] = sanitizeVehicleSpawnOptions(v.model, spawnData[i])
    spawnData[i].visibilityPoint = nil
    spawnData[i].removeTraffic = false
    spawnData[i].centeredPosition = not spawnOptions.ignoreAdjust and true or false
  end

  -- create a job that spawns one vehicle per frame
  extensions.core_jobsystem.create(workSpawnVehicles, 0.5, spawnData, spawnOptions)

  return getNewId()
end

local function workPlaceVehicles(job, vehIds, transformData, options) -- processes vehicles to be teleported
  options = options or {}
  for i, v in ipairs(vehIds) do
    local obj = getObjectByID(v)
    if obj then
      local pos = transformData[i].pos
      local rot = transformData[i].rot
      if not options.ignoreAdjust then
        local offset = obj:getInitialNodePosition(obj:getRefNodeId())
        offset = offset:rotated(rot)
        pos:setSub(offset)
      end

      if not options.ignoreSafe then
        spawn.safeTeleport(obj, pos, rot, nil, nil, false)
      else
        rot = quat(0, 0, 1, 0) * rot
        obj:setPosRot(pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
      end

      if job then
        job.sleep(0.02)
      end
    end
  end

  log('I', logTag, 'Vehicle group placing completed')
  extensions.hook('onVehicleGroupRespawned', vehIds)
end

local function placeGroup(vehIds, options) -- teleports a group of active vehicles into a new formation
  if not vehIds or not vehIds[1] then return end

  local transformData
  local instant = options and options.instant
  if options and type(options.customTransforms) == 'table' and #options.customTransforms >= #vehIds then
    transformData = options.customTransforms
  else
    transformData = createSpawnPositions(#vehIds, options)
  end

  if not instant then
    extensions.core_jobsystem.create(workPlaceVehicles, 1, vehIds, transformData, options) -- create a job that teleports one vehicle per frame
  else
    workPlaceVehicles(nil, vehIds, transformData, options)
  end
end

local function fitGroup(group, amount) -- fits a group to the given table size
  local groupSize = #group
  if groupSize == 0 then return group end
  amount = amount or groupSize
  local nextIndex = 0

  if groupSize < amount then
    for i = groupSize, amount - 1 do
      nextIndex = nextIndex + 1
      if (nextIndex % (groupSize + 1)) == 0 then
        nextIndex = 1
      end

      table.insert(group, deepcopy(group[nextIndex]))
    end
  elseif groupSize > amount then
    for i = groupSize, amount + 1, -1 do
      table.remove(group, i)
    end
  end

  return group
end

local function setVehicleSpawnData(group, amount) -- parses and sets the vehicle data from the spawn group
  if not group or not group[1] then
    log('W', logTag, 'Vehicle group is empty!')
    return
  end

  local spawnData = {}
  local groupCopy = deepcopy(group)
  groupCopy = fitGroup(groupCopy, amount)

  for i, options in ipairs(groupCopy) do
    if options[1] then -- old array format
      options = {model = options[1], config = options[2], paint = options[3], paint2 = options[4], paint3 = options[5]}
    end

    local modelData = core_vehicles.getModel(options.model)
    if modelData and next(modelData) then
      if not options.config or options.config == 'base' then
        options.config = modelData.model.default_pc
      end

      local paints = modelData.model.paints or {}
      local paintKeys = {'paint', 'paint2', 'paint3'}
      local paintNameKeys = {'paintName', 'paintName2', 'paintName3'}

      local str = "(Random)"
      if options.paintName == str then
        options.randomPaints = true
        if options.paintName2 == str and options.paintName3 == str then -- all are random, so assume multiPaintSetup
          options.randomMultiPaints = true
        end
      end

      if options.randomPaints or options.randomMultiPaints then
        local randomPaints
        if options.randomMultiPaints then
          randomPaints = core_vehiclePaints.createRandomMultiPaintSetup(options.model, options.config, true)
        else
          randomPaints = core_vehiclePaints.getRandomPaints(options.model, options.config)
        end
        if randomPaints and randomPaints.paintName1 then
          --log('I', logTag, string.format('Applying random paints for this vehicle: %s', options.model or ''))
          options.paintName = randomPaints.paintName1
          options.paintName2 = randomPaints.paintName2
          options.paintName3 = randomPaints.paintName3
        else
          log('W', logTag, string.format('Failed to get random paints for vehicle: %s (config: %s), using default paints', options.model or '', options.config or ''))
          options.paintName = modelData.model.defaultPaintName1 or 'White'
          options.paintName2 = modelData.model.defaultPaintName2 or modelData.model.defaultPaintName1 or 'White'
          options.paintName3 = modelData.model.defaultPaintName3 or modelData.model.defaultPaintName1 or 'White'
        end
      end

      for j, pName in ipairs(paintNameKeys) do
        local pKey = paintKeys[j]
        if options[pName] and not options[pKey] then
          options[pKey] = paints[options[pName]] -- gets actual paint data from the paint name
        end
      end

      spawnData[i] = options
    else
      log('E', logTag, string.format('Vehicle model not found: %s', options.model or ''))
      spawnData[i] = deepcopy(defaultOptions)
    end
  end
  return spawnData
end

local function spawnGroup(group, amount, options) -- spawns a given vehicle group
  if not amount or amount <= 0 then
    log('I', logTag, 'Spawn amount is zero, now returning nothing')
    return
  end

  if spawningBusy then
    table.insert(queue, {group, amount, options})
    log('I', logTag, 'Added vehicle group to queue, it will spawn when ready')
    return
  end

  if not group or not group[1] then
    log('I', logTag, 'Received empty group data, now creating default group...')
    group = createGroup()
  end

  options = options or {}
  options.name = options.name or 'custom' -- group name
  options.mode = options.mode or 'roadAhead' -- vehicle spawning method
  options.gap = options.gap or 15 -- spacing between spawn positions

  if options.randomPaints then
    for _, v in ipairs(group) do
      local modelData = core_vehicles.getModel(v.model or '')
      local configData = modelData.configs and modelData.configs[v.config or '']
      if configData then
        local configType = configData['Config Type']
        if not configType or configType == 'Factory' then -- only use random paints for factory or unknown configs
          v.randomPaints = true
        end
      else
        v.randomPaints = true
      end
    end
  end

  if options.shuffle then -- randomize group order
    group = arrayShuffle(deepcopy(group))
  end

  spawningBusy = true
  log('I', logTag, string.format('Spawning vehicle group with %d vehicles: %s', amount, options.name or ''))
  return spawnProcessedGroup(setVehicleSpawnData(group, amount), options) -- returns unique group id
end

local function setupVehicles(amount, shuffle, spawnMode, spawnGap) -- DEPRECATED, please use function spawnGroup instead
  log('W', logTag, 'This function is deprecated, please use function: spawnGroup')
  return spawnGroup(createGroup(), amount, {shuffle = shuffle, mode = spawnMode, gap = spawnGap})
end

local function deleteVehicles(amount, groupName) -- deletes vehicles that were spawned via this system
  -- the traffic UI app uses this function
  local vehicles = getAllVehicles()
  local count = 0
  for i = #vehicles, 1, -1 do
    if amount and count >= amount then break end

    if vehicles[i].vehicleGroup then
      if not groupName or vehicles[i].vehicleGroup == groupName then -- matches vehicle group name, otherwise doesn't care what it is
        vehicles[i]:delete()
        count = count + 1
      end
    end
  end
end

local function onSpawnCCallback(id)
  if spawningBusy then -- assumes that multispawn is currently spawning vehicles with no interruptions
    core_vehicle_manager.queueAdditionalVehicleData({spawnWithEngineRunning = M.startEngines}, id) -- start with engines running by default
  end
end

-- public interface
M.deleteVehicles = deleteVehicles
M.setupVehicles = setupVehicles
M.getInstalledVehicleData = getInstalledVehicleData
M.vehIdsToGroup = vehIdsToGroup
M.spawnedVehsToGroup = spawnedVehsToGroup

M.createGroup = createGroup
M.spawnGroup = spawnGroup
M.spawnProcessedGroup = spawnProcessedGroup
M.fitGroup = fitGroup
M.placeGroup = placeGroup
M.teleportGroup = placeGroup
M.setVehicleSpawnData = setVehicleSpawnData

M.onSpawnCCallback = onSpawnCCallback

return M