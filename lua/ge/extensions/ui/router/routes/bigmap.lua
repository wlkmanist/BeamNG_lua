-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

-- ModuleName(optional) by default is the name of the file unless specified otherwise
-- Uncomment and set to a different name if you want to specify a different name for the route module
-- local ModuleName = nil

M.Root = {
  screenId = "bigmap",
  title = "Map",
  targetScope = "bigmap-main",
  scopeTree = {
    ["bigmap-layout"] = {
      ["bigmap-camera"] = {},
      ["bigmap-main"] = {
        ["bigmap-details"] = {},
      },
    },
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaults,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults,
  },
}

M.Children = {
  ["bigmapMenu"] = {
    screenId = "bigmap.bigmapMenu",
    ui = {
      uiTypes = {"vue"},
    }
  },

}

return M
