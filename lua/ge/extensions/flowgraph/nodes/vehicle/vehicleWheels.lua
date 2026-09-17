-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Get Vehicle Wheel Center'
C.description = 'Provides average position of all wheels.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', default = 0, description = "Vehicle ID. If not present, player vehicle will be used." },
  { dir = 'out', type = 'vec3', name = 'wheelCenter', description = "Average of all wheel positions." }
}

C.tags = {'telemetry', 'wheel', 'info'}

function C:init(mgr, ...)
end

local wCenter, wPos = vec3(), vec3()

function C:work(args)
  local veh
  if self.pinIn.vehId.value then
    veh = scenetree.findObjectById(self.pinIn.vehId.value)
  else
    veh = getPlayerVehicle(0)
  end
  if not veh then return end

  wCenter:set(0,0,0)
  local wCount = veh:getWheelCount() - 1
  if wCount > 0 then
    for i = 0, wCount do
      local axisNodes = veh:getWheelAxisNodes(i)
      wPos:set(veh:getNodePosition(axisNodes[1]))
      wCenter:setAdd(wPos)
    end
    wCenter:setScaled(1 / (wCount + 1))
    wCenter:setAdd(veh:getPosition())
  end
  self.pinOut.wheelCenter.value = wCenter:toTable()
end

return _flowgraph_createNode(C)
