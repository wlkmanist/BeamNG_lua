-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Vue port of the legacy Angular lightRunner module (ui/modules/lightrunner).
-- Kept as a separate route tree from the legacy "menu.lightrunner" so both
-- can exist side by side behind a feature flag until the legacy module is
-- removed. Structurally identical to quickraceWizard.lua (see that file for
-- more detail); lightRunner shares the same oneshotRaceCore.lua backend and
-- only differs in which Lua configurator/grid-selector it points at.
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "lightrunnerWizard"

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
  screenId = "lightrunnerWizard",
  title = "ui.playmodes.lightRunner",
  onEnter = "lightrunner_lightrunnerConfigurator.onWizardRouteEnter",
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
    screenId = "lightrunnerWizard.level",
    -- Reuses busRoute's "Select Level" key rather than adding a new l10n
    -- entry - "ui.quickrace.quickraceLevels" ("Time Trials Map selection")
    -- doesn't fit lightRunner.
    title = "ui.busRoute.levelSelect",
    onEnter = "lightrunner_lightrunnerConfigurator.onWizardLevelRouteEnter",
    scopeTree = gridScopeTree,
    targetScope = "grid-selector-grid",
    children = {
      ["middle"] = {
        isMinorRoute = true,
        screenId = "lightrunnerWizard.level.middle",
        title = "ui.quickrace.quickraceTracks",
        onEnter = "lightrunner_lightrunnerConfigurator.onWizardMiddleRouteEnter",
        scopeTree = gridScopeTree,
        targetScope = "grid-selector-grid",
      }
    }
  },
  ["vehicle"] = {
    screenId = "lightrunnerWizard.vehicle",
    title = "ui.quickrace.selectVehicle",
    onEnter = "lightrunner_lightrunnerConfigurator.onWizardVehicleRouteEnter",
    scopeTree = gridScopeTree,
    targetScope = "grid-selector-grid",
  },
}

return M
