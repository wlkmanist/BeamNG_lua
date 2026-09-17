-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im  = ui_imgui

local C = {}

C.name = 'Traffic Driving Stats'
C.description = 'Gives information about the road tracking and driving behavior of a vehicle.'
C.color = ui_flowgraph_editor.nodeColors.traffic
C.icon = ui_flowgraph_editor.nodeIcons.traffic
C.category = 'once_p_duration'
C.tags = {'police', 'pursuit', 'traffic', 'ai', 'drive', 'driving', 'road', 'tracking'}

C.pinSchema = {
  {dir = 'in', type = 'number', name = 'vehId', description = 'Vehicle id to get information from; if none given, uses the player vehicle.'},
  {dir = 'out', type = 'string', name = 'n1', description = 'First node of the current road.'},
  {dir = 'out', type = 'string', name = 'n2', description = 'Second node of the current road.'},
  {dir = 'out', type = 'number', name = 'roadOffset', description = 'Road side offset from the center line.'},
  {dir = 'out', type = 'number', name = 'roadXnorm', hidden = true, description = 'Normalized road lateral offset (left edge is 0, right edge is 1).'},
  {dir = 'out', type = 'number', name = 'roadYnorm', hidden = true, description = 'Normalized road longitudinal offset (back edge is 0, front edge is 1).'},
  {dir = 'out', type = 'number', name = 'speedRatio', description = 'Vehicle speed divided by the speed limit.'},
  {dir = 'out', type = 'number', name = 'collisions', description = 'Number of collisions with other vehicles.'},
  {dir = 'out', type = 'number', name = 'faultOverSpeed', description = 'Fault score for speeding (from 0 to 1).'},
  {dir = 'out', type = 'number', name = 'faultWrongWay', description = 'Fault score for wrong way driving (from 0 to 1).'},
  {dir = 'out', type = 'number', name = 'faultReckless', description = 'Fault score for reckless driving (from 0 to 1).'},
  {dir = 'out', type = 'number', name = 'timerOverSpeed', hidden = true, description = 'Duration of the speeding offense.'},
  {dir = 'out', type = 'number', name = 'timerWrongWay', hidden = true, description = 'Duration of the wrong way driving offense.'},
  {dir = 'out', type = 'number', name = 'timerReckless', hidden = true, description = 'Duration of the reckless driving offense.'}
}

-- All "fault" numbers are set from 0 (good) to 1 (bad) depending on duration and intensity of the offense
-- The default threshold to trigger a pursuit offense is 0.5

function C:init()
  self:onNodeReset()
end

function C:_executionStopped()
  self:onNodeReset()
end

function C:onNodeReset()
  self.vehId = nil
  self.tracking = nil
end

function C:work()
  self.vehId = self.pinIn.vehId.value or be:getPlayerVehicleID(0)
  if not self.tracking or self.tracking.vehId ~= self.vehId then
    self.tracking = require('gameplay/traffic/roadTracking')({vehId = self.vehId})
  end

  if not self.tracking or self.tracking._invalid then return end

  self.tracking:onUpdate(self.mgr.dtSim)

  self.pinOut.n1.value = self.tracking.n1
  self.pinOut.n2.value = self.tracking.n2
  self.pinOut.roadOffset.value = self.tracking.roadOffset
  self.pinOut.roadXnorm.value = self.tracking.roadXnorm
  self.pinOut.roadYnorm.value = self.tracking.roadYnorm
  self.pinOut.speedRatio.value = self.tracking.speedRatio
  self.pinOut.collisions.value = self.tracking.collisionCount
  self.pinOut.faultOverSpeed.value = self.tracking.faults.overSpeed
  self.pinOut.faultWrongWay.value = self.tracking.faults.wrongWay
  self.pinOut.faultReckless.value = self.tracking.faults.reckless
  self.pinOut.timerOverSpeed.value = self.tracking.timers.overSpeed
  self.pinOut.timerWrongWay.value = self.tracking.timers.wrongWay
  self.pinOut.timerReckless.value = self.tracking.timers.reckless
end

return _flowgraph_createNode(C)