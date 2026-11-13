-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"editor_api_dynamicDecals"}

-- palette map 0 is the only mode in which a layer renders its own color, every other id pulls
-- the color from a vehicle color palette slot instead and ignores the layer's own
M.EDITABLE_COLOR_PALETTE_MAP_ID = 0

local function getVehiclePaintPresets()
  local vehicleObj = getPlayerVehicle(0)
  if not vehicleObj then return {} end

  local model = core_vehicles.getModel(vehicleObj.JBeam).model
  return model and model.paints or {}
end

-- ui values are normalized, so anything out of range or non-numeric falls back to the layer's own
local function readNormalized(value, fallback)
  value = tonumber(value)
  if not value then return fallback end
  return clamp(value, 0, 1)
end

-- shared with the decal editor, which paints the live projection instead of a committed layer
M.getVehiclePaintPresets = getVehiclePaintPresets
M.readNormalized = readNormalized

local function buildLayerPaint(layer)
  return {
    layerUid = layer.uid,
    color = layer.color and layer.color:toTable() or {1, 1, 1, 1},
    -- absent for fill layers, whose screen hides both material controls
    metallic = layer.metallicIntensity,
    roughness = layer.roughnessIntensity,
    presets = getVehiclePaintPresets(),
  }
end

local function findPaintLayer(layerUid, action)
  if not extensions.editor_api_dynamicDecals then return nil end

  if type(layerUid) ~= "string" then
    log("W", "liveries", string.format("can't %s layer paint, invalid layerUid '%s'", action, tostring(layerUid)))
    return nil
  end

  local layer = extensions.editor_api_dynamicDecals.getLayerByUid(layerUid)
  if not layer then
    log("W", "liveries", string.format("can't %s layer paint, no layer with uid '%s'", action, tostring(layerUid)))
    return nil
  end

  return layer
end

M.getLayerPaint = function(layerUid)
  local layer = findPaintLayer(layerUid, "read")
  if not layer then return nil end

  return buildLayerPaint(layer)
end

-- the new values are applied to a copy of the layer, so the api's history don't get affected
M.setLayerPaint = function(layerUid, paint)
  local layer = findPaintLayer(layerUid, "update")
  if not layer then return false end

  if type(paint) ~= "table" then
    log("W", "liveries", "can't update layer paint, no paint data given")
    return false
  end

  local updatedLayer = deepcopy(layer)
  local color = type(paint.color) == "table" and paint.color or {}
  local currentColor = layer.color and layer.color:toTable() or {1, 1, 1, 1}

  updatedLayer.color = Point4F(
    readNormalized(color[1], currentColor[1]),
    readNormalized(color[2], currentColor[2]),
    readNormalized(color[3], currentColor[3]),
    readNormalized(color[4], currentColor[4])
  )

  -- a layer bound to a color palette slot ignores its own color, so editing it here makes it custom
  if updatedLayer.colorPaletteMapId ~= nil then
    updatedLayer.colorPaletteMapId = M.EDITABLE_COLOR_PALETTE_MAP_ID
  end

  -- fill layers have no material intensities, so they are only updated where the layer has them
  if updatedLayer.metallicIntensity ~= nil then
    updatedLayer.metallicIntensity = readNormalized(paint.metallic, updatedLayer.metallicIntensity)
  end

  if updatedLayer.roughnessIntensity ~= nil then
    updatedLayer.roughnessIntensity = readNormalized(paint.roughness, updatedLayer.roughnessIntensity)
  end

  extensions.editor_api_dynamicDecals.setLayer(updatedLayer, true)
  return true
end

return M
