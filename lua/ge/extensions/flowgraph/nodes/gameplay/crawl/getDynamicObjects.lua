local C = {}

C.name = 'Get Dynamic Objects'
C.description = 'Gets dynamic objects from a prefab with a specific dynamic field name.'
C.category = 'repeat_instant'
C.color = ui_flowgraph_editor.nodeColors.sites
C.icon = ui_flowgraph_editor.nodeIcons.gameplay

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'prefabId', default = 0, description = 'Prefab ID to search in' },
  { dir = 'in', type = 'string', name = 'dynamicName', default = 'crawlDynamic', description = 'Dynamic field name to match' },
  { dir = 'out', type = 'table', name = 'dynamicObjects', description = 'Table of dynamic object IDs', tableType = 'generic' },
}

C.tags = {'crawl', 'gameplay', 'dynamic', 'objects'}

C.dependencies = {'gameplay_crawl_flowgraphBridge'}

function C:init(mgr)
  self.bridge = require('ge/extensions/gameplay/crawl/flowgraphBridge')
end

function C:work()
  local prefabId = self.pinIn.prefabId.value
  local dynamicName = self.pinIn.dynamicName.value

  if not prefabId or prefabId == 0 then
    self.pinOut.dynamicObjects.value = {}
    return
  end

  local objects = self.bridge.getDynamicObjectsFromPrefab(prefabId, dynamicName)
  self.pinOut.dynamicObjects.value = objects or {}
end

return _flowgraph_createNode(C)
