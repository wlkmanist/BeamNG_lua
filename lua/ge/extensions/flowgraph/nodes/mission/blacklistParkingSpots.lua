-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Blacklist Parking Spots'
C.description = "Filters out parking spots so that parked cars cannot use them. Uses data from the main parking system."
C.color = im.ImVec4(0.13, 0.3, 0.64, 0.75)
C.category = 'once_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'radius', description = 'Radius around the positions to query for and filter parking spots.' },
  { dir = 'in', type = 'bool', name = 'auto', description = 'If true, automatically uses and checks positions of existing mission vehicles.' },
  { dir = 'in', type = 'table', tableType = 'positions', name = 'posList', hidden = true, description = '(Optional) List of positions to check.' }
}

C.tags = {'mission', 'parking'}

local tempPos = vec3()

function C:init()
  self.count = 1
  self.bannedSpots = {}
end

function C:postInit()
  self:updatePins(0, self.count)
end

function C:_executionStopped()
  self:reset()
end

function C:onNodeReset()
  self:reset()
end

function C:reset()
  if not gameplay_parking then return end

  local parkingSpots = gameplay_parking.getParkingSpots()
  if not parkingSpots then return end

  for _, psId in ipairs(self.bannedSpots) do
    local ps = parkingSpots.objects[psId]
    if ps then
      ps.customFields:removeTag('banned')
    end
  end
  table.clear(self.bannedSpots)
end

function C:drawCustomProperties()
  local reason = nil
  im.PushID1("LAYOUT_COLUMNS")
  im.Columns(2, "layoutColumns")
  im.Text("Count")
  im.NextColumn()
  local ptr = im.IntPtr(self.count)
  if im.InputInt('##count'..self.id, ptr) then
    if ptr[0] < 1 then ptr[0] = 1 end
    self:updatePins(self.count, ptr[0])
    reason = "Changed Pin count to " .. ptr[0]
  end
  im.Columns(1)
  im.PopID()
  return reason
end

function C:updatePins(old, new)
  if new < old then
    for i = old, new + 1, -1 do
      for _, lnk in pairs(self.graph.links) do
        if lnk.sourcePin == self.pinInLocal['pos_'..i] then
          self.graph:deleteLink(lnk)
        end
      end
      self:removePin(self.pinInLocal['pos_'..i])
    end
  else
    for i = old + 1, new do
      if not self.pinInLocal['pos_'..i] then
        --direction, type, name, default, description, autoNumber
        self:createPin('in', 'vec3', 'pos_'..i, nil, 'Position ' .. i .. ' to check.')
      end
    end
  end
  self.count = new
end

function C:workOnce()
  if not gameplay_parking then return end

  local parkingSpots = gameplay_parking.getParkingSpots()
  if not parkingSpots then return end

  local radius = self.pinIn.radius.value or 5
  local posList = self.pinIn.posList.value or {}

  -- insert positions from auto mode
  if self.pinIn.auto.value then
    for _, veh in ipairs(getAllVehicles()) do
      if veh:getActive() and not veh.isTraffic and not veh.isParked and map.objects[veh:getId()] then
        tempPos:set(be:getObjectOOBBCenterXYZ(veh:getId()))
        table.insert(posList, tempPos:toTable())
      end
    end
  end

  -- insert positions from manual pins
  for i = 1, self.count do
    if self.pinIn['pos_'..i].value then
      table.insert(posList, self.pinIn['pos_'..i].value)
    end
  end

  -- tag parking spots for blacklist
  for _, pos in ipairs(posList) do
    if pos.x then
      tempPos:set(pos)
    else
      tempPos:setFromTable(pos)
    end

    local psList = gameplay_parking.findParkingSpots(tempPos, 0, radius)
    for _, psData in ipairs(psList) do
      psData.ps.customFields:addTag('banned')
      table.insert(self.bannedSpots, psData.ps.id)
    end
  end

  -- teleport any parking vehicles occupying blacklisted spots
  for _, psId in ipairs(self.bannedSpots) do
    local ps = parkingSpots.objects[psId]
    if ps and ps.vehicle then
      gameplay_parking.forceTeleport(ps.vehicle)
    end
  end
end

function C:_onSerialize(res)
  res.count = self.count
end

function C:_onDeserialized(res)
  self.count = res.count or 1
  self:updatePins(0, self.count)
end

return _flowgraph_createNode(C)
