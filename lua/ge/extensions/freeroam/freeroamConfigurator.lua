local M = {}
local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule").create()

M.dependencies = {}
local generatorFiles = FS:findFiles('lua/ge/extensions/freeroam/configuratorOptions/', '*.lua', 1, true, false)
for _, filePath in ipairs(generatorFiles) do
  -- Get relative path from configuratorOptions folder and convert to extension name format
  local relativePath = string.gsub(filePath, 'lua/ge/extensions/freeroam/configuratorOptions/', '')
  relativePath = string.gsub(relativePath, '^/', '') -- remove leading slash
  local nameWithoutExt = string.gsub(relativePath, '%.lua$', '')
  local generatorName = string.gsub(nameWithoutExt, '/', '_')

  local extName = 'freeroam_configuratorOptions_' .. generatorName
  table.insert(M.dependencies, extName)
  systemYield()
end

local CONFIG_FILE = "settings/freeroamConfigurator.json"
local version = 1
local fallbackEnvironmentDate = os.time({year = 2026, month = 6, day = 20, hour = 12})

local function getDefaultEnvironmentDate(levelName)
  local optionsExtension = freeroam_configuratorOptions_freeroamOptions
  if optionsExtension and optionsExtension.getDefaultEnvironmentDate then
    return optionsExtension.getDefaultEnvironmentDate(levelName)
  end
  return fallbackEnvironmentDate
end

local navigateToPlayOnFadeout = false
local playNavigationPendingAfterFadeout = false
local worldReadyState = -1

-- Configuration state
local currentConfiguration = {
  levelName = nil,
  spawnPointName = nil,
  options = {},
  vehicle = {
    model = nil,
    config = nil
  },
  spawnPointTile = nil,
  vehicleTile = nil
}

local wizardDefaultPathByStep = {
  level = { keys = { "allFreeroam" } },
  vehicle = { keys = { "allModels" } },
}

local wizardBackendNameByStep = {
  level = "freeroamSelector",
  vehicle = "vehicleSelector",
}

local wizardSearchState = {
  searchByStep = {
    level = "",
    vehicle = "",
  }
}

local wizardFilterState = {
  filtersByStep = {
    level = {},
    vehicle = {},
  }
}

local function isSupportedWizardStep(step)
  return type(step) == "string" and wizardDefaultPathByStep[step] ~= nil
end

local function getDefaultWizardBranchPathForStep(step)
  local defaultPath = wizardDefaultPathByStep[step]
  if type(defaultPath) ~= "table" then
    return { keys = {} }
  end
  return deepcopy(defaultPath)
end

local function normalizeWizardSearchText(searchText)
  if searchText == nil or searchText == "undefined" then
    return ""
  end

  local valueType = type(searchText)
  if valueType == "string" then
    return searchText
  end
  if valueType == "number" or valueType == "boolean" then
    return tostring(searchText)
  end

  return ""
end

local function normalizeWizardFilterValue(value, depth)
  if depth > 12 then
    return nil
  end

  local valueType = type(value)
  if valueType == "string" or valueType == "number" or valueType == "boolean" then
    return value
  end

  if valueType ~= "table" then
    return nil
  end

  local normalizedTable = {}
  for key, childValue in pairs(value) do
    local keyType = type(key)
    if keyType == "string" or keyType == "number" then
      local normalizedChild = normalizeWizardFilterValue(childValue, depth + 1)
      if normalizedChild ~= nil then
        normalizedTable[key] = normalizedChild
      end
    end
  end

  return normalizedTable
end

local function normalizeWizardFiltersPayload(filtersPayload)
  if type(filtersPayload) ~= "table" then
    return {}
  end

  local normalized = normalizeWizardFilterValue(filtersPayload, 0)
  if type(normalized) ~= "table" then
    return {}
  end
  return normalized
end

local function ensureWizardSearchStateDefaults()
  if type(wizardSearchState.searchByStep) ~= "table" then
    wizardSearchState.searchByStep = {}
  end

  for step, _ in pairs(wizardDefaultPathByStep) do
    wizardSearchState.searchByStep[step] = normalizeWizardSearchText(wizardSearchState.searchByStep[step])
  end
end

local function ensureWizardFilterStateDefaults()
  if type(wizardFilterState.filtersByStep) ~= "table" then
    wizardFilterState.filtersByStep = {}
  end

  for step, _ in pairs(wizardDefaultPathByStep) do
    wizardFilterState.filtersByStep[step] = normalizeWizardFiltersPayload(wizardFilterState.filtersByStep[step])
  end
end


-- Save configuration to file
local function saveConfigurationToFile()
  local saveData = deepcopy(currentConfiguration)
  saveData.version = version
  saveData._dirty = nil
  saveData._loaded = nil
  saveData._language = Lua:getSelectedLanguage()

  local success = jsonWriteFile(CONFIG_FILE, saveData, true, nil, true)
  if success then
    log("I", "freeroamConfigurator", "Saved configuration to " .. CONFIG_FILE)
  else
    log("E", "freeroamConfigurator", "Failed to save configuration to " .. CONFIG_FILE)
  end
end

local defaultVehicle = {
  model = "pickup",
  config = "d15_4wd_A",
  additionalData = {
    paint = "Sea Blue",
    paint2 = "Sea Blue",
    paint3 = "Sea Blue"
  }
}
if extensions.tech_license.isValid() then
  defaultVehicle = {
    model = "etk800",
    config = "854_190d_A",
    additionalData = {
      paint = "Mineral Green",
      paint2 = "Mineral Green",
      paint3 = "Mineral Green"
    }
  }
end

local defaultLevelName, defaultSpawnPointName = "west_coast_usa", "spawns_industrial"

local function findSpawnPointByObjectName(level, spawnPointName)
  if type(level) ~= "table" or type(level.spawnPoints) ~= "table" or type(spawnPointName) ~= "string" then
    return nil
  end

  for _, spawnPoint in ipairs(level.spawnPoints) do
    if spawnPoint.objectname == spawnPointName then
      return spawnPoint
    end
  end

  return nil
end

-- Some levels (e.g. Small Grid) only carry an inserted fallback spawnpoint
-- entry that has no `objectname` because the actual scenetree spawn object
-- comes from PlayerDropPoints. Those entries are still identifiable by
-- either matching the level's `defaultSpawnPointName` via `name` or by
-- carrying `flag == "default"`. This helper accepts any of those identities
-- so the wizard/configurator path can resolve them.
local function findSpawnPointByIdentity(level, candidate)
  if type(level) ~= "table" or type(level.spawnPoints) ~= "table" then
    return nil
  end

  local hasCandidate = type(candidate) == "string" and candidate ~= ""
  for _, spawnPoint in ipairs(level.spawnPoints) do
    if hasCandidate and (spawnPoint.objectname == candidate or spawnPoint.name == candidate) then
      return spawnPoint
    end
  end

  return nil
end

local function findFlaggedDefaultSpawnPoint(level)
  if type(level) ~= "table" or type(level.spawnPoints) ~= "table" then
    return nil
  end

  for _, spawnPoint in ipairs(level.spawnPoints) do
    if spawnPoint.flag == "default" then
      return spawnPoint
    end
  end

  return nil
end

local function getSpawnPointIdentity(spawnPoint)
  if type(spawnPoint) ~= "table" then
    return nil
  end
  if type(spawnPoint.objectname) == "string" and spawnPoint.objectname ~= "" then
    return spawnPoint.objectname
  end
  if type(spawnPoint.name) == "string" and spawnPoint.name ~= "" then
    return spawnPoint.name
  end
  return nil
end

local function resolveSpawnPointNameForLevel(levelName, spawnPointName)
  local level = type(levelName) == "string" and core_levels.getLevelByName(levelName) or nil
  if type(level) ~= "table" or type(level.spawnPoints) ~= "table" or #level.spawnPoints == 0 then
    return spawnPointName
  end

  if type(spawnPointName) == "string" and spawnPointName ~= "" and findSpawnPointByIdentity(level, spawnPointName) then
    return spawnPointName
  end

  local levelDefaultName = type(level.defaultSpawnPointName) == "string" and level.defaultSpawnPointName ~= ""
    and level.defaultSpawnPointName or nil
  if levelDefaultName and findSpawnPointByIdentity(level, levelDefaultName) then
    return levelDefaultName
  end

  -- Inserted fallback spawnpoints (e.g. Small Grid) carry only `flag == "default"`
  -- with no `objectname`/`name`. Trust `level.defaultSpawnPointName` in that case
  -- so the scenetree spawn object (loaded from PlayerDropPoints) is still used.
  if levelDefaultName and findFlaggedDefaultSpawnPoint(level) then
    return levelDefaultName
  end

  local firstSpawnPoint = level.spawnPoints[1]
  return getSpawnPointIdentity(firstSpawnPoint)
end

local function hasVehicleConfig(model, config)
  if type(model) ~= "string" or model == "" or type(config) ~= "string" or config == "" then
    return false
  end

  if string.endswith(config, ".pc") and FS:fileExists(config) then
    return true
  end

  return core_vehicles.getConfig(model, config) ~= nil
end

local function getFirstConfigForModel(model)
  local modelData = core_vehicles.getModel(model)
  if type(modelData) ~= "table" or type(modelData.configs) ~= "table" then
    return nil
  end

  for _, configData in pairs(modelData.configs) do
    if type(configData) == "table" and type(configData.key) == "string" and configData.key ~= "" then
      return configData.key
    end
  end

  return nil
end

local function resolveVehicleConfigForModel(model, config)
  if hasVehicleConfig(model, config) then
    return config
  end

  local modelData = core_vehicles.getModel(model)
  local defaultModelConfig = modelData and modelData.model and modelData.model.default_pc or nil
  if hasVehicleConfig(model, defaultModelConfig) then
    return defaultModelConfig
  end

  local firstModelConfig = getFirstConfigForModel(model)
  if hasVehicleConfig(model, firstModelConfig) then
    return firstModelConfig
  end

  if currentConfiguration.vehicle and currentConfiguration.vehicle.model == model and hasVehicleConfig(model, currentConfiguration.vehicle.config) then
    return currentConfiguration.vehicle.config
  end

  return nil
end

local function getSpawnPointTileKey(levelName, spawnPointName)
  if type(levelName) ~= "string" or levelName == "" or type(spawnPointName) ~= "string" or spawnPointName == "" then
    return nil
  end
  return string.format("spawnPoint_%s_%s", levelName, spawnPointName)
end

local function applySpawnPointTileIdentity(tile, levelName, spawnPointName)
  if type(tile) ~= "table" then
    return tile
  end

  tile.key = tile.key or getSpawnPointTileKey(levelName, spawnPointName)
  tile.levelName = levelName
  tile.spawnPointObjectName = spawnPointName
  return tile
end

local function buildLevelValidationFiles(level)
  local validationFiles = {}
  if type(level) ~= "table" then
    return validationFiles
  end
  for _, file in ipairs(level.previews or {}) do
    table.insert(validationFiles, file)
  end
  if level.fullfilename then
    table.insert(validationFiles, level.fullfilename)
  end
  return validationFiles
end

-- Build a minimal spawnpoint tile from level metadata for spawnpoints that
-- only exist as inserted fallbacks (e.g. Small Grid, where the actual spawn
-- object is loaded from PlayerDropPoints rather than `info.spawnPoints`).
-- The gameplaySelector details helper requires a matching `info.spawnPoints`
-- entry with an `objectname`, so we synthesize the small set of fields the
-- freeroam configurator UI actually reads (`headerTitle`, `preview`,
-- `levelTitle`, `description`, `validationFiles`).
local function buildFallbackSpawnPointTile(level, levelName, spawnPointName, spawnPointEntry)
  if type(level) ~= "table" then
    return nil
  end

  local fallbackPreview = nil
  if type(spawnPointEntry) == "table" and type(spawnPointEntry.previews) == "table" then
    fallbackPreview = spawnPointEntry.previews[1]
  end
  if not fallbackPreview and type(level.previews) == "table" then
    fallbackPreview = level.previews[1]
  end

  local headerTitleSource = nil
  if type(spawnPointEntry) == "table" then
    headerTitleSource = spawnPointEntry.translationId or spawnPointEntry.name or spawnPointEntry.objectname
  end
  if not headerTitleSource then
    headerTitleSource = "ui.levelselect.unnamedSpawnpoint"
  end
  local headerTitle = _tr(headerTitleSource)
  if level.title then
    headerTitle = string.format("%s (%s)", headerTitle, _tr(level.title))
  end

  return {
    headerTitle = headerTitle,
    description = level.description and _tr(level.description) or nil,
    preview = fallbackPreview,
    levelTitle = level.title and _tr(level.title) or nil,
    buttonInfo = {},
    tags = {},
    specifications = {},
    validationFiles = buildLevelValidationFiles(level),
  }
end

-- Helper function to fetch spawn point tile data
local function fetchSpawnPointTile(levelName, spawnPointName)
  log("I", "freeroamConfigurator", "fetchSpawnPointTile: levelName=" .. tostring(levelName) .. ", spawnPointName=" .. tostring(spawnPointName))
  local level = core_levels.getLevelByName(levelName)
  if not level then
    log("W", "freeroamConfigurator", "Failed to find level while fetching spawnpoint tile: " .. tostring(levelName))
    return nil
  end

  local resolvedSpawnPointName = resolveSpawnPointNameForLevel(levelName, spawnPointName)
  local spawnPoint = resolvedSpawnPointName and findSpawnPointByIdentity(level, resolvedSpawnPointName) or nil
  if not spawnPoint then
    spawnPoint = findFlaggedDefaultSpawnPoint(level)
  end
  if not spawnPoint then
    log("W", "freeroamConfigurator", "Failed to resolve spawnpoint while fetching tile for level: " .. tostring(levelName) .. "/" .. tostring(resolvedSpawnPointName))
    return nil
  end

  -- The gameplaySelector tile generator only works when the spawnpoint entry
  -- has an `objectname` (it indexes details by `objectname`). For inserted
  -- fallback entries we synthesize a minimal tile from level metadata.
  local canUseGameplaySelectorTile = type(spawnPoint.objectname) == "string" and spawnPoint.objectname ~= ""

  if canUseGameplaySelectorTile then
    local details = {}
    local success = pcall(function()
      ui_gameplaySelector_tileGenerators_levelTiles.onGameplaySelectorGetDetails(
        {levelName = levelName, spawnPointObjectName = resolvedSpawnPointName},
        details, nil, ui_freeroamSelector_general)
    end)

    if not success then
      log("W", "freeroamConfigurator", "Failed to get spawnpoint details: " .. tostring(levelName) .. "/" .. tostring(spawnPointName))
      return nil
    end

    if #details > 0 then
      details[1].validationFiles = buildLevelValidationFiles(level)
      details[1].bottomTags = nil
      return applySpawnPointTileIdentity(details[1], levelName, resolvedSpawnPointName)
    end

    return nil
  end

  local fallbackTile = buildFallbackSpawnPointTile(level, levelName, resolvedSpawnPointName, spawnPoint)
  if not fallbackTile then
    return nil
  end
  log("I", "freeroamConfigurator", "fetchSpawnPointTile: using synthetic fallback tile for level " .. tostring(levelName) .. "/" .. tostring(resolvedSpawnPointName))
  return applySpawnPointTileIdentity(fallbackTile, levelName, resolvedSpawnPointName)
end

-- Helper function to fetch vehicle tile data
local function fetchVehicleTile(model, config, additionalData)
  log("I", "freeroamConfigurator", "fetchVehicleTile: model=" .. tostring(model) .. ", config=" .. tostring(config))
  if not model or not config then
    return nil
  end

  local success, vehicleDetails = pcall(function()
    return ui_vehicleSelector_detailsInteraction.getDetails({model = model, config = config})
  end)

  if not success then
    log("W", "freeroamConfigurator", "Failed to get vehicle details: model=" .. tostring(model) .. ", config=" .. tostring(config))
    return nil
  end

  if vehicleDetails and vehicleDetails.brand then
    vehicleDetails.headerTitle = vehicleDetails.brand .. " " .. vehicleDetails.headerTitle
  end
  if vehicleDetails and additionalData then
    vehicleDetails.additionalData = additionalData
  end

  -- Build validationFiles list for checking if vehicle still exists
  local validationFiles = {}

  -- If config ends in .pc, add it to the list
  if config and string.endswith(config, ".pc") and FS:fileExists(config) then
    table.insert(validationFiles, config)
  end

  local configData = core_vehicles.getConfig(model, config)
  if configData then
    if configData.infoFilename and FS:fileExists(configData.infoFilename) then
      table.insert(validationFiles, configData.infoFilename)
    end
    if configData.pcFilename and FS:fileExists(configData.pcFilename) then
      table.insert(validationFiles, configData.pcFilename)
    end
    if configData.preview and FS:fileExists(configData.preview) then
      table.insert(validationFiles, configData.preview)
    end
  end

  if vehicleDetails then
    vehicleDetails.validationFiles = validationFiles
  end

  return vehicleDetails
end

local function copyTileForRecentGroup(source)
  if type(source) ~= "table" then
    return nil
  end
  local tile = deepcopy(source)
  tile.isClustered = false
  tile.recentIdx = -math.huge
  tile.subElementCount = nil
  tile.gotoPath = nil
  return tile
end

local function makeCurrentSpawnPointRecentTile()
  local currentTile = M.getCurrentSpawnPointTile()
  if type(currentTile) ~= "table" then
    return nil
  end
  local levelName = currentConfiguration.levelName
  local spawnPointName = currentConfiguration.spawnPointName
  if not levelName or not spawnPointName then
    return nil
  end

  local tile = copyTileForRecentGroup(currentTile)
  tile.name = tile.name or tile.headerTitle
  tile.key = tile.key or getSpawnPointTileKey(levelName, spawnPointName)
  tile.showDetails = { levelName = levelName, spawnPointObjectName = spawnPointName, key = tile.key }
  tile.doubleClickDetails = { levelName = levelName, spawnPointObjectName = spawnPointName, key = tile.key }
  tile.system = "freeroam"
  tile.type = "freeroamSpawnpoint"
  tile.cornerIcon = "road"
  tile.levelName = levelName
  tile.spawnPointObjectName = spawnPointName
  tile.validBackends = { freeroamSelector = true, gameplaySelector = false }
  return tile
end

local function makeCurrentVehicleRecentTile()
  local currentTile = M.getCurrentVehicleTile()
  if type(currentTile) ~= "table" then
    return nil
  end
  local vehicle = currentConfiguration.vehicle or {}
  local model = vehicle.model
  local config = vehicle.config
  if not model or not config then
    return nil
  end

  local tile = copyTileForRecentGroup(currentTile)
  tile.name = tile.name or tile.headerTitle
  tile.key = tile.key or string.format("%s/%s", model, config)
  tile.model = model
  tile.config = config
  tile.model_key = model
  tile.config_key = config
  tile.cornerIcon = "car"
  tile.showDetails = { model = model, config = config }
  tile.doubleClickDetails = { model = model, config = config }
  return tile
end

function M.getCurrentSelectionRecentTile(step)
  return step == "level" and makeCurrentSpawnPointRecentTile()
    or step == "vehicle" and makeCurrentVehicleRecentTile()
    or nil
end

function M.isCurrentSelection(step, details)
  if step == "level" then
    return details.levelName == currentConfiguration.levelName
      and details.spawnPointObjectName == currentConfiguration.spawnPointName
  end
  if step == "vehicle" then
    local vehicle = currentConfiguration.vehicle or {}
    return details.model == vehicle.model and details.config == vehicle.config
  end
  return false
end

local cachedDefaultSpawnPointTile
local cachedDefaultVehicleTile
local function getDefaultTiles()
  if not cachedDefaultSpawnPointTile then
    cachedDefaultSpawnPointTile = fetchSpawnPointTile(defaultLevelName, defaultSpawnPointName)
  end
  if not cachedDefaultVehicleTile then
    cachedDefaultVehicleTile = fetchVehicleTile(defaultVehicle.model, defaultVehicle.config, defaultVehicle.additionalData)
  end
  return cachedDefaultSpawnPointTile, cachedDefaultVehicleTile
end

-- Load configuration from file
local function loadConfigurationFromFile()
  local data = jsonReadFile(CONFIG_FILE)
  if data and data.version ~= version then
    log("I", "freeroamConfigurator", "Configuration file version mismatch, loading defaults")
    data = nil
  end
  if data then
    -- Merge loaded data with defaults
    if data.levelName then currentConfiguration.levelName = data.levelName end
    if data.spawnPointName then currentConfiguration.spawnPointName = data.spawnPointName end
    if data.vehicle and data.vehicle.model then currentConfiguration.vehicle.model = data.vehicle.model end
    if data.vehicle and data.vehicle.config then currentConfiguration.vehicle.config = data.vehicle.config end
    if data.vehicle and data.vehicle.additionalData then currentConfiguration.vehicle.additionalData = data.vehicle.additionalData end
    if data.options then currentConfiguration.options = data.options end
    if currentConfiguration.options.environment_date == fallbackEnvironmentDate then
      currentConfiguration.options.environment_date = getDefaultEnvironmentDate(currentConfiguration.levelName)
    end
    if data._language then currentConfiguration._language = data._language end
    if currentConfiguration._language == Lua:getSelectedLanguage() then
      -- Load cached tiles
      if data.spawnPointTile then currentConfiguration.spawnPointTile = data.spawnPointTile end
      if data.vehicleTile then currentConfiguration.vehicleTile = data.vehicleTile end
    end
    log("I", "freeroamConfigurator", "Loaded configuration from " .. CONFIG_FILE)
  else
    log("I", "freeroamConfigurator", "No existing configuration file found: " .. CONFIG_FILE)
    currentConfiguration = {
      levelName = defaultLevelName,
      spawnPointName = defaultSpawnPointName,
      options = {
        environment_timeOfDay = "default",
        environment_date = getDefaultEnvironmentDate(defaultLevelName),
        environment_timePlay = "disabled",
        traffic_trafficMode = "disabled"
      },
      vehicle = defaultVehicle,
      spawnPointTile = nil,
      vehicleTile = nil
    }
    -- Cache default tiles
    local defaultSpawnPointTile, defaultVehicleTile = getDefaultTiles()
    currentConfiguration.spawnPointTile = defaultSpawnPointTile
    currentConfiguration.vehicleTile = defaultVehicleTile
    saveConfigurationToFile()
  end
end


-- Get current freeroam configuration
M.getConfiguration = function()
  -- Load configuration from file on first access
  if not currentConfiguration._loaded then
    loadConfigurationFromFile()
    currentConfiguration._loaded = true
  end



  local levelName = currentConfiguration.levelName or "gridmap_v2"
  local level = core_levels.getLevelByName(levelName) or {}

  -- Get configuration options from extensions
  local options = {}
  extensions.hook("onFreeroamConfiguratorGetOptions", level, options)
  table.sort(options, function(a, b) return (a.order or math.huge) < (b.order or math.huge) end)

  -- Update option values with current configuration
  for _, group in ipairs(options) do
    if group.key then
      if currentConfiguration.options[group.key] == nil then
        currentConfiguration.options[group.key] = group.value
      end
      group.value = currentConfiguration.options[group.key]
    end
    if group.options then
      for _, option in ipairs(group.options) do
        if option.key then
          if currentConfiguration.options[option.key] == nil then
            currentConfiguration.options[option.key] = option.value
          end
          option.value = currentConfiguration.options[option.key]
        end
      end
    end
  end

  return {
    options = options,
    currentSpawnPoint = M.getCurrentSpawnPointTile(),
    currentVehicle = M.getCurrentVehicleTile(),
  }
end

M.getButtons = function()
  buttonModule.clearButtonFunctions()

  buttonModule.addButton(M.startFreeroam, {
    label = _tr("ui.freeroam.startFreeroam"),
    priority = 1,
  })

  extensions.hook("onFreeroamConfiguratorOverrideStartButton", buttonModule, currentConfiguration)
  local buttonsInfos = buttonModule.getAllButtonInfos()
  local buttons = {}
  for _, buttonInfo in pairs(buttonsInfos) do
    table.insert(buttons, buttonInfo)
  end
  table.sort(buttons, function(a, b)
    local priorityA = a.meta and a.meta.priority or 0
    local priorityB = b.meta and b.meta.priority or 0
    return priorityA > priorityB
  end)
  return buttons[1]
end

M.triggerButton = function(buttonId, ...)
  if currentConfiguration._dirty then
    saveConfigurationToFile()
  end
  -- Notify extensions about the option update
  extensions.hook("onFreeroamConfiguratorApplyOptions", currentConfiguration.options)

  buttonModule.executeButton(buttonId, currentConfiguration)
end

M.doubleClickOverride = function(item)
  dump(item)
end


-- Update configuration option
M.updateOption = function(key, value)
  currentConfiguration.options[key] = value
  currentConfiguration._dirty = true
end

M.setWizardSearchForStep = function(step, searchText)
  if not isSupportedWizardStep(step) then
    log("W", "freeroamConfigurator", "setWizardSearchForStep: Unsupported step: " .. tostring(step))
    return false
  end

  ensureWizardSearchStateDefaults()
  wizardSearchState.searchByStep[step] = normalizeWizardSearchText(searchText)
  return true
end

M.getWizardSearchForStep = function(step)
  if not isSupportedWizardStep(step) then
    return nil
  end

  ensureWizardSearchStateDefaults()
  return wizardSearchState.searchByStep[step]
end

M.clearWizardSearchForStep = function(step)
  if not isSupportedWizardStep(step) then
    return false
  end

  ensureWizardSearchStateDefaults()
  wizardSearchState.searchByStep[step] = ""
  return true
end

M.setWizardFiltersForStep = function(step, filtersPayload)
  if not isSupportedWizardStep(step) then
    log("W", "freeroamConfigurator", "setWizardFiltersForStep: Unsupported step: " .. tostring(step))
    return false
  end

  ensureWizardFilterStateDefaults()
  wizardFilterState.filtersByStep[step] = normalizeWizardFiltersPayload(filtersPayload)
  return true
end

M.getWizardFiltersForStep = function(step)
  if not isSupportedWizardStep(step) then
    return nil
  end

  ensureWizardFilterStateDefaults()
  return deepcopy(wizardFilterState.filtersByStep[step])
end

M.clearWizardFiltersForStep = function(step)
  if not isSupportedWizardStep(step) then
    return false
  end

  ensureWizardFilterStateDefaults()
  wizardFilterState.filtersByStep[step] = {}
  return true
end

local function isWizardVehicleSelectionRoute(route)
  local routeName = route and route.name or nil
  local screenId = route and route.screenId or nil
  local isWizardVehicleConfigRoute = routeName == "menu.freeroamLevels.vehicles.vehicle"
    or routeName == "pause.freeroamLevels.vehicles.vehicle"
    or screenId == "freeroamLevels.vehicles.vehicle"
  local isWizardVehiclesRoute = routeName == "menu.freeroamLevels.vehicles"
    or routeName == "pause.freeroamLevels.vehicles"
    or screenId == "freeroamLevels.vehicles"
  return isWizardVehicleConfigRoute or isWizardVehiclesRoute
end

local function getWizardSelectionSegment(value)
  if value == nil or value == "undefined" then
    return nil
  end

  local valueType = type(value)
  local segment = nil
  if valueType == "string" then
    segment = value
  elseif valueType == "number" or valueType == "boolean" then
    segment = tostring(value)
  end

  if segment == nil or segment == "" then
    return nil
  end
  return segment
end

local function getWizardLevelDetailPathFromSelection()
  local levelName = getWizardSelectionSegment(currentConfiguration.levelName)
  if not levelName then
    return getDefaultWizardBranchPathForStep("level")
  end
  return { keys = { "spawnPointsForLevel", levelName } }
end

-- Normalize a path payload coming from route params. Accepts the canonical
-- `{ keys = {...} }` shape, a raw keys array, or nil. Returns nil when the
-- payload does not yield at least one usable key so callers can fall back to
-- selection-derived paths.
local function normalizeWizardRouteDetailPath(rawPath)
  local keysSource = nil
  if type(rawPath) == "table" then
    if type(rawPath.keys) == "table" then
      keysSource = rawPath.keys
    elseif rawPath[1] ~= nil then
      keysSource = rawPath
    end
  end
  if type(keysSource) ~= "table" then
    return nil
  end

  local normalizedKeys = {}
  for _, key in ipairs(keysSource) do
    local segment = getWizardSelectionSegment(key)
    if segment then
      table.insert(normalizedKeys, segment)
    end
  end
  if #normalizedKeys == 0 then
    return nil
  end
  return { keys = normalizedKeys }
end

-- Prefer a route-supplied path for the wizard level detail route (e.g. when a
-- Recent/Favourites clustered tile passes `{ path = { keys = ... } }` through
-- navigate params), and fall back to the current selection path otherwise.
local function getWizardLevelDetailPathForRoute(route)
  local routeParams = type(route) == "table" and route.params or nil
  if type(routeParams) == "table" then
    local fromParams = normalizeWizardRouteDetailPath(routeParams.path)
      or normalizeWizardRouteDetailPath(routeParams)
    if fromParams then
      return fromParams
    end
  end
  return getWizardLevelDetailPathFromSelection()
end

local function getWizardVehicleDetailPathFromSelection()
  local model = getWizardSelectionSegment(currentConfiguration.vehicle and currentConfiguration.vehicle.model)
  if not model then
    return getDefaultWizardBranchPathForStep("vehicle")
  end
  return { keys = { "configsForModel", model } }
end

-- Vehicle paths use empty strings as positional placeholders (e.g.
-- `{"configsForBrandSubModelOrModel", model, "", ""}`); stripping them via
-- normalizeWizardRouteDetailPath() would shift the subModel/brand/groupMode
-- slots in tiles.lua. This variant preserves empties and only drops nil /
-- "undefined" entries.
local function normalizeWizardVehicleRouteDetailPath(rawPath)
  local keysSource = nil
  if type(rawPath) == "table" then
    if type(rawPath.keys) == "table" then
      keysSource = rawPath.keys
    elseif rawPath[1] ~= nil then
      keysSource = rawPath
    end
  end
  if type(keysSource) ~= "table" then
    return nil
  end

  local normalizedKeys = {}
  for _, key in ipairs(keysSource) do
    if key == nil or key == "undefined" then
      table.insert(normalizedKeys, "")
    elseif type(key) == "string" then
      table.insert(normalizedKeys, key)
    elseif type(key) == "number" or type(key) == "boolean" then
      table.insert(normalizedKeys, tostring(key))
    end
  end
  if #normalizedKeys == 0 then
    return nil
  end
  return { keys = normalizedKeys }
end

local function isVehicleDetailPathKeys(keys)
  if type(keys) ~= "table" or #keys < 2 then
    return false
  end
  local pathType = keys[1]
  if pathType ~= "configsForBrandSubModelOrModel" and pathType ~= "configsForModel" then
    return false
  end
  -- A meaningful vehicle drilldown must carry a model key in slot 2.
  local modelKey = keys[2]
  return type(modelKey) == "string" and modelKey ~= ""
end

-- Prefer a route-supplied path for the wizard vehicle detail route (e.g. when
-- a cluster tile passes `{ path = { keys = gotoPath } }` through navigate
-- params), and fall back to the current selection path otherwise. Mirrors
-- getWizardLevelDetailPathForRoute(): cluster drilldowns must hydrate the
-- snapshot for the clicked model rather than for the currently selected one.
-- Returns `(path, fromRouteParams)` so callers can decide whether to suppress
-- the current-selection override on the destination route.
local function getWizardVehicleDetailPathForRoute(route)
  local routeParams = type(route) == "table" and route.params or nil
  if type(routeParams) == "table" then
    local fromParams = normalizeWizardVehicleRouteDetailPath(routeParams.path)
      or normalizeWizardVehicleRouteDetailPath(routeParams)
    if fromParams and isVehicleDetailPathKeys(fromParams.keys) then
      return fromParams, true
    end
  end
  return getWizardVehicleDetailPathFromSelection(), false
end

local function buildWizardRouteData(data, route, pathByStepOverrides, options)
  if type(data) ~= "table" then
    return
  end

  if not currentConfiguration._loaded then
    loadConfigurationFromFile()
    currentConfiguration._loaded = true
  end

  ensureWizardSearchStateDefaults()
  ensureWizardFilterStateDefaults()

  -- Cluster drilldown routes pass `suppressVehicleSelectionOverride = true` so
  -- we don't pin the previously selected config as default-selected for an
  -- unrelated model. Without this, navigating into a cluster whose preview
  -- happens to match the previously chosen config would steal focus from the
  -- model's actual default config in tiles.lua.
  local suppressVehicleSelectionOverride = type(options) == "table"
    and options.suppressVehicleSelectionOverride == true
  local selectedVehicle = currentConfiguration.vehicle or {}
  if not suppressVehicleSelectionOverride
    and isWizardVehicleSelectionRoute(route)
    and selectedVehicle.model
    and selectedVehicle.config
    and ui_vehicleSelector_tiles
    and ui_vehicleSelector_tiles.overrideDefaultSelectedTile then
    ui_vehicleSelector_tiles.overrideDefaultSelectedTile({
      model_key = selectedVehicle.model,
      key = selectedVehicle.config,
    })
  end

  local pathByStep = {
    level = getDefaultWizardBranchPathForStep("level"),
    vehicle = getDefaultWizardBranchPathForStep("vehicle"),
  }
  if type(pathByStepOverrides) == "table" then
    for step, path in pairs(pathByStepOverrides) do
      if isSupportedWizardStep(step) and type(path) == "table" then
        pathByStep[step] = deepcopy(path)
      end
    end
  end

  data.freeroamWizard = {
    selection = {
      levelName = currentConfiguration.levelName,
      spawnPointName = currentConfiguration.spawnPointName,
      vehicle = deepcopy(currentConfiguration.vehicle),
    },
    uiState = {
      pathByStep = pathByStep,
      searchByStep = deepcopy(wizardSearchState.searchByStep),
      filtersByStep = deepcopy(wizardFilterState.filtersByStep),
    },
  }
end

M.onWizardLevelsRouteEnter = function(context, toRoute, fromRoute, data)
  buildWizardRouteData(data, toRoute, {
    level = getDefaultWizardBranchPathForStep("level"),
  })
end

M.onWizardVehiclesRouteEnter = function(context, toRoute, fromRoute, data)
  buildWizardRouteData(data, toRoute, {
    vehicle = getDefaultWizardBranchPathForStep("vehicle"),
  })
end

M.onWizardLevelDetailRouteEnter = function(context, toRoute, fromRoute, data)
  buildWizardRouteData(data, toRoute, {
    level = getWizardLevelDetailPathForRoute(toRoute),
  })
end

M.onWizardVehicleDetailRouteEnter = function(context, toRoute, fromRoute, data)
  local detailPath, fromRouteParams = getWizardVehicleDetailPathForRoute(toRoute)
  buildWizardRouteData(data, toRoute, {
    vehicle = detailPath,
  }, {
    suppressVehicleSelectionOverride = fromRouteParams,
  })
end

M.onWizardRouteEnter = function(context, toRoute, fromRoute, data)
  buildWizardRouteData(data, toRoute)
end

-- Breadcrumb title resolvers. Receive the full route `params` table (no
-- `paramKey` set in the route config), so we can inspect `params.path.keys`
-- from the wizard's drilldown navigations as well as fall back to the
-- currently selected level/vehicle in `currentConfiguration`.
local function titleIsNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

local function getRouteParamsPathKeys(params)
  if type(params) ~= "table" then return nil end
  local path = params.path
  if type(path) ~= "table" then return nil end
  local keys = path.keys
  if type(keys) ~= "table" then return nil end
  return keys
end

local function resolveLevelTitleFromName(levelName)
  if not titleIsNonEmptyString(levelName) then return nil end
  local level = core_levels.getLevelByName(levelName)
  if type(level) == "table" and titleIsNonEmptyString(level.title) then
    return _tr(level.title)
  end
  return levelName
end

local function buildVehicleTitleFromModelKey(modelKey)
  if not titleIsNonEmptyString(modelKey) then return nil end
  local model = core_vehicles.getModel(modelKey)
  local modelData = model and model.model or nil
  if type(modelData) ~= "table" then
    return modelKey
  end
  local brand = titleIsNonEmptyString(modelData.Brand) and modelData.Brand or nil
  local subModel = titleIsNonEmptyString(modelData.SubModel) and modelData.SubModel or nil
  local name = titleIsNonEmptyString(modelData.Name) and modelData.Name or modelKey
  if brand and subModel then
    return brand .. " " .. subModel
  end
  if brand then
    return brand .. " " .. name
  end
  if subModel then
    return subModel
  end
  return name
end

M.resolveSelectedLevelTitle = function(params)
  -- Prefer the route's drilldown path (level detail routes navigate with
  -- `{ path = { keys = { "spawnPointsForLevel", levelName, ... } } }`).
  local pathKeys = getRouteParamsPathKeys(params)
  if pathKeys and pathKeys[1] == "spawnPointsForLevel" then
    local routeTitle = resolveLevelTitleFromName(pathKeys[2])
    if titleIsNonEmptyString(routeTitle) then
      return routeTitle
    end
  end

  -- Fall back to the currently selected level (committed via setSpawnPoint).
  local tile = currentConfiguration.spawnPointTile
  if type(tile) == "table" and titleIsNonEmptyString(tile.levelTitle) then
    return tile.levelTitle
  end

  return resolveLevelTitleFromName(currentConfiguration.levelName)
end

M.resolveSelectedVehicleTitle = function(params)
  -- Prefer the route's drilldown path. Freeroam vehicle cluster drilldown is
  -- navigation-only (no setVehicle call), so the route params are the source
  -- of truth for which model the user is browsing.
  local pathKeys = getRouteParamsPathKeys(params)
  if pathKeys
    and (pathKeys[1] == "configsForBrandSubModelOrModel" or pathKeys[1] == "configsForModel")
    and titleIsNonEmptyString(pathKeys[2]) then
    local routeTitle = buildVehicleTitleFromModelKey(pathKeys[2])
    if titleIsNonEmptyString(routeTitle) then
      return routeTitle
    end
  end

  -- Fall back to the cached selected vehicle tile.
  local tile = currentConfiguration.vehicleTile
  if type(tile) == "table" and titleIsNonEmptyString(tile.headerTitle) then
    return tile.headerTitle
  end

  -- Last resort: derive from the selected vehicle model key.
  local vehicle = currentConfiguration.vehicle
  if type(vehicle) == "table" then
    return buildVehicleTitleFromModelKey(vehicle.model)
  end

  return nil
end

local function getWizardBackendForStep(step)
  if not isSupportedWizardStep(step) then
    return nil
  end
  local backendName = wizardBackendNameByStep[step]
  if type(backendName) ~= "string" or backendName == "" then
    return nil
  end
  local backend = ui_gridSelector and ui_gridSelector.getBackendByName and ui_gridSelector.getBackendByName(backendName)
  if type(backend) ~= "table" then
    return nil
  end
  return backend, backendName
end

local function captureWizardSearchAndFiltersFromBackend(step)
  local _, backendName = getWizardBackendForStep(step)
  if not backendName then
    return false
  end

  ensureWizardSearchStateDefaults()
  ensureWizardFilterStateDefaults()

  if not (ui_gridSelector and type(ui_gridSelector.getSelectorSnapshotSlices) == "function") then
    return false
  end

  -- Search and filters are owned by the generic grid selector backend. Route
  -- transitions must read that live state, not replay a separate route cache.
  local ok, snapshotOrErr = pcall(ui_gridSelector.getSelectorSnapshotSlices, backendName, getDefaultWizardBranchPathForStep(step), {
    filters = true,
    searchText = true,
  })
  if not ok then
    log("E", "freeroamConfigurator",
      string.format("Failed to capture wizard %s selector state: %s", tostring(step), tostring(snapshotOrErr)))
    return false
  end

  local snapshot = snapshotOrErr
  wizardSearchState.searchByStep[step] = normalizeWizardSearchText(snapshot and snapshot.searchText)
  local filters = type(snapshot) == "table" and snapshot.filters or nil
  wizardFilterState.filtersByStep[step] = {
    filterByProp = type(filters) == "table" and deepcopy(filters.filterByProp or {}) or {}
  }
  return true
end

local function shouldResetVehicleFiltersOnStart()
  if not (ui_vehicleSelector_general and type(ui_vehicleSelector_general.getDisplayData) == "function") then
    return false
  end

  local ok, displayData = pcall(ui_vehicleSelector_general.getDisplayData)
  return ok and type(displayData) == "table" and displayData.filterResetOnSpawn == true
end

local function clearWizardSelectorFiltersForStart()
  if not (ui_gridSelector and type(ui_gridSelector.clearAllFilters) == "function") then
    return
  end

  pcall(ui_gridSelector.clearAllFilters, "freeroamSelector")
  captureWizardSearchAndFiltersFromBackend("level")

  if shouldResetVehicleFiltersOnStart() then
    pcall(ui_gridSelector.clearAllFilters, "vehicleSelector")
  end
  captureWizardSearchAndFiltersFromBackend("vehicle")
end

local function buildWizardStepSnapshot(step, path)
  local _, backendName = getWizardBackendForStep(step)
  if not backendName then
    return nil
  end

  local resolvedPath
  if type(path) == "table" and type(path.keys) == "table" then
    resolvedPath = { keys = deepcopy(path.keys) }
  else
    resolvedPath = getDefaultWizardBranchPathForStep(step)
  end

  if not (ui_gridSelector and type(ui_gridSelector.getSelectorSnapshot) == "function") then
    return nil
  end

  local ok, snapshotOrErr = pcall(ui_gridSelector.getSelectorSnapshot, backendName, resolvedPath)
  if not ok then
    log("E", "freeroamConfigurator",
      string.format("Failed to build wizard %s snapshot: %s", tostring(step), tostring(snapshotOrErr)))
    return nil
  end

  return {
    backendName = backendName,
    path = resolvedPath,
    snapshot = snapshotOrErr,
  }
end

-- Find the initial tile to show details for after the snapshot is built.
-- Prefer the tile flagged isDefaultSelected by the backend's tile generators
-- and fall back to the first tile that exposes a usable showDetails payload.
-- Mirrors ui_vehicleSelector_general.findInitialDetailsTile so the wizard
-- vehicle step can emit an initial details push at route-mount time.
local function findInitialDetailsTile(snapshot)
  if type(snapshot) ~= "table" or type(snapshot.groups) ~= "table" then
    return nil
  end
  local fallback = nil
  for _, group in ipairs(snapshot.groups) do
    if type(group) == "table" and type(group.tiles) == "table" then
      for _, tile in ipairs(group.tiles) do
        if type(tile) == "table" and type(tile.showDetails) == "table" then
          if tile.isDefaultSelected then
            return tile
          end
          if not fallback then
            fallback = tile
          end
        end
      end
    end
  end
  return fallback
end

-- Emit an initial details payload for the given step's initial tile so the
-- Vue side can preselect details on first mount of the wizard route, without
-- requiring a user focus action. Only the vehicle step currently has a
-- backend `requestDetails` that emits `vehicleSelectorDetails`; the level
-- step's initial details are owned by the freeroam selector backend.
local function emitInitialWizardStepDetails(step, stepSnapshot)
  if step ~= "vehicle" then return end
  if type(stepSnapshot) ~= "table" or type(stepSnapshot.snapshot) ~= "table" then return end
  local initialTile = findInitialDetailsTile(stepSnapshot.snapshot)
  if not initialTile then return end
  if not (ui_vehicleSelector_general and type(ui_vehicleSelector_general.requestDetails) == "function") then
    return
  end
  local ok, errDetails = pcall(ui_vehicleSelector_general.requestDetails, initialTile)
  if not ok then
    log("E", "freeroamConfigurator",
      string.format("Failed to emit vehicleSelectorDetails for initial wizard vehicle tile: %s", tostring(errDetails)))
  end
end

local function attachWizardStepSnapshot(data, step, path)
  if type(data) ~= "table" or not isSupportedWizardStep(step) then
    return
  end

  local stepSnapshot = buildWizardStepSnapshot(step, path)
  if not stepSnapshot then
    return
  end

  if type(data.freeroamWizard) ~= "table" then
    data.freeroamWizard = {}
  end
  if type(data.freeroamWizard.gridSnapshots) ~= "table" then
    data.freeroamWizard.gridSnapshots = {}
  end
  data.freeroamWizard.gridSnapshots[step] = stepSnapshot

  -- Keep the backend's current selector path aligned with the wizard route's
  -- snapshot path so later emitDisplayDataSnapshot calls (e.g. from Display
  -- controls) rebuild against the same path instead of falling back to stale
  -- state owned by other routes.
  local backend = getWizardBackendForStep(step)
  if backend and type(backend.setCurrentSelectorPath) == "function" then
    pcall(backend.setCurrentSelectorPath, stepSnapshot.path)
  end

  emitInitialWizardStepDetails(step, stepSnapshot)
end

-- Tracks the most recent wizard level/vehicle route mount while async loading
-- is in progress. Captured at onWizardLevels*RouteMount /
-- onWizardVehicles*RouteMount and consumed by asyncLevelLoadComplete /
-- asyncVehicleLoadComplete so the snapshot we emit matches the route the user
-- actually navigated to (guards against stale completions firing for a
-- navigation that has since been replaced).
local pendingLevelRouteMount = nil
local pendingVehicleRouteMount = nil

local function describeWizardPathForLog(path)
  if type(path) ~= "table" or type(path.keys) ~= "table" then
    return "nil"
  end
  return table.concat(path.keys, "/")
end

local function isPendingRouteStillCurrent(pending)
  if type(pending) ~= "table" then
    return false
  end
  if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
    or type(extensions.ui_router.getCurrent) ~= "function" then
    return true
  end
  local currentEntry = extensions.ui_router.getCurrent()
  local currentName = currentEntry and currentEntry.resolved and currentEntry.resolved.name or nil
  if not currentName then
    return true
  end
  return currentName == pending.routeName
end

local function emitFreeroamSelectorDataLoaded(step, pending)
  if type(pending) ~= "table" or not isSupportedWizardStep(step) then
    return false
  end

  captureWizardSearchAndFiltersFromBackend(step)

  local stepSnapshot = buildWizardStepSnapshot(step, pending.path)
  if not stepSnapshot then
    return false
  end

  -- Mirror attachWizardStepSnapshot: align backend's current path with the
  -- snapshot path so later emitDisplayDataSnapshot calls rebuild correctly.
  local backend = getWizardBackendForStep(step)
  if backend and type(backend.setCurrentSelectorPath) == "function" then
    pcall(backend.setCurrentSelectorPath, stepSnapshot.path)
  end

  -- Vehicle step also emits an initial details payload so the Vue side can
  -- preselect VehicleDetails on cold loads without requiring a focus action.
  -- Mirrors the sync `attachWizardStepSnapshot` path.
  emitInitialWizardStepDetails(step, stepSnapshot)

  local backendName = wizardBackendNameByStep[step]
  -- print(string.format(
  --   "[freeroamConfigurator] emitting FreeroamSelectorDataLoaded step=%s backend=%s route=%s path=%s",
  --   tostring(step), tostring(backendName),
  --   tostring(pending.routeName), describeWizardPathForLog(pending.path)
  -- ))

  guihooks.trigger("FreeroamSelectorDataLoaded", {
    backendName = backendName,
    routeName = pending.routeName,
    snapshot = stepSnapshot,
  })
  return true
end

-- Defer the snapshot build/emit off the route mount + transition path so the
-- wizard route can paint first and the Vue grid selector shows its loading
-- state before the (potentially heavy) snapshot is built. Mirrors the async
-- completion path so warm and cold-but-already-loaded loads behave identically
-- from the UI's perspective: route mount stays cheap and the grid hydrates
-- from FreeroamSelectorDataLoaded. Stale navigations are discarded before
-- emitting (the user may have navigated away during the one-tick defer).
local function scheduleDeferredSnapshotEmit(step, pending)
  if type(pending) ~= "table" or not isSupportedWizardStep(step) then
    return false
  end

  if type(core_jobsystem) ~= "table" or type(core_jobsystem.create) ~= "function" then
    log("W", "freeroamConfigurator", "core_jobsystem unavailable; emitting snapshot synchronously")
    return emitFreeroamSelectorDataLoaded(step, pending)
  end

  core_jobsystem.create(function(job)
    job.sleep(0)
    if not isPendingRouteStillCurrent(pending) then
      -- print(string.format(
      --   "[freeroamConfigurator] deferred %s snapshot skipped for stale route=%s",
      --   tostring(step), tostring(pending.routeName)
      -- ))
      return
    end
    emitFreeroamSelectorDataLoaded(step, pending)
  end, 1/30)

  return true
end

local function beginAsyncLevelRouteMount(routeName, path)
  pendingLevelRouteMount = {
    routeName = routeName,
    path = path,
  }

  -- print(string.format(
  --   "[freeroamConfigurator] beginAsyncLevelRouteMount route=%s path=%s",
  --   tostring(routeName), describeWizardPathForLog(path)
  -- ))

  if type(extensions) ~= "table" or type(extensions.util_asyncBulkLoader) ~= "table"
    or type(extensions.util_asyncBulkLoader.loadLevels) ~= "function" then
    log("W", "freeroamConfigurator", "util_asyncBulkLoader.loadLevels unavailable; deferring snapshot emit")
    local snapshotPending = pendingLevelRouteMount
    pendingLevelRouteMount = nil
    scheduleDeferredSnapshotEmit("level", snapshotPending)
    return
  end

  local result = extensions.util_asyncBulkLoader.loadLevels()
  if result == "alreadyLoaded" then
    -- print("[freeroamConfigurator] levels already loaded; deferring snapshot emit")
    local snapshotPending = pendingLevelRouteMount
    pendingLevelRouteMount = nil
    scheduleDeferredSnapshotEmit("level", snapshotPending)
  end
end

local function beginAsyncVehicleRouteMount(routeName, path, options)
  pendingVehicleRouteMount = {
    routeName = routeName,
    path = path,
    suppressVehicleSelectionOverride = type(options) == "table"
      and options.suppressVehicleSelectionOverride == true or false,
  }

  -- print(string.format(
  --   "[freeroamConfigurator] beginAsyncVehicleRouteMount route=%s path=%s",
  --   tostring(routeName), describeWizardPathForLog(path)
  -- ))

  if type(extensions) ~= "table" or type(extensions.util_asyncBulkLoader) ~= "table"
    or type(extensions.util_asyncBulkLoader.loadVehicles) ~= "function" then
    log("W", "freeroamConfigurator", "util_asyncBulkLoader.loadVehicles unavailable; deferring snapshot emit")
    local snapshotPending = pendingVehicleRouteMount
    pendingVehicleRouteMount = nil
    scheduleDeferredSnapshotEmit("vehicle", snapshotPending)
    return
  end

  local result = extensions.util_asyncBulkLoader.loadVehicles()
  if result == "alreadyLoaded" then
    -- print("[freeroamConfigurator] vehicles already loaded; deferring snapshot emit")
    local snapshotPending = pendingVehicleRouteMount
    pendingVehicleRouteMount = nil
    scheduleDeferredSnapshotEmit("vehicle", snapshotPending)
  end
end

-- Listens for the asyncBulkLoader completion hook so we can build and emit the
-- freeroam selector level snapshot only after the heavy data is ready. The
-- pending route is compared against the active router entry to discard stale
-- completions caused by rapid route changes.
function M.asyncLevelLoadComplete()
  local pending = pendingLevelRouteMount
  if type(pending) ~= "table" then
    return
  end
  pendingLevelRouteMount = nil

  if not isPendingRouteStillCurrent(pending) then
    -- print(string.format(
    --   "[freeroamConfigurator] async level load completed for stale route=%s; skipping snapshot emit",
    --   tostring(pending.routeName)
    -- ))
    return
  end

  emitFreeroamSelectorDataLoaded("level", pending)
end

-- Mirrors M.asyncLevelLoadComplete for the vehicle step. Hooked from
-- util_asyncBulkLoader.loadVehicles via extensions.hook("asyncVehicleLoadComplete").
function M.asyncVehicleLoadComplete()
  local pending = pendingVehicleRouteMount
  if type(pending) ~= "table" then
    return
  end
  pendingVehicleRouteMount = nil

  if not isPendingRouteStillCurrent(pending) then
    -- print(string.format(
    --   "[freeroamConfigurator] async vehicle load completed for stale route=%s; skipping snapshot emit",
    --   tostring(pending.routeName)
    -- ))
    return
  end

  emitFreeroamSelectorDataLoaded("vehicle", pending)
end

-- For the level step we never attach a synchronous snapshot to route data.
-- When the level list is already loaded we still defer the snapshot build/emit
-- by one tick (scheduleDeferredSnapshotEmit) so the wizard route paints with
-- the grid selector's loading state first, then hydrates from
-- FreeroamSelectorDataLoaded. Cold loads kick off the async loader and rely on
-- asyncLevelLoadComplete to emit the snapshot.
local function attachOrDeferLevelSnapshot(data, toRoute, levelPath)
  local routeName = toRoute and toRoute.name or nil
  local levelsAlreadyLoaded = type(extensions) == "table"
    and type(extensions.util_asyncBulkLoader) == "table"
    and type(extensions.util_asyncBulkLoader.isLevelsLoaded) == "function"
    and extensions.util_asyncBulkLoader.isLevelsLoaded()

  if levelsAlreadyLoaded then
    -- Warm load: discard any stale pending cold completion and defer the
    -- snapshot emit. The snapshot build now reads the current grid selector
    -- backend state instead of replaying stale route-local search/filter data.
    -- run inside scheduleDeferredSnapshotEmit -> emitFreeroamSelectorDataLoaded.
    pendingLevelRouteMount = nil
    scheduleDeferredSnapshotEmit("level", { routeName = routeName, path = levelPath })
    return
  end

  -- Start (or queue) async loading. The snapshot will be emitted via
  -- FreeroamSelectorDataLoaded once loading completes. We intentionally do not
  -- attach a synchronous snapshot to route data: the Vue level grid composable
  -- treats the missing initial snapshot as a loading state and hydrates from
  -- the async completion payload.
  beginAsyncLevelRouteMount(routeName, levelPath)
end

-- Mirrors attachOrDeferLevelSnapshot for the vehicle step. We never attach a
-- synchronous snapshot to route data. When vehicle data is already loaded we
-- still defer the snapshot build/emit by one tick so the wizard route paints
-- with the grid selector's loading state first, then hydrates from
-- FreeroamSelectorDataLoaded. Cold loads kick off the async vehicle loader and
-- let asyncVehicleLoadComplete emit the snapshot.
local function attachOrDeferVehicleSnapshot(data, toRoute, vehiclePath, options)
  local routeName = toRoute and toRoute.name or nil
  local vehiclesAlreadyLoaded = type(extensions) == "table"
    and type(extensions.util_asyncBulkLoader) == "table"
    and type(extensions.util_asyncBulkLoader.isVehiclesLoaded) == "function"
    and extensions.util_asyncBulkLoader.isVehiclesLoaded()

  if vehiclesAlreadyLoaded then
    -- Warm load: discard any stale pending cold completion and defer the
    -- snapshot emit. The suppressVehicleSelectionOverride flag was already
    -- applied during buildWizardRouteData on this mount, so the deferred emit
    -- only needs the resolved path.
    pendingVehicleRouteMount = nil
    scheduleDeferredSnapshotEmit("vehicle", {
      routeName = routeName,
      path = vehiclePath,
      suppressVehicleSelectionOverride = type(options) == "table"
        and options.suppressVehicleSelectionOverride == true or false,
    })
    return
  end

  -- Cold load: skip attaching `data.freeroamWizard.gridSnapshots.vehicle`. The
  -- Vue vehicle grid composable treats the missing snapshot as a loading state
  -- and hydrates from the FreeroamSelectorDataLoaded event once the async
  -- vehicle loader finishes.
  beginAsyncVehicleRouteMount(routeName, vehiclePath, options)
end

M.onWizardLevelsRouteMount = function(context, toRoute, fromRoute, data)
  local levelPath = getDefaultWizardBranchPathForStep("level")
  buildWizardRouteData(data, toRoute, {
    level = levelPath,
  })
  attachOrDeferLevelSnapshot(data, toRoute, levelPath)
end

M.onWizardLevelDetailRouteMount = function(context, toRoute, fromRoute, data)
  local detailPath = getWizardLevelDetailPathForRoute(toRoute)
  buildWizardRouteData(data, toRoute, {
    level = detailPath,
  })
  attachOrDeferLevelSnapshot(data, toRoute, detailPath)
end

M.onWizardVehiclesRouteMount = function(context, toRoute, fromRoute, data)
  local vehiclePath = getDefaultWizardBranchPathForStep("vehicle")
  buildWizardRouteData(data, toRoute, {
    vehicle = vehiclePath,
  })
  attachOrDeferVehicleSnapshot(data, toRoute, vehiclePath)
end

M.onWizardVehicleDetailRouteMount = function(context, toRoute, fromRoute, data)
  local detailPath, fromRouteParams = getWizardVehicleDetailPathForRoute(toRoute)
  buildWizardRouteData(data, toRoute, {
    vehicle = detailPath,
  }, {
    suppressVehicleSelectionOverride = fromRouteParams,
  })
  attachOrDeferVehicleSnapshot(data, toRoute, detailPath, {
    suppressVehicleSelectionOverride = fromRouteParams,
  })
end


-- Set level for configuration
M.setSpawnPoint = function(levelName, spawnPointName, key)
  local previousLevelName = currentConfiguration.levelName
  local dateUsesLevelDefault = currentConfiguration.options.environment_date == getDefaultEnvironmentDate(previousLevelName)
    or currentConfiguration.options.environment_date == fallbackEnvironmentDate
  local resolvedSpawnPointName = resolveSpawnPointNameForLevel(levelName, spawnPointName)
  if resolvedSpawnPointName ~= spawnPointName then
    log("I", "freeroamConfigurator", "setSpawnPoint: resolved spawnpoint fallback from " .. tostring(spawnPointName) .. " to " .. tostring(resolvedSpawnPointName) .. " for level " .. tostring(levelName))
  end

  currentConfiguration.levelName = levelName
  if levelName ~= previousLevelName and dateUsesLevelDefault then
    currentConfiguration.options.environment_date = getDefaultEnvironmentDate(levelName)
  end
  if resolvedSpawnPointName == 'undefined' then
    resolvedSpawnPointName = nil
  end
  currentConfiguration.spawnPointName = resolvedSpawnPointName

  -- Fetch and cache the tile data
  currentConfiguration.spawnPointTile = fetchSpawnPointTile(levelName, resolvedSpawnPointName)

  currentConfiguration._dirty = true
end


M.validateFiles = function(validationFiles)
  if not validationFiles then
    return true
  end
  for _, file in ipairs(validationFiles) do
    -- check if file is a directory or a file
    if string.match(file, "[^/]+%.[%w]+$") then
      if not FS:fileExists(file) then
        return false
      end
    else
      if not FS:directoryExists(file) then
        return false
      end
    end
  end
  return true
end

-- Get current spawnpoint tile data
M.getCurrentSpawnPointTile = function()
  -- Validate that the level/spawnPoint still exists
  if currentConfiguration.spawnPointTile and not M.validateFiles(currentConfiguration.spawnPointTile.validationFiles) then
    log("W", "freeroamConfigurator", "Spawnpoint validation failed, fetching tile")
    local defaultSpawnPointTile = getDefaultTiles()
    currentConfiguration.spawnPointTile = defaultSpawnPointTile
    currentConfiguration._dirty = true
    currentConfiguration.levelName = defaultLevelName
    currentConfiguration.spawnPointName = defaultSpawnPointName
    applySpawnPointTileIdentity(
      currentConfiguration.spawnPointTile,
      currentConfiguration.levelName,
      currentConfiguration.spawnPointName
    )
  end

  -- Return cached tile if available, if not fetch tile
  if currentConfiguration.spawnPointTile then
    applySpawnPointTileIdentity(
      currentConfiguration.spawnPointTile,
      currentConfiguration.levelName,
      currentConfiguration.spawnPointName
    )
    return currentConfiguration.spawnPointTile
  end

  -- Fallback: fetch tile if cache is missing (e.g., after loading old config)
  local levelName = currentConfiguration.levelName
  local spawnPointName = currentConfiguration.spawnPointName

  if not levelName then
    return nil
  end

  local tile = fetchSpawnPointTile(levelName, spawnPointName)
  if tile then
    currentConfiguration.spawnPointTile = tile
    currentConfiguration._dirty = true
  end

  -- If fetch failed, try default
  if not tile then
    log("W", "freeroamConfigurator", "Failed to get spawnpoint details: " .. tostring(levelName) .. "/" .. tostring(spawnPointName) .. ", defaulting to " .. tostring(defaultLevelName) .. "/" .. tostring(defaultSpawnPointName))
    currentConfiguration.levelName = defaultLevelName
    currentConfiguration.spawnPointName = defaultSpawnPointName
    currentConfiguration._dirty = true

    tile = fetchSpawnPointTile(defaultLevelName, defaultSpawnPointName)
    if tile then
      currentConfiguration.spawnPointTile = tile
    end
  end

  return tile
end

-- Get current vehicle tile data
M.getCurrentVehicleTile = function()
  -- Validate that the vehicle still exists
  if currentConfiguration.vehicleTile and not M.validateFiles(currentConfiguration.vehicleTile.validationFiles) then
    log("W", "freeroamConfigurator", "Vehicle validation failed, fetching tile")
    local _, defaultVehicleTile = getDefaultTiles()
    currentConfiguration.vehicleTile = defaultVehicleTile
    currentConfiguration._dirty = true
    currentConfiguration.vehicle.model = defaultVehicle.model
    currentConfiguration.vehicle.config = defaultVehicle.config
    currentConfiguration.vehicle.additionalData = defaultVehicle.additionalData
  end

  -- Return cached tile if available
  if currentConfiguration.vehicleTile then
    return currentConfiguration.vehicleTile
  end

  -- Fallback: fetch tile if cache is missing (e.g., after loading old config)
  local model = currentConfiguration.vehicle.model
  local config = currentConfiguration.vehicle.config
  local additionalData = currentConfiguration.vehicle.additionalData

  if not model or not config then
    return nil
  end

  local tile = fetchVehicleTile(model, config, additionalData)
  if tile then
    currentConfiguration.vehicleTile = tile
    currentConfiguration._dirty = true
  end

  -- If fetch failed, try default
  if not tile then
    log("W", "freeroamConfigurator", "Failed to get vehicle details: " .. dumps(currentConfiguration.vehicle) .. ", defaulting to pickup")
    currentConfiguration.vehicle = deepcopy(defaultVehicle)
    currentConfiguration._dirty = true

    tile = fetchVehicleTile(defaultVehicle.model, defaultVehicle.config, defaultVehicle.additionalData)
    if tile then
      currentConfiguration.vehicleTile = tile
    end
  end

  return tile
end

-- Set vehicle
M.setVehicle = function(model, config, additionalData, key)
  local resolvedConfig = resolveVehicleConfigForModel(model, config)
  if resolvedConfig ~= config then
    log("I", "freeroamConfigurator", "setVehicle: resolved config fallback from " .. tostring(config) .. " to " .. tostring(resolvedConfig) .. " for model " .. tostring(model))
  end

  local sameVehicle = currentConfiguration.vehicle.model == model and currentConfiguration.vehicle.config == resolvedConfig
  local additionalDataIsEmpty = not additionalData or (type(additionalData) == "table" and next(additionalData) == nil)
  if sameVehicle and additionalDataIsEmpty then
    additionalData = currentConfiguration.vehicle.additionalData
  elseif not additionalData then
    additionalData = { }
  end

  currentConfiguration.vehicle.model = model
  currentConfiguration.vehicle.config = resolvedConfig
  currentConfiguration.vehicle.additionalData = additionalData

  -- Fetch and cache the tile data
  currentConfiguration.vehicleTile = fetchVehicleTile(model, resolvedConfig, additionalData)

  currentConfiguration._dirty = true
end

-- Get current vehicle
M.getCurrentVehicle = function()
  return currentConfiguration.vehicle
end

-- Stub click handlers
M.onSpawnPointTileClick = function()
  -- print("onSpawnPointTileClick")
  ui_freeroamSelector_general.openFreeroamSelectorForFreeroamConfigurator(function(levelName, spawnPointName)
    M.setSpawnPoint(levelName, spawnPointName)
    guihooks.trigger("ChangeState", "menu.freeroamconfigurator")
  end)
end

M.onVehicleTileClick = function()
  ui_vehicleSelector_general.openVehicleSelectorForFreeroamConfigurator(function(model, config, additionalData)
    M.setVehicle(model, config, additionalData)
    guihooks.trigger("ChangeState", "menu.freeroamconfigurator")
  end)
end

M.onLanguageChanged = function()
  cachedDefaultSpawnPointTile = nil
  cachedDefaultVehicleTile = nil
  currentConfiguration.spawnPointTile = nil
  currentConfiguration.vehicleTile = nil
end

M.onSerialize = function()
  if currentConfiguration._dirty then
    saveConfigurationToFile()
  end
  return currentConfiguration
end

M.onDeserialized = function(data)
  currentConfiguration = data
  currentConfiguration._dirty = false
end


M.startFreeroam = function(configuration)

  local options = {
    config = configuration.vehicle.config,
  }
  if configuration.vehicle.additionalData then
    local model = core_vehicles.getModel(configuration.vehicle.model)
    if model and model.model then
      options.paint = model.model.paints[configuration.vehicle.additionalData.paint]
      options.paint2 = model.model.paints[configuration.vehicle.additionalData.paint2]
      options.paint3 = model.model.paints[configuration.vehicle.additionalData.paint3]
    end
  end

  navigateToPlayOnFadeout = true
  local started = freeroam_freeroam.startFreeroamByName(configuration.levelName, configuration.spawnPointName, nil, { configuration.vehicle.model, options})
  if not started then
    navigateToPlayOnFadeout = false
    playNavigationPendingAfterFadeout = false
    return
  end
  local spawnPointKey = configuration.spawnPointTile and configuration.spawnPointTile.key
    or getSpawnPointTileKey(configuration.levelName, configuration.spawnPointName)
  if spawnPointKey then
    ui_freeroamSelector_general.trackRecent(spawnPointKey)
  end
  if configuration.vehicle and configuration.vehicle.model and configuration.vehicle.config then
    ui_vehicleSelector_general.trackRecentVehicle(configuration.vehicle.model, configuration.vehicle.config)
  end
  clearWizardSelectorFiltersForStart()
end

local function tryNavigateToPlayAfterLoad()
  if not playNavigationPendingAfterFadeout then
    return
  end
  if worldReadyState ~= 2 then
    return
  end
  if core_gamestate.loading() then
    return
  end
  playNavigationPendingAfterFadeout = false
  extensions.ui_router.navigate("play")
end

M.onLoadingScreenFadeout = function()
  if navigateToPlayOnFadeout then
    navigateToPlayOnFadeout = false
    playNavigationPendingAfterFadeout = true
    tryNavigateToPlayAfterLoad()
  end
end

M.onWorldReadyState = function(state)
  worldReadyState = state
  if state == 2 then
    tryNavigateToPlayAfterLoad()
  end
end

M.onUpdate = function()
  tryNavigateToPlayAfterLoad()
end

return M
