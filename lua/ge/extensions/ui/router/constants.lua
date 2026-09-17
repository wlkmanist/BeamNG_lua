-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

-- Transition states for the router state machine
M.TransitionStatus = {
  IDLE = "idle",               -- No transition in progress
  TRANSITIONING = "transitioning", -- Waiting for frameworks to complete
  CANCELLED = "cancelled",     -- Transition was cancelled
}

-- Navigation action types
M.NavigationAction = {
  PUSH = "push",
  REPLACE = "replace",
  BACK = "back",
  FORWARD = "forward",
}

-- Guard result types
M.GuardResult = {
  ALLOW = "allow",     -- Navigation is allowed to proceed
  REJECT = "reject",   -- Navigation is blocked
  REDIRECT = "redirect", -- Redirect to a different route
}

-- Framework action types (what should a framework do for a route)
M.FrameworkAction = {
  RENDER = "render",   -- Framework should render this route
  BLANK = "blank",     -- Framework should show blank/empty state
  HIDE = "hide",       -- Framework should hide completely
  PASSTHROUGH = "passthrough", -- Framework ignores this route change
}

-- Filter for which UI frameworks must complete for route change to succeed
M.UiTypesFilter = {
  only = "only",   -- only the ui types specified in the route should complete
  except = "except", -- all ui types except the ones specified should complete
  all = "all",     -- all registered ui types must complete
  any = "any",     -- at least one of the specified ui types must complete
}

-- UI element defaults
M.InfoBarDefaults = {
  visible = true,
  showSysInfo = true
}

M.TopBarDefaults = {
  visible = true
}

M.InfoBarDefaultsHidden = {
  visible = false,
  showSysInfo = false
}

M.TopBarDefaultsHidden = {
  visible = false
}

M.UiAppsDefaults = {
  shown = false
}

-- Default route config (must be after the individual defaults above)
M.RouteConfigDefaults = {
  ui = {
    uiTypes = {"angular", "vue"},
    uiTypesFilter = M.UiTypesFilter.any,
    infoBar = M.InfoBarDefaults,
    uiApps = M.UiAppsDefaults,
    topBar = M.TopBarDefaults,
  }
}

-- Hook event names emitted by the router.
-- These names are used as the suffix for GUI events ("ui_router_<name>") and,
-- for hooks that share a Lua extension hook name, as the Lua extension hook
-- name dispatched via extensions.hook(...). Hooks whose Lua extension hook
-- name diverges from the GUI event name are listed in RouterExtensionHooks
-- below and should be used for extensions.hook(...) calls.
M.RouterHooks = {
  BEFORE_ROUTE_CHANGE = "beforeRouteChange",
  ROUTE_CHANGE = "routeChange",
  ROUTE_CHANGE_SUCCESS = "routeChangeSuccess",
  AFTER_ROUTE_CHANGE = "afterRouteChange",
  ROUTE_CHANGE_ERROR = "routeChangeError",
  ROUTE_CHANGE_CANCELLED = "routeChangeCancelled",
  TRANSITION_TIMEOUT = "transitionTimeout",
  NAVIGATION_STATE_RESPONSE = "navigationStateResponse",
}

-- Lua extension hook names dispatched via extensions.hook(...). These follow
-- the standard "on<Event>" extension-hook naming convention so listeners
-- export them as M.on<Event>. They are intentionally separate from
-- RouterHooks above, which still drive the GUI event names.
M.RouterExtensionHooks = {
  AFTER_ROUTE_CHANGE = "onAfterRouteChange",
}

return M
