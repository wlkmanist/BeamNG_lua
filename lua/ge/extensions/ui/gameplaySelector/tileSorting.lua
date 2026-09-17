--[[
  Tile Sorting Module for Gameplay Selector

  This module provides centralized sorting functionality for gameplay tiles.
  It supports multiple sort modes and handles complex sorting rules for different
  gameplay systems.

  Sort Modes:
  - Name: Alphabetical sorting with "Other..." items last
  - System: Sort by gameplay system (Freeroam, Challenges, etc.)
  - GameplayAutomatic: Complex multi-criteria sorting for gameplay items
  - Date: Sort by date (newest first)

  UI Integration:
  - Maps UI display values to internal sort modes
  - Provides validation and error handling
  - Supports fallback to default sorting
]]

local M = {}

-- Constants
local DEFAULT_SORT_MODE = "Name"
local UNKNOWN_SYSTEM_ORDER = 999

-- Centralized system order for consistent sorting across the module
M.SYSTEM_ORDER = {
  ['freeroam'] = 1,
  ['challenges'] = 2,
  ['scenarios'] = 3,
  ['scenariosMultiplayer'] = 4,
  ['campaigns'] = 5,
  ['Other...'] = 6,
}

-- Base sorting function that puts "Other..." items last
local function sortByNameButOtherAlwaysLast(a, b)
  local aName = a.Name or a.name or a.label or ""
  local bName = b.Name or b.name or b.label or ""

  if aName == _tr("ui.menu.gridSelector.other") then
    return false
  elseif bName == _tr("ui.menu.gridSelector.other") then
    return true
  end
  return aName < bName
end

local function sortBySystem(a, b)
  local aSystem = a.system or _tr("ui.menu.gridSelector.other")
  local bSystem = b.system or _tr("ui.menu.gridSelector.other")

  if aSystem == bSystem then
    return sortByNameButOtherAlwaysLast(a, b)
  end

  local aSystemOrder = M.SYSTEM_ORDER[aSystem]
  local bSystemOrder = M.SYSTEM_ORDER[bSystem]

  if aSystemOrder == nil then
    return false
  end
  if bSystemOrder == nil then
    return true
  end

  return aSystemOrder < bSystemOrder
end

-- Helper function to compare clustered vs non-clustered items
local function compareClusteredStatus(a, b)
  local aIsClustered = a.isClustered or false
  local bIsClustered = b.isClustered or false

  if aIsClustered and not bIsClustered then
    return true
  elseif not aIsClustered and bIsClustered then
    return false
  elseif aIsClustered and bIsClustered then
    -- Both clustered, sort by name
    return sortByNameButOtherAlwaysLast(a, b)
  end

  return nil -- Neither clustered, continue with other comparisons
end

-- Helper function to compare auxiliary status
local function compareAuxiliaryStatus(a, b)
  local aIsAuxiliary = a.isAuxiliary or false
  local bIsAuxiliary = b.isAuxiliary or false

  if aIsAuxiliary ~= bIsAuxiliary then
    return not aIsAuxiliary -- non-auxiliary first
  end

  return nil -- Same auxiliary status, continue
end

-- Helper function to compare career status (for challenges)
local function compareCareerStatus(a, b)
  local aIsCareer = a.isCareerOnly or false
  local bIsCareer = b.isCareerOnly or false

  if aIsCareer ~= bIsCareer then
    return not aIsCareer -- non-career first
  end

  return nil -- Same career status, continue
end

-- Helper function to compare order property
local function compareOrderProperty(a, b)
  local aOrderProp = a.order or math.huge
  local bOrderProp = b.order or math.huge

  if aOrderProp ~= bOrderProp then
    return aOrderProp < bOrderProp
  end

  return nil -- Same order, continue
end

-- Gameplay automatic sorting with complex rules
local function sortByGameplayAutomatic(a, b)
  -- First: tiles created by clustering (always sorted by name)
  local clusteredResult = compareClusteredStatus(a, b)
  if clusteredResult ~= nil then
    return clusteredResult
  end

  -- Second: sort by system order
  local aSystem = a.system or OTHER_PLACEHOLDER
  local bSystem = b.system or OTHER_PLACEHOLDER
  local aOrder = M.SYSTEM_ORDER[aSystem] or UNKNOWN_SYSTEM_ORDER
  local bOrder = M.SYSTEM_ORDER[bSystem] or UNKNOWN_SYSTEM_ORDER

  if aOrder ~= bOrder then
    return aOrder < bOrder
  end

  -- Within same system, handle auxiliary items (always at the end)
  local auxiliaryResult = compareAuxiliaryStatus(a, b)
  if auxiliaryResult ~= nil then
    return auxiliaryResult
  end

  -- Within same auxiliary status, handle special sorting for challenges
  if aSystem == "Challenges" and bSystem == "Challenges" then
    -- First: non-career missions, then career missions
    local careerResult = compareCareerStatus(a, b)
    if careerResult ~= nil then
      return careerResult
    end

    -- Within same career status, sort by order property
    local orderResult = compareOrderProperty(a, b)
    if orderResult ~= nil then
      return orderResult
    end

    -- If no order, sort by name
    return sortByNameButOtherAlwaysLast(a, b)
  else
    -- For other systems, sort by order property
    local orderResult = compareOrderProperty(a, b)
    if orderResult ~= nil then
      return orderResult
    end

    -- If no order, sort by name
    return sortByNameButOtherAlwaysLast(a, b)
  end
end

-- Date sorting function (newest first)
local function sortByDate(a, b)
  local aDate = a.date
  local bDate = b.date

  -- If dates are equal, fall back to name sorting
  if aDate == bDate then
    return sortByNameButOtherAlwaysLast(a, b)
  end

  -- without date, sort to the end
  if not aDate then
    return false
  end
  if not bDate then
    return true
  end


  -- Sort by date descending (newest first)
  return aDate > bDate
end

-- Sort function lookup table
local sortFunctions = {
  ['Name'] = sortByNameButOtherAlwaysLast,
  ['System'] = sortBySystem,
  ['GameplayAutomatic'] = sortByGameplayAutomatic,
  ['Date'] = sortByDate,
}

-- Valid sort modes for validation
M.VALID_SORT_MODES = {
  'Name', 'System', 'GameplayAutomatic', 'Date'
}

-- Mapping from UI display values to internal sort modes
M.UI_TO_SORT_MODE = {
  ['name'] = 'Name',
  ['automatic'] = 'GameplayAutomatic',
  ['date'] = 'Date',
  ['system'] = 'System'
}

-- Reverse mapping for debugging/logging
M.SORT_MODE_TO_UI = {}
for uiValue, sortMode in pairs(M.UI_TO_SORT_MODE) do
  M.SORT_MODE_TO_UI[sortMode] = uiValue
end

-- Public API
function M.getSortFunction(sortMode)
  if not sortMode or type(sortMode) ~= 'string' then
    log("W", "tileSorting", "Invalid sort mode provided: " .. tostring(sortMode))
    return sortFunctions[DEFAULT_SORT_MODE]
  end

  local sortFunc = sortFunctions[sortMode]
  if not sortFunc then
    log("W", "tileSorting", "Unknown sort mode: " .. sortMode .. ", falling back to " .. DEFAULT_SORT_MODE)
    return sortFunctions[DEFAULT_SORT_MODE]
  end

  return sortFunc
end

function M.isValidSortMode(sortMode)
  return sortFunctions[sortMode] ~= nil
end

function M.convertUIValueToSortMode(uiValue)
  if not uiValue or type(uiValue) ~= 'string' then
    return DEFAULT_SORT_MODE -- Default fallback
  end

  local sortMode = M.UI_TO_SORT_MODE[uiValue]
  if not sortMode then
    log("W", "tileSorting", "Unknown UI sort value: " .. uiValue .. ", using " .. DEFAULT_SORT_MODE)
    return DEFAULT_SORT_MODE
  end

  return sortMode
end

function M.sortTilesFromUIValue(tiles, uiSortValue)
  local sortMode = M.convertUIValueToSortMode(uiSortValue)
  M.sortTiles(tiles, sortMode)
end

function M.sortTiles(tiles, sortMode)
  local sortFunc = M.getSortFunction(sortMode)
  table.sort(tiles, sortFunc)
end

function M.sortByNameButOtherAlwaysLast(a, b)
  return sortByNameButOtherAlwaysLast(a, b)
end

function M.sortBySystem(a, b)
  return sortBySystem(a, b)
end

function M.sortByGameplayAutomatic(a, b)
  return sortByGameplayAutomatic(a, b)
end

function M.sortByDate(a, b)
  return sortByDate(a, b)
end

-- Group-level sorting function for general sorting cases
function M.sortGroup(group, sortMode)
  M.sortTiles(group.tiles, sortMode)
end

return M
