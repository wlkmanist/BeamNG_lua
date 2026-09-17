-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Get Crawl Data'
C.description = 'Gets runtime data from the currently active crawl.'
C.category = 'repeat_instant'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'flow', name = 'onCompleted', description = 'Triggered when trail is completed' },
  { dir = 'out', type = 'flow', name = 'onDisqualified', description = 'Triggered when crawler is disqualified' },
  { dir = 'out', type = 'flow', name = 'onCheckpointReached', description = 'Triggered when crawler reaches a checkpoint' },
  { dir = 'out', type = 'bool', name = 'isCompleted', description = 'True if crawl has completed successfully' },
  { dir = 'out', type = 'bool', name = 'disqualified', description = 'True if crawler is disqualified' },
  { dir = 'out', type = 'vec3', name = 'crawlerPosition', description = 'Current crawler position' },
  { dir = 'out', type = 'quat', name = 'crawlerDirection', description = 'Current crawler direction rotation (yaw only)' },
  { dir = 'out', type = 'number', name = 'vehicleId', description = 'Active crawler vehicle ID' },
  { dir = 'out', type = 'bool', name = 'hasRecoveryCheckpoint', description = 'True if crawler has reached a recovery checkpoint' },
  { dir = 'out', type = 'vec3', name = 'recoveryPosition', description = 'Position of the last recovery checkpoint' },
  { dir = 'out', type = 'quat', name = 'recoveryRotation', description = 'Rotation of the last recovery checkpoint' }
}

C.tags = {'crawl', 'gameplay', 'data', 'runtime'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
  self.lastCompleted = false
  self.lastDisqualified = false
  self.lastCheckpointIndex = 0
end

function C:work()
  -- Check if bridge is initialized
  if not self.bridge then
    local errorMsg = "Crawl bridge not initialized. Make sure crawl system is loaded."
    self:__setNodeError('bridge', errorMsg)
    return
  end

  local data = self.bridge.getCrawlRuntimeData()
  local recoveryCheckpoint = self.bridge.getLastRecoveryCheckpoint()

  -- Reset flow events
  self.pinOut.onCompleted.value = false
  self.pinOut.onDisqualified.value = false
  self.pinOut.onCheckpointReached.value = false

  -- Check if crawl data is available
  if not data then
    local errorMsg = "Crawl runtime data not available. No active crawl found."
    self:__setNodeError('data', errorMsg)
    -- Set default values
    self.pinOut.isCompleted.value = false
    self.pinOut.disqualified.value = false
    self.pinOut.crawlerPosition.value = {0, 0, 0}
    self.pinOut.crawlerDirection.value = {0, 0, 0, 1}
    self.pinOut.vehicleId.value = 0
    self.pinOut.hasRecoveryCheckpoint.value = false
    self.pinOut.recoveryPosition.value = {0, 0, 0}
    self.pinOut.recoveryRotation.value = {0, 0, 0, 1}
    return
  end

  -- Clear error if data is available
  self:__setNodeError(nil, nil)

  if data then
    self.pinOut.isCompleted.value = data.isCompleted
    self.pinOut.disqualified.value = data.disqualified
    self.pinOut.crawlerPosition.value = data.crawlerPosition and data.crawlerPosition:toTable() or {0, 0, 0}
    self.pinOut.crawlerDirection.value = data.crawlerDirection and data.crawlerDirection:toTable() or {0, 0, 0, 1}
    self.pinOut.vehicleId.value = data.vehicleId

    -- Check for completion event
    if data.isCompleted and not self.lastCompleted then
      self.pinOut.onCompleted.value = true
    end
    self.lastCompleted = data.isCompleted

    -- Check for disqualification event
    if data.disqualified and not self.lastDisqualified then
      self.pinOut.onDisqualified.value = true
    end
    self.lastDisqualified = data.disqualified

    -- Check for checkpoint reached event
    if data.currentPathnodeIndex and data.currentPathnodeIndex > self.lastCheckpointIndex then
      self.pinOut.onCheckpointReached.value = true
    end
    self.lastCheckpointIndex = data.currentPathnodeIndex or 0

    -- Recovery checkpoint data
    if recoveryCheckpoint then
      self.pinOut.hasRecoveryCheckpoint.value = true
      self.pinOut.recoveryPosition.value = recoveryCheckpoint.position and recoveryCheckpoint.position:toTable() or {0, 0, 0}
      self.pinOut.recoveryRotation.value = recoveryCheckpoint.rotation and recoveryCheckpoint.rotation:toTable() or {0, 0, 0, 1}
    else
      self.pinOut.hasRecoveryCheckpoint.value = false
      self.pinOut.recoveryPosition.value = {0, 0, 0}
      self.pinOut.recoveryRotation.value = {0, 0, 0, 1}
    end
  end
end

return _flowgraph_createNode(C)
