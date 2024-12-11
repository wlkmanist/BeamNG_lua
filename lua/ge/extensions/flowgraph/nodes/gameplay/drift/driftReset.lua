local im  = ui_imgui
local C = {}

C.name = 'Reset drift'

C.description = "Reset the scores and other systems"
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
}

C.tags = {'gameplay', 'utils'}

local callbacks
function C:work()
  gameplay_drift_general.reset()
  self.mgr.modules.drift:resetModule()
end

return _flowgraph_createNode(C)