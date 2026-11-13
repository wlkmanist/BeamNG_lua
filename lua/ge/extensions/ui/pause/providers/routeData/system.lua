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
      label = _tr("ui.pause.system.disconnect"),
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

local function addModsButton(buttons, context)
  local enabled = not context.isFirstDriveActive
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.mods",
    label = _tr("ui.dashboard.mods"),
    icon = "puzzleModule",
    flavor = "system",
    routeTarget = "pause.mods.local",
    visible = true,
    enabled = enabled,
    disabledReason = enabled and nil or _tr("ui.experiences.firstDrive.pause.disabledDuringTutorial"),
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
    icon = "chartBars",
    flavor = "system",
    routeTarget = "pause.stats",
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("pause.stats")
  end))
end

local function isSplitScreenActive()
  return render_splitScreen ~= nil and render_splitScreen.getCurrentConfiguration()
end

local function addHudButton(buttons, context)
  if isSplitScreenActive() then return end
  local enabled = not context.isFirstDriveActive

  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.hudApps",
    label = _tr("ui.dashboard.appedit"),
    icon = "HUD",
    flavor = "system",
    routeTarget = "pause.hudApps",
    visible = true,
    enabled = enabled,
    disabledReason = enabled and nil or _tr("ui.experiences.firstDrive.pause.disabledDuringTutorial"),
    hideInSimpleMenu = false,
  }, function()
    return pushRoute("pause.hudApps")
  end))
end

local function addExitToMainMenuButton(buttons, context)
  table.insert(buttons, ui_pause_actions.registerButton(Common.withExitConfirm({
    id = "system.exitToMainMenu",
    label = _tr("ui.pause.system.exitLevel"),
    icon = "catalog02",
    flavor = "danger",
    visible = true,
    enabled = true,
  }, context, Common.ExitLevelTexts), function(payload)
    Common.runExit(returnToMainMenu, payload)
    return true
  end))
end

local function addExitGameButton(buttons, context)
  table.insert(buttons, ui_pause_actions.registerButton(Common.withExitConfirm({
    id = "system.exitGame",
    label = _tr("ui.pause.system.exitGame"),
    icon = "exit",
    flavor = "danger",
    visible = true,
    enabled = true,
    hideInSimpleMenu = true,
  }, context, Common.ExitGameTexts), function(payload)
    if quit then
      Common.runExit(quit, payload)
      return true
    end
    return false
  end))
end

local function buildTopSystemButtons(context)
  local buttons = {}
  addSettingsButton(buttons)
  addModsButton(buttons, context)
  addHudButton(buttons, context)
  addStatsButton(buttons)
  return buttons
end

local function buildFirstDriveButtons(context)
  local experience = gameplay_discover_firstDrive_experience
  if not context.isFirstDriveActive
    or not experience or not experience.isActive or not experience.isActive() then
    return {}
  end

  local buttons = {}
  if not context.isFirstDriveGuided then
    table.insert(buttons, ui_pause_actions.registerButton({
      id = "system.firstDrive.restart",
      label = _tr("ui.experiences.firstDrive.pause.restart"),
      icon = "restart",
      flavor = "system",
      visible = true,
      enabled = true,
    }, function()
      experience.start()
      return true
    end))
    table.insert(buttons, ui_pause_actions.registerButton({
      id = "system.firstDrive.resetProgress",
      label = _tr("ui.experiences.firstDrive.pause.resetProgress"),
      icon = "restart",
      flavor = "danger",
      confirmText = _tr("ui.experiences.firstDrive.pause.confirmResetProgress"),
      visible = true,
      enabled = true,
    }, function()
      if gameplay_discover_firstDrive_learningProgress then
        gameplay_discover_firstDrive_learningProgress.reset()
      end
      experience.start()
      return true
    end))
  end
  table.insert(buttons, ui_pause_actions.registerButton({
    id = "system.firstDrive.freeroam",
    label = _tr("ui.experiences.firstDrive.pause.freeroam"),
    icon = "road",
    flavor = "danger",
    confirmText = _tr("ui.experiences.firstDrive.pause.confirmFreeroam"),
    visible = true,
    enabled = true,
  }, function()
    experience.onFirstDrivePauseFreeroam()
    return true
  end))
  return buttons
end

local function buildExitSystemButtons(context)
  local buttons = {}
  addDisconnectButton(buttons, context)
  addExitToMainMenuButton(buttons, context)
  addExitGameButton(buttons, context)
  return buttons
end

local function buildSystemRail(context)
  local groups = {}
  local topSystemButtons = Common.asRailGroup("topSystemButtons", buildTopSystemButtons(context))
  local firstDriveButtons = Common.asRailGroup("firstDriveButtons", buildFirstDriveButtons(context))
  local exitSystemButtons = Common.asRailGroup("exitSystemButtons", buildExitSystemButtons(context))
  if topSystemButtons then table.insert(groups, topSystemButtons) end
  if firstDriveButtons then table.insert(groups, firstDriveButtons) end
  if exitSystemButtons then table.insert(groups, exitSystemButtons) end
  return groups
end

function M.getSystemData(context)
  return {
    heading = _tr("ui.pause.system"),
    sidePanelContents = nil,
    rail = buildSystemRail(context),
  }
end

return M
