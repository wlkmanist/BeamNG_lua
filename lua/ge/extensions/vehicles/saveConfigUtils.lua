-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local customSelectValue = "__custom__"

local fieldDefinitions = {
  {
    key = "Description",
    type = "text",
    label = "ui.vehicleconfig.metadata.description",
    maxLength = 120,
    useFallbackAsDefault = false,
  },
  {
    key = "Value",
    type = "money",
    label = "ui.vehicleconfig.metadata.price",
    description = "ui.vehicleconfig.metadata.priceDescription",
    min = 0,
    step = 100,
    useSourceFallback = true,
  },
  {
    key = "Years",
    type = "yearRange",
    label = "ui.vehicles.propName.Years",
    description = "ui.vehicleconfig.metadata.yearsDescription",
    minLabel = "ui.vehicleconfig.metadata.minimumYear",
    maxLabel = "ui.vehicleconfig.metadata.maximumYear",
    step = 1,
    useSourceFallback = true,
  },
  {
    key = "vehicleSelectorSubCluster",
    type = "select",
    label = "ui.vehicleconfig.metadata.selectorSubcluster",
    description = "ui.vehicleconfig.metadata.selectorSubclusterDescription",
    optionsSource = "modelAndConfigs",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicleconfig.metadata.selectorSubcluster",
    maxLength = 120,
    useSourceFallback = true,
  },
  {
    key = "vehicleSelectorSubGroup",
    type = "select",
    label = "ui.vehicleconfig.metadata.selectorSubgroup",
    description = "ui.vehicleconfig.metadata.selectorSubgroupDescription",
    optionsSource = "modelAndConfigs",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicleconfig.metadata.selectorSubgroup",
    maxLength = 120,
    useSourceFallback = true,
  },
  {
    key = "Country",
    type = "select",
    label = "ui.vehicles.propName.Country",
    description = "ui.vehicleconfig.metadata.countryDescription",
    optionsSource = "countries",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicleconfig.metadata.customCountryName",
    maxLength = 80,
    useSourceFallback = true,
  },
  {
    key = "Region",
    type = "multiSelect",
    label = "ui.vehicles.propName.Region",
    description = "ui.vehicleconfig.metadata.regionDescription",
    optionsSource = "catalogue",
    useSourceFallback = true,
  },
  {
    key = "Type",
    type = "select",
    label = "ui.vehicles.propName.Type",
    description = "ui.vehicleconfig.metadata.typeDescription",
    optionsSource = "catalogue",
    excludedValues = { "Traffic", "PropTraffic", "PropParked", "Utility", "Debug", "Unknown" },
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicles.propName.Type",
    maxLength = 80,
    useSourceFallback = true,
  },
  {
    key = "Body Style",
    type = "select",
    label = "ui.vehicles.propName.Body Style",
    description = "ui.vehicleconfig.metadata.bodyStyleDescription",
    optionsSource = "catalogue",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicles.propName.Body Style",
    maxLength = 80,
    useSourceFallback = true,
  },
  {
    key = "Config Type",
    type = "select",
    label = "ui.vehicles.propName.Config Type",
    description = "ui.vehicleconfig.metadata.configTypeDescription",
    optionsSource = "catalogue",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicles.propName.Config Type",
    maxLength = 80,
    useSourceFallback = true,
  },
  {
    key = "Commercial Class",
    type = "select",
    label = "ui.vehicles.propName.Commercial Class",
    description = "ui.vehicleconfig.metadata.commercialClassDescription",
    optionsSource = "catalogue",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicles.propName.Commercial Class",
    maxLength = 80,
    useSourceFallback = true,
  },
  {
    key = "Derby Class",
    type = "select",
    label = "ui.vehicles.propName.Derby Class",
    description = "ui.vehicleconfig.metadata.derbyClassDescription",
    optionsSource = "catalogue",
    allowCustom = true,
    customOptionLabel = "ui.vehicleconfig.metadata.customValue",
    customValueLabel = "ui.vehicles.propName.Derby Class",
    maxLength = 80,
    useSourceFallback = true,
  },
  {
    key = "InsuranceClass",
    type = "select",
    label = "ui.vehicleconfig.metadata.insuranceClass",
    description = "ui.vehicleconfig.metadata.insuranceClassDescription",
    options = {
      { value = "dailyDriver", label = "insurance.classes.dailyDriver.name" },
      { value = "commercial", label = "insurance.classes.commercial.name" },
      { value = "prestige", label = "insurance.classes.prestige.name" },
    },
    translateOptionLabels = true,
    useSourceFallback = true,
  },
  {
    key = "Population",
    type = "integer",
    label = "ui.vehicleconfig.metadata.population",
    description = "ui.vehicleconfig.metadata.populationDescription",
    min = 0,
    max = 50000,
    step = 100,
    useSourceFallback = true,
  },


}

local fieldDefinitionByKey = {}
for _, definition in ipairs(fieldDefinitions) do
  fieldDefinitionByKey[definition.key] = definition
end

local countryOptionsCache
local countryLookupCache
local catalogueOptionsCache = {}
local modelOptionWarningCache = {}

local function trim(value)
  return value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function isFiniteNumber(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizeYearRange(value)
  if type(value) ~= "table" then return nil end
  local min = tonumber(value.min)
  local max = tonumber(value.max)
  if not isFiniteNumber(min) or not isFiniteNumber(max) then return nil end
  if min % 1 ~= 0 or max % 1 ~= 0 or min > max then return nil end
  return { min = min, max = max }
end

local function getCountryOptions()
  if countryOptionsCache and countryLookupCache then
    return countryOptionsCache, countryLookupCache
  end

  local countries = {}
  local modelList = core_vehicles.getModelList(true)
  for _, model in ipairs(modelList and modelList.models or {}) do
    if type(model.Country) == "string" then
      local country = trim(model.Country)
      if country ~= "" then
        countries[country] = true
      end
    end
  end

  local options = {}
  for country in pairs(countries) do
    table.insert(options, {
      value = country,
      label = core_locales.translateWithPrefixFallback(country, "ui.vehicles.propValue.Country."),
    })
  end
  table.sort(options, function(a, b)
    local aLabel = string.lower(a.label or a.value)
    local bLabel = string.lower(b.label or b.value)
    if aLabel == bLabel then return a.value < b.value end
    return aLabel < bLabel
  end)

  countryOptionsCache = options
  countryLookupCache = countries
  return countryOptionsCache, countryLookupCache
end

local function isExcludedValue(definition, value)
  if not definition.excludedValues then return false end
  local lowerValue = string.lower(value)
  for _, excluded in ipairs(definition.excludedValues) do
    if string.lower(excluded) == lowerValue then return true end
  end
  return false
end

local function translateOptionValue(definition, value)
  if definition.optionsSource == "catalogue" then
    return core_locales.translateWithPrefixFallback(value, "ui.vehicles.propValue." .. definition.key .. ".")
  end
  return _tr(value) or value
end

local function buildOptionsFromCounts(definition, valueCounts, warningContext)
  local valuesByLabel = {}
  for value, count in pairs(valueCounts) do
    if not isExcludedValue(definition, value) then
      local label = translateOptionValue(definition, value)
      valuesByLabel[label] = valuesByLabel[label] or {}
      table.insert(valuesByLabel[label], { value = value, label = label, count = count })
    end
  end

  local options = {}
  local lookup = {}
  for label, candidates in pairs(valuesByLabel) do
    table.sort(candidates, function(a, b)
      if a.count == b.count then return a.value < b.value end
      return a.count > b.count
    end)

    local kept = candidates[1]
    table.insert(options, { value = kept.value, label = kept.label })
    for _, candidate in ipairs(candidates) do
      lookup[candidate.value] = kept.value
    end

    if #candidates > 1 then
      local candidateDescriptions = {}
      for _, candidate in ipairs(candidates) do
        table.insert(candidateDescriptions, string.format("%s (%d)", candidate.value, candidate.count))
      end
      local warning = string.format(
        "%s field '%s' has multiple values with the label '%s': %s. Keeping '%s'.",
        warningContext,
        definition.key,
        label,
        table.concat(candidateDescriptions, ", "),
        kept.value
      )
      if not modelOptionWarningCache[warning] then
        modelOptionWarningCache[warning] = true
        log("W", "saveConfigUtils", warning)
      end
    end
  end
  table.sort(options, function(a, b)
    local aLabel = string.lower(a.label or a.value)
    local bLabel = string.lower(b.label or b.value)
    if aLabel == bLabel then return a.value < b.value end
    return aLabel < bLabel
  end)
  return options, lookup
end

local function addOptionValue(valueCounts, value)
  if type(value) == "string" then
    value = trim(value)
    if value ~= "" then valueCounts[value] = (valueCounts[value] or 0) + 1 end
    return
  end
  if type(value) ~= "table" then return end
  for key, active in pairs(value) do
    local tableValue = type(key) == "number" and active or key
    if type(key) == "number" or active then
      addOptionValue(valueCounts, tableValue)
    end
  end
end

local function getModelFieldOptions(definition, modelKey)
  local valueCounts = {}
  local model = type(modelKey) == "string" and core_vehicles.getModel(modelKey) or nil

  addOptionValue(valueCounts, model and model.model and model.model[definition.key])
  for _, config in pairs(model and model.configs or {}) do
    local infoData = type(config.infoFilename) == "string" and jsonReadFile(config.infoFilename) or nil
    addOptionValue(valueCounts, infoData and infoData[definition.key])
  end
  return buildOptionsFromCounts(definition, valueCounts, "Model '" .. tostring(modelKey) .. "'")
end

local function getCatalogueFieldOptions(definition)
  local cached = catalogueOptionsCache[definition.key]
  if cached then return cached.options, cached.lookup end

  local valueCounts = {}
  local modelList = core_vehicles.getModelList(true)
  for _, modelData in ipairs(modelList and modelList.models or {}) do
    local modelKey = modelData.key or modelData.model_key
    local model = modelKey and core_vehicles.getModel(modelKey) or nil
    addOptionValue(valueCounts, model and model.model and model.model[definition.key])
    for _, config in pairs(model and model.configs or {}) do
      addOptionValue(valueCounts, config[definition.key])
    end
  end

  local options, lookup = buildOptionsFromCounts(definition, valueCounts, "Vehicle catalogue")
  catalogueOptionsCache[definition.key] = { options = options, lookup = lookup }
  return options, lookup
end

local function getFieldOptions(definition, modelKey)
  if definition.optionsSource == "countries" then
    return getCountryOptions()
  end
  if definition.optionsSource == "modelAndConfigs" then
    return getModelFieldOptions(definition, modelKey)
  end
  if definition.optionsSource == "catalogue" then
    return getCatalogueFieldOptions(definition)
  end
  local options = deepcopy(definition.options or {})
  local lookup = {}
  for _, option in ipairs(options) do
    if definition.translateOptionLabels then option.label = _tr(option.label) end
    lookup[option.value] = true
  end
  return options, lookup
end

local function normalizeSelectValue(definition, value, modelKey)
  if type(value) ~= "string" then return nil end
  value = trim(value)
  if value == "" or value == customSelectValue or isExcludedValue(definition, value) then return nil end

  local options, lookup = getFieldOptions(definition, modelKey)
  if lookup[value] then
    return type(lookup[value]) == "string" and lookup[value] or value
  end

  local lowerValue = string.lower(value)
  for _, option in ipairs(options) do
    if string.lower(option.value) == lowerValue or string.lower(option.label or option.value) == lowerValue then
      return option.value
    end
  end
  return definition.allowCustom and value or nil
end

local function normalizeMultiSelectValue(definition, value, modelKey)
  if type(value) == "string" then value = { value } end
  if type(value) ~= "table" then return nil end

  local normalized = {}
  local seen = {}
  for key, active in pairs(value) do
    local candidate = type(key) == "number" and active or key
    if (type(key) == "number" or active) and type(candidate) == "string" then
      candidate = normalizeSelectValue(definition, candidate, modelKey)
      if candidate and not seen[candidate] then
        seen[candidate] = true
        table.insert(normalized, candidate)
      end
    end
  end
  table.sort(normalized)
  return #normalized > 0 and normalized or nil
end

local function normalizeIntegerValue(definition, value)
  value = tonumber(value)
  if not isFiniteNumber(value) or value % 1 ~= 0 then return nil end
  if definition.min ~= nil and value < definition.min then return nil end
  if definition.max ~= nil and value > definition.max then return nil end
  return value
end

local function readConfigInfo(modelKey, vehicleDirectory, configName)
  if type(configName) ~= "string" or configName == "" then return nil end
  local infoData
  if type(vehicleDirectory) == "string" and vehicleDirectory ~= "" then
    infoData = jsonReadFile(vehicleDirectory .. "info_" .. configName .. ".json")
  end
  return infoData or core_vehicles.getConfig(modelKey, configName)
end

local function normalizeHydratedValue(definition, value, modelKey)
  if definition.type == "text" then
    if type(value) ~= "string" then return nil end
    value = trim(value)
    return value ~= "" and value or nil
  end
  if definition.type == "yearRange" then
    return normalizeYearRange(value)
  end
  if definition.type == "select" then
    return normalizeSelectValue(definition, value, modelKey)
  end
  if definition.type == "multiSelect" then
    return normalizeMultiSelectValue(definition, value, modelKey)
  end
  if definition.type == "integer" then
    return normalizeIntegerValue(definition, value)
  end
  if definition.type == "money" then
    value = tonumber(value)
    return isFiniteNumber(value) and value >= (definition.min or 0) and value or nil
  end
end

local function resolveFieldValue(definition, targetInfo, sourceInfo, modelKey)
  local targetValue = normalizeHydratedValue(definition, targetInfo and targetInfo[definition.key], modelKey)
  if targetValue ~= nil then return targetValue end
  if not definition.useSourceFallback then return nil end

  return normalizeHydratedValue(definition, sourceInfo and sourceInfo[definition.key], modelKey)
end

local function getFields(modelKey, vehicleDirectory, sourceConfigName, targetConfigName)
  local model = core_vehicles.getModel(modelKey)
  local modelInfo = model and model.model or {}
  local targetInfo = readConfigInfo(modelKey, vehicleDirectory, targetConfigName)
  local sourceInfo = readConfigInfo(modelKey, vehicleDirectory, sourceConfigName)
  local fields = {}

  for _, definition in ipairs(fieldDefinitions) do
    local field = deepcopy(definition)
    local configValue = resolveFieldValue(definition, targetInfo, sourceInfo, modelKey)
    local fallbackValue = normalizeHydratedValue(definition, modelInfo and modelInfo[definition.key], modelKey)
    local value = configValue
    if value == nil and definition.useFallbackAsDefault ~= false then
      value = fallbackValue
    end
    field.included = configValue ~= nil
    field.value = value
    field.fallbackValue = fallbackValue
    field.optional = true
    field.includeLabel = "ui.vehicleconfig.metadata.include"
    if definition.type == "select" or definition.type == "multiSelect" then
      local options, optionLookup = getFieldOptions(definition, modelKey)
      field.options = deepcopy(options)
      if definition.type == "select" and definition.allowCustom then
        table.insert(field.options, 1, {
          value = customSelectValue,
          label = _tr(definition.customOptionLabel),
          custom = true,
        })
        field.customOptionValue = customSelectValue
        field.customValueLabel = definition.customValueLabel
        if value ~= nil and not optionLookup[value] then
          field.customValue = value
          field.value = customSelectValue
        else
          field.customValue = ""
        end
      end
    end
    field.useSourceFallback = nil
    field.useFallbackAsDefault = nil
    field.optionsSource = nil
    field.allowCustom = nil
    field.customOptionLabel = nil
    field.translateOptionLabels = nil
    table.insert(fields, field)
  end
  return fields
end

local function metadataError(field, code)
  return nil, { field = field, code = code }
end

local function validateMetadata(metadata, modelKey)
  if metadata == nil then return {} end
  if type(metadata) ~= "table" then
    return metadataError(nil, "notTable")
  end

  if metadata.description ~= nil then
    metadata = deepcopy(metadata)
    if metadata.Description == nil then
      metadata.Description = metadata.description
    end
    metadata.description = nil
  end

  for key in pairs(metadata) do
    if not fieldDefinitionByKey[key] then
      return metadataError(key, "unknownField")
    end
  end

  local normalized = {}
  for _, definition in ipairs(fieldDefinitions) do
    local value = metadata[definition.key]
    if value ~= nil then
      if definition.type == "text" then
        if type(value) ~= "string" then
          return metadataError(definition.key, "invalidType")
        end
        value = trim(value)
        if value == "" then
          return metadataError(definition.key, "empty")
        end
        if definition.maxLength and #value > definition.maxLength then
          return metadataError(definition.key, "tooLong")
        end
        normalized[definition.key] = value
      elseif definition.type == "yearRange" then
        value = normalizeYearRange(value)
        if not value then
          return metadataError(definition.key, "invalidRange")
        end
        normalized[definition.key] = value
      elseif definition.type == "select" then
        value = normalizeSelectValue(definition, value, modelKey)
        if not value then
          return metadataError(definition.key, "invalidOption")
        end
        if definition.maxLength and #value > definition.maxLength then
          return metadataError(definition.key, "tooLong")
        end
        normalized[definition.key] = value
      elseif definition.type == "multiSelect" then
        value = normalizeMultiSelectValue(definition, value, modelKey)
        if not value then
          return metadataError(definition.key, "invalidOption")
        end
        normalized[definition.key] = value
      elseif definition.type == "integer" then
        value = normalizeIntegerValue(definition, value)
        if value == nil then
          return metadataError(definition.key, "invalidNumber")
        end
        normalized[definition.key] = value
      elseif definition.type == "money" then
        value = tonumber(value)
        if not isFiniteNumber(value) or value < (definition.min or 0) then
          return metadataError(definition.key, "invalidNumber")
        end
        normalized[definition.key] = value
      end
    end
  end
  return normalized
end

local function clearCache()
  countryOptionsCache = nil
  countryLookupCache = nil
  catalogueOptionsCache = {}
end

M.getFields = getFields
M.validateMetadata = validateMetadata
M.clearCache = clearCache

return M
