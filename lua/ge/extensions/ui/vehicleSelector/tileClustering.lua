local M = {}

-- Clustering mode functions
local clusterModeFunctions = {
  ['brandSubModelOrModel'] = function(config)
    local model = core_vehicles.getModel(config.model_key)
    local brand = config.Brand or model.model.Brand
    local subModel = config.SubModel
    if subModel == nil then
      if model and model.model then
        subModel = model.model.SubModel
      end
    end
    subModel = subModel or config.model_key
    brand = brand or ""
    return brand .. " " .. subModel
  end,
  ['model'] = function(config)
    return config.model_key .. (config.useSubCluster and " " .. (config.vehicleSelectorSubCluster or "") or "" )
  end,
}

-- Get favourite and recent vehicle statistics for clustered items
local function getClusteredItemsFavouriteIconPercent(clusteredItems)
  local highestFavouriteConfig, lowestRecentConfig = nil, nil
  local favouriteCount = 0
  local highestFavouriteIdx = 0
  local lowestRecentIdx = math.huge
  for _configKey, config in pairs(clusteredItems.configsByKey) do
    local favouriteIdx = ui_vehicleSelector_general.isFavourite(config.model_key, config.key) or 0
    local recentIdx = ui_vehicleSelector_general.isRecentVehicle(config.model_key, config.key) or math.huge
    if favouriteIdx > highestFavouriteIdx then
      highestFavouriteIdx = favouriteIdx
      highestFavouriteConfig = config
    end
    if recentIdx < lowestRecentIdx then
      lowestRecentIdx = recentIdx
      lowestRecentConfig = config
    end
    favouriteCount = favouriteCount + (ui_vehicleSelector_general.isFavourite(config.model_key, config.key) and 1 or 0)
  end
  return highestFavouriteIdx, lowestRecentIdx, favouriteCount > 0 and (favouriteCount / clusteredItems.count) or 0, highestFavouriteConfig, lowestRecentConfig
end

-- Get statistics for clustered items (preview, model, config selection)
local function getClusteredItemsStats(clusteredItems, sortMode)
  local _, config = next(clusteredItems.configsByKey)
  local model = core_vehicles.getModel(config.model_key)
  local preview = model.model.preview or model.model.preview or ("/vehicles/" .. model.model.key .. "/default.jpg")

  -- Import sorting functions
  local tileSorting = require('/lua/ge/extensions/ui/vehicleSelector/tileSorting')
  if sortMode == "Automatic" or sortMode == "Name" then
    if not clusteredItems.configsByKey[model.model.default_pc] then
      local configsByConfigTypeName = {}
      local defaultConfigForSubCluster = nil
      for _, config in pairs(clusteredItems.configsByKey) do
        if config.isDefaultForSubCluster then
          defaultConfigForSubCluster = config
          break
        end
        table.insert(configsByConfigTypeName, config)
      end
      if defaultConfigForSubCluster then
        preview = defaultConfigForSubCluster.preview or preview
        return preview, model.model.key, defaultConfigForSubCluster.key, defaultConfigForSubCluster
      end
      table.sort(configsByConfigTypeName, tileSorting.sortByConfigTypeName)
      local config = configsByConfigTypeName[1]
      preview = config.preview or preview
      return preview, model.model.key, config.key, config
    end
    return preview, model.model.key, model.model.default_pc, clusteredItems.configsByKey[model.model.default_pc]
  end

  -- Use the sort mode to sort the configs
  local sortFunc = tileSorting.getSortFunction(sortMode)
  table.sort(clusteredItems.list, sortFunc)
  local last = clusteredItems.list[#clusteredItems.list]
  preview = last.preview or preview
  local previewModel = last.model_key
  local previewConfig = last.key

  return preview, previewModel, previewConfig, last
end

-- Get sources for a config
local function getSources(config, model, onlyIcons)
  local sources = {}
  local source = config.Source or model.Source
  if source == "BeamNG - Official" then
    if not onlyIcons then
      table.insert(sources, translate("ui.menu.gridSelector.tags.beamngOfficial"))
    end
    table.insert(sources, "beamNG")
  elseif source == "Custom" then
    if not onlyIcons then
      table.insert(sources, translate("ui.menu.gridSelector.tags.custom"))
    end
    table.insert(sources, "wrench")
  end
  if config.Type == "Automation" or model.Type == "Automation" then
    if not onlyIcons then
      table.insert(sources, "Automation")
    end
    table.insert(sources, "/ui/assets/Original/camshaft_automation_logo.svg")
  end
  if config.modID then
    if not onlyIcons then
      table.insert(sources, config.Source)
    end
    table.insert(sources, "puzzleModule")
  end
  if model.missingJbeamFiles then
    if not onlyIcons then
      table.insert(sources, translate("ui.menu.gridSelector.tags.missingJbeamFiles"))
    end
    table.insert(sources, "danger")
  end
  return sources
end

-- Create tile from clustered items for brandSubModelOrModel mode
local function createTileFromBrandSubModelOrModel(clusteredItems, group)
  local _, config = next(clusteredItems.configsByKey)
  local model = core_vehicles.getModel(config.model_key)
  local subModel = config.SubModel or model.model.SubModel
  local brand = config.Brand or model.model.Brand
  local name = (brand and brand .. " " or "")
  if subModel then
    name = name .. subModel
  else
    name = name .. (model.model.Name or model.model.key)
  end
  local gotoPath = {"configsForBrandSubModelOrModel", model.model.key, subModel or "", brand or ""}
  local highestFavouriteIdx, lowestRecentIdx, showFavouriteIconPercent, highestFavouriteConfig, lowestRecentConfig = getClusteredItemsFavouriteIconPercent(clusteredItems)
  local sortMode = ui_vehicleSelector_general.getUiData().displayData.sortMode
  local preview, previewModel, previewConfig, last = getClusteredItemsStats(clusteredItems, sortMode)
  local allAuxiliary = true
  for _, config in pairs(clusteredItems.configsByKey) do
    if not config.isAuxiliary then
      allAuxiliary = false
      break
    end
  end
  local sourcesByIconCount = {}
  for _, config in pairs(clusteredItems.configsByKey) do
    local sources = getSources(config, model.model, true)
    for _, source in ipairs(sources) do
      sourcesByIconCount[source] = (sourcesByIconCount[source] or 0) + 1
    end
  end
  local sources = tableKeys(sourcesByIconCount)
  table.sort(sources, function(a, b)
    return sourcesByIconCount[a] > sourcesByIconCount[b]
  end)
  local sourceIcons = {}
  for _, source in ipairs(sources) do
    if string.endswith(source, ".svg") then
      table.insert(sourceIcons, {svg = source})
    else
      table.insert(sourceIcons, {icon = source})
    end
  end
  return {
    key = string.format("%s_%s_%s", group.key, model.model.key .. (subModel or ""), previewConfig or ""),
    name = name,
    brand = brand,
    preview = preview,
    subElementCount = clusteredItems.count,
    favouriteIdx = highestFavouriteIdx,
    recentIdx = lowestRecentIdx,
    gotoPath = arrayConcat(gotoPath, group.gotoParams or {}),
    showFavouriteIconPercent = showFavouriteIconPercent,
    doubleClickDetails = {model = previewModel, config = previewConfig},
    highestFavouriteConfig = highestFavouriteConfig,
    lowestRecentConfig = lowestRecentConfig,
    doubleClickMode = "capture",
    Value = last and last.Value or 0,
    Weight = last and last.Weight or 0,
    ['Top Speed'] = last and last['Top Speed'] or 0,
    Power = last and last.Power or 0,
    ['Power/Weight'] = last and last.Power and last.Weight and last.Weight > 0 and last.Power > 0 and last.Power / last.Weight or math.huge,
    ['0-60 mph'] = last and last['0-60 mph'] or math.huge,
    ['0-100 km/h'] = last and last['0-100 km/h'] or math.huge,
    isAuxiliary = allAuxiliary,
    sourceIcons = sourceIcons,
  }
end

-- Create tile from clustered items for model mode
local function createTileFromModel(clusteredItems, group)
  local _, config = next(clusteredItems.configsByKey)
  local model = core_vehicles.getModel(config.model_key)
  local brand = model.model.Brand
  local name = (brand and brand .. " " or "") .. (model.model.Name or model.model.key)
  local gotoPath = {"configsForBrandSubModelOrModel", model.model.key, "", ""}
  local highestFavouriteIdx, lowestRecentIdx, showFavouriteIconPercent, highestFavouriteConfig, lowestRecentConfig = getClusteredItemsFavouriteIconPercent(clusteredItems)
  local sortMode = ui_vehicleSelector_general.getUiData().displayData.sortMode
  local preview, previewModel, previewConfig, last = getClusteredItemsStats(clusteredItems, sortMode)
  local allAuxiliary = true
  for _, config in pairs(clusteredItems.configsByKey) do
    if not config.isAuxiliary then
      allAuxiliary = false
      break
    end
  end
  local useSubCluster = model.model.useSubCluster
  local allSameSubCluster = true
  local subCluster = config.vehicleSelectorSubCluster or ""
  for _, config in pairs(clusteredItems.configsByKey) do
    if config.vehicleSelectorSubCluster ~= subCluster then
      allSameSubCluster = false
      break
    end
  end
  if allSameSubCluster then
    useSubCluster = true
  end
  if useSubCluster then
    gotoPath = {"configsForBrandSubModelOrModel", model.model.key, subCluster, ""}
    name = (brand and brand .. " " or "") .. subCluster
  end

  local sourcesByIconCount = {}
  for _, config in pairs(clusteredItems.configsByKey) do
    local sources = getSources(config, model.model, true)
    for _, source in ipairs(sources) do
      sourcesByIconCount[source] = (sourcesByIconCount[source] or 0) + 1
    end
  end
  local sources = tableKeys(sourcesByIconCount)
  table.sort(sources, function(a, b)
    return sourcesByIconCount[a] > sourcesByIconCount[b]
  end)
  local sourceIcons = {}
  for _, source in ipairs(sources) do
    if string.endswith(source, ".svg") then
      table.insert(sourceIcons, {svg = source})
    else
      table.insert(sourceIcons, {icon = source})
    end
  end
  return {
    key = string.format("%s_%s_%s", group.key, model.model.key, previewConfig or ""),
    name = name,
    preview = preview,
    subElementCount = clusteredItems.count,
    favouriteIdx = highestFavouriteIdx,
    recentIdx = lowestRecentIdx,
    gotoPath = arrayConcat(gotoPath, group.gotoParams or {}),
    showFavouriteIconPercent = showFavouriteIconPercent,
    doubleClickDetails = {model = previewModel, config = previewConfig},
    highestFavouriteConfig = highestFavouriteConfig,
    lowestRecentConfig = lowestRecentConfig,
    doubleClickMode = "capture",
    Value = last and last.Value or 0,
    Weight = last and last.Weight or 0,
    ['Top Speed'] = last and last['Top Speed'] or 0,
    Power = last and last.Power or 0,
    ['Power/Weight'] = last and last.Power and last.Weight and last.Weight > 0 and last.Power > 0 and last.Power / last.Weight or math.huge,
    ['0-60 mph'] = last and last['0-60 mph'] or math.huge,
    ['0-100 km/h'] = last and last['0-100 km/h'] or math.huge,
    isAuxiliary = allAuxiliary,
    sourceIcons = sourceIcons,
  }
end

-- Tile creation functions for different cluster modes
local tileFromClusteredItems = {
  ['brandSubModelOrModel'] = createTileFromBrandSubModelOrModel,
  ['model'] = createTileFromModel,
}

-- Cluster configs by the specified cluster mode
function M.clusterItems(configs, clusterMode)
  local clusteredItems = {}
  for _, config in pairs(configs) do
    local groups = clusterModeFunctions[clusterMode](config) or "No Data"
    if type(groups) == "string" then groups = {groups} end
    for _, group in pairs(groups) do

      if not clusteredItems[group] then
        clusteredItems[group] = {configsByKey = {}, count = 0, list = {}}
      end
      clusteredItems[group].configsByKey[config.key] = config
      clusteredItems[group].count = clusteredItems[group].count + 1
      clusteredItems[group].list[clusteredItems[group].count] = config
      local years = config.Years or config.years or math.huge
      if type(years) == "table" then
        years = years.min
      end
      clusteredItems[group].years = math.min(years, clusteredItems[group].years or math.huge)
      local value = config.Value or config.value or 0
      if type(value) == "table" then
        value = value.min
      end
      clusteredItems[group].value = math.min(value, clusteredItems[group].value or math.huge)
    end
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
M.getSources = getSources

return M
