local M = {}

local api = extensions.editor_api_dynamicDecals
local uiTools = extensions.ui_liveryEditor_tools
local uiSelectionApi = extensions.ui_liveryEditor_selection
local uiLayersApi = extensions.ui_liveryEditor_layers

M.moveOrderUp = function()
  uiTools.doOperation(function(layer)
    M.moveOrderUpById(layer.uid)
  end)
end

M.moveOrderDown = function()
  uiTools.doOperation(function(layer)
    M.moveOrderDownById(layer.uid)
  end)
end

M.moveOrderUpById = function(layerUid)
  local uiLayer = uiLayersApi.getLayerByUid(layerUid)

  if uiLayer.order <= 1 then
    log("W", "", "Unable to move layer " .. uiLayer.uid .. " up with order " .. uiLayer.order)
    return
  end

  api.moveLayer(uiLayer.order, uiLayer.parentUid, uiLayer.order - 1, uiLayer.parentUid)
end

M.moveOrderDownById = function(layerUid)
  local uiLayer = uiLayersApi.getLayerByUid(layerUid)
  local siblingsCount = uiLayersApi.getChildrenCount(uiLayer.parentUid)

  if uiLayer.order >= siblingsCount then
    log("W", "", "Unable to move layer " .. uiLayer.uid .. " down with order " .. uiLayer.order)
    return
  end

  api.moveLayer(uiLayer.order, uiLayer.parentUid, uiLayer.order + 1, uiLayer.parentUid)
end

M.changeOrder = function(oldOrder, oldParentUid, newOrder, newParentUid)
  if oldParentUid == "" then
    oldParentUid = nil
  end
  if newParentUid == "" then
    newParentUid = nil
  end
  api.moveLayer(oldOrder, oldParentUid, newOrder, newParentUid)
end

M.groupLayers = function()
  local selectedLayerUids = uiSelectionApi.getSelectedLayers()

  -- create linked group layer here
  -- get layer with shallowest level and use its parent as group's parent
  local shallowestLevel
  local parentUid
  for k, layerUid in ipairs(selectedLayerUids) do
    local uiLayer = uiLayersApi.getLayerByUid(layerUid)
    local level = uiLayer.path and #uiLayer.path or 0

    if not shallowestLevel or level < shallowestLevel then
      shallowestLevel = level
      parentUid = uiLayer.parentUid
    end
  end

  local newGroup = api.addLinkedSet({parentUid})

  -- move selected layers to this group
  local newOrder = 1
  for k, layerUid in ipairs(selectedLayerUids) do
    local uiLayer = uiLayersApi.getLayerByUid(layerUid)
    api.moveLayer(uiLayer.order, uiLayer.parentUid, newOrder, newGroup.uid)
    newOrder = newOrder + 1
  end

  -- select new group
  uiSelectionApi.setSelected(newGroup.uid)
end

M.ungroupLayer = function()
  uiTools.doOperation(function(layer)
    local uiLayer = uiLayersApi.getLayerByUid(layer.uid)

    -- Need to store layer ids first instead of directly calling moveLayer
    -- to avoid getting reference and the latest data after moving layer
    local childLayerUids = {}

    for k, childLayer in ipairs(uiLayer.children) do
      table.insert(childLayerUids, childLayer.uid)
    end

    local layerIndex = uiLayer.order
    for k, layerUid in ipairs(childLayerUids) do
      local layer = uiLayersApi.getLayerByUid(layerUid)
      api.moveLayer(layer.order, layer.parentUid, layerIndex, uiLayer.parentUid)
      layerIndex = layerIndex + 1
    end

    uiLayer = uiLayersApi.getLayerByUid(layer.uid)
    api.removeLayer(uiLayer.order, uiLayer.parentUid)
  end)
end

return M
