-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Pursuit manager for handling multiple chasers and evaders as a gameplay event (players and/or NPCs)
-- Only one gameplay instance at a time; support for multiple instances may be added in the future

local M = {}

local logTag = 'pursuitMode'

local manager = {} -- main manager object
local newVeh = require('gameplay/traffic/vehicle')

local defaults = {
  graceTime = 10
}

local function getDistance(vehId1, vehId2) -- returns the distance between two vehicles
  return manager.vehData[vehId1].pos:distance(manager.vehData[vehId2].pos)
end

local function getBestTarget(vehId) -- returns the best target for a given vehicle
  -- flee vehicle: closest chase vehicle
  -- chase vehicle: best catchable flee vehicle, depending on position, direction, and speed

  local bestTarget = nil
  local bestDist = math.huge
  local bestScore = 0 -- higher score means better target

  -- TODO: improve and optimize
  if manager.chaseVehs[vehId] then
    for otherId, otherData in pairs(manager.fleeVehs) do
      if otherData.pursuitUsable then
        local dist = getDistance(vehId, otherId)
        if dist < bestDist then
          bestTarget = otherId
          bestDist = dist
        end
      end
    end
  elseif manager.fleeVehs[vehId] then
    for otherId, otherData in pairs(manager.chaseVehs) do
      if otherData.pursuitUsable then
        local dist = getDistance(vehId, otherId)
        if dist < bestDist then
          bestTarget = otherId
          bestDist = dist
        end
      end
    end
  end

  return bestTarget, bestDist, bestScore
end

local function updateTarget(vehId) -- updates the target for a given vehicle
  local vehData = manager.vehData[vehId]
  if not vehData then return end

  local bestTarget, _, _ = getBestTarget(vehId)
  if bestTarget then
    vehData.role:setTarget(bestTarget)
  else
    vehData.role.targetId = nil
    vehData.role:resetAction()
  end
end

local function setupGoals(options) -- creates and validates the goals before gameplay starts
  options = options or manager.options -- use manager.options as a fallback
  if not options then return end

  local goals = manager.goals
  if not goals then return end

  goals.mode = options.gameMode or 'free'
  goals.time = options.timeLimit or -1
  goals.score = options.scoreGoal or -1
  goals.arrests = options.arrestGoal or -1
  goals.locations = options.locationGoal or -1

  if goals.mode ~= 'free' then
    if goals.mode == 'timed' then
      if goals.time < 0 then
        goals.time = 0
      end
      if goals.arrests <= 0 then
        goals.arrests = tableSize(manager.fleeVehs)
      end
    end
    if goals.time ~= -1 then
      goals.time = math.max(30, goals.time) -- at least 30 seconds
    end

    if goals.mode == 'score' then
      goals.score = math.max(100, goals.score) -- at least 100 points
    end

    if goals.mode == 'destination' then
      goals.locations = math.max(1, goals.locations) -- at least 1 location
    end
  end
end

local function insertVeh(vehId, isChase, isAiControlled, options) -- validates and inserts a vehicle into the pursuit manager
  if not vehId or manager.vehData[vehId] then return end
  options = options or {}
  local vehData
  local traffic = gameplay_traffic.getTraffic()
  if not traffic[vehId] then
    vehData = newVeh({id = vehId})
    if vehData then
      if isAiControlled then
        vehData.isAi = true
        local obj = getObjectByID(vehId)
        obj.playerUsable = false
        gameplay_walk.addVehicleToBlacklist(vehId)
      end
    end
  else -- use traffic table as reference
    vehData = traffic[vehId]
    vehData.isShared = true -- vehicle is used in traffic manager and this pursuit manager
    vehData.isAi = isAiControlled
    log('I', logTag, 'Using existing traffic data for vehicle: '..vehId)
  end

  if not vehData then
    return false
  end

  vehData.pursuitClass = isChase and 'chase' or 'flee'
  vehData.pursuitUsable = true -- if true, vehicle can be targeted by others
  vehData.ignorePursuit = true -- if true, vehicle will be ignored by the main traffic police system
  vehData.enableAutoPooling = false
  vehData.enableRespawn = false
  vehData.getTraffic = function () return manager.fleeVehs end
  vehData.getPolice = function () return manager.chaseVehs end

  manager.vehData[vehId] = vehData
  table.insert(manager.vehIds, vehId)
  if isChase then
    vehData:setRole('police')
    manager.chaseVehs[vehId] = vehData
  else
    vehData:setRole('suspect')
    manager.fleeVehs[vehId] = vehData
  end

  if vehData.isAi then
    vehData:setAiMode('stop')
  else
    vehData:setAiMode('disabled')
  end

  return true
end

local function removeVeh(vehId) -- removes a vehicle from the pursuit manager
  if not manager.vehData[vehId] then return end

  manager.vehData[vehId] = nil
  table.remove(manager.vehIds, arrayFindValueIndex(manager.vehIds, vehId))
  manager.chaseVehs[vehId] = nil
  manager.fleeVehs[vehId] = nil

  local traffic = gameplay_traffic.getTraffic()
  if traffic[vehId] then
    traffic[vehId]:setRole(traffic[vehId].autoRole)
    traffic[vehId].getTraffic = gameplay_traffic.getTraffic
    traffic[vehId].getPolice = gameplay_police.getPolice
  end
end

local function resetVehs() -- resets all vehicles
  for vehId, vehData in pairs(manager.vehData) do
    if vehData.isAi then vehData:setAiMode('stop') end
    if vehData.pursuitClass == 'chase' then
      getObjectByID(vehData.id):queueLuaCommand('electrics.set_lightbar_signal(0)') -- temporary; consider using role action
    else
      vehData:resetPursuit()
    end
    vehData.role.targetId = nil

    --local veh = getObjectByID(vehId)
    --veh:requestReset(RESET_PHYSICS)
    --veh:resetBrokenFlexMesh()
    core_vehicleBridge.executeAction(getObjectByID(vehId), 'interactRecovery', 'loadHome')
  end
end

local function activateVehs() -- activates all vehicles
  manager.state = 'active'
  manager.running = true

  if not next(manager.chaseVehs) or not next(manager.fleeVehs) then
    log('E', logTag, 'Pursuit setup failed due to missing required vehicles')
  end

  for vehId, vehData in pairs(manager.chaseVehs) do
    vehData.role:setTarget(getBestTarget(vehId)) -- random target might be better at the start?
    vehData.role:setAction('pursuitStart', {mode = 3, targetId = vehData.role.targetId})
    vehData.pursuit.timers.respawn = 0
    vehData.role.sirenTimer = -1 -- disable siren timer
  end
  for vehId, vehData in pairs(manager.fleeVehs) do
    vehData.role:setTarget(getBestTarget(vehId))
    vehData.role:setAction('fleePolice')
    vehData.pursuit.mode = 1
    vehData.pursuit.timers.respawn = 0
    extensions.hook('onPursuitAction', vehId, 'start', vehData.pursuit)
  end
end

local function resetActiveData() -- resets gameplay data
  manager.data = {duration = 0, arrests = 0, totalScore = 0, tempScore = 0, locations = 0, roadblocks = 0} -- gameplay data
  manager.stuckTimer = 0 -- increments while all vehicles are stuck
  manager.tickTimer = 0 -- increments at a low frequency
end

local function reset() -- completely resets the pursuit manager
  if manager.running then M.stop() end

  table.clear(manager)
  manager.vehData = {}
  manager.vehIds = {} -- array of main vehicle ids (not including roadblocks)
  manager.chaseVehs = {}
  manager.fleeVehs = {}
  manager.roadblockVehs = {} -- stationary vehicles used as roadblocks
  manager.roadblockProps = {} -- props used as roadblocks (barriers, spikes, etc.)
  manager.options = {} -- gameMode, recoveryMode, startSpeed, markRunners, timeLimit, scoreGoal, arrestGoal, locationGoal
  manager.goals = {mode = 'free', time = -1, score = -1, arrests = -1, locations = -1}
  manager.state = 'off' -- 'off', 'ready', 'active', 'inactive', 'complete'
  manager.running = false -- true if state is active, inactive, or complete
  resetActiveData()
  resetVehs()
  gameplay_police.setPursuitVars() -- reset pursuit variables to default
end
reset()

local function restart() -- restarts pursuit gameplay without resetting the manager (does not start gameplay)
  manager.state = 'ready'
  manager.running = false
  resetActiveData()
  resetVehs()

  log('I', logTag, 'Pursuit manager gameplay restarted and now waiting for start')
end

local function start() -- starts pursuit gameplay
  if manager.state ~= 'ready' and manager.state ~= 'inactive' then return end
  activateVehs()

  extensions.hook('onPursuitGameplayStarted')
  log('I', logTag, 'Pursuit manager gameplay started')
end

local function stop(winner) -- stops pursuit gameplay (finalizes the gameplay if a winner is specified)
  if manager.state ~= 'active' then return end
  manager.state = winner ~= nil and 'complete' or 'inactive'

  for vehId, vehData in pairs(manager.vehData) do
    if vehData.isAi then vehData:setAiMode('stop') end
    if vehData.pursuitClass == 'chase' then
      getObjectByID(vehData.id):queueLuaCommand('electrics.set_lightbar_signal(0)') -- temporary; consider using role action
    else
      if winner then
        vehData:resetPursuit()
      end
    end
    vehData.role.targetId = nil
  end

  if winner then
    extensions.hook('onPursuitGameplayFinished', {winningTeam = winner})
  end
  log('I', logTag, 'Pursuit manager gameplay stopped')
end

local function filterParkingSpots(parkingSpots, chaseAmount, fleeAmount) -- checks parking spots for flee and chase tags, then returns a fitted array of parking spots, if possible
  parkingSpots = shallowcopy(parkingSpots)

  if chaseAmount and fleeAmount then -- rework the parking spots array to contain n chase spots and n flee spots
    local psChase, psFlee = {}, {}
    for _, ps in ipairs(parkingSpots) do
      if chaseAmount <= 0 then break end
      if ps.customFields.tags.chase and not ps.customFields.tags.flee then
        table.insert(psChase, ps)
        chaseAmount = chaseAmount - 1
      end
    end
    for _, ps in ipairs(parkingSpots) do
      if fleeAmount <= 0 then break end
      if ps.customFields.tags.flee and not ps.customFields.tags.chase then
        table.insert(psFlee, ps)
        fleeAmount = fleeAmount - 1
      end
    end

    if psChase[1] and psFlee[1] then
      parkingSpots = arrayConcat(psChase, psFlee)
    else
      log('W', logTag, 'Failed to get enough tagged parking spots; using default parking spots instead')
    end
  end

  return parkingSpots
end

local function setupPursuit(chaseVehId, fleeVehId, options, pursuitVars) -- creates pursuit with one chase vehicle and one flee vehicle
  if manager.state ~= 'off' then
    reset()
  end

  local chaseVeh = getObjectByID(chaseVehId)
  if not chaseVeh then
    log('E', logTag, 'Missing or invalid chase vehicle: '..chaseVehId)
    return false
  end

  local fleeVeh = getObjectByID(fleeVehId)
  if not fleeVeh then
    log('E', logTag, 'Missing or invalid flee vehicle: '..fleeVehId)
    return false
  end

  insertVeh(chaseVehId, true, not chaseVeh:isPlayerControlled(), options)
  insertVeh(fleeVehId, false, not fleeVeh:isPlayerControlled(), options)

  manager.options = options or manager.options
  manager.state = 'ready'
  manager._tempData = nil

  setupGoals()
  if pursuitVars then
    gameplay_police.setPursuitVars(pursuitVars)
  end

  return true
end

local function setupPursuitMulti(chaseVehIds, fleeVehIds, options, pursuitVars) -- creates pursuit with multiple chase vehicles and multiple flee vehicles
  if manager.state ~= 'off' then
    reset()
  end

  for _, vehId in ipairs(chaseVehIds) do
    local veh = getObjectByID(vehId)
    if veh then
      insertVeh(vehId, true, not veh:isPlayerControlled(), options)
    end
  end

  for _, vehId in ipairs(fleeVehIds) do
    local veh = getObjectByID(vehId)
    if veh then
      insertVeh(vehId, false, not veh:isPlayerControlled(), options)
    end
  end

  local expectedCount = #chaseVehIds + #fleeVehIds
  local actualCount = #manager.vehIds

  if not next(manager.chaseVehs) then
    log('E', logTag, 'Setup failed, no chase vehicles inserted!')
    reset()
    return false
  elseif not next(manager.fleeVehs) then
    log('E', logTag, 'Setup failed, no flee vehicles inserted!')
    reset()
    return false
  elseif actualCount < expectedCount then
    log('W', logTag, 'Some vehicles failed to be inserted; results: '..actualCount..' / '..expectedCount)
    -- allowed to continue, for now
  end

  manager.options = options or manager.options
  manager.state = 'ready'
  manager._tempData = nil

  setupGoals()
  if pursuitVars then
    gameplay_police.setPursuitVars(pursuitVars)
  end

  return true
end

local function _setupVehicles(chaseAmount, fleeAmount, chaseVehGroup, fleeVehGroup, transforms, options) -- internal function for spawning and preparing vehicles
  chaseVehGroup = deepcopy(chaseVehGroup)
  fleeVehGroup = deepcopy(fleeVehGroup)

  if options.shuffleVehGroups then
    arrayShuffle(chaseVehGroup)
    arrayShuffle(fleeVehGroup)
  end

  core_multiSpawn.fitGroup(chaseVehGroup, chaseAmount)
  core_multiSpawn.fitGroup(fleeVehGroup, fleeAmount)

  if #transforms >= chaseAmount + fleeAmount then -- enough start positions exist
    local chaseTransforms, fleeTransforms = {}, {}
    for i = 1, chaseAmount do
      table.insert(chaseTransforms, transforms[i])
    end
    for i = chaseAmount + 1, chaseAmount + fleeAmount do
      table.insert(fleeTransforms, transforms[i])
    end

    core_multiSpawn.spawnGroup(chaseVehGroup, chaseAmount, {name = 'autoPursuitChase', customTransforms = chaseTransforms})
    core_multiSpawn.spawnGroup(fleeVehGroup, fleeAmount, {name = 'autoPursuitFlee', customTransforms = fleeTransforms})
  else -- lacking start positions; auto place vehicles
    core_multiSpawn.spawnGroup(chaseVehGroup, chaseAmount, {name = 'autoPursuitChase', mode = 'roadAhead', gap = 15})
    core_multiSpawn.spawnGroup(fleeVehGroup, fleeAmount, {name = 'autoPursuitFlee', mode = 'roadAhead', gap = 15, startIndex = chaseAmount + 1})
  end

  return true
end

local function setupVehicles(chaseAmount, fleeAmount, chaseVehGroup, fleeVehGroup, parkingSpots, options, pursuitVars) -- spawns and prepares vehicles for pursuit gameplay
  -- chaseVehGroup = vehicle group array {model, config, etc.} for chase vehicles
  -- fleeVehGroup = vehicle group array {model, config, etc.} for flee vehicles
  -- parkingSpots = array of parking spots; if none given, function will attempt to auto place vehicles

  chaseAmount = chaseAmount or 1
  fleeAmount = fleeAmount or 1
  chaseVehGroup = chaseVehGroup or core_multiSpawn.createGroup()
  fleeVehGroup = fleeVehGroup or core_multiSpawn.createGroup()

  options = options or {}
  manager._tempData = {options = options, pursuitVars = pursuitVars}

  if chaseAmount < 1 or fleeAmount < 1 then
    log('E', logTag, 'Pursuit mode requires at least one chase and one flee vehicle (currently: '..chaseAmount..', '..fleeAmount..')')
    return false
  end

  local transforms = {}
  if type(parkingSpots) == 'table' then
    for _, ps in ipairs(parkingSpots) do
      table.insert(transforms, {pos = ps.pos, rot = ps.rot})
    end
  end

  return _setupVehicles(chaseAmount, fleeAmount, chaseVehGroup, fleeVehGroup, transforms, options)
end

local function setupVehiclesFromFiles(chaseAmount, fleeAmount, chaseVehGroupFile, fleeVehGroupFile, sitesFile, options, pursuitVars) -- spawns and prepares vehicles for pursuit gameplay (using file paths)
  -- chaseVehGroupFile & fleeVehGroupFile = file name of json file containing vehicle group data
  -- sitesFile = file name of json file containing parking spots (optional)
  -- sites file data can also contain zones that enclose groups of parking spots; use options.zoneName to use a specific zone

  options = options or {}
  manager._tempData = {options = options, pursuitVars = pursuitVars}

  if chaseAmount < 1 or fleeAmount < 1 then
    log('E', logTag, 'Pursuit mode requires at least one chase and one flee vehicle (currently: '..chaseAmount..', '..fleeAmount..')')
    return false
  end

  local chaseVehGroup, fleeVehGroup, parkingSpots

  local chaseVehData = jsonReadFile(chaseVehGroupFile)
  if chaseVehData and chaseVehData.data then
    chaseVehGroup = chaseVehData.data
  end

  local fleeVehData = jsonReadFile(fleeVehGroupFile)
  if fleeVehData and fleeVehData.data then
    fleeVehGroup = fleeVehData.data
  end

  if sitesFile and FS:fileExists(sitesFile) then
    local sites = gameplay_sites_sitesManager.loadSites(sitesFile)
    if sites then
      local parkingSpots = sites.parkingSpots.sorted
      if options.zoneName then
        if sites.zones.byName[options.zoneName] then
          parkingSpots = sites.zones.byName[options.zoneName].parkingSpots
        end
      end
      if options.shuffleSpots then
        parkingSpots = arrayShuffle(shallowcopy(parkingSpots))
      end
      parkingSpots = filterParkingSpots(parkingSpots, chaseAmount, fleeAmount)
    end
  end

  if not chaseVehGroup then
    log('E', logTag, 'Failed to read chase vehicle group file: '..chaseVehGroupFile)
    return false
  elseif not fleeVehGroup then
    log('E', logTag, 'Failed to read flee vehicle group file: '..fleeVehGroupFile)
    return false
  end

  local transforms = {}
  if parkingSpots then
    for _, ps in ipairs(parkingSpots) do
      table.insert(transforms, {pos = ps.pos, rot = ps.rot})
    end
  end

  return _setupVehicles(chaseAmount, fleeAmount, chaseVehGroup, fleeVehGroup, transforms, options)
end

local function getManager() -- returns the main manager object
  return manager
end

local function onPursuitAction(vehId, action, pursuit)
  if manager.state ~= 'active' or not manager.fleeVehs[vehId] then return end
  local targetVeh = manager.fleeVehs[vehId]

  if action == 'start' then
  elseif action == 'arrest' then
    targetVeh.role:setAction('arrest')
    targetVeh.pursuitUsable = false
    manager.data.arrests = manager.data.arrests + 1
    for vehId, vehData in pairs(manager.chaseVehs) do
      if vehData.role.targetId == vehId then
        vehData.role:setAction('pursuitEnd')
      end
    end
  elseif action == 'evade' then
    targetVeh.role:setAction('clear')
    targetVeh.pursuitUsable = false
    local nextTargetId
    for vehId, vehData in pairs(manager.fleeVehs) do
      if targetVeh.pursuitUsable then
        nextTargetId = vehId
        break
      end
    end
    for vehId, vehData in pairs(manager.chaseVehs) do
      if vehData.role.targetId == vehId then
        if nextTargetId then
          vehData.role:setTarget(nextTargetId)
        else
          vehData.role:resetAction() -- no other targets available
        end
      end
    end
  elseif action == 'release' then
    if manager.data.arrests < manager.goals.arrests then
      if manager.options.recoveryMode == 'none' then
        -- do nothing
      elseif manager.options.recoveryMode == 'basic' then
        targetVeh.role:setAction('fleePolice') -- flee again on the spot
        targetVeh.pursuitUsable = true
      else
        targetVeh.state = 'fadeOutAlt' -- vehicle fade transition
      end
    end
  elseif action == 'roadblockAlert' then
  elseif action == 'roadblock' then
  end
end

local function onUpdate(dt, dtSim)
  if manager.state ~= 'off' then
    for _, vehData in pairs(manager.vehData) do
      if not vehData.isShared then
        vehData:onUpdate(dt, dtSim)
      end
    end
  end

  if manager.state == 'ready' and manager.options.startSpeed then
    for _, vehData in pairs(manager.fleeVehs) do
      if vehData.speed >= manager.options.startSpeed then -- auto trigger start based on speed
        start()
        break
      end
    end
  end

  if manager.state == 'active' then
    manager.data.duration = manager.data.duration + dtSim
    manager.tickTimer = manager.tickTimer + dtSim
    if manager.tickTimer >= 1 then -- every second
      for vehId, vehData in pairs(manager.vehData) do
        if vehData.isAi then
          vehData.role:setTarget(getBestTarget(vehId))
        end
      end
      manager.tickTimer = manager.tickTimer - 1

      if manager.stuckTimer >= defaults.graceTime then
        if manager.options.autoRecovery then
          for vehId, vehData in pairs(manager.vehData) do
            local spawnData = gameplay_traffic_trafficUtils.findSpawnPointRadial(vehData.pos, vehData.dirVec, 0, 10000, 0, {gap = 20})
            spawnData.rot = quatFromDir(spawnData.dir, map.surfaceNormal(spawnData.pos))
            spawn.safeTeleport(getObjectByID(vehId), spawnData.pos, spawnData.rot)
          end
          extensions.hook('onPursuitGameplayEvent', 'recoverAll')
        else
          stop('none')
          log('I', logTag, 'All vehicles are stuck and cannot continue')
          extensions.hook('onPursuitGameplayEvent', 'stuckAll')
        end
        manager.stuckTimer = 0
      end

      if manager.data.duration >= defaults.graceTime then
        local maxSpeed = 0
        for _, vehData in pairs(manager.vehData) do
          if vehData.pursuit.timers.arrest ~= 0 then
            maxSpeed = math.huge
            break
          else
            maxSpeed = math.max(maxSpeed, vehData.speed)
          end
        end
        if maxSpeed < 2.5 then -- this means all vehicles are stuck
          manager.stuckTimer = manager.stuckTimer + 1
        else
          manager.stuckTimer = 0
        end
      end
    end

    for vehId, vehData in pairs(manager.vehData) do
      if manager.data.duration < defaults.graceTime then
        vehData.pursuit.timers.arrest = 0 -- reset arrest timers while grace time is active
      end
      if vehData.state == 'fadeOutAlt' or vehData.state == 'fadeInAlt' then
        vehData:fade(dtSim * 4, vehData.state == 'fadeOutAlt')
      end
      if vehData.state == 'queued' then
        if manager.options.recoveryMode == 'teleportRoad' then
          local spawnData = gameplay_traffic_trafficUtils.findSpawnPointRadial(vehData.pos, vehData.dirVec, 0, 10000, 0, {gap = 20})
          spawnData.rot = quatFromDir(spawnData.dir, map.surfaceNormal(spawnData.pos))
          spawn.safeTeleport(getObjectByID(vehId), spawnData.pos, spawnData.rot)
        elseif manager.options.recoveryMode == 'teleportStart' then
          core_vehicleBridge.executeAction(getObjectByID(vehId), 'interactRecovery', 'loadHome')
        elseif manager.options.recoveryMode == 'teleportRandom' then
          local spawnData = gameplay_traffic_trafficUtils.findSpawnPointRadial(vehData.pos, vehData.dirVec, 50 + math.random() * 200, 10000, 50)
          spawnData.rot = quatFromDir(spawnData.dir, map.surfaceNormal(spawnData.pos))
          spawn.safeTeleport(getObjectByID(vehId), spawnData.pos, spawnData.rot)
        end
        vehData.state = 'fadeInAlt'
        vehData.role:setTarget(getBestTarget(vehId))
        vehData.role:setAction('fleePolice')
        vehData.pursuit.mode = 1
        vehData.pursuitUsable = true
      end
    end

    manager.data.totalScore = 0
    for _, vehData in pairs(manager.fleeVehs) do
      manager.data.totalScore = manager.data.totalScore + vehData.pursuit.score
    end

    if manager.goals.time > 0 and manager.data.duration >= manager.goals.time then
      manager.data.duration = manager.goals.time
      if manager.goals.mode == 'timed' then
        stop('flee')
        log('I', logTag, 'Time over, flee team wins')
      else
        stop('chase')
        log('I', logTag, 'Time over, chase team wins')
      end
    end
    if manager.goals.score > 0 and manager.data.totalScore >= manager.goals.score then
      manager.data.totalScore = manager.goals.score
      stop('flee')
      log('I', logTag, 'Score achieved, flee team wins')
    end
    if manager.goals.arrests > 0 and manager.data.arrests >= manager.goals.arrests then
      stop('chase')
      log('I', logTag, 'Arrests achieved, chase team wins')
    end
  elseif manager.state == 'inactive' then
    for _, vehData in pairs(manager.fleeVehs) do -- maybe temporary, but blocks arrest and evade actions
      vehData.pursuit.timers.arrest = 0
      vehData.pursuit.timers.evade = 0
    end
  end
end

local function onVehicleGroupSpawned(vehList, groupId, groupName)
  if not manager._tempData then return end

  if groupName == 'autoPursuitChase' then
    manager._tempData.chaseVehIds = vehList
  elseif groupName == 'autoPursuitFlee' then
    manager._tempData.fleeVehIds = vehList
    if tableIsEmpty(manager._tempData.chaseVehIds) or tableIsEmpty(manager._tempData.fleeVehIds) then
      log('E', logTag, 'Pursuit setup failed due to vehicle spawning errors')
      reset()
      return
    end
  else
    return
  end

  local data = deepcopy(manager._tempData)
  if not tableIsEmpty(data.chaseVehIds) and not tableIsEmpty(data.fleeVehIds) then
    setupPursuitMulti(data.chaseVehIds, data.fleeVehIds, data.options, data.pursuitVars)
  end
end

local function onTrafficStarted() -- merges manager data into traffic data
  local traffic = gameplay_traffic.getTraffic()
  for id, veh in pairs(traffic) do
    if manager.vehData[id] then
      traffic[id] = manager.vehData[id]
    end
  end
end

local function onTrafficStopped()
end

local function onTrafficAmountChanged()
end

local function onSerialize()
  local data = {
    manager = {
      roadblockVehs = deepcopy(manager.roadblockVehs),
      roadblockProps = deepcopy(manager.roadblockProps),
      options = deepcopy(manager.options),
      goals = deepcopy(manager.goals),
      data = deepcopy(manager.data),
      state = manager.state,
      running = manager.running,
      stuckTimer = manager.stuckTimer
    },
    vehicles = {}
  }

  for _, vehId in ipairs(manager.vehIds) do
    local vehData = manager.vehData[vehId]
    table.insert(data.vehicles, {
      data = vehData:onSerialize(),
      pursuitClass = vehData.pursuitClass,
      pursuitUsable = vehData.pursuitUsable
    })
  end

  return data
end

local function onDeserialized(data)
  reset()
  tableMerge(manager, data.manager)

  for _, storedVeh in ipairs(data.vehicles) do
    local vehData = storedVeh.data
    local isChase = storedVeh.pursuitClass == 'chase'
    insertVeh(vehData.id, isChase, vehData.isAi)
    local restoredVeh = manager.vehData[vehData.id]
    restoredVeh:onDeserialized(vehData)
    restoredVeh.pursuitClass = storedVeh.pursuitClass
    restoredVeh.pursuitUsable = storedVeh.pursuitUsable
  end
end

M.reset = reset
M.restart = restart
M.start = start
M.stop = stop
M.insertVeh = insertVeh
M.removeVeh = removeVeh
M.setupGoals = setupGoals
M.setupPursuit = setupPursuit
M.setupPursuitMulti = setupPursuitMulti
M.setupVehicles = setupVehicles
M.setupVehiclesFromFiles = setupVehiclesFromFiles
M.filterParkingSpots = filterParkingSpots
M.getManager = getManager

M.onUpdate = onUpdate
M.onPursuitAction = onPursuitAction
M.onVehicleGroupSpawned = onVehicleGroupSpawned
M.onTrafficStarted = onTrafficStarted
M.onTrafficStopped = onTrafficStopped
M.onTrafficAmountChanged = onTrafficAmountChanged
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M