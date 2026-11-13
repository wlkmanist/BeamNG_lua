-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY VEHICLE TRACKER

  Tracks which vehicles are spawned and driven, and for how long. This answers
  which of our content actually gets used.

  Custom part configurations are reported as ":custom" instead of the config blob,
  so no user built configuration leaves the machine.
]]

local M = {}
M.dependencies = {'telemetry_core'}

-- The vehicle the player currently drives, kept so its activity can be closed
local currentVehicle = nil

local function endVehicleUsed()
  if not currentVehicle then return end
  extensions.telemetry_core.endActivity("vehicleUsed", currentVehicle)
  currentVehicle = nil
end

local function startVehicleUsed(vid)
  endVehicleUsed()

  local vehicleData = extensions.telemetry_vehicleInfo.getData(vid)
  if not vehicleData then return end

  currentVehicle = vehicleData
  extensions.telemetry_core.startActivity("vehicleUsed", vehicleData)
end

local function onVehicleSpawned(vid)
  local vehicleData = extensions.telemetry_vehicleInfo.getData(vid)
  if not vehicleData then return end

  extensions.telemetry_core.addEvent({
    name = "vehicleSpawned",
    model = vehicleData.model,
    config = vehicleData.config,
    level = getCurrentLevelIdentifier() or "unknown",
  })
end

local function onVehicleSwitched(oldId, newId, player)
  if player ~= 0 then return end

  -- -1 means the player is not in a vehicle anymore
  if newId == -1 then
    endVehicleUsed()
    return
  end

  startVehicleUsed(newId)
end

local function trackVehReset()
  -- resets are frequent, this is the noisiest event here, so it can be turned off
  if extensions.telemetry_configManager.getModuleConfig('vehicle').trackResets == false then return end

  local vid = be:getPlayerVehicleID(0)
  if not vid or vid == -1 then return end

  local vehicleData = extensions.telemetry_vehicleInfo.getData(vid)
  if not vehicleData then return end

  extensions.telemetry_core.addEvent({
    name = "vehicleReset",
    model = vehicleData.model,
    damage = map.objects[vid] and map.objects[vid].damage,
  })
end

local function onClientEndMission()
  endVehicleUsed()
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")

  -- a lua reload starts a new session while the player is already driving, and
  -- onVehicleSwitched will not fire again, so reopen the activity here
  local vid = be:getPlayerVehicleID(0)
  if vid and vid ~= -1 then startVehicleUsed(vid) end
end

local function onExit()
  endVehicleUsed()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExit = onExit
-- a lua reload tears the trackers down without an onExit, so close the activity here too
M.onExtensionUnloaded = endVehicleUsed

M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.trackVehReset = trackVehReset
M.onClientEndMission = onClientEndMission

return M
