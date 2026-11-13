-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui

-- these must stay in sync with engine::Ease::enumDirection and engine::Ease::enumType, the
-- names are listed in the enum order, so the value of a name is its index - 1
local dirNames = {"InOut", "In", "Out"}
local typeNames = {"Linear", "Quadratic", "Cubic", "Quartic", "Quintic", "Sinusoidal", "Exponential", "Circular", "Elastic", "Back", "Bounce"}
local typeElastic = 8
local typeBack = 9
local defaultParam = -1

local previewSampleCount = 64
local thumbSampleCount = 32
local pickerListHeight = 400

local comboValue = im.IntPtr(0)
local paramValue = {im.FloatPtr(0), im.FloatPtr(0)}
local editEnded = im.BoolPtr(false)
local curveColor = im.ImVec4(1, 1, 1, 1)
local selectedCurveColor = im.ImVec4(1, 0.5, 0, 1)
local thumbCurves = {}
local thumbCurvesParamKey

local function clampIndex(value, names)
  if not value or value < 0 or value > #names - 1 then return 0 end
  return value
end

local function parseValue(value)
  local tbl = stringToTable(value or "")
  local dir = clampIndex(tonumber(tbl[1]), dirNames)
  local easeType = clampIndex(tonumber(tbl[2]), typeNames)
  local param0 = tonumber(tbl[3]) or defaultParam
  local param1 = tonumber(tbl[4]) or defaultParam

  return dir, easeType, param0, param1
end

local function formatValue(dir, easeType, param0, param1)
  return string.format("%d %d %g %g", dir, easeType, param0, param1)
end

local function curveName(dir, easeType)
  if easeType == 0 then return typeNames[1] end
  return dirNames[dir + 1] .. " " .. typeNames[easeType + 1]
end

local function getSamples(dir, easeType, param0, param1, sampleCount)
  return worldEditorCppApi.getEaseCurveSamples(dir, easeType, param0, param1, sampleCount)
end

-- the ease params only affect the Elastic and Back curves, so the thumbnails are only
-- resampled when those params change
local function getThumbCurves(param0, param1)
  local paramKey = string.format("%g %g", param0, param1)
  if thumbCurvesParamKey ~= paramKey then
    thumbCurvesParamKey = paramKey
    thumbCurves = {}
    for dir = 0, #dirNames - 1 do
      for easeType = 0, #typeNames - 1 do
        thumbCurves[dir .. " " .. easeType] = getSamples(dir, easeType, param0, param1, thumbSampleCount)
      end
    end
  end

  return thumbCurves
end

-- Elastic and Back overshoot the 0..1 range, so the plot is scaled to fit the whole curve
local function plotCurve(id, samples, size, overlayText)
  local minValue, maxValue = 0, 1
  for i = 1, #samples do
    minValue = math.min(minValue, samples[i])
    maxValue = math.max(maxValue, samples[i])
  end
  local padding = (maxValue - minValue) * 0.05

  im.PushStyleColor2(im.Col_PlotLines, curveColor)
  im.PlotLines1(id, samples, #samples, 0, overlayText, minValue - padding, maxValue + padding, size)
  im.PopStyleColor()
end

local function curvePicker(id, dir, easeType, param0, param1)
  local picked

  if im.BeginPopup("easeCurvePicker" .. id) then
    local curves = getThumbCurves(param0, param1)
    local style = im.GetStyle()
    local uiScale = im.uiscale[0]
    local thumbSize = im.ImVec2(130 * uiScale, 44 * uiScale)
    local listSize = im.ImVec2(
      #dirNames * thumbSize.x + (#dirNames - 1) * style.ItemSpacing.x + style.ScrollbarSize + style.WindowPadding.x,
      pickerListHeight * uiScale)

    im.TextUnformatted("Click a curve to use it")
    im.Separator()
    im.BeginChild1("easeCurvePickerList" .. id, listSize)

    for curveType = 0, #typeNames - 1 do
      for curveDir = 0, #dirNames - 1 do
        if curveDir > 0 then im.SameLine() end
        plotCurve("##easeThumb" .. id .. curveDir .. " " .. curveType,
          curves[curveDir .. " " .. curveType], thumbSize, curveName(curveDir, curveType))

        local rectMin = im.GetItemRectMin()
        local rectMax = im.GetItemRectMax()

        if curveDir == dir and curveType == easeType then
          im.ImDrawList_AddRect(im.GetWindowDrawList(), rectMin, rectMax,
            im.GetColorU322(selectedCurveColor), 0, 0, 2 * uiScale)
        end
        if im.IsMouseHoveringRect(rectMin, rectMax) and im.IsMouseClicked(0) then
          picked = {dir = curveDir, type = curveType}
        end
      end
    end

    im.EndChild()
    if picked then im.CloseCurrentPopup() end
    im.EndPopup()
  end

  return picked
end

local function paramSlider(id, index, label, maxValue, value)
  paramValue[index][0] = value
  local changed = editor.uiSliderFloat("##easeParam" .. index .. id, paramValue[index], defaultParam, maxValue,
    label .. ": %0.2f", nil, editEnded)
  im.tooltip(label .. " of the curve, " .. defaultParam .. " uses the curve default")

  if changed or editEnded[0] then
    return paramValue[index][0], editEnded[0]
  end

  return nil
end

-- opts:
--   id          unique string id
--   value       the EaseF value as the "dir type param0 param1" string
--   setValue(valueString, editEnded)
local function draw(opts)
  local id = opts.id
  local dir, easeType, param0, param1 = parseValue(opts.value)
  local comboWidth = (im.GetContentRegionAvailWidth() - im.GetStyle().ItemSpacing.x) / 2

  comboValue[0] = dir
  im.SetNextItemWidth(comboWidth)
  if im.Combo1("##easeDir" .. id, comboValue, dirNames, #dirNames) then
    opts.setValue(formatValue(comboValue[0], easeType, param0, param1), true)
  end
  im.tooltip("Easing direction")

  im.SameLine()
  comboValue[0] = easeType
  im.SetNextItemWidth(comboWidth)
  if im.Combo1("##easeType" .. id, comboValue, typeNames, #typeNames) then
    opts.setValue(formatValue(dir, comboValue[0], param0, param1), true)
  end
  im.tooltip("Easing curve type")

  plotCurve("##easePreview" .. id, getSamples(dir, easeType, param0, param1, previewSampleCount),
    im.ImVec2(im.GetContentRegionAvailWidth(), 60 * im.uiscale[0]), curveName(dir, easeType))

  if im.IsMouseHoveringRect(im.GetItemRectMin(), im.GetItemRectMax()) then
    im.SetTooltip("Click to pick another curve")
    if im.IsMouseClicked(0) then
      im.OpenPopup("easeCurvePicker" .. id)
    end
  end

  local picked = curvePicker(id, dir, easeType, param0, param1)
  if picked then
    opts.setValue(formatValue(picked.dir, picked.type, param0, param1), true)
  end

  -- the params are only used by the Elastic and Back curves, -1 means the curve default
  if easeType == typeElastic then
    local amplitude, amplitudeEnded = paramSlider(id, 1, "Amplitude", 2, param0)
    if amplitude then
      opts.setValue(formatValue(dir, easeType, amplitude, param1), amplitudeEnded)
    end
    local period, periodEnded = paramSlider(id, 2, "Period", 2, param1)
    if period then
      opts.setValue(formatValue(dir, easeType, param0, period), periodEnded)
    end
  elseif easeType == typeBack then
    local overshoot, overshootEnded = paramSlider(id, 1, "Overshoot", 5, param0)
    if overshoot then
      opts.setValue(formatValue(dir, easeType, overshoot, param1), overshootEnded)
    end
  end
end

M.draw = draw

return M
