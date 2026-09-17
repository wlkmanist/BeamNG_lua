local M = {}
local backend = nil

M.setBackend = function(_backend)
  backend = _backend
end

-- Clustering mode functions for gameplay elements
local clusterModeFunctions = {
  ['level'] = function(item)
    return item.level or "Other..."
  end,
  ['type'] = function(item)
    return item.type or "Other..."
  end,
  ['automatic'] = function(item)
    local system = item.system or "Other..."
    if system == "campaigns" then
      return "None" -- No clustering for campaign system
    elseif system == "Other Gameplay" then
      return "None" -- No clustering for More system - add to group normally
    elseif system == "freeroam" then
      return item.level or "Other..." -- Cluster by level for freeroam system
    elseif system == "scenarios" or system == "scenariosMultiplayer" then
      return item.level or "Other..." -- Cluster by level for scenario system
    elseif system == "challenges" then
      return item.type or "Other..." -- Cluster by type for challenges system
    elseif item.level then
      return item.level
    else
      return "Other..."
    end
  end,
  ['none'] = function(item)
    return "None"
  end,
}

-- Get favourite and recent statistics for clustered items
local function getClusteredItemsFavouriteIconPercent(clusteredItems)
  local highestFavouriteConfig, lowestRecentConfig = nil, nil
  local favouriteCount = 0
  local highestFavouriteIdx = 0
  local lowestRecentIdx = math.huge

  for _itemKey, item in pairs(clusteredItems.itemsByKey) do
    local favouriteIdx = backend.isFavourite(item.key) or 0
    local recentIdx = backend.isRecent(item.key) or math.huge

    if favouriteIdx > highestFavouriteIdx then
      highestFavouriteIdx = favouriteIdx
      highestFavouriteConfig = item
    end

    if recentIdx < lowestRecentIdx then
      lowestRecentIdx = recentIdx
      lowestRecentConfig = item
    end

    favouriteCount = favouriteCount + (backend.isFavourite(item.key) and 1 or 0)
  end

  return highestFavouriteIdx, lowestRecentIdx, favouriteCount > 0 and (favouriteCount / clusteredItems.count) or 0, highestFavouriteConfig, lowestRecentConfig
end

-- Get statistics for clustered items (preview, item selection)
local function getClusteredItemsStats(clusteredItems, sortMode)
  local _, item = next(clusteredItems.itemsByKey)
  local preview = item.preview or "/gameplay/default/preview.jpg"

  -- Check if all items are spawnpoint items
  local allSpawnPoints = true
  local defaultSpawnPoint = nil

  for _, item in pairs(clusteredItems.itemsByKey) do
    if item.type ~= "freeroamSpawnpoint" then
      allSpawnPoints = false
      break
    end
    -- Look for the default spawnpoint
    if item.isDefaultSpawnPoint then
      defaultSpawnPoint = item
    end
  end

  -- If all items are spawnpoints and we found a default one, use its preview
  if allSpawnPoints and defaultSpawnPoint then
    preview = defaultSpawnPoint.levelPreviews and defaultSpawnPoint.levelPreviews[1] or preview
    return preview, defaultSpawnPoint
  end

  -- Check if all items have the same missionTypeLabel
  local firstMissionTypeLabel = nil
  local allSameMissionType = true
  local firstMissionItem = nil

  for _, item in pairs(clusteredItems.itemsByKey) do
    if firstMissionTypeLabel == nil and item.missionTypeLabel then
      firstMissionTypeLabel = item.missionTypeLabel
      firstMissionItem = item
    elseif item.missionTypeLabel ~= firstMissionTypeLabel then
      allSameMissionType = false
      break
    end
  end

  -- If all items have the same missionTypeLabel, use the first one
  if allSameMissionType and firstMissionTypeLabel then
    local mission = gameplay_missions_missions.getMissionById(firstMissionItem.showDetails.missionId)
    preview = mission.defaultPreviewFile or firstMissionItem.preview or preview
    return preview, firstMissionItem
  end

  -- For now, use the first item as preview
  -- In a more complex implementation, you could sort by the sortMode
  if sortMode == "Name" then
    local itemsList = {}
    for _, item in pairs(clusteredItems.itemsByKey) do
      table.insert(itemsList, item)
    end
    table.sort(itemsList, function(a, b)
      return (a.name or "") < (b.name or "")
    end)
    local firstItem = itemsList[1]
    preview = firstItem.preview or preview
    return preview, firstItem
  end

  return preview, item
end

local sourceIconsOrder = {
  beamNG = 1,
  camshaft = 2,
  puzzleModule = 3,
  cup = 4,
  bug = 5,
}
-- all others are at the end and sorted by name

local function getSourceIcons(clusteredItems)
  local sourceIconsLookup = {}
  for _, item in pairs(clusteredItems.itemsByKey) do
    for _, source in pairs(item.sourceIcons or {}) do
      sourceIconsLookup[source.icon or source.svg] = true
    end
  end
  local sourceIcons = {}
  for source, active in pairs(sourceIconsLookup) do
    if string.endswith(source, ".svg") then
      table.insert(sourceIcons, {svg = source})
    else
      table.insert(sourceIcons, {icon = source})
    end
  end
  local sourceIconsWithOrder, sourceIconsWithoutOrder = {}, {}
  for _, sourceIcon in pairs(sourceIcons) do
    if sourceIconsOrder[sourceIcon.icon or sourceIcon.svg] then
      table.insert(sourceIconsWithOrder, sourceIcon)
    else
      table.insert(sourceIconsWithoutOrder, sourceIcon)
    end
  end
  table.sort(sourceIconsWithOrder, function(a, b)
    return sourceIconsOrder[a.icon or a.svg] < sourceIconsOrder[b.icon or b.svg]
  end)
  table.sort(sourceIconsWithoutOrder, function(a, b)
    return (a.icon or a.svg) < (b.icon or b.svg)
  end)
  return arrayConcat(sourceIconsWithOrder, sourceIconsWithoutOrder)
end

local function getAuxiliarySum(clusteredItems)
  local auxiliarySum = true
  for _, item in pairs(clusteredItems.itemsByKey) do
    auxiliarySum = auxiliarySum and item.isAuxiliary
  end
  return auxiliarySum
end

-- Create tile from clustered items for level mode
local function createTileFromLevel(clusteredItems, group)
  local _, item = next(clusteredItems.itemsByKey)
  local level = item.level or "Other..."
  local name = level
  local gotoPath = {"detailGameplay", "level", level}

  local highestFavouriteIdx, lowestRecentIdx, showFavouriteIconPercent, highestFavouriteConfig, lowestRecentConfig = getClusteredItemsFavouriteIconPercent(clusteredItems)
  local sortMode = "Name" -- Could be retrieved from UI data
  local preview, _ = getClusteredItemsStats(clusteredItems, sortMode)


  return {
    key = string.format("%s_%s", group.key, level),
    name = name,
    preview = preview,
    subElementCount = clusteredItems.count,
    favouriteIdx = highestFavouriteIdx,
    recentIdx = lowestRecentIdx,
    gotoPath = arrayConcat(gotoPath, group.gotoParams or {}),
    showFavouriteIconPercent = showFavouriteIconPercent,
    doubleClickDetails = item.doubleClickDetails,
    highestFavouriteConfig = highestFavouriteConfig,
    lowestRecentConfig = lowestRecentConfig,
    doubleClickMode = item.doubleClickDetails and "capture" or "explore",
    sourceIcons = getSourceIcons(clusteredItems),
    isAuxiliary = getAuxiliarySum(clusteredItems),
  }
end

-- Create tile from clustered items for type mode
local function createTileFromType(clusteredItems, group)
  local _, item = next(clusteredItems.itemsByKey)
  local typeName = item.type or "Other..."
  local name = typeName
  local gotoPath = {"detailGameplay", "type", typeName}

  local highestFavouriteIdx, lowestRecentIdx, showFavouriteIconPercent, highestFavouriteConfig, lowestRecentConfig = getClusteredItemsFavouriteIconPercent(clusteredItems)
  local sortMode = "Name" -- Could be retrieved from UI data
  local preview, _ = getClusteredItemsStats(clusteredItems, sortMode)



  return {
    key = string.format("%s_%s", group.key, typeName),
    name = name,
    preview = preview,
    subElementCount = clusteredItems.count,
    favouriteIdx = highestFavouriteIdx,
    recentIdx = lowestRecentIdx,
    gotoPath = arrayConcat(gotoPath, group.gotoParams or {}),
    showFavouriteIconPercent = showFavouriteIconPercent,
    doubleClickDetails = item.doubleClickDetails,
    highestFavouriteConfig = highestFavouriteConfig,
    lowestRecentConfig = lowestRecentConfig,
    doubleClickMode = item.doubleClickDetails and "capture" or "explore",
    sourceIcons = getSourceIcons(clusteredItems),
    isAuxiliary = getAuxiliarySum(clusteredItems),
  }
end

-- Create tile from clustered items for automatic mode
local function createTileFromAutomatic(clusteredItems, group)
  local sortMode = "Name" -- Could be retrieved from UI data
  local preview, item = getClusteredItemsStats(clusteredItems, sortMode)
  local system = item.system or "Other..."
  local name = ""
  local gotoPath = {"detailGameplay", "automatic", system}


  -- Determine clustering strategy based on system
  if system == "campaigns" then
    -- No clustering for campaign system - this shouldn't be called
    name = "Campaign Items"
  elseif system == "freeroam" then
    local level = item.level or "Other..."
    name = level
    gotoPath = arrayConcat(gotoPath, {"level", level})
  elseif system == "scenarios" or system == 'scenariosMultiplayer' then
    local level = item.level or "Other..."
    name = level
    gotoPath = arrayConcat(gotoPath, {"level", level})
  elseif system == "challenges" then
    local typeName = item.type or "Other..."
    name = typeName
    gotoPath = arrayConcat(gotoPath, {"type", typeName})
  else
    name = system
  end

  if group.isRecentGroup then
    gotoPath = arrayConcat(gotoPath, {"Recent"})
  end
  if group.isFavouriteGroup then
    gotoPath = arrayConcat(gotoPath, {"Favourites"})
  end

  local highestFavouriteIdx, lowestRecentIdx, showFavouriteIconPercent, highestFavouriteConfig, lowestRecentConfig = getClusteredItemsFavouriteIconPercent(clusteredItems)


  return {
    key = string.format("%s_%s_%s", group.key, system, name),
    name = name,
    preview = preview,
    subElementCount = clusteredItems.count,
    favouriteIdx = highestFavouriteIdx,
    recentIdx = lowestRecentIdx,
    gotoPath = gotoPath,
    showFavouriteIconPercent = showFavouriteIconPercent,
    doubleClickDetails = item.doubleClickDetails,
    highestFavouriteConfig = highestFavouriteConfig,
    lowestRecentConfig = lowestRecentConfig,
    doubleClickMode = item.doubleClickDetails and "capture" or "explore",
    sourceIcons = getSourceIcons(clusteredItems),
    isAuxiliary = getAuxiliarySum(clusteredItems),
  }
end

-- Tile creation functions for different cluster modes
local tileFromClusteredItems = {
  ['level'] = createTileFromLevel,
  ['type'] = createTileFromType,
  ['automatic'] = createTileFromAutomatic,
}

-- Cluster items by the specified cluster mode
function M.clusterItems(items, clusterMode)
  local clusteredItems = {}

  for _, item in pairs(items) do
    local group = clusterModeFunctions[clusterMode](item) or "Other..."

    if not clusteredItems[group] then
      clusteredItems[group] = {itemsByKey = {}, count = 0, list = {}}
    end

    clusteredItems[group].itemsByKey[item.key] = item
    clusteredItems[group].count = clusteredItems[group].count + 1
    clusteredItems[group].list[clusteredItems[group].count] = item
  end

  return clusteredItems
end

-- Create tile from clustered items
function M.createTileFromClusteredItems(clusteredItems, group, clusterMode)
  local createFunc = tileFromClusteredItems[clusterMode]
  if createFunc then
    return createFunc(clusteredItems, group)
  end
  return nil
end

-- Get cluster mode function
function M.getClusterModeFunction(clusterMode)
  return clusterModeFunctions[clusterMode]
end

-- Public API
M.getClusteredItemsFavouriteIconPercent = getClusteredItemsFavouriteIconPercent
M.getClusteredItemsStats = getClusteredItemsStats
M.getSourceIcons = getSourceIcons

return M