-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain vehId at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"gameplay_vehiclePerformance"}

local classAggressionMultipliers = { -- ai aggression coefficient
  S = 1,
  A = 0.9,
  B = 0.8,
  C = 0.7,
  D = 0.6
}

local defaultModelFilter = { -- prevents these vehicle models from being used (these models are either unsuitable or specialized)
  atv = 1,
  utv = 1,
  us_semi = 1,
  midtruck = 1,
  citybus = 1,
  racetruck = 1,
  rockbouncer = 1,
  simple_traffic = 1
}

local defaultConfigFilter = { -- prevents these vehicle configs from being used
  -- e.g. pickup/d15_farmhand_M = 1
}

local defaultConfigTypeFilter = { -- prevents these vehicle config types from being used
  Police = 1,
  Service = 1,
  Powerglow = 1
}

local function getAggressionMultiplier(class) -- returns the expected aggression multiplier for the given class
  class = class or "B"
  return classAggressionMultipliers[class] or 1
end

local function checkFilter(filter, value, invert)
  if not invert then
    return filter[value]
  else
    return not filter[value]
  end
end

local function generateGroup(class, mode, modelFilter, configFilter, configTypeFilter, invertedFilters, randomizePaint, smartShuffle, performanceIndexTarget, performanceIndexWindow) -- generates a group of vehicles for the given class
  class = class or "B" -- B is the default class
  mode = mode or "default" -- default or drag
  -- filters are blacklists by default, but can be inverted
  modelFilter = modelFilter or defaultModelFilter
  configFilter = configFilter or defaultConfigFilter
  configTypeFilter = configTypeFilter or defaultConfigTypeFilter
  invertedFilters = invertedFilters or {} -- e.g. {modelFilter = true} inverts the model filter
  if randomizePaint == nil then randomizePaint = true end
  if smartShuffle == nil then smartShuffle = true end
  performanceIndexWindow = performanceIndexWindow or 5

  local group = { -- this group is usable for the core_multiSpawn system
    name = string.format("Class %s", class),
    type = "custom",
    data = {}
  }
  local closestCandidates = {}

  for _, model in pairs(core_vehicles.getModelList().models) do
    local modelType = model.Type or "Unknown"
    if (modelType == "Car" or modelType == "Truck") and not checkFilter(modelFilter, model.key, invertedFilters.modelFilter) then
      for _, config in pairs(core_vehicles.getModel(model.key).configs) do
        local modelConfigKey = string.format("%s/%s", model.key, config.key)
        if not checkFilter(configFilter, modelConfigKey, invertedFilters.configFilter) then
          local configType = config["Config Type"] or "Unknown"
          if not checkFilter(configTypeFilter, configType, invertedFilters.configTypeFilter) then
            local classData = gameplay_vehiclePerformance.getClassFromConfig(model.key, config.key)
            if classData and classData.class and classData.class.name == class then
              local vehicleData = {model = model.key, config = config.key, paintName = randomizePaint and "(Random)"}
              if performanceIndexTarget and classData.performanceIndex then
                local distance = math.abs(classData.performanceIndex - performanceIndexTarget)
                table.insert(closestCandidates, {distance = distance, data = vehicleData})
                if distance <= performanceIndexWindow then
                  table.insert(group.data, vehicleData)
                end
              else
                table.insert(group.data, vehicleData)
              end
            end
          end
        end
      end
    end
  end

  if performanceIndexTarget and not group.data[1] and closestCandidates[1] then
    table.sort(closestCandidates, function(a, b) return a.distance < b.distance end)
    for i = 1, math.min(10, #closestCandidates) do
      table.insert(group.data, closestCandidates[i].data)
    end
  end

  if not group.data[1] then -- this should not be possible, but provides a failsafe anyways
    table.insert(group.data, {model = 'midsize', paintName = randomizePaint and "(Random)"})
  end

  -- the code below shuffles the group, but prevents same consecutive models in the group data array
  group.data = arrayShuffle(group.data)

  if smartShuffle then
    local groupModels, groupModelsToConfigs = {}, {}
    for _, v in ipairs(group.data) do
      if not groupModelsToConfigs[v.model] then
        groupModelsToConfigs[v.model] = {}
        table.insert(groupModels, v.model)
      end
      table.insert(groupModelsToConfigs[v.model], v)
    end

    local newGroupData = {}
    repeat -- repeats until groupModelsToConfigs is empty
      for _, model in ipairs(groupModels) do
        if groupModelsToConfigs[model][1] then
          local data = table.remove(groupModelsToConfigs[model], 1)
          table.insert(newGroupData, data)
        end
      end
    until #newGroupData == #group.data

    group.data = newGroupData
  end

  return group
end

M.getAggressionMultiplier = getAggressionMultiplier
M.generateGroup = generateGroup

return M