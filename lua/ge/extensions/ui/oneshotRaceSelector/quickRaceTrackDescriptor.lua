-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared grid-backend descriptor for quickrace and lightRunner: both draw
-- their level/track lists from scenario_quickRaceLoader and only differ in
-- backend name, vehicle restrictions (applied elsewhere) and start behavior.
local oneshotRaceSelectorCore = require("ge/extensions/ui/oneshotRaceSelector/core")

local M = {}

-- level.name mirrors levelInfo.title, which is a translation id for regular
-- levels (e.g. "levels.derby.info.title") but a plain literal string for the
-- synthetic "Procedural Tracks"/"Track Editor Tracks" entries. _tr() passes
-- unknown ids through unchanged, so it's safe to apply unconditionally
-- (matches the legacy Angular UI's `| translate` filter on levelInfo.title).
local function levelDisplayName(level)
  return _tr(level.name or level.levelName)
end

function M.build(backendName)
  return {
    backendName = backendName,
    middlePathKey = "tracks",
    levelListTitleKey = "ui.quickrace.quickraceLevels",
    middleListTitleKey = "ui.quickrace.quickraceTracks",

    getLevels = function() return scenario_quickRaceLoader.getQuickraceList() end,
    getMiddleItems = function(level) return level.tracks or {} end,
    middleName = function(track) return track.trackName end,
    levelDisplayName = levelDisplayName,
    middleDisplayName = function(track) return _tr(track.name) end,

    levelToTile = function(level)
      return {
        key = level.levelName,
        name = levelDisplayName(level),
        preview = level.preview,
        subElementCount = level.trackCount or 0,
        showDetails = {levelName = level.levelName},
        doubleClickDetails = {levelName = level.levelName},
      }
    end,

    middleToTile = function(track, levelName)
      return {
        key = track.trackName,
        name = _tr(track.name),
        preview = track.previews and track.previews[1],
        subElementCount = 0,
        showDetails = {levelName = levelName, middleName = track.trackName},
        doubleClickDetails = {levelName = levelName, middleName = track.trackName},
      }
    end,

    getLevelDetails = function(level)
      local levelInfo = level.levelInfo or {}
      local specifications = {}
      if levelInfo.size then
        table.insert(specifications, {key = "size", label = _tr("ui.levelselect.size"), value = string.format("%d m x %d m", levelInfo.size[1] or 0, levelInfo.size[2] or 0), icon = "scale"})
      end
      table.insert(specifications, {key = "tracks", label = _tr("ui.quickrace.quickraceTracks"), value = tostring(level.trackCount or 0), icon = "flag"})
      return {
        headerTitle = levelDisplayName(level),
        preview = level.preview,
        levelName = level.levelName,
        specifications = {specifications},
        buttonInfo = {},
      }
    end,

    getMiddleDetails = function(track, levelName)
      local specifications = {}
      if track.difficulty then
        table.insert(specifications, {key = "difficulty", label = _tr("ui.common.property.difficulty"), value = oneshotRaceSelectorCore.difficultyLabel(track.difficulty), icon = "gaugeFull"})
      end
      if track.reversible then
        table.insert(specifications, {key = "reversible", label = _tr("ui.quickrace.tracks.reversible"), value = _tr("ui.common.yes"), icon = "arrowsSwitch"})
      end
      if track.allowRollingStart then
        table.insert(specifications, {key = "allowRollingStart", label = _tr("ui.quickrace.tracks.allowRollingStart"), value = _tr("ui.common.yes"), icon = "fastForward"})
      end
      table.insert(specifications, {key = "laps", label = _tr("ui.quickrace.tracks.laps"), value = track.uniqueLapCountString or tostring(track.lapCount or 1), icon = "flag"})
      if track.authors and track.authors ~= "" then
        table.insert(specifications, {key = "authors", label = _tr("ui.common.property.authors"), value = track.authors, icon = "person"})
      end
      if track.length then
        table.insert(specifications, {key = "length", label = _tr("ui.quickrace.tracks.length"), value = string.format("%d m", track.length), icon = "road"})
      end
      return {
        headerTitle = _tr(track.name),
        preview = track.previews and track.previews[1],
        description = track.description and _tr(track.description),
        levelName = levelName,
        middleName = track.trackName,
        specifications = {specifications},
        buttonInfo = {},
      }
    end,
  }
end

return M
