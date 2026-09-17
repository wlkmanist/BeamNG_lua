-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui
local C = {}

C.name = 'Get Drag Race Times'

C.description = 'get all the timers in real time for this vehId'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.vehicle
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'vehId', description = "ID of the vehicle"},
  { dir = 'out', type = 'number', name = 'timer', description = "Actual timer of the vehicle"},
}

C.tags = {'gameplay', 'utils'}

local timers = {
  reactionTime = {type = "reactionTimer", value = 0, distance = 0.1, isSet = false},
  dial = {type = "dialTimer", value = 0, distance = 0.1, isSet = true},
  time_60 = {type = "distanceTimer", value = 0, distance = 18.288, isSet = false},
  time_330 = {type = "distanceTimer", value = 0, distance = 100.584, isSet = false},
  time_1_8 = {type = "distanceTimer", value = 0, distance = 201.168, isSet = false},
  time_1000 = {type = "distanceTimer", value = 0, distance = 304.8, isSet = false},
  time_1_4 = {type = "distanceTimer", value = 0, distance = 402.336, isSet = false},
  velAt_1_8 = {type = "velocity", value = 0, distance = 201.168, isSet = false},
  velAt_1_4 = {type = "velocity", value = 0, distance = 402.336, isSet = false}
}

function C:postInit()
  self.timerData = timers
  for timerId, data in pairs(self.timerData) do
    self:createPin("out", "flow", 'flow_' .. timerId).impulse = true
    self:createPin("out", "number", timerId)
  end
end

function C:_executionStarted()
end

function C:updateInfos()
  local vehId = self.pinIn.vehId.value

  -- Check if vehicle ID is provided
  if not vehId or vehId == 0 then
    local errorMsg = "Vehicle ID not provided or invalid"
    self:__setNodeError('input', errorMsg)
    self.timerData = timers
    return
  end

  local timerData = gameplay_drag_dragBridge.getTimers(vehId)

  if not timerData then
    local errorMsg = string.format("Timer data not found for vehicle ID: %s. Vehicle may not be part of the drag race.", tostring(vehId))
    self:__setNodeError('timers', errorMsg)
    self.timerData = timers
    return
  end

  -- Clear error if data is available
  self:__setNodeError(nil, nil)
  self.timerData = timerData
end

function C:work()
  self:updateInfos()

  if not self.timerData then
    self.timerData = timers
  end

  for timerId, data in pairs(self.timerData) do
    if data.type ~= "timer" and data.isSet then
      if self.pinOut["flow_" .. timerId] then
        self.pinOut["flow_" .. timerId].value = data.isSet
        self.pinOut[timerId].value = data.value
      end
    end
  end
  if self.timerData.timer then
    self.pinOut.timer.value = self.timerData.timer.value or 0
  end
end

return _flowgraph_createNode(C)