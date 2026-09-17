-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui


local C = {}

C.name = 'Get Photomode'
C.description = 'Returns if photomode is active or not.'
C.color = ui_flowgraph_editor.nodeColors.ui
C.category = 'provider'
C.icon = 'photo_camera'
C.author = 'BeamNG'

C.pinSchema = {
  { dir = 'out', type = 'bool', name = 'value', description = 'If photomode is active or not.' },
}

C.tags = {'photomode', 'photo', 'camera', 'screenshot', 'capture'}

function C:work()
  self.pinOut.value.value = photoModeOpen
end


return _flowgraph_createNode(C)
