-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("transitionRecovery")
--
-- Focused coverage for the Vue startup-retry recovery contract:
--   - the indefinite one-second startup resend loop
--   - routeChangeReceived being telemetry only (does not stop resends)
--   - routeNavigationStarted stopping resends and resetting the post-start completion timers
--   - stale/mismatched transition-id acknowledgements being rejected
--   - cancellation transition-id preservation (used by the cancellation payload)
--   - navigation pending-entry clearing

local M = {}
local Config = require("ge/extensions/ui/router/config")
local TransitionManager = require("ge/extensions/ui/router/managers/transitionManager")
local NavigationState = require("ge/extensions/ui/router/navigationState")

-- A minimal phased (Vue) session that begins in the indefinite startup phase.
local function makeStartupSession()
  return {
    routeName = "play",
    routeData = {},
    pendingEntry = { resolved = { name = "play" } },
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

--MARK: startup config

function M.testStartupResendIntervalIsOneSecond(ctx)
  ctx:setDescription("Startup resend interval is a fixed 1 second")
  ctx:assertEqual(Config.PhaseTimeouts.startupResendInterval, 1.0)
end

--MARK: indefinite startup resends

function M.testStartupResendsEverySecondIndefinitely(ctx)
  ctx:setDescription("Startup resends the pending entry every second and never times out")
  TransitionManager.reset()
  TransitionManager.start({ toRoute = { name = "play" }, fromRoute = nil, session = makeStartupSession() })

  -- Advance well past any old handoff/total budget; every full second must produce a resend
  -- and never a timeout.
  for i = 1, 30 do
    local event = TransitionManager.update(1.0)
    ctx:assert(event ~= nil, "expected a resend at second " .. i)
    ctx:assertEqual(event.type, "resendRouteChange")
    ctx:assert(event.entry ~= nil and event.entry.resolved.name == "play", "resend must carry the exact pending entry")
  end

  TransitionManager.reset()
end

function M.testReceivedDoesNotStopStartupResends(ctx)
  ctx:setDescription("routeChangeReceived is telemetry only and does not stop startup resends")
  TransitionManager.reset()
  TransitionManager.start({ toRoute = { name = "play" }, fromRoute = nil, session = makeStartupSession() })

  local ack = TransitionManager.markProgress("play", "routeChangeReceived")
  ctx:assert(ack.success == true, "expected routeChangeReceived to be accepted")

  local event = TransitionManager.update(1.0)
  ctx:assert(event ~= nil and event.type == "resendRouteChange", "receipt must not stop startup resends")

  TransitionManager.reset()
end

--MARK: start stops resends + resets timers

function M.testNavigationStartedStopsResends(ctx)
  ctx:setDescription("routeNavigationStarted stops the startup resends")
  TransitionManager.reset()
  TransitionManager.start({ toRoute = { name = "play" }, fromRoute = nil, session = makeStartupSession() })

  TransitionManager.markProgress("play", "routeNavigationStarted")

  -- Leaving startup: no resend, and not enough post-start time to time out yet.
  local event = TransitionManager.update(0.5)
  ctx:assert(event == nil, "expected no resend or timeout right after the start milestone")

  TransitionManager.reset()
end

function M.testPostStartTimersResetAfterLongStartup(ctx)
  ctx:setDescription("Completion timers reset after startup so the startup wait is excluded")
  TransitionManager.reset()
  TransitionManager.start({ toRoute = { name = "play" }, fromRoute = nil, session = makeStartupSession() })

  -- 5 seconds of startup waiting - far beyond the post-start budgets/total cap.
  for _ = 1, 5 do TransitionManager.update(1.0) end

  TransitionManager.markProgress("play", "routeNavigationStarted")

  -- Transition frame into routeCommit: timers reset, no timeout.
  local e0 = TransitionManager.update(0.1)
  ctx:assert(e0 == nil, "expected no timeout on the startup->routeCommit transition frame")

  -- Just under the routeCommit budget (3.0s), measured from the reset.
  local e1 = TransitionManager.update(2.8)
  ctx:assert(e1 == nil, "expected no timeout under the routeCommit budget after the reset")

  -- Cross the routeCommit budget.
  local e2 = TransitionManager.update(0.2)
  ctx:assert(e2 ~= nil and e2.type == "timeout", "expected a routeCommit timeout once the reset budget elapses")
  ctx:assertEqual(e2.classification, "route_change_not_completed")

  TransitionManager.reset()
end

--MARK: stale / mismatched transition ids

function M.testStaleTransitionIdIsRejectedOnProgress(ctx)
  ctx:setDescription("markProgress rejects a mismatched transition id")
  TransitionManager.reset()
  local started, transitionId = TransitionManager.start({ toRoute = { name = "play" }, session = makeStartupSession() })
  ctx:assert(started == true, "expected transition to start")

  local ack = TransitionManager.markProgress("play", "routeNavigationStarted", transitionId .. "_stale")
  ctx:assert(ack.success == false, "expected a stale transition id to be rejected")
  ctx:assertEqual(ack.reason, "transition_id_mismatch")

  -- The matching id is still accepted.
  local good = TransitionManager.markProgress("play", "routeNavigationStarted", transitionId)
  ctx:assert(good.success == true, "expected the matching transition id to be accepted")

  TransitionManager.reset()
end

function M.testStaleTransitionIdIsRejectedOnComplete(ctx)
  ctx:setDescription("complete rejects a mismatched transition id")
  TransitionManager.reset()
  local started, transitionId = TransitionManager.start({ toRoute = { name = "play" }, session = makeStartupSession() })
  ctx:assert(started == true, "expected transition to start")

  local ok, reason = TransitionManager.complete("play", transitionId .. "_stale")
  ctx:assert(ok == false, "expected a stale transition id to be rejected on complete")
  ctx:assertEqual(reason, "transition_id_mismatch")

  TransitionManager.reset()
end

--MARK: cancellation transition id

function M.testCancelReturnsStartedTransitionId(ctx)
  ctx:setDescription("cancel() returns the started transition id for the cancellation payload")
  TransitionManager.reset()
  local started, transitionId = TransitionManager.start({ toRoute = { name = "play" }, session = makeStartupSession() })
  ctx:assert(started == true, "expected transition to start")
  ctx:assert(type(transitionId) == "string" and transitionId ~= "", "expected a non-empty transition id")

  local wasCancelled, cancelledId = TransitionManager.cancel("route_change_rejected")
  ctx:assert(wasCancelled == true, "expected cancel to report an active transition")
  ctx:assertEqual(cancelledId, transitionId)

  TransitionManager.reset()
end

function M.testCancelWhenIdleReturnsNilId(ctx)
  ctx:setDescription("cancel() reports no id when there is no active transition")
  TransitionManager.reset()
  local wasCancelled, cancelledId = TransitionManager.cancel("cancelled")
  ctx:assert(wasCancelled == false, "expected no active transition")
  ctx:assert(cancelledId == nil, "expected a nil id when idle")
end

--MARK: pending-entry clearing

function M.testClearPendingEntryRemovesUncommittedEntry(ctx)
  ctx:setDescription("clearPendingEntry drops an uncommitted pending entry")
  -- Preserve any live pending entry so the manual in-game runner is non-destructive.
  local original = NavigationState.getPendingEntry()

  NavigationState.setPendingEntry({ resolved = { name = "play" } })
  ctx:assert(NavigationState.getPendingEntry() ~= nil, "expected a pending entry to be set")

  NavigationState.clearPendingEntry()
  ctx:assert(NavigationState.getPendingEntry() == nil, "expected the pending entry to be cleared")

  NavigationState.setPendingEntry(original)
end

return M
