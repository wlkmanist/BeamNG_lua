-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local im = ui_imgui
local common = require("editor/ezObjectSelect/modalOperatorCommon")
local gizmo = require("editor/ezObjectSelect/transformGizmo")
local transformSession = require("editor/ezObjectSelect/transformSession")

local sKey = im.GetKeyIndex(im.Key_S)
local state = nil
local borderColor = im.GetColorU322(im.ImVec4(0.3, 0.75, 1, 1))

local function mouseDistance()
  local mouse = im.GetMousePos()
  local dx = mouse.x - state.pivotScreen.x
  local dy = mouse.y - state.pivotScreen.y
  return math.sqrt(dx * dx + dy * dy)
end

local function scaleFactors(factor)
  if not state.constraint then return {x = factor, y = factor, z = factor} end
  local factors = {x = 1, y = 1, z = 1}
  if state.constraint.exclude then
    for _, name in ipairs({"x", "y", "z"}) do
      if name ~= state.constraint.axis then factors[name] = factor end
    end
  else
    factors[state.constraint.axis] = factor
  end
  return factors
end

local function finish(result)
  local resolved, completion = common.finish(result)
  state = nil
  return resolved, completion
end

function M.wantsBegin()
  return im.IsKeyPressed(sKey)
end

function M.begin(options)
  if state or transformSession.isActive() then return false end
  options = options or {}
  state = common.begin({
    defaultLocal = options.defaultLocal,
    historyName = "EasySelectScale"
  })
  if not state then return false end
  state.pivotScreen = common.projectToScreen(state.camera, state.pivot)
  if not state.pivotScreen then
    transformSession.cancel()
    state = nil
    return false
  end
  state.initialDistance = mouseDistance()
  state.radialReady = state.initialDistance >= 10 * im.uiscale[0]
  state.factor = 1
  common.setInteractionCursorHidden(true)
  return true
end

function M.update()
  if not state then return nil end
  local result = common.finishRequested()
  if result then return finish(result) end
  common.updateConstraint(state, true)

  local numericValue = common.updateNumeric(state)
  local factor = numericValue
  if not factor then
    local distance = mouseDistance()
    if not state.radialReady then
      if distance >= 10 * im.uiscale[0] then
        state.initialDistance = distance
        state.radialReady = true
      end
      factor = 1
    else
      factor = distance / state.initialDistance
    end
  end
  factor = clamp(factor, 0.0001, 100000)
  local _, appliedFactor = transformSession.updateScale(
    state.pivot,
    common.axes(state),
    scaleFactors(factor))
  state.factor = appliedFactor or factor
  gizmo.drawScale(state.pivot, common.axes(state), state.constraint)
  return "active"
end

function M.cancel()
  if not state then return false end
  finish("cancel")
  return true
end

function M.setLocalSpace(localSpace)
  return common.setLocalSpace(state, localSpace)
end

function M.isActive()
  return state ~= nil
end

function M.getObjectIds()
  return state and transformSession.getObjectIds() or {}
end

function M.drawScreen()
  if not state then return end
  common.drawInteractionHint("scale", state.pivotScreen)
  local constraint = "UNIFORM"
  local space = "WORLD"
  if state.constraint then
    constraint = state.constraint.exclude
      and ("SHIFT+" .. string.upper(state.constraint.axis))
      or string.upper(state.constraint.axis)
    space = state.constraint.localSpace and "LOCAL" or "WORLD"
  end
  local value = string.format("%.3fx", state.factor)
  common.drawHud(
    "S",
    string.format("%s  %s  %s", constraint, space, value),
    "X/Y/Z axis  Shift+axis exclude  axis twice local  LMB/Enter confirm  RMB/Esc cancel",
    borderColor)
end

return M
