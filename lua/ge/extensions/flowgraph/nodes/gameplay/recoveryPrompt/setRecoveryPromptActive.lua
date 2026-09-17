-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Set Recovery Prompt Active'
C.description = 'Activates or deactivates the recovery system for missions; use this with the "Set Recovery Prompt Enabled" node to make the buttons selectable.'
C.color = ui_flowgraph_editor.nodeColors.recoveryPrompt
C.icon = ui_flowgraph_editor.nodeIcons.recoveryPrompt
C.category = 'once_instant'

C.pinSchema = {
  {dir = 'in', type = 'bool', name = 'active', default = true, hardcoded = true, description = "If this system should be active or not."},
  {dir = 'in', type = 'bool', name = 'enableAll', default = true, hidden = true, hardcoded = true, description = "(Deprecated) Sets enabled state for all buttons."},
  {dir = 'in', type = 'bool', name = 'flipMission', default = true, hardcoded = true, description = 'Allows the "Flip Upright" action; has no screen fade.'},
  {dir = 'in', type = 'bool', name = 'recoverMission', default = true, hardcoded = true, description = 'Allows the "Recover" action; has a screen fade.'},
  {dir = 'in', type = 'bool', name = 'submitMission', default = false, hardcoded = true, description = 'Allows the "Submit Score" action; has no screen fade.'},
  {dir = 'in', type = 'bool', name = 'restartMission', default = false, hardcoded = true, description = 'Allows the "Restart Mission" action; has no screen fade.'}
}
C.dependencies = {'gameplay_walk'}
C.blocksOnResetGameplay = true

local actions = {'flipMission', 'recoverMission', 'submitMission', 'restartMission'}
function C:workOnce(args)
  if self.pinIn.active.value then
    core_recoveryPrompt.setActive(true)
    core_recoveryPrompt.deactivateAllButtons()
    for _, o in ipairs(actions) do
      if self.pinIn[o].value ~= nil then
        core_recoveryPrompt.setButtonActiveById(o, self.pinIn[o].value)
        --if self.pinIn.enableAll.value ~= nil and  then
        --  core_recoveryPrompt.setButtonEnabledById(o, self.pinIn.enableAll.value and self.pinIn[o].value)
        --end
      end
    end
  else
    core_recoveryPrompt.setActive(false)
  end
end

function C:drawMiddle(builder, style)
  builder:Middle()
end

return _flowgraph_createNode(C)
