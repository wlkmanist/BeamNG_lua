-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"editor_api_dynamicDecals", "ui_liveries_paint"}

local baseFillLayerUid = nil

M.setup = function(vehicleColor)
  if not extensions.editor_api_dynamicDecals or not vehicleColor then return false end

  extensions.editor_api_dynamicDecals.setFillLayerColorPaletteMapId(ui_liveries_paint.EDITABLE_COLOR_PALETTE_MAP_ID)
  extensions.editor_api_dynamicDecals.setFillLayerColor(vehicleColor)

  local layer = extensions.editor_api_dynamicDecals.addFillLayer()
  baseFillLayerUid = layer and layer.uid or nil
  return baseFillLayerUid ~= nil
end

M.bindLoadedLayer = function()
  if not extensions.editor_api_dynamicDecals then return false end

  -- get the fill layer at the bottom of the stack
  baseFillLayerUid = nil
  for _, layer in ipairs(extensions.editor_api_dynamicDecals.getLayerStack()) do
    if layer.type == extensions.editor_api_dynamicDecals.layerTypes.fill then
      baseFillLayerUid = layer.uid
      break
    end
  end

  if not baseFillLayerUid then
    log("W", "liveries", "loaded livery has no base fill layer, the paint screen will be inert")
    return false
  end

  return true
end

M.teardown = function()
  baseFillLayerUid = nil
end

M.getPaint = function()
  if not baseFillLayerUid then
    log("W", "liveries", "no base fill layer to read the paint of")
    return nil
  end

  local paint = ui_liveries_paint.getLayerPaint(baseFillLayerUid)
  if not paint then return nil end

  local vehicleObj = getPlayerVehicle(0)
  if vehicleObj and vehicleObj.color then
    paint.vehicleColor = {
      vehicleObj.color.x,
      vehicleObj.color.y,
      vehicleObj.color.z,
      vehicleObj.color.w,
    }
  end

  return paint
end

M.setPaint = function(paint)
  if not baseFillLayerUid then
    log("W", "liveries", "no base fill layer to update the paint of")
    return false
  end

  return ui_liveries_paint.setLayerPaint(baseFillLayerUid, paint)
end

return M
