-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local platoons = {}
local nextPlatoonId = 1
local vehicleExtCmd = "extensions.load('tech/platooning'); extensions.tech_platooning."

local function vehicleExists(vehicleId)
  return vehicleId and getObjectByID(vehicleId) ~= nil
end

local function get(platoonId)
  return platoons[tonumber(platoonId)]
end

local function findVehicleIndex(platoon, vehicleId)
  for i, id in ipairs(platoon.vehicles) do
    if id == vehicleId then
      return i
    end
  end
end

local function queueVehicleLua(vehicleId, command)
  local vehicle = vehicleId and getObjectByID(vehicleId)
  if vehicle then
    vehicle:queueLuaCommand(command)
  end
end

local function queueVehicleState(platoon, index)
  local vehicleId = platoon.vehicles[index]
  queueVehicleLua(vehicleId, string.format(vehicleExtCmd .. "onState(%q)", lpack.encode({
    platoonId = platoon.platoonId,
    selfId = vehicleId,
    role = index == 1 and "leader" or "follower",
    predecessorId = index > 1 and platoon.vehicles[index - 1] or nil,
    platoonIndex = index,
    launched = platoon.launched,
    leaderMode = platoon.leaderMode,
    commandedSpeed = platoon.commandedSpeed
  })))
end

local function dispatchState(platoonId)
  local platoon = get(platoonId)
  if not platoon then
    return
  end

  for index in ipairs(platoon.vehicles) do
    queueVehicleState(platoon, index)
  end
end

local function make(vehicles, launched, leaderMode, commandedSpeed)
  local platoonId = nextPlatoonId
  nextPlatoonId = nextPlatoonId + 1
  platoons[platoonId] = {
    platoonId = platoonId,
    vehicles = vehicles,
    launched = launched == true,
    leaderMode = leaderMode or 0,
    commandedSpeed = commandedSpeed
  }
  return platoons[platoonId]
end

local function create(leaderId, firstFollowerId)
  leaderId = tonumber(leaderId)
  firstFollowerId = tonumber(firstFollowerId)
  if not vehicleExists(leaderId) or not vehicleExists(firstFollowerId) or leaderId == firstFollowerId then
    return nil
  end

  local platoon = make({leaderId, firstFollowerId})
  dispatchState(platoon.platoonId)
  return platoon.platoonId
end

local function join(platoonId, followerId, index)
  local platoon = get(platoonId)
  followerId = tonumber(followerId)
  if not platoon or not vehicleExists(followerId) or findVehicleIndex(platoon, followerId) then
    return false
  end

  if index == nil then
    table.insert(platoon.vehicles, followerId)
  else
    index = tonumber(index)
    if not index or index < 0 or index > #platoon.vehicles then
      return false
    end
    table.insert(platoon.vehicles, index + 1, followerId)
  end

  dispatchState(platoonId)
  return true
end

local function launch(platoonId, leaderMode, speed)
  local platoon = get(platoonId)
  if not platoon then
    return false
  end

  platoon.launched = true
  platoon.leaderMode = tonumber(leaderMode) or 0
  platoon.commandedSpeed = tonumber(speed) or 0.0
  queueVehicleState(platoon, 1)
  return true
end

local function changeSpeed(platoonId, speed)
  local platoon = get(platoonId)
  if not platoon then
    return false
  end

  platoon.commandedSpeed = tonumber(speed) or 0.0
  if platoon.launched then
    queueVehicleState(platoon, 1)
  end
  return true
end

local function disband(platoonId)
  local platoon = get(platoonId)
  if not platoon then
    return false
  end

  for _, vehicleId in ipairs(platoon.vehicles) do
    queueVehicleLua(vehicleId, vehicleExtCmd .. "unload()")
  end
  platoons[platoonId] = nil
  return true
end

local function leave(platoonId, vehicleId)
  local platoon = get(platoonId)
  vehicleId = tonumber(vehicleId)
  local index = platoon and findVehicleIndex(platoon, vehicleId)
  if not index then
    return false
  end

  if #platoon.vehicles <= 2 then
    return disband(platoonId)
  end

  table.remove(platoon.vehicles, index)
  queueVehicleLua(vehicleId, vehicleExtCmd .. "unload()")
  dispatchState(platoonId)
  return true
end

local function split(platoonId, index)
  local platoon = get(platoonId)
  local n = platoon and #platoon.vehicles
  index = tonumber(index)
  if not platoon or index == nil or n < 4 or index < 2 or index > n - 2 then
    return nil
  end

  local vehicles = platoon.vehicles
  platoon.vehicles = table.move(vehicles, 1, index, 1, {})
  local secondPlatoon = make(table.move(vehicles, index + 1, n, 1, {}), platoon.launched, platoon.leaderMode, platoon.commandedSpeed)
  dispatchState(platoonId)
  dispatchState(secondPlatoon.platoonId)
  return secondPlatoon.platoonId
end

local function updateVehicleKinematics(vehicleId, encodedKinematics)
  vehicleId = tonumber(vehicleId)
  if not vehicleId then
    return
  end

  local kinematics = lpack.decode(encodedKinematics)
  kinematics.vehicleId = vehicleId
  be["sendToMailbox"](be, "platoonKin_" .. tostring(vehicleId), lpack.encodeBinWorkBuffer(kinematics))
end

M.create = create
M.join = join
M.split = split
M.launch = launch
M.changeSpeed = changeSpeed
M.leave = leave
M.disband = disband
M.updateVehicleKinematics = updateVehicleKinematics
M.onVehicleLostTrack = leave

return M
