-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.Root = {
  screenId = "radial",
  -- returning to the radial root ends any pending route handoff and unhides the menu
  onEnter = "core_quickAccess.endRouteHandoff",
  back = {
    mode = "handler",
    handler = "radialBackHandler",
  },
  ui = {
    uiTypes = {"vue"},
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults,
  },
}

M.Children = {
  ["vehicles"] = {
    screenId = "radial.vehicles",
    onEnter = "ui_gridSelectorRouteLifecycleCallbacks.onRouteEnter",
    onMount = "ui_gridSelectorRouteLifecycleCallbacks.onRouteMount",
    onLeave = "ui_gridSelectorRouteLifecycleCallbacks.onRouteLeave",
    meta = {
      gridSelector = {
        backendName = "vehicleSelector",
        routePath = "/vehicle-selector",
        defaultPath = { keys = { "allModels" } },
      }
    },
    scopeTree = {
      ["grid-selector-grid"] = {
        ["grid-selector-details"] = {
          backTarget = "grid-selector-grid",
          backTargetType = "scope"
        }
      }
    },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
    }
  },
  ["vehicleconfig"] = {
    -- radial-owned vehicle config; renders the concrete vue route instead of the
    -- redirecting menu.vehicleconfig parent so lua/vue mount acks stay in the radial family
    screenId = "radial.vehicleconfig",
    backTarget = "radial",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
    }
  },
  ["mirrors"] = {
    screenId = "radial.mirrors",
    title = "ui.mirrors.name",
    backTarget = "radial",
  },
}

return M