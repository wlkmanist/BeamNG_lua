-- Run with:
-- require("testFramework/TestManager"):runTestFiles("runtimeRouteRegistry")
-- or: extensions.testFramework_TestManager:runTestFiles("runtimeRouteRegistry")

local M = {}
local Registry = require("/lua/ge/extensions/ui/router/runtimeRouteRegistry")
local Constants = require("/lua/ge/extensions/ui/router/constants")

local function contains(list, value)
  for _, entry in ipairs(list) do
    if entry == value then
      return true
    end
  end
  return false
end

--MARK: parsing

function M.testParsesSingleNamedRouteWithVueDefaults(ctx)
  ctx:setDescription("A single named route gets vue-only ui defaults, runtime flag, and preserved meta")
  local parsed = Registry.parseRawRoutes({
    {name = "menu.play", path = "/play", meta = {some = "value"}},
  })

  ctx:assert(parsed.ok, "expected parse to succeed")
  ctx:assertEqual(#parsed.names, 1)
  ctx:assertEqual(parsed.names[1], "menu.play")

  local def = parsed.definitions["menu.play"]
  ctx:assert(def ~= nil, "expected definition for menu.play")
  ctx:assertEqual(def.runtime, true)
  ctx:assertEqual(def.ui.uiTypes[1], "vue")
  ctx:assertEqual(def.ui.uiTypesFilter, Constants.UiTypesFilter.only)
  ctx:assertEqual(def.meta.some, "value")
end

function M.testUnnamedGroupEmitsChildrenButNotItself(ctx)
  ctx:setDescription("Unnamed grouping nodes contribute their children but never themselves")
  local parsed = Registry.parseRawRoutes({
    {
      path = "/pause",
      children = {
        {name = "pause", path = ""},
        {name = "pause.system", path = "system"},
      },
    },
  })

  ctx:assert(parsed.ok, "expected parse to succeed")
  ctx:assertEqual(#parsed.names, 2)
  ctx:assert(parsed.definitions["pause"] ~= nil, "expected pause")
  ctx:assert(parsed.definitions["pause.system"] ~= nil, "expected pause.system")
end

function M.testParsesDeeplyNestedChildren(ctx)
  ctx:setDescription("Children are parsed recursively regardless of nesting depth")
  local parsed = Registry.parseRawRoutes({
    {
      name = "a",
      children = {
        {
          name = "a.b",
          children = {
            {name = "a.b.c"},
          },
        },
      },
    },
  })

  ctx:assert(parsed.ok, "expected parse to succeed")
  ctx:assertEqual(#parsed.names, 3)
  ctx:assertEqual(parsed.names[1], "a")
  ctx:assertEqual(parsed.names[2], "a.b")
  ctx:assertEqual(parsed.names[3], "a.b.c")
end

function M.testArrayRouteNamesShareDefinition(ctx)
  ctx:setDescription("A route with an array of names emits one definition per name")
  local parsed = Registry.parseRawRoutes({
    {name = {"pause.options", "pause.options.category"}, path = "/pause/options/:category?"},
  })

  ctx:assert(parsed.ok, "expected parse to succeed")
  ctx:assertEqual(#parsed.names, 2)
  ctx:assert(parsed.definitions["pause.options"] ~= nil, "expected pause.options")
  ctx:assert(parsed.definitions["pause.options.category"] ~= nil, "expected pause.options.category")
  -- distinct copies so mutating one never leaks into the sibling
  ctx:assert(parsed.definitions["pause.options"] ~= parsed.definitions["pause.options.category"],
    "array-name definitions must be independent copies")
end

function M.testMapsUiFieldsFromMeta(ctx)
  ctx:setDescription("Recognised meta UI fields are mapped into the ui config block")
  local parsed = Registry.parseRawRoutes({
    {
      name = "pause.hudApps",
      meta = {
        infoBar = {visible = true, showSysInfo = false},
        topBar = {visible = false},
        uiApps = {shown = true},
        triggerPause = true,
        uiNav = false,
        handlesOwnReady = true,
      },
    },
  })

  ctx:assert(parsed.ok, "expected parse to succeed")
  local def = parsed.definitions["pause.hudApps"]
  ctx:assertEqual(def.ui.infoBar.visible, true)
  ctx:assertEqual(def.ui.infoBar.showSysInfo, false)
  ctx:assertEqual(def.ui.topBar.visible, false)
  ctx:assertEqual(def.ui.uiApps.shown, true)
  ctx:assertEqual(def.ui.triggerPause, true)
  ctx:assertEqual(def.ui.uiNav, false)
  -- non-ui meta stays on meta and is not promoted to ui
  ctx:assertEqual(def.meta.handlesOwnReady, true)
  ctx:assertEqual(def.ui.handlesOwnReady, nil)
end

function M.testAppliesAllowlistedLuaRouteOverrides(ctx)
  ctx:setDescription("Allowlisted meta.luaRoute keys override config; unknown keys are ignored")
  local parsed = Registry.parseRawRoutes({
    {
      name = "garage.vehicle.save",
      meta = {
        luaRoute = {
          screenId = "garage.vehicle.save",
          title = "Save",
          abstract = true,
          backTarget = "garage",
          onEnter = "ui_router_routes_garage.onEnter",
          scopeTree = {["garage-vehicle-save"] = {}},
          ui = {uiTypes = {"vue", "angular"}},
          bogusKey = "nope",
        },
      },
    },
  })

  ctx:assert(parsed.ok, "expected parse to succeed")
  local def = parsed.definitions["garage.vehicle.save"]
  ctx:assertEqual(def.screenId, "garage.vehicle.save")
  ctx:assertEqual(def.title, "Save")
  ctx:assertEqual(def.abstract, true)
  ctx:assertEqual(def.backTarget, "garage")
  ctx:assertEqual(def.onEnter, "ui_router_routes_garage.onEnter")
  ctx:assert(def.scopeTree["garage-vehicle-save"] ~= nil, "expected scopeTree entry")
  -- luaRoute.ui merges over the vue defaults
  ctx:assertEqual(def.ui.uiTypes[1], "vue")
  ctx:assertEqual(def.ui.uiTypes[2], "angular")
  -- unknown keys are dropped
  ctx:assertEqual(def.bogusKey, nil)
end

--MARK: validation / transactional failures

function M.testRejectsInvalidLifecycleHook(ctx)
  ctx:setDescription("Lifecycle hooks must be 'module.func' string references")
  local parsed = Registry.parseRawRoutes({
    {name = "garage", meta = {luaRoute = {onEnter = "notavalidref"}}},
  })
  ctx:assert(not parsed.ok, "expected parse to fail for invalid onEnter")
  ctx:assert(#parsed.errors > 0, "expected at least one error")
end

function M.testRejectsFunctionLifecycleHook(ctx)
  ctx:setDescription("Lifecycle hooks may not be inline functions")
  local parsed = Registry.parseRawRoutes({
    {name = "garage", meta = {luaRoute = {onLeave = function() end}}},
  })
  ctx:assert(not parsed.ok, "expected parse to fail for function onLeave")
end

function M.testRejectsBackTargetAndFallbackTargetTogether(ctx)
  ctx:setDescription("backTarget and fallbackTarget cannot both be set on one route")
  local parsed = Registry.parseRawRoutes({
    {name = "garage", meta = {luaRoute = {backTarget = "menu", fallbackTarget = "play"}}},
  })
  ctx:assert(not parsed.ok, "expected parse to fail for back/fallback conflict")
end

function M.testRejectsDuplicateRouteNameWithinSource(ctx)
  ctx:setDescription("Duplicate route names within a single source are rejected")
  local parsed = Registry.parseRawRoutes({
    {name = "menu.play"},
    {name = "menu.play"},
  })
  ctx:assert(not parsed.ok, "expected parse to fail for duplicate name")
end

function M.testRejectsInvalidNameShape(ctx)
  ctx:setDescription("Route names must be non-empty strings or arrays of non-empty strings")
  ctx:assert(not Registry.parseRawRoutes({{name = 42}}).ok, "numeric name should fail")
  ctx:assert(not Registry.parseRawRoutes({{name = ""}}).ok, "empty name should fail")
  ctx:assert(not Registry.parseRawRoutes({{name = {"ok", ""}}}).ok, "empty array entry should fail")
  ctx:assert(not Registry.parseRawRoutes("not a table").ok, "non-table input should fail")
end

function M.testFailedReRegistrationKeepsPreviousSnapshot(ctx)
  ctx:setDescription("A failed re-registration leaves the source's prior snapshot intact")
  local reg = Registry.new()
  ctx:assert(reg:register("modA", {{name = "menu.play"}}).success, "initial register should succeed")

  local result = reg:register("modA", {{name = "menu.play", meta = {luaRoute = {onEnter = "bad"}}}})
  ctx:assert(not result.success, "expected re-registration to fail")

  -- the previous good snapshot must still be effective
  ctx:assert(reg:hasRoute("menu.play"), "menu.play should remain from the prior snapshot")
  ctx:assertEqual(reg:getRoute("menu.play").onEnter, nil, "prior snapshot had no onEnter")
end

--MARK: precedence + winners

function M.testNewestSourceWinsWithoutComposition(ctx)
  ctx:setDescription("When two sources define the same name, the newest wins and does not compose")
  local reg = Registry.new()
  reg:register("modA", {{name = "shared", meta = {luaRoute = {title = "A", screenId = "fromA"}}}})
  reg:register("modB", {{name = "shared", meta = {luaRoute = {title = "B"}}}})

  ctx:assertEqual(reg:getRouteSource("shared"), "modB", "newest source should win")
  local def = reg:getRoute("shared")
  ctx:assertEqual(def.title, "B")
  -- top-only: A's screenId must NOT bleed through into B's winning definition
  ctx:assertEqual(def.screenId, nil, "winner must not compose fields from the losing source")
end

function M.testReRegistrationRetainsOriginalPrecedence(ctx)
  ctx:setDescription("Re-registering an existing source keeps its original precedence slot")
  local reg = Registry.new()
  reg:register("modA", {{name = "shared", meta = {luaRoute = {title = "A"}}}})
  reg:register("modB", {{name = "shared", meta = {luaRoute = {title = "B"}}}})

  -- modA re-registers: it should keep its (older) slot, so modB still wins
  local result = reg:register("modA", {{name = "shared", meta = {luaRoute = {title = "A2"}}}})
  ctx:assertEqual(result.isNew, false, "re-registration is not a new source")
  ctx:assertEqual(reg:getRouteSource("shared"), "modB", "modB should still win after modA re-registers")
  ctx:assertEqual(reg:getRoute("shared").title, "B")
end

function M.testUnregisterThenRegisterCreatesNewPrecedence(ctx)
  ctx:setDescription("Unregistering then re-registering a source grants it the newest precedence")
  local reg = Registry.new()
  reg:register("modA", {{name = "shared", meta = {luaRoute = {title = "A"}}}})
  reg:register("modB", {{name = "shared", meta = {luaRoute = {title = "B"}}}})
  ctx:assertEqual(reg:getRouteSource("shared"), "modB")

  reg:unregister("modA")
  reg:register("modA", {{name = "shared", meta = {luaRoute = {title = "A2"}}}})

  ctx:assertEqual(reg:getRouteSource("shared"), "modA", "re-added modA should now be newest")
  ctx:assertEqual(reg:getRoute("shared").title, "A2")
end

function M.testUnregisterRestoresPreviousWinner(ctx)
  ctx:setDescription("Removing the winning source lets the next-newest source win again")
  local reg = Registry.new()
  reg:register("modA", {{name = "shared", meta = {luaRoute = {title = "A"}}}})
  reg:register("modB", {{name = "shared", meta = {luaRoute = {title = "B"}}}})
  ctx:assertEqual(reg:getRouteSource("shared"), "modB")

  local result = reg:unregister("modB")
  ctx:assert(result.existed, "modB existed")
  ctx:assertEqual(reg:getRouteSource("shared"), "modA", "modA should win after modB is removed")
  ctx:assertEqual(reg:getRoute("shared").title, "A")
end

function M.testSourceOrderTracksFirstRegistration(ctx)
  ctx:setDescription("Source order reflects first-registration order and survives re-registration")
  local reg = Registry.new()
  reg:register("modA", {{name = "a"}})
  reg:register("modB", {{name = "b"}})
  reg:register("modA", {{name = "a"}})

  local order = reg:getSourceOrder()
  ctx:assertEqual(#order, 2)
  ctx:assertEqual(order[1], "modA")
  ctx:assertEqual(order[2], "modB")
end

--MARK: stale-name removal + diffs

function M.testReRegistrationRemovesStaleNames(ctx)
  ctx:setDescription("Re-registering a source with fewer routes removes its stale names")
  local reg = Registry.new()
  reg:register("modA", {{name = "a"}, {name = "b"}})
  ctx:assert(reg:hasRoute("b"), "b should exist after first registration")

  local result = reg:register("modA", {{name = "a"}})
  ctx:assert(reg:hasRoute("a"), "a should remain")
  ctx:assert(not reg:hasRoute("b"), "b should be removed as a stale name")
  ctx:assert(contains(result.removed, "b"), "diff should report b as removed")
end

function M.testRegisterReportsAddedAndChangedDiffs(ctx)
  ctx:setDescription("Register returns effective added/changed diffs")
  local reg = Registry.new()
  local first = reg:register("modA", {{name = "a", meta = {luaRoute = {title = "A"}}}})
  ctx:assertEqual(first.isNew, true)
  ctx:assert(contains(first.added, "a"), "a should be reported as added")

  local second = reg:register("modA", {
    {name = "a", meta = {luaRoute = {title = "A-changed"}}},
    {name = "c"},
  })
  ctx:assert(contains(second.added, "c"), "c should be added")
  ctx:assert(contains(second.changed, "a"), "a should be changed")
  ctx:assert(not contains(second.changed, "c"), "c is added, not changed")
end

function M.testUnregisterReportsRemovedDiff(ctx)
  ctx:setDescription("Unregister reports the effective routes it removed")
  local reg = Registry.new()
  reg:register("modA", {{name = "a"}, {name = "b"}})
  local result = reg:unregister("modA")
  ctx:assert(result.existed, "source existed")
  ctx:assert(contains(result.removed, "a"), "a removed")
  ctx:assert(contains(result.removed, "b"), "b removed")
  ctx:assertEqual(#reg:getEffectiveNames(), 0, "no routes should remain")
end

function M.testUnregisterMissingSourceIsNoop(ctx)
  ctx:setDescription("Unregistering an unknown source succeeds as a no-op")
  local reg = Registry.new()
  local result = reg:unregister("ghost")
  ctx:assert(result.success, "unregister should succeed")
  ctx:assertEqual(result.existed, false)
  ctx:assertEqual(#result.removed, 0)
end

--MARK: isolation

function M.testEffectiveRoutesAreDeepCopied(ctx)
  ctx:setDescription("Mutating returned effective routes must not affect internal state")
  local reg = Registry.new()
  reg:register("modA", {{name = "a", meta = {luaRoute = {title = "A"}}}})

  local def = reg:getRoute("a")
  def.title = "mutated"
  def.ui.uiTypes[1] = "mutated"

  local fresh = reg:getRoute("a")
  ctx:assertEqual(fresh.title, "A", "internal title must be untouched")
  ctx:assertEqual(fresh.ui.uiTypes[1], "vue", "internal ui must be untouched")
end

function M.testSeparateRegistriesDoNotShareState(ctx)
  ctx:setDescription("Registry instances are independent")
  local a = Registry.new()
  local b = Registry.new()
  a:register("modA", {{name = "onlyInA"}})

  ctx:assert(a:hasRoute("onlyInA"), "a should have the route")
  ctx:assert(not b:hasRoute("onlyInA"), "b should not see a's route")
end

function M.testInvalidSourceIdRejected(ctx)
  ctx:setDescription("Registration requires a non-empty string sourceId")
  local reg = Registry.new()
  ctx:assert(not reg:register("", {{name = "a"}}).success, "empty sourceId should fail")
  ctx:assert(not reg:register(nil, {{name = "a"}}).success, "nil sourceId should fail")
end

return M
