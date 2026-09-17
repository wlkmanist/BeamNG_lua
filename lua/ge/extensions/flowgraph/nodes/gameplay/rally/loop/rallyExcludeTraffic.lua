-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = ''

C.name = 'Rally Exclude Traffic'
C.description = 'Applies or clears traffic exclusion zones for the rally loop.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'bool', name = 'enable', description = 'True to apply traffic exclusion, false to clear it.', default = true },
}

local function getRallyLoopManager()
  if not extensions.isExtensionLoaded(RallyUtil.extRallyLoop) then
    log('E', logTag, RallyUtil.extRallyLoop .. ' extension not loaded')
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

function C:workOnce()
  -- not ready yet
  local rm = getRallyLoopManager()
  if not rm then
    log('E', logTag, 'Failed to get rally loop manager')
    return
  end

  local enable = self.pinIn.enable.value
  if enable then
    rm:applyTrafficExclusion()
    log('I', logTag, 'Applied traffic exclusion zones for rally loop')
  else
    rm:clearTrafficExclusion()
    log('I', logTag, 'Cleared traffic exclusion zones for rally loop')
  end
end

return _flowgraph_createNode(C)

