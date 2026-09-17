-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Get Drag Racer Data'

C.description = '[LEGACY] Convenience node combining status and spawn data. Consider using "Get Drag Racer Status" and "Get Drag Racer Spawn Point" separately for better organization.'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = "ID of the vehicle"},
  { dir = 'out', type = 'bool', name = 'isPlayable', description = ""},
  { dir = 'out', type = 'number', name = 'lane', description = ""},
  { dir = 'out', type = 'bool', name = 'isDesqualified', description = ""},
  { dir = 'out', type = 'string', name = 'desqualifiedReason', description = ""},
  { dir = 'out', type = 'bool', name = 'isFinished', description = ""},
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
    return
  end

  -- Clear waiting flags and errors if data is available
  self._racerWaiting = false
  self:__setNodeError(nil, nil)

  if self.pinOut.isPlayable:isUsed() then
    self.pinOut.isPlayable.value = self.data.isPlayable
  end
  if self.pinOut.lane:isUsed() then
    self.pinOut.lane.value = self.data.lane
  end
  if self.pinOut.isDesqualified:isUsed() then
    self.pinOut.isDesqualified.value = self.data.isDesqualified
  end
  if self.pinOut.desqualifiedReason:isUsed() then
    self.pinOut.desqualifiedReason.value = self.data.desqualifiedReason
  end
  if self.pinOut.isFinished:isUsed() then
    self.pinOut.isFinished.value = self.data.isFinished
  end
end

return _flowgraph_createNode(C)