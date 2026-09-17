local M = {}

local updatingMods = false
local currentConfig

-- todo: load/save this to file

local function isMultiplayerExtensionLoaded()
  return extensions.isExtensionLoaded("multiplayer_multiplayer")
end

local function defaultSessionExtraDefaults()
  local ex = multiplayer_settings and multiplayer_settings.extraOptions or {}
  local gh = ex.ghostOptions or {}
  return {
    ghostOnTp = gh.ghostOnTp == true,
    ghostOnReset = gh.ghostOnReset ~= false,
    vehicleCollisions = ex.vehicleCollisions ~= false,
    allowPausing = ex.allowPausing == true,
  }
end

local function onFreeroamConfiguratorGetOptions(level, additionalOptions)
  if shipping_build then return end
  if not isMultiplayerExtensionLoaded() then return end
  local d = defaultSessionExtraDefaults()

  local mpOptions = {
    name = "Multiplayer",
    order = 1000,
    type = "switch",
    key = "mp_mpEnabled",
    value = false,
    options = {},
    enable_step = "multiplayer",
  }

  local isLocalSession = (multiplayer_settings and multiplayer_settings.sessionSettings and multiplayer_settings.sessionSettings.isLocalSession) or false

  table.insert(mpOptions.options, {
    label = _tr("ui.multiplayer.session.localSession"),
    value = isLocalSession,
    key = "mp_isLocalSession",
    type = "switch",
  })

  local maxPlayers = (multiplayer_settings and multiplayer_settings.sessionSettings and multiplayer_settings.sessionSettings.maxPlayers) or 8

  table.insert(mpOptions.options, {
    label = _tr("ui.multiplayer.maxPlayers"),
    value = maxPlayers,
    key = "mp_mpMaxPlayers",
    icon = "helmets",
    type = "number",
    min = 1,
    max = 64,
    step = 1,
  })

  table.insert(mpOptions.options, {
    label = _tr("ui.multiplayer.session.ghostOnTeleport"),
    value = d.ghostOnTp,
    key = "mp_extra_ghostOnTp",
    type = "switch",
  })
  table.insert(mpOptions.options, {
    label = _tr("ui.multiplayer.session.ghostOnSpawnReset"),
    value = d.ghostOnReset,
    key = "mp_extra_ghostOnReset",
    type = "switch",
  })
  table.insert(mpOptions.options, {
    label = _tr("ui.multiplayer.session.vehicleCollisions"),
    value = d.vehicleCollisions,
    key = "mp_extra_vehicleCollisions",
    type = "switch",
  })
  table.insert(mpOptions.options, {
    label = _tr("ui.multiplayer.session.allowPausing"),
    value = d.allowPausing,
    key = "mp_extra_allowPausing",
    type = "switch",
  })

  table.insert(additionalOptions, mpOptions)
end

local function onFreeroamConfiguratorApplyOptions(options)

end

local function onFreeroamConfiguratorOverrideStartButton(buttonModule, configuration)
  if shipping_build then return end
  if not isMultiplayerExtensionLoaded() then return end
  if configuration.options.mp_mpEnabled then
    buttonModule.addButton(M.startMultiplayer, {
      label = "Host Session",
      icon = "helmets",
      priority = 100,
    })
  end
end

M.startMultiplayer = function(configuration)
  extensions.load("multiplayer_multiplayer")

  -- If failed to load extension (e.g. Steam no available, Online Features disabled), return
  if not multiplayer_multiplayer then return end

  -- Check for updates and start multiplayer session after mods are updated
  -- TODO: Only check updates for mods that are active
  core_modmanager.checkUpdate()
  updatingMods = true
  currentConfig = configuration
end

-- Start multiplayer session after mods are updated
M.onModManagerModsMounted = function(mods)
  if not updatingMods then return end
  updatingMods = false

  local createSessionSettings = deepcopy(multiplayer_settings.sessionSettings)
  createSessionSettings.level = currentConfig.levelName
  createSessionSettings.spawnPoint = currentConfig.spawnPointName
  local o = currentConfig.options or {}
  createSessionSettings.isLocalSession = o.mp_isLocalSession or createSessionSettings.isLocalSession or false
  createSessionSettings.maxPlayers = o.mp_mpMaxPlayers or createSessionSettings.maxPlayers or 8

  local extraOptions = deepcopy(multiplayer_settings.extraOptions)
  extraOptions.spawnDefaultVehicle = true
  if o.mp_extra_vehicleCollisions ~= nil then
    extraOptions.vehicleCollisions = o.mp_extra_vehicleCollisions
  end
  if o.mp_extra_allowPausing ~= nil then
    extraOptions.allowPausing = o.mp_extra_allowPausing
  end
  extraOptions.ghostOptions = extraOptions.ghostOptions or {}
  if o.mp_extra_ghostOnTp ~= nil then
    extraOptions.ghostOptions.ghostOnTp = o.mp_extra_ghostOnTp
  end
  if o.mp_extra_ghostOnReset ~= nil then
    extraOptions.ghostOptions.ghostOnReset = o.mp_extra_ghostOnReset
  end

  -- Selected vehicle options
  local options = {
    config = currentConfig.vehicle.config,
  }
  local paintName1, paintName2, paintName3 = nil, nil, nil
  if currentConfig.vehicle.additionalData then
    local model = core_vehicles.getModel(currentConfig.vehicle.model)
    if model then
      options.paint = model.model.paints[currentConfig.vehicle.additionalData.paint]
      options.paint2 = model.model.paints[currentConfig.vehicle.additionalData.paint2]
      options.paint3 = model.model.paints[currentConfig.vehicle.additionalData.paint3]
      paintName1 = currentConfig.vehicle.additionalData.paint
      paintName2 = currentConfig.vehicle.additionalData.paint2
      paintName3 = currentConfig.vehicle.additionalData.paint3
    end
  end

  local spawnVehicle = { currentConfig.vehicle.model, options}

  multiplayer_sessionManager.createAndJoinSession(false, createSessionSettings, extraOptions, spawnVehicle)
end

M.onFreeroamConfiguratorGetOptions = onFreeroamConfiguratorGetOptions
M.onFreeroamConfiguratorApplyOptions = onFreeroamConfiguratorApplyOptions
M.onFreeroamConfiguratorOverrideStartButton = onFreeroamConfiguratorOverrideStartButton
return M