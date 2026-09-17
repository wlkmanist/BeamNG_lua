local M = {}

-- Constructor function
function M.create(config)
  local instance = {}

  -- Default configuration
  config = config or {}
  local itemToTileConverter = config.itemToTileConverter
  local pathHandlers = config.pathHandlers or {}
  local clusteringFunction = config.clusteringFunction
  local groupingModule = config.groupingModule
  local sortingModule = config.sortingModule
  local getDataFunction = config.getDataFunction
  local filterFunction = config.filterFunction
  local backendName = config.backendName or "gridSelector"
  -- Profiler setup
  local function emptyProfiler()
    return {
      start = function() end,
      add = function() end,
      finish = function() end,
    }
  end

  local p = emptyProfiler()
  -- Uncomment to enable profiling: p = LuaProfiler(config.profilerName or "Grid Selector Tiles Profiler")

  -- Generic utility functions for context
  local function finalizeGroups(groups, favouriteGroup, recentGroup, data)
    -- Generic: Limit recent group size
    local recentTileCount = #recentGroup.tiles
    while recentTileCount > 15 do
      table.remove(recentGroup.tiles, recentTileCount)
      recentTileCount = recentTileCount - 1
    end

    -- Generic: Prepare final groups list and sort groups
    local groupsList = {}
    for _, group in pairs(groups) do
      if #group.tiles > 0 then
        table.insert(groupsList, group)
      end
    end
    table.sort(groupsList, function(a, b)
      if a.order == b.order then
        return sortingModule.sortByNameButOtherAlwaysLast(a, b)
      end
      return a.order < b.order
    end)
    p:add("sort groups")

    return groupsList
  end

  local function setDefaultSelection(group, model, overrideDefaultSelectedTile)
    -- Generic: Find default tile with content-specific fallback
    local defaultTile = nil
    if group.tiles and #group.tiles > 0 then
      -- Content-specific default selection logic can be provided via model parameter
      if model and model.model and model.model.default_pc then
        for _, tile in ipairs(group.tiles) do
          if tile.config_key == model.model.default_pc then
            defaultTile = tile
            break
          end
        end
      end

      -- Generic: Override mechanism for default selection
      if overrideDefaultSelectedTile then
        for _, tile in ipairs(group.tiles) do
          if tile.config_key == overrideDefaultSelectedTile.key then
            defaultTile = tile
            defaultTile.forceAutoFocus = true
            print("Overriding default tile to:"..dumps(defaultTile.key))
            break
          end
        end
      end

      -- Generic: Fallback to last tile if no default found
      if not defaultTile then
        defaultTile = group.tiles[#group.tiles]
      end
      if defaultTile then
        defaultTile.isDefaultSelected = true
      end
    end

    return defaultTile
  end

  local function matchesGroup(config, groupMode, groupName)
    if not groupMode or not groupName then
      return true
    end

    -- Generic: Group-based filtering logic
    local validGroups = {}
    if not groupingModule.isRange[groupMode] then
      local value = groupingModule.getConfigOrModelPropValue(config, groupMode) or "Other..."
      local groupName, _ = groupingModule.getGroupModeFunction(groupMode)(value)
      validGroups[groupName] = true
    else
      local value = groupingModule.getConfigOrModelPropValue(config, groupMode) or "Other..."
      local rangeGroups = groupingModule.getRangeGroupingFunction(groupMode)(value)
      for _, group in ipairs(rangeGroups) do
        validGroups[group.groupName] = true
      end
    end

    -- Generic: Special group filtering (favourites/recent)
    if groupMode == "Favourites" then
      -- This should be handled by the calling code with specific favourite checking logic
      return true -- Let the caller handle favourite filtering
    elseif groupMode == "Recent" then
      -- This should be handled by the calling code with specific recent checking logic
      return true -- Let the caller handle recent filtering
    end

    return validGroups[groupName]
  end

  local function processClusteredItems(clusteredItems, group, data, clusterMode, tileFromClusteredItems)
    local tiles = {}
    -- Generic: Decide whether to expand clusters or create single tile
    if clusteredItems.count > data.displayData.expandGroups then
      tiles[1] = tileFromClusteredItems[clusterMode](clusteredItems, group)
    else
      -- Convert individual items to tiles
      for i, config in pairs(clusteredItems.configsByKey) do
        local tile = itemToTileConverter(config, true)
        table.insert(tiles, tile)
      end
    end
    return tiles
  end

  local function handleSpecialGroups(tile, favouriteGroup, recentGroup, data)
    -- Generic: Duplicate tiles for favourites group if needed
    if (data.displayData.showFavouritesMode == 'completeClusters') and tile.favouriteIdx > 0 then
      local favouriteTile = deepcopy(tile)
      favouriteTile.key = favouriteTile.key .. "_" .. tile.favouriteIdx
      if favouriteTile.highestFavouriteConfig then
        favouriteTile.doubleClickDetails.config = favouriteTile.highestFavouriteConfig.key
        favouriteTile.preview = favouriteTile.highestFavouriteConfig.preview
      end
      table.insert(favouriteGroup.tiles, favouriteTile)
      favouriteTile.highestFavouriteConfig = nil
      favouriteTile.lowestRecentConfig = nil
    end

    -- Generic: Duplicate tiles for recent group if needed
    if (data.displayData.showRecentMode == 'completeClusters') and tile.recentIdx < math.huge then
      local recentTile = deepcopy(tile)
      recentTile.key = recentTile.key .. "_" .. tile.recentIdx
      if recentTile.lowestRecentConfig then
        recentTile.doubleClickDetails.config = recentTile.lowestRecentConfig.key
        recentTile.preview = recentTile.lowestRecentConfig.preview
      end
      table.insert(recentGroup.tiles, recentTile)
      recentTile.highestFavouriteConfig = nil
      recentTile.lowestRecentConfig = nil
    end

    tile.highestFavouriteConfig = nil
    tile.lowestRecentConfig = nil
  end

  -- Create context object with utilities
  local function createContext(data, overrideDefaultSelectedTile, tileFromClusteredItems)
    return {
      -- Configuration functions
      itemToTileConverter = itemToTileConverter,
      filterFunction = filterFunction,
      clusteringFunction = clusteringFunction,
      groupingModule = groupingModule,
      sortingModule = sortingModule,

      -- Generic utility functions
      finalizeGroups = function(groups, favouriteGroup, recentGroup)
        return finalizeGroups(groups, favouriteGroup, recentGroup, data)
      end,

      setDefaultSelection = function(group, model)
        return setDefaultSelection(group, model, overrideDefaultSelectedTile)
      end,

      matchesGroup = matchesGroup,
      processClusteredItems = function(clusteredItems, group, clusterMode)
        return processClusteredItems(clusteredItems, group, data, clusterMode, tileFromClusteredItems)
      end,
      handleSpecialGroups = function(tile, favouriteGroup, recentGroup)
        return handleSpecialGroups(tile, favouriteGroup, recentGroup, data)
      end,

      -- State management
      profiler = p,
      backendName = backendName,
      data = data
    }
  end

  -- Main getTiles function
  local function getTiles(path, pathChanged, overrideDefaultSelectedTile, tileFromClusteredItems)
    p:start()
    local data = getDataFunction()
    p:add("getUiData")

    -- Generic: Path handling for navigation
    path = path or {keys = {}}
    local pathType = path.keys[1]
    p:add("setupValidFilters")

    -- Create context for this request
    local context = createContext(data, overrideDefaultSelectedTile, tileFromClusteredItems)

    -- Dispatch to appropriate path handler
    local handler = pathHandlers[pathType]
    if handler then
      local result = handler(path, data, context)

      -- Generic: Hook system for extensibility
      if pathChanged then
        extensions.hook("onGridSelectorGetTiles", backendName, pathType)
      end

      p:add("lua function finished, sending groups to UI...")
      p:finish(true)
      return result
    end

    -- No handler found
    p:finish(true)
    return {}
  end

  -- Export instance methods
  instance.getTiles = getTiles
  instance.createContext = createContext

  return instance
end

return M
