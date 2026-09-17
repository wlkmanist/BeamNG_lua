-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Quat'
C.description = "Provides a quaternion."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'x', description = 'The x value.' },
  { dir = 'in', type = 'number', name = 'y', description = 'The y value.' },
  { dir = 'in', type = 'number', name = 'z', description = 'The z value.' },
  { dir = 'in', type = 'number', name = 'w', description = 'The w value.' },
  { dir = 'out', type = 'quat', name = 'value', description = 'The quaternion value.' }
}

C.tags = {'quat', 'quaternion', 'rotation'}

local quatOut = quat()
function C:work()
    local rot = {self.pinIn.x.value or 0, self.pinIn.y.value or 0, self.pinIn.z.value or 0, self.pinIn.w.value or 0}
    quatOut:set(rot[1], rot[2], rot[3], rot[4])
    self.pinOut.value.value = {quatOut.x, quatOut.y, quatOut.z, quatOut.w}
end

function C:drawMiddle(builder, style)
  builder:Middle()
  im.Text(tostring(quat(self.pinIn.x.value or 0, self.pinIn.y.value or 0, self.pinIn.z.value or 0, self.pinIn.w.value or 0)))
end

function C:drawProperties()
end

function C:_onSerialize(res)
end

function C:_onDeserialized(nodeData)
end

return _flowgraph_createNode(C)
