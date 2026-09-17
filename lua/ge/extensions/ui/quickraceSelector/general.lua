-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Grid selector backend for the Quickrace Vue wizard: exposes the level list
-- and, per level, its track list. Thin registration of the shared
-- quickrace/lightRunner track descriptor (see oneshotRaceSelector/core.lua).

local M = {}
M.dependencies = {"scenario_quickRaceLoader"}

local oneshotRaceSelectorCore = require("ge/extensions/ui/oneshotRaceSelector/core")
local quickRaceTrackDescriptor = require("ge/extensions/ui/oneshotRaceSelector/quickRaceTrackDescriptor")

local backend = oneshotRaceSelectorCore.createBackend(quickRaceTrackDescriptor.build("quickraceSelector"))
for key, value in pairs(backend) do
  M[key] = value
end

return M
