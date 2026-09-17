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

local tickTime = 0.25
local tempPos, tempDirVec = vec3(), vec3()

-- const vectors --
local vecUp = vec3(0, 0, 1)

function C:init(id, role)
  id = id or 0
  local obj = getObjectByID(id)
  if not obj then
    log('E', logTag, string.format('Failed to initialize traffic vehicle: %d', id))
    return
  end

  local modelData = core_vehicles.getModel(obj.jbeam).model
  local modelType = modelData and string.lower(modelData.Type) or 'none'
  if obj.jbeam == 'unicycle' and obj:isPlayerControlled() then modelType = 'player' end
  if not modelData or not arrayFindValueIndex({'car', 'truck', 'automation', 'traffic', 'proptraffic', 'player'}, modelType) then
    log('I', logTag, string.format('Ignoring traffic vehicle due to invalid vehicle type: %d', id))
    return
  elseif obj.ignoreTraffic then
    log('I', logTag, string.format('Ignoring traffic vehicle due to blocking flag: %d', id))
    return
  end

  getObjectByID(id):setMeshAlpha(1, '') -- force vehicle to be visible

  self.vars = gameplay_traffic.getTrafficVars()
  self.policeVars = gameplay_police.getPoliceVars()

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
  self.isPlayerControlled = obj:isPlayerControlled()
  self.focus = gameplay_traffic.getFocus()
  self.focusDist = 0

  self.tracking = require('gameplay/traffic/roadTracking')({vehId = id})

  self:resetAll()
  self:applyModelConfigData()
  self:setRole(role or self.autoRole)

  if core_trailerRespawn and core_trailerRespawn.getTrailerData()[id] then -- assumes that this vehicle will always respawn with a trailer attached
    self.hasTrailer = true
  end

  self.debugLine = true
  self.debugText = true

  self.pos, self.targetPos, self.dirVec, self.vel, self.driveVec = vec3(), vec3(), vec3(), vec3(), vec3()
  self.damage = 0
  self.speed = 0
  self.alpha = 1
  self.respawnCount = 0
  self.tickTimer = 0
  self.activeProbability = 1
end

function C:applyModelConfigData() -- sets data that depends on the vehicle model & config, and returns the generated vehicle role
  local role = 'standard'
  local obj = getObjectByID(self.id)
  local modelData = core_vehicles.getModel(obj.jbeam).model
  local _, configKey = path.splitWithoutExt(obj.partConfig)
  local configData = core_vehicles.getModel(obj.jbeam).configs[configKey]

  local modelName = obj.jbeam
  local vehType = modelData.Type
  local configType = configData and configData['Config Type']
  local width = obj.initialNodePosBB:getExtents().x
  local length = obj.initialNodePosBB:getExtents().y
  local useRandomPaint = false

  if modelData.Name then
    modelName = modelData.Brand and string.format('%s %s', modelData.Brand, modelData.Name) or modelData.Name
  end
  if modelName == 'Simplified Traffic Vehicles' then -- NOTE: this is hacky, please improve
    local partConfigStr = obj.partConfig
    local _, key = path.splitWithoutExt(partConfigStr)
    key = string.match(key, '%w*')
    if key then
      local tempModel = core_vehicles.getModelList().models[key] or {Name = 'Unknown'}
      modelName = tempModel.Brand and string.format('%s %s', tempModel.Brand, tempModel.Name) or tempModel.Name
    end
  end

  if modelData.paints and next(modelData.paints) and (not configType or configType == 'Factory' or vehType == 'Traffic') then
    useRandomPaint = true
  end

  local drivability = 0.25
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
  if configTypeLower == 'service' then
    self._serviceConfigFlag = 1 -- temporary flag
  end

  self.model = obj.jbeam
  self.modelName = modelName
  self.width = width
  self.length = length
  self.drivability = drivability
  self.isPerson = obj.jbeam == 'unicycle' -- assumes that the "vehicle" is a person
  self.useRandomPaint = useRandomPaint
  self.autoRole = role
end

function C:resetPursuit()
  if self.pursuit and self.pursuit.mode ~= 0 then
    gameplay_police.setPursuitMode(0, self.id)
  end
  self.pursuit = {mode = 0, score = 0, addScore = 0, policeCount = 0, hitCount = 0, offensesCount = 0, uniqueOffensesCount = 0,
  sightValue = 0, roadblocks = 0, roadblockPos = vec3(), policeWrecks = 0, offenses = {}, offensesList = {}, flags = {}}
  self.pursuit.timers = {main = 0, arrest = 0, evade = 0, roadblock = 0, arrestValue = 0, evadeValue = 0}
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
    spawnValue = self.vars.spawnValue, -- respawnability coefficient, from 0 (slow) to 3 (rapid); exactly 0 disables respawning
    spawnDirBias = self.vars.spawnDirBias, -- probability of direction of next respawn, from -1 (away from you) to 1 (towards you)
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
  mode = mode or self.vars.aiMode
  self.isAi = mode ~= 'disabled'

  local obj = getObjectByID(self.id)
  obj:queueLuaCommand(string.format('ai.setMode("%s")', mode))

  if ignoreParams then return end -- ignoreParams can be used to prevent auto setting of parameters such as aggression

  if mode == 'traffic' then
    obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', self.vars.baseAggression))
    obj:queueLuaCommand('ai.setSpeedMode("legal")')
    obj:queueLuaCommand('ai.driveInLane("on")')
  elseif mode == 'random' or mode == 'flee' or mode == 'chase' then
    if mode == 'flee' or mode == 'chase' then
      obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', max(0.8, self.vars.baseAggression)))
      obj:queueLuaCommand('ai.setAggressionMode("off")')
    else
      obj:queueLuaCommand(string.format('ai.setAggression(%.3f)', self.vars.baseAggression))
    end
    obj:queueLuaCommand('ai.setSpeedMode("off")')
    obj:queueLuaCommand('ai.driveInLane("off")')
  end

  obj:queueLuaCommand('ai.reset()')
end

function C:setAiParameters(params) -- sets a few AI parameters
  params = params or self.vars -- uses the traffic variables by default

  local obj = getObjectByID(self.id)
  if params.aggression or params.baseAggression then
    local aggression = params.aggression or params.baseAggression
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

    if self._serviceConfigFlag then -- temporary flag
      self.role.ignorePersonality = true
      self._serviceConfigFlag = nil
    end

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

            for otherId, otherVeh in pairs(gameplay_traffic.getTrafficData()) do -- notify other traffic vehicles of collision
              if not otherVeh.otherCollisionFlag and otherId ~= self.id and otherId ~= id then
                otherVeh.role:onOtherCollision(self.id, id, collision)
                otherVeh.otherCollisionFlag = true
              end
            end
          end
        end

        if self.isAi and not self.isTaxi then -- it is easy to touch the taxi while walking up to it. If not for this flag It would reset its AI, messing with the taxi system
          veh = gameplay_traffic.getTrafficData()[id]
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

function C:checkOffenses() -- tests for vechicle offenses for police
  -- Offenses: speeding, racing, hitPolice, hitTraffic, reckless, wrongWay, intersection
  if self.policeVars.strictness <= 0 then return end
  local pursuit = self.pursuit
  local threshold = 1 - clamp(self.policeVars.strictness, 0, 0.8) -- offense threshold

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
    local veh = gameplay_traffic.getTrafficData()[id]
    if veh then
      local validCollision = coll.dot >= 0.2 and coll.speed >= 1 -- simple comparison to check if current vehicle is at fault for collision
      if veh.role.targetId ~= nil and veh.role.targetId ~= self.id then -- invalidate collision if other vehicle is targeting a different vehicle
        validCollision = false
      elseif veh.role.name == 'police' and (veh.role.flags.roadblock or veh.role.flags.cooldown) then -- invalidate collision during some police actions
        validCollision = false
      end
      if self.isPerson then -- special check if the vehicle is a person
        local center = vec3(be:getObjectOOBBCenterXYZ(id)) -- for accuracy
        validCollision = self.pos:z0():squaredDistance(center:z0()) < square(veh.width * 0.6) or coll.count >= 3 -- jumping on car, or multiple hits
      end

      if not coll.offense and validCollision then
        if veh.role.name == 'police' and coll.inArea then -- always triggers if police was hit (in most cases)
          self:triggerOffense({key = 'hitPolice', value = id, score = 200})
          pursuit.hitCount = pursuit.hitCount + 1
          coll.offense = true
        elseif pursuit.mode > 0 or coll.state == 'abandoned' then -- fleeing in a pursuit, or abandoning an accident
          self:triggerOffense({key = 'hitTraffic', value = id, score = 100})
          pursuit.hitCount = pursuit.hitCount + 1
          coll.offense = true
        end
      end
    end
  end
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

    self.vars = gameplay_traffic.getTrafficVars()
    self.policeVars = gameplay_police.getPoliceVars()
    self:resetAll()

    obj.playerUsable = settings.getValue('trafficEnableSwitching') and true or false

    if self.vars.aiDebug == 'traffic' then
      obj:queueLuaCommand('ai.setVehicleDebugMode({debugMode = "off"})')
    else
      obj:queueLuaCommand(string.format('ai.setVehicleDebugMode({debugMode = "%s"})', self.vars.aiDebug))
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

    for id, veh in pairs(gameplay_traffic.getTrafficData()) do
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
    for id, veh in pairs(gameplay_traffic.getTrafficData()) do
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
    if self.tickTimer >= tickTime then
      self:onTrafficTick(tickTime)
      self.tickTimer = self.tickTimer - tickTime
    end

    if self.enableTracking then
      self:checkCollisions()

      for id, _ in pairs(self.collisions) do
        self:trackCollision(id, dtSim)
      end

      if self.role.name ~= 'police' and self.pursuit.policeVisible then
        self:checkOffenses()
      end
    end

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
    respawnCount = self.respawnCount,
    enableRespawn = self.enableRespawn,
    enableTracking = self.enableTracking,
    enableAutoPooling = self.enableAutoPooling,
    activeProbability = self.activeProbability,
    reserved = self.reserved,
    claimed = self.claimed,
    tracking = self.tracking:onSerialize(),
    role = self.role:onSerialize()
  }

  return data
end

function C:onDeserialized(data)
  self.id = data.id
  self.isAi = data.isAi
  self.respawnCount = data.respawnCount
  self.enableRespawn = data.enableRespawn
  self.enableTracking = data.enableTracking
  self.enableAutoPooling = data.enableAutoPooling
  self.activeProbability = data.activeProbability
  self.reserved = data.reserved
  self.claimed = data.claimed

  self:applyModelConfigData()
  self:setRole(data.role.name)
  self:onRefresh()
  self.tracking:onDeserialized(data.tracking)
  self.role:onDeserialized(data.role)
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  C.__index = C
  o:init(o.id)
  return o.model and o -- returns nil if invalid object
end