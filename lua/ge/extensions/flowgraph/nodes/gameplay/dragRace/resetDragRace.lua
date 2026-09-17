-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Reset Drag Race'

C.description = 'Reset the drag race with optional clearing of racers. Use for retries with new opponents.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'bool', name = 'clearRacers', description = 'Also clear all racers from the system', default = false },
  { dir = 'out', type = 'flow', name = 'flow', description = 'Flow output after reset', impulse = true },
  { dir = 'out', type = 'bool', name = 'success', description = 'True if reset was successful' },
}

C.tags = {'gameplay', 'utils'}

function C:workOnce()
  local dragData = gameplay_drag_dragBridge.getData()
  local resetSuccess = false
  if dragData then
    resetSuccess = gameplay_drag_dragBridge.reset()
  end

  if self.pinIn.clearRacers.value then
    gameplay_drag_dragBridge.clearRacers()
  end

  self.pinOut.success.value = resetSuccess
  self.pinOut.flow.value = true
  self:__setNodeError(nil, nil)
end

return _flowgraph_createNode(C)

