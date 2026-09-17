local M = {}

-- Constructor function
function M.create(dataFile, displayDataOptions, updateDisplayDataFunction, backendName, targetVersion)
  local instance = {}

  -- Default values
  dataFile = dataFile or "/settings/gridSelectorData.json"
  displayDataOptions = displayDataOptions or {}
  backendName = backendName or "gridSelector"
  targetVersion = targetVersion or 1

  -- Instance variables
  local favourites = {}
  local recentItems = {}
  local maxRecentItems = 100
  local displayData = nil
  local currentVersion = targetVersion

  -- Use provided display data options
  local finalDisplayDataOptions = displayDataOptions

  local displayOptionKeyToType = {}
  for _, option in ipairs(finalDisplayDataOptions) do
    displayOptionKeyToType[option.key] = option.type
  end

  local displayOptionSettingsKeyByKey = {}
  for _, option in ipairs(finalDisplayDataOptions) do
    if option.settingsKey then
      displayOptionSettingsKeyByKey[option.key] = option.settingsKey
    end
  end

  -- Save all data to file
  local function saveAllData(displayData)
    local data = {
      favourites = favourites,
      recentItems = recentItems,
      version = currentVersion,
      displayData = displayData
    }
    for _, option in ipairs(finalDisplayDataOptions) do
      if option.save then
        data.displayData[option.key] = displayData[option.key]
      end
    end
    jsonWriteFile(dataFile, data, true, nil, true)
  end


  -- Load all data from file
  local function loadAllData()
    local data = jsonReadFile(dataFile) or {}
    data.displayData = data.displayData or {}
    data.version = data.version or 0

    if data then
      if data.version == nil or data.version < currentVersion then
        data.version = 0
        if updateDisplayDataFunction then
          data.displayData = updateDisplayDataFunction(data.displayData, data.version, currentVersion)
        end
      end
      favourites = data.favourites or {}
      recentItems = data.recentItems or {}
      return data.displayData or {}
    end
    return {}
  end

  -- Initialize display data
  local function initializeDisplayData()
    local savedDisplayData = loadAllData()
    local displayData = {}

    -- Copy default values
    for _, option in ipairs(finalDisplayDataOptions) do
      displayData[option.key] = option.default
      if savedDisplayData[option.key] ~= nil then
        displayData[option.key] = savedDisplayData[option.key]
      end
      if option.type == "number" then
        displayData[option.key] = tonumber(displayData[option.key])
      end
      if option.settingsKey then
        displayData[option.key] = settings.getValue(option.settingsKey)
      end
      -- default for aux data depends on shipping status
      if option.key == "showAuxContent" then
        displayData[option.key] = not shipping_build
      end
      -- default for career content depends on shipping status
      if option.key == "showCareerContent" then
        if displayData[option.key] and not shipping_build then
          displayData[option.key] = false
        end
      end
    end

    return displayData
  end

  -- Get display data
  local function getDisplayData()
    if not displayData then
      displayData = initializeDisplayData()
    end
    return displayData
  end

  -- Set display data
  local function setDisplayDataOption(key, value)
    local displayData = getDisplayData()
    local hasChanges = false
    local type = displayOptionKeyToType[key]
    if type == "number" then
      value = tonumber(value)
    end
    if key and value ~= nil and value ~= "undefined" then
      displayData[key] = value
      hasChanges = true
      extensions.hook("onGridSelectorDisplayDataChanged", backendName, key, value)
    end

    local optionKey = displayOptionSettingsKeyByKey[key]
    if optionKey then
      settings.setValue(optionKey, value)
    end

    if hasChanges then
      saveAllData(displayData)
    end

    return displayData
  end

  -- Reset all display data to default values
  local function resetDisplayDataToDefaults()
    local displayData = getDisplayData()
    local hasChanges = false

    -- Reset all options to their default values
    for _, option in ipairs(finalDisplayDataOptions) do
      if option.save then
        local defaultValue = option.default
        if option.key == "showAuxContent" then
          defaultValue = not shipping_build
        end
        if option.type == "number" then
          defaultValue = tonumber(defaultValue)
        end
        if displayData[option.key] ~= defaultValue then
          displayData[option.key] = defaultValue
          hasChanges = true
          extensions.hook("onGridSelectorDisplayDataChanged", backendName, option.key, defaultValue)
        end
      end
    end

    if hasChanges then
      saveAllData(displayData)
    end

    return displayData
  end

  local function clearAllFavourites()
    favourites = {}
    local displayData = getDisplayData()
    saveAllData(displayData)
  end

  local function clearAllRecentItems()
    recentItems = {}
    local displayData = getDisplayData()
    saveAllData(displayData)
  end

  -- Favourite management
  local function toggleFavourite(itemKey)
    if favourites[itemKey] then
      favourites[itemKey] = nil
    else
      favourites[itemKey] = os.time()
    end
    extensions.hook("onGridSelectorFavouriteToggled", backendName, itemKey, favourites[itemKey] ~= nil)
    local displayData = getDisplayData()
    saveAllData(displayData)
  end

  local function isFavourite(itemKey)
    return favourites[itemKey]
  end

  -- Recent items management
  local function isRecentItem(itemKey)
    return arrayFindValueIndex(recentItems, itemKey) or false
  end

  local function trackRecentItem(itemKey)
    local idx = arrayFindValueIndex(recentItems, itemKey)
    if idx then
      table.remove(recentItems, idx)
    end
    table.insert(recentItems, 1, itemKey)
    while #recentItems > maxRecentItems do
      table.remove(recentItems, #recentItems)
    end
    local displayData = getDisplayData()
    saveAllData(displayData)
  end

  -- Get display data options
  local function getDisplayDataOptions()
    local displayData = getDisplayData()
    local data = {}
    for _, option in ipairs(finalDisplayDataOptions) do
      local value = nil
      if option.key == 'searchText' then
        -- This would need to be handled by the calling module
        value = nil
      else
        value = displayData[option.key]
      end
      if option.settingsKey then
        value = settings.getValue(option.settingsKey)
      end
      table.insert(data, {
        label = option.label,
        key = option.key,
        type = option.type,
        min = option.min,
        max = option.max,
        value = value,
        options = option.options,
        showInModes = option.showInModes,
        description = option.description,
        hideInSimpleMenu = option.hideInSimpleMenu,
      })
    end
    return data
  end

  -- Export instance methods
  instance.getDisplayData = getDisplayData
  instance.setDisplayDataOption = setDisplayDataOption
  instance.resetDisplayDataToDefaults = resetDisplayDataToDefaults
  instance.toggleFavourite = toggleFavourite
  instance.isFavourite = isFavourite
  instance.isRecentItem = isRecentItem
  instance.trackRecentItem = trackRecentItem
  instance.initializeDisplayData = initializeDisplayData
  instance.clearAllFavourites = clearAllFavourites
  instance.clearAllRecentItems = clearAllRecentItems
  instance.getDisplayDataOptions = getDisplayDataOptions

  return instance
end

return M
