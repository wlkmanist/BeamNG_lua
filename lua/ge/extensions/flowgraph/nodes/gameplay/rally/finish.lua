-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}

C.name = 'Rally Mode Finish'
C.description = 'Fires when the vehicle crosses the rally flying finish.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
}

function C:workOnce()
  extensions.hook('onRallyStageFlyingFinish')
end

return _flowgraph_createNode(C)
