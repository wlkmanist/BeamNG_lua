-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Get Drag Racer Status'

C.description = 'Get racer status information (lane, playable status, finish state, etc.) for a specific vehicle'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = "ID of the vehicle"},
  { dir = 'out', type = 'bool', name = 'isPlayable', description = "True if this is the playable racer"},
  { dir = 'out', type = 'number', name = 'lane', description = "Lane number assigned to this racer"},
  { dir = 'out', type = 'bool', name = 'isDesqualified', description = "True if racer is disqualified"},
  { dir = 'out', type = 'string', name = 'desqualifiedReason', description = "Reason for disqualification"},
  { dir = 'out', type = 'bool', name = 'isFinished', description = "True if racer has finished the race"},
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
    return
  end

  self.dragData = gameplay_drag_dragBridge.getData() or {}
  self.data = self.dragData and gameplay_drag_dragBridge.getRacerData(vehId) or {}

  -- Check if we have drag data
  -- During retry, data may be temporarily unavailable - don't spam errors
  if not self.dragData or not next(self.dragData) then
    if not self._dataWaiting then
      self._dataWaiting = true
    end
    -- Clear outputs when data is unavailable
    if self.pinOut.isPlayable:isUsed() then self.pinOut.isPlayable.value = false end
    if self.pinOut.lane:isUsed() then self.pinOut.lane.value = 0 end
    if self.pinOut.isDesqualified:isUsed() then self.pinOut.isDesqualified.value = false end
    if self.pinOut.desqualifiedReason:isUsed() then self.pinOut.desqualifiedReason.value = "" end
    if self.pinOut.isFinished:isUsed() then self.pinOut.isFinished.value = false end
    return
  end

  -- Clear waiting flag since we have data now
  self._dataWaiting = false

  -- Check if we have racer data for this vehicle
  -- During retry, racer data may be temporarily unavailable after clearing racers
  if not self.data or not next(self.data) then
    if not self._racerWaiting then
      self._racerWaiting = true
    end
    -- Set default values when racer data is unavailable
    if self.pinOut.isPlayable:isUsed() then self.pinOut.isPlayable.value = false end
    if self.pinOut.lane:isUsed() then self.pinOut.lane.value = 0 end
    if self.pinOut.isDesqualified:isUsed() then self.pinOut.isDesqualified.value = false end
    if self.pinOut.desqualifiedReason:isUsed() then self.pinOut.desqualifiedReason.value = "" end
    if self.pinOut.isFinished:isUsed() then self.pinOut.isFinished.value = false end
    return
  end

  -- Clear waiting flags and errors if data is available
  self._racerWaiting = false
  self:__setNodeError(nil, nil)

  -- Output racer status data
  if self.pinOut.isPlayable:isUsed() then
    self.pinOut.isPlayable.value = self.data.isPlayable or false
  end
  if self.pinOut.lane:isUsed() then
    self.pinOut.lane.value = self.data.lane or 0
  end
  if self.pinOut.isDesqualified:isUsed() then
    self.pinOut.isDesqualified.value = self.data.isDesqualified or false
  end
  if self.pinOut.desqualifiedReason:isUsed() then
    self.pinOut.desqualifiedReason.value = self.data.desqualifiedReason or ""
  end
  if self.pinOut.isFinished:isUsed() then
    self.pinOut.isFinished.value = self.data.isFinished or false
  end
end

return _flowgraph_createNode(C)

