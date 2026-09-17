-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Co-driver delay: the gap (seconds) between the co-driver finishing a note and
-- the car reaching the corner. Voicepacks can offset the base setting and opt
-- out of the speed-scaled portion configured below.

local M = {}

local cfgFile = '/gameplay/rally/codriverTiming.json'
local cfg = nil

local function getCfg()
  if not cfg then
    local data = jsonReadFile(cfgFile) or {}
    cfg = {
      -- extra delay added on top of the min at endSpeed (max = min + offset). storing the
      -- offset means changing the min setting shifts the whole range without re-saving.
      maxDelayOffsetSeconds = tonumber(data.maxDelayOffsetSeconds) or 0.5,
      startSpeedMph         = tonumber(data.startSpeedMph) or 40,
      endSpeedMph           = tonumber(data.endSpeedMph) or 80,
    }
  end
  return cfg
end

function M.config()
  return getCfg()
end

function M.minDelay(offsetSeconds)
  return settings.getValue('rallyCodriverTiming') + (tonumber(offsetSeconds) or 0)
end

function M.maxDelay(enableSpeedScaling, offsetSeconds)
  local minD = M.minDelay(offsetSeconds)
  if enableSpeedScaling == false then return minD end
  return minD + getCfg().maxDelayOffsetSeconds
end

function M.delayForSpeed(speedMph, enableSpeedScaling, offsetSeconds)
  local c = getCfg()
  local minD = M.minDelay(offsetSeconds)
  if enableSpeedScaling == false then return minD end
  local s0, s1 = c.startSpeedMph, c.endSpeedMph
  if speedMph <= s0 or s1 <= s0 then return minD end
  local t = math.min((speedMph - s0) / (s1 - s0), 1.0)
  return minD + c.maxDelayOffsetSeconds * t
end

-- shift the delay range by `tick` seconds. only the min (rallyCodriverTiming setting)
-- moves; the max follows via the offset, so nothing needs to be re-saved. returns newMin, newMax.
function M.nudge(tick)
  local newMin = math.max(1, math.min((M.minDelay() or 3.0) + tick, 10))
  settings.setValue('rallyCodriverTiming', newMin)
  return newMin, newMin + getCfg().maxDelayOffsetSeconds
end

return M
