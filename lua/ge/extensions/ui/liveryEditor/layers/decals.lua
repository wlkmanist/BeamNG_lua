local M = {}

local api = extensions.editor_api_dynamicDecals
local camera = extensions.ui_liveryEditor_camera
local selection = extensions.ui_liveryEditor_selection
local uiUtils = extensions.ui_liveryEditor_utils

local ACTIONS = {"transform", "material", "order", "duplicate", "mirror", "rename", "visibility", "lock", "delete"}
local MEASUREMENTS = {
  TRANSLATE_STEP_UNIT = 0.1,
  ROTATE_STEP_UNIT = 1,
  SCALE_STEP_UNIT = 0.1,
  SKEW_STEP_UNIT = 0.1
}

local getLayerActions = function()
  return ACTIONS
end

local translateX = function(layer, steps)
  local coordinatesOrientation = camera.getOrientationCoordinates()
  local diff = steps * MEASUREMENTS.TRANSLATE_STEP_UNIT

  if coordinatesOrientation.x.index == 1 then
    layer.decalPos.x = coordinatesOrientation.x.inverted and layer.decalPos.x - diff or layer.decalPos.x + diff
  elseif coordinatesOrientation.x.index == 2 then
    layer.decalPos.y = coordinatesOrientation.x.inverted and layer.decalPos.y - diff or layer.decalPos.y + diff
  elseif coordinatesOrientation.x.index == 3 then
    layer.decalPos.z = coordinatesOrientation.x.inverted and layer.decalPos.z - diff or layer.decalPos.z + diff
  end

  api.setLayer(layer, true)
end

local translateY = function(layer, steps)
  local coordinatesOrientation = camera.getOrientationCoordinates()
  local diff = steps * MEASUREMENTS.TRANSLATE_STEP_UNIT

  if coordinatesOrientation.y.index == 1 then
    layer.decalPos.x = coordinatesOrientation.y.inverted and layer.decalPos.x - diff or layer.decalPos.x + diff
  elseif coordinatesOrientation.y.index == 2 then
    layer.decalPos.y = coordinatesOrientation.y.inverted and layer.decalPos.y - diff or layer.decalPos.y + diff
  elseif coordinatesOrientation.y.index == 3 then
    layer.decalPos.z = coordinatesOrientation.y.inverted and layer.decalPos.z - diff or layer.decalPos.z + diff
  end

  api.setLayer(layer, true)
end

local scaleX = function(layer, steps)
  local diff = steps * MEASUREMENTS.SCALE_STEP_UNIT
  local oldScale = layer.decalScale
  layer.decalScale = vec3(oldScale.x + diff, oldScale.y, oldScale.z)
  api.setLayer(layer, true)
end

local scaleY = function(layer, steps)
  local diff = steps * MEASUREMENTS.SCALE_STEP_UNIT
  local oldScale = layer.decalScale
  dump(oldScale)
  layer.decalScale = vec3(oldScale.x, 1, oldScale.z + diff)
  api.setLayer(layer, true)
end

local skewX = function(layer, steps)
  local diff = steps * MEASUREMENTS.SCALE_STEP_UNIT
  layer.decalSkew = Point2F(layer.decalSkew.x + diff, layer.decalSkew.y)
  api.setLayer(layer, true)
end

local skewY = function(layer, steps)
  local diff = steps * MEASUREMENTS.SCALE_STEP_UNIT
  layer.decalSkew = Point2F(layer.decalSkew.x, layer.decalSkew.y + diff)
  api.setLayer(layer, true)
end

local showCursor = function(enable)
  local alpha = enable and 1 or 0
  local color = api.getDecalColor()

  api.setDecalColor(Point4F(color.x, color.y, color.z, alpha))
end

M.createDecal = function(params)
  if params and params.texture then
    api.setDecalTexturePath("color", params.texture)
  end

  if params and params.color then
    local color = params.color
    api.setDecalColor(Point4F(color[1], color[2], color[3], color[4]))
  else
    api.setDecalColor(Point4F(1, 1, 1, 1))
  end

  local decal = api.addDecal()

  showCursor(false)

  return decal
end

M.translate = function(layer, steps_x, steps_y)
  if steps_x and steps_x ~= 0 then
    translateX(layer, steps_x)
  end

  if steps_y and not steps_y ~= 0 then
    translateY(layer, steps_y)
  end
end

M.rotate = function(layer, degrees, counterClockwise)
  local steps = degrees * MEASUREMENTS.ROTATE_STEP_UNIT
  local rads = uiUtils.convertDegreesToRadians(steps) * (counterClockwise and -1 or 1)
  layer.decalRotation = layer.decalRotation - rads

  api.setLayer(layer, true)
end

M.setRotation = function(layer, degrees)
  layer.decalRotation = uiUtils.convertDegreesToRadians(degrees)
  api.setLayer(layer, true)
end

M.scale = function(layer, steps_x, steps_y)
  if steps_x and steps_x ~= 0 then
    scaleX(layer, steps_x)
  end

  if steps_y and not steps_y ~= 0 then
    scaleY(layer, steps_y)
  end
end

M.setScale = function(layer, scaleX, scaleY)
  layer.decalScale = vec3(scaleX, layer.decalScale.y, scaleY)
  api.setLayer(layer, true)
end

M.skew = function(layer, stepsX, stepsY)
  if stepsX and stepsX ~= 0 then
    skewX(layer, stepsX)
  end

  if stepsY and not stepsY ~= 0 then
    skewY(layer, stepsY)
  end
end

M.setSkew = function(layer, skewX, skewY)
  layer.decalSkew = Point2F(skewX, skewY)
  api.setLayer(layer, true)
end

M.showCursor = showCursor
M.getLayerActions = getLayerActions
M.translateX = translateX
M.translateY = translateY

return M
