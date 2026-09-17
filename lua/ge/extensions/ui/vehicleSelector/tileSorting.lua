local M = {}

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

-- Sorting functions for different criteria
local function sortByValue(a, b)
  local aValue = a.Value or a.value or 0
  local bValue = b.Value or b.value or 0
  if type(aValue) == 'table' then
    aValue = aValue.min
  end
  if type(bValue) == 'table' then
    bValue = bValue.min
  end
  if aValue == bValue then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return aValue < bValue
end

local function sortByYears(a, b)
  local aYears = a.Years or a.years or math.huge
  local bYears = b.Years or b.years or math.huge
  if type(aYears) == 'table' then
    aYears = aYears.min
  end
  if type(bYears) == 'table' then
    bYears = bYears.min
  end
  if aYears == bYears then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return aYears < bYears
end

local function sortByWeight(a, b)
  local aWeight = a.Weight or a.weight or 0
  local bWeight = b.Weight or b.weight or 0
  if aWeight == bWeight then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return aWeight < bWeight
end

local function sortByTopSpeed(a, b)
  local aTopSpeed = a['Top Speed'] or a.topSpeed or 0
  local bTopSpeed = b['Top Speed'] or b.topSpeed or 0
  if aTopSpeed == bTopSpeed then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return aTopSpeed < bTopSpeed
end

local function sortByPower(a, b)
  local aPower = a.Power or a.power or 0
  local bPower = b.Power or b.power or 0
  if aPower == bPower then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return aPower < bPower
end

local function sortByWeightPower(a, b)
  local aWeight = a.Weight or a.weight or 0
  local aPower = a.Power or a.power or 0
  local bWeight = b.Weight or b.weight or 0
  local bPower = b.Power or b.power or 0
  local aWeightPower = aWeight > 0 and aPower > 0 and aWeight / aPower or math.huge
  local bWeightPower = bWeight > 0 and bPower > 0 and bWeight / bPower or math.huge
  if aWeightPower == bWeightPower then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return aWeightPower > bWeightPower
end

local function sortBy0To60(a, b)
  local a0To60 = a['0-60 mph'] or a.zeroTo60 or math.huge
  local b0To60 = b['0-60 mph'] or b.zeroTo60 or math.huge
  if a0To60 == b0To60 then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return a0To60 > b0To60
end

local function sortBy0To100(a, b)
  local a0To100 = a['0-100 km/h'] or a.zeroTo100 or math.huge
  local b0To100 = b['0-100 km/h'] or b.zeroTo100 or math.huge
  if a0To100 == b0To100 then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  return a0To100 > b0To100
end

-- Config type sorting with predefined order
local configTypeOrder = {
  ['Factory'] = 1,
  ['Service'] = 2,
  ['Race'] = 3,
  ['Drift'] = 4,
  ['Rally'] = 5,
  ['Police'] = 6,
  ['Custom'] = 7,
  ['Powerglow'] = 8,
  ['Other...'] = 9,
}

local function sortByConfigTypeName(a, b)
  local aConfigTypeName = a['Config Type'] or "Other..."
  local bConfigTypeName = b['Config Type'] or "Other..."
  if aConfigTypeName == bConfigTypeName then
    return sortByNameButOtherAlwaysLast(a, b)
  end
  local aConfigTypeOrder = configTypeOrder[aConfigTypeName]
  local bConfigTypeOrder = configTypeOrder[bConfigTypeName]
  if aConfigTypeOrder == nil then
    return false
  end
  if bConfigTypeOrder == nil then
    return true
  end
  return aConfigTypeOrder < bConfigTypeOrder
end

-- Sort function lookup table
local sortFunctions = {
  ['Name'] = sortByNameButOtherAlwaysLast,
  ['Value'] = sortByValue,
  ['Years'] = sortByYears,
  ['Weight'] = sortByWeight,
  ['Top Speed'] = sortByTopSpeed,
  ['Power'] = sortByPower,
  ['Weight/Power'] = sortByWeightPower,
  ['0-60 mph'] = sortBy0To60,
  ['0-100 km/h'] = sortBy0To100,
  ['Config Type'] = sortByConfigTypeName,
}

-- Public API
function M.getSortFunction(sortMode)
  return sortFunctions[sortMode] or sortByNameButOtherAlwaysLast
end

function M.sortTiles(tiles, sortMode)
  local sortFunc = M.getSortFunction(sortMode)
  table.sort(tiles, sortFunc)
end

function M.sortByNameButOtherAlwaysLast(a, b)
  return sortByNameButOtherAlwaysLast(a, b)
end

function M.sortByValue(a, b)
  return sortByValue(a, b)
end

function M.sortByYears(a, b)
  return sortByYears(a, b)
end

function M.sortByConfigTypeName(a, b)
  return sortByConfigTypeName(a, b)
end

-- Group-level sorting function for general sorting cases
function M.sortGroup(group, sortMode)
  M.sortTiles(group.tiles, sortMode)
end

return M
