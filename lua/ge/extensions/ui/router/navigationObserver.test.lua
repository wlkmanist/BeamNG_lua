-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("navigationObserver")
--
-- Focused coverage for the non-shipping NavigationObserver diagnostics module:
--   - identical resolved requests classified as duplicate_navigation
--   - a difference in route, params, scope, or options classified as conflicting_navigation
--   - external Lua caller attribution, and the bridge/unknown fallback when no Lua frame is available
--   - exactly one warning per preempted attempt, and reset() clearing all state
--   - no report unless a proven preemption (both attempts present, distinct ids) is supplied

local M = {}
local NavigationObserver = require("ge/extensions/ui/router/navigationObserver")

-- Build a resolved-target payload in the shape resolveNavigationTarget() produces, so
-- attachResolvedTarget() maps it onto an attempt the same way the router does.
local function makeTarget(route, scope, params, extraOptions)
  local options = { routeScopeId = scope }
  for key, value in pairs(extraOptions or {}) do
    options[key] = value
  end
  return {
    fullRouteName = route,
    params = params,
    options = options,
  }
end

-- Begin an attempt and immediately attach a resolved target, mirroring the router's
-- navigate() -> resolveNavigationTarget() sequence.
local function makeResolvedAttempt(route, scope, params, extraOptions)
  local attempt = NavigationObserver.beginAttempt()
  NavigationObserver.attachResolvedTarget(attempt, makeTarget(route, scope, params, extraOptions))
  return attempt
end

--MARK: classification - duplicates

function M.testIdenticalRequestsAreDuplicate(ctx)
  ctx:setDescription("Identical resolved route, scope, params and options classify as duplicate_navigation")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("menu.mainmenu", "menu-scope", { id = 3 }, { force = true })
  local replacement = makeResolvedAttempt("menu.mainmenu", "menu-scope", { id = 3 }, { force = true })

  local record = NavigationObserver.reportPreemption(preempted, replacement, "active_transition")
  ctx:assert(record ~= nil, "expected a warning record for a proven preemption")
  ctx:assertEqual(record.category, "duplicate_navigation")
  ctx:assertEqual(record.phase, "active_transition")
  ctx:assert(record.preempted == preempted, "record must reference the preempted attempt")
  ctx:assert(record.replacement == replacement, "record must reference the replacement attempt")

  NavigationObserver.reset()
end

--MARK: classification - conflicts

function M.testDifferentRouteIsConflict(ctx)
  ctx:setDescription("A different resolved route classifies as conflicting_navigation")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("menu.mainmenu", "menu-scope", { id = 1 })
  local replacement = makeResolvedAttempt("garage", "menu-scope", { id = 1 })

  local record = NavigationObserver.reportPreemption(preempted, replacement, "post_guard")
  ctx:assert(record ~= nil, "expected a warning record")
  ctx:assertEqual(record.category, "conflicting_navigation")

  NavigationObserver.reset()
end

function M.testDifferentParamsIsConflict(ctx)
  ctx:setDescription("Differing effective params classify as conflicting_navigation")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("mission.dragHistory", "scope", { id = 1, level = 2 })
  local replacement = makeResolvedAttempt("mission.dragHistory", "scope", { id = 1, level = 9 })

  local record = NavigationObserver.reportPreemption(preempted, replacement, "post_guard")
  ctx:assert(record ~= nil, "expected a warning record")
  ctx:assertEqual(record.category, "conflicting_navigation")

  NavigationObserver.reset()
end

function M.testDifferentScopeIsConflict(ctx)
  ctx:setDescription("A different resolved scope classifies as conflicting_navigation")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("garage.vehicle.save", "garage-vehicle-save", nil)
  local replacement = makeResolvedAttempt("garage.vehicle.save", "garage-layout", nil)

  local record = NavigationObserver.reportPreemption(preempted, replacement, "post_onenter")
  ctx:assert(record ~= nil, "expected a warning record")
  ctx:assertEqual(record.category, "conflicting_navigation")

  NavigationObserver.reset()
end

function M.testDifferentOptionsIsConflict(ctx)
  ctx:setDescription("Differing router options classify as conflicting_navigation")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("play", "scope", nil, { force = true })
  local replacement = makeResolvedAttempt("play", "scope", nil, { force = false })

  local record = NavigationObserver.reportPreemption(preempted, replacement, "post_guard")
  ctx:assert(record ~= nil, "expected a warning record")
  ctx:assertEqual(record.category, "conflicting_navigation")

  NavigationObserver.reset()
end

--MARK: source attribution

function M.testBeginAttemptAttributesExternalCaller(ctx)
  ctx:setDescription("beginAttempt skips router-internal frames and attributes an external Lua caller")
  NavigationObserver.reset()

  -- The captured frame must not be this router-subsystem test file, and must not be the
  -- bridge/unknown fallback, since a real Lua frame (the test runner) is on the stack.
  local attempt = NavigationObserver.beginAttempt()
  ctx:assert(attempt.source ~= nil, "expected a captured source")
  ctx:assertEqual(attempt.id, 1, "first attempt after reset should have id 1")
  ctx:assert(attempt.source.module ~= "bridge/unknown", "expected an external Lua caller, not the bridge fallback")
  ctx:assert(attempt.source.file ~= nil, "expected a source file for a Lua caller")
  ctx:assert(attempt.source.file:find("ui/router/", 1, true) == nil, "captured source must be external to the router subsystem")

  NavigationObserver.reset()
end

function M.testBeginAttemptFallsBackToBridgeUnknown(ctx)
  ctx:setDescription("beginAttempt falls back to bridge/unknown when no Lua frame is available")
  NavigationObserver.reset()

  -- Simulate a non-Lua (bridge/engine) caller: no stack frames are visible to the walk.
  local originalGetInfo = debug.getinfo
  debug.getinfo = function() return nil end
  local ok, attempt = pcall(NavigationObserver.beginAttempt)
  debug.getinfo = originalGetInfo

  ctx:assert(ok, "beginAttempt must not error when the stack walk yields nothing")
  ctx:assertEqual(attempt.source.module, "bridge/unknown")
  ctx:assert(attempt.source.file == nil, "bridge/unknown fallback carries no file")

  NavigationObserver.reset()
end

--MARK: one warning per attempt + reset

function M.testPreemptedAttemptIsReportedOnlyOnce(ctx)
  ctx:setDescription("A given preempted attempt is warned about at most once")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("play", "scope", nil)
  local first = makeResolvedAttempt("garage", "scope", nil)
  local second = makeResolvedAttempt("menu.mainmenu", "scope", nil)

  local firstRecord = NavigationObserver.reportPreemption(preempted, first, "post_guard")
  ctx:assert(firstRecord ~= nil, "expected the first preemption to be reported")

  local secondRecord = NavigationObserver.reportPreemption(preempted, second, "post_onenter")
  ctx:assert(secondRecord == nil, "the same preempted attempt must not be reported twice")

  NavigationObserver.reset()
end

function M.testResetClearsCounterAndReportState(ctx)
  ctx:setDescription("reset clears the attempt counter, current attempt and dedupe state")
  NavigationObserver.reset()

  local preempted = makeResolvedAttempt("play", "scope", nil)
  local replacement = makeResolvedAttempt("garage", "scope", nil)
  ctx:assert(NavigationObserver.reportPreemption(preempted, replacement, "post_guard") ~= nil, "expected a report before reset")
  ctx:assert(NavigationObserver.getCurrentAttempt() ~= nil, "expected a current attempt before reset")

  NavigationObserver.reset()
  ctx:assert(NavigationObserver.getCurrentAttempt() == nil, "reset must clear the current attempt")

  -- Counter is back to zero: the next attempt is id 1 again.
  local afterReset = NavigationObserver.beginAttempt()
  ctx:assertEqual(afterReset.id, 1, "reset must restart the attempt counter")

  NavigationObserver.reset()
end

--MARK: no report without a proven preemption

function M.testMissingAttemptsAreNotReported(ctx)
  ctx:setDescription("reportPreemption is a no-op when either attempt is missing")
  NavigationObserver.reset()

  local attempt = makeResolvedAttempt("play", "scope", nil)
  ctx:assert(NavigationObserver.reportPreemption(nil, attempt, "post_guard") == nil, "nil preempted must not report")
  ctx:assert(NavigationObserver.reportPreemption(attempt, nil, "post_guard") == nil, "nil replacement must not report")

  NavigationObserver.reset()
end

function M.testSelfPreemptionIsNotReported(ctx)
  ctx:setDescription("An attempt preempting itself is never reported")
  NavigationObserver.reset()

  local attempt = makeResolvedAttempt("play", "scope", nil)
  ctx:assert(NavigationObserver.reportPreemption(attempt, attempt, "post_guard") == nil, "self-preemption must not report")

  NavigationObserver.reset()
end

return M
