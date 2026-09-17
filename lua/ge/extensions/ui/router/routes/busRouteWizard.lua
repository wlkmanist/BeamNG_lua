-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vue port of the legacy Angular busRoute module (ui/modules/busRoute). Kept
-- as a separate route tree from the legacy "menu.busRoutes" so both can
-- exist side by side behind a feature flag until the legacy module is
-- removed. Structurally identical to quickraceWizard.lua (see that file for
-- more detail); busRoute shares the same oneshotRaceCore.lua backend and
-- only differs in which Lua configurator/grid-selector it points at.
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "busRouteWizard"

local gridScopeTree = {
  ["root"] = {
    ["grid-selector-grid"] = {},
    ["grid-selector-details"] = {
      backTarget = "grid-selector-grid",
      backTargetType = "scope"
    }
  },
}

M.Root = {
  screenId = "busRouteWizard",
  title = "ui.playmodes.bus",
  onEnter = "busroute_busrouteConfigurator.onWizardRouteEnter",
  scopeTree = {
    ["root"] = {}
  },
  targetScope = "root",
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults,
  }
}

M.Children = {
  ["level"] = {
    screenId = "busRouteWizard.level",
    title = "ui.busRoute.levelSelect",
    onEnter = "busroute_busrouteConfigurator.onWizardLevelRouteEnter",
    scopeTree = gridScopeTree,
    targetScope = "grid-selector-grid",
    children = {
      ["middle"] = {
        isMinorRoute = true,
        screenId = "busRouteWizard.level.middle",
        title = "ui.busRoute.routeSelect",
        onEnter = "busroute_busrouteConfigurator.onWizardMiddleRouteEnter",
        scopeTree = gridScopeTree,
        targetScope = "grid-selector-grid",
      }
    }
  },
  ["vehicle"] = {
    screenId = "busRouteWizard.vehicle",
    title = "ui.quickrace.selectVehicle",
    onEnter = "busroute_busrouteConfigurator.onWizardVehicleRouteEnter",
    scopeTree = gridScopeTree,
    targetScope = "grid-selector-grid",
  },
}

return M
