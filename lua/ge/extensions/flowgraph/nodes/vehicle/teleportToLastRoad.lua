-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Teleport To Last Road'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle

C.description = "Teleports the vehicle to the previous valid road."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Defines the id of the vehicle to move.' },
  { dir = 'in', type = 'bool', name = 'resetVehicle', description = 'Fully resets the vehicle when teleported.' },
  { dir = 'in', type = 'vec3', name = 'destinationPos', description = '(Optional) The destination position that the vehicle should face towards.' }
}
C.tags = {'rotation', 'position', 'recover', 'teleport', 'move'}

function C:init()
  --self.data.useWheelCenter = false
end

function C:work()
  local veh
  if self.pinIn.vehId.value then
    veh = scenetree.findObjectById(self.pinIn.vehId.value)
  else
    veh = getPlayerVehicle(0)
  end
  if not veh then return end

  local targetPos = vec3(self.pinIn.destinationPos.value)
  if not self.pinIn.destinationPos.value then
    targetPos:set(veh:getPositionXYZ())
    targetPos:setAdd(veh:getDirectionVector() * 15) -- arbitrary position ahead of the vehicle
  end
  spawn.teleportToLastRoad(veh, {resetVehicle = self.pinIn.resetVehicle.value, destinationPos = targetPos})
  extensions.hook('onVehicleTeleportedToLastRoad', veh:getID())
end

return _flowgraph_createNode(C)
