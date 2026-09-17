-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "mission"

M.Root = {
  screenId = "mission",
  abstract = true,
  ui = {
    uiTypes = {"vue"},
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults
  }
}

M.Children = {
  ["details"] = {
    screenId = "mission.details",
    back = {
      mode = "handler",
      handler = "missionDetailsExitHandler"
    },
    scopeTree = {
      ["root"] = {
        ["details-scope"] = {},
      },
    }
  },
  ["control"] = {
    screenId = "mission.control",
    backTarget = "pause",
    scopeTree = {
      ["mission-control"] = {}
    },
    children = {
      ["vehicleSelector"] = {
        screenId = "mission.control.vehicleSelector",
        onEnter = "ui_gridSelectorRouteLifecycleCallbacks.onRouteEnter",
        onMount = "ui_gridSelectorRouteLifecycleCallbacks.onRouteMount",
        onLeave = "ui_gridSelectorRouteLifecycleCallbacks.onRouteLeave",
        back = {
          mode = "handler",
          handler = "missionVehicleSelectorBackHandler"
        },
        meta = {
          gridSelector = {
            backendName = "vehicleSelector",
            routePath = "/mission-vehicle-selector",
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
      }
    }
  },
  ["grid"] = {
    screenId = "mission.grid"
  },
  ["dragHistory"] = {
    screenId = "mission.dragHistory"
  },
  ["dragRules"] = {
    screenId = "mission.dragRules"
  },
  ["aiCompetitorsLeaderboardTable"] = {
    screenId = "mission.aiCompetitorsLeaderboardTable"
  }
}

return M
