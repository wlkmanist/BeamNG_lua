-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local allowedReturnRoutes = {
  ["pause"] = true,
  ["pause.vehicle"] = true,
}

local target = nil
local pendingDestroyedVehicleId = nil

local function validVehicleId(vehId)
  vehId = tonumber(vehId)
  if not vehId or vehId < 0 then return nil end
  return vehId
end

local function notifyChanged(previous, reason)
  extensions.hook("onVehicleConfigTargetChanged", deepcopy(target), previous, reason)
end

function M.begin(vehId, context)
  vehId = validVehicleId(vehId)
  if not vehId or not getObjectByID(vehId) then return false end

  context = type(context) == "table" and context or {}
  local returnRoute = allowedReturnRoutes[context.returnRoute] and context.returnRoute or "pause.vehicle"
  local previous = target and deepcopy(target) or nil
  target = {
    vehId = vehId,
    playerId = tonumber(context.playerId),
    returnRoute = returnRoute,
  }
  pendingDestroyedVehicleId = nil
  notifyChanged(previous, "begin")
  return true
end

function M.clear(reason)
  if not target then return false end
  local previous = target
  target = nil
  pendingDestroyedVehicleId = nil
  notifyChanged(previous, reason or "clear")
  return true
end

function M.isActive()
  return target ~= nil
end

function M.get()
  return target and deepcopy(target) or nil
end

function M.getTargetVehicleId()
  return target and target.vehId or nil
end

function M.getTargetPlayerId()
  return target and target.playerId or nil
end

function M.getReturnRoute()
  return target and target.returnRoute or "pause.vehicle"
end

function M.resolveVehicleId(explicitVehicleId)
  if explicitVehicleId ~= nil then
    local explicitId = validVehicleId(explicitVehicleId)
    return explicitId and getObjectByID(explicitId) and explicitId or nil
  end

  if target then
    return getObjectByID(target.vehId) and target.vehId or nil
  end

  local vehId = validVehicleId(be:getPlayerVehicleID(0))
  if vehId and getObjectByID(vehId) then return vehId end
  return nil
end

function M.resolveVehicle(explicitVehicleId)
  local vehId = M.resolveVehicleId(explicitVehicleId)
  return vehId and getObjectByID(vehId) or nil
end

function M.resolveVehicleData(explicitVehicleId)
  local vehId = M.resolveVehicleId(explicitVehicleId)
  local manager = extensions.core_vehicle_manager
  return vehId and manager and manager.getVehicleData(vehId) or nil
end

function M.onVehicleDestroyed(vehId)
  if target and target.vehId == tonumber(vehId) then
    pendingDestroyedVehicleId = target.vehId
  end
end

function M.onVehicleSpawned(vehId)
  if pendingDestroyedVehicleId == tonumber(vehId) then
    pendingDestroyedVehicleId = nil
  end
end

function M.onUpdate()
  if not pendingDestroyedVehicleId then return end
  local vehId = pendingDestroyedVehicleId
  pendingDestroyedVehicleId = nil
  if target and target.vehId == vehId and not getObjectByID(vehId) then
    M.clear("vehicleDestroyed")
  end
end

function M.onClientEndMission()
  M.clear("missionEnded")
end

function M.onExtensionUnloaded()
  M.clear("extensionUnloaded")
end

function M.onSerialize()
  return {
    target = target and deepcopy(target) or nil,
  }
end

function M.onDeserialized(data)
  local restored = type(data) == "table" and data.target or nil
  if type(restored) == "table" and validVehicleId(restored.vehId) and getObjectByID(restored.vehId) then
    M.begin(restored.vehId, restored)
  else
    target = nil
    pendingDestroyedVehicleId = nil
  end
end

return M
