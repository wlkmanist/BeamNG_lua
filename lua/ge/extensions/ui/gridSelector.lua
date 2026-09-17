local M = {}
M.dependencies = {"ui_vehicleSelector_general", "ui_gameplaySelector_general", "ui_appSelector_general", "ui_freeroamSelector_general", "ui_quickraceSelector_general", "ui_lightRunnerSelector_general", "ui_busRouteSelector_general"}
local LOG_TAG = "ui.gridSelector"

local REQUIRED_BACKEND_METHODS = {
  "getTiles",
  "getFilters",
  "getSearchText",
  "setSearchText",
  "getDisplayDataOptions",
  "setDisplayDataOption",
  "resetDisplayDataToDefaults",
  "getScreenHeaderTitleAndPath",
  "getDetails",
}

local OPTIONAL_BACKEND_METHODS = {
  "getManagementDetails",
  "executeButton",
  "executeDoubleClick",
  "toggleFavourite",
  "requestClusterTiles",
  "requestDetails",
  "clearAllFilters",
  "closedFromUI",
  "profilerFinish",
}

local OPTIONAL_METHOD_FALLBACKS = {
  getManagementDetails = function()
    return { buttons = {} }
  end,
  executeButton = function()
    return nil
  end,
  executeDoubleClick = function()
    return nil
  end,
  toggleFavourite = function()
    return false
  end,
  requestClusterTiles = function()
    return nil
  end,
  requestDetails = function()
    return nil
  end,
  clearAllFilters = function()
    return false
  end,
  closedFromUI = function()
    return nil
  end,
  profilerFinish = function()
    return nil
  end,
}

M.BackendContract = {
  requiredMethods = REQUIRED_BACKEND_METHODS,
  optionalMethods = OPTIONAL_BACKEND_METHODS,
}

local function getBackendByName(backendName)
  if backendName == "vehicleSelector" then
    return ui_vehicleSelector_general
  elseif backendName == "gameplaySelector" then
    return ui_gameplaySelector_general
  elseif backendName == "appSelector" then
    return ui_appSelector_general
  elseif backendName == "freeroamSelector" then
    return ui_freeroamSelector_general
  elseif backendName == "quickraceSelector" then
    return ui_quickraceSelector_general
  elseif backendName == "lightRunnerSelector" then
    return ui_lightRunnerSelector_general
  elseif backendName == "busRouteSelector" then
    return ui_busRouteSelector_general
  end
  return nil
end
M.getBackendByName = getBackendByName

local function shallowCopy(value)
  if type(value) ~= "table" then
    return {}
  end

  local copy = {}
  for key, itemValue in pairs(value) do
    copy[key] = itemValue
  end
  return copy
end

local function normalizePath(path, backendName, methodName)
  local function normalizePathKeys(pathKeys)
    local normalizedKeys = {}
    for index, key in ipairs(pathKeys) do
      local keyType = type(key)
      if keyType == "string" or keyType == "number" or keyType == "boolean" then
        normalizedKeys[#normalizedKeys + 1] = tostring(key)
      elseif key ~= nil then
        log("W", LOG_TAG, string.format(
          "Ignoring invalid path segment for backend '%s' (%s) at index %d: %s",
          tostring(backendName),
          tostring(methodName),
          index,
          keyType
        ))
      end
    end
    return normalizedKeys
  end

  if type(path) == "table" then
    if type(path.keys) == "table" then
      return { keys = normalizePathKeys(path.keys) }
    end

    if path[1] ~= nil then
      return { keys = normalizePathKeys(path) }
    end

    if next(path) ~= nil then
      log("W", LOG_TAG, string.format(
        "Invalid path shape for backend '%s' (%s). Expected { keys = {...} }",
        tostring(backendName),
        tostring(methodName)
      ))
    end
  end

  if path ~= nil and type(path) ~= "table" then
    log("W", LOG_TAG, string.format(
      "Invalid path type for backend '%s' (%s): %s",
      tostring(backendName),
      tostring(methodName),
      type(path)
    ))
  end

  return { keys = {} }
end

local contractValidationByBackend = {}
local fallbackWarningByBackendMethod = {}

local function validateBackendContract(backendName, backend)
  if contractValidationByBackend[backendName] then
    return
  end
  contractValidationByBackend[backendName] = true

  local missingRequiredMethods = {}
  for _, methodName in ipairs(REQUIRED_BACKEND_METHODS) do
    if type(backend[methodName]) ~= "function" then
      missingRequiredMethods[#missingRequiredMethods + 1] = methodName
    end
  end

  if #missingRequiredMethods > 0 then
    log("E", LOG_TAG, string.format(
      "Backend '%s' is missing required methods: %s",
      tostring(backendName),
      table.concat(missingRequiredMethods, ", ")
    ))
  end
end

local function dispatch(backendName, methodName, ...)
  local backend = getBackendByName(backendName)
  if not backend then
    log("E", LOG_TAG, string.format("Unknown grid selector backend '%s' for method '%s'", tostring(backendName), tostring(methodName)))
    return nil
  end

  validateBackendContract(backendName, backend)

  local backendMethod = backend[methodName]
  if type(backendMethod) ~= "function" then
    local optionalFallback = OPTIONAL_METHOD_FALLBACKS[methodName]
    if optionalFallback then
      local backendMethodKey = tostring(backendName) .. ":" .. tostring(methodName)
      if not fallbackWarningByBackendMethod[backendMethodKey] then
        fallbackWarningByBackendMethod[backendMethodKey] = true
        log("W", LOG_TAG, string.format(
          "Backend '%s' does not implement optional method '%s'. Using default fallback.",
          tostring(backendName),
          tostring(methodName)
        ))
      end
      return optionalFallback(...)
    end

    log("E", LOG_TAG, string.format("Backend '%s' is missing method '%s'", tostring(backendName), tostring(methodName)))
    return nil
  end

  return backendMethod(...)
end

local function normalizeGroupsPayload(groups, backendName)
  if type(groups) ~= "table" then
    if groups ~= nil then
      log("W", LOG_TAG, string.format(
        "Backend '%s' returned malformed groups payload (%s). Falling back to an empty groups array.",
        tostring(backendName),
        type(groups)
      ))
    end
    return {}
  end

  local normalizedGroups = {}
  local generatedTileKeyCounter = 0
  for groupIndex, group in ipairs(groups) do
    if type(group) ~= "table" then
      log("W", LOG_TAG, string.format(
        "Backend '%s' returned malformed group at index %d (%s). Skipping group.",
        tostring(backendName),
        groupIndex,
        type(group)
      ))
      goto continue
    end

    local groupCopy = shallowCopy(group)
    local sourceTiles = groupCopy.tiles
    if type(sourceTiles) ~= "table" then
      if sourceTiles ~= nil then
        log("W", LOG_TAG, string.format(
          "Backend '%s' group %d has non-array tiles payload (%s). Falling back to [].",
          tostring(backendName),
          groupIndex,
          type(sourceTiles)
        ))
      end
      sourceTiles = {}
    end

    local normalizedTiles = {}
    for tileIndex, tile in ipairs(sourceTiles) do
      if type(tile) ~= "table" then
        log("W", LOG_TAG, string.format(
          "Backend '%s' returned malformed tile at group %d index %d (%s). Skipping tile.",
          tostring(backendName),
          groupIndex,
          tileIndex,
          type(tile)
        ))
        goto continueTile
      end

      local tileCopy = shallowCopy(tile)
      if tileCopy.key == nil or tileCopy.key == "" then
        generatedTileKeyCounter = generatedTileKeyCounter + 1
        tileCopy.key = string.format("__missingTileKey_%s_%d", tostring(backendName), generatedTileKeyCounter)
        log("W", LOG_TAG, string.format(
          "Backend '%s' tile is missing key at group %d index %d. Generated key '%s'.",
          tostring(backendName),
          groupIndex,
          tileIndex,
          tostring(tileCopy.key)
        ))
      end

      normalizedTiles[#normalizedTiles + 1] = tileCopy
      ::continueTile::
    end

    groupCopy.tiles = normalizedTiles
    normalizedGroups[#normalizedGroups + 1] = groupCopy
    ::continue::
  end

  return normalizedGroups
end

local function normalizeFiltersForSnapshot(filtersPayload, backendName)
  if type(filtersPayload) ~= "table" then
    if filtersPayload ~= nil then
      log("W", LOG_TAG, string.format(
        "Backend '%s' returned malformed filters payload (%s). Falling back to defaults.",
        tostring(backendName),
        type(filtersPayload)
      ))
    end
    filtersPayload = {}
  end

  return {
    filterList = type(filtersPayload.filterList) == "table" and filtersPayload.filterList or {},
    filterByProp = type(filtersPayload.filterByProp) == "table" and filtersPayload.filterByProp or {},
    commonFilters = type(filtersPayload.commonFilters) == "table" and filtersPayload.commonFilters or {},
    lockedFiltersByProp = type(filtersPayload.lockedFiltersByProp) == "table" and filtersPayload.lockedFiltersByProp or {},
    activeFilters = type(filtersPayload.activeFilters) == "table" and filtersPayload.activeFilters or {},
    onlyCommonFilters = filtersPayload.onlyCommonFilters ~= false,
  }
end

local function normalizeDisplayDataForSnapshot(displayData, backendName)
  if type(displayData) ~= "table" then
    if displayData ~= nil then
      log("W", LOG_TAG, string.format(
        "Backend '%s' returned malformed display data payload (%s). Falling back to [].",
        tostring(backendName),
        type(displayData)
      ))
    end
    return {}
  end
  return displayData
end

local function normalizeHeaderForSnapshot(headerData, backendName)
  if type(headerData) ~= "table" then
    if headerData ~= nil then
      log("W", LOG_TAG, string.format(
        "Backend '%s' returned malformed header payload (%s). Falling back to defaults.",
        tostring(backendName),
        type(headerData)
      ))
    end
    return {
      title = "Grid Selector",
      pathSegments = {},
    }
  end

  return {
    title = type(headerData.title) == "string" and headerData.title or "Grid Selector",
    pathSegments = type(headerData.pathSegments) == "table" and headerData.pathSegments or {},
  }
end

local function normalizeManagementDetailsForSnapshot(payload, backendName)
  if type(payload) ~= "table" then
    if payload ~= nil then
      log("W", LOG_TAG, string.format(
        "Backend '%s' returned malformed management details payload (%s). Falling back to { buttons = {} }.",
        tostring(backendName),
        type(payload)
      ))
    end
    return { buttons = {} }
  end

  local normalizedPayload = shallowCopy(payload)
  if type(normalizedPayload.buttons) ~= "table" then
    normalizedPayload.buttons = {}
  end
  return normalizedPayload
end

local function resolveDefaultFocusKey(groups)
  for _, group in ipairs(groups) do
    for _, tile in ipairs(group.tiles or {}) do
      if tile.forceAutoFocus or tile.isDefaultSelected then
        return tile.key
      end
    end
  end
  return nil
end

local SNAPSHOT_SLICE_KEYS = {
  "tiles",
  "filters",
  "displayData",
  "searchText",
  "managementDetails",
  "header",
}

local function normalizeSnapshotSliceOptions(options)
  local source = type(options) == "table" and options or {}
  local normalizedOptions = {}
  local hasEnabledSlice = false

  for _, key in ipairs(SNAPSHOT_SLICE_KEYS) do
    local isEnabled = source[key] == true
    normalizedOptions[key] = isEnabled
    if isEnabled then
      hasEnabledSlice = true
    end
  end

  if not hasEnabledSlice then
    for _, key in ipairs(SNAPSHOT_SLICE_KEYS) do
      normalizedOptions[key] = true
    end
  end

  return normalizedOptions
end

--Tiles
M.getTiles = function(backendName, path, ...)
  local normalizedPath = normalizePath(path, backendName, "getTiles")
  local groups = dispatch(backendName, "getTiles", normalizedPath, ...)
  return normalizeGroupsPayload(groups, backendName)
end
M.requestClusterTiles = function(backendName, path, ...)
  local normalizedPath = normalizePath(path, backendName, "requestClusterTiles")
  return dispatch(backendName, "requestClusterTiles", normalizedPath, ...)
end
--Filters
M.getFilters = function(backendName, ...) return dispatch(backendName, "getFilters", ...) end
M.getActiveFilters = function(backendName, ...) return dispatch(backendName, "getActiveFilters", ...) end
M.toggleFilter = function(backendName, ...) return dispatch(backendName, "toggleFilter", ...) end
M.updateRangeFilter = function(backendName, ...) return dispatch(backendName, "updateRangeFilter", ...) end
M.resetRangeFilter = function(backendName, ...) return dispatch(backendName, "resetRangeFilter", ...) end
M.resetSetFilter = function(backendName, ...) return dispatch(backendName, "resetSetFilter", ...) end
M.clearAllFilters = function(backendName, ...) return dispatch(backendName, "clearAllFilters", ...) end
M.getSearchText = function(backendName, ...) return dispatch(backendName, "getSearchText", ...) end
M.setSearchText = function(backendName, ...) return dispatch(backendName, "setSearchText", ...) end
--Display Data
M.getDisplayDataOptions = function(backendName, ...) return dispatch(backendName, "getDisplayDataOptions", ...) end
M.setDisplayDataOption = function(backendName, ...) return dispatch(backendName, "setDisplayDataOption", ...) end
M.resetDisplayDataToDefaults = function(backendName, ...) return dispatch(backendName, "resetDisplayDataToDefaults", ...) end
--General
M.getScreenHeaderTitleAndPath = function(backendName, path, ...)
  local normalizedPath = normalizePath(path, backendName, "getScreenHeaderTitleAndPath")
  return dispatch(backendName, "getScreenHeaderTitleAndPath", normalizedPath, ...)
end
M.profilerFinish = function(backendName, ...) return dispatch(backendName, "profilerFinish", ...) end
M.closedFromUI = function(backendName, ...) return dispatch(backendName, "closedFromUI", ...) end
--Details
M.getDetails = function(backendName, ...) return dispatch(backendName, "getDetails", ...) end
M.requestDetails = function(backendName, ...) return dispatch(backendName, "requestDetails", ...) end
M.executeButton = function(backendName, ...) return dispatch(backendName, "executeButton", ...) end
M.getManagementDetails = function(backendName, ...) return dispatch(backendName, "getManagementDetails", ...) end
M.exitCallback = function(backendName, ...) return dispatch(backendName, "exitCallback", ...) end
M.executeDoubleClick = function(backendName, ...) return dispatch(backendName, "executeDoubleClick", ...) end
--M.exploreFolder = function(backendName, ...) return getBackendByName(backendName).exploreFolder(...) end
--M.goToMod = function(backendName, ...) return getBackendByName(backendName).goToMod(...) end
M.toggleFavourite = function(backendName, ...) return dispatch(backendName, "toggleFavourite", ...) end

local function getSelectorSnapshotSlices(backendName, path, options)
  local normalizedPath = normalizePath(path, backendName, "getSelectorSnapshotSlices")
  local sliceOptions = normalizeSnapshotSliceOptions(options)

  local payload = {
    backendName = backendName,
    path = normalizedPath,
  }

  if sliceOptions.tiles then
    local groups = M.getTiles(backendName, normalizedPath)
    payload.groups = groups
    payload.defaultFocusKey = resolveDefaultFocusKey(groups)
  end

  if sliceOptions.filters then
    payload.filters = normalizeFiltersForSnapshot(dispatch(backendName, "getFilters"), backendName)
  end

  if sliceOptions.displayData then
    payload.displayData = normalizeDisplayDataForSnapshot(dispatch(backendName, "getDisplayDataOptions"), backendName)
  end

  if sliceOptions.searchText then
    local searchTextPayload = dispatch(backendName, "getSearchText")
    payload.searchText = type(searchTextPayload) == "string" and searchTextPayload or ""
  end

  if sliceOptions.managementDetails then
    payload.managementDetails = normalizeManagementDetailsForSnapshot(dispatch(backendName, "getManagementDetails"), backendName)
  end

  if sliceOptions.header then
    payload.header = normalizeHeaderForSnapshot(dispatch(backendName, "getScreenHeaderTitleAndPath", normalizedPath), backendName)
  end

  return payload
end
M.getSelectorSnapshotSlices = getSelectorSnapshotSlices
M.getSelectorRefresh = getSelectorSnapshotSlices

local function getSelectorSnapshot(backendName, path)
  return getSelectorSnapshotSlices(backendName, path, {
    tiles = true,
    filters = true,
    displayData = true,
    searchText = true,
    managementDetails = true,
    header = true,
  })
end
M.getSelectorSnapshot = getSelectorSnapshot
M.getInitialData = getSelectorSnapshot


local function exploreFolder(_backendName, path)
  Engine.Platform.exploreFolder(path)
end
M.exploreFolder = exploreFolder
local function goToMod(_backendName, modId)
  guihooks.trigger('ChangeState', {state = 'menu.mods.details', params = {modId = modId}})
end
M.goToMod = goToMod
return M