-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local multiseatConfiguration = require("ge/extensions/ui/multiseat/multiseatConfiguration")

M.dependencies = {
  "ui_multiseat_generalSettings",
  "ui_multiseat_multiseatConfiguration",
  "ui_multiseat_multiseatVehicles",
  "ui_gridSelectorRouteLifecycleCallbacks",
  "ui_pause_routeLifecycleCallbacks",
}

local SETTINGS_ROUTE = "pause.multiseatSettings"
local VEHICLE_SELECTOR_ROUTE = "pause.multiseatSettings.vehicleSelector"
local PAUSE_REQUEST_ID = "multiseat_settings"

local activeValues = {}
local stagedValues = {}
local settingsOpen = false
local pauseRequestActive = false
local pendingExitNavigation = nil
local exitConfirmationBypass = false
local deviceColorRevision = nil

local function valuesEqual(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for key, value in pairs(a) do
    if not valuesEqual(value, b[key]) then return false end
  end
  for key in pairs(b) do
    if a[key] == nil then return false end
  end
  return true
end

local function fieldStoresValue(field)
  return field.type ~= "action" and field.type ~= "actionSelect"
end

local function collectProviders()
  local providers = {}
  extensions.hook("onGetMultiseatGameSettings", providers)

  local validProviders = {}
  local liveProviderIds = {}
  for _, provider in ipairs(providers) do
    if type(provider) == "table"
      and type(provider.id) == "string"
      and type(provider.fields) == "table"
      and not liveProviderIds[provider.id]
    then
      liveProviderIds[provider.id] = true
      validProviders[#validProviders + 1] = provider
      activeValues[provider.id] = activeValues[provider.id] or {}
      stagedValues[provider.id] = stagedValues[provider.id] or {}

      for _, field in ipairs(provider.fields) do
        if type(field) == "table" and type(field.id) == "string" and fieldStoresValue(field) then
          if activeValues[provider.id][field.id] == nil then
            activeValues[provider.id][field.id] = deepcopy(field.value)
          end
          if stagedValues[provider.id][field.id] == nil then
            stagedValues[provider.id][field.id] = deepcopy(activeValues[provider.id][field.id])
          end
        end
      end
    end
  end

  for providerId in pairs(activeValues) do
    if not liveProviderIds[providerId] then
      activeValues[providerId] = nil
      stagedValues[providerId] = nil
    end
  end
  return validProviders
end

local function findProvider(providers, providerId)
  for _, provider in ipairs(providers) do
    if provider.id == providerId then return provider end
  end
end

local function findField(provider, fieldId)
  for _, field in ipairs(provider.fields) do
    if field.id == fieldId then return field end
  end
end

local function applyValueOverrides(providers, overrides)
  for providerId, values in pairs(overrides or {}) do
    local provider = findProvider(providers, providerId)
    if provider and type(values) == "table" then
      for fieldId, value in pairs(values) do
        stagedValues[providerId][fieldId] = deepcopy(value)
      end
    end
  end
end

local function normalizeOptionValue(field, value)
  if type(field.options) ~= "table" then return value end
  for _, option in ipairs(field.options) do
    if option.value == value then return option.value end
    if type(option.value) == "number" and option.value == tonumber(value) then
      return option.value
    end
  end
end

local function validateStagedValues(providers)
  for _, provider in ipairs(providers) do
    for _, field in ipairs(provider.fields) do
      local value = fieldStoresValue(field) and stagedValues[provider.id][field.id] or nil
      if fieldStoresValue(field)
        and type(field.options) == "table"
        and normalizeOptionValue(field, value) == nil
        and not (field.allowEmpty == true and value == "")
      then
        return false, "invalid_setting"
      end
    end
  end
  return true
end

local function getGameChanges(providers)
  local changes = {
    dirty = false,
    requiresRestart = false,
    fields = {},
  }
  for _, provider in ipairs(providers) do
    for _, field in ipairs(provider.fields) do
      if fieldStoresValue(field) then
        local activeValue = activeValues[provider.id][field.id]
        local stagedValue = stagedValues[provider.id][field.id]
        if not valuesEqual(activeValue, stagedValue) then
          local applyMode = field.applyMode or provider.applyMode or "restart"
          changes.dirty = true
          changes.requiresRestart = changes.requiresRestart or applyMode == "restart"
          changes.fields[#changes.fields + 1] = {
            providerId = provider.id,
            fieldId = field.id,
            applyMode = applyMode,
          }
        end
      end
    end
  end
  return changes
end

local function isSettingsRoute(route)
  local name = type(route) == "table" and route.name or nil
  return name == SETTINGS_ROUTE or name == VEHICLE_SELECTOR_ROUTE
end

local function acquirePauseRequest()
  if pauseRequestActive then return end
  if simTimeAuthority and simTimeAuthority.pushPauseRequest then
    simTimeAuthority.pushPauseRequest(PAUSE_REQUEST_ID)
    pauseRequestActive = true
  end
end

local function releasePauseRequest()
  if not pauseRequestActive then return end
  if simTimeAuthority and simTimeAuthority.popPauseRequest then
    simTimeAuthority.popPauseRequest(PAUSE_REQUEST_ID)
  end
  pauseRequestActive = false
end

-- the input devices already light up in the colour of the player they are staged for
local function syncDeviceColorPreview()
  local revision = multiseatConfiguration.getPreview().revision
  if revision == deviceColorRevision then return end
  deviceColorRevision = revision
  core_multiseat.previewDeviceColors(multiseatConfiguration.getCommitConfiguration())
end

local function clearDeviceColorPreview()
  deviceColorRevision = nil
  core_multiseat.clearDeviceColors()
end

local function closeSettings(toRoute)
  if isSettingsRoute(toRoute) then return end
  settingsOpen = false
  releasePauseRequest()
  pendingExitNavigation = nil
  exitConfirmationBypass = false
  extensions.hook("onMultiseatSettingsClosed", toRoute)
  ui_multiseat_multiseatVehicles.resetSettingsSnapshots()
  multiseatConfiguration.discard()
  clearDeviceColorPreview()
  activeValues = {}
  stagedValues = {}
end

local function isMultiseatActive()
  return (core_multiseat and core_multiseat.isMultiseatActive() == true)
    or (ui_multiseat_freeroam and ui_multiseat_freeroam.isActive() == true)
    or (gameplay_multiseat_gamemodeManager and gameplay_multiseat_gamemodeManager.isActive() == true)
end

function M.getScreenData()
  if not settingsOpen then return end
  multiseatConfiguration.begin({source = "settings"})
  syncDeviceColorPreview()
  local providers = collectProviders()
  local gameChanges = getGameChanges(providers)
  local vehicleChanges = ui_multiseat_multiseatVehicles.getStagedChanges()
  local userDirty = gameChanges.dirty
    or ui_multiseat_multiseatVehicles.hasUserChanges()
    or multiseatConfiguration.hasUserChanges()
  local components = {
    {
      id = "personas",
      type = "personaSelector",
      data = ui_multiseat_multiseatVehicles.getPersonaSelectorData(),
    },
  }
  local trailingComponents = {}

  for _, provider in ipairs(providers) do
    local component = deepcopy(provider)
    component.type = "settings"
    for _, field in ipairs(component.fields) do
      if fieldStoresValue(field) then
        field.value = deepcopy(stagedValues[provider.id][field.id])
      end
    end
    local target = provider.placement == "afterVehicles" and trailingComponents or components
    target[#target + 1] = component
  end

  components[#components + 1] = {
    id = "vehicles",
    type = "vehicles",
    data = ui_multiseat_multiseatVehicles.getSettingsData(),
  }
  for _, component in ipairs(trailingComponents) do
    components[#components + 1] = component
  end

  local screen = {
    title = "ui.multiseat.settings.title",
    readyToPlay = false,
    busy = false,
  }
  extensions.hook("onGetMultiseatSettingsScreenData", screen)

  return {
    title = screen.title,
    components = components,
    active = isMultiseatActive(),
    dirty = userDirty,
    discardDirty = userDirty,
    applyMode = (gameChanges.requiresRestart or vehicleChanges.requiresRestart)
      and "restart"
      or (gameChanges.dirty or vehicleChanges.dirty) and "apply"
      or "none",
    readyToPlay = screen.readyToPlay == true,
    busy = screen.busy == true,
  }
end

function M.stageSetting(providerId, fieldId, value)
  local providers = collectProviders()
  local provider = findProvider(providers, providerId)
  local field = provider and findField(provider, fieldId)
  if not field or not fieldStoresValue(field) then return M.getScreenData() end

  local normalizedValue = normalizeOptionValue(field, value)
  if type(field.options) == "table"
    and normalizedValue == nil
    and not (field.allowEmpty == true and value == "")
  then
    return M.getScreenData()
  end
  if field.allowEmpty == true and value == "" then normalizedValue = "" end
  stagedValues[providerId][fieldId] = deepcopy(normalizedValue)
  if (field.applyMode or provider.applyMode) == "immediate" then
    activeValues[providerId][fieldId] = deepcopy(normalizedValue)
  end
  extensions.hook("onMultiseatGameSettingChanged", providerId, fieldId, deepcopy(normalizedValue))
  return M.getScreenData()
end

-- action fields do not carry a value, the owning provider performs the change right away
function M.runSettingAction(providerId, fieldId, value)
  local providers = collectProviders()
  local provider = findProvider(providers, providerId)
  local field = provider and findField(provider, fieldId)
  local result = {success = false}
  if field and field.type == "action" then
    extensions.hook("onMultiseatGameSettingAction", providerId, fieldId, result)
  elseif field and field.type == "actionSelect" then
    local normalizedValue = normalizeOptionValue(field, value)
    if normalizedValue ~= nil then
      extensions.hook("onMultiseatGameSettingAction", providerId, fieldId, result, normalizedValue)
    end
  end
  -- actions change staged data behind the screen's back, so the screen has to reload
  if result.success == true then M.notifyScreenChanged() end
  return {
    success = result.success == true,
    data = M.getScreenData(),
  }
end

function M.applyStagedSettings(options)
  options = type(options) == "table" and options or {}
  local providers = collectProviders()
  local gameChanges = getGameChanges(providers)
  local vehicleChanges = ui_multiseat_multiseatVehicles.getStagedChanges()
  if not gameChanges.dirty and not vehicleChanges.dirty then
    return {success = true}
  end

  local valid, reason = validateStagedValues(providers)
  if not valid then return {success = false, reason = reason} end

  local changeSet = {
    gameSettingsChanged = gameChanges.dirty,
    rosterChanged = vehicleChanges.rosterChanged,
    vehicleChanged = vehicleChanges.vehicleChanged,
    iconChanged = vehicleChanges.iconChanged,
    preferencesChanged = vehicleChanges.preferencesChanged,
    requiresRestart = gameChanges.requiresRestart or vehicleChanges.requiresRestart,
    gameFields = deepcopy(gameChanges.fields),
  }
  local context = {
    players = ui_multiseat_multiseatVehicles.getStagedPlayers(),
    changes = changeSet,
  }
  local result = {
    success = true,
    requiresRestart = changeSet.requiresRestart,
    exitAfterApply = options.exitAfterApply == true,
  }

  if gameChanges.dirty or vehicleChanges.rosterChanged then
    extensions.hook(
      "onValidateMultiseatGameSettings",
      deepcopy(stagedValues),
      deepcopy(activeValues),
      result,
      context
    )
    if result.success == false then return result end
  end

  local prepared = ui_multiseat_multiseatVehicles.prepareStagedChanges()
  if prepared.success == false then return prepared end
  local committed, committedConfig = multiseatConfiguration.commitCore()
  if not committed then
    ui_multiseat_multiseatVehicles.cancelPreparedChanges()
    return {success = false, reason = committedConfig}
  end

  local vehicleResult = ui_multiseat_multiseatVehicles.finalizeStagedChanges(vehicleChanges, committedConfig)
  if vehicleResult.success == false then
    multiseatConfiguration.rollbackCommit()
    ui_multiseat_multiseatVehicles.cancelPreparedChanges()
    return vehicleResult
  end

  if gameChanges.dirty then
    extensions.hook(
      "onApplyMultiseatGameSettings",
      deepcopy(stagedValues),
      deepcopy(activeValues),
      result,
      context
    )
    if result.success == false then
      multiseatConfiguration.rollbackCommit()
      return result
    end
    applyValueOverrides(providers, result.valueOverrides)
    activeValues = deepcopy(stagedValues)
  end

  multiseatConfiguration.completeCommit()
  extensions.hook("onMultiseatSettingsApplied", changeSet, result)
  if result.success == false then return result end
  if result.deferred ~= true then M.notifyScreenChanged() end
  return result
end

function M.discardStagedSettings()
  collectProviders()
  stagedValues = deepcopy(activeValues)
  if not isMultiseatActive() and multiseatConfiguration.clearCachedAssignments then
    multiseatConfiguration.clearCachedAssignments()
  end
  multiseatConfiguration.discard()
  ui_multiseat_multiseatVehicles.discardStagedChanges()
  return M.getScreenData()
end

function M.requestMultiseatExit()
  if not isMultiseatActive() then return false end
  guihooks.trigger("showConfirmationDialog", {
    title = "ui.multiseat.exit",
    text = "ui.multiseat.confirmExit",
    buttons = {
      {
        label = "ui.common.cancel",
        isCancel = true,
      },
      {
        label = "ui.multiseat.exit",
        luaCallback = "ui_multiseat_multiseatSettings.confirmMultiseatExit()",
        isConfirm = true,
      },
    },
  })
  return true
end

local hasUnappliedChanges

function M.confirmMultiseatExit()
  local stagedPlayers = ui_multiseat_multiseatVehicles.getStagedPlayers()
  local exitOptions
  if #stagedPlayers == 0 then
    exitOptions = {assignmentCache = multiseatConfiguration.getCommitConfiguration()}
  elseif #stagedPlayers == 1 and hasUnappliedChanges() then
    local applyResult = M.applyStagedSettings({exitAfterApply = true})
    if applyResult and applyResult.success == false then
      M.notifyScreenChanged()
      return false
    end
  end
  if not ui_multiseat_freeroam
    or not ui_multiseat_freeroam.exitMultiseat
    or not ui_multiseat_freeroam.exitMultiseat(exitOptions)
  then
    return false
  end
  exitConfirmationBypass = true
  local result = extensions.ui_menuManager.closeMenu()
  return result and result.handled == true
end

hasUnappliedChanges = function()
  local providers = collectProviders()
  return getGameChanges(providers).dirty
    or ui_multiseat_multiseatVehicles.hasUserChanges()
    or multiseatConfiguration.hasUserChanges()
end

local function resumePendingExit()
  local pending = pendingExitNavigation
  pendingExitNavigation = nil
  if type(pending) ~= "table" then return false end
  exitConfirmationBypass = true
  return extensions.ui_router.navigate(pending.routeName, pending.params, pending.options)
end

function M.confirmExit(route, params, context)
  if exitConfirmationBypass then
    exitConfirmationBypass = false
    return true
  end
  if not hasUnappliedChanges() then return true end

  context = type(context) == "table" and context or {}
  local routeName = context.routeName or (type(route) == "table" and route.name)
  if type(routeName) ~= "string" or routeName == "" then return true end
  if pendingExitNavigation then return false end

  pendingExitNavigation = {
    routeName = routeName,
    params = params,
    options = context.options,
  }

  -- matches the settings screen, which only allows applying with more than one assigned player
  local canApply = #multiseatConfiguration.getPreview().joinedPersonas > 1

  guihooks.trigger("showConfirmationDialog", {
    title = "ui.multiseat.settings.unappliedChanges.title",
    text = "ui.multiseat.settings.unappliedChanges.message",
    buttons = {
      {
        label = "ui.common.cancel",
        luaCallback = "ui_multiseat_multiseatSettings.cancelExit()",
        isCancel = true,
      },
      {
        label = "ui.multiseat.settings.unappliedChanges.discard",
        luaCallback = "ui_multiseat_multiseatSettings.confirmExitDiscarding()",
        isDestructive = true,
      },
      {
        label = "ui.multiseat.settings.unappliedChanges.apply",
        luaCallback = "ui_multiseat_multiseatSettings.confirmExitApplying()",
        isConfirm = true,
        enabled = canApply,
      },
    },
  })
  return false
end

function M.cancelExit()
  pendingExitNavigation = nil
end

-- No explicit discard needed: leaving the flow drops the staged values in closeSettings
function M.confirmExitDiscarding()
  return resumePendingExit()
end

function M.confirmExitApplying()
  local result = M.applyStagedSettings()
  if result and result.success == false then
    pendingExitNavigation = nil
    M.notifyScreenChanged()
    return result
  end
  return resumePendingExit()
end

function M.stagePlayerOptIn(player, optedIn)
  local changed = ui_multiseat_multiseatVehicles.stagePlayerOptIn(player, optedIn)
  return {
    success = changed ~= false,
    data = M.getScreenData(),
  }
end

function M.cycleDevicePlayer(deviceId)
  local success = ui_multiseat_multiseatVehicles.cycleDevicePlayer(deviceId)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.toggleDevicePlayer(deviceId)
  local success = ui_multiseat_multiseatVehicles.toggleDevicePlayer(deviceId)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.moveDevicePlayer(deviceId, direction)
  local success = ui_multiseat_multiseatVehicles.moveDevicePlayer(deviceId, direction)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.setDevicePlayer(deviceId, personaNumber)
  local success = ui_multiseat_multiseatVehicles.setDevicePlayer(deviceId, personaNumber)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.removeDevice(deviceId)
  local success = ui_multiseat_multiseatVehicles.removeDevice(deviceId)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.joinDeviceGroup(groupId)
  local success = ui_multiseat_multiseatVehicles.joinDeviceGroup(groupId)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.leaveDeviceGroup(player)
  local success = ui_multiseat_multiseatVehicles.leaveDeviceGroup(player)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.openVehicleSelectorForPlayer(player)
  return ui_multiseat_multiseatVehicles.openVehicleSelectorForPlayer(player)
end

function M.stagePlayerVehiclePreferences(player, preferences)
  local success = ui_multiseat_multiseatVehicles.stagePlayerVehiclePreferences(player, preferences)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.stagePlayerIcon(player, icon)
  local success = ui_multiseat_multiseatVehicles.stagePlayerIcon(player, icon)
  return {
    success = success,
    data = M.getScreenData(),
  }
end

function M.play()
  local result = {success = false}
  extensions.hook("onPlayMultiseatGameSettings", result)
  return result
end

function M.notifyScreenChanged()
  guihooks.trigger("MultiseatSettingsChanged")
end

function M.onLocalParticipantsChanged()
  if ui_multiseat_multiseatVehicles.isSynchronizing() then return end
  M.notifyScreenChanged()
end

function M.onSettingsEnter()
  settingsOpen = true
  acquirePauseRequest()
end

function M.onSettingsLeave(context, toRoute, fromRoute, data)
  ui_pause_routeLifecycleCallbacks.onPauseLeave(context, toRoute, fromRoute, data)
  closeSettings(toRoute)
end

function M.onVehicleSelectorEnter(context, toRoute, fromRoute, data)
  settingsOpen = true
  acquirePauseRequest()
  ui_gridSelectorRouteLifecycleCallbacks.onRouteEnter(context, toRoute, fromRoute, data)
end

function M.onVehicleSelectorMount(context, toRoute, fromRoute, data)
  ui_gridSelectorRouteLifecycleCallbacks.onRouteMount(context, toRoute, fromRoute, data)
end

function M.onVehicleSelectorLeave(context, toRoute, fromRoute, data)
  ui_gridSelectorRouteLifecycleCallbacks.onRouteLeave(context, toRoute, fromRoute, data)
  ui_pause_routeLifecycleCallbacks.onPauseLeave(context, toRoute, fromRoute, data)
  ui_multiseat_multiseatVehicles.onVehicleSelectorLeave(toRoute)
  closeSettings(toRoute)
end

function M.onClientEndMission()
  settingsOpen = false
  releasePauseRequest()
  pendingExitNavigation = nil
  exitConfirmationBypass = false
  deviceColorRevision = nil
  activeValues = {}
  stagedValues = {}
end

function M.onExtensionUnloaded()
  releasePauseRequest()
end

return M
