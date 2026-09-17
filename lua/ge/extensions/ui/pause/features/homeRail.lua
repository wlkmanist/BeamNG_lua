-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}

local function pushRoute(routeName)
  if extensions and extensions.ui_router and extensions.ui_router.navigate then
    local result = extensions.ui_router.navigate(routeName)
    return result ~= false
  end
  guihooks.trigger("ChangeState", {state = routeName})
  return true
end

-- "Exit scenario" only clears scenario_scenarios' bookkeeping and leaves the
-- player exactly where they were and doesn't unload the level. For quickrace/
-- lightRunner/busRoute (one-shot wizard flows) that looks like the button's broken.
local function isWizardScenario(activeScenario)
  if not activeScenario then return false end
  -- Bus routes are started via scenario_scenariosLoader and always tag
  -- themselves with a busdriver config (see busrouteConfigurator.lua).
  if activeScenario.busdriver then return true end
  -- quickrace/lightRunner both go through scenario_quickRaceLoader, which
  -- tags every race isQuickRace = true (see quickRaceLoader.lua's
  -- loadQuickrace()).
  return activeScenario.isQuickRace == true
end

local function getCurrentPlayerVehicle()
  if not getPlayerVehicle then return nil end
  return getPlayerVehicle(0)
end

local function buildRecoveryTarget(targetType, targetVehId)
  if targetType == "none" then
    return {type = "none"}
  end
  if targetType == "walk" then
    return {type = "walk"}
  end
  if targetType == "vehicle" and targetVehId then
    return {type = "vehicle", vehId = targetVehId}
  end

  local veh = getCurrentPlayerVehicle()
  if veh then
    return {type = "vehicle", vehId = veh:getId()}
  end
  return {type = "none"}
end

local function executeRecoveryButton(buttonId, targetType, targetVehId)
  if not core_recoveryPrompt or not core_recoveryPrompt.buttonPressed or not buttonId then
    return false
  end
  core_recoveryPrompt.buttonPressed(buttonId, buildRecoveryTarget(targetType, targetVehId))
  return true
end

local function toActionLabel(value, fallback)
  if type(value) == "string" and value ~= "" then return value end
  if type(value) ~= "table" then return fallback end

  if type(value.label) == "string" and value.label ~= "" then
    return value.label
  end

  if type(value.context) == "table" and type(value.context.label) == "string" and value.context.label ~= "" then
    if value.context.count ~= nil then
      return string.format("%s (%s)", value.context.label, tostring(value.context.count))
    end
    return value.context.label
  end

  if type(value.txt) == "string" and value.txt ~= "" then
    return value.txt
  end

  return fallback
end

local function addFreeroamStyleRecoveryActions(actions, registerButton)
  table.insert(actions, registerButton({
    id = "home.repairHere",
    label = _tr("ui.radialmenu2.repairVehicle"),
    icon = "wrench",
    rail = "home",
    visible = true,
    enabled = true,
  }, function()
    local veh = getCurrentPlayerVehicle()
    if not veh or not spawn or not spawn.safeTeleport then return false end
    spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true)
    extensions.hook("onPauseMenuRightRailButtonPressed", "repairHere")
    return true
  end))
end

local function addCareerRecoveryActions(actions, registerButton)
  local dynamicButtons = core_recoveryPrompt and core_recoveryPrompt.getPauseCareerRightRailButtons and core_recoveryPrompt.getPauseCareerRightRailButtons() or {}
  for _, button in ipairs(dynamicButtons) do
    local recoveryButtonId = tostring(button.id or "unknown")
    local recoveryTargetType = button.targetType
    local recoveryTargetVehId = button.targetVehId
    table.insert(actions, registerButton({
      id = "home.career." .. recoveryButtonId,
      label = toActionLabel(button.title, recoveryButtonId),
      icon = button.icon or "recover",
      rail = "home",
      visible = true,
      enabled = button.enabled ~= false,
      disabledReason = button.disableReason,
      confirmText = button.holdToClick,
    }, function()
      return executeRecoveryButton(recoveryButtonId, recoveryTargetType, recoveryTargetVehId)
    end))
  end
end

local function addMissionRecoveryActions(actions, registerButton)
  local dynamicButtons = core_recoveryPrompt and core_recoveryPrompt.getPauseMissionRightRailButtons and core_recoveryPrompt.getPauseMissionRightRailButtons() or {}
  if #dynamicButtons > 0 then
    for _, button in ipairs(dynamicButtons) do
      local recoveryButtonId = tostring(button.id or "unknown")
      local recoveryTargetType = button.targetType
      local recoveryTargetVehId = button.targetVehId
      table.insert(actions, registerButton({
        id = "home.mission." .. recoveryButtonId,
        label = toActionLabel(button.title, recoveryButtonId),
        icon = button.icon or "recover",
        rail = "home",
        visible = true,
        enabled = button.enabled ~= false,
        disabledReason = button.disableReason,
        confirmText = button.holdToClick,
      }, function()
        return executeRecoveryButton(recoveryButtonId, recoveryTargetType, recoveryTargetVehId)
      end))
    end
    return
  end

  table.insert(actions, registerButton({
    id = "home.missionRestart",
    label = _tr("missions.missions.general.panel.restart"),
    icon = "restart",
    rail = "home",
    visible = true,
    enabled = true,
  }, function()
    return executeRecoveryButton("restartMission", "none")
  end))

  table.insert(actions, registerButton({
    id = "home.missionFlip",
    label = _tr("ui.radialmenu2.flipVehicleUpright"),
    icon = "carToWheels",
    rail = "home",
    visible = true,
    enabled = true,
  }, function()
    return executeRecoveryButton("flipMission", "vehicle")
  end))

  table.insert(actions, registerButton({
    id = "home.missionRecover",
    label = _tr("ui.radialmenu2.recoverToLastRoad"),
    icon = "car",
    rail = "home",
    visible = true,
    enabled = true,
  }, function()
    return executeRecoveryButton("recoverMission", "vehicle")
  end))

  table.insert(actions, registerButton({
    id = "home.missionTowToRoad",
    label = _tr("ui.career.towToRoad"),
    icon = "road",
    rail = "home",
    visible = true,
    enabled = true,
  }, function()
    return executeRecoveryButton("towToRoad", "vehicle")
  end))
end

local function isCareerPathsAndMilestonesAvailable()
  local tutorialActive = career_modules_tutorial and career_modules_tutorial.isActive and career_modules_tutorial.isActive()
  if tutorialActive then return false end
  return career_career and career_career.hasBoughtStarterVehicle and career_career.hasBoughtStarterVehicle()
end

local function getUnclaimedMilestonesCount()
  if not career_modules_milestones_milestones or not career_modules_milestones_milestones.unclaimedMilestonesCount then
    return 0
  end
  return career_modules_milestones_milestones.unclaimedMilestonesCount() or 0
end

local function addCareerPathsAction(actions, registerButton)
  if not isCareerPathsAndMilestonesAvailable() then return end
  local unclaimedMilestones = getUnclaimedMilestonesCount()
  table.insert(actions, registerButton({
    id = "home.careerPaths",
    label = _tr("ui.career.landingPage.name"),
    icon = "cup",
    rail = "home",
    routeTarget = "career.domainSelection",
    showIndicator = unclaimedMilestones > 0,
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("career.domainSelection")
  end))
end

local function addCareerMilestonesAction(actions, registerButton)
  if not isCareerPathsAndMilestonesAvailable() then return end
  local unclaimedMilestones = getUnclaimedMilestonesCount()
  table.insert(actions, registerButton({
    id = "home.careerMilestones",
    label = _tr("ui.career.milestones.title"),
    icon = "catalog03",
    rail = "home",
    routeTarget = "career.milestones",
    showIndicator = unclaimedMilestones > 0,
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("pause.milestones")
  end))
end

local function buildRecoveryActions(context, registerButton)
  local actions = {}

  table.insert(actions, registerButton({
    id = "home.resume",
    label = _tr("ui.common.action.resume"),
    icon = "play",
    rail = "home",
    routeTarget = "play",
    visible = true,
    enabled = true,
  }, function()
    if gameplay_missions_missionScreen and gameplay_missions_missionScreen.isMissionStartOrEndScreenActive() then
      return pushRoute("mission.control")
    end
    return pushRoute("play")
  end))

  if context.mode == "garage" then
    return actions
  end

  if context.mode == "career" then
    addCareerRecoveryActions(actions, registerButton)
    return actions
  end

  if context.mode == "mission" then
    addMissionRecoveryActions(actions, registerButton)
    return actions
  end

  if context.mode == "multiplayer" or context.mode == "freeroam" or context.mode == "freeroamTutorial" then
    addFreeroamStyleRecoveryActions(actions, registerButton)
  end

  return actions
end

local function buildTutorialLessonActions(context, registerButton)
  if context.mode ~= "freeroamTutorial" then return {} end
  if not gameplay_discover_freeroamTutorial_tutorial or not gameplay_discover_freeroamTutorial_tutorial.getActivePhase then return {} end

  local activePhase = gameplay_discover_freeroamTutorial_tutorial.getActivePhase()
  if activePhase == nil or activePhase == "" then return {} end
  if gameplay_discover_freeroamTutorial_lessonRegistry
    and gameplay_discover_freeroamTutorial_lessonRegistry.isIntroMandatoryPhase
    and gameplay_discover_freeroamTutorial_lessonRegistry.isIntroMandatoryPhase(activePhase) then
    return {}
  end

  local actions = {}
  table.insert(actions, registerButton({
    id = "home.freeroamTutorial.stopCurrentLesson",
    label = _tr("ui.experiences.freeroamTutorial.common.button.stopCurrentLesson"),
    icon = "abandon",
    rail = "home",
    routeTarget = "play",
    visible = true,
    enabled = true,
  }, function()
    gameplay_discover_freeroamTutorial_tutorial.setActivePhase("")
    local result = pushRoute("play")
    if not result then
      guihooks.trigger("ChangeState", {state = "play"})
    end
    return result
  end))

  return actions
end

local function buildAuxiliaryActions(context, registerButton)
  local actions = {}
  local vehicleSelectorAllowed = context.mode == "freeroam"
    or context.mode == "multiplayer"
    or context.mode == "garage"
    or context.mode == "freeroamTutorial"

  if vehicleSelectorAllowed then
    table.insert(actions, registerButton({
      id = "home.vehicleSelector",
      label = _tr("ui.menu.vehicleSelector.title"),
      icon = "vehicleFeatures01",
      routeTarget = "pause.vehicleSelector",
      visible = true,
      enabled = true,
    }, function()
      if ui_vehicleSelector_general and ui_vehicleSelector_general.openFromPause then
        ui_vehicleSelector_general.openFromPause()
        return true
      end
      return false
    end))
  end

  if not context.isScenarioActive then
    table.insert(actions, registerButton({
      id = "home.map",
      label = _tr("ui.dashboard.bigmap"),
      icon = "mapWithEmitter",
      visible = true,
      enabled = context.isBigMapAllowed,
      disabledReason = context.isBigMapAllowed and nil or "Disabled in current context",
      routeTarget = "pause.bigmap",
    }, function()
      --if ui_pause_camera then
      --  ui_pause_camera.endPauseSession()
      --end
      if freeroam_bigMapMode and freeroam_bigMapMode.enterBigMap then
        freeroam_bigMapMode.enterBigMap({instant = true, routeTarget = "pause.bigmap"})
        return true
      end
      return false
    end))
  end

  table.insert(actions, registerButton({
    id = "home.photomode",
    label = _tr("ui.dashboard.photomode"),
    icon = "photo",
    routeTarget = "pause.photomode",
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("pause.photomode")
  end))

  table.insert(actions, registerButton({
    id = "home.replay",
    label = _tr("ui.menu.replay"),
    icon = "movieCamera",
    routeTarget = "pause.replay",
    visible = context.mode ~= "career",
    enabled = context.mode ~= "career",
  }, function()
    return pushRoute("pause.replay")
  end))

  return actions
end

local function buildMainMenuActions(context, registerButton)
  local actions = {}

  if context.mode == "freeroam" then

    table.insert(actions, registerButton({
      id = "home.changeLevel",
      label = _tr("ui.pause.home.changeLevel"),
      icon = "terrain",
      flavor = "system",
      routeTarget = "pause.freeroamLevels",
      visible = true,
      enabled = true,
      hideInSimpleMenu = true,
    }, function()
      if ui_freeroamSelector_general and ui_freeroamSelector_general.openFromPause then
        ui_freeroamSelector_general.openFromPause()
        return true
      end
      return pushRoute("pause.freeroamselector")
    end))
  end

  local hideExitActivityForWizardScenario = context.isScenarioActive
    and scenario_scenarios
    and scenario_scenarios.getScenario
    and isWizardScenario(scenario_scenarios.getScenario())

  if (context.isMissionActive or context.isScenarioActive) and not hideExitActivityForWizardScenario then
    table.insert(actions, registerButton({
      id = "home.exitActivity",
      label = context.isMissionActive and "Exit challenge" or "Exit scenario",
      icon = "abandon",
      flavor = "danger",
      confirmText = context.isMissionActive and "Exit current challenge?" or "Exit current scenario?",
      visible = true,
      enabled = true,
    }, function()
      if context.isMissionActive
        and gameplay_missions_missionScreen
        and gameplay_missions_missionScreen.stopMissionById then
        gameplay_missions_missionScreen.stopMissionById(nil, false, true)
        return true
      end

      if context.isScenarioActive
        and campaign_campaigns
        and campaign_campaigns.getCampaignActive
        and campaign_campaigns.getCampaignActive() then
        returnToMainMenu()
        return true
      end

      if context.isScenarioActive and scenario_scenarios and scenario_scenarios.stop then
        scenario_scenarios.stop()
        return true
      end

      return pushRoute("play")
    end))
  end

  table.insert(actions, registerButton({
    id = "home.exitToMainMenu",
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

  return actions
end

local function buildCareerActions(context, registerButton)
  if context.mode ~= "career" then return {} end

  local actions = {}

  table.insert(actions, registerButton({
    id = "home.careerQuicksave",
    label = _tr("ui.career.quicksave"),
    icon = "floppyDisk",
    visible = true,
    enabled = career_career.isAutosaveEnabled(),
  }, function()
    if career_saveSystem and career_saveSystem.saveCurrent then
      career_saveSystem.saveCurrent(nil, true)
      return true
    end
    return false
  end))

  table.insert(actions, registerButton({
    id = "home.careerSaveAs",
    label = _tr("ui.common.save"),
    icon = "saveAs1",
    routeTarget = "career.profiles.saveAs",
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("career.profiles.saveAs")
  end))

  table.insert(actions, registerButton({
    id = "home.careerLoad",
    label = _tr("ui.common.load"),
    icon = "folder",
    routeTarget = "career.profiles",
    confirmText = "Are you sure you want to load a different profile? Any unsaved progress will be lost.",
    visible = true,
    enabled = true,
  }, function()
    return pushRoute("career.profiles")
  end))

  return actions
end

function M.build(context, registerButton)
  local groups = {}
  local recoveryGroup = Common.asRailGroup("recovery", buildRecoveryActions(context, registerButton))
  local tutorialLessonGroup = Common.asRailGroup("tutorialLesson", buildTutorialLessonActions(context, registerButton))
  local careerGroup = Common.asRailGroup("career", buildCareerActions(context, registerButton))
  local auxiliaryGroup = Common.asRailGroup("auxiliary", buildAuxiliaryActions(context, registerButton))
  local mainMenuGroup = Common.asRailGroup("mainMenu", buildMainMenuActions(context, registerButton))

  if recoveryGroup then table.insert(groups, recoveryGroup) end
  if tutorialLessonGroup then table.insert(groups, tutorialLessonGroup) end
  if careerGroup then table.insert(groups, careerGroup) end
  if auxiliaryGroup then table.insert(groups, auxiliaryGroup) end
  if mainMenuGroup then table.insert(groups, mainMenuGroup) end

  return groups
end

return M
