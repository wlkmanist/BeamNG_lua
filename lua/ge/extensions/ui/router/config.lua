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
--   handoff     -> waiting for the UI to accept the route (routeChangeReceived)
--   routerStart -> UI accepted, waiting for Vue Router to enter its pipeline (routeNavigationStarted)
--   routeCommit -> Vue Router started, waiting for routeChangeComplete
--   mountReady  -> route committed, waiting for routeMounted (when a mount ack is required)
M.PhaseTimeouts = {
  -- Handoff phase: resend the pending route-change event until the UI acknowledges it.
  handoffResendDelay = 0.4, -- delay before resending the pending route-change event
  handoffMaxResends = 2,    -- max resend attempts after the initial emit
  handoff = 1.5,            -- hard timeout for the handoff phase
  -- Remaining phase budgets.
  routerStart = 1.0,
  routeCommit = 3.0,
  mountReady = 3.0,
  -- Emergency cap across all phases to prevent per-phase budgets from stacking forever.
  total = 8.0,
}

M.ContextDecoratorDefaultSource = "core_gamestate.gameStateDecorator"
M.ShowContextDecoratorInBreadcrumbs = false

-- Loading screen configuration
M.LoadingScreen = {
  show = false,              -- Show loading screen by default
  defaultMode = "custom",    -- "progress" | "custom" (custom = fade style)
  autoHideOnComplete = true, -- Auto-hide when routeChangeComplete is called
}

return M
