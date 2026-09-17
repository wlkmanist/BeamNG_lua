--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

-- /!\ do not change this file without speaking to tdev

local M = {}

local tableInsert, tableClear = table.insert, table.clear

local jbeamUtils = require("jbeam/utils")
local jbeamTableSchema = require('jbeam/tableSchema')
local stringBufferEncode, stringBufferDecode = jbeamUtils.stringBufferEncode, jbeamUtils.stringBufferDecode

-- part caches
local fileCache = {} -- filename > part cache entry

-- what directories are cached: map directory path to number of jbeam files they contain
local jbeamFilenameDirCache = {}

-- below are rebuild from fresh using fileCache, on any change
local partFileMap = {}
local partSlotMap = {}
local partNameMap = {}

local modManager = nil
local lastStartLoadingStats = { total = 0, cachedHits = 0 }

local function _processSlotsV1DestructiveBackwardCompatibility(slots, newSlots)
  local addedSlots = 0
  for k, slotSectionRow in ipairs(slots) do
    if slotSectionRow[1] == "type" then goto continue end -- ignore the header

    local slot = {}

    slot.type = slotSectionRow[1]
    slot.default = slotSectionRow[2]
    slot.description = slot.type

    if #slotSectionRow > 2 and type(slotSectionRow[3]) == 'string' then
      slot.description = slotSectionRow[3]
    end
    if #slotSectionRow > 3 and type(slotSectionRow[4]) == 'table' then
      tableMerge(slot, slotSectionRow[4])
    end
    tableInsert(newSlots, slot)
    addedSlots = addedSlots + 1

    ::continue::
  end
  return addedSlots
end

local function _processSlotsDestructiveLegacy(part, sourceFilename)
  if type(part.slots) ~= 'table' then return nil end

  local newSlots = {}
  if #part.slots > 0 and type(part.slots[1]) == 'table' and part.slots[1][1] ~= 'type' then
    -- backward compatibility: some parts miss the table header, which worked due to limitations before.
    log('W', 'slotSystem', 'Slot section of part ' .. tostring(part.partName) .. ' in file ' .. tostring(sourceFilename) ..' misses the table header. Adding default: ["type", "default", "description"]. Please fix.')
    tableInsert(part.slots, 1, {"type", "default", "description"})
  end
  local newListSize = jbeamTableSchema.processTableWithSchemaDestructive(part.slots, newSlots)
  if newListSize < 0 then
    -- fallback: use old code for old mods with errors
    newSlots = {}
    newListSize = _processSlotsV1DestructiveBackwardCompatibility(part.slots, newSlots)
    if newListSize < 0 then
      log('E', "", "Slots section in file " .. tostring(sourceFilename) .. " invalid. Unable to recover: " .. dumpsz(part.slots, 2))
    else
      log('W', "", "Slots section in file " .. tostring(sourceFilename) .. " invalid. Please fix. Partly reconstructed: " .. dumpsz(part.slots, 2))
    end
  end
  part.slots = newSlots
end

-- this function processes the slots / slots2
local function processSlotsDestructive(part, sourceFilename)
  --log('I', "", "Processing slots in file " .. tostring(sourceFilename) .. " ..." .. dumpsz(part, 2))
  if type(part.slots) ~= 'table' and type(part.slots2) ~= 'table' then return nil end

  if part.slots then
    _processSlotsDestructiveLegacy(part, sourceFilename)
    -- now upgrade to the new slots2 data structure
    for _, slot in ipairs(part.slots) do
      slot.name = slot.name or slot.type
      slot.allowTypes = {slot.type}
      slot.type = nil
      slot.denyTypes = {}
    end
    part.slots2 = part.slots
    part.slots = nil
  elseif part.slots2 then
    -- slots 2
    -- ["name", "allowTypes", "denyTypes", "default", "description"],
    local newSlots2 = {}
    local newListSize = jbeamTableSchema.processTableWithSchemaDestructive(part.slots2, newSlots2)
    if newListSize < 0 then
      log('E', "", "Slots section in file " .. tostring(sourceFilename) .. " invalid. Unable to recover: " .. dumpsz(part.slots2, 2))
    end
    --log('I', "", "Slots section in file " .. tostring(sourceFilename) .. " processed: " .. dumpsz(newSlots2, 2))
    part.slots2 = newSlots2
  end
  -- from here on we only have slots2 available
end

-- this filters the data we send to the UI as there is a lot of additonal data in there that we do not want
local function getSlotInfoDataForUi(slots)
  local res = table.new(0, #slots)
  for _, slot in ipairs(slots) do
    local s = {}
    s.name = slot.name or slot.type -- slots2 - new feature for uniquely identifying slots
    s.type = slot.type -- slots1, replaced by allowTypes and denyTypes
    --s.default = slot.default,
    s.allowTypes = slot.allowTypes -- slots2
    s.denyTypes = slot.denyTypes  -- slots2
    s.description = slot.description
    s.coreSlot = slot.coreSlot
    res[slot.name or slot.type] = s
  end
  return res
end

-- json decode the file
local function _parseFileIntoCache(filename)
  local ok, data = pcall(jsonReadFile, filename)
  if ok == false then
    log('E', "jbeam.parseFile","unable to decode JSON: "..tostring(filename))
    log('E', "jbeam.parseFile","JSON decoding error: "..tostring(data))
    return nil
  elseif data == nil then
    log('E', "jbeam.parseFile","unable to read file: "..tostring(filename))
    return nil
  end
  -- fix the slots sections
  local res = {}
  local parts = {}
  local partCounter = 0
  for partName, part in pairs(data) do
    -- this processes the slot and slot2 section
    processSlotsDestructive(part, filename)

    if type(part.slotType) ~= 'string' and type(part.slotType) ~= 'table' then
      log('E', "jbeam.loadJBeamFile", "part does not have a slot type. Ignoring: "..tostring(filename) .. ' - ' .. dumpsz(part, 2))
      goto continue2
    end
    parts[partName] = {}
    -- support for a part that fits in the correct slottype
    if type(part.slotType) == 'string' then
      parts[partName].slotTypes = {part.slotType}
    elseif type(part.slotType) == 'table' then
      parts[partName].slotTypes = part.slotType
    end
    local partDesc = {
      description = part.information.name or "",
      authors = part.information.authors or "",
      isAuxiliary = part.information.isAuxiliary,
      slotInfoUi = getSlotInfoDataForUi(part.slots2 or {})
    }
    if modManager then -- only available on the game engine side
      -- enrich the part with modName and ID
      local modName, modInfo = modManager.getModForFilename(filename)
      if modName then
        partDesc.modName = modName
        --partDesc.modID   = modInfo.modID
        --partDesc.modInfo = modInfo -- too much data
      end
    end

    part.partName = partName -- this is for backward compatibility of the surrounding code

    parts[partName].partDesc = partDesc
    parts[partName].partEncoded = stringBufferEncode(part)
    partCounter = partCounter + 1
    ::continue2::
  end
  res.partCount = partCounter
  res.parts = parts
  res.namespace = string.match(filename, "(/vehicles/[^/]*/).*$") -- yeah it's weird to have no leading slash :/
  return res
end

-- this function updates all the caches when one file changes or on rebuild
local function _updateGlobalCache()
  -- invalidate all caches as parts might have changed
  partFileMap = {}
  partSlotMap = {}
  partNameMap = {}

  -- walk all file caches to build the global caches together
  for filename, cacheData in pairs(fileCache) do
    --dumpz({"cacheData: ", cacheData}, 8)
    for partName, partData in pairs(cacheData.parts) do
      for _, slotType in ipairs(partData.slotTypes) do
        partSlotMap[cacheData.namespace] = partSlotMap[cacheData.namespace] or {}
        partSlotMap[cacheData.namespace][slotType] = partSlotMap[cacheData.namespace][slotType] or {}
        if tableContains(partSlotMap[cacheData.namespace][slotType], partName) then
          log('E', 'jbeam.loadJBeamFile', 'Duplicate part found: ' .. tostring(partName) .. ' from file ' .. tostring(filename))
        end
        tableInsert(partSlotMap[cacheData.namespace][slotType], partName)
      end
      partFileMap[cacheData.namespace] = partFileMap[cacheData.namespace] or {}
      partFileMap[cacheData.namespace][partName] = filename

      partNameMap[cacheData.namespace] = partNameMap[cacheData.namespace] or {}
      partNameMap[cacheData.namespace][partName] = partData.partDesc
      local desc = partData.partDesc and partData.partDesc.description
      if type(desc) == 'table' and desc.txt and _tr then
        partData.partDesc.description = desc.ctx and extensions.core_locales.contextTranslate(desc.txt, desc.ctx) or _tr(desc.txt)
      end
    end
  end

  --dumpz({"partFileMap: ", partFileMap}, 4)
  --dumpz({"partSlotMap: ", partSlotMap}, 4)
  --dumpz({"partNameMap: ", partNameMap}, 4)
end

local function _ensureJBeamFileLoaded(filename)
  if fileCache[filename] then
    return true
  end
  fileCache[filename] = _parseFileIntoCache(filename)
  return false
end

local function startLoading(directories)
  profilerPushEvent('jbeam/io.startLoading')

  --log('I', "jbeam.startLoading", "*** loading jbeam files: " .. dumps(directories))

  local cacheDirty = false
  local jbeamWasCached
  lastStartLoadingStats = { total = 0, cachedHits = 0 }
  for _, dir in ipairs(directories) do
    local numFiles = jbeamFilenameDirCache[dir]
    if numFiles == nil then
      numFiles = 0
      local filenames = FS:findFiles(dir, "*.jbeam", -1, false, false)
      for _, filename in ipairs(filenames) do
        jbeamWasCached = _ensureJBeamFileLoaded(filename)
        cacheDirty = cacheDirty or (not jbeamWasCached)
        if jbeamWasCached then lastStartLoadingStats.cachedHits = lastStartLoadingStats.cachedHits + 1 end
        numFiles = numFiles + 1
      end
      lastStartLoadingStats.total = lastStartLoadingStats.total + numFiles
      jbeamFilenameDirCache[dir] = numFiles
    else
      lastStartLoadingStats.total = lastStartLoadingStats.total + numFiles
      lastStartLoadingStats.cachedHits = lastStartLoadingStats.cachedHits + numFiles
    end
    --log('D', 'jbeam.startLoading', "Loaded " .. tostring(partCountTotal) .. " parts from " .. tostring(tableSize(jbeamCache)) .. ' jbeam files in ' .. tostring(dir))
  end

  -- we finished loading all the files, now create the lookup tables
  if cacheDirty then
    _updateGlobalCache()
  end

  profilerPopEvent('jbeam/io.startLoading')
  return { preloadedDirs = directories }
end

local function getPart(ioCtx, partName)
  if not partName then return end
  for _, dir in ipairs(ioCtx.preloadedDirs) do
    local jbeamFilename = partFileMap[dir][partName]
    if jbeamFilename then
      if not fileCache[jbeamFilename] then
        -- file got missing, maybe it changed, reload it and rebuild all caches
        _ensureJBeamFileLoaded(jbeamFilename)
        _updateGlobalCache()
      end
      -- realize the object from the cache
      local partCached = fileCache[jbeamFilename].parts[partName]
      return stringBufferDecode(partCached.partEncoded), jbeamFilename
    end
  end
end

local function isContextValid(ioCtx)
  return type(ioCtx.preloadedDirs) == 'table'
end

local function getMainPartName(ioCtx)
  if not isContextValid(ioCtx) then return end
  for _, dir in ipairs(ioCtx.preloadedDirs) do
    if partSlotMap[dir] and partSlotMap[dir]['main'] then
      return partSlotMap[dir]['main'][1]
    end
  end
end

local function finishLoading()
  --tableClear(jbeamCache)
end

local function getAvailableParts(ioCtx)
  if not isContextValid(ioCtx) then return end

  local res = {}
  local loaded = false
  for _, dir in ipairs(ioCtx.preloadedDirs) do
    if not partSlotMap[dir] then
      startLoading(ioCtx.preloadedDirs)
      loaded = true
    end
    -- merge manually to catch errors
    for partName, partDesc in pairs(partNameMap[dir] or {}) do
      if res[partName] then
        log('E', "jbeam.getAvailableParts", "parts names are duplicate: " .. tostring(partName) .. ' in folders: ' .. dumps(ioCtx.preloadedDirs))
      end
      res[partName] = partDesc
    end
  end
  if loaded then finishLoading() end
  return res
end

-- DEPRECATED FUNCTION: IT IS NOT COMPATIBLE WITH SLOTS2, USE getCompatiblePartNamesForSlot() INSTEAD
local function getAvailableSlotNameMap(ioCtx)
  if not isContextValid(ioCtx) then return end

  local slotsPartMap, res = {}, {}
  local loaded = false
  for _, dir in ipairs(ioCtx.preloadedDirs) do
    if not partSlotMap[dir] then
      startLoading(ioCtx.preloadedDirs)
      loaded = true
    end
    -- merge manually to catch errors
    for slotName, partList in pairs(partSlotMap[dir]) do
      if not res[slotName] then res[slotName], slotsPartMap[slotName] = {}, {} end
      local partMap = slotsPartMap[slotName]
      for _, partName in ipairs(partList) do
        if partMap[partName] then
          log('E', "jbeam.getAvailableSlotNameMap", "parts names are duplicate: " .. tostring(partName) .. ' in folders: ' .. dumps(ioCtx.preloadedDirs))
        end
        tableInsert(res[slotName], partName)
        partMap[partName] = true
      end
    end
  end
  if loaded then finishLoading() end
  return res
end

local function getAvailablePartNamesForSlot(ioCtx, slotType)
  local slotMap = getAvailableSlotNameMap(ioCtx)
  return slotMap and slotMap[slotType] or {}
end

-- supply slotMap with getAvailableSlotNameMap() , especially if you will be calling this function multiple times as an optimization
-- slotDef comes from:
--  local part = getPart(ioCtx, partName)
--  local slots = part.slots2 or part.slots
--  local slotDef = slots[i]
local function getCompatiblePartNamesForSlot(ioCtx, slotDef, slotMap)
  slotMap = slotMap or getAvailableSlotNameMap(ioCtx)
  if not slotMap then return {}, {} end

  -- slot version 1
  if slotDef.type then
    return slotMap[slotDef.type] or {}, {}

  -- slot version 2
  elseif slotDef.allowTypes then
    local suitablePartNames, unsuitablePartNames = {}, {}
    local suitablePartsMap = {}
    local denyTypesMap = next(slotDef.denyTypes) and {}
    if denyTypesMap then
      for _, denyType in ipairs(slotDef.denyTypes) do
        denyTypesMap[denyType] = true
      end
    end
    for _, slotType in ipairs(slotDef.allowTypes) do
      -- get all parts that fit the slot allow type
      local allowedParts = slotMap[slotType] or {}
      for _, partName in ipairs(allowedParts) do
        if not suitablePartsMap[partName] then
          local part = getPart(ioCtx, partName)
          if part then
            local partSlotType = type(part.slotType)
            if partSlotType == 'string' then
              -- case 1: the slotType on the part side is a string only
              -- check if the part is denied by any of the slot deny types
              if denyTypesMap then
                if not denyTypesMap[part.slotType] then
                  tableInsert(suitablePartNames, partName)
                  suitablePartsMap[partName] = true
                else
                  tableInsert(unsuitablePartNames, {partName = partName, reason = "Part type is in deny list"})
                end
              else
                tableInsert(suitablePartNames, partName)
                suitablePartsMap[partName] = true
              end
            elseif partSlotType == 'table' then
              -- case 2: the slotType on the part is a table
              -- check if the part is denied by any of the slot deny types
              if denyTypesMap then
                local allowed = true
                for _, slotType in ipairs(part.slotType) do
                  if denyTypesMap[slotType] then
                    allowed = false
                    break
                  end
                end
                if allowed then
                  tableInsert(suitablePartNames, partName)
                  suitablePartsMap[partName] = true
                else
                  tableInsert(unsuitablePartNames, {partName = partName, reason = "Part type is in deny list"})
                end
              else
                tableInsert(suitablePartNames, partName)
                suitablePartsMap[partName] = true
              end
            end
          else
            log("E", "jbeam.getCompatiblePartNamesForSlot", "Part \"" .. tostring(partName) .. "\" not found; skipping.")
          end
        end
      end
    end
    return suitablePartNames, unsuitablePartNames
  end

  return {}, {}
end

local function updateAllVehiclesCompatibleParts()
  local function updateSlotRec(ioCtx, slotTreeEntry, slotMap)
    local part = getPart(ioCtx, slotTreeEntry.chosenPartName)
    if part then
      local slots = part.slots2 or part.slots
      if slots then
        for _, slotDef in ipairs(slots) do
          local slotId = slotDef.name or slotDef.type
          local childSlotTreeEntry = slotTreeEntry.children[slotId]
          if childSlotTreeEntry then
            childSlotTreeEntry.suitablePartNames, childSlotTreeEntry.unsuitablePartNames = getCompatiblePartNamesForSlot(ioCtx, slotDef, slotMap)
            updateSlotRec(ioCtx, childSlotTreeEntry, slotMap)
          end
        end
      end
    end
  end

  for vehId, veh in vehiclesIterator() do
    local vehData = core_vehicle_manager.getVehicleData(vehId)
    local ioCtx = vehData.ioCtx
    startLoading(ioCtx.preloadedDirs)
    local slotMap = getAvailableSlotNameMap(ioCtx)
    if not slotMap then
      log('E', "jbeam.updateAllVehiclesCompatibleParts", "unable to get slot map, unable to update compatible parts")
      return
    end
    updateSlotRec(ioCtx, vehData.config.partsTree, slotMap)
  end
end

local function onFileChanged(filename, type)
  --local dir = string.match(filename, "(/vehicles/[^/]*/).*$") -- yeah it's weird to have no leading slash :/
  local _, _, ext = path.split(filename)
  if ext ~= 'jbeam' then return end

  -- invalidate everthing from that file in all the caches.
  -- important: the other caches will be stale until we reload. This is by design.
  if fileCache[filename] then
    log('I', 'jbeam.onFileChanged', 'File changed: ' .. tostring(filename) .. ' (' .. tostring(type) .. ')')
  end
  fileCache[filename] = nil
  jbeamFilenameDirCache = {}  -- re-scan all directories on next startLoading
end

local function getLastStartLoadingStats()
  return lastStartLoadingStats
end

local function onExtensionLoaded()
  modManager = extensions.core_modmanager
end

M.onExtensionLoaded = onExtensionLoaded
M.onFileChanged = onFileChanged

M.startLoading = startLoading
M.finishLoading = finishLoading
M.getPart = getPart
M.getMainPartName = getMainPartName

M.getAvailableParts = getAvailableParts
M.getAvailableSlotNameMap = getAvailableSlotNameMap
M.getAvailablePartNamesForSlot = getAvailablePartNamesForSlot
M.getCompatiblePartNamesForSlot = getCompatiblePartNamesForSlot
M.getLastStartLoadingStats = getLastStartLoadingStats


return M