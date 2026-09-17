-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local NavigationState = require("ge/extensions/ui/router/navigationState")
local Utils = require("ge/extensions/ui/router/utils")

local M = {}

local function isStaticTitle(title)
  return type(title) == "string" or type(title) == "table" and title.mode ~= "dynamic"
end

local function resolveSourceHandler(source, sourceType)
  local label = string.format("Breadcrumb %s source %s", tostring(sourceType), tostring(source))
  local handler, err = Utils.resolveFunctionReference(source, label)
  if err then
    log("E", "Router", err)
    return nil
  end
  return handler
end

local function getDynamicTitle(title, params)
  local handler = resolveSourceHandler(title.source, "title")
  if not handler then
    return title.fallback
  end
  local resolved = handler(params)
  if resolved == nil or resolved == "" then
    return title.fallback
  end
  return resolved
end

local function resolveTitle(title, params)
  if not title then
    return nil
  end
  if isStaticTitle(title) then
    return title
  end
  local paramKey = title.paramKey
  local paramValue = paramKey and (params and params[paramKey]) or (not paramKey and params)
  return getDynamicTitle(title, paramValue)
end

local function internalBuildBreadcrumbs(routeNodes, params)
  local breadcrumbs = {}
  for _, node in ipairs(routeNodes or {}) do
    local breadcrumb = {}
    local title = node.title or node.key
    breadcrumb.label = resolveTitle(title, params)
    breadcrumb.abstract = node.abstract
    breadcrumb.isMinorRoute = node.isMinorRoute
    breadcrumb.routeName = node.routeName
    breadcrumb.params = params
    table.insert(breadcrumbs, breadcrumb)
  end
  return breadcrumbs
end

local function resolveDecoratorConfig(config, params)
  if not config then return nil end
  if config.mode == "dynamic" then
    local handler = resolveSourceHandler(config.source, "decorator")
    local result = handler and handler(params)
    return result or config.fallback
  end
  return config.label and { label = config.label } or nil
end

M.buildBreadcrumbs = function(routename, route, params, decorator)
  local breadcrumbs = {}
  if not route.global then
    if not decorator then
      if NavigationState.isDecoratorVisible() then
        local config = extensions.ui_router_routeManager.getModuleDecorator(routename)
        decorator = resolveDecoratorConfig(config, params)
      end
    end
    if decorator then
      table.insert(breadcrumbs, {
        label = decorator,
        routeName = nil,
        decorator = true,
      })
    end
    local routeNodes = extensions.ui_router_routeManager.getRouteNodes(routename)
    for _, crumb in ipairs(internalBuildBreadcrumbs(routeNodes, params)) do
      table.insert(breadcrumbs, crumb)
    end
  end
  return breadcrumbs
end

M.setDecoratorVisible = function(visible)
  NavigationState.setDecoratorVisible(visible)
end

M.isDecoratorVisible = function()
  return NavigationState.isDecoratorVisible()
end

return M
