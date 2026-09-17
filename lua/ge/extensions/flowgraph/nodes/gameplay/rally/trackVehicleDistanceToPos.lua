-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local im  = ui_imgui

local C = {}

C.name = 'Track Vehicle Distance to Position'
C.icon = "straighten"
C.description = 'Tracks the distance from a vehicle to a position and streams it to the UI.'
C.color = rallyUtil.rally_flowgraph_color
C.category = 'repeat'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of the vehicle to check.' },
  { dir = 'in', type = 'vec3', name = 'pos', description = 'Position to check.' },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.' },
}
C.tags = {'rally'}

function C:init(mgr, ...)
  self.targetPos = nil
end

function C:_executionStarted()
  self.targetPos = nil
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

function C:getDistanceSquared()
  if self.targetPos == nil then
    if type(self.pinIn.pos.value) == "table" and not self.pinIn.pos.value.x then
      self.targetPos = vec3(self.pinIn.pos.value)
    elseif self.pinIn.pos.value then
      self.targetPos = self.pinIn.pos.value
    end
  end
  if self.targetPos then
    return vehPos:squaredDistance(self.targetPos)
  else
    return nil
  end
end

function C:work(args)
  self:updateVehicleData2()

  local distanceSquared = self:getDistanceSquared()

  -- Send proximity data to Lua extensions
  if distanceSquared then
    -- Unified proximity data structure
    local proximityData = {
      isNear = false,
      distance = math.sqrt(distanceSquared),
      isStopped = false,
      isFrozen = false,
      timer = 0,
      duration = 0
    }
    extensions.hook("onRallyDataUpdated", {
      activeState = rallyUtil.activeState_vehicleProximity,
      vehicleProximity = proximityData
    })
  end

  self.pinOut.flow.value = self.pinIn.flow.value
end

return _flowgraph_createNode(C)
