-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Abandon Delivery'
C.description = 'Abandons the current delivery and tears down the delivery system, removing all vehicles, cleaning up UI elements, and resetting state.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.gameplay
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'In flow pin to trigger abandoning the delivery' },
  { dir = 'in', type = 'flow', name = 'reset', hidden = true, description = 'Resets this node.', impulse = true },
  { dir = 'in', type = 'bool', name = 'keepVehicles', default = false, description = 'If true, vehicles will be preserved and moved out of prefabs to prevent deletion.' },

  { dir = 'out', type = 'flow', name = 'flow', default = false, description = 'Continues flow when delivery is abandoned and torn down.' },
  { dir = 'out', type = 'bool', name = 'success', default = false, description = 'True if delivery was abandoned successfully, false otherwise.' },
}

C.dependencies = { 'gameplay_freeformDelivery_freeformDelivery' }

C.tags = {'delivery', 'gameplay', 'mission'}

function C:init()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
end

function C:_executionStopped()
  self:reset()
end

function C:onNodeReset()
  self:reset()
end

function C:reset()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
end



function C:work()
  if self.pinIn.reset.value then
    self:reset()
  end

  if not self.pinIn.flow.value then return end

  if not gameplay_freeformDelivery_freeformDelivery then
    self.mgr:logEvent("Abandon Delivery Failed", "E", "Delivery system not available", {type = "node", node = self})
    self.pinOut.success.value = false
    self.pinOut.flow.value = false
    return
  end

  local keepVehicles = self.pinIn.keepVehicles.value or false
  gameplay_freeformDelivery_freeformDelivery.teardown(keepVehicles)
  self.pinOut.success.value = true
  self.pinOut.flow.value = true
end

return _flowgraph_createNode(C)
