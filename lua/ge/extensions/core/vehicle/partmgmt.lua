-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local json = require("json")
local jbeamIO = require('jbeam/io')

local vehManager = extensions.core_vehicle_manager
local vehsPartsData = {}

local attachedCouplers = {}

local function getVehData(vehID)
  local vehObj = vehID and be:getObjectByID(vehID) or getPlayerVehicle(0)
  if not vehObj then return end
  vehID = vehObj:getID()

  local vehData = vehManager.getVehicleData(vehID)
  if not vehData then return end

  if not vehsPartsData[vehID] then
    vehsPartsData[vehID] = {vehName = vehObj:getJBeamFilename(), alpha = 1, partsHighlighted = nil}
  end

  return vehObj, vehData, vehID, vehsPartsData[vehID]
end

local function getDefaultConfigFileFromDir(vehicleDir, configData)
  local vehicleInfo = jsonReadFile(vehicleDir .. '/info.json')
  if not vehicleInfo then return end
  if not vehicleInfo.default_pc then return end
  log('W', 'main', "Supplied config file: " .. tostring(configData) .. " not found. Using default config instead.")
  return vehicleDir .. vehicleInfo.default_pc .. ".pc"
end

local function buildConfigFromString(vehicleDir, configData)
  local dataType = type(configData)
  if dataType == 'table' then
    return configData
  end

  if dataType == 'string' and configData:sub(1, 1) == '{' then
    return deserialize(configData)
  end

  local fileData
  if configData ~= nil and configData ~= "" then
    fileData = jsonReadFile(configData)
    if not fileData then
      log("W", "", "Unable to read json contents for configData file path: "..dumps(configData))
    end
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

  return res
end

local function findAttachedVehicles(vehId)
  local visited = {}
  local connected = {}

  local function search(vehicle)
      visited[vehicle] = true
      for _, cdata in ipairs(attachedCouplers) do
          if cdata[1] == vehicle and not visited[cdata[2]] then
              table.insert(connected, cdata[2])
              search(cdata[2])
          elseif cdata[2] == vehicle and not visited[cdata[1]] then
              table.insert(connected, cdata[1])
              search(cdata[1])
          end
      end
  end
  search(vehId)
  return connected
end

local function findNodeByCid(vehicleData, nodeCid)
  for nodeId, node in pairs(vehicleData.vdata.nodes) do
    if node.cid == nodeCid then
      return node
    end
  end
end

local function saveVehicle(collection, vehId, idMap)
  local vehicle = be:getObjectByID(vehId)
  local vehicleData = vehManager.getVehicleData(vehId)
  if not vehicle or not vehicleData then
    log('E', 'partmgmt', 'vehicle ' .. tostring(vehId) .. ' not found')
    return
  end

  local data = vehicleData.config
  data.partConfigFilename = nil
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

  local coupledNodes = {}
  for _, coupler in ipairs(attachedCouplers) do
    -- objId1, objId2, nodeId, obj2nodeId
    if coupler[1] == vehId and coupler[2] then
      local nodeName = findNodeByCid(vehicleData, coupler[3]).name
      if nodeName then
        coupledNodes[nodeName] = idMap[coupler[2]]
      end
    elseif coupler[2] == vehId and coupler[1] then
      local nodeName = findNodeByCid(vehicleData, coupler[4]).name
      if nodeName then
        coupledNodes[nodeName] = idMap[coupler[1]]
      end
    end
  end
  dump{'coupledNodes = ', vehId, coupledNodes}
  data.coupledNodes = coupledNodes
  data.format = nil -- remove obsolete key
  table.insert(collection, data)
end

local function savePartConfigFileStage2_Format3(partsCondition, filename)
  local playerVehicle = getPlayerVehicle(0)
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  local playerVehicleId = be:getPlayerVehicleID(0)

  local vehiclesToSave = findAttachedVehicles(playerVehicleId)
  local idMap = {}
  idMap[playerVehicleId] = 1
  local counter = 2
  for _, vid in pairs(vehiclesToSave) do
    idMap[vid] = counter
    counter = counter + 1
  end

  local vehicles = {}
  saveVehicle(vehicles, playerVehicleId, idMap)
  for _, vehId in pairs(vehiclesToSave) do
    saveVehicle(vehicles, vehId, idMap)
  end

  local res = {}
  res.format = 3
  res.vehicles = vehicles

  local writeRes = jsonWriteFile(filename, res, true)
  if writeRes then
    guihooks.trigger("VehicleconfigSaved", {})
  else
    log('W', "vehicles.save", "unable to save config: "..filename)
  end
  guihooks.trigger('Message', {ttl = 15, msg = 'Configuration saved', icon = 'directions_car'})
end


local function savePartConfigFileStage2_Format2(partsCondition, filename)
  local playerVehicle = getPlayerVehicle(0)
  local playerVehicleData = vehManager.getPlayerVehicleData()
  if not playerVehicle or not playerVehicleData then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end

  local data = playerVehicleData.config
  local prevPCFilename = data.partConfigFilename
  data.partConfigFilename = nil
  data.format = 2
  data.model = playerVehicleData.model or playerVehicleData.vehicleDirectory:gsub("vehicles/", ""):gsub("/", "")
  data.partsCondition = partsCondition
  if not data.paints or data.colors then
    data.paints = {}
    local colorTable = playerVehicle:getColorFTable()
    local colorTableSize = tableSize(colorTable)
    for i = 1, colorTableSize do
      local metallicPaintData = stringToTable(playerVehicle:getField('metallicPaintData', i - 1))
      local paint = createVehiclePaint({x = colorTable[i].r, y = colorTable[i].g, z = colorTable[i].b, w = colorTable[i].a}, metallicPaintData)
      validateVehiclePaint(paint)
      table.insert(data.paints, paint)
    end

    if #data.paints > 0 then
      data.colors = nil
    end
  end
  data.licenseName = extensions.core_vehicles.makeVehicleLicenseText()

  local res = jsonWriteFile(filename, data, true)
  if res then
    data.partConfigFilename = filename
    guihooks.trigger("VehicleconfigSaved", {})
  else
    data.partConfigFilename = prevPCFilename
    log('W', "vehicles.save", "unable to save config: "..filename)
  end
  guihooks.trigger('Message', {ttl = 15, msg = 'Configuration saved', icon = 'directions_car'})
end

local function savePartConfigFile(filename)
  local savePartsCondition = false
  if savePartsCondition then
    local playerVehicle = getPlayerVehicle(0)
    if playerVehicle then
      queueCallbackInVehicle(playerVehicle, "extensions.core_vehicle_partmgmt.savePartConfigFileStage2", "partCondition.getConditions("..serialize(filename)..")")
    end
  else
    -- uncomment for format 3 saving
    --savePartConfigFileStage2_Format3(nil, filename)
    savePartConfigFileStage2_Format2(nil, filename)
  end
end

local function saveLocal(fn)
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  savePartConfigFile(playerVehicle.vehicleDirectory .. fn)
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
  local playerVehicle = vehManager.getPlayerVehicleData()
  local screenshotName = (playerVehicle.vehicleDirectory .. fn)
  screenshot.doScreenshot(nil, nil, screenshotName, 'jpg')
  -- Stage 3 on JS side
  guihooks.trigger('saveLocalScreenshot_stage3', {})
end


local function savedefault()
  guihooks.trigger('Message', {ttl = 5, msg = 'New default vehicle has been set', icon = 'directions_car'})
  savePartConfigFile('settings/default.pc')
end

local function sendDataToUI()
  local vehObj, vehData, vehID, partsData
  local playerVehicle = getPlayerVehicle(0)
  if playerVehicle then
    vehObj, vehData, vehID, partsData = getVehData(playerVehicle:getID())
  end
  if not vehObj then
    log('E', 'partmgmt', 'no active vehicle')
    return
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

  local data = {
    mainPartName     = vehData.mainPartName,
    chosenParts      = vehData.chosenParts,
    variables        = vehData.vdata.variables,
    availableParts   = jbeamIO.getAvailableParts(vehData.ioCtx),
    slotMap          = jbeamIO.getAvailableSlotMap(vehData.ioCtx),
    partsHighlighted = partsData.partsHighlighted,
    defaults         = configDefaults,
  }

  -- enrich the data a bit for the UI
  for partName, part in pairs(data.availableParts) do
    if part.modName then
      local mod = core_modmanager.getModDB(part.modName)
      if mod and mod.modData then
        part.modTagLine    = mod.modData.tag_line
        part.modTitle      = mod.modData.title
        part.modLastUpdate = mod.modData.last_update
      end
    end
  end

  guihooks.trigger("VehicleConfigChange", data)
end

local function hasAvailablePart(partName)
  if not partName or partName == "" then return end
  local playerVehicleData = core_vehicle_manager.getPlayerVehicleData()
  local parts = jbeamIO.getAvailableParts(playerVehicleData.ioCtx)

  if parts[partName] then
    return true
  end

  return false
end

local function setSkin(skin)
  local vehicle = getPlayerVehicle(0)
  local playerVehicleData = core_vehicle_manager.getPlayerVehicleData()

  if not vehicle or not playerVehicleData then return end

  local partName = nil

  if skin and skin ~= "" then
    partName = vehicle.JBeam .. "_skin_" .. skin
    local parts = jbeamIO.getAvailableParts(playerVehicleData.ioCtx)
    if not parts[partName] then return end
  end

  local carConfigToLoad = playerVehicleData.config
  carConfigToLoad.parts["paint_design"] = partName
  local carModelToLoad = vehicle.JBeam
  local vehicleData = {}
  vehicleData.config = carConfigToLoad
  core_vehicles.replaceVehicle(carModelToLoad, vehicleData)
end

local function reset()
  sendDataToUI()
end

local function mergeConfig(inData, respawn)
  --dump{"mergeConfig> ", inData, respawn}
  local veh = getPlayerVehicle(0)
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not veh or not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end

  if respawn == nil then respawn = true end -- respawn is required all the time except when loading the vehicle

  if not inData or type(inData) ~= 'table' then
    log('W', "partmgmt.mergeConfig", "invalid argument [" .. type(inData) .. '] = '..dumps(inData))
    return
  end

  tableMerge(playerVehicle.config, inData)

  if respawn then
    --dump{"RESPAWN: ", playerVehicle.config}
    veh:respawn(serialize(playerVehicle.config))
  else
    local paintCount = tableSize(inData.paints)
    for i = 1, paintCount do
      vehManager.liveUpdateVehicleColors(veh:getId(), veh, i, inData.paints[i])
    end
    veh:setField('partConfig', '', serialize(playerVehicle.config))
  end
end

local function setConfigPaints (data, respawn)
  mergeConfig({paints = data}, respawn)
end

local function setConfigVars (data, respawn)
  mergeConfig({vars = data}, respawn)
end

local function setPartsConfig (data, respawn)
  mergeConfig({parts = data}, respawn)
end

local function getConfig()
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  return playerVehicle.config
end

local function loadLocal(filename, respawn)
  local veh = getPlayerVehicle(0)
  if not veh then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  core_vehicles.replaceVehicle(veh.JBeam, {config = filename})
end

local function removeLocal(filename)
  local playerVehicle = vehManager.getPlayerVehicleData()
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
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  isOfficial = isOfficialContentVPath(playerVehicle.vehicleDirectory .. filename)
  return isOfficial
end

local function isPlayerConfig(filename)
  local isPlayerConfig
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  isPlayerConfig = isPlayerVehConfig(playerVehicle.vehicleDirectory .. filename)
  return isPlayerConfig
end


local function getConfigList()
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end

  local files = FS:findFiles(playerVehicle.vehicleDirectory, "*.pc", -1, true, false) or {}
  local result = {}

  for _, file in pairs(files) do
    local basename = string.sub(file, string.len(playerVehicle.vehicleDirectory) + 1, -1)
    table.insert(result,
    {
      fileName = basename,
      name = string.sub(basename,0, -4),
      official = isOfficialConfig(basename),
      player = isPlayerConfig(basename)
    })
  end
  return result
end

local function openConfigFolderInExplorer()
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end

  if not fileExistsOrNil(playerVehicle.vehicleDirectory) then  -- create dir if it doesnt exist
    FS:directoryCreate(playerVehicle.vehicleDirectory, true)
  end
   Engine.Platform.exploreFolder(playerVehicle.vehicleDirectory)
end

-- Actually sets transparency of meshes related to parts
local function setPartsMeshesAlpha(vehObj, vdata, partNames, alpha, notSelectedAlpha)
  -- If parts is nil, then set whole vehicle mesh transparency
  -- Otherwise set individual meshes transparencies
  if not partNames then
    vehObj:setMeshAlpha(alpha, "", false)
  else
    vehObj:setMeshAlpha(notSelectedAlpha or 0, "", false)

    if vdata.flexbodies then
      for _, flexbody in pairs(vdata.flexbodies) do
        if flexbody.mesh and flexbody.mesh ~= 'SPOTLIGHT' and flexbody.mesh ~= 'POINTLIGHT' and flexbody.meshLoaded then
          if flexbody.partOrigin == nil then
            vehObj:setMeshAlpha(alpha, flexbody.mesh, false) -- if mesh not related to part, just set mesh to alpha value
          else
            if partNames[flexbody.partOrigin] then
              if not vehObj:setMeshAlpha(alpha, flexbody.mesh, false) then
                log('W', 'mesh', 'unable to set mesh alpha: ' ..  dumps{'mesh: ', flexbody.mesh, 'alpha: ', alpha, 'existing alpha: ', vehObj:getMeshAlpha(flexbody.mesh)})
              end
            else
              --log('W', '', 'part not highlighted: ' .. tostring(flexbody.partOrigin))
            end
          end
        end
      end
    end
    if vdata.props then
      for _, prop in pairs(vdata.props) do
        if prop.partOrigin == nil and prop.mesh then
          vehObj:setMeshAlpha(alpha, prop.mesh, false) -- if mesh not related to part, just set mesh to alpha value
        else
          if partNames[prop.partOrigin] and prop.mesh then
            vehObj:setMeshAlpha(alpha, prop.mesh, false)
          end
        end
      end
    end
  end
end

-- Sets transparency of highlighted parts
local function setHighlightedPartsVisiblity(alpha, _vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  partsData.alpha = alpha

  setPartsMeshesAlpha(vehObj, vehData.vdata, partsData.partsHighlighted, alpha)
end

-- Changes transparency of highlighted parts by delta value
local function changeHighlightedPartsVisiblity(deltaAlpha, _vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  partsData.alpha = clamp(partsData.alpha + deltaAlpha, 0, 1)

  setPartsMeshesAlpha(vehObj, vehData.vdata, partsData.partsHighlighted, partsData.alpha)
end

-- Just shows parts highlighted
local function showHighlightedParts(_vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  setPartsMeshesAlpha(vehObj, vehData.vdata, partsData.partsHighlighted, partsData.alpha)
end

-- Highlighting refers to clicking on the "eye" icon
local function highlightParts(parts, _vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  if not partsData.partsHighlighted then
    partsData.partsHighlighted = {}
  end

  local chosenParts = vehData.chosenParts
  for slot, part in pairs(chosenParts) do
    if slot ~= 'main' and part ~= '' then
      partsData.partsHighlighted[part] = parts[part] or false
    end
  end

  setPartsMeshesAlpha(vehObj, vehData.vdata, parts, partsData.alpha)
end

-- selecting refers to hovering over a part in the UI (only temporary)
local function selectParts(partNamesToHighlight, _vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  setPartsMeshesAlpha(vehObj, vehData.vdata, partNamesToHighlight, partsData.alpha, 0.2)
end

local function setSubPartsHighlight(part, highlight, partsHighlighted, vehData)
  partsHighlighted[part] = highlight

  local data = vehData.vdata.activeParts[part]
  if data then
    local slots = data.slots or data.slots2
    if slots then
      for _, slot in ipairs(slots) do
        local slotIdentifier = slot.type or slot.name
        if slotIdentifier then
          local childPart = vehData.chosenParts[slotIdentifier]
          if childPart and childPart ~= "" then
            setSubPartsHighlight(childPart, highlight, partsHighlighted, vehData)
          end
        end
      end
    end
  end
end

-- Merge old part highlights with new vehicle parts
-- When new part added, its visiblity is set to the parent part visiblity,
-- as well as its children to prevent weirdness
local function setNewParts(_vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  local newHighlightedParts = {}
  local oldPartsHighlighted = partsData.partsHighlighted

  if oldPartsHighlighted then
    -- Get part to parent part for getting highlight of parent part
    local partToParentPart = {}

    for parentPart, parentData in pairs(vehData.vdata.activeParts) do
      local slots = parentData.slots or parentData.slots2
      if slots then
        for _, childSlot in ipairs(slots) do
          local slotIdentifier = childSlot.type or childSlot.name
          if slotIdentifier then
            local childPart = vehData.chosenParts[slotIdentifier]
            if childPart and childPart ~= "" then
              partToParentPart[childPart] = parentPart
            end
          end
        end
      end
    end

    local partsSettingChildParts = {}

    for slot, chosenPartname in pairs(vehData.chosenParts) do
      if slot ~= "main" and chosenPartname and chosenPartname ~= "" then
        if oldPartsHighlighted[chosenPartname] ~= nil then
          newHighlightedParts[chosenPartname] = oldPartsHighlighted[chosenPartname]
        else
          -- If adding new part, highlight of part and its child parts
          -- is equal to parent part
          local highlight = nil

          local parentPart = partToParentPart[chosenPartname]
          if parentPart then
            highlight = oldPartsHighlighted[parentPart]
            if highlight == nil then
              highlight = true
            end
          end

          -- Set all child parts highlights later
          newHighlightedParts[chosenPartname] = highlight
          table.insert(partsSettingChildParts, chosenPartname)
        end
      end
    end

    -- Set childparts of parts highlight the same as parent part
    for _, part in ipairs(partsSettingChildParts) do
      local highlight = newHighlightedParts[part]
      setSubPartsHighlight(part, highlight, newHighlightedParts, vehData)
    end
  else
    for slot, part in pairs(vehData.chosenParts) do
      if slot ~= "main" and part and part ~= "" then
        newHighlightedParts[part] = true
      end
    end
  end

  vehsPartsData[vehID].partsHighlighted = newHighlightedParts
end

local function onSerialize()
  return {
    vehsPartsData = vehsPartsData,
    attachedCouplers = attachedCouplers,
  }
end

local function onDeserialized(data)
  vehsPartsData = data.vehsPartsData
  attachedCouplers = data.attachedCouplers
end

-- Sets parts highlights to false
local function clearVehicleHighlights(_vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  partsData.partsHighlighted = nil
end

-- Clears out all highlights data (parts highlighted, mesh transparency, and vehicle)
local function resetVehicleHighlights(onlyIfVehChanged, _vehID)
  local vehObj, vehData, vehID, partsData = getVehData(_vehID)
  if not vehObj then return end

  local clear = true

  if onlyIfVehChanged then
    local name = be:getObjectByID(vehID):getJBeamFilename()
    local oldName = partsData.vehName

    if name == oldName then
      clear = false
    end
  end

  if clear then
    vehsPartsData[vehID] = nil
  end
end

local function resetConfig()
  mergeConfig({parts = {}, vars = {}}, true)
end

local function resetAllToLoadedConfig()
  local playerVehicle = vehManager.getPlayerVehicleData()
  if not playerVehicle then
    log('E', 'partmgmt', 'no active vehicle')
    return
  end
  loadLocal(playerVehicle.config.partConfigFilename)
end

-- Used by Vehicle Config -> Parts "Reset" button to reset parts back to loaded config
local function resetPartsToLoadedConfig()
  local playerVehicle = vehManager.getPlayerVehicleData()
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
  local playerVehicle = vehManager.getPlayerVehicleData()
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

local function onCouplerAttached( objId1, objId2, nodeId, obj2nodeId)
  table.insert(attachedCouplers, {objId1, objId2, nodeId, obj2nodeId})
end

local function onCouplerDetached(obj1id, obj2id, nodeId, obj2nodeId)
  for i, coupler in ipairs(attachedCouplers) do
    if coupler[1] == obj1id and coupler[2] == obj2id and coupler[3] == nodeId and coupler[4] == obj2nodeId then
      table.remove(attachedCouplers, i)
      break
    end
  end
end

-- public interface
M.save = savePartConfigFile
M.savePartConfigFileStage2 = savePartConfigFileStage2_Format3

M.setHighlightedPartsVisiblity = setHighlightedPartsVisiblity
M.changeHighlightedPartsVisiblity = changeHighlightedPartsVisiblity
M.highlightParts = highlightParts
M.selectParts = selectParts
M.setNewParts = setNewParts
M.showHighlightedParts = showHighlightedParts
M.clearVehicleHighlights = clearVehicleHighlights
M.resetVehicleHighlights = resetVehicleHighlights
M.setConfig = mergeConfig
M.setConfigPaints = setConfigPaints
M.setConfigVars = setConfigVars
M.setPartsConfig = setPartsConfig
M.getConfig = getConfig
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.resetConfig = resetConfig
M.reset = reset
M.sendDataToUI = sendDataToUI
M.vehicleResetted = reset
M.getConfigSource = getConfigSource
M.getConfigList = getConfigList
M.openConfigFolderInExplorer = openConfigFolderInExplorer
M.loadLocal = loadLocal
M.removeLocal = removeLocal
M.resetAllToLoadedConfig = resetAllToLoadedConfig
M.resetPartsToLoadedConfig = resetPartsToLoadedConfig
M.resetVarsToLoadedConfig = resetVarsToLoadedConfig
M.saveLocal = saveLocal
M.saveLocalScreenshot = saveLocalScreenshot
M.saveLocalScreenshot_stage2 = saveLocalScreenshot_stage2
M.savedefault = savedefault
M.hasAvailablePart = hasAvailablePart
M.setSkin = setSkin
M.findAttachedVehicles = findAttachedVehicles

M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached

M.buildConfigFromString = buildConfigFromString
return M
