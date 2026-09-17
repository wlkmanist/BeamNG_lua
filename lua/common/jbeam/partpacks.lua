-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Part packs quickstart
--
-- Put filters under "filters" in each pack:
-- {
--   "path": "/example",
--   "filters": {
--     "slotWhitelist": { "wl40_counterweight_R": "empty", "tow_*": "nonempty" },
--     "slotBlacklist": { "paint_design": "present" },
--     "vehicleWhitelist": ["wl40", "etk_*"],
--     "partNameWhitelist": ["wheel_*", "wl40_tire_R"],
--     "pathWhitelist": ["*/wl40_differential_R/*"]
--   }
-- }
--
-- Supported keys (all optional):
-- - slotWhitelist: required slot states. Example: { "tow_hitch": "nonempty", "wl40_counterweight_R": "empty", "axle_*": "present" }
-- - slotBlacklist: forbidden slot states. Example: { "paint_design": "present" }
-- - vehicleWhitelist: required vehicle names/patterns. Example: ["wl40", "etk_*"]
-- - vehicleBlacklist: forbidden vehicle names/patterns. Example: ["test_*", "deprecated_*"]
-- - partNameWhitelist: required chosen part names/patterns. Example: ["wl40_wheel_R", "wheel_*"]
-- - partNameBlacklist: forbidden chosen part names/patterns. Example: ["wl40_wheel_R_dually", "*_race*"]
-- - pathWhitelist: required part.path values/patterns. Example: ["/wl40_frame_R/wl40_axle_R/", "*/wl40_differential_R/*"]
-- - pathBlacklist: forbidden part.path values/patterns. Example: ["/wl40_frame_R/wl40_spare/", "*/deprecated/*"]
--
-- Rules:
-- - Whitelist: all entries must match
-- - Blacklist: any entry match hides the pack
-- - Rule keys in all filters can use "*" wildcard (example: "axle_*")
-- - Generic filters (partName/path) are string lists
-- - Slot filter values: true | "present" | "empty" | "nonempty"
-- - Invalid filter formats are logged and the pack is hidden

local M = {}
local collectCacheByDirectories = {}

local function getDirectoriesKey(vehicleDirectories)
  return table.concat(vehicleDirectories or {}, '\n')
end

local function invalidateCollectCache()
  collectCacheByDirectories = {}
end

local function collectAllPartPacks(vehicleDirectories)
  vehicleDirectories = vehicleDirectories or {}
  local directoriesKey = getDirectoriesKey(vehicleDirectories)
  local cacheEntry = collectCacheByDirectories[directoriesKey]
  if cacheEntry then
    return cacheEntry
  end

  local res = {}

  for _, vehicleDirectory in ipairs(vehicleDirectories) do
    local files = FS:findFiles(vehicleDirectory, "*.partpacks.json", -1, true, false) or {}
    for _, filePath in ipairs(files) do
      local fileData = jsonReadFile(filePath)
      if type(fileData) == 'table' then
        for _, pack in ipairs(fileData) do
          if pack and type(pack.path) == 'string' then
            if res[pack.path] then
              log('W', 'partpacks', 'duplicate part pack path ' .. tostring(pack.path) .. ' in ' .. tostring(filePath))
            end
            res[pack.path] = pack
            pack.path = nil
          else
            log('E', 'partpacks', 'invalid part pack format in ' .. tostring(filePath) .. ' (expected object with path string): ' .. dumps(pack))
          end
        end
      else
        log('E', 'partpacks', 'invalid partpacks format in ' .. tostring(filePath) .. ' (expected array): ' .. dumps(fileData))
      end
    end
  end

  --dump('partpacks: ', res)
  collectCacheByDirectories[directoriesKey] = res
  return res
end

local function gatherInstalledData(part, outData)
  if type(part) ~= 'table' then return end

  local partId = part.id
  local chosenPartName = part.chosenPartName
  local partPath = part.path

  if type(partId) == 'string' and partId ~= '' then
    outData.slots[part.id] = true
    if type(chosenPartName) ~= 'string' or chosenPartName == '' then
      outData.emptySlots[partId] = true
    end
  end

  if type(chosenPartName) == 'string' and chosenPartName ~= '' then
    outData.partNames[chosenPartName] = true
    table.insert(outData.partNamesList, chosenPartName)
  end

  if type(partPath) == 'string' and partPath ~= '' then
    outData.paths[partPath] = true
    table.insert(outData.pathsList, partPath)
  end

  for _, child in pairs(part.children or {}) do
    gatherInstalledData(child, outData)
  end
end

local filterFields = {
  'slotWhitelist',
  'slotBlacklist',
  'vehicleWhitelist',
  'vehicleBlacklist',
  'partNameWhitelist',
  'partNameBlacklist',
  'pathWhitelist',
  'pathBlacklist'
}

local function getPackFilters(packPath, pack)
  local filters = pack.filters
  if filters == nil then
    return {}
  end
  if type(filters) ~= 'table' then
    log('E', 'partpacks', "invalid filter type for pack '" .. tostring(packPath) .. "': filters must be a table")
    return nil
  end

  for _, fieldName in ipairs(filterFields) do
    local value = filters[fieldName]
    if value ~= nil and type(value) ~= 'table' then
      log('E', 'partpacks', "invalid filter type for pack '" .. tostring(packPath) .. "': filters." .. fieldName .. " must be a table")
      return nil
    end
  end

  return filters
end

local function collectInstalled(partsTree)
  local outData = {
    slots = {},
    emptySlots = {},
    partNames = {},
    partNamesList = {},
    paths = {},
    pathsList = {}
  }
  gatherInstalledData(partsTree, outData)
  return outData
end

local function wildcardToLuaPattern(wildcard)
  local escaped = wildcard:gsub("([%^%$%(%)%%%.%[%]%+%-%?])", "%%%1")
  return "^" .. escaped:gsub("%*", ".*") .. "$"
end

local function hasWildcard(value)
  return type(value) == 'string' and value:find("%*", 1, true) ~= nil
end

local function hasWildcardInMap(map)
  for key in pairs(map or {}) do
    if hasWildcard(key) then
      return true
    end
  end
  return false
end

local function matchesAnyPattern(valueList, wildcard, cache)
  if cache[wildcard] ~= nil then
    return cache[wildcard]
  end
  local luaPattern = wildcardToLuaPattern(wildcard)
  for _, value in ipairs(valueList) do
    if value:match(luaPattern) then
      cache[wildcard] = true
      return true
    end
  end
  cache[wildcard] = false
  return false
end

local function buildSlotStateFilters(filters)
  local whitelist = {}
  local blacklist = {}

  for slotName, state in pairs(filters.slotWhitelist or {}) do
    whitelist[slotName] = state
  end
  for slotName, state in pairs(filters.slotBlacklist or {}) do
    blacklist[slotName] = state
  end

  return whitelist, blacklist
end

local function matchKey(key, installedSet, installedList, patternCache)
  if type(key) ~= 'string' or key == '' then
    return nil
  end
  if hasWildcard(key) then
    return matchesAnyPattern(installedList, key, patternCache)
  end
  return installedSet[key] == true
end

local function matchSlotState(slotName, expectedState, installedSlotsData, emptySlotsData)
  if expectedState == true or expectedState == 'present' then
    return installedSlotsData[slotName] == true
  end
  if expectedState == 'empty' then
    return emptySlotsData[slotName] == true
  end
  if expectedState == 'nonempty' then
    return installedSlotsData[slotName] == true and emptySlotsData[slotName] ~= true
  end
  return nil
end

local function applySlotStateMap(rules, mode, installedSlotsData, emptySlotsData, installedSlotNames, slotPatternCache)
  for slotKey, expectedState in pairs(rules or {}) do
    if type(slotKey) ~= 'string' or slotKey == '' then
      return false, "invalid slot" .. mode .. " key"
    end

    if not hasWildcard(slotKey) then
      local stateMatches = matchSlotState(slotKey, expectedState, installedSlotsData, emptySlotsData)
      if stateMatches == nil then
        return false, "invalid slot value for '" .. slotKey .. "' (expected true, 'present', 'empty' or 'nonempty')"
      end
      if mode == "Whitelist" and not stateMatches then
        return false, "slot '" .. slotKey .. "' did not match state '" .. tostring(expectedState) .. "'"
      end
      if mode == "Blacklist" and stateMatches then
        return false, "slot '" .. slotKey .. "' matched blacklisted state '" .. tostring(expectedState) .. "'"
      end
    else
      local luaPattern = slotPatternCache[slotKey]
      if luaPattern == nil then
        luaPattern = wildcardToLuaPattern(slotKey)
        slotPatternCache[slotKey] = luaPattern
      end

      local matchedAny = false
      local matchedExpected = false
      for _, slotName in ipairs(installedSlotNames) do
        if slotName:match(luaPattern) then
          matchedAny = true
          local stateMatches = matchSlotState(slotName, expectedState, installedSlotsData, emptySlotsData)
          if stateMatches == nil then
            return false, "invalid slot value for '" .. slotKey .. "' (expected true, 'present', 'empty' or 'nonempty')"
          end
          if stateMatches then
            matchedExpected = true
            if mode == "Blacklist" then
              return false, "slot pattern '" .. slotKey .. "' matched blacklisted state '" .. tostring(expectedState) .. "'"
            end
            break
          end
        end
      end

      if mode == "Whitelist" and not matchedAny then
        return false, "no slot matched whitelisted pattern '" .. slotKey .. "'"
      end
      if mode == "Whitelist" and not matchedExpected then
        return false, "slot pattern '" .. slotKey .. "' did not match state '" .. tostring(expectedState) .. "'"
      end
    end
  end
  return true
end

local function applyGenericList(rules, mode, label, installedSet, installedList, patternCache)
  rules = rules or {}
  local hasWildcardEntry = false
  for _, key in ipairs(rules) do
    if hasWildcard(key) then
      hasWildcardEntry = true
      break
    end
  end

  if not hasWildcardEntry then
    for _, key in ipairs(rules) do
      if type(key) ~= 'string' or key == '' then
        return false, "invalid " .. label .. mode .. " key"
      end
      local isMatch = installedSet[key] == true
      if mode == "Whitelist" and not isMatch then
        return false, "missing whitelisted " .. label .. " '" .. key .. "'"
      end
      if mode == "Blacklist" and isMatch then
        return false, "blacklisted " .. label .. " '" .. key .. "' matched"
      end
    end
    return true
  end

  for _, key in ipairs(rules) do
    local isMatch = matchKey(key, installedSet, installedList, patternCache)
    if isMatch == nil then
      return false, "invalid " .. label .. mode .. " key"
    end
    if mode == "Whitelist" and not isMatch then
      return false, "missing whitelisted " .. label .. " '" .. key .. "'"
    end
    if mode == "Blacklist" and isMatch then
      return false, "blacklisted " .. label .. " '" .. key .. "' matched"
    end
  end
  return true
end

local function filter(partPacksCatalog, installedData, vehicleModel)

  local filtered = {}
  local stats = {
    total = 0,
    shown = 0,
    hidden = 0,
    invalid = 0
  }
  installedData = installedData or {}
  local installedSlots = installedData.slots or {}
  local emptySlots = installedData.emptySlots or {}
  local installedPartNames = installedData.partNames or {}
  local installedPartNamesList = installedData.partNamesList or {}
  local installedPaths = installedData.paths or {}
  local installedPathsList = installedData.pathsList or {}
  local installedVehicleNames = {}
  local installedVehicleNamesList = {}
  if type(vehicleModel) == 'string' and vehicleModel ~= '' then
    installedVehicleNames[vehicleModel] = true
    installedVehicleNamesList[1] = vehicleModel
  end
  local vehiclePatternCache = {}
  local partNamePatternCache = {}
  local pathPatternCache = {}
  local slotKeyPatternCache = {}
  local installedSlotNames = nil

  for packPath, pack in pairs(partPacksCatalog or {}) do
    stats.total = stats.total + 1
    local filters = getPackFilters(packPath, pack)
    if not filters then
      stats.invalid = stats.invalid + 1
      stats.hidden = stats.hidden + 1
      log('D', 'partpacks', "hiding part pack '" .. tostring(packPath) .. "': invalid filter format")
    else
      local showPack = true
      local reason = nil

      if showPack then
        showPack, reason = applyGenericList(filters.vehicleWhitelist, "Whitelist", "vehicle", installedVehicleNames, installedVehicleNamesList, vehiclePatternCache)
      end
      if showPack then
        showPack, reason = applyGenericList(filters.vehicleBlacklist, "Blacklist", "vehicle", installedVehicleNames, installedVehicleNamesList, vehiclePatternCache)
      end

      local slotWhitelist, slotBlacklist = buildSlotStateFilters(filters)
      if (hasWildcardInMap(slotWhitelist) or hasWildcardInMap(slotBlacklist)) and not installedSlotNames then
        installedSlotNames = {}
        for slotName in pairs(installedSlots) do
          table.insert(installedSlotNames, slotName)
        end
      end
      if showPack then
        showPack, reason = applySlotStateMap(slotWhitelist, "Whitelist", installedSlots, emptySlots, installedSlotNames or {}, slotKeyPatternCache)
      end
      if showPack then
        showPack, reason = applySlotStateMap(slotBlacklist, "Blacklist", installedSlots, emptySlots, installedSlotNames or {}, slotKeyPatternCache)
      end
      if showPack then
        showPack, reason = applyGenericList(filters.partNameWhitelist, "Whitelist", "partName", installedPartNames, installedPartNamesList, partNamePatternCache)
      end
      if showPack then
        showPack, reason = applyGenericList(filters.partNameBlacklist, "Blacklist", "partName", installedPartNames, installedPartNamesList, partNamePatternCache)
      end
      if showPack then
        showPack, reason = applyGenericList(filters.pathWhitelist, "Whitelist", "path", installedPaths, installedPathsList, pathPatternCache)
      end
      if showPack then
        showPack, reason = applyGenericList(filters.pathBlacklist, "Blacklist", "path", installedPaths, installedPathsList, pathPatternCache)
      end

      if showPack then
        filtered[packPath] = pack
        stats.shown = stats.shown + 1
        log('D', 'partpacks', "showing part pack '" .. tostring(packPath) .. "': filters matched")
      else
        stats.hidden = stats.hidden + 1
        log('D', 'partpacks', "hiding part pack '" .. tostring(packPath) .. "': " .. tostring(reason))
      end
    end
  end

  return filtered, stats
end

local function process(vehicleDirectories, partsTree, vehicleModel)
  local t0 = os.clockhp()
  local partPacksCatalog = collectAllPartPacks(vehicleDirectories)
  local t1 = os.clockhp()
  local installedData = collectInstalled(partsTree)
  local t2 = os.clockhp()
  local filtered, stats = filter(partPacksCatalog, installedData, vehicleModel)
  local t3 = os.clockhp()

  log('I', 'partpacks', string.format('timing: collect=%.0fms, collectInstalled=%.0fms, filter=%.0fms, total=%.0fms', (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000, (t3 - t0) * 1000))
  log('I', 'partpacks', string.format('counts: total=%d, shown=%d, hidden=%d, invalid=%d', stats.total or 0, stats.shown or 0, stats.hidden or 0, stats.invalid or 0))

  return filtered
end

M.collectAllPartPacks = collectAllPartPacks
M.invalidateCollectCache = invalidateCollectCache
M.collectInstalled = collectInstalled
M.filter = filter
M.process = process

return M
