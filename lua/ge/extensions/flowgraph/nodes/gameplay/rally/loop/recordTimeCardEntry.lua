-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Loop Record Time Card Entry'
C.description = 'Records a time card entry for the current rally loop manager.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'string', name = 'name', description = 'Name of the time card entry to record.'},
  { dir = 'in', type = 'number', name = 'time', description = 'Time to record.'},
}

local function getRallyLoopManager()
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('E', logTag, RallyUtil.extRallyLoop .. ' extension not loaded')
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

function C:workOnce()
  local rm = getRallyLoopManager()
  if rm then
    rm:recordTimeCardEntry(self.pinIn.name.value, self.pinIn.time.value)
  else
    log('E', logTag, 'failed to get rally loop manager')
  end
end

return _flowgraph_createNode(C)
