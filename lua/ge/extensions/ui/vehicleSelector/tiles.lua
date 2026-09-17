local M = {}

-- Import sub-modules
local tileSorting = require('/lua/ge/extensions/ui/vehicleSelector/tileSorting')
local tileGrouping = require('/lua/ge/extensions/ui/vehicleSelector/tileGrouping')
local tileClustering = require('/lua/ge/extensions/ui/vehicleSelector/tileClustering')
local tilesModule = require('/lua/ge/extensions/ui/gridSelectorUtils/tilesModule')

local function emptyProfiler()
  return {
    start = function() end,
    add = function() end,
    finish = function() end,
  }
end
M.emptyProfiler = emptyProfiler
-- Note: Profiler is now handled by the tilesModule

local function prependTileToGroup(group, tile)
  if type(tile) ~= "table" then
    return
  end
  group.tiles = group.tiles or {}
  for index = #group.tiles, 1, -1 do
    if group.tiles[index].key == tile.key then
      table.remove(group.tiles, index)
    end
  end
  table.insert(group.tiles, 1, tile)
end

local function ensureRecentGroup(groups, recentGroup, displayData)
  if displayData.showRecentMode == 'hidden' then
    return recentGroup
  end
  local recentLabel = _tr("ui.menu.gridSelector.recent")
  if not groups[recentLabel] then
    groups[recentLabel] = {
      key = recentLabel,
      label = recentLabel,
      unclusteredConfigs = {},
      tiles = {},
      order = -2,
      gotoParams = {"Recent"},
      isFavouriteGroup = false,
      isRecentGroup = true
    }
  end
  return groups[recentLabel]
end

local function isCurrentFreeroamVehicleTile(model, config)
  return ui_vehicleSelector_general.isFreeroamVehicleSelectorContext()
    and freeroam_freeroamConfigurator.isCurrentSelection("vehicle", { model = model, config = config })
end


-- Use clustering module function
M.getClusteredItemsFavouriteIconPercent = tileClustering.getClusteredItemsFavouriteIconPercent

-- Use clustering module function
M.getClusteredItemsStats = tileClustering.getClusteredItemsStats

-- Use clustering module for tile creation (passed to tilesModule)
local tileFromClusteredItems = {
  ['brandSubModelOrModel'] = function(clusteredItems, group)
    return tileClustering.createTileFromClusteredItems(clusteredItems, group, 'brandSubModelOrModel')
  end,
  ['model'] = function(clusteredItems, group)
    return tileClustering.createTileFromClusteredItems(clusteredItems, group, 'model')
  end,
}


-- Use clustering module function
M.getSources = tileClustering.getSources

local function configToTile(config, fullName)
  local model = core_vehicles.getModel(config.model_key).model
  local isCurrentFreeroamVehicle = isCurrentFreeroamVehicleTile(config.model_key, config.key)
  local sources = M.getSources(config, model, true) or {}
  local sourceIcons = {}
  for _, source in ipairs(sources) do
    if string.endswith(source, ".svg") then
      table.insert(sourceIcons, {svg = source})
    else
      table.insert(sourceIcons, {icon = source})
    end
  end
  return {
    key = config.model_key .. "/" .. config.key,
    name = fullName and (config.Name or config.key) or (config.Configuration or config.key),
    isConfig = true,
    preview = config.preview or ("/vehicles/" .. config.model_key .. "/default.jpg"),
    model_key = config.model_key,
    config_key = config.key,
    configType = config['Config Type'] or _tr("ui.menu.gridSelector.other"),
    showDetails = {model = config.model_key, config = config.key},
    doubleClickDetails = {model = config.model_key, config = config.key},
    doubleClickMode = "",
    subElementCount = 0,
    favouriteIdx = ui_vehicleSelector_general.isFavourite(config.model_key, config.key) or 0,
    recentIdx = ui_vehicleSelector_general.isRecentVehicle(config.model_key, config.key) or math.huge,
    showFavouriteIconPercent = ui_vehicleSelector_general.isFavourite(config.model_key, config.key) and 1 or 0,
    sourceIcons = sourceIcons,
    isAuxiliary = config.isAuxiliary,
    isDefaultForSubCluster = config.isDefaultForSubCluster,
    cornerIcon = isCurrentFreeroamVehicle and "car" or nil,
    Value = config.Value or model.Value,
    Weight = config.Weight or model.Weight,
    ['Top Speed'] = config['Top Speed'] or model['Top Speed'],
    Power = config.Power or model.Power,
    ['Power/Weight'] = config.Power and config.Weight and config.Weight > 0 and config.Power > 0 and config.Power / config.Weight or math.huge,
    ['0-60 mph'] = config['0-60 mph'] or config.zeroTo60 or math.huge,
    ['0-100 km/h'] = config['0-100 km/h'] or config.zeroTo100 or math.huge,
  }
end

-- Use clustering module function
local function clusterItems(configs)
  local clusterMode = ui_vehicleSelector_general.getUiData().displayData.clusterMode
  return tileClustering.clusterItems(configs, clusterMode)
end

-- Use grouping module functions
M.groupModeFunctions = tileGrouping.groupModeFunctions
M.getConfigOrModelPropValue = tileGrouping.getConfigOrModelPropValue

local overrideDefaultSelectedTile = nil
M.overrideDefaultSelectedTile = function(tile)
  overrideDefaultSelectedTile = tile
end

local function clearSelectionMarkers(groups)
  for _, group in ipairs(groups) do
    local tiles = group and group.tiles or {}
    for _, tile in ipairs(tiles) do
      tile.isDefaultSelected = nil
      tile.forceAutoFocus = nil
    end
  end
end

local function getOverrideConfigSelection(overrideTile)
  if type(overrideTile) ~= "table" then
    return nil, nil
  end

  local overrideModelKey = overrideTile.model_key
  local overrideConfigKey = overrideTile.config_key or overrideTile.key
  if type(overrideConfigKey) ~= "string" or overrideConfigKey == "" then
    return nil, nil
  end

  return overrideModelKey, overrideConfigKey
end

local function tileMatchesOverride(tile, overrideTile)
  local overrideModelKey, overrideConfigKey = getOverrideConfigSelection(overrideTile)
  if not overrideConfigKey then
    return false
  end
  if tile.config_key ~= overrideConfigKey then
    return false
  end

  if type(overrideModelKey) == "string" and overrideModelKey ~= "" then
    return tile.model_key == overrideModelKey
  end

  return true
end

local function tileMatchesExactModelOverride(tile, overrideTile)
  local overrideModelKey, overrideConfigKey = getOverrideConfigSelection(overrideTile)
  if not overrideModelKey or not overrideConfigKey then
    return false
  end

  if tile.model_key == overrideModelKey and tile.config_key == overrideConfigKey then
    return true
  end

  local details = tile.doubleClickDetails or {}
  return details.model == overrideModelKey and details.config == overrideConfigKey
end

local function tileMatchesModelOverride(tile, overrideTile)
  local overrideModelKey = type(overrideTile) == "table" and overrideTile.model_key or nil
  if type(overrideModelKey) ~= "string" or overrideModelKey == "" then
    return false
  end

  if tile.model_key == overrideModelKey then
    return true
  end

  local details = tile.doubleClickDetails or {}
  if details.model == overrideModelKey then
    return true
  end

  local gotoPath = tile.gotoPath or {}
  return gotoPath[1] == "configsForBrandSubModelOrModel" and gotoPath[2] == overrideModelKey
end

local function findTileInGroups(groups, predicate)
  for _, group in ipairs(groups) do
    local tiles = group and group.tiles or {}
    for _, tile in ipairs(tiles) do
      if predicate(tile) then
        return tile
      end
    end
  end

  return nil
end

local function findFallbackTile(groups)
  for groupIndex = #groups, 1, -1 do
    local group = groups[groupIndex]
    local tiles = group and group.tiles or nil
    if tiles and #tiles > 0 then
      return tiles[#tiles]
    end
  end

  return nil
end

local function setDefaultSelectionAcrossConfigGroups(groups, model, overrideTile)
  clearSelectionMarkers(groups)

  local defaultTile = findTileInGroups(groups, function(tile)
    return tileMatchesOverride(tile, overrideTile)
  end)

  if defaultTile then
    defaultTile.forceAutoFocus = true
  end

  if not defaultTile and model and model.model and model.model.default_pc then
    defaultTile = findTileInGroups(groups, function(tile)
      return tile.config_key == model.model.default_pc
    end)
  end

  if model.model.clusterBySubGroup then
    defaultTile = findTileInGroups(groups, function(tile)
      return tile.isDefaultForSubCluster
    end)
  end

  if not defaultTile then
    defaultTile = findFallbackTile(groups)
  end

  if defaultTile then
    defaultTile.isDefaultSelected = true
  end

  return defaultTile
end

local function setDefaultSelectionAcrossModelGroups(groups, overrideTile)
  if type(overrideTile) ~= "table" then
    return nil
  end

  clearSelectionMarkers(groups)

  local defaultTile = findTileInGroups(groups, function(tile)
    return tileMatchesExactModelOverride(tile, overrideTile)
  end)

  if not defaultTile then
    defaultTile = findTileInGroups(groups, function(tile)
      return tileMatchesModelOverride(tile, overrideTile)
    end)
  end

  if defaultTile then
    defaultTile.forceAutoFocus = true
    defaultTile.isDefaultSelected = true
  end

  return defaultTile
end


-- ============================================================================
-- VEHICLE-SPECIFIC PATH HANDLERS
-- ============================================================================

-- Path handler for "allModels" - displays all vehicle models with grouping and clustering
local function handleAllModelsPath(path, data, context)
  -- VEHICLE-SPECIFIC: Filter vehicle configurations based on vehicle-specific criteria
  local validConfigs = {}
  context.profiler:add("setupValidFilters")
  for _, config in pairs(data.configs) do
    -- VEHICLE-SPECIFIC: Uses vehicle-specific filter logic
    if not ui_vehicleSelector_general.passesFilters({model = config.model_key, config = config.key}) then
      goto continue
    end
    table.insert(validConfigs, config)
    ::continue::
  end
  context.profiler:add("apply filters to configs")

  -- GENERIC: Group creation logic (could work for any item type with grouping support)
  local groups = {}
  local favouriteGroup, recentGroup = {tiles = {}}, {tiles = {}}
  for _, config in pairs(validConfigs) do
    -- GENERIC: Get groups for item (could work for any item type)
    local groupsForConfig = context.groupingModule.getGroupsForConfig(config, data.displayData.groupMode, data.displayData)
    for _, group in pairs(groupsForConfig) do
      local groupName, groupOrder = group.groupName, group.groupOrder
      if not groups[groupName] then
        groups[groupName] = {
          key = groupName,
          label = groupName,
          unclusteredConfigs = {},
          tiles = {},
          order = groupOrder,
          gotoParams = {data.displayData.groupMode, groupName},
          isFavouriteGroup = group.isFavouriteGroup,
          isRecentGroup = group.isRecentGroup
        }
        -- GENERIC: Special group handling for favourites and recent items
        if group.isFavouriteGroup then
          groups[groupName].gotoParams = {"Favourites"}
          favouriteGroup = groups[groupName]
        end
        if group.isRecentGroup then
          groups[groupName].gotoParams = {"Recent"}
          recentGroup = groups[groupName]
        end
      end
      -- GENERIC: Conditional clustering logic - skip for completeClusters mode
      if group.isFavouriteGroup and data.displayData.showFavouritesMode == 'completeClusters'
      or group.isRecentGroup and data.displayData.showRecentMode == 'completeClusters' then
        goto continue
      end
      table.insert(groups[groupName].unclusteredConfigs, config)
      ::continue::
    end
    context.profiler:add("put config in group")
  end

  -- GENERIC: Complete clusters mode handling - clear configs for completeClusters only
  if data.displayData.showFavouritesMode == 'completeClusters' then
    favouriteGroup.unclusteredConfigs = {}
    favouriteGroup.tiles = {}
  end
  if data.displayData.showRecentMode == 'completeClusters' then
    recentGroup.unclusteredConfigs = {}
    recentGroup.tiles = {}
  end

  -- GENERIC: Process each group to create tiles
  for _, group in pairs(groups) do
    -- Skip clustering for special groups in unclustered mode
    local skipClustering = (group.isRecentGroup and data.displayData.showRecentMode == 'unclustered') or
                           (group.isFavouriteGroup and data.displayData.showFavouritesMode == 'unclustered')

    if skipClustering then
      -- Convert configs directly to tiles without clustering
      for _, config in pairs(group.unclusteredConfigs) do
        local tile = context.itemToTileConverter(config, true)
        table.insert(group.tiles, tile)
      end
      group.unclusteredConfigs = nil
    else
      -- GENERIC: Cluster items within each group
      local itemsClustered = context.clusteringFunction(group.unclusteredConfigs)
      group.unclusteredConfigs = nil

      -- GENERIC: Create tiles for each cluster
      for _, clusteredItems in pairs(itemsClustered) do
        local tiles = context.processClusteredItems(clusteredItems, group, data.displayData.clusterMode)

        -- GENERIC: Add tiles to groups and handle special groups (favourites/recent)
        for _, tile in pairs(tiles) do
          table.insert(group.tiles, tile)
          context.handleSpecialGroups(tile, favouriteGroup, recentGroup)
        end
      end
    end
    context.profiler:add("cluster items in group")
  end

  -- add favourite group if its empty but we want to include the default config
  if data.displayData.includeDefaultConfigInFavourites and ui_vehicleSelector_general.getDefaultVehicleTile() and not groups[_tr("ui.menu.gridSelector.favourites")] then
    groups[_tr("ui.menu.gridSelector.favourites")] = {
      key = _tr("ui.menu.gridSelector.favourites"),
      label = _tr("ui.menu.gridSelector.favourites"),
      unclusteredConfigs = {},
      tiles = {},
      order = -1,
      gotoParams = {"Favourites"},
      isFavouriteGroup = true,
      isRecentGroup = false
    }
  end
  local currentFreeroamVehicleTile = ui_vehicleSelector_general.isFreeroamVehicleSelectorContext()
    and freeroam_freeroamConfigurator.getCurrentSelectionRecentTile("vehicle") or nil
  if currentFreeroamVehicleTile then
    recentGroup = ensureRecentGroup(groups, recentGroup, data.displayData)
  end

  -- GENERIC: Automatic sorting based on group type and display settings
  for _, group in pairs(groups) do
    --print(string.format("sorting group %s with mode %s %s (in handleAllModelsPath)", group.key, data.displayData.sortMode, data.displayData.groupMode))
    if data.displayData.sortMode == 'Automatic' or group.isRecentGroup then
      if group.isRecentGroup then
        table.sort(group.tiles, function(a, b)
          return a.recentIdx < b.recentIdx
        end)
        prependTileToGroup(group, currentFreeroamVehicleTile)
      elseif group.isFavouriteGroup then
        table.sort(group.tiles, function(a, b)
          return a.favouriteIdx > b.favouriteIdx
        end)
        if data.displayData.includeDefaultConfigInFavourites and ui_vehicleSelector_general.getDefaultVehicleTile() then
          table.insert(group.tiles, 1, ui_vehicleSelector_general.getDefaultVehicleTile())
        end
      elseif data.displayData.groupMode == 'Value' then
        tileSorting.sortTiles(group.tiles, 'Value')
      elseif data.displayData.groupMode == 'Years' then
        tileSorting.sortTiles(group.tiles, 'Years')
      else
        tileSorting.sortTiles(group.tiles, 'Name')
      end
    else
      tileSorting.sortTiles(group.tiles, data.displayData.sortMode)
    end
    context.profiler:add("sort tiles in group (auto)")
  end

  local groupList = context.finalizeGroups(groups, favouriteGroup, recentGroup)
  setDefaultSelectionAcrossModelGroups(groupList, overrideDefaultSelectedTile)
  return groupList
end

-- Path handler for "configsForBrandSubModelOrModel" - displays configurations for a specific vehicle model
local function handleConfigsForBrandSubModelOrModelPath(path, data, context)
  -- VEHICLE-SPECIFIC: Extract vehicle-specific path parameters
  local modelKey = path.keys[2]
  local modelSubKey = path.keys[3]
  local brandKey = path.keys[4]
  local groupMode = path.keys[5]
  local groupName = path.keys[6]

  -- VEHICLE-SPECIFIC: Get vehicle model data
  local model = core_vehicles.getModel(modelKey)
  extensions.hook("onVehicleSelectorGetTiles", "configsForBrandSubModelOrModel", modelKey, modelSubKey, brandKey, groupMode, groupName)
  if not model then
    return {}
  end

  -- GENERIC: Group structure (could work for any item collection)
  local defaultGroup = {
    key = "configsForBrandSubModelOrModel_default",
    label = nil,
    tiles = {}
  }
  local subGroups = {}


  -- VEHICLE-SPECIFIC: Iterate through vehicle configurations
  for _, config in pairs(model.configs) do
    -- VEHICLE-SPECIFIC: Filter by vehicle submodel
    local clusterKey = config.vehicleSelectorSubCluster or model.model.vehicleSelectorSubCluster
    if modelSubKey and modelSubKey ~= "" then
      if clusterKey ~= modelSubKey then
        goto continue
      end
    end
    -- VEHICLE-SPECIFIC: Filter by vehicle brand
    if brandKey and brandKey ~= "" then
      local brand = config.Brand or model.model.Brand
      if brand ~= brandKey then
        goto continue
      end
    end
    -- VEHICLE-SPECIFIC: Filter auxiliary content
    if config.isAuxiliary and not data.displayData.showAuxContent then
      goto continue
    end

    local subKey = config.vehicleSelectorSubGroup or model.model.vehicleSelectorSubGroup
    if subKey and subKey ~= "" and not subGroups[subKey] then
      subGroups[subKey] = {
        key = "configsForBrandSubModelOrModel_" .. subKey,
        label = subKey,
        tiles = {}
      }
    end

    -- VEHICLE-SPECIFIC: Apply vehicle-specific filters
    local match = ui_vehicleSelector_general.passesFilters({model = config.model_key, config = config.key})
    context.profiler:add("passesFilters")

    -- GENERIC: Group-based filtering logic (could work for any grouped items)
    if groupMode then
      if groupMode == "Favourites" then
        match = match and ui_vehicleSelector_general.isFavourite(config.model_key, config.key)
      elseif groupMode == "Recent" then
        match = match and ui_vehicleSelector_general.isRecentVehicle(config.model_key, config.key)
      elseif groupName then
        match = match and context.matchesGroup(config, groupMode, groupName)
      end
    end

    -- VEHICLE-SPECIFIC: Convert config to tile if it matches
    if match then
      if subKey and subKey ~= "" and subGroups[subKey] then
        table.insert(subGroups[subKey].tiles, context.itemToTileConverter(config))
      else
        table.insert(defaultGroup.tiles, context.itemToTileConverter(config))
      end
    end
    context.profiler:add("configToTile")
    ::continue::
  end
  local groupList = {}
  for _, subGroup in pairs(subGroups) do
    if next(subGroup.tiles) then
      table.insert(groupList, subGroup)
    end
  end

  table.sort(groupList, function(a, b)
    return a.label < b.label
  end)

  -- default group is always first
  if next(defaultGroup.tiles) then
    if next(subGroups) then
      defaultGroup.label = model.model.Name or modelKey
    end
    table.insert(groupList, 1, defaultGroup)
  end

  context.profiler:add("sorting groups")

  -- GENERIC: Sort tiles
  --print(string.format("sorting group %s with mode %s %s (in handleAllModelsPath)", group.key, data.displayData.sortMode, data.displayData.groupMode))
  for _, group in ipairs(groupList) do
    if data.displayData.sortMode == 'Automatic' or group.isRecentGroup then
      if group.isRecentGroup then
        table.sort(group.tiles, function(a, b)
          return a.recentIdx < b.recentIdx
        end)
      elseif group.isFavouriteGroup then
        table.sort(group.tiles, function(a, b)
          return a.favouriteIdx > b.favouriteIdx
        end)
      elseif data.displayData.groupMode == 'Value' then
        tileSorting.sortTiles(group.tiles, 'Value')
      elseif data.displayData.groupMode == 'Years' then
        tileSorting.sortTiles(group.tiles, 'Years')
      else
        tileSorting.sortTiles(group.tiles, 'Value')
      end
    else
      tileSorting.sortTiles(group.tiles, data.displayData.sortMode)
    end
  end

  setDefaultSelectionAcrossConfigGroups(groupList, model, overrideDefaultSelectedTile)
  context.profiler:add("sorting")

  -- GENERIC: Return group structure
  context.profiler:add("returning group")
  return groupList
end

-- Path handler for "configsForModel" - semantic alias for model config selection
local function handleConfigsForModelPath(path, data, context)
  local pathKeys = path.keys or {}
  local translatedPath = {
    keys = {
      "configsForBrandSubModelOrModel",
      pathKeys[2],
      pathKeys[3],
      pathKeys[4],
      pathKeys[5],
      pathKeys[6]
    }
  }

  return handleConfigsForBrandSubModelOrModelPath(translatedPath, data, context)
end

-- ============================================================================
-- TILES MODULE CONFIGURATION AND INITIALIZATION
-- ============================================================================
local tilesInstance = nil
local function onExtensionLoaded()
  -- Create tiles instance with vehicle-specific configuration
  tilesInstance = tilesModule.create({
    -- Vehicle-specific item to tile converter
    itemToTileConverter = configToTile,

    -- Vehicle-specific path handlers
    pathHandlers = {
      allModels = handleAllModelsPath,
      configsForBrandSubModelOrModel = handleConfigsForBrandSubModelOrModelPath,
      configsForModel = handleConfigsForModelPath
    },

    -- Generic functions (reusable for other selectors)
    clusteringFunction = clusterItems,
    groupingModule = tileGrouping,
    sortingModule = tileSorting,

    -- Vehicle-specific data source and filtering
    getDataFunction = ui_vehicleSelector_general.getUiData,
    filterFunction = ui_vehicleSelector_general.passesFilters,

    -- Configuration
    backendName = "vehicleSelector",
    profilerName = "vehicleSelector Tiles Profiler"
  })
end

-- Main getTiles function - now delegates to the tilesModule
local function getTiles(path, pathChanged)
  local pathType = path and path.keys and path.keys[1] or nil
  local consumeOverrideAfterLoad = overrideDefaultSelectedTile ~= nil
    and (pathType == "allModels" or pathType == "configsForBrandSubModelOrModel" or pathType == "configsForModel")

  local result = tilesInstance.getTiles(path, pathChanged, overrideDefaultSelectedTile, tileFromClusteredItems)

  if consumeOverrideAfterLoad then
    overrideDefaultSelectedTile = nil
  end

  -- enable for testing
  --extensions.load('gameplay_discover_freeroamTutorial_vehicleSelectorRestriction')

  if gameplay_discover_freeroamTutorial_vehicleSelectorRestriction then
    result = gameplay_discover_freeroamTutorial_vehicleSelectorRestriction.applyRestriction(pathType, result)
  end

  return result
end




-- Export functions
M.getTiles = getTiles
M.configToTile = configToTile
M.clusterItems = clusterItems

-- Export sorting functions from module
M.sortByNameButOtherAlwaysLast = tileSorting.sortByNameButOtherAlwaysLast
M.sortByValue = tileSorting.sortByValue
M.sortByYears = tileSorting.sortByYears

M.onExtensionLoaded = onExtensionLoaded

return M