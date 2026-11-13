-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "core_locales",
  "core_vehicle_configTarget",
  "core_vehicle_thumbnail",
  "core_vehicle_partFocusCamera",
  "gameplay_achievement",
}

local buffer = require('string.buffer')
local json = require("json")
local jbeamIO = require('jbeam/io')
local partPacksFunctions = require('jbeam/partpacks')
local saveConfigUtils = require("ge/extensions/vehicles/saveConfigUtils")

local vehManager = extensions.core_vehicle_manager
local vehsPartsData = {}
local vehsRichPartInfo = {}

local function resolveConfigVehicleId(explicitVehicleId)
  return extensions.core_vehicle_configTarget.resolveVehicleId(explicitVehicleId)
end

local function resolveConfigVehicle(explicitVehicleId)
  return extensions.core_vehicle_configTarget.resolveVehicle(explicitVehicleId)
end

local function resolveConfigVehicleData(explicitVehicleId)
  return extensions.core_vehicle_configTarget.resolveVehicleData(explicitVehicleId)
end

local function isOccupantCharacterMesh(entry, mesh)
  local meshKind = entry.originalMesh or mesh
  if meshKind ~= "character_torso" and meshKind ~= "character_head" then return false end
  return type(entry.partPath) == "string" and entry.partPath:find("occupant_generic", 1, true) ~= nil
end

local function processHighlightMeshes(vehData)
  local meshesByPart = {}
  local allMeshes = {}
  local allMeshesSeen = {}

  local function addMesh(entry)
    local mesh = entry.mesh
    if not mesh or mesh == "" or mesh == "SPOTLIGHT" or mesh == "POINTLIGHT" then return end
    if isOccupantCharacterMesh(entry, mesh) then return end
    if not allMeshesSeen[mesh] then
      allMeshesSeen[mesh] = true
      allMeshes[#allMeshes + 1] = mesh
    end
    if entry.partPath then
      local meshes = meshesByPart[entry.partPath]
      if not meshes then
        meshes = {}
        meshesByPart[entry.partPath] = meshes
      end
      meshes[#meshes + 1] = mesh
    end
  end

  -- flexbodies become flexmeshes; props are the remaining mesh objects
  for _, flexbody in pairs(vehData.vdata.flexbodies or {}) do
    addMesh(flexbody)
  end
  for _, prop in pairs(vehData.vdata.props or {}) do
    addMesh(prop)
  end

  local highlightMeshesByPart = {}
  local function visit(node, parentMeshes)
    local highlightMeshes = parentMeshes
    if node.partPath and meshesByPart[node.partPath] then
      highlightMeshes = meshesByPart[node.partPath]
    end
    if node.partPath then
      node.highlightMeshes = highlightMeshes or {}
      highlightMeshesByPart[node.partPath] = node.highlightMeshes
    end
    for _, child in pairs(node.children or {}) do
      visit(child, highlightMeshes)
    end
  end
  visit(vehData.config.partsTree or {}, nil)
  table.sort(allMeshes)
  return allMeshes, allMeshesSeen, highlightMeshesByPart
end

-- If inVehID is nil, it uses the active configuration target or player 0's vehicle.
local function getVehData(inVehID)
  local vehObj = resolveConfigVehicle(inVehID)
  if not vehObj then return end
  local vehID = vehObj:getID()

  local vehData = vehManager.getVehicleData(vehID)
  if not vehData then return end

  if not vehsPartsData[vehID] then
    local partsHighlighted = {}
    local partsHighlightedIdxs = {}
    local partNameToIdx = {}

    -- A local helper function to recurse through the 'children'.
    local function recGetPart(node, outPartsHighlighted, outPartsHighlightedIdxs, outPartNameToIdx)
      if node.partPath then
        outPartsHighlighted[node.partPath] = true
      end
      -- Recurse on any further children.
      if node.children then
        for _, childNode in pairs(node.children) do
          recGetPart(childNode, outPartsHighlighted, outPartsHighlightedIdxs, outPartNameToIdx)
        end
      end
    end

    recGetPart(vehData.config.partsTree or {}, partsHighlighted, partsHighlightedIdxs, partNameToIdx)
    local partsSorted = tableKeysSorted(partsHighlighted)

    for k, partName in ipairs(partsSorted) do
      partsHighlighted[partName] = true
      table.insert(partsHighlightedIdxs, k)
      partNameToIdx[partName] = k
    end
    local allMeshes, allMeshesSet, highlightMeshesByPart = processHighlightMeshes(vehData)

    vehsPartsData[vehID] = {
      vehName = vehObj:getJBeamFilename(),
      alpha = 1,
      partsSorted = partsSorted,
      partsHighlighted = partsHighlighted,
      partsHighlightedIdxs = partsHighlightedIdxs,
      partNameToIdx = partNameToIdx,
      allMeshes = allMeshes,
      allMeshesSet = allMeshesSet,
      highlightMeshesByPart = highlightMeshesByPart,
    }
  end

  local partsData = vehsPartsData[vehID]
  if not partsData.highlightMeshesByPart then
    partsData.allMeshes, partsData.allMeshesSet, partsData.highlightMeshesByPart =
      processHighlightMeshes(vehData)
  end
  return vehObj, vehData, vehID, partsData
end

local function getTranslation(name, prefix)
  prefix = prefix or "ui.vehicleconfig.title."
  if not name then return end
  if type(name) == 'table' and name.txt and name.ctx and type(name.ctx) == 'table' then
    local ctx = {}
    for key, value in pairs(name.ctx) do
      ctx[key] = _tr(value)
    end
    return core_locales.contextTranslate(name.txt, ctx)
  elseif type(name) == 'table' then
    return nil
  else
    return core_locales.translateWithPrefixFallback(name, prefix)
  end
end

local function translateTuningData(tuningData)
  local translated = deepcopy(tuningData or {})
  for _, varData in pairs(translated) do
    varData.title = getTranslation(varData.title, "ui.vehicleconfig.variables.title.")
    varData.description = getTranslation(
      varData.description,
      "ui.vehicleconfig.variables.description."
    )
    if varData.category then
      varData.category = getTranslation(
        varData.category,
        "ui.vehicleconfig.variables.category."
      )
    end
    if varData.subCategory then
      varData.subCategory = getTranslation(
        varData.subCategory,
        "ui.vehicleconfig.variables.subCategory."
      )
    end
  end
  return translated
end

-- Caches and returns the "rich part info" as a json encoded string buffer to avoid needing to re-encode the same data multiple times
local function getRichPartInfo(vehId)
  if vehsRichPartInfo[vehId] then
    return vehsRichPartInfo[vehId]
  end

  local vehData = vehManager.getVehicleData(vehId)
  if not vehData then return end
  local ioCtx = vehData.ioCtx

  local availableParts = jbeamIO.getAvailableParts(ioCtx)
  local res = {}
  -- enrich the data a bit for the UI
  for partName, uiPartInfo in pairs(availableParts) do
    local richPartInfo = {}
    richPartInfo.information = deepcopy(uiPartInfo or {})
    richPartInfo.information.description = getTranslation(
      richPartInfo.information.description,
      "ui.vehicleconfig.information.name."
    )
    if richPartInfo.information.slotInfoUi then
      for _, slotInfo in pairs(richPartInfo.information.slotInfoUi) do
        if slotInfo.description then
          slotInfo.description = getTranslation(
            slotInfo.description,
            "ui.vehicleconfig.slot.description."
          )
        end
      end
    end
    if uiPartInfo.modName then
      local mod = core_modmanager.getModDB(uiPartInfo.modName)
      if mod and mod.modData then
        richPartInfo.modTagLine    = mod.modData.tag_line
        richPartInfo.modTitle      = mod.modData.title
        richPartInfo.modLastUpdate = mod.modData.last_update
      end
    end
    res[partName] = richPartInfo
  end

  local buf = buffer.new()
  vehsRichPartInfo[vehId] = buf:put(jsonEncode(res))
  return buf
end

local function getDefaultConfigFileFromDir(vehicleDir, configData)
  local vehicleInfo = jsonReadFile(vehicleDir .. '/info.json')
  if not vehicleInfo then return end
  if not vehicleInfo.default_pc then return end
  log('W', 'main', "Supplied config file: " .. dumps(configData) .. " not found. Using default config instead.")
  return vehicleDir .. vehicleInfo.default_pc .. ".pc"
end

local function buildConfigFromString(vehicleDir, configData, onlyReturnChosenConfig)
  local function preprocessPartConfig(configData)
    -- If the config data format is 4, then we need to preprocess it
    -- Replace references to part config files with the actual part config data
    if configData.format == 4 then
      for _, vehData in ipairs(configData.vehicles) do
        if vehData.linkedPCFile then
          local data, isChosenConfigReturned = buildConfigFromString(vehData.linkedPCFile, nil, true)
          if isChosenConfigReturned then
            tableMerge(vehData, data)
          else
            return false, nil
          end
        end
      end
    else
      return true, configData
    end
  end

  local dataType = type(configData)
  local fileData
  local isChosenConfigReturned = false

  if dataType == 'table' then
    local res, newConfigData = preprocessPartConfig(configData)
    if res then
      isChosenConfigReturned = true
      return newConfigData, isChosenConfigReturned
    end
  elseif dataType == 'string' and configData:sub(1, 1) == '{' then
    local res, newConfigData = preprocessPartConfig(deserialize(configData))
    if res then
      isChosenConfigReturned = true
      return newConfigData, isChosenConfigReturned
    end
  elseif configData ~= nil and configData ~= "" then
    fileData = jsonReadFile(configData)
    if fileData then
      local res, newConfigData = preprocessPartConfig(fileData)
      if res then
        isChosenConfigReturned = true
        fileData = newConfigData
      else
        fileData = nil
      end
    else
      log("W", "", "Unable to read json contents for configData file path: "..dumps(configData))
    end
  end

  if onlyReturnChosenConfig and not isChosenConfigReturned then
    return nil, false
  end

  -- Default to default config if config not found
  if not fileData then
    log("W", "", "Problems reading requested configuration: "..dumps(configData))
    configData = getDefaultConfigFileFromDir(vehicleDir, configData)
    if configData then
      fileData = jsonReadFile(configData)
    end
  end

  local res = {}
  res.partConfigFilename = configData
  if fileData and fileData.format == 2 then
    fileData.format = nil
    tableMerge(res, fileData)
  else
    res.parts = fileData or {}
  end

  return res, isChosenConfigReturned
end

-- Flattens a resolved partsTree into a simple slotId -> chosenPartName map (pc "parts" format)
local function partsTreeToPartsMap(partsTree)
  local legacySlotMap = {}
  local legacySlotMapSimple = {}

  local function flattenPartsTreeRecursive(node)
    if not node then return end
    for slotId, child in pairs(node.children or {}) do
      legacySlotMap[child.path] = {
        slotId = child.id,
        path = child.path,
        chosenPartName = child.chosenPartName,
      }
      flattenPartsTreeRecursive(child)
    end
  end
  flattenPartsTreeRecursive(partsTree)

  -- now simplify it
  for path, slotData in pairs(legacySlotMap) do
    if not legacySlotMapSimple[slotData.slotId] then
      legacySlotMapSimple[slotData.slotId] = slotData
    else
      -- we have a collision, so we need to save both slots with the full path
      local tmp = legacySlotMapSimple[slotData.slotId]
      if tmp ~= "COLLISION" then
        legacySlotMapSimple[tmp.path] = tmp
        legacySlotMapSimple[slotData.slotId] = "COLLISION"
      end
      legacySlotMapSimple[slotData.path] = slotData
    end
  end
  -- now discard the complex data, keeping only the chosen part name per key
  for key, slotData in pairs(legacySlotMapSimple) do
    if slotData ~= "COLLISION" then
      legacySlotMapSimple[key] = slotData.chosenPartName
    else
      legacySlotMapSimple[key] = nil
    end
  end
  return legacySlotMapSimple
end

local function saveVehicle(vehEntry)
  local vehId = vehEntry.vehId
  local vehicle = getObjectByID(vehId)
  local vehicleData = vehManager.getVehicleData(vehId)
  if not vehicle or not vehicleData then
    log('E', 'partmgmt', 'vehicle ' .. tostring(vehId) .. ' not found')
    return
  end

  local data

  -- Check if vehicle originates from a part config file
  local partConfigFilename = vehicle.partConfig
  if partConfigFilename and string.endswith(partConfigFilename, '.pc') then
    -- Vehicle originates from a part config file
    data = {}
    data.linkedPCFile = partConfigFilename
  else
    -- Vehicle doesn't originate from a part config file
    data = deepcopy(vehicleData.config)
    data.linkedPCFile = nil
    data.model = vehicleData.model or vehicleData.vehicleDirectory:gsub("vehicles/", ""):gsub("/", "")
    data.partsCondition = partsCondition
    if not data.paints or data.colors then
      data.paints = {}
      local colorTable = vehicle:getColorFTable()
      local colorTableSize = tableSize(colorTable)
      for i = 1, colorTableSize do
        local metallicPaintData = stringToTable(vehicle:getField('metallicPaintData', i - 1))
        local paint = createVehiclePaint({x = colorTable[i].r, y = colorTable[i].g, z = colorTable[i].b, w = colorTable[i].a}, metallicPaintData)
        validateVehiclePaint(paint)
        table.insert(data.paints, paint)
      end

      if #data.paints > 0 then
        data.colors = nil
      end
    end
    data.licenseName = extensions.core_vehicles.makeVehicleLicenseText()

    data.parts = partsTreeToPartsMap(data.partsTree)
    data.partsTree = nil
  end

  data.id = vehEntry.id
  data.offsetData = vehEntry.offsetData

  --dump{'coupledNodes = ', vehId, coupledNodes}
  data.format = nil -- remove obsolete key
  data.mainPartPath = nil

  return data
end

-- Compile the vehicle collection tree into a list of vehicles, resolve offsets, and assign pre-runtime ids
local function compileVehicleCollection(collectionTree)
  local collectionTreeCopy = deepcopy(collectionTree)

  -- Calculate offset between parent and child
  local function calculateOffsetRec(entry, parentEntry)
    if parentEntry then
      local offsetData = entry.offsetData
      local veh, parentVeh = getObjectByID(entry.vehId), getObjectByID(parentEntry.vehId)
      if not veh then
        log('E', 'partmgmt', 'vehicle not found for entry: ' .. tostring(entry.vehId))
        return
      end
      if not parentVeh then
        log('E', 'partmgmt', 'parent vehicle not found for entry: ' .. tostring(entry.vehId))
        return
      end

      local vehicleMat, parentVehMat = veh:getRefNodeMatrix(), parentVeh:getRefNodeMatrix()
      local offsetMat = parentVehMat:inverse() * vehicleMat
      local offsetEuler = offsetMat:toEuler()

      if offsetData.type == 'default' then
        local offsetPos = offsetMat:getPosition()
        entry.offsetData.offset = {
          x = roundNear(offsetPos.x, 0.001),
          y = roundNear(offsetPos.y, 0.001),
          z = roundNear(offsetPos.z, 0.001),
          rx = roundNear(math.deg(offsetEuler.x), 0.1),
          ry = roundNear(math.deg(offsetEuler.y), 0.1),
          rz = roundNear(math.deg(offsetEuler.z), 0.1),
        }

      elseif offsetData.type == 'coupledNodes' then
        entry.offsetData.offset = {
          rx = roundNear(math.deg(offsetEuler.x), 0.1),
          ry = roundNear(math.deg(offsetEuler.y), 0.1),
          rz = roundNear(math.deg(offsetEuler.z), 0.1),
        }
      end
    end

    for _, child in ipairs(entry.children) do
      calculateOffsetRec(child, entry)
    end
  end
  calculateOffsetRec(collectionTreeCopy, nil)

  local vehicles = {}
  local vehIdMap = {}

  local function createVehIdMapRec(entry)
    vehIdMap[entry.vehId] = tableSize(vehIdMap) + 1
    for _, child in ipairs(entry.children) do
      createVehIdMapRec(child)
    end
  end

  createVehIdMapRec(collectionTreeCopy)

  local function convertVehIdToIdx(entry, parentEntry)
    local offsetData = entry.offsetData
    if offsetData then
      local parentVehId = parentEntry.vehId
      local parentId = vehIdMap[parentVehId]
      if parentId then
        offsetData.parentId = parentId
      end
    end

    local data = saveVehicle(entry)
    if data then
      table.insert(vehicles, data)
    end

    for _, child in ipairs(entry.children) do
      convertVehIdToIdx(child, entry)
    end
  end

  convertVehIdToIdx(collectionTreeCopy)

  return vehicles
end

local function saveVehicleCollection(collectionTree, filename)
  log('D', 'partmgmt', 'saving vehicle collection... ' .. filename)

  local vehicles = compileVehicleCollection(collectionTree)

  local res = {}
  res.format = 4
  res.vehicles = vehicles

  local writeRes = jsonWriteFile(filename, res, true)
  if writeRes then
    log('D', 'partmgmt', 'vehicle collection saved to ' .. filename)
    guihooks.trigger("VehicleconfigSaved", {})
  else
    log('W', "vehicles.save", "unable to save config: "..filename)
  end
  guihooks.trigger('Message', {ttl = 15, msg = 'Configuration saved', icon = 'directions_car'})
end

local function savePartConfigFileStage2(partsCondition, filename)
  local playerVehicle = resolveConfigVehicle()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  local playerVehicleId = playerVehicle:getID()
  local collectionTree = core_vehicles.generateAttachedVehiclesTree(playerVehicleId)
  local vehicles = compileVehicleCollection(collectionTree)

  local res = {}
  res.format = 4
  res.vehicles = vehicles

  local writeRes = jsonWriteFile(filename, res, true)
  if writeRes then
    guihooks.trigger("VehicleconfigSaved", {})
  else
    log('W', "vehicles.save", "unable to save config: "..filename)
  end
  guihooks.trigger('Message', {ttl = 15, msg = 'Configuration saved', icon = 'directions_car'})
end

-- TODO: remove this later
local defaultSaveSettings = {
  generateThumbnail = true,
  saveLicenseplate = false,
  savePaints = true,
  overridePaints = false,
  useThumbnailFile = false,
  thumbnailFile = nil,
  thumbnailCaptureId = nil,
}

local function normalizeSaveSettings(settings)
  local normalized = deepcopy(defaultSaveSettings)
  normalized.thumbnailCaptureRequested = false
  if type(settings) == "table" then
    if type(settings.generateThumbnail) == "boolean" then
      normalized.generateThumbnail = settings.generateThumbnail
    end
    if type(settings.saveLicenseplate) == "boolean" then
      normalized.saveLicenseplate = settings.saveLicenseplate
    elseif type(settings.saveLicensePlate) == "boolean" then
      normalized.saveLicenseplate = settings.saveLicensePlate
    end
    if type(settings.savePaints) == "boolean" then
      normalized.savePaints = settings.savePaints
    end
    if type(settings.overridePaints) == "boolean" then
      normalized.overridePaints = settings.overridePaints
    end
    if type(settings.useThumbnailFile) == "boolean" then
      normalized.useThumbnailFile = settings.useThumbnailFile
    end
    if type(settings.thumbnailFile) == "string" and settings.thumbnailFile ~= "" then
      normalized.thumbnailFile = settings.thumbnailFile
    end
    if settings.thumbnailCaptureId ~= nil then
      normalized.thumbnailCaptureRequested = true
      if type(settings.thumbnailCaptureId) == "number" then
        normalized.thumbnailCaptureId = settings.thumbnailCaptureId
      end
    end
  elseif type(settings) == "boolean" then
    -- backwards compatibility with legacy `withThumbnail` bool argument
    normalized.generateThumbnail = settings
  end
  return normalized
end

local function getPlayerVehicleModelKey()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then return nil end
  local modelKey = playerVehicle.model
    or (playerVehicle.vehicleDirectory or ""):gsub("^/?vehicles/", ""):gsub("/", "")
  return modelKey ~= "" and modelKey or nil
end

local function normalizeSaveMetadata(metadata)
  return saveConfigUtils.validateMetadata(metadata, getPlayerVehicleModelKey())
end

local function getSaveAvailability()
  if gameplay_walk and gameplay_walk.isWalking and gameplay_walk.isWalking() then
    return { canSave = false, reason = "walking" }
  end
  if be:getObjectCount() == 0 or resolveConfigVehicle() == nil or resolveConfigVehicleData() == nil then
    return { canSave = false, reason = "noVehicle" }
  end
  return { canSave = true }
end

local function captureVehiclePaints(playerVehicle)
  local paints = {}
  if not playerVehicle then
    return paints
  end
  local colorTable = playerVehicle:getColorFTable()
  local colorTableSize = tableSize(colorTable)
  for i = 1, colorTableSize do
    local metallicPaintData = stringToTable(playerVehicle:getField('metallicPaintData', i - 1))
    local paint = createVehiclePaint({x = colorTable[i].r, y = colorTable[i].g, z = colorTable[i].b, w = colorTable[i].a}, metallicPaintData)
    validateVehiclePaint(paint)
    table.insert(paints, paint)
  end
  return paints
end

local function savePartConfigFileStage2_Format2(partsCondition, filename, saveSettings, saveMetadata)
  local playerVehicle = resolveConfigVehicle()
  local playerVehicleData = resolveConfigVehicleData()
  if not playerVehicle or not playerVehicleData then
    log('E', 'partmgmt', 'no active vehicle')
    return false
  end
  local normalizedSaveSettings = normalizeSaveSettings(saveSettings)
  local normalizedSaveMetadata, metadataError = normalizeSaveMetadata(saveMetadata)
  if not normalizedSaveMetadata then
    log('W', 'partmgmt', 'invalid save metadata: '..dumps(metadataError))
    return false
  end

  local configName = string.sub(filename, #(playerVehicleData.vehicleDirectory or "") + 1)
  configName = configName:gsub("%.pc$", "")

  local pcData = deepcopy(playerVehicleData.config)
  local infoData = {}
  local prevPCFilename = pcData.partConfigFilename
  pcData.partConfigFilename = nil
  pcData.format = 2
  pcData.model = playerVehicleData.model or playerVehicleData.vehicleDirectory:gsub("vehicles/", ""):gsub("/", "")
  pcData.partsCondition = partsCondition

  if normalizedSaveSettings.savePaints then
    pcData.paints = captureVehiclePaints(playerVehicle)
    if #pcData.paints > 0 then
      pcData.colors = nil
      if normalizedSaveSettings.overridePaints then
        core_vehiclePaints.writePcPaintsAsInfoPaints(pcData, infoData, configName)
      else
        core_vehiclePaints.convertPcPaintsToInfoPaints(pcData, infoData, configName, playerVehicleData.mainPartName)
      end
    else
      pcData.paints = nil
    end
  else
    pcData.paints = nil
    pcData.colors = nil
  end

  infoData.Configuration = playerVehicleData.config.Configuration or configName
  for key, value in pairs(normalizedSaveMetadata) do
    infoData[key] = value
  end
  pcData.paints = nil
  if normalizedSaveSettings.saveLicenseplate then
    pcData.licenseName = extensions.core_vehicles.makeVehicleLicenseText(playerVehicle)
  else
    pcData.licenseName = nil
  end

  pcData.parts = partsTreeToPartsMap(pcData.partsTree)
  pcData.partsTree = nil

  local res = jsonWriteFile(filename, pcData, true)
  if res then
    pcData.partConfigFilename = filename
    guihooks.trigger("VehicleconfigSaved", {})
  else
    pcData.partConfigFilename = prevPCFilename
    log('W', "vehicles.save", "unable to save config: "..filename)
    return false
  end

  local infoFilename = "/vehicles/" .. pcData.model .. "/info_" .. configName .. ".json"
  if not jsonWriteFile(infoFilename, infoData, true) then
    log('W', "vehicles.save", "unable to save config info: "..infoFilename)
  end

  guihooks.trigger('Message', {ttl = 15, msg = 'Configuration saved', icon = 'directions_car'})

  -- notify the vehicle selector that the vehicle has been saved and clear the cache
  local configWithoutFilename = string.sub(filename, #(playerVehicleData.vehicleDirectory or "") + 1)
  configWithoutFilename = configWithoutFilename:gsub("%.pc$", "")
  ui_vehicleSelector_general.trackRecentVehicle(pcData.model, configWithoutFilename)
  ui_vehicleSelector_general.clearCache()
  core_vehicles.clearCache()
  return true
end

local function savePartConfigFile(filename, saveSettings, saveMetadata)
  local savePartsCondition = false
  if savePartsCondition then
    local playerVehicle = resolveConfigVehicle()
    if playerVehicle then
      queueCallbackInVehicle(playerVehicle, "extensions.core_vehicle_partmgmt.savePartConfigFileStage2", "partCondition.getConditions("..serialize(filename)..")")
    end
  else
    -- TODO: CHANGE THIS LATER TO FORMAT 4
    return savePartConfigFileStage2_Format2(nil, filename, saveSettings, saveMetadata)
  end
end

local function saveLocal(fn, saveSettings, saveMetadata)
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return false
  end
  return savePartConfigFile(playerVehicle.vehicleDirectory .. fn, saveSettings, saveMetadata)
end

local function setCurrentConfigurationName(configurationName)
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return false
  end
  playerVehicle.config = playerVehicle.config or {}
  playerVehicle.config.Configuration = configurationName
  return true
end

local function saveLocalScreenshot(fn)
  -- See ui/modules/vehicleconfig/vehicleconfig.js (line 420)
  -- Set up camera
  commands.setFreeCamera()
  core_camera.setFOV(0, 35)
  -- Stage 1 happens on JS side for timing reasons
  guihooks.trigger("saveLocalScreenshot_stage1", {})
end

-- Stage 2
local function saveLocalScreenshot_stage2(fn)
  -- Take screenshot
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then return false end
  local screenshotName = (playerVehicle.vehicleDirectory .. fn)
  screenshot.doScreenshot(nil, nil, screenshotName, 'jpg')
  -- Stage 3 on JS side
  guihooks.trigger('saveLocalScreenshot_stage3', {})
end


local function savedefault()
  guihooks.trigger('Message', {ttl = 5, msg = 'New default vehicle has been set', icon = 'directions_car'})
  savePartConfigFile('settings/default.pc')
end

local setNewParts

local function highlightsCoverTree(partsHighlighted, partsTree)
  local covered = true
  local function walk(node)
    if not covered or not node then return end
    if node.partPath and partsHighlighted[node.partPath] == nil then
      covered = false
      return
    end
    if node.children then
      for _, child in pairs(node.children) do
        walk(child)
      end
    end
  end
  walk(partsTree)
  return covered
end

local function sendDataToUI(explicitVehicleId)
  local startTime = os.clockhp()
  local vehicleId = resolveConfigVehicleId(explicitVehicleId)
  if not vehicleId then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  local vehObj, vehData, vehID, partsData = getVehData(vehicleId)
  if not vehObj or not vehData then return end

  -- Highlight flags are cached from the tree at first open. A part just installed into an
  -- empty slot is missing from that cache, so the eye and pin stay disabled until reopen.
  if not highlightsCoverTree(partsData.partsHighlighted, vehData.config.partsTree) then
    setNewParts(vehID, true)
    partsData = vehsPartsData[vehID]
  end

  local pcFilename = vehData.config.partConfigFilename
  local configDefaults = nil
  if pcFilename then
    local data = buildConfigFromString(vehData.vehicleDirectory, pcFilename)
    if data ~= nil then
      configDefaults = data
      configDefaults.parts = configDefaults.parts or {}
      configDefaults.vars = configDefaults.vars or {}
    end
  end
  if configDefaults == nil then
    configDefaults = {parts = {}, vars = {}}
  end

  local partPacksCatalog = partPacksFunctions.process(vehData.directoriesLoaded, vehData.config.partsTree, vehData.model)

  local tuningData = translateTuningData(vehData.vdata.variables)
  local dataJson = string.format(
    '{"vehID":%s,"model":%s,"mainPartName":%s,"chosenPartsTree":%s,"variables":%s,"defaults":%s,"partPacks":%s,"partsHighlighted":%s,"richPartInfo":%s}',
    jsonEncode(vehID),
    jsonEncode(vehData.model),
    jsonEncode(vehData.mainPartName),
    jsonEncode(vehData.config.partsTree),
    jsonEncode(tuningData),
    jsonEncode(configDefaults),
    jsonEncode(partPacksCatalog),
    jsonEncode(partsData.partsHighlighted),
    getRichPartInfo(vehID)
  )

  --dump{'UI part info = ', data}

  guihooks.triggerRawJS("VehicleConfigChange", dataJson)

  log('D', 'partmgmt', 'sendDataToUI took ' .. (os.clockhp() - startTime) .. ' seconds')
end

local function hasAvailablePart(partName)
  if not partName or partName == "" then return end
  local playerVehicleData = resolveConfigVehicleData()
  if not playerVehicleData then return false end
  local parts = jbeamIO.getAvailableParts(playerVehicleData.ioCtx)

  if parts[partName] then
    return true
  end

  return false
end

local function setSkin(skin)
  local vehicle = resolveConfigVehicle()
  local playerVehicleData = resolveConfigVehicleData()

  if not vehicle or not playerVehicleData then return end

  local partName = nil

  if skin and skin ~= "" then
    partName = vehicle.JBeam .. "_skin_" .. skin
    local parts = jbeamIO.getAvailableParts(playerVehicleData.ioCtx)
    if not parts[partName] then return end
  end

  local carConfigToLoad = playerVehicleData.config

  local function setPaintDesignSlotRec(node)
    if node.id == "paint_design" then
      node.chosenPartName = partName

      local carModelToLoad = vehicle.JBeam
      local vehicleData = {}
      vehicleData.config = carConfigToLoad
      core_vehicles.replaceVehicle(carModelToLoad, vehicleData, vehicle)
      return true
    else
      if node.children then
        for _, childNode in pairs(node.children) do
          if setPaintDesignSlotRec(childNode) then
            return true
          end
        end
      end
    end
  end

  local success = setPaintDesignSlotRec(carConfigToLoad.partsTree)
  if not success then
    log('E', 'setSkin', '"paint_design" slot not found in config')
  end
end

local function reset()
  sendDataToUI()
end

local function mergeConfigOfVehicle(veh, inData, respawn)
  --dump{"mergeConfig> ", inData, respawn}
  local vehId = veh:getID()
  local vehicleData = vehManager.getVehicleData(vehId)
  if not vehicleData then
    log('E', 'partmgmt', 'vehicle data not found')
    return
  end

  if respawn == nil then respawn = true end -- respawn is required all the time except when loading the vehicle

  if not inData or type(inData) ~= 'table' then
    log('W', "partmgmt.mergeConfig", "invalid argument [" .. type(inData) .. '] = '..dumps(inData))
    return
  end

  tableMerge(vehicleData.config, inData)

  if respawn then
    --dump{"RESPAWN: ", vehicleData.config}
    if extensions.core_vehicle_configTarget.getTargetVehicleId() == vehId then
      -- the respawn re-seats autoEnterVehiclePlayer (player 0 by default): keep the configuring player
      -- in their vehicle, without pulling player 0 into someone else's
      local targetPlayer = extensions.core_vehicle_configTarget.getTargetPlayerId()
      if targetPlayer and be:getPlayerVehicleID(targetPlayer) == vehId then
        veh.autoEnterVehiclePlayer = tostring(targetPlayer)
      else
        veh.autoEnterVehicle = "false"
      end
    end
    veh:respawn(serialize(vehicleData.config))
  else
    local paintCount = tableSize(inData.paints)
    for i = 1, paintCount do
      vehManager.liveUpdateVehicleColors(vehId, veh, i, inData.paints[i])
    end
    veh:setField('partConfig', '', serialize(vehicleData.config))
  end
end

local function mergeConfig(inData, respawn, explicitVehicleId)
  local veh = resolveConfigVehicle(explicitVehicleId)
  if not veh then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  if not career_career.isActive() then
    gameplay_achievement.unlockAchievement("VEHICLE_MODIFIED")
  end
  return mergeConfigOfVehicle(veh, inData, respawn)
end

local function setConfigPaints (data, respawn, explicitVehicleId)
  mergeConfig({paints = data}, respawn, explicitVehicleId)
end

local function setConfigVars (data, respawn)
  mergeConfig({vars = data}, respawn)
end

local function setPartsConfig (data, respawn)
  log('E', 'partmgmt', 'please use the new function setPartsTreeConfig instead')
end

local function setPartsTreeConfig (dataTree, respawn, part)
  extensions.hook("onPartsTreeConfigChanged", dataTree, respawn, part)
  mergeConfig({partsTree = dataTree}, respawn)
end

local function getConfigOfVehicle(vehicleId)
  -- get config of vehicle with given id
  local vehicleData = vehManager.getVehicleData(vehicleId)
  if not vehicleData then return nil end
  return vehicleData.config
end

local function getConfig()
  local vehicleId = resolveConfigVehicleId()
  local config = getConfigOfVehicle(vehicleId)
  if not config then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  return config
end

local function loadLocal(filename, respawn)
  local veh = resolveConfigVehicle()
  if not veh then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  core_vehicles.replaceVehicle(veh.JBeam, {config = filename}, veh)
end

local function removeLocal(filename)
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  FS:removeFile(playerVehicle.vehicleDirectory .. filename .. ".pc")
  FS:removeFile(playerVehicle.vehicleDirectory .. filename .. ".jpg") -- remove generated thumbnail
  guihooks.trigger("VehicleconfigRemoved", {})
  log('I', 'partmgmt', "deleted user configuration: " .. playerVehicle.vehicleDirectory .. filename .. ".pc")
end

local function isOfficialConfig(filename)
  local isOfficial
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  isOfficial = isOfficialContentVPath(playerVehicle.vehicleDirectory .. filename)
  return isOfficial
end

local function isPlayerConfig(filename)
  local isPlayerConfig
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  isPlayerConfig = isPlayerVehConfig(playerVehicle.vehicleDirectory .. filename)
  return isPlayerConfig
end

local function sanitizeConfigBasename(configRef)
  if type(configRef) ~= "string" then
    return nil
  end
  local sanitized = configRef
  sanitized = sanitized:gsub("\\", "/")
  sanitized = sanitized:match("([^/]+)$") or sanitized
  sanitized = sanitized:gsub("%.pc$", "")
  if sanitized == "" then
    return nil
  end
  return sanitized
end

local function getCurrentLocalConfigName()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    return nil
  end
  local configRef = playerVehicle.config and playerVehicle.config.partConfigFilename
  if not configRef or configRef == "" then
    local veh = resolveConfigVehicle()
    configRef = veh and veh.partConfig
  end
  return sanitizeConfigBasename(tostring(configRef or ""))
end

local function getSaveMetadataFields(targetConfigName)
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then return {} end
  local modelKey = getPlayerVehicleModelKey()
  if not modelKey then return {} end
  return saveConfigUtils.getFields(
    modelKey,
    playerVehicle.vehicleDirectory,
    getCurrentLocalConfigName(),
    sanitizeConfigBasename(targetConfigName)
  )
end

local function getConfigList()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end

  local files = FS:findFiles(playerVehicle.vehicleDirectory, "*.pc", -1, true, false) or {}
  local result = {}

  for _, file in pairs(files) do
    local basename = string.sub(file, string.len(playerVehicle.vehicleDirectory) + 1, -1)
    local configName = string.sub(basename, 0, -4)
    local displayName
    local infoData = jsonReadFile(playerVehicle.vehicleDirectory .. "info_" .. configName .. ".json")
    if infoData and infoData.Configuration and infoData.Configuration ~= "" then
      displayName = core_locales.translate(infoData.Configuration)
    end
    local entry = {
      fileName = basename,
      name = configName,
      displayName = displayName,
      official = isOfficialConfig(basename),
      player = isPlayerConfig(basename)
    }
    local thumbnailPath = playerVehicle.vehicleDirectory .. configName .. '.jpg'
    if FS:fileExists(thumbnailPath) then
      entry.thumbnailPath = thumbnailPath
    end
    table.insert(result, entry)
  end
  return result
end

local function getNextCustomConfigFilename(configurationName)
  local list = getConfigList()
  if not list then
    return
  end
  local usedNames = {}
  for _, entry in ipairs(list) do
    if entry.name and entry.name ~= '' then
      usedNames[string.lower(entry.name)] = true
    end
  end
  configurationName = string.lower(configurationName or '')

  local candidate = configurationName
  while usedNames[string.lower(candidate)] do
    candidate = configurationName .. string.format('%06d', math.random(0, 999999))
  end
  return candidate
end

local function validatePaints()
  local playerVehicle = resolveConfigVehicle()
  local playerVehicleData = resolveConfigVehicleData()
  if not playerVehicle or not playerVehicleData then
    log('E', 'partmgmt', 'no active vehicle')
    return {}
  end

  local paints = captureVehiclePaints(playerVehicle)
  local modelName = playerVehicleData.mainPartName
    or playerVehicleData.model
    or playerVehicleData.vehicleDirectory:gsub("vehicles/", ""):gsub("/", "")
  local validation = core_vehiclePaints.validatePcPaints({ paints = paints }, modelName) or {}
  validation.defaults = deepcopy(defaultSaveSettings)
  return validation
end

local function getCurrentLicensePlate()
  local playerVehicle = resolveConfigVehicle()
  if not playerVehicle then
    return ""
  end
  local plateText = core_vehicles.getVehicleLicenseText(playerVehicle)
  if type(plateText) ~= "string" then
    return ""
  end
  return plateText
end

local function setCurrentLicensePlate(text)
  local vehicleId = resolveConfigVehicleId()
  if not vehicleId then return false end
  core_vehicles.setPlateText(text, vehicleId)
  return true
end

local function regenerateCurrentLicensePlate()
  local vehicle = resolveConfigVehicle()
  if not vehicle then return "" end
  local text = core_vehicles.regenerateVehicleLicenseText(vehicle)
  core_vehicles.setPlateText(text, vehicle:getId())
  return text or ""
end

local function saveLocalConfigToFile(fileName, configurationName, saveSettings, saveMetadata)
  local availability = getSaveAvailability()
  if not availability.canSave then
    log('W', 'partmgmt', 'cannot save config: '..tostring(availability.reason))
    return { success = false, reason = availability.reason }
  end
  local normalizedFileName = type(fileName) == "string" and fileName:gsub("%.pc$", "") or ""
  if normalizedFileName == "" then
    return { success = false, reason = "invalidFilename" }
  end
  local normalizedSaveSettings = normalizeSaveSettings(saveSettings)
  local normalizedSaveMetadata, metadataError = normalizeSaveMetadata(saveMetadata)
  if not normalizedSaveMetadata then
    return {
      success = false,
      reason = "invalidMetadata",
      metadataError = metadataError,
    }
  end
  local playerVehicleData = resolveConfigVehicleData()
  local previousConfigurationName = playerVehicleData and playerVehicleData.config and playerVehicleData.config.Configuration or nil
  local targetConfigurationName = type(configurationName) == "string" and configurationName or ""
  targetConfigurationName = targetConfigurationName:gsub("^%s+", ""):gsub("%s+$", "")
  if targetConfigurationName == "" then
    targetConfigurationName = normalizedFileName
  end
  local function restoreConfigurationName()
    local currentVehicleData = resolveConfigVehicleData()
    if currentVehicleData and currentVehicleData.config then
      currentVehicleData.config.Configuration = previousConfigurationName
    end
  end
  if not setCurrentConfigurationName(targetConfigurationName) then
    return { success = false, reason = "noVehicle" }
  end
  if not saveLocal(normalizedFileName .. '.pc', normalizedSaveSettings, normalizedSaveMetadata) then
    restoreConfigurationName()
    return { success = false, reason = "saveFailed" }
  end
  playerVehicleData = resolveConfigVehicleData()
  local thumbnailPath = playerVehicleData and (playerVehicleData.vehicleDirectory .. normalizedFileName .. ".jpg") or nil
  local copiedPreviewThumbnail = false
  local hasRequestedCapture = normalizedSaveSettings.thumbnailCaptureRequested
  local hasProvidedThumbnail = normalizedSaveSettings.useThumbnailFile
    and normalizedSaveSettings.thumbnailFile
  if hasRequestedCapture then
    if normalizedSaveSettings.generateThumbnail then
      log('W', 'partmgmt', 'generateThumbnail was requested with a thumbnail capture; using the capture instead')
    end
    if thumbnailPath then
      copiedPreviewThumbnail = extensions.core_vehicle_thumbnail.commitTemporaryThumbnail(
        normalizedSaveSettings.thumbnailCaptureId,
        thumbnailPath
      )
    end
    if not copiedPreviewThumbnail then
      log('W', 'partmgmt', 'unable to commit thumbnail capture: '..tostring(normalizedSaveSettings.thumbnailCaptureId))
      gameplay_achievement.unlockAchievement("VEHICLE_CONFIG_SAVED")
      return {
        success = false,
        configSaved = true,
        reason = "thumbnailCopyFailed",
        fileName = normalizedFileName,
        displayName = targetConfigurationName,
        thumbnailCopied = false,
      }
    end
  elseif hasProvidedThumbnail then
    if normalizedSaveSettings.generateThumbnail then
      log('W', 'partmgmt', 'generateThumbnail was requested with a supplied thumbnail file; using the supplied thumbnail instead')
    end
    if not extensions.core_vehicle_thumbnail.isValidTemporaryThumbnail(normalizedSaveSettings.thumbnailFile) then
      log('W', 'partmgmt', 'invalid supplied thumbnail file: '..tostring(normalizedSaveSettings.thumbnailFile))
    elseif thumbnailPath then
      copiedPreviewThumbnail = extensions.core_vehicle_thumbnail.copyThumbnailFile(
        normalizedSaveSettings.thumbnailFile,
        thumbnailPath
      )
      if not copiedPreviewThumbnail then
        log('W', 'partmgmt', 'unable to copy supplied thumbnail file: '..tostring(normalizedSaveSettings.thumbnailFile))
      end
    end
  end
  if normalizedSaveSettings.generateThumbnail and not hasRequestedCapture and not hasProvidedThumbnail and not copiedPreviewThumbnail then
    extensions.core_vehicle_thumbnail.generateConfigThumbnail(normalizedFileName)
  end
  gameplay_achievement.unlockAchievement("VEHICLE_CONFIG_SAVED")
  return {
    success = true,
    fileName = normalizedFileName,
    displayName = targetConfigurationName,
    configSaved = true,
    thumbnailCopied = copiedPreviewThumbnail,
  }
end

local function saveNewLocalConfig(configurationName, saveSettings, saveMetadata)
  local fileName = getNextCustomConfigFilename(configurationName)
  if not fileName then
    log('E', 'partmgmt', 'no active vehicle')
    return { success = false, reason = "noVehicle" }
  end
  return saveLocalConfigToFile(fileName, configurationName, saveSettings, saveMetadata)
end

local function saveExistingLocalConfig(fileName, configurationName, saveSettings, saveMetadata)
  local normalizedFileName = type(fileName) == "string" and fileName:gsub("%.pc$", "") or ""
  if normalizedFileName == "" then
    return { success = false, reason = "invalidFilename" }
  end

  local list = getConfigList()
  if type(list) ~= "table" then
    return { success = false, reason = "noVehicle" }
  end

  local existingConfig = nil
  for _, entry in ipairs(list) do
    if entry.name == normalizedFileName then
      existingConfig = entry
      break
    end
  end

  if not existingConfig then
    return { success = false, reason = "configNotFound" }
  end

  if not existingConfig.player then
    return { success = false, reason = "notPlayerConfig" }
  end

  local targetName = type(configurationName) == "string" and configurationName:gsub("^%s+", ""):gsub("%s+$", "") or ""
  if targetName == "" then
    targetName = existingConfig.displayName or existingConfig.name or normalizedFileName
  end

  return saveLocalConfigToFile(normalizedFileName, targetName, saveSettings, saveMetadata)
end

local function openConfigFolderInExplorer()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end

  if not fileExistsOrNil(playerVehicle.vehicleDirectory) then  -- create dir if it doesnt exist
    FS:directoryCreate(playerVehicle.vehicleDirectory, true)
  end
   Engine.Platform.exploreFolder(playerVehicle.vehicleDirectory)
end

-- Part highlighting draws the vehicle as an x-ray ghost with the highlighted parts kept real on top
-- of it. Every mesh holds its own alpha and eases toward its target, so changing the selection
-- crossfades the parts that changed instead of popping, and so does entering or leaving the x-ray.
-- alpha per second. On M so it can be retuned from the console while watching a fade:
--   core_vehicle_partmgmt.xrayFadeRate = 5
M.xrayFadeRate = 5
local xrayVehID = nil
local xrayTarget = {}  -- mesh name -> alpha it is heading for
local xrayCurrent = {} -- mesh name -> alpha it is at
local xrayFaded = {}   -- meshes owned by the ghost overlay (non-selected)
local xrayOverlay = {} -- partially visible meshes drawn by the translucent overlay
local xraySolid = {}   -- fully visible meshes drawn after the ghost with their normal materials
local xrayHidden = {}  -- selected meshes set to 0% visibility, kept out of the ghost so nothing is drawn
local xrayAnimating = false
local xrayPassesDirty = false
local partsSelectorChangedTime = nil
local partsSelectorChangedState = nil

local function clearXrayState(restoreAlpha)
  local vehObj = xrayVehID and getObjectByID(xrayVehID)
  if vehObj then
    if restoreAlpha then
      for mesh in pairs(xrayCurrent) do
        vehObj:setMeshAlpha(1, mesh, false)
      end
    end
    vehObj:clearRenderPass(0)
    vehObj:clearRenderPass(1)
    vehObj:clearRenderPass(3)
  end

  table.clear(xrayTarget)
  table.clear(xrayCurrent)
  table.clear(xrayFaded)
  table.clear(xrayOverlay)
  table.clear(xraySolid)
  table.clear(xrayHidden)
  xrayVehID = nil
  xrayAnimating = false
  xrayPassesDirty = false
  partsSelectorChangedTime = nil
  partsSelectorChangedState = nil
end

local function clearVehicleHighlights(inVehID)
  if not inVehID or xrayVehID == inVehID then
    clearXrayState(true)
  end
end

-- The normal base handles alpha state. Ghost, fading, and solid selected meshes are layered after it.
local function applyXrayPasses(vehObj)
  local faded = {}
  local overlay = {}
  local solid = {}
  local needGhost = false
  for mesh, target in pairs(xrayTarget) do
    local current = xrayCurrent[mesh] or 1
    if target < 1 or current < 1 then
      needGhost = true
    end
    -- ghost by target so it appears as soon as a part is deselected, not after the fade finishes
    if target < 0.999 and not xrayHidden[mesh] then
      table.insert(faded, mesh)
    end
    if current > 0.001 and current < 0.999 then
      table.insert(overlay, mesh)
    elseif target >= 0.999 and current >= 0.999 then
      table.insert(solid, mesh)
    end
  end

  if not needGhost then
    vehObj:clearRenderPass(0)
    vehObj:clearRenderPass(1)
    vehObj:clearRenderPass(3)
    table.clear(xrayFaded)
    table.clear(xrayOverlay)
    table.clear(xraySolid)
    return
  end

  table.sort(faded)
  table.sort(overlay)
  table.sort(solid)
  if table.concat(faded, '\0') == table.concat(xrayFaded, '\0')
    and table.concat(overlay, '\0') == table.concat(xrayOverlay, '\0')
    and table.concat(solid, '\0') == table.concat(xraySolid, '\0') then
    return
  end
  xrayFaded = faded
  xrayOverlay = overlay
  xraySolid = solid

  if #faded > 0 then
    vehObj:setRenderPass(0, 'vehicleGhost', faded, false, true)
  else
    vehObj:clearRenderPass(0)
  end
  if #solid > 0 then
    vehObj:setRenderPass(1, '', solid, true, true, false)
  else
    vehObj:clearRenderPass(1)
  end
  if #overlay > 0 then
    vehObj:setRenderPass(3, '', overlay, true, true)
  else
    vehObj:clearRenderPass(3)
  end
end

local function updateXrayFade(dt)
  if not xrayAnimating then return end

  local vehObj = xrayVehID and getObjectByID(xrayVehID)
  if not vehObj then
    clearXrayState(false)
    return
  end

  if xrayPassesDirty then
    if not vehObj:prepareTranslucentPermutations() then
      return
    end
    applyXrayPasses(vehObj)
    xrayPassesDirty = false
  end

  local step = dt * (M.xrayFadeRate or 0.5)
  local done = true
  local membershipChanged = false
  for mesh, target in pairs(xrayTarget) do
    local current = xrayCurrent[mesh] or 1
    if math.abs(target - current) > 0.001 then
      local wasDrawn = current > 0.001
      local wasSolid = current >= 0.999
      current = current < target and math.min(current + step, target) or math.max(current - step, target)
      xrayCurrent[mesh] = current
      vehObj:setMeshAlpha(current, mesh, false)
      done = false
      if wasDrawn ~= (current > 0.001) or wasSolid ~= (current >= 0.999) then
        membershipChanged = true
      end
    elseif current ~= target then
      xrayCurrent[mesh] = target
      vehObj:setMeshAlpha(target, mesh, false)
    end
  end

  if membershipChanged or done then
    applyXrayPasses(vehObj)
  end
  xrayAnimating = not done
end

-- bdebug filters its node/beam/triangle visualizations by this map, so it has to be kept in sync
-- with the highlight state whenever the selection or the parts tree changes.
local function sendPartsSelected(vehObj, partNames)
  vehObj:queueLuaCommand(string.format('bdebug.setPartsSelected(%s)', serialize(partNames)))
end

-- Actually sets transparency of meshes related to parts. Anything not selected fades out completely
-- and is left to the x-ray ghost underneath.
local function collectPartMeshes(partsData, partNames)
  local meshes = {}
  for partPath, selected in pairs(partNames) do
    if selected then
      for _, mesh in ipairs(partsData.highlightMeshesByPart[partPath] or {}) do
        meshes[mesh] = true
      end
    end
  end
  return meshes
end

-- cameraParts is the set the part camera frames, which is not always what is highlighted: the camera
-- follows what the user points at, so a forced highlight cannot drag it around. An empty set releases
-- the camera back to the player once the selection stays empty.
local function updatePartFocusCamera(vehID, partsData, cameraParts, cameraOptions)
  if type(cameraParts) == 'table' and next(cameraParts) then
    extensions.core_vehicle_partFocusCamera.focusOnParts(
      vehID,
      cameraParts,
      collectPartMeshes(partsData, cameraParts),
      nil,
      cameraOptions
    )
  else
    extensions.core_vehicle_partFocusCamera.release(type(cameraOptions) == 'table' and cameraOptions.immediate == true)
  end
end

local function releasePartFocusCamera()
  extensions.core_vehicle_partFocusCamera.clear()
end

local function setPartsMeshesAlpha(vehObj, partsData, partNames, alpha)
  local vehID = vehObj:getId()
  local selectedMeshes = collectPartMeshes(partsData, partNames)

  local allPartsSelected = alpha >= 1
  for _, partPath in ipairs(partsData.partsSorted) do
    if not partNames[partPath] then
      allPartsSelected = false
      break
    end
  end
  if allPartsSelected then
    clearVehicleHighlights(vehID)
    sendPartsSelected(vehObj, partNames)
    return selectedMeshes
  end

  if xrayVehID ~= vehID then
    clearXrayState(true)
    xrayVehID = vehID
    vehObj:prepareTranslucentPermutations()
  end

  local changed = false
  for _, mesh in ipairs(partsData.allMeshes) do
    if xrayCurrent[mesh] == nil then
      xrayCurrent[mesh] = 1
      vehObj:setMeshAlpha(1, mesh, false)
    end
    local target = selectedMeshes[mesh] and alpha or 0
    local hidden = selectedMeshes[mesh] and alpha <= 0.001 or nil
    if xrayTarget[mesh] ~= target or xrayHidden[mesh] ~= hidden then
      xrayTarget[mesh] = target
      xrayHidden[mesh] = hidden
      changed = true
    end
  end

  -- Meshes removed by a configuration change must not retain stale alpha.
  for mesh in pairs(xrayCurrent) do
    if not partsData.allMeshesSet[mesh] and xrayTarget[mesh] ~= 1 then
      xrayTarget[mesh] = 1
      changed = true
    end
  end

  -- the ui calls this on every hover and on a debounce timer, so doing nothing when the selection
  -- did not actually move is what keeps an in flight fade smooth
  if changed then
    xrayPassesDirty = true
    xrayAnimating = true
  end

  sendPartsSelected(vehObj, partNames)
  return selectedMeshes
end

-- Sets transparency of highlighted parts
-- If inVehID is nil, it uses player vehicle
local function setHighlightedPartsVisiblity(alpha, inVehID)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end

  partsData.alpha = alpha

  setPartsMeshesAlpha(vehObj, partsData, partsData.partsHighlighted, alpha)
end

-- Changes transparency of highlighted parts by delta value
-- If inVehID is nil, it uses player vehicle
local function changeHighlightedPartsVisiblity(deltaAlpha, inVehID)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end

  partsData.alpha = clamp(partsData.alpha + deltaAlpha, 0, 1)

  setPartsMeshesAlpha(vehObj, partsData, partsData.partsHighlighted, partsData.alpha)
end

-- Just shows parts highlighted
-- cameraParts lets the caller keep the part camera on something while the highlight goes back to normal
-- If inVehID is nil, it uses player vehicle
local function showHighlightedParts(inVehID, cameraParts, cameraOptions)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end

  setPartsMeshesAlpha(vehObj, partsData, partsData.partsHighlighted, partsData.alpha)
  updatePartFocusCamera(vehID, partsData, cameraParts, cameraOptions)
end

-- Highlighting refers to clicking on the "eye" icon
-- If inVehID is nil, it uses player vehicle
local function highlightParts(parts, inVehID)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end

  table.clear(partsData.partsHighlightedIdxs)

  -- A local helper function to recurse through the 'children'.
  local function highlightNode(node)
    if node.chosenPartName and node.chosenPartName ~= '' then
      if parts[node.partPath] then
        partsData.partsHighlighted[node.partPath] = parts[node.partPath]
        table.insert(partsData.partsHighlightedIdxs, partsData.partNameToIdx[node.partPath])
      else
        partsData.partsHighlighted[node.partPath] = false
      end
    end

    -- Recurse on any further children.
    if node.children then
      for _, childNode in pairs(node.children) do
        highlightNode(childNode)
      end
    end
  end

  highlightNode(vehData.config.partsTree or {})
  setPartsMeshesAlpha(vehObj, partsData, parts, partsData.alpha)
end

-- selecting refers to hovering over a part in the UI (only temporary)
-- cameraParts defaults to the highlighted parts
-- If inVehID is nil, it uses player vehicle
local function selectParts(parts, inVehID, cameraParts, cameraOptions)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end
  setPartsMeshesAlpha(vehObj, partsData, parts, 1)
  updatePartFocusCamera(vehID, partsData, type(cameraParts) == 'table' and cameraParts or parts, cameraOptions)
end

-- Merge old part highlights with new vehicle parts
-- When new part added, its visiblity is set to the parent part visiblity,
-- as well as its children to prevent weirdness
-- If inVehID is nil, it uses player vehicle
function setNewParts(inVehID, silent)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end

  local partsFlattened = {}
  local newHighlightedParts = {}
  local oldPartsHighlighted = partsData.partsHighlighted

  local function recHighlightNode(node, parentHighlight)
    local highlight = nil
    if node.partPath then
      partsFlattened[node.partPath] = true
      if oldPartsHighlighted then
        if oldPartsHighlighted[node.partPath] ~= nil then
          -- Existing part uses old highlight
          highlight = oldPartsHighlighted[node.partPath]
        else
          -- New part uses parent part highlight
          highlight = parentHighlight
        end
      else
        highlight = parentHighlight
      end
      newHighlightedParts[node.partPath] = highlight
    end
    if node.children then
      for _, childNode in pairs(node.children) do
        recHighlightNode(childNode, highlight)
      end
    end
  end

  recHighlightNode(vehData.config.partsTree or {}, true)

  local partsSorted = tableKeysSorted(partsFlattened)
  partsData.partsHighlighted = newHighlightedParts
  partsData.partsSorted = partsSorted

  table.clear(partsData.partsHighlightedIdxs)
  table.clear(partsData.partNameToIdx)

  for k, partName in ipairs(partsSorted) do
    if newHighlightedParts[partName] then
      table.insert(partsData.partsHighlightedIdxs, k)
    end
    partsData.partNameToIdx[partName] = k
  end
  partsData.allMeshes, partsData.allMeshesSet, partsData.highlightMeshesByPart =
    processHighlightMeshes(vehData)

  if not silent then
    sendPartsSelected(vehObj, newHighlightedParts)
  end
end

local function sendPartsSelectorStateToUI()
  local vehObj, vehData, vehID, partsData = getVehData()
  if not vehObj then return end

  local uiData = {
    vehID = vehID,
    partsSorted = partsData.partsSorted,
    partsHighlightedIdxs = partsData.partsHighlightedIdxs,
  }
  guihooks.trigger("PartsSelectorUpdate", uiData)
end

local function partsSelectorChangedDebounced(state)
  local vehObj, vehData, vehID, partsData = getVehData(state.vehID)
  if not vehObj then return end

  local partsSelected = {}
  for _, idx in ipairs(state.partsHighlightedIdxs) do
    partsSelected[state.partsSorted[idx]] = true
  end
  highlightParts(partsSelected, vehID)
end

local function partsSelectorChanged(state)
  partsSelectorChangedState = state
  partsSelectorChangedTime = os.clockhp()
end

-- Clears out all highlights data (parts highlighted, mesh transparency, and vehicle)
-- If inVehID is nil, it uses player vehicle
local function resetVehicleHighlights(onlyIfVehChanged, inVehID)
  local vehObj, vehData, vehID, partsData = getVehData(inVehID)
  if not vehObj then return end

  local clear = true

  if onlyIfVehChanged then
    local name = getObjectByID(vehID):getJBeamFilename()
    local oldName = partsData.vehName

    if name == oldName then
      clear = false
    end
  end

  if clear then
    vehsPartsData[vehID] = nil

    -- fade back to the solid vehicle rather than popping. applyXrayPasses drops the ghost and the
    -- overlay by itself once every mesh is back at 1.
    -- everything ever touched, not just what the last selection listed, so nothing is left faded
    if xrayVehID == vehID and next(xrayCurrent) then
      for mesh in pairs(xrayCurrent) do
        xrayTarget[mesh] = 1
      end
      xrayAnimating = true
    end
    extensions.core_vehicle_partFocusCamera.clear()
  end
end

local function resetConfig()
  mergeConfig({parts = {}, vars = {}}, true)
end

local function resetAllToLoadedConfig()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  loadLocal(playerVehicle.config.partConfigFilename)
end

-- Used by Vehicle Config -> Parts "Reset" button to reset parts back to loaded config
local function resetPartsToLoadedConfig()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  local pcFilename = playerVehicle.config.partConfigFilename
  local parts = nil
  if pcFilename then
    local data = buildConfigFromString(playerVehicle.vehicleDirectory, pcFilename)
    if data ~= nil then
      parts = data.parts
    end
  end
  if parts == nil then
    parts = {}
  end
  setPartsConfig(parts, true)
end

local function resetVarsToLoadedConfig()
  local playerVehicle = resolveConfigVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  local pcFilename = playerVehicle.config.partConfigFilename
  local vars = nil
  if pcFilename then
    local data = buildConfigFromString(playerVehicle.vehicleDirectory, pcFilename)
    if data ~= nil then
      vars = data.vars
    end
  end
  if vars == nil then
    vars = {}
  end
  setConfigVars(vars, true)
end

local function onVehicleSpawned(vehID)
  if xrayVehID == vehID or (partsSelectorChangedState and partsSelectorChangedState.vehID == vehID) then
    clearXrayState(true)
  end
  -- Invalidate the rich part info on vehicle spawned
  vehsRichPartInfo[vehID] = nil
end

local function onVehicleSwitched(oldID, newID, player)
  local targetPlayer = extensions.core_vehicle_configTarget.getTargetPlayerId() or 0
  if player == targetPlayer and oldID ~= newID then
    clearXrayState(true)
  end
end

local function onVehicleDestroyed(vehID)
  if xrayVehID == vehID or (partsSelectorChangedState and partsSelectorChangedState.vehID == vehID) then
    clearXrayState(false)
  end
  vehsPartsData[vehID] = nil
  vehsRichPartInfo[vehID] = nil
end

local function onVehicleConfigTargetChanged(current)
  clearXrayState(true)
  if current and current.vehId then
    sendDataToUI(current.vehId)
  end
end

local function onExtensionUnloaded()
  clearXrayState(true)
end

local function onLanguageChanged()
  table.clear(vehsRichPartInfo)
  saveConfigUtils.clearCache()
end

local function onReloadLocales()
  table.clear(vehsRichPartInfo)
  saveConfigUtils.clearCache()
end

local function onUpdate(dt)
  if partsSelectorChangedTime then
    if os.clockhp() - partsSelectorChangedTime > 0.1 then
      partsSelectorChangedDebounced(partsSelectorChangedState)
      partsSelectorChangedState = nil
      partsSelectorChangedTime = nil
    end
  end
  updateXrayFade(dt)
end

local function onFilesChanged(files)
  saveConfigUtils.clearCache()
  -- detect and invalidate part packs collect cache when part packs files change
  for _, fileData in pairs(files or {}) do
    local filename = fileData and fileData.filename
    if type(filename) == 'string' and string.endswith(filename, '.partpacks.json') then
      partPacksFunctions.invalidateCollectCache()
      --log('I', 'partmgmt', 'invalidated partpacks collect cache due to file change: ' .. tostring(filename))
      return
    end
  end
end

local function onSerialize()
  clearXrayState(true)
  return {
    vehsPartsData = vehsPartsData,
    vehsRichPartInfo = vehsRichPartInfo,
  }
end

local function onDeserialized(data)
  vehsPartsData = data.vehsPartsData
  vehsRichPartInfo = data.vehsRichPartInfo
end

-- public interface
M.save = savePartConfigFile
M.compileVehicleCollection = compileVehicleCollection
M.saveVehicleCollection = saveVehicleCollection

-- TODO: CHANGE THIS LATER TO FORMAT 4
M.savePartConfigFileStage2 = savePartConfigFileStage2_Format2 --savePartConfigFileStage2

M.buildConfigFromString = buildConfigFromString
M.partsTreeToPartsMap = partsTreeToPartsMap
M.setHighlightedPartsVisiblity = setHighlightedPartsVisiblity
M.changeHighlightedPartsVisiblity = changeHighlightedPartsVisiblity
M.highlightParts = highlightParts
M.selectParts = selectParts
M.setNewParts = setNewParts
M.showHighlightedParts = showHighlightedParts
M.resetVehicleHighlights = resetVehicleHighlights
M.clearVehicleHighlights = clearVehicleHighlights
M.setConfigOfVehicle = mergeConfigOfVehicle
M.setConfig = mergeConfig
M.setConfigPaints = setConfigPaints
M.setConfigVars = setConfigVars
M.setPartsConfig = setPartsConfig
M.setPartsTreeConfig = setPartsTreeConfig
M.getConfig = getConfig
M.getConfigOfVehicle = getConfigOfVehicle
M.getConfigVehicleId = resolveConfigVehicleId
M.resetConfig = resetConfig
M.reset = reset
M.sendDataToUI = sendDataToUI
M.sendPartsSelectorStateToUI = sendPartsSelectorStateToUI
M.releasePartFocusCamera = releasePartFocusCamera
M.partsSelectorChanged = partsSelectorChanged
M.getConfigList = getConfigList
M.getCurrentLocalConfigName = getCurrentLocalConfigName
M.getSaveMetadataFields = getSaveMetadataFields
M.openConfigFolderInExplorer = openConfigFolderInExplorer
M.loadLocal = loadLocal
M.removeLocal = removeLocal
M.resetAllToLoadedConfig = resetAllToLoadedConfig
M.resetPartsToLoadedConfig = resetPartsToLoadedConfig
M.resetVarsToLoadedConfig = resetVarsToLoadedConfig
M.saveLocal = saveLocal
M.setCurrentConfigurationName = setCurrentConfigurationName
M.getSaveAvailability = getSaveAvailability
M.saveNewLocalConfig = saveNewLocalConfig
M.saveExistingLocalConfig = saveExistingLocalConfig
M.validatePaints = validatePaints
M.getCurrentLicensePlate = getCurrentLicensePlate
M.setCurrentLicensePlate = setCurrentLicensePlate
M.regenerateCurrentLicensePlate = regenerateCurrentLicensePlate
M.saveLocalScreenshot = saveLocalScreenshot
M.saveLocalScreenshot_stage2 = saveLocalScreenshot_stage2
M.savedefault = savedefault
M.hasAvailablePart = hasAvailablePart
M.setSkin = setSkin
M.getTranslation = getTranslation
M.translateTuningData = translateTuningData

M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onVehicleDestroyed = onVehicleDestroyed
M.onVehicleConfigTargetChanged = onVehicleConfigTargetChanged
M.onExtensionUnloaded = onExtensionUnloaded
M.onUpdate = onUpdate
M.onFilesChanged = onFilesChanged
M.onLanguageChanged = onLanguageChanged
M.onReloadLocales = onReloadLocales
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
