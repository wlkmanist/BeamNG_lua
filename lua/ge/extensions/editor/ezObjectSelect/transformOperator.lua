-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local common = require("editor/ezObjectSelect/modalOperatorCommon")
local numericInput = require("editor/ezObjectSelect/transformNumericInput")
local selectionGeometry = require("editor/ezObjectSelect/selectionGeometry")
local transformGizmo = require("editor/ezObjectSelect/transformGizmo")
local transformSession = require("editor/ezObjectSelect/transformSession")

local gKey = im.GetKeyIndex(im.Key_G)
local xKey = im.GetKeyIndex(im.Key_X)
local yKey = im.GetKeyIndex(im.Key_Y)
local zKey = im.GetKeyIndex(im.Key_Z)
local enterKey = im.GetKeyIndex(im.Key_Enter)
local keypadEnterKey = im.GetKeyIndex(im.Key_KeypadEnter)
local escapeKey = im.GetKeyIndex(im.Key_Escape)
local state = nil
local overlayBackground = im.GetColorU322(im.ImVec4(0.02, 0.03, 0.04, 0.9))
local overlayBorder = im.GetColorU322(im.ImVec4(0.2, 1, 0.35, 1))
local overlayText = im.GetColorU322(im.ImVec4(1, 1, 1, 1))
local planeGridDivisions = 8

local function normalized(vector, fallback)
  local result = vec3(vector)
  local length = result:length()
  return length > 0.0001 and result / length or vec3(fallback)
end

local function currentRay()
  local ray = getCameraMouseRay()
  if not ray then return nil end
  local direction = normalized(ray.dir, vec3(0, 1, 0))
  return {origin = vec3(ray.pos), direction = direction}
end

local function rayPlanePoint(ray, planePoint, planeNormal)
  if not ray then return nil end
  local denominator = ray.direction:dot(planeNormal)
  if math.abs(denominator) <= 0.0001 then return nil end
  local distance = (planePoint - ray.origin):dot(planeNormal) / denominator
  return ray.origin + ray.direction * distance
end

local function rayAxisParameter(ray, point, axis)
  if not ray then return nil end
  local axisRayDot = axis:dot(ray.direction)
  local denominator = 1 - axisRayDot * axisRayDot
  if math.abs(denominator) <= 0.0001 then return nil end
  local relative = point - ray.origin
  return (axisRayDot * ray.direction:dot(relative) - axis:dot(relative)) / denominator
end

local function viewPlaneDelta()
  local ray = currentRay()
  local currentPoint = rayPlanePoint(ray, state.pivot, state.camera.forward)
  if currentPoint and state.startViewPoint then return currentPoint - state.startViewPoint end
  local mouse = im.GetMousePos()
  local deltaX = mouse.x - state.startMouse.x
  local deltaY = mouse.y - state.startMouse.y
  return state.camera.right * deltaX * state.worldPerPixel
    - state.camera.up * deltaY * state.worldPerPixel
end

local function constrainedAxis()
  if not state.constraint then return nil end
  local axes = state.constraint.localSpace and state.localAxes or state.worldAxes
  return axes[state.constraint.axis]
end

local function mouseDelta()
  if not state.constraint then return viewPlaneDelta() end
  local axis = constrainedAxis()
  if state.constraint.plane then
    local ray = currentRay()
    local currentPoint = rayPlanePoint(ray, state.pivot, axis)
    local startPoint = rayPlanePoint(state.startRay, state.pivot, axis)
    if currentPoint and startPoint then return currentPoint - startPoint end
    local delta = viewPlaneDelta()
    return delta - axis * delta:dot(axis)
  end

  local currentParameter = rayAxisParameter(currentRay(), state.pivot, axis)
  local startParameter = rayAxisParameter(state.startRay, state.pivot, axis)
  if currentParameter and startParameter then
    return axis * (currentParameter - startParameter)
  end
  local delta = viewPlaneDelta()
  return axis * delta:dot(axis)
end

local function numericDelta(delta)
  local value = numericInput.value(state.numeric)
  if value == nil then return delta end
  if state.constraint and not state.constraint.plane then
    return constrainedAxis() * value
  end
  local length = delta:length()
  local direction
  if length > 0.0001 then
    direction = delta / length
  elseif state.constraint then
    local axes = state.constraint.localSpace and state.localAxes or state.worldAxes
    local fallbackAxis = state.constraint.axis == "x" and "y" or "x"
    direction = axes[fallbackAxis]
  else
    direction = state.camera.right
  end
  return direction * value
end

local function worldGridMask()
  if not state.constraint or state.constraint.localSpace then
    return {x = true, y = true, z = true}
  end
  if state.constraint.plane then
    return {
      x = state.constraint.axis ~= "x",
      y = state.constraint.axis ~= "y",
      z = state.constraint.axis ~= "z"
    }
  end
  return {
    x = state.constraint.axis == "x",
    y = state.constraint.axis == "y",
    z = state.constraint.axis == "z"
  }
end

local function snapLocalDelta(delta, gridSize)
  if not state.constraint or not state.constraint.localSpace then return delta end
  local axes = state.localAxes
  if state.constraint.plane then
    local result = vec3(0, 0, 0)
    for name, axis in pairs(axes) do
      if name ~= state.constraint.axis then
        local amount = round(delta:dot(axis) / gridSize) * gridSize
        result = result + axis * amount
      end
    end
    return result
  end
  local axis = axes[state.constraint.axis]
  local amount = round(delta:dot(axis) / gridSize) * gridSize
  return axis * amount
end

local function setConstraint(axis, plane)
  if state.constraint
    and state.constraint.axis == axis
    and state.constraint.plane == plane then
    state.constraint.localSpace = not state.constraint.localSpace
  else
    state.constraint = {
      axis = axis,
      plane = plane,
      localSpace = state.defaultLocal
    }
  end
end

local function updateConstraintInput()
  local plane = editor.keyModifiers.shift == true
  if im.IsKeyPressed(xKey) then setConstraint("x", plane) end
  if im.IsKeyPressed(yKey) then setConstraint("y", plane) end
  if im.IsKeyPressed(zKey) then setConstraint("z", plane) end
end

local function guideLength()
  return clamp((state.pivot - state.camera.pos):length() * 0.35, 5, 100)
end

local function drawGridPlane(firstAxis, secondAxis, length, depthTest)
  local size = length * 0.55
  local first = normalized(firstAxis, vec3(1, 0, 0))
  local second = normalized(secondAxis, vec3(0, 1, 0))
  local gridColor = editor.getPreference("gizmos.general.gizmoPlaneGridColor")
    or ColorI(255, 255, 255, 40)
  local lineColor = ColorF(
    gridColor.r / 255,
    gridColor.g / 255,
    gridColor.b / 255,
    gridColor.a / 255)

  for index = -planeGridDivisions, planeGridDivisions do
    local offset = size * index / planeGridDivisions
    debugDrawer:drawLineInstance(
      state.pivot + first * offset - second * size,
      state.pivot + first * offset + second * size,
      index == 0 and 2 or 1,
      lineColor,
      depthTest == true)
    debugDrawer:drawLineInstance(
      state.pivot + second * offset - first * size,
      state.pivot + second * offset + first * size,
      index == 0 and 2 or 1,
      lineColor,
      depthTest == true)
  end
end

local function drawConstraintPlane(axes, length, depthTest)
  local basis = {}
  for _, name in ipairs({"x", "y", "z"}) do
    if name ~= state.constraint.axis then basis[#basis + 1] = axes[name] end
  end
  drawGridPlane(basis[1], basis[2], length, depthTest)
end

local function drawGuides(options)
  local length = guideLength()
  if not state.constraint then
    if options.showPlane then
      drawGridPlane(
        state.camera.right,
        state.camera.up,
        length,
        options.clipPlane)
    end
    return
  end

  local axes = state.constraint.localSpace and state.localAxes or state.worldAxes
  if state.constraint.plane then
    if options.showPlane then drawConstraintPlane(axes, length, options.clipPlane) end
    transformGizmo.drawTranslate(state.pivot, axes, {
      axis = state.constraint.axis,
      exclude = true
    })
  else
    transformGizmo.drawTranslate(state.pivot, axes, {
      axis = state.constraint.axis,
      exclude = false
    })
  end
end

local function finish(result)
  local completion
  if result == "confirm" then
    local committed
    committed, completion = transformSession.finish()
    if committed == nil then result = "cancel" end
  else
    transformSession.cancel()
  end
  common.setInteractionCursorHidden(false)
  state = nil
  return result, completion
end

function M.wantsBegin()
  return im.IsKeyPressed(gKey)
end

function M.begin(options)
  if state or transformSession.isActive() then return false end
  options = options or {}
  local selection = editor.selection.object or {}
  local anchorId = selection[#selection]
  local anchor = anchorId and scenetree.findObjectById(anchorId) or nil
  local camera = selectionGeometry.createCameraContext()
  local ray = currentRay()
  if not anchor or not camera or not ray or not transformSession.begin(anchor) then return false end

  if editor.computeSelectionBBox then editor.computeSelectionBBox() end
  local pivot = editor.objectSelectionBBox and vec3(editor.objectSelectionBBox:getCenter())
    or vec3(anchor:getPosition())
  local transform = anchor:getTransform()
  local depth = math.max((pivot - camera.pos):dot(camera.forward), 1)
  state = {
    pivot = pivot,
    camera = camera,
    startRay = ray,
    startViewPoint = rayPlanePoint(ray, pivot, camera.forward),
    startMouse = im.GetMousePos(),
    worldPerPixel = 2 * depth * camera.halfTan / camera.height,
    worldAxes = {
      x = vec3(1, 0, 0),
      y = vec3(0, 1, 0),
      z = vec3(0, 0, 1)
    },
    localAxes = {
      x = normalized(transform:getColumn(0), vec3(1, 0, 0)),
      y = normalized(transform:getColumn(1), vec3(0, 1, 0)),
      z = normalized(transform:getColumn(2), vec3(0, 0, 1))
    },
    constraint = nil,
    defaultLocal = options.defaultLocal == true,
    numeric = numericInput.newState(),
    delta = vec3(0, 0, 0)
  }
  common.setInteractionCursorHidden(true)
  return true
end

function M.update(options)
  if not state then return nil end
  options = options or {}
  if im.IsKeyPressed(escapeKey) or im.IsMouseClicked(1) then return finish("cancel") end
  if im.IsKeyPressed(enterKey)
    or im.IsKeyPressed(keypadEnterKey)
    or (im.IsMouseClicked(0) and editor.isViewportHovered()) then
    return finish("confirm")
  end

  updateConstraintInput()
  numericInput.update(state.numeric, state.ignoreTopRowFour)
  state.ignoreTopRowFour = false
  state.delta = numericDelta(mouseDelta())
  local gridSize = options.gridSize
  if state.numeric.active then
    gridSize = nil
  elseif gridSize and state.constraint and state.constraint.localSpace then
    state.delta = snapLocalDelta(state.delta, gridSize)
    gridSize = nil
  end
  transformSession.updateDelta(state.delta, {
    gridMask = worldGridMask(),
    gridSize = gridSize,
    gridPivot = state.pivot,
    gridRelative = options.gridRelative,
    snapZ = true
  })
  drawGuides(options)
  return "active"
end

function M.cancel()
  if not state then return false end
  finish("cancel")
  return true
end

function M.setLocalSpace(localSpace)
  if not state then return false end
  state.defaultLocal = localSpace == true
  if state.constraint then state.constraint.localSpace = state.defaultLocal end
  state.ignoreTopRowFour = true
  return true
end

function M.isActive()
  return state ~= nil
end

function M.getObjectIds()
  return state and transformSession.getObjectIds() or {}
end

function M.status()
  if not state then return nil end
  local constraint = "VIEW"
  local space = "WORLD"
  if state.constraint then
    constraint = state.constraint.plane
      and ("SHIFT+" .. string.upper(state.constraint.axis))
      or string.upper(state.constraint.axis)
    space = state.constraint.localSpace and "LOCAL" or "WORLD"
  end
  return {
    constraint = constraint,
    space = space,
    numeric = state.numeric.active and state.numeric.text or nil,
    delta = vec3(state.delta)
  }
end

function M.drawScreen(options)
  local status = M.status()
  if not status then return end
  common.drawInteractionHint(
    "translate",
    common.projectToScreen(state.camera, state.pivot + state.delta))
  options = options or {}
  local grid = options.gridSize
    and string.format(
      "GRID %s %.3g m",
      options.gridRelative and "REL" or "ABS",
      options.gridSize)
    or "GRID OFF"
  local value = status.numeric
    and (status.numeric .. " m")
    or string.format("|d| %.3f m", status.delta:length())
  local firstLine = string.format(
    "G  %s  %s  %s  %s",
    status.constraint,
    status.space,
    value,
    grid)
  local secondLine = "X/Y/Z constrain  Shift+axis plane  axis twice local  LMB/Enter confirm  RMB/Esc cancel"
  local firstSize = im.CalcTextSize(firstLine)
  local secondSize = im.CalcTextSize(secondLine)
  local width = math.max(firstSize.x, secondSize.x) + 18
  local height = firstSize.y + secondSize.y + 18
  local mouse = im.GetMousePos()
  local viewport = im.GetMainViewport()
  local x = mouse.x + 20
  local y = mouse.y + 20
  if x + width > viewport.Pos.x + viewport.Size.x - 8 then x = mouse.x - width - 20 end
  if y + height > viewport.Pos.y + viewport.Size.y - 8 then y = mouse.y - height - 20 end

  local drawList = im.GetForegroundDrawList2(viewport)
  local topLeft = im.ImVec2(x, y)
  local bottomRight = im.ImVec2(x + width, y + height)
  im.ImDrawList_AddRectFilled(drawList, topLeft, bottomRight, overlayBackground, 5)
  im.ImDrawList_AddRect(drawList, topLeft, bottomRight, overlayBorder, 5, 0, 2)
  im.ImDrawList_AddText1(drawList, im.ImVec2(x + 9, y + 5), overlayText, firstLine, nil)
  im.ImDrawList_AddText1(
    drawList,
    im.ImVec2(x + 9, y + firstSize.y + 9),
    overlayText,
    secondLine,
    nil)
end

return M
