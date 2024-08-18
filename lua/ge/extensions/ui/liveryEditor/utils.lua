local M = {}

-- local api = extensions.editor_api_dynamicDecals
-- local uiCameraApi = extensions.ui_liveryEditor_camera

local convertRadiansToDegrees = function(radians)
  local value = radians * (180 / math.pi)
  return math.floor(value + 0.5)
end

local convertDegreesToRadians = function(degrees)
  local radians = degrees * (math.pi / 180)
  local truncated = string.format("%.14f", radians)
  return tonumber(radians)
end

local roundAndTruncateDecimal = function(number, decimals)
  -- local rounded = math.floor(number * 10 + 0.5) / 10
  -- return math.floor(rounded * 10) / 10
  decimals = decimals or 1

  local scale = 10 ^ decimals
  local rounded = math.ceil(number * scale - 0.5) / scale
  return rounded
end

local getXYCoordinates = function(decalPos, coordinates)
  local decalPosTable = decalPos:toTable()
  local x = decalPosTable[coordinates.x.index]
  local y = decalPosTable[coordinates.y.index]

  return {
    x = roundAndTruncateDecimal(x, 3),
    y = roundAndTruncateDecimal(y, 3)
  }
end

local getActionMapNameByTool = function(tool)
  log("D", "", "getActionMapNameByTool" .. tool)
  local tools = extensions.ui_liveryEditor_tools.TOOLS
  local actionMaps = extensions.ui_liveryEditor_controls
  if tool == tools.TRANSLATE or tool == tools.ROTATE then
    return actionMaps.TRANSFORM
  elseif tool == tools.SCALE or tool == tools.SKEW then
    return actionMaps.DEFORM
  elseif tool == tools.MATERIAL then
    return actionMaps.MATERIAL
  end
end

M.roundAndTruncateDecimal = roundAndTruncateDecimal
M.getXYCoordinates = getXYCoordinates
M.getActionMapNameByTool = getActionMapNameByTool
M.convertDegreesToRadians = convertDegreesToRadians
M.convertRadiansToDegrees = convertRadiansToDegrees

return M
