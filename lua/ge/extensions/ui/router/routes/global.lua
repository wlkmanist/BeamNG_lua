-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.Children = {
  ["buttonLayout"] = {
    ui = {
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = Constants.UiAppsDefaults,
    }
  },

  ["play"] = {
    screenId = "play",
    title = "Play",
    back = { mode = "rootExit" },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = {
        shown = true,
      }
    }
  },

  ["/mainmenu"] = {
    screenId = "menu",
    title = "Main Menu",
    back = { mode = "rootExit" },
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = {
        shown = false,
      }
    }
  },
}

return M