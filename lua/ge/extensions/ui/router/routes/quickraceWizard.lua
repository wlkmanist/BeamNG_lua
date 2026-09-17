-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vue port of the legacy Angular quickrace module (ui/modules/quickrace).
-- Kept as a separate route tree from the legacy "menu.quickrace" so both can
-- exist side by side behind a feature flag until the legacy module is
-- removed. The root route is the overview/options screen (mirrors
-- overview.html acting as the wizard's home), with level/middle(track)/vehicle
-- selection as drilldown children that return to it. Structurally identical
-- to lightrunnerWizard.lua/busRouteWizard.lua (see those for the sibling
-- modes sharing the oneshotRaceCore.lua backend).
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "quickraceWizard"

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
  screenId = "quickraceWizard",
  title = "ui.playmodes.quickrace",
  onEnter = "quickrace_quickraceConfigurator.onWizardRouteEnter",
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
    screenId = "quickraceWizard.level",
    title = "ui.quickrace.quickraceLevels",
    onEnter = "quickrace_quickraceConfigurator.onWizardLevelRouteEnter",
    scopeTree = gridScopeTree,
    targetScope = "grid-selector-grid",
    children = {
      ["middle"] = {
        isMinorRoute = true,
        screenId = "quickraceWizard.level.middle",
        title = "ui.quickrace.quickraceTracks",
        onEnter = "quickrace_quickraceConfigurator.onWizardMiddleRouteEnter",
        scopeTree = gridScopeTree,
        targetScope = "grid-selector-grid",
      }
    }
  },
  ["vehicle"] = {
    screenId = "quickraceWizard.vehicle",
    title = "ui.quickrace.selectVehicle",
    onEnter = "quickrace_quickraceConfigurator.onWizardVehicleRouteEnter",
    scopeTree = gridScopeTree,
    targetScope = "grid-selector-grid",
  },
}

return M
