-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Race End Transform'
C.description = 'Gives the End Positions Transform of a Path. Useful for creating custom triggers..'
C.category = 'repeat_instant'

C.color = im.ImVec4(1, 1, 0, 0.75)
C.pinSchema = {
  {dir = 'in', type = 'table', name = 'pathData', tableType = 'pathData', description = 'Data from the path for other nodes to process.'},
  {dir = 'out', type = 'bool', name = 'existing', description = 'True if the transform was found'},
  {dir = 'out', type = 'vec3', name = 'pos', description= 'The position of this transform.'},
  {dir = 'out', type = 'number', name = 'radius', description= 'The radius of this transform.'},
}

C.tags = {'scenario'}


function C:init(mgr, ...)
  self.path = nil
  self.clearOutPinsOnStart = false
end


function C:_executionStopped()
  self.path = nil
end

function C:work(args)
  if self.path == nil and self.pinIn.pathData.value then
    self.path = self.pinIn.pathData.value

    local endNode = nil
    for _, sortedNode in pairs(self.path.pathnodes.sorted) do
      if sortedNode.id == self.path.endNode then
        endNode = sortedNode
      end
    end

    self.pinOut.existing.value = false

    if endNode == nil then return end

    self.pinOut.existing.value = true

    self.pinOut.pos.value = endNode.pos:toTable()
    self.pinOut.radius.value = endNode.radius
  end
end

return _flowgraph_createNode(C)
