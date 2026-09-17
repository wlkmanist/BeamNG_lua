-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Loop Chained Mission Setup'
C.description = 'Setup the next mission in the Rally Loop after transferring the mission execution.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  -- { dir = 'in', type = 'number', name = 'vehId', description = 'Vehicle id.'},
}

-- gets called when the project of this node stops execution.
function C:_executionStopped()
  log('D', logTag, 'loopChainedMissionSetup _executionStopped')
  if extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    if not gameplay_rallyLoop.getMissionExecutionTransferFlag() then
      -- unload the extension if the mission execution transfer flag is not set,
      -- meaning the mission was abandoned or otherwise stopped as a result of something other than a transfer.
      log('D', logTag, 'loopChainedMissionSetup _executionStopped: unloading rally loop extension')
      extensions.unload(RallyUtil.extRallyLoop)
    end
  end
end

function C:workOnce()
  -- clear the mission execution transfer flag at the start of the next chained mission
  -- so if the mission is abandoned, the _executionStopped() hook will be called.
  if gameplay_rallyLoop then
    gameplay_rallyLoop.setMissionExecutionTransferFlag(false)
    gameplay_rallyLoop.setupForNewMission()
  end
end

return _flowgraph_createNode(C)
