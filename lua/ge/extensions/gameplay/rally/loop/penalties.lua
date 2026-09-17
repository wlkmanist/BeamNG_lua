-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.timeControlPenaltySecondsPerMinute = 10
M.falseStartPenaltySeconds = 10

-- Calculate penalty for early arrival
-- Penalty per minute or fraction thereof (see timeControlPenaltySecondsPerMinute)
-- minutesEarly: number of full minutes early
-- Returns: penalty value
local calculateEarlyPenalty = function(minutesEarly)
  return minutesEarly * M.timeControlPenaltySecondsPerMinute
end

-- Calculate penalty for late arrival
-- Penalty per minute or fraction thereof (see timeControlPenaltySecondsPerMinute)
-- minutesLate: number of full minutes late
-- Returns: penalty value
local calculateLatePenalty = function(minutesLate)
  return minutesLate * M.timeControlPenaltySecondsPerMinute
end

local calculateFalseStartPenalty = function(falseStartCount)
  return M.falseStartPenaltySeconds
end

-- Determine if arrival at checkpoint is early, on-time, or late
-- actualTime: actual arrival epoch time in seconds
-- scheduledTime: scheduled epoch time in seconds (can be nil)
-- Returns: table with fields:
--   - status: "early"|"on-time"|"late"
--   - totalPenalty: sum of all penalty amounts (denormalized for performance)
--   - hasPenalty: boolean
--   - penalties: array of individual penalty objects with structured data for i18n
local getTimingStatus = function(actualTime, scheduledTime)
  local status
  local penalty
  local penalties = {}

  -- Handle nil scheduled time (events without schedule)
  if not scheduledTime or not actualTime then
    return {
      status = "on-time",
      totalPenalty = 0,
      hasPenalty = false,
      penalties = {}
    }
  end

  -- Calculate minutes from epoch (integer division by 60)
  local actualMinute = math.floor(actualTime / 60)
  local scheduledMinute = math.floor(scheduledTime / 60)

  local minuteDiff = actualMinute - scheduledMinute

  if minuteDiff < 0 then
    -- Early: arrived in an earlier minute
    status = "early"
    local minutesEarly = math.abs(minuteDiff)
    penalty = calculateEarlyPenalty(minutesEarly)

    -- Add structured penalty for i18n
    if penalty > 0 then
      table.insert(penalties, {
        type = "time_control_early",
        amount = penalty,
        data = {
          minutesEarly = minutesEarly,
          actualMinute = actualMinute,
          scheduledMinute = scheduledMinute
        }
      })
    end
  elseif minuteDiff == 0 then
    -- On-time: arrived in the same minute as scheduled
    status = "on-time"
    penalty = 0
  else
    -- Late: arrived in a later minute
    status = "late"
    local minutesLate = minuteDiff
    penalty = calculateLatePenalty(minutesLate)

    -- Add structured penalty for i18n
    if penalty > 0 then
      table.insert(penalties, {
        type = "time_control_late",
        amount = penalty,
        data = {
          minutesLate = minutesLate,
          actualMinute = actualMinute,
          scheduledMinute = scheduledMinute
        }
      })
    end
  end

  return {
    status = status,
    totalPenalty = penalty,
    hasPenalty = penalty > 0,
    penalties = penalties
  }
end

M.calculateEarlyPenalty = calculateEarlyPenalty
M.calculateLatePenalty = calculateLatePenalty
M.calculateFalseStartPenalty = calculateFalseStartPenalty
M.getTimingStatus = getTimingStatus

return M