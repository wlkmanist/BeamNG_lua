-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--- ImGui draw-list plotting for the AI Competitors mixture preview.

local im = ui_imgui

local M = {}

local plotHeightPixels = 300
local paddingLeft = 60
local paddingRight = 12
local paddingTop = 20
local paddingBottom = 40
local gridDivisionsX = 20
local gridDivisionsY = 10

local outcomeLineColors = {
  im.ImVec4(0x58 / 255, 0xa6 / 255, 0xff / 255, 1),
  im.ImVec4(0xff / 255, 0xa6 / 255, 0x57 / 255, 1),
  im.ImVec4(0x3f / 255, 0xb9 / 255, 0x50 / 255, 1),
  im.ImVec4(0xf8 / 255, 0x51 / 255, 0x49 / 255, 1),
  im.ImVec4(0x8b / 255, 0x94 / 255, 0x9e / 255, 1),
}

local mixtureHighlightColor = im.ImVec4(0xf0 / 255, 0xf6 / 255, 0xfc / 255, 1)

local function rgbaToImU32(red, green, blue, alpha)
  return im.GetColorU322(im.ImVec4(red, green, blue, alpha or 1))
end

local function drawSamplePolyline(drawList, originX, originY, plotWidth, plotHeight, samples, densityMaxY, colorU32, lineThickness)
  if densityMaxY <= 0 then
    densityMaxY = 1e-12
  end
  local count = #samples
  if count < 2 then
    return
  end
  for index = 2, count do
    local x1 = originX + plotWidth * (index - 2) / (count - 1)
    local x2 = originX + plotWidth * (index - 1) / (count - 1)
    local y1 = originY + plotHeight * (1 - samples[index - 1] / densityMaxY)
    local y2 = originY + plotHeight * (1 - samples[index] / densityMaxY)
    drawList:AddLine(im.ImVec2(x1, y1), im.ImVec2(x2, y2), colorU32, lineThickness)
  end
end

local function drawGridAndAxes(drawList, originX, originY, plotWidth, plotHeight, timeLo, timeHi, densityMaxY, axisLabel)
  local gridColor = rgbaToImU32(0.42, 0.42, 0.45, 0.55)
  local axisColor = rgbaToImU32(0.55, 0.55, 0.58, 0.95)
  local textColor = rgbaToImU32(0.75, 0.78, 0.82, 1)

  for gridX = 0, gridDivisionsX do
    local x = originX + plotWidth * (gridX / gridDivisionsX)
    drawList:AddLine(im.ImVec2(x, originY), im.ImVec2(x, originY + plotHeight), gridColor, 1)
  end
  for gridY = 0, gridDivisionsY do
    local y = originY + plotHeight * (gridY / gridDivisionsY)
    drawList:AddLine(im.ImVec2(originX, y), im.ImVec2(originX + plotWidth, y), gridColor, 1)
  end
  drawList:AddRect(im.ImVec2(originX, originY), im.ImVec2(originX + plotWidth, originY + plotHeight), axisColor, 0, 0, 1.25)

  local timeSpan = timeHi - timeLo
  for gridX = 0, gridDivisionsX, 2 do
    local t = timeLo + timeSpan * (gridX / gridDivisionsX)
    local x = originX + plotWidth * (gridX / gridDivisionsX)
    local label
    if timeSpan >= 100 then
      label = string.format("%.0f", t)
    elseif timeSpan >= 10 then
      label = string.format("%.1f", t)
    else
      label = string.format("%.2f", t)
    end
    im.ImDrawList_AddText1(drawList, im.ImVec2(x - 12, originY + plotHeight + 4), textColor, label, nil)
  end

  if densityMaxY <= 0 then
    densityMaxY = 1e-12
  end
  local valueLabelAnchorX = originX - 6
  for gridY = 0, gridDivisionsY, 2 do
    local value = densityMaxY * (1 - gridY / gridDivisionsY)
    local y = originY + plotHeight * (gridY / gridDivisionsY) - 6
    local label = string.format("%.3g", value)
    im.ImDrawList_AddText1(drawList, im.ImVec2(valueLabelAnchorX - 44, y), textColor, label, nil)
  end

  im.ImDrawList_AddText1(
    drawList,
    im.ImVec2(originX + plotWidth * 0.5 - 48, originY + plotHeight + 20),
    textColor,
    axisLabel,
    nil
  )
end

local function drawOutcomeShareRow(im, visualization, outcomeLabels, outcomeColors, modelModule)
  im.Columns(modelModule.numOutcomes, "##aiCompetitorsProb", false)
  for outcomeIndex = 1, modelModule.numOutcomes do
    im.TextColored(outcomeColors[outcomeIndex], outcomeLabels[outcomeIndex] or modelModule.outcomeLabels[outcomeIndex])
    local percentText = string.format("%.2f", 100.0 * visualization.weights[outcomeIndex])
    im.Text(percentText)
    im.SameLine(0, 0)
    im.TextUnformatted(" %")
    im.NextColumn()
  end
  im.Columns(1)
end

local function drawFinishTimeChart(im, visualization, chartCopy)
  im.Spacing()
  local availableWidth = im.GetContentRegionAvailWidth()
  local plotSize = im.ImVec2(availableWidth, plotHeightPixels)
  local cursorScreenPos = im.GetCursorScreenPos()
  im.InvisibleButton("##mixtureChart", plotSize)
  local drawList = im.GetWindowDrawList()

  local originX = cursorScreenPos.x + paddingLeft
  local originY = cursorScreenPos.y + paddingTop
  local plotWidth = plotSize.x - paddingLeft - paddingRight
  local plotHeight = plotSize.y - paddingTop - paddingBottom
  if plotWidth < 48 or plotHeight < 48 then
    im.Text(chartCopy.plotTooSmall)
    return
  end

  local density = visualization.density
  local densityMaxY = visualization.yMax

  drawGridAndAxes(
    drawList,
    originX,
    originY,
    plotWidth,
    plotHeight,
    visualization.timeLo,
    visualization.timeHi,
    densityMaxY,
    chartCopy.axisLabel
  )

  drawList:PushClipRect(im.ImVec2(originX, originY), im.ImVec2(originX + plotWidth, originY + plotHeight), true)
  for outcomeIndex = 1, 4 do
    local color = outcomeLineColors[outcomeIndex]
    drawSamplePolyline(
      drawList,
      originX,
      originY,
      plotWidth,
      plotHeight,
      visualization.weightedComponents[outcomeIndex],
      densityMaxY,
      im.GetColorU322(color),
      1.2
    )
  end
  drawSamplePolyline(
    drawList,
    originX,
    originY,
    plotWidth,
    plotHeight,
    density.mixture,
    densityMaxY,
    im.GetColorU322(mixtureHighlightColor),
    2.4
  )
  drawList:PopClipRect()
end

M.outcomeLineColors = outcomeLineColors
M.drawOutcomeShareRow = drawOutcomeShareRow
M.drawFinishTimeChart = drawFinishTimeChart

return M
