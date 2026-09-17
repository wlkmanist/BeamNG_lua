-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
M.dependencies = {
  "ui_gameplaySelector_tiles",
  "core_locales"
}
M.backendName = "gameplaySelector"
local customRootPath = {}
-- Load the modules
local displayDataModule = require("ge/extensions/ui/gridSelectorUtils/displayDataModule")
local filterModule = require("ge/extensions/ui/gridSelectorUtils/filterModule")
-- Backend name for this selector

local propName = function(key) return _tr("ui.menu.gameplaySelector.propName." .. key, key) end
local propValue = function(propName, key) return core_locales.translateWithPrefixFallback(key, "ui.menu.gameplaySelector.propValue." .. propName .. ".") end
local othersText = nil
local defaultDisplayDataOptions, displayDataInstance, filterInstance
local activeRouteName = nil
local RALLY_SELECTOR_ROUTE_NAME = "menu.rallySelector"

local function isRallySelectorContext(routeName)
  if routeName ~= nil then
    return routeName == RALLY_SELECTOR_ROUTE_NAME
  end
  if activeRouteName == RALLY_SELECTOR_ROUTE_NAME then
    return true
  end
  if type(extensions) ~= "table" or type(extensions.ui_router) ~= "table"
    or type(extensions.ui_router.getCurrent) ~= "function" then
    return false
  end
  local currentEntry = extensions.ui_router.getCurrent()
  local currentName = currentEntry and currentEntry.resolved and currentEntry.resolved.name
    or currentEntry and currentEntry.request and currentEntry.request.name
    or currentEntry and currentEntry.name
  return currentName == RALLY_SELECTOR_ROUTE_NAME
end

local function copyDisplayData(source)
  local result = {}
  if type(source) == "table" then
    for key, value in pairs(source) do
      result[key] = value
    end
  end
  return result
end

local function getEffectiveDisplayData(routeName)
  local source = displayDataInstance.getDisplayData()
  if not isRallySelectorContext(routeName) then
    return source
  end

  local result = copyDisplayData(source)
  result.groupMode = source.groupModeRally or "type"
  result.clusterMode = source.clusterModeRally or "none"
  return result
end

local function getContextDisplayDataOptions(routeName)
  local isRallySelector = isRallySelectorContext(routeName)
  local result = {}
  for _, option in ipairs(displayDataInstance.getDisplayDataOptions()) do
    local key = option.key
    local shouldHide = (isRallySelector and (key == "groupMode" or key == "clusterMode"))
      or (not isRallySelector and (key == "groupModeRally" or key == "clusterModeRally"))
    if not shouldHide then
      table.insert(result, option)
    end
  end
  return result
end

local setupInstances = function()
  othersText = _tr("ui.menu.gridSelector.other")
  -- Default display data options for gameplay selector
  defaultDisplayDataOptions = {
    {
      label = _tr("ui.menu.gridSelector.displayOptions.groupBy.title"),
      key = "groupMode",
      default = "system",
      type = "dropdown",
      description = _tr("ui.menu.gridSelector.displayOptions.groupBy.description"),
      save = true,
      showInModes = {default = true, filterInstance = true, displayControls = true},
      options = {
        {label = _tr("ui.menu.gameplaySelector.propName.system"), value = "system"},
        {label = _tr("ui.menu.gameplaySelector.propName.type"), value = "type"},
        {label = _tr("ui.menu.gameplaySelector.propName.level"), value = "level"},
        {label = _tr("ui.menu.gameplaySelector.propName.none"), value = "none"},
      },
    },
    {
      label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.title"),
      key = "clusterMode",
      default = "automatic",
      type = "dropdown",
      description = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.description"),
      save = true,
      showInModes = {default = true, filterInstance = true, displayControls = true},
      options = {
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.automatic"), value = "automatic"},
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.type"), value = "type"},
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.level"), value = "level"},
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.none"), value = "none"},
      },
    },
    {
      label = _tr("ui.menu.gameplaySelector.displayOptions.groupByRally.title"),
      key = "groupModeRally",
      default = "type",
      type = "dropdown",
      description = _tr("ui.menu.gameplaySelector.displayOptions.groupByRally.description"),
      save = true,
      showInModes = {default = true, filterInstance = true, displayControls = true},
      options = {
        {label = _tr("ui.menu.gameplaySelector.propName.system"), value = "system"},
        {label = _tr("ui.menu.gameplaySelector.propName.type"), value = "type"},
        {label = _tr("ui.menu.gameplaySelector.propName.level"), value = "level"},
        {label = _tr("ui.menu.gameplaySelector.propName.none"), value = "none"},
      },
    },
    {
      label = _tr("ui.menu.gameplaySelector.displayOptions.clusterByRally.title"),
      key = "clusterModeRally",
      default = "none",
      type = "dropdown",
      description = _tr("ui.menu.gameplaySelector.displayOptions.clusterByRally.description"),
      save = true,
      showInModes = {default = true, filterInstance = true, displayControls = true},
      options = {
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.automatic"), value = "automatic"},
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.type"), value = "type"},
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.level"), value = "level"},
        {label = _tr("ui.menu.gameplaySelector.displayOptions.clusterBy.none"), value = "none"},
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
      label = _tr("ui.menu.gridSelector.displayOptions.includeCareerContent.title"),
      key = "showCareerContent",
      default = false,
      hidden = false,
      hideInSimpleMenu = true,
      type = "checkbox",
      description = _tr("ui.menu.gridSelector.displayOptions.includeCareerContent.description"),
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
      save = true,
      showInModes = {displayControls = true, default = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.sortBy.automatic"), value = "automatic"},
        {label = _tr("ui.menu.gridSelector.displayOptions.sortBy.name"), value = "name"},
        {label = _tr("ui.menu.gridSelector.displayOptions.sortBy.date"), value = "date"},
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
        {label = _tr("ui.menu.gridSelector.clusterOptions.hidden"), value = "hidden"},
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

  -- Gameplay-specific filterInstance configuration
  local filtersWhiteList = {
    "system",
    "type",
    "level",
  }

  local rangeFilters = tableValuesAsLookupDict({

  })

  local commonFilters = {
    --{"system", "Freeroam"},
    {propName("system"), propValue("system", "challenges")},
    {propName("system"), propValue("system", "scenarios")},
    {propName("system"), propValue("system", "scenariosMultiplayer")},
    {propName("system"), propValue("system", "campaigns")},
  }

  -- Gameplay-specific filterInstance creation function
  local function createGameplayFilters(gameplayList)
    local filterByProp = {}

    if gameplayList then
      for _, item in pairs(gameplayList) do
        for _, propKey in pairs(filtersWhiteList) do
          local propName = propName(propKey)
          local propVal = item[propKey]
          if propVal == nil then
            propVal = item[propKey]
          end
          if propVal == nil then
            propVal = othersText
          end

          if not filterByProp[propName] then
            filterByProp[propName] = {}
          end

          if type(propVal) == "table" then
            for _, val in pairs(propVal) do
              filterByProp[propName][propValue(propKey, val)] = true
            end
          else
            filterByProp[propName][propValue(propKey, propVal)] = true
          end
        end
      end
    end

    local filters = {}
    for _, propKey in pairs(filtersWhiteList) do
      local propName = propName(propKey)
      local options = {}
      for option, _ in pairs(filterByProp[propName] or {}) do
        table.insert(options, option)
      end
      table.sort(options)

      local filterType = rangeFilters[propKey] and "range" or "set"
      table.insert(filters, {
        propName = propName,
        propKey = propKey,
        type = filterType,
        options = options,
        currentFilterValues = {},
        currentMin = nil,
        currentMax = nil,
        min = nil,
        max = nil,
      })
    end

    return filters, filterByProp
  end

  -- Gameplay-specific filterInstance check function
  local function gameplayPassesFilters(item, validFilters, searchText)
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
        for _, propName in pairs(filtersWhiteList) do
          local propVal = item[propName:lower()] or item[propName]
          if type(propVal) == 'string' then
            if string.find(string.lower(propVal), searchTextLower, 1, true) then
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
      local propVal = item[filterInstance.propKey]
      if propVal == nil then
        propVal = item[filterInstance.propKey]
      end
      if propVal == nil then
        propVal = othersText
      end
      if type(propVal) == 'string' then
        propVal = propValue(filterInstance.propKey, propVal)
      end

      if filterInstance.type == 'set' then
        for _, option in pairs(filterInstance.options) do
          if propVal == option and not filterInstance.currentFilterValues[option] then
            return false
          end
        end
      end
      if filterInstance.type == 'range' then
        if propVal == othersText or not type(propVal) == 'number' then
          return false
        end
        if (propVal < filterInstance.currentMin) or (propVal > filterInstance.currentMax) then
          return false
        end
      end
    end
    return true
  end

  -- Update display data function for gameplay selector
  local targetVersion = 12
  local function updateDisplayData(data, version, targetVersion)
    while version < targetVersion do
      version = version + 1
      -- Add version-specific updates here if needed
      if version == 11 then
        data.defaultFreeroamAction = "configureFreeroam"
      elseif version == 12 then
        data.groupModeRally = data.groupModeRally or "type"
        data.clusterModeRally = data.clusterModeRally or "none"
      end
    end
    log("I", "", "Gameplay selector display data updated to version " .. tostring(version))
    return data
  end

  -- Create display data instance for gameplay selector
  displayDataInstance = displayDataModule.create("/settings/gameplaySelectorData.json", defaultDisplayDataOptions, updateDisplayData, M.backendName, targetVersion)
  M.displayDataInstance = displayDataInstance
  -- Initialize filterInstance module
  filterInstance = filterModule.create(createGameplayFilters, commonFilters, rangeFilters, {}, M.backendName, gameplayPassesFilters)
end
-- Get UI data for the gameplay selector
function M.getUiData(routeName)
  local data = M.getGameplayData()
  return {
    items = data.items,
    displayData = getEffectiveDisplayData(routeName),
    filterList = data.filterList,
    activeFilters = data.activeFilters,
    lockedFiltersByProp = data.lockedFiltersByProp,
    backendName = M.backendName,
  }
end

-- Gameplay data storage
local gameplayData = nil
local gameplayDataChanged = false

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
M.isGameplayDataLoaded = function()
  return gameplayData and not gameplayDataChanged
end

-- Mark data as changed when mods are activated/deactivated
M.onModDeactivated = function() gameplayDataChanged = true end
M.onModActivated = function() gameplayDataChanged = true end
M.onModManagerReady = function() gameplayDataChanged = true end
M.onModManagerStateChanged = function() gameplayDataChanged = true end
M.onSettingsChanged = function() gameplayDataChanged = true end

-- Get tiles for a specific path
function M.getTiles(path, routeName)
  local tiles = require("ge/extensions/ui/gameplaySelector/tiles")
  return tiles.getTiles(path, M, routeName)
end

local function normalizeKeysList(rawKeys)
  if type(rawKeys) ~= "table" then
    return {}
  end
  local keys = {}
  for _, key in ipairs(rawKeys) do
    if type(key) == "string" then
      table.insert(keys, key)
    end
  end
  return keys
end

local function resolveClusterKeysFromInput(input)
  if type(input) ~= "table" then
    return {}
  end
  if type(input.gotoPath) == "table" then
    return normalizeKeysList(input.gotoPath)
  end
  if type(input.keys) == "table" then
    return normalizeKeysList(input.keys)
  end
  return normalizeKeysList(input)
end

local function resolveClusterTitleFromInput(input, keys)
  if type(input) == "table" then
    if type(input.name) == "string" and input.name ~= "" then
      return input.name
    end
    if type(input.label) == "string" and input.label ~= "" then
      return input.label
    end
    if type(input.title) == "string" and input.title ~= "" then
      return input.title
    end
  end
  local headerInfo = M.getScreenHeaderTitleAndPath({ keys = keys })
  if type(headerInfo) == "table" and type(headerInfo.title) == "string" and headerInfo.title ~= "" then
    return headerInfo.title
  end
  return _tr("ui.menu.gameplaySelector.clusterTitle")
end

local pendingClusterSelection = nil
local activeClusterSelection = nil

local DEFAULT_CLUSTER_SELECTION_KEYS = { "allGameplay" }

local function getDefaultClusterSelection()
  return {
    keys = deepcopy(DEFAULT_CLUSTER_SELECTION_KEYS),
    title = _tr("ui.menu.gameplaySelector.clusterTitle"),
  }
end

local function copyClusterSelection(selection)
  if type(selection) ~= "table" then
    return nil
  end
  return {
    keys = normalizeKeysList(selection.keys),
    title = type(selection.title) == "string" and selection.title or nil,
  }
end

function M.navigateToCluster(input)
  dump("navigateToCluster", input)
  local keys = resolveClusterKeysFromInput(input)
  local clusterTitle = resolveClusterTitleFromInput(input, keys)
  pendingClusterSelection = {
    keys = keys,
    title = clusterTitle,
  }
  dump("pendingClusterSelection", pendingClusterSelection)
  return extensions.ui_router.navigate("menu.gameplay.type")
end

function M.requestDetails(item, requestId)
  local details = M.getDetails(item)
  local payload = {
    backendName = M.backendName,
    requestId = requestId,
    item = item,
    details = details,
  }

  guihooks.trigger("gameplaySelectorDetails", payload)
  return payload
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
function M.getDisplayData(routeName)
  return getEffectiveDisplayData(routeName)
end

-- Update display data
function M.updateDisplayData(key, value)
  displayDataInstance.setDisplayDataOption(key, value)
end

-- Update filterInstance data
function M.updateFilterData(key, value)
  filterInstance.updateData(key, value)
end

-- Clear all filters
function M.clearAllFilters()
  filterInstance.clearAllFilters()
end


-- Check if an item is a favourite
function M.isFavourite(itemKey)
  return displayDataInstance.isFavourite(itemKey)
end

-- Toggle favourite status
function M.toggleFavourite(itemDetails)
  local itemKey = itemDetails.key
  displayDataInstance.toggleFavourite(itemKey)
  return displayDataInstance.isFavourite(itemKey)
end

-- Check if an item is recent
function M.isRecent(itemKey)
  return displayDataInstance.isRecentItem(itemKey)
end

-- Track recent item
function M.trackRecent(itemKey)
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
function M.getDisplayDataOptions(routeName)
  return getContextDisplayDataOptions(routeName or activeRouteName)
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

  table.insert(pathSegments, {label = _tr("ui.menu.gameplaySelector.title"), gotoPath = {'allGameplay'}, clearFilters = true, clearSearch = true})

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
    title = _tr("ui.menu.gameplaySelector.path.allGameplay")
  elseif pathType == "detailGameplay" then
    local pathKeys = path.keys or {}
    local clusterMode = pathKeys[2] or "Unknown"
    local clusterKey = pathKeys[3] or "Unknown"
    local groupKey = pathKeys[4] or "Unknown"
    local groupName = pathKeys[5] or "Unknown"

    if clusterMode == "automatic" then
      local filterValue = groupName
      if groupName == "Unknown" then
        filterValue = clusterKey
      end
      title = string.format("%s", filterValue)
    else
      title = string.format("%s", clusterKey, groupKey, groupName)
    end

    table.insert(pathSegments, {label = title, gotoPath = path.keys})
  else
    title = _tr("ui.menu.gameplaySelector.title")
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
  -- TODO: Implement cleanup when closed from UI
end

local buttonInstance = require("ge/extensions/ui/gridSelectorUtils/buttonModule").create()
-- Details
function M.getDetails(item)
  -- TODO: Implement details for gameplay items
  local details = {}
  extensions.hook("onGameplaySelectorGetDetails", item, details, buttonInstance, M)
  if #details == 0 or not details[1] then
    return nil
  end
  return details[1]
end

function M.executeButton(buttonId, additionalData)
  return buttonInstance.executeButton(buttonId, additionalData)
end

function M.getManagementDetails()
  -- TODO: Implement management details
  return { buttons = {} }
end

function M.exitCallback()
  -- TODO: Implement exit callback
end

function M.executeDoubleClick(item)
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

local DEFAULT_ROUTE_PATH = { keys = { "allGameplay" } }

local GAMEPLAY_ROUTE_PRESETS = {
  ["menu.rallySelector"] = {
    -- Rally tiles store item.type as the translated missionTypeLabel. Use the
    -- translation keys so applyPresetFilterEntry resolves them to the active
    -- locale via propValue (same path as filter option matching).
    filters = {
      { propKey = "type", value = "bigMap.missionLabels.rallyStage" },
      { propKey = "type", value = "bigMap.missionLabels.rallyLoop" },
    },
  },
}

local function clearRouteFiltersAndSearch()
  M.getUiData()
  M.clearAllFilters()
  M.setSearchText("")
end

local function applyPresetFilterEntry(entry)
  if type(entry) ~= "table" then
    return
  end
  local propKey = entry.propKey
  if type(propKey) ~= "string" or propKey == "" then
    return
  end
  local rawValue = entry.value
  if type(rawValue) ~= "string" or rawValue == "" then
    return
  end
  local filterValue = rawValue
  if entry.translateValue ~= false then
    filterValue = propValue(propKey, rawValue)
  end
  if type(filterValue) ~= "string" or filterValue == "" then
    return
  end
  M.toggleFilter(propName(propKey), filterValue)
end

local function applyRoutePreset(routeName)
  local preset = GAMEPLAY_ROUTE_PRESETS[routeName] or {}
  clearRouteFiltersAndSearch()
  if type(preset.displayOptions) == "table" then
    for key, value in pairs(preset.displayOptions ) do
      M.setDisplayDataOption(key, value)
    end
  end
  if type(preset.systemFilterKey) == "string" and preset.systemFilterKey ~= "" then
    applyPresetFilterEntry({ propKey = "system", value = preset.systemFilterKey })
  end
  if type(preset.filters) == "table" then
    for _, entry in ipairs(preset.filters) do
      applyPresetFilterEntry(entry)
    end
  end
end

local function buildRouteMountSnapshot(path, routeName)
  local resolvedPath
  if type(path) == "table" and type(path.keys) == "table" then
    resolvedPath = { keys = normalizeKeysList(path.keys) }
  else
    resolvedPath = deepcopy(DEFAULT_ROUTE_PATH)
  end
  return {
    backendName = M.backendName,
    path = resolvedPath,
    groups = M.getTiles(resolvedPath, routeName),
    filters = M.getFilters(),
    displayData = getContextDisplayDataOptions(routeName),
    managementDetails = M.getManagementDetails(),
    searchText = M.getSearchText(),
    header = M.getScreenHeaderTitleAndPath(resolvedPath),
  }
end

local function attachSnapshotToRouteData(data, path, routeName)
  if type(data) ~= "table" then
    return
  end
  local ok, snapshotOrErr = pcall(buildRouteMountSnapshot, path, routeName)
  if not ok then
    log("E", "ui.gameplaySelector", string.format("Failed to build gameplay selector route mount snapshot: %s", tostring(snapshotOrErr)))
    return
  end
  data.gameplaySelector = {
    backendName = M.backendName,
    snapshot = snapshotOrErr,
  }
end

-- Tracks the most recent gameplay selector route the UI is mounted on while
-- async data loading runs. Captured at onRouteMount / onClusterRouteMount and
-- consumed by asyncGameplaySelectorLoadComplete so the snapshot we emit always
-- matches the route the user actually navigated to (guards against stale
-- completions firing for a navigation that has since been replaced).
local pendingRouteMount = nil

local function describePathForLog(path)
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

local function emitRouteMountSnapshot(pending)
  if type(pending) ~= "table" then
    return false
  end

  applyRoutePreset(pending.routeName)

  local ok, snapshotOrErr = pcall(buildRouteMountSnapshot, pending.path, pending.routeName)
  if not ok then
    log("E", "ui.gameplaySelector", string.format("Failed to build gameplay selector route mount snapshot: %s", tostring(snapshotOrErr)))
    return false
  end

  local payload = {
    backendName = M.backendName,
    routeName = pending.routeName,
    snapshot = snapshotOrErr,
  }
  if type(pending.cluster) == "table" then
    payload.cluster = {
      keys = normalizeKeysList(pending.cluster.keys),
      title = pending.cluster.title,
    }
  end

  print(string.format(
    "[ui.gameplaySelector] emitting GameplaySelectorDataLoaded for route=%s path=%s",
    tostring(pending.routeName), describePathForLog(pending.path)
  ))

  guihooks.trigger("GameplaySelectorDataLoaded", payload)
  return true
end

local function beginAsyncRouteMount(routeName, path, clusterInfo)
  pendingRouteMount = {
    routeName = routeName,
    path = path,
    cluster = clusterInfo,
  }

  print(string.format(
    "[ui.gameplaySelector] beginAsyncRouteMount route=%s path=%s",
    tostring(routeName), describePathForLog(path)
  ))

  if type(extensions) ~= "table" or type(extensions.util_asyncBulkLoader) ~= "table"
    or type(extensions.util_asyncBulkLoader.loadGameplaySelector) ~= "function" then
    log("W", "ui.gameplaySelector", "util_asyncBulkLoader.loadGameplaySelector unavailable; emitting snapshot synchronously")
    local snapshotPending = pendingRouteMount
    pendingRouteMount = nil
    emitRouteMountSnapshot(snapshotPending)
    return
  end

  local result = extensions.util_asyncBulkLoader.loadGameplaySelector()
  if result == "alreadyLoaded" then
    print("[ui.gameplaySelector] gameplay data already loaded; emitting snapshot immediately")
    local snapshotPending = pendingRouteMount
    pendingRouteMount = nil
    emitRouteMountSnapshot(snapshotPending)
  end
end

-- Listens for the asyncBulkLoader completion hook so we can build and emit the
-- gameplay selector snapshot only after the heavy data is ready. The pending
-- route is compared against the active router entry to discard stale completions
-- caused by rapid route changes.
function M.asyncGameplaySelectorLoadComplete()
  local pending = pendingRouteMount
  if type(pending) ~= "table" then
    return
  end
  pendingRouteMount = nil

  if not isPendingRouteStillCurrent(pending) then
    print(string.format(
      "[ui.gameplaySelector] async load completed for stale route=%s; skipping snapshot emit",
      tostring(pending.routeName)
    ))
    return
  end

  emitRouteMountSnapshot(pending)
end

-- Resolve the path of the gameplay selector view the user is currently looking
-- at. Cluster routes track their selection through onClusterRouteEnter /
-- onClusterRouteMount, so a non-nil activeClusterSelection means we are in a
-- cluster view. Root routes clear it via onRouteMount.
function M.resolveCurrentSelectorPath()
  if type(activeClusterSelection) == "table" then
    local keys = normalizeKeysList(activeClusterSelection.keys)
    if #keys > 0 then
      return { keys = keys }
    end
  end
  return deepcopy(DEFAULT_ROUTE_PATH)
end

-- Build the current-view selector snapshot and emit it through guihooks so the
-- UI can refresh the grid in response. Vue correlates the response with its
-- own requestId so rapid control changes can drop stale responses. Lua stays
-- authoritative: it resolves the current path and rebuilds groups, filters,
-- displayData, managementDetails, header, etc.
function M.emitDisplayDataSnapshot(requestId)
  local path = M.resolveCurrentSelectorPath()
  local ok, snapshotOrErr = pcall(buildRouteMountSnapshot, path, activeRouteName)
  if not ok then
    log("E", "ui.gameplaySelector", string.format("Failed to rebuild gameplay selector snapshot for display refresh: %s", tostring(snapshotOrErr)))
    return false
  end
  guihooks.trigger("gameplaySelectorDisplayDataSnapshot", {
    backendName = M.backendName,
    requestId = requestId,
    snapshot = snapshotOrErr,
  })
  return true
end

function M.onRouteMount(context, toRoute, fromRoute, data)
  activeClusterSelection = nil
  pendingClusterSelection = nil
  local routeName = toRoute and toRoute.name or nil
  activeRouteName = routeName
  beginAsyncRouteMount(routeName, deepcopy(DEFAULT_ROUTE_PATH), nil)
end

function M.onClusterRouteEnter(context, toRoute, fromRoute, data)
  -- Promote the pending selection set by navigateToCluster, otherwise reset to
  -- the default cluster so direct navigation to menu.gameplay.type never shows
  -- stale cluster data from an earlier selection.
  if pendingClusterSelection then
    activeClusterSelection = copyClusterSelection(pendingClusterSelection)
    pendingClusterSelection = nil
  else
    activeClusterSelection = getDefaultClusterSelection()
  end
end

function M.onClusterRouteMount(context, toRoute, fromRoute, data)
  dump("onClusterRouteMount selection", activeClusterSelection)
  local selection = activeClusterSelection or getDefaultClusterSelection()
  local keys = normalizeKeysList(selection.keys)
  if #keys == 0 then
    keys = normalizeKeysList(DEFAULT_CLUSTER_SELECTION_KEYS)
  end
  local routeName = toRoute and toRoute.name or nil
  activeRouteName = routeName
  local clusterInfo = {
    keys = keys,
    title = selection.title,
  }
  beginAsyncRouteMount(routeName, { keys = keys }, clusterInfo)
end

function M.resolveClusterTitle(clusterTitle)
  if type(activeClusterSelection) == "table"
    and type(activeClusterSelection.title) == "string"
    and activeClusterSelection.title ~= "" then
    return activeClusterSelection.title
  end
  if type(clusterTitle) == "string" and clusterTitle ~= "" then
    return clusterTitle
  end
  return nil
end

local function openSelectorRoute(routeName)
  activeRouteName = routeName
  applyRoutePreset(routeName)
  extensions.ui_router.navigate(routeName)
end

function M.openGameplaySelector()
  openSelectorRoute("menu.gameplay")
end

function M.openRallySelector()
  openSelectorRoute("menu.rallySelector")
end

return M
