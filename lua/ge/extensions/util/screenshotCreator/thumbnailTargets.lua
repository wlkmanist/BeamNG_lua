-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"core_vehicles", "util_screenshotCreator_shippedConfigs"}

local function normalizeConfigName(partConfig)
  if type(partConfig) ~= "string" or not partConfig:match("%.pc$") then return nil end
  local name = partConfig:gsub("\\", "/"):match("([^/]+)$") or partConfig
  name = name:gsub("%.pc$", "")
  return name ~= "" and name or nil
end

local function getConfigData(modelKey, configName)
  local modelData = core_vehicles.getModel(modelKey)
  local configs = modelData and modelData.configs or {}
  for _, configData in pairs(configs) do
    if configData.key == configName then return configData end
  end
end

local function isDefaultConfig(modelKey, configName, configData)
  local modelData = core_vehicles.getModel(modelKey)
  local defaultConfig = modelData and modelData.model and modelData.model.default_pc
  return (configData and configData.is_default_config == true) or configName == defaultConfig
end

local function sanitizeTargets(targets)
  if targets == nil then return nil end
  if type(targets) ~= "table" or #targets == 0 or #targets > 2000 then
    return nil, "Invalid capture target list"
  end
  local result = {}
  local seen = {}
  for index, target in ipairs(targets) do
    local model = type(target) == "table" and target.model or nil
    local config = type(target) == "table" and target.config or nil
    if type(model) ~= "string" or model == "" or #model > 128
      or type(config) ~= "string" or config == "" or #config > 128
    then
      return nil, "Invalid capture target at index " .. tostring(index)
    end
    local key = model .. "\0" .. config
    if not seen[key] then
      seen[key] = true
      result[#result + 1] = {model = model, config = config}
    end
  end
  return result
end

local function buildExplicitWorkItems(targets)
  local items = {}
  for _, target in ipairs(targets) do
    local configData = getConfigData(target.model, target.config)
    if not configData then
      return nil, "Unknown vehicle config: " .. tostring(target.model) .. "/" .. tostring(target.config)
    end
    items[#items + 1] = {
      modelName = target.model,
      modelKey = configData.model_key or target.model,
      configName = target.config,
      isDefaultConfig = isDefaultConfig(target.model, target.config, configData)
    }
  end
  return items
end

local function buildModelCatalog()
  local models = {}
  local modelList = core_vehicles.getModelList()
  for modelKey, model in pairs(modelList and modelList.models or {}) do
    local modelData = core_vehicles.getModel(modelKey)
    local defaultConfig = modelData and modelData.model and modelData.model.default_pc
    local configs = {}
    for _, config in pairs(modelData and modelData.configs or {}) do
      configs[#configs + 1] = {
        key = config.key,
        label = tostring(config.Name or config.Configuration or config.key),
        isDefault = config.is_default_config == true or config.key == defaultConfig,
        shipped = util_screenshotCreator_shippedConfigs.isConfigShipped(modelKey, config.key)
      }
    end
    table.sort(configs, function(a, b) return a.label < b.label end)
    if #configs > 0 then
      models[#models + 1] = {
        key = modelKey,
        label = tostring(((model.Brand and model.Brand .. " ") or "") .. (model.Name or modelKey)),
        category = model.Type,
        configs = configs
      }
    end
  end
  table.sort(models, function(a, b) return a.label < b.label end)
  return models
end

local function buildShippedTargets(modelKeys)
  local targets = {}
  for _, modelKey in ipairs(modelKeys) do
    local modelData = core_vehicles.getModel(modelKey)
    for _, config in pairs(modelData and modelData.configs or {}) do
      if util_screenshotCreator_shippedConfigs.isConfigShipped(modelKey, config.key) then
        targets[#targets + 1] = {model = modelKey, config = config.key}
      end
    end
  end
  return targets
end

local function resolveStartMessage(message)
  message = type(message) == "table" and message or {}
  local targets, targetError = sanitizeTargets(message.targets)
  if targetError then return nil, targetError end
  if targets then return buildExplicitWorkItems(targets) end
  local vehicle = getPlayerVehicle(0)
  if not vehicle then return nil, "A player vehicle is required as the capture anchor" end
  local configName = normalizeConfigName(vehicle.partConfig)
  if not configName then return nil, "The current player vehicle must use a named .pc configuration" end
  return buildExplicitWorkItems({{model = vehicle.jbeam, config = configName}})
end

M.normalizeConfigName = normalizeConfigName
M.getConfigData = getConfigData
M.isDefaultConfig = isDefaultConfig
M.sanitizeTargets = sanitizeTargets
M.buildExplicitWorkItems = buildExplicitWorkItems
M.buildModelCatalog = buildModelCatalog
M.buildShippedTargets = buildShippedTargets
M.resolveStartMessage = resolveStartMessage

return M
