-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Backend for the LightRunner Vue wizard's overview/options step. Thin
-- registration of the shared quickrace/lightRunner descriptor on top of
-- oneshotRaceCore.lua - LightRunner picks from the same
-- scenario_quickRaceLoader level/track list as quickrace, tags the started
-- race as "lightRunner" (matching the legacy Angular LightRunnerService),
-- and restricts vehicle choice to powerglow-capable cars/trucks while the
-- vehicle grid route is active (see ui_vehicleSelector_general.setVehicleRestrictionMode).
--
-- In-memory only, mirrors the legacy Angular LightRunnerService lifecycle.

local oneshotRaceCore = require("ge/extensions/oneshotRace/oneshotRaceCore")
local quickRaceConfiguratorDescriptor = require("ge/extensions/oneshotRace/quickRaceConfiguratorDescriptor")

-- Matches the legacy Angular LightRunnerService's hardcoded default (glow_city
-- + "Argon Curves" + the sbr powerglow config) so the wizard opens with a
-- ready-to-play race instead of blank selections. Falls back to that level's
-- first track if "Argon Curves" isn't found.
local function getDefaultSelection(selector)
  local level = selector.findLevel("glow_city")
  if not level then return nil end

  local track = nil
  for _, candidate in ipairs(level.tracks or {}) do
    if candidate.name == "Argon Curves" then
      track = candidate
      break
    end
  end
  track = track or (level.tracks or {})[1]

  return {
    levelName = "glow_city",
    middleName = track and track.trackName or nil,
    vehicle = {model = "sbr", config = "powerglow"},
  }
end

local descriptor = quickRaceConfiguratorDescriptor.build({
  logTag = "lightrunnerConfigurator",
  gridBackendName = "lightRunnerSelector",
  routeDataKey = "lightrunnerWizard",
  raceType = "lightRunner",
  vehicleRestrictionMode = "lightRunner",
  getDefaultSelection = getDefaultSelection,
})

local M = oneshotRaceCore.createConfigurator(descriptor)
M.dependencies = {"scenario_quickRaceLoader", "core_highscores", "ui_vehicleSelector_general", "ui_lightRunnerSelector_general"}

return M
