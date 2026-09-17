-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

-- GraphicClusteredQuality presets for clustered local lights and their shadows
M.qualityLevels = {
  Lowest = {
    minLightScreenSize = 0.040,
    lightFlares = false,
    shadowMaxCasters = 16,
    shadowFallbackFrames = 600,
    shadowOversample = 0.5,
    shadowBubble = 0.0,
  },
  Low = {
    minLightScreenSize = 0.025,
    lightFlares = true,
    shadowMaxCasters = 48,
    shadowFallbackFrames = 360,
    shadowOversample = 0.75,
    shadowBubble = 0.75,
  },
  Normal = {
    minLightScreenSize = 0.02,
    lightFlares = true,
    shadowMaxCasters = 64,
    shadowFallbackFrames = 240,
    shadowOversample = 1.0,
    shadowBubble = 1.0,
  },
  High = {
    minLightScreenSize = 0.015,
    lightFlares = true,
    shadowMaxCasters = 96,
    shadowFallbackFrames = 240,
    shadowOversample = 1.25,
    shadowBubble = 1.5,
  },
  Ultra = {
    minLightScreenSize = 0.010,
    lightFlares = true,
    shadowMaxCasters = 96,
    shadowFallbackFrames = 240,
    shadowOversample = 1.25,
    shadowBubble = 2.0,
  },
}

local function applyLevel(level)
  local cs = ClusteredShading
  if not cs then
    return
  end
  local p = M.qualityLevels[level]
  if not p then
    return
  end
  cs.minLightScreenSize = p.minLightScreenSize
  cs.lightFlares = p.lightFlares
  cs.shadowMaxCasters = p.shadowMaxCasters
  cs.shadowFallbackFrames = p.shadowFallbackFrames
  cs.shadowOversample = p.shadowOversample
  cs.shadowBubble = p.shadowBubble
end

M.applyLevel = applyLevel

return M
