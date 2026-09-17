-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


local M = {}

local debugLog =  nop
local debugModelKey, debugConfigKey
local debugLogFun = function(message)
  if debugConfigKey == nil or debugConfigKey == "bastion_base" then
    log("I","", string.format("%s %s: %s", debugModelKey and debugModelKey .. " " or "", debugConfigKey and "config " .. debugConfigKey or "", message))
  end
end

local precision = 10000
M.paintSignature = function(paint) return string.format("{\"baseColor\":[%0.5f,%0.5f,%0.5f,%0.5f],\"clearcoat\":%0.5f,\"clearcoatRoughness\":%0.5f,\"metallic\":%0.5f,\"roughness\":%0.5f}", round(paint.baseColor[1]*precision)/precision, round(paint.baseColor[2]*precision)/precision, round(paint.baseColor[3]*precision)/precision, round(paint.baseColor[4]*precision)/precision, round(paint.clearcoat*precision)/precision, round(paint.clearcoatRoughness*precision)/precision, round(paint.metallic*precision)/precision, round(paint.roughness*precision)/precision) end

M.multiPaintSetupSignature = function(multiPaintSetup) return string.format("{\"paint1\":%s,\"paint2\":%s,\"paint3\":%s}", M.paintSignature(multiPaintSetup.paint1), M.paintSignature(multiPaintSetup.paint2), M.paintSignature(multiPaintSetup.paint3)) end

local paintsByIdCache = nil
local paintsByNameAsListCache = nil
local paintCollectionsByIdCache = nil
local multiPaintSetupsByIdCache = nil
local OFFICIAL_AUTHOR = "BeamNG"
local missingPaint = {
  name = "Missing Paint",
  id = "_missing_paint_",
  baseColor = {0.5, 0.5, 0.5, 0.5},
  clearcoat = 0.5,
  clearcoatRoughness = 0.5,
  metallic = 0.5,
  roughness = 0.5,
}

local function isEntryOfficial(entry)
  return type(entry) == "table" and entry.Author == OFFICIAL_AUTHOR
end

local function markPaintOfficial(paint, isOfficial)
  if type(paint) ~= "table" then return end
  paint._official = isOfficial == true
end

local function markMultiPaintSetupOfficial(setup, isOfficial)
  if type(setup) ~= "table" then return end
  setup._official = isOfficial == true
end

local function stripPaintOfficialFlag(paint)
  if type(paint) ~= "table" then return end
  paint._official = nil
end

local function stripMultiPaintSetupOfficialFlag(setup)
  if type(setup) ~= "table" then return end
  setup._official = nil
  for i = 1, 3 do
    stripPaintOfficialFlag(setup["paint" .. i])
  end
end
local function buildPaintCaches()
  -- Global cache builder (dependency-ordered):
  --   G1 CollectRaw:
  --      - read every paint library file
  --      - register paints, multiPaintSetups, and raw paintCollections
  --      - do not validate cross-references yet
  --   G2 ResolveMultiPaintSetups:
  --      - validate each setup's paint1/2/3 against the global paint cache
  --      - clear invalid paint refs and log errors
  --   G3 ResolvePaintCollections:
  --      - resolve collection paints against global paints
  --      - validate collection multiPaintSetups against global multiPaintSetup cache
  --   Finalize:
  --      - assign paint ids, compute duplicate-name stats, log summary
  --
  -- Why this order:
  --   multiPaintSetups depend on paints, and collections depend on both paints
  --   and multiPaintSetups. Collect first, then resolve by dependency.
  paintsByIdCache = { _missing_paint_ = missingPaint }
  paintsByNameAsListCache = { }
  paintCollectionsByIdCache = {}
  multiPaintSetupsByIdCache = {}

  local rawPaintCollectionsById = {}
  local multiPaintSetupSourceById = {}

  -- G1: collect all raw entities from files (no cross-reference validation yet)
  for _, paintFilePath in pairs(core_vehicles.getPaintFiles()) do
    local paintFile = core_vehicles.getFilesParsed()[paintFilePath]
    local isOfficialPaintFile = isOfficialContentVPath and isOfficialContentVPath(paintFilePath) or false
    local _, filename, _ = path.split(paintFilePath, true)
    local paintFileCollection = {
      name = filename,
      class = "custom",
      paints = {},
      multiPaintSetups = {},
      _official = isOfficialPaintFile,
    }

    for id, paint in pairs(paintFile.paints or {}) do
      paint.sources = nil
      markPaintOfficial(paint, isOfficialPaintFile)
      if paintsByIdCache[id] then
        log('E', 'vehicles', 'duplicate paint id: ' .. id .. ' in ' .. paintFilePath)
      else
        paintsByIdCache[id] = paint
      end
      if not paintsByNameAsListCache[paint.name] then
        paintsByNameAsListCache[paint.name] = {}
      end
      table.insert(paintsByNameAsListCache[paint.name], paint)
      table.insert(paintFileCollection.paints, id)
    end
    for id, setup in pairs(paintFile.multiPaintSetups or {}) do
      markMultiPaintSetupOfficial(setup, isOfficialPaintFile)
      multiPaintSetupsByIdCache[id] = setup
      multiPaintSetupSourceById[id] = paintFilePath
      table.insert(paintFileCollection.multiPaintSetups, id)
    end
    for id, collection in pairs(paintFile.paintCollections or {}) do
      if type(collection) == "table" then
        collection._official = isOfficialPaintFile
      end
      rawPaintCollectionsById[id] = collection
    end
    rawPaintCollectionsById[filename] = paintFileCollection
  end

  -- G2: resolve multiPaintSetups against already collected paints
  for id, setup in pairs(multiPaintSetupsByIdCache) do
    local sourcePath = multiPaintSetupSourceById[id] or "unknown file"
    for i = 1, 3 do
      local paintKey = "paint" .. i
      if type(setup[paintKey]) == 'string' and not paintsByIdCache[setup[paintKey]] then
        log('E', 'vehicles', 'paint ' .. setup[paintKey] .. ' not found in ' .. sourcePath .. ' for multiPaintSetup ' .. id)
        setup[paintKey] = nil
      end
    end
  end

  -- G3: resolve paintCollections against paints + multiPaintSetups
  for cId, collection in pairs(rawPaintCollectionsById) do
    local cleanCollection = {
      name = collection.name,
      class = collection.class,
      paints = {},
      multiPaintSetups = {},
      _official = collection._official == true,
    }
    -- resolve all the paints in the collection
    for _, paint in pairs(collection.paints or {}) do
      if type(paint) == 'string' then paint = {id = paint} end
      if not paintsByIdCache[paint.id] then
        log('E', 'vehicles', "paint " .. dumps(paint.id) .. " not found in paint collection " .. dumps(collection.name or cId))
      else
        table.insert(cleanCollection.paints, tableMerge(paint, paintsByIdCache[paint.id]))
      end
    end
    -- resolve all the multiPaintSetups in the collection
    for _, setup in pairs(collection.multiPaintSetups or {}) do
      if type(setup) == 'string' then
        if not multiPaintSetupsByIdCache[setup] then
          log('E', 'vehicles', "multiPaintSetup " .. dumps(setup) .. " not found in paint collection " .. dumps(collection.name or cId))
        else
          table.insert(cleanCollection.multiPaintSetups, setup)
        end
      else
        table.insert(cleanCollection.multiPaintSetups, setup)
      end
    end

    paintCollectionsByIdCache[cId] = cleanCollection
  end
  for id, paint in pairs(paintsByIdCache) do
    paint.id = id
  end
  local multiNames = 0
  for name, paints in pairs(paintsByNameAsListCache) do
    if #paints > 1 then
      multiNames = multiNames + 1
    end
  end

  -- create procedural paint collections

  log("I","",string.format("Found %d paints, %d paint collections, %d multiPaintSetups in %d paint libraries, %d same-name paint names", #tableKeys(paintsByIdCache), #tableKeys(paintCollectionsByIdCache), #tableKeys(multiPaintSetupsByIdCache), #tableKeys(core_vehicles.getPaintFiles()), multiNames))
end

local function getPaintById(id)
  if not paintsByIdCache then buildPaintCaches() end
  return deepcopy(paintsByIdCache[id])
end

local function getPaintCollectionById(id)
  if not paintCollectionsByIdCache then buildPaintCaches() end
  return deepcopy(paintCollectionsByIdCache[id])
end


local function resolvePaintHelper(modelPaints, paintKeyOrPaint, paintIdsToPaintNames)
  local paint = nil

  if type(paintKeyOrPaint) == 'string' then
    debugLog("resolving paint " .. dumps(paintKeyOrPaint))
    paint = modelPaints[paintKeyOrPaint]
  elseif type(paintKeyOrPaint) == 'table' then
    debugLog("resolving paint " .. dumps(paintKeyOrPaint.name))
    paint = paintKeyOrPaint
  end
  if paint then
    debugLog("paint found: " .. dumps(paint.name))
    if not modelPaints[paint.name] then
      debugLog("added paint " .. dumps(paint.name) .. " to model. This paint was explicitly defined")
      paint.class = 'custom'
      modelPaints[paint.name] = paint
      return paint, true
    end
    return paint
  end

  if not paint then
    local paintName = paintIdsToPaintNames[paintKeyOrPaint]
    if paintName then
      paint = modelPaints[paintName]
      if paint then
        debugLog("paint found: " .. dumps(paint.name) .. ". Paint was already added to the model")
        return paint
      end
    end
  end
  if not paint then
    paint = getPaintById(paintKeyOrPaint)
    if paint then
      paint.class = 'custom'
      modelPaints[paint.name] = paint
      paintIdsToPaintNames[paintKeyOrPaint] = paint.name
      debugLog("adding paint to model: " .. dumps(paint.id) .. "/" .. dumps(paint.name) .. " (from library) ")
      return paint, true
    end
  end
  if not paint then
    local paints = paintsByNameAsListCache[paintKeyOrPaint]
    if paints then
      log("W", "vehicles", "paint " .. dumps(paintKeyOrPaint) .. " from config " .. dumps(debugModelKey) .. "/" .. dumps(debugConfigKey) .. " not found in the model file. But found by name in the paint library.. Please use the id instead: " .. dumps(paints[1].id) .. " or add the paint to the model file.")
      paint = deepcopy(paints[1])
      paint.class = 'custom'
      modelPaints[paint.name] = paint
      paintIdsToPaintNames[paint.id] = paint.name
      return paint, true
    end
  end
  return paint
end

local function resolveMultiPaintSetupHelper(model, multiPaintSetupKeyOrMultiPaintSetup, paintIdsToPaintNames, multiPaintSetupsByIdOrName)
  local multiPaintSetup = nil
  if type(multiPaintSetupKeyOrMultiPaintSetup) == 'string' then
    if multiPaintSetupsByIdOrName[multiPaintSetupKeyOrMultiPaintSetup] then
      multiPaintSetup = multiPaintSetupsByIdOrName[multiPaintSetupKeyOrMultiPaintSetup]
      if type(multiPaintSetup) == "table" and not multiPaintSetup.id then
        multiPaintSetup.id = multiPaintSetupKeyOrMultiPaintSetup
      end
      return multiPaintSetup
    else
      if multiPaintSetupsByIdCache and multiPaintSetupsByIdCache[multiPaintSetupKeyOrMultiPaintSetup] ~= nil then
        multiPaintSetup = deepcopy(multiPaintSetupsByIdCache[multiPaintSetupKeyOrMultiPaintSetup])
        if type(multiPaintSetup) == "table" and not multiPaintSetup.id then
          multiPaintSetup.id = multiPaintSetupKeyOrMultiPaintSetup
        end
      end
    end
    if not multiPaintSetup then
      log("E", "vehicles", "multiPaintSetup " .. dumps(multiPaintSetupKeyOrMultiPaintSetup) .. " not found in any paint library or model " ..dumps(debugModelKey) .. " " .. dumps(debugConfigKey))
      return nil
    end
  elseif type(multiPaintSetupKeyOrMultiPaintSetup) == 'table' then
    local multiPaintSetupRefId = multiPaintSetupKeyOrMultiPaintSetup.id
    if type(multiPaintSetupRefId) == 'string' then
      -- Allow table-form references (e.g. {id="foo", randomProbability=10}):
      -- resolve base setup by id, deepcopy it, then merge custom overrides.
      local baseMultiPaintSetup = nil
      if multiPaintSetupsByIdCache and multiPaintSetupsByIdCache[multiPaintSetupRefId] ~= nil then
        baseMultiPaintSetup = deepcopy(multiPaintSetupsByIdCache[multiPaintSetupRefId])
      else
        local alreadyResolved = multiPaintSetupsByIdOrName[multiPaintSetupRefId]
        if alreadyResolved then
          -- Convert resolved shape back to resolvable paint1/2/3 keys.
          baseMultiPaintSetup = {
            id = alreadyResolved.id or multiPaintSetupRefId,
            name = alreadyResolved.name,
            paint1 = alreadyResolved.paintName1,
            paint2 = alreadyResolved.paintName2,
            paint3 = alreadyResolved.paintName3,
            _official = alreadyResolved._official,
          }
        end
      end

      if not baseMultiPaintSetup then
        log("E", "vehicles", "multiPaintSetup id " .. dumps(multiPaintSetupRefId) .. " not found for table-based setup in model " ..dumps(debugModelKey) .. " " .. dumps(debugConfigKey))
        return nil
      end
      multiPaintSetup = tableMerge(baseMultiPaintSetup, multiPaintSetupKeyOrMultiPaintSetup)
    else
      multiPaintSetup = multiPaintSetupKeyOrMultiPaintSetup
    end
  end
  local multiPaintSetupWithNames = {
    id = multiPaintSetup.id,
    name = multiPaintSetup.name,
    usedByConfigByKey = {},
    isDefaultForConfigByKey = {},
    isDefaultForModel = multiPaintSetup.defaultForModel,
    generated = multiPaintSetup.generated,
    randomProbability = multiPaintSetup.randomProbability,
    class = multiPaintSetup.class,
    _official = multiPaintSetup._official == true,
  }



  debugLog("resolving multiPaintSetup: " .. dumps(multiPaintSetupWithNames.name))
  for i = 1, 3 do
    local defaultPaintKey = "paint" .. i
    if multiPaintSetup[defaultPaintKey] and multiPaintSetup[defaultPaintKey] ~= "" then
      local paint, _
      paint, _ = resolvePaintHelper(model.paints, multiPaintSetup[defaultPaintKey], paintIdsToPaintNames)
      if paint then
        multiPaintSetup[defaultPaintKey] = paint.name
        multiPaintSetupWithNames['paintName' .. i] = paint.name
      else
        log("E", "vehicles", "paint " .. dumps(multiPaintSetup[defaultPaintKey]) .. " not found in default paint list or any library for model " .. dumps(key) .. ", used as " ..dumps(defaultPaintKey) .. " in multiPaintSetup " .. dumps(multiPaintSetup.name or "unknown"))
      end
    else
      debugLog("paint " .. dumps(multiPaintSetup[defaultPaintKey]) .. " not found in default paint list or any library for model " .. dumps(key) .. ", used as " ..dumps(defaultPaintKey) .. " in multiPaintSetup " .. dumps(multiPaintSetup.name or "unknown"))
    end
  end

  multiPaintSetupWithNames.paintName2 = multiPaintSetupWithNames.paintName2 or multiPaintSetupWithNames.paintName1
  multiPaintSetupWithNames.paintName3 = multiPaintSetupWithNames.paintName3 or multiPaintSetupWithNames.paintName1

  if (multiPaintSetupWithNames.paintName1 or multiPaintSetupWithNames.paintName2 or multiPaintSetupWithNames.paintName3) then
    table.insert(model.multiPaintSetups, multiPaintSetupWithNames)
    return multiPaintSetupWithNames
  end
  return nil
end

local function setupPaints(model, configs)
  -- Model/config paint setup (shared phased flow, model-first):
  --   R1 Collect direct paints (model + configs)
  --   R2 Collect explicit libraryPaints (model + configs)
  --   R3 Collect/expand paintCollections (model + configs)
  --   R4 Resolve multiPaintSetups + defaults (model first, then configs)
  --   R5 Finalize classes/default fields
  debugModelKey = model.key
  debugConfigKey = nil
  --debugLog = model.key == 'simple_traffic' and debugLogFun or nop
  debugLog("setupPaints for model " .. dumps(model.key))

  local paintIdsToPaintNames = {}
  local configMultiPaintSetupsFromCollectionsByKey = {}
  local multiPaintSetupsByIdOrName = {}

  local function normalizeDirectPaints(target)
    target.paints = target.paints or {}
    local targetIsOfficial = isEntryOfficial(target)
    for name, paint in pairs(target.paints) do
      paint.name = name
      if paint._official == nil then
        markPaintOfficial(paint, targetIsOfficial)
      end
    end
  end

  local function normalizeMultiPaintSetups(target)
    target.multiPaintSetups = target.multiPaintSetups or {}
    local targetIsOfficial = isEntryOfficial(target)
    for setupKey, setup in pairs(target.multiPaintSetups) do
      if type(setup) == "table" then
        if setup.id == nil and type(setupKey) == "string" then
          setup.id = setupKey
        end
        if setup._official == nil then
          markMultiPaintSetupOfficial(setup, targetIsOfficial)
        end
      end
    end
    if type(target.defaultMultiPaintSetup) == "table" and target.defaultMultiPaintSetup._official == nil then
      markMultiPaintSetupOfficial(target.defaultMultiPaintSetup, targetIsOfficial)
    end
  end

  local function addPaintToScope(target, paint, sourceLabel)
    if paint._official == nil then
      markPaintOfficial(paint, isEntryOfficial(target))
    end
    target.paints[paint.name] = paint
    if target ~= model and not model.paints[paint.name] then
      -- Config paints are added to model scope so shared resolve helpers can find them.
      model.paints[paint.name] = paint
    end
    if paint.id then
      paintIdsToPaintNames[paint.id] = paint.name
    end
    if sourceLabel then
      debugLog(sourceLabel .. ": " .. dumps(paint.id) .. "/" .. dumps(paint.name))
    end
  end

  local function collectLibraryPaints(target, ownerLabel)
    for _, paint in pairs(target.libraryPaints or {}) do
      if type(paint) == 'string' then paint = {id = paint} end
      local paintFromLibrary = getPaintById(paint.id)
      if paintFromLibrary then
        tableMerge(paintFromLibrary, paint)
        markPaintOfficial(paintFromLibrary, paintFromLibrary._official == true)
        addPaintToScope(target, paintFromLibrary, "adding paint from " .. ownerLabel .. ".libraryPaints to " .. (target == model and "model" or "config"))
      else
        log('E', 'vehicles', "paint " .. dumps(paint.id) .. " not found in any paint library for " .. ownerLabel .. " " .. dumps(target.key))
      end
    end
    target.libraryPaints = nil
  end

  local function collectCollectionPaints(target, ownerLabel)
    local multiPaintsFromCollections = {}
    for _, collectionId in ipairs(target.paintCollections or {}) do
      local collection = getPaintCollectionById(collectionId)
      if collection then
        local collectionIsOfficial = collection._official == true
        for _, paint in pairs(collection.paints or {}) do
          tableMerge(paint, paintsByIdCache[paint.id])
          paint.class = collection.class
          markPaintOfficial(paint, collectionIsOfficial)
          addPaintToScope(target, paint, "adding paint from " .. ownerLabel .. ".paintCollections to " .. (target == model and "model" or "config") .. " (from collection " .. dumps(collectionId) .. ")")
        end
        local collectionMultiPaintSetups = {}
        for _, setup in pairs(collection.multiPaintSetups or {}) do
          if type(setup) == "table" then
            local setupCopy = deepcopy(setup)
            markMultiPaintSetupOfficial(setupCopy, collectionIsOfficial)
            table.insert(collectionMultiPaintSetups, setupCopy)
          else
            table.insert(collectionMultiPaintSetups, setup)
          end
        end
        tableMerge(multiPaintsFromCollections, collectionMultiPaintSetups)
      else
        log('E', 'vehicles', "paint collection " .. dumps(collectionId) .. " not found for " .. ownerLabel .. " " .. dumps(target.key))
      end
    end
    target.paintCollections = nil
    return multiPaintsFromCollections
  end

  local function registerResolvedMultiPaintSetup(multiPaintSetupWithNames, isForAllConfigs)
    if not multiPaintSetupWithNames then
      return nil
    end
    if not multiPaintSetupWithNames.id then
      multiPaintSetupWithNames.id = multiPaintSetupWithNames.name
    end
    if multiPaintSetupWithNames.id then
      multiPaintSetupsByIdOrName[multiPaintSetupWithNames.id] = multiPaintSetupWithNames
    end
    if multiPaintSetupWithNames.name then
      multiPaintSetupsByIdOrName[multiPaintSetupWithNames.name] = multiPaintSetupWithNames
    end
    if isForAllConfigs then
      multiPaintSetupWithNames.forAllConfigs = true
    end
    return multiPaintSetupWithNames
  end

  -- R1: collect direct paints (model + configs)
  normalizeDirectPaints(model)
  normalizeMultiPaintSetups(model)
  debugLog("Model has " .. #tableKeys(model.paints) .. " explicit paints: " .. table.concat(tableKeysSorted(model.paints), ", "))
  for _, config in pairs(configs) do
    normalizeDirectPaints(config)
    normalizeMultiPaintSetups(config)
    for _, paint in pairs(config.paints) do
      if paint._official == nil then
        markPaintOfficial(paint, isEntryOfficial(config))
      end
      if not model.paints[paint.name] then
        model.paints[paint.name] = paint
      end
      if paint.id then
        paintIdsToPaintNames[paint.id] = paint.name
      end
    end
  end

  -- R2: collect explicit libraryPaints (model + configs)
  collectLibraryPaints(model, "model")
  for _, config in pairs(configs) do
    collectLibraryPaints(config, "config")
  end

  -- R3: collect/expand paintCollections (model + configs)
  local modelMultiPaintSetupsFromCollections = collectCollectionPaints(model, "model")
  for _, config in pairs(configs) do
    configMultiPaintSetupsFromCollectionsByKey[config.key] = collectCollectionPaints(config, "config")
  end

  -- R4a: resolve model multiPaintSetups + model default
  local multiPaintSetupsToProcess = model.multiPaintSetups or {}
  tableMerge(multiPaintSetupsToProcess, modelMultiPaintSetupsFromCollections)
  model.multiPaintSetups = {}
  for _, multiPaintSetup in pairs(multiPaintSetupsToProcess) do
    local multiPaintSetupWithNames = resolveMultiPaintSetupHelper(model, multiPaintSetup, paintIdsToPaintNames, multiPaintSetupsByIdOrName)
    registerResolvedMultiPaintSetup(multiPaintSetupWithNames, true)
  end
  table.clear(multiPaintSetupsToProcess)

  local defaultMultiPaintSetup = model.defaultMultiPaintSetup
  if not defaultMultiPaintSetup then
    debugLog("no defaultMultiPaintSetup found for model " .. dumps(model.key)..". Using defaultPaintName1, defaultPaintName2, defaultPaintName3: " .. dumps(model.defaultPaintName1) .. ", " .. dumps(model.defaultPaintName2) .. ", " .. dumps(model.defaultPaintName3))
    defaultMultiPaintSetup = {
      name = model.Name .. " default paints",
      paint1 = model.defaultPaintName1,
      paint2 = model.defaultPaintName2 or model.defaultPaintName1,
      paint3 = model.defaultPaintName3 or model.defaultPaintName1,
      generated = true,
      _official = isEntryOfficial(model),
    }
  end
  local defaultMultiPaintSetupWithNames = resolveMultiPaintSetupHelper(model, defaultMultiPaintSetup, paintIdsToPaintNames, multiPaintSetupsByIdOrName)
  defaultMultiPaintSetupWithNames = registerResolvedMultiPaintSetup(defaultMultiPaintSetupWithNames, false)
  if defaultMultiPaintSetupWithNames then
    if not model.defaultMultiPaintSetup then
      defaultMultiPaintSetupWithNames.name = model.Name .. " default paints"
    end
    defaultMultiPaintSetupWithNames.defaultForModel = true
    defaultMultiPaintSetupWithNames.generated = defaultMultiPaintSetup.generated

    model.defaultPaintName1 = defaultMultiPaintSetupWithNames.paintName1
    model.defaultPaintName2 = defaultMultiPaintSetupWithNames.paintName2
    model.defaultPaintName3 = defaultMultiPaintSetupWithNames.paintName3

    local paint1 = model.paints[model.defaultPaintName1]
    model.defaultPaint = paint1 or {}
  end

  -- R4b: resolve each config's multiPaintSetups + defaults
  for _, config in pairs(configs) do
    debugConfigKey = config.key

    if config.defaultPaintName1 and config.defaultMultiPaintSetup then
      log("W","", model.key .. " " .. dumps(config.key) .. ": defaultPaintName1 overriden by defaultMultiPaintSetup")
    end

    local configDefaultMultiPaintSetup = config.defaultMultiPaintSetup

    if not configDefaultMultiPaintSetup then
      for i = 1, 3 do
        local defaultPaintKey = "defaultPaintName" .. i
        if config[defaultPaintKey] == nil or config[defaultPaintKey] == "" then
          config[defaultPaintKey] = i == 1 and model.defaultPaintName1 or config.defaultPaintName1
        end
      end

      configDefaultMultiPaintSetup = {
        name = config.Name .. " default paints",
        paint1 = config.defaultPaintName1,
        paint2 = config.defaultPaintName2,
        paint3 = config.defaultPaintName3,
        generated = true,
        _official = isEntryOfficial(config),
      }
      debugLog("no defaultMultiPaintSetup found for config " .. dumps(config.key)..". Using defaultPaintName1, defaultPaintName2, defaultPaintName3: " .. dumps(configDefaultMultiPaintSetup.paint1) .. ", " .. dumps(configDefaultMultiPaintSetup.paint2) .. ", " .. dumps(configDefaultMultiPaintSetup.paint3))
      if not (configDefaultMultiPaintSetup.paint1 or configDefaultMultiPaintSetup.paint2 or configDefaultMultiPaintSetup.paint3) then
        configDefaultMultiPaintSetup = nil
      end
    end

    if type(configDefaultMultiPaintSetup) == "table" and not configDefaultMultiPaintSetup.name then
      configDefaultMultiPaintSetup.name = config.Name .. " default paints"
    end

    local configMultiPaintSetupsToProcess = {}
    tableMerge(configMultiPaintSetupsToProcess, configMultiPaintSetupsFromCollectionsByKey[config.key] or {})
    tableMerge(configMultiPaintSetupsToProcess, config.multiPaintSetups or {})
    if configDefaultMultiPaintSetup then
      table.insert(configMultiPaintSetupsToProcess, configDefaultMultiPaintSetup)
    end

    config.multiPaintSetups = {}
    local configDefaultMultiPaintSetupWithNames = nil
    for _, multiPaintSetup in pairs(configMultiPaintSetupsToProcess) do
      local multiPaintSetupWithNames = resolveMultiPaintSetupHelper(model, multiPaintSetup, paintIdsToPaintNames, multiPaintSetupsByIdOrName)
      multiPaintSetupWithNames = registerResolvedMultiPaintSetup(multiPaintSetupWithNames, false)
      if multiPaintSetupWithNames then
        multiPaintSetupWithNames.usedByConfigByKey[config.key] = true
        if multiPaintSetup == configDefaultMultiPaintSetup then
          multiPaintSetupWithNames.isDefaultForConfigByKey[config.key] = true
          configDefaultMultiPaintSetupWithNames = multiPaintSetupWithNames
        end
        table.insert(config.multiPaintSetups, multiPaintSetupWithNames)
      else
        log("E", "vehicles", "multiPaintSetup " .. dumps(multiPaintSetup.name) .. " not found for config " .. dumps(config.key))
      end
    end

    if configDefaultMultiPaintSetupWithNames then
      if not config.defaultMultiPaintSetup then
        configDefaultMultiPaintSetupWithNames.name = config.Name .. " default paints"
      end
      if type(configDefaultMultiPaintSetup) == "table" then
        configDefaultMultiPaintSetupWithNames.generated = configDefaultMultiPaintSetup.generated
      end
      config.defaultPaintName1 = configDefaultMultiPaintSetupWithNames.paintName1
      config.defaultPaintName2 = configDefaultMultiPaintSetupWithNames.paintName2
      config.defaultPaintName3 = configDefaultMultiPaintSetupWithNames.paintName3
      config.defaultPaint = model.paints[config.defaultPaintName1] or {}
    end

  end

  -- R5: finalize
  for _, paint in pairs(model.paints) do
    if not paint.class then
      paint.class = 'factory'
    end
  end

  debugLog("Finished: Model has " .. #tableKeys(model.paints) .. " paints: " .. table.concat(tableKeysSorted(model.paints), ", "))




  --[[
  model.factoryPaintNames = {}
  model.customPaintNames = {}
  for _, paint in pairs(model.paints) do
    if paint.class == 'factory' then
      table.insert(model.factoryPaintNames, paint.name)
    elseif paint.class == 'custom' then
      table.insert(model.customPaintNames, paint.name)
    end
  end
  if model.key == 'pickup' then
    log("I", "vehicles", "model " .. dumps(key) .. "Factory paints: " .. table.concat(model.factoryPaintNames, ", "))
    log("I", "vehicles", "model " .. dumps(key) .. "Custom paints: " .. table.concat(model.customPaintNames, ", "))
  end
  ]]
end
M.setupPaints = setupPaints




local function setupRandomPaintHelper(model_key)
  local modelData = core_vehicles.getModel(model_key)
  local model = modelData.model
  local configs = modelData.configs


  -- random paint distribution
  local defaultRandomPaintProbability = model.defaultRandomPaintProbability or 1
  local defaultRandomMultiPaintProbability = model.defaultRandomMultiPaintProbability or 1
  debugLog("setupRandomPaintHelper for model " .. dumps(model_key))
  debugLog(string.format("defaultRandomPaintProbability: %0.3f, defaultRandomMultiPaintProbability: %0.3f", defaultRandomPaintProbability, defaultRandomMultiPaintProbability))

  -- first, remap every paint in randomPaintDistribution to use the paint names
  model.randomPaintDistribution = model.randomPaintDistribution or {}
  local newRandomPaintDistributionModel = {}
  for paintNameOrId, probability in pairs(model.randomPaintDistribution) do
    local paint = model.paints[paintNameOrId]
    if not paint then
      paint = paintsByIdCache[paintNameOrId]
    end
    if paint then
      newRandomPaintDistributionModel[paint.name] = probability
    end
  end
  -- then add all the remaining paint names with 1 probability
  for paintName, _ in pairs(model.paints) do
    newRandomPaintDistributionModel[paintName] = newRandomPaintDistributionModel[paintName] or defaultRandomPaintProbability
  end


  local multiPaintSetupsByName = {}
  for _, multiPaintSetup in ipairs(model.multiPaintSetups) do
    multiPaintSetupsByName[multiPaintSetup.name] = multiPaintSetup
  end

  -- then do the same for randomMultiPaintDistribution
  model.randomMultiPaintDistribution = model.randomMultiPaintDistribution or {}
  local newRandomMultiPaintDistributionModel = {}
  for multiPaintSetupNameOrId, probability in pairs(model.randomMultiPaintDistribution) do
    local multiPaintSetup = multiPaintSetupsByName[multiPaintSetupNameOrId]
    if not multiPaintSetup then
      multiPaintSetup = multiPaintSetupsByIdCache[multiPaintSetupNameOrId]
      multiPaintSetup = multiPaintSetupsByName[multiPaintSetup.name]
    end
    if multiPaintSetup then
      newRandomMultiPaintDistributionModel[multiPaintSetup.name] = probability
      multiPaintSetupsByName[multiPaintSetup.name] = multiPaintSetup
    end
  end
  for _, multiPaintSetup in ipairs(model.multiPaintSetups) do
    if multiPaintSetup.forAllConfigs then
      newRandomMultiPaintDistributionModel[multiPaintSetup.name] = newRandomMultiPaintDistributionModel[multiPaintSetup.name] or defaultRandomMultiPaintProbability
    end
  end

  -- finally, add all results into one list and add the sum of all probabilities
  local totalProbability = 0
  local allPaintResults = {}
  for paintName, probability in pairs(newRandomPaintDistributionModel) do
    totalProbability = totalProbability + probability
    if probability > 0 then
      table.insert(allPaintResults, {
        type = 'paint',
        paintName1 = paintName,
        paintName2 = paintName,
        paintName3 = paintName,
        probability = probability,
      })
    end
  end
  for multiPaintSetupName, probability in pairs(newRandomMultiPaintDistributionModel) do
    totalProbability = totalProbability + probability
    local multiPaintSetup = multiPaintSetupsByName[multiPaintSetupName]
    if probability > 0 then
      table.insert(allPaintResults, {
        type = 'multiPaintSetup',
        paintName1 = multiPaintSetup.paintName1,
        paintName2 = multiPaintSetup.paintName2,
        paintName3 = multiPaintSetup.paintName3,
        probability = probability,
      })
    end
  end
  model.randomPaintHelper = {
    allPaintResults = allPaintResults,
    totalProbability = totalProbability,
  }
  if debugLog ~= nop then
    debugLog("model " .. dumps(key) .. " has " .. #allPaintResults .. " paint results with total probability " .. totalProbability)
    for _, paintResult in pairs(allPaintResults) do
      debugLog("paint result: " .. dumps(paintResult.type) .. ", " .. dumps(paintResult.paintName1) .. ", " .. dumps(paintResult.paintName2) .. ", " .. dumps(paintResult.paintName3) .. ", probability: " .. dumps(paintResult.probability))
    end
  end

  -- now do the same for each config
  for _, config in pairs(configs) do
    debugConfigKey = config.key

    local defaultRandomPaintProbability = config.defaultRandomPaintProbability or model.defaultRandomPaintProbability or 1
    local defaultRandomMultiPaintProbability = config.defaultRandomMultiPaintProbability or model.defaultRandomMultiPaintProbability or 1


    -- first, remap every paint in randomPaintDistribution to use the paint names
    local newRandomPaintDistributionConfig = {}
    for paintNameOrId, probability in pairs(config.randomPaintDistribution or {}) do
      local paint = model.paints[paintNameOrId]
      if not paint then
        paint = paintsByIdCache[paintNameOrId]
      end
      if paint then
        newRandomPaintDistributionConfig[paint.name] = probability
      end
    end
    -- add the probabilities from the model
    if not config.ignoreModelRandomPaintDistribution then
      for paintName, probability in pairs(newRandomPaintDistributionModel) do
        newRandomPaintDistributionConfig[paintName] = newRandomPaintDistributionConfig[paintName] or newRandomPaintDistributionModel[paintName] or probability
      end
    end
    -- also add all the paints from the config
    for paintName, paint in pairs(config.paints) do
      newRandomPaintDistributionConfig[paintName] = newRandomPaintDistributionConfig[paintName] or paint.randomProbability or defaultRandomPaintProbability
    end
    -- then add all the remaining paint names with 1 probability
    if not config.onlyUseConfigPaintsForRandomPaintDistribution then
      for paintName, paint in pairs(model.paints) do
        newRandomPaintDistributionConfig[paintName] = newRandomPaintDistributionConfig[paintName] or paint.randomProbability or defaultRandomPaintProbability
      end
    end


     -- then do the same for randomMultiPaintDistribution
    local newRandomMultiPaintDistributionConfig = {}
    for multiPaintSetupNameOrId, probability in pairs(config.randomMultiPaintDistribution or {}) do
      local multiPaintSetup = multiPaintSetupsByName[multiPaintSetupNameOrId]
      if not multiPaintSetup then
        multiPaintSetup = multiPaintSetupsByIdCache[multiPaintSetupNameOrId]
        multiPaintSetup = multiPaintSetupsByName[multiPaintSetup.name]
      end
      if multiPaintSetup then
        newRandomMultiPaintDistributionConfig[multiPaintSetup.name] = probability
        multiPaintSetupsByName[multiPaintSetup.name] = multiPaintSetup
      end
    end
    -- add the probabilities from the model
    if not config.ignoreModelRandomMultiPaintDistribution then
      for multiPaintSetupName, probability in pairs(newRandomMultiPaintDistributionConfig) do
        newRandomMultiPaintDistributionConfig[multiPaintSetupName] = newRandomMultiPaintDistributionModel[multiPaintSetupName] or probability
      end
    end

    -- then add all the remaining multiPaintSetups with 1 probability
    if not config.onlyUseConfigMultiPaintSetupsForRandomPaintDistribution then
      for _, multiPaintSetup in ipairs(model.multiPaintSetups) do
        if multiPaintSetup.usedByConfigByKey[config.key] or (multiPaintSetup.forAllConfigs and not config.onlyUseConfigMultiPaintSetupsForRandomPaintDistribution) then
          newRandomMultiPaintDistributionConfig[multiPaintSetup.name] = newRandomMultiPaintDistributionConfig[multiPaintSetup.name] or multiPaintSetup.randomProbability or defaultRandomMultiPaintProbability
        end
      end
    end

    -- finally, add all results into one list and add the sum of all probabilities
    local totalProbability = 0
    local allPaintResults = {}
    for paintName, probability in pairs(newRandomPaintDistributionConfig) do
      totalProbability = totalProbability + probability
      if probability > 0 then
        table.insert(allPaintResults, {
          type = 'paint',
          paintName1 = paintName,
          paintName2 = paintName,
          paintName3 = paintName,
          probability = probability,
        })
      end
    end
    for multiPaintSetupName, probability in pairs(newRandomMultiPaintDistributionConfig) do
      totalProbability = totalProbability + probability
      local multiPaintSetup = multiPaintSetupsByName[multiPaintSetupName]
      if probability > 0 then
        table.insert(allPaintResults, {
          type = 'multiPaintSetup',
          paintName1 = multiPaintSetup.paintName1,
          paintName2 = multiPaintSetup.paintName2,
          paintName3 = multiPaintSetup.paintName3,
          probability = probability,
        })
      end
    end
    config.randomPaintHelper = {
      allPaintResults = allPaintResults,
      totalProbability = totalProbability,
    }

    if debugLog ~= nop  and config.key == 'van_delivery' then
      debugLog("config " .. dumps(config.key) .. " has " .. #allPaintResults .. " paint results with total probability " .. totalProbability)
      for _, paintResult in pairs(allPaintResults) do
        debugLog("paint result: " .. dumps(paintResult.type) .. ", " .. dumps(paintResult.paintName1) .. ", " .. dumps(paintResult.paintName2) .. ", " .. dumps(paintResult.paintName3) .. ", probability: " .. dumps(paintResult.probability))
      end
    end
  end
end

local function buildModelPaintsBySignature(modelName)
  local modelWrapper = core_vehicles.getModel(modelName)
  local model = modelWrapper and modelWrapper.model or nil
  if not model or model.Author ~= OFFICIAL_AUTHOR then
    return nil, {}
  end
  local modelPaintsBySignature = {}
  if model and model.paints then
    for paintName, paint in pairs(model.paints) do
      if paint._official == true then
        local signature = M.paintSignature(paint)
        modelPaintsBySignature[signature] = paint.name or paintName
      end
    end
  end
  return model, modelPaintsBySignature
end

local function buildLibraryPaintsBySignature()
  if not paintsByIdCache then buildPaintCaches() end
  local paintsBySignature = {}
  for paintId, paint in pairs(paintsByIdCache or {}) do
    if paintId ~= "_missing_paint_" and type(paint) == "table" and paint._official == true then
      local signature = M.paintSignature(paint)
      paintsBySignature[signature] = paintsBySignature[signature] or {}
      table.insert(paintsBySignature[signature], {
        id = paintId,
        name = paint.name,
      })
    end
  end
  return paintsBySignature
end

local function findModelMultiPaintSetupBySignatures(model, paintSignatures)
  if not model or not model.multiPaintSetups or not model.paints then return nil end
  for _, multiPaintSetup in pairs(model.multiPaintSetups) do
    if not multiPaintSetup.generated and multiPaintSetup._official == true then
      local matchCount = 0
      for i = 1, 3 do
        local paintName = multiPaintSetup["paintName" .. i]
        local modelPaint = model.paints[paintName]
        if modelPaint and modelPaint._official == true and paintSignatures[i] and M.paintSignature(modelPaint) == paintSignatures[i] then
          matchCount = matchCount + 1
        end
      end
      if matchCount == 3 then
        local setupId = multiPaintSetup.id or multiPaintSetup.name
        return {
          id = setupId,
          name = multiPaintSetup.name or setupId,
        }
      end
    end
  end
  return nil
end

local function findLibraryMultiPaintSetupBySignatures(paintSignatures)
  if not multiPaintSetupsByIdCache then buildPaintCaches() end
  if not paintsByIdCache then buildPaintCaches() end
  for setupId, multiPaintSetup in pairs(multiPaintSetupsByIdCache or {}) do
    if multiPaintSetup._official ~= true then
      goto continue_setup
    end
    local matchCount = 0
    for i = 1, 3 do
      local paintId = multiPaintSetup["paint" .. i]
      local libraryPaint = type(paintId) == "string" and paintsByIdCache[paintId] or nil
      if libraryPaint and libraryPaint._official == true and paintSignatures[i] and M.paintSignature(libraryPaint) == paintSignatures[i] then
        matchCount = matchCount + 1
      end
    end
    if matchCount == 3 then
      return {
        id = setupId,
        name = multiPaintSetup.name or setupId,
      }
    end
    ::continue_setup::
  end
  return nil
end

local function resolvePcPaintReferences(pcData, modelName)
  local resolution = {
    paints = {},
    paintSignatures = {},
    multiPaintSetup = {
      found = false,
      source = nil,
      name = nil,
      id = nil,
      resolvedReference = nil,
    },
    defaultStorageMode = "individualPaints",
    canOverridePaints = false,
  }

  local paints = pcData and pcData.paints or nil
  if type(paints) ~= "table" then
    return resolution
  end

  local model, modelPaintsBySignature = buildModelPaintsBySignature(modelName)
  local libraryPaintsBySignature = buildLibraryPaintsBySignature()

  for i = 1, 3 do
    local paint = paints[i]
    if type(paint) == "table" then
      local signature = M.paintSignature(paint)
      resolution.paintSignatures[i] = signature
      local modelPaintName = modelPaintsBySignature[signature]
      local libraryCandidates = libraryPaintsBySignature[signature] or {}
      local source = "custom"
      local resolvedReference = nil
      if modelPaintName then
        source = "model"
        resolvedReference = modelPaintName
      elseif #libraryCandidates > 0 then
        source = "library"
        resolvedReference = libraryCandidates[1].id or libraryCandidates[1].name
      end
      resolution.paints[i] = {
        index = i,
        source = source,
        modelPaintName = modelPaintName,
        libraryPaintId = libraryCandidates[1] and libraryCandidates[1].id or nil,
        libraryPaintName = libraryCandidates[1] and libraryCandidates[1].name or nil,
        resolvedReference = resolvedReference,
      }
    else
      resolution.paintSignatures[i] = nil
      resolution.paints[i] = {
        index = i,
        source = "custom",
        modelPaintName = nil,
        libraryPaintId = nil,
        libraryPaintName = nil,
        resolvedReference = nil,
      }
    end
  end

  local libraryMultiPaintSetup = findLibraryMultiPaintSetupBySignatures(resolution.paintSignatures)
  if libraryMultiPaintSetup then
    resolution.multiPaintSetup = {
      found = true,
      source = "library",
      name = libraryMultiPaintSetup.name,
      id = libraryMultiPaintSetup.id,
      resolvedReference = libraryMultiPaintSetup.id or libraryMultiPaintSetup.name,
    }
    resolution.defaultStorageMode = "multiPaintSetup"
  else
    local modelMultiPaintSetup = findModelMultiPaintSetupBySignatures(model, resolution.paintSignatures)
    if modelMultiPaintSetup then
      resolution.multiPaintSetup = {
        found = true,
        source = "model",
        name = modelMultiPaintSetup.name,
        id = modelMultiPaintSetup.id,
        resolvedReference = modelMultiPaintSetup.id or modelMultiPaintSetup.name,
      }
      resolution.defaultStorageMode = "multiPaintSetup"
    end
  end

  local hasReusablePaint = false
  for _, paintResolution in ipairs(resolution.paints) do
    if paintResolution.source ~= "custom" then
      hasReusablePaint = true
      break
    end
  end
  resolution.canOverridePaints = hasReusablePaint or resolution.multiPaintSetup.found

  return resolution
end

local function writePcPaintsAsInfoPaints(pcData, infoData, configName)
  infoData.defaultMultiPaintSetup = {
    name = configName .. " Multi Paint Setup",
  }
  for i, paint in ipairs(pcData.paints or {}) do
    local explicitPaint = deepcopy(paint)
    stripPaintOfficialFlag(explicitPaint)
    explicitPaint.class = "hidden"
    explicitPaint.name = configName .. " Paint " .. i
    infoData.defaultMultiPaintSetup["paint" .. i] = explicitPaint
  end
  stripMultiPaintSetupOfficialFlag(infoData.defaultMultiPaintSetup)
end

local function convertPcPaintsToInfoPaints(pcData, infoData, configName, modelName)
  local resolution = resolvePcPaintReferences(pcData, modelName)
  infoData.defaultMultiPaintSetup = {
    name = configName .. " Multi Paint Setup",
  }

  for i, paint in ipairs(pcData.paints or {}) do
    local paintResolution = resolution.paints[i]
    if paintResolution and paintResolution.resolvedReference then
      infoData.defaultMultiPaintSetup["paint" .. i] = paintResolution.resolvedReference
    else
      local explicitPaint = deepcopy(paint)
      stripPaintOfficialFlag(explicitPaint)
      explicitPaint.class = "hidden"
      explicitPaint.name = configName .. " Paint " .. i
      infoData.defaultMultiPaintSetup["paint" .. i] = explicitPaint
    end
  end

  if resolution.multiPaintSetup.found then
    infoData.defaultMultiPaintSetup = resolution.multiPaintSetup.resolvedReference
  else
    stripMultiPaintSetupOfficialFlag(infoData.defaultMultiPaintSetup)
  end
end

local function getModelDefaultPaintValidationData(modelName)
  local result = {
    modelDefaultColors = {},
    modelDefaultMultiPaintSetup = {
      found = false,
      name = nil,
      id = nil,
    },
  }

  local modelWrapper = core_vehicles.getModel(modelName)
  local model = modelWrapper and modelWrapper.model or nil
  if type(model) ~= "table" then
    return result
  end

  local defaultMultiPaintSetup = model.defaultMultiPaintSetup
  if type(defaultMultiPaintSetup) == "table" then
    if type(defaultMultiPaintSetup.name) == "string" and defaultMultiPaintSetup.name ~= "" then
      result.modelDefaultMultiPaintSetup.found = true
      result.modelDefaultMultiPaintSetup.name = defaultMultiPaintSetup.name
      result.modelDefaultMultiPaintSetup.id = defaultMultiPaintSetup.id
    end
  elseif type(defaultMultiPaintSetup) == "string" and defaultMultiPaintSetup ~= "" then
    result.modelDefaultMultiPaintSetup.found = true
    result.modelDefaultMultiPaintSetup.name = defaultMultiPaintSetup
    result.modelDefaultMultiPaintSetup.id = defaultMultiPaintSetup
  end

  for i = 1, 3 do
    local paintName = model["defaultPaintName" .. i]
    if type(paintName) == "string" and paintName ~= "" then
      table.insert(result.modelDefaultColors, paintName)
    elseif i > 1 and result.modelDefaultColors[1] then
      table.insert(result.modelDefaultColors, result.modelDefaultColors[1])
    end
  end

  if #result.modelDefaultColors == 0 and type(model.defaultPaint) == "table" then
    local defaultPaintName = model.defaultPaint.name
    if type(defaultPaintName) == "string" and defaultPaintName ~= "" then
      table.insert(result.modelDefaultColors, defaultPaintName)
    end
  end

  return result
end

local function validatePcPaints(pcData, modelName)
  local resolution = resolvePcPaintReferences(pcData, modelName)
  local modelDefaults = getModelDefaultPaintValidationData(modelName)
  return {
    paints = resolution.paints,
    multiPaintSetup = {
      found = resolution.multiPaintSetup.found,
      source = resolution.multiPaintSetup.source,
      name = resolution.multiPaintSetup.name,
      id = resolution.multiPaintSetup.id,
    },
    defaultStorageMode = resolution.defaultStorageMode,
    canOverridePaints = resolution.canOverridePaints,
    modelDefaultColors = modelDefaults.modelDefaultColors,
    modelDefaultMultiPaintSetup = modelDefaults.modelDefaultMultiPaintSetup,
  }
end

M.convertPcPaintsToInfoPaints = convertPcPaintsToInfoPaints
M.writePcPaintsAsInfoPaints = writePcPaintsAsInfoPaints
M.validatePcPaints = validatePcPaints




-- gets random paint data, given a model key and a config key
local function getRandomPaints(model_key, config_key)
  local modelData = core_vehicles.getModel(model_key)
  local model = modelData.model
  if not model.randomPaintHelper then
    setupRandomPaintHelper(model_key)
  end
  local paintHelper

  local config = modelData.configs[config_key]
  if config then
    paintHelper = config.randomPaintHelper
  end
  paintHelper = paintHelper or model.randomPaintHelper

  local randomNum = math.random() * paintHelper.totalProbability
  local sum = 0
  for _, paintResult in ipairs(paintHelper.allPaintResults) do
    sum = sum + paintResult.probability
    if randomNum < sum then
      return paintResult
    end
  end
end
M.getRandomPaints = getRandomPaints

-- gets random paints to use for an existing vehicle
local function getRandomPaintsByVehicle(vehId)
  local obj = getObjectByID(vehId or 0)
  local model = obj and obj.jbeam
  local config = obj and tostring(obj.partConfig)
  config  = string.match(config, "vehicles/".. model .."/(.*).pc")
  if not obj or not config then
    log('W', 'getRandomPaint', 'Vehicle not found, now using default paint data')
    return {'White', 'White', 'White'}
  end
  local paints = getRandomPaints(model, config)
  if not paints then
    log('W', 'getRandomPaintsByVehicle', 'Failed to get random paints for vehicle ' .. vehId .. ', now using default paint data')
    return {'White', 'White', 'White'}
  end
  --log("I","",string.format("Selected for model %s, config %s: %s %s %s", model, config, paints.paintName1, paints.paintName2, paints.paintName3))
  return {paints.paintName1, paints.paintName2, paints.paintName3} -- returns as an array so that the function setVehicleColorsNames can use it
end
M.getRandomPaintsByVehicle = getRandomPaintsByVehicle

-- creates and returns a randomly generated multiPaintSetup
local function createRandomMultiPaintSetup(model_key, config_key, avoidDuplicates)
  local multiPaintSetup = {}

  local modelData = core_vehicles.getModel(model_key)
  local model = modelData.model
  if not model.randomPaintHelper then
    setupRandomPaintHelper(model_key)
  end
  local tempPaintHelper

  local config = modelData.configs[config_key]
  if config then
    tempPaintHelper = config.randomPaintHelper
  end
  tempPaintHelper = tempPaintHelper or model.randomPaintHelper
  local paintHelper = deepcopy(tempPaintHelper)
  for _, paintResult in ipairs(paintHelper.allPaintResults) do -- strip out all multiPaintSetups
    if paintResult.type ~= 'paint' then
      paintHelper.totalProbability = paintHelper.totalProbability - paintResult.probability
      paintResult.probability = 0
    end
  end

  for i = 1, 3 do
    local randomNum = math.random() * paintHelper.totalProbability
    local sum = 0
    for j, paintResult in ipairs(paintHelper.allPaintResults) do
      sum = sum + paintResult.probability
      if randomNum < sum and paintResult.probability > 0 then
        table.insert(multiPaintSetup, paintResult.paintName1)
        if avoidDuplicates then
          paintHelper.totalProbability = paintHelper.totalProbability - paintResult.probability
          paintResult.probability = 0
        end
        break
      end
    end
  end

  while not multiPaintSetup[3] do -- just in case
    table.insert(multiPaintSetup, multiPaintSetup[1] or 'White')
  end

  multiPaintSetup.paintName1, multiPaintSetup.paintName2, multiPaintSetup.paintName3 = multiPaintSetup[1], multiPaintSetup[2], multiPaintSetup[3]
  multiPaintSetup[1], multiPaintSetup[2], multiPaintSetup[3] = nil, nil, nil

  return multiPaintSetup
end
M.createRandomMultiPaintSetup = createRandomMultiPaintSetup

-- tests paint distribution
local function testRandomPaint(model_key, config_key, amount)
  local resultsByName = {}
  for i = 1, amount do
    local paintResult = getRandomPaints(model_key, config_key)
    local name = string.format("%s: %s %s %s", paintResult.type, paintResult.paintName1, paintResult.paintName2, paintResult.paintName3)
    resultsByName[name] = (resultsByName[name] or 0) + 1
  end

  log("I", "vehicles", "Random Paint Test Results")
  log("I", "vehicles", "Total samples: " .. amount)
  log("I", "vehicles", "Amount | Percent | Paint Configuration")
  log("I", "vehicles", "----------------------------------------")

  local sortedResults = {}
  for name, count in pairs(resultsByName) do
    table.insert(sortedResults, {name = name, count = count})
  end
  table.sort(sortedResults, function(a,b) return a.count > b.count end)

  for _, result in ipairs(sortedResults) do
    local percentage = (result.count / amount) * 100
    log("I", "vehicles", string.format("%5d | %6.1f%% | %s", result.count, percentage, result.name))
  end
end
M.testRandomPaint = testRandomPaint

return M