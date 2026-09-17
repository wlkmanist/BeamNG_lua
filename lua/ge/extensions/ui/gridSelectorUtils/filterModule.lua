local M = {}

-- Constructor function
function M.create(createFiltersFunction, commonFilters, rangeFilters, dictFilters, backendName, customPassesFiltersFunction)
  local instance = {}

  -- Default values
  backendName = backendName or "gridSelector"
  commonFilters = commonFilters or {}
  rangeFilters = rangeFilters or {}
  dictFilters = dictFilters or {}
  -- customPassesFiltersFunction is used in the passesFilters function below

  -- Instance variables
  local filterList = {}
  local filterByProp = {}
  local lockedFiltersByProp = {}
  local validFilters = {}
  local searchText = ""
  local filtersDirty = true -- Flag to track if filters need to be recalculated

  local function optionValue(option)
    if type(option) == "table" then
      return option.value or option.id or option.name
    end
    return option
  end

  local commonFiltersLookup = {}
  local function createCommonFiltersLookup(commonFilters)
    -- Create a lookup table for common filters for efficient checking
    for _, commonFilter in ipairs(commonFilters) do
      local propName, option = commonFilter[1], commonFilter[2]
      if not commonFiltersLookup[propName] then
        commonFiltersLookup[propName] = {}
      end
      commonFiltersLookup[propName][optionValue(option)] = true
    end
  end
  createCommonFiltersLookup(commonFilters)

  -- Initialize filters using the provided function
  local function initializeFilters(configList)
    if createFiltersFunction then
      local _filterList, _filterByProp, _commonFilters = createFiltersFunction(configList)
      filtersDirty = true -- Mark filters as dirty after initialization
      filterList = _filterList
      filterByProp = _filterByProp
      if _commonFilters then
        commonFilters = _commonFilters
        createCommonFiltersLookup(commonFilters)
      end
    end
  end

  -- Get search text
  local function getSearchText()
    return searchText
  end

  -- Set search text
  local function setSearchText(val)
    searchText = val or ""
    filtersDirty = true -- Mark filters as dirty when search text changes
  end

  -- Check if a filter option is locked
  local function isFilterLocked(propName, option)
    if not lockedFiltersByProp[propName] then
      return false
    end

    if option then
      -- Check if specific option is locked
      return lockedFiltersByProp[propName][option] ~= nil
    else
      -- Check if any option for this property is locked
      for _, _ in pairs(lockedFiltersByProp[propName]) do
        return true
      end
      return false
    end
  end

  -- Calculate active filters
  local function calculateActiveFilters()
    local activeFilters = {}
    local hasNonCommonFilters = false

    -- Go through filterList to maintain proper ordering
    for _, filterItem in ipairs(filterList) do
      local propName = filterItem.propName
      local filterOptions = filterByProp[propName]

      -- Skip if this property doesn't exist in filterByProp
      if not filterOptions then
        goto continue
      end

      -- Handle different filter types
      if filterItem.type == 'range' then
        -- Range filter: compare min/max values to defaults
        local currentMin = filterOptions.min
        local currentMax = filterOptions.max
        local defaultMin = filterItem.min
        local defaultMax = filterItem.max

        -- Check if current values differ from defaults
        if currentMin > defaultMin or currentMax < defaultMax then
          local displayText, propValue

          if currentMin > defaultMin and currentMax < defaultMax then
            displayText = string.format("%s %s - %s", propName, currentMin, currentMax)
            propValue = string.format("%s,%s", currentMin, currentMax)
          elseif currentMin > defaultMin then
            displayText = string.format("%s > %s", propName, currentMin)
            propValue = string.format("> %s", currentMin)
          else
            displayText = string.format("%s < %s", propName, currentMax)
            propValue = string.format("< %s", currentMax)
          end

          table.insert(activeFilters, {
            propName = propName,
            propValue = propValue,
            displayText = displayText,
            isActive = true,
            iconType = 'checkmark',
            type = 'range'
          })

          -- Range filters are not common filters
          hasNonCommonFilters = true
        end
      else
        -- Set filter: use existing logic for option-based filters
        if type(filterOptions) ~= 'table' or filterOptions == nil then
          goto continue
        end

        -- Get all options for this property, maintaining order from filterList
        local allOptions = {}
        if filterItem.options then
          -- Use the order from filterList if available
          for _, option in ipairs(filterItem.options) do
            local optionName = optionValue(option)
            if filterOptions[optionName] ~= nil then
              table.insert(allOptions, {value = optionName, label = type(option) == "table" and (option.label or optionName) or optionName})
            end
          end
        else
          -- Fallback to iterating through keys if no options structure in filterList
          for key, _ in pairs(filterOptions) do
            if key ~= 'min' and key ~= 'max' then
              table.insert(allOptions, {value = key, label = key})
            end
          end
        end

        local enabledOptions = {}
        local disabledOptions = {}

        for _, option in ipairs(allOptions) do
          if filterOptions[option.value] == true then
            table.insert(enabledOptions, option)
          elseif filterOptions[option.value] == false then
            table.insert(disabledOptions, option)
          end
        end

        -- Skip if all options are enabled (no filtering)
        if #enabledOptions == #allOptions then
          goto continue
        end

        -- Handle case where no options are enabled (all disabled)
        if #enabledOptions == 0 then
          table.insert(activeFilters, {
            propName = propName,
            propValue = 'all',
            displayText = string.format("%s: None!", propName),
            isActive = false,
            iconType = 'xmark',
            type = 'set'
          })
          goto continue
        end

        -- Create only one entry per property
        if #enabledOptions > 0 or #disabledOptions > 0 then
          local displayText, propValue, isActive, iconType
          local function optionLabels(options)
            local labels = {}
            for _, option in ipairs(options) do
              table.insert(labels, option.label)
            end
            return labels
          end

          -- If more elements are enabled than disabled, show the disabled names in red
          if #enabledOptions > #disabledOptions then
            local labels = optionLabels(disabledOptions)
            displayText = string.format("%s %s", propName, table.concat(labels, ", "))
            propValue = table.concat(labels, ",")
            isActive = false
            iconType = 'abandon'
          else
            -- If more elements are disabled than enabled, show the enabled names in green
            local labels = optionLabels(enabledOptions)
            displayText = string.format("%s %s", propName, table.concat(labels, ", "))
            propValue = table.concat(labels, ",")
            isActive = true
            iconType = 'checkmark'
          end

          table.insert(activeFilters, {
            propName = propName,
            propValue = propValue,
            displayText = displayText,
            isActive = isActive,
            iconType = iconType,
            containedOptionCount = math.min(#enabledOptions, #disabledOptions),
            type = 'set'
          })

          -- Check if this filter contains any non-common options
          local hasNonCommonOption = false
          for _, option in ipairs(enabledOptions) do
            if not commonFiltersLookup[propName] or not commonFiltersLookup[propName][option.value] then
              hasNonCommonOption = true
              break
            end
          end
          for _, option in ipairs(disabledOptions) do
            if not commonFiltersLookup[propName] or not commonFiltersLookup[propName][option.value] then
              break
            end
          end

          if hasNonCommonOption then
            hasNonCommonFilters = true
          end
        end
      end

      ::continue::
    end

    return activeFilters, hasNonCommonFilters
  end

  -- Get available filters
  local function getFilters()
    local activeFilters, hasNonCommonFilters = calculateActiveFilters()
    return {
      filterList = filterList,
      filterByProp = filterByProp,
      commonFilters = commonFilters,
      lockedFiltersByProp = lockedFiltersByProp,
      activeFilters = activeFilters,
      onlyCommonFilters = not hasNonCommonFilters
    }
  end

  local function getActiveFilters()
    local activeFilters, _ = calculateActiveFilters()
    return activeFilters
  end

  -- Update active filters
  local function updateFilters(newFilters)
    -- Preserve locked filters when updating
    for propName, lockedOptions in pairs(lockedFiltersByProp) do
      if newFilters[propName] then
        if type(lockedOptions) == 'table' then
          -- For set filters, preserve locked options
          for option, lockedValue in pairs(lockedOptions) do
            if newFilters[propName][option] ~= nil then
              newFilters[propName][option] = lockedValue
            end
          end
        else
          -- For range filters, preserve locked min/max values
          if lockedOptions.min ~= nil then
            newFilters[propName].min = lockedOptions.min
          end
          if lockedOptions.max ~= nil then
            newFilters[propName].max = lockedOptions.max
          end
        end
      end
    end

    filterByProp = newFilters
    filtersDirty = true -- Mark filters as dirty
  end

  -- Toggle filter
  local function toggleFilter(propName, option)
    log("D","",string.format("Toggling filter: %s, option: %s", propName, option))

    -- Check if the filter is locked
    if isFilterLocked(propName, option) then
      log("W","",string.format("Cannot toggle locked filter: %s, option: %s", propName, option))
      return
    end

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter or not filter.options then
      return
    end

    -- Check if all items are currently enabled
    local allEnabled = true
    for _, opt in ipairs(filter.options) do
      if filterByProp[propName][optionValue(opt)] ~= true then
        allEnabled = false
        break
      end
    end

    if allEnabled then
      -- If all items were enabled, enable only the clicked item and disable all others
      for _, opt in ipairs(filter.options) do
        local optValue = optionValue(opt)
        -- Only modify if not locked
        if not isFilterLocked(propName, optValue) then
          filterByProp[propName][optValue] = (optValue == option)
        end
      end
    else
      -- If at least one item was disabled, simply flip the clicked item
      local currentValue = filterByProp[propName][option]
      filterByProp[propName][option] = not currentValue
    end
    -- Check if all items are now false after the toggle
    local allFalse = true
    for _, opt in ipairs(filter.options) do
      if filterByProp[propName][optionValue(opt)] ~= false then
        allFalse = false
        break
      end
    end

    -- If all items are false, set all to true instead
    if allFalse then
      for _, opt in ipairs(filter.options) do
        local optValue = optionValue(opt)
        -- Only modify if not locked
        if not isFilterLocked(propName, optValue) then
          filterByProp[propName][optValue] = true
        end
      end
    end
    filtersDirty = true -- Mark filters as dirty
  end

  -- Update range filter
  local function updateRangeFilter(propName, min, max)
    log("D","",string.format("Updating range filter: %s, min: %s, max: %s", propName, min, max))

    -- Check if the filter is locked
    if isFilterLocked(propName) then
      log("W","",string.format("Cannot update locked range filter: %s", propName))
      return
    end

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter or filter.type ~= 'range' then
      return
    end

    -- Ensure values are within the allowed range
    min = math.max(filter.min, math.min(filter.max, min))
    max = math.max(filter.min, math.min(filter.max, max))

    -- Ensure min <= max
    if min > max then
      min, max = max, min
    end

    -- Update the filter values
    if not filterByProp[propName] then
      filterByProp[propName] = {}
    end
    filterByProp[propName].min = min
    filterByProp[propName].max = max
    filtersDirty = true -- Mark filters as dirty
  end

  -- Reset range filter
  local function resetRangeFilter(propName)
    log("D","",string.format("Resetting range filter: %s", propName))

    -- Check if the filter is locked
    if isFilterLocked(propName) then
      log("W","",string.format("Cannot reset locked range filter: %s", propName))
      return
    end

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter or filter.type ~= 'range' then
      return
    end

    -- Reset to original min/max values
    if not filterByProp[propName] then
      filterByProp[propName] = {}
    end
    filterByProp[propName].min = filter.min
    filterByProp[propName].max = filter.max
    filtersDirty = true -- Mark filters as dirty
  end

  -- Reset set filter
  local function resetSetFilter(propName)
    log("D","",string.format("Resetting set filter: %s", propName))

    -- Check if the filter is locked
    if isFilterLocked(propName) then
      log("W","",string.format("Cannot reset locked set filter: %s", propName))
      return
    end

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter or filter.type ~= 'set' then
      return
    end

    -- Reset all options to true (enabled)
    if not filterByProp[propName] then
      filterByProp[propName] = {}
    end

    for _, option in ipairs(filter.options) do
      option = optionValue(option)
      -- Only reset if not locked
      if not isFilterLocked(propName, option) then
        filterByProp[propName][option] = true
      end
    end
    filtersDirty = true -- Mark filters as dirty
  end

  -- Clear all filters
  local function clearAllFilters()
    for _, filter in ipairs(filterList) do
      if filter.type == 'range' then
        resetRangeFilter(filter.propName)
      end
      if filter.type == 'set' then
        resetSetFilter(filter.propName)
      end
    end
    setSearchText("")
    filtersDirty = true -- Mark filters as dirty
  end

  -- Lock a filter to prevent modification
  local function lockFilter(propName, options)
    log("D","",string.format("Locking filter: %s", propName))

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter then
      return
    end

    -- Initialize locked filters for this property if it doesn't exist
    if not lockedFiltersByProp[propName] then
      lockedFiltersByProp[propName] = {}
    end

    if filter.type == 'range' then
      -- For range filters, lock the current min/max values
      if not filterByProp[propName] then
        filterByProp[propName] = {}
      end
      lockedFiltersByProp[propName].min = filterByProp[propName].min or filter.min
      lockedFiltersByProp[propName].max = filterByProp[propName].max or filter.max
    else
      -- For set filters, lock specific options or all options
      if options then
        -- Lock specific options
        for _, option in ipairs(options) do
          if filterByProp[propName] and filterByProp[propName][option] ~= nil then
            lockedFiltersByProp[propName][option] = filterByProp[propName][option]
          end
        end
      else
        -- Lock all current options
        if filterByProp[propName] then
          for option, value in pairs(filterByProp[propName]) do
            lockedFiltersByProp[propName][option] = value
          end
        end
      end
    end
    filtersDirty = true -- Mark filters as dirty
  end

  -- Unlock a filter to allow modification
  local function unlockFilter(propName, options)
    log("D","",string.format("Unlocking filter: %s", propName))

    if not lockedFiltersByProp[propName] then
      return lockedFiltersByProp
    end

    if options then
      -- Unlock specific options
      for _, option in ipairs(options) do
        lockedFiltersByProp[propName][option] = nil
      end
      -- Remove the property entirely if no options are locked
      local hasLockedOptions = false
      for _, _ in pairs(lockedFiltersByProp[propName]) do
        hasLockedOptions = true
        break
      end
      if not hasLockedOptions then
        lockedFiltersByProp[propName] = nil
      end
    else
      -- Unlock all options for this property
      lockedFiltersByProp[propName] = nil
    end
    filtersDirty = true -- Mark filters as dirty
  end

  -- Lock a filter into a specific mode (set specific options to true/false)
  local function lockFilterMode(propName, options)
    log("D","",string.format("Locking filter mode: %s", propName))

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter then
      return
    end

    -- Initialize locked filters for this property if it doesn't exist
    if not lockedFiltersByProp[propName] then
      lockedFiltersByProp[propName] = {}
    end

    if filter.type == 'range' then
      -- For range filters, lock the specified min/max values
      if not filterByProp[propName] then
        filterByProp[propName] = {}
      end

      if options.min ~= nil then
        filterByProp[propName].min = options.min
        lockedFiltersByProp[propName].min = options.min
      end
      if options.max ~= nil then
        filterByProp[propName].max = options.max
        lockedFiltersByProp[propName].max = options.max
      end
    else
      -- For set filters, set specific options to true/false and lock them
      if not filterByProp[propName] then
        filterByProp[propName] = {}
      end

      -- First, set all options to false (disabled)
      for _, option in ipairs(filter.options) do
        option = optionValue(option)
        filterByProp[propName][option] = false
        lockedFiltersByProp[propName][option] = false
      end

      -- Then, set the specified options to true (enabled)
      if options then
        for option, enabled in pairs(options) do
          if filterByProp[propName][option] ~= nil then
            filterByProp[propName][option] = enabled
            lockedFiltersByProp[propName][option] = enabled
          end
        end
      end
    end
    filtersDirty = true -- Mark filters as dirty
  end

  -- Lock a filter into exclusive mode (set all options to false except specified ones)
  local function lockFilterModeExclusive(propName, allowedOptions)
    log("D","",string.format("Locking filter mode exclusive: %s", propName))

    local filter = nil
    for _, f in ipairs(filterList) do
      if f.propName == propName then
        filter = f
        break
      end
    end

    if not filter then
      return
    end

    -- Only works with set filters
    if filter.type ~= 'set' then
      log("W","",string.format("lockFilterModeExclusive only works with set filters, got: %s", filter.type))
      return
    end

    -- Initialize locked filters for this property if it doesn't exist
    if not lockedFiltersByProp[propName] then
      lockedFiltersByProp[propName] = {}
    end

    if not filterByProp[propName] then
      filterByProp[propName] = {}
    end

    -- Set all options to false (disabled) and lock them
    for _, option in ipairs(filter.options) do
      option = optionValue(option)
      filterByProp[propName][option] = false
      lockedFiltersByProp[propName][option] = false
    end

    -- Then, set only the allowed options to true (enabled) but DON'T lock them
    if allowedOptions then
      for _, option in ipairs(allowedOptions) do
        if filterByProp[propName][option] ~= nil then
          filterByProp[propName][option] = true
          -- Don't lock the allowed options - remove them from locked filters
          lockedFiltersByProp[propName][option] = nil
        end
      end
    end

    filtersDirty = true -- Mark filters as dirty
    return
  end

  -- Clear all locked filters
  local function clearLockedFilters()
    log("D","",string.format("Clearing all locked filters"))
    lockedFiltersByProp = {}
    filtersDirty = true -- Mark filters as dirty
  end

  -- Setup valid filters
  local function setupValidFilters()
    table.clear(validFilters)
    for _, filterData in ipairs(filterList) do
      local propFilter = filterByProp[filterData.propName]
      if filterData.type == 'range' then
        if propFilter.min > filterData.min or propFilter.max < filterData.max then
          -- Include the current filter values in the filter object
          local validFilter = {
            propName = filterData.propName,
            propKey = filterData.propKey,
            type = filterData.type,
            min = filterData.min,
            max = filterData.max,
            options = filterData.options,
            currentMin = propFilter.min,
            currentMax = propFilter.max
          }
          table.insert(validFilters, validFilter)
        end
      else
        for _, option in ipairs(filterData.options) do
          if propFilter[optionValue(option)] == false then
            -- Include the current filter values in the filter object
            local validFilter = {
              propName = filterData.propName,
              propKey = filterData.propKey,
              type = filterData.type,
              min = filterData.min,
              max = filterData.max,
              options = filterData.options,
              currentFilterValues = propFilter
            }
            table.insert(validFilters, validFilter)
            break -- Only add once per property
          end
        end
      end
    end
    filtersDirty = false -- Clear the dirty flag after setup
  end

  -- Get valid filters (cached)
  local function getValidFilters()
    -- Check if filters are dirty and need to be recalculated
    if filtersDirty then
      setupValidFilters()
    end
    return validFilters
  end

  -- Passes filters - use custom function if provided
  local function passesFilters(itemData)
    -- Check if filters are dirty and need to be recalculated
    if filtersDirty then
      setupValidFilters()
    end

    if customPassesFiltersFunction then
      return customPassesFiltersFunction(itemData, validFilters, searchText)
    end
    return true
  end

  -- Export instance methods
  instance.initializeFilters = initializeFilters
  instance.getFilters = getFilters
  instance.getActiveFilters = getActiveFilters
  instance.updateFilters = updateFilters
  instance.toggleFilter = toggleFilter
  instance.updateRangeFilter = updateRangeFilter
  instance.resetRangeFilter = resetRangeFilter
  instance.resetSetFilter = resetSetFilter
  instance.clearAllFilters = clearAllFilters
  instance.lockFilter = lockFilter
  instance.unlockFilter = unlockFilter
  instance.isFilterLocked = isFilterLocked
  instance.lockFilterMode = lockFilterMode
  instance.lockFilterModeExclusive = lockFilterModeExclusive
  instance.clearLockedFilters = clearLockedFilters
  instance.calculateActiveFilters = calculateActiveFilters
  instance.setupValidFilters = setupValidFilters
  instance.getValidFilters = getValidFilters
  instance.passesFilters = passesFilters
  instance.getSearchText = getSearchText
  instance.setSearchText = setSearchText

  return instance
end

return M
