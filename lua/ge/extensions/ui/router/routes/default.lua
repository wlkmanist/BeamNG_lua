-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "default"

M.Root = {
  abstract = true,
}

M.Children = {
  ["iconViewer"] = {
    ui = {
      uiTypes = {"angular"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = Constants.UiAppsDefaults,
    }
  },
  ["mapview"] = {
    ui = {
      uiTypes = {"angular"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = Constants.UiAppsDefaults,
    }
  },
  ["options"] = {
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = Constants.UiAppsDefaults,
    }
  },
  ["play"] = {
    ui = {
      uiTypes = {"angular"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = {
        shown = true,
      }
    }
  },
  ["radial"] = {
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = Constants.UiAppsDefaults,
    }
  }
}

return M
