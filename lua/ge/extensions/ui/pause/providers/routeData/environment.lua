-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}
M.dependencies = {
  "ui_pause_providers_trafficControls",
}

local function isEnvironmentEditable(context)
  return context.mode == "freeroam" or context.mode == "multiplayer" or context.mode == "freeroamTutorial"
end

local function getCurrentLevelText()
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier() or nil
  if not levelId then return _tr("ui.pause.environment.noLevelLoaded") end

  local title = core_levels and core_levels.getLevelTitle and core_levels.getLevelTitle(levelId) or nil
  return _tr(title or levelId)
end

local function buildEnvironmentButtons(actionState)
  local definitions = {
    {
      id = "weather",
      label = _tr("ui.pause.environment.timeWeatherMore"),
      icon = "weather",
      routeTarget = "pause.environment.weather",
      callback = function()
        return Common.tryPushStateSequence({"pause.environment.weather:menu-content-card-1", "menu.environment.weather"})
      end,
    },
    {
      id = "traffic",
      label = _tr("ui.pause.environment.traffic"),
      icon = "trafficLight",
      routeTarget = "pause.environment.traffic",
      callback = function()
        return Common.tryPushStateSequence({"pause.environment.traffic:menu-content-card-1", "menu.environment.traffic"})
      end,
    },
    {
      id = "simulation",
      label = _tr("ui.pause.environment.simulationMore"),
      icon = "beamNG",
      routeTarget = "pause.environment.simulation",
      callback = function()
        return Common.tryPushStateSequence({"pause.environment.simulation:menu-content-card-1", "menu.environment.simulation"})
      end,
    },
  }

  local buttons = {}
  for _, definition in ipairs(definitions) do
    local permission = actionState[definition.id] or {}
    local registered = Common.registerPauseButton({
      id = definition.id,
      label = definition.label,
      icon = definition.icon,
      routeTarget = definition.routeTarget,
      visible = permission.visible ~= false,
      enabled = permission.enabled ~= false,
      disabledReason = permission.disabledReason,
      callback = definition.callback,
    })
    if registered and registered.visible ~= false then
      buttons[definition.id] = registered
    end
  end
  return buttons
end

function M.getEnvironmentData(context)
  local editable = isEnvironmentEditable(context)
  local disabledReason = editable and nil or _tr("ui.pause.readOnlyInThisMode")
  local timeOfDayOptions = core_environment and core_environment.getTimeOfDayOptions and core_environment.getTimeOfDayOptions() or {}
  local levelDefaults = core_environment and core_environment.getInitState and core_environment.getInitState() or {}
  local actionState = {
    visible = true,
    enabled = editable,
    disabledReason = disabledReason,
  }
  local actions = {
    weather = deepcopy(actionState),
    simulation = deepcopy(actionState),
    traffic = deepcopy(actionState),
  }
  local buttons = buildEnvironmentButtons(actions)

  local otherButtonsCandidates, otherButtons = {}, {}
  extensions.hook("onEnvironmentGetOtherButtons", otherButtonsCandidates, actionState)

  for _, button in ipairs(otherButtonsCandidates) do
    if not button.id then log("E","", "onEnvironmentGetOtherButtons: button id is required") goto continue end
    if not button.label then log("E","", "onEnvironmentGetOtherButtons: button label is required") goto continue end
    if not button.callback then log("E","", "onEnvironmentGetOtherButtons: button callback is required") goto continue end

    local registered = Common.registerPauseButton({
      id = button.id,
      label = button.label,
      icon = button.icon,
      routeTarget = button.routeTarget,
      callback = button.callback,
    })
    if registered and registered.visible ~= false then
      table.insert(otherButtons, registered)
    end

    ::continue::
  end
  table.insert(otherButtons, buttons.simulation)
  table.sort(otherButtons, function(a, b) return a.label < b.label end)


  return {
    editable = editable,
    mainPanelContent = {
      {
        id = "environmentDigestComponent",
        type = "component",
        componentName = "PauseEnvironmentDigest",
        props = {
          editable = editable,
          weatherButton = buttons.weather,
          trafficButton = buttons.traffic,
          otherButtons = otherButtons,
        },
      },
    },
    actions = actions,
    timeOfDayOptions = timeOfDayOptions,
    levelDefaults = levelDefaults,
    currentLevelName = getCurrentLevelText(),
  }
end

function M.getEnvironmentWeatherData(context)
  local editable = isEnvironmentEditable(context)
  local timeOfDayOptions = core_environment.getTimeOfDayOptions()
  local levelDefaults = core_environment.getInitState()

  return {
    editable = editable,
    disabledReason = editable and nil or _tr("ui.pause.readOnlyInThisMode"),
    mainCardClass = "menu-content-card-1--wide",
    mainPanelContent = {
      {
        id = "environmentWeatherComponent",
        type = "component",
        componentName = "PauseEnvironmentWeather",
      },
    },
    gravityPresets = core_environment and core_environment.gravityPresets or {},
    simSpeedPresets = core_environment and core_environment.simSpeedPresets or {},
    timeOfDayOptions = timeOfDayOptions,
    levelDefaults = levelDefaults,
  }
end

function M.getEnvironmentSimulationData(context)
  local editable = isEnvironmentEditable(context)

  return {
    editable = editable,
    disabledReason = editable and nil or _tr("ui.pause.readOnlyInThisMode"),
    mainPanelContent = {
      {
        id = "environmentSimulationComponent",
        type = "component",
        componentName = "PauseEnvironmentSimulation",
      },
    },
  }
end

function M.getEnvironmentTrafficData(context)
  local editable = isEnvironmentEditable(context)

  return {
    editable = editable,
    disabledReason = editable and nil or _tr("ui.pause.readOnlyInThisMode"),
    traffic = ui_pause_providers_trafficControls.getData({editable = editable}),
    mainPanelContent = {
      {
        id = "environmentTrafficComponent",
        type = "component",
        componentName = "PauseEnvironmentTraffic",
      },
    },
  }
end

function M.requestEnvironmentTrafficPayload(payload)
  return ui_pause_providers_trafficControls.getData(payload)
end

return M
