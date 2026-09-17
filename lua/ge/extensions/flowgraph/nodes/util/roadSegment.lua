-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Road Properties'

C.description = 'Outputs properties of a road segment, defined by two nodes.'
C.category = 'repeat_instant'
C.color = ui_flowgraph_editor.nodeColors.default

C.pinSchema = {
  { dir = 'in', type = 'string', name = 'n1', description = "First node of the road segment." },
  { dir = 'in', type = 'string', name = 'n2', description = "Second node of the road segment." },
  { dir = 'in', type = 'number', name = 'xnorm', hidden = true, default = 0.5, description = "(Optional) Normalized distance along the road segment (from 0 to 1)." },
  { dir = 'out', type = 'vec3', name = 'roadDir', description = "Road direction vector (respects one-way direction if needed)." },
  { dir = 'out', type = 'number', name = 'length', description = "Road segment length." },
  { dir = 'out', type = 'number', name = 'width', description = "Road width (from xnorm value)." },
  { dir = 'out', type = 'number', name = 'drivability', description = "Road drivability value (from 0 to 1)." },
  { dir = 'out', type = 'number', name = 'speedLimit', description = "Road speed limit, in m/s." },
  { dir = 'out', type = 'number', name = 'lanesIncoming', description = "Incoming lanes count." },
  { dir = 'out', type = 'number', name = 'lanesOutgoing', description = "Outgoing lanes count." },
  { dir = 'out', type = 'number', name = 'lanesTotal', description = "Total lanes count." },
  { dir = 'out', type = 'bool', name = 'isOneWay', hidden = true, description = "True if the road is one-way only." },
  { dir = 'out', type = 'bool', name = 'isPrivate', hidden = true, description = "True if the road is private (gated road)." }
}

C.tags = {'road', 'map', 'navgraph', 'lanes'}

local dirVec = vec3()

function C:init()
  self._n1, self._n2 = nil, nil
end

function C:_executionStarted()
  self._n1, self._n2 = nil, nil
end

function C:work()
  if not self.pinIn.n1.value or not self.pinIn.n2.value then return end
  local mapNodes = map.getMap().nodes
  local n1, n2 = self.pinIn.n1.value, self.pinIn.n2.value
  if not mapNodes[n1] or not mapNodes[n2] then return end

  local a, b = mapNodes[n1], mapNodes[n2]
  if self._n1 ~= n1 or self._n2 ~= n2 then
    self._n1, self._n2 = n1, n2
    local link = a.links[n2] or b.links[n1]
    if link then
      dirVec:setSub2(b.pos, a.pos)
      self.pinOut.length.value = dirVec:length()
      self.pinOut.drivability.value = link.drivability
      self.pinOut.speedLimit.value = link.speedLimit
      self.pinOut.isOneWay.value = link.oneWay and true or false
      self.pinOut.isPrivate.value = link.type == 'private' and true or false

      local lanes = link.lanes or '-+'
      local _, iCount = string.gsub(lanes, '-', '')
      local _, oCount = string.gsub(lanes, '+', '')
      self.pinOut.lanesIncoming.value = iCount
      self.pinOut.lanesOutgoing.value = oCount
      self.pinOut.lanesTotal.value = iCount + oCount
    end

    if link.inNode == n2 then dirVec:setScaled(-1) end -- flips direction
    dirVec:normalize()
    self.pinOut.roadDir.value = dirVec:toTable()
  end
  self.pinOut.width.value = lerp(a.radius, b.radius, self.pinIn.xnorm.value or 0.5) * 2 -- updates at runtime due to xnorm
end

return _flowgraph_createNode(C)
