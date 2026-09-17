-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "freeformDelivery_setup"

local spawnedVehicles = {}
local vehicleIdMap = {} -- Maps delivery vehicle IDs to actual vehicle IDs
local initialVehicleTransforms = {} -- Stores initial vehicle positions/rotations for reset
local setupInProgress = false
local pendingCouplings = {} -- Track vehicles with pending couplings

local function findVehicleByInternalName(delivery, internalName)
  -- Vehicles are already spawned by loader, find them by internalName
  local vehicleIndex = delivery._vehicleIndex
  if not vehicleIndex then
    log('E', logTag, 'No vehicle index available')
    return nil
  end

  local vehId = vehicleIndex[internalName]
  if not vehId then
    log('E', logTag, 'Vehicle not found with internalName: ' .. tostring(internalName))
    return nil
  end

  local veh = getObjectByID(vehId)
  if not veh then
    log('E', logTag, 'Vehicle object not found for ID: ' .. tostring(vehId))
    return nil
  end

  return veh, vehId
end

local function applyStartupCode(veh, startupCode)
  if not startupCode then return end

  local commands = {}

  -- Drive mode
  if startupCode.driveMode then
    table.insert(commands, string.format('controller.getControllerSafe("mainController").setGearboxMode("%s")', startupCode.driveMode))
  end

  -- Gear
  if startupCode.gear then
    table.insert(commands, string.format('powertrain.getDevice("transmission").setGear(%d)', startupCode.gear))
  end

  -- Engine status
  if startupCode.engineOn ~= nil then
    if startupCode.engineOn then
      table.insert(commands, 'powertrain.getDevice("engine").startEngine()')
    else
      table.insert(commands, 'powertrain.getDevice("engine").stopEngine()')
    end
  end

  if #commands > 0 then
    local cmd = table.concat(commands, '\n')
    veh:queueLuaCommand(cmd)
  end
end

local function applyVehicleStartupState(veh, vehicleDef)
  if not veh or not vehicleDef then return end

  if vehicleDef.startupCode then
    applyStartupCode(veh, vehicleDef.startupCode)
  end

  if vehicleDef.setIgnitionLevel ~= nil then
    core_vehicleBridge.executeAction(veh, 'setIgnitionLevel', vehicleDef.setIgnitionLevel)
    log('D', logTag, 'Set ignition level for vehicle ' .. tostring(vehicleDef.id) .. ' to ' .. tostring(vehicleDef.setIgnitionLevel))
  end
end

local function createCouplingSetup(couplings, vehId)
  local couplingSetup = {}
  for _, coupling in ipairs(couplings) do
    local targetVehId = vehicleIdMap[coupling.targetVehicleId]
    if targetVehId then
      table.insert(couplingSetup, {
        vehId = vehId,
        nodeTag = coupling.nodeTag,
        targetVehId = targetVehId
      })
    end
  end
  return couplingSetup
end

local allCouplingSetup = {} -- Collect all couplings to set up in one sequence

local function setupCouplingSequence(couplingSetupArray)
  if not couplingSetupArray or #couplingSetupArray == 0 then return end

  -- Mark vehicles as having pending couplings
  for _, coupling in ipairs(couplingSetupArray) do
    pendingCouplings[coupling.vehId] = true
  end

  local readyCheckStartTime = os.clock()
  local couplingVerifyStartTime = os.clock()
  local readyCheckTimeout = 8
  local couplingVerifyTimeout = 8

  extensions.load('util_stepHandler')
  local seq = {
    -- Step 1: Wait for vehicles to be ready
    util_stepHandler.makeStepReturnTrueFunction(function()
      for _, coupling in ipairs(couplingSetupArray) do
        local veh = getObjectByID(coupling.vehId)
        local targetVeh = getObjectByID(coupling.targetVehId)
        if not veh or not veh:isReady() or not targetVeh or not targetVeh:isReady() then
          if os.clock() - readyCheckStartTime < readyCheckTimeout then
            return false
          end

          -- Fail-safe: don't block reset forever if a vehicle never becomes ready.
          log('E', logTag, 'Coupling ready-check timeout reached, continuing without full readiness.')
          break
        end
      end
      return true
    end),
    -- Step 2: Activate couplings
    util_stepHandler.makeStepReturnTrueFunction(function()
      for _, coupling in ipairs(couplingSetupArray) do
        local veh = getObjectByID(coupling.vehId)
        if veh then
          veh:queueLuaCommand(string.format('beamstate.activateAutoCoupling("%s")', coupling.nodeTag))
        end
      end
      return true
    end),
    -- Step 3: Wait for couplings to be registered in trailerRespawn
    util_stepHandler.makeStepReturnTrueFunction(function()
      if not core_trailerRespawn then
        -- If trailerRespawn is not available, assume couplings are done after activation
        -- Clear pending couplings for this sequence
        for _, coupling in ipairs(couplingSetupArray) do
          pendingCouplings[coupling.vehId] = nil
        end
        return true
      end

      -- Get trailer registration data
      local trailerData = core_trailerRespawn.getTrailerData()
      if not trailerData then
        return false
      end

      -- Check if all couplings are registered in trailerRespawn
      local allCoupled = true
      for _, coupling in ipairs(couplingSetupArray) do
        local vehId = coupling.vehId
        local targetVehId = coupling.targetVehId

        -- Check if coupling exists in either direction
        local coupled = false
        if trailerData[vehId] and type(trailerData[vehId]) == "table" and trailerData[vehId].trailerId == targetVehId then
          coupled = true
        elseif trailerData[targetVehId] and type(trailerData[targetVehId]) == "table" and trailerData[targetVehId].trailerId == vehId then
          coupled = true
        end

        if not coupled then
          allCoupled = false
          break
        end
      end

      if allCoupled then
        -- Clear pending couplings for this sequence
        for _, coupling in ipairs(couplingSetupArray) do
          pendingCouplings[coupling.vehId] = nil
        end
        log('I', logTag, 'All couplings verified in trailerRespawn')
        return true
      end

      if os.clock() - couplingVerifyStartTime >= couplingVerifyTimeout then
        -- Fail-safe: avoid hanging reset/start flow forever if trailerRespawn
        -- never reports the expected coupling state.
        for _, coupling in ipairs(couplingSetupArray) do
          pendingCouplings[coupling.vehId] = nil
        end
        log('W', logTag, 'Coupling verification timeout reached, continuing without verification.')
        return true
      end

      return false
    end)
  }
  util_stepHandler.startStepSequence(seq)
end

local function setupCouplings(deliveryVehicle, vehId)
  if not deliveryVehicle.couplings or #deliveryVehicle.couplings == 0 then
    return
  end

  local veh = getObjectByID(vehId)
  if not veh then return end

  local couplingSetup = createCouplingSetup(deliveryVehicle.couplings, vehId)
  for _, coupling in ipairs(couplingSetup) do
    table.insert(allCouplingSetup, coupling)
    -- Mark this vehicle as having pending couplings
    pendingCouplings[vehId] = true
  end
end

local function setupAllCouplings()
  if #allCouplingSetup == 0 then return end
  -- Note: pendingCouplings are already marked in setupCouplings() when couplings are collected
  setupCouplingSequence(allCouplingSetup)
end

local function setupPlayer(delivery)
  local playerStart = delivery.playerStart
  if not playerStart then
    log('W', logTag, 'No player start defined')
    return
  end

  if playerStart.type == "vehicle" then
    local vehId = vehicleIdMap[playerStart.vehicleId]
    if vehId then
      local veh = getObjectByID(vehId)
      if veh then
        gameplay_walk.getInVehicle(veh)
      end
      log('I', logTag, 'Setup player in vehicle: ' .. dumps(playerStart.vehicleId))
    else
      log('E', logTag, 'Starting vehicle not found: ' .. tostring(playerStart.vehicleId))
    end
  elseif playerStart.type == "walking" then
    if playerStart.position then
      local pos = vec3(playerStart.position[1], playerStart.position[2], playerStart.position[3])
      local rot = quat(0, 0, 0, 1)
      if playerStart.rotation then
        rot = quat(playerStart.rotation[1], playerStart.rotation[2], playerStart.rotation[3], playerStart.rotation[4])
      end

      -- Exit any vehicle first
      be:exitVehicle(0)

      -- Enable walking mode and teleport player
      if gameplay_walk then
        if gameplay_walk.isWalking() then
          local correctedRot = quat(rot) * quat(0,0,-1,0)
          spawn.safeTeleport(gameplay_walk.getCurrentUnicycle(), vec3(pos), quat(correctedRot), nil, nil, nil, nil, false)
          gameplay_walk.setRot(rot * vec3(0, 1, 0), vec3(0, 0, 1))
        else
          gameplay_walk.setWalkingMode(true, pos, rot, true)
        end
      end
      log('I', logTag, 'Setup player at walking start: ' .. dumps(playerStart.position) .. ' at ' .. dumps(pos) .. ' with rotation ' .. dumps(rot))
    end
  elseif playerStart.type == "parkingSpot" then
    if not playerStart.targetAreaId then
      log('E', logTag, 'parkingSpot playerStart requires targetAreaId field')
      return
    end

    -- Find the target area
    local targetArea = gameplay_freeformDelivery_utils.findTargetArea(delivery, playerStart.targetAreaId)
    if not targetArea then
      log('E', logTag, 'Target area not found: ' .. tostring(playerStart.targetAreaId))
      return
    end

    -- Verify it's a parking spot type
    if targetArea.type ~= "parkingSpot" then
      log('E', logTag, 'Target area is not a parking spot: ' .. tostring(playerStart.targetAreaId))
      return
    end

    -- Get the parking spot site object
    local parkingSpot = gameplay_freeformDelivery_utils.findSiteObject(delivery.sites, "parkingSpot", targetArea.siteId)
    if not parkingSpot then
      log('E', logTag, 'Parking spot site not found: ' .. tostring(targetArea.siteId))
      return
    end

    local pos = parkingSpot.pos
    local rot = parkingSpot.rot or quat(0, 0, 0, 1)


    -- Enable walking mode and teleport player
    if gameplay_walk then
      if gameplay_walk.isWalking() then
        local correctedRot = quat(rot) * quat(0,0,-1,0)
        spawn.safeTeleport(gameplay_walk.getCurrentUnicycle(), vec3(pos), quat(correctedRot), nil, nil, nil, nil, false)
        gameplay_walk.setRot(rot * vec3(0, 1, 0), vec3(0, 0, 1))
      else
        gameplay_walk.setWalkingMode(true, pos, rot, true)
      end
    end
    log('I', logTag, 'Setup player at parking spot in walking mode: ' .. dumps(playerStart.targetAreaId) .. ' at ' .. dumps(pos) .. ' with rotation ' .. dumps(rot))
  end
end

local function storeInitialVehicleTransforms(delivery)
  initialVehicleTransforms = {}

  if not delivery or not delivery.vehicles then return end

  for _, vehicleDef in ipairs(delivery.vehicles) do
    local vehId = vehicleIdMap[vehicleDef.id]
    if vehId then
      local veh = getObjectByID(vehId)
      if veh then
        veh = Sim.upcast(veh)
        initialVehicleTransforms[vehId] = {
          pos = veh:getPosition(),
          rot = quat(veh:getRotation()),
          up = veh:getDirectionVectorUp()
        }
      end
    end
  end
end

local function resolveDeliveryAssetPath(delivery, assetPath)
  if not assetPath then return nil end

  local resolvedPath = nil
  if string.sub(assetPath, 1, 1) == '/' then
    resolvedPath = assetPath
  elseif delivery and delivery._basePath then
    resolvedPath = gameplay_freeformDelivery_utils.resolvePath(delivery._basePath, assetPath)
  end

  if resolvedPath and FS:fileExists(resolvedPath) then
    return resolvedPath
  end
  return nil
end

local function addVehiclePreviewAndThumbnail(veh, vehicleDef, delivery)
  if not veh or not vehicleDef then return end

  -- Prefer paths from delivery definition when present and valid.
  local customPreview = resolveDeliveryAssetPath(delivery, vehicleDef.preview)
  local customThumbnail = resolveDeliveryAssetPath(delivery, vehicleDef.thumbnail)
  vehicleDef.preview = customPreview
  vehicleDef.thumbnail = customThumbnail

  -- Fallback to core vehicle metadata for missing assets.
  if vehicleDef.preview and vehicleDef.thumbnail then
    return
  end

  local vehKey = veh.JBeam
  local vehMainInfo = core_vehicles.getModel(vehKey)
  if not vehMainInfo then return end

  local configInfo = nil
  local vehConfig = veh.partConfig
  if type(vehConfig) == "string" then
    local configKey = string.match(vehConfig, "vehicles/" .. vehKey .. "/(.*).pc")
    if configKey and vehMainInfo.configs then
      configInfo = vehMainInfo.configs[configKey]
    end
  end
  configInfo = configInfo or vehMainInfo.model

  if configInfo then
    if not vehicleDef.preview then
      vehicleDef.preview = configInfo.preview
    end
    if not vehicleDef.thumbnail then
      vehicleDef.thumbnail = configInfo.preview
    end
  end
end

local function addTargetAreaPreviewAndThumbnail(targetArea, delivery)
  if not targetArea then return end

  if targetArea.preview ~= nil then
    targetArea.preview = resolveDeliveryAssetPath(delivery, targetArea.preview)
  end
  if targetArea.thumbnail ~= nil then
    targetArea.thumbnail = resolveDeliveryAssetPath(delivery, targetArea.thumbnail)
  end
end

function M.setup(delivery)
  if not delivery then
    log('E', logTag, 'No delivery data provided')
    return false
  end

  -- Mark setup as in progress
  setupInProgress = true
  pendingCouplings = {}
  allCouplingSetup = {}

  -- Store reference for vehicle spawning
  delivery._deliveryData = delivery

  -- Resolve optional target area assets (no fallback).
  for _, targetArea in ipairs(delivery.targetAreas or {}) do
    addTargetAreaPreviewAndThumbnail(targetArea, delivery)
  end

  -- Find and index vehicles from spawned prefabs
  for _, vehicleDef in ipairs(delivery.vehicles) do
    local veh, vehId = findVehicleByInternalName(delivery, vehicleDef.id)
    if veh then
      -- Store vehicle mapping
      spawnedVehicles[vehId] = {
        vehicleId = vehicleDef.id,
        vehicle = veh,
        deliveryVehicle = vehicleDef,
      }
      addVehiclePreviewAndThumbnail(veh, vehicleDef, delivery)
      vehicleIdMap[vehicleDef.id] = vehId

      -- Process enterable flag - add to blacklist if not enterable
      if vehicleDef.enterable == false then
        if gameplay_walk then
          gameplay_walk.addVehicleToBlacklist(vehId)
          log('D', logTag, 'Added vehicle to blacklist (not enterable): ' .. tostring(vehicleDef.id))
        end
      end

      -- Apply startup state (startup code + ignition)
      applyVehicleStartupState(veh, vehicleDef)

    end
  end

  -- Collect couplings in a second pass after all vehicles are indexed.
  -- This avoids missing couplings that target vehicles defined later in delivery.vehicles.
  for _, vehicleDef in ipairs(delivery.vehicles) do
    if vehicleDef.couplings and #vehicleDef.couplings > 0 then
      local vehId = vehicleIdMap[vehicleDef.id]
      if vehId then
        setupCouplings(vehicleDef, vehId)
      else
        log('W', logTag, 'Skipping couplings for unknown vehicle: ' .. tostring(vehicleDef.id))
      end
    end
  end

  -- Setup all couplings in one sequence
  setupAllCouplings()

  -- Setup player
  setupPlayer(delivery)

  -- Store initial vehicle transforms for reset functionality
  storeInitialVehicleTransforms(delivery)

  log('I', logTag, 'Setup started, waiting for async operations to complete')
  return true
end

function M.isSetupComplete()
  if not setupInProgress then
    return true -- No setup in progress, consider complete
  end

  -- Check if all vehicles are ready
  for vehId, vehicleData in pairs(spawnedVehicles) do
    local veh = getObjectByID(vehId)
    if not veh or not veh:isReady() then
      return false
    end
  end

  -- Check if all couplings are complete
  if next(pendingCouplings) then
    return false
  end

  -- All setup complete
  setupInProgress = false
  log('I', logTag, 'Setup complete, all async operations finished')
  return true
end

function M.restoreVehicleTransforms()
  -- Mark setup as in progress since we're re-applying startup code and couplings
  setupInProgress = true
  pendingCouplings = {}

  for vehId, transform in pairs(initialVehicleTransforms) do
    local veh = getObjectByID(vehId)
    if veh then
      vehicleSetPositionRotation(vehId, transform.pos.x, transform.pos.y, transform.pos.z,
                                 transform.rot.x, transform.rot.y, transform.rot.z, transform.rot.w)
      veh:requestReset(RESET_PHYSICS)
      veh:resetBrokenFlexMesh()

      -- Re-apply startup state after reset
      local vehicleData = spawnedVehicles[vehId]
      if vehicleData and vehicleData.deliveryVehicle then
        applyVehicleStartupState(veh, vehicleData.deliveryVehicle)
      end
    end
  end

  -- Re-setup couplings after vehicles are reset (with delay for physics to settle)
  local couplingSetup = {}
  for vehId, vehicleData in pairs(spawnedVehicles) do
    if vehicleData.deliveryVehicle and vehicleData.deliveryVehicle.couplings then
      for _, couplingData in ipairs(createCouplingSetup(vehicleData.deliveryVehicle.couplings, vehId)) do
        table.insert(couplingSetup, couplingData)
      end
    end
  end

  if #couplingSetup > 0 then
    setupCouplingSequence(couplingSetup)
  else
    -- No couplings to set up, mark as complete immediately
    setupInProgress = false
  end
end

function M.getVehicleId(deliveryVehicleId)
  return vehicleIdMap[deliveryVehicleId]
end

function M.isSetupInProgress()
  return setupInProgress
end

function M.setupPlayer(delivery)
  setupPlayer(delivery)
end

function M.getPendingCouplings()
  local result = {}
  for vehId, _ in pairs(pendingCouplings) do
    table.insert(result, vehId)
  end
  return result
end

function M.getAllCouplingSetup()
  return allCouplingSetup
end

function M.getSpawnedVehicles()
  return spawnedVehicles
end

function M.freezeAllVehicles(freeze)
  freeze = freeze ~= false -- Default to true if not specified
  for vehId, vehicleData in pairs(spawnedVehicles) do
    local veh = getObjectByID(vehId)
    if veh then
      core_vehicleBridge.executeAction(veh, 'setFreeze', freeze)
      log('D', logTag, string.format('%s vehicle %d (%s)', freeze and 'Froze' or 'Unfroze', vehId, vehicleData.vehicleId or 'unknown'))
    end
  end
end

function M.cleanup(delivery, keepVehicles)
  keepVehicles = keepVehicles or false

  -- Track prefabs that need to be exploded (contain vehicles we want to keep)
  local prefabsToExplode = {}
  local vehiclesToKeep = {} -- Vehicles not in prefabs

  if keepVehicles then
    -- Collect prefabs containing vehicles we want to keep
    for vehId, vehicleData in pairs(spawnedVehicles) do
      local veh = getObjectByID(vehId)
      if veh then
        -- Find parent prefab (if vehicle is inside one)
        local prefab = nil
        if Prefab and Prefab.getPrefabByChild then
          prefab = Prefab.getPrefabByChild(veh)
        end

        if prefab then
          local prefabId = prefab:getID()
          if not prefabsToExplode[prefabId] then
            prefabsToExplode[prefabId] = {}
          end
          -- Store vehicle transform before explosion
          local pos = veh:getPosition()
          local rot = quat(0, 0, 1, 0) * quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
          prefabsToExplode[prefabId][vehId] = {pos = pos, rot = rot}
        else
          -- Vehicle is not in a prefab
          vehiclesToKeep[vehId] = true
        end
      end
    end
  end

  -- Explode prefabs containing vehicles we want to keep
  if keepVehicles and next(prefabsToExplode) then
    for prefabId, vehicleTransforms in pairs(prefabsToExplode) do
      local prefab = scenetree.findObjectById(prefabId)
      if prefab then
        -- Explode the prefab
        local group = prefab:explode()
        prefab:delete()

        -- Move vehicles to MissionGroup and restore positions
        for vehId, transform in pairs(vehicleTransforms) do
          local veh = getObjectByID(vehId)
          if veh then
            if scenetree.MissionGroup then
              scenetree.MissionGroup:add(veh)
              veh:setPosRot(transform.pos.x, transform.pos.y, transform.pos.z, transform.rot.x, transform.rot.y, transform.rot.z, transform.rot.w)
            end
            log('I', logTag, 'Extracted vehicle from prefab via explosion: ' .. tostring(vehId))
          end
        end

        -- Delete the exploded group
        if group then
          group:delete()
        end
      end
    end
  end

  -- Remove spawned prefabs (which will also remove vehicles inside them if keepVehicles is false)
  if delivery and delivery._prefabIds then
    for _, prefabId in ipairs(delivery._prefabIds) do
      -- Skip prefabs we already exploded
      if not prefabsToExplode[prefabId] then
        local prefab = scenetree.findObjectById(prefabId)
        if prefab then
          if editor and editor.onRemoveSceneTreeObjects then
            editor.onRemoveSceneTreeObjects({prefabId})
          end
          prefab:delete()
        end
      end
    end
  end

  -- Move vehicles not in prefabs to MissionGroup (if keeping vehicles)
  if keepVehicles then
    for vehId, _ in pairs(vehiclesToKeep) do
      local veh = getObjectByID(vehId)
      if veh then
        if scenetree.MissionGroup then
          local parentId = tonumber(veh:getField("parentGroup", 0))
          local parent = scenetree.findObjectById(parentId)
          if parent and parent ~= scenetree.MissionGroup then
            parent:remove(veh)
            scenetree.MissionGroup:add(veh)
          end
        end
        log('I', logTag, 'Kept vehicle (not in prefab): ' .. tostring(vehId))
      end
    end
  end

  -- Remove spawned vehicles that aren't part of prefabs or if not keeping vehicles
  if not keepVehicles then
    for vehId, _ in pairs(spawnedVehicles) do
      local veh = getObjectByID(vehId)
      if veh then
        veh:delete()
      end
    end
  end

  -- Clear state
  spawnedVehicles = {}
  vehicleIdMap = {}
  initialVehicleTransforms = {}
  setupInProgress = false
  pendingCouplings = {}
  allCouplingSetup = {}
end

return M
