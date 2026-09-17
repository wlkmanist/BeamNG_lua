-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Utility functions for rally loop scheduling and time calculations
local M = {}

-- Round time up to the next minute boundary (60 second intervals)
-- @param timeSecs: Time in seconds
-- @return: Time rounded up to next minute
function M.roundToNextMinute(timeSecs)
  return math.ceil(timeSecs / 60) * 60
end

-- Convert slot size from minutes to seconds
-- @param slotSizeMinutes: Slot size in minutes
-- @return: Slot size in seconds
function M.slotMinutesToSeconds(slotSizeMinutes)
  return (slotSizeMinutes or 1) * 60
end

-- Calculate the next slot time by adding slot duration and rounding to minute boundary
-- @param currentTime: Current time in seconds
-- @param slotSizeMinutes: Size of time slot in minutes (default: 1)
-- @param roundToMinute: If true, rounds result to next minute boundary (default: true)
-- @return: Next slot time in seconds
function M.calculateNextSlotTime(currentTime, slotSizeMinutes, roundToMinute)
  if roundToMinute == nil then roundToMinute = true end

  local slotSizeSecs = M.slotMinutesToSeconds(slotSizeMinutes)
  local newTime = currentTime + slotSizeSecs

  if roundToMinute then
    newTime = M.roundToNextMinute(newTime)
  end

  return newTime
end

-- Check if one time is later than another (with optional tolerance)
-- @param newTime: Time to check
-- @param currentTime: Time to compare against
-- @param tolerance: Optional tolerance in seconds (default: 0)
-- @return: true if newTime > currentTime (accounting for tolerance)
function M.isLaterTime(newTime, currentTime, tolerance)
  tolerance = tolerance or 0
  return newTime > (currentTime + tolerance)
end

return M

