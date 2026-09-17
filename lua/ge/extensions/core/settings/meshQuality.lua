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
  },
  High = {
  },
  Ultra = {
  },
}

M.qualityLevels.Lowest["$pref::TS::detailAdjust"] = 0.5
M.qualityLevels.Lowest["$pref::TS::skipRenderDLs"] = 0

M.qualityLevels.Low["$pref::TS::detailAdjust"] = 0.75
M.qualityLevels.Low["$pref::TS::skipRenderDLs"] = 0

M.qualityLevels.Normal["$pref::TS::detailAdjust"] = 1.0
M.qualityLevels.Normal["$pref::TS::skipRenderDLs"] = 0

M.qualityLevels.High["$pref::TS::detailAdjust"] = 1.5
M.qualityLevels.High["$pref::TS::skipRenderDLs"] = 0

M.qualityLevels.Ultra["$pref::TS::detailAdjust"] = 2.0
M.qualityLevels.Ultra["$pref::TS::skipRenderDLs"] = 0

return M