-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local Constants = require("ge/extensions/ui/router/constants")
local M = {}

M.ModuleName = "multiplayer"

M.Root = {}

M.Children = {
  ["host-options"] = {
    screenId = "multiplayer.host-options"
  },
  ["settings"] = {
    screenId = "pause.multiplayer.settings",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    scopeTree = {
      ["pause-root"] = {
        ["menu-content-card-1"] = {}
      }
    },
    targetScope = "menu-content-card-1",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["gamemode"] = {
    screenId = "pause.multiplayer.gamemode",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["playerList"] = {
    screenId = "pause.multiplayer.playerList",
    onEnter = "ui_pause_routeLifecycleCallbacks.onPauseEnter",
    onMount = "ui_pause_routeLifecycleCallbacks.onPauseMount",
    onLeave = "ui_pause_routeLifecycleCallbacks.onPauseLeave",
    ui = {
      topBar = Constants.TopBarDefaultsHidden
    }
  },
  ["spectator"] = {
    screenId = "multiplayer.spectator",
    onEnter = "multiplayer_gamemodes_utils_spectator.onSpectatorViewEnter",
    onLeave = "multiplayer_gamemodes_utils_spectator.onSpectatorViewLeave",
    ui = {
      uiTypes = {"vue"},
      uiTypesFilter = Constants.UiTypesFilter.only,
      infoBar = Constants.InfoBarDefaultsHidden,
      topBar = Constants.TopBarDefaultsHidden,
      uiApps = { shown = true },
    },
  },
}

return M
