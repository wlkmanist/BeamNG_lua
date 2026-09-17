-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Setup Crawl'
C.description = 'Sets up a crawl trail by loading the trail data, teleporting the vehicle to the start position, and loading prefabs. Does not start the crawl timer - use Start Crawl node to begin the race.'
C.category = 'once_instant'
C.color = ui_flowgraph_editor.nodeColors.sites
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'string', name = 'trailId', default = '', description = 'Trail ID/filepath to load' },
  { dir = 'in', type = 'number', name = 'vehicleId', default = 0, description = 'Vehicle ID (0 = player vehicle)' },
  { dir = 'out', type = 'flow', name = 'success', description = 'Triggered when crawl setup completes successfully' },
  { dir = 'out', type = 'flow', name = 'failed', description = 'Triggered when setup fails' },
  { dir = 'out', type = 'bool', name = 'isSetup', description = 'True after successful setup (crawl ready but not started)' }
}

C.tags = {'crawl', 'gameplay', 'setup'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  log('I', 'SetupCrawl', '=== Setup Crawl Node Triggered ===')
  local trailId = self.pinIn.trailId.value
  local vehicleId = self.pinIn.vehicleId.value

  log('D', 'SetupCrawl', string.format('Input values - trailId: "%s", vehicleId: %s', tostring(trailId), tostring(vehicleId)))

  -- If no trailId provided, try to get it from flowgraph variable or mission folder
  if not trailId or trailId == '' then
    log('D', 'SetupCrawl', 'No trail ID provided, checking flowgraph variable')
    if self.mgr and self.mgr.variables then
      local trailFileVar, exists = self.mgr.variables:get('trailFile')
      if exists and trailFileVar and trailFileVar ~= '' then
        trailId = trailFileVar
        log('D', 'SetupCrawl', string.format('Found trail file from flowgraph variable: %s', trailId))
      end
    end

    -- If still no trailId, try mission folder
    if (not trailId or trailId == '') and self.mgr and self.mgr.activity and self.mgr.activity.missionFolder then
      local missionFolder = self.mgr.activity.missionFolder
      log('D', 'SetupCrawl', string.format('Checking mission folder: %s', missionFolder))

      -- Look for trail files in mission folder
      local trailFiles = FS:findFiles(missionFolder, '*.trail.json', -1, true, false) or {}
      if #trailFiles > 0 then
        trailId = trailFiles[1]
        log('D', 'SetupCrawl', string.format('Found trail file in mission folder: %s', trailId))
      end
    end

    if not trailId or trailId == '' then
      log('E', 'SetupCrawl', 'No trail ID provided and none found in flowgraph variable or mission folder')
      self.pinOut.success.value = false
      self.pinOut.failed.value = true
      self.pinOut.isSetup.value = false
      return
    end
  end

  log('D', 'SetupCrawl', 'Loading trail: ' .. tostring(trailId))
  local trail = self.bridge.loadCrawlTrail(trailId)
  if not trail then
    log('E', 'SetupCrawl', 'Failed to load trail: ' .. tostring(trailId))
    self.pinOut.success.value = false
    self.pinOut.failed.value = true
    self.pinOut.isSetup.value = false
    return
  end

  log('D', 'SetupCrawl', string.format('Trail loaded successfully - name: "%s", pathId: "%s", boundaryId: "%s", startingPositionId: "%s"',
    tostring(trail.name), tostring(trail.pathId), tostring(trail.boundaryId), tostring(trail.startingPositionId)))

  local vehicleIdToUse = vehicleId > 0 and vehicleId or nil
  log('D', 'SetupCrawl', string.format('Calling bridge.setupCrawl with vehicleId: %s', tostring(vehicleIdToUse)))
  if self.bridge.setupCrawl(vehicleIdToUse, trail) then
    log('I', 'SetupCrawl', 'Crawl setup completed successfully via bridge')
    self.pinOut.success.value = true
    self.pinOut.failed.value = false
    self.pinOut.isSetup.value = true
  else
    log('E', 'SetupCrawl', 'Bridge.setupCrawl returned false')
    self.pinOut.success.value = false
    self.pinOut.failed.value = true
    self.pinOut.isSetup.value = false
  end
end

return _flowgraph_createNode(C)

