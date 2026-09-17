-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}

C.name = 'Rally Position Getter'
C.description = 'Gets positions from the current rally loop manager.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'table', name = 'pathData', tableType = 'pathData', description = 'Data from the path for other nodes to process.'},
  { dir = 'in', type = 'string', name = 'name', description = 'Name of the position to get; no value will use default.'},

  { dir = 'out', type = 'vec3', name = 'pos', description = 'The position.'},
  { dir = 'out', type = 'quat', name = 'rot', description = 'The rotation.'},
}

function C:_executionStarted()
  self.pinOut.flow.value = false
end

function C:work()
  if self.pinIn.pathData.value and self.pinIn.name.value then
    local sp = self.pinIn.pathData.value:findStartPositionByName(self.pinIn.name.value)
    if sp then
      -- dump(sp)
      self.pinOut.pos.value = sp.pos
      self.pinOut.rot.value = sp.rot
      self.pinOut.flow.value = true
    end
  end
end

return _flowgraph_createNode(C)
