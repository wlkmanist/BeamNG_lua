-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = { "ui_gridSelector" }

local LOG_TAG = "ui.gridSelectorRouteLifecycleCallbacks"

local ROUTE_DEFAULTS_BY_NAME = {
  ["pause.vehicleSelector"] = {
    backendName = "vehicleSelector",
    routePath = "/vehicle-selector-pause",
    defaultPath = { keys = { "allModels" } },
  },
}

local function normalizePath(path)
  local keys = nil

  if type(path) == "table" then
    if type(path.keys) == "table" then
      keys = path.keys
    elseif path[1] ~= nil then
      keys = path
    end
  end

  if type(keys) ~= "table" then
    return { keys = {} }
  end

  local normalizedKeys = {}
  for _, value in ipairs(keys) do
    local valueType = type(value)
    if valueType == "string" or valueType == "number" or valueType == "boolean" then
      normalizedKeys[#normalizedKeys + 1] = tostring(value)
    end
  end

  return { keys = normalizedKeys }
end

local function pathFromRouteParams(params)
  if type(params) ~= "table" then
    return nil
  end

  if type(params.path) == "table" then
    return normalizePath(params.path)
  end

  if type(params.keys) == "table" then
    return normalizePath({ keys = params.keys })
  end

  local pathMatch = params.pathMatch
  if type(pathMatch) == "table" then
    return normalizePath({ keys = pathMatch })
  end

  if type(pathMatch) == "string" and pathMatch ~= "" then
    local keys = {}
    for segment in string.gmatch(pathMatch, "[^/]+") do
      keys[#keys + 1] = segment
    end
    return normalizePath({ keys = keys })
  end

  return nil
end

local function getGridSelectorMeta(route)
  if type(route) ~= "table" or type(route.meta) ~= "table" then
    return nil
  end
  if type(route.meta.gridSelector) ~= "table" then
    return nil
  end
  return route.meta.gridSelector
end

local function resolveGridSelectorConfig(routeName, routeMeta)
  local defaults = ROUTE_DEFAULTS_BY_NAME[routeName] or {}
  local metadata = type(routeMeta) == "table" and routeMeta or {}

  local backendName = metadata.backendName or defaults.backendName
  if type(backendName) ~= "string" or backendName == "" then
    return nil
  end

  local routePath = metadata.routePath
  if type(routePath) ~= "string" or routePath == "" then
    routePath = defaults.routePath
  end

  local defaultPath = metadata.defaultPath
  if defaultPath == nil then
    defaultPath = defaults.defaultPath
  end

  return {
    backendName = backendName,
    routePath = routePath,
    defaultPath = normalizePath(defaultPath),
  }
end

local function isPauseRouteName(routeName)
  if type(routeName) ~= "string" then return false end
  return routeName == "pause"
    or routeName:find("^pause%.") == 1
    or routeName:find("^menu%.pause") == 1
end

local function runPauseLifecycleIfAvailable(hookName, context, toRoute, fromRoute, data)
  local routeName = nil
  if hookName == "onPauseLeave" then
    routeName = fromRoute and fromRoute.name or toRoute and toRoute.name
  else
    routeName = toRoute and toRoute.name or fromRoute and fromRoute.name
  end
  if not isPauseRouteName(routeName) then
    return
  end

  local pauseLifecycle = extensions.ui_pause_routeLifecycleCallbacks
  local hook = pauseLifecycle and pauseLifecycle[hookName]
  if type(hook) == "function" then
    hook(context, toRoute, fromRoute, data)
  end
end

local function attachGridSelectorSnapshot(toRoute, data)
  if type(data) ~= "table" then
    return
  end

  local routeName = type(toRoute) == "table" and toRoute.name or nil
  local config = resolveGridSelectorConfig(routeName, getGridSelectorMeta(toRoute))
  if not config then
    log("W", LOG_TAG, string.format(
      "Route '%s' missing gridSelector config; skipping route snapshot attach.",
      tostring(routeName)
    ))
    return
  end

  local routePath = pathFromRouteParams(type(toRoute) == "table" and toRoute.params or nil) or config.defaultPath
  local envelope = {
    backendName = config.backendName,
    routePath = config.routePath,
    routeName = routeName,
    snapshot = ui_gridSelector.getSelectorSnapshot(config.backendName, routePath),
  }
  data.gridSelector = envelope
  if config.backendName == "vehicleSelector" then
    data.vehicleSelector = envelope
  end
end

function M.onRouteEnter(context, toRoute, fromRoute, data)
  runPauseLifecycleIfAvailable("onPauseEnter", context, toRoute, fromRoute, data)
  attachGridSelectorSnapshot(toRoute, data)
end

function M.onRouteMount(context, toRoute, fromRoute, data)
  runPauseLifecycleIfAvailable("onPauseMount", context, toRoute, fromRoute, data)
  attachGridSelectorSnapshot(toRoute, data)
end

function M.onRouteLeave(context, toRoute, fromRoute, data)
  runPauseLifecycleIfAvailable("onPauseLeave", context, toRoute, fromRoute, data)
end

return M
