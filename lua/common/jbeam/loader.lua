--[[
This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
If a copy of the bCDDL was not distributed with this
file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
This module contains a set of functions which manipulate behaviours of vehicles.
]]

local particles = require("particles")

local jbeamIO = require('jbeam/io')
local jbeamTableSchema = require('jbeam/tableSchema')
local jbeamLinks = require('jbeam/links')
local jbeamOptimization = require('jbeam/optimization')
local sectionMerger = require('jbeam/sectionMerger')
local jbeamSlotSystem = require('jbeam/slotSystem')
local jbeamGroups = require('jbeam/groups')
local jbeamScaling = require('jbeam/scaling')
local jbeamInteraction = require('jbeam/interaction')
local jbeamVariables = require('jbeam/variables')
local jbeamCamera = require('jbeam/sections/camera')
local jbeamWheels = require('jbeam/sections/wheels')
local jbeamNodeBeam = require('jbeam/sections/nodeBeam')
local jbeamLicensePlatesSkins = require('jbeam/sections/licenseplatesSkins')
local jbeamAssorted = require('jbeam/sections/assorted')
local jbeamMeshs = require('jbeam/sections/meshs')
local jbeamVisualRopes = require('jbeam/sections/vropes')
local jbeamEvents = require('jbeam/sections/events')
local jbeamColors = require('jbeam/sections/colors')
local jbeamPaints = require('jbeam/sections/paints')
local jbeamMirrors = require('jbeam/sections/mirror')
local jbeamPartColors =  require_optional('jbeam/sections/partColors') or { process=nop }
local jbeamCondition = require_optional('jbeam/sections/condition') or { process=nop }
local jbeamMaterials = require('jbeam/materials')
local jbeamUtils = require('jbeam/utils')

local M = {}

-- these are defined in C, do not change the values
local NORMALTYPE = 0
local BEAM_ANISOTROPIC = 1
local BEAM_BOUNDED = 2
local BEAM_PRESSURED = 3
local BEAM_LBEAM = 4
local BEAM_BROKEN = 5
local BEAM_HYDRO = 6
local BEAM_SUPPORT = 7

local debugVehicleLoading = false
if Engine.getStartingArgs then
  debugVehicleLoading = tableFindKey(Engine.getStartingArgs(), '-debugVehicleLoading') ~= nil
end

-- this is intentionally here for the doc sync system
M.defaultBeamSpring = 4300000
M.defaultBeamDeform = 220000
M.defaultBeamDamp   = 580
M.defaultNodeWeight = 25
M.defaultBeamStrength = math.huge

M.data = {}
M.materials, M.materialsMap = particles.getMaterialsParticlesTable()

-- this will inject frame renders during loading
-- if you want to just profile the loading time, you can disable it
local refreshScreenWhileLoading = true

local cache = {}

-- helper function to preprocess vehicle configuration
local function prepareVehicleConfig(ioCtx, vehicleDirectories, vehicleConfig)
  -- figure out the model name based on the directory given
  local modelName = vehicleDirectories[1]:match('/vehicles/([^/]+)')

  if vehicleConfig == nil then vehicleConfig = {} end

  vehicleConfig.model = modelName

  if not vehicleConfig.paints and vehicleConfig.colors then
    vehicleConfig.paints = convertVehicleColorsToPaints(vehicleConfig.colors)
    vehicleConfig.colors = nil
  end
  if not vehicleConfig.mainPartName then
    vehicleConfig.mainPartName = jbeamIO.getMainPartName(ioCtx)
  end
  if vehicleConfig.mainPartName then
    vehicleConfig.mainPartPath = '/' .. vehicleConfig.mainPartName
  end

  --log('D', 'loadVehicle', 'spawn config: ' .. dumps(vehicleConfig))
  return modelName, vehicleConfig
end

-- same as loadJbeam, but only returns the vehicle config and skips irrelevant parts of the loading process
local function loadJbeamOnlyConfig(vehicleDirectories, vehicleConfig)
  local ioCtx = jbeamIO.startLoading(vehicleDirectories)
  local modelName, vehicleConfig = prepareVehicleConfig(ioCtx, vehicleDirectories, vehicleConfig)
  local vehicle, unifyJournal, unifyJournalC, chosenPartsTree, slotPartMap, activePartsData, activeParts = jbeamSlotSystem.findParts(ioCtx, vehicleConfig)
  if not vehicle then return end
  vehicleConfig.parts = nil -- obsolete info, replaced with partsTree
  vehicleConfig.partsTree = chosenPartsTree
  jbeamIO.finishLoading() -- clears some caches
  return vehicleConfig
end

-- load all the jbeam and construct the thing in memory
local function loadJbeam(objID, loadingProgress, vehicleDirectories, vehicleConfig)
  profilerPushEvent('jbeam/loader')
  if loadingProgress then loadingProgress:update(0.1, _tr("ui.jbeam.loader.readingFiles")) end
  local ioCtx = jbeamIO.startLoading(vehicleDirectories)
  local modelName, vehicleConfig = prepareVehicleConfig(ioCtx, vehicleDirectories, vehicleConfig)

  local debugEnabled = nil
  local additionalVehicleData = vehicleConfig.additionalVehicleData
  if additionalVehicleData then
    debugEnabled = additionalVehicleData.debugEnabled
  end

  if loadingProgress then loadingProgress:update(0.2, _tr("ui.jbeam.loader.findingParts")) end
  local vehicle, unifyJournal, unifyJournalC, chosenPartsTree, slotPartMap, activePartsData, activeParts = jbeamSlotSystem.findParts(ioCtx, vehicleConfig)
  if not vehicle then return end

  vehicle.partOrigin = vehicle.partName
  vehicle.partPath = '/' .. vehicle.partName

  -- this converts all the variable tables into objects.
  local vars = jbeamVariables.getAllVariables(vehicle, unifyJournal, vehicleConfig)

  -- we process all components before processing variables so the variables can use them
  jbeamVariables.processComponents(vehicle, unifyJournalC, vehicleConfig, vars)

  if loadingProgress then loadingProgress:update(0.21, _tr("ui.jbeam.loader.applyingVariables")) end
  local allVariables = jbeamVariables.processParts(vehicle, unifyJournal, vehicleConfig, vars)

  if loadingProgress then loadingProgress:update(0.22, _tr("ui.jbeam.loader.unifyingParts")) end
  if not jbeamSlotSystem.unifyPartJournal(ioCtx, unifyJournal) then return end

  jbeamVariables.postProcessVariables(vehicle, allVariables)

  -- cleanup everything that should not be send over to the other side that is not serializeable
  jbeamVariables.cleanup(vehicle)

  if debugVehicleLoading then
    local fn = vehicleDirectories[1] .. '/vehicleDebug_preTable.json'
    require('jbeamWriter').writeFile(fn, vehicle)
    log('I', 'vehicleloader.debug', 'wrote file: ' .. fn)
  end
  --dump({'chosenPartsTree = ', chosenPartsTree})

  vehicleConfig.parts = nil -- obsolete info, replaced with partsTree
  vehicleConfig.partsTree = chosenPartsTree

  --jsonWriteFile('chosenPartsTree.json', chosenPartsTree, true)
  --jsonWriteFile('vehicle.json', vehicle, true)
  --jsonWriteFile('activePartsData.json', activePartsData, true)

  if loadingProgress then loadingProgress:update(0.3, _tr("ui.jbeam.loader.assemblingTables")) end
  if not jbeamTableSchema.process(vehicle) then
    log('W', "jbeam.compile", "*** preparation error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  -- 0) merge sections together properly. This is primarily for usability of the jbeam
  local sectionRenames = {}
  if not sectionMerger.process(vehicle, sectionRenames) then
    log('W', "jbeam.compile", "*** sectionMerger error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  if loadingProgress then loadingProgress:update(0.4, _tr("ui.jbeam.loader.linkingThings")) end
  -- a) this creates a list of things to be linked AND deletes unlinkable things
  local linksToResolve = jbeamLinks.prepareLinksDestructive(vehicle, sectionRenames)
  if linksToResolve == nil then
    log('W', "jbeam.compile", "*** link preparation error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  -- b) this assigns upcounting continouus IDs for the physics.
  --    Items cannot be added or deleted afterwards
  if not jbeamOptimization.assignCIDs(vehicle) then
    log('W', "jbeam.compile", "*** numbering error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  -- c) This resolves the links with the cids assigned now
  if not jbeamLinks.resolveLinks(vehicle, linksToResolve) then
    log('W', "jbeam.compile", "*** link resolving error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  if loadingProgress then loadingProgress:update(0.5, _tr("ui.jbeam.loader.inspectingVariables")) end
  jbeamNodeBeam.process(vehicle)
  if vmType == 'game' then
    jbeamCamera.process(objID, vehicle)
  end

  extensions.hook('onJbeamLoadingPhase1', loadingProgress, objID, vehicle, unifyJournal, vehicleConfig, vars)

  if loadingProgress then loadingProgress:update(0.6, _tr("ui.jbeam.loader.addingWheels")) end
  jbeamWheels.processWheels(vehicle)

  if not jbeamLinks.resolveGroupLinks(vehicle) then
    log('W', "jbeam.postProcess","*** group link resolving error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  if loadingProgress then loadingProgress:update(0.7, 'Doing some things.') end
  jbeamAssorted.process(vehicle) -- after resolveGroupLinks
  jbeamWheels.processRotators(vehicle)
  jbeamGroups.process(vehicle) -- after processWheels, processRotators
  jbeamScaling.process(vehicle) -- after jbeamGroups

  -- add default options
  if vehicle.options.beamSpring   == nil then vehicle.options.beamSpring   = M.defaultBeamSpring end
  if vehicle.options.beamDeform   == nil then vehicle.options.beamDeform   = M.defaultBeamDeform end
  if vehicle.options.beamDamp     == nil then vehicle.options.beamDamp     = M.defaultBeamDamp end
  if vehicle.options.beamStrength == nil then vehicle.options.beamStrength = M.defaultBeamStrength end
  if vehicle.options.nodeWeight   == nil then vehicle.options.nodeWeight   = M.defaultNodeWeight end

  vehicle.vehicleDirectory = vehicleDirectories[1]
  vehicle.directoriesLoaded = vehicleDirectories
  vehicle.activePartsData = activePartsData
  vehicle.activeParts = activeParts
  vehicle.slotPartMap = slotPartMap
  vehicle.model = modelName

  extensions.hook('onJbeamLoadingPhase2', loadingProgress, objID, vehicle, unifyJournal, vehicleConfig, vars)

  if loadingProgress then loadingProgress:update(0.9, _tr("ui.jbeam.loader.optimizingResult")) end
  if not jbeamOptimization.process(vehicle, debugEnabled) then
    log('W', "jbeam.compile", "*** optimization error")
    profilerPopEvent('jbeam/loader')
    return nil
  end

  jbeamIO.finishLoading() -- clears some caches

  -- for the UI, after all the jbeam loading is done
  jbeamInteraction.process(vehicle)

  -- TODO: REMOVE TEST CODE
  if additionalVehicleData then
    if additionalVehicleData.indestructible then
      local beamToTorbar = {}
      if vehicle.torsionbars then
        for i = 0, #vehicle.torsionbars do
          local torbar = vehicle.torsionbars[i]
          local a, b = math.min(torbar.id1, torbar.id2), math.max(torbar.id1, torbar.id2)
          beamToTorbar[a..':'..b] = i
          a, b = math.min(torbar.id2, torbar.id3), math.max(torbar.id2, torbar.id3)
          beamToTorbar[a..':'..b] = i
          a, b = math.min(torbar.id3, torbar.id4), math.max(torbar.id3, torbar.id4)
          beamToTorbar[a..':'..b] = i
        end
      end

      local beamToRail = {}
      if vehicle.rails then
        for k, v in pairs(vehicle.rails) do
          local links = v['links:']

          for i = 1, #links - 1 do
            local id1, id2 = links[i], links[i + 1]
            local a, b = math.min(id1, id2), math.max(id1, id2)
            beamToRail[a..':'..b] = k
          end
        end
      end

      -- Make all beams indestructible, disable break groups
      if vehicle.beams then
        for i = 0, #vehicle.beams do
          local beam = vehicle.beams[i]
          local a, b = math.min(beam.id1, beam.id2), math.max(beam.id1, beam.id2)
          -- check if the beam is not part of a wheel, a torsionbar, or a rail
          if not beam.wheelID
          and not beamToTorbar[a..':'..b]
          and not beamToRail[a..':'..b]
          then
            beam.beamStrength = math.huge
          end
          --beam.breakGroup = nil

          -- Make beams with such beam types "beamLongBound" infinite to prevent them from breaking
          if beam.beamType == BEAM_ANISOTROPIC or beam.beamType == BEAM_SUPPORT then
            beam.beamLongBound = math.huge
          end
        end
      end

      -- Disable trigger boxes
      vehicle.triggers = nil

      -- Disable all actions
      vehicle.actionsEnabled = {}

      -- Disable advanced couplers
      -- for section, sectionData in pairs(vehicle) do
      --   if section == 'controller' then
      --     for i = #sectionData, 0, -1 do
      --       local controllerData = sectionData[i]
      --       if controllerData.fileName == 'advancedCouplerControl' then
      --         table.remove(sectionData, i)
      --       end
      --     end
      --   end
      -- end
    end
  end

  profilerPopEvent('jbeam/loader')
  return {
    id               = objID,
    vehicleDirectory = vehicle.vehicleDirectory,
    directoriesLoaded = vehicle.directoriesLoaded,
    vdata            = vehicle,
    config           = vehicleConfig,
    mainPartName     = vehicleConfig.mainPartName,
    ioCtx            = ioCtx,
  }
end

local function loadBundle(objID, vehicleBundle, loadingProgress)
  profilerPushEvent('loadBundle')
  if not vehicleBundle then return end

  local vehicleObj
  if vmType == 'game' then
    vehicleObj = scenetree.findObject(objID)
    if not vehicleObj then
      log('E', 'loader', 'unable to find object with it: ' .. tostring(objID))
    else
      vehicleObj = vehicleObj.obj
    end
  end
  -- everything that needs the object to be working or 3D meshes goes from here:
  if vehicleObj then

    if loadingProgress then loadingProgress:update(0.8, 'Loading input events...') end
    jbeamEvents.process(objID, vehicleObj, vehicleBundle.vdata)

    if loadingProgress then loadingProgress:update(0.8, _tr("ui.jbeam.loader.addingMeshes")) end
    jbeamLicensePlatesSkins.process(objID, vehicleObj, vehicleBundle.config, vehicleBundle.vdata.activePartsData)
    jbeamColors.process(vehicleObj, vehicleBundle.config, vehicleBundle.vdata)
    jbeamPaints.process(vehicleObj, vehicleBundle.config, vehicleBundle.vdata)
    jbeamPartColors.process(vehicleObj, vehicleBundle.config, vehicleBundle.vdata)
    jbeamCondition.process(vehicleObj, vehicleBundle.config, vehicleBundle.vdata, vehicleBundle)

    -- set initial node positions
    if vehicleBundle.vdata.maxIDs.nodes then
      vehicleObj:setInitialNodePositionCount(vehicleBundle.vdata.maxIDs.nodes)
      local nodes = vehicleBundle.vdata.nodes
      for i = 0, tableSizeC(vehicleBundle.vdata.nodes) - 1 do
        local n = nodes[i]
        vehicleObj:setInitialNodePosition(n.pos.x, n.pos.y, n.pos.z)
        local staticCollision = n.staticCollision
        if staticCollision == nil then staticCollision = true end
        local collision = n.collision
        if collision == nil then collision = true end
        vehicleObj:setInitialNodeCollision(collision, staticCollision)
      end
      vehicleObj:initialNodePositionsDone()
    end
    local refNodes = vehicleBundle.vdata.refNodes[0]
    vehicleObj:setRefNodes(refNodes.ref or 0, refNodes.back or 0, refNodes.left or 0, refNodes.up or 0)

    jbeamMeshs.process(objID, vehicleObj, vehicleBundle.vdata)
    jbeamVisualRopes.process(objID, vehicleObj, vehicleBundle.vdata)
    jbeamMaterials.process(vehicleObj, vehicleBundle.vdata)
    jbeamMirrors.process(objID, vehicleObj, vehicleBundle.vdata)

    --some configs hardcode their colors in the info json rather than referencing a color name from the main json
    --only look for that if we don't have any other color information already, otherwise things go wrong
    if not vehicleBundle.config.paints then
      vehicleBundle.config.paints = deserialize(vehicleObj.paints or '{}')
    end

    if vehicleBundle.vdata.animation then
      vehicleObj:queueLuaCommand('extensions.load("test_animationViz")')
    end

    -- parts can request ge extensions to load themselves via a `gameEngineExtensions` section, so a
    -- feature part (e.g. the lawn mower) works just by being installed - no manual extensions.load.
    -- entry is `name = true` to just load, or `name = {..args..}` to also pass args + this vehicle id
    -- to the extension's optional onVehicleExtensionLoaded(vehId, args) callback.
    if vehicleBundle.vdata.gameEngineExtensions then
      for k, val in pairs(vehicleBundle.vdata.gameEngineExtensions) do
        local extName = type(val) == 'string' and val or (type(k) == 'string' and k or nil)
        if extName then
          local ext = extensions.use(extName) -- loads on demand, returns the module
          if type(val) == 'table' and ext and ext.onVehicleExtensionLoaded then
            ext.onVehicleExtensionLoaded(objID, val)
          end
        end
      end
    end

  else
    vehicleBundle.vdata.props = {}
    vehicleBundle.vdata.flexbodies = {}
  end
  profilerPopEvent('loadBundle')
end

-- be aware this code runs on vehicle and ge lua
local function loadVehicleStage1(objID, vehicleDir, vehicleConfig)
  profilerPushEvent('loadVehicleStage1')
  local loadingProgress

  if refreshScreenWhileLoading and vmType == 'game' then
    loadingProgress = LoadingManager:push('beamng')
  end

  -- the directory needs a leading and trailing slash
  if vehicleDir:sub(1, 1) ~= '/' then
    vehicleDir = '/' .. vehicleDir
  end
  if vehicleDir:sub(-1, -1) ~= '/' then
    vehicleDir = vehicleDir .. '/'
  end

  local vehicleDirectories = {vehicleDir, '/vehicles/common/'}
  local spawnHash = nil
  if hashStringSHA256 then
    spawnHash = hashStringSHA256(dumps(vehicleDirectories) .. '#' .. jsonEncode(vehicleConfig))
  end
  --print(">>> spawnHash = " .. tostring(spawnHash))

  local vehicleBundle = cache[spawnHash]

  if not vehicleBundle then
    vehicleBundle = loadJbeam(objID, loadingProgress, vehicleDirectories, vehicleConfig)
    if spawnHash then cache[spawnHash] = jbeamUtils.stringBufferEncode(vehicleBundle) end
  else
    profilerPushEvent('jbeam/loader.cached')
    vehicleBundle = jbeamUtils.stringBufferDecode(vehicleBundle)
    vehicleBundle.id = objID
    profilerPopEvent('jbeam/loader.cached')
  end

  --log('D', 'loader', 'jbeam LOADING TOOK: ' .. tostring(t:stopAndReset()) .. ' ms')

  --- for debug purposes:
  if vehicleBundle and debugVehicleLoading then
    local fn = vehicleDirectories[1] .. '/vehicleDebug_data.json'
    log('I', 'vehicleloader.debug', 'wrote file: ' .. fn)
    jsonWriteFile(fn, vehicleBundle.vdata, true)

    fn = vehicleDirectories[1] .. '/vehicleDebug_activeParts.json'
    log('I', 'vehicleloader.debug', 'wrote file: ' .. fn)
    jsonWriteFile(fn, vehicleBundle.vdata.activePartsData, true)

    fn = vehicleDirectories[1] .. '/vehicleDebug_config.json'
    log('I', 'vehicleloader.debug', 'wrote file: ' .. fn)
    jsonWriteFile(fn, vehicleBundle.config, true)

    fn = vehicleDirectories[1] .. '/vehicleDebug_Tree.json'
    log('I', 'vehicleloader.debug', 'wrote file: ' .. fn)
    jsonWriteFile(fn, vehicleBundle.config.partsTree, true)
  end


  --jsonWriteFile('vehicleBundle.json', vehicleBundle, true)

  loadBundle(objID, vehicleBundle, loadingProgress)

  --log('D', 'loader', '3D LOADING TOOK: ' .. tostring(t:stopAndReset()) .. ' ms')

  profilerPopEvent('loadVehicleStage1')

  if loadingProgress then
    loadingProgress:update(1, _tr("ui.jbeam.loader.vehicleLoadingDone"))
    LoadingManager:pop(loadingProgress)
  end

  return vehicleBundle
end

local function onFileChanged(filename, type)
  cache = {}
end

-- public interface
M._noSerialize = true
M.loadVehicleStage1 = loadVehicleStage1
M.loadBundle = loadBundle
M.loadJbeam = loadJbeam
M.loadJbeamOnlyConfig = loadJbeamOnlyConfig
M.onFileChanged = onFileChanged

return M
