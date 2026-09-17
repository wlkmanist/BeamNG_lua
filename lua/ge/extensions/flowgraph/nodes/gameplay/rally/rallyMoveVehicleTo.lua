-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}
local logTag = 'rallyMoveVehicleTo'

C.name = 'Rally Move Vehicle To'
C.description = 'Moves a vehicle so its front-bottom is at the specified position and rotation.'
C.color = RallyUtil.rallyLoop_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of vehicle to move.' },
  { dir = 'in', type = 'vec3', name = 'pos', description = 'Target position for vehicle front-bottom.' },
  { dir = 'in', type = 'quat', name = 'rot', description = 'Target rotation.' },
}

function C:work(args)
  -- Only execute if all required inputs are present
  if self.pinIn.vehId.value and self.pinIn.pos.value and self.pinIn.rot.value then
    local vehId = self.pinIn.vehId.value
    local veh = scenetree.findObjectById(vehId)
    if not veh then
      log('W', logTag, 'Vehicle not found: ' .. tostring(self.pinIn.vehId.value))
      return
    end

    -- make copies so we dont clobber memory
    local targetPos = vec3(self.pinIn.pos.value)
    local targetRot = quat(self.pinIn.rot.value)

    -- Get vehicle OOBB points to calculate local offset (like calculateVehiclePosRot)
    local fl  = vec3(veh:getSpawnWorldOOBB():getPoint(0))
    local fr  = vec3(veh:getSpawnWorldOOBB():getPoint(3))
    local bl  = vec3(veh:getSpawnWorldOOBB():getPoint(4))
    local flU = vec3(veh:getSpawnWorldOOBB():getPoint(1))

    -- Calculate vehicle's current local axes
    local xVeh = (fr - fl):normalized()
    local yVeh = (fl - bl):normalized()
    local zVeh = (flU - fl):normalized()

    -- Calculate front-bottom center (average of fl and fr)
    local frontBottom = (fl + fr) * 0.5

    -- Get vehicle position and calculate local offset from front-bottom to refnode
    local pos = veh:getPosition()
    local posOffset = pos - frontBottom
    local localOffset = vec3(xVeh:dot(posOffset), yVeh:dot(posOffset), zVeh:dot(posOffset))

    -- Calculate new coordinate axes from target rotation
    local xLine = targetRot * vec3(1, 0, 0)
    local yLine = targetRot * vec3(0, 1, 0)
    local zLine = targetRot * vec3(0, 0, 1)

    -- Transform local offset to new orientation and calculate new vehicle position
    local newOffset = xLine * localOffset.x + yLine * localOffset.y + zLine * localOffset.z
    local newPos = targetPos - newOffset

    -- Set the final position and rotation
    local newZ = targetPos.z + 0.25
    veh:setPositionRotation(newPos.x, newPos.y, newZ, targetRot.x, targetRot.y, targetRot.z, targetRot.w)
  end
end

return _flowgraph_createNode(C)

