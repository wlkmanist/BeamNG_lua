-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "legal"

M.Root = {
  abstract = true,
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = Constants.UiAppsDefaults
  }
}

M.Children = {
  ["onlineFeatures"] = {
    screenId = "legal.onlineFeatures",
    scopeTree = {
      ["root"] = {}
    },
    backTarget = nil,
    exitGuards = {"onlineConsentSet"},
    -- Preserve the controller hint bar that the consent wizard relies on (matches Vue meta).
    ui = {
      infoBar = Constants.InfoBarDefaults
    }
  },
  ["telemetry"] = {
    screenId = "legal.telemetry",
    scopeTree = {
      ["root"] = {}
    },
    backTarget = "legal.onlineFeatures",
    exitGuards = {"onlineConsentSet"},
    -- Preserve the controller hint bar that the consent wizard relies on (matches Vue meta).
    ui = {
      infoBar = Constants.InfoBarDefaults
    }
  },
  ["confirmation"] = {
    screenId = "legal.confirmation",
    scopeTree = {
      ["root"] = {}
    },
    backTarget = "legal.telemetry",
    exitGuards = {"onlineConsentSet"},
    -- Preserve the controller hint bar that the consent wizard relies on (matches Vue meta).
    ui = {
      infoBar = Constants.InfoBarDefaults
    }
  }
}

return M
