-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Backend for the Quickrace Vue wizard's overview/options step. Thin
-- registration of the shared quickrace/lightRunner descriptor on top of
-- oneshotRaceCore.lua (see that file for the shared selection/config logic).
--
-- In-memory only: mirrors the legacy Angular QuickraceService, which is a
-- browser-session singleton that resets whenever the quickrace module is
-- (re)loaded rather than persisting across game restarts.

local oneshotRaceCore = require("ge/extensions/oneshotRace/oneshotRaceCore")
local quickRaceConfiguratorDescriptor = require("ge/extensions/oneshotRace/quickRaceConfiguratorDescriptor")

local descriptor = quickRaceConfiguratorDescriptor.build({
  logTag = "quickraceConfigurator",
  gridBackendName = "quickraceSelector",
  routeDataKey = "quickraceWizard",
  raceType = nil,
})

local M = oneshotRaceCore.createConfigurator(descriptor)
M.dependencies = {"scenario_quickRaceLoader", "core_highscores", "ui_vehicleSelector_general", "ui_quickraceSelector_general"}

return M
