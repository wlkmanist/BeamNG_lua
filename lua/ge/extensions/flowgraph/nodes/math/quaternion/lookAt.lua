-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui


local C = {}

C.name = 'Look At'
C.description = 'Gives the quaternion that describes rotation looking into a certain direction.'
C.category = 'simple'

C.pinSchema = {
  { dir = 'in', type = 'vec3', name = 'from', description = 'The origin of the look-vector.' },
  { dir = 'in', type = 'vec3', name = 'to', description = 'The target of the look-vector.' },
  { dir = 'in', type = 'vec3', name = 'up', default = { 0, 0, 1 }, hidden = true, hardcoded = true, description = 'Up-Vector, default is (0,0,1).' },
  { dir = 'out', type = 'quat', name = 'value', description = 'The rotation as a quaternion.' },
}

C.tags = {'quat', 'quaternion', 'rotation'}

local dirVec, dirVecUp = vec3(), vec3()
local rot = quat()

function C:init()
end

function C:work()
  if not self.pinIn.from.value or not self.pinIn.to.value then return end

  dirVecUp:setFromTable(self.pinIn.from.value)
  dirVec:setFromTable(self.pinIn.to.value)
  dirVec:setSub(dirVecUp)

  if self.pinIn.up.value then
    dirVecUp:setFromTable(self.pinIn.up.value)
  else
    dirVecUp:set(0, 0, 1)
  end

  rot:setFromDir(dirVec, dirVecUp)
  self.pinOut.value.value = rot:toTable()
end

return _flowgraph_createNode(C)
