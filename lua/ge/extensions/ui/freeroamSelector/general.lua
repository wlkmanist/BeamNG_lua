-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.backendName = "freeroamSelector"
M.dependencies = {
  "ui_gameplaySelector_tiles",
  "core_locales",
}
local customRootPath = {}
local propName = function(key) return _tr("ui.menu.gameplaySelector.propName." .. key, key) end
local propValue = function(propNameKey, key) return core_locales.translateWithPrefixFallback(key, "ui.menu.gameplaySelector.propValue." .. propNameKey .. ".") end

local mapSizeSteps = {0, 1024 * 1024, 2048 * 2048, 4096 * 4096, 8192 * 8192, 16384 * 16384}

local function getFilterValue(item, propKey)
  local value = item[propKey]
  if propKey ~= "mapSize" or type(value) ~= "number" then return value or "other" end
  for index = #mapSizeSteps, 1, -1 do
    if value > mapSizeSteps[index] then return mapSizeSteps[index] end
  end
  return 0
end

local function filterOptionLabel(propKey, value)
  if propKey == "mapSize" then return _tr("ui.common.unknown") end
  if propKey == "source" then return _tr(value == "official" and "ui.common.official" or "ui.menu.gridSelector.tags.mod") end
  local label = core_locales.translateWithPrefixFallback(value, "ui.vehicles.propValue.Region.")
  if label == value and value:match("^%l") and not value:find("[%s%.]") then
    return string.sentenceCase(value:gsub("[_-]+", " "))
  end
  return label
end
-- Load the modules
local displayDataModule = require("ge/extensions/ui/gridSelectorUtils/displayDataModule")
local filterModule = require("ge/extensions/ui/gridSelectorUtils/filterModule")

local defaultDisplayDataOptions, displayDataInstance, filterInstance

local wizardRouteByStep = {
  menu = {
    level = "menu.freeroamLevels",
    vehicle = "menu.freeroamLevels.vehicles",
    options = "menu.freeroamLevels.vehicles.options",
    multiplayer = "menu.freeroamLevels.vehicles.options.multiplayer",
  },
  pause = {
    level = "pause.freeroamLevels",
    vehicle = "pause.freeroamLevels.vehicles",
    options = "pause.freeroamLevels.vehicles.options",
    multiplayer = "pause.freeroamLevels.vehicles.options.multiplayer",
  }
}

local function getWizardRouteByStep(step, routeFamily)
  local routes = wizardRouteByStep[routeFamily] or wizardRouteByStep.menu
  return routes[step] or routes.level
end

local function setupInstances()
  -- Default display data options for gameplay selector
  defaultDisplayDataOptions = {
    {
      label = _tr("ui.menu.gridSelector.displayOptions.groupBy.title"),
      key = "groupMode",
      default = "system",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.groupBy.description"),
      showInModes = {},
      options = {
        {label = _tr("ui.menu.gameplaySelector.propName.system"), value = "system"},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.clusterBy.title"),
      key = "clusterMode",
      default = "automatic",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.clusterBy.description"),
      showInModes = {},
      options = {
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.automatic"), value = "automatic"},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displaySize.title"),
      key = "displaySize",
      default = "medium",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displaySize.description"),
      save = true,
      showInModes = {displayControls = true, default = true},
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
      label = _tr("ui.menu.gridSelector.displayOptions.sortBy.title"),
      key = "sorting",
      default = "automatic",
      hidden = false,
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.sortBy.description"),
      showInModes = {},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.sorting.automatic"), value = "automatic"},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.recentSelections.title"),
      key = "showRecentMode",
      default = "unclustered",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.recentSelections.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        --{label = _tr("ui.menu.gridSelector.clusterOptions.hidden"), value = "hidden"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.reducedClusters"), value = "reducedClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.completeClusters"), value = "completeClusters"},
        {label = _tr("ui.menu.gridSelector.clusterOptions.unclustered"), value = "unclustered"},
      },
    },
    {
      label = _tr("ui.menu.gridSelector.displayOptions.favourites.title"),
      key = "showFavouritesMode",
      default = "reducedClusters",
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
      label = _tr("ui.menu.gridSelector.displayOptions.defaultFreeroamAction.title"),
      key = "defaultFreeroamAction",
      default = "configureFreeroam",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.defaultFreeroamAction.description"),
      save = true,
      showInModes = {},
      options = {
        {label = _tr("ui.freeroam.startFreeroam"), value = "startFreeroam"},
        {label = _tr("ui.freeroam.configureFreeroam"), value = "configureFreeroam"},
      },
    },
  }

  local filterDefinitions = {
    {
      propKey = "source",
      propName = _tr("ui.vehicles.propName.Source"),
      optionOrder = {"official", "mod"},
    },
    {
      propKey = "mapSize",
      propName = _tr("ui.menu.freeroamSelector.filters.mapSize"),
      optionOrder = mapSizeSteps,
    },
    {
      propKey = "region",
      propName = _tr("ui.vehicles.propName.Region"),
    },
  }

  local function createFilters(gameplayList)
    local filterByProp = {}
    for _, item in pairs(gameplayList) do
      for _, definition in ipairs(filterDefinitions) do
        local propVal = getFilterValue(item, definition.propKey)
        filterByProp[definition.propName] = filterByProp[definition.propName] or {}
        filterByProp[definition.propName][propVal] = true
      end
    end

    local filters = {}
    local quickFilters = {}
    for _, definition in ipairs(filterDefinitions) do
      local filterName = definition.propName
      local availableOptions = filterByProp[filterName] or {}
      local options = {}
      local optionOrder = {}
      for index, option in ipairs(definition.optionOrder or {}) do
        optionOrder[option] = index
      end
      for option in pairs(availableOptions) do
        local optionData = {value = option}
        if definition.propKey == "mapSize" and type(option) == "number" then
          optionData.maxValue = mapSizeSteps[optionOrder[option] + 1]
        else
          optionData.label = filterOptionLabel(definition.propKey, option)
        end
        table.insert(options, optionData)
      end
      table.sort(options, function(a, b)
        local aOrder, bOrder = optionOrder[a.value], optionOrder[b.value]
        if aOrder then return not bOrder or aOrder < bOrder end
        if bOrder then return false end
        return a.label < b.label
      end)
      for _, option in ipairs(options) do
        table.insert(quickFilters, {filterName, option.value, option.label})
      end

      table.insert(filters, {
        propName = filterName,
        propKey = definition.propKey,
        type = "set",
        options = options,
      })
    end

    return filters, filterByProp, quickFilters
  end

  local function passesFilters(item, validFilters, searchText)
    -- Check auxiliary content filterInstance
    if not M.displayDataInstance.getDisplayData().showAuxContent and item.isAuxiliary then
      return false
    end

    -- Check search text first
    if searchText and searchText ~= "" then
      local searchTextLower = string.lower(searchText)
      local itemNameLower = string.lower(item.name or "")
      local match = string.find(itemNameLower, searchTextLower, 1, true)


      if not match and item.level then
        match = string.find(string.lower(item.level), searchTextLower, 1, true)
      end
      -- Also search in item properties
      if not match then
        for _, definition in ipairs(filterDefinitions) do
          local propVal = item[definition.propKey]
          if type(propVal) == 'string' then
            local translatedPropVal = filterOptionLabel(definition.propKey, propVal)
            if string.find(string.lower(translatedPropVal), searchTextLower, 1, true) then
              match = true
              break
            end
          end
        end
      end

      if not match and item.filterHook then
        local result = {match = false}
        extensions.hook(item.filterHook, item, searchText, result)
        if result.match then
          match = true
        end
      end

      if not match then
        return false
      end
    end

    -- Check filters
    for _, filterInstance in ipairs(validFilters) do
      local propVal = getFilterValue(item, filterInstance.propKey)
      if filterInstance.currentFilterValues[propVal] == false then
        return false
      end
    end

    return true
  end

  -- Update display data function for gameplay selector
  local targetVersion = 13
  local function updateDisplayData(data, version, targetVersion)
    while version < targetVersion do
      version = version + 1
      -- Add version-specific updates here if needed
      if version == 11 then
        data.showRecentMode = "unclustered"
        data.showFavouritesMode = "reducedClusters"
      elseif version == 12 then
        data.defaultFreeroamAction = "configureFreeroam"
      elseif version == 13 then
        if data.showRecentMode == "hidden" then
          data.showRecentMode = "unclustered"
        end
      end
    end
    log("I", "", "Freeroam selector display data updated to version " .. tostring(version))
    return data
  end

  -- Create display data instance for gameplay selector
  displayDataInstance = displayDataModule.create("/settings/freeroamSelectorData.json", defaultDisplayDataOptions, updateDisplayData, M.backendName, targetVersion)
  M.displayDataInstance = displayDataInstance
  -- Initialize filterInstance module
  filterInstance = filterModule.create(createFilters, {}, {}, {}, M.backendName, passesFilters)
end

local function ensureInstances()
  if not displayDataInstance then
    setupInstances()
  end
end

-- Get UI data for the gameplay selector
function M.getUiData()
  local data = M.getGameplayData()
  return {
    items = data.items,
    displayData = data.displayData,
    filterList = data.filterList,
    activeFilters = data.activeFilters,
    lockedFiltersByProp = data.lockedFiltersByProp,
    backendName = M.backendName,
  }
end

-- Gameplay data storage
local gameplayData = nil
local gameplayDataChanged = false

-- Custom details buttons for freeroam selector
local customDetailsButtons = {}
local managementButtonsEnabled = true
local exitCallback = nil

-- Initialize gameplay data from tile generators
local function initializeGameplayData()
  setupInstances()
  local items = {}

  -- Get items from all tile generators
  extensions.hook("onGameplaySelectorGetTiles", items, M)

  local validItems = {}
  for _, item in pairs(items) do
    if item.validBackends[M.backendName] then
      table.insert(validItems, item)
    end
  end

  items = validItems

  -- Initialize filters with the gameplay data
  filterInstance.initializeFilters(items)
  local filterData = filterInstance.getFilters()

  return {
    items = items,
    filterList = filterData.filterList,
    activeFilters = {},
    lockedFiltersByProp = filterData.lockedFiltersByProp,
    displayData = displayDataInstance.getDisplayData(),
  }
end

-- Getter for gameplayData that initializes if needed
local function getGameplayData()
  if gameplayDataChanged then
    log("I", "", "Reloading gameplay data for gameplay selector")
    gameplayData = initializeGameplayData()
    gameplayDataChanged = false
  end
  gameplayData = gameplayData or initializeGameplayData()
  return gameplayData
end

M.getGameplayData = getGameplayData

-- Mark data as changed when mods are activated/deactivated
M.onModDeactivated = function() gameplayDataChanged = true end
M.onModActivated = function() gameplayDataChanged = true end
M.onModManagerReady = function() gameplayDataChanged = true end
M.onModManagerStateChanged = function() gameplayDataChanged = true end
M.onSettingsChanged = function() gameplayDataChanged = true end
M.onLanguageChanged = function() gameplayDataChanged = true end

-- Get tiles for a specific path
function M.getTiles(path)
  local tiles = require("ge/extensions/ui/gameplaySelector/tiles")
  local groups = tiles.getTiles(path, M)
  if groups[1] and groups[1].label == _tr("ui.menu.gameplaySelector.propValue.system.freeroam") then
    groups[1].label = nil
  end
  return groups
end

-- Check if an item passes the current filters
function M.passesFilters(item)
  -- First check standard filters
  if not filterInstance.passesFilters(item) then
    return false
  end

  -- Check career content filtering
  local displayData = displayDataInstance.getDisplayData()
  if item.isCareerOnly and not displayData.showCareerContent then
    return false
  end

  return true
end

-- Get display data
function M.getDisplayData()
  ensureInstances()
  return displayDataInstance.getDisplayData()
end

-- Update display data
function M.updateDisplayData(key, value)
  ensureInstances()
  displayDataInstance.setDisplayDataOption(key, value)
end

-- Update filterInstance data
function M.updateFilterData(key, value)
  filterInstance.updateData(key, value)
end

-- Clear all filters
function M.clearAllFilters(requestId)
  filterInstance.clearAllFilters()
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
end


-- Check if an item is a favourite
function M.isFavourite(itemKey)
  ensureInstances()
  return displayDataInstance.isFavourite(itemKey)
end

-- Toggle favourite status
function M.toggleFavourite(itemDetails)
  ensureInstances()
  local itemKey = itemDetails.key
  displayDataInstance.toggleFavourite(itemKey)
  return displayDataInstance.isFavourite(itemKey)
end

-- Check if an item is recent
function M.isRecent(itemKey)
  ensureInstances()
  return displayDataInstance.isRecentItem(itemKey)
end

-- Track recent item
function M.trackRecent(itemKey)
  ensureInstances()
  displayDataInstance.trackRecentItem(itemKey)
end

-- Required functions for gridSelector integration

-- Filters
function M.getFilters()
  M.getUiData()
  return filterInstance.getFilters()
end

function M.getActiveFilters()
  return filterInstance.getActiveFilters()
end

-- Apply a full filterByProp shape directly. Used by route lifecycle code that
-- needs to restore persisted wizard filter state safely without replaying UI
-- toggles. Locked filters are preserved by filterInstance.updateFilters.
function M.updateFilters(newFilters)
  return filterInstance.updateFilters(newFilters)
end

function M.toggleFilter(filterKey, value, requestId)
  local result = filterInstance.toggleFilter(filterKey, value)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.updateRangeFilter(filterKey, min, max, requestId)
  local result = filterInstance.updateRangeFilter(filterKey, min, max)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.resetRangeFilter(filterKey, requestId)
  local result = filterInstance.resetRangeFilter(filterKey)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.resetSetFilter(filterKey, requestId)
  local result = filterInstance.resetSetFilter(filterKey)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.getSearchText()
  return filterInstance.getSearchText()
end

function M.setSearchText(text, requestId)
  local result = filterInstance.setSearchText(text)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

-- Display Data
function M.getDisplayDataOptions()
  return displayDataInstance.getDisplayDataOptions()
end

function M.setDisplayDataOption(key, value, requestId)
  local displayData = displayDataInstance.setDisplayDataOption(key, value)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return displayData
end

function M.resetDisplayDataToDefaults(requestId)
  local displayData = displayDataInstance.resetDisplayDataToDefaults()
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return displayData
end

-- General

function M.getScreenHeaderTitleAndPath(path)
  local title = ""
  local pathSegments = {{label = _tr("ui.common.menu"), gotoAngularState = "menu"}}
  local pathType = path and path.keys and path.keys[1]

  table.insert(pathSegments, {label = _tr("ui.menu.freeroamSelector.title"), gotoPath = {'allGameplay'}, clearFilters = true, clearSearch = true})

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
  if #searchSegmentText > 0 then
    table.insert(pathSegments, {label = table.concat(searchSegmentText, ", "), gotoPath = {'allGameplay'}})
  end

  if pathType == "allGameplay" then
    title = _tr("ui.menu.freeroamSelector.title")
  elseif pathType == "detailGameplay" then
    local pathKeys = path.keys or {}
    local clusterMode = pathKeys[2] or "Unknown"
    local clusterKey = pathKeys[3] or "Unknown"
    local groupKey = pathKeys[4] or "Unknown"
    local groupName = pathKeys[5] or "Unknown"

    if clusterMode == "automatic" then
      local filterValue = groupName
      title = string.format("%s", filterValue)
    else
      title = string.format("%s", clusterKey, groupKey, groupName)
    end

    table.insert(pathSegments, {label = title, gotoPath = path.keys})
  elseif pathType == "spawnPointsForLevel" then
    local levelName = path and path.keys and path.keys[2]
    local level = levelName and core_levels.getLevelByName(levelName) or nil
    if level and level.title then
      title = _tr(level.title)
    else
      title = levelName or _tr("ui.menu.freeroamSelector.path.spawnPoints")
    end
    table.insert(pathSegments, {label = title, gotoPath = path.keys})
  else
    title = _tr("ui.menu.freeroamSelector.path.selectLevel")
  end

  if isFiltered then
    title = title .. " (" .. _tr("ui.menu.gridSelector.filtered") .. ")"
  end

  return {
    title = title,
    isFiltered = isFiltered,
    pathSegments = pathSegments
  }
end

function M.profilerFinish()
  -- TODO: Implement profiler finish
end

function M.closedFromUI()
  -- Clear custom buttons and reset management buttons
  customDetailsButtons = {}
  customRootPath = {}
  extensions.hook("onFreeroamSelectorClosed")
end

local buttonInstance = require("ge/extensions/ui/gridSelectorUtils/buttonModule").create()
-- Details
function M.getDetails(item)
  local details = {}
  extensions.hook("onGameplaySelectorGetDetails", item, details, buttonInstance, M)
  if #details == 0 or not details[1] then
    return nil
  end

  return details[1]
end

-- Build and emit a details payload for the given item so the UI can correlate
-- the response with its own requestId. Mirrors the contract used by
-- gameplaySelector / vehicleSelector requestDetails.
function M.requestDetails(item, requestId)
  local details = M.getDetails(item)
  local payload = {
    backendName = M.backendName,
    requestId = requestId,
    item = item,
    details = details,
  }

  guihooks.trigger("freeroamSelectorDetails", payload)
  return payload
end

local DEFAULT_SELECTOR_PATH = { keys = { "allFreeroam" } }
local activeSelectorPath = nil

local function normalizeSelectorPath(path)
  if type(path) ~= "table" then
    return nil
  end
  local rawKeys = path.keys
  if type(rawKeys) ~= "table" then
    return nil
  end
  local keys = {}
  for _, key in ipairs(rawKeys) do
    if type(key) == "string" and key ~= "" then
      table.insert(keys, key)
    end
  end
  if #keys == 0 then
    return nil
  end
  return { keys = keys }
end

-- Record the path of the selector view currently visible to the user. Route
-- lifecycle code (e.g. the freeroam wizard mounts) should call this so that
-- emitDisplayDataSnapshot rebuilds the snapshot against the right path. Pass
-- nil to clear it back to the default root path.
function M.setCurrentSelectorPath(path)
  if path == nil then
    activeSelectorPath = nil
    return
  end
  local normalized = normalizeSelectorPath(path)
  if normalized then
    activeSelectorPath = normalized
  end
end

-- Resolve the path of the freeroam selector view the user is currently looking
-- at. Falls back to the default root path when no active selection has been
-- recorded, mirroring gameplaySelector / vehicleSelector behavior.
function M.resolveCurrentSelectorPath()
  if type(activeSelectorPath) == "table" then
    local normalized = normalizeSelectorPath(activeSelectorPath)
    if normalized then
      return normalized
    end
  end
  return deepcopy(DEFAULT_SELECTOR_PATH)
end

-- Build the current-view selector snapshot and emit it through guihooks so the
-- UI can refresh the grid in response. Vue correlates the response with its
-- own requestId so rapid control changes can drop stale responses. Lua stays
-- authoritative: it resolves the current path and rebuilds the snapshot.
function M.emitDisplayDataSnapshot(requestId)
  local path = M.resolveCurrentSelectorPath()
  local ok, snapshotOrErr = pcall(ui_gridSelector.getSelectorSnapshot, M.backendName, path)
  if not ok then
    log("E", "ui.freeroamSelector",
      string.format("Failed to rebuild freeroam selector snapshot for display refresh: %s", tostring(snapshotOrErr)))
    return false
  end
  guihooks.trigger("freeroamSelectorDisplayDataSnapshot", {
    backendName = M.backendName,
    requestId = requestId,
    snapshot = snapshotOrErr,
  })
  return true
end

-- Custom details buttons management
function M.setCustomDetailsButtons(buttons)
  customDetailsButtons = buttons or {}
end

function M.getCustomDetailsButtons()
  return customDetailsButtons
end

function M.executeButton(buttonId, additionalData)
  return buttonInstance.executeButton(buttonId, additionalData)
end

function M.getManagementDetails()
  -- TODO: Implement management details
  return { buttons = {} }
end

function M.exitCallback()
end

function M.executeDoubleClick(item)
  log("I", "", "Freeroam selector execute double click: " .. dumps(item))
  local details = M.getDetails(item)
  if details and details.buttonInfo then
    for _, button in ipairs(details.buttonInfo) do
      if button.isDoubleClickAction or #details.buttonInfo == 1 then
        M.executeButton(button.buttonId)
        return
      end
    end
  end
end

function M.exploreFolder(path)
  -- TODO: Implement folder exploration
  log("I", "", "Gameplay selector explore folder: " .. tostring(path))
end

function M.goToMod(modId)
  -- TODO: Implement mod navigation
  log("I", "", "Gameplay selector go to mod: " .. tostring(modId))
end

-- Open gameplay selector with freeroam filterInstance enabled
function M.openFreeroamSelector()
  -- Clear all filters first
  M.clearAllFilters()

  -- Set display data options for freeroam
  M.setDisplayDataOption(propName("groupMode"), "system")
  M.setDisplayDataOption(propName("clusterMode"), "automatic")

  -- Enable the freeroam system filterInstance
  M.toggleFilter(propName("system"), propValue("system", "freeroam"))

  -- Open the gameplay selector
  extensions.ui_router.navigate("menu.gameplay")
end

function M.openFromPause()
  -- Pause breadcrumbs now come from router route metadata.
  customRootPath = {}
  local configuredStep = settings.getValue("freeroamSetupDefaultStep") or "level"
  local targetRoute = getWizardRouteByStep(configuredStep, "pause")
  extensions.ui_router.navigate(targetRoute, {returnRoute = "pause"})
end

function M.openFreeroamSelectorForFreeroamConfigurator(callback)
  -- Set custom buttons
  M.setCustomDetailsButtons({
    {
      callback = function(levelName, spawnPointName, key)
        callback(levelName, spawnPointName)
      end,
      meta = {
        label = _tr("ui.menu.freeroamSelector.selectSpawnpoint"),
        icon = "road",
        primary = true,
        isDoubleClickAction = true,
        trackRecent = true,
      }
    }
  })

  customRootPath = {
    {label = _tr("ui.common.menu"), gotoAngularState = "menu"},
    {label = _tr("ui.menu.freeroamSelector.freeroamConfigurator"), gotoAngularState = 'menu.freeroamconfigurator'},
    {label = _tr("ui.menu.freeroamSelector.spawnpointSelection"), gotoPath = {'allFreeroam'}, clearFilters = true, clearSearch = true},
  }

  -- Open the selector
  extensions.ui_router.navigate("menu.freeroamselector")
  -- guihooks.trigger("gridSelectorRefreshAll", "freeroamSelector") -- kept for later reference
  extensions.hook("onFreeroamSelectorOpen")
end

return M
