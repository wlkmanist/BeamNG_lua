-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}
local route
C.name = 'Route Position'

C.description = 'Gets a position along a route from the given distance.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.default

C.pinSchema = {
  { dir = 'in', type = 'table', tableType = 'navgraphPath', name = 'navgraphRoute', description = "Array of waypoints that forms a route." },
  { dir = 'in', type = 'number', name = 'distance', description = "Distance ahead on the route." },
  { dir = 'out', type = 'vec3', name = 'pos', description = "Target position from the distance ahead on the route." },
  { dir = 'out', type = 'vec3', name = 'dirVec', description = "Direction vector of the road segment on the route." },
  { dir = 'out', type = 'string', name = 'n1', description = "First node of the road segment." },
  { dir = 'out', type = 'string', name = 'n2', description = "Second node of the road segment." }
}

C.tags = {'route', 'navgraph', 'waypoints', 'distance', 'length'}

function C:init()
  self:onNodeReset()
end

function C:_executionStopped()
  self:onNodeReset()
end

function C:onNodeReset()
  route = require('/lua/ge/extensions/gameplay/route/route')()
end

function C:workOnce()
  route:setupPathMultiWaypoints(self.pinIn.navgraphRoute.value or {})
  if not route.path[2] then return end

  local road = route:stepAhead(self.pinIn.distance.value or 0)
  if road then
    local mapNodes = map.getMap().nodes
    self.pinOut.n1.value = road.n1
    self.pinOut.n2.value = road.n2
    self.pinOut.pos.value = road.pos:toTable()
    self.pinOut.dirVec.value = (mapNodes[road.n2].pos - mapNodes[road.n1].pos):normalized():toTable()
  end
end

return _flowgraph_createNode(C)
