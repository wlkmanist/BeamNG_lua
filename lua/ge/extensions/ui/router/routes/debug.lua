-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

-- ModuleName(optional) by default is the name of the file unless specified otherwise
-- Uncomment and set to a different name if you want to specify a different name for the route module
-- local ModuleName = nil

M.Root = {
  abstract = true,
  ui = {
    uiTypes = {"vue"},
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults,
  },
}

M.Children = {
  ["components"] = {
    scopeTree = {
      ["root"] = {
        ["demo"] = {}
      }
    }
  },
  ["ui-apps-test"] = {},
  ["asyncBulkLoader"] = {},
}

return M
