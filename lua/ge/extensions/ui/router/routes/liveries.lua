-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "liveries"
M.Root = {
  screenId = "liveries",
  title = "ui.liveries.title",
  scopeTree = {
    ["root"] = {}
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults
  },
  onEnter = "ui_liveries_routeLifecycleCallbacks.onLiveriesEnter",
  onLeave = "ui_liveries_routeLifecycleCallbacks.onLiveriesRootLeave"
}

M.Children = {
  ["edit"] = {
    screenId = "liveries.edit",
    title = "ui.liveries.edit.title",
    backTarget = "liveries",
    scopeTree = {
      ["root"] = {}
    },
    onEnter = "ui_liveries_routeLifecycleCallbacks.onLiveriesEditEnter",
    onLeave = "ui_liveries_routeLifecycleCallbacks.onLiveriesLeave",
    children = {
      ["paint"] = {
        screenId = "liveries.edit.paint",
        title = "ui.liveries.edit.paint",
        backTarget = "liveries.edit",
        scopeTree = {
          ["root"] = {}
        },
        onEnter = "ui_liveries_routeLifecycleCallbacks.onLiveriesPaintEnter"
      },
      ["decals"] = {
        include = "decals"
      }
    }
  }
}

return M