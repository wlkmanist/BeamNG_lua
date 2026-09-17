-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.qualityLevels = {
  Disabled = {
  },
  Lowest = {
  },
  Low = {
  },
  Normal = {
  },
  High = {
  },
  Ultra = {
  }
}

M.vehicleTexSizes = {
  Disabled = 512,
  Lowest = 512,
  Low = 1024,
  Normal = 2048,
  High = 4096,
  Ultra = 8192
}

M.qualityLevels.Disabled["$pref::Shadows::textureScalar"] = 0.25
M.qualityLevels.Disabled["$pref::Shadows::disable"] = 2

M.qualityLevels.Lowest["$pref::Shadows::textureScalar"] = 0.25
M.qualityLevels.Lowest["$pref::Shadows::disable"] = 0

M.qualityLevels.Low["$pref::Shadows::textureScalar"] = 0.5
M.qualityLevels.Low["$pref::Shadows::disable"] = 0

M.qualityLevels.Normal["$pref::Shadows::textureScalar"] = 1.0
M.qualityLevels.Normal["$pref::Shadows::disable"] = 0

M.qualityLevels.High["$pref::Shadows::textureScalar"] = 2.0
M.qualityLevels.High["$pref::Shadows::disable"] = 0

M.qualityLevels.Ultra["$pref::Shadows::textureScalar"] = 4.0
M.qualityLevels.Ultra["$pref::Shadows::disable"] = 0

return M