-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.path = '/settings/'
M.pathDefaults = M.path..'defaults.json'
M.pathDeprecated = M.path..'deprecated.json'
M.pathInternal = M.path..'not-shipping.internal.json'
M.pathLocal = M.path..'settings.json'
M.pathCloud = M.path..'cloud/settings.json'
M.pathVariables = M.path..'game-settings.json'
M.pathPersona = M.path..'persona-settings.tmp.json'
M.deprecatedPathTorquescript = M.path..'game-settings.cs'

M.defaults = jsonReadFile(M.pathDefaults) or {}
M.deprecated = jsonReadFile(M.pathDeprecated) or {}
M.personaScopedSettings = {
  defaultGearboxBehavior = true,
  autoClutch = true,
  autoThrottle = true,
  spawnVehicleIgnitionLevel = true,
  playerCharacterFace = true,
}

-- check if a setting has been deprecated or replaced, and return the new version when possible
local function upgradeSetting(setting)
  if setting == nil then
    log('E', '', "Cannot parse null setting")
    return
  end
  if M.defaults[setting] == nil then
    if M.deprecated[setting] == nil then
      if vmType == 'game' then
        log('W', '', "Unrecognized setting name \""..setting.."\" (not defined in defaults file: "..dumps(M.pathDefaults)..")")
      end
      return
    end

    if M.deprecated[setting]["replacement"] ~= nil then
      if vmType == 'game' then
        log('D', '', "Replacing deprecated setting "..setting.." with new setting "..M.deprecated[setting]["replacement"]);
      end
      return upgradeSetting(M.deprecated[setting]["replacement"])
    end
    if M.deprecated[setting]["obsolete"] == true then
      if vmType == 'game' then
        log('D', '', "Ignoring deprecated setting: "..setting)
      end
      return
    end
    log('E', '', "Couldn't process deprecated setting "..setting..": "..dumps(M.deprecated[setting]))
    return
  end
  return setting
end

-- takes care of updating renamed settings, deprecated settings, etc
local function upgradeSettings(settings)
  local result = {}
  for originalSetting,v in pairs(settings) do
    local setting = upgradeSetting(originalSetting)
    if setting then
      result[setting] = v
    else
      result[originalSetting] = v
    end
  end
  return result
end

local unitPresets = {
  imperial = {
    uiUnits = "imperial",
    uiUnitLength = "imperial",
    uiUnitTemperature = "f",
    uiUnitWeight = "lb",
    uiUnitConsumptionRate = "imperial",
    uiUnitTorque = "imperial",
    uiUnitEnergy = "imperial",
    uiUnitDate = "us",
    uiUnitPower = "bhp",
    uiUnitVolume = "gal",
    uiUnitPressure = "psi",
  },
  metric = {
    uiUnits = "metric",
    uiUnitLength = "metric",
    uiUnitTemperature = "c",
    uiUnitWeight = "kg",
    uiUnitConsumptionRate = "metric",
    uiUnitTorque = "metric",
    uiUnitEnergy = "metric",
    uiUnitDate = "ger",
    uiUnitPower = "hp",
    uiUnitVolume = "l",
    uiUnitPressure = "bar",
  },
  british = {
    uiUnits = "british",
    uiUnitLength = "imperial",
    uiUnitTemperature = "c",
    uiUnitWeight = "kg",
    uiUnitConsumptionRate = "imperial",
    uiUnitTorque = "imperial",
    uiUnitEnergy = "imperial",
    uiUnitDate = "uk",
    uiUnitPower = "bhp",
    uiUnitVolume = "l",
    uiUnitPressure = "inHg",
  },
}

-- Saved settings are merged later, so this only supplies the locale-based default.
local osLanguage = Lua and Lua.getOSLanguage and Lua:getOSLanguage() or ""
local language, region = osLanguage:gsub("-", "_"):match("^([^_]+)_?([^_]*)")
language = string.lower(language or "")
region = string.upper(region or "")
local unitPreset = region == "US" and unitPresets.imperial
  or (region == "GB" or region == "UK") and unitPresets.british
  or (language == "en" and region == "") and unitPresets.imperial
  or unitPresets.metric
for key, value in pairs(unitPreset) do
  if M.defaults[key] then
    M.defaults[key][2] = value
  end
end

if not shipping_build then
   if FS:fileExists(M.pathInternal) then
    local internalValues = jsonReadFile(M.pathInternal) or {}
    M.internalValues = upgradeSettings(internalValues)
    for k,v in pairs(M.internalValues) do
      local definition = M.defaults[k]
      if definition then
        definition[2] = v
      end
    end
  end
end

-- enforce some options if we are running on a known platform like steamdeck
local platform = Engine and Engine.Platform and Engine.Platform.getPlatform() or ""
local platformPreset = Engine and Engine.Platform and Engine.Platform.getPlatformPreset() or nil
local pathPlatform = platformPreset == nil and (M.path..platform..".json") or (M.path..platform.."_"..platformPreset..".json")
log("D", "", string.format("Checking for existence of platform-specific settings (platform='%s', path='%s')...", platform, pathPlatform))
if FS:fileExists(pathPlatform) then
  local platformValues = jsonReadFile(pathPlatform) or {}
  platformValues = upgradeSettings(platformValues)
  log("D", "", string.format("Found %i platform-specific settings (platform='%s', path='%s')", tableSize(platformValues), platform, pathPlatform))
  for k,v in pairs(platformValues) do
    local definition = M.defaults[k]
    if definition then
      log("D", "", string.format("Applied '%s' platform-specific setting '%s'='%s'", platform, k, dumps(v)))
      definition[2] = v
    else
      log("E", "", string.format("Unable to apply platform-specific (%s) setting '%s'='%s' that is not defined in the defaults file: '%s'", platform, k, dumps(v), M.pathDefaults))
    end
  end
end

-- Override the default before saved values are merged, so an explicitly saved 1.0 remains valid.
if Engine and Engine.UI and Engine.UI.isSimpleMenu and Engine.UI.isSimpleMenu() and M.defaults.uiContentScale then
  M.defaults.uiContentScale[2] = 1.05
end

-- precompute default values
M.defaultValues = {}
for k,v in pairs(M.defaults) do
  M.defaultValues[k] = v[2]
end

local valuesCache = nil
local personaValuesCache = nil
local personaFallbackValues = {}
local personaFallbackInitialized = {}

local function normalizePersona(persona)
  if type(persona) == "table" then
    persona = persona.id
  end
  if persona == nil then return nil end
  persona = tostring(persona)
  if persona == "" then return nil end
  return persona
end

local function getValues()
  if not valuesCache then
    local values = deepcopy(M.defaultValues)
    local cloudValues = jsonReadFile(M.pathCloud) or {}
    local localValues = jsonReadFile(M.pathLocal) or {}

    values = upgradeSettings(values)
    cloudValues = upgradeSettings(cloudValues)
    localValues = upgradeSettings(localValues)

    tableMerge(values, cloudValues)
    tableMerge(values, localValues)
    if CppSettings then
      for k,value in pairs(values) do
        if CppSettings[k] ~= nil then
          -- we have C++ type information
          if type(CppSettings[k]) ~= type(value) then
            log("E", "", string.format("Unable to parse setting '%s': it should be a %s, but is a %s. The ignored value is: %s", k, type(CppSettings[k]), type(value), dumps(value)))
            values[k] = nil
          end
        end
      end
    end
    valuesCache = values
  end
  return valuesCache
end

local function getPersonaValues()
  if not personaValuesCache then
    personaValuesCache = jsonReadFile(M.pathPersona) or {}
  end
  return personaValuesCache
end

local function getPersonaValue(key, fallbackValue, persona)
  local personaId = normalizePersona(persona)
  if not M.personaScopedSettings[key] then return fallbackValue end
  if not personaId or personaId == "" then
    --log("I","", string.format("Getting persona value for %s for persona: %s: no persona id, fallback value %s", key, dumps(personaId), dumps(fallbackValue)))
    return fallbackValue
  end

  local personaValues = getPersonaValues()[personaId]
  if personaValues and personaValues[key] ~= nil then
    --log("I","", string.format("Getting persona value for %s for persona: %s: stored value %s", key, dumps(personaId), dumps(personaValues[key])))
    return personaValues[key]
  end

  personaFallbackValues[personaId] = personaFallbackValues[personaId] or {}
  personaFallbackInitialized[personaId] = personaFallbackInitialized[personaId] or {}
  if not personaFallbackInitialized[personaId][key] then
    personaFallbackValues[personaId][key] = fallbackValue
    personaFallbackInitialized[personaId][key] = true
  end
  --log("I","", string.format("Getting persona fallback value for %s for persona: %s: fallback value %s", key, dumps(personaId), dumps(personaFallbackValues[personaId][key])))
  return personaFallbackValues[personaId][key]
end

-- will return 'defaultValue' when the value does not exist or is nil
local function getValue(key, defaultValue, persona)
  local value = getValues()[key]
  if value == nil then
    value = defaultValue
  end
  return getPersonaValue(key, value, persona)
end

local function invalidatePersonaCache()
  personaValuesCache = nil
end

local function invalidateCache()
  valuesCache = nil
  invalidatePersonaCache()
end

M.getValue = getValue
M.getValues = getValues
M.getPersonaValue = getPersonaValue
M.invalidatePersonaCache = invalidatePersonaCache
M.refresh = invalidateCache -- retrocompatibility
M.settingsChanged = invalidateCache
M.invalidateCache = invalidateCache

return M
