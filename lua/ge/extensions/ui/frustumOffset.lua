-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Camera frustum center offset used by UI panels covering parts of the screen (see BngFrustumMover.js).
-- The engine offset is a camera-space slope (GuiViewportCtrl::onRender scales it by the near plane),
-- so on-screen shift = offset / (aspect * tan(vFov / 2)). Screen offsets are converted here and
-- re-applied whenever the FoV changes.

local M = {}

local rawX, rawY = 0, 0 -- engine units, passed through as is
local screenX, screenY = 0, 0 -- fraction of the half screen, positive = view center moves right/up
local appliedFov

local function getAspect()
  local extent = scenetree.OnlyGui:getExtent()
  return extent.x / math.max(extent.y, 1)
end

local function getFovDeg()
  -- match the engine, which clamps the render FoV to 10 degrees
  return math.max(core_camera.getFovDeg(), 10)
end

local function apply()
  local x, y = rawX, rawY
  appliedFov = nil
  if screenX ~= 0 or screenY ~= 0 then
    appliedFov = getFovDeg()
    local tanHalfVFov = math.tan(math.rad(appliedFov) * 0.5)
    x = x + screenX * getAspect() * tanHalfVFov
    y = y + screenY * tanHalfVFov
  end
  scenetree.OnlyGui:setFrustumCameraCenterOffset(Point2F(x, y))
end

local function set(newRawX, newRawY, newScreenX, newScreenY)
  rawX, rawY = newRawX or 0, newRawY or 0
  screenX, screenY = newScreenX or 0, newScreenY or 0
  apply()
end

local function onUpdate()
  if screenX == 0 and screenY == 0 then return end
  if getFovDeg() ~= appliedFov then apply() end
end

M.set = set
M.onUpdate = onUpdate

return M
