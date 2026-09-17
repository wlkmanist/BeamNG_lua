-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Backend for the BusRoute Vue wizard's overview/options step. Registers the
-- busRoute descriptor on top of oneshotRaceCore.lua - unlike
-- quickrace/lightRunner, busRoute's "middle" selection is a full scenario
-- file (scenario_scenariosLoader.getLevels("bus")) that already contains its
-- own vehicle-independent settings (busdriver.strictStop/traffic) and is
-- started directly rather than being merged with a separate level file.
-- Vehicle choice is restricted to transit buses (see vehicleRestrictionMode below).
--
-- In-memory only, mirrors the legacy Angular BusRouteService lifecycle.

local oneshotRaceCore = require("ge/extensions/oneshotRace/oneshotRaceCore")
local oneshotRaceSelectorCore = require("ge/extensions/ui/oneshotRaceSelector/core")

local descriptor = {
  logTag = "busrouteConfigurator",
  gridBackendName = "busRouteSelector",
  routeDataKey = "busRouteWizard",
  -- Restricts the vehicle grid to transit buses.
  vehicleRestrictionMode = "busRoute",

  defaultSettings = function()
    return {
      strictStop = true,
      traffic = false,
    }
  end,

  onSelectMiddle = function(settings, route)
    local busdriver = route.busdriver or {}
    settings.strictStop = busdriver.strictStop ~= false
    settings.traffic = busdriver.traffic == true
  end,

  buildLevelSummary = function(level)
    local levelInfo = level.levelInfo or {}
    return {
      levelName = level.levelName,
      name = _tr(levelInfo.title or level.levelName),
      preview = type(level.previews) == "table" and level.previews[1] or nil,
      official = level.official or false,
      sizeText = levelInfo.size and string.format("%d m x %d m", levelInfo.size[1] or 0, levelInfo.size[2] or 0) or nil,
      suitablefor = levelInfo.suitablefor,
      features = levelInfo.features,
    }
  end,

  buildMiddleSummary = function(route, selection)
    local preview
    if type(route.previews) == "string" then
      preview = route.previews
    elseif type(route.previews) == "table" then
      preview = route.previews[1]
    end
    return {
      levelName = selection.levelName,
      middleName = route.name,
      name = _tr(route.name),
      preview = preview,
      official = route.official or false,
      difficultyLabel = oneshotRaceSelectorCore.difficultyLabel(route.difficulty),
      createdAt = route.date,
      reversible = false,
      allowRollingStart = false,
      closed = false,
      procedural = false,
      uniqueLapCountString = nil,
      stopCount = route.stopCount,
      settings = selection.settings,
    }
  end,

  -- Legacy Angular's BusRoutesController computed a real highscores
  -- configKey from the route settings but then discarded it, hardcoding the
  -- literal string "busRoute" in the actual engineLua call. Kept as-is.
  getHighscoreKey = function(selection, route)
    return {levelName = selection.levelName, scenarioName = route.name, configKey = "busRoute"}
  end,

  start = function(_level, route, settings, _vehicleFile, selection)
    local routeFile = deepcopy(route)
    routeFile.busdriver = routeFile.busdriver or {}
    routeFile.busdriver.strictStop = settings.strictStop
    routeFile.busdriver.traffic = settings.traffic
    routeFile.userSelectedVehicle = {
      model = selection.vehicle.model,
      config = selection.vehicle.config,
    }
    scenario_scenariosLoader.start(routeFile)
  end,
}

local M = oneshotRaceCore.createConfigurator(descriptor)
M.dependencies = {"scenario_scenariosLoader", "core_highscores", "ui_vehicleSelector_general", "ui_busRouteSelector_general"}

return M
