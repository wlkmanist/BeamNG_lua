-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local re_util = require('/lua/ge/extensions/editor/rallyEditor/util')

local C = {}

C.name = 'AI Pacenotes Wait for Empty Audio Queue'
-- C.icon = "timer"
C.description = 'Waits for audio queue to be empty'
C.color = re_util.aip_fg_color

C.pinSchema = {
  -- { dir = 'in', type = 'flow', name = 'activate', description = 'Inflow for this node.', impulse = true },
  { dir = 'in', type = 'flow', name = 'reset', description = 'Resets this node.', impulse = true },
  -- { dir = 'in', type = 'flow', name = 'reset', description = 'Reset the countdown.', impulse = true },
  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.' },
  { dir = 'out', type = 'flow', name = 'empty', description = 'flows when empty' },
}
C.tags = {'aipacenotes'}
C.category = 'repeat_instant'

function C:reset()
  self.pinIn.reset.value = false
  self.pinOut.flow.value = false
  self.pinOut.empty.value = false
  self.found_empty = false
end

function C:work(args)
  if self.pinIn.reset.value then
    self:reset()
    return
  end

  if not self.found_empty then
    local qs = gameplay_aipacenotes.getRallyManager().audioManager:getQueueInfo()
    if qs.queueSize == 0 and qs.paused then
      self.found_empty = true
      self.pinOut.empty.value = true
    end
  end

  self.pinOut.flow.value = true
end

return _flowgraph_createNode(C)
