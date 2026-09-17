-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local im  = ui_imgui

local C = {}

C.name = 'Stopped Near Position?'
C.icon = "timer"
C.behaviour = { once = true, duration = true }
C.description = 'Checks if the vehicle is stopped near a position for at least T seconds.'
C.color = rallyUtil.rally_flowgraph_color
-- C.category = 'once_f_duration'
C.category = 'repeat'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'flow', name = 'reset', description = 'Resets this node.', impulse = true },
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of the vehicle to check.' },
  { dir = 'in', type = 'vec3', name = 'pos', description = 'Position to check.' },
  { dir = 'in', type = 'number', name = 'duration', description = 'Duration of the stop.', default = 0.5, hardcoded = true },
  { dir = 'in', type = 'number', name = 'radius', description = 'Radius to check for.', default = 4, hardcoded = true },

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
  self.hookInterval = 0.1  -- Send hook every 0.1 seconds
end

function C:_executionStarted()
  self.timer = 0
  self.running = false
  self.targetPos = nil
  self.dSqared = nil
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
-- local wCenter, wPos = vec3(), vec3()
local vehPos, vehRot, vehVel = vec3(), quat(), vec3()

-- function C:updateVehicleData()
--   if self.pinIn.vehId.value then
--     veh = scenetree.findObjectById(self.pinIn.vehId.value)
--   else
--     veh = getPlayerVehicle(0)
--   end
--   if not veh then return end

--   vehicleData = map.objects[veh:getId()]

--   if vehicleData then
--     vehPos:set(vehicleData.pos)
--     vehRot:setFromDir(vehicleData.dirVec, vehicleData.dirVecUp)
--     vehVel:set(vehicleData.vel)
--   end
-- end

-- uses vehicle bounding box leading point
function C:updateVehicleData2()
  if self.pinIn.vehId.value then
    veh = scenetree.findObjectById(self.pinIn.vehId.value)
  else
    veh = getPlayerVehicle(0)
  end
  if not veh then return end

  vehicleData = map.objects[veh:getId()]

  if vehicleData then
    -- vehPos:set(vehicleData.pos)
    vehPos:set(rallyUtil.getVehFrontCenter(veh:getId()))
    vehRot:setFromDir(vehicleData.dirVec, vehicleData.dirVecUp)
    vehVel:set(vehicleData.vel)
  end

end

function C:isStopped()
  if vehVel then
    return vehVel:length() < 0.1
  else
    return false
  end
end

function C:isNearPosition()
  if self.dSqared == nil then
    self.dSqared = self.pinIn.radius.value * self.pinIn.radius.value
  end
  if self.targetPos == nil then
    if type(self.pinIn.pos.value) == "table" and not self.pinIn.pos.value.x then
      self.targetPos = vec3(self.pinIn.pos.value)
    elseif self.pinIn.pos.value then
      self.targetPos = self.pinIn.pos.value
    end
  end
  if self.targetPos and self.dSqared then
    local distance = vehPos:squaredDistance(self.targetPos)
    return distance <= self.dSqared, math.sqrt(distance)
  else
    return false
  end
end

function C:drawDebugStopZone()
  if gameplay_rallyLoop and gameplay_rallyLoop.getDrawFlag('stopZones') then
    debugDrawer:drawSphere(self.targetPos, self.pinIn.radius.value, ColorF(0.2, 0.2, 1.0, 0.2), true, false)
  end
end

function C:drawDebugVehiclePoint(inside)
  -- debugDrawer:drawCylinder(vehPos, vehPos + vec3(0,0,2), 0.1, ColorF(0,1,0,0.5), true, false)
  if gameplay_rallyLoop and gameplay_rallyLoop.getDrawFlag('stopZones') then
    local vehId = self.pinIn.vehId.value
    rallyUtil.drawVehLeadingPoint(vehId, inside)
  end
end

function C:work(args)
  -- self:updateVehicleData()
  self:updateVehicleData2()

  self:drawDebugStopZone()

  self.pinOut.impulse.value = false
  if self.pinIn.duration.value == nil then return end

  local duration = math.max(1e-12, self.pinIn.duration.value)

  if self.pinIn.flow.value and not self.running and self.timer < duration then
    self.running = true
    self.timer = 0
  end
  if self.pinIn.reset.value then
    self.timer = 0
    self.running = false
  end

  local isStopped = self:isStopped()
  local isNearPosition, distance = self:isNearPosition()

  if isStopped and isNearPosition then
    self:updateTimer()
  elseif not isStopped and isNearPosition then
    -- Reset timer if car moves, even if inside distance
    self.timer = 0
  end

  if isNearPosition then
    self:drawDebugVehiclePoint(true)
  else
    self:drawDebugVehiclePoint(false)
  end

  -- Unified proximity data structure
  local proximityData = {
    isNear = isNearPosition,
    distance = distance,
    isStopped = isStopped,
    isFrozen = false,
    timer = self.timer,
    duration = duration,
  }

  -- Send to Lua extensions
  extensions.hook("onRallyDataUpdated", {
    activeState = rallyUtil.activeState_vehicleProximity,
    vehicleProximity = proximityData
  })

  self.pinOut.flow.value = self.timer >= duration and self.pinIn.flow.value
end

return _flowgraph_createNode(C)
