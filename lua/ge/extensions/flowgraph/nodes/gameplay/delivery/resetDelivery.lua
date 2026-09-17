-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Reset Delivery'
C.description = 'Resets the current active delivery, restoring all vehicles to their starting positions and resetting goals.'
C.category = 'once_f_duration'
C.color = ui_flowgraph_editor.nodeColors.gameplay
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'In flow pin to trigger resetting the delivery' },
  { dir = 'in', type = 'flow', name = 'reset', hidden = true, description = 'Resets this node.', impulse = true },

  { dir = 'out', type = 'flow', name = 'flow', default = false, description = 'Continues flow when delivery is reset.' },
  { dir = 'out', type = 'bool', name = 'success', default = false, description = 'True if delivery was reset successfully, false otherwise.' },
}

C.dependencies = { 'gameplay_freeformDelivery_freeformDelivery', 'gameplay_freeformDelivery_setup' }

C.tags = {'delivery', 'gameplay', 'mission'}

function C:init()
  self.pinOut.flow.value = false
  self.pinOut.success.value = false
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
  self:setDurationState('inactive')
end

function C:workOnce()
  if not self.pinIn.flow.value then return end

  if not gameplay_freeformDelivery_freeformDelivery then
    self.mgr:logEvent("Reset Delivery Failed", "E", "Delivery system not available", {type = "node", node = self})
    self.pinOut.success.value = false
    return
  end

  if not gameplay_freeformDelivery_freeformDelivery.isActive() and not gameplay_freeformDelivery_freeformDelivery.isFinished() then
    self.mgr:logEvent("Reset Delivery Failed", "W", "No active or finished delivery to reset", {type = "node", node = self})
    self.pinOut.success.value = false
    return
  end

  local success = gameplay_freeformDelivery_freeformDelivery.reset()
  if not success then
    self.mgr:logEvent("Reset Delivery Failed", "E", "Failed to reset delivery", {type = "node", node = self})
    self.pinOut.success.value = false
    return
  end

  -- Mark as started, waiting for reset (couplings, startup code, etc.) to complete
  self:setDurationState('started')
end

function C:work()
  if self.pinIn.reset.value then
    self:reset()
  end

  -- Check if reset is complete (wait for setup to complete, similar to loadDelivery)
  if self.durationState == 'started' then
    if gameplay_freeformDelivery_freeformDelivery and gameplay_freeformDelivery_setup then
      if gameplay_freeformDelivery_setup.isSetupComplete() then
        self.pinOut.success.value = true
        self.pinOut.flow.value = true
        self:setDurationState('finished')
      end
    else
      -- Fallback: if setup module not available, wait one frame
      self.pinOut.success.value = true
      self.pinOut.flow.value = true
      self:setDurationState('finished')
    end
  elseif self.durationState == 'finished' then
    -- Keep flow active
    self.pinOut.flow.value = true
  end
end

return _flowgraph_createNode(C)
