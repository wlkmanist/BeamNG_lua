-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local Common = require("ge/extensions/ui/pause/providers/routeData/common")

local M = {}
M.dependencies = {
  "ui_pause_providers_vehicleTabInteractions",
  "ui_vehicleSelector_general",
}

local function isVehicleConfigEditable(context)
  return context.mode == "freeroam" or context.mode == "multiplayer" or context.mode == "garage" or context.mode == "freeroamTutorial"
end

local function getCurrentPlayerVehicle()
  if not getPlayerVehicle then return nil end
  return getPlayerVehicle(0)
end

local function getCurrentVehicleModelDisplayName()
  local veh = getCurrentPlayerVehicle()
  if not veh or not core_vehicles or not core_vehicles.getModel then return nil end

  local vehKey = veh.JBeam
  if not vehKey and veh.getJBeamFilename then
    vehKey = veh:getJBeamFilename()
  end
  if type(vehKey) ~= "string" or vehKey == "" then return nil end

  local modelInfo = core_vehicles.getModel(vehKey)
  local model = modelInfo and modelInfo.model
  if not model then return nil end

  local brand = model.Brand
  local name = model.Name
  if type(brand) == "string" and brand ~= "" and type(name) == "string" and name ~= "" then
    return brand .. " " .. name
  end
  if type(name) == "string" and name ~= "" then return name end
  if type(brand) == "string" and brand ~= "" then return brand end
  return nil
end

local function getVehicleSaveRouteTitle()
  local baseTitle = _tr("ui.pause.route.saveConfig")
  local vehicleModelName = getCurrentVehicleModelDisplayName()
  if vehicleModelName and vehicleModelName ~= "" then
    return baseTitle .. " - " .. vehicleModelName
  end
  return baseTitle
end

local function buildVehicleButtons(actionState)
  local definitions = {
--[[     {
      id = "partpacks",
      label = "Part packs",
      icon = "puzzleModule",
      routeTarget = "pause.vehicle.packs",
      callback = function()
        return Common.tryPushStateSequence({"pause.vehicle.packs:menu-content-card-1", "menu.vehicleconfig.partpacks"})
      end,
    }, ]]
    {
      id = "configurationCombined",
      label = _tr("ui.dashboard.vehicleconfig"),
      icon = "engine",
      routeTarget = "pause.vehicle.configurationcombined",
      callback = function()
        return Common.tryPushStateSequence({"pause.vehicle.configurationcombined:pause-tab-combined-parts"})
      end,
    },
    --[[
    {
      id = "parts",
      label = "Parts management",
      icon = "wrench",
      routeTarget = "pause.vehicle.parts",
      callback = function()
        return Common.tryPushStateSequence({"pause.vehicle.parts:menu-content-card-1", "menu.vehicleconfig.parts"})
      end,
    },
    {
      id = "tuning",
      label = "Tuning",
      icon = "adjust",
      routeTarget = "pause.vehicle.tuning",
      callback = function()
        return Common.tryPushStateSequence({"pause.vehicle.tuning:menu-content-card-1", "menu.vehicleconfig.tuning"})
      end,
    },
    {
      id = "colorSkin",
      label = "Appearance",
      icon = "sprayCan",
      routeTarget = "pause.vehicle.paint",
      callback = function()
        return Common.tryPushStateSequence({"pause.vehicle.paint:pause-skin-paint-tab", "menu.vehicleconfig.color"})
      end,
    },
    ]]
    --[[
    {
      id = "seatAdjust",
      label = "Seat adjustment",
      icon = "seat",
      callback = function()
        return false
      end,
    },
    ]]
  }

  local buttons = {}
  for _, definition in ipairs(definitions) do
    local permission = actionState[definition.id] or {}
    local registered = Common.registerPauseButton({
      id = definition.id,
      label = definition.label,
      icon = definition.icon,
      routeTarget = definition.routeTarget,
      hideInSimpleMenu = definition.hideInSimpleMenu,
      focusSidePanelId = definition.focusSidePanelId,
      columnSpan = definition.columnSpan,
      rowSpan = definition.rowSpan,
      visible = permission.visible ~= false,
      enabled = permission.enabled ~= false,
      disabledReason = permission.disabledReason,
      callback = definition.callback,
    })
    if registered and registered.visible ~= false then
      table.insert(buttons, registered)
    end
  end
  return buttons
end

local function buildVehicleRecoveryButtons(actionState)
  local definitions = {
    {
      id = "vehicleRepairHere",
      label = _tr("ui.radialmenu2.repairVehicle"),
      icon = "wrench",
      callback = function()
        local veh = getCurrentPlayerVehicle()
        if not veh or not spawn or not spawn.safeTeleport then return false end
        spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, true)
        extensions.hook("onPauseMenuRightRailButtonPressed", "repairHere")
        return true
      end,
    },
    {
      id = "vehicleRecoverToRoad",
      label = _tr("ui.radialmenu2.recoverToLastRoad"),
      icon = "road",
      callback = function()
        local veh = getCurrentPlayerVehicle()
        if not veh or not spawn or not spawn.teleportToLastRoad then return false end
        spawn.teleportToLastRoad(veh, {resetVehicle = false})
        extensions.hook("onPauseMenuRightRailButtonPressed", "recoverToRoad")
        return true
      end,
    },
    {
      id = "vehicleFlipUpright",
      label = _tr("ui.radialmenu2.flipVehicleUpright"),
      icon = "carToWheels",
      callback = function()
        local veh = getCurrentPlayerVehicle()
        if not veh or not spawn or not spawn.safeTeleport then return false end
        spawn.safeTeleport(veh, veh:getPosition(), quatFromDir(veh:getDirectionVector()), nil, nil, nil, nil, false)
        extensions.hook("onPauseMenuRightRailButtonPressed", "flipUpright")
        return true
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
      hideInSimpleMenu = definition.hideInSimpleMenu,
      focusSidePanelId = definition.focusSidePanelId,
      columnSpan = definition.columnSpan,
      rowSpan = definition.rowSpan,
      visible = permission.visible ~= false,
      enabled = permission.enabled ~= false,
      disabledReason = permission.disabledReason,
      callback = definition.callback,
    })
    if registered and registered.visible ~= false then
      table.insert(buttons, registered)
    end
  end

  return buttons
end

local function buildVehicleSelectorButtons(actionState)
  local definitions = {
    {
      id = "vehicleSelector",
      label = _tr("ui.menu.vehicleSelector.title"),
      icon = "vehicleFeatures01",
      routeTarget = "pause.vehicle.vehicleSelector",
      callback = function()
        if ui_vehicleSelector_general and ui_vehicleSelector_general.openFromPause then
          ui_vehicleSelector_general.openFromPause("pause.vehicle.vehicleSelector")
          return true
        end
        return false
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
      hideInSimpleMenu = definition.hideInSimpleMenu,
      focusSidePanelId = definition.focusSidePanelId,
      columnSpan = definition.columnSpan,
      rowSpan = definition.rowSpan,
      visible = permission.visible ~= false,
      enabled = permission.enabled ~= false,
      disabledReason = permission.disabledReason,
      callback = definition.callback,
    })
    if registered and registered.visible ~= false then
      table.insert(buttons, registered)
    end
  end

  return buttons
end

local function buildVehicleRail(actionState)
  local groups = {}
  local vehicleButtons = Common.asRailGroup("vehicleButtons", buildVehicleButtons(actionState))
  local vehicleRecoveryButtons = Common.asRailGroup("vehicleRecoveryButtons", buildVehicleRecoveryButtons(actionState))
  local vehicleSelectorButtons = Common.asRailGroup("vehicleSelectorButtons", buildVehicleSelectorButtons(actionState))
  if vehicleButtons then table.insert(groups, vehicleButtons) end
  if vehicleRecoveryButtons then table.insert(groups, vehicleRecoveryButtons) end
  if vehicleSelectorButtons then table.insert(groups, vehicleSelectorButtons) end
  return groups
end

local function buildManageSpawnedSidePanel(context, useAsyncHydrationShell)
  local summaryData
  if useAsyncHydrationShell then
    local shellData = ui_pause_providers_vehicleTabInteractions.getSpawnedVehiclesShellData(context)
    summaryData = {
      summary = shellData.summary,
      vehicles = shellData.vehicles,
    }
  else
    summaryData = ui_pause_providers_vehicleTabInteractions.getSpawnedVehiclesSummaryData(context)
  end
  return {
    {
      id = "spawnedVehiclesSummaryTitle",
      type = "title",
      text = _tr("ui.pause.vehicle.manageSpawnedVehicles"),
    },
    {
      id = "spawnedVehiclesSummaryComponent",
      type = "component",
      componentName = "PauseVehicleSpawnedSummary",
      props = summaryData,
    },
  }
end

function M.getVehicleData(context)
  local editable = isVehicleConfigEditable(context)
  local disabledReason = editable and nil or _tr("ui.pause.readOnlyInThisMode")
  local recoveryAllowed = context.mode == "freeroam" or context.mode == "multiplayer" or context.mode == "freeroamTutorial"
  local vehicleSelectorAllowed = context.mode == "freeroam"
    or context.mode == "multiplayer"
    or context.mode == "garage"
    or context.mode == "freeroamTutorial"
  local actionState = {
    visible = true,
    enabled = editable,
    disabledReason = disabledReason,
  }
  local actions = {
    partpacks = deepcopy(actionState),
    configurationCombined = deepcopy(actionState),
    parts = deepcopy(actionState),
    tuning = deepcopy(actionState),
    colorSkin = deepcopy(actionState),
    saveConfig = deepcopy(actionState),
    seatAdjust = {
      visible = true,
      enabled = false,
      disabledReason = _tr("ui.pause.notImplementedYet"),
    },
    vehicleRepairHere = {
      visible = recoveryAllowed,
      enabled = recoveryAllowed,
    },
    vehicleRecoverToRoad = {
      visible = recoveryAllowed,
      enabled = recoveryAllowed,
    },
    vehicleFlipUpright = {
      visible = recoveryAllowed,
      enabled = recoveryAllowed,
    },
    vehicleSelector = {
      visible = vehicleSelectorAllowed,
      enabled = vehicleSelectorAllowed,
    },
    debug = deepcopy(actionState),
  }

  return {
    editable = editable,
    rail = buildVehicleRail(actions),
    mainCardClass = "menu-content-card-1--vehicle-spawned",
    mainPanelContent = {
      {
        id = "vehicleInteractionsComponent",
        type = "component",
        componentName = "PauseVehicleSpawned",
      },
    },
    spawnedVehicles = {
      mode = context.mode,
    },
    sidePanelContents = {
      {
        {
          id = "vehicleSummaryTitle",
          type = "title",
          text = _tr("ui.pause.vehicle"),
        },
        {
          id = "vehicleComponent",
          type = "component",
          componentName = "PauseVehicleTab",
        },
      },
    },
    actions = actions,
  }
end

function M.getVehiclePacksData()
  return {
    mainPanelContent = {
      {
        id = "vehiclePacksComponent",
        type = "component",
        componentName = "PauseVehiclePacks",
      },
    },
  }
end

function M.getVehiclePartsData()
  return {
    mainPanelContent = {
      {
        id = "vehiclePartsComponent",
        type = "component",
        componentName = "PauseVehicleParts",
      },
    },
  }
end

function M.getVehicleConfigurationCombinedData()
  return {
    heading = _tr("ui.dashboard.vehicleconfig"),
    mainCardClass = "menu-content-card-1--wide",
    mainPanelContent = {
      {
        id = "vehicleConfigurationCombinedComponent",
        type = "component",
        componentName = "PauseVehicleConfigurationCombined",
      },
    },
  }
end

function M.getVehicleTuningData()
  return {
    mainPanelContent = {
      {
        id = "vehicleTuningComponent",
        type = "component",
        componentName = "PauseVehicleTuning",
      },
    },
  }
end

function M.getVehiclePaintData()
  return {
    mainPanelContent = {
      {
        id = "vehiclePaintComponent",
        type = "component",
        componentName = "PauseVehicleSkin",
      },
    },
  }
end

function M.getVehicleSaveData()
  return {
    heading = getVehicleSaveRouteTitle(),
  }
end

function M.getVehicleSaveRouteTitle()
  return getVehicleSaveRouteTitle()
end

function M.getVehicleConfigListManageData()
  return {
    mainCardClass = "menu-content-card-1--wide",
    mainPanelContent = {
      {
        id = "vehicleConfigListManageComponent",
        type = "component",
        componentName = "PauseVehicleConfigListManage",
      },
    },
  }
end

function M.getVehicleSpawnedData(context)
  -- PoC async hydration: keep the route mount payload light, then let the Vue screen request
  -- the full spawned vehicle payload after mount. This is intentionally scoped to spawned list.
  return {
    mainPanelContent = {
      {
        id = "vehicleSpawnedComponent",
        type = "component",
        componentName = "PauseVehicleSpawned",
      },
    },
    spawnedVehicles = ui_pause_providers_vehicleTabInteractions.getSpawnedVehiclesShellData(context),
  }
end

function M.getVehicleDebugData()
  return {
    mainCardClass = "menu-content-card-1--no-scroll",
    mainPanelContent = {
      {
        id = "vehicleDebugComponent",
        type = "component",
        componentName = "PauseVehicleDebug",
      },
    },
  }
end

return M
