-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Advance Loop Schedule'
C.description = 'Advances the rally loop manager to the next mission in the schedule.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {}

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
    local nextMissionId = rm:getNextMissionId()
    if nextMissionId then
      log('D', logTag, 'Advanced to next mission: ' .. nextMissionId)
    else
      log('W', logTag, 'No next mission to advance to')
    end
  else
    log('E', logTag, 'failed to get rally loop manager')
  end
end

return _flowgraph_createNode(C)

