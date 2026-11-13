-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max
local abs = math.abs
local random = math.random
local huge = math.huge

local C = {}

local logTag = 'traffic'

local TICK_TIME = 0.25
local SLOW_SPEED = 2.5

local tempPos, tempDirVec = vec3(), vec3()

-- const vectors --
local vecUp = vec3(0, 0, 1)

function C:init(id, role)
  id = id or 0
  local obj = getObjectByID(id)
  if not obj then
    log('E', logTag, string.format('Vehicle not found: %d', id))
    return
  elseif obj.ignoreTraffic then
    log('I', logTag, string.format('Ignoring traffic vehicle due to blocking flag: %d', id))
    return
  end

  getObjectByID(id):setMeshAlpha(1, '') -- force vehicle to be visible
  if gameplay_seatOccupants and obj:isPlayerControlled() then gameplay_seatOccupants.refreshOccupantMeshes(id) end -- keep empty seat occupants hidden

  self.collisions = {} -- keys: vehicle id, values: collision data
  self.queuedFuncs = {} -- keys: name id, values: timer, func, args, vLua (vLua string overrides func and args)
  self.activeData = {} -- miscellaneous active data

  self.id = id
  self.state = 'reset'
  self.enableRespawn = true
  self.enableTracking = true
  self.enableAutoPooling = true
  self.camVisible = true
  self.headlights = false
  self.isAi = false
  self.isPerson = obj.jbeam == 'unicycle'
  self.isVehicle = not self.isPerson
  self.isPlayerControlled = obj:isPlayerControlled()
  self.focus = gameplay_traffic.getFocus()
  self.focusDist = 0

  -- self tracking object
  self.tracking = require('gameplay/traffic/roadTracking')({vehId = id})

  -- getters (can be externally accessed and modified, if needed)
  self.getTraffic = gameplay_traffic.getTraffic
  self.getPolice = gameplay_police.getPolice
  self.getTrafficVars = gameplay_traffic.getTrafficVars
  self.getPoliceVars = gameplay_police.getPoliceVars

  self:resetAll()

  if core_trailerRespawn and core_trailerRespawn.getTrailerData()[id] then -- assumes that this vehicle will always respawn with a trailer attached
    self.hasTrailer = true
  end

  self.debugLine = true
  self.debugText = true

  self.model = obj.jbeam
  self.width = obj.initialNodePosBB:getExtents().x
  self.length = obj.initialNodePosBB:getExtents().y

  self.pos, self.targetPos, self.dirVec, self.vel, self.driveVec = vec3(), vec3(), vec3(), vec3(), vec3()
  self.damage = 0
  self.speed = 0
  self.alpha = 1
  self.respawnCount = 0
  self.tickTimer = 0
  self.activeProbability = 1

  -- the following properties get updated in postInit
  self.modelName = self.model
  self.drivability = 0.5
  self.useRandomPaint = false
  self.autoRole = 'empty'
  self:setRole(self.autoRole)
end

function C:postInit() -- recommended to call this after the vehicle was initialized
  self:applyModelConfigData()
  self:setRole(self.autoRole)
end

function C:applyModelConfigData() -- sets data and role that depends on the vehicle model & config
  local obj = getObjectByID(self.id)

  local modelData = core_vehicles.getModel(obj.jbeam).model
  local _, configKey = path.splitWithoutExt(obj.partConfig)
  local configData = core_vehicles.getModel(obj.jbeam).configs[configKey]
  local modelType = modelData and string.lower(modelData.Type) or 'none'
  if obj.jbeam == 'unicycle' and obj:isPlayerControlled() then modelType = 'player' end
  if not modelData or not arrayFindValueIndex({'car', 'truck', 'automation', 'traffic', 'proptraffic', 'player'}, modelType) then
    log('I', logTag, string.format('Traffic vehicle status is false: %d', self.id))
    self.isVehicle = false
  end

  if not self.isVehicle then
    self.isAi = false
  end

  local modelName = obj.jbeam
  local vehType = modelData.Type
  local configType = configData and configData['Config Type']
  local width = obj.initialNodePosBB:getExtents().x
  local length = obj.initialNodePosBB:getExtents().y
  local useRandomPaint = false

  if modelData.Name then
    modelName = modelData.Brand and string.format('%s %s', modelData.Brand, modelData.Name) or modelData.Name
  end
  if obj.jbeam == 'simple_traffic' then -- special case for simplified traffic vehicles
    local partConfigStr = obj.partConfig
    local _, key = path.splitWithoutExt(partConfigStr)
    key = string.match(key, '%w*')
    if key then
      local tempModel = core_vehicles.getModelList().models[key] or {Name = 'Unknown'} -- TODO: avoid unknown
      modelName = tempModel.Brand and string.format('%s %s', tempModel.Brand, tempModel.Name) or tempModel.Name
    end
  end

  if modelData.paints and next(modelData.paints) and (not configType or configType == 'Factory' or vehType == 'Traffic') then
    useRandomPaint = true
  end

  local drivability = 0.25
  local role = self.isVehicle and 'standard' or 'empty'
  if self.isVehicle then
    local offRoadScore = configData and configData['Off-Road Score']
    if offRoadScore then
      drivability = clamp(10 / max(1e-12, offRoadScore - 4 * max(0, width - 2) - 4 * max(0, length - 5)), 0, 1) -- minimum drivability
      -- large vehicles lower this value even more
      -- this is rough and could be improved
    end

    local configTypeLower = string.lower(configType or '')
    local pc = string.lower(obj.partConfig)
    if configTypeLower == 'police' then
      role = 'police'
    elseif string.endswith(pc, '.pc') and string.find(pc, 'police') then -- assumes police vehicle
      role = 'police'
      log('I', logTag, string.format('Assigning police role using file name method: %d', self.id))
    end
    if string.find(pc, 'taxi') then
      self.isTaxi = true
    end
  end

  self.modelName = modelName
  self.drivability = drivability
  self.useRandomPaint = useRandomPaint
  self.autoRole = role
end

function C:resetPursuit()
  if self.pursuit and self.pursuit.mode ~= 0 then
    gameplay_police.setPursuitMode(0, self.id)
  end
  self.pursuit = {mode = 0, score = 0, addScore = 0, policeCount = 0, hitCount = 0, offensesCount = 0, uniqueOffensesCount = 0,
  sightValue = 0, roadblocks = 0, roadblockTargetId = 0, policeWrecks = 0, offenses = {}, offensesList = {}, sight = {}, flags = {}}
  self.pursuit.timers = {main = 0, arrest = 0, evade = 0, roadblock = 0, stuck = 0, arrestValue = 0, evadeValue = 0}
end

function C:resetTracking()
  self.tracking:refresh()
  self.collisionCount = 0
  self.prevDamage = (be:getObjectActive(self.id) and map.objects[self.id]) and map.objects[self.id].damage or 0
  self.crashDamage = 0
end

function C:resetValues()
  self.pos = self.pos or getObjectByID(self.id):getPosition()
  self.respawn = {
    spawnValue = self.getTrafficVars().spawnValue, -- respawnability coefficient, from 0 (slow) to 3 (rapid); exactly 0 disables respawning
    spawnDirBias = self.getTrafficVars().spawnDirBias, -- probability of direction of next respawn, from -1 (away from you) to 1 (towards you)
    spawnRandomization = 1, -- spawn point search randomization (from 0 to 1; 0 = straight ahead, 1 = branching and scattering)
    activeRadius = self.pos:distance(self.focus.pos) + 500, -- radius to stay active in (compares distance to focus point)
    finalRadius = 1e6, -- calculated active radius
    innerRadius = 50, -- minimum inner radius to stay active in (compares distances of non-traffic vehicles)
    staticVisibility = 1 -- world visibility value (lower if occluded)
  }
  table.clear(self.collisions)
  table.clear(self.queuedFuncs)
  table.clear(self.activeData)
end

function C:resetElectrics()
  local obj = getObjectByID(self.id)
  obj:queueLuaCommand('electrics.set_lightbar_signal(0)')
  obj:queueLuaCommand('electrics.set_warn_signal(0)')
  obj:queueLuaCommand('electrics.horn(false)')
end

function C:resetAll() -- resets everything
  self:resetPursuit()
  self:resetTracking()
  self:resetValues()
end

function C:honkHorn(duration) -- set horn with duration
  getObjectByID(self.id):queueLuaCommand('electrics.horn(true)')
  self.queuedFuncs.horn = {timer = duration or 1, vLua = 'electrics.horn(false)'}
end

function C:useSiren(duration, disableAfterUse) -- set siren with duration
  -- assumes that vehicle has a lightbar...
  getObjectByID(self.id):queueLuaCommand('electrics.set_lightbar_signal(2)')
  local cmd = disableAfterUse and 'electrics.set_lightbar_signal(0)' or 'electrics.set_lightbar_signal(1)'
  self.queuedFuncs.horn = {timer = duration or 1, vLua = cmd}
end

function C:setAiMode(mode, ignoreParams) -- sets the AI mode and a few automatic parameters
  local vars = self.getTrafficVars()
  mode = mode or vars.aiMode
  self.isAi = mode ~= 'disabled'

  local obj = getObjectByID(self.id)
  obj:queueLuaCommand(string.format('ai.setMode("%s")', mode))

  if ignoreParams then return end -- ignoreParams can be used to prevent auto setting of parameters such as aggression

  if mode == 'traffic' then
    obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', vars.baseAggression))
    obj:queueLuaCommand('ai.setSpeedMode("legal")')
    obj:queueLuaCommand('ai.driveInLane("on")')
  elseif mode == 'random' or mode == 'flee' or mode == 'chase' then
    if mode == 'flee' or mode == 'chase' then
      obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', max(0.8, vars.baseAggression)))
      obj:queueLuaCommand('ai.setAggressionMode("off")')
    else
      obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', vars.baseAggression))
    end
    obj:queueLuaCommand('ai.setSpeedMode("off")')
    obj:queueLuaCommand('ai.driveInLane("off")')
  end

  obj:queueLuaCommand('ai.reset()')
end

function C:setAiParameters(params) -- sets a few AI parameters
  params = params or self.getTrafficVars() -- uses the traffic variables by default

  local obj = getObjectByID(self.id)
  local aggression = params.aggression or params.baseAggression
  if aggression then
    obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', aggression))
  end

  if params.speedLimit then
    if params.speedLimit >= 0 then
      obj:queueLuaCommand('ai.setSpeedMode("limit")')
      obj:queueLuaCommand(string.format('ai.setSpeed(%.3f)', params.speedLimit))
    else -- force legal speed
      obj:queueLuaCommand('ai.setSpeedMode("legal")')
    end
  end

  if params.aiAware then
    obj:queueLuaCommand(string.format('ai.setAvoidCars("%s")', params.aiAware))
  end

  --obj:queueLuaCommand('ai.reset()') -- this is called to reset the AI plan
end

function C:setRole(roleName) -- sets the driver role
  roleName = roleName or 'standard'
  local roleClass = gameplay_traffic_trafficUtils.getRoleConstructor(roleName)
  if roleClass then
    self.roleName = roleName
    local prevName

    if self.role then -- only if there is a previous role
      prevName = self.role.name
      self.role:onRoleEnded()
    end

    self.role = roleClass({veh = self, name = roleName})

    self.role:onRoleStarted()
    extensions.hook('onTrafficAction', self.id, 'changeRole', {targetId = self.role.targetId or 0, name = roleName, prevName = prevName, data = {}})
  end
end

function C:getInteractiveDistance(pos, squared) -- returns the distance of the "look ahead" point from this vehicle
  if pos then
    return squared and (self.targetPos):squaredDistance(pos) or (self.targetPos):distance(pos)
  else
    return huge
  end
end

function C:modifyRespawnValues(addActiveRadius, addInnerRadius) -- instantly modifies respawn values (can be used to keep a vehicle active for longer)
  -- for example, this is used after collisions and within the police pursuit system
  self.respawn.activeRadius = self.respawn.activeRadius + (addActiveRadius or 0)
  self.respawn.innerRadius = self.respawn.innerRadius + (addInnerRadius or 0)
end

function C:getBrakingDistance(speed, accel) -- gets estimated braking distance
  -- prevents division by zero gravity
  local gravity = core_environment.getGravity()
  gravity = max(0.1, abs(gravity)) * sign2(gravity)

  return square(speed or self.speed) / (2 * (accel or self.role.driver.aggression) * abs(gravity))
end

function C:checkCollisions() -- checks for contact with other tracked vehicles
  for id, veh in pairs(map.objects) do
    if self.id ~= id then
      local isCurrentCollision = map.objects[id] and map.objects[id].objectCollisions[self.id] == 1

      if not self.collisions[id] and isCurrentCollision then -- checks bounding boxes and creates a collision table
        local bb1 = getObjectByID(self.id):getSpawnWorldOOBB()
        local bb2 = getObjectByID(id):getSpawnWorldOOBB()

        if overlapsOBB_OBB(bb1:getCenter(), bb1:getAxis(0) * bb1:getHalfExtents().x, bb1:getAxis(1) * bb1:getHalfExtents().y, bb1:getAxis(2) * bb1:getHalfExtents().z, bb2:getCenter(), bb2:getAxis(0) * bb2:getHalfExtents().x, bb2:getAxis(1) * bb2:getHalfExtents().y, bb2:getAxis(2) * bb2:getHalfExtents().z) then
          self.collisions[id] = {state = 'active', inArea = false, speed = 0, vehDist = 0, damage = 0, dot = 0, count = 0, stop = 0}
        end
      end

      local collision = self.collisions[id]
      if collision then -- update existing collision table
        local dist = self.pos:squaredDistance(veh.pos) -- distance is used to ensure accuracy with body collisions and rebounds
        if isCurrentCollision then collision.damage = max(collision.damage, self.damage - self.prevDamage) end -- update damage value while in contact

        if not isCurrentCollision and dist > square(collision.vehDist + 1) then
          collision.inArea = false
        elseif isCurrentCollision and not collision.inArea then
          collision.vehDist = self.pos:distance(veh.pos)
          collision.inArea = true
          collision.count = collision.count + 1
          collision.speed = self.speed
          collision.dot = self.driveVec:dot((veh.pos - self.pos):normalized())
          self.collisionCount = self.collisionCount + 1

          if self.speed >= 1 then -- hacky, but solves an edge case where this vehicle is refreshed while stopped in a collision
            self.role:onCollision(id, collision)

            for otherId, otherVeh in pairs(self.getTraffic()) do -- notify other traffic vehicles of collision
              if not otherVeh.otherCollisionFlag and otherId ~= self.id and otherId ~= id then
                otherVeh.role:onOtherCollision(self.id, id, collision)
                otherVeh.otherCollisionFlag = true
              end
            end
          end
        end

        if self.isAi and not self.isTaxi then -- it is easy to touch the taxi while walking up to it. If not for this flag It would reset its AI, messing with the taxi system
          veh = self.getTraffic()[id]
          if veh and veh.isPerson then -- specific logic that handles collision with unicycle (walking mode)
            if isCurrentCollision and not self.role.flags.pullOver then -- stops AI during contact
              self.role:setAction('pullOver')
            elseif not isCurrentCollision and self.role.flags.pullOver and dist > square(collision.vehDist + 3) then -- restarts AI after a small distance (greater than jump distance)
              self.role:resetAction()
            end
          end
        end
      end
    else
      self.collisions[id] = nil
    end
  end
end

function C:trackCollision(otherId, dt) -- track and alter the state of the collision with other vehicle id
  otherId = otherId or 0
  local collision = self.collisions[otherId]
  local otherVeh = map.objects[otherId]
  if not collision or not otherVeh then return end

  local lowSpeed = gameplay_traffic_trafficUtils.getBaseValues().lowSpeed
  local dist = self.pos:squaredDistance(otherVeh.pos)

  if collision.state == 'active' then
    if dist <= 2500 and self.speed <= lowSpeed then -- waiting near site of collision
      collision.stop = collision.stop + dt
      if collision.stop >= 5 then
        collision.state = 'resolved'
      end
    elseif dist > 2500 and self.speed > lowSpeed and self.driveVec:dot(self.pos - otherVeh.pos) > 0 then -- leaving site of collision
      collision.state = 'abandoned'
    end
  end
  if (collision.state == 'resolved' or collision.state == 'abandoned') and dist >= 14400 then -- clear collision data
    self.collisions[otherId] = nil
  end
end

function C:fade(rate, isFadeOut) -- fades vehicle mesh
  self.alpha = clamp(self.alpha + (rate or 0.1) * (isFadeOut and -1 or 1), 0, 1)
  getObjectByID(self.id):setMeshAlpha(self.alpha, '')

  if isFadeOut and self.alpha == 0 then
    self.state = 'queued'
  elseif not isFadeOut and self.alpha == 1 then
    self.state = 'active'
  end
end

function C:checkRayCast(startPos, endPos) -- returns true if ray reaches position, or false if hit detected
  startPos = startPos or self.pos
  endPos = endPos or self.pos
  tempDirVec:setSub2(endPos, startPos)
  local vecLen = tempDirVec:length()
  tempDirVec:setScaled(1 / max(1e-12, vecLen))
  return castRayStatic(startPos, tempDirVec, vecLen) >= vecLen
end

function C:updateActiveRadius(tickTime) -- updates values that track if the vehicle should stay active or respawn
  if not self.enableRespawn or self.respawn.spawnValue <= 0 or not be:getObjectActive(self.id) then return end

  tempDirVec:setSub2(self.pos, self.focus.pos)
  tempDirVec:normalize()

  local activeRadius = lerp(160, 80, min(1, self.respawn.spawnValue)) -- based on spawn value (larger radius if value is smaller)
  local extraRadius = self.focus.speed + max(0, (1 - self.focus.speed / 5) * 80) -- larger extra radius if player is at a low speed
  extraRadius = extraRadius + max(0, self.focus.dirVec:dot(tempDirVec)) * 150 -- larger extra radius if focus direction to vehicle is straight ahead

  local visibilityValue = self.camVisible and tickTime * 2 or -tickTime
  self.respawn.staticVisibility = clamp(self.respawn.staticVisibility + visibilityValue * 0.125, 0, 1) -- 4 seconds up, 8 seconds down

  local decrement = tickTime * self.respawn.spawnValue * (2 - self.respawn.staticVisibility) * 35 -- stronger if occluded for longer
  self.respawn.activeRadius = max(activeRadius, self.respawn.activeRadius - decrement) -- gradually reduces active radius
  self.respawn.finalRadius = self.respawn.activeRadius + extraRadius
end

function C:tryRespawn() -- tests if the vehicle is out of sight and ready to respawn
  if self.id == be:getPlayerVehicleID(0) then return end -- never respawn the vehicle the player is currently in
  if not be:getObjectActive(self.id) then
    self.state = 'queued'
    return
  end

  if not self.enableRespawn or self.respawn.spawnValue <= 0 then return end

  if self.respawn.finalRadius < self.focusDist then
    -- check all non-traffic vehicles to ensure that they are not much too close to this vehicle
    local valid = true
    for _, veh in ipairs(getAllVehiclesByType()) do
      if not veh.isTraffic and not veh.isParked and map.objects[veh:getId()] then -- other non-traffic and non-player vehicle
        local mapData = map.objects[veh:getId()]
        local radius = tonumber(veh:getDynDataFieldbyName('trafficClearRadius', 0)) or self.respawn.innerRadius
        tempPos:set(gameplay_traffic_trafficUtils.getAheadPos(mapData.pos, mapData.dirVec, radius * 0.5, true))
        if self.pos:squaredDistance(tempPos) < square(radius) then -- prevents respawning if too close
          valid = false
          break
        end
      end
    end

    if valid or self.ignoreInnerRadius then
      table.clear(self.queuedFuncs)
      getObjectByID(self.id):queueLuaCommand('electrics.horn(false)') -- always turn off horn
      getObjectByID(self.id):queueLuaCommand('electrics.setLightsState(0)') -- always turn off headlights
      self.headlights = false
      self.state = 'fadeOut'
    end
  end
end

function C:triggerOffense(data) -- triggers a pursuit offense
  if not data or not data.key then return end
  data.score = data.score or 100
  if self.isAi then data.score = data.score * 0.5 end -- half score if the vehicle is AI controlled
  local key = data.key
  data.key = nil

  if not self.pursuit.offenses[key] then
    self.pursuit.offenses[key] = data
    table.insert(self.pursuit.offensesList, key)
    self.pursuit.uniqueOffensesCount = self.pursuit.uniqueOffensesCount + 1

    extensions.hook('onPursuitOffense', self.id, key, data)
  end
  self.pursuit.offensesCount = self.pursuit.offensesCount + 1
  self.pursuit.offenseFlag = true
  self.pursuit.addScore = self.pursuit.addScore + data.score
end

function C:checkOffenses() -- tests for vehicle offenses for police
  -- Offenses: speeding, racing, hitPolice, hitTraffic, reckless, wrongWay, intersection
  if self.getPoliceVars().strictness <= 0 then return end
  local pursuit = self.pursuit
  local threshold = 1 - clamp(self.getPoliceVars().strictness, 0, 0.8) -- offense threshold

  if self.tracking.faults.overSpeed >= threshold then
    if self.speed >= max(16.7, self.tracking.speedLimit * 1.2) and not pursuit.offenses.speeding then -- at least 60 km/h
      self:triggerOffense({key = 'speeding', value = self.speed, threshold = self.tracking.speedLimit, score = 100})
    end
    if self.speed >= max(27.8, self.tracking.speedLimit * 2) and not pursuit.offenses.racing then -- at least 100 km/h
      self:triggerOffense({key = 'racing', value = self.speed, threshold = self.tracking.speedLimit, score = 200})
    end
  end
  if self.tracking.faults.reckless >= threshold and not pursuit.offenses.reckless then
    self:triggerOffense({key = 'reckless', value = self.tracking.faults.reckless, threshold = threshold, score = 250})
  end
  if self.tracking.faults.wrongWay >= threshold and not pursuit.offenses.wrongWay then
    self:triggerOffense({key = 'wrongWay', value = self.tracking.faults.wrongWay, threshold = threshold, score = 150})
  end
  if self.tracking.signalFault and not pursuit.offenses.intersection then
    self:triggerOffense({key = 'intersection', value = self.tracking.signalFault, score = 200})
  end

  for id, coll in pairs(self.collisions) do
    local veh = self.getTraffic()[id]
    if veh then
      local validCollision = coll.dot >= 0.2 and coll.speed >= 1 -- simple comparison to check if current vehicle is at fault for collision
      if veh.role.targetId ~= nil and veh.role.targetId ~= self.id then -- invalidate collision if other vehicle is targeting a different vehicle
        validCollision = false
      elseif veh.role.name == 'police' and veh.role.flags.cooldown then -- invalidate collision if police has cooldown flag
        validCollision = false
      end
      if self.isPerson then -- special check if the vehicle is a person
        tempPos:set(be:getObjectOOBBCenterXYZ(id))
        tempPos.z = 0
        validCollision = self.pos:z0():squaredDistance(tempPos) < square(veh.width * 0.6) or coll.count >= 3 -- jumping on car, or multiple hits
      end

      if not coll.offense and validCollision then
        if veh.role.name == 'police' then -- police vehicle collision
          if coll.inArea then -- needs to be in collision area
            self:triggerOffense({key = 'hitPolice', value = id, score = 200})
            pursuit.hitCount = pursuit.hitCount + 1
            coll.offense = true
          end
        else -- civilian vehicle collision
          if pursuit.mode > 0 or coll.state == 'abandoned' then -- fleeing in a pursuit, or abandoning an accident
            self:triggerOffense({key = 'hitTraffic', value = id, score = 100})
            pursuit.hitCount = pursuit.hitCount + 1
            coll.offense = true
          end
        end
      end
    end
  end
end

function C:checkPoliceVisibility(dtSim) -- checks police visibility
  local pursuit = self.pursuit
  local useTargetVisible = pursuit.timers.stuck * 2 < self.getPoliceVars().arrestRadius -- false if vehicle is stuck for too long
  if gameplay_traffic.getTraffic()[self.id] then
    pursuit.sight.policeId, pursuit.sight.dist, pursuit.sight.interDist = gameplay_police.getNearestPoliceVehicle(self.id, useTargetVisible, true)
  else
    pursuit.sight.policeId = nil
    pursuit.sight.dist = math.huge
    pursuit.sight.interDist = math.huge

    for id, veh in pairs(self.getPolice()) do -- similar to function gameplay_police.getNearestPoliceVehicle
      if be:getObjectActive(id) then
        local target = veh.role.validTargets[self.id]
        if target and veh.role.state ~= 'disabled' and (not useTargetVisible or target.visible) then
          if target.dist < pursuit.sight.dist then
            pursuit.sight.dist = target.dist
            pursuit.sight.interDist = target.interDist
            pursuit.sight.policeId = id
          end
        end
      end
    end
  end

  local addSightValue
  local sightCoef = self.pursuit.mode + 2
  local strictness = self.getPoliceVars().strictness
  if not pursuit.sight.policeId then
    addSightValue = -dtSim * 0.25 -- no police visible, reduce sight value
  else
    local targetDist = min(pursuit.sight.dist, pursuit.sight.interDist) -- police look ahead distance or police vehicle distance, whichever is better
    addSightValue = (120 / targetDist) * dtSim * strictness * sightCoef -- increments faster when nearer
  end
  self.pursuit.sightValue = clamp(self.pursuit.sightValue + addSightValue, 0, 1)
  self.pursuit.policeVisible = self.pursuit.sightValue >= 0.5

  local addScore = 0
  if self.pursuit.addScore > 0 then
    addScore = self.pursuit.addScore -- add score from pursuit infraction
  else
    if self.pursuit.mode >= 1 then
      addScore = strictness * min(10, self.speed) * dtSim * 2 -- gradual increase during pursuit
    end
  end
  self.pursuit.score = max(0, self.pursuit.score + addScore)

  self.pursuit.addScore = 0
end

function C:checkTimeOfDay() -- checks time of day
  local timeObj = core_environment.getTimeOfDay()
  local isDaytime = true
  if timeObj and timeObj.time then
    local nightStart, nightEnd = core_solarTimeOfDay.getSolarNightWindow(timeObj)
    isDaytime = (timeObj.time < nightStart or timeObj.time > nightEnd)
  end

  return isDaytime
end

function C:onVehicleResetted() -- triggers whenever vehicle resets (automatically or manually)
  if self.role.flags.freeze then
    getObjectByID(self.id):queueLuaCommand('controller.setFreeze(0)')
    self.role.flags.freeze = false
  end
  self:resetTracking()
end

function C:onActiveDone() -- triggers after a vehicle is faded out or sent to inactive pool
  self.role:onActiveDone()
end

function C:onRespawn() -- triggers after vehicle respawns in traffic
  if self.useRandomPaint then
    core_vehicle_manager.setVehiclePaintsNames(self.id, core_vehiclePaints.getRandomPaintsByVehicle(self.id))
  end

  self.respawnCount = self.respawnCount + 1
  self.respawnActive = true
  self.state = 'reset'
end

function C:onRefresh() -- triggers whenever vehicle data needs to be refreshed (usually after respawning)
  if self.isAi then
    local obj = getObjectByID(self.id)

    self:resetAll()

    obj.playerUsable = settings.getValue('trafficEnableSwitching') and true or false

    if self.getTrafficVars().aiDebug == 'traffic' then
      obj:queueLuaCommand('ai.setVehicleDebugMode({debugMode = "off"})')
    else
      obj:queueLuaCommand(string.format('ai.setVehicleDebugMode({debugMode = "%s"})', self.getTrafficVars().aiDebug))
    end

    local isDaytime = self:checkTimeOfDay()

    if not isDaytime then
      self.respawn.spawnValue = self.respawn.spawnValue * 0.25 -- basic spawn density adjustment
    end
    self.state = self.alpha == 1 and 'active' or 'fadeIn'

    if not self.role.keepActionOnRefresh then
      self.role:resetAction()
    end
    if not self.role.keepPersonalityOnRefresh then
      self.role:applyPersonality(self.role:generatePersonality())
    end

    self:setAiParameters()
  end

  self.tickTimer = 0
  self._teleport = nil
  self.role:onRefresh()
end

function C:onTrafficTick(tickTime)
  local baseValues = gameplay_traffic_trafficUtils.getBaseValues()

  self.tracking.signalFault = nil -- clear signal fault every tick
  if self.enableTracking and not self.isPerson then
    self.tracking:onUpdate(tickTime)
  end

  if self.state == 'active' and self.alpha < 1 then
    log('W', logTag, string.format('Vehicle that should be visible is invisible: %d', self.id))
  end

  if self.isAi then
    self.camVisible = self:checkRayCast(self.focus.pos)
    self:updateActiveRadius(tickTime)

    if self.respawnSpeed then
      local dt = self.respawnSpeed > 0 and 0.25 or 0.1
      getObjectByID(self.id):queueLuaCommand('thrusters.applyVelocity(obj:getDirectionVector() * '..self.respawnSpeed..', '..dt..')') -- makes vehicle start at speed
      self.respawnSpeed = nil
    end

    if self.state == 'active' then
      local isDaytime = self:checkTimeOfDay()
      local terrainHeight = core_terrain.getTerrain() and core_terrain.getTerrainHeight(self.pos) or 0
      local terrainHeightDefault = core_terrain.getTerrain() and core_terrain.getTerrain():getPosition().z or 0
      local isTunnel = self.pos.z < terrainHeight
      if terrainHeight == terrainHeightDefault then -- no terrain, or out of terrain bounds
        -- the following check can be inaccurate sometimes, but it's good enough
        local raisedPos = self.pos + vecUp * 10
        local sideVec = map.objects[self.id].dirVec:cross(map.objects[self.id].dirVecUp) * 5
        isTunnel = not self:checkRayCast(nil, raisedPos) and not self:checkRayCast(nil, raisedPos - sideVec) and not self:checkRayCast(nil, raisedPos + sideVec)
      end
      if (isTunnel or not isDaytime) and not self.headlights then
        local coef = min(4, 200 / self.focusDist) -- larger value (more random) if the vehicle is nearer
        self.queuedFuncs.headlights = {timer = random() * coef, vLua = 'electrics.setLightsState(1)'}
        self.headlights = true
      elseif (not isTunnel and isDaytime) and self.headlights then
        self.queuedFuncs.headlights = nil
        getObjectByID(self.id):queueLuaCommand('electrics.setLightsState(0)')
        self.headlights = false
      end
    end
  end

  local tickDamage = self.damage - self.prevDamage
  self.crashDamage = max(self.crashDamage, tickDamage) -- highest tick damage experienced

  if tickDamage >= baseValues.lowDamage then
    self.role:onCrashDamage({speed = self.speed, damage = self.damage, tickDamage = tickDamage})

    for id, veh in pairs(self.getTraffic()) do
      if id ~= self.id then
        veh.role:onOtherCrashDamage(self.id, {speed = self.speed, damage = self.damage, tickDamage = tickDamage})
      end
    end

    if not self.activeData.tCrash then
      self:modifyRespawnValues(1000) -- discourage vehicle from respawning for a while
      self.activeData.tCrash = os.clockhp() -- timestamp of initial crash
      extensions.hook('onTrafficVehicleCrashed', self.id, {speed = self.speed, damage = self.damage, tickDamage = tickDamage})
    end
  end

  if not self.activeData.tCrash and not self.activeData.tNearMiss then
    for id, veh in pairs(self.getTraffic()) do
      if id ~= self.id then
        local tracking = veh.tracking
        if tracking.sideValue < 0 and (tracking.faults.wrongWay >= 0.25 or tracking.faults.overSpeed >= 0.25) then
          if self.pos:squaredDistance(veh.pos) <= square(min(80, veh.speed * 2)) then
            tempDirVec:setSub2(veh.pos, self.pos)
            if self.driveVec:dot(tempDirVec) > 0 and self.driveVec:dot(veh.driveVec) < -0.866 then -- 30 degrees
              self.role:onOtherEvent('nearMiss', id, {})
              self.activeData.tNearMiss = os.clockhp() -- timestamp of initial near miss
              break
            end
          end
        end
      end
    end
  end

  self.prevDamage = self.damage

  self.role:onTrafficTick(tickTime)
end

function C:onPursuitUpdate(dt, dtSim)
  local pursuit = self.pursuit
  local vars = self.getPoliceVars()
  local isMainTraffic = gameplay_traffic.getTraffic()[self.id] and true or false -- true if the main traffic system has this vehicle
  if pursuit.mode ~= 0 then
    local arrestRadius = pursuit.policeVisible and vars.arrestRadius or 5 -- very small radius if police visibility is blocked, prevents false arresting
    local evadeRadius = pursuit.policeVisible and 200 or vars.evadeRadius -- very large radius if police visibility is unblocked, prevents false evading
    local nearDist = pursuit.sight.dist or math.huge

    -- alert
    if isMainTraffic and pursuit.mode == 1 and pursuit.offensesCount > 1 and not pursuit.flags.policeAlert then -- alert more police units if there is more than one offense
      gameplay_police.setPursuitMode(1, self.id)
      pursuit.flags.policeAlert = 1
    end

    -- arrest
    if pursuit.mode >= 1 then
      if pursuit.timers.arrest >= vars.arrestTime then
        if isMainTraffic then
          gameplay_police.arrestVehicle(self.id, gameplay_traffic.showMessages)
        else
          pursuit.mode = -1
          pursuit.timers.arrest = 0
          extensions.hook('onPursuitAction', self.id, 'arrest', self.pursuit)
        end
      end
    -- release
    elseif pursuit.mode == -1 then
      if (pursuit.timers.arrest <= -5 or not self.role.flags.freeze) then
        if isMainTraffic then
          gameplay_police.releaseVehicle(self.id, gameplay_traffic.showMessages)
        else
          pursuit.mode = 0
          pursuit.timers.arrest = 0
          extensions.hook('onPursuitAction', self.id, 'release', self.pursuit)
        end
      end

      if self.getPoliceVars().autoRelease then
        pursuit.timers.arrest = clamp(pursuit.timers.arrest - dtSim, -5, 0)
      else
        pursuit.timers.arrest = 0
      end
    end

    if pursuit.mode >= 1 then
      pursuit.timers.stuck = self.speed <= SLOW_SPEED and pursuit.timers.stuck + dtSim or 0
      if pursuit.timers.stuck * 2 >= vars.arrestRadius then
        arrestRadius = min(pursuit.timers.stuck * 2, vars.arrestRadius * 3) -- arrest radius grows if the vehicle is stuck
      end

      -- visible and within arrest distance
      if pursuit.sight.policeId and nearDist < square(arrestRadius) then
        if self.speed <= SLOW_SPEED and self.getPolice()[pursuit.sight.policeId].speed <= SLOW_SPEED and nearDist < square(arrestRadius) then
          pursuit.timers.arrest = min(vars.arrestTime, pursuit.timers.arrest + dtSim)
        else
          pursuit.timers.arrest = 0
        end

        pursuit.timers.evade = 0
      else
        if pursuit.mode == 3 then
          -- setup roadblock and adjust timer
          if vars.roadblockFrequency > 0 and pursuit.timers.roadblock == 0 then
            if isMainTraffic then
              local roadblock = gameplay_police.setupRoadblock(self.id, nil, nil, self.focus.pos, self.focus.dirVec)
              if roadblock then
                pursuit.roadblockTargetId = roadblock.vehIds[1]
                pursuit.flags.roadblockNear = nil
                pursuit.timers.roadblock = max(10, 60 - vars.roadblockFrequency * 60) -- time interval to test for the next roadblock
                extensions.hook('onPursuitAction', self.id, 'roadblock', pursuit)
              else
                pursuit.timers.roadblock = 2 -- bounce time until next roadblock check
              end
            else
              pursuit.timers.roadblock = max(10, 60 - vars.roadblockFrequency * 60)
              extensions.hook('onPursuitAction', self.id, 'roadblockAlert', pursuit)
            end
          end
        end

        if pursuit.timers.evade >= vars.evadeTime then
          if isMainTraffic then
            gameplay_police.evadeVehicle(self.id, gameplay_traffic.showMessages)
          else
            pursuit.mode = 0
            pursuit.timers.evade = 0
            extensions.hook('onPursuitAction', self.id, 'evade', pursuit)
          end
        end

        if nearDist > square(evadeRadius) then
          pursuit.timers.evade = min(vars.evadeTime, pursuit.timers.evade + dtSim)
        elseif nearDist <= square(evadeRadius * 0.5) then
          pursuit.timers.evade = 0
        end

        pursuit.timers.arrest = 0
      end
    end

    if pursuit.mode == 3 and pursuit.timers.evadeValue < 0.5 then
      pursuit.timers.roadblock = max(0, pursuit.timers.roadblock - dtSim)
    end

    local roadblockVeh = self.getPolice()[pursuit.roadblockTargetId]
    if not pursuit.flags.roadblockNear and roadblockVeh and self.pos:squaredDistance(roadblockVeh.pos) <= 400 then -- increment roadblock counter
      pursuit.roadblocks = pursuit.roadblocks + 1
      pursuit.flags.roadblockNear = 1
    end

    if pursuit.mode >= 1 then
      pursuit.timers.main = pursuit.timers.main + dtSim
    end
  end

  pursuit.timers.arrestValue = pursuit.mode ~= -1 and clamp(pursuit.timers.arrest / max(1e-12, self.getPoliceVars().arrestTime), 0, 1) or 1
  pursuit.timers.evadeValue = clamp(pursuit.timers.evade / max(1e-12, self.getPoliceVars().evadeTime), 0, 1)
end

function C:onUpdate(dt, dtSim)
  if not map.objects[self.id] then return end

  self.pos = map.objects[self.id].pos
  self.dirVec = map.objects[self.id].dirVec
  self.vel = map.objects[self.id].vel
  self.speed = self.isPerson and self.vel:z0():length() or self.vel:length()
  self.focus = gameplay_traffic.getFocus() -- the origin point, whether it's the game camera, player, or other entity
  self.focusDist = self.pos:distance(self.focus.pos)

  if self.speed < 1 then
    self.driveVec = self.dirVec
  else
    self.driveVec:setScaled2(self.vel, 1 / (self.speed + 1e-12))
  end
  self.targetPos:setScaled2(self.driveVec, clamp(self.speed * 2, 10, 50))
  self.targetPos:setAdd2(self.pos, self.targetPos) -- virtual point ahead of vehicle trajectory, dependent on speed

  if (not be:getObjectActive(self.id) or self.state == 'active') and not self.enableRespawn then
    self.state = 'locked'
  elseif self.state == 'locked' and self.enableRespawn then
    self.state = 'reset'
  end

  if be:getObjectActive(self.id) then
    self.damage = map.objects[self.id].damage

    if self.isAi then
      if self.state == 'fadeOut' or self.state == 'fadeIn' then
        if self.state == 'fadeIn' then
          if self.damage >= 500 and self.respawnActive and self.alpha > 0 then
            log('W', logTag, string.format('Traffic vehicle respawned with big damage: %d', self.id))
            self:fade(1)
            -- simTimeAuthority.pause(false) -- uncomment this to stop the simulation when this issue happens
            -- commands.setFreeCamera(); core_camera.setPosRot(0, self.pos.x, self.pos.y, self.pos.z, 0, 0, 0, 1) -- uncomment this to move the camera to the vehicle
          end
        end

        self:fade(dtSim * 4, self.state == 'fadeOut')
      end

      if self.state == 'active' then
        if self.respawnActive then
          self.respawnActive = nil
        end
      end
    end

    self.tickTimer = self.tickTimer + dtSim
    if self.tickTimer >= TICK_TIME then
      self:onTrafficTick(TICK_TIME)
      self.tickTimer = self.tickTimer - TICK_TIME
    end

    if self.enableTracking then
      self:checkCollisions()

      for id, _ in pairs(self.collisions) do
        self:trackCollision(id, dtSim)
      end

      if self.role.name ~= 'police' then
        self:checkPoliceVisibility(dtSim)
        if self.pursuit.policeVisible then
          self:checkOffenses()
        end
      end
    end

    self:onPursuitUpdate(dt, dtSim)

    -- queued functions
    for k, v in pairs(self.queuedFuncs) do
      if not v.timer then v.timer = 0 end
      v.timer = v.timer - dtSim
      if v.timer <= 0 then
        if not v.vLua then
          v.func(unpack(v.args))
        else
          getObjectByID(self.id):queueLuaCommand(v.vLua)
        end
        self.queuedFuncs[k] = nil
      end
    end

    self.role:onUpdate(dt, dtSim)
  else
    self.camVisible = false
  end
end

function C:onSerialize()
  local data = {
    id = self.id,
    isAi = self.isAi,
    isVehicle = self.isVehicle,
    model = self.model,
    modelName = self.modelName,
    drivability = self.drivability,
    useRandomPaint = self.useRandomPaint,
    autoRole = self.autoRole,
    state = self.state,
    respawn = self.respawn,
    respawnCount = self.respawnCount,
    enableRespawn = self.enableRespawn,
    enableTracking = self.enableTracking,
    enableAutoPooling = self.enableAutoPooling,
    activeProbability = self.activeProbability,
    reserved = self.reserved,
    claimed = self.claimed,
    collisions = self.collisions,
    pursuit = self.pursuit,
    tracking = self.tracking:onSerialize(),
    role = self.role:onSerialize()
  }

  return data
end

function C:onDeserialized(data)
  self.id = data.id
  self.isAi = data.isAi
  self.isVehicle = data.isVehicle
  self.model = data.model
  self.modelName = data.modelName
  self.drivability = data.drivability
  self.useRandomPaint = data.useRandomPaint
  self.autoRole = data.autoRole
  self.state = data.state
  self.respawn = data.respawn
  self.respawnCount = data.respawnCount
  self.enableRespawn = data.enableRespawn
  self.enableTracking = data.enableTracking
  self.enableAutoPooling = data.enableAutoPooling
  self.activeProbability = data.activeProbability
  self.reserved = data.reserved
  self.claimed = data.claimed
  self.collisions = data.collisions
  self.pursuit = data.pursuit

  --self:applyModelConfigData()
  self:setRole(data.role.name)
  self.tracking:onDeserialized(data.tracking)
  self.role:onDeserialized(data.role, self)

  if not be:getObjectActive(self.id) then self.state = 'queued' end
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  C.__index = C
  o:init(o.id)
  return o.model and o -- returns nil if invalid object
end