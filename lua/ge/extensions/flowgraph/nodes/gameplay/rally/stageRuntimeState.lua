-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')

local C = {}

C.name = 'Rally Stage Runtime State'
C.description = 'Reads rally-owned stage runtime state from RallyManager.'
C.color = rallyUtil.rally_flowgraph_color
C.tags = {'rally'}
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow from this node.' },
  { dir = 'out', type = 'flow', name = 'active', description = 'Active while RallyManager reports the stage active.' },
  { dir = 'out', type = 'flow', name = 'complete', description = 'Outflow when rally-owned tracker completion is complete.' },
  { dir = 'out', type = 'number', name = 'time', description = 'Current stage time in seconds.' },
}

function C:init()
  self.lastTime = 0
end

function C:_executionStarted()
  self.lastTime = 0
end

local function clearOutputs(self)
  self.pinOut.flow.value = false
  self.pinOut.active.value = false
  self.pinOut.complete.value = false
  self.pinOut.time.value = self.lastTime or 0
end

function C:work()
  clearOutputs(self)
  self.pinOut.flow.value = self.pinIn.flow.value

  if not extensions.isExtensionLoaded('gameplay_rally') or not gameplay_rally then
    return
  end

  local rm = gameplay_rally.getRallyManager and gameplay_rally.getRallyManager() or nil
  if not rm then return end

  rm:setStageRuntimeAuthorityMode('tracker')
  if self.pinIn.flow.value then
    rm:setStageRuntimeActive(true)
  end

  if self.pinIn.flow.value then
    extensions.hook("onRallyDataUpdated", {
      activeState = rallyUtil.activeState_stageActive,
    })
  end

  local stageData = rm:getActiveStageData()
  local observerState = rm.getStageObserverState and rm:getStageObserverState() or nil
  local trackerComplete = observerState and observerState.stageComplete == true or false
  local currentTime = stageData and stageData.currentSSTime
  if currentTime == nil and rm.getStageRuntimeTime then
    currentTime = rm:getStageRuntimeTime()
  end
  if currentTime ~= nil then
    self.lastTime = currentTime
  end

  self.pinOut.active.value = stageData and stageData.isActive == true
  self.pinOut.time.value = self.lastTime or 0
  self.pinOut.complete.value = trackerComplete
end

return _flowgraph_createNode(C)
