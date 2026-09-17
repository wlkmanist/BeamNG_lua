-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local StagedCountdownUtils = require('/lua/ge/extensions/gameplay/rally/loop/stagedCountdownUtils')
local im  = ui_imgui

local C = {}

C.name = 'Stopped Near Plane?'
C.icon = "timer"
C.behaviour = { once = true, duration = true }
C.description = 'Checks if the vehicle is stopped within D meters of a plane for at least T seconds.'
C.color = rallyUtil.rally_flowgraph_color
C.category = 'repeat'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'flow', name = 'reset', description = 'Resets this node.', impulse = true },
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of the vehicle to check.' },
  { dir = 'in', type = 'vec3', name = 'pos', description = 'Position to check.' },
  { dir = 'in', type = 'quat', name = 'rot', description = 'Rotation of the plane to check.' },
  { dir = 'in', type = 'number', name = 'duration', description = 'Duration of the stop.', default = 4.0, hardcoded = true },
  { dir = 'in', type = 'number', name = 'distance', description = 'Distance to check for.', default = 1, hardcoded = true },
  { dir = 'in', type = 'number', name = 'speedThreshold', description = 'Speed threshold to check for.', default = 0.08, hardcoded = true },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'out', type = 'flow', name = 'impulse', description = 'Impulse flow when the vehicle is stopped near the position.', impulse = true },
}
C.tags = {'rally'}

function C:init(mgr, ...)
  self.timer = 0
  self.running = false
  self.targetPos = nil
  self.dSqared = nil
  self.useDtSim = false

  self.vehicleDataValid = false
  self.signedDistance = 0
  self.displayDistance = 0
  self.lateralDistance = 0
  self.isInsideFiniteControlZone = false
  self.isPastFiniteZone = false
  self.usingGroundMarkerDistance = false
  self.isNearPlaneValue = false
  self.isStoppedValue = false
  self.isStagedValue = false

  self.pos = vec3()
  self.rot = quat()

  self.data = {
    drawDebug = false
  }
end

function C:_executionStarted()
  self.timer = 0
  self.running = false
  self.targetPos = nil
  self.dSqared = nil
  self.vehicleDataValid = false
  self.signedDistance = 0
  self.displayDistance = 0
  self.lateralDistance = 0
  self.isInsideFiniteControlZone = false
  self.isPastFiniteZone = false
  self.usingGroundMarkerDistance = false
  self.isNearPlaneValue = false
  self.isStoppedValue = false
  self.isStagedValue = false
  self.pos = vec3()
  self.rot = quat()
end

function C:updateTimer()
  if not self.running then return end
  self.timer = self.timer + (self.useDtSim and self.mgr.dtSim or self.mgr.dtReal)
  if self.timer >= self.pinIn.duration.value then
    self.running = false
    self.pinOut.impulse.value = true
  end
end

function C:drawMiddle(builder, style)
  builder:Middle()
  if self.pinIn.duration.value == nil then return end
  im.ProgressBar(self.timer / math.max(1e-12, self.pinIn.duration.value), im.ImVec2(50,0))
end

local veh, vehicleData
local vehPos, vehVel = vec3(), vec3()
-- Reusable temporary vectors for core calculations (avoid per-frame allocations)
local tmpVec1, tmpVec2 = vec3(), vec3()

-- uses vehicle bounding box front center point
function C:updateVehicleData()
  -- Get vehicle and update position/velocity (using module-level variables)
  if not self.pinIn.vehId.value then
    return false
  end

  veh = scenetree.findObjectById(self.pinIn.vehId.value)
  if not veh then
    return false
  end

  vehicleData = map.objects[veh:getId()]
  if not vehicleData then
    return false
  end

  -- Get vehicle front center (set module-level vehPos, vehVel)
  vehPos:set(rallyUtil.getVehFrontCenter(veh:getId()))
  vehVel:set(vehicleData.vel)

  return true
end

-- function C:isStopped()
--   if vehVel then
--     return vehVel:length() < self.pinIn.speedThreshold.value
--   else
--     return false
--   end
-- end

-- Calculate the signed distance from vehicle to plane
-- Returns: signedDistance (negative = back, positive = front)
-- function C:calculatePlaneDistance()
--   if not vehPos then return nil, nil end

--   local planePos = self.pos
--   local rot = self.rot

--   -- The plane normal is the y-axis (since plane is drawn in x-z) - reuse tmpVec1
--   tmpVec1:set(0, 1, 0)
--   tmpVec1:set(rot * tmpVec1)
--   tmpVec1:normalize()

--   -- Calculate signed distance from vehicle to plane - reuse tmpVec2
--   tmpVec2:setSub2(vehPos, planePos)  -- toVehicle
--   local dist = tmpVec2:dot(tmpVec1)
--   local signedDistance = dist

--   return signedDistance
-- end

-- function C:isNearPlane()
--   local signedDistance = self:calculatePlaneDistance()
--   if not signedDistance then return false end

--   -- Check if within distance threshold and not behind the plane (signedDistance must be >= 0)
--   local isNear = signedDistance >= 0 and math.abs(signedDistance) <= self.pinIn.distance.value
--   return isNear, signedDistance
-- end

local tmpPlaneNormal = vec3()
local tmpToVehicle = vec3()
local tmpLateralToControl = vec3()
local tmpClosestPoint = vec3()
local tmpMidPoint = vec3()

-- Limits the wrong-side check to the actual control area instead of an infinite plane.
local finiteControlZoneRadius = 10

local function getGroundMarkerDistance()
  if core_groundMarkers and core_groundMarkers.currentlyHasTarget() then
    local groundMarkerDist = core_groundMarkers.getPathLength()
    if groundMarkerDist then
      return groundMarkerDist
    end
  end
  return nil
end

function C:updateProximityState()
  -- Calculate all proximity state once per frame (requires valid vehicle data)
  if not self.vehicleDataValid then
    self.signedDistance = 0
    self.displayDistance = 0
    self.lateralDistance = 0
    self.isInsideFiniteControlZone = false
    self.isPastFiniteZone = false
    self.usingGroundMarkerDistance = false
    self.isNearPlaneValue = false
    self.isStoppedValue = false
    self.isStagedValue = false
    return
  end

  -- Calculate signed distance from vehicle to plane
  local planePos = self.pos
  local rot = self.rot

  -- The plane normal is the y-axis (since plane is drawn in x-z) - reuse tmpPlaneNormal
  tmpPlaneNormal:set(0, 1, 0)
  tmpPlaneNormal:set(rot * tmpPlaneNormal)
  tmpPlaneNormal:normalize()

  -- Calculate signed distance from vehicle to plane - reuse tmpToVehicle
  tmpToVehicle:setSub2(vehPos, planePos)
  local dist = tmpToVehicle:dot(tmpPlaneNormal)

  -- Flip sign so back/past is negative, front/before is positive (for display convention)
  self.signedDistance = -dist
  -- self.signedDistance = dist

  -- Measure how far the vehicle's projection onto the plane is from the control center.
  tmpLateralToControl:set(tmpPlaneNormal)
  tmpLateralToControl:setScaled(dist)
  tmpLateralToControl:setSub2(tmpToVehicle, tmpLateralToControl)
  self.lateralDistance = tmpLateralToControl:length()
  self.isInsideFiniteControlZone = self.lateralDistance <= finiteControlZoneRadius
  self.isPastFiniteZone = self.signedDistance < 0 and self.isInsideFiniteControlZone

  -- Check if vehicle is stopped
  self.isStoppedValue = vehVel:length() < (self.pinIn.speedThreshold.value or 0.08)

  local groundMarkerDist = getGroundMarkerDistance()

  -- Final stop detection must happen at the control, not anywhere along the infinite plane.
  self.isNearPlaneValue = self.isInsideFiniteControlZone and self.signedDistance >= 0 and self.signedDistance <= (self.pinIn.distance.value or 1)

  if self.isInsideFiniteControlZone then
    self.displayDistance = self.signedDistance
    self.usingGroundMarkerDistance = false
  elseif groundMarkerDist then
    self.displayDistance = groundMarkerDist
    self.usingGroundMarkerDistance = true
  elseif self.signedDistance >= 0 then
    self.displayDistance = self.signedDistance
    self.usingGroundMarkerDistance = false
  else
    self.displayDistance = math.max(0, self.lateralDistance - finiteControlZoneRadius)
    self.usingGroundMarkerDistance = false
  end

  -- Vehicle is staged if it's near the plane AND stopped
  self.isStagedValue = self.isNearPlaneValue and self.isStoppedValue
end

function C:shouldDrawDebug()
  local loopManager = self:getRallyLoopManager()
  return self.data.drawDebug or (loopManager and loopManager:getDrawFlag('stopZones'))
end

function C:getRallyLoopManager()
  -- Try to get rally loop manager (only exists in rally loop missions)
  if gameplay_rallyLoop then
    return gameplay_rallyLoop.getManager()
  end
  return nil
end

function C:isNearPlane()
  return self.isNearPlaneValue
end

function C:drawDebugVisualization()
  if not self:shouldDrawDebug() or not self.vehicleDataValid then
    return
  end

  StagedCountdownUtils.drawDebugPlane(self.pos, self.rot, true)
  StagedCountdownUtils.drawVehicleToPlaneDebug(vehPos, self.pos, self.rot, tmpPlaneNormal, tmpToVehicle, tmpClosestPoint, tmpMidPoint)
  StagedCountdownUtils.drawDebugVehiclePoint(vehPos, self:isNearPlane())
end

function C:work(args)
  if self.pinIn.pos.value and self.pinIn.rot.value then
    -- Handle both array format and vec3/quat object format
    local posVal = self.pinIn.pos.value
    local rotVal = self.pinIn.rot.value

    if type(posVal) == "table" then
      -- Array format
      self.pos:set(posVal[1], posVal[2], posVal[3])
    else
      -- vec3 object format
      self.pos:set(posVal)
    end

    if type(rotVal) == "table" then
      -- Array format
      self.rot:set(rotVal[1], rotVal[2], rotVal[3], rotVal[4])
    else
      -- quat object format
      self.rot:set(rotVal)
    end
  else
    return
  end

  self.vehicleDataValid = self:updateVehicleData()
  self:updateProximityState()
  self:drawDebugVisualization()

  self.pinOut.impulse.value = false
  if self.pinIn.duration.value == nil then return end

  local duration = math.max(1e-12, self.pinIn.duration.value)

  local isStopped = self.isStoppedValue
  local isNearPlane = self.isNearPlaneValue
  local signedDistance = self.signedDistance

  -- dump("isStopped: " .. tostring(isStopped))
  -- dump("isNearPlane: " .. tostring(isNearPlane) .. " signedDistance: " .. tostring(signedDistance))

  -- Start/reset timer logic
  if self.pinIn.flow.value and not self.running and self.timer < duration then
    self.running = true
    self.timer = 0
  elseif self.pinIn.reset.value or not isNearPlane then
    self.timer = 0
    self.running = false
  end

  if isStopped and isNearPlane then
    self:updateTimer()
  elseif not isStopped and isNearPlane then
    -- Reset timer if car moves, even if inside distance
    self.timer = 0
  end

  -- Calculate straight-line distance to target position
  -- local straightLineDistToPos = vehPos:distance(self.pos)

  local displayDistance = self.displayDistance
  local distanceToPlane = signedDistance

  -- Unified proximity data structure
  local proximityData = {
    isNear = isNearPlane,
    distance = displayDistance,
    distanceToPlane = distanceToPlane,
    -- straightLineDistToPos = straightLineDistToPos,
    isStopped = isStopped,
    isFrozen = false,
    usingGroundMarkerDistance = self.usingGroundMarkerDistance,
    timer = self.timer,
    duration = duration
  }

  -- Send to Lua extensions
  extensions.hook("onRallyDataUpdated", {
    activeState = rallyUtil.activeState_vehicleProximity,
    vehicleProximity = proximityData
  })

  self.pinOut.flow.value = self.timer >= duration and self.pinIn.flow.value
end

return _flowgraph_createNode(C)
