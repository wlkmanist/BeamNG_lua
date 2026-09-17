-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  ResolvedRoute Model

  Builds the canonical NavigationEntry used throughout the router.
  After createEntry() returns, the table is complete and should be
  treated as immutable -- no caller should mutate it.

  NavigationEntry shape:
    request   = { name, fullRoute, params, query, options }
    resolved  = { name, params, query, moduleName, meta, ui,
                  breadcrumbs, scope, scopes, backTarget, screenId, ... }
    origin    = { route = previousRequestName }
    toRoute   = { name, screenId, params, meta }   -- compat view
    fromRoute = { name, screenId, params, meta }   -- compat view
    routeNode = routeConfigRef                         -- internal, not serialized

  Note: `request.params` holds true screen params only. Router-control
  keys (e.g. preferredScope, decorator, showDecorator, loadingScreen)
  are kept on `request.options` so reload/back/replay flows can recover
  them without polluting the screen params.
]]

local Constants = require("ge/extensions/ui/router/constants")

local M = {}

local excludeKeys = { children = true, onEnter = true, onMount = true, onLeave = true }

local function isFunction(v)
  return type(v) == "function"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

M.createRequest = function(name, params, query, options, fullRoute)
  local canonicalName = name
  local normalizedFullRoute = type(fullRoute) == "string" and fullRoute ~= "" and fullRoute or canonicalName
  return {
    name = canonicalName,
    fullRoute = normalizedFullRoute,
    params = params or {},
    query = query or {},
    options = options or {},
  }
end

M.createResolved = function(routeConfig, request, extras)
  routeConfig = routeConfig or {}
  extras = extras or {}

  local resolved = {}

  for k, v in pairs(routeConfig) do
    if not excludeKeys[k] and not isFunction(v) then
      resolved[k] = v
    end
  end

  resolved.name = request.name
  resolved.params = request.params or {}
  resolved.query = request.query or {}

  for k, v in pairs(extras) do
    resolved[k] = v
  end

  if not resolved.ui then resolved.ui = {} end
  if not resolved.ui.uiTypes then resolved.ui.uiTypes = {"angular", "vue"} end
  if not resolved.ui.uiTypesFilter then resolved.ui.uiTypesFilter = Constants.UiTypesFilter.any end

  return resolved
end

M.toCompatRoute = function(resolved)
  if not resolved then return nil end
  return {
    name = resolved.name,
    screenId = resolved.screenId or resolved.name,
    params = resolved.params or {},
    meta = resolved.meta or {},
  }
end

M.createEntry = function(routeConfig, request, extras, previousEntry)
  local resolved = M.createResolved(routeConfig, request, extras)

  local origin = nil
  if previousEntry and previousEntry.request then
    origin = { route = previousEntry.request.name }
  end

  return {
    request = request,
    resolved = resolved,
    origin = origin,
    toRoute = M.toCompatRoute(resolved),
    fromRoute = previousEntry and M.toCompatRoute(previousEntry.resolved) or nil,
    routeNode = routeConfig,
  }
end

M.toStorable = function(entry)
  if not entry then return nil end

  local storedResolved = {}
  if entry.resolved then
    for k, v in pairs(entry.resolved) do
      if not isFunction(v) then
        storedResolved[k] = v
      end
    end
  end

  return {
    request = entry.request,
    resolved = storedResolved,
    origin = entry.origin,
    toRoute = entry.toRoute,
    fromRoute = entry.fromRoute,
  }
end

M.fromStorable = function(data)
  if not data then return nil end
  return {
    request = data.request,
    resolved = data.resolved,
    origin = data.origin,
    toRoute = data.toRoute or M.toCompatRoute(data.resolved),
    fromRoute = data.fromRoute,
    routeNode = nil,
  }
end

M.validate = function(entry)
  local errors = {}

  if entry == nil then
    table.insert(errors, "NavigationEntry is nil")
    return false, errors
  end

  if not entry.request or type(entry.request) ~= "table" then
    table.insert(errors, "request is required and must be a table")
  elseif not entry.request.name or type(entry.request.name) ~= "string" then
    table.insert(errors, "request.name is required and must be a string")
  end

  if not entry.resolved or type(entry.resolved) ~= "table" then
    table.insert(errors, "resolved is required and must be a table")
  else
    if not entry.resolved.name or type(entry.resolved.name) ~= "string" then
      table.insert(errors, "resolved.name is required and must be a string")
    end
    if type(entry.resolved.screenId) ~= "string" or entry.resolved.screenId == "" then
      table.insert(errors, "resolved.screenId is required and must be a non-empty string")
    end
    if entry.resolved.ui == nil or entry.resolved.ui.uiTypes == nil or type(entry.resolved.ui.uiTypes) ~= "table" then
      table.insert(errors, "resolved.ui.uiTypes is required and must be an array")
    end
  end

  return #errors == 0, errors
end

-- ---------------------------------------------------------------------------
-- Deprecated aliases -- kept so existing callers don't break during migration
-- ---------------------------------------------------------------------------

M.createNew = function()
end

M.create = function(config, name, params, query, moduleName)
  local request = M.createRequest(name, params, query, nil)
  local extras = {}
  if moduleName then extras.moduleName = moduleName end
  return M.createResolved(config, request, extras)
end

M.toMinimal = function(route)
  return {
    name = route.name,
    params = route.params,
    query = route.query,
  }
end

return M
