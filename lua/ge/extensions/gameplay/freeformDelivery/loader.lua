-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = "freeformDelivery_loader"

local function loadSitesFile(sitesPath)
  if not sitesPath then
    log('W', logTag, 'No sites file specified')
    return nil
  end

  -- Use sitesManager to load sites if available
  if gameplay_sites_sitesManager then
    local sites = gameplay_sites_sitesManager.loadSites(sitesPath, true, true)
    if sites then
      return sites
    end
  end

  -- Fallback to direct loading
  local sitesData = jsonReadFile(sitesPath)
  if not sitesData then
    log('E', logTag, 'Failed to load sites file: ' .. tostring(sitesPath))
    return nil
  end

  -- Create sites object and load data
  local Sites = require('/lua/ge/extensions/gameplay/sites/sites')
  local sites = Sites()
  sites:onDeserialized(sitesData)
  sites:finalizeSites()
  sites.filename = sitesPath
  local dir, _, _ = path.split(sitesPath)
  sites.dir = dir

  return sites
end

local function findAllObjectsRecursive(obj, vehicleList, allObjectsList)
  if (obj:isSubClassOf("SimSet") or obj:isSubClassOf("SimGroup") or obj:isSubClassOf("Prefab")) and obj.size then
    for i = 0, obj:size() - 1 do
      local child = obj:at(i)
      findAllObjectsRecursive(child, vehicleList, allObjectsList)
    end
  end

  local cn = obj:getClassName()
  if cn == "BeamNGVehicle" then
    local internalName = obj:getInternalName() or ""
    if internalName ~= "" then
      vehicleList[internalName] = obj:getId()
    end
  end

  -- Track all objects by class name for collision/navgraph checks
  if allObjectsList then
    allObjectsList[cn] = allObjectsList[cn] or {}
    table.insert(allObjectsList[cn], obj:getId())
  end
end

-- Check if prefab contains colliders (TSStatic with collisionType != "None")
local function containsColliders(allObjectsByType)
  if not allObjectsByType or not allObjectsByType['TSStatic'] then
    return false
  end

  for _, id in ipairs(allObjectsByType['TSStatic']) do
    local static = scenetree.findObjectById(id)
    if static and static:getField('collisionType', '') ~= "None" then
      return true
    end
  end

  return false
end

-- Check if prefab requires navgraph reload (BeamNGWaypoint or DecalRoad)
local function requiresNavgraphReload(allObjectsByType)
  if not allObjectsByType then
    return false
  end

  -- Check for BeamNGWaypoint (if not excludeFromMap)
  if allObjectsByType['BeamNGWaypoint'] then
    for _, id in ipairs(allObjectsByType['BeamNGWaypoint']) do
      local wp = scenetree.findObjectById(id)
      if wp and not wp.excludeFromMap then
        return true
      end
    end
  end

  -- Check for DecalRoad (if drivability > 0)
  if allObjectsByType['DecalRoad'] then
    for _, id in ipairs(allObjectsByType['DecalRoad']) do
      local dr = scenetree.findObjectById(id)
      if dr and dr.drivability and dr.drivability > 0 then
        return true
      end
    end
  end

  return false
end

local function spawnAndIndexPrefab(prefabPath)
  if not prefabPath then
    log('W', logTag, 'No prefab file specified')
    return nil, nil, false, false
  end

  -- Spawn the prefab
  local name = generateObjectNameForClass('Prefab', "freeformDelivery_prefab_")
  local pos = vec3(0, 0, 0)
  local scenetreeObject = spawnPrefab(name, prefabPath, pos.x .. " " .. pos.y .. " " .. pos.z, "0 0 1 0", "1 1 1", false)

  if not scenetreeObject then
    log('E', logTag, 'Failed to spawn prefab: ' .. tostring(prefabPath))
    return nil, nil, false, false
  end

  scenetreeObject.canSave = false
  if scenetree.MissionGroup then
    scenetree.MissionGroup:add(scenetreeObject)
  end

  -- Find all vehicles in the prefab and index by internalName
  local vehicleIndex = {} -- Maps internalName to vehicle ID
  local allObjectsByType = {} -- Maps class name to array of object IDs
  findAllObjectsRecursive(scenetreeObject, vehicleIndex, allObjectsByType)

  -- Check for collision and navgraph requirements
  local needsCollisionReload = containsColliders(allObjectsByType)
  local needsNavgraphReload = requiresNavgraphReload(allObjectsByType)

  return scenetreeObject:getID(), vehicleIndex, needsCollisionReload, needsNavgraphReload
end

function M.load(deliveryPath)
  if not deliveryPath then
    log('E', logTag, 'No delivery path provided')
    return nil
  end

  -- Load main delivery file
  local deliveryData = jsonReadFile(deliveryPath)
  if not deliveryData then
    log('E', logTag, 'Failed to load delivery file: ' .. tostring(deliveryPath))
    return nil
  end

  -- Store the base path for resolving relative paths
  deliveryData._basePath = deliveryPath

  -- Resolve and load sites file
  if deliveryData.sitesFile then
    local sitesPath = gameplay_freeformDelivery_utils.resolvePath(deliveryPath, deliveryData.sitesFile)
    deliveryData.sites = loadSitesFile(sitesPath)
    if not deliveryData.sites then
      log('E', logTag, 'Failed to load sites data')
      return nil
    end
  else
    log('W', logTag, 'No sites file specified in delivery')
  end

  -- Resolve and spawn prefab file(s)
  local prefabFiles = deliveryData.prefabFiles or (deliveryData.prefabFile and {deliveryData.prefabFile} or {})
  if #prefabFiles > 0 then
    local allPrefabIds = {}
    local allVehicleIndex = {} -- Maps internalName to vehicle ID
    local needsCollisionReload = false
    local needsNavgraphReload = false

    for _, prefabFile in ipairs(prefabFiles) do
      local prefabPath = gameplay_freeformDelivery_utils.resolvePath(deliveryPath, prefabFile)
      local prefabId, vehicleIndex, hasColliders, needsNav = spawnAndIndexPrefab(prefabPath)
      systemYield()
      if prefabId and vehicleIndex then
        table.insert(allPrefabIds, prefabId)
        -- Merge vehicle indices (one vehicle per internalName)
        for internalName, vehId in pairs(vehicleIndex) do
          if allVehicleIndex[internalName] then
            log('W', logTag, 'Duplicate internalName found: ' .. tostring(internalName) .. ', overwriting previous vehicle ID')
          end
          allVehicleIndex[internalName] = vehId
        end
        -- Track if any prefab needs reloads
        if hasColliders then
          needsCollisionReload = true
        end
        if needsNav then
          needsNavgraphReload = true
        end
      else
        log('E', logTag, 'Failed to spawn prefab file: ' .. tostring(prefabFile))
        return nil
      end
    end

    deliveryData._prefabIds = allPrefabIds
    deliveryData._vehicleIndex = allVehicleIndex

    -- Handle collision and navgraph reloads
    if needsCollisionReload then
      if core_gamestate and core_gamestate.loading() then
        -- During level loading, delay collision reload
        log('I', logTag, 'Prefab contains colliders, collision will be reloaded after level loading')
        -- Note: The level loading system should handle this, but we log it for visibility
      else
        -- After level loading, reload immediately
        log('I', logTag, 'Reloading collision because prefab(s) contained colliders')
        be:reloadCollision()
      end
    end

    if needsNavgraphReload then
      if core_gamestate and core_gamestate.loading() then
        -- During level loading, delay navgraph reload
        log('I', logTag, 'Prefab contains navgraph data, navgraph will be reloaded after level loading')
        -- Note: The level loading system should handle this, but we log it for visibility
      else
        -- After level loading, reload immediately
        log('I', logTag, 'Reloading navgraph because prefab(s) contained waypoints or drivable roads')
        map.reset()
      end
    end
  else
    log('W', logTag, 'No prefab file(s) specified in delivery')
  end

  -- Validate required fields
  if not deliveryData.vehicles then
    log('W', logTag, 'No vehicles defined in delivery')
    deliveryData.vehicles = {}
  end

  if not deliveryData.targetAreas then
    log('W', logTag, 'No target areas defined in delivery')
    deliveryData.targetAreas = {}
  end

  return deliveryData
end

return M
