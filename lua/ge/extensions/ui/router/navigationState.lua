-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local Config = require("ge/extensions/ui/router/config")
local ResolvedRoute = require("ge/extensions/ui/router/models/ResolvedRoute")

local previousEntry = nil
local currentEntry = nil
local pendingEntry = nil
local decorator = { value = nil, moduleName = nil, visible = Config.ShowContextDecoratorInBreadcrumbs }
local lastActiveScopeByRoute = {}

local function resetLastActiveScopes()
  lastActiveScopeByRoute = {}
end

M.setLastActiveScope = function(routeName, scopeId)
  lastActiveScopeByRoute[routeName] = scopeId
end

M.getLastActiveScope = function(routeName)
  return lastActiveScopeByRoute[routeName]
end

M.clearLastActiveScope = function(routeName)
  if not routeName then
    return
  end

  lastActiveScopeByRoute[routeName] = nil
end

-- ---------------------------------------------------------------------------
-- Entry-based API
-- ---------------------------------------------------------------------------

M.setPendingEntry = function(entry)
  pendingEntry = entry
end

M.promotePendingEntry = function()
  previousEntry = currentEntry
  currentEntry = pendingEntry
  pendingEntry = nil
end

M.getCurrentEntry = function()
  return currentEntry
end

M.getPendingEntry = function()
  return pendingEntry
end

M.getPreviousEntry = function()
  return previousEntry
end

-- ---------------------------------------------------------------------------
-- Compatibility shims (same return shapes as the old API)
-- ---------------------------------------------------------------------------

M.getCurrentResolved = function()
  return currentEntry
end

M.getCurrentRouteNode = function()
  return currentEntry and currentEntry.routeNode
end

M.getPendingRouteNode = function()
  return pendingEntry and pendingEntry.routeNode
end

M.getBreadcrumbs = function()
  return currentEntry and currentEntry.resolved and currentEntry.resolved.breadcrumbs or {}
end

M.setPendingState = function(routeNode, data)
  pendingEntry = {
    request = data.request,
    resolved = data.resolved,
    origin = data.origin,
    routeNode = routeNode,
  }
end

M.promotePendingStates = function()
  M.promotePendingEntry()
end

M.setRequest = function() end

-- ---------------------------------------------------------------------------
-- Decorator
-- ---------------------------------------------------------------------------

local function resetDecorator()
  decorator.value = nil
  decorator.moduleName = nil
  decorator.visible = Config.ShowContextDecoratorInBreadcrumbs
end

M.setDecorator = function(value, moduleName)
  decorator.value = value
  decorator.moduleName = moduleName
end

M.getDecorator = function()
  return decorator.value
end

M.getDecoratorModule = function()
  return decorator.moduleName
end

M.setDecoratorVisible = function(visible)
  decorator.visible = visible
end

M.isDecoratorVisible = function()
  return decorator.visible
end

M.clearDecorator = function()
  resetDecorator()
end

-- ---------------------------------------------------------------------------
-- Serialize / Deserialize
-- ---------------------------------------------------------------------------

M.serialize = function()
  return {
    previousEntry = ResolvedRoute.toStorable(previousEntry),
    currentEntry = ResolvedRoute.toStorable(currentEntry),
    pendingEntry = ResolvedRoute.toStorable(pendingEntry),
    decorator = {
      value = decorator.value,
      moduleName = decorator.moduleName,
      visible = decorator.visible,
    },
  }
end

M.deserialize = function(data)
  if not data then return end
  previousEntry = ResolvedRoute.fromStorable(data.previousEntry)
  currentEntry = ResolvedRoute.fromStorable(data.currentEntry)
  pendingEntry = ResolvedRoute.fromStorable(data.pendingEntry)
  if data.decorator then
    decorator.value = data.decorator.value
    decorator.moduleName = data.decorator.moduleName
    decorator.visible = data.decorator.visible ~= nil and data.decorator.visible or Config.ShowContextDecoratorInBreadcrumbs
  else
    resetDecorator()
  end
end

M.reset = function()
  previousEntry = nil
  currentEntry = nil
  pendingEntry = nil
  resetLastActiveScopes()
  resetDecorator()
end

return M
