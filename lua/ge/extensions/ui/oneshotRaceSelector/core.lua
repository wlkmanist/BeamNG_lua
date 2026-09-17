-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Shared ui_gridSelector backend plumbing for the three "oneshot race" grid
-- selectors (quickraceSelector/lightRunnerSelector/busRouteSelector): search,
-- display data persistence, filters (unused - flat lists), header/breadcrumb
-- building and getDetails dispatch by path shape (levels vs. level's middle
-- items - tracks/routes). Tile/detail formatting is mode-specific and left to
-- the descriptor passed to createBackend(), since quickrace/lightRunner track
-- data and busRoute route data have fairly different shapes.

local M = {}

local displayDataModule = require("ge/extensions/ui/gridSelectorUtils/displayDataModule")

local difficultyLabels = {
  [0] = "ui.scenarios.difficulty.easy",
  [1] = "ui.scenarios.difficulty.medium",
  [2] = "ui.scenarios.difficulty.hard",
  [3] = "ui.scenarios.difficulty.veryHard",
}
local function difficultyLabel(value)
  local num = tonumber(value)
  if not num then return nil end
  local key = difficultyLabels[math.floor(num / 25)]
  return key and _tr(key) or nil
end
M.difficultyLabel = difficultyLabel

-- descriptor contract:
--   backendName: string
--   middlePathKey: "tracks" | "routes" - path.keys[1] for the drilldown level
--   levelListTitleKey, middleListTitleKey: translation ids
--   getLevels(): array of level tables
--   findLevel(levelName): optional override; defaults to scanning getLevels()
--   getMiddleItems(level): array of track/route tables for a level
--   middleName(middle): stable key for a track/route within its level
--   levelDisplayName(level), middleDisplayName(middle): already-_tr()'d names
--   levelToTile(level), middleToTile(middle, levelName): grid tile tables
--   getLevelDetails(level), getMiddleDetails(middle, levelName): getDetails() payloads
function M.createBackend(descriptor)
  local backend = {}
  backend.backendName = descriptor.backendName

  local function getDefaultDisplayDataOptions()
    return {
      {
        label = _tr("ui.menu.gridSelector.displaySize.title"),
        key = "displaySize",
        default = "medium",
        type = "dropdown",
        description = _tr("ui.menu.gridSelector.displaySize.description"),
        save = true,
        showInModes = {displayControls = true},
        options = {
          {label = _tr("ui.menu.gridSelector.displaySize.list"), value = "list"},
          {label = _tr("ui.menu.gridSelector.displaySize.tiny"), value = "tiny"},
          {label = _tr("ui.menu.gridSelector.displaySize.small"), value = "small"},
          {label = _tr("ui.menu.gridSelector.displaySize.medium"), value = "medium"},
          {label = _tr("ui.menu.gridSelector.displaySize.large"), value = "large"},
          {label = _tr("ui.menu.gridSelector.displaySize.huge"), value = "huge"},
        },
      },
    }
  end

  local function updateDisplayData(saved, version, targetVersion)
    return saved or {}
  end

  local displayDataInstance = nil
  local function getDisplayDataInstance()
    if not displayDataInstance then
      displayDataInstance = displayDataModule.create(
        "/settings/" .. descriptor.backendName .. "Data.json",
        getDefaultDisplayDataOptions(),
        updateDisplayData,
        descriptor.backendName,
        1
      )
    end
    return displayDataInstance
  end

  local searchText = ""
  local function matchesSearch(name)
    if searchText == "" then return true end
    if not name then return false end
    return string.find(string.lower(name), string.lower(searchText), 1, true) ~= nil
  end

  local function findLevel(levelName)
    if descriptor.findLevel then return descriptor.findLevel(levelName) end
    if not levelName then return nil end
    for _, level in ipairs(descriptor.getLevels()) do
      if level.levelName == levelName then
        return level
      end
    end
    return nil
  end
  backend.findLevel = findLevel

  local function findMiddle(levelName, middleName)
    local level = findLevel(levelName)
    if not level then return nil end
    for _, middle in ipairs(descriptor.getMiddleItems(level)) do
      if descriptor.middleName(middle) == middleName then
        return middle
      end
    end
    return nil
  end
  backend.findMiddle = findMiddle

  function backend.getTiles(path)
    local keys = path.keys or {}

    if keys[1] == descriptor.middlePathKey then
      local levelName = keys[2]
      local level = levelName and findLevel(levelName)
      local tiles = {}
      if level then
        for _, middle in ipairs(descriptor.getMiddleItems(level)) do
          if matchesSearch(descriptor.middleDisplayName(middle)) then
            table.insert(tiles, descriptor.middleToTile(middle, levelName))
          end
        end
      end
      return {{label = "", tiles = tiles}}
    end

    local tiles = {}
    for _, level in ipairs(descriptor.getLevels()) do
      if matchesSearch(descriptor.levelDisplayName(level)) then
        table.insert(tiles, descriptor.levelToTile(level))
      end
    end
    table.sort(tiles, function(a, b) return string.lower(a.name or "") < string.lower(b.name or "") end)
    return {{label = "", tiles = tiles}}
  end

  function backend.getFilters()
    return {
      filterList = {},
      filterByProp = {},
      commonFilters = {},
      lockedFiltersByProp = {},
      activeFilters = {},
      onlyCommonFilters = true,
    }
  end

  function backend.getActiveFilters()
    return {}
  end

  function backend.getSearchText()
    return searchText
  end

  function backend.setSearchText(value)
    searchText = value or ""
    return true
  end

  function backend.getDisplayDataOptions()
    return getDisplayDataInstance().getDisplayDataOptions()
  end

  function backend.setDisplayDataOption(key, value)
    return getDisplayDataInstance().setDisplayDataOption(key, value)
  end

  function backend.resetDisplayDataToDefaults()
    return getDisplayDataInstance().resetDisplayDataToDefaults()
  end

  function backend.getScreenHeaderTitleAndPath(path)
    local keys = path.keys or {}
    if keys[1] == descriptor.middlePathKey then
      local level = keys[2] and findLevel(keys[2])
      return {
        title = _tr(descriptor.middleListTitleKey),
        pathSegments = {
          {label = _tr("ui.common.menu"), gotoAngularState = "menu"},
          {label = level and descriptor.levelDisplayName(level) or _tr(descriptor.middleListTitleKey)},
        },
      }
    end
    return {
      title = _tr(descriptor.levelListTitleKey),
      pathSegments = {
        {label = _tr("ui.common.menu"), gotoAngularState = "menu"},
        {label = _tr(descriptor.levelListTitleKey)},
      },
    }
  end

  function backend.getDetails(details)
    details = type(details) == "table" and details or {}

    if details.middleName then
      local middle = findMiddle(details.levelName, details.middleName)
      if not middle then
        return {headerTitle = details.middleName}
      end
      return descriptor.getMiddleDetails(middle, details.levelName)
    end

    if details.levelName then
      local level = findLevel(details.levelName)
      if not level then
        return {headerTitle = details.levelName}
      end
      return descriptor.getLevelDetails(level)
    end

    return {headerTitle = ""}
  end

  function backend.getManagementDetails()
    return {buttons = {}}
  end

  function backend.executeButton()
    return nil
  end

  function backend.executeDoubleClick()
    return nil
  end

  function backend.toggleFavourite()
    return false
  end

  function backend.profilerFinish() end
  function backend.closedFromUI() end

  return backend
end

return M
