-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Load Delivery'
C.description = 'Loads a delivery file and sets up vehicles, routes, and puts player in the correct vehicle. Takes a few frames to complete setup. Use Start Delivery node to activate goals, hints, and markers.'
C.category = 'once_f_duration'
C.color = ui_flowgraph_editor.nodeColors.gameplay
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'In flow pin to trigger loading the delivery' },
  { dir = 'in', type = 'flow', name = 'reset', hidden = true, description = 'Resets this node.', impulse = true },
  { dir = 'in', type = 'string', name = 'deliveryPath', default = 'delivery.delivery.json', description = 'Path to the delivery JSON file' },

  { dir = 'out', type = 'flow', name = 'flow', default = false, description = 'Continues flow when delivery is loaded and setup complete.' },
  { dir = 'out', type = 'bool', name = 'success', default = false, description = 'True if delivery was loaded successfully, false otherwise.' },
  { dir = 'out', type = 'bool', name = 'isLoaded', default = false, description = 'True if delivery is loaded and ready to start.' },
}

C.dependencies = { 'gameplay_freeformDelivery_freeformDelivery' }

C.tags = {'delivery', 'gameplay', 'mission'}

function C:init()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
  self.pinOut.isLoaded.value = false
  self:setDurationState('inactive')
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
  self.pinOut.isLoaded.value = false
  self:setDurationState('inactive')
end

function C:workOnce()
  if not self.pinIn.flow.value then return end

  -- Load the delivery file
  local deliveryPath = self.pinIn.deliveryPath.value
  local configuredDeliveryPath = self.mgr and self.mgr.activity and self.mgr.activity.missionTypeData and self.mgr.activity.missionTypeData.deliveryPath
  if configuredDeliveryPath and configuredDeliveryPath ~= '' then
    if not deliveryPath or deliveryPath == '' or deliveryPath == 'delivery.delivery.json' then
      deliveryPath = configuredDeliveryPath
    end
  end
  if not deliveryPath or deliveryPath == '' then
    self.mgr:logEvent("Load Delivery Failed", "E", "No delivery path provided", {type = "node", node = self})
    self.pinOut.success.value = false
    self.pinOut.isLoaded.value = false
    return
  end

  if not gameplay_freeformDelivery_freeformDelivery then
    self.mgr:logEvent("Load Delivery Failed", "E", "Delivery system not available", {type = "node", node = self})
    self.pinOut.success.value = false
    self.pinOut.isLoaded.value = false
    return
  end
  local validFile = self.mgr:getRelativeAbsolutePath(deliveryPath, false)

  local success = gameplay_freeformDelivery_freeformDelivery.load(validFile)
  if not success then
    self.mgr:logEvent("Load Delivery Failed", "E", "Failed to load delivery: " .. tostring(deliveryPath), {type = "node", node = self})
    self.pinOut.success.value = false
    self.pinOut.isLoaded.value = false
    return
  end

  -- Mark as started, waiting for setup to complete
  self:setDurationState('started')
end

function C:work()
  if self.pinIn.reset.value then
    self:reset()
  end

  -- Check if setup is complete
  if self.durationState == 'started' then
    if gameplay_freeformDelivery_freeformDelivery and gameplay_freeformDelivery_freeformDelivery.isLoaded() then
      self.pinOut.success.value = true
      self.pinOut.isLoaded.value = true
      self.pinOut.flow.value = true
      self:setDurationState('finished')
    end
  elseif self.durationState == 'finished' then
    -- Keep flow active and update isLoaded status
    self.pinOut.isLoaded.value = gameplay_freeformDelivery_freeformDelivery and gameplay_freeformDelivery_freeformDelivery.isLoaded() or false
    self.pinOut.flow.value = true
  end
end

return _flowgraph_createNode(C)
