-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

C.name = 'Random Time of Day'
C.icon = "simobject_timeofday"
C.description = "Generates a random time of day between two specified hours."
C.category = 'repeat_instant'

C.pinSchema = {
  { dir = 'in', type = 'number', name = 'fromHour', default = 9, hardcoded = true, description = "Starting hour (0-23)." },
  { dir = 'in', type = 'number', name = 'toHour', default = 17, hardcoded = true, description = "Ending hour (0-23)." },
  { dir = 'in', type = 'bool', name = 'use24Hour', default = false, hardcoded = true, description = "If true, formats time as 24-hour clock (HH:MM). If false, formats as 12-hour clock with AM/PM." },
  { dir = 'out', type = 'number', name = 'time', description = "Time of day on a scale from 0 to 1. 0.5 is midnight." },
  { dir = 'out', type = 'string', name = 'timeString', description = "Time formatted as HH:MM (24-hour) or HH:MM AM/PM (12-hour)." }
}

C.tags = {'environment', 'tod', 'random'}

-- Convert hour (0-23) to time of day (0-1, where 0.5 is midnight)
local function hourToTimeOfDay(hour)
  return (hour / 24 + 0.5) % 1
end

-- Convert time of day (0-1) back to hour and minute
local function timeOfDayToHourMinute(timeOfDay)
  local hourDecimal = (timeOfDay - 0.5) * 24
  if hourDecimal < 0 then hourDecimal = hourDecimal + 24 end
  hourDecimal = hourDecimal % 24

  local hour = math.floor(hourDecimal)
  local minute = math.floor((hourDecimal - hour) * 60)
  return hour, minute
end

-- Format time as HH:MM (24-hour) or HH:MM AM/PM (12-hour)
local function formatTime(hour, minute, use24Hour)
  if use24Hour then
    return string.format("%02d:%02d", hour, minute)
  else
    local hour12 = hour % 12
    if hour12 == 0 then hour12 = 12 end
    local ampm = hour < 12 and "AM" or "PM"
    return string.format("%d:%02d %s", hour12, minute, ampm)
  end
end

function C:postInit()
  self.pinInLocal.fromHour.numericSetup = {
    min = 0,
    max = 23,
    type = 'int',
    gizmo = 'slider',
  }

  self.pinInLocal.toHour.numericSetup = {
    min = 0,
    max = 23,
    type = 'int',
    gizmo = 'slider',
  }
end

function C:work()
  local fromHour = math.floor(self.pinIn.fromHour.value or 9)
  local toHour = math.floor(self.pinIn.toHour.value or 17)

  -- Clamp hours to valid range
  fromHour = math.max(0, math.min(23, fromHour))
  toHour = math.max(0, math.min(23, toHour))

  -- Convert hours to time of day values
  local fromTime = hourToTimeOfDay(fromHour)
  local toTime = hourToTimeOfDay(toHour)

  -- Generate random time between the two times
  local randomTime
  if fromTime <= toTime then
    -- Normal case: fromTime to toTime
    randomTime = fromTime + math.random() * (toTime - fromTime)
  else
    -- Wrap-around case: e.g., 22 to 2 hours
    -- Split into two ranges: [fromTime, 1) and [0, toTime]
    local range1 = 1 - fromTime
    local range2 = toTime
    local totalRange = range1 + range2
    local random = math.random() * totalRange

    if random < range1 then
      randomTime = fromTime + random
    else
      randomTime = random - range1
    end
  end
  randomTime = randomTime % 1

  -- Convert back to hour and minute for formatting
  local randomHour, randomMinute = timeOfDayToHourMinute(randomTime)
  local use24Hour = self.pinIn.use24Hour.value or false

  -- Output values
  self.pinOut.time.value = randomTime
  self.pinOut.timeString.value = formatTime(randomHour, randomMinute, use24Hour)
end

return _flowgraph_createNode(C)

