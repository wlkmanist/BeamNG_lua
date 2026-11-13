-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY MODS TRACKER

  Reports which mods are installed and active, so crashes and performance numbers can
  be told apart between modded and clean installs.

  Only mod names, types and repository ids are reported, never file paths.

  Mods change far more often than hardware, so an unchanged list is only resent every
  surveyIntervalHours, while a changed list is reported on the next start.

  The survey we last sent is kept. Its modification time is when it went out, and the list
  in it is what a changed list is recognized against.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local defaultSurveyIntervalHours = 24 * 7
local surveyFile = extensions.telemetry_core.getDataFolder() .. "surveys/modSurvey.json"

local surveyed = false

local function collectMods()
  local installed = {}
  for modname, mod in pairs(core_modmanager.getMods()) do
    table.insert(installed, {
      name = modname,
      modID = mod.modID, -- missing when the mod did not come from the repository
      modType = mod.modType,
      active = mod.active and true or false,
      unpacked = mod.stat ~= nil and mod.stat.filetype == "dir",
    })
  end

  -- sorted so the fingerprint does not depend on the order pairs() happened to use
  table.sort(installed, function(a, b) return a.name < b.name end)
  return installed
end

-- Identifies the set of mods and whether each is on, so we can tell a real change from
-- the same list being reported again. collectMods already sorted the list by name.
local function modFingerprint(installed)
  local rows = {}
  for _, mod in ipairs(installed) do
    table.insert(rows, {mod.name, mod.active})
  end
  return hashStringSHA256(jsonEncode(rows))
end

-- The mod database is only filled once the mod manager is up, which is well after
-- telemetry starts, so the survey cannot happen in onExtensionLoaded
local function onModManagerReady()
  if surveyed then return end
  surveyed = true

  local installed = collectMods()
  local hours = extensions.telemetry_configManager.getSurveyIntervalHours(
    'mods', defaultSurveyIntervalHours)
  local stat = FS:stat(surveyFile)
  local delivered = stat and stat.modtime
  if delivered and delivered > os.time() - hours * 60 * 60 then
    -- inside the interval, so only a changed list is still worth sending
    local sent = jsonReadFile(surveyFile)
    if sent and modFingerprint(sent.mods or {}) == modFingerprint(installed) then return end
  end

  local survey = {
    name = "modSurvey",
    counts = core_modmanager.getStats(),
    mods = installed,
  }
  -- only kept once it is in the report. Keeping a dropped survey would silence this
  -- machine for a whole interval over data that was never sent.
  if extensions.telemetry_core.addEvent(survey) then
    jsonWriteFile(surveyFile, survey, true)
  end
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onModManagerReady = onModManagerReady

return M
