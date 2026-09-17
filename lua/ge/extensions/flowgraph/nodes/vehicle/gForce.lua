-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Gravity Force'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle

C.description = 'Gets the gravity force (g-force) of a vehicle.'
C.category = 'repeat_p_duration'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Vehicle id; if not provided, uses the current player vehicle.'},
  { dir = 'out', type = 'number', name = 'gx', description = 'Lateral acceleration in g.'},
  { dir = 'out', type = 'number', name = 'gy', description = 'Longitudinal acceleration in g.'},
  { dir = 'out', type = 'number', name = 'gz', description = 'Vertical acceleration in g.'},
  { dir = 'out', type = 'number', name = 'gForce', description = 'Total acceleration in g.'},
  { dir = 'out', type = 'number', name = 'gForceZ0', hidden = true, description = 'Total acceleration in g, ignoring vertical component.'}
}

C.tags = {"gravity", "force", "gforce"}

local values = {accXSmooth = 0, accYSmooth = 0, accZSmooth = 0}

function C:init()
  self:onNodeReset()
end

function C:_executionStarted()
  self:onNodeReset()
end

function C:_executionStopped()
  self:onNodeReset()
end

function C:onNodeReset()
  -- TODO: unregister values
end

function C:work()
  local vehId = self.pinIn.vehId.value or be:getPlayerVehicleID(0)
  local veh = getObjectByID(vehId)
  if not veh then return end

  for k, _ in pairs(values) do
    values[k] = core_vehicleBridge.getCachedVehicleData(vehId, k)
    if not values[k] then
      core_vehicleBridge.registerValueChangeNotification(veh, k)
      values[k] = 0
    end
  end

  local gravity = core_environment.getGravity()
  gravity = math.max(0.01, math.abs(gravity)) * sign2(gravity)

  if values.accZSmooth == 0 then values.accZSmooth = gravity end -- match gravity at first frame

  self.pinOut.gx.value = values.accXSmooth / gravity
  self.pinOut.gy.value = values.accYSmooth / gravity
  self.pinOut.gz.value = (values.accZSmooth - gravity) / gravity
  self.pinOut.gForce.value = math.sqrt(square(self.pinOut.gx.value) + square(self.pinOut.gy.value) + square(self.pinOut.gz.value))
  self.pinOut.gForceZ0.value = math.sqrt(square(self.pinOut.gx.value) + square(self.pinOut.gy.value))
end

return _flowgraph_createNode(C)
