-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  Shared vehicle lookups for the telemetry trackers. Not a tracker itself, so it does
  not live in the trackers folder and is not auto loaded as one.
]]

local M = {}

-- Model and part config of a vehicle. A custom configuration reports as ":custom", so no
-- user built configuration ever leaves the machine.
local function getData(vid)
  local vehicle = scenetree.findObjectById(vid)
  if not vehicle then
    log('W', 'telemetry_vehicleInfo', 'there is no vehicle with id: ' .. tostring(vid))
    return nil
  end
  if not vehicle:isSubClassOf('BeamNGVehicle') then
    return nil
  end

  local config
  if vehicle.partConfig ~= nil and (string.find(vehicle.partConfig, '{') ~= nil or string.find(vehicle.partConfig, '[', nil, true)) then
    config = ":custom"
  else
    local _, configName, _ = path.splitWithoutExt(vehicle.partConfig)
    config = configName
  end

  return {model = vehicle.JBeam, config = config}
end

-- The mod a vehicle model comes from, nil for stock content. The mod manager can only
-- resolve zipped mods, an unpacked mod returns nil.
local function getMod(model)
  if not model or not core_modmanager then return nil end

  local modname, mod = core_modmanager.getModForFilename('/vehicles/' .. model .. '/info.json')
  if not modname then return nil end

  return {name = modname, modID = mod and mod.modID}
end

M.getData = getData
M.getMod = getMod

return M
