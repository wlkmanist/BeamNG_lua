-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY PHYSICS TRACKER

  Reports physics instabilities with enough context to reproduce them: the vehicle and
  its config, the mod it came from, the level, the position and the damage state.

  This tracker only observes. It never sets instabilityHandled, so it does not interfere
  with whatever else deals with the instability.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local function onInstabilityDetected(vid, returnData)
  local vehicleData = extensions.telemetry_vehicleInfo.getData(vid)
  if not vehicleData then return end

  local event = {
    name = "physicsInstability",
    model = vehicleData.model,
    config = vehicleData.config,
    mod = extensions.telemetry_vehicleInfo.getMod(vehicleData.model),
    level = getCurrentLevelIdentifier() or "unknown",
    simSpeed = be:getSimulationTimeScale(),
    vehicleCount = #getAllVehicles(),
  }

  local veh = getObjectByID(vid)
  if veh then
    local pos = veh:getPosition()
    event.position = {x = pos.x, y = pos.y, z = pos.z}
    event.damage = veh.getSectionDamageSum and veh:getSectionDamageSum()
  end

  extensions.telemetry_core.addEvent(event)

  -- an instability is often the last thing before a crash, and the buffer only reaches
  -- disk every 100 events, so this one goes out now
  extensions.telemetry_core.triggerReportWrite()
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onInstabilityDetected = onInstabilityDetected

return M
