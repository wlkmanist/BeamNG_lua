-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Start Crawl'
C.description = 'Starts the crawl race/timer. Requires Setup Crawl to be called first. Uses the trail and vehicle that were set up by Setup Crawl node.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.sites
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'out', type = 'flow', name = 'success', description = 'Triggered when crawl starts successfully' },
  { dir = 'out', type = 'flow', name = 'failed', description = 'Triggered when start fails' }
}

C.tags = {'crawl', 'gameplay', 'start'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  log('I', 'StartCrawl', '=== Start Crawl Node Triggered ===')
  log('D', 'StartCrawl', 'Using active trail and vehicle from Setup Crawl node')

  log('D', 'StartCrawl', 'Calling bridge.startCrawl (trail and vehicle from Setup Crawl)')
  if self.bridge.startCrawl(nil, nil) then
    log('I', 'StartCrawl', 'Crawl started successfully via bridge')
    self.pinOut.success.value = true
    self.pinOut.failed.value = false
  else
    log('E', 'StartCrawl', 'Bridge.startCrawl returned false - make sure Setup Crawl was called first')
    self.pinOut.success.value = false
    self.pinOut.failed.value = true
  end
end

return _flowgraph_createNode(C)
