-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local numericInput = require("editor/ezObjectSelect/transformNumericInput")
local selectionGeometry = require("editor/ezObjectSelect/selectionGeometry")
local transformSession = require("editor/ezObjectSelect/transformSession")

local xKey = im.GetKeyIndex(im.Key_X)
local yKey = im.GetKeyIndex(im.Key_Y)
local zKey = im.GetKeyIndex(im.Key_Z)
local enterKey = im.GetKeyIndex(im.Key_Enter)
local keypadEnterKey = im.GetKeyIndex(im.Key_KeypadEnter)
local escapeKey = im.GetKeyIndex(im.Key_Escape)
local overlayBackground = im.GetColorU322(im.ImVec4(0.02, 0.03, 0.04, 0.9))
local overlayText = im.GetColorU322(im.ImVec4(1, 1, 1, 1))
local hintColor = im.GetColorU322(im.ImVec4(1, 1, 1, 0.9))

function M.normalized(vector, fallback)
  local result = vec3(vector)
  local length = result:length()
  return length > 0.0001 and result / length or vec3(fallback)
end

function M.currentRay()
  local ray = getCameraMouseRay()
  if not ray then return nil end
  return {
    origin = vec3(ray.pos),
    direction = M.normalized(ray.dir, vec3(0, 1, 0))
  }
end

function M.rayPlanePoint(ray, planePoint, planeNormal)
  if not ray then return nil end
  local denominator = ray.direction:dot(planeNormal)
  if math.abs(denominator) <= 0.0001 then return nil end
  local distance = (planePoint - ray.origin):dot(planeNormal) / denominator
  return ray.origin + ray.direction * distance
end

function M.begin(options)
  options = options or {}
  local selection = editor.selection.object or {}
  local anchorId = selection[#selection]
  local anchor = anchorId and scenetree.findObjectById(anchorId) or nil
  local camera = selectionGeometry.createCameraContext()
  local ray = M.currentRay()
  if not anchor or not camera or not ray
    or not transformSession.begin(anchor, {historyName = options.historyName}) then
    return nil
  end

  if editor.computeSelectionBBox then editor.computeSelectionBBox() end
  local pivot = selectionGeometry.validBox(editor.objectSelectionBBox)
    and vec3(editor.objectSelectionBBox:getCenter())
    or vec3(anchor:getPosition())
  local transform = anchor:getTransform()
  return {
    pivot = pivot,
    camera = camera,
    startRay = ray,
    startMouse = im.GetMousePos(),
    worldAxes = {
      x = vec3(1, 0, 0),
      y = vec3(0, 1, 0),
      z = vec3(0, 0, 1)
    },
    localAxes = {
      x = M.normalized(transform:getColumn(0), vec3(1, 0, 0)),
      y = M.normalized(transform:getColumn(1), vec3(0, 1, 0)),
      z = M.normalized(transform:getColumn(2), vec3(0, 0, 1))
    },
    constraint = nil,
    defaultLocal = options.defaultLocal == true,
    numeric = numericInput.newState()
  }
end

function M.updateConstraint(state, allowExclude)
  local axis
  if im.IsKeyPressed(xKey) then axis = "x" end
  if im.IsKeyPressed(yKey) then axis = "y" end
  if im.IsKeyPressed(zKey) then axis = "z" end
  if not axis then return false end
  local exclude = allowExclude and editor.keyModifiers.shift == true
  if state.constraint
    and state.constraint.axis == axis
    and state.constraint.exclude == exclude then
    state.constraint.localSpace = not state.constraint.localSpace
  else
    state.constraint = {
      axis = axis,
      exclude = exclude,
      localSpace = state.defaultLocal
    }
  end
  return true
end

function M.setLocalSpace(state, localSpace)
  if not state then return false end
  state.defaultLocal = localSpace == true
  if state.constraint then state.constraint.localSpace = state.defaultLocal end
  state.ignoreTopRowFour = true
  return true
end

function M.axes(state)
  return state.constraint and state.constraint.localSpace and state.localAxes
    or state.worldAxes
end

function M.activeAxis(state)
  if not state.constraint then return nil end
  return M.axes(state)[state.constraint.axis]
end

function M.updateNumeric(state)
  numericInput.update(state.numeric, state.ignoreTopRowFour)
  state.ignoreTopRowFour = false
  return numericInput.value(state.numeric)
end

function M.finishRequested()
  if im.IsKeyPressed(escapeKey) or im.IsMouseClicked(1) then return "cancel" end
  if im.IsKeyPressed(enterKey)
    or im.IsKeyPressed(keypadEnterKey)
    or (im.IsMouseClicked(0) and editor.isViewportHovered()) then
    return "confirm"
  end
end

function M.finish(result)
  local completion
  if result == "confirm" then
    local committed
    committed, completion = transformSession.finish()
    if committed == nil then
      M.setInteractionCursorHidden(false)
      return "cancel"
    end
  else
    transformSession.cancel()
  end
  M.setInteractionCursorHidden(false)
  return result, completion
end

function M.projectToScreen(camera, point)
  local relative = vec3(point) - camera.pos
  local depth = relative:dot(camera.forward)
  if depth <= 0.0001 then return nil end
  local x = relative:dot(camera.right) / (depth * camera.halfTan * camera.aspect)
  local y = relative:dot(camera.up) / (depth * camera.halfTan)
  return im.ImVec2(
    camera.viewportX + camera.width * (0.5 + x * 0.5),
    camera.viewportY + camera.height * (0.5 - y * 0.5))
end

local function drawDashedLine(drawList, first, second, scale)
  local dx, dy = second.x - first.x, second.y - first.y
  local length = math.sqrt(dx * dx + dy * dy)
  if length <= 0.0001 then return end
  local dirX, dirY = dx / length, dy / length
  local dash, gap = 7 * scale, 5 * scale
  local distance = 0
  while distance < length do
    local dashEnd = math.min(distance + dash, length)
    im.ImDrawList_AddLine(
      drawList,
      im.ImVec2(first.x + dirX * distance, first.y + dirY * distance),
      im.ImVec2(first.x + dirX * dashEnd, first.y + dirY * dashEnd),
      hintColor,
      1.5 * scale)
    distance = distance + dash + gap
  end
end

local function drawChevron(drawList, tipX, tipY, dirX, dirY, scale)
  local length = math.sqrt(dirX * dirX + dirY * dirY)
  if length <= 0.0001 then return end
  dirX, dirY = dirX / length, dirY / length
  local size = 10 * scale
  local wing = 6 * scale
  local baseX, baseY = tipX - dirX * size, tipY - dirY * size
  local perpX, perpY = -dirY, dirX
  local tip = im.ImVec2(tipX, tipY)
  im.ImDrawList_AddLine(
    drawList,
    tip,
    im.ImVec2(baseX + perpX * wing, baseY + perpY * wing),
    hintColor,
    2.5 * scale)
  im.ImDrawList_AddLine(
    drawList,
    tip,
    im.ImVec2(baseX - perpX * wing, baseY - perpY * wing),
    hintColor,
    2.5 * scale)
end

function M.drawInteractionHint(kind, pivotScreen)
  if not pivotScreen then return end
  im.SetMouseCursor(im.MouseCursor_None)
  local viewport = im.GetMainViewport()
  local drawList = im.GetForegroundDrawList2(viewport)
  local mouse = im.GetMousePos()
  local scale = im.uiscale[0]
  local dx, dy = mouse.x - pivotScreen.x, mouse.y - pivotScreen.y
  local radius = math.sqrt(dx * dx + dy * dy)
  local dirX, dirY = 1, 0
  if radius > 0.0001 then
    dirX, dirY = dx / radius, dy / radius
  end

  if kind ~= "translate" then drawDashedLine(drawList, pivotScreen, mouse, scale) end
  if kind == "rotate" and radius > 2 * scale then
    local tangentX, tangentY = -dirY, dirX
    drawChevron(
      drawList,
      mouse.x + tangentX * 12 * scale,
      mouse.y + tangentY * 12 * scale,
      tangentX,
      tangentY,
      scale)
    drawChevron(
      drawList,
      mouse.x - tangentX * 12 * scale,
      mouse.y - tangentY * 12 * scale,
      -tangentX,
      -tangentY,
      scale)
  elseif kind == "scale" then
    drawChevron(
      drawList,
      mouse.x + dirX * 12 * scale,
      mouse.y + dirY * 12 * scale,
      dirX,
      dirY,
      scale)
    drawChevron(
      drawList,
      mouse.x - dirX * 12 * scale,
      mouse.y - dirY * 12 * scale,
      -dirX,
      -dirY,
      scale)
  elseif kind == "translate" then
    drawChevron(drawList, mouse.x + 13 * scale, mouse.y, 1, 0, scale)
    drawChevron(drawList, mouse.x - 13 * scale, mouse.y, -1, 0, scale)
    drawChevron(drawList, mouse.x, mouse.y + 13 * scale, 0, 1, scale)
    drawChevron(drawList, mouse.x, mouse.y - 13 * scale, 0, -1, scale)
  end
  im.ImDrawList_AddCircleFilled(drawList, mouse, 2.5 * scale, hintColor, 12)
end

function M.setInteractionCursorHidden(hidden)
  if hidden then im.SetMouseCursor(im.MouseCursor_None) end
  local canvas = scenetree.findObject("Canvas")
  if canvas and canvas.setCursorVisible then
    canvas:setCursorVisible(hidden ~= true)
  end
end

function M.drawHud(prefix, details, help, border)
  local scale = im.uiscale[0]
  local firstLine = prefix .. "  " .. details
  local firstSize = im.CalcTextSize(firstLine)
  local secondSize = im.CalcTextSize(help)
  local width = math.max(firstSize.x, secondSize.x) + 18 * scale
  local height = firstSize.y + secondSize.y + 18 * scale
  local mouse = im.GetMousePos()
  local viewport = im.GetMainViewport()
  local x = mouse.x + 20 * scale
  local y = mouse.y + 20 * scale
  if x + width > viewport.Pos.x + viewport.Size.x - 8 * scale then
    x = mouse.x - width - 20 * scale
  end
  if y + height > viewport.Pos.y + viewport.Size.y - 8 * scale then
    y = mouse.y - height - 20 * scale
  end

  local drawList = im.GetForegroundDrawList2(viewport)
  im.ImDrawList_AddRectFilled(
    drawList,
    im.ImVec2(x, y),
    im.ImVec2(x + width, y + height),
    overlayBackground,
    5 * scale)
  im.ImDrawList_AddRect(
    drawList,
    im.ImVec2(x, y),
    im.ImVec2(x + width, y + height),
    border,
    5 * scale,
    0,
    2 * scale)
  im.ImDrawList_AddText1(
    drawList,
    im.ImVec2(x + 9 * scale, y + 5 * scale),
    overlayText,
    firstLine,
    nil)
  im.ImDrawList_AddText1(
    drawList,
    im.ImVec2(x + 9 * scale, y + firstSize.y + 9 * scale),
    overlayText,
    help,
    nil)
end

return M
