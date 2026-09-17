-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Pure runtime route registry + raw Vue-route parser.
--
-- This module has no game-side side effects: it only parses raw Vue route
-- arrays into router route-config overlays and tracks which registered source
-- owns each effective route name. The route manager consumes the effective
-- winners to overlay them onto the static Lua route tree.
--
-- A registry instance (M.new()) owns:
--   * source snapshots keyed by sourceId (parsed names + definitions)
--   * a stable first-registration order used for precedence
--   * per-name winner derivation (newest registered source wins, no compose)
--
-- Parsing is transactional: an invalid raw route array is rejected in full and
-- never replaces the previous snapshot for that source.
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

-- meta fields that map onto the router `ui` config block
local UI_META_KEYS = {"uiTypes", "uiTypesFilter", "infoBar", "topBar", "uiApps", "triggerPause"}

-- keys a mod may set via meta.luaRoute to override router route config
local LUA_ROUTE_ALLOWLIST = {
  screenId = true,
  title = true,
  abstract = true,
  scopeTree = true,
  backTarget = true,
  fallbackTarget = true,
  back = true,
  onEnter = true,
  onMount = true,
  onLeave = true,
  ui = true,
}

local LIFECYCLE_KEYS = {"onEnter", "onMount", "onLeave"}

-- Lifecycle hooks must stay declarative "module.func" string references.
local function isValidHookRef(ref)
  if type(ref) ~= "string" or ref == "" then
    return false
  end
  local lastDot = ref:match("^.*()%.")
  if not lastDot then
    return false
  end
  local moduleName = ref:sub(1, lastDot - 1)
  local funcName = ref:sub(lastDot + 1)
  return moduleName ~= "" and funcName ~= ""
end

-- Build a route-config overlay for a single raw Vue route, layering (in order):
--   1. Vue runtime defaults (vue-only ui, runtime flag)
--   2. preserved meta
--   3. mapped UI fields pulled from meta
--   4. allowlisted meta.luaRoute overrides
local function buildDefinition(rawRoute)
  local def = {
    runtime = true,
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
    },
  }

  local meta = rawRoute.meta
  def.meta = deepcopy(meta or {})

  if type(meta) == "table" then
    for _, key in ipairs(UI_META_KEYS) do
      if meta[key] ~= nil then
        def.ui[key] = deepcopy(meta[key])
      end
    end

    local luaRoute = meta.luaRoute
    if type(luaRoute) == "table" then
      for k, v in pairs(luaRoute) do
        if LUA_ROUTE_ALLOWLIST[k] then
          if k == "ui" and type(v) == "table" then
            for uiKey, uiValue in pairs(v) do
              def.ui[uiKey] = deepcopy(uiValue)
            end
          else
            def[k] = deepcopy(v)
          end
        else
          log("W", "runtimeRouteRegistry", "Ignoring unsupported meta.luaRoute key: " .. tostring(k))
        end
      end
    end
  end

  return def
end

local function validateDefinition(def, routeName, errors)
  for _, key in ipairs(LIFECYCLE_KEYS) do
    local ref = def[key]
    if ref ~= nil and not isValidHookRef(ref) then
      table.insert(errors, string.format("route %q: %s must be a 'module.func' string reference", routeName, key))
    end
  end

  if def.backTarget ~= nil and def.fallbackTarget ~= nil then
    table.insert(errors, string.format("route %q: backTarget and fallbackTarget cannot both be set", routeName))
  end
end

-- Resolve the route name(s) declared on a raw route. Returns an array of names
-- (empty for unnamed grouping nodes). Shape problems are appended to errors.
local function extractNames(rawRoute, errors, index)
  local name = rawRoute.name
  if name == nil then
    return {}
  end

  if type(name) == "string" then
    if name == "" then
      table.insert(errors, string.format("route #%d: name must be a non-empty string", index))
      return {}
    end
    return {name}
  end

  if type(name) == "table" then
    local names = {}
    local hasEntry = false
    for _, entry in ipairs(name) do
      hasEntry = true
      if type(entry) ~= "string" or entry == "" then
        table.insert(errors, string.format("route #%d: name array entries must be non-empty strings", index))
      else
        table.insert(names, entry)
      end
    end
    if not hasEntry then
      table.insert(errors, string.format("route #%d: name array must not be empty", index))
    end
    return names
  end

  table.insert(errors, string.format("route #%d: name must be a string or array of strings", index))
  return {}
end

-- Parse a raw Vue route array into an ordered list of route names and a
-- name -> route-config-overlay map. Recurses into `children` for both named and
-- unnamed nodes. Any error rejects the whole parse (transactional).
local function parseRawRoutes(rawRoutes)
  local errors = {}
  local names = {}
  local definitions = {}
  local seen = {}

  if type(rawRoutes) ~= "table" then
    return {ok = false, errors = {"raw routes must be an array table"}, names = {}, definitions = {}}
  end

  local function walk(routes)
    if type(routes) ~= "table" then
      table.insert(errors, "children must be an array table")
      return
    end

    for index, rawRoute in ipairs(routes) do
      if type(rawRoute) ~= "table" then
        table.insert(errors, string.format("route #%d: entry must be a table", index))
      else
        local metaOk = true
        if rawRoute.meta ~= nil and type(rawRoute.meta) ~= "table" then
          table.insert(errors, string.format("route #%d: meta must be a table", index))
          metaOk = false
        elseif type(rawRoute.meta) == "table" and rawRoute.meta.luaRoute ~= nil and type(rawRoute.meta.luaRoute) ~= "table" then
          table.insert(errors, string.format("route #%d: meta.luaRoute must be a table", index))
          metaOk = false
        end

        if metaOk then
          local routeNames = extractNames(rawRoute, errors, index)
          if #routeNames > 0 then
            local def = buildDefinition(rawRoute)
            for _, routeName in ipairs(routeNames) do
              validateDefinition(def, routeName, errors)
              if seen[routeName] then
                table.insert(errors, string.format("duplicate route name %q within source", routeName))
              else
                seen[routeName] = true
                table.insert(names, routeName)
                definitions[routeName] = deepcopy(def)
              end
            end
          end
        end

        if rawRoute.children ~= nil then
          walk(rawRoute.children)
        end
      end
    end
  end

  walk(rawRoutes)

  if #errors > 0 then
    return {ok = false, errors = errors, names = {}, definitions = {}}
  end
  return {ok = true, errors = {}, names = names, definitions = definitions}
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

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

-- Derive effective winners across all sources in registration order. Later
-- (newer) sources overwrite earlier ones for the same name: no composition.
local function computeEffective(reg)
  local effective = {}
  local winners = {}
  for _, sourceId in ipairs(reg.order) do
    local snapshot = reg.sources[sourceId]
    if snapshot then
      for _, name in ipairs(snapshot.names) do
        effective[name] = snapshot.definitions[name]
        winners[name] = sourceId
      end
    end
  end
  return effective, winners
end

local function diffEffective(before, after)
  local added, removed, changed = {}, {}, {}
  for _, name in ipairs(sortedKeys(after)) do
    if before[name] == nil then
      table.insert(added, name)
    elseif not deepEqual(before[name], after[name]) then
      table.insert(changed, name)
    end
  end
  for _, name in ipairs(sortedKeys(before)) do
    if after[name] == nil then
      table.insert(removed, name)
    end
  end
  return {added = added, removed = removed, changed = changed}
end

local function registryRegister(reg, sourceId, rawRoutes)
  if type(sourceId) ~= "string" or sourceId == "" then
    return {success = false, errors = {"sourceId must be a non-empty string"}}
  end

  local parsed = parseRawRoutes(rawRoutes)
  if not parsed.ok then
    -- transactional: leave any existing snapshot for this source untouched
    return {success = false, sourceId = sourceId, errors = parsed.errors}
  end

  local before = computeEffective(reg)

  local isNew = reg.sources[sourceId] == nil
  reg.sources[sourceId] = {names = parsed.names, definitions = parsed.definitions}
  if isNew then
    -- new source claims the newest precedence slot; re-registration keeps its slot
    table.insert(reg.order, sourceId)
  end

  local after = computeEffective(reg)
  local diff = diffEffective(before, after)

  return {
    success = true,
    sourceId = sourceId,
    isNew = isNew,
    names = deepcopy(parsed.names),
    added = diff.added,
    removed = diff.removed,
    changed = diff.changed,
  }
end

local function registryUnregister(reg, sourceId)
  if type(sourceId) ~= "string" or sourceId == "" then
    return {success = false, errors = {"sourceId must be a non-empty string"}}
  end

  if reg.sources[sourceId] == nil then
    return {success = true, sourceId = sourceId, existed = false, added = {}, removed = {}, changed = {}}
  end

  local before = computeEffective(reg)
  reg.sources[sourceId] = nil
  for i, id in ipairs(reg.order) do
    if id == sourceId then
      table.remove(reg.order, i)
      break
    end
  end

  local after = computeEffective(reg)
  local diff = diffEffective(before, after)

  return {
    success = true,
    sourceId = sourceId,
    existed = true,
    added = diff.added,
    removed = diff.removed,
    changed = diff.changed,
  }
end

local function registryGetEffectiveRoutes(reg)
  local effective = computeEffective(reg)
  local out = {}
  for name, def in pairs(effective) do
    out[name] = deepcopy(def)
  end
  return out
end

local function registryGetEffectiveNames(reg)
  local effective = computeEffective(reg)
  return sortedKeys(effective)
end

local function registryGetRoute(reg, name)
  local effective = computeEffective(reg)
  local def = effective[name]
  return def and deepcopy(def) or nil
end

local function registryGetRouteSource(reg, name)
  local _, winners = computeEffective(reg)
  return winners[name]
end

local function registryHasRoute(reg, name)
  local effective = computeEffective(reg)
  return effective[name] ~= nil
end

local function registryHasSource(reg, sourceId)
  return reg.sources[sourceId] ~= nil
end

local function registryGetSourceOrder(reg)
  return deepcopy(reg.order)
end

local function registryClear(reg)
  reg.sources = {}
  reg.order = {}
end

-- Create an isolated registry instance. The route manager holds one; tests can
-- spin up as many independent instances as they need.
local function createRegistry()
  local reg = {
    sources = {},
    order = {},
  }

  function reg:register(sourceId, rawRoutes)
    return registryRegister(self, sourceId, rawRoutes)
  end
  function reg:unregister(sourceId)
    return registryUnregister(self, sourceId)
  end
  function reg:getEffectiveRoutes()
    return registryGetEffectiveRoutes(self)
  end
  function reg:getEffectiveNames()
    return registryGetEffectiveNames(self)
  end
  function reg:getRoute(name)
    return registryGetRoute(self, name)
  end
  function reg:getRouteSource(name)
    return registryGetRouteSource(self, name)
  end
  function reg:hasRoute(name)
    return registryHasRoute(self, name)
  end
  function reg:hasSource(sourceId)
    return registryHasSource(self, sourceId)
  end
  function reg:getSourceOrder()
    return registryGetSourceOrder(self)
  end
  function reg:clear()
    return registryClear(self)
  end

  return reg
end

M.new = createRegistry
M.parseRawRoutes = parseRawRoutes
M.isValidHookRef = isValidHookRef

return M
