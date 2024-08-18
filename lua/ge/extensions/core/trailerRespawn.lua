-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {"core_vehicleBridge"}
local logTag = 'trailerRespawn'

local enabled = true
local trailerReg = {}
local couplerOffset = {}
local couplerTags = {}

local function onSerialize()
  local data = {}
  data.trailerReg = trailerReg
  data.couplerOffset = couplerOffset
  data.couplerTags = couplerTags
  data.enabled = enabled
  return data
end

local function onDeserialized(data)
  trailerReg = data.trailerReg
  couplerOffset = data.couplerOffset
  couplerTags = data.couplerTags
  enabled = data.enabled
  M.setEnabled(enabled)
end

local function resetData()
  trailerReg = {}
  couplerOffset = {}
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

local function getAttachedNonTrailer(vehId)
  local veh = be:getObjectByID(vehId)
  local vehModel = core_vehicles.getModel(veh:getField('JBeam','0')).model
  if vehModel.Type ~= "Trailer" then return vehId end
  local previousAttachedVehicleId = getPreviousAttachedVehicleId(vehId)
  if previousAttachedVehicleId then
    return getAttachedNonTrailer(previousAttachedVehicleId)
  end
  return false
end

local function unregisterVehicle(vehId)
  if trailerReg[vehId] then
    log("D", logTag, "Unregistered vehicle "..tostring(vehId).."; trailer was ".. (type(trailerReg[vehId]) == "table" and tostring(trailerReg[vehId].trailerId) or trailerReg[vehId]))
    trailerReg[vehId] = nil
  end

  for vId, coupleInfo in pairs(trailerReg) do
    if coupleInfo and coupleInfo.trailerId == vehId then
      log("D", logTag, "Unregistered trailer "..tostring(vehId).."; vehicle was "..tostring(vId))
      trailerReg[vId] = nil
    end
  end
end

local function onCouplerAttached(objId1, objId2, nodeId, obj2nodeId)
  if objId1 == objId2 then return end
  if couplerOffset[objId1] == nil or couplerOffset[objId1][nodeId] == nil or couplerOffset[objId2] == nil or couplerOffset[objId2][obj2nodeId] == nil then
    return
  end

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
end

local function onCouplerDetach(objId1, nodeId)
  unregisterVehicle(objId1)
end

-- coupler tags + a tag for the auto couple function
local couplerTagsOptions = {
  tow_hitch = "autoCouple",
  fifthwheel = "autoCouple",
  gooseneck_hitch = "autoCouple",
  pintle = "autoCouple",
  fifthwheel_v2 = true
}

local function getCouplerTagsOptions()
  return couplerTagsOptions
end

local function onVehicleActiveChanged(vehId, active)
  -- sets the vehicle's trailer visibility state to match the owner
  if trailerReg[vehId] then
    be:getObjectByID(trailerReg[vehId].trailerId):setActive(active and 1 or 0)
    log("D", logTag, "Trailer "..tostring(trailerReg[vehId].trailerId).." active state set to "..tostring(active))

    if active then
      local tmp = couplerOffset[trailerReg[vehId].trailerId][trailerReg[vehId].trailerNode]
      spawn.placeTrailer(vehId, couplerOffset[vehId][trailerReg[vehId].node], trailerReg[vehId].trailerId, tmp, couplerTags[vehId][trailerReg[vehId].node])
    end
  end
end

local function onVehicleSpawned(vehId)
  if couplerOffset[vehId] then
    couplerOffset[vehId] = nil
  end

  unregisterVehicle(vehId)

  local veh = be:getObjectByID(vehId)
  for tag, _ in pairs(couplerTagsOptions) do
    core_vehicleBridge.requestValue(veh, function(ret) M.addCouplerOffset(vehId, ret.result) end, 'couplerOffset', tag)
  end
end

local function onVehicleResetted(vehId)
  if trailerReg[vehId] then
    local tmp = couplerOffset[trailerReg[vehId].trailerId][trailerReg[vehId].trailerNode]
    spawn.placeTrailer(vehId, couplerOffset[vehId][trailerReg[vehId].node], trailerReg[vehId].trailerId, tmp, couplerTags[vehId][trailerReg[vehId].node])
  end
end

local function onVehicleDestroyed(vehId)
  if couplerOffset[vehId] then
    couplerOffset[vehId] = nil
  end

  unregisterVehicle(vehId)
end

local function addCouplerOffset(vId, data)
  couplerOffset[vId] = couplerOffset[vId] or {}
  couplerTags[vId] = couplerTags[vId] or {}
  for id, off in pairs(data or {}) do
    couplerOffset[vId][id] = vec3(off)
    couplerTags[vId][id] = off.couplerTag
  end
end

local function debugUpdate(dt, dtSim)
  if M.debugEnabled == false then return end

  -- highlight all coupling nodes

  for vID,c in pairs(couplerOffset) do
    local veh = be:getObjectByID(vID)
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
    M.onCouplerDetach = onCouplerDetach
    M.onVehicleResetted = onVehicleResetted
  else
    M.onCouplerAttached = nop
    M.onCouplerDetach = nop
    M.onVehicleResetted = nop
  end
end

local function isVehicleCoupledToTrailer(vehId, trailerId)
  local coupleInfo = trailerReg[vehId]
  if not coupleInfo then return false end
  if coupleInfo.trailerId == trailerId then return true end
  return isVehicleCoupledToTrailer(coupleInfo.trailerId, trailerId)
end

M.setEnabled = setEnabled
M.getTrailerData = getTrailerData
M.addCouplerOffset = addCouplerOffset
M.getCouplerTagsOptions = getCouplerTagsOptions
M.getAttachedNonTrailer = getAttachedNonTrailer
M.isVehicleCoupledToTrailer = isVehicleCoupledToTrailer

M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onCouplerAttached = onCouplerAttached
M.onCouplerDetach = onCouplerDetach
M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleResetted = onVehicleResetted
M.onVehicleDestroyed = onVehicleDestroyed

M.debugEnabled = false
-- M.onPreRender = debugUpdate
M.resetData = resetData

return M