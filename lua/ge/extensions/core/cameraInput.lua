-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Player camera input handlers (look / move / zoom / 3d-mouse absolute axes), split out
-- of core/camera.lua. core_camera injects moveFor + getFovDeg via setup() and re-exposes
-- these on its module table (the input bindings call core_camera.rotate_yaw etc.).
-- MoveManager is the global input state core_camera repoints to the current view each frame.

local M = {}

local moveFor, getFovDeg -- injected by core/camera.lua

function M.setup(deps)
  moveFor = deps.moveFor
  getFovDeg = deps.getFovDeg
end

-- input source filter (kbd/pad/mouse) and last-rotation tracking, read by camera modes/UI
local lastFilter = FILTER_KBD
function M.getLastFilter() return lastFilter end

local lastRotatedTime = 0
local lastCameraMovementType = "none" -- absolute or relative
local function rotatedCamera(mode)
  lastRotatedTime = Engine.Platform.getSystemTimeMS()
  lastCameraMovementType = mode or lastCameraMovementType
end

function M.timeSinceLastRotation()
  return Engine.Platform.getSystemTimeMS() - lastRotatedTime
end

function M.getLastCameraMovementType()
  return lastCameraMovementType
end

function M.rotate_yaw_left(val, filter, player)
  moveFor(player).yawLeft = val
  lastFilter = filter
  rotatedCamera("absolute")
end

function M.rotate_yaw_right(val, filter, player)
  moveFor(player).yawRight = val
  lastFilter = filter
  rotatedCamera("absolute")
end

function M.rotate_yaw(val, filter, player)
  local mm = moveFor(player)
  lastFilter = filter
  if val > 0 then
    mm.yawRight = val
    mm.yawLeft = 0
  else
    mm.yawLeft = -val
    mm.yawRight = 0
  end
  rotatedCamera("absolute")
end

function M.rotate_pitch_up(val, filter, player)
  moveFor(player).pitchUp = val
  lastFilter = filter
  rotatedCamera("absolute")
end

function M.rotate_pitch_down(val, filter, player)
  moveFor(player).pitchDown = val
  lastFilter = filter
  rotatedCamera("absolute")
end

function M.rotate_pitch(val, filter, player)
  local mm = moveFor(player)
  lastFilter = filter
  if val > 0 then
    mm.pitchUp = val
    mm.pitchDown = 0
  else
    mm.pitchDown = -val
    mm.pitchUp = 0
  end
  rotatedCamera("absolute")
end

function M.rotate_roll_right(val, filter, player)
  moveFor(player).rollRight = val
  lastFilter = filter
  rotatedCamera("absolute")
end

function M.rotate_roll_left(val, filter, player)
  moveFor(player).rollLeft = val
  lastFilter = filter
  rotatedCamera("absolute")
end

function M.moveForwardBackward(val, player)
  local mm = moveFor(player)
  if val > 0 then
    mm.forward = val
    mm.backward = 0
  else
    mm.forward = 0
    mm.backward = -val
  end
end

function M.moveLeftRight(val, player)
  local mm = moveFor(player)
  if val > 0 then
    mm.right = val
    mm.left = 0
  else
    mm.right = 0
    mm.left = -val
  end
end

function M.cameraZoom(val, player)
  local mm = moveFor(player)
  if val > 0 then
    mm.zoomIn = val
    mm.zoomOut = 0
  else
    mm.zoomIn = 0
    mm.zoomOut = -val
  end
end

-- rmb mouse camera
function M.rotate_yaw_relative(val, player)
  local mm = moveFor(player)
  mm.yawRelative = mm.yawRelative + getFovDeg() * val / 4500
  if val ~= 0 then
    rotatedCamera("relative")
  end
end

function M.rotate_pitch_relative(val, player)
  local mm = moveFor(player)
  mm.pitchRelative = mm.pitchRelative + getFovDeg() * val / 4500
  if val ~= 0 then
    rotatedCamera("relative")
  end
end

-- Movement Keys (free camera fly + driver-seat adjust), routed to the player's view
function M.moveleft    (val, player) moveFor(player).left     = val end
function M.moveright   (val, player) moveFor(player).right    = val end
function M.moveforward (val, player) moveFor(player).forward  = val end
function M.movebackward(val, player) moveFor(player).backward = val end
function M.moveup      (val, player) moveFor(player).up       = val end
function M.movedown    (val, player) moveFor(player).down     = val end

-- 3d spacemouse support :)
local absRotateAxisFactor = 0.0005
local yawTemp   = 0
local rollTemp  = 0
local pitchTemp = 0
function M.yawAbs(val)   MoveManager.yawRelative   = (  yawTemp - val) * absRotateAxisFactor;   yawTemp = val end
function M.rollAbs(val)  MoveManager.rollRelative  = ( rollTemp - val) * absRotateAxisFactor;  rollTemp = val end
function M.pitchAbs(val) MoveManager.pitchRelative = (pitchTemp - val) * absRotateAxisFactor; pitchTemp = val end
local absTranslateAxisFactor = 0.02
local xAxisAbsTemp = 0
local yAxisAbsTemp = 0
local zAxisAbsTemp = 0
function M.xAxisAbs(val) MoveManager.absXAxis = (xAxisAbsTemp - val) * absTranslateAxisFactor; xAxisAbsTemp = val end
function M.yAxisAbs(val) MoveManager.absYAxis = (yAxisAbsTemp - val) * absTranslateAxisFactor; yAxisAbsTemp = val end
function M.zAxisAbs(val) MoveManager.absZAxis = (zAxisAbsTemp - val) * absTranslateAxisFactor; zAxisAbsTemp = val end

-- Move at "val" speed for a small set amount of time (3d-mouse zoom step)
local absTranslateTimer = nil
function M.yAxisMoveStep(val)
  if editor and editor.disableCameraZoom then return end
  absTranslateTimer = 0
  M.yAxisAbs(val)
end

-- Decay the absolute (3d-mouse) translation axes once the move-step window elapses; the
-- main view's update calls this each frame. Operates on the current global MoveManager.
function M.tickAbsAxes(dtReal)
  if absTranslateTimer then
    absTranslateTimer = absTranslateTimer + dtReal
    if absTranslateTimer < 0.05 then return end -- keep moving for a moment
    absTranslateTimer = nil
  end
  MoveManager.absXAxis = 0
  MoveManager.absYAxis = 0
  MoveManager.absZAxis = 0
end

return M
