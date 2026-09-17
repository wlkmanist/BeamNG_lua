-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared oneshotRaceCore descriptor for quickrace and lightRunner: both
-- select a scenario_quickRaceLoader track and only differ in grid backend
-- name, route-data key and the `raceType` tag passed to startQuickrace
-- (lightRunner passes "lightRunner"; quickrace passes nothing).
local oneshotRaceSelectorCore = require("ge/extensions/ui/oneshotRaceSelector/core")

local M = {}

function M.build(opts)
  return {
    logTag = opts.logTag,
    gridBackendName = opts.gridBackendName,
    routeDataKey = opts.routeDataKey,
    vehicleRestrictionMode = opts.vehicleRestrictionMode,
    getDefaultSelection = opts.getDefaultSelection,

    defaultSettings = function()
      return {
        reverse = false,
        rollingStart = false,
        lapCount = 1,
        tod = 3,
        seed = nil,
      }
    end,

    extraSettingKeys = {seed = true},

    onSelectMiddle = function(settings, track)
      -- NOTE: can't use the `cond and false or nil` idiom here - `false` is
      -- itself falsy, so `... or nil` would always win and both settings
      -- would end up nil, which then made oneshotRaceCore.lua's updateSetting() reject them as "unknown".
      settings.reverse = track.reversible and false
      settings.rollingStart = track.allowRollingStart and false
      settings.lapCount = track.lapCount or 1
      settings.tod = track.tod or 3
      settings.seed = track.procedural and (track.customData and track.customData.seed) or nil
    end,

    onUpdateSetting = function(settings, key, value, middle)
      if key == "lapCount" and value == 0 and middle and middle.allowRollingStart then
        settings.rollingStart = true
      end
    end,

    buildLevelSummary = function(level)
      local levelInfo = level.levelInfo or {}
      return {
        levelName = level.levelName,
        -- level.name mirrors levelInfo.title, a translation id for regular
        -- levels; _tr() passes unrecognised ids through unchanged.
        name = _tr(level.name or level.levelName),
        preview = level.preview,
        official = level.official or false,
        sizeText = levelInfo.size and string.format("%d m x %d m", levelInfo.size[1] or 0, levelInfo.size[2] or 0) or nil,
        suitablefor = levelInfo.suitablefor,
        features = levelInfo.features,
      }
    end,

    buildMiddleSummary = function(track, selection)
      local previews = track.previews or {}
      local preview = selection.settings.reverse and track.reversePreviews and track.reversePreviews[1] or previews[1]
      return {
        levelName = selection.levelName,
        middleName = track.trackName,
        name = _tr(track.name),
        preview = preview,
        official = track.official or false,
        difficultyLabel = oneshotRaceSelectorCore.difficultyLabel(track.difficulty),
        createdAt = track.date,
        reversible = track.reversible or false,
        allowRollingStart = track.allowRollingStart or false,
        closed = track.closed or false,
        procedural = track.procedural or false,
        uniqueLapCountString = track.uniqueLapCountString,
        settings = selection.settings,
      }
    end,

    getHighscoreKey = function(selection, track)
      local settings = selection.settings
      local configKey = "standing"
      if settings.rollingStart and settings.lapCount > 0 and not selection.showLapRecords then
        configKey = "rolling"
      end
      if settings.reverse then
        configKey = configKey .. "Reverse"
      end
      configKey = configKey .. (selection.showLapRecords and 0 or (settings.lapCount or 1))
      return {levelName = selection.levelName, scenarioName = track.trackName, configKey = configKey}
    end,

    start = function(level, track, settings, vehicleFile, selection)
      local scenarioFile = deepcopy(level)
      scenarioFile.tracks = nil

      local trackFile = deepcopy(track)
      trackFile.reverse = settings.reverse or false
      trackFile.rollingStart = settings.rollingStart or false
      trackFile.lapCount = settings.lapCount or 1
      trackFile.tod = settings.tod or 3
      if trackFile.procedural and settings.seed then
        trackFile.customData = trackFile.customData or {}
        trackFile.customData.seed = settings.seed
      end

      scenario_quickRaceLoader.startQuickrace(scenarioFile, trackFile, vehicleFile, opts.raceType)
    end,
  }
end

return M
