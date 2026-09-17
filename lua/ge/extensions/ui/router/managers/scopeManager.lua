-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local NavigationState = require("ge/extensions/ui/router/navigationState")
local reservedKeys = { backTarget = true, backTargetType = true, optional = true, escapeTargets = true, preferAutoFocus = true }

local function getScopeTreeRoot(route)
  if type(route.scopeTree) == "table" then
    for scopeName, _ in pairs(route.scopeTree) do
      return scopeName
    end
  end
  return nil
end

local function asNonEmptyString(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

M.isScopeDeclaredInTree = function(scopeTree, scopeId)
  if type(scopeTree) ~= "table" then
    return false
  end

  local canonicalScopeId = asNonEmptyString(scopeId)
  if not canonicalScopeId then
    return false
  end

  local scopeParentMap = M.buildScopeParentMap(scopeTree)
  return scopeParentMap[canonicalScopeId] ~= nil
end

M.getTargetScope = function(route, options)
  options = options and type(options) == "table" and options or {}
  local routeName = asNonEmptyString(route and route.name)
  local scopeTree = route and route.scopeTree or nil
  local routeScopeId = asNonEmptyString(options.routeScopeId)
  local preferredScope = asNonEmptyString(options.preferredScope)
  local defaultTargetScope = asNonEmptyString(route and route.targetScope)
  if routeScopeId and preferredScope then
    log("W", "ScopeManager", "Both routeScopeId and preferredScope were provided for route '" ..
      tostring(route and route.name or "unknown") .. "'; routeScopeId takes precedence.")
  end

  local targetScope = routeScopeId or preferredScope
  if not targetScope and options.restoreLastScope == true and routeName then
    local rememberedScope = asNonEmptyString(NavigationState.getLastActiveScope(routeName))
    if rememberedScope then
      if M.isScopeDeclaredInTree(scopeTree, rememberedScope) then
        targetScope = rememberedScope
      else
        NavigationState.clearLastActiveScope(routeName)
      end
    end
  end

  return {
    targetScope = targetScope or defaultTargetScope or getScopeTreeRoot(route),
  }
end

M.buildScopeParentMap = function(scopeTree)
  if not scopeTree then return {} end
  local map = {}
  local function walk(node, parentScopeId)
    for key, value in pairs(node) do
      if not reservedKeys[key] and type(value) == "table" then
        map[key] = {
          parentScopeId = parentScopeId,
          isRoot = parentScopeId == false,
          backTarget = value.backTarget,
          backTargetType = value.backTargetType,
          optional = value.optional == true,
          escapeTargets = value.escapeTargets,
          preferAutoFocus = value.preferAutoFocus == true,
        }
        walk(value, key)
      end
    end
  end
  walk(scopeTree, false)
  return map
end

return M