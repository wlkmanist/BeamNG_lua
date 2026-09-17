-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Resolves a `vehicleFilters` settings table (as produced by the
-- `addVehicleFilter` mission editor element and stored in
-- `missionTypeData.vehicleFilters`) into a flat list of
-- `{model, config, name}` entries.
--
-- The logic mirrors `gameplay/missionTypes/garageToGarage/constructor.lua`
-- so this can be reused by flowgraph nodes and other mission types that
-- expose the same filter UI.

local M = {}

local function convertFilterToConfigListFormat(filter)
  if not filter or not filter.propName then return nil end
  local propName = filter.propName
  local whiteList = {}

  if filter.type == 'range' then
    if filter.values and filter.values.min and filter.values.max then
      whiteList[propName] = {min = filter.values.min, max = filter.values.max}
    end
  elseif filter.type == 'set' then
    if filter.values then
      local selected = {}
      for option, isSelected in pairs(filter.values) do
        if isSelected and option ~= 'Other...' then
          table.insert(selected, option)
        end
      end
      if #selected > 0 then
        whiteList[propName] = selected
      end
    end
  end

  if next(whiteList) then
    return {whiteList = whiteList}
  end
  return nil
end

local function convertFilterList(filterArray)
  local result = {}
  if not filterArray then return result end
  for _, filter in ipairs(filterArray) do
    local converted = convertFilterToConfigListFormat(filter)
    if converted and converted.whiteList then
      table.insert(result, converted.whiteList)
    end
  end
  return result
end

local function doesVehiclePassConvertedFilter(vehicleInfo, filterConverted, configListGenerator)
  if filterConverted.whiteList and #filterConverted.whiteList > 0 then
    local passes = false
    for _, wl in ipairs(filterConverted.whiteList) do
      if configListGenerator.doesVehiclePassFilter(vehicleInfo, {whiteList = wl}) then
        passes = true
        break
      end
    end
    if not passes then return false end
  end
  if filterConverted.blackList and #filterConverted.blackList > 0 then
    for _, bl in ipairs(filterConverted.blackList) do
      if configListGenerator.doesVehiclePassFilter(vehicleInfo, {whiteList = bl}) then
        return false
      end
    end
  end
  return true
end

local function buildVehicleByModelKey()
  local lookup = {}
  local vehList = core_vehicles.getVehicleList()
  if not vehList or not vehList.vehicles then return lookup end
  for _, v in ipairs(vehList.vehicles) do
    lookup[v.model.key] = v
  end
  return lookup
end

local function getNiceVehicleName(modelKey, configKey, vehicleByModelKey)
  local vehicle = vehicleByModelKey[modelKey]
  if not vehicle then return modelKey .. "/" .. configKey end
  local model = vehicle.model
  local config = vehicle.configs and vehicle.configs[configKey]
  local parts = {}
  if model.Brand then table.insert(parts, model.Brand) end
  if model.Name then table.insert(parts, model.Name) end
  if config and config.Configuration then table.insert(parts, config.Configuration) end
  if #parts == 0 then return modelKey .. "/" .. configKey end
  return table.concat(parts, " ")
end

local function buildBaseFilter(filterData)
  if not filterData.baseFilter then return nil end
  local wl = convertFilterList(filterData.baseFilter.whiteList)
  local bl = convertFilterList(filterData.baseFilter.blackList)
  if #wl == 0 and #bl == 0 then return nil end
  return {whiteList = wl, blackList = bl}
end

local function applyBaseFilter(eligibleVehicles, baseFilterConverted, configListGenerator)
  if not baseFilterConverted then return eligibleVehicles end
  local out = {}
  for _, vi in ipairs(eligibleVehicles) do
    if doesVehiclePassConvertedFilter(vi, baseFilterConverted, configListGenerator) then
      table.insert(out, vi)
    end
  end
  return out
end

local function applyProbabilitySettings(eligibleVehicles, probabilitySettings, baseFilterConverted, configListGenerator)
  local matched = {}
  local seen = {}
  for _, setting in ipairs(probabilitySettings) do
    local wl = convertFilterList(setting.whiteList)
    local bl = convertFilterList(setting.blackList)
    if #wl > 0 or #bl > 0 then
      local subFilter = {whiteList = wl, blackList = bl}
      for _, vi in ipairs(eligibleVehicles) do
        local key = vi.model_key .. "/" .. vi.key
        if not seen[key] then
          if doesVehiclePassConvertedFilter(vi, subFilter, configListGenerator) and
             (not baseFilterConverted or doesVehiclePassConvertedFilter(vi, baseFilterConverted, configListGenerator)) then
            table.insert(matched, vi)
            seen[key] = true
          end
        end
      end
    end
  end
  return matched
end

local function limitToMaxVehicles(list, maxVehicles)
  if not maxVehicles or maxVehicles <= 0 or #list <= maxVehicles then
    return list
  end
  local indices = {}
  for i = 1, #list do indices[i] = i end
  local selected = {}
  for _ = 1, maxVehicles do
    local pick = math.random(#indices)
    table.insert(selected, list[indices[pick]])
    table.remove(indices, pick)
  end
  return selected
end

local function buildRemovalsNested(manualRemovals)
  local nested = {}
  for configKey in pairs(manualRemovals or {}) do
    local m, c = string.match(configKey, "^([^/]+)/(.+)$")
    if m and c then
      nested[m] = nested[m] or {}
      nested[m][c] = true
    end
  end
  return nested
end

-- Returns true if `filterData` has any filter, manual addition, or manual removal
-- that would meaningfully constrain the eligible vehicle set.
function M.hasAnyConfiguration(filterData)
  if type(filterData) ~= "table" then return false end
  if filterData.baseFilter then
    local wl = filterData.baseFilter.whiteList
    local bl = filterData.baseFilter.blackList
    if (wl and #wl > 0) or (bl and #bl > 0) then return true end
  end
  if filterData.probabilitySettings and #filterData.probabilitySettings > 0 then return true end
  if filterData.manualAdditions and #filterData.manualAdditions > 0 then return true end
  if filterData.manualRemovals and next(filterData.manualRemovals) then return true end
  if filterData.maxVehicles and filterData.maxVehicles > 0 then return true end
  return false
end

-- Resolves the given `filterData` into a flat list of `{model, config, name}` entries.
-- Always returns a table (possibly empty). Honors base filter, probability settings,
-- manual additions, manual removals, maxVehicles, and auxiliary/trailer flags.
function M.resolveFilteredConfigs(filterData)
  local results = {}
  if type(filterData) ~= "table" then return results end

  local configListGenerator = require('/lua/ge/extensions/util/configListGenerator')
  local eligibleVehicles = configListGenerator.getEligibleVehicles(
    filterData.allowAuxiliaryVehicles or false,
    filterData.allowLoadedTrailers or false
  )

  local baseFilterConverted = buildBaseFilter(filterData)
  local filteredVehicles = applyBaseFilter(eligibleVehicles, baseFilterConverted, configListGenerator)

  if filterData.probabilitySettings and #filterData.probabilitySettings > 0 then
    local probMatched = applyProbabilitySettings(eligibleVehicles, filterData.probabilitySettings, baseFilterConverted, configListGenerator)
    if #probMatched > 0 then
      filteredVehicles = probMatched
    end
  end

  filteredVehicles = limitToMaxVehicles(filteredVehicles, filterData.maxVehicles)

  local removalsNested = buildRemovalsNested(filterData.manualRemovals)
  local vehicleByModelKey = buildVehicleByModelKey()
  local seenSet = {}

  for _, vi in ipairs(filteredVehicles) do
    local m, c = vi.model_key, vi.key
    local removed = removalsNested[m] and removalsNested[m][c]
    local alreadyIn = seenSet[m] and seenSet[m][c]
    if not removed and not alreadyIn then
      table.insert(results, {
        model = m,
        config = c,
        name = getNiceVehicleName(m, c, vehicleByModelKey)
      })
      seenSet[m] = seenSet[m] or {}
      seenSet[m][c] = true
    end
  end

  for _, ma in ipairs(filterData.manualAdditions or {}) do
    if ma.model and ma.config then
      local m, c = ma.model, ma.config
      if not (seenSet[m] and seenSet[m][c]) then
        local name = ma.name
        if not name or name == c then
          name = getNiceVehicleName(m, c, vehicleByModelKey)
        end
        table.insert(results, {model = m, config = c, name = name})
        seenSet[m] = seenSet[m] or {}
        seenSet[m][c] = true
      end
    end
  end

  return results
end

return M
