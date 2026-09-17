-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared backend for the three "oneshot race" Vue wizards' overview/options
-- step (quickrace, lightRunner, busRoute): owns the current
-- level/middle(track or route)/vehicle selection plus per-middle settings,
-- and wraps highscores and starting the race/route. Mirrors
-- freeroam_freeroamConfigurator's role for the freeroam wizard, scaled down
-- to this family's much smaller surface (no filters, no async bulk loading).
--
-- Each mode (quickrace/lightRunner/busRoute) gets its own configurator
-- instance (own in-memory selection state) via M.createConfigurator(descriptor),
-- since the three modes must not share selection state with each other.
-- The descriptor supplies everything that differs between modes: default
-- settings, how a middle-item seeds those settings, how to summarize
-- level/middle for the Vue UI, the highscores key, and how to actually start
-- the race/route. See quickRaceConfiguratorDescriptor.lua and
-- busrouteConfigurator.lua for concrete descriptors.

local M = {}

local todNames = {"night", "sunrise", "morning", "earlyNoon", "noon", "lateNoon", "afternoon", "evening", "sunset"}
M.todNames = todNames

local function buildVehicleSummary(vehicle)
  if not vehicle.model then return nil end
  local modelData = core_vehicles.getModel(vehicle.model)
  local configData = core_vehicles.getConfig(vehicle.model, vehicle.config)
  if not modelData then return nil end
  local model = modelData.model or {}
  return {
    model = vehicle.model,
    config = vehicle.config,
    name = configData and configData.Name or model.Name,
    preview = configData and configData.preview,
    official = not not (model.aggregates and model.aggregates.Source and model.aggregates.Source["BeamNG - Official"]),
    country = model.Country,
    brand = model.Brand,
    derbyClass = model["Derby Class"],
  }
end

local function buildVehicleFile(vehicle)
  local modelData = core_vehicles.getModel(vehicle.model)
  local configData = core_vehicles.getConfig(vehicle.model, vehicle.config)
  return {
    official = configData and configData.aggregates and configData.aggregates.Source and configData.aggregates.Source["BeamNG - Official"] or false,
    model = vehicle.model,
    config = vehicle.config,
    color = configData and configData.default_color,
    name = configData and configData.Name,
    preview = configData and configData.preview,
    file = modelData,
  }
end

-- descriptor contract:
--   logTag: string
--   gridBackendName: ui_gridSelector backend name (levels + tracks/routes source of truth)
--   routeDataKey: key under router route-data payloads (e.g. "quickraceWizard")
--   vehicleRestrictionMode: optional, passed to
--     ui_vehicleSelector_general.setVehicleRestrictionMode() while the wizard's
--     vehicle route is active (e.g. "lightRunner", "busRoute"); nil means no restriction
--   defaultSettings(): -> table
--   onSelectMiddle(settings, middle): mutate `settings` in place from the newly selected middle item
--   onUpdateSetting(settings, key, value, middle): optional, extra side effects on setting change
--   extraSettingKeys: optional table of setting keys allowed beyond defaultSettings()'s own keys (e.g. {seed = true})
--   buildLevelSummary(level) -> table
--   buildMiddleSummary(middle, selection) -> table (must include a `settings` field)
--   getHighscoreKey(selection, middle) -> {levelName, scenarioName, configKey} or nil to skip highscores
--   start(level, middle, settings, vehicleFile, selection): actually starts the race/route
--   getDefaultSelection(selector): optional, called once when the wizard is
--     entered with nothing selected yet (e.g. lightRunner defaults to
--     "glow_city"); `selector` is the ui_gridSelector backend (findLevel/
--     findMiddle) for gridBackendName. -> {levelName, middleName, vehicle =
--     {model, config}} or nil for "no default" (quickrace/busRoute)
function M.createConfigurator(descriptor)
  local logTag = descriptor.logTag

  local selection = {
    levelName = nil,
    middleName = nil,
    settings = descriptor.defaultSettings(),
    showLapRecords = false,
    vehicle = {
      model = nil,
      config = nil,
      additionalData = nil,
    },
  }

  local function getSelector()
    return ui_gridSelector and ui_gridSelector.getBackendByName and ui_gridSelector.getBackendByName(descriptor.gridBackendName)
  end

  local function getLevel(levelName)
    local selector = getSelector()
    return levelName and selector and selector.findLevel(levelName) or nil
  end

  local function findMiddle(levelName, middleName)
    local selector = getSelector()
    if not selector or not levelName or not middleName then return nil end
    return selector.findMiddle(levelName, middleName)
  end

  local function getMiddle()
    if not selection.levelName or not selection.middleName then return nil end
    return findMiddle(selection.levelName, selection.middleName)
  end

  local Cfg = {}

  function Cfg.getSelection()
    return selection
  end

  function Cfg.selectLevel(levelName)
    selection.levelName = levelName
    selection.middleName = nil
    return true
  end

  function Cfg.selectMiddle(levelName, middleName)
    local middle = findMiddle(levelName, middleName)
    if not middle then
      log("W", logTag, "selectMiddle: could not find " .. tostring(middleName) .. " for level " .. tostring(levelName))
      return false
    end

    selection.levelName = levelName
    selection.middleName = middleName
    selection.settings = descriptor.defaultSettings()
    descriptor.onSelectMiddle(selection.settings, middle)
    return true
  end

  function Cfg.selectVehicle(model, config, additionalData)
    if not model then
      log("W", logTag, "selectVehicle: model is required")
      return false
    end
    local resolvedConfig = config
    if not resolvedConfig or not core_vehicles.getConfig(model, resolvedConfig) then
      local modelData = core_vehicles.getModel(model)
      resolvedConfig = modelData and modelData.model and modelData.model.default_pc or resolvedConfig
    end
    selection.vehicle.model = model
    selection.vehicle.config = resolvedConfig
    selection.vehicle.additionalData = additionalData or {}
    return true
  end

  function Cfg.updateSetting(key, value)
    local isKnownKey = selection.settings[key] ~= nil or (descriptor.extraSettingKeys and descriptor.extraSettingKeys[key])
    if not isKnownKey then
      log("W", logTag, "updateSetting: unknown setting " .. tostring(key))
      return false
    end
    selection.settings[key] = value
    if descriptor.onUpdateSetting then
      descriptor.onUpdateSetting(selection.settings, key, value, getMiddle())
    end
    return true
  end

  function Cfg.toggleShowLapRecords()
    selection.showLapRecords = not selection.showLapRecords
    return selection.showLapRecords
  end

  function Cfg.getHighscores()
    local middle = getMiddle()
    if not middle then return {} end
    local key = descriptor.getHighscoreKey(selection, middle)
    if not key then return {} end
    local ok, scores = pcall(core_highscores.getScenarioHighscores, key.levelName, key.scenarioName, key.configKey)
    if not ok then
      log("E", logTag, "Failed to get highscores: " .. tostring(scores))
      return {}
    end
    return scores
  end

  -- Applied at most once per configurator lifetime (in-memory only, reset on
  -- extension reload) - only fires while nothing has been picked yet, so it
  -- never overrides a deliberate user selection. Lives on Cfg.getConfiguration
  -- (rather than only the wizard-route-enter path) so it also covers the
  -- direct getConfiguration() RPC fallback path (see
  -- useOneshotRaceConfigurator.js's initialize()).
  local function applyDefaultSelectionIfNeeded()
    if selection.levelName or not descriptor.getDefaultSelection then return end
    local selector = getSelector()
    if not selector then return end
    local default = descriptor.getDefaultSelection(selector)
    if not default or not default.levelName then return end
    Cfg.selectLevel(default.levelName)
    if default.middleName then
      Cfg.selectMiddle(default.levelName, default.middleName)
    end
    if default.vehicle and default.vehicle.model then
      Cfg.selectVehicle(default.vehicle.model, default.vehicle.config)
    end
  end

  function Cfg.getConfiguration()
    applyDefaultSelectionIfNeeded()
    local level = getLevel(selection.levelName)
    local middle = getMiddle()
    local levelSummary = level and descriptor.buildLevelSummary(level) or nil
    local middleSummary = middle and descriptor.buildMiddleSummary(middle, selection) or nil
    local vehicleSummary = buildVehicleSummary(selection.vehicle)
    return {
      level = levelSummary,
      middle = middleSummary,
      vehicle = vehicleSummary,
      highscores = Cfg.getHighscores(),
      showLapRecords = selection.showLapRecords,
      isDisabled = not (levelSummary and middleSummary and vehicleSummary),
      todOptionKeys = todNames,
    }
  end

  local function buildWizardRouteData(data)
    if type(data) ~= "table" then return end
    data[descriptor.routeDataKey] = {
      config = Cfg.getConfiguration(),
    }
  end

  -- Modes that need a restricted vehicle pool (lightRunner/busRoute) set
  -- descriptor.vehicleRestrictionMode; it's applied only while the vehicle
  -- grid route is active and cleared again on every other wizard route so it
  -- can never leak into an unrelated vehicle selector screen.
  local function setVehicleRestrictionMode(mode)
    if ui_vehicleSelector_general and ui_vehicleSelector_general.setVehicleRestrictionMode then
      ui_vehicleSelector_general.setVehicleRestrictionMode(mode)
    end
  end

  function Cfg.onWizardRouteEnter(context, toRoute, fromRoute, data)
    setVehicleRestrictionMode(nil)
    buildWizardRouteData(data)
  end

  function Cfg.onWizardLevelRouteEnter(context, toRoute, fromRoute, data)
    setVehicleRestrictionMode(nil)
    buildWizardRouteData(data)
  end

  function Cfg.onWizardMiddleRouteEnter(context, toRoute, fromRoute, data)
    setVehicleRestrictionMode(nil)
    buildWizardRouteData(data)
  end

  function Cfg.onWizardVehicleRouteEnter(context, toRoute, fromRoute, data)
    setVehicleRestrictionMode(descriptor.vehicleRestrictionMode)
    buildWizardRouteData(data)
  end

  function Cfg.start()
    local level = getLevel(selection.levelName)
    local middle = getMiddle()
    if not level or not middle then
      log("W", logTag, "start: level or middle not selected")
      return false
    end
    if not selection.vehicle.model then
      log("W", logTag, "start: vehicle not selected")
      return false
    end

    local vehicleFile = buildVehicleFile(selection.vehicle)
    descriptor.start(level, middle, selection.settings, vehicleFile, selection)
    return true
  end

  return Cfg
end

return M
