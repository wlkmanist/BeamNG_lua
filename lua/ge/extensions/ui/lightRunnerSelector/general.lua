-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Grid selector backend for the LightRunner Vue wizard. LightRunner reuses
-- the exact same level/track data as quickrace (scenario_quickRaceLoader);
-- only the vehicle selection is restricted (to powerglow-capable cars/trucks,
-- applied where the vehicle selector filters are set up). Thin registration
-- of the shared quickrace/lightRunner track descriptor.

local M = {}
M.dependencies = {"scenario_quickRaceLoader"}

local oneshotRaceSelectorCore = require("ge/extensions/ui/oneshotRaceSelector/core")
local quickRaceTrackDescriptor = require("ge/extensions/ui/oneshotRaceSelector/quickRaceTrackDescriptor")

local backend = oneshotRaceSelectorCore.createBackend(quickRaceTrackDescriptor.build("lightRunnerSelector"))
for key, value in pairs(backend) do
  M[key] = value
end

return M
