-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "options"

M.Root = {
  screenId = "options",
  title = "Options",
  fallbackTarget = "menu",
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = {
      visible = true,
      showSysInfo = false
    },
    topBar = {
      visible = false
    },
    uiApps = {
      shown = false
    },
  }
}

M.Children = {
  ["category"] = {
    screenId = "pause.options.category",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  }
}

return M
