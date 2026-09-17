-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Mode Fire Rally Event'
C.description = 'Fire a Rally event.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'
C.pinSchema = {
  { dir = 'in', type = 'string', name = 'eventType', description = 'The type of event to fire.' },
  { dir = 'in', type = 'bool', name = 'show', description = 'Show the UI for the event.', default = true },
}

function C:workOnce()
  extensions.hook('on'..self.pinIn.eventType.value, {show = self.pinIn.show.value})
  guihooks.trigger(self.pinIn.eventType.value, {show = self.pinIn.show.value})

end

return _flowgraph_createNode(C)
