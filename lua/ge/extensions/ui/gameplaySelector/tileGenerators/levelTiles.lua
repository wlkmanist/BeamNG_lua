local M = {}


local function getKeyFromDetails(details)
  return string.format("spawnPoint_%s_%s", details.levelName, details.spawnPointObjectName)
end

local function isMatchingSpawnPoint(level, spawnPoint, candidate)
  if type(spawnPoint) ~= "table" or type(candidate) ~= "string" or candidate == "" then
    return false
  end
  return spawnPoint.objectname == candidate
    or spawnPoint.name == candidate
    or spawnPoint.translationId == candidate
    or (level and level.defaultSpawnPointName == candidate and spawnPoint.flag == "default")
end

local function findSpawnPoint(level, candidate)
  if type(level) ~= "table" or type(level.spawnPoints) ~= "table" then
    return nil
  end
  for _, spawnPoint in ipairs(level.spawnPoints) do
    if isMatchingSpawnPoint(level, spawnPoint, candidate) then
      return spawnPoint
    end
  end
  return nil
end

local function getSpawnPointObjectName(level, spawnPoint)
  if type(spawnPoint) ~= "table" then
    return nil
  end
  if type(spawnPoint.objectname) == "string" and spawnPoint.objectname ~= "" then
    return spawnPoint.objectname
  end
  if type(level) == "table" and spawnPoint.flag == "default" then
    return level.defaultSpawnPointName
  end
  return nil
end

local function onGameplaySelectorGetTiles(items)
  for _, level in ipairs(core_levels.getList()) do
    local defaultSpawnPointCount = 0
    for idx, spawnPoint in ipairs(level.spawnPoints) do
      local name = spawnPoint.translationId or spawnPoint.name or spawnPoint.objectname or "ui.levelselect.unnamedSpawnpoint"
      name = _tr(name)
      if level.title then
        local levelTitle = level.title
        levelTitle = _tr(levelTitle)
        name = string.format("%s (%s)", name, levelTitle)
      end
      local spawnPointObjectName = getSpawnPointObjectName(level, spawnPoint)
      local item = {
        name = name,
        preview = spawnPoint.previews and spawnPoint.previews[1] or nil,
        order = idx,
        favouriteIdx = 0,
        showFavouriteIconPercent = 0,
        --gotoPath = {"spawnPoints", "spawnPoint_" .. name},
        isDefaultSpawnPoint = spawnPoint.flag == "default" or spawnPoint.objectname == level.defaultSpawnPointName,
        levelPreviews = spawnPoint.levelPreviews,

        showDetails = {levelName = level.levelName, spawnPointObjectName = spawnPointObjectName},
        doubleClickDetails = {levelName = level.levelName, spawnPointObjectName = spawnPointObjectName},

        system = "freeroam",
        type = "freeroamSpawnpoint",
        levelName = level.levelName,
        isAuxiliary = level.isAuxiliary,
        sourceIcons = {},
        validBackends = {freeroamSelector = true, gameplaySelector = false},
        filterHook = "onFilterCustomLevelTiles"
      }
      defaultSpawnPointCount = defaultSpawnPointCount + (item.isDefaultSpawnPoint and 1 or 0)
      item.key = getKeyFromDetails(item.showDetails)
      item.showDetails.key = item.key
      item.doubleClickDetails.key = item.key
      if freeroam_freeroamConfigurator.isCurrentSelection("level", item.showDetails) then
        item.cornerIcon = "road"
      end
      if level.official then
        table.insert(item.sourceIcons, {icon = "beamNG"})
      end
      if level.authors == "BeamNG & Camshaft Software" then
        table.insert(item.sourceIcons, {svg = "/ui/assets/Original/camshaft_automation_logo.svg"})
      end
      if level.isAuxiliary then
        table.insert(item.sourceIcons, {icon = "bug"})
      end
      item.level = _tr(level.title)
      table.insert(items, item)
    end
    if defaultSpawnPointCount > 1 then
      log("E", "levelTiles", string.format("Default spawnpoint count is greater than 1 for level %s", level.levelName))
    end
  end
end
M.onGameplaySelectorGetTiles = onGameplaySelectorGetTiles

local function getLevelSpecifications(level)
  local generalSpecs = {}
  if level.size then
    local size1, size2 = level.size[1], level.size[2]

    -- Check if size is negative (infinite)
    if size1 < 0 or size2 < 0 then
      table.insert(generalSpecs, {
        label = _tr("ui.levelselect.size"),
        value = _tr("ui.common.infinite"),
        icon = "scale"
      })
    else
      local area = size1 * size2
      local metricOrImperial = settings.getValue("uiUnitLength")
      -- convert lengths from meter to km or mi
      local convertedSize1, convertedSize2, convertedArea, unit, areaUnit
      if metricOrImperial == "metric" then
        -- Metric: meters to kilometers
        convertedSize1 = size1 / 1000
        convertedSize2 = size2 / 1000
        convertedArea = area / 1000000
        unit = "km"
        areaUnit = "km²"
      else
        -- Imperial: meters to miles
        convertedSize1 = size1 * 0.000621371
        convertedSize2 = size2 * 0.000621371
        convertedArea = area * 0.000000386102
        unit = "mi"
        areaUnit = "sq mi"
      end
      table.insert(generalSpecs, {
        label = _tr("ui.levelselect.size"),
        value = string.format("%0.2f%s x %0.2f%s (%0.2f%s)", convertedSize1, unit, convertedSize2, unit, convertedArea, areaUnit),
        icon = "scale"
      })
    end
  end
  if level.biome then
    table.insert(generalSpecs, {
      label = _tr("ui.levelselect.biome"),
      value = _tr(level.biome),
      icon = "terrain"
    })
  end
  if level.roads then
    table.insert(generalSpecs, {
      label = _tr("ui.levelselect.roads"),
      value = _tr(level.roads),
      icon = "roadStack"
    })
  end
  if level.suitablefor then
    table.insert(generalSpecs, {
      label = _tr("ui.levelselect.suitablefor"),
      value = _tr(level.suitablefor),
      icon = "flag"
    })
  end
  if level.features then
    table.insert(generalSpecs, {
      label = _tr("ui.levelselect.features"),
      value = _tr(level.features),
      icon = "info"
    })
  end
  if level.country then
    table.insert(generalSpecs, {
      label = _tr("ui.quickrace.country"),
      value = _tr(level.country),
      icon = "flag"
    })
  end
  return { generalSpecs }

end


local function onGameplaySelectorGetDetails(itemDetails, details, buttonInstance, backend)
  local levelName, spawnPointObjectName = itemDetails.levelName, itemDetails.spawnPointObjectName
  if not levelName then
    return
  end
  local level = core_levels.getLevelByName(levelName)
  if not level then
    return
  end
  local spawnPoint = findSpawnPoint(level, spawnPointObjectName)
  local name = spawnPoint and (spawnPoint.translationId or spawnPoint.name or spawnPoint.objectname)
    or "ui.levelselect.unnamedSpawnpoint"
  name = _tr(name)
  if level.title then
    name = string.format("%s (%s)", name, _tr(level.title))
  end

  local data = {
    headerTitle = name,
    description = _tr(level.description),
    preview = spawnPoint and spawnPoint.previews and spawnPoint.previews[1] or level.previews and level.previews[1] or nil,
    isFavourite = backend.isFavourite(getKeyFromDetails(itemDetails)),
    buttonInfo = {},
    specifications = getLevelSpecifications(level),
    levelTitle = _tr(level.title),
    tags = {},
  }

  -- Add tags for all sourceIcons
  if level.official then
    table.insert(data.tags, {icon = "beamNG", label = _tr("ui.menu.gridSelector.tags.beamngOfficial")})
  end
  if level.authors == "BeamNG & Camshaft Software" then
    table.insert(data.tags, {svg = "/ui/assets/Original/camshaft_automation_logo.svg", label = _tr("ui.menu.gridSelector.tags.camshaftSoftware")})
  end
  if level.isAuxiliary then
    table.insert(data.tags, {icon = "bug", label = _tr("ui.menu.gridSelector.tags.auxiliary")})
  end

  -- Add mod information tags
  if level.modID then
    local mod = core_modmanager.getModNameFromID(level.modID)
    if mod then
      table.insert(data.tags, {icon = "puzzleModule", label = level.modTitle or level.modName, goToMod = mod.modID})
    end
  end

  if buttonInstance and backend then
    local defaultAction = backend.getUiData().displayData.defaultFreeroamAction or "startFreeroam"
    local startIsPrimary = defaultAction == "startFreeroam"

    table.insert(data.buttonInfo,
      buttonInstance.addButton(function()
        -- Track recent usage
        backend.trackRecent(itemDetails.key)
        -- Start freeroam
        freeroam_freeroam.startFreeroamByName(levelName, spawnPointObjectName)
      end, {
        label = _tr("ui.freeroam.startFreeroam"),
        icon = "road",
        primary = startIsPrimary,
        isDoubleClickAction = startIsPrimary,
      }))
    table.insert(data.buttonInfo,
      buttonInstance.addButton(function()
        -- open freeroam configurator with current level and spawn point
        freeroam_freeroamConfigurator.setLevel(levelName, spawnPointObjectName)
        guihooks.trigger("ChangeState", "menu.freeroamconfigurator")
      end, {
        label = _tr("ui.freeroam.configure"),
        icon = "adjust",
        primary = not startIsPrimary,
        isDoubleClickAction = not startIsPrimary,
    }))

    extensions.hook("onFreeroamSelectorGetDetails", data, level, spawnPointObjectName, buttonInstance, backend)
    local customButtons = backend.getCustomDetailsButtons()
    if customButtons and next(customButtons) then
      table.clear(data.buttonInfo)
      for _, button in ipairs(customButtons) do
        table.insert(data.buttonInfo, buttonInstance.addButton(function()
          button.callback(itemDetails.levelName, itemDetails.spawnPointObjectName, itemDetails.key)
          if button.meta.trackRecent then
            backend.trackRecent(itemDetails.key)
          end
        end, button.meta))
      end
    end
  end
  table.insert(details, data)
end
M.onGameplaySelectorGetDetails = onGameplaySelectorGetDetails



local function onFilterCustomLevelTiles(item, searchText, result)
  if not searchText or searchText == "" then
    return
  end
  local searchTextLower = string.lower(searchText)
  local level = core_levels.getLevelByName(item.levelName)
  if level then
    if level.biome then
      if string.find(string.lower(_tr(level.biome)), searchTextLower, 1, true) then
        result.match = true
        return
      end
    end
    if level.suitablefor then
      if string.find(string.lower(_tr(level.suitablefor)), searchTextLower, 1, true) then
        result.match = true
        return
      end
    end
    if level.features then
      if string.find(string.lower(_tr(level.features)), searchTextLower, 1, true) then
        result.match = true
        return
      end
    end
    if level.roads then
      if string.find(string.lower(_tr(level.roads)), searchTextLower, 1, true) then
        result.match = true
        return
      end
    end
    if level.country then
      if string.find(string.lower(_tr(level.country)), searchTextLower, 1, true) then
        result.match = true
        return
      end
    end
  end
end
M.onFilterCustomLevelTiles = onFilterCustomLevelTiles

M.setAlwaysShowDialogue = function(backendName, newValue)
  if not backendName then
    log("E", "levelTiles", "setAlwaysShowDialogue requires backendName parameter")
    return
  end
  ui_gridSelector.setDisplayDataOption(backendName, "defaultFreeroamAction", newValue and "configureFreeroam" or "startFreeroam")
end

-- Function to open level configuration popup
M.openLevelConfigurationPopup = function(levelData)
  guihooks.trigger("openLevelConfigurationPopup", levelData)
end

-- Hook to handle when freeroam selector is opened with item details
local function onFreeroamSelectorOpenedWithItemDetails(itemDetails, backend)
  if itemDetails then
    -- Re-open the level configuration popup with the stored item details
    local levelName = itemDetails.levelName
    local spawnPointObjectName = itemDetails.spawnPointObjectName
    local level = core_levels.getLevelByName(levelName)
    local spawnPoint = findSpawnPoint(level, spawnPointObjectName)

    M.openLevelConfigurationPopup({
      levelName = levelName,
      spawnPointObjectName = spawnPointObjectName,
      level = level,
      spawnPoint = spawnPoint,
      backendName = "freeroamSelector",
      itemDetails = itemDetails,
    })
  end
end

M.onFreeroamSelectorOpenedWithItemDetails = onFreeroamSelectorOpenedWithItemDetails

return M
