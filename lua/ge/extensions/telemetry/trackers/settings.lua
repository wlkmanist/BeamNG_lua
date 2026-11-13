-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY SETTINGS TRACKER

  Records the declared game settings, so framerate and crash numbers can be read against
  what the player actually asked the game to do.

  It reports declared game settings except local addresses, paths, and user-authored
  lists or presets. A change is reported on the next start, and an unchanged set is resent
  every surveyIntervalHours.

  The survey we last sent is kept. Its modification time is when it went out, and the
  fingerprint in it is what a change is recognized against.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local defaultSurveyIntervalHours = 24 * 7
local surveyFile = extensions.telemetry_core.getDataFolder() .. "surveys/settingsSurvey.json"
local sbuffer = require('string.buffer')

local unreportedSettings = {
  IngameConsoleLogBlacklist = true,
  IngameConsoleLogWhitelist = true,
  WinConsoleLogBlacklist = true,
  WinConsoleLogWhitelist = true,
  mpCustomServiceURL = true,
  protocols_motionSim_address = true,
  protocols_outgauge_address = true,
  rallyCodriverVoicepackMRU = true,
  shaderGenCachePath = true,
  userColorPresets = true,
  userPaintPresets = true,
}

local function collectSettings()
  local declared = settings.impl and settings.impl.defaults
  if not declared then return nil end

  local reported = {}
  local defaults = {}
  local defaultValues = settings.impl.defaultValues or {}
  for key in pairs(declared) do
    if not unreportedSettings[key] then
      local value = settings.getValue(key)
      if value ~= nil then
        reported[key] = value
      end
      if defaultValues[key] ~= nil then
        defaults[key] = defaultValues[key]
      end
    end
  end
  return reported, defaults
end

local function appendCanonical(buffer, value)
  if type(value) ~= "table" then
    buffer:put(jsonEncode(value))
    return
  end

  local keys = {}
  for key in pairs(value) do
    table.insert(keys, key)
  end
  table.sort(keys, function(a, b)
    local typeA, typeB = type(a), type(b)
    if typeA == typeB then return tostring(a) < tostring(b) end
    return typeA < typeB
  end)

  buffer:put("{")
  for _, key in ipairs(keys) do
    appendCanonical(buffer, key)
    buffer:put(":")
    appendCanonical(buffer, value[key])
    buffer:put(",")
  end
  buffer:put("}")
end

-- pairs() does not promise an order, including for tables nested in a setting.
local function settingsFingerprint(reported)
  local buffer = sbuffer.new()
  appendCanonical(buffer, reported)
  return hashStringSHA256(tostring(buffer))
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")

  local reported, defaults = collectSettings()
  if not reported then return end

  local fingerprint = settingsFingerprint({settings = reported, defaults = defaults})
  local hours = extensions.telemetry_configManager.getSurveyIntervalHours(
    'settings', defaultSurveyIntervalHours)
  local stat = FS:stat(surveyFile)
  local delivered = stat and stat.modtime
  if delivered and delivered > os.time() - hours * 60 * 60 then
    -- inside the interval, so only changed settings are still worth sending. The stored
    -- fingerprint is compared rather than one recomputed from the stored values, which a
    -- json round trip could change on its own by rewriting a number.
    local sent = jsonReadFile(surveyFile)
    if sent and sent.fingerprint == fingerprint then return end
  end

  local survey = {
    name = "settings",
    surveyVersion = 2,
    settings = reported,
    defaults = defaults,
  }
  -- only kept once it is in the report. Keeping a dropped survey would silence this
  -- machine for a whole interval over data that was never sent.
  if extensions.telemetry_core.addEvent(survey) then
    jsonWriteFile(surveyFile, {fingerprint = fingerprint, settings = reported}, true)
  end
end

M.onExtensionLoaded = onExtensionLoaded

return M
