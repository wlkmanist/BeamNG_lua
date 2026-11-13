-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'telemetry_userIdentity'}

local clientFacts = require("ge/extensions/telemetry/clientFacts")

local logTag = 'telemetry_config'
local configFile = '/telemetry/config.json'
local defaultConfigTTLHours = 24
-- Only used until the server answers. The reporter reads the value it sends.
local defaultReportIntervalHours = 12
local minimumTTLHours = 1 / 60
local configTTLSeconds = defaultConfigTTLHours * 3600
local configCheckIntervalSeconds = 60
local configRetryIntervalSeconds = 300
local lastConfigFetch = 0
local nextConfigFetchAttempt = 0
local configCheckTimer = 0
local telemetryVersion = "30"

local currentConfig = nil
local configApplied = nil
local disabledModuleConfig = {enabled = false}
local localModuleConfig = {enabled = true}

-- -telemetryLocal: every tracker on with its defaults, the server is never asked and
-- nothing is uploaded
local function isLocalOnly()
  return tableFindKey(Engine.getStartingArgs(), '-telemetryLocal') ~= nil
end
local pollingEnabled = false
local onUpdate
local setPollingEnabled

local function getDefaultConfig()
  return {
    enabled = false,
    ttlHours = defaultConfigTTLHours,
    reportIntervalHours = defaultReportIntervalHours,
    runIds = {},
    moduleConfigs = {}
  }
end

local function validateRunIds(ids)
  if type(ids) ~= "table" or #ids > 32 then return false end
  for _, id in ipairs(ids) do
    if type(id) ~= "string"
        or #id < 4
        or #id > 64
        or not string.match(id, "^R[A-Z0-9]+$") then
      return false
    end
  end
  return true
end

local function validateConfig(config)
  if not config or type(config.enabled) ~= "boolean" then return false end
  if not validateRunIds(config.runIds) then return false end
  if type(config.ttlHours) ~= "number"
      or config.ttlHours < minimumTTLHours
      or config.ttlHours > 168 then
    return false
  end
  if type(config.reportIntervalHours) ~= "number"
      or config.reportIntervalHours < minimumTTLHours
      or config.reportIntervalHours > 168 then
    return false
  end
  if config.moduleConfigs ~= nil and type(config.moduleConfigs) ~= "table" then
    config.moduleConfigs = {}
  end
  return true
end

local function saveCachedConfig(config)
  if not FS:directoryExists("telemetry") then
    FS:directoryCreate("telemetry")
  end

  config.lastFetchTime = os.time()
  local file = io.open(configFile, 'w')
  if file then
    file:write(jsonEncodePretty(config))
    file:close()
    log('I', logTag, "Saved telemetry configuration")
  else
    log('E', logTag, "Failed to save telemetry configuration")
  end
  return config.lastFetchTime
end

local function loadCachedConfig()
  if not FS:fileExists(configFile) then return nil end

  local content = readFile(configFile)
  if not content then return nil end
  return jsonDecode(content)
end

local function fetchConfigFromAPI(callback)
  log('I', logTag, "Fetching telemetry configuration from API")

  local function useDefaults(reason)
    log('W', logTag, reason)
    -- Preserve the last server decision during transient network failures.
    if currentConfig then return end
    if callback then callback(getDefaultConfig()) end
  end

  local context = clientFacts.collect(telemetryVersion)
  context.anonymousUserID = extensions.telemetry_userIdentity.getAnonymousUserID()

  core_online.apiCall('s11/v1/telemetryConfig', function(r)
    if r.responseData and r.responseData.config then
      local config = r.responseData.config
      if validateConfig(config) then
        lastConfigFetch = saveCachedConfig(config)
        log('I', logTag, "Telemetry configuration updated successfully")
        if callback then callback(config) end
      else
        useDefaults("Invalid configuration received from API, using defaults")
      end
    else
      useDefaults("Failed to fetch telemetry configuration, using defaults")
    end
  end, context)
end

local function applyConfiguration(config, onConfigApplied)
  if not config then return end

  currentConfig = config
  configTTLSeconds = config.ttlHours * 3600

  if onConfigApplied then
    onConfigApplied(config)
  end
end

local function checkConfigExpiry()
  local now = os.time()
  if now < nextConfigFetchAttempt then return end
  if now - lastConfigFetch < configTTLSeconds then return end

  nextConfigFetchAttempt = now + configRetryIntervalSeconds
  fetchConfigFromAPI(function(updatedConfig)
    if updatedConfig then
      applyConfiguration(updatedConfig, configApplied)
    end
  end)
end

local function getConfig()
  return currentConfig
end

local function getModuleConfig(moduleName)
  if isLocalOnly() then return localModuleConfig end
  if currentConfig and currentConfig.moduleConfigs and currentConfig.moduleConfigs[moduleName] then
    return currentConfig.moduleConfigs[moduleName]
  end
  return disabledModuleConfig
end

local function isModuleEnabled(moduleName)
  return getModuleConfig(moduleName).enabled == true
end

-- Older cached configs used days. Keep reading them until every installation has fetched
-- the hours-based server format.
local function getSurveyIntervalHours(moduleName, defaultHours)
  local config = getModuleConfig(moduleName)
  if type(config.surveyIntervalHours) == "number" then
    return config.surveyIntervalHours
  end
  if type(config.surveyIntervalDays) == "number" then
    return config.surveyIntervalDays * 24
  end
  return defaultHours
end

local function getTelemetryVersion()
  return telemetryVersion
end

local function initializeConfig(callback)
  configApplied = callback
  if isLocalOnly() then
    local config = getDefaultConfig()
    config.enabled = true
    applyConfiguration(config, callback)
    return
  end
  setPollingEnabled(true)

  local cachedConfig = loadCachedConfig()
  local cacheAge = cachedConfig and os.time() - (cachedConfig.lastFetchTime or 0)
  if cachedConfig and validateConfig(cachedConfig)
      and cacheAge < cachedConfig.ttlHours * 3600 then
    lastConfigFetch = cachedConfig.lastFetchTime or 0
    applyConfiguration(cachedConfig, callback)
  else
    lastConfigFetch = 0
    applyConfiguration(getDefaultConfig(), callback)
  end

  -- The config endpoint is unavailable until the online session authenticates.
end

local function onOnlineStateChanged(connected)
  if not pollingEnabled or not connected then return end
  checkConfigExpiry()
end

onUpdate = function(dtReal)
  configCheckTimer = configCheckTimer + dtReal
  if configCheckTimer < configCheckIntervalSeconds then return end

  configCheckTimer = 0
  if Engine.Online.isAuthenticated() then
    checkConfigExpiry()
  end
end

setPollingEnabled = function(enabled)
  enabled = enabled == true
  if pollingEnabled == enabled then return end
  pollingEnabled = enabled
  configCheckTimer = 0
  M.onUpdate = enabled and onUpdate or nil
  M.onOnlineStateChanged = enabled and onOnlineStateChanged or nil
  extensions.hookUpdate("onUpdate")
  extensions.hookUpdate("onOnlineStateChanged")
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.isLocalOnly = isLocalOnly
M.initializeConfig = initializeConfig
M.getConfig = getConfig
M.getModuleConfig = getModuleConfig
M.isModuleEnabled = isModuleEnabled
M.getSurveyIntervalHours = getSurveyIntervalHours
M.getTelemetryVersion = getTelemetryVersion
M.checkConfigExpiry = checkConfigExpiry
M.fetchConfigFromAPI = fetchConfigFromAPI
M.setPollingEnabled = setPollingEnabled
M.onExtensionLoaded = onExtensionLoaded

return M