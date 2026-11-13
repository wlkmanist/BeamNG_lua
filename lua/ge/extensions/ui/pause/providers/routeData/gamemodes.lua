-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {
  "ui_pause_providers_routeData_multiplayer",
}

local function getPlayerListSidePanelContents(context)
  if not context or not context.isMultiplayerActive then return nil end
  if not ui_pause_providers_routeData_multiplayer then return nil end
  return ui_pause_providers_routeData_multiplayer.getPlayerListSidePanelContents()
end

function M.getGamemodesData(context)
  return {
    mainPanelContent = {
      { id = "gamemodesComponent", type = "component", componentName = "GamemodesTab" },
    },
    sidePanelContents = getPlayerListSidePanelContents(context),
  }
end

function M.getGamemodeSetupData(context, params)
  return {
    mainCardClass = "menu-content-card-1--no-scroll",
    mainPanelContent = {
      {
        id = "gamemodeSetupComponent",
        type = "component",
        componentName = "GamemodeSetupView",
        props = {
          gamemodeName = params and params.gamemodeName or nil,
        },
      },
    },
    sidePanelContents = getPlayerListSidePanelContents(context),
  }
end

function M.getGamemodeSettingsData(context)
  return {
    mainCardClass = "menu-content-card-1--no-scroll",
    mainPanelContent = {
      { id = "gamemodeSettingsComponent", type = "component", componentName = "GamemodeSettingsView" },
    },
    sidePanelContents = getPlayerListSidePanelContents(context),
  }
end

return M
