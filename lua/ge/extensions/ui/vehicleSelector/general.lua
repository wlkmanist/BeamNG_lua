local M = {}
M.dependencies = {
  "core_vehicles",
  "ui_vehicleSelector_detailsInteraction",
  "ui_vehicleSelector_tiles",
  "core_locales"
  --"ui_vehicleSelector_vehicleMetadataEditor"
}
local customRootPath = {}
local openedFromGarage = false
local spawnOnly = false
-- Load the modules
local displayDataModule = require("ge/extensions/ui/gridSelectorUtils/displayDataModule")
local filterModule = require("ge/extensions/ui/gridSelectorUtils/filterModule")
local propName = function(key) return _tr("ui.vehicles.propName." .. key, key) end
local propValue = function(propName, key) return core_locales.translateWithPrefixFallback(key, "ui.vehicles.propValue." .. propName .. ".") end
local filterOptionLabel = function(propKey, value)
  if propKey == "Source" and value == "Custom" then
    return _tr("ui.garage.tabs.load")
  end
  return propValue(propKey, value)
end
local othersText = nil
local othersValue = "__other__"
-- Backend name for this selector
local backendName = "vehicleSelector"

local defaultDisplayDataOptions, displayDataInstance, filterInstance

-- Hard vehicle-type restriction applied on top of the normal filter system,
-- used by callers the lightRunner/busRoute oneshot race wizards. nil means
-- "no restriction" (default behavior).
local activeRestrictionMode = nil
M.setVehicleRestrictionMode = function(restrictionMode)
  activeRestrictionMode = restrictionMode
end

-- Normalized spawn-only accessors. setSpawnOnly(nil/false/other) always
-- restores normal behavior, so callers can pass options.spawnOnly directly.
local function setSpawnOnly(value)
  spawnOnly = value == true
end
M.setSpawnOnly = setSpawnOnly

local function isSpawnOnly()
  return spawnOnly == true
end
M.isSpawnOnly = isSpawnOnly

local function setupInstances()
  -- print("setupInstances")
  othersText = _tr("ui.menu.gridSelector.other")
  -- Default display data options for vehicle selector
  defaultDisplayDataOptions = {
    {
      label = _tr("ui.menu.gridSelector.displayOptions.groupBy.title"),
      key = "groupMode",
      default = "Type",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.groupBy.description"),
      save = true,
      showInModes = {default = true, filter = true, displayControls = true},
      options = {
        {label = propName("Type"), value = "Type"},
        {label = propName("Brand"), value = "Brand"},
        {label = propName("Country"), value = "Country"},
        {label = propName("Config Type"), value = "Config Type"},
        {label = propName("Derby Class"), value = "Derby Class"},
        {label = propName("Body Style"), value = "Body Style"},
        {label = propName("Years"), value = "Years"},
        {label = propName("Value"), value = "Value"},
        {label = propName("Source"), value = "Source"},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.sortBy.title"),
      key = "sortMode",
      default = "Automatic",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.sortBy.description"),
      save = true,
      showInModes = {default = true, filter = true, displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.sortBy.automatic"), value = "Automatic"},
        {label = propName("Name"), value = "Name"},
        {label = propName("Value"), value = "Value"},
        {label = propName("Weight"), value = "Weight"},
        {label = propName("Top Speed"), value = "Top Speed"},
        {label = propName("Power"), value = "Power"},
        {label = propName("Weight/Power"), value = "Weight/Power"},
        {label = propName("0-60 mph"), value = "0-60 mph"},
        {label = propName("0-100 km/h"), value = "0-100 km/h"},
      },
    },
    {
      label = _tr("ui.menu.vehicleSelector.displayOptions.clusterBy.title"),
      key = "clusterMode",
      default = "model",
      type = "dropdown",
      description = _tr("ui.menu.vehicleSelector.displayOptions.clusterBy.description"),
      save = false,
      showInModes = {displayControls = false},
      options = {
        {label = "Brand/Model", value = "brandSubModelOrModel"},
        {label = "Legacy (Model)", value = "model"},
      },
    },
    {
      label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.title"),
      key = "expandGroups",
      default = 0,
      type = "dropdown",
      description = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.never"), value = 0},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.singleConfig"), value = 1},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.groupsOf2"), value = 2},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.groupsOf3"), value = 3},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.groupsOf4"), value = 4},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.groupsOf5"), value = 5},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.expandGroups.always"), value = 999},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displaySize.title"),
      key = "displaySize",
      default = "medium",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displaySize.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displaySize.list"), value = "list"},
        {label = _tr("ui.menu.gridSelector.displaySize.tiny"), value = "tiny"},
        {label = _tr("ui.menu.gridSelector.displaySize.small"), value = "small"},
        {label = _tr("ui.menu.gridSelector.displaySize.medium"), value = "medium"},
        {label = _tr("ui.menu.gridSelector.displaySize.large"), value = "large"},
        {label = _tr("ui.menu.gridSelector.displaySize.huge"), value = "huge"},
      },
    },
    {
      label = _tr("ui.menu.vehicleSelector.displayOptions.filterResetOnSpawn.title"),
      key = "filterResetOnSpawn",
      default = false,
      type = "checkbox",
      description = _tr("ui.menu.vehicleSelector.displayOptions.filterResetOnSpawn.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.vehicleSelector.displayOptions.filterResetOnSpawn.reset"), value = true},
        {label = _tr("ui.menu.vehicleSelector.displayOptions.filterResetOnSpawn.keep"), value = false},
      },
    },
    {
      label = core_locales.contextTranslate("ui.menu.gridSelector.displayOptions.recentSelections.titleContext", {context = _tr("ui.menu.vehicleSelector.title")}),
      key = "showRecentMode",
      default = "unclustered",
      type = "dropdown",
      description = core_locales.contextTranslate("ui.menu.gridSelector.displayOptions.recentSelections.descriptionContext", {context = _tr("ui.menu.vehicleSelector.title")}),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.clusterOptions.hidden"), value = "hidden"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.reducedClusters"), value = "reducedClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.completeClusters"), value = "completeClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.unclustered"), value = "unclustered"},
      },
    },
    {
      label = core_locales.contextTranslate("ui.menu.gridSelector.displayOptions.recentSelections.titleContext", {context = _tr("ui.menu.freeroamSelector.wizard.vehicle")}),
      key = "showRecentModeFreeroamSelector",
      default = "unclustered",
      type = "dropdown",
      description = core_locales.contextTranslate("ui.menu.gridSelector.displayOptions.recentSelections.descriptionContext", {context = _tr("ui.menu.freeroamSelector.title")}),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.clusterOptions.reducedClusters"), value = "reducedClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.completeClusters"), value = "completeClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.unclustered"), value = "unclustered"},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.favourites.title"),
      key = "showFavouritesMode",
      default = "unclustered",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.favourites.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.clusterOptions.hidden"), value = "hidden"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.reducedClusters"), value = "reducedClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.completeClusters"), value = "completeClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.unclustered"), value = "unclustered"},
      },
    },
    {
      label = _tr("ui.menu.vehicleSelector.displayOptions.includeDefaultConfigInFavourites.title"),
      key = "includeDefaultConfigInFavourites",
      default = false,
      type = "checkbox",
      description = _tr("ui.menu.vehicleSelector.displayOptions.includeDefaultConfigInFavourites.description"),
      hideInSimpleMenu = true,
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.included"), value = true},
        {label = _tr("ui.menu.gridSelector.displayOptions.excluded"), value = false},
      },
    },
    {
      label = _tr("ui.menu.vehicleSelector.displayOptions.showCustomPCFiles.title"),
      key = "showCustomPCFiles",
      default = true,
      type = "checkbox",
      description = _tr("ui.menu.vehicleSelector.displayOptions.showCustomPCFiles.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.included"), value = true},
        {label = _tr("ui.menu.gridSelector.displayOptions.excluded"), value = false},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.includeAuxContent.title"),
      key = "showAuxContent",
      default = true,
      hidden = false,
      hideInSimpleMenu = true,
      type = "checkbox",
      description = _tr("ui.menu.gridSelector.displayOptions.includeAuxContent.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.included"), value = true},
        {label = _tr("ui.menu.gridSelector.displayOptions.excluded"), value = false},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.includeDevInfo.title"),
      key = "includeDevInfo",
      default = false,
      type = "checkbox",
      hideInSimpleMenu = true,
      description = _tr("ui.menu.gridSelector.displayOptions.includeDevInfo.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.show"), value = true},
        {label = _tr("ui.menu.gridSelector.displayOptions.hide"), value = false},
      },
    },
  }

  -- Update display data function for vehicle selector
  local function updateDisplayData(data, version, targetVersion)
    local existingExpandGroups = data.expandGroups
    local existingClusterMode = data.clusterMode
    local existingShowFavouritesMode = data.showFavouritesMode
    local existingShowRecentMode = data.showRecentMode
    local existingShowRecentModeFreeroamSelector = data.showRecentModeFreeroamSelector
    local existingFilterResetOnSpawn = data.filterResetOnSpawn
    while version < targetVersion do
      version = version + 1
      if version == 2 then
        data.expandGroups = existingExpandGroups ~= nil and existingExpandGroups or 0
        data.clusterMode = existingClusterMode ~= nil and existingClusterMode or "brandSubModelOrModel"
      elseif version == 3 then
        data.showFavouritesMode = existingShowFavouritesMode ~= nil and existingShowFavouritesMode or "completeClusters"
        data.showRecentMode = existingShowRecentMode ~= nil and existingShowRecentMode or "completeClusters"
      elseif version == 8 then
        data.clusterMode = existingClusterMode ~= nil and existingClusterMode or "model"
      elseif version == 9 then
        data.filterResetOnSpawn = existingFilterResetOnSpawn ~= nil and existingFilterResetOnSpawn or false
      elseif version == 11 then
        data.showRecentModeFreeroamSelector = existingShowRecentModeFreeroamSelector
          or existingShowRecentMode
          or data.showRecentMode
          or "completeClusters"
      end
    end
    log("I", "", "Display data updated to version " .. tostring(version))
    return data
  end

  -- Create display data instance for vehicle selector
  displayDataInstance = displayDataModule.create("/settings/vehicleSelectorData.json", defaultDisplayDataOptions, updateDisplayData, backendName, 11)

  -- Vehicle-specific filter configuration
  local filtersWhiteList = {
    "Drivetrain",
    "Config Type",
    "Body Style",
    "Transmission",
    "Weight",
    "Top Speed",
    "0-100 km/h",
    "0-60 mph",
    "Power",
    "Torque",
    "Weight/Power",
    "Years",
    "Value",
    "Brand",
    "Country",
    "Region",
    "Source",
    "Type",
    "Derby Class",
    "Performance Class",
    "Off-Road Score",
    'Propulsion',
    'Fuel Type',
    'Induction Type',
    'Commercial Class',
    --"Character Tags",
    --"Use",
  }

  local rangeFilters = tableValuesAsLookupDict({
    "Value",
    "Weight",
    "Top Speed",
    "0-100 km/h",
    "0-60 mph",
    "Power",
    "Torque",
    "Weight/Power",
    "Off-Road Score",
    "Years",
  })

  local dictFilters = tableValuesAsLookupDict({
    --"Character Tags",
    --"Use",
    "Region",
  })

  local commonFilters = {
    {"Source", "Custom", _tr("ui.garage.tabs.load")},
    {"Type", "Car"},
    {"Type", "Truck"},
    {"Type", "Heavy Machinery"},
    {"Type", "Trailer"},
    {"Type", "Prop"},
    {"Drivetrain", "4WD"},
    {"Drivetrain", "RWD"},
    {"Drivetrain", "FWD"},
    {"Drivetrain", "AWD"},
    {"Config Type", "Factory"},
    {"Config Type", "Drift"},
    {"Config Type", "Rally"},
    {"Config Type", "Race"},
    {"Config Type", "Police"},
    {"Config Type", "Service"},
    {"Transmission", "Manual"},
    {"Transmission", "Automatic"},
    {"Transmission", "Sequential"},
    --{"Source", "BeamNG - Official"},
  }
  for i, filter in ipairs(commonFilters) do
    local propKey, optionValue, optionLabel = filter[1], filter[2], filter[3]
    commonFilters[i] = {
      propName(propKey),
      optionValue,
      optionLabel or filterOptionLabel(propKey, optionValue),
    }
  end

  -- Vehicle-specific filter creation function
  local function createVehicleFilters(configList)
    local filterByProp = {}

    if configList then
      for _, config in pairs(configList) do
        for _, propKey in pairs(filtersWhiteList) do
          local propName = propName(propKey)
          local propVal = config[propKey]
          if propVal ~= nil then
            if rangeFilters[propKey] then
              local min, max = propVal, propVal
              if type(propVal) == 'table' then
                min = propVal.min
                max = propVal.max
              end
              if type(min) == 'number' and type(max) == 'number' then
                if not filterByProp[propName] then
                  filterByProp[propName] = {
                    min = min,
                    max = max,
                  }
                end
                filterByProp[propName].min = math.min(min, filterByProp[propName].min)
                filterByProp[propName].max = math.max(max, filterByProp[propName].max)
              end
            elseif dictFilters[propKey] then
              if not filterByProp[propName] then
                filterByProp[propName] = {}
              end
              for value, active in pairs(propVal or {}) do
                if active then
                  filterByProp[propName][value] = true
                end
              end
            else
              if not filterByProp[propName] then
                filterByProp[propName] = {}
              end

              if propVal ~= 'Powerglow' then
                --exclude powerglow for filters
                filterByProp[propName][propVal] = true
              end
            end
          end
        end
      end
    end

    local filterUiData = {}
    for _, propKey in pairs(filtersWhiteList) do
      local propName = propName(propKey)
      if filterByProp[propName] then
        local filterData = {
          propName = propName,
          propKey = propKey,
          options = {}
        }
        if filterByProp[propName].min and filterByProp[propName].max then
          filterData.type = 'range'
          filterData.min = filterByProp[propName].min
          filterData.max = filterByProp[propName].max
        else
          filterData.type = 'set'
          for _, key in ipairs(tableKeysSorted(filterByProp[propName])) do
            table.insert(filterData.options, {value = key, label = filterOptionLabel(propKey, key)})
          end
          table.insert(filterData.options, {value = othersValue, label = othersText})
          filterByProp[propName][othersValue] = true
        end
        table.insert(filterUiData, filterData)
      end
    end

    return filterUiData, filterByProp
  end

  -- Vehicle-specific passesFilters function
  local function vehiclePassesFilters(itemData, validFilters, searchText)
    local model = core_vehicles.getModel(itemData.model).model
    local config = core_vehicles.getConfig(itemData.model, itemData.config)
    local configOrModel = config or model -- this is the case if no config exist (standalone pc)
    if not config then
      log("W","",string.format("No config found for model: %s, config: %s", itemData.model, itemData.config))
    end
    if not displayDataInstance.getDisplayData().showCustomPCFiles and (not config.infoFilename) then
      return false
    end
    if not displayDataInstance.getDisplayData().showAuxContent and (configOrModel.isAuxiliary or model.missingJbeamFiles) then
      return false
    end

    if activeRestrictionMode == "lightRunner" then
      -- lightRunner only offers powerglow-equipped cars/trucks { key: ["powerglow"], Type: ["Car", "Truck"] }`)
      if configOrModel['Config Type'] ~= 'Powerglow' then
        return false
      end
      local vehicleType = configOrModel.Type or model.Type
      if vehicleType ~= "Car" and vehicleType ~= "Truck" then
        return false
      end
    elseif activeRestrictionMode == "busRoute" then
      -- busRoute only offers transit buses { "Body Style": ["Bus"], "Commercial Class": ["Transit Bus"] }`)
      local bodyStyle = configOrModel['Body Style'] or model['Body Style']
      local commercialClass = configOrModel['Commercial Class'] or model['Commercial Class']
      if bodyStyle ~= "Bus" or commercialClass ~= "Transit Bus" then
        return false
      end
    elseif configOrModel['Config Type'] == 'Powerglow' then
      -- explicitly exclude powerglow configs
      return false
    end

    if searchText and searchText ~= "" then
      local searchTextLower = string.lower(searchText)
      local configNameLower = string.lower(configOrModel.Name or "")
      local modelNameLower = string.lower(model.Name or "")
      local fileNameLower = string.lower(configOrModel.infoFilename or "")
      local combinedSearchTextLower = string.lower(table.concat({
        configOrModel.Brand or model.Brand or "",
        model.Name or "",
        configOrModel.Name or "",
        configOrModel.Configuration or "",
        configOrModel.infoFilename or "",
      }, " "))
      local match = false
      for _, propKey in ipairs(filtersWhiteList) do
        local propVal = configOrModel[propKey]
        if propVal == nil then
          propVal = model[propKey]
        end
        if type(propVal) == "string" then
          propVal = propValue(propKey, propVal)
        end
        if type(propVal) == 'string' then
          if string.find(string.lower(propVal), searchTextLower, 1, true) then
            match = true
            break
          end
        end
        if match then
          break
        end
      end
      match = match
        or string.find(configNameLower, searchTextLower, 1, true)
        or string.find(modelNameLower, searchTextLower, 1, true)
        or string.find(fileNameLower, searchTextLower, 1, true)
        or string.find(combinedSearchTextLower, searchTextLower, 1, true)
      if not match then
        return false
      end
    end

    -- Use the pre-computed valid filters passed as parameter

    for _, filter in ipairs(validFilters) do
      local propVal = configOrModel[filter.propKey]
      if propVal == nil then
        propVal = model[filter.propKey]
      end
      if propVal == nil then
        propVal = dictFilters[filter.propKey] and {[othersValue] = true} or othersValue
      end
      if dictFilters[filter.propKey] then
        local matchesAny = false
        for value, active in pairs(propVal or {}) do
          if filter.currentFilterValues[value] then
            matchesAny = true
            break
          end
        end
        if not matchesAny then
          return false
        end
      elseif filter.type == 'set' then
        for _, option in pairs(filter.options) do
          if propVal == option.value and not filter.currentFilterValues[option.value] then
            return false
          end
        end
      elseif filter.type == 'range' then
        if propVal == othersValue or not type(propVal) == 'number' then
          return false
        end
        if type(propVal) == 'table' then
          if (propVal.min and propVal.min < filter.currentMin) or (propVal.max and propVal.max > filter.currentMax) then
            return false
          end
          if (filter.currentMin > filter.min and not propVal.min) or (filter.currentMax < filter.max and not propVal.max) then
            return false
          end
        else
          if (propVal < filter.currentMin) or (propVal > filter.currentMax) then
            return false
          end
        end
      end
    end
    return true
  end

  -- Create filter instance for vehicle selector
  filterInstance = filterModule.create(createVehicleFilters, commonFilters, rangeFilters, dictFilters, backendName, vehiclePassesFilters)
end

local function ensureInstances()
  if not displayDataInstance then
    setupInstances()
  end
end

local function emptyProfiler()
  return {
    start = function() end,
    add = function() end,
    finish = function() end,
  }
end
M.emptyProfiler = emptyProfiler
M.p = emptyProfiler()
--M.p = LuaProfiler("vehicleSelector Profiler")
--[[
  M.p = LuaProfiler("vehicleSelector Profiler")
  ]]
-- Vehicle data storage
local uiData = nil
local displayData = nil

local FREEROAM_VEHICLE_SELECTOR_ROUTE_NAMES = {
  ["freeroamLevels.vehicles"] = true,
  ["freeroamLevels.vehicles.vehicle"] = true,
  ["freeroamWizard.vehicles"] = true,
  ["freeroamWizard.vehicles.vehicle"] = true,
  ["menu.freeroamLevels.vehicles"] = true,
  ["menu.freeroamLevels.vehicles.vehicle"] = true,
  ["pause.freeroamLevels.vehicles"] = true,
  ["pause.freeroamLevels.vehicles.vehicle"] = true,
}

local FREEROAM_VEHICLE_SELECTOR_SCREEN_IDS = {
  ["freeroamLevels.vehicles"] = true,
  ["freeroamLevels.vehicles.vehicle"] = true,
  ["freeroamWizard.vehicles"] = true,
  ["freeroamWizard.vehicles.vehicle"] = true,
}

local function isFreeroamVehicleSelectorRoute(route)
  if type(route) ~= "table" then
    return false
  end
  return FREEROAM_VEHICLE_SELECTOR_ROUTE_NAMES[route.name] == true
    or FREEROAM_VEHICLE_SELECTOR_ROUTE_NAMES[route.routeName] == true
    or FREEROAM_VEHICLE_SELECTOR_SCREEN_IDS[route.screenId] == true
end

local function isFreeroamVehicleSelectorContext()
  if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
    or type(extensions.ui_router.getCurrent) ~= "function" then
    return false
  end

  local currentEntry = extensions.ui_router.getCurrent()
  return isFreeroamVehicleSelectorRoute(currentEntry)
    or isFreeroamVehicleSelectorRoute(currentEntry and currentEntry.resolved)
    or isFreeroamVehicleSelectorRoute(currentEntry and currentEntry.request)
end
M.isFreeroamVehicleSelectorContext = isFreeroamVehicleSelectorContext

local function copyDisplayData(source)
  local result = {}
  if type(source) == "table" then
    for key, value in pairs(source) do
      result[key] = value
    end
  end
  return result
end

local function getEffectiveDisplayData()
  ensureInstances()
  local source = displayData or displayDataInstance.getDisplayData()
  if not isFreeroamVehicleSelectorContext() then
    return source
  end

  local result = copyDisplayData(source)
  result.showRecentMode = source.showRecentModeFreeroamSelector or source.showRecentMode
  return result
end

local function getContextDisplayDataOptions()
  ensureInstances()
  local isFreeroamSelector = isFreeroamVehicleSelectorContext()
  local result = {}
  for _, option in ipairs(displayDataInstance.getDisplayDataOptions()) do
    local key = option.key
    local shouldHide = (isFreeroamSelector and key == "showRecentMode")
      or (not isFreeroamSelector and key == "showRecentModeFreeroamSelector")
    if not shouldHide then
      table.insert(result, option)
    end
  end
  return result
end

M.getDisplayData = function()
  return getEffectiveDisplayData()
end
-- Initialize vehicle data from core module
local function initializeVehicleData()
  setupInstances()
  local p = M.emptyProfiler()
  --p = LuaProfiler("initializeVehicleData")
  p:start()
  local uiData = {}
  -- Get fresh display data from the module instance


  uiData = {
    models = {},
    configs = {},
    filterList = {},
    activeFilters = {}, -- Currently applied filters
    lockedFiltersByProp = {}, -- Locked filters that cannot be modified
    displayData = M.getDisplayData(),
  }
  local modelList, configList, modelAndConfigList = {}, {}, {}
  p:add("displayData")
  for modelName, _ in pairs(core_vehicles.getModelsData()) do
    table.insert(modelList, core_vehicles.getModel(modelName).model)
    table.insert(modelAndConfigList, core_vehicles.getModel(modelName).model)
    for _, config in pairs(core_vehicles.getModel(modelName).configs or {}) do
      table.insert(configList, config)
      table.insert(modelAndConfigList, config)
    end
  end
  p:add("vehicle and config list")
  filterInstance.initializeFilters(modelAndConfigList)
  local filterData = filterInstance.getFilters()
  uiData.filterList = filterData.filterList
  uiData.filterByProp = filterData.filterByProp
  uiData.lockedFiltersByProp = filterData.lockedFiltersByProp

  uiData.activeFilters, uiData.onlyCommonFilters = filterInstance.calculateActiveFilters()
  p:add("filterList")
  -- Update uiData
  uiData.models = modelList
  uiData.configs = configList
  uiData.displayInfo = core_vehicles.displayInfo
  p:add("uiData finished")
  p:finish(true)
  return uiData
end
local vehicleDataChanged = false
M.onModDeactivated = function()
  vehicleDataChanged = true
  displayData = nil
end
M.onModActivated = function()
  vehicleDataChanged = true
  displayData = nil
end
M.onModManagerReady = function()
  vehicleDataChanged = true
  displayData = nil
end
M.onModManagerStateChanged = function()
  vehicleDataChanged = true
  displayData = nil
end
M.clearCache = function()
  vehicleDataChanged = true
  displayData = nil
end
M.onLanguageChanged = function()
  vehicleDataChanged = true
  displayData = nil
end

-- default vehicle utility
local pathDefaultConfig = "settings/default.pc"
local defaultVehicleInfo = nil
local function onFileChanged(filename, type)
  if filename == pathDefaultConfig then
    defaultVehicleInfo = nil
  end
end
M.onfilechanged = onFileChanged

local function getDefaultVehicleInfo()
  if defaultVehicleInfo then
    return defaultVehicleInfo
  end
  if FS:fileExists(pathDefaultConfig) then
    local data = jsonReadFile(pathDefaultConfig)
    if data then
      defaultVehicleInfo = data
    end
  end
  return defaultVehicleInfo
end
M.getDefaultVehicleInfo = getDefaultVehicleInfo

local function getDefaultVehicleTile()
  local info = M.getDefaultVehicleInfo()
  if not info then
    return nil
  end
  local model = core_vehicles.getModel(info.model)
  if not model or not model.model then return nil end
  model = model.model
  local data = {
    key = pathDefaultConfig,
    name = "Legacy default.pc",
    isConfig = true,
    preview = gameplay_missions_missions.getNoVehicleThumbFilepath(),
    model_key = info.model,
    config_key = '',
    configType = model['Config Type'] or othersText,
    showDetails = {model = info.model, config = pathDefaultConfig},
    doubleClickDetails = {model = info.model, config = pathDefaultConfig},
    subElementCount = 0,
    favouriteIdx = 0,
    recentIdx = math.huge,
    showFavouriteIconPercent = 0,
    sourceIcons = {{icon = "wrench"}},
    isAuxiliary = false,
    Value = 0,
    Weight = 0,
    ['Top Speed'] = 0,
    Power = 0,
    ['Power/Weight'] = 0,
    ['0-60 mph'] = math.huge,
    ['0-100 km/h'] = math.huge,
  }
  return data
end
M.getDefaultVehicleTile = getDefaultVehicleTile


-- Getter for uiData that initializes if needed
local function getUiData()
  if vehicleDataChanged then
    log("I","","Reloading vehicle data for vehicle selector")
    uiData = initializeVehicleData()
    vehicleDataChanged = false
  end
  uiData = uiData or initializeVehicleData()
  uiData.displayData = getEffectiveDisplayData()
  return uiData
end
M.getUiData = getUiData



local function closedFromUI()
  customRootPath = {}
  setSpawnOnly(false)
  if M.clearDrilldownSelectorState then
    M.clearDrilldownSelectorState()
  end
  if filterInstance then
    filterInstance.clearLockedFilters()
  end
  openedFromGarage = false
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(true)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons(nil)
  ui_vehicleSelector_detailsInteraction.setExitCallback(nop)
  extensions.hook("onVehicleSelectorClosed")
end
M.closedFromUI = closedFromUI

M.getFilters = function(...) M.getUiData() return filterInstance.getFilters(...) end
M.getActiveFilters = function(...) return filterInstance.getActiveFilters(...) end
M.getSearchText = function(...) return filterInstance.getSearchText(...) end
M.setSearchText = function(text, requestId)
  local result = filterInstance.setSearchText(text)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end
M.getTiles = function(...) return ui_vehicleSelector_tiles.getTiles(...) end
M.getDisplayData = function(...)
  return getEffectiveDisplayData()
end
M.getDisplayDataOptions = function(...)
  return getContextDisplayDataOptions()
end
M.setDisplayDataOption = function(key, value, requestId)
  ensureInstances()
  local displayData = displayDataInstance.setDisplayDataOption(key, value)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return displayData
end
M.resetDisplayDataToDefaults = function(requestId)
  ensureInstances()
  local displayData = displayDataInstance.resetDisplayDataToDefaults()
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return displayData
end
M.toggleFavourite = function(itemDetails)
  ensureInstances()
  local model = itemDetails.model
  local config = itemDetails.config
  if config == pathDefaultConfig then
    local nextValue = not M.getDisplayData().includeDefaultConfigInFavourites
    displayDataInstance.setDisplayDataOption("includeDefaultConfigInFavourites", nextValue)
    return nextValue and true or false
  end
  local itemKey = model .. "/" .. config
  displayDataInstance.toggleFavourite(itemKey)
  return displayDataInstance.isFavourite(itemKey) and true or false
end

M.updateFilters = function(...) return filterInstance.updateFilters(...) end
M.toggleFilter = function(filterKey, value, requestId)
  local result = filterInstance.toggleFilter(filterKey, value)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end
M.updateRangeFilter = function(filterKey, min, max, requestId)
  local result = filterInstance.updateRangeFilter(filterKey, min, max)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end
M.resetRangeFilter = function(filterKey, requestId)
  local result = filterInstance.resetRangeFilter(filterKey)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end
M.resetSetFilter = function(filterKey, requestId)
  local result = filterInstance.resetSetFilter(filterKey)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end
M.clearAllFilters = function(...) return filterInstance.clearAllFilters(...) end


M.lockFilter = function(...) return filterInstance.lockFilter(...) end
M.unlockFilter = function(...) return filterInstance.unlockFilter(...) end
M.isFilterLocked = function(...) return filterInstance.isFilterLocked(...) end
M.lockFilterMode = function(...) return filterInstance.lockFilterMode(...) end
M.lockFilterModeExclusive = function(...) return filterInstance.lockFilterModeExclusive(...) end
M.clearLockedFilters = function(...) return filterInstance.clearLockedFilters(...) end
M.calculateActiveFilters = function(...) return filterInstance.calculateActiveFilters(...) end
M.setupValidFilters = function(...) return filterInstance.setupValidFilters(...) end
M.getValidFilters = function(...) return filterInstance.getValidFilters(...) end
M.createFilters = function(...) return createVehicleFilters(...) end
M.passesFilters = function(...) return filterInstance.passesFilters(...) end

M.isFavourite = function(model, config)
  ensureInstances()
  local itemKey = model .. "/" .. config
  return displayDataInstance.isFavourite(itemKey)
end
M.isRecentVehicle = function(model, config)
  ensureInstances()
  local itemKey = model .. "/" .. config
  return displayDataInstance.isRecentItem(itemKey)
end
M.trackRecentVehicle = function(model, config)
  ensureInstances()
  local itemKey = model .. "/" .. config
  return displayDataInstance.trackRecentItem(itemKey)
end



M.goToMod = function(...) return ui_vehicleSelector_detailsInteraction.goToMod(...) end
M.getDetails = function(...) return ui_vehicleSelector_detailsInteraction.getDetails(...) end
M.getManagementDetails = function(...) return ui_vehicleSelector_detailsInteraction.getManagementDetails(...) end
M.executeButton = function(...) return ui_vehicleSelector_detailsInteraction.executeButton(...) end
M.executeDoubleClick = function(...) return ui_vehicleSelector_detailsInteraction.executeDoubleClick(...) end
M.setManagementButtonsEnabled = function(...) return ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(...) end
M.setDetailsButtonForFreeroam = function(...) return ui_vehicleSelector_detailsInteraction.setDetailsButtonForFreeroam(...) end
M.setCustomDetailsButtons = function(...) return ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons(...) end

-- Get screen header title based on current path and filter state
local function getScreenHeaderTitleAndPath(path)
  local title = ""
  local pathSegments = deepcopy(extensions.ui_router.getBreadcrumbs())
  local pathType = path and path.keys and path.keys[1]

  table.insert(pathSegments, {label = _tr("ui.menu.vehicleSelector.title"), gotoPath = {'allModels'}, clearFilters = true, clearSearch = true})

  if customRootPath and next(customRootPath) then
    pathSegments = deepcopy(customRootPath)
  end

  -- Check if any filters or search are active
  local activeFilters, _ = filterInstance.calculateActiveFilters()
  local searchText = filterInstance.getSearchText()
  local isFiltered = #activeFilters > 0 or (searchText and searchText ~= "")
  local searchSegmentText = {}
  if #activeFilters > 0 then
    local label = _tr("ui.menu.gridSelector.filtered")
    if #activeFilters == 1
       and (not activeFilters[1].containedOptionCount or activeFilters[1].containedOptionCount == 1)
       then
      label = _tr("ui.menu.gridSelector.filtered") .. ": " .. activeFilters[1].displayText
    end
    table.insert(searchSegmentText, label)
  end
  if searchText and searchText ~= "" then
    table.insert(searchSegmentText, _tr("ui.menu.gridSelector.search") .. ": " .. searchText)
  end
  if #searchSegmentText > 0 and not openedFromGarage then
    table.insert(pathSegments, {label = table.concat(searchSegmentText, ", "), gotoPath = {'allModels'}})
  end

  if pathType == "allModels" then
    title = _tr("ui.menu.vehicleSelector.path.allVehicles")
  elseif pathType == "configsForBrandSubModelOrModel" or pathType == "configsForModel" then
    local modelKey = path.keys[2]
    local modelSubKey = path.keys[3]
    local brandKey = path.keys[4]
    local groupMode = path.keys[5]
    local groupName = path.keys[6]
    local lastSegmentName = ""
    if modelKey then
      local model = core_vehicles.getModel(modelKey)
      if model then
        local brand = brandKey and brandKey ~= "" and brandKey or (model.model.Brand or "")
        local subModel = modelSubKey and modelSubKey ~= "" and modelSubKey or (model.model.SubModel or "")
        local modelName = model.model.Name or modelKey

        if brand and brand ~= "" then
          title = brand
          if subModel and subModel ~= "" then
            title = title .. " " .. subModel
          else
            title = title .. " " .. modelName
          end
        else
          if subModel and subModel ~= "" then
            title = subModel
          else
            title = modelName
          end
        end
        lastSegmentName = title
        -- Add group context if available
        if groupMode then
          if groupMode == "Favourites" then
            title = title .. " (" .. _tr("ui.menu.gridSelector.favourites") .. ")"
            --lastSegmentName = "Favourites / " .. lastSegmentName
          elseif groupMode == "Recent" then
            title = title .. " (" .. _tr("ui.menu.gridSelector.recent") .. ")"
            --lastSegmentName = "Recent / " .. lastSegmentName
          elseif groupName then
            title = title .. " (" .. propName(groupMode) .. ": " .. groupName .. ")"
            --lastSegmentName = groupName .. " / " .. lastSegmentName
          else
            title = title .. " (" .. propName(groupMode) .. ")"
            --lastSegmentName = groupMode .. " / " .. lastSegmentName
          end
        end
      else
        lastSegmentName = _tr("ui.menu.vehicleSelector.path.unknownModel")
        title = _tr("ui.menu.vehicleSelector.path.unknownModel")
      end
    else
      lastSegmentName = _tr("ui.menu.vehicleSelector.path.vehicleConfigurations")
      title = _tr("ui.menu.vehicleSelector.path.vehicleConfigurations")
    end
    table.insert(pathSegments, {label = lastSegmentName, gotoPath = path.keys})
  else
    title = _tr("ui.menu.vehicleSelector.title")
  end

  if isFiltered then
    title = title .. " (" .. _tr("ui.menu.gridSelector.filtered") .. ")"
  end
  -- Spawn-only sessions always present as "Spawn Vehicle" across the root grid
  -- and the config drilldown, overriding the dynamic model/config title.
  if isSpawnOnly() then
    title = _tr("ui.career.inventory.menu.spawnVehicle")
  end
  return {
    title = title,
    isFiltered = isFiltered,
    pathSegments = pathSegments
  }
end
M.getScreenHeaderTitleAndPath = getScreenHeaderTitleAndPath

local function profilerFinish(tag)
  if not M.p or not M.p.timer then return end
  if tag and tag ~= "" and tag ~= "undefined" then
    M.p:add(tag)
  else
    M.p:add("profilerFinish (no tag, UI is now ready)")
    M.p:finish(true)
  end
end
M.profilerFinish = profilerFinish

M.isOpenedFromGarage = function()
  return openedFromGarage
end

-- opening the vehicle selector
local function openVehicleSelectorForFreeroam()
  openedFromGarage = false
  setSpawnOnly(false)
  M.getUiData() -- Initialize if needed
  filterInstance.clearLockedFilters()
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(true)
  ui_vehicleSelector_detailsInteraction.setDetailsButtonForFreeroam(true)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons()
  ui_vehicleSelector_detailsInteraction.setExitCallback(nop)
  extensions.ui_router.navigate("menu.vehiclesnew")
  -- guihooks.trigger("gridSelectorRefreshAll","vehicleSelector") -- kept for later reference
  extensions.hook("onVehicleSelectorOpen")
end
M.openVehicleSelectorForFreeroam = openVehicleSelectorForFreeroam

-- opening the vehicle selector
local function openVehicleSelectorForFreeroamWithMod(modId)
  openedFromGarage = false
  setSpawnOnly(false)
  local mod = getModById(modId)
  M.getUiData() -- Initialize if needed

  filterInstance.clearLockedFilters()
  filterInstance.toggleFilter("Source",{"Mod: " ..mod.modname})
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(true)
  ui_vehicleSelector_detailsInteraction.setDetailsButtonForFreeroam(true)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons()
  ui_vehicleSelector_detailsInteraction.setExitCallback(nop)
  extensions.ui_router.navigate("menu.vehiclesnew")
  -- guihooks.trigger("gridSelectorRefreshAll","vehicleSelector") -- kept for later reference
  extensions.hook("onVehicleSelectorOpen")
end
M.openVehicleSelectorForFreeroamWithMod = openVehicleSelectorForFreeroamWithMod

local function openVehicleSelectorForGarage(showOwnedOnly)
  local function goBackToGarage()
    openedFromGarage = false
    extensions.ui_router.navigate("garage")
  end

  local function spawnGarageSelection(model, config, additionalData)
    if not model then
      goBackToGarage()
      return
    end

    local selectedConfig
    local uiData = M.getUiData()
    if uiData and uiData.configs then
      for _, cfg in ipairs(uiData.configs) do
        if cfg.model_key == model and cfg.key == config then
          selectedConfig = cfg
          break
        end
      end
    end

    if selectedConfig and selectedConfig.spawnFunction then
      local invId = string.match(selectedConfig.spawnFunction, "enterVehicle%((%d+)%)")
      if invId and career_modules_inventory and career_modules_inventory.enterVehicle then
        career_modules_inventory.enterVehicle(tonumber(invId))
        goBackToGarage()
        return
      end
    end

    local options = {
      config = config,
    }
    if type(additionalData) == "table" and next(additionalData) then
      local modelData = core_vehicles.getModel(model)
      if modelData and modelData.model and modelData.model.paints then
        options.paint = modelData.model.paints[additionalData.paint]
        options.paint2 = modelData.model.paints[additionalData.paint2]
        options.paint3 = modelData.model.paints[additionalData.paint3]
      end
    end

    local sanitizedOptions = sanitizeVehicleSpawnOptions(model, options)
    core_vehicles.replaceVehicle(model, sanitizedOptions)
    if config then
      M.trackRecentVehicle(model, config)
    end
    goBackToGarage()
  end

  customRootPath = {
    {label = _tr("ui.common.menu"), gotoAngularState = "menu"},
    {label = _tr("ui.mainmenu.garage"), gotoAngularState = "garage", gotoState = "garage"},
    {
      label = _tr(showOwnedOnly and "ui.garage.load.loadCar" or "ui.garage.tabs.vehicles"),
      gotoPath = {"allModels"},
      clearFilters = true,
      clearSearch = true
    },
  }

  setSpawnOnly(false)
  M.getUiData()
  filterInstance.clearLockedFilters()
  if showOwnedOnly then
    filterInstance.lockFilterModeExclusive("Source", {"Custom", "Mod", "Career"})
  else
    filterInstance.lockFilterModeExclusive("Source", {"Custom", "BeamNG - Official", "Mod"})
  end

  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(false)
  ui_vehicleSelector_detailsInteraction.setDetailsButtonForFreeroam(false)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons({{
    callback = spawnGarageSelection,
    meta = {
      label = _tr("ui.garage.load.loadCar"),
      icon = "car",
      primary = true,
      isDoubleClickAction = true,
    }
  }})
  ui_vehicleSelector_detailsInteraction.setExitCallback(goBackToGarage)
  openedFromGarage = true
  local targetRoute = showOwnedOnly and "garage.mycars" or "garage.vehicles"
  extensions.ui_router.navigate(targetRoute)
  extensions.hook("onVehicleSelectorOpen")
end
M.openVehicleSelectorForGarage = openVehicleSelectorForGarage

M.openVehicleSelectorForFreeroamModal = function()

  local callback = function(a,b,c,d)
    -- print("callback")
    dump(a) dump(b) dump(c) dump(d)
    extensions.ui_router.navigate("menu.freeroamselector")
    -- guihooks.trigger("gridSelectorRefreshAll","freeroamSelector") -- kept for later reference
  end

  setSpawnOnly(false)
  M.getUiData() -- Initialize if needed
  filterInstance.clearLockedFilters()
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(false)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons({{
    callback = callback,
    meta = {
      label = "Select Vehicle",
      icon = "car"
    }
  }})
  ui_vehicleSelector_detailsInteraction.setExitCallback(function()
    -- print("exit callback")
    callback()
  end)
  guihooks.trigger("ChangeState", "vehicle-selector")
  guihooks.trigger("gridSelectorRefreshAll","vehicleSelector")
  extensions.hook("onVehicleSelectorOpen")

end

local function openVehicleSelectorForChallenge(callback)
  callback = callback or nop
  openedFromGarage = false
  setSpawnOnly(false)
  customRootPath = {
    {label = _tr("ui.menu.vehicleSelector.title"), gotoPath = {"allModels"}, clearFilters = true, clearSearch = true},
  }
  M.getUiData() -- Initialize if needed
  filterInstance.clearLockedFilters()
  -- Opponents must be drivable vehicles, so hard-exclude props and trailers from the grid.
  local filters = filterInstance.getFilters()
  if filters and filters.filterList then
    local excludedTypeValues = {
      Prop = true,
      Trailer = true,
    }
    for _, f in ipairs(filters.filterList) do
      if f.propKey == "Type" and f.type == "set" and f.options then
        local allowedTypes = {}
        for _, opt in ipairs(f.options) do
          local optValue = type(opt) == "table" and (opt.value or opt.id or opt.name) or opt
          if optValue and not excludedTypeValues[optValue] then
            table.insert(allowedTypes, optValue)
          end
        end
        filterInstance.lockFilterModeExclusive(f.propName, allowedTypes)
        break
      end
    end
  end
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(false)
  ui_vehicleSelector_detailsInteraction.setDetailsButtonForFreeroam(false)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons({{
    callback = function(model, config, additionalData)
      callback(model, config, additionalData)
    end,
    meta = {
      label = "Select Vehicle",
      icon = "car",
      primary = true,
      isDoubleClickAction = true,
    }
  }})
  ui_vehicleSelector_detailsInteraction.setExitCallback(function()
    callback()
  end)
  extensions.ui_router.navigate("mission.control.vehicleSelector")
  extensions.hook("onVehicleSelectorOpen")
end
M.openVehicleSelectorForChallenge = openVehicleSelectorForChallenge


local function openVehicleSelectorForFreeroamConfigurator(callback)
  setSpawnOnly(false)
  M.getUiData() -- Initialize if needed
  filterInstance.clearLockedFilters()
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(false)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons({{
    callback = function(model, config, additionalData)
      if model and config then
        M.trackRecentVehicle(model, config)
      end
      callback(model, config, additionalData)
    end,
    meta = {
      label = "Select Vehicle",
      icon = "car",
      primary = true,
      isDoubleClickAction = true,
    }
  }})
  customRootPath = {
    {label = "Menu", gotoAngularState = "menu"},
    {label = "Freeroam Configurator", gotoAngularState = 'menu.freeroamconfigurator'},
    {label = "Player Vehicle Selection", gotoPath = {'allModels'}, clearFilters = true, clearSearch = true},
  }
  guihooks.trigger("ChangeState", "vehicle-selector")
  guihooks.trigger("gridSelectorRefreshAll","vehicleSelector")
  extensions.hook("onVehicleSelectorOpen")
end
M.openVehicleSelectorForFreeroamConfigurator = openVehicleSelectorForFreeroamConfigurator

local function openFromPause(routeName)
  openedFromGarage = false
  setSpawnOnly(options and options.spawnOnly == true)
  customRootPath = {
    --{label = "Pause", gotoState = "pause.vehicle"},
    {label = _tr("ui.menu.vehicleSelector.title"), gotoPath = {'allModels'}, clearFilters = true, clearSearch = true},
  }
  M.getUiData()
  filterInstance.clearLockedFilters()
  ui_vehicleSelector_detailsInteraction.setManagementButtonsEnabled(true)
  ui_vehicleSelector_detailsInteraction.setDetailsButtonForFreeroam(true)
  ui_vehicleSelector_detailsInteraction.setCustomDetailsButtons()
  ui_vehicleSelector_detailsInteraction.setExitCallback(nop)
  extensions.ui_router.navigate(routeName or "pause.vehicleSelector")
end
M.openFromPause = openFromPause

-- Drilldown lifecycle and helpers for the pause.vehicleSelector.vehicle child
-- route. The pattern mirrors ui_gameplaySelector_general:
--  * navigateToVehicle saves a pending selection then navigates.
--  * onVehicleRouteEnter promotes the pending selection to active.
--  * onVehicleRouteMount builds the configs-for-model snapshot and attaches it
--    to the route data so VehicleSelectorPause.vue can hydrate.
--  * resolveSelectedVehicleTitle drives the dynamic route title.

-- The VehicleSelectorPause component is shared by the pause menu selector and
-- the garage selectors (vehicles / mycars). Each entry point lives at its own
-- Vue route, so route names and paths are resolved per parent context instead
-- of being hardcoded to the pause routes.

-- Root selector route name -> Vue route path. Both garage roots share the
-- garage.vehicles screen, hence the same path.
local ROOT_ROUTE_PATHS = {
  ["pause.vehicleSelector"] = "/vehicle-selector-pause",
  ["pause.vehicle.vehicleSelector"] = "/vehicle-selector-pause/vehicle-tab",
  ["pause.manageVehicles.vehicleSelector"] = "/vehicle-selector-pause/manage-vehicles",
  ["garage.vehicles"] = "/garage/vehicles",
  ["garage.mycars"] = "/garage/vehicles",
}

-- Root selector route name -> vehicle drilldown child route name.
local VEHICLE_CHILD_ROUTE_NAMES = {
  ["pause.vehicleSelector"] = "pause.vehicleSelector.vehicle",
  ["pause.vehicle.vehicleSelector"] = "pause.vehicle.vehicleSelector.vehicle",
  ["pause.manageVehicles.vehicleSelector"] = "pause.manageVehicles.vehicleSelector.vehicle",
  ["garage.vehicles"] = "garage.vehicles.vehicle",
  ["garage.mycars"] = "garage.mycars.vehicle",
}

-- Vehicle drilldown child route name -> Vue route path.
local VEHICLE_CHILD_ROUTE_PATHS = {
  ["pause.vehicleSelector.vehicle"] = "/vehicle-selector-pause/vehicle",
  ["pause.vehicle.vehicleSelector.vehicle"] = "/vehicle-selector-pause/vehicle-tab/vehicle",
  ["pause.manageVehicles.vehicleSelector.vehicle"] = "/vehicle-selector-pause/manage-vehicles/vehicle",
  ["garage.vehicles.vehicle"] = "/garage/vehicles/vehicle",
  ["garage.mycars.vehicle"] = "/garage/my-cars/vehicle",
}

local DEFAULT_ROOT_ROUTE_NAME = "pause.vehicleSelector"
local VEHICLE_CHILD_ROUTE_NAME = "pause.vehicleSelector.vehicle"
local VEHICLE_CHILD_ROUTE_PATH = "/vehicle-selector-pause/vehicle"

-- Every route name that belongs to the vehicle selector family (root selector
-- screens plus their vehicle drilldown children). Used to keep spawn-only state
-- alive while navigating between a selector root and its vehicle child, while
-- resetting it once navigation leaves the family entirely.
local SELECTOR_FAMILY_ROUTE_NAMES = {}
for rootName in pairs(ROOT_ROUTE_PATHS) do
  SELECTOR_FAMILY_ROUTE_NAMES[rootName] = true
end
for _, childName in pairs(VEHICLE_CHILD_ROUTE_NAMES) do
  SELECTOR_FAMILY_ROUTE_NAMES[childName] = true
end

local function isSelectorFamilyRoute(route)
  if type(route) ~= "table" then
    return false
  end
  return SELECTOR_FAMILY_ROUTE_NAMES[route.name] == true
    or SELECTOR_FAMILY_ROUTE_NAMES[route.routeName] == true
    or SELECTOR_FAMILY_ROUTE_NAMES[route.screenId] == true
end

-- Reset spawn-only when the destination route is outside the selector family;
-- intra-family navigation (root <-> vehicle child) preserves it.
local function resetSpawnOnlyOnFamilyExit(toRoute)
  if not isSelectorFamilyRoute(toRoute) then
    setSpawnOnly(false)
  end
end

-- Read the currently resolved router route name (e.g. "garage.vehicles"). Used
-- to pick the right child drilldown route when navigating from the grid.
local function getCurrentRouteName()
  if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
    or type(extensions.ui_router.getCurrent) ~= "function" then
    return nil
  end
  local currentEntry = extensions.ui_router.getCurrent()
  return currentEntry and currentEntry.resolved and currentEntry.resolved.name or nil
end

-- Resolve the vehicle drilldown child route name + path for a given parent
-- (root) selector route. Falls back to the pause routes for unknown parents.
local function resolveVehicleChildRoute(parentRouteName)
  local childName = parentRouteName and VEHICLE_CHILD_ROUTE_NAMES[parentRouteName] or VEHICLE_CHILD_ROUTE_NAME
  return {
    name = childName,
    path = VEHICLE_CHILD_ROUTE_PATHS[childName] or VEHICLE_CHILD_ROUTE_PATH,
  }
end

local pendingVehicleSelection = nil
local activeVehicleSelection = nil
-- Wizard-owned selector path: when a route (e.g. the freeroam wizard) needs
-- emitDisplayDataSnapshot to rebuild against a specific path that does not
-- come from the pause vehicle drilldown lifecycle, it can record that path
-- here via setCurrentSelectorPath. Takes precedence over activeVehicleSelection
-- in resolveCurrentSelectorPath; cleared by closedFromUI.
local activeSelectorPath = nil

-- Reset all drilldown / wizard-owned selector state. Used by the root
-- pause.vehicleSelector lifecycle and by closedFromUI so that a refreshed
-- snapshot (via emitDisplayDataSnapshot) never rebuilds against a previously
-- selected vehicle's config path.
local function clearDrilldownSelectorState()
  pendingVehicleSelection = nil
  activeVehicleSelection = nil
  activeSelectorPath = nil
end
M.clearDrilldownSelectorState = clearDrilldownSelectorState

local function isNonEmptyString(value)
  return type(value) == "string" and value ~= ""
end

-- Preserve empty strings: vehicle path keys use them as positional
-- placeholders (e.g. {"configsForBrandSubModelOrModel", model, "", ""}).
local function normalizeStringList(rawList)
  if type(rawList) ~= "table" then
    return {}
  end
  local result = {}
  for _, value in ipairs(rawList) do
    if type(value) == "string" then
      table.insert(result, value)
    elseif type(value) == "number" or type(value) == "boolean" then
      table.insert(result, tostring(value))
    end
  end
  return result
end

local function resolveModelKeyFromTile(tile)
  if type(tile) ~= "table" then
    return nil
  end
  if isNonEmptyString(tile.model_key) then
    return tile.model_key
  end
  local details = tile.doubleClickDetails or tile.showDetails
  if type(details) == "table" and isNonEmptyString(details.model) then
    return details.model
  end
  local gotoPath = tile.gotoPath
  if type(gotoPath) == "table"
    and (gotoPath[1] == "configsForBrandSubModelOrModel" or gotoPath[1] == "configsForModel")
    and isNonEmptyString(gotoPath[2]) then
    return gotoPath[2]
  end
  return nil
end

local function resolveConfigKeyFromTile(tile)
  if type(tile) ~= "table" then
    return nil
  end
  if isNonEmptyString(tile.config_key) then
    return tile.config_key
  end
  local details = tile.doubleClickDetails or tile.showDetails
  if type(details) == "table" and isNonEmptyString(details.config) then
    return details.config
  end
  return nil
end

-- Build the configsForBrandSubModelOrModel/configsForModel path the route
-- should display. Cluster tiles already carry a gotoPath we can reuse; for
-- unclustered config tiles we synthesize a path from the tile's model key.
local function buildVehiclePathKeys(tile)
  if type(tile) == "table" and type(tile.gotoPath) == "table" then
    local keys = normalizeStringList(tile.gotoPath)
    if #keys > 0 and (keys[1] == "configsForBrandSubModelOrModel" or keys[1] == "configsForModel") then
      return keys
    end
  end
  local modelKey = resolveModelKeyFromTile(tile)
  if isNonEmptyString(modelKey) then
    return { "configsForBrandSubModelOrModel", modelKey, "", "" }
  end
  return nil
end

-- Resolve a short vehicle title (e.g. "Brand Model") for breadcrumbs and the
-- dynamic route title. Falls back to the tile name when the model lookup is
-- unavailable.
local function resolveVehicleTitleFromTile(tile, modelKey)
  if type(tile) == "table" and isNonEmptyString(tile.name) then
    return tile.name
  end
  if isNonEmptyString(modelKey) then
    local model = core_vehicles.getModel(modelKey)
    local modelData = model and model.model or nil
    if type(modelData) == "table" then
      local brand = isNonEmptyString(modelData.Brand) and modelData.Brand or nil
      local subModel = isNonEmptyString(modelData.SubModel) and modelData.SubModel or nil
      local name = isNonEmptyString(modelData.Name) and modelData.Name or modelKey
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
  end
  return nil
end

local function copyVehicleSelection(selection)
  if type(selection) ~= "table" then
    return nil
  end
  return {
    pathKeys = normalizeStringList(selection.pathKeys),
    title = isNonEmptyString(selection.title) and selection.title or nil,
    modelKey = isNonEmptyString(selection.modelKey) and selection.modelKey or nil,
    configKey = isNonEmptyString(selection.configKey) and selection.configKey or nil,
    overrideTile = type(selection.overrideTile) == "table" and selection.overrideTile or nil,
    childRouteName = isNonEmptyString(selection.childRouteName) and selection.childRouteName or nil,
    childRoutePath = isNonEmptyString(selection.childRoutePath) and selection.childRoutePath or nil,
  }
end

local function buildVehicleRouteSnapshot(pathKeys)
  local resolvedKeys = normalizeStringList(pathKeys)
  if #resolvedKeys == 0 then
    return nil
  end
  return ui_gridSelector.getSelectorSnapshot(backendName, { keys = resolvedKeys })
end

-- Find the initial config tile to show details for after the snapshot is
-- built. Prefer the tile flagged as isDefaultSelected by tiles.lua and fall
-- back to the first tile that exposes a usable showDetails payload.
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

function M.requestDetails(item, requestId)
  local detailsRequest = item
  if type(item) == "table" and type(item.showDetails) == "table" then
    detailsRequest = item.showDetails
  end

  local details = M.getDetails(detailsRequest)
  local payload = {
    backendName = backendName,
    requestId = requestId,
    item = item,
    details = details,
  }

  guihooks.trigger("vehicleSelectorDetails", payload)
  return payload
end

local pendingPauseRouteMount = nil

local function describePauseRoutePathForLog(path)
  if type(path) ~= "table" or type(path.keys) ~= "table" then
    return "nil"
  end
  return table.concat(path.keys, "/")
end

local function isPendingPauseRouteStillCurrent(pending)
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

local function emitPauseRouteSnapshot(pending)
  if type(pending) ~= "table" then
    return false
  end

  local pathKeys = normalizeStringList(pending.pathKeys)
  if #pathKeys == 0 then
    return false
  end

  if pending.overrideTile and ui_vehicleSelector_tiles
    and ui_vehicleSelector_tiles.overrideDefaultSelectedTile then
    ui_vehicleSelector_tiles.overrideDefaultSelectedTile(pending.overrideTile)
  end

  local ok, snapshotOrErr = pcall(buildVehicleRouteSnapshot, pathKeys)
  if not ok then
    log("E", "ui.vehicleSelector",
      string.format("Failed to build pause vehicle selector route snapshot: %s", tostring(snapshotOrErr)))
    return false
  end

  local routePath = pending.routePath or VEHICLE_CHILD_ROUTE_PATH
  local payload = {
    backendName = backendName,
    routeName = pending.routeName,
    routePath = routePath,
    snapshot = snapshotOrErr,
  }

  -- print(string.format(
  --   "[ui.vehicleSelector] emitting VehicleSelectorDataLoaded for route=%s path=%s",
  --   tostring(pending.routeName), describePauseRoutePathForLog({ keys = pathKeys })
  -- ))

  guihooks.trigger("VehicleSelectorDataLoaded", payload)

  -- Kick the initial details push so the Vue side can preselect
  -- VehicleDetails on cold loads without requiring a focus action. Mirrors
  -- the behavior the synchronous route-data attach used to perform.
  local initialTile = findInitialDetailsTile(snapshotOrErr)
  if initialTile then
    local okDetails, errDetails = pcall(M.requestDetails, initialTile)
    if not okDetails then
      log("E", "ui.vehicleSelector",
        string.format("Failed to emit vehicleSelectorDetails for initial tile: %s", tostring(errDetails)))
    end
  end

  return true
end

-- Defer the snapshot build/emit off the route mount path so the wizard route
-- can paint first and the Vue grid selector shows its loading state before the
-- (potentially heavy) snapshot is built. Mirrors the async completion path so
-- warm and cold-but-already-loaded loads behave identically from the UI's
-- perspective: route mount stays cheap and the grid hydrates from
-- VehicleSelectorDataLoaded. Stale navigations are discarded before emitting
-- (the user may have navigated away during the one-tick defer).
local function scheduleDeferredPauseSnapshotEmit(pending)
  if type(pending) ~= "table" then
    return false
  end

  if type(core_jobsystem) ~= "table" or type(core_jobsystem.create) ~= "function" then
    log("W", "ui.vehicleSelector", "core_jobsystem unavailable; emitting pause vehicle snapshot synchronously")
    return emitPauseRouteSnapshot(pending)
  end

  core_jobsystem.create(function(job)
    job.sleep(0)
    if not isPendingPauseRouteStillCurrent(pending) then
      -- print(string.format(
      --   "[ui.vehicleSelector] deferred pause vehicle snapshot skipped for stale route=%s",
      --   tostring(pending.routeName)
      -- ))
      return
    end
    emitPauseRouteSnapshot(pending)
  end, 1/30)

  return true
end

-- Start (or queue) async loading. If vehicle data is already loaded we still
-- defer the snapshot build/emit by one tick so the pause route paints with the
-- grid selector's loading state first, then hydrates from
-- VehicleSelectorDataLoaded. Cold loads kick off the async vehicle loader and
-- rely on asyncVehicleLoadComplete to emit the snapshot.
local function beginAsyncPauseRouteMount(pending)
  pendingPauseRouteMount = pending

  -- print(string.format(
  --   "[ui.vehicleSelector] beginAsyncPauseRouteMount route=%s path=%s",
  --   tostring(pending.routeName), describePauseRoutePathForLog({ keys = normalizeStringList(pending.pathKeys) })
  -- ))

  if type(extensions) ~= "table" or type(extensions.util_asyncBulkLoader) ~= "table"
    or type(extensions.util_asyncBulkLoader.loadVehicles) ~= "function" then
    log("W", "ui.vehicleSelector", "util_asyncBulkLoader.loadVehicles unavailable; deferring snapshot emit")
    local snapshotPending = pendingPauseRouteMount
    pendingPauseRouteMount = nil
    scheduleDeferredPauseSnapshotEmit(snapshotPending)
    return
  end

  local result = extensions.util_asyncBulkLoader.loadVehicles()
  if result == "alreadyLoaded" then
    -- print("[ui.vehicleSelector] vehicles already loaded; deferring pause snapshot emit")
    local snapshotPending = pendingPauseRouteMount
    pendingPauseRouteMount = nil
    scheduleDeferredPauseSnapshotEmit(snapshotPending)
  end
end

-- Listens for the asyncBulkLoader completion hook so we can build and emit the
-- pause vehicle selector snapshot only after the heavy data is ready. The
-- pending route is compared against the active router entry to discard stale
-- completions caused by rapid route changes.
function M.asyncVehicleLoadComplete()
  local pending = pendingPauseRouteMount
  if type(pending) ~= "table" then
    return
  end
  pendingPauseRouteMount = nil

  if not isPendingPauseRouteStillCurrent(pending) then
    -- print(string.format(
    --   "[ui.vehicleSelector] async vehicle load completed for stale route=%s; skipping snapshot emit",
    --   tostring(pending.routeName)
    -- ))
    return
  end

  emitPauseRouteSnapshot(pending)
end

-- Save the pending selection and let the router navigate; the rest of the
-- snapshot/title/breadcrumb work happens in the lifecycle hooks below.
-- `options` (optional) are forwarded to extensions.ui_router.navigate so
-- callers can influence route activation. Random selection passes
-- { preferredScope = "auxillary" } to keep the auxiliary panel active instead
-- of focusing the grid; normal grid tile clicks pass no options.
local function navigateToVehicle(tile, options)
  dump("navigateToVehicle", tile)
  if type(tile) ~= "table" then
    log("W", "ui.vehicleSelector", "navigateToVehicle called without a tile")
    return
  end

  local pathKeys = buildVehiclePathKeys(tile)
  if not pathKeys then
    log("W", "ui.vehicleSelector",
      "navigateToVehicle could not resolve a vehicle path; aborting drilldown navigation.")
    return
  end

  local modelKey = resolveModelKeyFromTile(tile)
  local configKey = resolveConfigKeyFromTile(tile)
  local title = resolveVehicleTitleFromTile(tile, modelKey)

  -- Only request a selected-tile override when the click came from a config
  -- tile; cluster tiles should land on the model's default selection.
  local overrideTile = nil
  if tile.isConfig and isNonEmptyString(modelKey) and isNonEmptyString(configKey) then
    overrideTile = {
      model_key = modelKey,
      config_key = configKey,
      key = configKey,
    }
  end

  -- The current route is the parent (root) selector we are drilling down from;
  -- pick the matching child route so garage and pause selectors navigate to
  -- their own drilldown screens.
  local childRoute = resolveVehicleChildRoute(getCurrentRouteName())

  pendingVehicleSelection = {
    pathKeys = pathKeys,
    title = title,
    modelKey = modelKey,
    configKey = configKey,
    overrideTile = overrideTile,
    childRouteName = childRoute.name,
    childRoutePath = childRoute.path,
  }
  dump("pendingVehicleSelection", pendingVehicleSelection)

  local navigateOptions = type(options) == "table" and options or nil
  return extensions.ui_router.navigate(childRoute.name, nil, navigateOptions)
end
M.navigateToVehicle = navigateToVehicle

local function runPauseLifecycle(hookName, context, toRoute, fromRoute, data)
  local pauseLifecycle = extensions.ui_pause_routeLifecycleCallbacks
  local hook = pauseLifecycle and pauseLifecycle[hookName]
  if type(hook) == "function" then
    hook(context, toRoute, fromRoute, data)
  end
end

function M.onVehicleRouteEnter(context, toRoute, fromRoute, data)
  runPauseLifecycle("onPauseEnter", context, toRoute, fromRoute, data)
  activeSelectorPath = nil
  if pendingVehicleSelection then
    activeVehicleSelection = copyVehicleSelection(pendingVehicleSelection)
    pendingVehicleSelection = nil
  else
    activeVehicleSelection = nil
  end
end

function M.onVehicleRouteMount(context, toRoute, fromRoute, data)
  runPauseLifecycle("onPauseMount", context, toRoute, fromRoute, data)
  if type(activeVehicleSelection) ~= "table" then
    log("W", "ui.vehicleSelector",
      "onVehicleRouteMount has no active vehicle selection; skipping snapshot attach.")
    return
  end

  local pathKeys = normalizeStringList(activeVehicleSelection.pathKeys)
  local routeName = type(toRoute) == "table" and toRoute.name
    or activeVehicleSelection.childRouteName or VEHICLE_CHILD_ROUTE_NAME
  local routePath = activeVehicleSelection.childRoutePath
    or VEHICLE_CHILD_ROUTE_PATHS[routeName] or VEHICLE_CHILD_ROUTE_PATH
  beginAsyncPauseRouteMount({
    routeName = routeName,
    routePath = routePath,
    pathKeys = pathKeys,
    overrideTile = activeVehicleSelection.overrideTile,
  })
end

function M.onRootRouteEnter(context, toRoute, fromRoute, data)
  M.clearDrilldownSelectorState()
  runPauseLifecycle("onPauseEnter", context, toRoute, fromRoute, data)
end

function M.onRootRouteMount(context, toRoute, fromRoute, data)
  M.clearDrilldownSelectorState()
  runPauseLifecycle("onPauseMount", context, toRoute, fromRoute, data)

  local routeName = type(toRoute) == "table" and toRoute.name or DEFAULT_ROOT_ROUTE_NAME
  local routeParams = type(toRoute) == "table" and toRoute.params or nil
  local resolvedPath = nil
  if type(routeParams) == "table" then
    if type(routeParams.path) == "table" and type(routeParams.path.keys) == "table" then
      resolvedPath = routeParams.path.keys
    elseif type(routeParams.keys) == "table" then
      resolvedPath = routeParams.keys
    end
  end
  local pathKeys = normalizeStringList(resolvedPath or { "allModels" })
  if #pathKeys == 0 then
    pathKeys = { "allModels" }
  end
  beginAsyncPauseRouteMount({
    routeName = routeName,
    routePath = ROOT_ROUTE_PATHS[routeName] or ROOT_ROUTE_PATHS[DEFAULT_ROOT_ROUTE_NAME],
    pathKeys = pathKeys,
    overrideTile = nil,
  })
end

function M.onVehicleRouteLeave(context, toRoute, fromRoute, data)
  runPauseLifecycle("onPauseLeave", context, toRoute, fromRoute, data)
  resetSpawnOnlyOnFamilyExit(toRoute)
end

function M.onRootRouteLeave(context, toRoute, fromRoute, data)
  runPauseLifecycle("onPauseLeave", context, toRoute, fromRoute, data)
  resetSpawnOnlyOnFamilyExit(toRoute)
  if openedFromGarage and filterInstance then
    filterInstance.clearLockedFilters()
    filterInstance.clearAllFilters()
    openedFromGarage = false
  end
end

function M.setCurrentSelectorPath(path)
  if path == nil then
    activeSelectorPath = nil
    return
  end
  local rawKeys = nil
  if type(path) == "table" then
    if type(path.keys) == "table" then
      rawKeys = path.keys
    elseif path[1] ~= nil then
      rawKeys = path
    end
  end
  if rawKeys == nil then
    return
  end
  local normalizedKeys = normalizeStringList(rawKeys)
  if #normalizedKeys > 0 then
    activeSelectorPath = { keys = normalizedKeys }
  end
end

function M.resolveCurrentSelectorPath()
  if type(activeSelectorPath) == "table" then
    local keys = normalizeStringList(activeSelectorPath.keys)
    if #keys > 0 then
      return { keys = keys }
    end
  end
  if type(activeVehicleSelection) == "table" then
    local keys = normalizeStringList(activeVehicleSelection.pathKeys)
    if #keys > 0 then
      return { keys = keys }
    end
  end
  return { keys = { "allModels" } }
end

function M.emitDisplayDataSnapshot(requestId)
  local path = M.resolveCurrentSelectorPath()
  local ok, snapshotOrErr = pcall(ui_gridSelector.getSelectorSnapshot, backendName, path)
  if not ok then
    log("E", "ui.vehicleSelector",
      string.format("Failed to rebuild vehicle selector snapshot for display refresh: %s", tostring(snapshotOrErr)))
    return false
  end
  guihooks.trigger("vehicleSelectorDisplayDataSnapshot", {
    backendName = backendName,
    requestId = requestId,
    snapshot = snapshotOrErr,
  })
  return true
end

function M.resolveSelectedVehicleTitle(paramTitle)
  if type(activeVehicleSelection) == "table" and isNonEmptyString(activeVehicleSelection.title) then
    return activeVehicleSelection.title
  end
  if isNonEmptyString(paramTitle) then
    return paramTitle
  end
  return nil
end

return M