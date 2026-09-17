-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}
C.name = 'Get Navgraph Route'

C.description = 'Finds a route between a start and finish position on the navgraph.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.default

C.pinSchema = {
  { dir = 'in', type = 'vec3', name = 'posA', description = "Start position." },
  { dir = 'in', type = 'vec3', name = 'posB', description = "Finish position." },
  { dir = 'in', type = 'bool', name = 'legalRoute', hidden = true, default = true, description = "True if the route should respect the legal directions." },
  { dir = 'out', type = 'table', tableType = 'navgraphPath', name = 'navgraphRoute', description = "Array of waypoints that forms a route." }
}

C.tags = {'route', 'navgraph', 'waypoints'}

local pos = vec3()

function C:workOnce()
  local tempNodes = {} -- first and last nodes
  local mapNodes = map.getMap().nodes
  for _, v in ipairs({'posA', 'posB'}) do
    pos:setFromTable(self.pinIn[v].value)
    local n1, n2 = map.findClosestRoad(pos)
    if n1 then
      tempNodes[v] = pos:squaredDistance(mapNodes[n1].pos) < pos:squaredDistance(mapNodes[n2].pos) and n1 or n2
    else
      return
    end
  end

  local legalRoute = self.pinIn.legalRoute.value
  if legalRoute == nil then legalRoute = true end
  local route = map.getPath(tempNodes.posA, tempNodes.posB, nil, legalRoute and 1000 or 1)
  self.pinOut.navgraphRoute.value = route
end

return _flowgraph_createNode(C)
