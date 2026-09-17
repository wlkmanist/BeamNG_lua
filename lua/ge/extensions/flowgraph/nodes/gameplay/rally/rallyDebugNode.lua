-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = 'rallyDebugNode'

C.name = 'Rally Debug Draw'
C.description = 'Draws debug information for debugging purposes.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of vehicle to draw bounding box for.' },
  { dir = 'in', type = 'vec3', name = 'pos', description = 'Target position for vehicle front-center.' },
  { dir = 'in', type = 'quat', name = 'rot', description = 'Target rotation.' }
}

function C:work(args)
  -- dump("yo")
  if self.pinIn.vehId.value then
    RallyUtil.drawVehBB(self.pinIn.vehId.value)

    local vehicle = scenetree.findObjectById(self.pinIn.vehId.value)

    debugDrawer:drawSphere(RallyUtil.getVehFrontBottom(self.pinIn.vehId.value), 0.1, ColorF(1.0, 0.2, 1.0, 0.5), false, false)
    debugDrawer:drawSphere(vehicle:getPosition(), 0.1, ColorF(1.0, 1.0, 0.2, 0.5), false, false)

    local pinPos = vec3(self.pinIn.pos.value)
    -- dump(pinPos)
    debugDrawer:drawSphere(pinPos, 0.1, ColorF(0.2, 1.0, 0.2, 0.5), false, false)
  end
end

return _flowgraph_createNode(C)

