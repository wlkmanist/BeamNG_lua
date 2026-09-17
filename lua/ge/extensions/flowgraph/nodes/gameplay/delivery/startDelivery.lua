-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Start Delivery'
C.description = 'Starts the delivery, making goals, hints, markers, and tasklist visible. Timer starts counting. Requires delivery to be loaded first.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.gameplay
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'In flow pin to trigger starting the delivery' },
  { dir = 'in', type = 'flow', name = 'reset', hidden = true, description = 'Resets this node.', impulse = true },

  { dir = 'out', type = 'flow', name = 'flow', default = false, description = 'Continues flow when delivery is started.' },
  { dir = 'out', type = 'bool', name = 'success', default = false, description = 'True if delivery was started successfully, false otherwise.' },
}

C.dependencies = { 'gameplay_freeformDelivery_freeformDelivery' }

C.tags = {'delivery', 'gameplay', 'mission'}

function C:init()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
end

function C:_executionStopped()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
end

function C:_executionStarted()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
end

function C:work()
  if self.pinIn.reset.value then
    self.pinOut.flow.value = false
    self.pinOut.success.value = false
  end

  if self.pinIn.flow.value then
    if not gameplay_freeformDelivery_freeformDelivery then
      self.mgr:logEvent("Start Delivery Failed", "E", "Delivery system not available", {type = "node", node = self})
      self.pinOut.success.value = false
      self.pinOut.flow.value = false
      return
    end

    if not gameplay_freeformDelivery_freeformDelivery.isLoaded() then
      self.mgr:logEvent("Start Delivery Failed", "E", "No delivery loaded. Use Load Delivery node first.", {type = "node", node = self})
      self.pinOut.success.value = false
      self.pinOut.flow.value = false
      return
    end

    if gameplay_freeformDelivery_freeformDelivery.isActive() then
      self.mgr:logEvent("Start Delivery Failed", "W", "Delivery already active", {type = "node", node = self})
      self.pinOut.success.value = false
      self.pinOut.flow.value = false
      return
    end

    local success = gameplay_freeformDelivery_freeformDelivery.start()
    if not success then
      self.mgr:logEvent("Start Delivery Failed", "E", "Failed to start delivery", {type = "node", node = self})
      self.pinOut.success.value = false
      self.pinOut.flow.value = false
      return
    end

    self.pinOut.success.value = true
    self.pinOut.flow.value = true
  end
end

return _flowgraph_createNode(C)
