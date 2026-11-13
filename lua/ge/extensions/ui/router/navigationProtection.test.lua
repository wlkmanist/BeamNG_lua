-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("navigationProtection")
--
-- Focused coverage for the protected-navigation lock (options.cancellable == false) in router.lua:
--   - default (nil/true) navigations never acquire the lock and keep last-navigation-wins behavior
--   - a protected navigation acquires an identity-safe token that blocks every newer navigate up
--     front, before route resolution / guards / lifecycle hooks (no queueing, identical calls too)
--   - the lock is held across commit and released on full completion (mount and non-mount routes)
--   - the lock is released on every terminal path: cancel, rejection, framework failure, timeout,
--     reset, and deserialization
--   - identity safety: terminal cleanup of an older transition never clears a newer protected lock
--   - reload carries cancellable=false into the replayed transition
--
-- Terminal-path tests fabricate a transition whose session carries a protection token and seed the
-- router lock through the test-only seams, mirroring the sibling routeFailure/transitionRecovery
-- pattern. Acquisition/reload tests drive the live singleton against a temporary mod route and
-- cancel before commit, so the live current route is never mutated. Tests that must commit snapshot
-- and restore the navigation state.

local M = {}
local Config = require("ge/extensions/ui/router/config")
local TransitionManager = require("ge/extensions/ui/router/managers/transitionManager")
local NavigationState = require("ge/extensions/ui/router/navigationState")

local ROUTE = "navprotect"

-- A minimal flat (Angular/legacy) protected session. phase == nil exercises the flat timeout path
-- and is inert for the cancel/rejection/failure handlers, which do not depend on the phase.
local function makeProtectedFlatSession(token)
  return {
    routeName = ROUTE,
    routeData = {},
    protectionToken = token,
    navigationContext = {},
    pendingEntry = { resolved = { name = ROUTE }, routeNode = {}, request = { name = ROUTE } },
    skipOnMount = false,
    mounted = false,
    routeChangeCommitted = false,
    expectsMountAck = false,
    phase = nil,
    progress = {
      routeChangeReceived = false,
      routeNavigationStarted = false,
      routeChangeCommitted = false,
      routeMounted = false,
    },
  }
end

-- A protected Vue session that has already committed and is waiting on the mount ack, used to prove
-- the lock is retained between commit and mount and released once routeMounted completes it.
local function makeProtectedCommittedVueSession(token)
  return {
    routeName = ROUTE,
    routeData = {},
    protectionToken = token,
    navigationContext = {},
    pendingEntry = { resolved = { name = ROUTE }, routeNode = {}, request = { name = ROUTE } },
    skipOnMount = false,
    mounted = false,
    routeChangeCommitted = true,
    expectsMountAck = true,
    phase = "mountReady",
    phaseElapsed = 0,
    totalElapsed = 0,
    timeSinceLastEmit = 0,
    handoffAttempts = 1,
    progress = {
      routeChangeReceived = true,
      routeNavigationStarted = true,
      routeChangeCommitted = true,
      routeMounted = false,
    },
  }
end

-- A protected non-Vue session that finishes at routeChangeComplete (no mount ack), used to prove the
-- lock is released on non-mount completion.
local function makeProtectedUncommittedNonVueSession(token)
  return {
    routeName = ROUTE,
    routeData = {},
    protectionToken = token,
    navigationContext = {},
    pendingEntry = { resolved = { name = ROUTE }, routeNode = {}, request = { name = ROUTE } },
    skipOnMount = false,
    mounted = false,
    routeChangeCommitted = false,
    expectsMountAck = false,
    phase = "routeCommit",
    phaseElapsed = 0,
    totalElapsed = 0,
    timeSinceLastEmit = 0,
    handoffAttempts = 1,
    progress = {
      routeChangeReceived = true,
      routeNavigationStarted = true,
      routeChangeCommitted = false,
      routeMounted = false,
    },
  }
end

local function startFabricatedTransition(session)
  TransitionManager.reset()
  return TransitionManager.start({ toRoute = { name = ROUTE }, fromRoute = nil, session = session })
end

-- Register a temporary navigable mod route, run fn, and always unregister afterward.
local function withModRoute(routeName, sourceId, fn)
  local RM = extensions.ui_router_routeManager
  RM.registerModRoutes(sourceId, { { name = routeName } })
  local ok, resultOrErr = pcall(fn)
  RM.unregisterModRoutes(sourceId)
  if not ok then
    error(resultOrErr)
  end
  return resultOrErr
end

--MARK: default (nil/true) never acquires the lock

function M.testDefaultNavigationsDoNotAcquireProtection(ctx)
  ctx:setDescription("cancellable nil and cancellable=true keep last-navigation-wins and never lock")
  local Router = extensions.ui_router
  local originalPending = NavigationState.getPendingEntry()
  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)

  withModRoute("navprotectdefault", "navprotect_default", function()
    local resNil = Router.navigate("navprotectdefault")
    ctx:assert(resNil ~= nil and resNil.success == true, "expected the default navigation to start")
    ctx:assert(Router.__test_getProtectionToken() == nil, "cancellable nil must not acquire the lock")
    Router.cancel()

    local resTrue = Router.navigate("navprotectdefault", nil, { cancellable = true })
    ctx:assert(resTrue ~= nil and resTrue.success == true, "expected the cancellable=true navigation to start")
    ctx:assert(Router.__test_getProtectionToken() == nil, "cancellable=true must not acquire the lock")
    Router.cancel()
  end)

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
  NavigationState.setPendingEntry(originalPending)
end

--MARK: acquisition + admission blocking + cancel release (integrated)

function M.testProtectedNavigationAcquiresBlocksAndCancelReleases(ctx)
  ctx:setDescription("cancellable=false acquires the lock, blocks newer navigations, and cancel releases it")
  local Router = extensions.ui_router
  local originalPending = NavigationState.getPendingEntry()
  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)

  withModRoute("navprotectfalse", "navprotect_false", function()
    local res = Router.navigate("navprotectfalse", nil, { cancellable = false })
    ctx:assert(res ~= nil and res.success == true, "expected the protected navigation to start")
    ctx:assert(Router.__test_getProtectionToken() ~= nil, "expected cancellable=false to acquire the lock")

    -- A newer navigation is rejected up front with the protection reason, not a guard/route error.
    local blocked = Router.navigate("navprotectfalse")
    ctx:assert(blocked ~= nil and blocked.success == false, "expected the newer navigation to be blocked")
    ctx:assertEqual(blocked.reason, "active_navigation_not_cancellable")

    Router.cancel()
    ctx:assert(Router.__test_getProtectionToken() == nil, "expected cancel to release the lock")
  end)

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
  NavigationState.setPendingEntry(originalPending)
end

--MARK: admission gate runs before resolution / guards / lifecycle

function M.testProtectedLockBlocksBeforeResolution(ctx)
  ctx:setDescription("The admission gate rejects a newer request before route resolution or guards")
  local Router = extensions.ui_router
  Router.__test_setProtectionToken("gate_token")

  -- A bogus route would normally fail with route_not_found during resolution; the admission gate
  -- must reject it first, proving it runs before resolution/guards/lifecycle hooks.
  local res = Router.navigate("navprotect.definitely.missing", { any = true }, { cancellable = true })
  ctx:assert(res ~= nil and res.success == false, "expected the navigation to be blocked")
  ctx:assertEqual(res.reason, "active_navigation_not_cancellable")

  Router.__test_setProtectionToken(nil)
end

function M.testProtectedLockBlocksIdenticalAndRepeatedRequests(ctx)
  ctx:setDescription("Repeated/identical requests are uniformly blocked while protected (no queueing)")
  local Router = extensions.ui_router
  Router.__test_setProtectionToken("repeat_token")

  local first = Router.navigate("play")
  local second = Router.navigate("play")
  ctx:assert(first ~= nil and first.reason == "active_navigation_not_cancellable", "expected the first repeat to be blocked")
  ctx:assert(second ~= nil and second.reason == "active_navigation_not_cancellable", "expected the identical repeat to be blocked")

  Router.__test_setProtectionToken(nil)
end

--MARK: idle router does not block

function M.testIdleRouterDoesNotBlockNavigation(ctx)
  ctx:setDescription("With no protected navigation active, navigate is not admission-blocked")
  local Router = extensions.ui_router
  Router.__test_setProtectionToken(nil)

  local res = Router.navigate("navprotect.definitely.missing")
  ctx:assert(res ~= nil and res.success == false, "expected a normal failure")
  ctx:assert(res.reason ~= "active_navigation_not_cancellable", "an idle router must not admission-block")
  ctx:assertEqual(res.reason, "route_not_found")
end

--MARK: identity safety

function M.testReleaseOfNonMatchingTokenPreservesLock(ctx)
  ctx:setDescription("Terminal cleanup of an older transition cannot clear a newer protected lock")
  local Router = extensions.ui_router
  -- The active (older) transition carries token T2; the live lock belongs to a newer nav (T1).
  local _, transitionId = startFabricatedTransition(makeProtectedFlatSession("T2"))
  Router.__test_setProtectionToken("T1")

  Router.routeChangeRejected("vue", ROUTE, transitionId, "superseded")
  ctx:assertEqual(Router.__test_getProtectionToken(), "T1")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
end

--MARK: terminal release matrix

function M.testCancelReleasesProtection(ctx)
  ctx:setDescription("M.cancel releases the protected navigation lock")
  local Router = extensions.ui_router
  local token = "cancel_token"
  local started = startFabricatedTransition(makeProtectedFlatSession(token))
  ctx:assert(started == true, "expected the fabricated transition to start")
  Router.__test_setProtectionToken(token)

  local res = Router.cancel()
  ctx:assert(res ~= nil and res.success == true, "expected cancel to succeed")
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected cancel to release the lock")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
end

function M.testRejectionReleasesProtection(ctx)
  ctx:setDescription("routeChangeRejected releases the protected navigation lock")
  local Router = extensions.ui_router
  local token = "reject_token"
  local _, transitionId = startFabricatedTransition(makeProtectedFlatSession(token))
  Router.__test_setProtectionToken(token)

  local res = Router.routeChangeRejected("vue", ROUTE, transitionId, "test")
  ctx:assert(res ~= nil and res.success == true, "expected the rejection to be accepted")
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected rejection to release the lock")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
end

function M.testFrameworkFailureReleasesProtection(ctx)
  ctx:setDescription("routeChangeFailed releases the protected navigation lock")
  local Router = extensions.ui_router
  local original = NavigationState.getPendingEntry()
  local token = "fail_token"
  local _, transitionId = startFabricatedTransition(makeProtectedFlatSession(token))
  NavigationState.setPendingEntry({ resolved = { name = ROUTE }, routeNode = {}, request = { name = ROUTE } })
  Router.__test_setProtectionToken(token)

  local res = Router.routeChangeFailed("vue", ROUTE, transitionId)
  ctx:assert(res ~= nil and res.success == true, "expected the failure rollback to succeed")
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected failure to release the lock")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
  NavigationState.setPendingEntry(original)
end

function M.testTimeoutReleasesProtection(ctx)
  ctx:setDescription("A transition timeout releases the protected navigation lock")
  local Router = extensions.ui_router
  local token = "timeout_token"
  local started = startFabricatedTransition(makeProtectedFlatSession(token))
  ctx:assert(started == true, "expected the fabricated transition to start")
  Router.__test_setProtectionToken(token)

  -- Flat transitions time out after Config.Timeout seconds; advance past it in one update.
  Router.onGuiUpdate(Config.Timeout + 1, 0, 0)
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected the timeout to release the lock")
  ctx:assert(TransitionManager.isTransitioning() == false, "expected the timed-out transition to end")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
end

function M.testResetStatesReleasesProtection(ctx)
  ctx:setDescription("resetStates clears the protected navigation lock")
  local Router = extensions.ui_router
  local snapshot = NavigationState.serialize()
  Router.__test_setProtectionToken("reset_token")

  Router.resetStates()
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected resetStates to clear the lock")

  NavigationState.deserialize(snapshot)
end

function M.testDeserializeClearsStaleProtection(ctx)
  ctx:setDescription("onDeserialize drops a stale lock without touching persisted nav state")
  local Router = extensions.ui_router
  Router.__test_setProtectionToken("deser_token")

  Router.onDeserialize(nil)
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected deserialize to clear the stale lock")
end

--MARK: completion (held across commit, released on full completion)

function M.testProtectionHeldAcrossCommitAndReleasedOnMount(ctx)
  ctx:setDescription("The lock is held between commit and mount, then released on full completion")
  local Router = extensions.ui_router
  local snapshot = NavigationState.serialize()
  -- Isolate from any live current entry so the onMount lookup stays a safe no-op.
  NavigationState.reset()

  local token = "mount_token"
  local started, transitionId = startFabricatedTransition(makeProtectedCommittedVueSession(token))
  ctx:assert(started == true, "expected the committed transition to start")
  Router.__test_setProtectionToken(token)

  -- Committed but not yet mounted: the lock is still held.
  ctx:assertEqual(Router.__test_getProtectionToken(), token)

  local res = Router.routeMounted(ROUTE, transitionId)
  ctx:assert(res ~= nil and res.success == true, "expected the mount ack to complete the transition")
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected full completion to release the lock")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
  NavigationState.deserialize(snapshot)
end

function M.testProtectionReleasedOnNonMountCompletion(ctx)
  ctx:setDescription("A non-mount route releases the lock at routeChangeComplete")
  local Router = extensions.ui_router
  local snapshot = NavigationState.serialize()
  NavigationState.reset()
  NavigationState.setPendingEntry({ resolved = { name = ROUTE }, routeNode = {}, request = { name = ROUTE } })

  local token = "complete_token"
  local started, transitionId = startFabricatedTransition(makeProtectedUncommittedNonVueSession(token))
  ctx:assert(started == true, "expected the transition to start")
  Router.__test_setProtectionToken(token)

  local res = Router.routeChangeComplete("vue", ROUTE, transitionId)
  ctx:assert(res ~= nil and res.success == true, "expected routeChangeComplete to succeed")
  ctx:assert(Router.__test_getProtectionToken() == nil, "expected non-mount completion to release the lock")

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
  NavigationState.deserialize(snapshot)
end

--MARK: reload inherits cancellable=false

function M.testReloadForwardsCancellableFalse(ctx)
  ctx:setDescription("reload carries cancellable=false into the replayed transition, acquiring the lock")
  local Router = extensions.ui_router
  local originalPending = NavigationState.getPendingEntry()
  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)

  withModRoute("navprotectreload", "navprotect_reload", function()
    local res = Router.reload("navprotectreload", nil, { cancellable = false })
    ctx:assert(res ~= nil and res.success == true, "expected reload to start a navigation")
    ctx:assert(Router.__test_getProtectionToken() ~= nil, "expected reload's cancellable=false to acquire the lock")
    Router.cancel()
  end)

  TransitionManager.reset()
  Router.__test_setProtectionToken(nil)
  NavigationState.setPendingEntry(originalPending)
end

return M
