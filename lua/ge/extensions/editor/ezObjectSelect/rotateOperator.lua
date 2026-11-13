-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local common = require("editor/ezObjectSelect/modalOperatorCommon")
local gizmo = require("editor/ezObjectSelect/transformGizmo")
local transformSession = require("editor/ezObjectSelect/transformSession")

local rKey = im.GetKeyIndex(im.Key_R)
local state = nil
local borderColor = im.GetColorU322(im.ImVec4(1, 0.7, 0.15, 1))

local function rotationAxis()
  return state.constraint and common.activeAxis(state) or state.camera.forward
end

local function mouseVector(axis, ray)
  local point = common.rayPlanePoint(ray or common.currentRay(), state.pivot, axis)
  if not point then return nil end
  local vector = point - state.pivot
  vector = vector - axis * vector:dot(axis)
  return common.normalized(vector, state.camera.right)
end

local function screenAngle()
  local mouse = im.GetMousePos()
  local dx = mouse.x - state.pivotScreen.x
  local dy = mouse.y - state.pivotScreen.y
  if dx * dx + dy * dy <= 0.0001 then return nil end
  return math.atan2(dy, dx)
end

local function resetMouseReference()
  local axis = rotationAxis()
  state.startVector = mouseVector(axis)
  if not state.startVector then
    state.startVector = common.normalized(
      state.camera.right - axis * state.camera.right:dot(axis),
      state.camera.up)
  end
  state.startScreenAngle = screenAngle()
  state.angle = 0
end

local function mouseAngle()
  local current = screenAngle()
  if not current or not state.startScreenAngle then return state.angle end
  local delta = current - state.startScreenAngle
  if not state.constraint then delta = -delta end
  return math.atan2(math.sin(delta), math.cos(delta))
end

local function finish(result)
  local resolved, completion = common.finish(result)
  state = nil
  return resolved, completion
end

function M.wantsBegin()
  return im.IsKeyPressed(rKey)
end

function M.begin(options)
  if state or transformSession.isActive() then return false end
  options = options or {}
  state = common.begin({
    defaultLocal = options.defaultLocal,
    historyName = "EasySelectRotate"
  })
  if not state then return false end
  state.pivotScreen = common.projectToScreen(state.camera, state.pivot)
  if not state.pivotScreen then
    transformSession.cancel()
    state = nil
    return false
  end
  state.angle = 0
  resetMouseReference()
  common.setInteractionCursorHidden(true)
  return true
end

function M.update(options)
  if not state then return nil end
  options = options or {}
  local result = common.finishRequested()
  if result then return finish(result) end
  if common.updateConstraint(state, false) then resetMouseReference() end

  local numericValue = common.updateNumeric(state)
  local angle = numericValue and math.rad(numericValue) or mouseAngle()
  if not numericValue and options.rotateSnapEnabled and options.rotateSnapSize > 0 then
    local snap = math.rad(options.rotateSnapSize)
    angle = round(angle / snap) * snap
  end
  state.angle = angle
  transformSession.updateRotation(state.pivot, rotationAxis(), angle)
  gizmo.drawRotation(state.pivot, rotationAxis(), state.startVector, angle)
  return "active"
end

function M.cancel()
  if not state then return false end
  finish("cancel")
  return true
end

function M.setLocalSpace(localSpace)
  if not common.setLocalSpace(state, localSpace) then return false end
  resetMouseReference()
  return true
end

function M.isActive()
  return state ~= nil
end

function M.getObjectIds()
  return state and transformSession.getObjectIds() or {}
end

function M.drawScreen()
  if not state then return end
  common.drawInteractionHint("rotate", state.pivotScreen)
  local constraint = state.constraint and string.upper(state.constraint.axis) or "VIEW"
  local space = state.constraint and (state.constraint.localSpace and "LOCAL" or "WORLD") or "VIEW"
  local value = state.numeric.active
    and (state.numeric.text .. " deg")
    or string.format("%.2f deg", math.deg(state.angle))
  common.drawHud(
    "R",
    string.format("%s  %s  %s", constraint, space, value),
    "X/Y/Z axis  axis twice local  LMB/Enter confirm  RMB/Esc cancel",
    borderColor)
end

return M
