-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui

-- Module-level configListGenerator (set in C:init)
local configListGenerator

local C = {}

-- Helper function to clean a single filter (remove false values from its values table)
local function cleanFilter(filter)
  if not filter or type(filter) ~= "table" then return nil end

  -- Preserve all filter fields (propName, type, and any other fields)
  local cleaned = deepcopy(filter)

  -- Handle values field based on filter type
  if cleaned.values then
    if type(cleaned.values) ~= "table" then
      -- Invalid values, remove filter
      return nil
    end

    -- Check if this is a range filter (has min/max keys)
    if cleaned.values.min ~= nil or cleaned.values.max ~= nil then
      -- Range filter: preserve min/max if they're valid numbers
      local hasMin = cleaned.values.min ~= nil and type(cleaned.values.min) == "number"
      local hasMax = cleaned.values.max ~= nil and type(cleaned.values.max) == "number"

      if hasMin and hasMax then
        -- Valid range filter with both min and max
        -- Preserve the entire values table (may contain other fields)
        return cleaned
      elseif hasMin or hasMax then
        -- Partial range filter - keep it but ensure both are numbers
        if not hasMin then
          cleaned.values.min = cleaned.values.max or 0
        end
        if not hasMax then
          cleaned.values.max = cleaned.values.min or 0
        end
        return cleaned
      else
        -- Invalid range filter (no valid numbers), remove it
        return nil
      end
    else
      -- Set filter or other filter types: clean boolean values but preserve other data types
      local cleanedValues = {}
      local hasAnyValue = false

      for key, value in pairs(cleaned.values) do
        if value == true then
          -- Keep true boolean values
          cleanedValues[key] = true
          hasAnyValue = true
        elseif type(value) ~= "boolean" then
          -- Preserve non-boolean values (strings, numbers, tables, etc.)
          cleanedValues[key] = value
          hasAnyValue = true
        end
        -- Skip false boolean values (they're filtered out)
      end

      if hasAnyValue then
        cleaned.values = cleanedValues
        return cleaned
      else
        -- No values to keep, remove filter
        return nil
      end
    end
  else
    -- Filter has no values field, but might have other important fields
    -- Keep it if it has propName and type (might be valid)
    if cleaned.propName and cleaned.type then
      return cleaned
    else
      -- Invalid filter structure, remove it
      return nil
    end
  end
end

-- Helper function to clean filter array (remove filters with no true values)
local function cleanFilterArray(filterArray)
  if not filterArray or type(filterArray) ~= "table" then return {} end
  local cleaned = {}
  for _, filter in ipairs(filterArray) do
    local cleanedFilter = cleanFilter(filter)
    if cleanedFilter then
      table.insert(cleaned, cleanedFilter)
    end
  end
  return cleaned
end

-- Helper function to clean base filter
local function cleanBaseFilter(baseFilter)
  if not baseFilter or type(baseFilter) ~= "table" then return {} end
  local cleaned = {}
  if baseFilter.whiteList then
    cleaned.whiteList = cleanFilterArray(baseFilter.whiteList)
  end
  if baseFilter.blackList then
    cleaned.blackList = cleanFilterArray(baseFilter.blackList)
  end
  -- Only return if there's something to save
  if next(cleaned.whiteList) or next(cleaned.blackList) then
    return cleaned
  end
  return {}
end

-- Helper function to clean probability settings
local function cleanProbabilitySettings(probabilitySettings)
  if not probabilitySettings or type(probabilitySettings) ~= "table" then return {} end
  local cleaned = {}
  for _, setting in ipairs(probabilitySettings) do
    local cleanedSetting = deepcopy(setting)
    if cleanedSetting.whiteList then
      cleanedSetting.whiteList = cleanFilterArray(cleanedSetting.whiteList)
    end
    if cleanedSetting.blackList then
      cleanedSetting.blackList = cleanFilterArray(cleanedSetting.blackList)
    end
    -- Only include setting if it has filters or weight > 0
    if (cleanedSetting.whiteList and #cleanedSetting.whiteList > 0) or
       (cleanedSetting.blackList and #cleanedSetting.blackList > 0) or
       (cleanedSetting.weight and cleanedSetting.weight > 0) then
      table.insert(cleaned, cleanedSetting)
    end
  end
  return cleaned
end

-- Helper function to convert configListGenerator vehicleInfo format to our vehicleOptions format
local function convertVehicleInfosToOptions(vehicleInfos)
  local vehicleOptions = {}
  local modelsMap = {}

  for _, vehicleInfo in ipairs(vehicleInfos) do
    local modelKey = vehicleInfo.model_key
    if not modelsMap[modelKey] then
      -- Get model to access paints
      local model = core_vehicles.getModel(modelKey)
      modelsMap[modelKey] = {
        model = modelKey,
        configs = {},
        paints = model and model.model and tableKeys(tableValuesAsLookupDict(model.model.paints or {})) or {}
      }
    end

    table.insert(modelsMap[modelKey].configs, {
      config = vehicleInfo.key,
      name = vehicleInfo.Name,
    })
  end

  -- Convert map to array
  for _, vehicleModel in pairs(modelsMap) do
    if #vehicleModel.configs > 0 then
      table.insert(vehicleOptions, vehicleModel)
    end
  end

  return vehicleOptions
end

-- Convert a single filter to configListGenerator format
-- filterByProp is optional - only used in editor for checking full range/all selected
-- In constructor, filters are already cleaned, so we can skip those checks
local function convertSingleFilterToConfigListFormat(filter, filterByProp)
  if not filter or not filter.propName then return nil end

  local propName = filter.propName
  local whiteList = {}

  if filter.type == 'range' then
    -- Range filter - filters are already cleaned when saved, so just apply them
    if filter.values and filter.values.min and filter.values.max then
      -- If filterByProp is provided, check if it's full range (editor mode)
      -- Otherwise, just apply the filter (constructor mode - already cleaned)
      if filterByProp then
        local filterInfo = filterByProp[propName]
        if filterInfo and filterInfo.min and filterInfo.max then
          -- Only add if it's not the full range
          if filter.values.min > filterInfo.min or filter.values.max < filterInfo.max then
            whiteList[propName] = {min = filter.values.min, max = filter.values.max}
          end
        end
      else
        -- No filterByProp - filters are already cleaned, just apply them
        whiteList[propName] = {min = filter.values.min, max = filter.values.max}
      end
    end
  elseif filter.type == 'set' then
    -- Set filter - convert selected options to array
    if filter.values then
      local selectedOptions = {}
      for option, selected in pairs(filter.values) do
        if selected and option ~= 'Other...' then
          table.insert(selectedOptions, option)
        end
      end
      if #selectedOptions > 0 then
        -- If filterByProp is provided, check if all options are selected (editor mode)
        -- Otherwise, just apply the filter (constructor mode - already cleaned)
        if filterByProp then
          local allSelected = true
          local filterInfo = filterByProp[propName]
          if filterInfo then
            for key, _ in pairs(filterInfo) do
              if key ~= 'Other...' and not filter.values[key] then
                allSelected = false
                break
              end
            end
          end
          if not allSelected then
            whiteList[propName] = selectedOptions
          end
        else
          -- No filterByProp - filters are already cleaned, just apply them
          whiteList[propName] = selectedOptions
        end
      end
    end
  end

  if next(whiteList) then
    return {whiteList = whiteList}
  end
  return nil
end

-- Check if a vehicle passes a filter object (with whiteList and blackList arrays)
-- Each filter object has whiteList and blackList arrays, OR logic within each array
local function doesVehiclePassFilterObject(vehicleInfo, filterObj)
  if not filterObj then return true end

  -- Check whiteList: vehicle must match ANY filter in whiteList array (OR logic)
  if filterObj.whiteList and #filterObj.whiteList > 0 then
    local passesWhiteList = false
    for _, whiteListFilter in ipairs(filterObj.whiteList) do
      if configListGenerator.doesVehiclePassFilter(vehicleInfo, {whiteList = whiteListFilter}) then
        passesWhiteList = true
        break
      end
    end
    if not passesWhiteList then
      return false -- Didn't match any whiteList filter
    end
  end

  -- Check blackList: vehicle must NOT match ANY filter in blackList array (OR logic)
  if filterObj.blackList and #filterObj.blackList > 0 then
    for _, blackListFilter in ipairs(filterObj.blackList) do
      if configListGenerator.doesVehiclePassFilter(vehicleInfo, {whiteList = blackListFilter}) then
        return false -- Matches blackList, so excluded
      end
    end
  end

  return true
end

-- Convert base filter from UI format to filter format
-- Base filter has whiteList and blackList arrays, each containing filter criteria objects
-- filterByProp is optional - only needed in editor for checking full range/all selected
local function convertBaseFilterToConfigListFormat(baseFilter, filterByProp)
  if not baseFilter then
    return {whiteList = {}, blackList = {}}
  end

  local whiteList = {}
  local blackList = {}

  -- baseFilter should have whiteList and blackList arrays of filters
  if baseFilter.whiteList then
    for _, filter in ipairs(baseFilter.whiteList) do
      local configListFilter = convertSingleFilterToConfigListFormat(filter, filterByProp)
      if configListFilter and configListFilter.whiteList then
        -- Add the filter criteria object to whiteList array
        table.insert(whiteList, configListFilter.whiteList)
      end
    end
  end

  if baseFilter.blackList then
    for _, filter in ipairs(baseFilter.blackList) do
      local configListFilter = convertSingleFilterToConfigListFormat(filter, filterByProp)
      if configListFilter and configListFilter.whiteList then
        -- Add the filter criteria object to blackList array
        table.insert(blackList, configListFilter.whiteList)
      end
    end
  end

  return {whiteList = whiteList, blackList = blackList}
end

-- Generate vehicle options from probability settings using configListGenerator
-- Matches dealership structure: base filter + subFilters that inherit and can override
-- Exposed for use in constructor
local function generateVehicleOptionsFromProbabilitySettings(baseFilter, probabilitySettings, filterByProp, maxVehicles, popAttribute, allowAuxiliaryVehicles, allowLoadedTrailers)
  -- Get eligible vehicles (filtered based on settings)
  allowAuxiliaryVehicles = allowAuxiliaryVehicles or false
  allowLoadedTrailers = allowLoadedTrailers or false
  local eligibleVehicles = configListGenerator.getEligibleVehicles(allowAuxiliaryVehicles, allowLoadedTrailers)

  -- Convert base filter from UI format to configListGenerator format
  local baseFilterConverted = convertBaseFilterToConfigListFormat(baseFilter, filterByProp)

  -- If no probability settings, apply base filter if it exists, otherwise return all eligible vehicles
  if not probabilitySettings or #probabilitySettings == 0 then
    if baseFilterConverted and (#baseFilterConverted.whiteList > 0 or #baseFilterConverted.blackList > 0) then
      -- Apply base filter using array-based filtering
      local baseFilterObj = {}
      if #baseFilterConverted.whiteList > 0 then
        baseFilterObj.whiteList = baseFilterConverted.whiteList
      end
      if #baseFilterConverted.blackList > 0 then
        baseFilterObj.blackList = baseFilterConverted.blackList
      end

      local filteredVehicles = {}
      for _, vehicle in ipairs(eligibleVehicles) do
        if doesVehiclePassFilterObject(vehicle, baseFilterObj) then
          table.insert(filteredVehicles, vehicle)
        end
      end
      -- Limit to maxVehicles if specified
      if maxVehicles > 0 and #filteredVehicles > maxVehicles then
        -- Randomly select maxVehicles
        local selected = {}
        local available = deepcopy(filteredVehicles)
        for i = 1, math.min(maxVehicles, #available) do
          local idx = math.random(#available)
          table.insert(selected, available[idx])
          table.remove(available, idx)
        end
        filteredVehicles = selected
      end
      return convertVehicleInfosToOptions(filteredVehicles)
    end
    return convertVehicleInfosToOptions(eligibleVehicles)
  end

  -- Build subFilters (like dealership system)
  -- Each probability setting has whiteList and blackList arrays of filters
  -- Each setting inherits from base filter and can add more filters
  local subFilters = {}
  for _, setting in ipairs(probabilitySettings) do
    -- Convert filters in this setting to whiteList/blackList arrays
    local subFilterWhiteList = {}
    local subFilterBlackList = {}

    -- setting should have whiteList and blackList arrays
    if setting.whiteList then
      for _, filter in ipairs(setting.whiteList) do
        local configListFilter = convertSingleFilterToConfigListFormat(filter, filterByProp)
        if configListFilter and configListFilter.whiteList then
          table.insert(subFilterWhiteList, configListFilter.whiteList)
        end
      end
    end

    if setting.blackList then
      for _, filter in ipairs(setting.blackList) do
        local configListFilter = convertSingleFilterToConfigListFormat(filter, filterByProp)
        if configListFilter and configListFilter.whiteList then
          table.insert(subFilterBlackList, configListFilter.whiteList)
        end
      end
    end

    -- Create subFilter structure (will be merged with base filter)
    -- Even if empty, this subFilter will inherit the base filter
    local subFilter = {}
    if #subFilterWhiteList > 0 then
      subFilter.whiteList = subFilterWhiteList
    end
    if #subFilterBlackList > 0 then
      subFilter.blackList = subFilterBlackList
    end

    -- Always add the subFilter, even if empty (it will inherit from base filter)
    table.insert(subFilters, {
      filter = subFilter,
      probability = setting.weight or 1.0
    })
  end

  -- If no subFilters were created (no probability settings), apply base filter only if it exists
  if #subFilters == 0 then
    if baseFilterConverted and (#baseFilterConverted.whiteList > 0 or #baseFilterConverted.blackList > 0) then
      -- Apply base filter using array-based filtering
      local baseFilterObj = {}
      if #baseFilterConverted.whiteList > 0 then
        baseFilterObj.whiteList = baseFilterConverted.whiteList
      end
      if #baseFilterConverted.blackList > 0 then
        baseFilterObj.blackList = baseFilterConverted.blackList
      end

      local filteredVehicles = {}
      for _, vehicle in ipairs(eligibleVehicles) do
        if doesVehiclePassFilterObject(vehicle, baseFilterObj) then
          table.insert(filteredVehicles, vehicle)
        end
      end
      -- Limit to maxVehicles if specified
      if maxVehicles > 0 and #filteredVehicles > maxVehicles then
        local selected = {}
        local available = deepcopy(filteredVehicles)
        for i = 1, math.min(maxVehicles, #available) do
          local idx = math.random(#available)
          table.insert(selected, available[idx])
          table.remove(available, idx)
        end
        filteredVehicles = selected
      end
      return convertVehicleInfosToOptions(filteredVehicles)
    end
    return convertVehicleInfosToOptions(eligibleVehicles)
  end

  -- Determine number of vehicles to select
  local numberOfVehicles = maxVehicles or 0
  if numberOfVehicles <= 0 then
    numberOfVehicles = 10000 -- Large number to get all matching
  end

  -- Calculate total weight to distribute vehicles proportionally
  local totalWeight = 0
  for _, subFilter in ipairs(subFilters) do
    totalWeight = totalWeight + (subFilter.probability or 1.0)
  end

  -- If no total weight, return all vehicles
  if totalWeight <= 0 then
    return convertVehicleInfosToOptions(eligibleVehicles)
  end

  -- Collect vehicles from each subFilter proportionally based on weights
  -- Each subFilter is merged with base filter (like dealership system)
  local allRandomVehicles = {}
  local vehiclesSelected = 0

  for i, subFilterData in ipairs(subFilters) do
    local weight = subFilterData.probability or 1.0
    local proportion = weight / totalWeight

    -- Calculate how many vehicles this subFilter should contribute
    local vehiclesForThisSubFilter = 0
    if i == #subFilters then
      -- Last subFilter gets the remainder to ensure we get exactly numberOfVehicles
      vehiclesForThisSubFilter = numberOfVehicles - vehiclesSelected
    else
      vehiclesForThisSubFilter = math.floor(numberOfVehicles * proportion + 0.5) -- Round to nearest
    end

    -- Ensure we don't exceed the total
    vehiclesForThisSubFilter = math.min(vehiclesForThisSubFilter, numberOfVehicles - vehiclesSelected)

    if vehiclesForThisSubFilter > 0 then
      -- Merge base filter arrays with subFilter arrays (combine arrays, not merge objects)
      -- Base filter is inherited, subFilter filters are added to the arrays (OR logic)
      local mergedWhiteList = {}
      local mergedBlackList = {}

      -- Add base filter filters first
      if baseFilterConverted.whiteList then
        for _, filterObj in ipairs(baseFilterConverted.whiteList) do
          table.insert(mergedWhiteList, filterObj)
        end
      end
      if baseFilterConverted.blackList then
        for _, filterObj in ipairs(baseFilterConverted.blackList) do
          table.insert(mergedBlackList, filterObj)
        end
      end

      -- Add subFilter filters (they extend the base filter, OR logic)
      if subFilterData.filter.whiteList then
        for _, filterObj in ipairs(subFilterData.filter.whiteList) do
          table.insert(mergedWhiteList, filterObj)
        end
      end
      if subFilterData.filter.blackList then
        for _, filterObj in ipairs(subFilterData.filter.blackList) do
          table.insert(mergedBlackList, filterObj)
        end
      end

      -- Filter vehicles using merged arrays (OR logic between all filters)
      -- Create a filter object with the merged arrays
      local mergedFilterObj = {}
      if #mergedWhiteList > 0 then
        mergedFilterObj.whiteList = mergedWhiteList
      end
      if #mergedBlackList > 0 then
        mergedFilterObj.blackList = mergedBlackList
      end

      -- Filter using the merged filter object
      local filteredVehicles = {}
      for _, vehicle in ipairs(eligibleVehicles) do
        if doesVehiclePassFilterObject(vehicle, mergedFilterObj) then
          table.insert(filteredVehicles, vehicle)
        end
      end

      -- Randomly select vehicles from filtered list based on weight and population attribute
      local selectedVehicles = {}
      if #filteredVehicles > 0 then
        local available = deepcopy(filteredVehicles)
        local toSelect = math.min(vehiclesForThisSubFilter, #available)

        for i = 1, toSelect do
          if #available == 0 then break end

          -- Weight by population attribute if available
          local totalPop = 0
          for _, veh in ipairs(available) do
            totalPop = totalPop + (veh[popAttribute] or 1)
          end

          if totalPop > 0 then
            -- Use math.random() * totalPop for float values
            local chosenPop = math.random() * totalPop
            local popCounter = 0
            for idx, veh in ipairs(available) do
              popCounter = popCounter + (veh[popAttribute] or 1)
              if popCounter >= chosenPop then
                table.insert(selectedVehicles, veh)
                table.remove(available, idx)
                break
              end
            end
          else
            -- No population data, random selection
            local idx = math.random(#available)
            table.insert(selectedVehicles, available[idx])
            table.remove(available, idx)
          end
        end
      end

      -- Add to the combined list
      for _, vehicle in ipairs(selectedVehicles) do
        table.insert(allRandomVehicles, vehicle)
      end

      vehiclesSelected = vehiclesSelected + vehiclesForThisSubFilter
    end
  end

  return convertVehicleInfosToOptions(allRandomVehicles)
end

function C:init(element)
  self.element = element
  -- Ensure configListGenerator is available (required dependency)
  if not configListGenerator then
    local success, result = pcall(function()
      return require('/lua/ge/extensions/util/configListGenerator')
    end)
    if success and result then
      configListGenerator = result
    else
      error('Failed to load configListGenerator in vehicleFilterUtil: ' .. tostring(result))
    end
  end
  self.configListGenerator = configListGenerator
end

function C:initialize()
  local e = self.element
  if e.initialized then return end

  local filtersWhiteList = {
    "Drivetrain", "Config Type", "Body Style", "Transmission", "Weight", "Top Speed",
    "0-100 km/h", "0-60 mph", "Power", "Torque", "Weight/Power", "Years", "Value",
    "Brand", "Country", "Region", "Source", "Type", "Derby Class", "Performance Class",
    "Off-Road Score", 'Propulsion', 'Fuel Type', 'Induction Type', 'Commercial Class'
  }

  local rangeFilters = tableValuesAsLookupDict({
    "Value", "Weight", "Top Speed", "0-100 km/h", "0-60 mph", "Power", "Torque",
    "Weight/Power", "Off-Road Score", "Years",
  })

  local modelList, configList = {}, {}
  for modelName, _ in pairs(core_vehicles.getModelsData()) do
    table.insert(modelList, core_vehicles.getModel(modelName).model)
    for _, config in pairs(core_vehicles.getModel(modelName).configs or {}) do
      table.insert(configList, config)
    end
  end

  local filterByProp = {}

  -- Helper function to process a property value
  local function processPropertyValue(propName, propVal)
    if propVal == nil then return end

    if rangeFilters[propName] then
      local min, max = propVal, propVal
      if type(propVal) == 'table' then
        min = propVal.min
        max = propVal.max
      end
      if type(min) == 'number' and type(max) == 'number' then
        if not filterByProp[propName] then
          filterByProp[propName] = {min = min, max = max}
        end
        filterByProp[propName].min = math.min(min, filterByProp[propName].min)
        filterByProp[propName].max = math.max(max, filterByProp[propName].max)
      end
    else
      if not filterByProp[propName] then
        filterByProp[propName] = {}
      end
      if propName == "Region" then
        local values = propVal
        if type(values) == 'string' then
          values = {values}
        end
        for _, value in pairs(values) do
          filterByProp[propName][value] = true
        end
      elseif propVal ~= 'Powerglow' then
        filterByProp[propName][propVal] = true
      end
    end
  end

  -- Scan models first (for model-level properties like Country, Brand, Body Style, etc.)
  for _, model in ipairs(modelList) do
    for _, propName in pairs(filtersWhiteList) do
      local propVal = model[propName]
      processPropertyValue(propName, propVal)
    end
  end

  -- Then scan configs (for config-level properties like Drivetrain, Config Type, etc.)
  for _, config in pairs(configList) do
    for _, propName in pairs(filtersWhiteList) do
      local propVal = config[propName]
      processPropertyValue(propName, propVal)
    end
  end

  -- Special handling for Source filter (Mod/Official) - not populated from vehicle data
  if not filterByProp["Source"] then
    filterByProp["Source"] = {}
    filterByProp["Source"]["Mod"] = true
    filterByProp["Source"]["Official"] = true
  end

  local filterUiData = {}
  for _, propName in pairs(filtersWhiteList) do
    if filterByProp[propName] then
      local filterData = {
        propName = propName,
        options = {}
      }
      if filterByProp[propName].min and filterByProp[propName].max then
        filterData.type = 'range'
        filterData.min = filterByProp[propName].min
        filterData.max = filterByProp[propName].max
      else
        filterData.type = 'set'
        -- Special handling for Source filter
        if propName == "Source" then
          table.insert(filterData.options, "Mod")
          table.insert(filterData.options, "Official")
        else
          for _, key in ipairs(tableKeysSorted(filterByProp[propName])) do
            table.insert(filterData.options, key)
          end
          table.insert(filterData.options, 'Other...')
          filterByProp[propName]['Other...'] = true
        end
      end
      table.insert(filterUiData, filterData)
    end
  end

  e.filterByProp = filterByProp
  e.filterUiData = filterUiData

  -- Initialize base filter if empty (has whiteList and blackList arrays)
  if not e.baseFilter then
    e.baseFilter = {whiteList = {}, blackList = {}}
  end
  if not e.baseFilter.whiteList then
    e.baseFilter.whiteList = {}
  end
  if not e.baseFilter.blackList then
    e.baseFilter.blackList = {}
  end

  -- Initialize probability settings if empty (no settings = all configs selected)
  if not e.probabilitySettings then
    e.probabilitySettings = {}
  end

  -- Generate initial vehicle options (all configs if no probability settings)
  e.cachedVehicleOptions = generateVehicleOptionsFromProbabilitySettings(
    e.baseFilter,
    e.probabilitySettings,
    e.filterByProp,
    e.maxVehicles,
    e.popAttribute,
    e.allowAuxiliaryVehicles,
    e.allowLoadedTrailers
  )

  e.initialized = true
end

function C:setContainer(ctd, container)
  local e = self.element
  -- Restore filter configuration from missionTypeData (stored in vehicleFilters)
  local filterData = ctd[e.fieldName]
  -- Check if it's the old format (array of vehicle configs) or new format (filter settings object)
  if filterData and type(filterData) == "table" then
    -- Check if it's old format (array with model/config entries) or new format (object with baseFilter, etc.)
    local isOldFormat = false
    if #filterData > 0 then
      -- Check if first element looks like a vehicle config
      local first = filterData[1]
      if first and (first.model or first.config) then
        isOldFormat = true
      end
    end

    if isOldFormat then
      -- Old format detected - clear it, filter settings will be empty
      filterData = nil
    end
    -- If new format, filterData already contains the settings
  else
    filterData = nil
  end

  if filterData and (filterData.baseFilter or filterData.probabilitySettings) then
    -- Use deepcopy only for complex nested structures that need isolation
    e.manualAdditions = filterData.manualAdditions and deepcopy(filterData.manualAdditions) or {}
    e.manualRemovals = filterData.manualRemovals and deepcopy(filterData.manualRemovals) or {}
    e.baseFilter = filterData.baseFilter and deepcopy(filterData.baseFilter) or {}
    e.probabilitySettings = filterData.probabilitySettings and deepcopy(filterData.probabilitySettings) or {}
    e.maxVehicles = filterData.maxVehicles or 0
    e.popAttribute = filterData.popAttribute or "Population"
    e.allowAuxiliaryVehicles = filterData.allowAuxiliaryVehicles or false
    e.allowLoadedTrailers = filterData.allowLoadedTrailers or false
  else
    -- Initialize defaults (no legacy support needed)
    e.manualAdditions = {}
    e.manualRemovals = {}
    e.baseFilter = {}
    e.probabilitySettings = {}
    e.maxVehicles = 0
    e.popAttribute = "Population"
    e.allowAuxiliaryVehicles = false
    e.allowLoadedTrailers = false
  end

  -- Clear cached vehicle options so they regenerate with the loaded filter settings
  e.cachedVehicleOptions = nil
  -- Clear all caches when loading new data
  e._cachedVehicleList = nil
  e._cachedVehicleByModelKey = nil
  e._cachedFinalConfigs = nil
  e._cachedRemovalsNested = nil
  e._cachedRemovalsCount = 0
  e._cachedAdditionsCount = 0
end

function C:draw(ctd, container, labelFn)
  local e = self.element
  labelFn(e)
  self:initialize()

  local ret = false
  local probChanged = false

  -- Initialize manual additions/removals if needed
  if not e.manualAdditions then e.manualAdditions = {} end
  if not e.manualRemovals then e.manualRemovals = {} end
  if not e.baseFilter then e.baseFilter = {} end
  if not e.probabilitySettings then e.probabilitySettings = {} end

  -- Vehicle eligibility settings
  im.Separator()
  im.Text("Vehicle Eligibility:")
  local auxVehPtr = im.BoolPtr(e.allowAuxiliaryVehicles)
  if im.Checkbox("Allow Auxiliary Vehicles##"..e._id.."allowAux", auxVehPtr) then
    e.allowAuxiliaryVehicles = auxVehPtr[0]
    -- Filter config saved to additionalAttributes, not ctd
    probChanged = true
    ret = true
  end
  im.SameLine()
  local trailerPtr = im.BoolPtr(e.allowLoadedTrailers)
  if im.Checkbox("Allow Loaded Trailers##"..e._id.."allowTrailers", trailerPtr) then
    e.allowLoadedTrailers = trailerPtr[0]
    -- Filter config saved to additionalAttributes, not ctd
    probChanged = true
    ret = true
  end

  -- Base Filter (inherited by all probability settings, like dealership filter)
  im.Separator()
  im.Text("Base Filter (applies to all probability settings):")
  if not e.baseFilter then e.baseFilter = {whiteList = {}, blackList = {}} end
  if not e.baseFilter.whiteList then e.baseFilter.whiteList = {} end
  if not e.baseFilter.blackList then e.baseFilter.blackList = {} end

  -- Base Filter WhiteList
  im.Text("  WhiteList:")
  for filterIdx, filter in ipairs(e.baseFilter.whiteList) do
    im.PushID1("baseFilter"..filterIdx..e._id)

    -- Find filter UI data
    local filterUiInfo = nil
    for _, uiInfo in ipairs(e.filterUiData) do
      if uiInfo.propName == filter.propName then
        filterUiInfo = uiInfo
        break
      end
    end

    if filterUiInfo then
      -- Configure filter inline
      im.Text("  " .. filter.propName .. ":")

      if filterUiInfo.type == 'range' then
        -- Range filter
        if not filter.values then
          filter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
        end
        im.SameLine()
        im.PushItemWidth(80)
        local minPtr = im.FloatPtr(filter.values.min)
        local maxPtr = im.FloatPtr(filter.values.max)
        local minChanged = im.InputFloat("Min##min", minPtr)
        im.SameLine()
        local maxChanged = im.InputFloat("Max##max", maxPtr)
        im.PopItemWidth()
        if minChanged or maxChanged then
          filter.values.min = math.max(filterUiInfo.min, math.min(filterUiInfo.max, minPtr[0]))
          filter.values.max = math.min(filterUiInfo.max, math.max(filterUiInfo.min, maxPtr[0]))
          -- Filter config saved to additionalAttributes, not ctd
          probChanged = true
          ret = true
        end
      else
        -- Set filter
        if not filter.values then
          filter.values = {}
          for _, option in ipairs(filterUiInfo.options) do
            filter.values[option] = false
          end
        end

        -- Show selected count
        local selectedCount = 0
        for _, selected in pairs(filter.values) do
          if selected then selectedCount = selectedCount + 1 end
        end
        local displayText = selectedCount > 0 and (selectedCount .. " selected") or "None selected"
        im.SameLine()
        if im.BeginCombo("##combo", displayText) then
          for _, option in ipairs(filterUiInfo.options) do
            local selected = filter.values[option] or false
            local selectedPtr = im.BoolPtr(selected)
            if im.Checkbox(option.."##option", selectedPtr) then
              filter.values[option] = selectedPtr[0]
              -- Filter config saved to additionalAttributes, not ctd
              probChanged = true
              ret = true
            end
          end
          im.EndCombo()
        end
      end
    else
      im.Text("  - " .. (filter.propName or "Unknown"))
    end

    im.SameLine()
    if im.SmallButton("Remove##removeFilter") then
      table.remove(e.baseFilter.whiteList, filterIdx)
      -- Filter config saved to additionalAttributes, not ctd
      probChanged = true
      ret = true
      im.PopID()
      break
    end

    im.PopID()
  end

  -- Add filter button for base filter whiteList
  im.Text("    ")
  im.SameLine()
  if im.BeginCombo("+ Add to WhiteList##addBaseWhiteList"..e._id, "Add Filter...") then
    for _, filterUiInfo in ipairs(e.filterUiData) do
      if im.Selectable1(filterUiInfo.propName) then
        local newFilter = {
          propName = filterUiInfo.propName,
          type = filterUiInfo.type,
          values = {}
        }

        if filterUiInfo.type == 'range' then
          newFilter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
        else
          for _, option in ipairs(filterUiInfo.options) do
            newFilter.values[option] = false
          end
        end

        table.insert(e.baseFilter.whiteList, newFilter)
        -- Filter config saved to additionalAttributes, not ctd
        probChanged = true
        ret = true
        im.EndCombo()
        break
      end
    end
    im.EndCombo()
  end

  -- Base Filter BlackList
  im.Text("  BlackList:")
  for filterIdx, filter in ipairs(e.baseFilter.blackList) do
    im.PushID1("baseBlackFilter"..filterIdx..e._id)

    -- Find filter UI data
    local filterUiInfo = nil
    for _, uiInfo in ipairs(e.filterUiData) do
      if uiInfo.propName == filter.propName then
        filterUiInfo = uiInfo
        break
      end
    end

    if filterUiInfo then
      -- Configure filter inline
      im.Text("    " .. filter.propName .. ":")

      if filterUiInfo.type == 'range' then
        -- Range filter
        if not filter.values then
          filter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
        end
        im.SameLine()
        im.PushItemWidth(80)
        local minPtr = im.FloatPtr(filter.values.min)
        local maxPtr = im.FloatPtr(filter.values.max)
        local minChanged = im.InputFloat("Min##min", minPtr)
        im.SameLine()
        local maxChanged = im.InputFloat("Max##max", maxPtr)
        im.PopItemWidth()
        if minChanged or maxChanged then
          filter.values.min = math.max(filterUiInfo.min, math.min(filterUiInfo.max, minPtr[0]))
          filter.values.max = math.min(filterUiInfo.max, math.max(filterUiInfo.min, maxPtr[0]))
          -- Filter config saved to additionalAttributes, not ctd
          probChanged = true
          ret = true
        end
      else
        -- Set filter
        if not filter.values then
          filter.values = {}
          for _, option in ipairs(filterUiInfo.options) do
            filter.values[option] = false
          end
        end

        -- Show selected count
        local selectedCount = 0
        for _, selected in pairs(filter.values) do
          if selected then selectedCount = selectedCount + 1 end
        end
        local displayText = selectedCount > 0 and (selectedCount .. " selected") or "None selected"
        im.SameLine()
        if im.BeginCombo("##combo", displayText) then
          for _, option in ipairs(filterUiInfo.options) do
            local selected = filter.values[option] or false
            local selectedPtr = im.BoolPtr(selected)
            if im.Checkbox(option.."##option", selectedPtr) then
              filter.values[option] = selectedPtr[0]
              -- Filter config saved to additionalAttributes, not ctd
              probChanged = true
              ret = true
            end
          end
          im.EndCombo()
        end
      end
    else
      im.Text("    - " .. (filter.propName or "Unknown"))
    end

    im.SameLine()
    if im.SmallButton("Remove##removeFilter") then
      table.remove(e.baseFilter.blackList, filterIdx)
      -- Filter config saved to additionalAttributes, not ctd
      probChanged = true
      ret = true
      im.PopID()
      break
    end

    im.PopID()
  end

  -- Add filter button for base filter blackList
  im.Text("    ")
  im.SameLine()
  if im.BeginCombo("+ Add to BlackList##addBaseBlackList"..e._id, "Add Filter...") then
    for _, filterUiInfo in ipairs(e.filterUiData) do
      if im.Selectable1(filterUiInfo.propName) then
        local newFilter = {
          propName = filterUiInfo.propName,
          type = filterUiInfo.type,
          values = {}
        }

        if filterUiInfo.type == 'range' then
          newFilter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
        else
          for _, option in ipairs(filterUiInfo.options) do
            newFilter.values[option] = false
          end
        end

        table.insert(e.baseFilter.blackList, newFilter)
        -- Filter config saved to additionalAttributes, not ctd
        probChanged = true
        ret = true
        im.EndCombo()
        break
      end
    end
    im.EndCombo()
  end

  -- Probability Settings List
  im.Separator()
  im.Text("Probability Settings:")
  if im.Button("+ Add Probability Setting##"..e._id.."addSetting") then
    table.insert(e.probabilitySettings, {
      weight = 1.0,
      whiteList = {},
      blackList = {}
    })
    -- Filter config saved to additionalAttributes, not ctd
    probChanged = true
    ret = true
  end

  -- Display each probability setting
  for settingIdx, setting in ipairs(e.probabilitySettings) do
    im.Separator()
    im.PushID1("setting"..settingIdx..e._id)

    -- Setting header with weight and remove button
    im.Text("Setting " .. settingIdx .. ":")
    im.SameLine()
    im.PushItemWidth(100)
    local weightPtr = im.FloatPtr(setting.weight or 1.0)
    if im.InputFloat("Weight##weight", weightPtr, 0.1, 1.0, "%.2f") then
      setting.weight = math.max(0.1, weightPtr[0])
      -- Filter config saved to additionalAttributes, not ctd
      probChanged = true
      ret = true
    end
    im.PopItemWidth()
    im.SameLine()
    if im.SmallButton("Remove##removeSetting") then
      table.remove(e.probabilitySettings, settingIdx)
      -- Filter config saved to additionalAttributes, not ctd
      probChanged = true
      ret = true
      im.PopID()
      break
    end

    -- Initialize whiteList and blackList if needed
    if not setting.whiteList then setting.whiteList = {} end
    if not setting.blackList then setting.blackList = {} end

    -- WhiteList filters in this setting
    im.Text("  WhiteList:")
    for filterIdx, filter in ipairs(setting.whiteList) do
      im.PushID1("filter"..filterIdx)

      -- Find filter UI data
      local filterUiInfo = nil
      for _, uiInfo in ipairs(e.filterUiData) do
        if uiInfo.propName == filter.propName then
          filterUiInfo = uiInfo
          break
        end
      end

      if filterUiInfo then
        -- Configure filter inline
        im.Text("    " .. filter.propName .. ":")

        if filterUiInfo.type == 'range' then
          -- Range filter
          if not filter.values then
            filter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
          end
          im.SameLine()
          im.PushItemWidth(80)
          local minPtr = im.FloatPtr(filter.values.min)
          local maxPtr = im.FloatPtr(filter.values.max)
          local minChanged = im.InputFloat("Min##min", minPtr)
          im.SameLine()
          local maxChanged = im.InputFloat("Max##max", maxPtr)
          im.PopItemWidth()
          if minChanged or maxChanged then
            filter.values.min = math.max(filterUiInfo.min, math.min(filterUiInfo.max, minPtr[0]))
            filter.values.max = math.min(filterUiInfo.max, math.max(filterUiInfo.min, maxPtr[0]))
            -- Filter config saved to additionalAttributes, not ctd
            probChanged = true
            ret = true
          end
        else
          -- Set filter
          if not filter.values then
            filter.values = {}
            for _, option in ipairs(filterUiInfo.options) do
              filter.values[option] = false
            end
          end

          -- Show selected count
          local selectedCount = 0
          for _, selected in pairs(filter.values) do
            if selected then selectedCount = selectedCount + 1 end
          end
          local displayText = selectedCount > 0 and (selectedCount .. " selected") or "None selected"
          im.SameLine()
          if im.BeginCombo("##combo", displayText) then
            for _, option in ipairs(filterUiInfo.options) do
              local selected = filter.values[option] or false
              local selectedPtr = im.BoolPtr(selected)
              if im.Checkbox(option.."##option", selectedPtr) then
                filter.values[option] = selectedPtr[0]
                -- Filter config saved to additionalAttributes, not ctd
                probChanged = true
                ret = true
              end
            end
            im.EndCombo()
          end
        end
      else
        im.Text("    - " .. (filter.propName or "Unknown"))
      end

      im.SameLine()
      if im.SmallButton("Remove##removeFilter") then
        table.remove(setting.whiteList, filterIdx)
        -- Filter config saved to additionalAttributes, not ctd
        probChanged = true
        ret = true
        im.PopID()
        break
      end

      im.PopID()
    end

    -- Add filter button for whiteList
    im.Text("    ")
    im.SameLine()
    if im.BeginCombo("+ Add to WhiteList##addWhiteList"..settingIdx, "Add Filter...") then
      for _, filterUiInfo in ipairs(e.filterUiData) do
        if im.Selectable1(filterUiInfo.propName) then
          local newFilter = {
            propName = filterUiInfo.propName,
            type = filterUiInfo.type,
            values = {}
          }

          if filterUiInfo.type == 'range' then
            newFilter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
          else
            for _, option in ipairs(filterUiInfo.options) do
              newFilter.values[option] = false
            end
          end

          table.insert(setting.whiteList, newFilter)
          -- Filter config saved to additionalAttributes, not ctd
          probChanged = true
          ret = true
          im.EndCombo()
          break
        end
      end
      im.EndCombo()
    end

    -- BlackList filters in this setting
    im.Text("  BlackList:")
    for filterIdx, filter in ipairs(setting.blackList) do
      im.PushID1("blackFilter"..filterIdx)

      -- Find filter UI data
      local filterUiInfo = nil
      for _, uiInfo in ipairs(e.filterUiData) do
        if uiInfo.propName == filter.propName then
          filterUiInfo = uiInfo
          break
        end
      end

      if filterUiInfo then
        -- Configure filter inline
        im.Text("    " .. filter.propName .. ":")

        if filterUiInfo.type == 'range' then
          -- Range filter
          if not filter.values then
            filter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
          end
          im.SameLine()
          im.PushItemWidth(80)
          local minPtr = im.FloatPtr(filter.values.min)
          local maxPtr = im.FloatPtr(filter.values.max)
          local minChanged = im.InputFloat("Min##min", minPtr)
          im.SameLine()
          local maxChanged = im.InputFloat("Max##max", maxPtr)
          im.PopItemWidth()
          if minChanged or maxChanged then
            filter.values.min = math.max(filterUiInfo.min, math.min(filterUiInfo.max, minPtr[0]))
            filter.values.max = math.min(filterUiInfo.max, math.max(filterUiInfo.min, maxPtr[0]))
            -- Filter config saved to additionalAttributes, not ctd
            probChanged = true
            ret = true
          end
        else
          -- Set filter
          if not filter.values then
            filter.values = {}
            for _, option in ipairs(filterUiInfo.options) do
              filter.values[option] = false
            end
          end

          -- Show selected count
          local selectedCount = 0
          for _, selected in pairs(filter.values) do
            if selected then selectedCount = selectedCount + 1 end
          end
          local displayText = selectedCount > 0 and (selectedCount .. " selected") or "None selected"
          im.SameLine()
          if im.BeginCombo("##combo", displayText) then
            for _, option in ipairs(filterUiInfo.options) do
              local selected = filter.values[option] or false
              local selectedPtr = im.BoolPtr(selected)
              if im.Checkbox(option.."##option", selectedPtr) then
                filter.values[option] = selectedPtr[0]
                -- Filter config saved to additionalAttributes, not ctd
                probChanged = true
                ret = true
              end
            end
            im.EndCombo()
          end
        end
      else
        im.Text("    - " .. (filter.propName or "Unknown"))
      end

      im.SameLine()
      if im.SmallButton("Remove##removeFilter") then
        table.remove(setting.blackList, filterIdx)
        -- Filter config saved to additionalAttributes, not ctd
        probChanged = true
        ret = true
        im.PopID()
        break
      end

      im.PopID()
    end

    -- Add filter button for blackList
    im.Text("    ")
    im.SameLine()
    if im.BeginCombo("+ Add to BlackList##addBlackList"..settingIdx, "Add Filter...") then
      for _, filterUiInfo in ipairs(e.filterUiData) do
        if im.Selectable1(filterUiInfo.propName) then
          local newFilter = {
            propName = filterUiInfo.propName,
            type = filterUiInfo.type,
            values = {}
          }

          if filterUiInfo.type == 'range' then
            newFilter.values = {min = filterUiInfo.min, max = filterUiInfo.max}
          else
            for _, option in ipairs(filterUiInfo.options) do
              newFilter.values[option] = false
            end
          end

          table.insert(setting.blackList, newFilter)
          -- Filter config saved to additionalAttributes, not ctd
          probChanged = true
          ret = true
          im.EndCombo()
          break
        end
      end
      im.EndCombo()
    end

    im.PopID()
  end

  -- Global settings
  im.Separator()
  im.Text("Global Settings:")
  im.PushItemWidth(150)
  local maxVehPtr = im.IntPtr(e.maxVehicles)
  if im.InputInt("Max Vehicles##"..e._id.."maxVeh", maxVehPtr) then
    e.maxVehicles = math.max(0, maxVehPtr[0])
    -- Filter config saved to additionalAttributes, not ctd
    probChanged = true
    ret = true
  end
  im.PopItemWidth()
  im.SameLine()
  im.Text("(0 = select all matching vehicles)")

  im.PushItemWidth(150)
  local popAttrPtr = im.ArrayChar(64, e.popAttribute)
  if editor.uiInputText("Population Attribute##"..e._id.."popAttr", popAttrPtr, 64) then
    e.popAttribute = ffi.string(popAttrPtr)
    -- Filter config saved to additionalAttributes, not ctd
    probChanged = true
    ret = true
  end
  im.PopItemWidth()
  im.SameLine()
  im.Text("(Attribute to use for weighting, e.g. 'Population')")

  -- Regenerate vehicle options when probability settings change
  if probChanged or not e.cachedVehicleOptions then
    e.cachedVehicleOptions = generateVehicleOptionsFromProbabilitySettings(
      e.baseFilter,
      e.probabilitySettings,
      e.filterByProp,
      e.maxVehicles,
      e.popAttribute,
      e.allowAuxiliaryVehicles,
      e.allowLoadedTrailers
    )
    -- Clear removals when settings change
    if probChanged then
      e.manualRemovals = {}
      e._cachedRemovalsCount = 0
      -- Filter config saved to additionalAttributes, not ctd
    end
    -- Invalidate final configs cache when vehicle options change
    e._cachedFinalConfigs = nil
  end

  -- Cache vehicle list and lookup table (only fetch once, vehicles don't change during editor use)
  if not e._cachedVehicleList or not e._cachedVehicleByModelKey then
    e._cachedVehicleList = core_vehicles.getVehicleList()
    e._cachedVehicleByModelKey = {}
    for _, v in ipairs(e._cachedVehicleList.vehicles) do
      e._cachedVehicleByModelKey[v.model.key] = v
    end
  end

  -- Helper function to get nice vehicle name (uses cached lookup)
  local function getNiceVehicleName(modelKey, configKey)
    local vehicle = e._cachedVehicleByModelKey[modelKey]
    if not vehicle then
      return modelKey .. "/" .. configKey
    end

    local model = vehicle.model
    local config = vehicle.configs[configKey]

    local nameParts = {}
    if model.Brand then
      table.insert(nameParts, model.Brand)
    end
    if model.Name then
      table.insert(nameParts, model.Name)
    end
    if config and config.Configuration then
      table.insert(nameParts, config.Configuration)
    end

    if #nameParts == 0 then
      return modelKey .. "/" .. configKey
    end

    return table.concat(nameParts, " ")
  end

  -- Track changes to manual additions/removals for cache invalidation
  local currentRemovalsCount = 0
  for _ in pairs(e.manualRemovals) do
    currentRemovalsCount = currentRemovalsCount + 1
  end
  local currentAdditionsCount = #e.manualAdditions

  -- Rebuild final configs only if cache is invalid or dependencies changed
  local needsRebuild = not e._cachedFinalConfigs or
                       currentRemovalsCount ~= e._cachedRemovalsCount or
                       currentAdditionsCount ~= e._cachedAdditionsCount or
                       probChanged

  if needsRebuild then
    local finalConfigs = {}
    local configSet = {} -- Track configs to avoid duplicates: {[model] = {[config] = true}}

    -- Convert manualRemovals to nested structure for O(1) lookups (cache this too)
    if not e._cachedRemovalsNested or currentRemovalsCount ~= e._cachedRemovalsCount then
      e._cachedRemovalsNested = {}
      for configKey, _ in pairs(e.manualRemovals) do
        local model, config = configKey:match("^([^/]+)/(.+)$")
        if model and config then
          if not e._cachedRemovalsNested[model] then
            e._cachedRemovalsNested[model] = {}
          end
          e._cachedRemovalsNested[model][config] = true
        end
      end
      e._cachedRemovalsCount = currentRemovalsCount
    end
    local removalsNested = e._cachedRemovalsNested

    -- Add filtered configs
    for _, vehicleModel in ipairs(e.cachedVehicleOptions) do
      local model = vehicleModel.model
      for _, configInfo in ipairs(vehicleModel.configs) do
        local config = configInfo.config
        -- O(1) nested lookup instead of string concatenation + lookup
        if not removalsNested[model] or not removalsNested[model][config] then
          if not configSet[model] or not configSet[model][config] then
            local niceName = getNiceVehicleName(model, config)
            table.insert(finalConfigs, {
              model = model,
              config = config,
              name = niceName
            })
            if not configSet[model] then
              configSet[model] = {}
            end
            configSet[model][config] = true
          end
        end
      end
    end

    -- Add manual additions (ensure they have nice names)
    for _, manualConfig in ipairs(e.manualAdditions) do
      local model = manualConfig.model
      local config = manualConfig.config
      -- O(1) nested lookup instead of string concatenation + lookup
      if not configSet[model] or not configSet[model][config] then
        -- Ensure nice name is set
        if not manualConfig.name or manualConfig.name == config then
          manualConfig.name = getNiceVehicleName(model, config)
        end
        table.insert(finalConfigs, manualConfig)
        if not configSet[model] then
          configSet[model] = {}
        end
        configSet[model][config] = true
      end
    end

    e._cachedFinalConfigs = finalConfigs
    e._cachedAdditionsCount = currentAdditionsCount
  end

  local finalConfigs = e._cachedFinalConfigs

  -- Don't save finalConfigs - we'll generate from filters in constructor
  -- ctd[e.fieldName] = finalConfigs

  -- Display selected configs list
  im.Separator()
  im.Text("Selected Configs (" .. #finalConfigs .. "):")
  -- Use available content region, but ensure minimum height for usability
  -- Calculate based on content with reasonable min/max bounds
  local availHeight = im.GetContentRegionAvail().y
  local configListHeight = math.max(200, math.min(availHeight * 0.6, #finalConfigs * 25 + 30))
  im.BeginChild1("VehicleFilterConfigs"..e._id, im.ImVec2(0, configListHeight), true)

  if #finalConfigs == 0 then
    im.TextColored(im.ImVec4(1, 0.5, 0, 1), "No configs selected. Add probability settings or add manually.")
  else
    for i, cfg in ipairs(finalConfigs) do
      im.Text(cfg.model .. " / " .. (cfg.name or cfg.config))
      im.SameLine()
      if im.SmallButton("Remove##"..e._id.."remove"..i) then
        -- Check if it's a manual addition
        local foundManual = false
        for j, manualCfg in ipairs(e.manualAdditions) do
          if manualCfg.model == cfg.model and manualCfg.config == cfg.config then
            table.remove(e.manualAdditions, j)
            -- Invalidate cache
            e._cachedFinalConfigs = nil
            foundManual = true
            break
          end
        end
        -- If not manual, add to removals (using string key for storage compatibility)
        if not foundManual then
          e.manualRemovals[cfg.model .. "/" .. cfg.config] = true
          -- Invalidate cache
          e._cachedFinalConfigs = nil
          e._cachedRemovalsNested = nil
        end
        -- Filter config saved to additionalAttributes, not ctd
        ret = true
      end
    end
  end

  im.EndChild()

  -- Manual add section
  im.Separator()
  im.Text("Add Config Manually:")

  -- Get all available models and configs for dropdown
  local allModels = {}
  for modelName, _ in pairs(core_vehicles.getModelsData()) do
    local model = core_vehicles.getModel(modelName)
    if model and model.model then
      table.insert(allModels, model.model.key)
    end
  end
  table.sort(allModels)

  -- Model selection
  local selectedModel = e._tempSelectedModel or allModels[1] or ""
  if im.BeginCombo("Model##"..e._id.."addModel", selectedModel) then
    for _, modelKey in ipairs(allModels) do
      if im.Selectable1(modelKey, modelKey == selectedModel) then
        e._tempSelectedModel = modelKey
        e._tempSelectedConfig = nil -- Reset config when model changes
        ret = true
      end
    end
    im.EndCombo()
  end

  -- Config selection (based on selected model)
  if selectedModel and selectedModel ~= "" then
    local model = core_vehicles.getModel(selectedModel)
    if model and model.configs then
      local configs = {}
      for configName, _ in pairs(model.configs) do
        table.insert(configs, configName)
      end
      table.sort(configs)

      local selectedConfig = e._tempSelectedConfig or configs[1] or ""
      if im.BeginCombo("Config##"..e._id.."addConfig", selectedConfig) then
        for _, configKey in ipairs(configs) do
          if im.Selectable1(configKey, configKey == selectedConfig) then
            e._tempSelectedConfig = configKey
            ret = true
          end
        end
        im.EndCombo()
      end

      -- Add button
      im.SameLine()
      if im.Button("Add##"..e._id.."addManual") and selectedConfig and selectedConfig ~= "" then
        -- Check if already exists in manual additions
        local alreadyExists = false
        for _, manualCfg in ipairs(e.manualAdditions) do
          if manualCfg.model == selectedModel and manualCfg.config == selectedConfig then
            alreadyExists = true
            break
          end
        end
        -- Check if it's in removals (using string key for storage compatibility)
        if not alreadyExists and not e.manualRemovals[selectedModel .. "/" .. selectedConfig] then
          table.insert(e.manualAdditions, {
            model = selectedModel,
            config = selectedConfig,
            name = selectedConfig
          })
          -- Invalidate cache
          e._cachedFinalConfigs = nil
          -- Filter config saved to additionalAttributes, not ctd
          ret = true
        end
      end
    end
  end

  -- Save filter configuration to missionTypeData (not the final vehicle list)
  -- Always save if filters exist (not just on change) to ensure they're persisted
  if not ctd[e.fieldName] then
    ctd[e.fieldName] = {}
  end
  -- Save cleaned filter data (only true values) directly to vehicleFilters
  ctd[e.fieldName].baseFilter = cleanBaseFilter(e.baseFilter)
  ctd[e.fieldName].probabilitySettings = cleanProbabilitySettings(e.probabilitySettings)
  ctd[e.fieldName].manualAdditions = deepcopy(e.manualAdditions)
  ctd[e.fieldName].manualRemovals = deepcopy(e.manualRemovals)
  ctd[e.fieldName].maxVehicles = e.maxVehicles
  ctd[e.fieldName].popAttribute = e.popAttribute
  ctd[e.fieldName].allowAuxiliaryVehicles = e.allowAuxiliaryVehicles
  ctd[e.fieldName].allowLoadedTrailers = e.allowLoadedTrailers

  if ret then
    container._dirty = true
  end

  im.Columns(1)
  return ret
end

return function(element)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(element)
  return o
end

