-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Delivery Finished'
C.description = 'Detects when the delivery is finished (either automatically when all goals are completed, or manually via the quick access menu).'
C.category = 'repeat_instant'
C.color = ui_flowgraph_editor.nodeColors.gameplay
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'In flow pin to continuously check for delivery completion' },

  { dir = 'out', type = 'flow', name = 'finished', default = false, description = 'Triggers once when delivery is finished.', impulse = true },
  { dir = 'out', type = 'bool', name = 'isActive', default = false, description = 'True if delivery is currently active, false otherwise.' },
  { dir = 'out', type = 'bool', name = 'failed', default = false, description = 'True if delivery failed, false if completed successfully.' },
  { dir = 'out', type = 'string', name = 'failReason', default = '', description = 'Reason for failure, empty string if delivery succeeded.' },
}

C.dependencies = { 'gameplay_freeformDelivery_freeformDelivery' }

C.tags = {'delivery', 'gameplay', 'mission'}

function C:init()
  self.wasActive = false
  self.wasFinished = false
  self.pinOut.finished.value = false
  self.pinOut.isActive.value = false
  self.pinOut.failed.value = false
  self.pinOut.failReason.value = ''
end

function C:_executionStopped()
  self.wasActive = false
  self.wasFinished = false
  self.pinOut.finished.value = false
  self.pinOut.isActive.value = false
  self.pinOut.failed.value = false
  self.pinOut.failReason.value = ''
end

function C:_executionStarted()
  self.wasActive = false
  self.wasFinished = false
  self.pinOut.finished.value = false
  self.pinOut.isActive.value = false
  self.pinOut.failed.value = false
  self.pinOut.failReason.value = ''
end

function C:work()
  if self.pinIn.flow.value then
    if not gameplay_freeformDelivery_freeformDelivery then
      self.pinOut.isActive.value = false
      self.pinOut.failed.value = false
      self.pinOut.failReason.value = ''
      return
    end

    local isActive = gameplay_freeformDelivery_freeformDelivery.isActive()
    local isFinished = gameplay_freeformDelivery_freeformDelivery.isFinished()
    self.pinOut.isActive.value = isActive

    -- Detect transition to finished state
    if not self.wasFinished and isFinished then
      self.pinOut.finished.value = true
      -- Check if delivery failed
      local failed = gameplay_freeformDelivery_freeformDelivery.isFailed()
      self.pinOut.failed.value = failed
      if failed then
        local failReason = gameplay_freeformDelivery_freeformDelivery.getFailReason()
        self.pinOut.failReason.value = failReason or ''
      else
        self.pinOut.failReason.value = ''
      end
    else
      self.pinOut.finished.value = false
    end

    self.wasActive = isActive
    self.wasFinished = isFinished
  end
end

return _flowgraph_createNode(C)
