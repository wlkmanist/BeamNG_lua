-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Display Value'
C.type = 'simple'
C.description = "Displays a value."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'any', name = 'value', description = 'The value to be displayed; if it is a table, you can dump it to the console by clicking the button.' }
}

C.tags = {'util'}
function C:work()
  self._lastVal = self.pinIn.value.value
end

function C:drawMiddle(builder, style)
  builder:Middle()
  im.TextUnformatted(dumpsz(self._lastVal, 2))

  if type(self._lastVal) == 'table' then
    if im.Button("Dump##"..self.id) then
      dump(self._lastVal)
    end
  end
end

return _flowgraph_createNode(C)
