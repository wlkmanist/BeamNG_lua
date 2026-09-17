-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Get Traffic Enabled'
C.description = 'Gets whether traffic is enabled for the current rally loop.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally', 'traffic'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'out', type = 'bool', name = 'trafficEnabled', description = 'True when rally loop traffic should be enabled.'}
}

local function getRallyLoopManager()
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('E', logTag, RallyUtil.extRallyLoop .. ' extension not loaded')
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

local function isDevTrafficDisabled(mission)
  return mission
    and mission.devMission == true
    and mission.missionTypeData
    and mission.missionTypeData.devDisableTraffic == true
end

function C:workOnce()
  local rm = getRallyLoopManager()
  if not rm or not rm.getTrafficEnabled then
    -- Setup can query traffic before loopInit has created the loop manager.
    -- Read the mission flag directly so the flowgraph still bypasses spawning.
    self.pinOut.trafficEnabled.value = not isDevTrafficDisabled(self.mgr.activity)
    return
  end

  self.pinOut.trafficEnabled.value = rm:getTrafficEnabled()
end

return _flowgraph_createNode(C)
