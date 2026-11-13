-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("routeFailure")
--
-- Focused coverage for the transition-scoped runtime failure contract in router.lua:
--   - routeMounted is rejected until the matching routeChangeComplete commits (commit-before-mount)
--   - routeChangeFailed rolls back an uncommitted in-flight navigation (clears the pending entry)
--   - routeChangeFailed rejects when there is no active transition
--   - routeChangeFailed rejects a failure that arrives after commit (too late to roll back)
--
-- These drive the live ui_router singleton against a fabricated transition. Each test resets the
-- TransitionManager afterward and restores any pre-existing pending entry so the runner stays
-- non-destructive to a live route.

local M = {}
local TransitionManager = require("ge/extensions/ui/router/managers/transitionManager")
local NavigationState = require("ge/extensions/ui/router/navigationState")

-- A minimal phased (Vue) session whose pending entry resolves to "play". routeChangeCommitted
-- starts false so the commit-before-mount guard is exercised.
local function makeUncommittedSession()
  return {
    routeName = "play",
    routeData = {},
    -- routeNode is deliberately hook-free so onLeave/onMount lookups are safe no-ops.
    pendingEntry = { resolved = { name = "play" }, routeNode = {}, request = {} },
    skipOnMount = false,
    mounted = false,
    routeChangeCommitted = false,
    expectsMountAck = true,
    phase = "startup",
    phaseElapsed = 0,
    totalElapsed = 0,
    timeSinceLastEmit = 0,
    handoffAttempts = 1,
    progress = {
      routeChangeReceived = false,
      routeNavigationStarted = false,
      routeChangeCommitted = false,
      routeMounted = false,
    },
  }
end

local function startFabricatedTransition()
  TransitionManager.reset()
  local session = makeUncommittedSession()
  local started, transitionId = TransitionManager.start({
    toRoute = { name = "play" },
    fromRoute = nil,
    session = session,
  })
  return started, transitionId
end

--MARK: commit-before-mount

function M.testRouteMountedRejectedBeforeCommit(ctx)
  ctx:setDescription("routeMounted is rejected with not_committed until the route change commits")
  local started, transitionId = startFabricatedTransition()
  ctx:assert(started == true, "expected the fabricated transition to start")

  local result = extensions.ui_router.routeMounted("play", transitionId)
  ctx:assert(result ~= nil, "expected a routeMounted result")
  ctx:assert(result.success == false, "expected routeMounted to be rejected before commit")
  ctx:assertEqual(result.reason, "not_committed")

  TransitionManager.reset()
end

--MARK: runtime failure rollback

function M.testRouteChangeFailedRollsBackUncommittedNavigation(ctx)
  ctx:setDescription("routeChangeFailed clears the pending entry and ends the transition")
  local original = NavigationState.getPendingEntry()

  local started, transitionId = startFabricatedTransition()
  ctx:assert(started == true, "expected the fabricated transition to start")
  NavigationState.setPendingEntry({ resolved = { name = "play" }, routeNode = {}, request = {} })
  ctx:assert(NavigationState.getPendingEntry() ~= nil, "expected a pending entry to be set")

  local result = extensions.ui_router.routeChangeFailed("vue", "play", transitionId)
  ctx:assert(result ~= nil and result.success == true, "expected routeChangeFailed to succeed")
  ctx:assert(NavigationState.getPendingEntry() == nil, "expected the pending entry to be cleared")
  ctx:assert(TransitionManager.isTransitioning() == false, "expected the transition to be cancelled")

  TransitionManager.reset()
  NavigationState.setPendingEntry(original)
end

function M.testRouteChangeFailedRejectedWithoutActiveTransition(ctx)
  ctx:setDescription("routeChangeFailed is rejected when there is no active transition")
  TransitionManager.reset()

  local result = extensions.ui_router.routeChangeFailed("vue", "play", nil)
  ctx:assert(result ~= nil and result.success == false, "expected routeChangeFailed to be rejected")
  ctx:assertEqual(result.reason, "no_active_transition")
end

function M.testRouteChangeFailedRejectedAfterCommit(ctx)
  ctx:setDescription("routeChangeFailed is rejected once the route has already committed")
  local original = NavigationState.getPendingEntry()

  local started, transitionId = startFabricatedTransition()
  ctx:assert(started == true, "expected the fabricated transition to start")
  NavigationState.setPendingEntry({ resolved = { name = "play" }, routeNode = {}, request = {} })

  local committed = TransitionManager.markCommitted("play", transitionId)
  ctx:assert(committed.success == true, "expected the commit to be recorded")

  local result = extensions.ui_router.routeChangeFailed("vue", "play", transitionId)
  ctx:assert(result ~= nil and result.success == false, "expected routeChangeFailed to be rejected after commit")
  ctx:assertEqual(result.reason, "already_committed")

  TransitionManager.reset()
  NavigationState.setPendingEntry(original)
end

--MARK: stale transition id

function M.testRouteChangeFailedRejectsStaleTransitionId(ctx)
  ctx:setDescription("routeChangeFailed rejects a mismatched transition id so it can't roll back a newer nav")
  local started, transitionId = startFabricatedTransition()
  ctx:assert(started == true, "expected the fabricated transition to start")

  local result = extensions.ui_router.routeChangeFailed("vue", "play", transitionId .. "_stale")
  ctx:assert(result ~= nil and result.success == false, "expected a stale transition id to be rejected")
  ctx:assertEqual(result.reason, "transition_id_mismatch")
  ctx:assert(TransitionManager.isTransitioning() == true, "expected the active transition to stay untouched")

  TransitionManager.reset()
end

return M
