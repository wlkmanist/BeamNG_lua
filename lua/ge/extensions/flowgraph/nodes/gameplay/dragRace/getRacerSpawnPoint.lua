-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Get Drag Racer Spawn Point'

C.description = 'Get spawn position and rotation for a racer\'s lane. Typically used once when setting up vehicles.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = "ID of the vehicle to get spawn point for"},
  { dir = 'out', type = 'vec3', name = 'spawnPos', description = "Spawn position for this racer's lane"},
  { dir = 'out', type = 'quat', name = 'spawnRot', description = "Spawn rotation for this racer's lane"},
  { dir = 'out', type = 'number', name = 'lane', description = "Lane number (from racer data)"},
  { dir = 'out', type = 'bool', name = 'available', description = "True if spawn data is available"},
}

C.tags = {'gameplay', 'utils'}

function C:_executionStarted()
  self.data = {}
  self.dragData = {}
end

function C:work()
  local vehId = self.pinIn.vehId.value

  -- Check if vehicle ID is provided
  if not vehId or vehId == 0 then
    self.pinOut.available.value = false
    return
  end

  self.dragData = gameplay_drag_dragBridge.getData() or {}
  self.data = self.dragData and gameplay_drag_dragBridge.getRacerData(vehId) or {}

  -- Check if we have all required data
  if not self.dragData or not next(self.dragData) or
     not self.data or not next(self.data) or
     not self.data.lane or
     not self.dragData.strip or
     not self.dragData.strip.lanes or
     not self.dragData.strip.lanes[self.data.lane] or
     not self.dragData.strip.lanes[self.data.lane].waypoints or
     not self.dragData.strip.lanes[self.data.lane].waypoints.spawn then
    self.pinOut.available.value = false
    return
  end

  -- Output spawn point data
  local lane = self.data.lane
  local spawnWaypoint = self.dragData.strip.lanes[lane].waypoints.spawn

  if self.pinOut.spawnPos:isUsed() then
    self.pinOut.spawnPos.value = spawnWaypoint.transform.pos:toTable()
  end

  if self.pinOut.spawnRot:isUsed() then
    self.pinOut.spawnRot.value = spawnWaypoint.transform.rot:toTable()
  end

  if self.pinOut.lane:isUsed() then
    self.pinOut.lane.value = lane
  end

  self.pinOut.available.value = true
  self:__setNodeError(nil, nil)
end

return _flowgraph_createNode(C)

