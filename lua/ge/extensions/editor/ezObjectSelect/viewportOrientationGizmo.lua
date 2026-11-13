-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local backgroundColor = im.GetColorU322(im.ImVec4(0.02, 0.03, 0.04, 0.72))
local centerColor = im.GetColorU322(im.ImVec4(0.85, 0.88, 0.92, 1))
local textColor = im.GetColorU322(im.ImVec4(0.03, 0.03, 0.03, 1))
local modeTextColor = im.GetColorU322(im.ImVec4(1, 1, 1, 1))
local axes = {
  {
    name = "X",
    direction = vec3(1, 0, 0),
    color = im.GetColorU322(im.ImVec4(1, 0.25, 0.25, 1)),
    backColor = im.GetColorU322(im.ImVec4(0.55, 0.16, 0.16, 0.8))
  },
  {
    name = "Y",
    direction = vec3(0, 1, 0),
    color = im.GetColorU322(im.ImVec4(0.25, 1, 0.35, 1)),
    backColor = im.GetColorU322(im.ImVec4(0.16, 0.55, 0.22, 0.8))
  },
  {
    name = "Z",
    direction = vec3(0, 0, 1),
    color = im.GetColorU322(im.ImVec4(0.3, 0.58, 1, 1)),
    backColor = im.GetColorU322(im.ImVec4(0.18, 0.32, 0.58, 0.8))
  }
}

local function endpoint(
  center,
  axis,
  direction,
  cameraRight,
  cameraUp,
  cameraForward,
  radius,
  sign)
  return {
    position = im.ImVec2(
      center.x + direction:dot(cameraRight) * radius * sign,
      center.y - direction:dot(cameraUp) * radius * sign),
    depth = direction:dot(cameraForward) * sign,
    axis = axis,
    positive = sign > 0
  }
end

function M.draw(rightOffset, topOffset, localObjectId)
  local viewport = im.GetMainViewport()
  local scale = im.uiscale[0]
  local radius = 34 * scale
  local centerY = viewport.Pos.y + (topOffset or 64) * scale
  local rightEdge = editor.getSceneViewportRightEdge and editor.getSceneViewportRightEdge(centerY)
    or viewport.Pos.x + viewport.Size.x
  local center = im.ImVec2(
    rightEdge - (rightOffset or 64) * scale,
    centerY)
  local rotation = core_camera.getQuat()
  local cameraRight = rotation * vec3(1, 0, 0)
  local cameraUp = rotation * vec3(0, 0, 1)
  local cameraForward = rotation * vec3(0, 1, 0)
  local directions = {
    X = vec3(1, 0, 0),
    Y = vec3(0, 1, 0),
    Z = vec3(0, 0, 1)
  }
  local obj = localObjectId and scenetree.findObjectById(localObjectId) or nil
  local localApplied = false
  if obj and obj.getTransform then
    localApplied = true
    local transform = obj:getTransform()
    for index, name in ipairs({"X", "Y", "Z"}) do
      local direction = vec3(transform:getColumn(index - 1))
      local length = direction:length()
      if length > 0.0001 then directions[name] = direction / length end
    end
  end
  local endpoints = {}
  for _, axis in ipairs(axes) do
    endpoints[#endpoints + 1] = endpoint(
      center, axis, directions[axis.name], cameraRight, cameraUp, cameraForward, radius, -1)
    endpoints[#endpoints + 1] = endpoint(
      center, axis, directions[axis.name], cameraRight, cameraUp, cameraForward, radius, 1)
  end
  table.sort(endpoints, function(first, second) return first.depth > second.depth end)

  local drawList = im.GetForegroundDrawList2(viewport)
  im.ImDrawList_AddCircleFilled(drawList, center, 48 * scale, backgroundColor, 48)
  local modeText = localApplied and "L" or "W"
  local modePosition = im.ImVec2(center.x + 25 * scale, center.y + 25 * scale)
  local modeTextSize = im.CalcTextSize(modeText)
  im.ImDrawList_AddText1(
    drawList,
    im.ImVec2(
      modePosition.x - modeTextSize.x * 0.5,
      modePosition.y - modeTextSize.y * 0.5),
    modeTextColor,
    modeText,
    nil)
  for _, entry in ipairs(endpoints) do
    local color = entry.positive and entry.axis.color or entry.axis.backColor
    im.ImDrawList_AddLine(
      drawList,
      center,
      entry.position,
      color,
      entry.positive and 3 * scale or 2 * scale)
    im.ImDrawList_AddCircleFilled(
      drawList,
      entry.position,
      (entry.positive and 9 or 5) * scale,
      color,
      24)
    if entry.positive then
      local textSize = im.CalcTextSize(entry.axis.name)
      im.ImDrawList_AddText1(
        drawList,
        im.ImVec2(
          entry.position.x - textSize.x * 0.5,
          entry.position.y - textSize.y * 0.5),
        textColor,
        entry.axis.name,
        nil)
    end
  end
  im.ImDrawList_AddCircleFilled(drawList, center, 4 * scale, centerColor, 16)
end

return M
