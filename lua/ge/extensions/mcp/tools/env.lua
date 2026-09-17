-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Environment tools: time of day (and lighting).

local M = {}

function M.get_time_of_day()
  if not (core_environment and core_environment.getTimeOfDay) then return "core_environment unavailable (in a level?)", true end
  return jsonEncode(core_environment.getTimeOfDay() or {}), false
end

-- Set time of day and astronomical location/date fields.
function M.set_time_of_day(args)
  args = args or {}
  if not (core_environment and core_environment.setTimeOfDay) then return "core_environment unavailable (in a level?)", true end
  local tod = core_environment.getTimeOfDay() or {}
  if args.time ~= nil then tod.time = tonumber(args.time) end
  if args.play ~= nil then tod.play = args.play end
  if args.dayLength ~= nil then tod.dayLength = tonumber(args.dayLength) end
  if args.startTime ~= nil then tod.startTime = tonumber(args.startTime) end
  if args.latitude ~= nil then tod.latitude = tonumber(args.latitude) end
  if args.longitude ~= nil then tod.longitude = tonumber(args.longitude) end
  if args.year ~= nil then tod.year = tonumber(args.year) end
  if args.month ~= nil then tod.month = tonumber(args.month) end
  if args.day ~= nil then tod.day = tonumber(args.day) end
  if args.utcOffset ~= nil then tod.utcOffset = tonumber(args.utcOffset) end
  if args.dstRule ~= nil then tod.dstRule = tostring(args.dstRule) end
  if args.celestialProfile ~= nil then tod.celestialProfile = tostring(args.celestialProfile) end
  core_environment.setTimeOfDay(tod)
  return "time of day set: time=" .. tostring(tod.time), false
end

M.schemas = {
  get_time_of_day = { description = "Get time of day as JSON: time (0..1), play, dayLength, startTime, latitude, longitude, date, utcOffset, dstRule, celestialProfile." },
  set_time_of_day = {
    description = "Set time of day and astronomical sky fields. time is 0..1 (0/1 = midnight, 0.5 = noon).",
    inputSchema = { type = "object", properties = {
      time = { type = "number", description = "0..1 (0/1 = midnight, 0.5 = noon)" },
      play = { type = "boolean", description = "Whether time advances" },
      dayLength = { type = "number", description = "Full day-night cycle length in real seconds" },
      startTime = { type = "number", description = "Initial time of day for the level" },
      latitude = { type = "number", description = "Observer latitude in degrees north" },
      longitude = { type = "number", description = "Observer longitude in degrees east" },
      year = { type = "number", description = "UTC calendar year" },
      month = { type = "number", description = "UTC calendar month, 1-12" },
      day = { type = "number", description = "UTC calendar day of month, 1-31" },
      utcOffset = { type = "number", description = "Exact UTC offset in hours, including DST when applicable" },
      dstRule = { type = "string", description = "DST rule: auto, eu, us, au, or none" },
      celestialProfile = { type = "string", description = "Celestial profile name or path" },
    } },
  },
}

return M
