-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}

C.name = 'Rally Route Data'
C.description = 'Gets route data from the rally driveline.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'out', type = 'vec3', name = 'nextRoutePointPos', description = 'Position of the next route point ahead of the vehicle.' },
}

function C:work()
  local rm = gameplay_rally.getRallyManager()
  if rm then
    self.pinOut.nextRoutePointPos.value = rm:getRecoveryDestinationPos()
  end
  self.pinOut.flow.value = self.pinIn.flow.value
end

return _flowgraph_createNode(C)
