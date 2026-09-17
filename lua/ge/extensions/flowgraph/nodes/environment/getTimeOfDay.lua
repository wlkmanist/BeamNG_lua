-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Get Time of Day'
C.icon = "simobject_timeofday"
C.description = "Returns the current Time of Day settings."
C.category = 'provider'

C.pinSchema = {
    { dir = 'out', type = 'number', name = 'time', description = "Time of day on a scale from 0 to 1. 0/1 is midnight, 0.5 is midday." },
    { dir = 'out', type = 'number', name = 'dayLength', description = "Length of a full day-night cycle in real world seconds." }
}

C.tags = {'environment', 'tod'}

function C:work()
  local tod = core_environment.getTimeOfDay()
  self.pinOut.time.value = tod.time
  self.pinOut.dayLength.value = tod.dayLength
end

return _flowgraph_createNode(C)
