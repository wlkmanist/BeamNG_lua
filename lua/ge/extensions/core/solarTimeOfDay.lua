local M = {}

local RAD = math.pi / 180
local MINUTES_PER_DAY = 1440

local function isFinite(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function toFiniteNumber(value)
  local number = tonumber(value)
  return isFinite(number) and number or nil
end

local function mod(a, m)
  return ((a % m) + m) % m
end

local function round(value)
  return math.floor(value + 0.5)
end

local function normalizeMinutes(minutes)
  minutes = toFiniteNumber(minutes)
  if not minutes then return nil end
  return mod(round(minutes), MINUTES_PER_DAY)
end

local function timeFromMinutes(minutes)
  local normalizedMinutes = normalizeMinutes(minutes)
  if not normalizedMinutes then return nil end
  return mod(normalizedMinutes / MINUTES_PER_DAY - 0.5, 1)
end

local function minutesBetween(startMinutes, endMinutes)
  return mod(endMinutes - startMinutes, MINUTES_PER_DAY)
end

local function interpolateMinutes(startMinutes, endMinutes, fraction)
  return normalizeMinutes(startMinutes + minutesBetween(startMinutes, endMinutes) * fraction)
end

local function timeFromNormalizedTimeUsingNoon(normalizedTime, noonMinutes)
  return timeFromMinutes(noonMinutes + normalizedTime * MINUTES_PER_DAY)
end

local function julianDay(year, month, day)
  local a = math.floor((14 - month) / 12)
  local y = year + 4800 - a
  local m = month + 12 * a - 3
  local jdn = day + math.floor((153 * m + 2) / 5) + 365 * y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) - 32045
  return jdn - 0.5
end

local function solarDeclEqTime(year, month, day)
  local T = (julianDay(year, month, day) - 2451545.0) / 36525
  local L0 = 280.46646 + T * (36000.76983 + T * 0.0003032)
  local M = 357.52911 + T * (35999.05029 - T * 0.0001537)
  local ecc = 0.016708634 - T * (0.000042037 + T * 0.0000001267)
  local Mr = M * RAD
  local C = math.sin(Mr) * (1.914602 - T * (0.004817 + T * 0.000014)) +
    math.sin(2 * Mr) * (0.019993 - T * 0.000101) +
    math.sin(3 * Mr) * 0.000289
  local omega = (125.04 - 1934.136 * T) * RAD
  local lambda = (L0 + C - 0.00569 - 0.00478 * math.sin(omega)) * RAD
  local eps = (23 + (26 + (21.448 - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60) / 60 +
    0.00256 * math.cos(omega)) * RAD
  local decl = math.asin(math.sin(eps) * math.sin(lambda)) / RAD
  local y = math.tan(eps / 2) ^ 2
  local L0r = L0 * RAD
  local eqTime = 4 / RAD * (y * math.sin(2 * L0r) - 2 * ecc * math.sin(Mr) +
    4 * ecc * y * math.sin(Mr) * math.cos(2 * L0r) -
    0.5 * y * y * math.sin(4 * L0r) - 1.25 * ecc * ecc * math.sin(2 * Mr))
  return decl, eqTime
end

local function sunTimesUtcMinutes(year, month, day, lat, lon)
  local decl, eqTime = solarDeclEqTime(year, month, day)
  local latR = lat * RAD
  local declR = decl * RAD
  local cosH = math.cos(90.833 * RAD) / (math.cos(latR) * math.cos(declR)) - math.tan(latR) * math.tan(declR)
  local noon = 720 - 4 * lon - eqTime

  if cosH < -1 then return {sunrise = nil, noon = noon, sunset = nil, polar = "day"} end
  if cosH > 1 then return {sunrise = nil, noon = noon, sunset = nil, polar = "night"} end

  local ha = math.acos(cosH) / RAD
  return {
    sunrise = noon - 4 * ha,
    noon = noon,
    sunset = noon + 4 * ha,
    polar = nil,
  }
end

local function dow(year, month, day)
  local t = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
  local y = year
  if month < 3 then y = y - 1 end
  return mod(y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + t[month] + day, 7)
end

local function lastSunday(year, month)
  local last = (month == 4 or month == 9 or month == 11) and 30 or 31
  return last - dow(year, month, last)
end

local function firstSunday(year, month)
  return 1 + mod(7 - dow(year, month, 1), 7)
end

local function dstActive(rule, year, month, day)
  if rule == "eu" then
    if month < 3 or month > 10 then return false end
    if month > 3 and month < 10 then return true end
    return (month == 3 and day >= lastSunday(year, 3)) or (month == 10 and day < lastSunday(year, 10))
  end
  if rule == "us" then
    if month < 3 or month > 11 then return false end
    if month > 3 and month < 11 then return true end
    return (month == 3 and day >= firstSunday(year, 3) + 7) or (month == 11 and day < firstSunday(year, 11))
  end
  if rule == "au" then
    if month > 4 and month < 10 then return false end
    if month < 4 or month > 10 then return true end
    return (month == 4 and day < firstSunday(year, 4)) or (month == 10 and day >= firstSunday(year, 10))
  end
  return false
end

local function civilOffsetHours(state)
  local explicitOffset = toFiniteNumber(state and state.utcOffset)
  if explicitOffset then return explicitOffset end

  local lat = toFiniteNumber(state and state.latitude)
  local lon = toFiniteNumber(state and state.longitude)
  local year = toFiniteNumber(state and state.year)
  local month = toFiniteNumber(state and state.month)
  local day = toFiniteNumber(state and state.day)
  if not lat or not lon or not year or not month or not day then return nil end

  local rule = state.dstRule or "auto"
  if rule == "auto" then
    if lat <= -30 then
      rule = "au"
    elseif lat >= 30 then
      rule = lon > -170 and lon < -30 and "us" or "eu"
    else
      rule = "none"
    end
  end

  return math.floor(lon / 15 + 0.5) + (dstActive(rule, year, month, day) and 1 or 0)
end

local function copyOption(option, value)
  local copy = {}
  for key, optionValue in pairs(option) do
    copy[key] = optionValue
  end
  if value ~= nil then copy.value = value end
  return copy
end

function M.timeFromMinutes(minutes)
  return timeFromMinutes(minutes)
end

function M.getCivilOffsetHours(state)
  return civilOffsetHours(state)
end

function M.timeFromNormalizedTime(normalizedTime, state)
  normalizedTime = toFiniteNumber(normalizedTime)
  if not normalizedTime then return nil end
  if normalizedTime < 0 then return -1 end
  normalizedTime = mod(normalizedTime, 1)

  local events = M.getSolarTimeOfDayEvents(state)
  if not events or events.noon == nil then return normalizedTime end

  if events.sunrise == nil or events.sunset == nil then
    return timeFromNormalizedTimeUsingNoon(normalizedTime, events.noon)
  end

  local minutes
  if normalizedTime < 0.25 then
    minutes = interpolateMinutes(events.noon, events.sunset, normalizedTime / 0.25)
  elseif normalizedTime < 0.5 then
    minutes = interpolateMinutes(events.sunset, events.night, (normalizedTime - 0.25) / 0.25)
  elseif normalizedTime < 0.75 then
    minutes = interpolateMinutes(events.night, events.sunrise, (normalizedTime - 0.5) / 0.25)
  else
    minutes = interpolateMinutes(events.sunrise, events.noon, (normalizedTime - 0.75) / 0.25)
  end

  return timeFromMinutes(minutes)
end

function M.getSolarTimeOfDayEvents(state)
  local lat = toFiniteNumber(state and state.latitude)
  local lon = toFiniteNumber(state and state.longitude)
  local year = toFiniteNumber(state and state.year)
  local month = toFiniteNumber(state and state.month)
  local day = toFiniteNumber(state and state.day)
  local offset = civilOffsetHours(state)
  if not lat or not lon or not year or not month or not day or not offset then return nil end

  local utcTimes = sunTimesUtcMinutes(year, month, day, lat, lon)
  local function toLocal(minutes)
    if minutes == nil then return nil end
    return normalizeMinutes(minutes + offset * 60)
  end

  return {
    sunrise = toLocal(utcTimes.sunrise),
    noon = toLocal(utcTimes.noon),
    sunset = toLocal(utcTimes.sunset),
    night = toLocal(utcTimes.noon + MINUTES_PER_DAY / 2),
    polar = utcTimes.polar,
  }
end

function M.getSolarTimeOfDayValues(state)
  local events = M.getSolarTimeOfDayEvents(state)
  if not events then return nil end

  local values = {
    sunrise = events.sunrise,
    noon = events.noon,
    sunset = events.sunset,
    night = events.night,
  }

  if events.sunrise ~= nil and events.noon ~= nil then
    values.morning = interpolateMinutes(events.sunrise, events.noon, 1 / 3)
    values.earlyNoon = interpolateMinutes(events.sunrise, events.noon, 5 / 9)
  end

  if events.noon ~= nil and events.sunset ~= nil then
    values.lateNoon = interpolateMinutes(events.noon, events.sunset, 0.4)
    values.afternoon = interpolateMinutes(events.noon, events.sunset, 0.7)
    values.evening = interpolateMinutes(events.noon, events.sunset, 0.94)
  end

  for key, minutes in pairs(values) do
    values[key] = timeFromMinutes(minutes)
  end

  return values
end

function M.getSolarNightWindow(state)
  local events = M.getSolarTimeOfDayEvents(state)
  if not events then return nil end

  if events.sunrise == nil or events.sunset == nil then return nil end

  return timeFromMinutes(events.sunset), timeFromMinutes(events.sunrise)
end

function M.buildSolarTimeOfDayOptions(state, options)
  local events = M.getSolarTimeOfDayEvents(state)
  if events and events.polar then
    local result = {}
    local solarMidnight = timeFromMinutes(events.night)
    local solarNoon = timeFromMinutes(events.noon)
    if solarMidnight ~= nil then
      table.insert(result, {key = "solarMidnight", value = solarMidnight, label = "ui.quickrace.tod.solarMidnight"})
    end
    if solarNoon ~= nil then
      table.insert(result, {key = "solarNoon", value = solarNoon, label = "ui.quickrace.tod.solarNoon"})
    end
    return result
  end

  local values = M.getSolarTimeOfDayValues(state)
  local result = {}

  for _, option in ipairs(type(options) == "table" and options or {}) do
    local value = values and values[option.key] or nil
    table.insert(result, copyOption(option, value))
  end

  return result
end

function M.getTimeValueForKey(key, state, options)
  if type(key) ~= "string" then return nil end

  for _, option in ipairs(M.buildSolarTimeOfDayOptions(state, options)) do
    if option.key == key then
      return option.value
    end
  end
  return nil
end

return M
