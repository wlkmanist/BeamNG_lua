-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Get Crawl Results'
C.description = 'Gets completion data from a finished crawl.'
C.category = 'repeat_instant'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'number', name = 'time', description = 'Final completion time' },
  { dir = 'out', type = 'number', name = 'points', description = 'Final penalty points' },
  { dir = 'out', type = 'number', name = 'damage', description = 'Total damage taken' },
  { dir = 'out', type = 'number', name = 'recoveries', description = 'Number of recoveries used' },
  { dir = 'out', type = 'bool', name = 'completed', description = 'True if crawl was completed' },
  { dir = 'out', type = 'bool', name = 'disqualified', description = 'True if crawler was disqualified' },
  { dir = 'out', type = 'table', name = 'pathnodeTimings', description = 'Timing data for each pathnode', tableType = 'generic' }
}

C.tags = {'crawl', 'gameplay', 'results', 'completion'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  -- Check if bridge is initialized
  if not self.bridge then
    local errorMsg = "Crawl bridge not initialized. Make sure crawl system is loaded."
    self:__setNodeError('bridge', errorMsg)
    return
  end

  local data = self.bridge.getCrawlEndData()

  if data then
    -- Clear error if data is available
    self:__setNodeError(nil, nil)
    self.pinOut.time.value = data.time
    self.pinOut.points.value = data.points
    self.pinOut.damage.value = data.damage or 0
    self.pinOut.recoveries.value = data.recoveries or 0
    self.pinOut.completed.value = data.completed
    self.pinOut.disqualified.value = data.disqualified
    self.pinOut.pathnodeTimings.value = data.pathnodeTimings
  else
    local errorMsg = "Crawl end data not available. Crawl may not be completed yet."
    self:__setNodeError('data', errorMsg)
    self.pinOut.time.value = 0
    self.pinOut.points.value = 0
    self.pinOut.damage.value = 0
    self.pinOut.recoveries.value = 0
    self.pinOut.completed.value = false
    self.pinOut.disqualified.value = false
    self.pinOut.pathnodeTimings.value = {}
  end
end

return _flowgraph_createNode(C)
