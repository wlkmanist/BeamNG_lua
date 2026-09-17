-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- This is a utility module containing design standards for various types of roads, used across multiple tools.

local M = {}


-- 'Freeway / Autobahn' preset: Modern high-speed expressway with strict design constraints.
-- [Large, engineered roadways. Emphasises gentle grades, large curve radii, excellent visibility.]
local preset1Str = "Freeway / Autobahn"
local preset1 = {
  maxSlope = 0.04, -- Maximum allowed longitudinal slope (rise/run, as ratio). Fair range: [0.03 (flat), 0.20 (steep)].
  minRadius = 500.0, -- Minimum allowed horizontal curve radius, in meters. Fair range: [10 (tight), 500+ (wide)].
  maxBanking = 5.0, -- Maximum allowed banking from global up, in degrees. Fair range: [4 degrees (near flat), 15 degrees (steep)].
  maxWidthGradient = 0.02, -- Maximum allowed width variation from average. Fair range: [0.01 (tight), 0.10 (wide)].
}

-- 'Major Rural Road' preset:
-- [Narrow, often rural roads. Moderate curves, minor engineering, single carriageway.]
local preset2Str = "Major Rural Road"
local preset2 = {
  maxSlope = 0.06,
  minRadius = 200.0,
  maxBanking = 7.0,
  maxWidthGradient = 0.03,
}

-- 'Secondary Road' preset:
-- [Medium-quality countryside road, often paved but less consistent than highways.]
local preset3Str = "Secondary Road"
local preset3 = {
  maxSlope = 0.08,
  minRadius = 100.0,
  maxBanking = 9.0,
  maxWidthGradient = 0.05,
}

-- 'Mountain Pass' preset:
-- [Extemely-rugged 4x4 tracks. Steep, tight, often gravel or dirt.]
local preset4Str = "Mountain Pass"
local preset4 = {
  maxSlope = 0.12,
  minRadius = 40.0,
  maxBanking = 12.0,
  maxWidthGradient = 0.07,
}

-- 'Unpaved Trail' preset:
-- [Rural roads in steep topography, possibly under-developed.]
local preset5Str = "Unpaved Trail"
local preset5 = {
  maxSlope = 0.18,
  minRadius = 20.0,
  maxBanking = 14.0,
  maxWidthGradient = 0.1,
}

-- 'Off-Road / F-Road' preset:
-- [Narrow, high-curvature mountain roads. Sharp slopes and corners.]
local preset6Str = "Off-Road / F-Road"
local preset6 = {
  maxSlope = 0.24,
  minRadius = 12.0,
  maxBanking = 18.0,
  maxWidthGradient = 0.12,
}

-- The preset strings array [ordered].
local presetStrings = {
  preset1Str,
  preset2Str,
  preset3Str,
  preset4Str,
  preset5Str,
  preset6Str,
 }

-- The preset map [preset string key -> preset data].
local presetsMap = {
  [preset1Str] = preset1,
  [preset2Str] = preset2,
  [preset3Str] = preset3,
  [preset4Str] = preset4,
  [preset5Str] = preset5,
  [preset6Str] = preset6,
}


-- Returns the preset strings.
-- [This is an ordered array of preset name strings.]
local function getPresetStrings() return presetStrings end

-- Returns the preset map.
-- [This is a map of preset name strings to the preset parameters.]
local function getPresetsMap() return presetsMap end


-- Public interface.
M.getPresetStrings =                                    getPresetStrings
M.getPresetsMap =                                       getPresetsMap

return M