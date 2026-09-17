-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local ffi = ffi
local CONSTANTS = require('tech/ros/constants')
local utilRos = require('tech/ros/util')
local fieldCatalog = require('editor/tech/ros/editorFieldCatalog')

local AXIS_LABEL_COLORS = fieldCatalog.AXIS_LABEL_COLORS
local AXIS_LETTERS_3 = { 'X', 'Y', 'Z' }
local AXIS_LETTERS_2 = { 'X', 'Y' }

local M = {}

function M.drawRosCategoryHeader(title)
  im.Dummy(im.ImVec2(0, 2))
  im.Separator()
  im.Dummy(im.ImVec2(0, 3))
  im.PushStyleColor2(im.Col_Text, im.ImVec4(0.72, 0.76, 0.84, 1))
  im.TextUnformatted(title)
  im.PopStyleColor()
  im.Dummy(im.ImVec2(0, 2))
end

local function classifyTemplateValue(value)
  local valueType = type(value)
  if valueType == 'boolean' then return 'bool' end
  if valueType == 'number' then return 'number' end
  if valueType == 'string' then return 'string' end
  if valueType ~= 'table' then return 'other' end
  local len = #value
  if len == 3 and type(value[1]) == 'number' and type(value[2]) == 'number' and type(value[3]) == 'number' then
    return 'vec3'
  end
  if len == 2 and type(value[1]) == 'number' and type(value[2]) == 'number' then
    return 'vec2'
  end
  return 'table'
end

-- Computes per-cell width for n labeled inputs sharing one row. labelWidth includes a small padding.
local function computeFieldWidth(labels, minWidth)
  local style = im.GetStyle()
  local available = im.GetContentRegionAvailWidth()
  local labelTotal = 0
  for _, label in ipairs(labels) do labelTotal = labelTotal + im.CalcTextSize(label).x + 4 end
  local n = #labels
  local rawWidth = (available - labelTotal - style.ItemSpacing.x * (n + 1)) / n
  return math.max(minWidth or 52, rawWidth)
end

-- Draws an N-component vector row (vec2 or vec3) with X/Y[/Z] labels in axis colors.
local function drawAxisRow(editorState, target, key, templateValue, idScope)
  local current = target[key]
  if current == nil then current = utilRos.deepCopy(templateValue) end
  local src = (type(current) == 'table') and current or templateValue
  local n = (#templateValue == 3) and 3 or 2
  local letters = (n == 3) and AXIS_LETTERS_3 or AXIS_LETTERS_2

  im.TextUnformatted(fieldCatalog.displayNameForConfigKey(key))
  fieldCatalog.setConfigKeyItemTooltip(key)

  local floatFormat = fieldCatalog.floatFormatString(editorState)
  local fieldWidth = computeFieldWidth(letters, 48)
  local stableId = idScope .. tostring(key)
  local out = {}
  for i = 1, n do out[i] = tonumber(src[i]) or 0 end

  for i = 1, n do
    if i > 1 then im.SameLine(0, 6) end
    im.TextColored(AXIS_LABEL_COLORS[i], letters[i])
    im.SameLine(0, 4)
    im.PushItemWidth(fieldWidth)
    local floatPtr = im.FloatPtr(out[i])
    im.InputFloat('##' .. stableId .. 'c' .. i, floatPtr, 0, 0, floatFormat)
    im.PopItemWidth()
    out[i] = floatPtr[0]
  end
  target[key] = out
end

-- Draws two custom-labeled floats stored as a 2-element array on `target[key]`.
function M.drawLabeledPairRow(editorState, target, key, templateValue, idScope, labelA, labelB, colorA, colorB)
  local current = target[key]
  if current == nil then current = utilRos.deepCopy(templateValue) end
  local src = (type(current) == 'table') and current or templateValue
  colorA = colorA or AXIS_LABEL_COLORS[1]
  colorB = colorB or AXIS_LABEL_COLORS[2]

  local floatFormat = fieldCatalog.floatFormatString(editorState)
  local fieldWidth = computeFieldWidth({ labelA, labelB }, 52)
  local stableId = idScope .. tostring(key)
  local valueA = tonumber(src[1]) or 0
  local valueB = tonumber(src[2]) or 0

  im.TextColored(colorA, labelA)
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local floatPtrA = im.FloatPtr(valueA)
  im.InputFloat('##' .. stableId .. 'p1', floatPtrA, 0, 0, floatFormat)
  im.PopItemWidth()

  im.SameLine(0, 10)
  im.TextColored(colorB, labelB)
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local floatPtrB = im.FloatPtr(valueB)
  im.InputFloat('##' .. stableId .. 'p2', floatPtrB, 0, 0, floatFormat)
  im.PopItemWidth()

  target[key] = { floatPtrA[0], floatPtrB[0] }
  fieldCatalog.setConfigKeyItemTooltip(key)
end

-- Draws two custom-labeled floats stored as separate scalar keys keyA / keyB.
function M.drawTwoScalarsRow(editorState, target, template, keyA, keyB, idScope, labelA, labelB, colorA, colorB)
  colorA = colorA or AXIS_LABEL_COLORS[1]
  colorB = colorB or AXIS_LABEL_COLORS[2]
  local floatFormat = fieldCatalog.floatFormatString(editorState)
  local fieldWidth = computeFieldWidth({ labelA, labelB }, 52)
  local valueA = tonumber(target[keyA]) or tonumber(template and template[keyA]) or 0
  local valueB = tonumber(target[keyB]) or tonumber(template and template[keyB]) or 0

  im.TextColored(colorA, labelA)
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local floatPtrA = im.FloatPtr(valueA)
  im.InputFloat('##' .. idScope .. keyA, floatPtrA, 0, 0, floatFormat)
  im.PopItemWidth()
  target[keyA] = floatPtrA[0]

  im.SameLine(0, 10)
  im.TextColored(colorB, labelB)
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local floatPtrB = im.FloatPtr(valueB)
  im.InputFloat('##' .. idScope .. keyB, floatPtrB, 0, 0, floatFormat)
  im.PopItemWidth()
  target[keyB] = floatPtrB[0]
end

function M.drawConfigKeyControl(editorState, createTable, key, templateValue, idScope)
  local valueType = classifyTemplateValue(templateValue)
  local current = createTable[key]
  if current == nil then current = utilRos.deepCopy(templateValue) end
  local label = fieldCatalog.displayNameForConfigKey(key) .. '##' .. idScope .. tostring(key)

  if valueType == 'vec3' or valueType == 'vec2' then
    drawAxisRow(editorState, createTable, key, templateValue, idScope)
  elseif valueType == 'bool' then
    local boolPtr = im.BoolPtr(current == true)
    im.Checkbox(label, boolPtr)
    createTable[key] = boolPtr[0]
    fieldCatalog.setConfigKeyItemTooltip(key)
  elseif valueType == 'number' then
    local floatPtr = im.FloatPtr(tonumber(current) or tonumber(templateValue) or 0)
    im.InputFloat(label, floatPtr, 0, 0, fieldCatalog.floatFormatString(editorState))
    createTable[key] = floatPtr[0]
    fieldCatalog.setConfigKeyItemTooltip(key)
  elseif valueType == 'string' then
    local charBuffer = im.ArrayChar(CONSTANTS.ROS_EDITOR_IMGUI_TEXT_BUFFER, tostring(current or templateValue or ''))
    im.InputText(label, charBuffer, CONSTANTS.ROS_EDITOR_IMGUI_TEXT_BUFFER)
    createTable[key] = ffi.string(charBuffer)
    fieldCatalog.setConfigKeyItemTooltip(key)
  else
    im.TextDisabled(string.format('%s (complex type - use template file)', key))
  end
end

return M
