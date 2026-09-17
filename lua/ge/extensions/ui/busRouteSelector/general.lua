-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Grid selector backend for the BusRoute Vue wizard: exposes levels with bus
-- routes (scenario_scenariosLoader.getLevels("bus")) and, per level, its
-- route list. Routes don't have a dedicated id field in the source data
-- (unlike quickrace tracks' trackName), so the route's display name is used
-- as its key, mirroring the legacy Angular BusRouteService which keyed
-- highscores and navigation off `route.name` the same way.

local M = {}
M.dependencies = {"scenario_scenariosLoader"}

local oneshotRaceSelectorCore = require("ge/extensions/ui/oneshotRaceSelector/core")

local function levelDisplayName(level)
  local levelInfo = level.levelInfo or {}
  return _tr(levelInfo.title or level.levelName)
end

local function levelPreview(level)
  return type(level.previews) == "table" and level.previews[1] or nil
end

local function routeName(route)
  return route.name
end

local function routePreview(route)
  if type(route.previews) == "string" then return route.previews end
  if type(route.previews) == "table" then return route.previews[1] end
  return nil
end

local descriptor = {
  backendName = "busRouteSelector",
  middlePathKey = "routes",
  levelListTitleKey = "ui.busRoute.levelSelect",
  middleListTitleKey = "ui.busRoute.routeSelect",

  getLevels = function() return scenario_scenariosLoader.getLevels("bus") end,
  getMiddleItems = function(level) return level.scenarios or {} end,
  middleName = routeName,
  levelDisplayName = levelDisplayName,
  middleDisplayName = function(route) return _tr(route.name) end,

  levelToTile = function(level)
    return {
      key = level.levelName,
      name = levelDisplayName(level),
      preview = levelPreview(level),
      subElementCount = #(level.scenarios or {}),
      showDetails = {levelName = level.levelName},
      doubleClickDetails = {levelName = level.levelName},
    }
  end,

  middleToTile = function(route, levelName)
    return {
      key = routeName(route),
      name = _tr(route.name),
      preview = routePreview(route),
      subElementCount = 0,
      showDetails = {levelName = levelName, middleName = routeName(route)},
      doubleClickDetails = {levelName = levelName, middleName = routeName(route)},
    }
  end,

  getLevelDetails = function(level)
    local levelInfo = level.levelInfo or {}
    local specifications = {}
    if levelInfo.size then
      table.insert(specifications, {key = "size", label = _tr("ui.levelselect.size"), value = string.format("%d m x %d m", levelInfo.size[1] or 0, levelInfo.size[2] or 0), icon = "scale"})
    end
    table.insert(specifications, {key = "routes", label = _tr("ui.busRoute.routeSelect"), value = tostring(#(level.scenarios or {})), icon = "flag"})
    return {
      headerTitle = levelDisplayName(level),
      preview = levelPreview(level),
      levelName = level.levelName,
      specifications = {specifications},
      buttonInfo = {},
    }
  end,

  getMiddleDetails = function(route, levelName)
    local specifications = {}
    if route.difficulty then
      table.insert(specifications, {key = "difficulty", label = _tr("ui.common.property.difficulty"), value = oneshotRaceSelectorCore.difficultyLabel(route.difficulty), icon = "gaugeFull"})
    end
    if route.stopCount then
      table.insert(specifications, {key = "stopCount", label = _tr("ui.busRoute.stopCount"), value = tostring(route.stopCount), icon = "flag"})
    end
    if route.date then
      table.insert(specifications, {key = "createdAt", label = _tr("ui.common.property.createdAt"), value = os.date("%d %B %Y", route.date), icon = "calendar"})
    end
    return {
      headerTitle = _tr(route.name),
      preview = routePreview(route),
      levelName = levelName,
      middleName = routeName(route),
      specifications = {specifications},
      buttonInfo = {},
    }
  end,
}

local backend = oneshotRaceSelectorCore.createBackend(descriptor)
for key, value in pairs(backend) do
  M[key] = value
end

return M
