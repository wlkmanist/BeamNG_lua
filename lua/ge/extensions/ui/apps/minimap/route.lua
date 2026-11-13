-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local layers = require("ui/apps/minimap/layers")

local routeMaxLength = 3000 -- limit the route to 3000 points

--local navBgWhite, navFgBlue

local clrNavBg = color(255,255,255,255)
local clrNavFg = color(0,0.4*255,1*255,255)

local blendDistance = 75
local function getRouteColor(distance)
  if distance > blendDistance then
    return clrNavFg
  else
    -- blend between colorNavFG and white
    local t = (1 - distance / blendDistance) * 0.66
    return color(
      t*255,
      (0.4 + 0.6*t)*255,
      255, 255)
  end
end

local function drawRoute(route, td, dpi, camPos, cullRadius)
  dpi = dpi or 1
  if not route or not route[1] then
    return
  end
  --local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
  --navBgWhite = navBgWhite or currentStyleColorSet.navBg
  --navFgBlue = navFgBlue or currentStyleColorSet.navFg
  local startDistance = route[1].distToTarget
  local routeCurrentLength = math.min(#route, routeMaxLength)
  local worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset = ui_apps_minimap_utils.getWorldToMapTransform()
  local tdlineRoundEndWithBackground = td.lineRoundEndWithBackground
  local widthBg, widthFg = 4*dpi, 2*dpi
  local layerBG, layerFG = layers.ROUTE_BG, layers.ROUTE_FG
  local cullMinX, cullMinY, cullMaxX, cullMaxY
  if camPos and cullRadius then
    cullMinX, cullMinY = camPos.x - cullRadius, camPos.y - cullRadius
    cullMaxX, cullMaxY = camPos.x + cullRadius, camPos.y + cullRadius
  end

  for i = 1, routeCurrentLength - 1 do
    local p1, p2 = route[i].pos, route[i+1].pos
    local visible = not cullMinX
      or ((p1.x >= cullMinX or p2.x >= cullMinX)
        and (p1.x <= cullMaxX or p2.x <= cullMaxX)
        and (p1.y >= cullMinY or p2.y >= cullMinY)
        and (p1.y <= cullMaxY or p2.y <= cullMaxY))

    if visible then
      local color = getRouteColor(((startDistance - route[i].distToTarget) + (startDistance - route[i+1].distToTarget))/2)
      tdlineRoundEndWithBackground(td, p1.x, p1.y, p2.x, p2.y, widthFg, widthBg, color, clrNavBg, worldToMapXX, worldToMapXYCoef, worldToMapYX, worldToMapYY, worldToMapXOffset, worldToMapYOffset, layerFG, layerBG)
    end
  end
end

-- Navigation drawing function
local routeOverrides = {}
local function drawNavigationRoute(td, dpi, camPos, cullRadius)
  dpi = dpi or 1
  table.clear(routeOverrides)
  extensions.hook("onMinimapRouteOverride", routeOverrides)
  if next(routeOverrides) then
    for _, route in ipairs(routeOverrides) do
      drawRoute(route, td, dpi, camPos, cullRadius)
    end
  else
    local rp = core_groundMarkers.routePlanner
    if rp and rp.path and rp.path[1] then
      drawRoute(rp.path, td, dpi, camPos, cullRadius)
    end
  end
end

local function drawRoutePointer(td)
  local rp = core_groundMarkers.routePlanner
  if not rp or not rp.path or not rp.path[1] then
    return
  end
  local route = rp.path
  --local currentStyleColorSet = ui_apps_minimap_utils.getCurrentStyleColors()
  --navBgWhite = navBgWhite or currentStyleColorSet.navBg
  --navFgBlue = navFgBlue or currentStyleColorSet.navFg
  ui_apps_minimap_utils.simpleCircleWithEdgePointer(route[#route].pos, clrNavFg, clrNavBg, 9)
end

M.drawNavigationRoute = drawNavigationRoute
M.drawRoutePointer = drawRoutePointer
return M