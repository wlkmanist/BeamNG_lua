-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Stop Crawl'
C.description = 'Stops the currently active crawl.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.sites
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'flow', name = 'success', description = 'Triggered when crawl stops successfully' },
  { dir = 'out', type = 'flow', name = 'failed', description = 'Triggered when no crawl was active' },
  { dir = 'out', type = 'bool', name = 'isActive', description = 'False after stopping (always false)' }
}

C.tags = {'crawl', 'gameplay', 'stop'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  if self.bridge.stopCrawl() then
    self.pinOut.success.value = true
    self.pinOut.failed.value = false
  else
    self.pinOut.success.value = false
    self.pinOut.failed.value = true
  end

  self.pinOut.isActive.value = false
end

return _flowgraph_createNode(C)
