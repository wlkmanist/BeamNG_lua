-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

function C:init(damageThreshold)
  -- log('D', logTag, 'VehicleTracker init')

  self.damageThreshold = damageThreshold or 1

  local vehicleId = self:getVehicleId()
  if vehicleId then
    self:updateVehicleData(vehicleId)
  end
  self.lastDamage = self:damage()
  self.lastDamageDiff = 0
  self.justHadDamage = false

  -- Debug visualization settings
  self.debugDraw = false

  self.wheelOffsets = {}
  self.currentCorners = {}
  self.previousCorners = {}

  local vehicle = self:getVehicle()
  if vehicle then
    local wCount = vehicle:getWheelCount()-1
    if wCount > 0 then
      local vehiclePos = vehicle:getPosition()
      local vRot = quatFromDir(vehicle:getDirectionVector(), vehicle:getDirectionVectorUp())
      local x,y,z = vRot * vec3(1,0,0),vRot * vec3(0,1,0),vRot * vec3(0,0,1)
      for i=0, wCount do
        local axisNodes = vehicle:getWheelAxisNodes(i)
        local nodePos = vec3(vehicle:getNodePosition(axisNodes[1]))
        local pos = vec3(nodePos:dot(x), nodePos:dot(y), nodePos:dot(z))
        table.insert(self.wheelOffsets, pos)
        table.insert(self.currentCorners, vRot*pos + vehiclePos)
        table.insert(self.previousCorners, vRot*pos + vehiclePos)
      end
    end
  end
end

function C:getVehicleId()
  -- return getPlayerVehicleID(0)
  local vehicle = self:getVehicle()
  return vehicle and vehicle:getID() or nil
end

function C:getVehicle()
  -- local vehObjId = getPlayerVehicleID(0) -> 50001
  -- print( getObjectByID(getPlayerVehicleID(0)):getId() ) -> 50001
  -- return getObjectByID(self:getVehicleId())
  return getPlayerVehicle(0)
end

-- function C:getPreviousCorners()
--   return self.previousCorners
-- end

-- function C:getCurrentCorners()
--   return self.currentCorners
-- end

-- function C:onUpdate(dt, raceData)
function C:onUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("VehicleTracker - onUpdate")
  local vehId = self:getVehicleId()
  if not vehId then
    self.vehicleData = nil
    self.lastDamage = nil
    self.lastDamageDiff = 0
    self.justHadDamage = false
    profilerPopEvent("VehicleTracker - onUpdate")
    return
  end
  -- raceData = nil

  -- log('D', logTag, 'VehicleTracker.onUpdate vehId='..vehId)

  self:updateVehicleData(vehId)
  -- self:updateVehicleCorners(vehicle, raceData)
  -- self:updateVehicleCorners(vehicle)
  self:updateVehicleDamage()

  -- Draw debug visualization if enabled
  self:drawDebugInfo()

  profilerPopEvent("VehicleTracker - onUpdate")
end

-- function C:updateVehicleCorners(vehicle)
--   -- local vehId = self:getVehicleId()
--   -- if raceData and raceData.states[vehId] then
--     -- self.currentCorners = raceData.states[vehId].currentCorners
--     -- self.previousCorners = raceData.states[vehId].previousCorners
--   -- else
--     if vehicle then
--       local vPos = vehicle:getPosition()
--       local vRot = quatFromDir(vehicle:getDirectionVector(), vehicle:getDirectionVectorUp())
--       for i, corner in ipairs(self.wheelOffsets) do
--         self.previousCorners[i]:set(self.currentCorners[i])
--         self.currentCorners[i]:set(vPos + vRot*corner)
--       end
--     else
--       log('E', logTag, 'updateVehicleCorners: vehicle was null')
--     end
--   -- end
-- end

function C:updateVehicleDamage()
  profilerPushEvent("VehicleTracker - updateVehicleDamage")
  local currDamage = self:damage()
  if not currDamage then
    self.justHadDamage = false
    profilerPopEvent("VehicleTracker - updateVehicleDamage")
    return
  end

  -- this is some one time initial setup.
  -- otherwise, if the vehicle has damage already when the class is instantiated,
  -- it will erroneously think a big jump in damage has occurred..
  if not self.lastDamage then
    self.lastDamage = currDamage
  end

  local diff = currDamage - (self.lastDamage or 0)

  if currDamage > self.lastDamage then
    self.lastDamage = currDamage
    self.lastDamageDiff = diff
    if self.lastDamageDiff >= self.damageThreshold then
      self.justHadDamage = true
    end
  else
    self.justHadDamage = false
  end
  profilerPopEvent("VehicleTracker - updateVehicleDamage")
end

function C:updateVehicleData(vehicleId)
  self.vehicleData = vehicleId and map and map.objects and map.objects[vehicleId] or nil
end

local vehicle = nil
local vehPos = vec3()
function C:pos()
  vehicle = getPlayerVehicle(0)
  if vehicle then
    -- this causes vehicle tracking to break
    vehPos:set(vehicle:getPositionXYZ())
    return vehPos

    -- works
    -- return vehicle:getPosition()
  else
    log('E', logTag, 'pos(): vehicle was null')
    return nil
  end
end

local vehVel = vec3()

function C:velocity()
  vehicle = getPlayerVehicle(0)
  if vehicle then
    -- vehVel = vehicle:getVelocity()
    vehVel:set(vehicle:getVelocityXYZ())
    return vehVel
  else
    log('E', logTag, 'velocity(): vehicle was null')
    return nil
  end
end

function C:speedMs()
  local vel = self:velocity()
  return vel and vel:length() or nil
end

function C:damage()
  if self.vehicleData then
    return self.vehicleData.damage or 0
  else
    return nil
  end
end

function C:didJustHaveDamage()
  -- if self.justHadDamage then
  -- log('I', logTag, 'got damage during last tick. lastDamage='..self.lastDamage ..' diff='..self.lastDamageDiff..' threshold='..self.damageThreshold)
  -- end
  return self.justHadDamage
end

function C:setDebugDraw(enabled)
  self.debugDraw = enabled
end

function C:drawDebugInfo()
  if not self.debugDraw then return end

  local vehicle = self:getVehicle()
  if not vehicle then return end

  local pos = self:pos()
  local vel = self:velocity()
  local speed = self:speedMs()
  if not speed then return end

  if pos then
    -- Draw vehicle position marker
    local markerPos = vec3(pos)
    markerPos.z = markerPos.z + 2.0
    debugDrawer:drawSphere(markerPos, 1.5, ColorF(1, 0, 1, 0.8)) -- Magenta sphere

    -- Draw velocity vector
    if vel and speed > 0.1 then
      local velEnd = vec3(pos) + vel * 2.0 -- Scale for visibility
      velEnd.z = velEnd.z + 2.0
      debugDrawer:drawLine(markerPos, velEnd, ColorF(0, 1, 1, 1)) -- Cyan velocity vector
    end

    -- Draw text info
    local textPos = vec3(markerPos)
    textPos.z = textPos.z + 1.0
    local speedKmh = speed * 3.6
    local text = string.format("VehicleTracker | Pos: %.1f,%.1f,%.1f | Speed: %.1f km/h (%.1f m/s)",
      pos.x, pos.y, pos.z, speedKmh, speed)

    debugDrawer:drawTextAdvanced(
      textPos,
      String(text),
      ColorF(1, 1, 1, 1), -- White text
      true, -- screen aligned
      false, -- not fixed size
      ColorI(128, 0, 128, 200) -- Semi-transparent purple background
    )
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
