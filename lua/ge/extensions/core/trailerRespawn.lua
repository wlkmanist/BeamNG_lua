-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local logTag = 'trailerRespawn'

local enabled = true
local trailerReg = {}

local function onSerialize()
  local data = {}
  data.trailerReg = trailerReg
  data.enabled = enabled
  return data
end

local function onDeserialized(data)
  trailerReg = data.trailerReg
  enabled = data.enabled
  M.setEnabled(enabled)
end

local function resetData()
  trailerReg = {}
  enabled = true
  M.setEnabled(enabled)
end

local function getTrailerData()
  return trailerReg
end

--return true if create a loop
local function checkRedundancy(trailerId, forbiddenId)
  if trailerReg[trailerId] and trailerReg[trailerId]~= -1 then
    if trailerReg[trailerId].trailerId == forbiddenId then
      return true
    else
      return checkRedundancy(trailerReg[trailerId].trailerId, forbiddenId)
    end
  end
  return false
end

local function getPreviousAttachedVehicleId(vehId)
  for previousId, connectionInfo in pairs(trailerReg) do
    if type(connectionInfo) == "table" and connectionInfo.trailerId == vehId then
      return previousId
    end
  end
end

local function getVehicleTrainHead(vehId)
  local prevVehId = getPreviousAttachedVehicleId(vehId)
  if prevVehId then
    return getVehicleTrainHead(prevVehId)
  end
  return vehId
end

-- returns all vehicles connected to a given vehicle
local function getVehicleTrain(vehId, res, forward)
  if not res then
    res = {}
    res[vehId] = true
  end

  if forward == false then
    if trailerReg[vehId] then
      res[trailerReg[vehId].trailerId] = true
      getVehicleTrain(trailerReg[vehId].trailerId, res, false)
    end
  elseif forward == true then
    local prevVehId = getPreviousAttachedVehicleId(vehId)
    if prevVehId then
      res[prevVehId] = true
      getVehicleTrain(prevVehId, res, true)
    end
  else
    getVehicleTrain(vehId, res, true)
    getVehicleTrain(vehId, res, false)
  end
  return res
end

local function getConfigType(objId)
  local vehicleData = core_vehicle_manager.getVehicleData(objId)
  local configInfo
  if vehicleData.config.partConfigFilename then -- this property is nil if the config was not from a file
    local _, configName, _ = path.splitWithoutExt(vehicleData.config.partConfigFilename)
    configInfo = core_vehicles.getConfig(vehicleData.config.model, configName)
  end
  if not configInfo then
    local veh = getObjectByID(objId)
    local vehModel = core_vehicles.getModel(veh:getField('JBeam','0')).model
    return vehModel.Type
  end
  return next(configInfo.aggregates.Type)
end

local function getAttachedNonTrailer(vehId)
  -- Check for trailer and prop, because some trailers might actually be props
  if getConfigType(vehId) ~= "Trailer" then return vehId end
  local previousAttachedVehicleId = getPreviousAttachedVehicleId(vehId)
  if previousAttachedVehicleId then
    return getAttachedNonTrailer(previousAttachedVehicleId)
  end
  return false
end

local function unregisterVehicle(vehId, nodeId)
  -- check if vehId is on the "non trailer" side of the coupling
  local coupleInfo = trailerReg[vehId]
  if coupleInfo and (nodeId == nil or coupleInfo.node == nodeId) then
    log("D", logTag, "Unregistered vehicle "..tostring(vehId).."; trailer was ".. (type(coupleInfo) == "table" and tostring(coupleInfo.trailerId) or coupleInfo))
    trailerReg[vehId] = nil
  end

  -- check if vehId is on the "trailer" side of the coupling
  for vId, currentCoupleInfo in pairs(trailerReg) do
    if currentCoupleInfo.trailerId == vehId and (nodeId == nil or currentCoupleInfo.trailerNode == nodeId) then
      log("D", logTag, "Unregistered trailer "..tostring(vehId).."; vehicle was "..tostring(vId))
      trailerReg[vId] = nil
    end
  end
end

local function onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
  if objId1 == objId2 then return end
  if getConfigType(objId1) == "Prop" or getConfigType(objId2) == "Prop" then return end

  if getAttachedNonTrailer(objId1) and not checkRedundancy(objId2, objId1) then
    log("D", logTag, tostring(objId1).." registered trailer "..tostring(objId2).."  node = "..tostring(nodeId).."  trailernode = "..tostring(obj2nodeId))
    trailerReg[objId1] = {trailerId=objId2, trailerNode=obj2nodeId, node=nodeId}
  else
    log("D", logTag, tostring(objId2).." registered trailer "..tostring(objId1).."  node = "..tostring(obj2nodeId).."  trailernode = "..tostring(nodeId))
    if checkRedundancy(objId1,objId2) then
      log("E", logTag, "Tried to register a loop")
      return
    end
    trailerReg[objId2] = {trailerId=objId1, trailerNode=nodeId, node=obj2nodeId}
  end
  extensions.hook("onTrailerAttached", objId1, objId2)
end

local function onCouplerDetached(objId1, objId2, nodeId, obj2nodeId, breakForce)
  if not breakForce or breakForce > 0 then return end

  -- delay unregister by one frame so that it doesnt prevent trailer reset on non-trailer reset
  extensions.core_jobsystem.create(function(job)
    coroutine.yield()
    unregisterVehicle(objId1, nodeId)
  end, 1)
end

local function onVehicleActiveChanged(vehId, active)
  -- sets the vehicle's trailer visibility state to match the owner
  if trailerReg[vehId] then
    getObjectByID(trailerReg[vehId].trailerId):setActive(active and 1 or 0)
    log("D", logTag, "Trailer "..tostring(trailerReg[vehId].trailerId).." active state set to "..tostring(active))

    if active then
      local vehCouplerOffset = core_vehicles.vehsCouplerOffset[vehId][trailerReg[vehId].node]
      local trailerCouplerOffset = core_vehicles.vehsCouplerOffset[trailerReg[vehId].trailerId][trailerReg[vehId].trailerNode]
      local vehCouplerTag = core_vehicles.vehsCouplerTags[vehId][trailerReg[vehId].node]
      spawn.placeTrailer(vehId, vehCouplerOffset, trailerReg[vehId].trailerId, trailerCouplerOffset, vehCouplerTag)
    end
  end
end

local function placeTrailer(vehId)
  if trailerReg[vehId] then
    local vehCouplerOffset = core_vehicles.vehsCouplerOffset[vehId][trailerReg[vehId].node]
    local trailerCouplerOffset = core_vehicles.vehsCouplerOffset[trailerReg[vehId].trailerId][trailerReg[vehId].trailerNode]
    local vehCouplerTag = core_vehicles.vehsCouplerTags[vehId][trailerReg[vehId].node]
    spawn.placeTrailer(vehId, vehCouplerOffset, trailerReg[vehId].trailerId, trailerCouplerOffset, vehCouplerTag)
  end
end

local function coupleTrailer(vehId)
  if not trailerReg[vehId] then return end
  local veh = getObjectByID(vehId)
  if not veh then return end

  local couplerTag = core_vehicles.vehsCouplerTags[vehId][trailerReg[vehId].node]
  if core_vehicles.couplerTagsOptions[couplerTag] == "autoCouple" then
    veh:queueLuaCommand(string.format('beamstate.activateAutoCoupling("%s")', couplerTag))
  end
end

local function onVehicleSpawned(vehId)
  unregisterVehicle(vehId)
end

-- TODO: Remove this when trailer respawn is disabled
local function onVehicleResetted(vehId)
  if trailerReg[vehId] then
    local tmp = core_vehicles.vehsCouplerOffset[trailerReg[vehId].trailerId][trailerReg[vehId].trailerNode]
    spawn.placeTrailer(vehId, core_vehicles.vehsCouplerOffset[vehId][trailerReg[vehId].node], trailerReg[vehId].trailerId, tmp, core_vehicles.vehsCouplerTags[vehId][trailerReg[vehId].node])
  end
end

local function onVehicleDestroyed(vehId)
  unregisterVehicle(vehId)
end

local function debugUpdate(dt, dtSim)
  if M.debugEnabled == false then return end

  -- highlight all coupling nodes

  for vID,c in pairs(core_vehicles.vehsCouplerOffset) do
    local veh = getObjectByID(vID)
    if veh then
      local pos = veh:getPosition()
      for ci,cpos in pairs(c) do
        debugDrawer:drawSphere( (pos+cpos), 0.05, ColorF(1, 0, 0, 1))
        debugDrawer:drawTextAdvanced( (pos+cpos), String(tostring(vID.."@"..ci)), ColorF(0.2, 0, 0, 1), true, false, ColorI(255,255,255,255) )
      end
    end
  end
end

local function setEnabled(enabled) -- automatically or manually enables or disables the trailer respawn system
  if enabled then
    M.onCouplerAttached = onCouplerAttached
    M.onCouplerDetached = onCouplerDetached
  else
    M.onCouplerAttached = nop
    M.onCouplerDetached = nop
  end
end

local function isVehicleCoupledToTrailer(vehId, trailerId)
  local coupleInfo = trailerReg[vehId]
  if not coupleInfo then return false end
  if coupleInfo.trailerId == trailerId then return true end
  return isVehicleCoupledToTrailer(coupleInfo.trailerId, trailerId)
end

M.setEnabled = setEnabled
M.getEnabled = function() return enabled end
M.getTrailerData = getTrailerData
M.getPreviousAttachedVehicleId = getPreviousAttachedVehicleId
M.getVehicleTrainHead = getVehicleTrainHead
M.getAttachedNonTrailer = getAttachedNonTrailer
M.isVehicleCoupledToTrailer = isVehicleCoupledToTrailer
M.getVehicleTrain = getVehicleTrain
M.placeTrailer = placeTrailer
M.coupleTrailer = coupleTrailer
M.getConfigType = getConfigType

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetached = onCouplerDetached
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed

M.debugEnabled = false
-- M.onPreRender = debugUpdate
M.resetData = resetData

return M