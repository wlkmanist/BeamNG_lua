-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Loop Get Info'
C.description = 'Gets the info from the current rally loop manager.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'out', type = 'string', name = 'name', description = 'name of the rally'},
  { dir = 'out', type = {'string', 'table'}, name = 'startScreenText', description = 'start screen text', tableType = 'translationObject', fixed=true },
  { dir = 'out', type = {'string', 'table'}, name = 'endScreenText', description = 'end screen text', tableType = 'translationObject', fixed=true },
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
    local mission = rm:getRallyLoopMission()
    self.pinOut.name.value = rm:getRallyLoopName()
    self.pinOut.startScreenText.value = mission.missionTypeData.startScreenText or ""
    self.pinOut.endScreenText.value = mission.missionTypeData.endScreenText or ""
  else
    log('E', logTag, 'no rally loop manager')
  end
end

return _flowgraph_createNode(C)
