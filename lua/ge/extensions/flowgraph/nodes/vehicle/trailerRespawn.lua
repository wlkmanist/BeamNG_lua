-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Trailer Respawn Control'
C.description = [[Controls the trailer respawn system.
When enabled, trailers will automatically respawn with their attached vehicles.
When disabled, trailers will not respawn automatically.]]
C.category = 'once_instant'
C.icon = "fg_box_utility_trailer"

C.pinSchema = {
  {dir = 'in', type = 'bool', name = 'enabled', default = false, hardcoded = true, description = "Enable or disable trailer respawn system."},
}

C.dependencies = {"core_trailerRespawn"}
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.tags = {'trailer', 'respawn', 'vehicle'}

function C:init()
  self.enabled = true
end

function C:work()
  if self.pinIn.flow.value and core_trailerRespawn then
    core_trailerRespawn.setEnabled(self.pinIn.enabled.value)
  end
  self.pinOut.flow.value = self.pinIn.flow.value
end

return _flowgraph_createNode(C)
