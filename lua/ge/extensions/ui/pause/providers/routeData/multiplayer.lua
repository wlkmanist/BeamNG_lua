-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}

local function isMultiplayerActionsEditable(context)
  return not context or context.mode ~= "freeroamTutorial"
end

local function getPlayerListSidePanelContents()
  return {
    {
      {
        id = "multiplayerPlayerListTitle",
        type = "title",
        text = "ui.multiplayer.players",
      },
      {
        id = "multiplayerPlayerListComponent",
        type = "component",
        componentName = "PauseMultiplayerPlayerList",
      },
    },
  }
end

function M.getMultiplayerData(context)
  local isActive = context.isMultiplayerActive == true
  local editable = isMultiplayerActionsEditable(context)
  local disabledReason = editable and nil or "Read-only in this mode"
  local hasRunningGamemode = multiplayer_gamemodeManager and multiplayer_gamemodeManager.getCurrentGamemodeExt() ~= nil
  local gamemodeRoute = hasRunningGamemode and "pause.gamemodeSettings" or "pause.gamemodes"

  return {
    active = true,
    disabledReason = disabledReason,
    mainPanelContent = {
      {
        id = "multiplayerHomeRouteButtons",
        type = "component",
        componentName = "PausePanelButtons",
        props = {
          buttons = {
            Common.registerPauseButton({
              id = "openMultiplayerSessionSettingsFromHome",
              label = isActive and "Session Settings" or "Create Session...",
              icon = "adjust",
              routeTarget = "pause.multiplayer.settings",
              enabled = editable,
              disabledReason = disabledReason,
              callback = function()
                return Common.tryPushStateSequence("pause.multiplayer.settings")
              end,
            }),
            Common.registerPauseButton({
              id = "openMultiplayerGamemodeFromHome",
              label = _tr("ui.multiplayer.gamemodes"),
              icon = "play",
              routeTarget = gamemodeRoute,
              enabled = editable and isActive,
              disabledReason = disabledReason,
              callback = function()
                return Common.tryPushStateSequence(gamemodeRoute)
              end,
            }),
            Common.registerPauseButton({
              id = "openMultiplayerPlayerListFromHome",
              label = "Manage Players",
              icon = "helmets",
              routeTarget = "pause.multiplayer.playerList",
              enabled = editable and isActive,
              disabledReason = disabledReason,
              callback = function()
                return Common.tryPushStateSequence("pause.multiplayer.playerList")
              end,
            }),
          },
        },
      }
    },
    sidePanelContents = getPlayerListSidePanelContents(),
  }
end

function M.getMultiplayerSettingsData()
  return {
    mainPanelContent = {
      {
        id = "multiplayerSettingsComponent",
        type = "component",
        componentName = "PauseMultiplayerSessionTab",
      },
    },
    sidePanelContents = getPlayerListSidePanelContents(),
  }
end

M.getPlayerListSidePanelContents = getPlayerListSidePanelContents

function M.getMultiplayerPlayerListData()
  return {
    mainPanelContent = {
      {
        id = "multiplayerPlayerListTitle",
        type = "title",
        text = "Players",
      },
      {
        id = "multiplayerPlayerListComponent",
        type = "component",
        componentName = "PauseMultiplayerPlayerList",
        props = {
          interactive = true,
        },
      },
    },
  }
end

return M
