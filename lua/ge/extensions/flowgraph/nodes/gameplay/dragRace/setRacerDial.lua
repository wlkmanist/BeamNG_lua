-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}
local logTag = "setRacerDial"

C.name = 'Set Drag Racer Dial'

C.description = 'Set dial times for one or more racers. Input is a table with {racerId, value} entries.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'table', name = 'dials', description = 'Table of dials to set. Each entry: {racerId = number, value = number}' },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Flow output after setting dials', impulse = true },
  { dir = 'out', type = 'bool', name = 'success', description = 'True if all dials were set successfully' },
  { dir = 'out', type = 'number', name = 'count', description = 'Number of dials successfully set' },
}

C.tags = {'gameplay', 'utils'}

function C:workOnce()
  local dials = self.pinIn.dials.value or {}

  if not dials or type(dials) ~= 'table' or #dials == 0 then
    log('D', logTag, 'Dials table is required and must not be empty')
    self:__setNodeError(nil, nil)
    self.pinOut.success.value = false
    self.pinOut.count.value = 0
    self.pinOut.flow.value = true
    return
  end

  -- Use bridge to set dials (goes through core.lua for data storage)
  local dragData = gameplay_drag_dragBridge.getData()
  if not dragData then
    self:__setNodeError('state', 'Drag race data not available')
    self.pinOut.success.value = false
    self.pinOut.count.value = 0
    self.pinOut.flow.value = true
    return
  end

  -- Count expected successes/failures before calling bridge
  local expectedSuccessCount = 0
  local expectedFailedCount = 0
  for _, d in ipairs(dials) do
    if d and d.racerId and d.value then
      if dragData.racers and dragData.racers[d.racerId] then
        expectedSuccessCount = expectedSuccessCount + 1
      else
        expectedFailedCount = expectedFailedCount + 1
      end
    else
      expectedFailedCount = expectedFailedCount + 1
    end
  end

  -- Call bridge function to set dials (writes through core.lua)
  local result = gameplay_drag_dragBridge.setRacersDial(dials)

  -- No-op: avoid verbose logging for each dial

  self.pinOut.count.value = expectedSuccessCount
  self.pinOut.success.value = result and (expectedFailedCount == 0)

  if expectedFailedCount > 0 then
    self:__setNodeError('partial', string.format('Failed to set %d dial(s), succeeded: %d', expectedFailedCount, expectedSuccessCount))
  else
    self:__setNodeError(nil, nil)
  end

  self.pinOut.flow.value = true
end

return _flowgraph_createNode(C)


