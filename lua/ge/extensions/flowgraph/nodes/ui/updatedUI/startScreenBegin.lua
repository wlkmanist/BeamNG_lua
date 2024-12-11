-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

local ffi = require('ffi')

local C = {}

C.name = 'StartScreen Begin'
C.color = ui_flowgraph_editor.nodeColors.ui
C.description = 'Begins building the start screen.'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = '' },
  { dir = 'in', type = 'flow', name = 'reset', description = '', impulse = true },
  { dir = 'out', type = 'flow', name = 'flow', description = ''},
  { dir = 'out', type = 'flow', name = 'build', description = '', chainFlow = true},
}

C.tags = { 'string' }

function C:_executionStarted()
  self.started = false
  self.built = false
end

function C:workOnce()
end

function C:work()
  if self.pinIn.reset.value then
    self.started = false
    self.built = false
  end
  if self.pinIn.flow.value then
    if not self.built then
      self.mgr.modules.ui:startUIBuilding('startScreen', self)
      self.mgr.modules.ui:addHeader({header = self.graph.mgr.name})
    end
    self.pinOut.build.value = not self.built
    self.built = true
    self.pinOut.flow.value = self.started
  else
    self.pinOut.flow.value = false
    self.pinOut.build.value = false
  end
end

function C:startFromUi()
  self.started = true
  guihooks.trigger('ChangeState', {state ='play'})
end

return _flowgraph_createNode(C)
