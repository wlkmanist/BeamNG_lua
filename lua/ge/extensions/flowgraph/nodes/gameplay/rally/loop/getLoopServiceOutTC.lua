-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = 'getLoopServiceOutTC'

C.name = 'Rally Loop Get Service Out TC'
C.description = 'Gets the service out TC position and rotation from the current rally loop manager.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'out', type = 'vec3', name = 'pos', description = 'Position of the service out TC.'},
  { dir = 'out', type = 'quat', name = 'rot', description = 'Rotation of the service out TC.'},
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
    log('E', logTag, 'no rally loop manager')
    return
  end
  self.pinOut.pos.value = rm:getServiceOutTCPos()
  self.pinOut.rot.value = rm:getServiceOutTCRot()
end

return _flowgraph_createNode(C)
