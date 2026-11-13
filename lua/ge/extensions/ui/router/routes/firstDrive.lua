-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "firstDrive"

M.Root = {
  screenId = "firstDrive",
  onMount = "gameplay_discover_firstDrive_experience.onFirstDriveRouteMount",
  back = {
    mode = "handler",
    handler = "firstDriveLockedHandler",
  },
  scopeTree = {
    ["first-drive-intro"] = {},
  },
  ui = {
    uiTypes = {"vue"},
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = {shown = false},
    triggerPause = false,
  },
}

M.Children = {
  ["onboarding"] = {
    screenId = "firstDrive.onboarding",
    back = {
      mode = "handler",
      handler = "previousRouteBackHandler",
    },
    scopeTree = {
      ["root"] = {},
    },
    ui = {
      infoBar = Constants.InfoBarDefaults,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = {shown = false},
    },
  },
  ["arrival"] = {
    screenId = "firstDriveArrival",
    onMount = "gameplay_discover_firstDrive_experience.onFirstDriveArrivalRouteMount",
    back = {
      mode = "handler",
      handler = "firstDriveLockedHandler",
    },
    scopeTree = {
      ["first-drive-arrival"] = {},
    },
  },
  ["completion"] = {
    screenId = "firstDriveCompletion",
    onMount = "gameplay_discover_firstDrive_experience.onFirstDriveCompletionRouteMount",
    back = {
      mode = "handler",
      handler = "firstDriveLockedHandler",
    },
    scopeTree = {
      ["first-drive-completion"] = {},
    },
  },
  ["recovery"] = {
    screenId = "firstDriveRecovery",
    backTarget = "play",
    onLeave = "gameplay_discover_firstDrive_experience.onFirstDriveRecoveryRouteLeave",
    scopeTree = {
      ["first-drive-recovery"] = {},
    },
  },
  ["learning"] = {
    screenId = "firstDriveLearningAreas",
    backTarget = "pause",
    onEnter = "gameplay_discover_firstDrive_experience.onFirstDriveLearningRouteEnter",
    onLeave = "gameplay_discover_firstDrive_experience.onFirstDriveLearningRouteLeave",
    targetScope = "first-drive-learning-areas",
    scopeTree = {
      ["root"] = {
        ["first-drive-learning-areas"] = {
          backTarget = "pause",
          backTargetType = "route",
        },
      },
    },
    ui = {
      infoBar = Constants.InfoBarDefaults,
      triggerPause = true,
    },
  },
}

return M
