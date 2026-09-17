-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Get Drag Race Winner Data'

C.description = 'Get a list of the winners'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'out', type = 'bool', name = 'playerWin', description = ""},
  { dir = 'out', type = 'number', name = 'playerPos', description = ""},
}

C.tags = {'gameplay', 'utils'}


function C:_executionStarted()
  self.data = {}
  self.result = nil
end

function C:work()
  self.result = gameplay_drag_dragBridge.getPlayerRaceResult and gameplay_drag_dragBridge.getPlayerRaceResult() or nil
  self.data = self.result and self.result.winners or gameplay_drag_dragBridge.getWinnersData()

  if not self.data then
    local errorMsg = "Winners data not available. Drag race may not be completed or initialized."
    self:__setNodeError('winnersData', errorMsg)
    return
  end

  if not self.data[1] then
    local errorMsg = "No winners found in results. Race may not be completed yet."
    self:__setNodeError('winnersData', errorMsg)
    return
  end

  -- Clear error if data is available
  self:__setNodeError(nil, nil)
  if self.pinOut.playerWin:isUsed() then
    if self.result then
      self.pinOut.playerWin.value = self.result.playerWin or false
    else
      self.pinOut.playerWin.value = self.data[1].isPlayable
    end
  end
  if self.pinOut.playerPos:isUsed() then
    if self.result then
      self.pinOut.playerPos.value = self.result.playerPos
    else
      for k, v in ipairs(self.data) do
        if v.isPlayable then
          self.pinOut.playerPos.value = k
          break
        end
      end
    end
  end
end

return _flowgraph_createNode(C)