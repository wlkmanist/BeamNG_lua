-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Route After Road Section'
C.description = 'Routes flow to serviceIn or specialStage based on the next mission in the rally loop schedule.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'out', type = 'flow', name = 'toServiceIn', description = 'Flow out if next mission is serviceIn.'},
  { dir = 'out', type = 'flow', name = 'toSpecialStage', description = 'Flow out if next mission is a special stage.'}
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
    return
  end

  -- Get current mission (advanceLoopSchedule has already been called)
  local currentMissionId = rm:getCurrentMissionId()
  if not currentMissionId then
    log('W', logTag, 'No current mission in sequence')
    return
  end

  log('D', logTag, 'Current mission: ' .. tostring(currentMissionId))

  -- Check if current mission is serviceIn
  if currentMissionId == 'serviceIn' then
    log('D', logTag, 'Routing to serviceIn')
    self.pinOut.toServiceIn.value = true
  else
    -- Assume it's a special stage (could be another road section too, but that's handled elsewhere)
    log('D', logTag, 'Routing to special stage')
    self.pinOut.toSpecialStage.value = true
  end
end

return _flowgraph_createNode(C)

