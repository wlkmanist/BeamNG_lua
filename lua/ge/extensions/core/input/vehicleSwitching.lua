-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}
local vehicleOrder = nil

-- order is a list of vehicle IDs
local function setVehicleOrder(order)
  vehicleOrder = order
end

local lastIndex = -1

local function canEnterVehicle(veh, player)
  return not gameplay_seatOccupants
    or not gameplay_seatOccupants.canEnterVehicle
    or gameplay_seatOccupants.canEnterVehicle(veh:getId(), player)
end

local function findSwitchTarget(order, currentId, player, dir)
  local count = #order
  if count == 0 then return nil end
  local currentIndex = tableFindKey(order, currentId)
  if not currentIndex then
    currentIndex = dir > 0 and 0 or 1
  end

  for step = 1, count do
    local index = ((currentIndex - 1 + dir * step) % count) + 1
    local vehId = order[index]
    if vehId ~= currentId then
      local veh = scenetree.findObjectById(vehId)
      if veh then
        if canEnterVehicle(veh, player) then
          return veh
        end
      end
    end
  end
  return nil
end

local function enterVehicle(player, veh, dir)
  be:enterVehicle(player, veh)
  extensions.hook('trackNewVeh')
  extensions.hook("onVehicleSwitchPerformendByUser")
  extensions.hook("onVehicleCycleSwitchPerformedByUser", dir, player, veh:getId())
end

local function applySwitchCycleVehicle(player, dir)
  if player == -1 then return end
  player = player or 0
  -- custom order only if vehicleOrder is present, otherwise default behaviour
  if vehicleOrder ~= nil and #vehicleOrder > 0 then
    local currentId = be:getPlayerVehicleID(player)
    local currentIndex = tableFindKey(vehicleOrder, currentId) or lastIndex
    if currentIndex ~= -1 then
      local target = findSwitchTarget(vehicleOrder, currentId, player, dir)
      if target and be then
        enterVehicle(player, target, dir)
        return
      end
      vehicleOrder = nil
    else
      log("E","","Tried switching with custom order to vehicle, but player is not in a vehicle in the list!")
      vehicleOrder = nil
    end
  end

  -- if no success with custom order, use default behaviour
  if be then
    local currentId = be:getPlayerVehicleID(player)
    local order = {}
    for index = 0, be:getObjectCount() - 1 do
      local veh = be:getObject(index)
      if veh
        and veh:getJBeamFilename() ~= "unicycle"
        and veh.playerUsable ~= false
        and veh:getActive() then
        order[#order + 1] = veh:getId()
      end
    end

    local target = findSwitchTarget(order, currentId, player, dir)
    if target then enterVehicle(player, target, dir) end
  end
end

local function switchCycleVehicle(player, dir)
  player = player or 0
  if player == -1 then return end
  if multiplayer_vehicleSync then
    multiplayer_vehicleSync.requestSwitchCycleVehicle(player, dir)
    return
  end
  applySwitchCycleVehicle(player, dir)
end

M.switchCycleVehicle = switchCycleVehicle
M.applySwitchCycleVehicle = applySwitchCycleVehicle
M.setVehicleOrder = setVehicleOrder
return M
