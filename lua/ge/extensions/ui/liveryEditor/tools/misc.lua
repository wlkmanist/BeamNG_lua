local M = {}

local api = extensions.editor_api_dynamicDecals
local uiTools = extensions.ui_liveryEditor_tools
local uiLayers = extensions.ui_liveryEditor_layers

M.duplicate = function()
  uiTools.doOperation(function(layer)
    local uiLayer = uiLayers.getLayerByUid(layer.uid)
    api.duplicateLayer(uiLayer.order, uiLayer.parentUid)
  end)
end

return M
