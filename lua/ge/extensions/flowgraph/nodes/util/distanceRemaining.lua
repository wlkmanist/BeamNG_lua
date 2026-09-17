-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Waypoints Distance'

C.description = "Finds the remaining distance from waypoints along with if the player is going the right way."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = "in", hidden = true, type = "flow", name = "alwaysUpdate", description = ""},
  { dir = 'in', type = 'number', name = 'vehId', description = "The tracked vehicle." },
  { dir = 'in', type = 'table', name = 'waypoints', description = "Table of positions to use." },
  { dir = 'out', type = 'number', name = 'distLeft', description = "Distance to the road." },
  { dir = "out", type = "bool", name = "rightWay", description = "Whether the vehicle is going the wrong way."},
  { dir = "out", type = "flow", name = "goingRightWay", description = ""},
  { dir = "out", type = "flow", name = "goingWrongWay", description = ""},
}

C.color = ui_flowgraph_editor.nodeColors.default

local vehData
local vel
local threshold = 0.50
local index
local lastDistLeft = -1
local prevPos, nextPos, dirVec = vec3(), vec3(), vec3()

function C:work()
  if not self.pinIn.waypoints.value then return end

  vehData = map.objects[self.pinIn.vehId.value]
  if not vehData then return end

  local min = math.huge
  for i = 1, #self.pinIn.waypoints.value - 1 do
    local dist = vehData.pos:distanceToLineSegment(self.pinIn.waypoints.value[i], self.pinIn.waypoints.value[i + 1])
    if dist < min then
      min = dist
      prevPos:set(self.pinIn.waypoints.value[i])
      nextPos:set(self.pinIn.waypoints.value[i + 1])
      index = i
    end
  end

  local distLeft = 0

  local xnorm = vehData.pos:xnormOnLine(prevPos, nextPos)
  distLeft = distLeft + lerp(prevPos, nextPos, xnorm):distance(nextPos)
  if index < #self.pinIn.waypoints.value then
    for i = index, #self.pinIn.waypoints.value - 1 do
      distLeft = distLeft + self.pinIn.waypoints.value[i]:distance(self.pinIn.waypoints.value[i + 1])
    end
  end

  vel = vehData.vel:length()
  dirVec:setSub2(nextPos, prevPos)
  local goingTheRightDirection = vel <= threshold or (dirVec:dot(vehData.vel) > 0 and vel > threshold)

  self.pinOut.rightWay.value = goingTheRightDirection
  self.pinOut.goingRigthWay.value = goingTheRightDirection
  self.pinOut.goingWrongWay.value = not goingTheRightDirection
  self.pinOut.distLeft.value = ((self.pinIn.alwaysUpdate.value or lastDistLeft == -1) and distLeft) or vel > threshold and distLeft or lastDistLeft

  if ((self.pinIn.alwaysUpdate.value or lastDistLeft == -1) and distLeft) or vel > threshold then lastDistLeft = distLeft end
end

return _flowgraph_createNode(C)
