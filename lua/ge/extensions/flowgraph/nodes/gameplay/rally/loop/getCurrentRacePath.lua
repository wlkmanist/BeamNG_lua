-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Get Current Race Path'
C.description = 'Gets the race file path for the current mission in the rally loop schedule.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'out', type = 'string', name = 'racePath', description = 'Path to the race file for the current mission.'}
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
  if not rm then
    log('E', logTag, 'failed to get rally loop manager')
    self.pinOut.racePath.value = ''
    return
  end

  local racePath = rm:getCurrentRacePath()
  self.pinOut.racePath.value = racePath or ''

  if racePath then
    log('D', logTag, 'Current mission race path: ' .. racePath)
  end
end

return _flowgraph_createNode(C)

