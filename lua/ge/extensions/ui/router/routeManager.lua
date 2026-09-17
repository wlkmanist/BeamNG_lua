-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local Config = require("ge/extensions/ui/router/config")
local utils = require("ge/extensions/ui/router/utils")
local RootRegistry = require("ge/extensions/ui/router/routes")
local RuntimeRouteRegistry = require("ge/extensions/ui/router/runtimeRouteRegistry")
local routesDir = "/lua/ge/extensions/ui/router/routes/"
local routeExtensionPrefix = "ui_router_routes_"
local globalRoutesModuleName = "global"
local vueSyncSourceId = "__vueSync"
local M = {}

local runtimeRegistry = RuntimeRouteRegistry.new()

local function getRootRegistry()
  if not RootRegistry.Children then
    RootRegistry.Children = {}
  end
  return RootRegistry
end

M.RuntimeRoutes = {}
M.RuntimeRouteModules = {}
M.RegisteredRoutes = {}

local function invalidateCache()
  M.RegisteredRoutes = {}
end

local function findModule(moduleName)
  if FS:fileExists(routesDir .. moduleName .. ".lua") then
    local mod = extensions[routeExtensionPrefix .. moduleName]
    if not mod.Children then
      mod.Children = {}
    end
    return mod
  end
  return M.RuntimeRouteModules[moduleName] or nil
end

local function isArrayLike(t)
  if type(t) ~= "table" then
    return false
  end
  local count = 0
  for _ in pairs(t) do
    count = count + 1
  end
  if count == 0 then
    return false
  end
  for i = 1, count do
    if t[i] == nil then
      return false
    end
  end
  return true
end

local function mergeRouteField(base, overlay)
  if overlay == nil then
    return base
  end
  if type(base) == "table" and type(overlay) == "table" then
    if isArrayLike(base) then
      return overlay
    end
    local merged = {}
    for k, v in pairs(base) do
      merged[k] = v
    end
    for k, v in pairs(overlay) do
      merged[k] = mergeRouteField(merged[k], v)
    end
    return merged
  end
  return overlay
end

local function mergeRouteNode(base, overlay)
  local merged = deepcopy(base)
  for k, v in pairs(overlay) do
    if k == "Children" then
      if not merged.Children then
        merged.Children = {}
      end
      for childKey, childOverlay in pairs(v) do
        if merged.Children[childKey] then
          merged.Children[childKey] = mergeRouteNode(merged.Children[childKey], childOverlay)
        else
          merged.Children[childKey] = deepcopy(childOverlay)
        end
      end
    else
      merged[k] = mergeRouteField(merged[k], v)
    end
  end
  return merged
end

local function normalizeChildren(children, memo, buildStack, buildModule)
  if not children then
    return nil
  end

  local function normalizeNode(child)
    local subChildren = child.Children or child.children
    local node = {}
    for k, v in pairs(child) do
      if k ~= "children" and k ~= "Children" and k ~= "include" then
        node[k] = deepcopy(v)
      end
    end
    if subChildren then
      node.Children = normalizeChildren(subChildren, memo, buildStack, buildModule)
    end
    return node
  end

  local normalized = {}
  for key, child in pairs(children) do
    local includeName = type(child) == "table" and child.include or nil
    if includeName ~= nil then
      if type(includeName) ~= "string" or includeName == "" then
        log("W", "routeManager", "Route include must be a non-empty string, skipping entry")
      else
        local childKey = type(key) == "string" and key or includeName
        local includedRoot = buildModule(includeName, memo, buildStack)
        if includedRoot then
          local overlay = normalizeNode(child)
          if normalized[childKey] ~= nil then
            log("W", "routeManager", "Duplicate route child key '" .. childKey .. "' from include '" .. includeName .. "', overwriting")
          end
          normalized[childKey] = mergeRouteNode(includedRoot, overlay)
        else
          log("W", "routeManager", "Included route module '" .. includeName .. "' not found or cyclic, skipping")
        end
      end
    elseif type(key) ~= "string" then
      log("W", "routeManager", "Array-style route child requires an 'include' field, skipping entry")
    else
      normalized[key] = normalizeNode(child)
    end
  end
  return normalized
end

local function normalizeModuleTree(mod, memo, buildStack, buildModule)
  local root = deepcopy(mod.Root or {})
  root.children = nil
  root.Children = normalizeChildren(mod.Children, memo, buildStack, buildModule) or {}
  return root
end

local function buildRegisteredModule(moduleName, memo, buildStack)
  if memo[moduleName] then
    return memo[moduleName]
  end

  for _, name in ipairs(buildStack) do
    if name == moduleName then
      log("W", "routeManager",
          "Cycle detected in route includes: " .. table.concat(buildStack, " -> ") .. " -> " .. moduleName)
      return nil
    end
  end

  local mod = findModule(moduleName)
  if not mod then
    return nil
  end

  table.insert(buildStack, moduleName)
  local root = normalizeModuleTree(mod, memo, buildStack, buildRegisteredModule)
  table.remove(buildStack)

  memo[moduleName] = root
  return root
end

local function applyRuntimeOverlaysForModule(moduleName, root)
  for routeName, config in pairs(M.RuntimeRoutes) do
    local tokens = string.split(routeName, "[^%.]+")
    if tokens[1] == moduleName then
      if #tokens == 1 then
        root = mergeRouteNode(root, config)
      else
        local node = root
        for i = 2, #tokens do
          if not node.Children then
            node.Children = {}
          end
          if not node.Children[tokens[i]] then
            node.Children[tokens[i]] = {
              Children = {}
            }
          end
          if i == #tokens then
            node.Children[tokens[i]] = mergeRouteNode(node.Children[tokens[i]], config)
          else
            node = node.Children[tokens[i]]
          end
        end
      end
    end
  end
  return root
end

local function ensureRegisteredModule(moduleName)
  if M.RegisteredRoutes[moduleName] then
    return M.RegisteredRoutes[moduleName]
  end

  local memo = {}
  local buildStack = {}
  local root = buildRegisteredModule(moduleName, memo, buildStack)
  if not root then
    return nil
  end

  root = applyRuntimeOverlaysForModule(moduleName, root)
  M.RegisteredRoutes[moduleName] = root

  for name, built in pairs(memo) do
    if name ~= moduleName and not M.RegisteredRoutes[name] then
      M.RegisteredRoutes[name] = applyRuntimeOverlaysForModule(name, built)
    end
  end

  return root
end

local function ensureRegisteredRoutes()
  if next(M.RegisteredRoutes) == nil then
    M.resolveAllRoutes()
  end
end

local function extractRouteConfig(route)
  local excludedKeys = {
    children = true,
    Children = true,
    include = true
  }
  local config = {}
  for k, v in pairs(route) do
    if not excludedKeys[k] then
      config[k] = v
    end
  end
  return config
end

local function applyInheritedRouteConfig(route, inheritedConfig)
  -- only UI is inheritable for now
  if not route.ui then
    route.ui = {}
  end
  for k, v in pairs(inheritedConfig.ui) do
    if route.ui[k] == nil then
      route.ui[k] = v
    end
  end
  return route
end

local function createRuntimeModule(moduleName, settings)
  local mod = {
    ModuleName = moduleName,
    Children = {},
    Root = deepcopy(settings)
  }
  return mod
end

local function addRuntimeModule(mod)
  dump("adding runtime module: " .. mod.ModuleName)
  M.RuntimeRouteModules[mod.ModuleName] = mod
end

local function ensureModule(moduleName)
  local mod = findModule(moduleName)
  if mod then
    return mod
  end
  local runtimeMod = createRuntimeModule(moduleName, Constants.RouteConfigDefaults)
  addRuntimeModule(runtimeMod)
  return runtimeMod
end

-- Project the registry's effective winners into the resolution-facing state.
-- M.RuntimeRoutes maps route name -> winning definition overlay; synthesized
-- modules back runtime-only route families so the static tree can host them.
local function rebuildRuntimeState()
  M.RuntimeRoutes = runtimeRegistry:getEffectiveRoutes()
  M.RuntimeRouteModules = {}
  for routeName in pairs(M.RuntimeRoutes) do
    local moduleName = string.split(routeName, "[^%.]+")[1]
    ensureModule(moduleName)
  end
  invalidateCache()
end

local function getRootModuleNames()
  local modules = {}
  local rootMod = getRootRegistry()

  for _, entry in pairs(rootMod.Children) do
    if type(entry) == "table" and type(entry.include) == "string" and entry.include ~= "" then
      table.insert(modules, entry.include)
    else
      log("W", "routeManager", "Root route registry entries must be { include = \"module\" } tables, skipping invalid entry")
    end
  end
  return modules
end

local function collectRouteNames(routes, prefix, result)
  for key, route in pairs(routes) do
    local fullName = key == "" and prefix or (prefix .. "." .. key)
    table.insert(result, fullName)
    if route.Children then
      collectRouteNames(route.Children, fullName, result)
    end
  end
end

local function getGlobalRouteNames()
  local result = {}
  local mod = findModule(globalRoutesModuleName)
  if mod then
    for key, route in pairs(mod.Children) do
      table.insert(result, key)
    end
  end
  return result
end

M.getAllRoutes = function()
  ensureRegisteredRoutes()
  local result = {}
  local seen = {}
  local function add(routeName)
    if not seen[routeName] then
      seen[routeName] = true
      table.insert(result, routeName)
    end
  end

  for moduleName, root in pairs(M.RegisteredRoutes) do
    local mod = findModule(moduleName)
    if (not mod or not mod.ExcludeFromDiscovery) and root.Children then
      local names = {}
      collectRouteNames(root.Children, moduleName, names)
      for _, routeName in ipairs(names) do
        add(routeName)
      end
    end
  end

  -- add global route names
  for _, routeName in ipairs(getGlobalRouteNames()) do
    add(routeName)
  end

  -- add effective runtime names so runtime-only roots and overrides are
  -- discoverable; the seen set dedups any that already surfaced above.
  for _, routeName in ipairs(runtimeRegistry:getEffectiveNames()) do
    add(routeName)
  end

  return result
end

local function resolveRouteConfig(routeKey)
  local tokens = string.split(routeKey, "[^%.]+")
  local baseConfig = deepcopy(Constants.RouteConfigDefaults)

  -- if only 1 token check if it's a global route
  if #tokens == 1 then
    local globalRouteModule = findModule(globalRoutesModuleName)
    local globalRoute = globalRouteModule and globalRouteModule.Children[routeKey]
    if globalRoute then
      local routeCopy = deepcopy(globalRoute)
      -- the winning runtime definition (if any) overlays the static global; when
      -- the source is unregistered this override disappears and the static
      -- global is restored automatically.
      local runtimeOverride = M.RuntimeRoutes[routeKey]
      if runtimeOverride then
        routeCopy = mergeRouteNode(routeCopy, runtimeOverride)
      end
      routeCopy.global = true
      return applyInheritedRouteConfig(routeCopy, baseConfig)
    end
  end

  local root = ensureRegisteredModule(tokens[1])
  if not root then
    return nil
  end

  local fullConfig = applyInheritedRouteConfig(deepcopy(extractRouteConfig(root)), baseConfig)
  if #tokens == 1 then
    return fullConfig
  end

  local children = root.Children
  for i = 2, #tokens do
    local token = tokens[i]
    local foundRoute = children and children[token]
    if not foundRoute then
      return nil
    end

    fullConfig = applyInheritedRouteConfig(deepcopy(foundRoute), fullConfig)
    if i < #tokens then
      children = foundRoute.Children
      if not children then
        return nil
      end
    end
  end

  return fullConfig
end

local function getRouteConfig(routeKey)
  local routeConfig = resolveRouteConfig(routeKey)
  if routeConfig then
    routeConfig.name = routeKey
  end
  return routeConfig
end

local function getParent(route)
  local name = route.name
  local tokens = string.split(name, "[^%.]+")
  if #tokens == 1 then
    return nil
  end
  table.remove(tokens, #tokens)
  return getRouteConfig(table.concat(tokens, "."))
end

local function getBackTarget(route)
  if not route then
    return nil
  end

  if route.back then
    if route.back.mode == "rootExit" then
      -- call a special endpoint or something
      return nil
    end
  elseif route.backTarget then
    return route.backTarget
  else
    local parent = getParent(route)
    if parent and parent.abstract then
      return getBackTarget(parent)
    end
    if parent then
      return parent.name
    end
    if route.fallbackTarget then
      return route.fallbackTarget
    end
  end
end

M.getRoute = function(routeKey)
  local route = getRouteConfig(routeKey)
  if route then
    if route.backTarget and route.fallbackTarget then
      log("W", "routeManager", "Route '" .. routeKey .. "' has both backTarget and fallbackTarget; backTarget takes precedence")
    end
    route.backTarget = getBackTarget(route)
    if type(route.screenId) ~= "string" or route.screenId == "" then
      route.screenId = route.name
    end
  end
  return route
end

M.getRouteNodes = function(routeName)
  local tokens = string.split(routeName, "[^%.]+")
  local root = ensureRegisteredModule(tokens[1])

  if not root then
    return nil
  end

  local rootNode = extractRouteConfig(root)
  rootNode.key = tokens[1]
  rootNode.routeName = tokens[1]
  local routeNodes = {rootNode}

  if #tokens < 2 then
    return routeNodes
  end

  local currentRoute = root
  for i = 2, #tokens do
    local token = tokens[i]
    if not currentRoute.Children or not currentRoute.Children[token] then
      return nil
    end
    currentRoute = currentRoute.Children[token]
    local node = extractRouteConfig(currentRoute)
    node.key = token
    node.routeName = table.concat(tokens, ".", 1, i)
    routeNodes[i] = node
  end
  return routeNodes
end

-- Non-reconciling Vue dev/HMR sync entry point. Routes flow into the reserved
-- Vue-sync source only, so this can never disturb mod-registered sources. Active
-- route reconciliation is intentionally not performed here.
M.addVueRoutes = function(routesObject)
  local result = runtimeRegistry:register(vueSyncSourceId, routesObject or {})
  if not result.success then
    log("W", "routeManager", "addVueRoutes rejected: " .. table.concat(result.errors or {}, "; "))
    return
  end
  rebuildRuntimeState()
end

M.getModuleDecorator = function(routeName)
  local tokens = string.split(routeName, "[^%.]+")
  local mod = findModule(tokens[1])
  if mod and mod.ContextDecorator then
    return mod.ContextDecorator
  end
  return {
    mode = "dynamic",
    source = Config.ContextDecoratorDefaultSource
  }
end

-- Non-reconciling counterpart to addVueRoutes: clears only the reserved
-- Vue-sync source, leaving any mod-registered runtime sources intact.
M.removeRuntimeRoutes = function()
  runtimeRegistry:unregister(vueSyncSourceId)
  rebuildRuntimeState()
end

local function deepEqual(a, b)
  if a == b then
    return true
  end
  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end
  for k, v in pairs(a) do
    if not deepEqual(v, b[k]) then
      return false
    end
  end
  for k in pairs(b) do
    if a[k] == nil then
      return false
    end
  end
  return true
end

local function captureActiveRoute()
  local currentEntry = extensions.ui_router.getCurrent()
  local request = currentEntry and currentEntry.request
  local name = request and request.name
  if type(name) ~= "string" or name == "" then
    return nil
  end
  return {
    name = name,
    fullRoute = request.fullRoute or name,
    params = request.params,
    options = request.options,
    beforeConfig = M.getRoute(name),
  }
end

local function resolveFallbackRoute(mutationOptions)
  local fallbackRoute = mutationOptions and mutationOptions.fallbackRoute
  if type(fallbackRoute) == "string" and fallbackRoute ~= "" and M.getRoute(fallbackRoute) then
    return fallbackRoute
  end
  local missionFilename = type(getMissionFilename) == "function" and getMissionFilename() or nil
  if type(missionFilename) == "string" and missionFilename ~= "" then
    return "pause"
  end
  return "menu"
end

local function reconcileActiveRoute(captured, mutationOptions)
  if not captured then
    return { performed = false, action = "none", reason = "no_active_route" }
  end

  local afterConfig = M.getRoute(captured.name)
  if afterConfig == nil then
    local fallbackRoute = resolveFallbackRoute(mutationOptions)
    local navResult = extensions.ui_router.navigate(fallbackRoute)
    return {
      performed = true,
      action = "fallback",
      routeName = fallbackRoute,
      success = navResult and navResult.success == true,
      reason = navResult and navResult.reason or nil,
    }
  end

  if deepEqual(captured.beforeConfig, afterConfig) then
    return { performed = false, action = "none", reason = "unchanged" }
  end

  local navResult = extensions.ui_router.reload(captured.fullRoute, captured.params, captured.options)
  return {
    performed = true,
    action = "reload",
    routeName = captured.fullRoute,
    success = navResult and navResult.success == true,
    reason = navResult and navResult.reason or nil,
  }
end

M.registerModRoutes = function(sourceId, routes, options)
  local result = runtimeRegistry:register(sourceId, routes or {})
  if not result.success then
    log("W", "routeManager", "registerModRoutes rejected for source '" .. tostring(sourceId) .. "': " .. table.concat(result.errors or {}, "; "))
    return result
  end

  local captured = captureActiveRoute()
  rebuildRuntimeState()
  result.reconciliation = reconcileActiveRoute(captured, options)
  return result
end

M.unregisterModRoutes = function(sourceId, options)
  local result = runtimeRegistry:unregister(sourceId)
  if not result.success then
    log("W", "routeManager", "unregisterModRoutes rejected for source '" .. tostring(sourceId) .. "': " .. table.concat(result.errors or {}, "; "))
    return result
  end

  local captured = captureActiveRoute()
  rebuildRuntimeState()
  result.reconciliation = reconcileActiveRoute(captured, options)
  return result
end

M.resolveAllRoutes = function()
  M.RegisteredRoutes = {}

  -- Allow the root registry to declare which module holds the flat global routes.
  local rootMod = getRootRegistry()
  if rootMod and type(rootMod.Global) == "table" and type(rootMod.Global.include) == "string" and rootMod.Global.include ~= "" then
    globalRoutesModuleName = rootMod.Global.include
  end

  local moduleNames = getRootModuleNames()
  local seen = {}
  for _, name in ipairs(moduleNames) do
    seen[name] = true
  end
  for name, _ in pairs(M.RuntimeRouteModules) do
    if not seen[name] then
      table.insert(moduleNames, name)
    end
  end

  for _, moduleName in ipairs(moduleNames) do
    ensureRegisteredModule(moduleName)
  end
end

return M
