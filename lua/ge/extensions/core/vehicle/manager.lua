-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local jbeamIO = require('jbeam/io')
local jbeamLoader = require("jbeam/loader")
local im

local vehicles = {}

local materialsCache = {}
local debugEnabled = false

M.autoSpawnPhysics = true

local toolWindowName = 'Vehicle Manager'

local function getDebug()
  return debugEnabled
end

local function setDebug(enabled)
  debugEnabled = enabled
  guihooks.trigger('debugSpawnChanged', debugEnabled)
end

local function toggleDebug()
  setDebug(not debugEnabled)
end

local profileVehicleLoading = tableFindKey(Engine.getStartingArgs(), '-profileVehicleLoading')
local debugVehicleLoading = tableFindKey(Engine.getStartingArgs(), '-debugVehicleLoading')
if debugVehicleLoading then
  debugEnabled = true
end

local function loadVehicleMaterialsDirectory(path)
  if materialsCache[path] then return end
  local files = FS:findFiles(path, '*materials.json\t*.cs', -1, true, false)
  for _, filename in ipairs(files) do
    if filename:find('.json') then
      loadJsonMaterialsFile(filename)
    else
      TorqueScriptLua.exec(filename)
    end
  end
  materialsCache[path] = true
end

local function onClientEndMission()
  -- invalidate all materials
  materialsCache = {}
end

local function onFileChanged(filename, type)
  jbeamIO.onFileChanged(filename, type)
  jbeamLoader.onFileChanged(filename, type)
  local path = string.match(filename, "^(/vehicles/[^/]*/)[^%.]*%.materials%.json$")
  if path then
    log('D', 'vehicleLoader', 'Materials changed in vehicle path, invalidating cache: ' .. tostring(path))
    materialsCache[path] = nil
  end
end

local additionalVehicleData
local additionalDataId
local function queueAdditionalVehicleData(data, vehId)
  additionalVehicleData = data
  additionalDataId = vehId
end

local function spawnPhysicsForVehicle(objID, vehicleObj, vehicleBundle)
  if not objID then
    objID = be:getPlayerVehicleID(0)
  end
  local _vehicleBundle = vehicleBundle or vehicles[objID]
  if not vehicleObj or not _vehicleBundle then
    vehicleObj = scenetree.findObject(objID)
    if not vehicleObj then return end
  end

  if not _vehicleBundle or not _vehicleBundle.vdata then
    -- send an empty vehicle bundle to the physics engine to avoid stale data
    _vehicleBundle = {vdata = {}, config = {}}
  end

  profilerPushEvent('serialize')
  -- do not send everything, filter some UI things that are not required
  local vehicleBundleDataString = lpack.encode({
    vdata  = _vehicleBundle.vdata,
    config = _vehicleBundle.config,
  })
  profilerPopEvent('serialize')

  local luaVMType = 0 -- 0 = vehicle, 1 = object pool, 2 = none

  profilerPushEvent('spawnPhysics')
  vehicleObj:spawnPhysics(vehicleBundleDataString or '', luaVMType)
  profilerPopEvent('spawnPhysics')
end

local function spawnCCallback(objID, vehicleDir, configDataIn, reloading)
  if profileVehicleLoading and simpleProfilerStart then
    simpleProfilerStart(false)
  end
  profilerPushEvent('spawn')
  local vehicleObj = scenetree.findObject(objID)
  if not vehicleObj then
    log('E', 'loader', 'Spawning vehicle failed, missing vehicle obj: '..dumps(objID, vehicleDir, configDataIn))
    additionalVehicleData = nil
    return
  end


  profilerPushEvent('spawn/materials')
  loadVehicleMaterialsDirectory(vehicleDir)
  loadVehicleMaterialsDirectory('/vehicles/common/')
  profilerPopEvent('spawn/materials')

  -- makes the object available for every call, etc
  be:addObject(vehicleObj, false)

  local timer = hptimer()
  log('D', 'vehicleLoader', 'partConfigData [' .. type(configDataIn) .. '] = ' .. dumps(configDataIn))
  local vehicleConfig = extensions.core_vehicle_partmgmt.buildConfigFromString(vehicleDir, configDataIn)

  extensions.hook("onSpawnCCallback", objID)

  if additionalVehicleData and not additionalDataId or additionalDataId == objID then
    vehicleConfig.additionalVehicleData = additionalVehicleData
    additionalVehicleData = nil
  end

  if debugEnabled then
    vehicleConfig.additionalVehicleData = vehicleConfig.additionalVehicleData or {}
    vehicleConfig.additionalVehicleData.debugEnabled = debugEnabled
  end

  local luaVMType = 0 -- 0 = vehicle, 1 = object pool, 2 = none

  local vehicleBundle

  local status, err = xpcall(function () vehicleBundle = jbeamLoader.loadVehicleStage1(objID, vehicleDir, vehicleConfig) end, debug.traceback)
  vehicles[objID] = vehicleBundle

  if not vehicleBundle then
    log('E', 'loader', 'Spawning vehicle failed, missing stage 1 data: '..dumps(objID, vehicleDir, configDataIn))
    if err then log('E', 'loader', err) end
  end
  log('D', 'loader', "GE load time: " .. tostring(timer:stopAndReset() / 1000) .. ' s')

  --jsonWriteFile('jbeam_loading_NEW_stage1.json', vehicleBundle, true)
  local spawnPhysics = M.autoSpawnPhysics
  if vehicleObj.NoPhysics == 'true' then
    log('I', '', 'NOT spawning the physics ...')
    spawnPhysics = false
  end

  -- this will finish the 3d meshes and alike
  profilerPushEvent('finishConstructionGESide')
  vehicleObj:finishConstructionGESide()
  profilerPopEvent('finishConstructionGESide')

  vehicleSpawned(objID) -- callback to main function

  -- this enables the UI to react on the changed vehicle
  if vehicleBundle and vehicleBundle.vdata then
    guihooks.trigger('VehicleChange', vehicleBundle.vdata.vehicleDirectory, spawnPhysics)
  end

  if vehicleObj.autoEnterVehicle ~= "false" then -- and not reloading
    -- TODO: FIXME: do not call enterVehicle if the player is already in the vehicle or we reload: "and not reloading"
    local player = vehicleObj.autoEnterVehiclePlayer ~= "" and tonumber(vehicleObj.autoEnterVehiclePlayer) or 0
    be:enterVehicle(player, vehicleObj) -- will trigger onVehicleSwitched
  end
  vehicleObj:setDynDataFieldbyName("autoEnterVehicle", 0, "")
  vehicleObj:setDynDataFieldbyName("autoEnterVehiclePlayer", 0, "")

  if spawnPhysics then
    spawnPhysicsForVehicle(objID, vehicleObj, vehicleBundle)
  end

  -- remove the additionalVehicleData, because it's only supposed to be temporary
  if vehicleBundle and vehicleBundle.config then
    vehicleBundle.config.additionalVehicleData = nil
  end

  profilerPopEvent('spawn')

  if profileVehicleLoading and simpleProfilerStop then
    simpleProfilerStop()
    local vehName = vehicleObj and vehicleObj.jbeam or (vehicleBundle and vehicleBundle.vdata and vehicleBundle.vdata.vehicleDirectory) or 'Unknown'
    -- capture cache usage stats
    local jbeamStats = jbeamIO and jbeamIO.getLastStartLoadingStats and jbeamIO.getLastStartLoadingStats() or nil
    local jbeamCached = jbeamStats and jbeamStats.cachedHits > 0
    -- mesh cache summary via new API (may be nil if not available)
    local meshCacheSummary = nil
    if vehicleObj and vehicleObj.getMeshCacheRebuildSummary then
      local ok, summary = pcall(function() return vehicleObj:getMeshCacheRebuildSummary() end)
      if ok and type(summary) == 'table' then meshCacheSummary = summary end
    end
    extensions.utils_simpleProfiler_report.createReport('vehicle_loading', 'Vehicle Spawn', {
      vehicleName = vehName,
      jbeamCached = jbeamCached,
      meshCacheSummary = meshCacheSummary,
    })
    simpleProfilerDestroy()
  end
end

local function onVehicleSwitched(oldID, newID, player)
  if vehicles[oldID] then
    vehicles[oldID].activePlayer = nil
    local vehicle = scenetree.findObjectById(oldID)
    if not vehicle then return end

    vehicle:queueLuaCommand('input.event("clutch", 0, 0)')
  end
  if vehicles[newID] then
    vehicles[newID].activePlayer = player
  end
end

local function onDespawnObject(id, isReloading)
  if isReloading == false then
    vehicles[id] = nil
  end
end

local function getPlayerVehicleData()
  return vehicles[be:getPlayerVehicleID(0)]
end

local function getVehicleData(id)
  return vehicles[id]
end

local function liveUpdateVehicleColors(objID, _vehicleObj, index, paint)
  local vehicleObj = _vehicleObj or scenetree.findObjectById(objID)
  if not vehicleObj or not vehicles[objID] or not vehicles[objID].config or not vehicles[objID].config.paints then return end

  if paint and type(paint) == 'table' then
    local paintsData = {}
    validateVehiclePaint(paint)
    if     index == 1 then
      vehicleObj.color         = ColorF(paint.baseColor[1], paint.baseColor[2], paint.baseColor[3], paint.baseColor[4]):asLinear4F()
      paintsData[1] = paint
    elseif index == 2 then
      vehicleObj.colorPalette0 = ColorF(paint.baseColor[1], paint.baseColor[2], paint.baseColor[3], paint.baseColor[4]):asLinear4F()
      paintsData[2] = paint
    elseif index == 3 then
      vehicleObj.colorPalette1 = ColorF(paint.baseColor[1], paint.baseColor[2], paint.baseColor[3], paint.baseColor[4]):asLinear4F()
      paintsData[3] = paint
    end

    vehicleObj:setMetallicPaintData(paintsData)
    extensions.hook("onVehicleColorChanged", objID, index, paint)
  end
end

local function setVehicleColorsNames(id, paintNames, optional)
  id = id or be:getPlayerVehicleID(0)
  local vehicle = scenetree.findObjectById(id)
  if not vehicle or not paintNames then return end

  local data = core_vehicles.getModel(vehicle.jbeam)
  if not data.model.paints then return end
  if optional ~= nil and vehicle.color == vehicle.colorPalette0 == vehicle.colorPalette1 then return end

  for i = 1, 3 do
    if paintNames[i] and data.model.paints[paintNames[i]] then
      liveUpdateVehicleColors(id, nil, i, data.model.paints[paintNames[i]])
    end
  end
end

-- to support Lua reloads, we serialize the data
local function onDeserialized(data)
  vehicles = {}
  for k, v in pairs(data.vehicles) do
    vehicles[k] = lpack.decode(v)
  end
  M.autoSpawnPhysics = data.autoSpawnPhysics
end

local function onSerialize()
  local data = {
    vehicles = {},
    autoSpawnPhysics = M.autoSpawnPhysics
  }
  for k, v in pairs(vehicles) do
    data.vehicles[k] = lpack.encode(v)
  end
  return data
end

local function toggleModifyKey()
  extensions.core_vehicle_inplaceEdit.toggleShowWindow()
end

local function reloadVehicle(playerId)
  if be then
    core_vehicles.reloadVehicle(playerId)
    be:reloadVehicle(playerId)
  end
end

local function reloadAllVehicles()
  if be then
    be:reloadAllVehicles()
    core_vehicles.reloadVehicle(0)
  end
end

local function onEditorGui()
  if editor.beginWindow(toolWindowName, "Vehicle Manager") then
    im.Spacing()
    im.Spacing()
    im.Separator()
    im.Spacing()

    im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.2, 0.2, 1))
    im.TextWrapped("/!\\ THIS TOOL IS OBSOLETE /!\\")
    im.PopStyleColor()

    im.Spacing()
    im.Separator()
    im.Spacing()

    im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.8, 0, 1))
    im.TextWrapped("Please use the following command line argument instead:")
    im.PopStyleColor()

    im.Spacing()

    im.PushStyleColor2(im.Col_Text, im.ImVec4(0.3, 1, 0.3, 1))
    im.TextWrapped("-debugVehicleLoading")
    im.PopStyleColor()

    im.Spacing()
    im.Separator()
    im.Spacing()
  end
  editor.endWindow()
end

local function onWindowMenuItem()
  editor.showWindow(toolWindowName)
end

local function onEditorInitialized()
  im = ui_imgui
  editor.registerWindow(toolWindowName, im.ImVec2(420, 500))
  editor.addWindowMenuItem(toolWindowName, onWindowMenuItem, {groupMenuName = 'Vehicles'})
end

local function onUpdate()
  spawn.clearCache()
end

-- callbacks
M.onVehicleSwitched  = onVehicleSwitched
M.onDespawnObject    = onDespawnObject
M.onSerialize        = onSerialize
M.onDeserialized     = onDeserialized
M.onClientEndMission = onClientEndMission
M.onFileChanged      = onFileChanged
M.onUpdate = onUpdate


-- Editor
M.onEditorInitialized = onEditorInitialized
M.onEditorGui = onEditorGui

-- API
M.getPlayerVehicleData = getPlayerVehicleData
M.spawnPhysicsForVehicle = spawnPhysicsForVehicle
M.setVehicleColorsNames = setVehicleColorsNames
M.setVehiclePaintsNames = setVehicleColorsNames
M.liveUpdateVehicleColors = liveUpdateVehicleColors
M.getVehicleData = getVehicleData

M.toggleModifyKey = toggleModifyKey

M.queueAdditionalVehicleData = queueAdditionalVehicleData
M._spawnCCallback = spawnCCallback

M.reloadVehicle = reloadVehicle
M.reloadAllVehicles = reloadAllVehicles

M.getDebug = getDebug
M.setDebug = setDebug
M.toggleDebug = toggleDebug

return M
