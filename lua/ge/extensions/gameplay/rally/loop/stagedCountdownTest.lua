-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}

local logTag = 'stagedCountdownTest'

local function getTimeOfDay()
  -- Shim to get time of day from environment extension
  if core_environment then
    return core_environment.getTimeOfDay()
  end
  return nil
end

function C:init()
  self.epoch = 0
  self.environmentStartTimeSecs = 0
  self.scheduledEventTime = nil

  -- Initialize test mode based on current environment time
  local currentTime = getTimeOfDay()
  if currentTime and currentTime.time then
    -- Convert 0-1 to seconds of day (same as rallyLoopManager)
    local timeIn24 = currentTime.time * 24  -- Hours as float (0-24)
    local adjustedHours = (timeIn24 + 12) % 24  -- Shift by 12 hours (noon -> 0)
    self.environmentStartTimeSecs = adjustedHours * 3600  -- Convert to seconds
    log('D', logTag, string.format('Test mode: environment start time: %.0f seconds', self.environmentStartTimeSecs))
  else
    self.environmentStartTimeSecs = 0  -- Default to midnight
    log('W', logTag, 'Test mode: could not get environment time, defaulted to midnight')
  end

  -- Calculate scheduled event time
  self:calculateScheduledEventTime()
end

function C:calculateScheduledEventTime()
  -- Calculate scheduled event time as next minute rollover
  -- If less than 15 seconds to next minute, use the minute after that

  -- Current wall clock time = environment start time + epoch
  local currentWallClockSecs = self.environmentStartTimeSecs + self.epoch

  -- Get seconds within current minute
  local secondsIntoMinute = currentWallClockSecs % 60

  -- Calculate seconds until next minute
  local secondsToNextMinute = 60 - secondsIntoMinute

  -- If less than 15 seconds to next minute, schedule for the minute after
  local minutesToAdd = 1
  if secondsToNextMinute < 15 then
    minutesToAdd = 2
  end

  -- Calculate target wall clock time (next minute boundary)
  local targetWallClockSecs = math.ceil(currentWallClockSecs / 60) * 60
  if secondsToNextMinute < 15 then
    targetWallClockSecs = targetWallClockSecs + 60
  end

  -- Convert to epoch time (relative to environment start)
  self.scheduledEventTime = targetWallClockSecs - self.environmentStartTimeSecs

  log('D', logTag, string.format('Test mode: scheduled event at epoch %.2f (wall clock %.2f, in %.2f seconds)',
    self.scheduledEventTime, targetWallClockSecs, self.scheduledEventTime - self.epoch))
end

function C:reschedule(slotSizeMinutes, rescheduleCount, maxReschedules, defaultWarningTimes, warningsTriggered)
  -- Test mode: reschedule to next minute-aligned slot
  local oldTime = self.scheduledEventTime

  -- Convert old scheduled time to wall clock
  local oldWallClockSecs = self.environmentStartTimeSecs + oldTime

  -- Find the next minute boundary after the old time
  local nextMinuteBoundary = math.ceil(oldWallClockSecs / 60) * 60

  -- Add slot size in minutes (convert to seconds)
  local newWallClockSecs = nextMinuteBoundary + (slotSizeMinutes * 60)

  -- Convert back to epoch time
  self.scheduledEventTime = newWallClockSecs - self.environmentStartTimeSecs

  local newScheduledEventTime = self.scheduledEventTime

  -- Mark warnings as already triggered if they're in the past
  local currentEpochTime = self.epoch
  if currentEpochTime then
    local timeUntilEvent = newScheduledEventTime - currentEpochTime
    for _, warningTime in ipairs(defaultWarningTimes) do
      if timeUntilEvent < warningTime then
        warningsTriggered[warningTime] = true
      end
    end
  end

  log('D', logTag, string.format('Test mode: Rescheduled from %.2f to %.2f (attempt %d/%d)',
    oldTime, self.scheduledEventTime, rescheduleCount + 1, maxReschedules))

  return true, newScheduledEventTime
end

function C:getWallClockTime()
  -- Calculate wall clock time from epoch in test mode
  if not self.environmentStartTimeSecs then
    return nil
  end
  local wallClockSecs = (self.environmentStartTimeSecs + self.epoch) % 86400  -- Wrap at 24 hours
  return wallClockSecs
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end

