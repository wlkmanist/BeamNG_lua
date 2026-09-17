-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_apps",
}

-- Helpers
local function getApps()
  return ui_apps.getUIAppsData() or {}
end

-- Load the modules
local displayDataModule = require("ge/extensions/ui/gridSelectorUtils/displayDataModule")
local filterModule = require("ge/extensions/ui/gridSelectorUtils/filterModule")
local buttonModule = require("ge/extensions/ui/gridSelectorUtils/buttonModule")

-- Backend name for this selector
local backendName = "appSelector"
M.backendName = backendName

-- Build display options lazily to avoid calling _tr() during module load.
local function getDefaultDisplayDataOptions()
  return {
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
      key = "includeAuxContent",
      default = false,
      type = "checkbox",
      description = _tr("ui.menu.gridSelector.displayOptions.includeAuxContent.description"),
      save = true,
      showInModes = {displayControls = true},
      options = {
        {label = _tr("ui.menu.gridSelector.displayOptions.included"), value = true},
        {label = _tr("ui.menu.gridSelector.displayOptions.excluded"), value = false},
      },
    },
  }
end

-- Update display data if needed (versioned migrations)
local function updateDisplayData(saved, version, targetVersion)
  return saved or {}
end

-- Instances
local displayDataInstance = nil
local buttonInstance = buttonModule.create()

local function getDisplayDataInstance()
  if not displayDataInstance then
    displayDataInstance = displayDataModule.create("/settings/appSelectorData.json", getDefaultDisplayDataOptions(), updateDisplayData, backendName, 1)
  end
  return displayDataInstance
end

-- App data storage
local appData = nil
local appDataChanged = false

-- App-specific filter configuration
local filtersWhiteList = {
  "Type",
}

local INTERNAL_TYPE_KEY = "ui.apps.categories.internal"

local function getDisplayTypes(app)
  local types = {}
  for index, typeKey in ipairs(app.types or {}) do
    if typeKey ~= INTERNAL_TYPE_KEY then
      table.insert(types, app.typesTranslated[index] or typeKey)
    end
  end
  return types
end

-- Build filters from available apps
local function createFilters(apps)
  local filterByProp = {}

  -- Types set filter
  if apps then
    for _, app in pairs(apps) do
      for _, type in ipairs(getDisplayTypes(app)) do
        if not filterByProp["Type"] then
          filterByProp["Type"] = {}
        end
        filterByProp["Type"][type] = true
      end
    end
  end

  local filters = {}
  local commonFilters = {}
  for _, propName in pairs(filtersWhiteList) do
    if filterByProp[propName] then
      local options = {}
      for option, _ in pairs(filterByProp[propName]) do
        table.insert(options, option)
      end
      -- Sort by translated label
      table.sort(options, function(a, b)
        return a < b
      end)

      table.insert(filters, {
        propName = propName,
        type = "set",
        options = options,
        currentFilterValues = {},
        currentMin = nil,
        currentMax = nil,
        min = nil,
        max = nil,
      })
      if propName == "Type" then
        for _, t in ipairs(options) do
          table.insert(commonFilters, {propName, t})
        end
      end
    end
  end

  return filters, filterByProp, commonFilters
end

local function passesFiltersFunction(item, validFilters, searchText)
  -- search by localized name and description
  if searchText and searchText ~= "" then
    local q = string.lower(searchText)
    local match = false
    if not match and item.name then
      match = string.find(string.lower(core_locales.translateWithOrWithoutContext(item.name)), q, 1, true)
    end
    if not match and item.appName then
      match = string.find(string.lower(core_locales.translateWithOrWithoutContext(item.appName)), q, 1, true)
    end
    if not match and item.description then
      match = string.find(string.lower(core_locales.translateWithOrWithoutContext(item.description)), q, 1, true)
    end
    if not match then
      return false
    end
  end

  -- Check filters
  for _, filter in ipairs(validFilters or {}) do
    if filter.propName == "Type" then
      local anyEnabled = false
      for _, type in ipairs(getDisplayTypes(item)) do
        -- Check if this type is enabled in the filter
        if filter.currentFilterValues and filter.currentFilterValues[type] ~= false then
          anyEnabled = true
          break
        end
      end
      if not anyEnabled then return false end
    end
  end
  return true
end



local rangeFilters = {}
local DEFAULT_ROUTE_PATH = { keys = {"allApps"} }

local CATEGORY_KEYS = {
  Dashboard = "ui.apps.categories.dashboard",
  Telemetry = "ui.apps.categories.telemetry",
  General = "ui.apps.categories.general",
  Gameplay = "ui.apps.categories.gameplay",
  Debug = "ui.apps.categories.debug",
  Embedded = "ui.apps.categories.embedded",
}

local function translateCategory(category)
  local key = CATEGORY_KEYS[category]
  if key then
    return _tr(key)
  end
  return category
end

local function normalizeRoutePath(path)
  if type(path) == "table" and type(path.keys) == "table" then
    local normalizedKeys = {}
    for _, key in ipairs(path.keys) do
      if type(key) == "string" and key ~= "" then
        table.insert(normalizedKeys, key)
      end
    end
    if #normalizedKeys > 0 then
      return { keys = normalizedKeys }
    end
  end

  return { keys = {"allApps"} }
end

-- Initialize app data from apps module
local function initializeAppData()
  local apps = getApps()

  -- Initialize filters with the app data
  local filterInstance = filterModule.create(createFilters, {}, rangeFilters, {},backendName, passesFiltersFunction)
  filterInstance.initializeFilters(apps)
  local filterData = filterInstance.getFilters()

  return {
    apps = apps,
    filterInstance = filterInstance,
    filterList = filterData.filterList,
    activeFilters = {},
    lockedFiltersByProp = filterData.lockedFiltersByProp,
    displayData = getDisplayDataInstance().getDisplayData(),
  }
end

-- Getter for appData that initializes if needed
local function getAppData()
  if appDataChanged then
    log("I", "", "Reloading app data for app selector")
    appData = initializeAppData()
    appDataChanged = false
  end
  appData = appData or initializeAppData()
  return appData
end

M.getAppData = getAppData

-- Mark data as changed when apps are updated
M.onModDeactivated = function() appDataChanged = true end
M.onModActivated = function() appDataChanged = true end
M.onModManagerReady = function() appDataChanged = true end



local function appToTile(app)
  -- Build source icons array
  local sourceIcons = {}

  -- Add official icon if app is official
  if app.official then
    table.insert(sourceIcons, {
      icon = "beamNG",
    })
  end

  -- Add mouse icon if app requires mouse
  if app.interactive == "required" then
    table.insert(sourceIcons, {
      icon = "mouse"
    })
  end

  if not shipping_build and app.vue then
    table.insert(sourceIcons, {
      svg = "/ui/assets/Original/vuedotjs.svg"
    })

  end

  local types = getDisplayTypes(app)

  return {
    key = app.appName,
    name = core_locales.translateWithOrWithoutContext(app.name or app.appName),
    preview = (app.previews and app.previews[1]) or "/ui/modules/apps/common/default.png",
    showDetails = { appName = app.appName },
    doubleClickDetails = { appName = app.appName },
    doubleClickMode = "", -- default
    subElementCount = 0,
    showFavouriteIconPercent = 0,
    isAuxiliary = app.isAuxiliary or false,
    -- Keep original types for filtering
    types = types,
    -- Add translated types for display if available
    typesTranslated = types,
    -- Add source icons for official and mouse-only apps
    sourceIcons = sourceIcons,
  }
end

-- API required by GridSelector

function M.getTiles(path)
  local data = getAppData()
  local apps = data.apps
  local filterInstance = data.filterInstance

  -- build flat list of items and apply filters/search
  local items = {}
  for _, app in pairs(apps) do
    if app.photomode ~= true
      and (data.displayData.includeAuxContent or not app.isAuxiliary)
      and filterInstance.passesFilters(app) then
      table.insert(items, app)
    end
  end

  -- sort items within each category (hardcoded sorting)
  table.sort(items, function(a, b)
    -- First sort by auxiliary status (non-auxiliary first)
    local aAux = a.isAuxiliary or false
    local bAux = b.isAuxiliary or false
    if aAux ~= bAux then
      return not aAux -- non-auxiliary (false) comes before auxiliary (true)
    end

    -- Then sort by name
    local an = string.lower(a.name or a.appName or "")
    local bn = string.lower(b.name or b.appName or "")
    return an < bn
  end)

  -- group by category
  local categoryGroups = {}
  for _, app in ipairs(items) do
    local category = app.category or "General"
    if not categoryGroups[category] then
      categoryGroups[category] = {}
    end
    table.insert(categoryGroups[category], appToTile(app))
  end

  -- define category sort order
  local categoryOrder = {
    "Dashboard",
    "Telemetry",
    "General",
    "Gameplay",
    "Debug"
  }

  -- create category order lookup
  local categoryOrderLookup = {}
  for i, cat in ipairs(categoryOrder) do
    categoryOrderLookup[cat] = i
  end

  -- sort categories and build result
  local sortedGroups = {}

  -- first add categories in specified order
  for _, category in ipairs(categoryOrder) do
    if categoryGroups[category] then
      table.insert(sortedGroups, {
        label = translateCategory(category),
        tiles = categoryGroups[category]
      })
      categoryGroups[category] = nil -- remove from remaining groups
    end
  end

  -- then add remaining categories sorted by name
  local remainingCategories = {}
  for category, _ in pairs(categoryGroups) do
    table.insert(remainingCategories, category)
  end
  table.sort(remainingCategories)

  for _, category in ipairs(remainingCategories) do
    table.insert(sortedGroups, {
      label = translateCategory(category),
      tiles = categoryGroups[category]
    })
  end

  return sortedGroups
end

function M.getFilters()
  local data = getAppData()
  return data.filterInstance.getFilters()
end

function M.getActiveFilters()
  local data = getAppData()
  return data.filterInstance.getActiveFilters()
end

function M.toggleFilter(filterKey, value, requestId)
  local data = getAppData()
  local result = data.filterInstance.toggleFilter(filterKey, value)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.updateRangeFilter(filterKey, min, max, requestId)
  local data = getAppData()
  local result = data.filterInstance.updateRangeFilter(filterKey, min, max)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.resetRangeFilter(filterKey, requestId)
  local data = getAppData()
  local result = data.filterInstance.resetRangeFilter(filterKey)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.resetSetFilter(filterKey, requestId)
  local data = getAppData()
  local result = data.filterInstance.resetSetFilter(filterKey)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.clearAllFilters(requestId)
  local data = getAppData()
  local result = data.filterInstance.clearAllFilters()
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.getDisplayDataOptions()
  return getDisplayDataInstance().getDisplayDataOptions()
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

function M.getSearchText()
  local data = getAppData()
  return data.filterInstance.getSearchText()
end

function M.setSearchText(val, requestId)
  local data = getAppData()
  local result = data.filterInstance.setSearchText(val)
  if requestId ~= nil then
    M.emitDisplayDataSnapshot(requestId)
  end
  return result
end

function M.getScreenHeaderTitleAndPath(path)
  local data = getAppData()
  local isFiltered, isSearch = false, false
  local searchText = data.filterInstance.getSearchText()
  if searchText and searchText ~= "" then
    isSearch = true
  end
  local activeFilters = data.filterInstance.calculateActiveFilters()
  if #activeFilters > 0 then
    isFiltered = true
  end
  local pathSegments = {
    { label = _tr("ui.common.menu"), gotoAngularState = "menu" },
    { label = _tr("ui.dashboard.appedit"), routeName = "pause.hudApps.editlayout" },
    { label = _tr("ui.appselect.apps"), gotoPath = {"allApps"}, clearSearch = true, clearFilters = true },
  }
  local searchSegmentText = {}
  if isFiltered then
    table.insert(searchSegmentText, _tr("ui.menu.gridSelector.filtered"))
  end
  if isSearch then
    table.insert(searchSegmentText, _tr("ui.menu.gridSelector.search") .. ": " .. searchText)
  end
  if #searchSegmentText > 0 then
    table.insert(pathSegments, { label = table.concat(searchSegmentText, ", "), gotoPath = {"allApps"} })
  end

  return {
    title = _tr("ui.dashboard.appedit"),
    pathSegments = pathSegments,
    isFiltered = isFiltered,
  }
end

-- Details
function M.getDetails(details)
  details = type(details) == "table" and details or {}
  local apps = getApps()
  local app = apps and apps[details.appName]
  if not app then return { headerTitle = _tr("ui.apps.selector.fallbackAppName") } end

  -- Clear previous button functions
  buttonInstance.clearButtonFunctions()

  -- Add "Add to layout" button
  local addToLayoutButton = buttonInstance.addButton(function(additionalData)
    guihooks.trigger('appContainer:spawn', { appName = app.appName })
    extensions.ui_router.navigate("pause.hudApps.editlayout")
  end, {
    label = _tr("ui.apps.selector.addToLayout"),
    icon = "plus",
    primary = true
  })

  -- Build specifications
  local specifications = {}

  -- Add interactivity specification
  local interactive = app.interactive
  if interactive then
    if interactive == "yes" then
      table.insert(specifications, {
        key = "interactivity",
        label = _tr("ui.apps.selector.interactivity.label"),
        value = _tr("ui.apps.selector.interactivity.optional"),
        icon = "gamepad"
      })
    elseif interactive == "required" then
      table.insert(specifications, {
        key = "interactivity",
        label = _tr("ui.apps.selector.interactivity.label"),
        value = _tr("ui.apps.selector.interactivity.required"),
        icon = "mouse"
      })
    end
    -- "no" or any other value: don't add anything
  end

  -- Add version specification
  if app.version then
    table.insert(specifications, {
      icon = "info",
      key = "version",
      label = _tr("ui.apps.selector.version"),
      value = app.version
    })
  end

  -- Add types specification
  local types = getDisplayTypes(app)
  if #types > 0 then
    local typesText = table.concat(types, ", ")
    table.insert(specifications, {
      icon = "info",
      key = "types",
      label = _tr("ui.apps.selector.type"),
      value = typesText
    })
  end



  return {
    headerTitle = core_locales.translateWithOrWithoutContext(app.name or app.appName),
    preview = (app.previews and app.previews[1]) or nil,
    description = core_locales.translateWithOrWithoutContext(app.description or ""),
    specifications = { specifications }, -- Wrap in array as expected by the component
    buttonInfo = {
      addToLayoutButton
    },
    appName = app.appName,
  }
end

function M.requestDetails(item, requestId)
  local details = M.getDetails(item)
  local payload = {
    backendName = M.backendName,
    requestId = requestId,
    item = item,
    details = details,
  }
  guihooks.trigger("appSelectorDetails", payload)
  return payload
end

function M.executeButton(buttonId, data)
  -- Use button module to execute the button callback
  return buttonInstance.executeButton(buttonId, data)
end

-- No-op / optional API
function M.getManagementDetails()
  return { buttons = {} }
end

function M.toggleFavourite(itemDetails)
  -- Apps don't have favourites functionality yet
  return false
end

function M.exploreFolder(path)
  -- Apps don't have folder exploration
  log("I", "", "App selector explore folder: " .. tostring(path))
end

function M.goToMod(modId)
  -- Apps don't have mod navigation
  log("I", "", "App selector go to mod: " .. tostring(modId))
end

function M.executeDoubleClick(details)
  if details and details.appName then
    -- Find the addToLayout button and execute it
    local allButtons = buttonInstance.getAllButtonInfos()
    for buttonId, buttonInfo in pairs(allButtons) do
      if buttonInfo.meta and buttonInfo.meta.label == _tr("ui.apps.selector.addToLayout") then
        buttonInstance.executeButton(buttonId, details)
        break
      end
    end
  end
end

local function buildRouteMountSnapshot(path)
  local resolvedPath = normalizeRoutePath(path)
  return {
    backendName = M.backendName,
    path = resolvedPath,
    groups = M.getTiles(resolvedPath),
    filters = M.getFilters(),
    displayData = M.getDisplayDataOptions(),
    managementDetails = M.getManagementDetails(),
    searchText = M.getSearchText(),
    header = M.getScreenHeaderTitleAndPath(resolvedPath),
  }
end

local function attachSnapshotToRouteData(data, path)
  if type(data) ~= "table" then
    return
  end
  local ok, snapshotOrErr = pcall(buildRouteMountSnapshot, path)
  if not ok then
    log("E", "ui.appSelector", string.format("Failed to build app selector route mount snapshot: %s", tostring(snapshotOrErr)))
    return
  end
  data.appSelector = {
    backendName = M.backendName,
    snapshot = snapshotOrErr,
  }
end

function M.resolveCurrentSelectorPath()
  return normalizeRoutePath(DEFAULT_ROUTE_PATH)
end

function M.emitDisplayDataSnapshot(requestId)
  local path = M.resolveCurrentSelectorPath()
  local ok, snapshotOrErr = pcall(buildRouteMountSnapshot, path)
  if not ok then
    log("E", "ui.appSelector", string.format("Failed to rebuild app selector snapshot for display refresh: %s", tostring(snapshotOrErr)))
    return false
  end
  guihooks.trigger("appSelectorDisplayDataSnapshot", {
    backendName = M.backendName,
    requestId = requestId,
    snapshot = snapshotOrErr,
  })
  return true
end

function M.onRouteMount(context, toRoute, fromRoute, data)
  attachSnapshotToRouteData(data, DEFAULT_ROUTE_PATH)
end

function M.profilerFinish() end
function M.closedFromUI() end

return M


