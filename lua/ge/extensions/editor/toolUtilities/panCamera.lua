-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared spline-tool PAN camera.

local M = {}

-- Module dependencies.
local toolCamera = require('editor/toolUtilities/toolCamera')
local util = require('editor/toolUtilities/util')

-- Module state.
local on = false          -- pan camera driving (true) vs the editor's own free camera (false)
local focusProvider = nil -- host callback returning the current selection's point set to frame (or nil)


-- Fly the pan camera to frame `points` (a link spline, junction + arm tips...). splineFocus returns an ABSOLUTE framing
-- altitude; flyPan resolves the terrain under (mx,my) itself and floats the camera above it (groundZ nil = auto), so the
-- framing stays terrain-aware on tall maps and the eye doesn't snap when interactive drive resumes. No-op if too small.
local function frame(points)
  if not points or #points == 0 then return end
  local mx, my, h = util.splineFocus(points)
  if not mx then return end
  toolCamera.flyPan(mx, my, nil, h)
end

-- Host registers a fn() -> points (current selection) so toggle-on / open frames what you're looking at.
local function configure(opts)
  focusProvider = opts and opts.focusProvider
end

local function isOn()
  return on
end

-- Take over the camera and go top-down: frame the current selection if there is one, else just tilt to top-down where the
-- camera already is.
local function open()
  on = true
  toolCamera.takeOver()
  local pts = focusProvider and focusProvider()
  if pts and #pts > 0 then
    frame(pts)
  elseif core_camera then
    local p = core_camera.getPosition()
    toolCamera.flyPan(p.x, p.y) -- keep the current zoom height, just drop to top-down here
  end
end

-- Hand the editor's free camera back.
local function close()
  on = false
  toolCamera.handBack(false)
end

local function toggle()
  if on then close() else open() end
end

-- Go-to routing: when the pan camera (or a host's own use of the tool camera) is driving, fly IT to `points` and report
-- handled; otherwise let the caller do its normal free-camera jump.
local function gotoPoints(points)
  if not (on or toolCamera.isActive()) then return false end
  frame(points)
  return true
end

-- Per-frame drive (RMB-drag pan + wheel zoom). `blocked` suppresses movement during the tool's own modal interactions
-- (polygon drawing, node/gizmo drag, placement...).
local function drive(blocked)
  toolCamera.drive(blocked)
end


-- Public interface.
M.configure = configure
M.isOn = isOn
M.open = open
M.close = close
M.toggle = toggle
M.gotoPoints = gotoPoints
M.drive = drive

return M