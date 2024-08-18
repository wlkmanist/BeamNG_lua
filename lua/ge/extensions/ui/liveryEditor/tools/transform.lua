local M = {}

local api = extensions.editor_api_dynamicDecals
local uiSelectionApi = extensions.ui_liveryEditor_selection
local uiDecalsApi = extensions.ui_liveryEditor_layers_decals
local uiLayersApi = extensions.ui_liveryEditor_layers
local uiTools = extensions.ui_liveryEditor_tools
local uiControlsApi = extensions.ui_liveryEditor_controls

-- Stamp assumes there is only one layer selected
M.useStamp = function()
  local layerUid = uiSelectionApi.getFirstSelectedLayer()
  local layer = api.getLayerByUid(layerUid)

  -- match decal project properties to selected layer
  api.setDecalRotation(layer.decalRotation)
  api.setDecalScale(layer.decalScale)
  api.setDecalSkew(layer.decalSkew)
  api.setDecalColor(layer.color)

  -- hide selected layer
  layer.color = Point4F(layer.color.x, layer.color.y, layer.color.z, 0)
  api.setLayer(layer, true)

  uiDecalsApi.showCursor(true)
  uiControlsApi.useMouseProjection()

  guihooks.trigger("LiveryEditor_ToolDataUpdated", {mode = "stamp"})
end

M.cancelStamp = function()
  dump("cancelStamp")
  local layerUid = uiSelectionApi.getFirstSelectedLayer()
  local layer = api.getLayerByUid(layerUid)

  -- show selected layer
  layer.color = Point4F(layer.color.x, layer.color.y, layer.color.z, 1)
  api.setLayer(layer, true)

  uiDecalsApi.showCursor(false)
  uiControlsApi.useCursorProjection()
  guihooks.trigger("LiveryEditor_ToolDataUpdated", {mode = "default"})
end

-- Stamp assumes there is only one layer selected
M.stamp = function()
  local layerUid = uiSelectionApi.getFirstSelectedLayer()
  local layer = api.getLayerByUid(layerUid)
  local color = {layer.color.x, layer.color.y, layer.color.z, 1}

  local referenceLayer = uiDecalsApi.createDecal({color = color})
  local updatedLayer = deepcopy(referenceLayer)

  updatedLayer.uid = layerUid
  api.setLayer(updatedLayer, true)

  local uiLayer = uiLayersApi.getLayerByUid(layerUid)
  api.removeLayer(uiLayer.order + 1, uiLayer.parentUid)

  uiControlsApi.useCursorProjection()

  guihooks.trigger("LiveryEditor_ToolDataUpdated", {mode = "default"})
end

M.translate = function(steps_x, steps_y)
  uiTools.doOperation(function(layer, steps_x, steps_y)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.translate(layer, steps_x, steps_y)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, steps_x, steps_y)
end

-- Increment/decrement the rotation by a number of degrees
M.rotate = function(degrees, counterClockwise)
  uiTools.doOperation(function(layer, degrees, counterClockwise)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.rotate(layer, degrees, counterClockwise)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, degrees, counterClockwise)
end

-- Set degree value as the rotation
M.setRotation = function(degrees)
  uiTools.doOperation(function(layer, degrees)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.setRotation(layer, degrees)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, degrees)
end

M.scale = function(steps_x, steps_y)
  uiTools.doOperation(function(layer, steps_x, steps_y)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.scale(layer, steps_x, steps_y)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, steps_x, steps_y)
end

M.setScale = function(scaleX, scaleY)
  uiTools.doOperation(function(layer, scaleX, scaleY)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.setScale(layer, scaleX, scaleY)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, scaleX, scaleY)
end

M.skew = function(skewX, skewY)
  uiTools.doOperation(function(layer, skewX, skewY)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.skew(layer, skewX, skewY)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, skewX, skewY)
end

M.setSkew = function(skewX, skewY)
  uiTools.doOperation(function(layer, skewX, skewY)
    if layer.type == api.layerTypes.decal then
      uiDecalsApi.setSkew(layer, skewX, skewY)
    elseif layer.type == api.layerTypes.group then
      log("D", "", "Translate Group not implemented yet")
    else
      log("W", "", "Cannot move unsupported layer " .. layer.uid .. " of type " .. (layer.type or "nil"))
    end
  end, skewX, skewY)
end

return M
