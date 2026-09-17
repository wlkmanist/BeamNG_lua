-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- extension name: gameplay_rally
-- extensions.load('gameplay_rally_test_testRouteFix')

local im  = ui_imgui

local Route = require('/lua/ge/extensions/gameplay/route/route')

local logTag = ''

local M = {}

local route = nil

local path = {
  vec3(1499.20874,1593.685303,138.6869507),
  vec3(1508.348755,1600.3302,139.9772339),
  vec3(1516.930908,1606.302002,141.7883606)
}

local function drawMousePos()
  local mousePos = cameraMouseRayCast()
  if mousePos and mousePos.pos then
    debugDrawer:drawSphere(mousePos.pos, 1, ColorF(1,1,1,1), false, false)
  end
  if im.IsMouseClicked(0) then
    dump(mousePos)
  end
end

local drawPath = function()
  for i, pos in ipairs(path) do
    debugDrawer:drawSphere(pos, 0.5, ColorF(1,1,1,1), false, false)
    debugDrawer:drawTextAdvanced(pos, String(i), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192), false, false)
  end
end

local drawRoute = function()
  if not route then return end

  for i, pos in ipairs(route.path) do
    local p1 = pos.pos
    if i > 1 then
      local p2 = route.path[i-1].pos
      debugDrawer:drawSquarePrism(p1, p2, Point2F(0.5,0.5), Point2F(0.5,0.5), ColorF(1,1,1,1))
    end
    debugDrawer:drawSphere(p1, 0.5, ColorF(1,1,1,1), false, false)
    debugDrawer:drawTextAdvanced(p1, String(i), ColorF(1,1,1,1), true, false, ColorI(0,0,0,192), false, false)
  end
end

-- extension hooks
M.onUpdate = function()
  -- drawMousePos()
  -- drawPath()
  drawRoute()

  if route then
    local veh = getPlayerVehicle(0)
    if veh then
      route:trackVehicle(veh)
    end
  end
end

M.onVehicleResetted = function()
end

M.onExtensionLoaded = function()
  route = Route()
  route:setupPathMulti(path)
end

M.onExtensionUnloaded = function()
end

return M