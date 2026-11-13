-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("routeReference")

local M = {}
local RouteReference = require("/lua/ge/extensions/ui/router/routeReference")
local ResolvedRoute = require("/lua/ge/extensions/ui/router/models/ResolvedRoute")
local NavigationContext = require("/lua/ge/extensions/ui/router/services/navigationContext")

--MARK: parsing (pure)

function M.testPlainRouteHasNoDecoration(ctx)
  ctx:setDescription("A plain dotted route parses with no scope and no params")
  local parsed = RouteReference.parse("career.vehicleShopping")
  ctx:assertEqual(parsed.route, "career.vehicleShopping")
  ctx:assert(parsed.scope == nil, "expected no scope")
  ctx:assert(next(parsed.params) == nil, "expected no inline params")
end

function M.testScopeOnlyReference(ctx)
  ctx:setDescription("'route:scope' splits the scope suffix off the route")
  local parsed = RouteReference.parse("pause.options:options-search")
  ctx:assertEqual(parsed.route, "pause.options")
  ctx:assertEqual(parsed.scope, "options-search")
  ctx:assert(next(parsed.params) == nil, "expected no inline params")
end

function M.testQueryOnlyReference(ctx)
  ctx:setDescription("'route?a=1&b=2' parses inline params as strings")
  local parsed = RouteReference.parse("career.vehicleShopping?sellerId=2&tab=used")
  ctx:assertEqual(parsed.route, "career.vehicleShopping")
  ctx:assert(parsed.scope == nil, "expected no scope")
  ctx:assertEqual(parsed.params.sellerId, "2")
  ctx:assertEqual(parsed.params.tab, "used")
end

function M.testQueryAndScopeReference(ctx)
  ctx:setDescription("'route?query:scope' parses query before the scope suffix")
  local parsed = RouteReference.parse("career.vehicleShopping?sellerId=2:shop-list")
  ctx:assertEqual(parsed.route, "career.vehicleShopping")
  ctx:assertEqual(parsed.scope, "shop-list")
  ctx:assertEqual(parsed.params.sellerId, "2")
end

function M.testRelativeRoutePreservedThroughParse(ctx)
  ctx:setDescription("A relative reference keeps its relative route part with decoration stripped")
  local parsed = RouteReference.parse("./options?theme=dark:options-search")
  ctx:assertEqual(parsed.route, "./options")
  ctx:assertEqual(parsed.scope, "options-search")
  ctx:assertEqual(parsed.params.theme, "dark")
end

function M.testUrlDecodingOfQueryValues(ctx)
  ctx:setDescription("Percent-encoded and '+' query values are decoded")
  local parsed = RouteReference.parse("mission.detail?name=Grand%20Prix&note=a%2Bb&city=New+York")
  ctx:assertEqual(parsed.params.name, "Grand Prix")
  ctx:assertEqual(parsed.params.note, "a+b")
  ctx:assertEqual(parsed.params.city, "New York")
end

function M.testUrlDecodingOfEncodedKeyAndDelimiters(ctx)
  ctx:setDescription("Encoded keys and encoded reserved chars survive decoding")
  local parsed = RouteReference.parse("route?a%3Db=x%26y")
  ctx:assertEqual(parsed.params["a=b"], "x&y")
end

function M.testRepeatedInlineKeyKeepsLastValue(ctx)
  ctx:setDescription("Repeated inline keys keep the last value")
  local parsed = RouteReference.parse("route?id=1&id=2&id=3")
  ctx:assertEqual(parsed.params.id, "3")
end

function M.testBareKeyResolvesToEmptyString(ctx)
  ctx:setDescription("A bare inline key (no '=') resolves to an empty string value")
  local parsed = RouteReference.parse("route?flag&id=7")
  ctx:assertEqual(parsed.params.flag, "")
  ctx:assertEqual(parsed.params.id, "7")
end

--MARK: malformed inputs

function M.testMalformedEmptyScopeTreatedAsPlain(ctx)
  ctx:setDescription("'route:' with an empty scope is treated as an undecorated route")
  local parsed = RouteReference.parse("route:")
  ctx:assertEqual(parsed.route, "route:")
  ctx:assert(parsed.scope == nil, "expected no scope for empty scope suffix")
end

function M.testMalformedEmptyRouteTreatedAsWhole(ctx)
  ctx:setDescription("A reference with an empty route part falls back to the whole string")
  local parsed = RouteReference.parse(":scope")
  ctx:assertEqual(parsed.route, ":scope")
  ctx:assert(parsed.scope == nil, "expected no scope when route part is empty")
end

function M.testMalformedLeadingQueryTreatedAsWhole(ctx)
  ctx:setDescription("A reference starting with '?' keeps the whole string as the route")
  local parsed = RouteReference.parse("?a=1")
  ctx:assertEqual(parsed.route, "?a=1")
  ctx:assert(next(parsed.params) == nil, "expected no inline params for empty route part")
end

function M.testEmptyQuerySegmentsIgnored(ctx)
  ctx:setDescription("Empty query segments (&&) are ignored")
  local parsed = RouteReference.parse("route?a=1&&b=2")
  ctx:assertEqual(parsed.params.a, "1")
  ctx:assertEqual(parsed.params.b, "2")
end

function M.testNonStringReferencePassesThrough(ctx)
  ctx:setDescription("A non-string reference passes through with empty params")
  local parsed = RouteReference.parse(nil)
  ctx:assert(parsed.route == nil, "expected nil route to pass through")
  ctx:assert(next(parsed.params) == nil, "expected no inline params")
end

--MARK: merge precedence

function M.testExplicitParamsOverrideInline(ctx)
  ctx:setDescription("Explicit params win over inline params on collision")
  local parsed = RouteReference.parse("route?id=inline&keep=inline")
  local merged = RouteReference.mergeParams(parsed.params, { id = "explicit", extra = 5 })
  ctx:assertEqual(merged.id, "explicit")
  ctx:assertEqual(merged.keep, "inline")
  ctx:assertEqual(merged.extra, 5)
end

function M.testMergeWithoutExplicitKeepsInline(ctx)
  ctx:setDescription("Merging with no explicit params keeps inline params")
  local parsed = RouteReference.parse("route?id=inline")
  local merged = RouteReference.mergeParams(parsed.params, nil)
  ctx:assertEqual(merged.id, "inline")
end

function M.testMergeWithoutInlineKeepsExplicit(ctx)
  ctx:setDescription("Merging with no inline params keeps explicit params")
  local merged = RouteReference.mergeParams({}, { id = "explicit" })
  ctx:assertEqual(merged.id, "explicit")
end

--MARK: reload stability

function M.testCanonicalReferenceReparsesWithoutQuery(ctx)
  ctx:setDescription("A canonical 'route:scope' (query dropped) re-parses with no inline params")
  -- Router keeps request.fullRoute as base[:scope] without the inline query, so
  -- a reload replays effective params from request.params, not from re-parsing.
  local first = RouteReference.parse("career.vehicleShopping?sellerId=2:shop-list")
  local canonical = first.route .. ":" .. first.scope
  ctx:assertEqual(canonical, "career.vehicleShopping:shop-list")
  local reloaded = RouteReference.parse(canonical)
  ctx:assertEqual(reloaded.route, "career.vehicleShopping")
  ctx:assertEqual(reloaded.scope, "shop-list")
  ctx:assert(next(reloaded.params) == nil, "reloaded canonical reference must carry no inline params")
end

--MARK: lifecycle param propagation

-- Mirror the router's construction: parse -> merge -> request -> entry, then
-- assert both lifecycle sites (onEnter and onMount) observe the same effective
-- params. onEnter receives entry.resolved directly; onMount receives the
-- transition context's toRoute (entry.resolved) plus the same navigation context.
function M.testOnEnterAndOnMountShareEffectiveParams(ctx)
  ctx:setDescription("onEnter and onMount receive the same effective params via entry.resolved")

  local parsed = RouteReference.parse("career.vehicleShopping?sellerId=2")
  local effectiveParams = RouteReference.mergeParams(parsed.params, { fromLua = "yes" })

  local request = ResolvedRoute.createRequest("career.vehicleShopping", effectiveParams, nil, {}, "career.vehicleShopping")
  local routeNode = {
    name = "career.vehicleShopping",
    screenId = "career.vehicleShopping",
    ui = { uiTypes = { "vue" } },
  }
  local entry = ResolvedRoute.createEntry(routeNode, request, {}, nil)

  -- onEnter target == entry.resolved
  local onEnterToRoute = entry.resolved
  -- onMount target == transition context toRoute, which the router sets to entry.resolved
  local onMountToRoute = entry.resolved

  ctx:assertEqual(onEnterToRoute.params.sellerId, "2")
  ctx:assertEqual(onEnterToRoute.params.fromLua, "yes")
  ctx:assertEqual(onMountToRoute.params.sellerId, "2")
  ctx:assertEqual(onMountToRoute.params.fromLua, "yes")
  ctx:assert(onEnterToRoute.params == onMountToRoute.params, "both hooks must see the same params table")

  -- The navigation context handed to both hooks summarizes the resolved target.
  local navigationContext = NavigationContext.buildNavigationContext(entry.resolved, nil, "navigate", {})
  ctx:assertEqual(navigationContext.toRoute.params.sellerId, "2")
  ctx:assertEqual(navigationContext.toRoute.params.fromLua, "yes")
end

function M.testRequestPersistsEffectiveParamsWithoutQueryInFullRoute(ctx)
  ctx:setDescription("request.params holds effective params while fullRoute stays query-free")
  local parsed = RouteReference.parse("career.vehicleShopping?sellerId=2:shop-list")
  local effectiveParams = RouteReference.mergeParams(parsed.params, nil)
  local fullRoute = parsed.route .. ":" .. parsed.scope
  local request = ResolvedRoute.createRequest("career.vehicleShopping", effectiveParams, nil, {}, fullRoute)

  ctx:assertEqual(request.params.sellerId, "2")
  ctx:assertEqual(request.fullRoute, "career.vehicleShopping:shop-list")
  ctx:assert(not string.find(request.fullRoute, "?", 1, true), "fullRoute must not contain the inline query")
end

return M
