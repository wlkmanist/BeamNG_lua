local M = {}

-- Load button module
local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")

-- Create button management instance
local buttonInstance = buttonModule.create()

M.managementButtonsEnabled = true

local function customConfigurationsAllowed()
  local capabilities = gameplay_discover_firstDrive_capabilities
  return not capabilities
    or not capabilities.areCustomConfigurationsAllowed
    or capabilities.areCustomConfigurationsAllowed()
end

local function selectionAllowed(modelKey, configKey)
  local restriction = gameplay_discover_firstDrive_vehicleSelectorRestriction
  return not restriction
    or not restriction.isSelectionAllowed
    or restriction.isSelectionAllowed(modelKey, configKey)
end

local function confirmSpawn(spawnFn)
  if gameplay_lowPerformance then return gameplay_lowPerformance.confirmSpawn(spawnFn) end
  return spawnFn()
end

local function resetFiltersOnSpawn()
  if ui_vehicleSelector_general.getDisplayData().filterResetOnSpawn then
    ui_vehicleSelector_general.clearAllFilters()
  end
end

-- Fade screen callback
local callbackAfterFade

-- Execute button callback by ID with additional logic
local function executeButton(buttonId, additionalData)
  local buttonInfo = buttonInstance.getButtonInfo(buttonId)
  if buttonInfo then
    local data = buttonInstance.executeButton(buttonId, additionalData)
    if buttonInfo.meta.canClearFilters then resetFiltersOnSpawn() end
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

local function canModifyVehicle(playerId, vehicleId, permission)
  if not multiplayer_permissions then return true end
  local mpPlayerId = multiplayer_multiplayer.getLocalMPPlayerId(playerId)
  local mid = multiplayer_vehicleSync.vIdToMId(vehicleId)
  local allowed = multiplayer_permissions.checkPlayerPermission(mpPlayerId, permission, mid)
  return allowed
end

local function canModifyCurrentVehicle(playerId, permission)
  local vehicle = getPlayerVehicle(playerId)
  return vehicle ~= nil and canModifyVehicle(playerId, vehicle:getId(), permission)
end

local function hasModifiableVehicle(playerId, exceptVid, permission)
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh then
      local vid = veh:getId()
      if (exceptVid == nil or vid ~= exceptVid) and canModifyVehicle(playerId, vid, permission) then
        return true
      end
    end
  end
  return false
end

local function resetModifiableVehicles(playerId)
  extensions.hook('trackVehReset')
  if not multiplayer_permissions then
    resetGameplay(-1)
    return
  end
  for i = 0, be:getObjectCount() - 1 do
    local veh = be:getObject(i)
    if veh and canModifyVehicle(playerId, veh:getId(), 'resetVehicle') then
      veh:requestReset(RESET_PHYSICS)
      veh:resetBrokenFlexMesh()
    end
  end
end

local function removeModifiableVehicles(playerId, exceptVid)
  local deletedAny = false
  for i = be:getObjectCount() - 1, 0, -1 do
    local veh = be:getObject(i)
    if veh then
      local vid = veh:getId()
      if (exceptVid == nil or vid ~= exceptVid) and canModifyVehicle(playerId, vid, 'removeVehicle') then
        veh:delete()
        deletedAny = true
      end
    end
  end
  return deletedAny
end

-- Spawn vehicle after fade screen
local function spawnVehicleAfterFade(modelKey, configKey, additionalData)
  if not selectionAllowed(modelKey, configKey) then return false end
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
  if not selectionAllowed(modelKey, configKey) then return false end
  --ui_fadeScreen.start(fadeScreenDuration)
  extensions.hook("onVehicleSelectorReplaceCurrentRequested")
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
  local playerId = 0

  -- Spawn vehicle button
  if configDetails then
    local configSelectionAllowed = selectionAllowed(configDetails.model_key, configDetails.key)
    local spawningTutorialActive = gameplay_discover_freeroamTutorial_tutorial
      and gameplay_discover_freeroamTutorial_tutorial.getActivePhase() == "vehicleManagementSpawn"
    local lesson = gameplay_discover_firstDrive_learningFlow
      and gameplay_discover_firstDrive_learningFlow.isLessonActive("vehicleManagement")
      and gameplay_discover_firstDrive_lessons_vehicleManagement_vehicleManagement
    local spawnLocked = lesson and not lesson.isSpawnAllowed()
    local replaceLocked = spawningTutorialActive or lesson and not lesson.isReplaceAllowed()

    table.insert(buttons, buttonInstance.addButton(function(additionalData)
      if not configSelectionAllowed or spawnLocked then return false end
      confirmSpawn(function()
        extensions.ui_router.navigate("play")
        -- Callback for spawning a new vehicle
        local modelKey = configDetails.model_key
        local configKey = configDetails.key

        spawnVehicleAfterFade(modelKey, configKey, additionalData)
        ui_vehicleSelector_general.trackRecentVehicle(modelKey, configKey)
        resetFiltersOnSpawn()
      end)
    end, {
      label = _tr("ui.debug.vehicle.spawnNew"),
      icon = "carPlus",
      autofocus = (spawningTutorialActive or lesson) and not spawnLocked,
      disabled = not configSelectionAllowed or spawnLocked,
      uiEvent = "action_2",
      tutorialHighlightId = "gridSelector.action.spawnVehicleNew",
    }))


    if not spawnOnly then
      table.insert(buttons, buttonInstance.addButton(function(...)
        if not configSelectionAllowed or replaceLocked then return false end
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
        isDoubleClickAction = not replaceLocked,
        canClearFilters = true,
        disabled = not configSelectionAllowed or replaceLocked or not canModifyCurrentVehicle(playerId, 'removeVehicle'),
        uiEvent = "ok",
        tutorialHighlightId = "gridSelector.action.replaceVehicle",
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
  local buttons = {}
  local playerId = 0

  -- Only show management buttons if they are enabled
  if M.managementButtonsEnabled then
    buttonInstance.clearButtonFunctions()
    local showCustomConfigurationButtons = customConfigurationsAllowed()
    if showCustomConfigurationButtons and ui_vehicleSelector_general.getDisplayData().includeDevInfo then
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

    if showCustomConfigurationButtons then
      table.insert(buttons, buttonInstance.addButton(function()
        extensions.ui_router.navigate("pause.vehicle.configurationcombined.save")
      end, {
        label = _tr("ui.menu.vehicleSelector.saveCurrentConfig"),
        icon = "floppyDisk",
        disabled = not canModifyCurrentVehicle(playerId, 'resetVehicle') or gameplay_walk.isWalking(),
        data = {
          useCurrentVehicle = true,
        }
      }))
    end

    -- Clone current button
    table.insert(buttons, buttonInstance.addButton(function()
      confirmSpawn(function()
        extensions.ui_router.navigate("play")
        cloneVehicleAfterFade()
        extensions.hook("onVehicleSelectorCloneCurrent")
      end)
    end, {
      label = _tr("ui.debug.vehicle.cloneCurrent"),
      icon = "copy",
      disabled = not canModifyCurrentVehicle(playerId, 'spawnVehicle') or gameplay_walk.isWalking(),
    }))

    -- Select Random
    if showCustomConfigurationButtons then
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
    end

    -- Reset all button
    table.insert(buttons, buttonInstance.addButton(function()
      resetModifiableVehicles(playerId)
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorResetAll")
    end, {
      label = _tr("ui.menu.vehicleSelector.resetAll"),
      icon = "carsWrench",
      accent = "main",
      disabled = not hasModifiableVehicle(playerId, nil, 'resetVehicle'),
    }))

    -- Remove all button
    table.insert(buttons, buttonInstance.addButton(function()
      if removeModifiableVehicles(playerId, nil) then
        core_vehicles.enterFreecamIfNoVehicles()
        extensions.hook("trackNewVeh")
      end
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorRemoveAll")
    end, {
      label = _tr("ui.debug.vehicle.removeAll"),
      icon = "trashBin2",
      accent = "attention",
      disabled = not hasModifiableVehicle(playerId, nil, 'removeVehicle'),
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
      accent = "attention",
      disabled = not canModifyCurrentVehicle(playerId, 'removeVehicle'),
    }))

    -- Remove others button
    table.insert(buttons, buttonInstance.addButton(function()
      local currentVid = be:getPlayerVehicleID(playerId)
      if removeModifiableVehicles(playerId, currentVid) then
        extensions.hook("trackNewVeh")
      end
      extensions.ui_router.navigate("play")
      extensions.hook("onVehicleSelectorRemoveOthers")
    end, {
      label = _tr("ui.debug.vehicle.removeOthers"),
      icon = "broom",
      accent = "attention",
      disabled = not hasModifiableVehicle(playerId, be:getPlayerVehicleID(playerId), 'removeVehicle'),
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
