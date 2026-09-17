-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local im  = ui_imgui

local C = {}

C.name = 'Rally Track Stage Time'
C.icon = "timer"
C.description = 'Tracks the stage time.'
C.color = rallyUtil.rally_flowgraph_color
C.category = 'repeat'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.' },
}
C.tags = {'rally'}

function C:init(mgr, ...)
end

-- function C:_executionStarted()
-- end


function C:work(args)
  local stageTime = os.clockhp()

  -- Send stage active state to Lua extensions
  local data = {
    activeState = rallyUtil.activeState_stageActive,
  }
  extensions.hook("onRallyDataUpdated", data)

  self.pinOut.flow.value = self.pinIn.flow.value
end

return _flowgraph_createNode(C)
