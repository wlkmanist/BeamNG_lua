-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
-- Tile generators will be loaded dynamically
M.dependencies = {}
local systemName = function(system) return _tr("ui.menu.gameplaySelector.propValue.system." .. system, system) end

local generatorFiles = FS:findFiles('lua/ge/extensions/ui/gameplaySelector/tileGenerators/', '*.lua', 1, true, false)
for _, filePath in ipairs(generatorFiles) do
  -- Get relative path from tileGenerators folder and convert to extension name format
  local relativePath = string.gsub(filePath, 'lua/ge/extensions/ui/gameplaySelector/tileGenerators/', '')
  relativePath = string.gsub(relativePath, '^/', '') -- remove leading slash
  local nameWithoutExt = string.gsub(relativePath, '%.lua$', '')
  local generatorName = string.gsub(nameWithoutExt, '/', '_')

  local extName = 'ui_gameplaySelector_tileGenerators_' .. generatorName
  --extensions.load(extName)
  table.insert(M.dependencies, extName)
end



local backend = nil

-- Load required modules
local tileClustering = require('/lua/ge/extensions/ui/gameplaySelector/tileClustering')
local tileSorting = require('/lua/ge/extensions/ui/gameplaySelector/tileSorting')

-- Backend name
local backendName = "gameplaySelector"

-- Group mode functions for gameplay elements
local groupModeFunctions = {
  Type = function(item)
    return item.type or "Other..."
  end,
  Category = function(item)
    return item.category or "Other..."
  end,
  Difficulty = function(item)
    return item.difficulty or "Other..."
  end,
  Source = function(item)
    return item.source or "Other..."
  end,
  System = function(item)
    return item.system or "Other..."
  end,
}

-- Sort mode functions for gameplay elements
local sortModeFunctions = {
  Name = function(a, b)
    return (a.name or "") < (b.name or "")
  end,
  Difficulty = function(a, b)
    local difficultyOrder = {easy = 1, medium = 2, hard = 3, expert = 4}
    local aOrder = difficultyOrder[a.difficulty] or 0
    local bOrder = difficultyOrder[b.difficulty] or 0
    return aOrder < bOrder
  end,
  Duration = function(a, b)
    return (a.duration or "") < (b.duration or "")
  end,
  Popularity = function(a, b)
    -- Sort by recent index (lower = more recent)
    local aRecent = a.recentIdx or math.huge
    local bRecent = b.recentIdx or math.huge
    return aRecent < bRecent
  end,
}

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
      tiles = {},
      order = -2,
      gotoParams = {"", "", "Recent"},
      isFavouriteGroup = false,
      isRecentGroup = true
    }
  end
  return groups[recentLabel]
end


-- Path handler for "allGameplay" - displays all gameplay tiles with grouping and clustering
local function handleAllGameplayPath(path, data, items)
  local groups = {}
  local displayData = data.displayData
  local groupMode = displayData.groupMode
  local clusterMode = displayData.clusterMode
  local favouriteGroup, recentGroup = nil, nil

  -- Filter items based on current filters
  local validItems = {}
  for _, item in pairs(items) do
    if backend.passesFilters(item) then
      table.insert(validItems, item)
    end
  end

  if #validItems > 0 then
    -- Group items by the specified group mode (similar to vehicle selector approach)
    for _, item in pairs(validItems) do
      -- Get groups for this item (including special groups)
      local groupsForItem = {}

      -- Add to regular group
      -- groupValue is the raw filter value used for matching in detail path handling.
      -- groupLabel is the translated/display-facing string shown in the UI.
      local groupValue = item[groupMode] or "Other..."
      local groupLabel = item[groupMode] and systemName(item[groupMode]) or _tr("ui.menu.gridSelector.other")
      table.insert(groupsForItem, {groupName = groupLabel, groupOrder = 0, groupKey = groupValue})

      -- Add special groups for favourites and recent items
      if displayData.showFavouritesMode ~= 'hidden' and backend.isFavourite(item.key) then
        table.insert(groupsForItem, {groupName = _tr("ui.menu.gridSelector.favourites"), groupOrder = -1, isFavouriteGroup = true})
      end
      if displayData.showRecentMode ~= 'hidden' and backend.isRecent(item.key) then
        table.insert(groupsForItem, {groupName = _tr("ui.menu.gridSelector.recent"), groupOrder = -2, isRecentGroup = true})
      end

      -- Create groups and add items
      for _, groupInfo in pairs(groupsForItem) do
        local groupName = groupInfo.groupName
        local groupOrder = groupInfo.groupOrder
        local groupKey = groupInfo.groupKey or groupName
        local isFavouriteGroup = groupInfo.isFavouriteGroup
        local isRecentGroup = groupInfo.isRecentGroup

        if not groups[groupName] then
          -- gotoParams[2] must be the raw item value (not the translated label)
          -- because handleDetailGameplayPath compares it against item[groupMode].
          groups[groupName] = {
            key = groupKey,
            label = groupName,
            tiles = {},
            order = groupOrder,
            gotoParams = {groupMode, groupKey},
            isFavouriteGroup = isFavouriteGroup,
            isRecentGroup = isRecentGroup
          }

          -- Set special group references and gotoParams.
          -- These are suffixes appended after {"detailGameplay", clusterMode, clusterKey}
          -- by the cluster tile builders, so they must align with the path contract used
          -- by handleDetailGameplayPath: pathKeys[4]=groupKey, pathKeys[5]=groupName, pathKeys[6]=metaMode.
          -- Leave the group filter slots empty so only the cluster + meta filters apply.
          if isFavouriteGroup then
            groups[groupName].gotoParams = {"", "", "Favourites"}
            favouriteGroup = groups[groupName]
          end
          if isRecentGroup then
            groups[groupName].gotoParams = {"", "", "Recent"}
            recentGroup = groups[groupName]
          end
        end

        -- Skip adding items to special groups in completeClusters or unclustered mode
        if (isFavouriteGroup and displayData.showFavouritesMode == 'completeClusters') or
           (isRecentGroup and (displayData.showRecentMode == 'completeClusters')) then
          goto continue
        end

        -- Add item to group
        table.insert(groups[groupName].tiles, item)
        ::continue::
      end
    end

    -- Clear special group tiles for completeClusters and unclustered mode
    if displayData.showFavouritesMode == 'completeClusters' and favouriteGroup then
      favouriteGroup.tiles = {}
    end
    if (displayData.showRecentMode == 'completeClusters') and recentGroup then
      recentGroup.tiles = {}
    end

    -- Process each group to create tiles
    for _, group in pairs(groups) do
      local tiles = group.tiles

      -- Skip clustering for special groups in unclustered mode
      local skipClustering = (group.isRecentGroup and displayData.showRecentMode == 'unclustered') or
                             (group.isFavouriteGroup and displayData.showFavouritesMode == 'unclustered')

      -- Apply clustering if specified and not "None"
      if clusterMode and clusterMode ~= "none" and not skipClustering then
        local clusteredItems = tileClustering.clusterItems(tiles, clusterMode)
        tiles = {}

        for clusterKey, clusterData in pairs(clusteredItems) do
          -- Skip clustering for "None" results (e.g., campaign system in automatic mode)
          if clusterKey ~= "none" then
            local clusterTile = tileClustering.createTileFromClusteredItems(clusterData, group, clusterMode)
            if clusterMode == "automatic" then
              -- For automatic mode, the gotoPath is already set in the tile creation function
            else
              --clusterTile.gotoPath = {"detailGameplay"}, clusterMode, clusterKey, groupMode, group.key}
            end
            if clusterTile then
              table.insert(tiles, clusterTile)
            end
          else
            -- For "None" clustering, add items directly without clustering
            for _, item in pairs(clusterData.itemsByKey) do
              table.insert(tiles, item)
            end
          end
        end
      end

      -- Update group tiles
      group.tiles = tiles
    end

    -- Handle completeClusters and unclustered mode by duplicating tiles to special groups
    if displayData.showFavouritesMode == 'completeClusters' or displayData.showRecentMode == 'completeClusters' then
      for _, group in pairs(groups) do
        if not group.isFavouriteGroup and not group.isRecentGroup then
          for _, tile in pairs(group.tiles) do
            -- Duplicate tiles for favourites group if needed
            if displayData.showFavouritesMode == 'completeClusters' and tile.favouriteIdx and tile.favouriteIdx > 0 then
              if favouriteGroup then
                local favouriteTile = {}
                for k, v in pairs(tile) do
                  favouriteTile[k] = v
                end
                favouriteTile.key = favouriteTile.key .. "_fav_" .. tile.favouriteIdx
                favouriteTile.isClustered = true
                -- For cluster tiles, rewrite gotoPath based on cluster mode:
                --  - completeClusters: keep the source cluster's gotoPath so the detail page
                --    returns the full cluster (matches the displayed sub-element count).
                --  - reducedClusters: append the Favourites meta filter so the detail page
                --    returns only the favourite subset represented by the duplicated tile.
                -- Leaf items have no gotoPath and are launched directly, so leave them alone.
                if tile.gotoPath and tile.gotoPath[1] == "detailGameplay" then
                  if displayData.showFavouritesMode == 'completeClusters' then
                    favouriteTile.gotoPath = deepcopy(tile.gotoPath)
                  else
                    local clusterMode = tile.gotoPath[2] or "none"
                    local clusterKey = tile.gotoPath[3] or ""
                    favouriteTile.gotoPath = {"detailGameplay", clusterMode, clusterKey, "", "", "Favourites"}
                  end
                end
                table.insert(favouriteGroup.tiles, favouriteTile)
              end
            end

            -- Duplicate tiles for recent group if needed
            if (displayData.showRecentMode == 'completeClusters' or displayData.showRecentMode == 'unclustered') and tile.recentIdx and tile.recentIdx < math.huge then
              if recentGroup then
                local recentTile = {}
                for k, v in pairs(tile) do
                  recentTile[k] = v
                end
                recentTile.key = recentTile.key .. "_recent_" .. tile.recentIdx
                recentTile.isClustered = displayData.showRecentMode == 'completeClusters' -- Only mark as clustered for completeClusters mode
                -- For cluster tiles, rewrite gotoPath based on cluster mode:
                --  - completeClusters: keep the source cluster's gotoPath so the detail page
                --    returns the full cluster (matches the displayed sub-element count).
                --  - reducedClusters / unclustered: append the Recent meta filter so the detail
                --    page returns only the recent subset represented by the duplicated tile.
                if tile.gotoPath and tile.gotoPath[1] == "detailGameplay" then
                  if displayData.showRecentMode == 'completeClusters' then
                    recentTile.gotoPath = deepcopy(tile.gotoPath)
                  else
                    local clusterMode = tile.gotoPath[2] or "none"
                    local clusterKey = tile.gotoPath[3] or ""
                    recentTile.gotoPath = {"detailGameplay", clusterMode, clusterKey, "", "", "Recent"}
                  end
                end
                table.insert(recentGroup.tiles, recentTile)
              end
            end
          end
        end
      end
    end
    local currentFreeroamLevelTile = backend.backendName == "freeroamSelector"
      and freeroam_freeroamConfigurator.getCurrentSelectionRecentTile("level") or nil
    if currentFreeroamLevelTile then
      recentGroup = ensureRecentGroup(groups, recentGroup, displayData)
    end

    -- Sort tiles within each group
    for _, group in pairs(groups) do
      if group.isRecentGroup then
        for _, tile in pairs(group.tiles) do
          tile.recentIdx = backend.isRecent(tile.key) or math.huge
        end
        table.sort(group.tiles, function(a, b)
          return (a.recentIdx or math.huge) < (b.recentIdx or math.huge)
        end)
        prependTileToGroup(group, currentFreeroamLevelTile)
      elseif group.isFavouriteGroup then
        table.sort(group.tiles, function(a, b)
          return (a.favouriteIdx or 0) > (b.favouriteIdx or 0)
        end)
      elseif displayData.sorting == "automatic" then
        -- Use centralized gameplay automatic sorting
        tileSorting.sortTiles(group.tiles, "GameplayAutomatic")
      else
        -- Use UI value conversion for consistent sorting
        tileSorting.sortTilesFromUIValue(group.tiles, displayData.sorting)
      end

    end

    -- Convert groups table to list and filter out empty groups
    local groupsList = {}
    for _, group in pairs(groups) do
      if #group.tiles > 0 then
        table.insert(groupsList, group)
      end
    end

    -- Sort groups based on specific rules
    table.sort(groupsList, function(a, b)
      -- Special groups always come first
      if a.isRecentGroup and not b.isRecentGroup then return true end
      if b.isRecentGroup and not a.isRecentGroup then return false end
      if a.isFavouriteGroup and not b.isFavouriteGroup and not b.isRecentGroup then return true end
      if b.isFavouriteGroup and not a.isFavouriteGroup and not a.isRecentGroup then return false end

      -- If both are special groups, use order
      if (a.isRecentGroup or a.isFavouriteGroup) and (b.isRecentGroup or b.isFavouriteGroup) then
        return a.order < b.order
      end

      -- Regular groups: system order for automatic mode, alphabetical otherwise
      if groupMode == "system" then
        -- Use centralized system order from tileSorting module
        local aOrder = tileSorting.SYSTEM_ORDER[a.key] or 999
        local bOrder = tileSorting.SYSTEM_ORDER[b.key] or 999

        if aOrder == bOrder then
          return tileSorting.sortByNameButOtherAlwaysLast({name = a.label}, {name = b.label})
        end
        return aOrder < bOrder
      else
        -- Alphabetical with "Other..." always last
        return tileSorting.sortByNameButOtherAlwaysLast({name = a.label}, {name = b.label})
      end
    end)

    return groupsList
  end
  return {}
end

local function hasValidSubGroup(tile)
  return type(tile.gameplaySelectorSubGroup) == "string" and tile.gameplaySelectorSubGroup ~= ""
end

local function handleConfigsForBrandSubModelOrModelPath(tiles)
  if #tiles == 0 then
    return nil
  end

  for _, tile in ipairs(tiles) do
    if not hasValidSubGroup(tile) then
      return nil
    end
  end

  local subGroups = {}
  for _, tile in ipairs(tiles) do
    local subKey = tile.gameplaySelectorSubGroup
    if not subGroups[subKey] then
      subGroups[subKey] = {
        key = "configsForBrandSubModelOrModel_" .. subKey,
        label = _tr(subKey),
        tiles = {}
      }
    end
    table.insert(subGroups[subKey].tiles, tile)
  end

  local groupList = {}
  for _, subGroup in pairs(subGroups) do
    if next(subGroup.tiles) then
      table.insert(groupList, subGroup)
    end
  end

  table.sort(groupList, function(a, b)
    return a.key < b.key
  end)

  return groupList
end

-- Path handler for "detailGameplay" - displays filtered gameplay tiles for a specific cluster/group
local function handleDetailGameplayPath(path, data, items)
  local pathKeys = path.keys or {}

  local clusterMode = pathKeys[2] or "None"
  local clusterKey = pathKeys[3] or ""
  local groupKey = pathKeys[4] or ""
  local groupName = pathKeys[5] or ""
  local metaMode = pathKeys[6] or ""

  local system = clusterKey

  --print(string.format("handleDetailGameplayPath: clusterMode: %s, clusterKey: %s, groupKey: %s, groupName: %s, pathKeys: %s", clusterMode, clusterKey, groupKey, groupName, pathKeys))

  local groups = {}
  local filteredItems = {}
  if clusterMode == "automatic" then
    clusterMode = "system"
  end

  -- Filter items based on the automatic clustering rules
  for _, item in pairs(items) do
    -- Apply general filters first
    if not backend.passesFilters(item) then
      goto continue
    end
    local pass = true
    if clusterMode and clusterMode ~= "none" and (item[clusterMode] or "Other...") ~= system then
      pass = false
    end
    if groupKey and groupKey ~= "" and (item[groupKey] or "Other...") ~= groupName then
      pass = false
    end
    if metaMode == "Favourites" and not backend.isFavourite(item.key) then
      pass = false
    end
    if metaMode == "Recent" and not backend.isRecent(item.key) then
      pass = false
    end
    if pass then
      table.insert(filteredItems, item)
    end
    ::continue::
  end

  if #filteredItems > 0 then
    -- Get display data for sorting
    local displayData = backend.getDisplayData()
    -- Sort tiles within the group based on display settings
    tileSorting.sortTilesFromUIValue(filteredItems, displayData.sorting)

    local hasDefaultTile = false
    for _, tile in pairs(filteredItems) do
      tile.isDefaultSelected = false
      if tile.isDefaultSpawnPoint then
        tile.isDefaultSelected = true
        hasDefaultTile = true
        break
      end
    end
    if not hasDefaultTile then
      filteredItems[1].isDefaultSelected = true
    end

    local subGroupedTiles = handleConfigsForBrandSubModelOrModelPath(filteredItems)
    if subGroupedTiles then
      return subGroupedTiles
    end

    -- Create a single group with the filtered items
    table.insert(groups, {
      --label = string.format("%s (%s is %s)", clusterKey, groupKey, groupName),
      tiles = filteredItems
    })
  end


  return groups
end

-- Path handler for "spawnPointsForLevel" - semantic alias for freeroam level spawn points
local function normalizeSpawnPointsLevelSegment(levelSegment)
  if type(levelSegment) ~= "string" or levelSegment == "" then
    return nil
  end

  local levelData = core_levels.getLevelByName(levelSegment)
  if type(levelData) == "table" and type(levelData.title) == "string" and levelData.title ~= "" then
    return _tr(levelData.title)
  end

  return levelSegment
end

local function handleSpawnPointsForLevelPath(path, data, items)
  local pathKeys = path.keys or {}
  local levelName = normalizeSpawnPointsLevelSegment(pathKeys[2])
  if not levelName or levelName == "" then
    return {}
  end

  -- Optional third segment carries a Recent/Favourites meta filter so the
  -- detail grid can hydrate only the subset represented by a clustered tile.
  local metaMode = pathKeys[3]
  local detailKeys = {"detailGameplay", "system", "freeroam", "level", levelName}
  if metaMode == "Recent" or metaMode == "Favourites" then
    detailKeys[6] = metaMode
  end

  local detailPath = { keys = detailKeys }

  return handleDetailGameplayPath(detailPath, data, items)
end

-- Get tiles for a specific path

function M.getTiles(path, _backend, routeName)
  backend = _backend
  local data = backend.getUiData(routeName)
  local pathKeys = path.keys or {}
  local pathType = pathKeys[1] or "allGameplay"
  tileClustering.setBackend(backend)

  -- Use stored items instead of creating them every time
  local items = data.items
  for _, item in pairs(items) do
    item.showFavouriteIconPercent = backend.isFavourite(item.key) and 1 or 0
    if backend.backendName == "freeroamSelector" and item.type == "freeroamSpawnpoint" then
      if freeroam_freeroamConfigurator.isCurrentSelection("level", item.showDetails) then
        item.cornerIcon = "road"
      else
        item.cornerIcon = nil
      end
    end
  end
  local validItems = items
  if backend.backendName == "freeroamSelector" then
    -- filter only
    validItems = {}
    for _, item in pairs(items) do
      if item.validBackends[backend.backendName] then
        table.insert(validItems, item)
      end
    end
  end

  -- Route to appropriate path handler
  if pathType == "allGameplay" then
    return handleAllGameplayPath(path, data, items)
  elseif pathType == "detailGameplay" then
    return handleDetailGameplayPath(path, data, items)
  elseif pathType == "spawnPointsForLevel" then
    return handleSpawnPointsForLevelPath(path, data, items)
  else
    -- Default to allGameplay for unknown paths
    return handleAllGameplayPath(path, data, items)
  end
end

-- Get UI data for tiles
function M.getUiData()
  return {
    backendName = backendName,
    groupModeFunctions = groupModeFunctions,
    sortModeFunctions = sortModeFunctions,
    tileSorting = tileSorting,
  }
end



return M
