-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Set Recovery Prompt Enabled'
C.description = 'Enables or disables buttons in the recovery prompt. Disabled buttons are visible but not selectable.'
C.color = ui_flowgraph_editor.nodeColors.recoveryPrompt
C.icon = ui_flowgraph_editor.nodeIcons.recoveryPrompt
C.category = 'once_instant'

C.pinSchema = {
  {dir = 'in', type = 'bool', name = 'flipMission', default = true, description = 'Enables "Flip Upright" to be selected.'},
  {dir = 'in', type = 'bool', name = 'recoverMission', default = true, description = 'Enables "Recover" to be selected.'},
  {dir = 'in', type = 'bool', name = 'submitMission', default = false, description = 'Enables "Submit Score" to be selected.'},
  {dir = 'in', type = 'bool', name = 'restartMission', default = false, description = 'Enables "Restart Mission" to be selected.'}
}
C.dependencies = {'gameplay_walk'}

local actions = {'flipMission', 'recoverMission', 'submitMission', 'restartMission'}
function C:workOnce(args)
  for _, o in ipairs(actions) do
    if self.pinIn[o].value ~= nil then
      core_recoveryPrompt.setButtonEnabledById(o, self.pinIn[o].value)
    end
  end
end

function C:drawMiddle(builder, style)
  builder:Middle()
end

return _flowgraph_createNode(C)
