-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}
M.dependencies = {
  "career_career",
  "career_saveSystem",
  "ui_pause_providers_nearbyActivities",
  "ui_pause_providers_missionObjectives",
  "ui_pause_providers_routeData_multiplayer",
  "ui_pause_providers_vehicleTabInteractions",
  "ui_pause_features_homeRail",
  "ui_vehicleSelector_general",
}

local function registerCareerButtons(definitions)
  local buttons = {}
  for _, definition in ipairs(definitions) do
    local registered = Common.registerPauseButton({
      id = definition.id,
      label = definition.label,
      icon = definition.icon,
      routeTarget = definition.routeTarget,
      showIndicator = definition.showIndicator,
      confirmText = definition.confirmText,
      visible = true,
      enabled = true,
      callback = definition.callback,
    })
    if registered and registered.visible ~= false then
      table.insert(buttons, registered)
    end
  end

  return buttons
end

local function buildCareerButtons()
  local definitions = {}

  if career_modules_delivery_general and career_modules_delivery_general.isDeliveryModeActive and career_modules_delivery_general.isDeliveryModeActive() then
    table.insert(definitions, {
      id = "careerCargoMap",
      label = "Map (My Cargo)",
      icon = "map",
      callback = function()
        if career_modules_delivery_cargoScreen and career_modules_delivery_cargoScreen.enterMyCargo then
          career_modules_delivery_cargoScreen.enterMyCargo()
          return true
        end
        return false
      end,
    })
  end

  if career_modules_vehiclePerformance and career_modules_vehiclePerformance.isTestInProgress and career_modules_vehiclePerformance.isTestInProgress() then
    table.insert(definitions, {
      id = "cancelCertification",
      label = _tr("ui.career.vehiclePerformance.cancelTest"),
      icon = "abandon",
      showIndicator = true,
      callback = function()
        career_modules_vehiclePerformance.cancelTest()
        return true
      end,
    })
  end

  if career_modules_testDrive and career_modules_testDrive.isActive and career_modules_testDrive.isActive() then
    table.insert(definitions, {
      id = "cancelTestDrive",
      label = _tr("ui.career.vehiclePerformance.cancelTest"),
      icon = "abandon",
      showIndicator = true,
      callback = function()
        career_modules_testDrive.stop()
        return true
      end,
    })
  end

  return registerCareerButtons(definitions)
end

function M.getHomeData(context)
  local mainPanelContent = {}
  local sidePanelContents = nil

  local function addMainPanelElement(element)
    if not element then return end
    table.insert(mainPanelContent, element)
  end

  local function addMainPanelElements(elements)
    if type(elements) ~= "table" then return end
    for _, element in ipairs(elements) do
      addMainPanelElement(element)
    end
  end

  if context.mode == "career" then
    local careerButtons = buildCareerButtons()
    if #careerButtons > 0 then
      addMainPanelElement({
        id = "careerButtons",
        type = "component",
        componentName = "PausePanelButtons",
        props = {
          buttons = careerButtons,
        },
      })
    end
    sidePanelContents = {
      {
        {
          id = "careerProfileOverview",
          type = "component",
          componentName = "PauseCareerProfileOverview",
        },
      },
    }
  elseif context.mode == "mission" then
    addMainPanelElement( {
      id = "tasklist",
      type = "component",
      componentName = "TaskList",
      props = { },
    })
    sidePanelContents = {
      {
        {
          id = "missionObjectivesPanel",
          type = "component",
          componentName = "PauseMissionObjectives",
        },
      },
    }
  elseif context.mode == "multiplayer" then
    return ui_pause_providers_routeData_multiplayer.getMultiplayerData(context)
  elseif context.mode == "freeroamTutorial" and gameplay_discover_freeroamTutorial_pauseDataProvider then
    addMainPanelElements(gameplay_discover_freeroamTutorial_pauseDataProvider.getMainPanelContent(context))
  end
  if context.mode ~= "scenario" then
    addMainPanelElement({
      id = "nearbyVehiclesComponent",
      type = "component",
      componentName = "PauseNearbyVehicles",
    })
    if context.mode ~= "freeroamTutorial" then
      addMainPanelElement({
        id = "nearbyActivitiesComponent",
        type = "component",
        componentName = "PauseNearbyActivitiesTab",
      })
    end
  end

  if context.isCareerActive and career_modules_delivery_general and career_modules_delivery_general.isDeliveryModeActive and Common.bool(career_modules_delivery_general.isDeliveryModeActive()) then
  end

  local missionObjectives = nil
  if context.mode == "mission" then
    missionObjectives = ui_pause_providers_missionObjectives.getData(context)
  end

  local nearbyActivities = nil
  if context.mode ~= "freeroamTutorial" and context.mode ~= "mission" then
    nearbyActivities = ui_pause_providers_nearbyActivities.getData(context)
  end

  return {
    mode = context.mode,
    panels = panels,
    mainPanelContent = mainPanelContent,
    sidePanelContents = sidePanelContents,
    mainCardClass = "menu-content-card-1--vehicle-spawned",
    rail = ui_pause_features_homeRail.build(context, ui_pause_actions.registerButton),
    nearbyActivities = nearbyActivities,
    missionObjectives = missionObjectives,
  }
end

function M.getHomeVehicleDetailsData(context)
  local selectedData = ui_pause_providers_vehicleTabInteractions.getSpawnedSelectedVehicleShellData(context)
  return {
    heading = selectedData.label,
    mainPanelContent = {
      {
        id = "homeVehicleDetailsComponent",
        type = "component",
        componentName = "PauseVehicleSpawnedSelected",
      },
    },
    spawnedVehicleSelected = selectedData,
  }
end

return M
