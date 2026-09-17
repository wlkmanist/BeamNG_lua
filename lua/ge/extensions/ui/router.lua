-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

local Constants = require("ge/extensions/ui/router/constants")
local Config = require("ge/extensions/ui/router/config")
local TransitionManager = require("ge/extensions/ui/router/managers/transitionManager")
local FrameworkManager = require("ge/extensions/ui/router/managers/frameworkManager")
local GuardManager = require("ge/extensions/ui/router/managers/guardManager")
local LoadingScreenManager = require("ge/extensions/ui/router/managers/loadingScreenManager")
local NavigationState = require("ge/extensions/ui/router/navigationState")
local NavigationContextService = require("ge/extensions/ui/router/services/navigationContext")
local RouteHandlers = require("ge/extensions/ui/router/routeHandlers")
local BreadcrumbManager = require("ge/extensions/ui/router/managers/breadcrumbManager")
local ScopeManager = require("ge/extensions/ui/router/managers/scopeManager")
local ResolvedRoute = require("ge/extensions/ui/router/models/ResolvedRoute")
local LifecycleExecutor = require("ge/extensions/ui/router/lifecycleExecutor")

local navigationEpoch = 0
local activeRouteData = {}

local activeScopeState = {
  activeScopeId = nil,
  previousActiveScopeId = nil,
  routeName = nil,
}

local function beginNavigationEpoch()
  navigationEpoch = navigationEpoch + 1
  return navigationEpoch
end

local function isEpochCurrent(epoch)
  return epoch == navigationEpoch
end

local function routeSummary(route)
  if not route then
    return nil
  end

  return {
    name = route.name,
    screenId = route.screenId or route.name,
    params = route.params or {},
    query = route.query or {},
    meta = route.meta or {},
  }
end

local function containsValue(list, value)
  if type(list) ~= "table" then
    return false
  end
  for _, item in ipairs(list) do
    if item == value then
      return true
    end
  end
  return false
end

local function routeExpectsHandoff(resolved)
  local ui = resolved and resolved.ui
  if type(ui) ~= "table" then
    return false
  end
  if ui.uiTypesFilter ~= Constants.UiTypesFilter.only then
    return false
  end
  return containsValue(ui.uiTypes, "vue")
end

local function routeExpectsMountAck(resolved)
  local ui = resolved and resolved.ui
  if type(ui) ~= "table" then
    return false
  end
  return containsValue(ui.uiTypes, "vue")
end

local function asNonEmptyString(value)
  if type(value) == "string" and value ~= "" then
    return value
  end
  return nil
end

local function parseInlineScopedRoute(routeName)
  if type(routeName) ~= "string" then
    return routeName, nil, routeName
  end

  local delimiterIndex = string.find(routeName, ":", 1, true)
  if not delimiterIndex then
    return routeName, nil, routeName
  end

  local baseRouteName = string.sub(routeName, 1, delimiterIndex - 1)
  local routeScopeId = string.sub(routeName, delimiterIndex + 1)
  if baseRouteName == "" or routeScopeId == "" then
    return routeName, nil, routeName
  end

  return baseRouteName, routeScopeId, routeName
end

local function buildEffectiveOptions(options, routeScopeId)
  local effectiveOptions = {}
  if type(options) == "table" then
    for key, value in pairs(options) do
      effectiveOptions[key] = value
    end
  end

  if routeScopeId then
    effectiveOptions.routeScopeId = routeScopeId
  end

  return effectiveOptions
end

local function getNamespace(route)
  local routeMeta = route and route.meta or {}
  if type(routeMeta.routeDataNamespace) == "string" and routeMeta.routeDataNamespace ~= "" then
    return routeMeta.routeDataNamespace
  end

  local routeName = route and route.name or ""
  if type(routeName) == "string" and routeName ~= "" then
    local tokens = string.split(routeName, "[^%.]+")
    return tokens[1] or "route"
  end

  return "route"
end

local function emitRouteData(route, fromRoute, data, status, err, extras)
  extras = extras or {}
  guihooks.trigger("ui_router_routeData", {
    namespace = getNamespace(route),
    route = routeSummary(route),
    fromRoute = routeSummary(fromRoute),
    scopeTree = route and route.scopeTree or nil,
    scopeParentMap = route and ScopeManager.buildScopeParentMap(route.scopeTree) or nil,
    targetScope = extras.targetScope or nil,
    breadcrumbs = extras.breadcrumbs or nil,
    data = data,
    status = status,
    error = err or nil,
  })
end

local function buildNavigationContext(toRoute, fromRoute, kind, extras)
  return NavigationContextService.buildNavigationContext(toRoute, fromRoute, kind, extras)
end

local function runOnLeave(toRoute, fromRoute, options)
  local currentRoute = NavigationState.getCurrentRouteNode()
  if not currentRoute then
    return true
  end

  local leaveData = type(activeRouteData) == "table" and activeRouteData or {}
  local leaveContext = buildNavigationContext(toRoute, fromRoute, "leave", options)
  local ok, _ = LifecycleExecutor.runLifecycleHook(currentRoute, "onLeave", leaveContext, toRoute, fromRoute, leaveData)
  return ok
end

local function showLoadingScreenIfNeeded(resolvedRoute, options)
  -- log("D", "Router", "Checking loading screen for route: " .. resolvedRoute.name)
  local shouldShow = LoadingScreenManager.shouldShow(resolvedRoute, options)

  if not shouldShow then
    -- log("D", "Router", "Loading screen is not needed for this route " .. resolvedRoute.name)
    return
  end

  local autoHide = options and options.loadingScreen and options.loadingScreen.autoHide or
                       Config.LoadingScreen.autoHideOnComplete
  local autoHideTime = options and options.loadingScreen and options.loadingScreen.autoHideTime or nil
  LoadingScreenManager.show(nil, {
    autoHide = autoHide,
    autoHideTime = autoHideTime
  })
end

local function executeExitGuards(route, params, context)
  local data = {
    result = true
  }
  local currentNode = NavigationState.getCurrentEntry()
  if not currentNode then
    return data
  end
  local exitGuards = currentNode.resolved.exitGuards
  if not exitGuards or #exitGuards == 0 then
    return data
  end
  return GuardManager.executeGuards(exitGuards, route, params, context)
end

local function executeEnterGuards(route, params)
  local data = {
    result = true
  }
  local enterGuards = route.enterGuards
  if not enterGuards or #enterGuards == 0 then
    return data
  end
  return GuardManager.executeGuards(enterGuards, route, params)
end

local function updateDecorator(routename, options)
  local moduleName = string.split(routename, "[^%.]+")[1]
  if type(options) ~= "table" then
    if NavigationState.getDecoratorModule() ~= moduleName then
      NavigationState.clearDecorator()
    end
    return
  end
  if options.decorator then
    NavigationState.setDecorator(options.decorator, moduleName)
  elseif NavigationState.getDecoratorModule() ~= moduleName then
    NavigationState.clearDecorator()
  end
  if options.showDecorator ~= nil then
    NavigationState.setDecoratorVisible(options.showDecorator)
  end
end

local function navigationFailure(reason, extras)
  local result = {
    result = false,
    success = false,
    reason = reason,
  }

  if type(extras) == "table" then
    for key, value in pairs(extras) do
      result[key] = value
    end
  end

  return result
end

local function navigationPreemptedFailure()
  return navigationFailure("navigation_preempted", {
    message = "Navigation preempted",
  })
end

local function resolveNavigationTarget(routename, options)
  local baseRouteName, routeScopeId, fullRouteName = parseInlineScopedRoute(routename)
  local effectiveOptions = buildEffectiveOptions(options, routeScopeId)
  local route = extensions.ui_router_routeManager.getRoute(baseRouteName)

  if not route then
    log("W", "", "Route not found: " .. tostring(fullRouteName))
    return nil, navigationFailure("route_not_found")
  end

  return {
    route = route,
    baseRouteName = baseRouteName,
    fullRouteName = fullRouteName,
    options = effectiveOptions,
  }
end

local function guardFailure(reason, guardResult)
  return navigationFailure(reason, {
    failedGuard = guardResult.failedGuard,
  })
end

local function getActiveTransitionRoutes()
  local transitionContext = TransitionManager.getTransitionContext()
  local toRoute = transitionContext and transitionContext.toRoute or NavigationState.getCurrentRouteNode()
  local fromRoute = transitionContext and transitionContext.fromRoute or nil
  return toRoute, fromRoute
end

local function completeActiveTransition(routeName, routeData, transitionId)
  activeRouteData = routeData
  return TransitionManager.complete(routeName, transitionId)
end

local function cancelActiveTransition(reason, extras)
  extras = extras or {}
  local toRoute, fromRoute = getActiveTransitionRoutes()
  local wasCancelled = TransitionManager.cancel(reason)

  if extras.notify == false then
    return wasCancelled
  end

  FrameworkManager.sendRouteChangeCancelled(toRoute)

  local hookPayload = {
    toRoute = toRoute,
    fromRoute = fromRoute,
    reason = reason,
  }
  if type(extras.hook) == "table" then
    for key, value in pairs(extras.hook) do
      hookPayload[key] = value
    end
  end
  extensions.hook(Constants.RouterHooks.ROUTE_CHANGE_CANCELLED, hookPayload)

  LoadingScreenManager.hide()

  return wasCancelled
end

local function timeoutActiveTransition(reason, classification)
  reason = reason or "timeout_reached"

  local session = TransitionManager.getSession()
  local timeoutInfo = TransitionManager.getTimeoutInfo(classification)
  local timeoutClassification = timeoutInfo.classification
  local phase = timeoutInfo.phase
  local phaseElapsed = timeoutInfo.phaseElapsed
  local totalElapsed = timeoutInfo.totalElapsed
  local handoffAttempts = timeoutInfo.handoffAttempts

  local toRoute, fromRoute = getActiveTransitionRoutes()

  log("W", "Router", string.format(
      "Transition timeout for route: %s reason: %s classification: %s phase: %s phaseElapsed: %.2fs totalElapsed: %.2fs handoffAttempts: %s",
      tostring(toRoute and toRoute.name), tostring(reason), tostring(timeoutClassification),
      tostring(phase), phaseElapsed, totalElapsed, tostring(handoffAttempts)))

  local timeoutRouteData = session and session.routeData or {}
  local timeoutTargetScope = toRoute and toRoute.scope and toRoute.scope.targetScope or nil
  local timeoutBreadcrumbs = toRoute and toRoute.breadcrumbs or nil
  emitRouteData(toRoute, fromRoute, timeoutRouteData, "error", "transition timeout: " .. timeoutClassification, {
    targetScope = timeoutTargetScope,
    breadcrumbs = timeoutBreadcrumbs,
  })
  activeRouteData = timeoutRouteData

  cancelActiveTransition(reason, {
    hook = {
      timeoutClassification = timeoutClassification,
      phase = phase,
      phaseElapsed = phaseElapsed,
      totalElapsed = totalElapsed,
      handoffAttempts = handoffAttempts,
    },
  })
end

local function cancelActiveTransitionIfNeeded()
  if not TransitionManager.isTransitioning() then
    return
  end

  -- log("D", "", "Transition is currently in progress, cancelling the current transition")
  -- Preempted navigation: cancel silently, the incoming navigation owns the next side effects.
  cancelActiveTransition("navigation_replaced", { notify = false })
end

local function runEnterLifecycle(route, fromRoute, options)
  local routeData = {}
  local navigationContext = buildNavigationContext(route, fromRoute, "navigate", options)
  local enterOk, enterErr, enterIsHard = LifecycleExecutor.runLifecycleHook(route, "onEnter", navigationContext, route, fromRoute, routeData)

  if enterIsHard then
    return nil, navigationFailure("lifecycle_hook_error")
  end

  return {
    routeData = routeData,
    navigationContext = navigationContext,
    enterOk = enterOk,
    enterErr = enterErr,
  }
end

local function buildNavigationEntry(target, params, previousEntry)
  local targetScopeInfo = ScopeManager.getTargetScope(target.route, target.options)
  local targetScope = targetScopeInfo.targetScope

  updateDecorator(target.baseRouteName, target.options)
  local decorator = NavigationState.isDecoratorVisible() and NavigationState.getDecorator() or nil
  local breadcrumbs = BreadcrumbManager.buildBreadcrumbs(target.baseRouteName, target.route, params, decorator)

  local request = ResolvedRoute.createRequest(target.baseRouteName, params, nil, target.options, target.fullRouteName)
  local entry = ResolvedRoute.createEntry(target.route, request, {
    breadcrumbs = breadcrumbs,
    scope = targetScopeInfo,
  }, previousEntry)

  return {
    entry = entry,
    breadcrumbs = breadcrumbs,
    targetScope = targetScope,
  }
end

local function emitInitialRouteData(entryInfo, enterState)
  emitRouteData(entryInfo.entry.resolved, entryInfo.entry.fromRoute, enterState.routeData, enterState.enterOk and "enter-ready" or "error", enterState.enterErr, {
    targetScope = entryInfo.targetScope,
    breadcrumbs = entryInfo.breadcrumbs,
  })
end

local function createTransitionMeta(entry, routeName, enterState)
  local expectsHandoff = routeExpectsHandoff(entry.resolved)

  return {
    routeName = routeName,
    routeData = enterState.routeData,
    skipOnMount = not enterState.enterOk,
    mounted = false,
    routeChangeCommitted = false,
    navigationContext = enterState.navigationContext,
    -- Kept for handoff resends: the exact pending entry to re-emit without re-running setup.
    pendingEntry = entry,
    -- Phase state. `phase` is nil for non-phased (Angular/legacy) transitions, which keep
    -- the flat TransitionManager timeout. Phased framework transitions own their own budget.
    phase = expectsHandoff and "handoff" or nil,
    phaseElapsed = 0,
    totalElapsed = 0,
    timeSinceLastEmit = 0,
    handoffAttempts = 1, -- the initial sendRouteChange below counts as attempt 1
    -- Only consulted for phased (handoff) transitions, where routeExpectsMountAck is
    -- already implied by expectsHandoff, so this matches the previous expectsHandoff-based value.
    expectsMountAck = routeExpectsMountAck(entry.resolved) and enterState.enterOk or false,
    progress = {
      routeChangeReceived = false,
      routeNavigationStarted = false,
      routeChangeCommitted = false,
      routeMounted = false,
    },
  }
end

--[[
  Transition acknowledgement protocol.

  A navigation is a handshake between Lua (this router) and the UI frameworks. Lua owns the
  navigation orchestration and decides what to do at each step; the framework reports progress
  back through the M.route* entry points below. The happy-path sequence is:

    1. Lua emits the route change      -> startNavigationTransition() -> FrameworkManager.sendRouteChange()
    2. UI framework acknowledges it     -> M.routeChangeReceived()      (progress.routeChangeReceived)
    3. Vue Router reports it started    -> M.routeNavigationStarted()   (progress.routeNavigationStarted)
    4. Framework commits the route      -> M.routeChangeComplete()      (promotes pending entry)
    5. Vue routes that need readiness   -> M.routeMounted()             (runs onMount, completes)

  Module boundaries:
    - TransitionManager owns the active transition session: progress milestones, phase,
      phase/total elapsed time, handoff resend timing, and timeout classification. It exposes
      the session via getSession()/markProgress()/markCommitted()/markMounted()/getTimeoutInfo()
      and returns resend/timeout events from update(); it performs no side effects itself.
    - router.lua (this file) owns navigation orchestration and side effects: it decides when to
      start a transition, promotes pending entries, runs lifecycle hooks (onMount), emits route
      data, and reacts to TransitionManager events by calling FrameworkManager / loading screen.
    - FrameworkManager owns the outbound guihooks to the UI frameworks (sendRouteChange/*Complete/*Cancelled).

  Completion depends on the mount-ack predicate: routes that expect a Vue mount ack finish at
  step 5 (M.routeMounted), everything else finishes at step 4 (M.routeChangeComplete).
]]
local function startNavigationTransition(entry, routeName, enterState)
  NavigationState.setPendingEntry(entry)

  local session = createTransitionMeta(entry, routeName, enterState)
  local started, transitionId = TransitionManager.start({ toRoute = entry.resolved, fromRoute = entry.fromRoute, session = session })

  FrameworkManager.sendRouteChange(entry, started and transitionId or nil)
  extensions.hook(Constants.RouterHooks.BEFORE_ROUTE_CHANGE, entry)
end

M.navigate = function(routename, params, options)
  local target, resolveFailure = resolveNavigationTarget(routename, options)
  if resolveFailure then
    return resolveFailure
  end

  local canExit = executeExitGuards(target.route, params, {
    routeName = target.fullRouteName,
    options = target.options,
  })
  if canExit.result == false then
    return guardFailure("guard_blocked_exit", canExit)
  end

  local epoch = beginNavigationEpoch()
  local previousEntry = NavigationState.getCurrentEntry()
  local fromRoute = previousEntry and ResolvedRoute.toCompatRoute(previousEntry.resolved) or nil

  cancelActiveTransitionIfNeeded()
  runOnLeave(target.route, fromRoute, target.options)

  local canEnter = executeEnterGuards(target.route, params)
  if canEnter.result == false then
    return guardFailure("guard_blocked_enter", canEnter)
  end

  if not isEpochCurrent(epoch) then
    return navigationPreemptedFailure()
  end

  local enterState, enterFailure = runEnterLifecycle(target.route, fromRoute, target.options)
  if enterFailure then
    return enterFailure
  end

  local entryInfo = buildNavigationEntry(target, params, previousEntry)
  emitInitialRouteData(entryInfo, enterState)

  if not isEpochCurrent(epoch) then
    return navigationPreemptedFailure()
  end

  startNavigationTransition(entryInfo.entry, target.baseRouteName, enterState)

  return {
    result = true,
    success = true,
    data = entryInfo.entry
  }
end

M.back = function(options)
  -- dump("ui_router.back: ", { options = options })
  local currentEntry = NavigationState.getCurrentEntry()
  if not currentEntry then
    log("W", "", "back: no current route, doing nothing")
    return {
      result = false,
      reason = "no_current_route"
    }
  end

  local backTarget = currentEntry.resolved.backTarget
  if backTarget then
    local previousRequest = currentEntry.request
    local previousParams = previousRequest and previousRequest.params or {}
    local backOptions = buildEffectiveOptions(options)
    backOptions.restoreLastScope = true
    return M.navigate(backTarget, previousParams, backOptions)
  end

  local currentRouteNode = currentEntry.routeNode
  if currentRouteNode and currentRouteNode.back and currentRouteNode.back.mode == "handler" then
    local handler = RouteHandlers.getHandler(currentRouteNode.back.handler)
    if handler then
      return handler()
    end
  end
end

M.cancel = function(options)
  -- dump("ui_router.cancel")
  if not TransitionManager.isTransitioning() then
    log("W", "", "No transition in progress, cannot cancel")
    return {
      success = false,
      message = "No transition in progress, cannot cancel"
    }
  end

  cancelActiveTransition("cancelled")

  return {
    success = true
  }
end

M.getCurrent = function()
  return NavigationState.getCurrentEntry()
end

M.reload = function(routeName, params, options)
  -- dump("reload: " .. (routeName or ""))
  local currentEntry = NavigationState.getCurrentEntry()
  local targetRouteName = routeName
  local targetParams = params
  local targetOptions = options

  if currentEntry then
    if not targetRouteName then
      targetRouteName = currentEntry.request.name
    end
    if not targetParams then
      targetParams = currentEntry.request.params
    end
    if not targetOptions then
      targetOptions = currentEntry.request.options
    end
  end

  if not targetRouteName then
    log("W", "Router", "reload failed: no target route available")
    return {
      success = false,
      message = "No route available to reload"
    }
  end

  return M.navigate(targetRouteName, targetParams, targetOptions)
end

M.routeChangeReceived = function(frameworkId, routeName, transitionId)
  -- log("I", "", "routeChangeReceived: " .. routeName)
  return TransitionManager.markProgress(routeName, "routeChangeReceived", transitionId)
end

M.routeNavigationStarted = function(frameworkId, routeName, transitionId)
  -- log("I", "", "routeNavigationStarted: " .. routeName)
  return TransitionManager.markProgress(routeName, "routeNavigationStarted", transitionId)
end

M.routeChangeComplete = function(frameworkId, routeName, transitionId)
  -- log("I", "", "routeChangeComplete: " .. routeName)
  if not TransitionManager.isTransitioning() then
    log("W", "Router", "routeChangeComplete received without active transition: " .. tostring(routeName))
    return { success = false, reason = "no_active_transition" }
  end

  local session = TransitionManager.getSession()
  if not session then
    log("W", "Router", "routeChangeComplete missing transition metadata for route: " .. tostring(routeName))
    return { success = false, reason = "missing_transition_meta" }
  end

  if session.routeChangeCommitted then
    return { success = true, alreadyCommitted = true }
  end

  local pendingEntry = NavigationState.getPendingEntry()
  if not pendingEntry then
    log("W", "Router", "routeChangeComplete missing pending entry for route: " .. tostring(routeName))
    return { success = false, reason = "missing_pending_entry" }
  end

  local pendingRouteName = pendingEntry.resolved and pendingEntry.resolved.name or nil
  if routeName ~= pendingRouteName then
    log("W", "Router", "routeChangeComplete route mismatch. Expected: " .. tostring(pendingRouteName) .. ", Got: " .. tostring(routeName))
    return { success = false, reason = "route_mismatch" }
  end

  -- Validate the transition id (when provided) before promoting, so a stale
  -- acknowledgement can't commit the wrong entry. Missing ids fall back to route-name validation.
  local activeTransitionId = TransitionManager.getTransitionId()
  if transitionId ~= nil and activeTransitionId ~= nil and transitionId ~= activeTransitionId then
    log("W", "Router", "routeChangeComplete transition id mismatch. Expected: " .. tostring(activeTransitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  NavigationState.promotePendingEntry()
  TransitionManager.markCommitted(routeName, transitionId)

  local currentEntry = NavigationState.getCurrentEntry()
  if not currentEntry then
    log("W", "Router", "routeChangeComplete failed to promote route: " .. tostring(routeName))
    return { success = false, reason = "missing_current_entry" }
  end

  FrameworkManager.sendRouteChangeComplete(currentEntry)
  extensions.hook(Constants.RouterExtensionHooks.AFTER_ROUTE_CHANGE, currentEntry)
  extensions.hook("onUiChangedState", currentEntry.request.name,
      currentEntry.origin and currentEntry.origin.route or "")

  local needsVueMountAck = routeExpectsMountAck(currentEntry.resolved)

  if session.skipOnMount or not needsVueMountAck then
    completeActiveTransition(routeName, session.routeData, transitionId)
  end

  return { success = true }
end

M.routeMounted = function(routeName, transitionId)
  -- log("I", "Router", "routeMounted: " .. routeName)
  if not TransitionManager.isTransitioning() then
    local currentEntry = NavigationState.getCurrentEntry()
    if currentEntry and currentEntry.resolved and currentEntry.resolved.name == routeName then
      -- Late/duplicate mount acknowledgement for an already-committed route.
      return { success = true, stale = true }
    end
    log("W", "Router", "routeMounted received without active transition: " .. tostring(routeName))
    return { success = false, reason = "no_active_transition" }
  end

  local context = TransitionManager.getTransitionContext()
  if not context or not context.toRoute then
    log("W", "Router", "routeMounted missing transition context")
    return { success = false, reason = "missing_transition_context" }
  end

  if routeName ~= context.toRoute.name then
    log("W", "Router", "routeMounted route mismatch. Expected: " .. tostring(context.toRoute.name) .. ", Got: " .. tostring(routeName))
    return { success = false, reason = "route_mismatch" }
  end

  -- Validate the transition id when provided; missing ids fall back to route-name validation.
  if transitionId ~= nil and context.transitionId ~= nil and transitionId ~= context.transitionId then
    log("W", "Router", "routeMounted transition id mismatch. Expected: " .. tostring(context.transitionId) .. ", Got: " .. tostring(transitionId))
    return { success = false, reason = "transition_id_mismatch" }
  end

  local session = TransitionManager.getSession()
  if not session then
    return { success = false, reason = "missing_transition_meta" }
  end

  if session.skipOnMount then
    return { success = true, skipped = true }
  end

  if session.mounted then
    return { success = true, alreadyMounted = true }
  end

  local currentEntry = NavigationState.getCurrentEntry()
  local routeNode = currentEntry and currentEntry.routeNode
  local targetScope = currentEntry and currentEntry.resolved and currentEntry.resolved.scope and currentEntry.resolved.scope.targetScope or nil
  local mountOk, mountErr, mountIsHard = LifecycleExecutor.runLifecycleHook(routeNode or context.toRoute, "onMount", session.navigationContext, context.toRoute, context.fromRoute, session.routeData)
  if mountIsHard then
    return { success = false, reason = "lifecycle_hook_error" }
  end
  local breadcrumbs = currentEntry and currentEntry.resolved and currentEntry.resolved.breadcrumbs or nil
  emitRouteData(context.toRoute, context.fromRoute, session.routeData, mountOk and "mounted-ready" or "error", mountErr, { targetScope = targetScope, breadcrumbs = breadcrumbs })
  TransitionManager.markMounted(routeName, transitionId)
  completeActiveTransition(routeName, session.routeData, transitionId)

  return { success = true }
end

M.getBreadcrumbs = function()
  return NavigationState.getBreadcrumbs()
end

M.onGuiUpdate = function(dtReal, dtSim, dtRaw)
  local event = TransitionManager.update(dtReal)
  if event then
    if event.type == "resendRouteChange" then
      FrameworkManager.sendRouteChange(event.entry, TransitionManager.getTransitionId())
    elseif event.type == "timeout" then
      timeoutActiveTransition(event.reason, event.classification)
      return
    end
  end

  if LoadingScreenManager.canUpdate() then
    LoadingScreenManager.update(dtReal)
  end
end

M.onSerialize = function()
  return {
    navigation = NavigationState.serialize()
    -- Add other managers if they have state to persist
  }
end

M.onDeserialize = function(data)
  if not data then
    return
  end
  NavigationState.deserialize(data.navigation)
  -- Restore other managers if needed
end

M.onExtensionLoaded = function()
  setExtensionUnloadMode(M, "manual")
  GuardManager.reloadGuards()
  -- extensions.load("ui_router_debug")
end

M.reportActiveScope = function(payload)
  -- dump("reportActiveScope: " .. json.encode(payload))
  if type(payload) ~= "table" then
    return { success = false, reason = "invalid_payload" }
  end

  local currentEntry = NavigationState.getCurrentEntry()
  local currentRouteName = currentEntry and currentEntry.request and currentEntry.request.name or nil
  local currentScopeTree = currentEntry and currentEntry.resolved and currentEntry.resolved.scopeTree or nil
  local payloadRouteName = asNonEmptyString(payload.routeName)
  local activeScopeId = asNonEmptyString(payload.activeScopeId)

  if payloadRouteName and currentRouteName and payloadRouteName ~= currentRouteName then
    return { success = false, reason = "stale_route", stale = true }
  end

  activeScopeState.previousActiveScopeId = activeScopeState.activeScopeId
  activeScopeState.activeScopeId = payload.activeScopeId
  activeScopeState.routeName = payloadRouteName or currentRouteName

  local shouldRememberRouteScope = payloadRouteName and currentRouteName and payloadRouteName == currentRouteName and
                                     activeScopeId and payload.isPopup ~= true and
                                     ScopeManager.isScopeDeclaredInTree(currentScopeTree, activeScopeId)

  if shouldRememberRouteScope then
    NavigationState.setLastActiveScope(currentRouteName, activeScopeId)
  end

  extensions.hook("onUiActiveScopeChanged", payload)

  return { success = true }
end

M.getState = function()
  return {
    currentRoute = NavigationState.getCurrentEntry(),
    activeScope = activeScopeState,
  }
end

M.resetStates = function()
  NavigationState.reset()
  TransitionManager.reset()
  LoadingScreenManager.hide()
  activeRouteData = {}
  activeScopeState.activeScopeId = nil
  activeScopeState.previousActiveScopeId = nil
  activeScopeState.routeName = nil
end

-- Manual loading screen API
M.showLoadingScreen = function(options)
  LoadingScreenManager.show(nil, options)
end

M.hideLoadingScreen = function()
  LoadingScreenManager.hide()
end

M.isLoadingScreenActive = function()
  return LoadingScreenManager.isActive()
end

-- Deprecated methods
M.push = function(routename, params, options)
  log("W", "", "push is deprecated, use navigate instead")
  return M.navigate(routename, params, options)
end

M.replace = function(routename, params, options)
  log("W", "", "replace is deprecated, use navigate instead")
  return M.navigate(routename, params, options)
end

M.forward = function(options)
  log("W", "", "forward is deprecated, use navigate instead")
  return {
    result = false,
    reason = "deprecated_method"
  }
end

return M
