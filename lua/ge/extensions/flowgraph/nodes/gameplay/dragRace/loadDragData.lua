-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Load Drag Race Data'

C.description = 'Load and initialize drag race data from a file. This should typically be called once at mission/race start.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'string', name = 'filepath', description = "File path of the dragData"},
  { dir = 'out', type = 'flow', name = 'flow', description = 'Flow output after loading', impulse = true },
  { dir = 'out', type = 'bool', name = 'success', description = 'True if data loaded successfully' },
}

C.tags = {'gameplay', 'utils'}

function C:workOnce()
  if not self.pinIn.filepath.value then
    self:__setNodeError('filepath', 'File path is required')
    self.pinOut.success.value = false
    self.pinOut.flow.value = true
    return
  end

  -- Bridge is loaded automatically via dependencies when general loads
  gameplay_drag_dragBridge.loadDragDataForMission(self.pinIn.filepath.value)

  -- Check if data was loaded successfully
  local dragData = gameplay_drag_dragBridge.getData()
  if dragData then
    self:__setNodeError(nil, nil)
    self.pinOut.success.value = true
  else
    self:__setNodeError('load', 'Failed to load drag data from: ' .. tostring(self.pinIn.filepath.value))
    self.pinOut.success.value = false
  end

  self.pinOut.flow.value = true
end

return _flowgraph_createNode(C)