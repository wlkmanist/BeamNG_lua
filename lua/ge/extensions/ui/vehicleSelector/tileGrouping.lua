local M = {}
-- Type ordering for grouping
local typeOrder = {
  ['Car'] = {"ui.menu.vehicleSelector.tileGroups.carsAndTrucks", 10},
  ['Truck'] = {"ui.menu.vehicleSelector.tileGroups.carsAndTrucks", 20},
  ['Heavy Machinery'] = {"ui.menu.vehicleSelector.tileGroups.heavyMachinery", 30},
  ['Aircraft'] = {"ui.menu.vehicleSelector.tileGroups.otherVehicles", 40},
  ['Boat'] = {"ui.menu.vehicleSelector.tileGroups.otherVehicles", 50},
  ['Automation'] = {"ui.menu.vehicleSelector.tileGroups.automation", 60},
  ['Concept'] = {"ui.menu.vehicleSelector.tileGroups.concept", 70},
  ['Trailer'] = {"ui.menu.vehicleSelector.tileGroups.trailers", 80},
  ['Prop'] = {"ui.menu.vehicleSelector.tileGroups.props", 90},
}

-- Properties that use range-based grouping
local isRange = {
  ['Years'] = true,
  ['Value'] = true,
}

-- Group mode functions for different grouping criteria
local groupModeFunctions = {
  ['Type'] = function(type)
    local typeInfo = typeOrder[type]
    if not typeInfo then return type, 999 end
    return _tr(typeInfo[1]), typeInfo[2] or 999
  end,
  ['Brand'] = function(brand)
    return brand, 0
  end,
  ['Country'] = function(country)
    return country, 0
  end,
  ['Config Type'] = function(configType)
    return configType, 0
  end,
  ['Derby Class'] = function(derbyClass)
    return derbyClass, 0
  end,
  ['Body Style'] = function(bodyStyle)
    return bodyStyle, 0
  end,
  ['Source'] = function(source)
    return source, 0
  end,
}

-- Range-based grouping functions
local groupsForRange = {
  ['Years'] = function(years)
    if not years or not years.min or not years.max then
      return {{groupName = _tr("ui.menu.gridSelector.other"), groupOrder = 999}}
    end

    local decades = {}
    local startDecade = math.floor(years.min / 10) * 10
    local endDecade = math.floor(years.max / 10) * 10

    for decade = startDecade, endDecade, 10 do
      table.insert(decades, {
        groupName = tostring(decade) .. "s",
        groupOrder = 0
      })
    end

    return decades
  end,
  ['Value'] = function(value)
    local price = value
    if type(value) == 'table' then
      price = value.min
    end
    if not price or price == _tr("ui.menu.gridSelector.other") then
      return {{groupName = _tr("ui.menu.gridSelector.other"), groupOrder = 999}}
    end

    local groups = {}

    if price < 10000 then
      table.insert(groups, {groupName = "Misc ($0-$10k)", groupOrder = 1})
    elseif price < 20000 then
      table.insert(groups, {groupName = "$10k-$20k", groupOrder = 2})
    elseif price < 50000 then
      table.insert(groups, {groupName = "$20k-$50k", groupOrder = 3})
    elseif price < 100000 then
      table.insert(groups, {groupName = "$50k-$100k", groupOrder = 4})
    elseif price < 250000 then
      table.insert(groups, {groupName = "$100k-$250k", groupOrder = 5})
    elseif price < 500000 then
      table.insert(groups, {groupName = "$250k-$500k", groupOrder = 6})
    elseif price < 1000000 then
      table.insert(groups, {groupName = "$500k-$1M", groupOrder = 7})
    else
      table.insert(groups, {groupName = "$1M+", groupOrder = 8})
    end

    return groups
  end
}

-- Get property value from config or model
local function getConfigOrModelPropValue(config, prop)
  local value = config[prop]
  if value == nil then
    local model = core_vehicles.getModel(config.model_key)
    if model and model.model then
      value = model.model[prop]
    end
  end
  if value == nil then return nil end
  return value
end

-- Get groups for a specific config based on group mode
function M.getGroupsForConfig(config, groupMode, displayData)
  local groupsForConfig = {}

  if not isRange[groupMode] then
    local value = getConfigOrModelPropValue(config, groupMode) or _tr("ui.menu.gridSelector.other")
    local groupName, groupOrder = groupModeFunctions[groupMode](value)
    table.insert(groupsForConfig, {groupName = groupName, groupOrder = groupOrder})
  else
    local value = getConfigOrModelPropValue(config, groupMode) or _tr("ui.menu.gridSelector.other")
    local rangeGroups = groupsForRange[groupMode](value)
    if rangeGroups then
      for _, group in ipairs(rangeGroups) do
        table.insert(groupsForConfig, group)
      end
    else
      table.insert(groupsForConfig, {groupName = _tr("ui.menu.gridSelector.other"), groupOrder = 0})
    end
  end

  -- Add special groups for favourites and recent vehicles
  if displayData.showFavouritesMode ~= 'hidden' and ui_vehicleSelector_general.isFavourite(config.model_key, config.key) then
    table.insert(groupsForConfig, {groupName = _tr("ui.menu.gridSelector.favourites"), groupOrder = -1, isFavouriteGroup = true})
  end
  if displayData.showRecentMode ~= 'hidden' and ui_vehicleSelector_general.isRecentVehicle(config.model_key, config.key) then
    table.insert(groupsForConfig, {groupName = _tr("ui.menu.gridSelector.recent"), groupOrder = -2, isRecentGroup = true})
  end

  return groupsForConfig
end

-- Check if a group mode uses range-based grouping
function M.isRangeGroupMode(groupMode)
  return isRange[groupMode] or false
end

-- Get group mode function
function M.getGroupModeFunction(groupMode)
  return groupModeFunctions[groupMode]
end

-- Get range grouping function
function M.getRangeGroupingFunction(groupMode)
  return groupsForRange[groupMode]
end

-- Public API
M.getConfigOrModelPropValue = getConfigOrModelPropValue
M.groupModeFunctions = groupModeFunctions
M.isRange = isRange

return M
