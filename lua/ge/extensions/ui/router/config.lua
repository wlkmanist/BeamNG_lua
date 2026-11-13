-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

-- Default route when no route is specified
M.MainRoute = "menu"

-- Timeout settings (in seconds)
M.Timeout = 3 -- Force complete threshold (flat timeout for non-phased Angular/legacy transitions)

-- Phased transition timeouts (in seconds) for the Vue acknowledgement flow.
-- Each phase waits for a specific progress ack before advancing:
--   startup     -> waiting for Vue Router to enter its pipeline (routeNavigationStarted)
--   routeCommit -> Vue Router started, waiting for routeChangeComplete
--   mountReady  -> route committed, waiting for routeMounted (when a mount ack is required)
--
-- The startup phase resends the pending route-change event on a fixed interval and never
-- times out on its own: runtime/mod Vue routes may register late, so the request stays
-- retryable until the UI reports the navigation started. routeChangeReceived is kept as
-- telemetry only and does not stop the resends. Once the start milestone is observed the
-- completion timers reset so the startup wait is excluded from the post-start budgets.
M.PhaseTimeouts = {
  -- Startup phase: resend the pending route-change event on this fixed interval, indefinitely,
  -- until the UI reports the Vue Router pipeline has started (routeNavigationStarted).
  startupResendInterval = 1.0,
  -- Post-start phase budgets (startup elapsed time is excluded from these).
  routeCommit = 3.0,
  mountReady = 3.0,
  -- Emergency cap across the post-start phases to prevent per-phase budgets from stacking
  -- forever. The indefinite startup wait is not counted against this cap.
  total = 8.0,
}

M.ContextDecoratorDefaultSource = "core_gamestate.gameStateDecorator"
M.ShowContextDecoratorInBreadcrumbs = false

-- Router-owned UI defaults merged into the base route config during resolution.
-- Values here are supplied only when a route (or its parents) does not set them,
-- so explicit route-level overrides always win.
M.RouteUiDefaults = {
  uiNav = true, -- UINav (gamepad/keyboard navigation) enabled unless a route opts out
}

return M
