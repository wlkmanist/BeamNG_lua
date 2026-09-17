-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Reset Crawl'
C.description = 'Resets the currently active crawl by teleporting the crawler to the start and resetting all crawl data and timers. The crawl system remains active but the timer is stopped until Start Crawl is called.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.sites
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'flow', name = 'success', description = 'Triggered when crawl resets successfully' },
  { dir = 'out', type = 'flow', name = 'failed', description = 'Triggered when reset fails' },
  { dir = 'out', type = 'bool', name = 'isActive', description = 'True after reset (crawl continues running)' }
}

C.tags = {'crawl', 'gameplay', 'reset'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  if self.bridge.resetCrawl() then
    self.pinOut.success.value = true
    self.pinOut.failed.value = false
    self.pinOut.isActive.value = true  -- Crawl continues running after reset
  else
    self.pinOut.success.value = false
    self.pinOut.failed.value = true
    self.pinOut.isActive.value = self.bridge.isCrawlActive()  -- Check actual crawl state
  end
end

return _flowgraph_createNode(C)
