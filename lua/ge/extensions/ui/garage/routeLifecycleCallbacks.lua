-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_pause_providers_routeData_photomode",
  "ui_pause_photomode",
}

local GARAGE_PHOTOMODE_ROUTE = "garage.photomode"

local function isGaragePhotomodeRouteName(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == GARAGE_PHOTOMODE_ROUTE or routeName:find("^garage%.photomode%.") == 1
end

local function attachPhotomodeRouteData(context, toRoute, fromRoute, data)
  local routeName = toRoute and toRoute.name
  if not isGaragePhotomodeRouteName(routeName) then
    return
  end

  local routeData = {}
  if ui_pause_providers_routeData_photomode and ui_pause_providers_routeData_photomode.getPhotomodeData then
    routeData = ui_pause_providers_routeData_photomode.getPhotomodeData() or {}
  end

  if routeData.photomode then
    data.photomode = routeData.photomode
  end
end

function M.onPhotomodeEnter(context, toRoute, fromRoute, data)
  dump("garage.onPhotomodeEnter", toRoute and toRoute.name)
  if not isGaragePhotomodeRouteName(toRoute and toRoute.name) then
    return
  end

  if ui_pause_photomode and ui_pause_photomode.beginPhotomodeSession then
    ui_pause_photomode.beginPhotomodeSession({ profile = "garage" })
  end

  attachPhotomodeRouteData(context, toRoute, fromRoute, data)

  if ui_pause_photomode and ui_pause_photomode.onPhotomodeRouteEnter then
    ui_pause_photomode.onPhotomodeRouteEnter(toRoute and toRoute.name or "")
  end
end

function M.onPhotomodeMount(context, toRoute, fromRoute, data)
  dump("garage.onPhotomodeMount", toRoute and toRoute.name)
  attachPhotomodeRouteData(context, toRoute, fromRoute, data)
end

function M.onPhotomodeLeave(context, toRoute, fromRoute, data)
  dump("garage.onPhotomodeLeave", fromRoute and fromRoute.name)

  if ui_pause_photomode and ui_pause_photomode.onPhotomodeRouteLeave then
    ui_pause_photomode.onPhotomodeRouteLeave(toRoute and toRoute.name or "")
  end

  if ui_pause_photomode and ui_pause_photomode.endPhotomodeSession then
    ui_pause_photomode.endPhotomodeSession()
  end
end

return M
