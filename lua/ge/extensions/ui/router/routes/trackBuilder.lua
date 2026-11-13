-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "trackBuilder"

M.Root = {
  screenId = "trackBuilder",
  title = "ui.playmodes.trackBuilder",
  back = { mode = "rootExit" },
  scopeTree = {
    ["track-builder-root"] = {},
  },
  onEnter = "trackbuilder_trackBuilder.onRouteEnter",
  onLeave = "trackbuilder_trackBuilder.onRouteLeave",
  ui = {
    uiNav = false,
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = { shown = false },
  },
}

M.Children = {}

return M
