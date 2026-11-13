-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("routeManager")
--
-- Manual runtime smoke check for scoped relative navigation + reload stability
-- (needs a running game with an active route, e.g. while paused):
--   local r = extensions.ui_router
--   r.navigate("pause")
--   r.navigate("./options:options-search")
--   local cur = r.getCurrent()
--   dump({name = cur.request.name, fullRoute = cur.request.fullRoute})
--   -- expect name == "pause.options", fullRoute == "pause.options:options-search"
--   r.reload()
--   -- current route name/fullRoute must stay identical (no re-resolution drift)

local M = {}
local RouteManager = require("/lua/ge/extensions/ui/router/routeManager")

--MARK: relative resolution (pure)

function M.testAbsoluteReferenceUnchanged(ctx)
  ctx:setDescription("A dotted absolute reference passes through unchanged")
  local name, err = RouteManager.resolveRouteName("pause.options", "menu")
  ctx:assert(err == nil, "expected no error")
  ctx:assertEqual(name, "pause.options")
end

function M.testAbsoluteGlobalReferencesUnchanged(ctx)
  ctx:setDescription("Global one-segment and slash-prefixed references stay absolute")
  ctx:assertEqual(RouteManager.resolveRouteName("play", "pause"), "play")
  ctx:assertEqual(RouteManager.resolveRouteName("/mainmenu", "pause"), "/mainmenu")
  ctx:assertEqual(RouteManager.resolveRouteName("menu", nil), "menu")
end

function M.testRelativeChild(ctx)
  ctx:setDescription("'./x' resolves to a child of the base route")
  local name, err = RouteManager.resolveRouteName("./options", "pause")
  ctx:assert(err == nil, "expected no error")
  ctx:assertEqual(name, "pause.options")
end

function M.testRelativeDeeperChild(ctx)
  ctx:setDescription("'./x' resolves to a child of a nested base route")
  ctx:assertEqual(RouteManager.resolveRouteName("./category", "pause.options"), "pause.options.category")
end

function M.testRelativeSibling(ctx)
  ctx:setDescription("'../x' resolves to a sibling of the base route")
  ctx:assertEqual(RouteManager.resolveRouteName("../options", "pause.system"), "pause.options")
end

function M.testRelativeParent(ctx)
  ctx:setDescription("'..' resolves to the parent of the base route")
  ctx:assertEqual(RouteManager.resolveRouteName("..", "pause.options"), "pause")
end

function M.testRelativeSelf(ctx)
  ctx:setDescription("'.' resolves to the base route itself")
  ctx:assertEqual(RouteManager.resolveRouteName(".", "pause.options"), "pause.options")
end

function M.testRelativeMultiParent(ctx)
  ctx:setDescription("Chained '../..' walks up multiple levels before appending")
  ctx:assertEqual(RouteManager.resolveRouteName("../../system", "pause.options.category"), "pause.system")
end

function M.testRelativeIdempotentAfterResolution(ctx)
  ctx:setDescription("Re-resolving a canonical name yields itself (reload stability)")
  local name = RouteManager.resolveRouteName("./options", "pause")
  ctx:assertEqual(name, "pause.options")
  -- canonical names are absolute, so a follow-up resolve (e.g. reload) is a no-op
  ctx:assertEqual(RouteManager.resolveRouteName(name, "pause"), "pause.options")
end

function M.testRelativeWithoutBaseFails(ctx)
  ctx:setDescription("A relative reference without a base route is rejected")
  local nilName, err = RouteManager.resolveRouteName("./options", nil)
  ctx:assert(nilName == nil, "expected no resolved name")
  ctx:assertEqual(err, "relative_route_without_base")

  local nilName2, err2 = RouteManager.resolveRouteName("..", "")
  ctx:assert(nilName2 == nil, "expected no resolved name for empty base")
  ctx:assertEqual(err2, "relative_route_without_base")
end

function M.testRelativeAboveRootFails(ctx)
  ctx:setDescription("Traversing above the namespace root is rejected")
  local nilName, err = RouteManager.resolveRouteName("../../options", "pause")
  ctx:assert(nilName == nil, "expected no resolved name")
  ctx:assertEqual(err, "invalid_relative_route")

  local nilName2, err2 = RouteManager.resolveRouteName("..", "pause")
  ctx:assert(nilName2 == nil, "expected no resolved name when parent underflows to empty")
  ctx:assertEqual(err2, "invalid_relative_route")
end

function M.testInvalidReferenceFails(ctx)
  ctx:setDescription("Empty or non-string references are rejected")
  local nilName, err = RouteManager.resolveRouteName("", "pause")
  ctx:assert(nilName == nil, "expected no resolved name for empty string")
  ctx:assertEqual(err, "invalid_relative_route")

  local nilName2, err2 = RouteManager.resolveRouteName(nil, "pause")
  ctx:assert(nilName2 == nil, "expected no resolved name for nil reference")
  ctx:assertEqual(err2, "invalid_relative_route")
end

--MARK: declarative targets (via getRoute + temporary runtime routes)

local function withModRoutes(sourceId, routes, fn)
  local RM = extensions.ui_router_routeManager
  local registerResult = RM.registerModRoutes(sourceId, routes)
  local ok, resultOrErr = pcall(fn, RM, registerResult)
  RM.unregisterModRoutes(sourceId)
  if not ok then
    error(resultOrErr)
  end
  return resultOrErr
end

function M.testRelativeBackTargetResolvesToParent(ctx)
  ctx:setDescription("A relative '..' backTarget resolves against its declaring route")
  withModRoutes("reltest_bt", {
    {name = "reltestbt"},
    {name = "reltestbt.system", meta = {luaRoute = {backTarget = ".."}}},
    {name = "reltestbt.options", meta = {luaRoute = {backTarget = "../system"}}},
  }, function(RM, registerResult)
    ctx:assert(registerResult.success, "expected mod route registration to succeed")

    local systemRoute = RM.getRoute("reltestbt.system")
    ctx:assert(systemRoute ~= nil, "expected reltestbt.system to resolve")
    ctx:assertEqual(systemRoute.backTarget, "reltestbt")

    local optionsRoute = RM.getRoute("reltestbt.options")
    ctx:assert(optionsRoute ~= nil, "expected reltestbt.options to resolve")
    ctx:assertEqual(optionsRoute.backTarget, "reltestbt.system")
  end)
end

function M.testRelativeFallbackTargetResolves(ctx)
  ctx:setDescription("A relative fallbackTarget resolves against its declaring root route")
  withModRoutes("reltest_fb", {
    {name = "reltestfb", meta = {luaRoute = {fallbackTarget = "./target"}}},
  }, function(RM)
    local route = RM.getRoute("reltestfb")
    ctx:assert(route ~= nil, "expected reltestfb to resolve")
    ctx:assertEqual(route.backTarget, "reltestfb.target")
  end)
end

function M.testUiNavDefaultsToTrueWhenOmitted(ctx)
  ctx:setDescription("uiNav resolves to true when a route does not set it")
  withModRoutes("uinav_default", {
    {name = "uinavdefault"},
  }, function(RM)
    local route = RM.getRoute("uinavdefault")
    ctx:assert(route ~= nil, "expected uinavdefault to resolve")
    ctx:assertEqual(route.ui.uiNav, true)
  end)
end

function M.testUiNavExplicitFalseSurvivesInheritance(ctx)
  ctx:setDescription("An explicit ui.uiNav = false is preserved instead of the default")
  withModRoutes("uinav_optout", {
    {name = "uinavoptout", meta = {uiNav = false}},
  }, function(RM)
    local route = RM.getRoute("uinavoptout")
    ctx:assert(route ~= nil, "expected uinavoptout to resolve")
    ctx:assertEqual(route.ui.uiNav, false)
  end)
end

function M.testUiNavStaticPlayOptOut(ctx)
  ctx:setDescription("The static play route opts out of uiNav via ui.uiNav = false")
  local RM = extensions.ui_router_routeManager
  local route = RM.getRoute("play")
  ctx:assert(route ~= nil, "expected play to resolve")
  ctx:assertEqual(route.ui.uiNav, false)
end

function M.testUiNavStaticMultiseatOptOut(ctx)
  ctx:setDescription("The static multiseat root opts out of uiNav via ui.uiNav = false")
  local RM = extensions.ui_router_routeManager
  local route = RM.getRoute("multiseat")
  ctx:assert(route ~= nil, "expected multiseat to resolve")
  ctx:assertEqual(route.ui.uiNav, false)
end

function M.testAbstractParentRelativeBackTargetUsesParentBase(ctx)
  ctx:setDescription("An abstract parent's relative backTarget resolves against the parent, not the active child")
  withModRoutes("reltest_ap", {
    {name = "reltestap"},
    {name = "reltestap.grp", meta = {luaRoute = {abstract = true, backTarget = ".."}}},
    {name = "reltestap.grp.leaf"},
  }, function(RM)
    local leafRoute = RM.getRoute("reltestap.grp.leaf")
    ctx:assert(leafRoute ~= nil, "expected reltestap.grp.leaf to resolve")
    -- '..' declared on the abstract parent (reltestap.grp) must resolve to reltestap,
    -- not to reltestap.grp (which is what a child-based resolution would produce).
    ctx:assertEqual(leafRoute.backTarget, "reltestap")
  end)
end

return M
