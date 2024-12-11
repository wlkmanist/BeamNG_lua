local M = {}

local api = extensions.editor_api_dynamicDecals

local ACTIONS = {"material", "rename", "visibility"}
local PRESET_ACTIONS = {"rename", "visibility"}

M.layerUid = nil
M.layerData = nil

M.setLayer = function(layerUid)
  M.layerUid = layerUid
  M.layerData = deepcopy(api.getLayerByUid(M.layerUid))
  -- notify ui and extensions
end

M.changeColor = function(color)
  local layer = api.getLayerByUid(M.layerUid)
  if #color == 4 then
    layer.color = Point4F.fromTable(color)
  elseif #color == 3 then
    local r, g, b = unpack(color)
    layer.color = Point4F(r, g, b, 1)
  end
  api.setLayer(layer, true)
end

M.addLayer = function(params)
  api.setFillLayerColorPaletteMapId(0)
  api.setFillLayerColor(params.color)
  return api.addFillLayer()
end

M.updateLayer = function(params)
  if M.layerUid then
    if params.color then
      M.changeColor(params.color)
    end
  else
    log("W", "", "Unable to update non-existing layer " .. M.layerUid)
  end
end

M.saveChanges = function()
  if M.layerUid then
    M.layerData = api.getLayerByUid(M.layerUid)
  end
end

M.restoreLayer = function()
  if M.layerData then
    api.setLayer(M.layerData, true)
  end
end

return M
