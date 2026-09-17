-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This class tracks a vehicle's alignment and driving behavior on the road
-- Maybe consider moving this into a more suitable directory

local min = math.min
local max = math.max
local abs = math.abs

local C = {}

local tempVec = vec3()

function C:init(vehId)
  if not getObjectByID(vehId or -1) then
    log('E', 'roadTracking', string.format('Failed to initialize vehicle: %d', vehId))
    self._invalid = true
  end

  self.vehId = vehId
  self.pos, self.dirVec, self.vel = vec3(), vec3(), vec3()
  self.roadPos, self.roadDirVec, self.roadLeftPos, self.roadRightPos = vec3(), vec3(), vec3(), vec3()

  self.vehExtents = getObjectByID(vehId).initialNodePosBB:getExtents() -- vehicle width, length, and height
  self.vehBasicRadius = min(self.vehExtents.x, self.vehExtents.y) / 2 -- basic radius of the vehicle (half width or half length)
  -- TODO: vehBasicRadius is simple but less accurate; should really upgrade this to OBB later

  self.speedLimitFloor = 4.167 -- minimum checked speed limit (15 km/h)
  self.speedLimitCoef = 1.125 -- multiplier for speed limit
  self.highFrequency = false -- if true, force updates current road every frame
  self.fullStats = false -- if true, processes additional stats every frame

  self:refresh()
end

function C:refresh() -- resets all tables and values
  self.n1, self.n2 = '', ''
  self.linkData = {}
  self.speedLimit = self.speedLimitFloor
  self.centerLineXnorm = 0.5
  self.halfWidth = 0
  self.isPublicRoad = true
  self.isOneWay = false
  self.legalSide = map.getRoadRules().rightHandDrive and -1 or 1 -- negative if left side, positive if right side

  self.faults = { -- penalty scores, clamped from 0 to 1 (num > 0.5 triggers police offenses)
    overSpeed = 0,
    wrongWay = 0,
    reckless = 0
  }
  self.timers = { -- timers for faults
    overSpeed = 0,
    wrongWay = 0,
    reckless = 0
  }
  self.collisionIds = {}

  self:resetValues()

  if not map.objects[self.vehId] then return end

  self:updateVehicle()
  self:updateCurrentRoad()
end

function C:resetValues() -- resets active tracking values
  self.speedRatio = 1 -- current vehicle speed divided by speed limit
  self.alignment = 1 -- direction alignment with road (close to 1 if parallel)
  self.roadOffset = 0 -- precise road side offset, relative to center line of road
  self.roadXnorm = 0 -- normalized road lateral offset (left edge is 0, right edge is 1)
  self.roadYnorm = 0 -- normalized road longitudinal offset (back edge is 0, front edge is 1)
  self.sideValue = 1 -- legal side (1) or illegal side (-1)
  self.lastSideValue = 1
  self.collisionCount = 0
  self.isNearRoad = true -- if false, cancels some tracking values
  self.isOnRoad = true
  self.isReverse = false

  -- maybe include lane offset as well

  self.currSignal = nil
  self.signalAction = nil
  self.signalFault = nil -- value gets set when the vehicle disobeys the signal action state

  table.clear(self.collisionIds)

  for k, _ in pairs(self.faults) do
    self.faults[k] = 0
  end
  for k, _ in pairs(self.timers) do
    self.timers[k] = 0
  end
end

function C:updateVehicle() -- updates the vehicle data
  self.pos:set(be:getObjectOOBBCenterXYZ(self.vehId)) -- precise center position of vehicle
  self.dirVec:set(map.objects[self.vehId].dirVecUp)
  self.dirVec:setScaled(self.vehExtents.z / 2)
  self.pos:setSub(self.dirVec) -- corrected center ground position

  self.dirVec:set(map.objects[self.vehId].dirVec)
  self.vel:set(map.objects[self.vehId].vel)
  self.speed = self.vel:length()
  self.isReverse = self.dirVec:dot(self.vel) <= -1 -- minimum 1 m/s speed in the opposite vehicle direction
end

function C:calcVehOnRoad() -- calculates the vehicle placement and direction on the road; returns false if direction changed or exited bounds
  local mapNodes = map.getMap().nodes
  tempVec:set(self.dirVec)
  tempVec:setScaled(self.isReverse and -1 or 1)
  if not self.isNearRoad or not mapNodes[self.n1] or not mapNodes[self.n2] then return false end

  local p1, p2 = mapNodes[self.n1].pos, mapNodes[self.n2].pos
  self.roadYnorm = self.pos:xnormOnLine(p1, p2) -- normalized road longitudinal offset
  self.halfWidth = lerp(mapNodes[self.n1].radius, mapNodes[self.n2].radius, self.roadYnorm) -- precise half width of the road at this position
  self.roadPos:setLerp(p1, p2, self.roadYnorm)
  self.roadDirVec:setSub2(mapNodes[self.n2].pos, mapNodes[self.n1].pos)
  self.roadDirVec:normalize()

  self.alignment = tempVec:dot(self.roadDirVec) -- almost 1 if parallel to road

  self.roadLeftPos:setCross(self.roadDirVec, map.surfaceNormal(self.roadPos))
  self.roadLeftPos:setScaled(self.halfWidth)
  self.roadRightPos:setAdd2(self.roadPos, self.roadLeftPos) -- right edge of road
  self.roadLeftPos:setSub2(self.roadPos, self.roadLeftPos) -- left edge of road
  self.roadXnorm = self.pos:xnormOnLine(self.roadLeftPos, self.roadRightPos) -- normalized road lateral offset
  self.roadOffset = self.halfWidth * 2 * (self.roadXnorm - self.centerLineXnorm) -- actual road side offset

  local validRoad = true
  self.isOnRoad = true

  if (self.alignment < 0 and not self.isOneWay) -- this condition forces the road nodes (n1, n2) to swap
  or (self.roadXnorm < 0 or self.roadXnorm > 1) -- vehicle is outside of the left or right edge of the road
  or (self.roadYnorm < 0 or self.roadYnorm > 1) then -- vehicle is outside of the back or front edge of the road
    validRoad = false
  end

  if not validRoad then -- precise check for vehicle within road bounds; TODO: use OBB instead
    if (self.roadXnorm < 0 and self.roadLeftPos:squaredDistance(self.pos) > square(self.vehBasicRadius))
    or (self.roadXnorm > 1 and self.roadRightPos:squaredDistance(self.pos) > square(self.vehBasicRadius))
    or (self.roadYnorm < 0 and p1:squaredDistance(self.pos) > square(mapNodes[self.n1].radius + self.vehBasicRadius))
    or (self.roadYnorm > 1 and p2:squaredDistance(self.pos) > square(mapNodes[self.n2].radius + self.vehBasicRadius)) then
      self.isOnRoad = false
    end
  end

  return validRoad
end

function C:updateCurrentRoad() -- queries and updates the current road segment
  local mapNodes = map.getMap().nodes
  tempVec:set(self.dirVec)
  tempVec:setScaled(self.isReverse and -1 or 1)
  local n1, n2 = map.findBestRoad(self.pos, tempVec)
  if n1 and n2 then
    self.isNearRoad = true
    self.n1, self.n2 = n1, n2
    self.linkData = mapNodes[n1].links[n2] or mapNodes[n2].links[n1]
    self.isPublicRoad = self.linkData.type ~= 'private' and self.linkData.drivability >= 0.25
    self.isOneWay = self.linkData.oneWay
    self.speedLimit = max(self.speedLimitFloor, self.linkData.speedLimit)

    self.roadDirVec:setSub2(mapNodes[n2].pos, mapNodes[n1].pos)
    local flipDirection = false
    if (self.isOneWay and self.linkData.inNode == n2) or (not self.isOneWay and self.roadDirVec:dot(tempVec) < 0) then
      self.n1, self.n2 = n2, n1
      self.roadDirVec:setScaled(-1)
      flipDirection = true
    end

    local lanes = self.linkData.lanes
    if not lanes or #lanes == 0 then
      self.centerLineXnorm = 0.5
    else
      local _, iCount = string.gsub(lanes, '-', '')
      local _, oCount = string.gsub(lanes, '+', '')
      self.centerLineXnorm = flipDirection and iCount / #lanes or oCount / #lanes
    end

    self:calcVehOnRoad()
  else
    self.isNearRoad = false
    self.n1, self.n2 = '', ''
    self.linkData = {}
    self.speedLimit = self.speedLimitFloor
    self.centerLineXnorm = 0.5
    self:resetValues()
  end
end

function C:onUpdate(dt)
  local mapNodes = map.getMap().nodes
  if not map.objects[self.vehId] then return end

  self:updateVehicle()

  if self.highFrequency then
    self:updateCurrentRoad()
  else
    if not self:calcVehOnRoad() then
      self:updateCurrentRoad()
    end
  end

  self.collisionIds = tableMerge(self.collisionIds, map.objects[self.vehId].objectCollisions) -- NOTE: may not capture all collisions if dt is too large
  self.collisionCount = tableSize(self.collisionIds)

  if not self.isNearRoad or not mapNodes[self.n1] or not mapNodes[self.n2] then
    self:resetValues()
    return
  end

  if self.isPublicRoad then
    self.speedRatio = self.speed / (self.speedLimit + 1e-12)
    local faultCoef = min(2, self.speedRatio)

    -- vehicle is exceeding the speed limit by more than the threshold
    if self.speedRatio >= self.speedLimitCoef then
      self.faults.overSpeed = min(1, self.faults.overSpeed + faultCoef * dt * 0.12) -- increases faster at higher speeds
      self.timers.overSpeed = self.timers.overSpeed + dt
    else
      self.faults.overSpeed = max(0, self.faults.overSpeed - dt * 0.05)
      self.timers.overSpeed = 0
    end

    if self.speed > self.speedLimitFloor and self.isOnRoad and abs(self.alignment) > 0.707 then -- player is driving somewhat parallel on the road
      if not self.isOneWay then
        if self.legalSide == 1 then
          self.sideValue = self.roadXnorm > self.centerLineXnorm and 1 or -1 -- legal or illegal side
        else
          self.sideValue = self.roadXnorm < self.centerLineXnorm and 1 or -1
        end
      else
        self.sideValue = self.alignment > 0 and 1 or -2 -- legal or illegal direction
      end
    else
      self.sideValue = 1
    end

    faultCoef = faultCoef * (self.isOneWay and 2 or 1)

    -- vehicle is driving on the wrong side or wrong way
    if self.sideValue < 0 then
      self.faults.wrongWay = min(1, self.faults.wrongWay + faultCoef * dt * 0.1) -- increases faster if wrong way on oneWay
      self.timers.wrongWay = self.timers.wrongWay + dt
    else
      self.faults.wrongWay = max(0, self.faults.wrongWay - dt * 0.05)
      self.timers.wrongWay = 0
    end

    -- vehicle is driving recklessly (rapidly crossing lanes, doing donuts, etc.)
    if self.sideValue ~= self.lastSideValue then
      self.faults.reckless = min(1, self.faults.reckless + dt * faultCoef * 0.32) -- increases every time the vehicle switches from legal side to illegal side
      self.timers.reckless = self.timers.reckless + dt
    else
      self.faults.reckless = max(0, self.faults.reckless - dt * 0.025)
      self.timers.reckless = 0
    end
  else
    self.speedRatio, self.sideValue = 1, 1
    for k, _ in pairs(self.faults) do
      self.faults[k] = 0
    end
    for k, _ in pairs(self.timers) do
      self.timers[k] = 0
    end
  end

  self.lastSideValue = self.sideValue

  local mapSignals = core_trafficSignals and core_trafficSignals.getMapNodeSignals()
  if tableIsEmpty(mapSignals) then return end

  if not self.currSignal and mapSignals[self.n1] and mapSignals[self.n1][self.n2] then
    for _, signal in ipairs(mapSignals[self.n1][self.n2]) do -- get best signal from current road segment
      -- TODO: this can be problematic if the navgraph network is complex or overlapping
      local bestDist = 400
      local dist = self.pos:squaredDistance(signal.pos)
      if dist < bestDist then
        bestDist = dist
        self.currSignal = signal
        self.signalAction = nil
        self.signalFault = nil
      end
    end
  end

  local signal = self.currSignal
  if signal then
    local instance = core_trafficSignals.getSignalByName(signal.instance)
    if instance and instance.targetPos then
      local signalSpeedLimit = max(14, self.speedLimit)
      local minDot = self.signalAction and 0 or 0.707 -- should be 0 after the vehicle passed the signal point
      local valid, data = instance:isVehAfterSignal(self.vehId, 20, minDot)
      if data then
        if valid then -- vehicle is after signal point
          if not self.signalAction then
            self.signalAction = signal.action
            if signal.action == 3 and self.speed > signalSpeedLimit then -- if speed is high enough, trigger the stop sign violation (strongly prevents false positives)
              self.signalFault = instance.name
            end
          end
        elseif data.relDist > 0 then -- vehicle exited signal bounds
          if self.signalAction == 2 then
            if self.speed > signalSpeedLimit then -- if speed is high enough, always trigger the red light violation
              self.signalFault = instance.name
            else -- otherwise, check if the vehicle made a turn
              tempVec:set(0, 0, 1)
              tempVec:setCross(instance.dir, tempVec)
              tempVec:setScaled(-self.legalSide)
              tempVec:setAdd(instance.dir)
              tempVec:normalize()
              if self.dirVec:dot(tempVec) * (self.isReverse and -1 or 1) > 0 then
                self.signalFault = instance.name
              end
            end
          end

          self.currSignal = nil -- reset signal tracking
        end
      end
    end
  end
end

function C:onSerialize()
  return {
    vehId = self.vehId,
    speedLimitFloor = self.speedLimitFloor,
    speedLimitCoef = self.speedLimitCoef,
    highFrequency = self.highFrequency,
    fullStats = self.fullStats
  }
end

function C:onDeserialized(data)
  self.vehId = data.vehId
  self.speedLimitFloor = data.speedLimitFloor
  self.speedLimitCoef = data.speedLimitCoef
  self.highFrequency = data.highFrequency
  self.fullStats = data.fullStats
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  C.__index = C
  o:init(o.vehId)
  return o
end