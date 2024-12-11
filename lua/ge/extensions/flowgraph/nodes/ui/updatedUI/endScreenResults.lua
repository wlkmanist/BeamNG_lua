-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local ffi = require('ffi')

local C = {}

C.name = 'End Screen Results'
C.color = ui_flowgraph_editor.nodeColors.ui
C.icon = ui_flowgraph_editor.nodeIcons.ui
C.description = "Shows the end screen of a scenario with customizable buttons."
C.category = 'repeat_instant'
C.todo = "Showing two of these at the same time will break everything."
C.behaviour = {singleActive = true}

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'out', type = 'flow', name = 'flow', description = '', chainFlow = true },
  { dir = 'in', type = {'string','table'},  name = 'text', description = 'Subtext of the menu.' },
  { dir = 'in', type = 'table', name = 'change', description = 'Change from the attempt. use aggregate attempt node (test only)'},
  { dir = 'in', type = 'bool', name = 'includeObjectives', description = 'if true, adds Objectives after the panel ',  },
  { dir = 'in', type = 'bool', name = 'includeRatings', description = 'if true, adds ratings after the panel',  },
}

function C:init()
end

function C:work()
  self.pinOut.flow.value = self.pinIn.flow.value
  if self.pinIn.text.value then
    self.mgr.modules.ui:addUIElement({type = 'textPanel', header = "Results", text = self.pinIn.text.value, attempt = self.pinIn.change.value.formattedAttempt})
  end
  if self.pinIn.includeObjectives.value then
    self.mgr.modules.ui:addObjectives(self.pinIn.change.value)
  end
  if self.pinIn.includeRatings.value then
    self.mgr.modules.ui:addRatings(self.pinIn.change.value)
  end
end

return _flowgraph_createNode(C)
