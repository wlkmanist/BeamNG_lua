local M = {}

local api = extensions.editor_api_dynamicDecals
local uiTools = extensions.ui_liveryEditor_tools
local uiLayers = extensions.ui_liveryEditor_layers

M.setVisibility = function(show)
  uiTools.doOperation(function(layer, show)
    layer.enabled = show
    api.setLayer(layer, true)
  end, show)
end

M.toggleVisibility = function()
  uiTools.doOperation(function(layer)
    layer.enabled = not layer.enabled
    api.setLayer(layer, true)
  end)
end

M.toggleLock = function()
  uiTools.doOperation(function(layer)
    layer.locked = not layer.locked
    api.setLayer(layer, false)
  end)
end

M.toggleVisibilityById = function(layerUid)
  local layer = api.getLayerByUid(layerUid)
  layer.enabled = not layer.enabled
  api.setLayer(layer, true)
end

M.toggleLockById = function(layerUid)
  local layer = api.getLayerByUid(layerUid)
  layer.locked = not layer.locked
  api.setLayer(layer, false)
end

M.rename = function(name)
  uiTools.doOperation(function(layer)
    layer.name = name
    api.setLayer(layer, false)
  end)
end

M.deleteLayer = function()
  uiTools.doOperation(function(layer)
    local uiLayer = uiLayers.getLayerByUid(layer.uid)
    dump("deleteLayer", uiLayer)
    api.removeLayer(uiLayer.order, uiLayer.parentUid)
  end)
end

M.setMirrored = function(mirror, flip)
  uiTools.doOperation(function(layer)
    layer.mirrored = mirror
    layer.flipMirroredDecal = flip or false
    api.setLayer(layer, true)
  end)
end

return M
