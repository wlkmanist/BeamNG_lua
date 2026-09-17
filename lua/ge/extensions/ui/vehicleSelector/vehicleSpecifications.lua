local M = {}
M.dependencies = { "core_locales" }
local generalSpecifications = { "Years", "Country", "Power", "Weight", "Value", }
local propTitle = function(key) return _tr("ui.vehicles.propName." .. key, key) end
local propValue = function(propName, key) return core_locales.translateWithPrefixFallback(key, "ui.vehicles.propValue." .. propName .. ".") end

local specificationSetup = {
  {
    label = "Performance",
    aggregatesImperial = {
      'Power',
      'Torque',
      'Weight',
      'Top Speed',
      '0-60 mph',
      '0-100 mph',
      '0-200 mph',
      '60-100 mph',
      '60-0 mph',
      'Braking G',
      'Weight/Power',
      "Performance Class",
      'Off-Road Score',
    },
    aggregatesMetric = {
      'Power',
      'Torque',
      'Weight',
      'Top Speed',
      '0-100 km/h',
      '0-200 km/h',
      '0-300 km/h',
      '100-200 km/h',
      '100-0 km/h',
      'Braking G',
      'Weight/Power',
      "Performance Class",
      'Off-Road Score',
    },
    aggregates = {


    }
  },
  {
    label = "Other",
    aggregates = {
      "Type",
      "Config Type",
      "Transmission",
      "Derby Class",
      "Drivetrain",
      'Propulsion',
      'Fuel Type',
      'Induction Type',
      'Commercial Class',
    }
  }
}
local aggregateToUnit = {
  ['0-60 mph'] = 'seconds',
  ['0-100 mph'] = 'seconds',
  ['0-200 mph'] = 'seconds',
  ['60-100 mph'] = 'seconds',
  ['60-0 mph'] = 'distanceMinor',
  ['0-100 km/h'] = 'seconds',
  ['0-200 km/h'] = 'seconds',
  ['0-300 km/h'] = 'seconds',
  ['100-200 km/h'] = 'seconds',
  ['100-0 km/h'] = 'distanceMinor',
  ['Braking G'] = 'g',
  ['Torque'] = 'torque',
  ['Power'] = 'power',
  ['Top Speed'] = 'speed',
  ['Weight'] = 'weight',
  ['Weight/Power'] = 'weightPower',
  ['Years'] = 'years',
  ['Value'] = 'money',
}

-- Unit conversion constants
local CONVERSIONS = {
  -- Speed conversions (m/s to other units)
  MPS_TO_KMH = 3.6,
  MPS_TO_MPH = 2.23693629,

  -- Power conversions
  BHP_TO_PS = 1.01387,     -- bhp to PS
  PS_TO_BHP = 0.98632, -- PS to bhp
  PS_TO_KW = 0.73549875,   -- PS to kW

  -- Torque conversions (Nm to lb-ft)
  NM_TO_LBFT = 0.737562149,

  -- Weight conversions (kg to lb)
  KG_TO_LB = 2.20462262,

  -- Distance conversions (m to ft)
  M_TO_FT = 3.2808399,

  -- Weight/Power ratio conversions
  KGPS_TO_LBBHP = 2.20462262 / 0.98632,  -- kg/PS to lb/bhp
}

-- Unit conversions now use the correct individual uiUnit settings
local valueToUnit = {
  value = function(value, _, _, propTitle)
    if type(value) == 'table' and value.min and value.max and type(value.min) == 'number' and type(value.max) == 'number' then
      return string.format("%0.2f - %0.2f", value.min, value.max)
    else
      return propValue(propTitle, tostring(value))
    end
  end,
  years = function(value)
    if type(value) == 'table' and value.min and value.max and type(value.min) == 'number' and type(value.max) == 'number' then
      return string.format("%d - %d", value.min, value.max)
    else
      return tostring(value)
    end
  end,
  money = function(value)
    -- Format with comma separators for thousands and dot for decimals
    if not type(value) == 'number' then
      return tostring(value)
    end
    local formatted = string.format("%.2f", value)
    local integerPart, decimalPart = formatted:match("([^%.]+)%.?(.*)")

    -- Add comma separators to integer part
    local len = #integerPart
    local parts = {}
    for i = len, 1, -3 do
      local start = math.max(1, i - 2)
      table.insert(parts, 1, integerPart:sub(start, i))
    end

    local result = table.concat(parts, ",")
    if decimalPart and decimalPart ~= "" then
      result = result .. "." .. decimalPart
    end

    return "$"..result
  end,
  seconds = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    return string.format("%0.2f%s", value, " s")
  end,
  g = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    return string.format("%0.3f%s", value, "")
  end, -- omit g beacause its in the name
  kmh = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    return string.format("%0.2f%s", value * CONVERSIONS.MPS_TO_KMH, " km/h")
  end,
  mph = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    return string.format("%0.2f%s", value * CONVERSIONS.MPS_TO_MPH, " mph")
  end,
  torque = function(value, modelDetails, configDetails)
    if not type(value) == 'number' then
      return tostring(value)
    end
    local metricOrImperial = settings.getValue('uiUnitTorque')
    local peakRPM = configDetails['TorquePeakRPM'] or modelDetails['TorquePeakRPM']
    local unit = metricOrImperial == 'metric' and 'Nm' or 'lb-ft'
    value = metricOrImperial == 'metric' and value or value * CONVERSIONS.NM_TO_LBFT
    local decimals = value >= 100 and 0 or (value >= 10 and 1 or 2)
    -- value is in Nm
    if peakRPM then
      return {{text = string.format("%0."..decimals.."f %s", value, unit)},{text=string.format("@ %s rpm", peakRPM), italic = true}}
    else
      return string.format("%0."..decimals.."f %s", value, unit)
    end
  end,
  power = function(value, modelDetails, configDetails)
    if not type(value) == 'number' then
      return tostring(value)
    end
    local powerUnit = settings.getValue('uiUnitPower')
    local peakRPM = configDetails['PowerPeakRPM'] or modelDetails['PowerPeakRPM']
    local unit = 'PS'
    -- value is already in PS, convert based on setting
    if powerUnit == 'hp' then
      value = value * CONVERSIONS.PS_TO_BHP
      unit = 'hp'
    elseif powerUnit == 'bhp' then
      value = value * CONVERSIONS.PS_TO_BHP
      unit = 'bhp'
    elseif powerUnit == 'kw' then
      value = value * CONVERSIONS.PS_TO_KW
      unit = 'kW'
    else
      -- default to PS for metric
      unit = 'PS'
    end
    local decimals = value >= 100 and 0 or (value >= 10 and 1 or 2)
    if peakRPM then
      return {{text = string.format("%0."..decimals.."f %s", value, unit)},{text=string.format("@ %s rpm", peakRPM), italic = true}}
    else
      return string.format("%0."..decimals.."f %s", value, unit)
    end
  end,
  speed = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    local metricOrImperial = settings.getValue('uiUnitLength')
    -- value is in m/s
    if metricOrImperial == 'metric' then
      return string.format("%0.2f%s", value * CONVERSIONS.MPS_TO_KMH, " km/h")
    else
      return string.format("%0.2f%s", value * CONVERSIONS.MPS_TO_MPH, " mph")
    end
  end,
  weightPower = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    local weightUnit = settings.getValue('uiUnitWeight')
    local powerUnit = settings.getValue('uiUnitPower')

    -- Base value is in kg/PS, convert based on settings
    local weightStr = weightUnit == 'kg' and 'kg' or 'lb'
    local powerStr = powerUnit == 'kw' and 'kW' or (powerUnit == 'hp' and 'hp' or (powerUnit == 'bhp' and 'bhp' or 'PS'))

    -- Convert weight
    if weightUnit == 'lb' then
      value = value * CONVERSIONS.KG_TO_LB
    end

    -- Convert power denominator
    if powerUnit == 'hp' or powerUnit == 'bhp' then
      value = value / CONVERSIONS.PS_TO_BHP
    elseif powerUnit == 'kw' then
      value = value / CONVERSIONS.PS_TO_KW
    end

    return string.format("%0.2f %s/%s", value, weightStr, powerStr)
  end,
  weight = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    -- value is in kg
    local weightUnit = settings.getValue('uiUnitWeight')
    local decimals = value >= 100 and 0 or (value >= 10 and 1 or 2)
    if weightUnit == 'kg' then
      return string.format("%0."..decimals.."f kg", value)
    else
      -- convert kg to lb
      local lbValue = value * CONVERSIONS.KG_TO_LB
      local lbDecimals = lbValue >= 100 and 0 or (lbValue >= 10 and 1 or 2)
      return string.format("%0."..lbDecimals.."f lb", lbValue)
    end
  end,
  distanceMinor = function(value)
    if not type(value) == 'number' then
      return tostring(value)
    end
    local metricOrImperial = settings.getValue('uiUnitLength')
    -- value is in m
    if metricOrImperial == 'metric' then
      return string.format("%0.2f m", value)
    else
      return string.format("%0.2f ft", value * CONVERSIONS.M_TO_FT)
    end
  end,
}

local postIcon = {
  money = "beamCurrency",
}

local function makeSpec(modelDetails, configDetails, key, list)
  local isFromConfig = true
  local value = configDetails[key]
  if value == nil then
    isFromConfig = false
    value = modelDetails[key]
  end
  if value == nil then return nil end

  local unit = aggregateToUnit[key] or 'value'
  table.insert(list, {
    key = propTitle(key),
    value = valueToUnit[unit](value, modelDetails, configDetails, key),
    --postIcon = postIcon[unit],
    isFromConfig = isFromConfig
  })
end
local sourceIcons = {
  ["BeamNG - Official"] = "beamNG",
  ["Mod"] = "puzzleModule",
  ["Custom"] = "wrench",
}
local function addIconTags(modelDetails, configDetails)
  local iconTags = {}

  if configDetails.Drivetrain == "AWD" then
    table.insert(iconTags, {icon = "AWD", label = _tr("ui.menu.vehicleSelector.tagTooltips.drivetrainAwd")})
  elseif configDetails.Drivetrain == "RWD" then
    table.insert(iconTags, {icon = "RWD", label = _tr("ui.menu.vehicleSelector.tagTooltips.drivetrainRwd")})
  elseif configDetails.Drivetrain == "FWD" then
    table.insert(iconTags, {icon = "FWD", label = _tr("ui.menu.vehicleSelector.tagTooltips.drivetrainFwd")})
  elseif configDetails.Drivetrain == "4WD" then
    table.insert(iconTags, {icon = "4WD", label = _tr("ui.menu.vehicleSelector.tagTooltips.drivetrain4wd")})
  elseif configDetails.Drivetrain and type(configDetails.Drivetrain) == 'string' and string.find(configDetails.Drivetrain, "x") then
    table.insert(iconTags, {iconText = string.gsub(configDetails.Drivetrain, "x", "×"), label = "Drivetrain: "..string.gsub(configDetails.Drivetrain, "x", "×")})
  end

  if configDetails['Transmission'] == "Manual" then
    table.insert(iconTags, {icon = "transmissionM", label = _tr("ui.menu.vehicleSelector.tagTooltips.transmissionManual")})
  elseif configDetails['Transmission'] == "Automatic" then
    table.insert(iconTags, {icon = "transmissionA", label = _tr("ui.menu.vehicleSelector.tagTooltips.transmissionAutomatic")})
  elseif configDetails['Transmission'] == "Sequential" then
    table.insert(iconTags, {icon = "twoArrowsHorizontal", label = _tr("ui.menu.vehicleSelector.tagTooltips.transmissionSequential")})
  elseif configDetails['Transmission'] == "CVT" or configDetails['Transmission'] == "DCT" then
    table.insert(iconTags, {icon = "transmissionCvt", label = propTitle("Transmission") .. ": " .. propValue("Transmission", configDetails['Transmission']) })
  end

  if configDetails['Induction Type'] == "NA" then
    table.insert(iconTags, {icon = "intakeTrumpets", label = _tr("ui.menu.vehicleSelector.tagTooltips.inductionTypeNa")})
  elseif configDetails['Induction Type'] == "Turbo" then
    table.insert(iconTags, {icon = "turbine", label = _tr("ui.menu.vehicleSelector.tagTooltips.inductionTypeTurbo")})
  elseif configDetails['Induction Type'] == "Turbo + N2O" then
    table.insert(iconTags, {icon = "turbine", label = _tr("ui.menu.vehicleSelector.tagTooltips.inductionTypeTurboN2o")})
    table.insert(iconTags, {icon = "N2OHoriz", label = propValue("Induction Type", "N2O")})
  elseif configDetails['Induction Type'] == "SC" then
    table.insert(iconTags, {icon = "hydroPump2", label = _tr("ui.menu.vehicleSelector.tagTooltips.inductionTypeSc")})
  elseif configDetails['Induction Type'] == "SC + N2O" then
    table.insert(iconTags, {icon = "hydroPump2", label = _tr("ui.menu.vehicleSelector.tagTooltips.inductionTypeSc")})
    table.insert(iconTags, {icon = "N2OHoriz", label = propValue("Induction Type", "N2O")})
  end

  if configDetails['Fuel Type'] == "Battery" then
    table.insert(iconTags, {icon = "charge", label = _tr("ui.menu.vehicleSelector.tagTooltips.fuelTypeBattery")})
  elseif configDetails['Fuel Type'] == "Gasoline" or configDetails['Fuel Type'] == "Diesel" then
    table.insert(iconTags, {icon = "fuelPump", label = propTitle("Fuel Type") .. ": " .. propValue("Fuel Type", configDetails['Fuel Type'])})
  end


  return iconTags
end


-- Get detailed config information
local pathDefaultConfig = "settings/default.pc"
local function getDetails(itemDetails)
  local modelKey = itemDetails.model
  local configKey = itemDetails.config
  local modelDetails = core_vehicles.getModel(modelKey).model
  local configDetails = core_vehicles.getConfig(modelKey, configKey) or {}
  local metricOrImperial = settings.getValue('uiUnitLength')
  local configPcFile = core_vehicles.getFilesParsed()[configDetails.pcFilename]

  extensions.hook("onVehicleSelectorViewDetails", modelKey, configKey)

  local specificationsList = {}
  local displayData = ui_vehicleSelector_general.getDisplayData()
  if displayData.includeDevInfo then
    local devSpecs = {
      label = "Dev Info",
      icon = "bug",
      specifications = {
        {
          value =  modelKey .. " / " .. configKey,
        },
      }
    }
    if configDetails.infoFilename then
      table.insert(devSpecs.specifications, {
        value = configDetails.infoFilename,
        openFolder = true,
      })
      local mod = core_modmanager.getModFromPath(configDetails.infoFilename)
      if mod then
        table.insert(devSpecs.specifications, {
          value = mod.fullpath,
          openFolder = true,
        })
      end
    end

    if configDetails.pcFilename then
      table.insert(devSpecs.specifications, {
        value = configDetails.pcFilename,
        openFolder = true,
      })
    end
    if configDetails.preview then
      table.insert(devSpecs.specifications, {
        value = configDetails.preview,
        openFolder = true,
      })
    end
    if configDetails.Region then
      local regions = tableKeys(configDetails.Region)
      for i, region in ipairs(regions) do
        regions[i] = propValue("Region", region)
      end
      table.sort(regions)

      table.insert(devSpecs.specifications, {
        key = propTitle("Region"),
        value = table.concat(regions, ", "),
      })
    end
    if configDetails.isAuxiliary then
      table.insert(devSpecs.specifications, {
        key = "Is Auxiliary",
        value = "Yes",
        postIcon = "bug",
      })
    end
    table.insert(specificationsList, devSpecs)
  end


  for _, specificationGroup in ipairs(specificationSetup) do
    local group = {}
    group.label = specificationGroup.label
    group.specifications = {}
    if metricOrImperial == 'metric' then
      for _, specification in ipairs(specificationGroup.aggregatesMetric or {}) do
        makeSpec(modelDetails, configDetails, specification, group.specifications)
      end
    else
      for _, specification in ipairs(specificationGroup.aggregatesImperial or {}) do
        makeSpec(modelDetails, configDetails, specification, group.specifications)
      end
    end
    for _, specification in ipairs(specificationGroup.aggregates) do
      makeSpec(modelDetails, configDetails, specification, group.specifications)
    end
    if next(group.specifications) then
      table.insert(specificationsList, group)
    end
  end

  local generalSpecs = {}
  for _, specification in ipairs(generalSpecifications) do
    makeSpec(modelDetails, configDetails, specification, generalSpecs)
  end


  local iconTags = addIconTags(modelDetails, configDetails)

  local paintData = {
    multiPaintSetups = {},
    factoryPaints = {},
    allowPaintSelection = configDetails.allowPaintSelectionInSelector,
  }
  for _, multiPaintSetup in ipairs(modelDetails.multiPaintSetups) do
    if multiPaintSetup.usedByConfigByKey[configKey] or multiPaintSetup.forAllConfigs then
      local setup = deepcopy(multiPaintSetup)
      if setup.isDefaultForConfigByKey[configKey] then
        setup.isDefault = true
      end
      table.insert(paintData.multiPaintSetups, setup)
    end
  end
  for _, paint in pairs(modelDetails.paints) do
    table.insert(paintData.factoryPaints, paint)
  end
  table.sort(paintData.factoryPaints, function(a, b)
    return a.name < b.name
  end)

  local tags = {}

  local source = configDetails.Source or modelDetails.Source
  if source == "BeamNG - Official" then
    table.insert(tags, {icon = "beamNG", label = _tr("ui.menu.gridSelector.tags.beamngOfficial")})
  elseif source == "Custom" then
    table.insert(tags, {icon = "wrench", label = _tr("ui.menu.gridSelector.tags.custom")})
  end

  local type = configDetails.Type or modelDetails.Type
  if type == "Automation" then
    table.insert(tags, {svg = "/ui/assets/Original/camshaft_automation_logo.svg", label = "Automation"})
  end
  if configDetails.modID then
    local mod = core_modmanager.getModNameFromID(configDetails.modID)
    if mod then
      table.insert(tags, {icon = "puzzleModule", label = configDetails.Source, goToMod = mod.modID})
    end
  end
  if configDetails.isAuxiliary then
    table.insert(tags, {icon = "bug", label = _tr("ui.menu.gridSelector.tags.auxiliary"), auxiliary = true})
  end
  if modelDetails.missingJbeamFiles then
    table.insert(tags, {icon = "danger", label = _tr("ui.menu.gridSelector.tags.missingJbeamFiles")})
  end

  local data = {
    headerTitle = configDetails.Name or modelDetails.Name or "Unknown Config?",
    brand = configDetails.Brand or modelDetails.Brand,
    configDetails = configDetails,
    isFavourite = ui_vehicleSelector_general.isFavourite(modelKey, configKey),
    tags = tags,
    isStandalonePC = not configDetails.infoFilename,
    modelKey = modelKey,
    configKey = configKey,
    specificationsList = specificationsList,
    iconTags = iconTags,
    generalSpecs = generalSpecs,
    paints = paintData,
    preview = configDetails.preview or modelDetails.preview,
  }

  if itemDetails.config == pathDefaultConfig then
    data.headerTitle = "Legacy default.pc"
    data.preview = gameplay_missions_missions.getNoVehicleThumbFilepath()
    data.configDetails = {
      Description = "This is a legacy config. You can use Menu > Vehicle Config > Save & Load to create new vehicle configurations.",
      model_key = modelKey,
      key = pathDefaultConfig,
    }
    data.isFavourite = displayData.includeDefaultConfigInFavourites
    data.specificationsList = { }
    data.generalSpecs = { }
    data.iconTags = {}
    data.paints = {}
    data.tags = {{icon = "wrench", label = _tr("ui.menu.gridSelector.tags.custom")}}
  end

  return data
end

-- Public API
M.propTitle = propTitle
M.propValue = propValue

M.getDetails = getDetails
M.addIconTags = addIconTags
M.makeSpec = makeSpec
M.specificationSetup = specificationSetup
M.valueToUnit = valueToUnit
M.CONVERSIONS = CONVERSIONS

return M
