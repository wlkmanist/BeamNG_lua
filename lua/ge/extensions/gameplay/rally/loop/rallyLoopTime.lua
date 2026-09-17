-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = ''

M.key = 'rallyLoopTime'
M.defaultValue = '__rallyLoopTimeDefault'
M.nowValue = '__rallyLoopTimeNow'

local labelKey = 'missions.missions.rallyLoop.userSettings.loopTime'
local defaultOptionLabel = 'ui.common.default'
local nowOptionLabel = 'missions.missions.rallyLoop.userSettings.loopTimeNow'

-- Progression scale applied to authored (CSV) start times so the day advances
-- during the loop. missionManager computes dayLength = base / timeScale, so this
-- reproduces the previous feel (base 1800 / (7/36) ~= 9257s day length).
local progressionTimeScale = 7 / 36

-- Sensible default: static core-daylight time (noon) with play=false, for perf.
-- Raw tod.time is offset by half a day vs the wall clock, so noon = 0.
local defaultTime = 0

-- Parse a single "HH:MM" (24h) clock string into a raw tod.time value in [0,1).
-- Inverse of the editor's todToTime: time = (clockFraction - 0.5) % 1.
local function parseTime(clock)
  if type(clock) ~= 'string' then return nil end
  local h, m = clock:match('^(%d%d?):(%d%d)$')
  if not h then return nil end
  h, m = tonumber(h), tonumber(m)
  if not h or not m or h > 23 or m > 59 then return nil end
  local clockFraction = (h * 3600 + m * 60) / 86400
  return (clockFraction - 0.5) % 1
end

-- Parse a comma-separated list of "HH:MM" times, skipping invalid entries.
local function parseTimes(str)
  local result = {}
  if type(str) ~= 'string' then return result end
  for entry in string.gmatch(str, '[^,]+') do
    local clock = entry:match('^%s*(.-)%s*$')
    local time = parseTime(clock)
    if time ~= nil then
      table.insert(result, { clock = clock, time = time })
    end
  end
  return result
end
M.parseTimes = parseTimes

-- Build the single player-facing "Loop Time" select. Order: Default, Now, then
-- each authored CSV start time (labeled by its clock string).
function M.buildMissionSetting(missionTypeData)
  local values = {
    { l = defaultOptionLabel, v = M.defaultValue },
    { l = nowOptionLabel, v = M.nowValue },
  }
  local loopTimes = missionTypeData and missionTypeData.loopTimes
  for _, entry in ipairs(parseTimes(loopTimes)) do
    -- Use the clock STRING as the value (not the float time) so it round-trips
    -- through the UI exactly; a float can drift and break the currentOption match.
    table.insert(values, { l = entry.clock, v = entry.clock })
  end
  return {
    key = M.key,
    label = labelKey,
    type = 'select',
    values = values,
    value = M.defaultValue,
    defaultValue = M.defaultValue,
    currentOption = values[1],
  }
end

-- Map the chosen option into the environment setup module so the battle-tested
-- missionManager code applies and restores the time-of-day. This only touches
-- time-related fields; authored weather is preserved (nil weather fields are
-- zero-filled purely for nil-safety so missionManager's setters don't error).
function M.applyToEnvironment(environment, selectedValue)
  if type(environment) ~= 'table' then return end

  if selectedValue == M.nowValue then
    -- Full passthrough: disable the env module so missionManager applies nothing
    -- and the current freeroam time, play, dayLength AND weather are left as-is.
    environment.enabled = false
    environment._rallyForceStatic = false
    return
  end

  environment.enabled = true

  if selectedValue == nil or selectedValue == M.defaultValue then
    -- static core-daylight, play forced off later via setPlaying
    environment.time = defaultTime
    environment.timeScale = 0
    environment._rallyForceStatic = true
  else
    -- authored CSV start time (a "HH:MM" clock string), with progression enabled
    environment.time = parseTime(selectedValue) or defaultTime
    environment.timeScale = progressionTimeScale
    environment._rallyForceStatic = false
  end
  environment.normalizedTime = nil

  -- Preserve weather: keep any author-configured values, and for fields the author
  -- did NOT set, fill in the current freeroam weather so missionManager re-applies
  -- the same state (no visible change) instead of clearing it to zero.
  if environment.cloudCover == nil then
    environment.cloudCover = (core_environment.getCloudCover and core_environment.getCloudCover()) or 0
  end
  if environment.cloudWindSpeed == nil then
    environment.cloudWindSpeed = (core_environment.getWindSpeed and core_environment.getWindSpeed()) or 0
  end
  if environment.fogDensity == nil then
    environment.fogDensity = (core_environment.getFogDensity and core_environment.getFogDensity()) or 0
  end
  -- windSpeed drives an explicit wind override; leave it at 0 so freeroam wind is untouched.
  if environment.windSpeed == nil then environment.windSpeed = 0 end
  if environment.windDirAngle == nil then environment.windDirAngle = 0 end
end

-- Force the time-of-day play state. Used to guarantee play=false for the static
-- Default option after missionManager has applied the environment. An optional
-- time can be supplied to snap the clock back (Default may drift slightly during
-- the brief window before this runs). IMPORTANT: only send the fields we want to
-- change - passing a full getTimeOfDay() table (with startTime/date fields) fails
-- to actually stop the clock.
function M.setPlaying(play, time)
  if not core_environment or not core_environment.setTimeOfDay then
    log('W', logTag, 'Could not set rally loop play state, core_environment is unavailable')
    return false
  end

  local tod = { play = play and true or false }
  if time ~= nil then tod.time = time end
  core_environment.setTimeOfDay(tod)

  return true
end

-- Apply today's real-world date to the sky (drives sun/moon/star position) while
-- leaving the current time-of-day untouched. Only send the date fields.
function M.applyCurrentDate()
  if not core_environment or not core_environment.setTimeOfDay then
    log('W', logTag, 'Could not set rally loop date, core_environment is unavailable')
    return false
  end

  local today = os.date('*t')
  if type(today) ~= 'table' then return false end

  core_environment.setTimeOfDay({ year = today.year, month = today.month, day = today.day })
  return true
end

function M.advancePlayingTime(seconds)
  seconds = tonumber(seconds) or 0
  if seconds <= 0 then
    return false
  end

  if not core_environment or not core_environment.getTimeOfDay or not core_environment.setTimeOfDay then
    log('W', logTag, 'Could not advance rally loop time, core_environment is unavailable')
    return false
  end

  local tod = core_environment.getTimeOfDay()
  if not tod or tod.play ~= true then
    return false
  end

  local currentTime = tonumber(tod.time)
  local currentDayLength = tonumber(tod.dayLength)
  if not currentTime or not currentDayLength or currentDayLength <= 0 then
    return false
  end

  -- Only send the field we're changing; a full getTimeOfDay() table is unreliable.
  local newTime = (currentTime + (seconds / currentDayLength)) % 1
  core_environment.setTimeOfDay({ time = newTime })

  return true
end

return M
