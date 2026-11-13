-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local function number(config, name, default, minimum, maximum, zeroDisables)
  local value = config[name]
  if type(value) ~= "number" or value ~= value
      or value == math.huge or value == -math.huge then
    value = default
  end
  if zeroDisables and value == 0 then return 0 end
  return clamp(value, minimum, maximum)
end

function M.read(config)
  config = type(config) == "table" and config or {}
  local result = {
    sampleIntervalSeconds = number(
      config, "spatialSampleIntervalSeconds", 0, 1, 3600, true),
    dipTrackingEnabled = config.dipTrackingEnabled == true,
    recoveryTrackingEnabled = config.recoveryTrackingEnabled == true,
    gameplayExitTrackingEnabled = config.gameplayExitTrackingEnabled == true,
    shaderGenerationTrackingEnabled = config.shaderGenerationTrackingEnabled == true,
    sceneComplexityTrackingEnabled = config.sceneComplexityTrackingEnabled == true,
    renderTimingTrackingEnabled = config.renderTimingTrackingEnabled == true,
  }

  if type(config.levels) == "table" and #config.levels > 0 then
    result.levels = {}
    for index = 1, math.min(#config.levels, 64) do
      local level = config.levels[index]
      if type(level) == "string" and #level <= 128 and level:match("^[%w_.-]+$") then
        result.levels[level] = true
      end
    end
  end

  if result.dipTrackingEnabled then
    result.detector = {
      dipFpsThreshold = number(config, "dipFpsThreshold", 30, 1, 360),
      dipFrameTimeRatio = number(config, "dipFrameTimeRatio", 2, 1.1, 10),
      dipMinDurationMs = number(config, "dipMinDurationMs", 250, 50, 10000),
      dipCooldownSeconds = number(config, "dipCooldownSeconds", 5, 0, 3600),
      maxDipEventsPerSession = math.floor(number(
        config, "maxDipEventsPerSession", 100, 1, 1000)),
    }
  end
  return result
end

return M
