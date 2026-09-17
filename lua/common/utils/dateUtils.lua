-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Function to parse ISO 8601 date-time string
local function parseIso8601(datetime)
  local pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z"
  local year, month, day, hour, min, sec = datetime:match(pattern)
  if year == nil then -- fallback for broken formatting using %X
    pattern = "(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%s([AP])MZ"
    local ap
    year, month, day, hour, min, sec, ap = datetime:match(pattern)
    if year ~= nil then
      if ap == "A" and hour == "12" then hour = 0 end
      if ap == "P" and hour ~= "12" then hour = tonumber(hour) + 12 end
    end
  end
  if year == nil then
    log('E', 'parseIso8601', string.format('Cannot parse datetime \'%s\'. Using current time instead.', datetime))
    return os.time()
  end

  -- Convert to Unix timestamp
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
    isdst = false
  })
end

-- Function to calculate time difference
local function timeSince(datetime)
  local past = parseIso8601(datetime)
  local now = os.time(os.date("!*t"))
  local diff = os.difftime(now, past)
  return diff
end

M.parseIso8601 = parseIso8601
M.timeSince = timeSince

return M
