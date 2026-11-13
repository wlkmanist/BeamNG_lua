-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local panelBackground = im.GetColorU322(im.ImVec4(0.02, 0.03, 0.04, 0.9))
local panelText = im.GetColorU322(im.ImVec4(1, 1, 1, 1))

local function drawLabel(drawList, position, text, color, topLeftAligned)
  local textSize = im.CalcTextSize(text)
  local topLeft
  if topLeftAligned then
    topLeft = im.ImVec2(position.x, position.y)
  else
    topLeft = im.ImVec2(
      position.x - textSize.x * 0.5 - 7,
      position.y - textSize.y - 10)
  end
  local bottomRight = im.ImVec2(topLeft.x + textSize.x + 14, topLeft.y + textSize.y + 8)
  im.ImDrawList_AddRectFilled(drawList, topLeft, bottomRight, panelBackground, 4)
  im.ImDrawList_AddRect(drawList, topLeft, bottomRight, color, 4, 0, 2)
  im.ImDrawList_AddText1(
    drawList,
    im.ImVec2(topLeft.x + 7, topLeft.y + 4),
    panelText,
    text,
    nil)
  return bottomRight, textSize
end

local function followMetrics(labels)
  local totalHeight, maxWidth = 0, 0
  for _, label in ipairs(labels) do
    if label.followMouse then
      local textSize = im.CalcTextSize(label.text)
      totalHeight = totalHeight + textSize.y + 12
      maxWidth = math.max(maxWidth, textSize.x + 14)
    end
  end
  return totalHeight, maxWidth
end

local function drawFollowLabels(drawList, labels, mouse, viewport, priority)
  local totalHeight, maxWidth = followMetrics(labels)
  local viewportRight = viewport.Pos.x + viewport.Size.x
  local viewportBottom = viewport.Pos.y + viewport.Size.y
  local x = mouse.x + 18
  if x + maxWidth > viewportRight - 6 then x = mouse.x - maxWidth - 18 end
  local y = math.min(mouse.y + 18, viewportBottom - totalHeight - 6)
  y = math.max(y, viewport.Pos.y + 6)

  for _, label in ipairs(labels) do
    if label.followMouse and (label.priority == true) == priority then
      local bottomRight = drawLabel(
        drawList,
        im.ImVec2(x, y),
        label.text,
        label.color,
        true)
      y = bottomRight.y + 4
    end
  end
  return y
end

function M.draw(drawList, labels, mouse, viewport)
  local nextY = drawFollowLabels(drawList, labels, mouse, viewport, true)
  local hasPriority = false
  for _, label in ipairs(labels) do
    if label.followMouse and label.priority then
      hasPriority = true
      break
    end
  end
  if hasPriority then
    local totalHeight, maxWidth = followMetrics(labels)
    local viewportRight = viewport.Pos.x + viewport.Size.x
    local x = mouse.x + 18
    if x + maxWidth > viewportRight - 6 then x = mouse.x - maxWidth - 18 end
    for _, label in ipairs(labels) do
      if label.followMouse and not label.priority then
        local bottomRight = drawLabel(
          drawList,
          im.ImVec2(x, nextY),
          label.text,
          label.color,
          true)
        nextY = bottomRight.y + 4
      end
    end
  else
    drawFollowLabels(drawList, labels, mouse, viewport, false)
  end

  for _, label in ipairs(labels) do
    if not label.followMouse then
      drawLabel(drawList, label.position, label.text, label.color, false)
    end
  end
end

return M
