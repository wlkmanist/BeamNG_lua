-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.qualityLevels = {
  Lowest = {
  },
  Low = {
  },
  Normal = {
  }
}

M.qualityLevels.Lowest["$pref::Video::textureReductionLevel"] = 2
M.qualityLevels.Lowest["$pref::Reflect::refractTexScale"] = 0.5

M.qualityLevels.Low["$pref::Video::textureReductionLevel"] = 1
M.qualityLevels.Low["$pref::Reflect::refractTexScale"] = 0.75

M.qualityLevels.Normal["$pref::Video::textureReductionLevel"] = 0
M.qualityLevels.Normal["$pref::Reflect::refractTexScale"] = 1

M.onApply = function()
  reloadTextures() -- Note that this can be a slow operation.
end

return M