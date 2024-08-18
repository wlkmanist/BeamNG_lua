local M = {}

local api = extensions.editor_api_dynamicDecals
local uiTools = extensions.ui_liveryEditor_tools
local uiLayerGroup = extensions.ui_liveryEditor_layers_group

M.setColor = function(rgbaArray)
  dump("setColor", rgbaArray)
  uiTools.doOperation(function(layer, color)
    if layer.type == api.layerTypes.linkedSet then
      uiLayerGroup.setColor(layer, color)
    else
      layer.color = Point4F.fromTable(color)
      api.setLayer(layer, true)
    end
  end, rgbaArray)
end

M.setMetallicIntensity = function(metallicIntensity)
  dump("setMetallicIntensity", metallicIntensity)
  uiTools.doOperation(function(layer, metallicIntensity)
    if metallicIntensity and metallicIntensity >= 0 or metallicIntensity <= 1 then
      if layer.type == api.layerTypes.group then
        uiLayerGroup.setMetallicIntensity(layer, metallicIntensity)
      else
        layer.metallicIntensity = metallicIntensity
        api.setLayer(layer, true)
      end
    else
      log("W", "", "Metallic intensity is not valid " .. (metallicIntensity or "nil"))
    end
  end, metallicIntensity)
end

M.setRoughnessIntensity = function(roughnessIntensity)
  dump("seRoughnessIntensity", roughnessIntensity)
  uiTools.doOperation(function(layer, metallicIntensity)
    if roughnessIntensity and roughnessIntensity >= 0 or roughnessIntensity <= 1 then
      if layer.type == api.layerTypes.group then
        uiLayerGroup.setRoughnessIntensity(layer, roughnessIntensity)
      else
        layer.roughnessIntensity = roughnessIntensity
        api.setLayer(layer, true)
      end
    else
      log("W", "", "Roughness intensity is not valid " .. (metallicIntensity or "nil"))
    end
  end, roughnessIntensity)
end

M.setNormalIntensity = function(normalIntensity)
  dump("setNormalIntensity", normalIntensity)
  uiTools.doOperation(function(layer, normalIntensity)
    if normalIntensity and normalIntensity >= 0 or normalIntensity <= 1 then
      if layer.type == api.layerTypes.group then
        uiLayerGroup.setRoughnessIntensity(layer, normalIntensity)
      else
        layer.normalIntensity = normalIntensity
        api.setLayer(layer, true)
      end
    else
      log("W", "", "Roughness intensity is not valid " .. (normalIntensity or "nil"))
    end
  end, normalIntensity)
end

return M
