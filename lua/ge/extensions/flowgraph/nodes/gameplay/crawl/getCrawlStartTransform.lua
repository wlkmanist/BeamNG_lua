-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Get Crawl Start Transform'
C.description = 'Gets the start transform (position and rotation) of the currently active crawl.'
C.category = 'repeat_instant'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'vec3', name = 'startPosition', description = 'Crawl start position' },
  { dir = 'out', type = 'quat', name = 'startRotation', description = 'Crawl start rotation' }
}

C.tags = {'crawl', 'gameplay', 'data', 'start', 'transform'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  if not self.bridge then
    self:__setNodeError('bridge', 'Crawl bridge not initialized. Make sure crawl system is loaded.')
    self.pinOut.startPosition.value = {0, 0, 0}
    self.pinOut.startRotation.value = {0, 0, 0, 1}
    return
  end

  local transform = self.bridge.getCrawlSpawnTransform and self.bridge.getCrawlSpawnTransform() or nil
  if not transform then
    self:__setNodeError('transform', 'Crawl start transform not available. No active crawl found.')
    self.pinOut.startPosition.value = {0, 0, 0}
    self.pinOut.startRotation.value = {0, 0, 0, 1}
    return
  end

  self:__setNodeError(nil, nil)
  self.pinOut.startPosition.value = transform.position:toTable()
  self.pinOut.startRotation.value = transform.rotation:toTable()
end

return _flowgraph_createNode(C)
