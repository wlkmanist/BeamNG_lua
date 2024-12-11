local im  = ui_imgui
local C = {}

C.name = 'Clear drift'

C.description = "Clear the stunt zones, the scores and other systems"
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = ''

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'clearDrift', description = "Clears the drift system"},
}

C.tags = {'gameplay', 'utils'}

local callbacks
function C:work()
  if self.pinIn.flow.value then
    gameplay_drift_general.clear()
  end
end

return _flowgraph_createNode(C)