-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = 'rally-mode-flowgraph'

C.name = 'Rally Mode Resync After Teleport'
C.description = 'Clears pacenote runtime and resyncs rally state after a teleport or reset.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

function C:work()
  log('D', logTag, 'FG resync after teleport')
  local rm = gameplay_rally.getRallyManager()
  if rm then
    log('D', logTag, 'FG resync after teleport doing teleport resync')
    rm:resyncAfterTeleport()
  else
    log('E', logTag, 'FG resync after teleport failed, rallyManager not found')
  end

  self.pinOut.flow.value = self.pinIn.flow.value
end

return _flowgraph_createNode(C)
