-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}

local function isMultiplayerActionsEditable(context)
  return not context or context.mode ~= "freeroamTutorial"
end

function M.getMultiplayerData(context)
  local isActive = context.isMultiplayerActive == true
  local editable = isMultiplayerActionsEditable(context)
  local disabledReason = editable and nil or "Read-only in this mode"

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
              label = _tr("ui.multiplayer.gamemode"),
              icon = "play",
              routeTarget = "pause.multiplayer.gamemode",
              enabled = editable and isActive,
              disabledReason = disabledReason,
              callback = function()
                return Common.tryPushStateSequence("pause.multiplayer.gamemode")
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
    sidePanelContents = isActive and {
      {
        {
          id = "multiplayerPlayerListTitle",
          type = "title",
          text = "Players",
        },
        {
          id = "multiplayerPlayerListComponent",
          type = "component",
          componentName = "PauseMultiplayerPlayerList",
        },
      },
    } or {
      {
        {
          id = "multiplayerPlayerListTitle",
          type = "title",
          text = "Not connected to a multiplayer session",
        },
      }
    },
  }
end

function M.getMultiplayerSettingsData(context)
  local isActive = context.isMultiplayerActive == true
  return {
    mainPanelContent = {
      {
        id = "multiplayerSettingsComponent",
        type = "component",
        componentName = "PauseMultiplayerSessionTab",
      },
    },
    sidePanelContents = isActive and {
      {
        {
          id = "multiplayerPlayerListTitle",
          type = "title",
          text = "Players",
        },
        {
          id = "multiplayerPlayerListComponent",
          type = "component",
          componentName = "PauseMultiplayerPlayerList",
        },
      },
    } or {
      {
        {
          id = "multiplayerPlayerListTitle",
          type = "title",
          text = "Not connected to a multiplayer session",
        },
      }
    },
  }
end

function M.getMultiplayerGamemodeData()
  return {
    mainPanelContent = {
      {
        id = "multiplayerGamemodeComponent",
        type = "component",
        componentName = "PauseMultiplayerGamemodesTab",
      },
    },
    sidePanelContents = {
      {
        {
          id = "multiplayerGamemodePlayerListTitle",
          type = "title",
          text = "Players",
        },
        {
          id = "multiplayerGamemodePlayerListComponent",
          type = "component",
          componentName = "PauseMultiplayerPlayerList",
        },
      },
    },
  }
end

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
