-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")

local M = {}

M.ModuleName = "scenario"

M.Root = {
  abstract = true,
  ui = {
    uiTypesFilter = Constants.UiTypesFilter.only,
    infoBar = Constants.InfoBarDefaultsHidden,
    topBar = Constants.TopBarDefaultsHidden,
    uiApps = {
      shown = true,
    },
  },
}

M.Children = {
  ["start"] = {
    screenId = "scenario.start",
    backTarget = "pause",
    ui = {
      uiTypes = {"vue"},
    },
    targetScope = "scenario-start-actions",
    scopeTree = {
      ["scenario-start-root"] = {
        ["scenario-start-actions"] = { backTarget = "scenario-start-root", backTargetType = "scope" },
        -- Only one of settings/progress/vehicle (or none) ever renders,
        -- depending on the scenario's introType/data (see ScenarioStart.vue) -
        -- mark them optional so RouteScopeValidator doesn't warn about
        -- whichever ones this scenario doesn't use.
        ["scenario-start-settings"] = { backTarget = "scenario-start-root", backTargetType = "scope", optional = true },
        ["scenario-start-progress"] = { backTarget = "scenario-start-root", backTargetType = "scope", optional = true },
        ["scenario-start-vehicle"] = { backTarget = "scenario-start-root", backTargetType = "scope", optional = true },
      },
    },
  },

  ["end"] = {
    screenId = "scenario.end",
    ui = {
      uiTypes = {"vue"},
    },
    backTarget = "pause",
    targetScope = "scenario-end-actions",
    scopeTree = {
      ["scenario-end-root"] = {
        ["scenario-end-actions"] = { backTarget = "scenario-end-root", backTargetType = "scope" },
        -- stats/mission are mutually exclusive (StandardScenarioEndScreen.vue
        -- picks one based on hasMissionData) and rewards only renders when the
        -- scenario actually has rewards - mark all three optional so
        -- RouteScopeValidator doesn't warn about whichever ones this
        -- particular scenario end doesn't use.
        ["scenario-end-rewards"] = { backTarget = "scenario-end-root", backTargetType = "scope", optional = true },
        ["scenario-end-stats"] = { backTarget = "scenario-end-root", backTargetType = "scope", optional = true },
        ["scenario-end-mission"] = { backTarget = "scenario-end-root", backTargetType = "scope", optional = true },
      },
    },
  },

  ["quickrace"] = {
    abstract = true,
    children = {
      ["end"] = {
        screenId = "scenario.quickrace.end",
        backTarget = "pause",
        ui = {
          uiTypes = {"vue"},
        },
        scopeTree = {
          ["scenario-quickrace-end-root"] = {
            ["scenario-quickrace-end-laps"] = { backTarget = "scenario-quickrace-end-root", backTargetType = "scope" },
            ["scenario-quickrace-end-leaderboard"] = { backTarget = "scenario-quickrace-end-root", backTargetType = "scope" },
            ["scenario-quickrace-end-actions"] = { backTarget = "scenario-quickrace-end-root", backTargetType = "scope" },
          },
        },
      },
    },
  },

  ["chapter"] = {
    abstract = true,
    children = {
      ["end"] = {
        screenId = "scenario.chapter.end",
        backTarget = "pause",
        targetScope = "scenario-end-actions",
        ui = {
          uiTypes = {"vue"},
        },
        scopeTree = {
          ["scenario-end-root"] = {
            ["scenario-end-actions"] = { backTarget = "scenario-end-root", backTargetType = "scope" },
            -- see the "end" route above - stats/mission/rewards render conditionally.
            ["scenario-end-rewards"] = { backTarget = "scenario-end-root", backTargetType = "scope", optional = true },
            ["scenario-end-stats"] = { backTarget = "scenario-end-root", backTargetType = "scope", optional = true },
            ["scenario-end-mission"] = { backTarget = "scenario-end-root", backTargetType = "scope", optional = true },
          },
        },
      },
    },
  },
}

return M
