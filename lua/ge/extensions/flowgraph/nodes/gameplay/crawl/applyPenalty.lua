-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Apply Penalty'
C.description = 'Manually applies penalty points to the active crawl by selecting from a predefined list.'
C.category = 'impulse'
C.color = ui_flowgraph_editor.nodeColors.vehicle
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Trigger to apply penalty', impulse = true },
  { dir = 'in', type = 'string', name = 'penaltyType', description = 'Type of penalty to apply' },
}

C.tags = {'crawl', 'gameplay', 'penalty', 'manual'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:postInit()
  local penaltyTypes = self.bridge.getPenaltyTypes()
  local templates = {}
  for _, penaltyType in ipairs(penaltyTypes) do
    table.insert(templates, {value = penaltyType, label = penaltyType})
  end
  self.pinInLocal.penaltyType.hardTemplates = templates
end

function C:work()
  local penaltyType = self.pinIn.penaltyType.value

  -- Validate penalty type
  if not penaltyType or penaltyType == '' then
    self.pinOut.success.value = false
    self.pinOut.failed.value = true
    return
  end

  -- Apply penalty through bridge (bridge will validate penalty type and get points from utils)
  self.bridge.applyPenalty(penaltyType)
end

return _flowgraph_createNode(C)
