-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Get Delivery Results'
C.description = 'Gets the current results/statistics of the delivery as a table. Returns nil if no delivery is active.'
C.category = 'provider'
C.color = ui_flowgraph_editor.nodeColors.gameplay
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'table', name = 'results', tableType = 'generic', description = 'Table containing delivery results: time, timeStr, goalsTotal, goalsCompleted, goalsRequired, goalsRequiredCompleted, allRequiredComplete, vehicleDamages' },
  { dir = 'out', type = 'bool', name = 'isActive', default = false, description = 'True if delivery is currently active, false otherwise.' },
}

C.dependencies = {
  'gameplay_freeformDelivery_freeformDelivery'
}

C.tags = {'delivery', 'gameplay', 'mission'}

function C:init()
  self.pinOut.results.value = nil
  self.pinOut.isActive.value = false
end

function C:_executionStopped()
  self.pinOut.results.value = nil
  self.pinOut.isActive.value = false
end

function C:_executionStarted()
  self.pinOut.results.value = nil
  self.pinOut.isActive.value = false
end

function C:work()
  if not gameplay_freeformDelivery_freeformDelivery then
    self.pinOut.isActive.value = false
    self.pinOut.results.value = nil
    return
  end

  local isActive = gameplay_freeformDelivery_freeformDelivery.isActive()
  self.pinOut.isActive.value = isActive

  if isActive then
    -- Get results using the exposed API
    local results = gameplay_freeformDelivery_freeformDelivery.getResults()
    self.pinOut.results.value = results
  else
    self.pinOut.results.value = nil
  end
end

return _flowgraph_createNode(C)
