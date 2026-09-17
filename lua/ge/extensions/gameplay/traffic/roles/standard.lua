-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max
local ceil = math.ceil
local random = math.random

local minActionTime = 5
local tempVec = vec3()

local C = {}

function C:init()
  self.personalityModifiers = {}
  self.actions = {
    fleePostCrash = function (args)
      if self.veh.isAi then
        self.veh:setAiMode('flee')
        local obj = getObjectByID(self.veh.id)
        obj:queueLuaCommand('ai.driveInLane("off")')
        obj:queueLuaCommand('ai.setAggressionMode("off")')
        self:setAggression(args.aggression or max(0.5, random()))
      end
      self.state = 'flee'
      self.flags.askInsurance = nil
    end,
    followPostCrash = function (args)
      if self.veh.isAi then
        self.veh:setAiMode(args.isChase and 'chase' or 'follow')
        local obj = getObjectByID(self.veh.id)
        obj:queueLuaCommand('ai.driveInLane("off")')
        obj:queueLuaCommand('ai.setAggressionMode("off")')
        self:setAggression(args.aggression or max(0.5, random()))
      end
      self.state = 'follow'
      self.flags.askInsurance = nil
    end,
    askInsurance = function (args)
      if self.veh.isAi then
        self.veh:setAiMode('stop')
      end
      self.flags.askInsurance = nil
    end,
    disabled = function (args)
      if self.veh.isAi then
        self.veh:setAiMode('stop')
      end
      self.state = 'disabled'
    end
  }

  for k, v in pairs(self.baseActions) do
    self.actions[k] = v
  end
  self.baseActions = nil
end

function C:onRefresh()
  self.targetId = nil
  self.actionTimer = 0
  local personality = self.driver.personality

  self.driver.eventType = 'none'
  self.driver.damageAction = 'none'
  self.driver.collisionThreshold = math.huge

  if self.veh.isAi then -- only calculates values if vehicle is AI
    self.driver.damageAction = 'stop'

    if personality.bravery >= 0.56 then
      self.driver.damageAction = 'followPostCrash'
    elseif personality.bravery <= 0.44 then
      self.driver.damageAction = 'fleePostCrash'
    end

    self.driver.collisionThreshold = ceil(square(random()) * 6) -- minimum number of collisions that triggers damage action
  end

  self.driver.selfHitCount = 0
  self.driver.otherHitCount = 0
  self.driver.enableAskInsurance = true
end

function C:onCrashDamage(data)
  -- triggers if self is currently not in a collision or witness to one
  if self.driver.eventType ~= 'selfCollision' and self.driver.eventType ~= 'otherCollision' then
    self.driver.eventType = 'selfCrash'

    if self.veh.isAi then
      extensions.hook('onTrafficAction', self.veh.id, 'crashDamage', {targetId = self.veh.id})
    end
  end
end

function C:onOtherCrashDamage(otherId, data)
  -- triggers if self is currently not in a collision or witness to one
  if self.driver.eventType ~= 'selfCollision' and self.driver.eventType ~= 'otherCollision' then
    self.driver.eventType = 'otherCrash'
    self:setTarget(otherId)
  end
end

function C:onCollision(otherId, data)
  if self.veh.speed >= self.veh.tracking.speedLimit * 1.2 then -- speeding always means collision fault for self
    self.veh.collisions[otherId].fault = true
  end
  if self.driver.eventType ~= 'selfCollision' then -- overrides previous events
    self.driver.eventType = 'selfCollision'
    self:setTarget(otherId)

    if self.veh.isAi then
      extensions.hook('onTrafficAction', self.veh.id, 'collision', {targetId = self.targetId or 0})
    end
  end

  -- queue honk horn here, if above threshold
  if self.veh.isAi and not self.flags.askInsurance and self.driver.personality.bravery / (1 + data.count * 0.1) >= 0.5 then
    self.honkHornDuration = self.driver.personality.bravery
  end

  self.driver.selfHitCount = data.count
end

function C:onOtherCollision(id1, id2, data)
  if self.driver.eventType ~= 'selfCollision' then
    local targetVeh, secondVeh = gameplay_traffic.getTrafficData()[id1], gameplay_traffic.getTrafficData()[id2]
    if not targetVeh or not secondVeh then return end
    local targetId = targetVeh.speed < secondVeh.speed and id1 or id2 -- target the slower vehicle in collision
    if targetId == id2 then targetVeh = gameplay_traffic.getTrafficData()[targetId] end

    -- checks if target is visible, within distance, and in front of self
    if self:checkTargetVisible(targetId) and self.veh:getInteractiveDistance(targetVeh.pos, true) <= 3600 and self.veh.dirVec:dot(targetVeh.pos - self.veh.pos) > 0 then
      if self.driver.eventType ~= 'otherCollision' then
        self.driver.eventType = 'otherCollision'
        self:setTarget(targetId)
      end

      self.driver.otherHitCount = data.count
    end
  end
end

function C:onOtherEvent(eventType, otherId, data)
  if self.flags.crashActive then return end -- prevent event if crash happened, for now

  if self:checkTargetVisible(otherId) then
    self.driver.eventType = eventType
    self:setTarget(otherId)
  end
end

function C:onTrafficTick(tickTime)
  if self.state == 'disabled' then return end

  local baseValues = gameplay_traffic_trafficUtils.getBaseValues()

  if self.veh.isAi and self.state ~= 'disabled' and self.veh.state == 'active' and self.veh.damage > baseValues.highDamage then
    self:setAction('disabled')
  end

  local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
  self.targetVisible = self:checkTargetVisible()
  self.targetNear = (targetVeh and self.veh:getInteractiveDistance(targetVeh.pos, true) <= 3600) and true or false

  if targetVeh and self.veh.isAi then
    local driver = self.driver

    if self.targetVisible and self.targetNear then
      local actionType

      -- target vehicle was driving the wrong way or recklessly
      if driver.eventType == 'nearMiss' and not self.flags.nearMiss and driver.personality.bravery >= 0.5 then
        self.flags.nearMiss = 1 -- prevents this from triggering again until driver state is reset
        self.honkHornDuration = self.driver.personality.bravery * 2.5
        actionType = 'nearMiss'
      end

      -- target vehicle collided with self
      if driver.eventType == 'selfCollision' and self.veh.damage >= baseValues.lowDamage then
        if driver.selfHitCount >= driver.collisionThreshold then
          actionType = 'crashThreshold'
          driver.collisionThreshold = driver.collisionThreshold + 2
        else
          actionType = 'crash'
        end

      -- target vehicle collided with other vehicle
      elseif driver.eventType == 'otherCollision' and targetVeh.damage >= baseValues.lowDamage then
        if driver.otherHitCount >= driver.collisionThreshold + 1 then -- higher threshold than self collision
          actionType = 'crashThreshold'
          driver.collisionThreshold = driver.collisionThreshold + 2
        else
          actionType = 'crash'
        end

      -- target vehicle crashed by itself
      elseif driver.eventType == 'otherCrash' then
        tempVec:setSub2(targetVeh.pos, self.veh.pos)
        if self.state == 'none' and driver.personality.bravery + driver.personality.patience >= 0.8
        and self.veh.driveVec:dot(tempVec) > 0 then
          actionType = 'crash'
        end
      end

      if actionType == 'crashThreshold' then -- follow, flee, etc.
        if driver.damageAction == 'followPostCrash' and self.state ~= 'follow' then
          self:setAction('followPostCrash', {reason = driver.eventType, targetId = self.targetId})
          self.actionTimer = max(minActionTime, (driver.personality.bravery - 0.5) * 60) -- duration for following target
        elseif driver.damageAction == 'fleePostCrash' and self.state ~= 'flee' then
          self:setAction('fleePostCrash', {reason = driver.eventType, targetId = self.targetId})
          self.actionTimer = max(minActionTime, (0.5 - driver.personality.bravery) * 60) -- duration for fleeing from target
        else
          if self.state == 'none' then
            self:setAction('pullOver', {dist = self.veh:getBrakingDistance(self.veh.speed, driver.aggression * 1.5), reason = driver.eventType, useWarnSignal = true})
            self.actionTimer = max(minActionTime, driver.personality.patience * 30)
          end
        end

        self.flags.crashActive = 1
      elseif actionType == 'crash' then -- just pull over and stop
        if self.state == 'none' then
          self:setAction('pullOver', {dist = self.veh:getBrakingDistance(self.veh.speed, driver.aggression * 1.5), reason = driver.eventType, useWarnSignal = true})
          self.actionTimer = max(minActionTime * 0.5, driver.personality.patience * 20)
          if driver.eventType == 'selfCollision' then
            self.flags.askInsurance = 1
          end
        end

        self.flags.crashActive = 1
      end

      if self.actionName == 'followPostCrash' and not self.flags.chaseTarget then -- conditionally change from follow to chase ("road rage")
        tempVec:setSub2(targetVeh.pos, self.veh.pos)
        if tempVec:squaredLength() > 100 and targetVeh.driveVec:dot(tempVec) > 8 and driver.personality.bravery >= 0.6 then -- mode change if target driver seems to flee
          self:setAction('followPostCrash', {reason = driver.eventType, targetId = self.targetId, isChase = true})
          self.actionTimer = max(minActionTime * 2, (driver.personality.bravery - 0.5) * 60) -- duration for following target
          self.flags.chaseTarget = 1
        end
      end
    else -- target not visible or out of range
      if self.state ~= 'none' and self.veh.pos:squaredDistance(targetVeh.pos) >= 14400 then -- check if state needs to be reset
        self:resetAction()
      end
    end
  end

  if self.veh.state == 'active' and self.honkHornDuration and self.honkHornDuration >= 0 then
    self.veh:honkHorn(self.honkHornDuration)
    self.honkHornDuration = nil
  end

  if self.enableTrafficSignalsChange and self.veh.speed >= 6 and next(map.objects[self.veh.id].states) then -- lightbar triggers all traffic lights to change to the red state
    -- this exists here until we have a way to properly recognize emergency vehicles (lightbar exists)
    if map.objects[self.veh.id].states.lightbar then
      self:freezeTrafficSignals(true)
    else
      if self.flags.freezeSignals then
        self:freezeTrafficSignals(false)
      end
    end
  else
    if self.flags.freezeSignals then
      self:freezeTrafficSignals(false)
    end
  end
end

function C:onUpdate(dt, dtSim)
  if self.state == 'disabled' then return end

  local targetVeh = self.targetId and gameplay_traffic.getTrafficData()[self.targetId]
  if targetVeh then
    if self.actionTimer > 0 then
      self.actionTimer = self.actionTimer - dtSim

      if self.flags.askInsurance then
        if self.actionTimer <= 0 then
          if self.targetVisible and self.veh.speed <= 1 and targetVeh.speed <= 1 and self.veh.pos:squaredDistance(targetVeh.pos) <= 400 then
            self:setAction('askInsurance') -- exchange insurance information
            if gameplay_traffic.showMessages and self.targetId == be:getPlayerVehicleID(0) then
              if career_career and career_career.isActive() then
                -- career insurance logic might go here
              else
                ui_message('ui.traffic.interactions.insuranceExchanged', 5, 'traffic', 'trafficLight')
              end
            end
            self.targetId = nil
          else
            self.actionTimer = minActionTime -- bounce time
          end
        end
      elseif self.actionName == 'followPostCrash' or self.actionName == 'fleePostCrash' then
        if self.veh.pos:squaredDistance(targetVeh.pos) > 1600 or self.actionTimer <= 0 then
          if self.veh.collisions[self.targetId] then -- switch to askInsurance mode
            self:setAction('pullOver', {dist = self.veh:getBrakingDistance(self.veh.speed, self.driver.aggression * 1.5), reason = 'selfCollision', useWarnSignal = true})
            self.flags.askInsurance = 1
            self.actionTimer = minActionTime
          else
            self:resetAction()
          end
        end
      elseif self.actionName == 'pullOver' then
        if self.actionTimer <= 0 then
          self:resetAction()
        end
      end
    end
  end
end

return function(...) return require('/lua/ge/extensions/gameplay/traffic/baseRole')(C, ...) end