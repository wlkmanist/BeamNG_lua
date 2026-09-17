local M = {}

local fadeScreenDuration = 0.33


-- Load button module
local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")

-- Create button management instance
local buttonInstance = buttonModule.create()

M.managementButtonsEnabled = true

-- Fade screen callback
local callbackAfterFade

-- Execute button callback by ID with additional logic
local function executeButton(buttonId, additionalData)
  local buttonInfo = buttonInstance.getButtonInfo(buttonId)
  if buttonInfo then
    local data = buttonInstance.executeButton(buttonId, additionalData)
    if buttonInfo.meta.canClearFilters and ui_vehicleSelector_general.getDisplayData().filterResetOnSpawn then
      ui_vehicleSelector_general.clearAllFilters()
    end
    return data
  else
    log("E", "", "Button function not found for ID: " .. tostring(buttonId))
  end
end

-- Handle fade screen state changes
local function onScreenFadeState(state)
  if callbackAfterFade and state == 1 then
    callbackAfterFade()
    callbackAfterFade = nil
  end
end

local function onUiWaitingState(state)
  if callbackAfterFade then
    callbackAfterFade()
    callbackAfterFade = nil
  end
end
M.onUiWaitingState = onUiWaitingState

-- Spawn vehicle after fade screen
local function spawnVehicleAfterFade(modelKey, configKey, additionalData)
  --ui_fadeScreen.start(fadeScreenDuration)
  extensions.hook("onVehicleSelectorSpawnNewRequested")
  guihooks.trigger("app:waiting", true)
  callbackAfterFade = function()
    -- Create spawn options similar to spawnVehicle.lua
    local options = {
      config = configKey,
    }
    local paintName1, paintName2, paintName3 = nil, nil, nil
    if additionalData then
      local model = core_vehicles.getModel(modelKey)
      if model then
        options.paint = model.model.paints[additionalData.paint]
        options.paint2 = model.model.paints[additionalData.paint2]
        options.paint3 = model.model.paints[additionalData.paint3]
        paintName1 = additionalData.paint
        paintName2 = additionalData.paint2
        paintName3 = additionalData.paint3
      end
    end

    -- Sanitize and spawn the vehicle
    local sanitizedOptions = sanitizeVehicleSpawnOptions(modelKey, options)
    local vehicle = core_vehicles.spawnNewVehicle(modelKey, sanitizedOptions)
    extensions.hook("onVehicleSelectorSpawnNew", modelKey, configKey, paintName1, paintName2, paintName3)

    if vehicle then
      log("I", "", "Vehicle spawned: " .. tostring(modelKey) .. " (ID: " .. tostring(vehicle:getId()) .. ")")
      ui_vehicleSelector_general.setSpawnOnly(false)
      --ui_fadeScreen.stop(fadeScreenDuration)
      guihooks.trigger("app:waiting", false)
    else
      log("E", "", "Failed to spawn vehicle: " .. tostring(modelKey))
      --ui_fadeScreen.stop(fadeScreenDuration)
      guihooks.trigger("app:waiting", false)
    end
  end
end

-- Replace vehicle after fade screen
local function replaceVehicleAfterFade(modelKey, configKey, additionalData)
  --ui_fadeScreen.start(fadeScreenDuration)
  guihooks.trigger("app:waiting", true)
  callbackAfterFade = function()
    -- Create spawn options for replacement
    local options = {
      config = configKey,
    }
    local paintName1, paintName2, paintName3 = nil, nil, nil
    if additionalData then
      local model = core_vehicles.getModel(modelKey)
      if model then
        options.paint = model.model.paints[additionalData.paint]
        options.paint2 = model.model.paints[additionalData.paint2]
        options.paint3 = model.model.paints[additionalData.paint3]
        paintName1 = additionalData.paint
        paintName2 = additionalData.paint2
        paintName3 = additionalData.paint3
      end
    end

    -- Sanitize and replace the vehicle
    local sanitizedOptions = sanitizeVehicleSpawnOptions(modelKey, options)
    local vehicle = core_vehicles.replaceVehicle(modelKey, sanitizedOptions)
    extensions.hook("onVehicleSelectorReplaceCurrent", modelKey, configKey, paintName1, paintName2, paintName3)
    if vehicle then
      log("I", "", "Vehicle replaced: " .. tostring(modelKey) .. " (ID: " .. tostring(vehicle:getId()) .. ")")
      --ui_fadeScreen.stop(fadeScreenDuration)
      guihooks.trigger("app:waiting", false)
    else
      log("E", "", "Failed to replace vehicle: " .. tostring(modelKey))
      --ui_fadeScreen.stop(fadeScreenDuration)
      guihooks.trigger("app:waiting", false)
    end
  end
end

-- Clone vehicle after fade screen
local function cloneVehicleAfterFade(callback)
  --ui_fadeScreen.start(fadeScreenDuration)
  guihooks.trigger("app:waiting", true)
  callbackAfterFade = function()
    local vehicle = core_vehicles.cloneCurrent()

    if vehicle then
      log("I", "", "Vehicle cloned: (ID: " .. tostring(vehicle:getId()) .. ")")
      --ui_fadeScreen.stop(fadeScreenDuration)
      guihooks.trigger("app:waiting", false)
      if callback then callback() end
    else
      log("E", "", "Failed to clone vehicle")
      --ui_fadeScreen.stop(fadeScreenDuration)
      guihooks.trigger("app:waiting", false)
    end
  end
end

local function makeSpawningButtons(configDetails, spawnOnly)
  local buttons = {}

  -- Spawn vehicle button
  if configDetails then

    --[[
    -- maybe in the future
    if configDetails.Source == "Custom" then
      table.insert(buttons, buttonInstance.addButton(nop, {
        label = "Edit Metadata",
        icon = "edit",
        openVehicleEditorPopup = true,
        data = {
          model = configDetails.model_key,
          config = configDetails.key,
        }
      }))
    end
    ]]

    local spawningTutorialActive = gameplay_discover_freeroamTutorial_tutorial and gameplay_discover_freeroamTutorial_tutorial.getActivePhase() == "vehicleManagementSpawn"

    table.insert(buttons, buttonInstance.addButton(function(...)
      extensions.ui_router.navigate("play")
      -- Callback for spawning a new vehicle
      local modelKey = configDetails.model_key
      local configKey = configDetails.key

      spawnVehicleAfterFade(modelKey, configKey, ...)
      ui_vehicleSelector_general.trackRecentVehicle(modelKey, configKey)
    end, {
      label = _tr("ui.debug.vehicle.spawnNew"),
      icon = "carPlus",
      canClearFilters = true,
      autofocus = spawningTutorialActive,
      uiEvent = "action_2",
    }))


    if not spawnOnly then
      table.insert(buttons, buttonInstance.addButton(function(...)
        extensions.ui_router.navigate("play")
        -- Callback for replacing current vehicle
        local modelKey = configDetails.model_key
        local configKey = configDetails.key

        replaceVehicleAfterFade(modelKey, configKey, ...)
        ui_vehicleSelector_general.trackRecentVehicle(modelKey, configKey)
      end, {
        label = _tr("ui.debug.vehicle.replaceCurrent"),
        icon = "carsChange",
        primary = true,
        isDoubleClickAction = not spawningTutorialActive,
        canClearFilters = true,
        disabled = spawningTutorialActive,
        uiEvent = "ok",
      }))
    end
  end

  return buttons
end

-- Get vehicle name similar to quickAccess.lua
local function getVehicleName(veh)
  if not veh then return "No vehicle" end
  local vehKey = veh.JBeam
  local vehConfig = veh.partConfig
  local vehicleNameSTR = {veh.JBeam}
  local vehMainInfo = core_vehicles.getModel(vehKey)

  if vehMainInfo and next(vehMainInfo) then
    table.clear(vehicleNameSTR)
    local config_key = string.match(vehConfig, "vehicles/".. vehKey .."/(.*).pc")
    local configInfo = vehMainInfo.configs and vehMainInfo.configs[config_key] or vehMainInfo.model

    -- skip prop traffic

    -- build name
    table.insert(vehicleNameSTR, vehMainInfo.model["Brand"])
    table.insert(vehicleNameSTR, vehMainInfo.model["Name"])
    if vehMainInfo.configs and vehMainInfo.configs[config_key] then
      table.insert(vehicleNameSTR, configInfo["Configuration"] or "")
    end

  end
  local vehicleName = table.concat(vehicleNameSTR, " ")
  return vehicleName
end

-- Get current vehicle thumbnail similar to inventory.lua
local function getCurrentVehicleThumb(veh)
  if not veh then return nil end
  local vehKey = veh.JBeam
  local vehConfig = veh.partConfig
  local vehMainInfo = core_vehicles.getModel(vehKey)

  if not vehMainInfo or not next(vehMainInfo) then return nil end

  local config_key = string.match(vehConfig, "vehicles/".. vehKey .."/(.*).pc")
  local config = vehMainInfo.configs[config_key]
  if not config then return nil end

  return config.preview
end

-- Get management details for vehicle operations
local function getManagementDetails()
  buttonInstance.clearButtonFunctions()

  local buttons = {}

  -- Only show management buttons if they are enabled
  if M.managementButtonsEnabled then
    if ui_vehicleSelector_general.getDisplayData().includeDevInfo then
      -- Set as default button
      table.insert(buttons, buttonInstance.addButton(function()
        extensions.core_vehicle_partmgmt.savedefault()
        extensions.ui_router.navigate("play")
        extensions.hook("onVehicleSelectorSetAsDefault")
      end, {
        label = _tr("ui.menu.vehicleSelector.saveDefaultPc"),
        icon = "bug"
      }))

      -- Load default button
      table.insert(buttons, buttonInstance.addButton(function()
        callbackAfterFade = function()
          core_vehicles.spawnDefault();
          extensions.hook("trackNewVeh")
          guihooks.trigger("app:waiting", false)
          extensions.hook("onVehicleSelectorLoadDefault")
        end
        extensions.ui_router.navigate("play")
        guihooks.trigger("app:waiting", true)
      end, {
        label = _tr("ui.menu.vehicleSelector.loadDefaultPc"),
        icon = "bug"
      }))
    end

    table.insert(buttons, buttonInstance.addButton(function()
      extensions.ui_router.navigate("pause.vehicle.configurationcombined.save")
    end, {
      label = _tr("ui.menu.vehicleSelector.saveCurrentConfig"),
      icon = "floppyDisk",
      disabled = be:getObjectCount() == 0 or getPlayerVehicle(0) == nil or gameplay_walk.isWalking(),
      --openVehicleEditorPopup = true,
      data = {
        useCurrentVehicle = true,
      }
    }))

    -- Clone current button
    table.insert(buttons, buttonInstance.addButton(function()
      extensions.ui_router.navigate("play")
      cloneVehicleAfterFade()
      extensions.hook("onVehicleSelectorCloneCurrent")
    end, {
      label = _tr("ui.debug.vehicle.cloneCurrent"),
      icon = "copy",
      disabled = be:getObjectCount() == 0 or getPlayerVehicle(0) == nil or gameplay_walk.isWalking(),
    }))

    -- Select Random
    table.insert(buttons, buttonInstance.addButton(function()
      extensions.hook("onVehicleSelectorSelectRandom")


      -- get a random config that passes the filters
      local data = ui_vehicleSelector_general.getUiData()

      local validConfigs = {}
      for _, config in pairs(data.configs) do
        if not ui_vehicleSelector_general.passesFilters({model = config.model_key, config = config.key}) then
          goto continue
        end
        table.insert(validConfigs, config)
        ::continue::
      end

      local randomConfig = validConfigs[math.random(1, #validConfigs)]
      local model = core_vehicles.getModel(randomConfig.model_key)

      local type = randomConfig.Type or model.model.Type

      local path = {keys = {'configsForBrandSubModelOrModel', randomConfig.model_key, randomConfig.subModel or "", randomConfig.brand or "", "Type", ui_vehicleSelector_tiles.groupModeFunctions["Type"](type)}}
      -- force select the random config next time the tiles are loaded
      ui_vehicleSelector_tiles.overrideDefaultSelectedTile(randomConfig)
      return {gotoPath = path}
    end, {
      label = _tr("ui.menu.vehicleSelector.selectRandom"),
      icon = "arrowsShuffle",
      focusKey = "selectRandom"
    }))

    -- Reset all button
    table.insert(buttons, buttonInstance.addButton(function()
      resetGameplay(-1)
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorResetAll")
    end, {
      label = _tr("ui.menu.vehicleSelector.resetAll"),
      icon = "carsWrench",
      accent = "main"
    }))

    -- Remove all button
    table.insert(buttons, buttonInstance.addButton(function()
      core_vehicles.removeAll();
      extensions.hook("trackNewVeh")
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorRemoveAll")
    end, {
      label = _tr("ui.debug.vehicle.removeAll"),
      icon = "trashBin2",
      accent = "attention"
    }))

    -- Remove current button
    table.insert(buttons, buttonInstance.addButton(function()
      core_vehicles.removeCurrent();
      extensions.hook("trackNewVeh")
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorRemoveCurrent")
    end, {
      label = _tr("ui.debug.vehicle.removeCurrent"),
      icon = "trashBin1",
      accent = "attention"
    }))

    -- Remove others button
    table.insert(buttons, buttonInstance.addButton(function()
      core_vehicles.removeAllExceptCurrent();
      extensions.hook("trackNewVeh")
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorRemoveOthers")
    end, {
      label = _tr("ui.debug.vehicle.removeOthers"),
      icon = "broom",
      accent = "attention"
    }))

  end

  -- Get current vehicle details
  local currentVehicle = be:getPlayerVehicle(0)
  local managementDetails = {
    currentVehicleName = getVehicleName(currentVehicle),
    currentVehicleThumb = getCurrentVehicleThumb(currentVehicle)
  }

  return {
    buttonInfo = buttons,
    details = managementDetails
  }
end

local function executeDoubleClick(itemDetails)
  local details = ui_vehicleSelector_detailsInteraction.getDetails(itemDetails)
  if details and details.buttonInfo then
    for _, button in ipairs(details.buttonInfo) do
      if button.isDoubleClickAction or #details.buttonInfo == 1 then
        M.executeButton(button.buttonId)
        return
      end
    end
  end
end

-- Set management buttons enabled/disabled state
local function setManagementButtonsEnabled(enabled)
  M.managementButtonsEnabled = enabled
end

-- Set details button for freeroam mode
local function setDetailsButtonForFreeroam(enabled)
  M.detailsButtonForFreeroam = enabled
end

-- Set custom details buttons for challenge mode
local function setCustomDetailsButtons(buttons)
  M.customDetailsButtons = buttons
end

-- Assign functions to module
M.executeButton = executeButton
M.makeSpawningButtons = makeSpawningButtons
M.getManagementDetails = getManagementDetails
M.getVehicleName = getVehicleName
M.getCurrentVehicleThumb = getCurrentVehicleThumb
M.onScreenFadeState = onScreenFadeState
M.setManagementButtonsEnabled = setManagementButtonsEnabled
M.setDetailsButtonForFreeroam = setDetailsButtonForFreeroam
M.setCustomDetailsButtons = setCustomDetailsButtons
M.executeDoubleClick = executeDoubleClick

-- Expose button instance methods for external use
M.addButton = function(...) return buttonInstance.addButton(...) end
M.clearButtonFunctions = function(...) return buttonInstance.clearButtonFunctions(...) end
M.getFreeButtonId = function(...) return buttonInstance.getFreeButtonId(...) end

return M
