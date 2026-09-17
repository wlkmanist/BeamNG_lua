-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}

M.dependencies = {
  "ui_pause_actions",
}

local function pushRoute(routeName)
  if extensions and extensions.ui_router and extensions.ui_router.navigate then
    local result = extensions.ui_router.navigate(routeName)
    return result ~= false
  end
  return true
end

local function addDisconnectButton(buttons, context)
  if context.isMultiplayerActive then
    table.insert(buttons, ui_pause_actions.registerButton({
      id = "system.disconnect",
      label = "Disconnect",
      icon = "exit",
      flavor = "system",
      visible = true,
      enabled = true,
    }, function()
      if multiplayer_sessionManager and multiplayer_sessionManager.leaveCurrentSession then
        multiplayer_sessionManager.leaveCurrentSession()
        return true
      end
      return false
    end))
  end
end

local function addModsButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.mods",
    label = _tr("ui.dashboard.mods"),
    icon = "puzzleModule",
    flavor = "system",
    routeTarget = "pause.mods.local",
    visible = true,
    enabled = true,
    hideInSimpleMenu = true,
  }, function()
    return pushRoute("pause.mods.local")
  end))
end

local function addSettingsButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.settings",
    label = _tr("ui.dashboard.options"),
    icon = "adjust",
    flavor = "system",
    routeTarget = "pause.options",
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("pause.options")
  end))
end

local function addStatsButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.stats",
    label = _tr("ui.statspage.title"),
    icon = "stats",
    flavor = "system",
    visible = true,
    enabled = false,
    disabledReason = "Not available yet",
  }, function()
    return false
  end))
end

local function addHudButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.hudApps",
    label = _tr("ui.dashboard.appedit"),
    icon = "HUD",
    flavor = "system",
    routeTarget = "pause.hudApps",
    visible = true,
    enabled = true,
    hideInSimpleMenu = false,
  }, function()
    return pushRoute("pause.hudApps")
  end))
end

local function addExitToMainMenuButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.exitToMainMenu",
    label = _tr("ui.pause.system.exitLevel"),
    icon = "catalog02",
    flavor = "danger",
    confirmText = "Exit to main menu?",
    visible = true,
    enabled = true,
  }, function()
    returnToMainMenu()
    return true
  end))
end

local function addExitGameButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.exitGame",
    label = _tr("ui.pause.system.exitGame"),
    icon = "exit",
    flavor = "danger",
    confirmText = "Exit game?",
    visible = true,
    enabled = true,
    hideInSimpleMenu = true,
  }, function()
    if quit then
      quit()
      return true
    end
    return false
  end))
end

local function addOldPauseMenuButton(buttons)
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.mainmenu",
    label = "Old Pause Menu",
    icon = "catalog02",
    flavor = "system",
    routeTarget = "menu",
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("menu")
  end))
end

local function buildTopSystemButtons()
  local buttons = {}
  addSettingsButton(buttons)
  addModsButton(buttons)
  addHudButton(buttons)
  return buttons
end

local function buildExitSystemButtons(context)
  local buttons = {}
  addDisconnectButton(buttons, context)
  addExitToMainMenuButton(buttons)
  addExitGameButton(buttons)
  return buttons
end

local function getCurrentLevelText()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not levelId then return "No level loaded" end

  local title = core_levels and core_levels.getLevelTitle and core_levels.getLevelTitle(levelId) or nil
  return title or levelId
end

local function getEnabledModsText()
  if not core_modmanager or not core_modmanager.isReady or not core_modmanager.isReady() then
    return "Mod manager not ready"
  end

  local stats = core_modmanager.getStats and core_modmanager.getStats() or {}
  local enabledCount = (stats.zip or 0) + (stats.unpacked or 0)
  return tostring(enabledCount)
end

local function buildSystemSidePanel()
  return {
    {
      {
        id = "systemCurrentLevel",
        type = "component",
        componentName = "PausePanelSimpleText",
        props = {
          title = "Current level",
          text = getCurrentLevelText(),
        },
      },
      {
        id = "systemEnabledMods",
        type = "component",
        componentName = "PausePanelSimpleText",
        hideInSimpleMenu = true,
        props = {
          title = _tr("ui.career.mods"),
          text = getEnabledModsText(),
        },
      },
    },
  }
end

local function buildSystemRail(context)
  local groups = {}
  local topSystemButtons = Common.asRailGroup("topSystemButtons", buildTopSystemButtons())
  local exitSystemButtons = Common.asRailGroup("exitSystemButtons", buildExitSystemButtons(context))
  if topSystemButtons then table.insert(groups, topSystemButtons) end
  if exitSystemButtons then table.insert(groups, exitSystemButtons) end
  return groups
end

function M.getSystemData(context)
  return {
    heading = _tr("ui.pause.system"),
    sidePanelContents = buildSystemSidePanel(),
    rail = buildSystemRail(context),
  }
end

return M
