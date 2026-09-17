-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "freeroamLevels"

M.Root = {
  screenId = "freeroamLevels",
  title = "ui.menu.freeroamSelector.wizard.location",
  onEnter = "freeroam_freeroamConfigurator.onWizardLevelsRouteEnter",
  onMount = "freeroam_freeroamConfigurator.onWizardLevelsRouteMount",
  scopeTree = {
    ["root"] = {
      ["grid"] = {},
      ["auxillary"] = {
        backTarget = "grid",
        backTargetType = "scope"
      }
    },
  },
  targetScope = "grid",
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaultsHidden,
  }
}

M.Children = {
  ["level"] = {
    isMinorRoute = true,
    screenId = "freeroamLevels.level",
    title = {
      mode = "dynamic",
      source = "freeroam_freeroamConfigurator.resolveSelectedLevelTitle",
      fallback = "ui.menu.freeroamSelector.wizard.location"
    },
    onEnter = "freeroam_freeroamConfigurator.onWizardLevelDetailRouteEnter",
    onMount = "freeroam_freeroamConfigurator.onWizardLevelDetailRouteMount",
    scopeTree = {
      ["root"] = {
        ["grid"] = {},
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      },
    },
    targetScope = "grid",
  },
  ["vehicles"] = {
    screenId = "freeroamLevels.vehicles",
    onEnter = "freeroam_freeroamConfigurator.onWizardVehiclesRouteEnter",
    onMount = "freeroam_freeroamConfigurator.onWizardVehiclesRouteMount",
    title = "ui.menu.freeroamSelector.wizard.vehicle",
    scopeTree = {
      ["root"] = {
        ["grid"] = {},
        ["auxillary"] = {
          backTarget = "grid",
          backTargetType = "scope"
        }
      },
    },
    targetScope = "grid",
    children = {
      ["vehicle"] = {
        isMinorRoute = true,
        screenId = "freeroamLevels.vehicles.vehicle",
        title = {
          mode = "dynamic",
          source = "freeroam_freeroamConfigurator.resolveSelectedVehicleTitle",
          fallback = "ui.menu.freeroamSelector.wizard.vehicle"
        },
        onEnter = "freeroam_freeroamConfigurator.onWizardVehicleDetailRouteEnter",
        onMount = "freeroam_freeroamConfigurator.onWizardVehicleDetailRouteMount",
        scopeTree = {
          ["root"] = {
            ["grid"] = {},
            ["auxillary"] = {
              backTarget = "grid",
              backTargetType = "scope"
            }
          },
        },
        targetScope = "grid",
      },
      ["options"] = {
        screenId = "freeroamLevels.vehicles.options",
        title = "ui.menu.freeroamSelector.wizard.options",
        onEnter = "freeroam_freeroamConfigurator.onWizardRouteEnter",
        scopeTree = {
          ["root"] = {}
        },
        targetScope = "root",
        children = {
          ["multiplayer"] = {
            isMinorRoute = true,
            screenId = "freeroamLevels.vehicles.options.multiplayer",
            title = "ui.dashboard.multiplayer",
            onEnter = "freeroam_freeroamConfigurator.onWizardRouteEnter",
            scopeTree = {
              ["root"] = {}
            },
            targetScope = "root",
          }
        }
      }
    }
  }
}

return M
