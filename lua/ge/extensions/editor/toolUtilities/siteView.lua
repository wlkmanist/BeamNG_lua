-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- How the outline tools are looked at: which of the two editing steps is showing, and which of the three cameras is on it.
--
-- One copy because the answer is the same in both of them. A footprint is drawn flat and needs the top-down camera; a design
-- is looked around and wants the orbit; and either way the user may want their own camera back. Held here so the open space
-- editor and the parking lot editor offer the same buttons under the same icons, following the same rules.
--
-- The massing editor keeps its own: a building is framed by its height and its walls' facing, not by a flat outline, so it
-- has more to say about where the camera goes than a shared ring-and-terrain view can express. It offers the same buttons
-- and follows the same rules -- what differs is only the arithmetic behind the fly-to.

local M = {}

-- Module dependencies.
local toolCam = require('editor/toolUtilities/toolCamera')

-- Module constants.
local max, sqrt, huge, tan = math.max, math.sqrt, math.huge, math.tan
local PAN_FIT_PAD_M = 5.0 -- slack above the altitude that exactly fits the outline, so it does not touch the viewport edges


-- Module state. One tool is active at a time, so one set of these.
local ctx = nil
local step, mode, wasFree, lastSel = 'design', 'rotate', false, nil


--- Bind to the host tool. `ring` returns the outline to frame, `terrainZ` the ground under a point, `selIndex` what is
--- selected right now (so a change of selection can re-frame), and `onStep` is told when the step changes.
local function init(c)
  ctx = c
end

--- The outline's middle, the radius that frames it for the orbit camera, and the altitude that fits it top-down.
local function ringFocus()
  local r = ctx and ctx.ring and ctx.ring()
  if not r or #r < 1 then return nil end
  local x0, y0, x1, y1 = huge, huge, -huge, -huge
  for i = 1, #r do
    local p = r[i]
    if p.x < x0 then x0 = p.x end
    if p.y < y0 then y0 = p.y end
    if p.x > x1 then x1 = p.x end
    if p.y > y1 then y1 = p.y end
  end
  local cx, cy = (x0 + x1) * 0.5, (y0 + y1) * 0.5
  local hx, hy = (x1 - x0) * 0.5, (y1 - y0) * 0.5
  local gz = ctx.terrainZ(cx, cy)
  local fit = sqrt(hx * hx + hy * hy) / tan(core_camera.getFovRad() * 0.5)
  return cx, cy, gz, max(max(hx, hy), 8), gz + fit + PAN_FIT_PAD_M
end

--- Fly whichever camera is driving onto the selection.
local function focus(m)
  m = m or mode
  lastSel = ctx and ctx.selIndex and ctx.selIndex()
  local cx, cy, cz, radius, panZ = ringFocus()
  if not cx then cx, cy, cz, radius = 0, 0, ctx and ctx.terrainZ(0, 0) or 0, 24 end
  if m == 'pan' then toolCam.flyPan(cx, cy, cz, panZ) else toolCam.flyOrbit(cx, cy, cz, radius) end
end

--- Take the editor camera over and frame the selection.
local function activate(m)
  toolCam.takeOver()
  mode = m or mode
  focus(mode)
end

local function setMode(m)
  if m == mode then return end
  if m == 'free' then
    mode = 'free'
    toolCam.handBack(false)
  else
    local fromFree = (mode == 'free')
    mode = m
    if fromFree then activate(m) else focus(m) end
  end
end

--- Switch editing step. Footprint mode borrows the pan camera whatever was picked before -- the nodes are drawn flat on the
--- ground and are unusable from an angle -- and gives the choice back on the way out. A camera deliberately handed back
--- stays handed back.
local function setStep(key)
  if key == step then return end
  step = key
  if ctx and ctx.onStep then ctx.onStep(key) end
  if key == 'footprint' then
    wasFree = (mode == 'free')
    setMode('pan')
  elseif wasFree then
    wasFree = false
    setMode('free')
  elseif mode ~= 'free' then
    setMode('rotate')
  end
end

--- What a camera button does: switch to that camera, or re-frame it when it is already the one driving. That second press
--- is how the tools go to the site, which is why none of them carries a Go To button of its own. Free is the user's camera,
--- so pressing it again deliberately does nothing.
local function clickMode(m)
  if m ~= mode then setMode(m) elseif m ~= 'free' then focus(m) end
end

--- Re-frame when the panel is pointed at something else. Free mode is the user's camera and is left alone.
local function followSelection()
  if mode == 'free' then return end
  local sel = ctx and ctx.selIndex and ctx.selIndex()
  if sel ~= lastSel then focus(mode) end
end

--- Per-frame drive. `blocked` suppresses movement during the tool's own modal interactions (drawing, dragging a handle).
local function drive(blocked)
  if mode ~= 'free' then toolCam.drive(blocked) end
end

--- Hand the editor camera back, on the way out of the tool.
local function handBack()
  toolCam.handBack(false)
end

--- Where the tool opens: design, in orbit. Footprint mode is a deliberate trip.
local function reset()
  step, mode, wasFree, lastSel = 'design', 'rotate', false, nil
  activate('rotate')
end

local function isShaping() return step == 'footprint' end
local function getStep() return step end
local function getMode() return mode end


-- Public interface.
M.steps = {
  { key = 'footprint', label = 'Footprint', icon = 'format_shapes' },
  { key = 'design', label = 'Design', icon = 'view_module' },
}
M.modes = {
  { mode = 'pan', icon = 'cameraFocusTopDown', tip = 'Pan camera (top-down; RMB-drag to move, wheel to zoom)' },
  { mode = 'rotate', icon = 'rotate', tip = 'Rotate camera (orbit the site; RMB-drag to spin, wheel to dolly)' },
  { mode = 'free', icon = 'videocam', tip = 'Free camera (hand the editor camera back)' },
}

M.init = init
M.focus = focus
M.activate = activate
M.setMode = setMode
M.clickMode = clickMode
M.setStep = setStep
M.followSelection = followSelection
M.drive = drive
M.handBack = handBack
M.reset = reset
M.isShaping = isShaping
M.getStep = getStep
M.getMode = getMode

return M