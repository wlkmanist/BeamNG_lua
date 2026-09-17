-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- DEPRECATED: The main router flow builds NavigationEntries directly via
-- ResolvedRoute.createEntry(). This module is retained only for any external
-- callers that may still reference it.
local M = {}

local ResolvedRoute = require("ge/extensions/ui/router/models/ResolvedRoute")
local Utils = require("ge/extensions/ui/router/utils")

-- Resolve a route name to a resolved route table.
-- @deprecated Use ResolvedRoute.createEntry() for full NavigationEntries.
M.resolve = function(routeName, params, currentRoute)
  if currentRoute and Utils.isRelativeRoute(routeName) then
    routeName = Utils.resolveRelativeRoute(routeName, currentRoute.name)
  end

  local routeConfig = extensions.ui_router_routeManager.getRoute(routeName)
  if not routeConfig then
    log("W", "", "Route not found: " .. routeName)
    return
  end

  local request = ResolvedRoute.createRequest(routeName, params)
  local resolved = ResolvedRoute.createResolved(routeConfig, request)
  if not resolved then
    log("W", "", "Failed to create resolved route: " .. routeName)
    return
  end
  return resolved
end

--[[
  Check if two routes are the same (by name and params).

  @param routeA - First route
  @param routeB - Second route
  @return boolean
]]
M.isEqualRoutes = function(routeA, routeB)
  if not routeA or not routeB then
    return false
  end

  if routeA.name ~= routeB.name then
    return false
  end

  -- Compare params
  local paramsA =  type(routeA.params) == "table" and routeA.params or {}
  local paramsB = type(routeB.params) == "table" and routeB.params or {}

  for key, value in pairs(paramsA) do
    if paramsB[key] ~= value then
      return false
    end
  end

  for key, value in pairs(paramsB) do
    if paramsA[key] ~= value then
      return false
    end
  end

  return true
end
return M
