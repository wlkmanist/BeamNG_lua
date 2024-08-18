M = {}

local api = extensions.editor_api_dynamicDecals

local ACTIONS = {"material", "order", "rename", "visibility", "lock", "delete"}
local PRESET_ACTIONS = {"order", "rename", "visibility", "delete"}

local getLayerActions = function(layer)
  if not layer and layer.colorPaletteMapId == 0 then
    return ACTIONS
  end
  return PRESET_ACTIONS
end

M.getLayerActions = getLayerActions

M.getColorPaletteDataById = function(colorPaletteId)
  dump("getColorPaletteById", colorPaletteId)
  local palettes = M.getColorPalettes()

  for k, palette in ipairs(palettes) do
    if palette.value == colorPaletteId then
      return palette
    end
  end
end

M.getColorPalettes = function()
  local colorPaletteMap = api.propertiesMap["fill_colorPaletteMapId"]
  local vehicleObj = getPlayerVehicle(0)

  local colorPalettes = {}

  for i = colorPaletteMap.min, colorPaletteMap.max do
    local colorPaletteMapColor
    local label

    if i == 0 then
      label = "Custom Palette"
      colorPaletteMapColor = api.getFillLayerColor()
    elseif i == 1 then
      colorPaletteMapColor = vehicleObj.color
    elseif i == 2 then
      colorPaletteMapColor = vehicleObj.colorPalette0
    elseif i == 3 then
      colorPaletteMapColor = vehicleObj.colorPalette1
    end

    local color = colorPaletteMapColor:toTable()
    local rgba255Color = {color[1] * 255, color[2] * 255, color[3] * 255, color[4]}

    table.insert(colorPalettes, {
      label = label or "Paint "..tostring(i + 1),
      color = color,
      color255 = rgba255Color,
      value = i
    })
  end

  return colorPalettes
end

M.createLayer = function(params)
  api.setFillLayerColorPaletteMapId(params.colorPaletteMapId)

  if params.colorPaletteMapId == 0 and params.color then
    local color = Point4F.fromTable(params.color)
    api.setFillLayerColor(color)
  end

  api.addFillLayer()
end

return M
