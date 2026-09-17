-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- Get vehicle name and icon type
local function getVehicleInfo(veh)
  if not veh then return nil, nil end

  local vehKey = veh.JBeam
  local vehConfig = veh.partConfig
  local vehicleNameSTR = {veh.JBeam}
  local vehMainInfo = core_vehicles.getModel(vehKey)
  local icon = "car" -- default icon for regular vehicles

  if vehMainInfo then
    table.clear(vehicleNameSTR)
    local config_key = string.match(vehConfig, "vehicles/".. vehKey .."/(.*).pc")
    local configInfo = vehMainInfo.configs and vehMainInfo.configs[config_key] or vehMainInfo.model

    -- build name
    table.insert(vehicleNameSTR, vehMainInfo.model["Brand"])
    table.insert(vehicleNameSTR, vehMainInfo.model["Name"])
    if vehMainInfo.configs and vehMainInfo.configs[config_key] then
      table.insert(vehicleNameSTR, configInfo["Configuration"] or "")
    end

    -- determine icon based on type (check config first, then model)
    local vehicleType = configInfo["Type"] or vehMainInfo.model["Type"]
    if vehicleType then
      if vehicleType == "Trailer" then
        icon = "smallTrailer"
      elseif vehicleType == "Prop" then
        icon = "trafficCone"
      elseif vehicleType == "Truck" then
        icon = "boxTruck"
      elseif vehicleType == "Car" then
        icon = "car"
      else
        -- Any other type (other than Trailer or Prop)
        icon = "beamNG"
      end
    end
  end

  local vehicleName = table.concat(vehicleNameSTR, " ")
  return vehicleName, icon
end

local function getSwitchableVehicleStats(currentVehId)
  local availableOptionsCount = 0
  local currentOptionIndex = 0

  for i = 0, be:getObjectCount() - 1 do
    local candidateVeh = be:getObject(i)
    if not candidateVeh then goto continue end

    -- Skip walking mode vehicle (unicycle)
    if candidateVeh:getJBeamFilename() == "unicycle" then goto continue end

    -- skip non-player usable vehicles
    if not candidateVeh.playerUsable then goto continue end

    -- skip inactive vehicles
    if not candidateVeh:getActive() then goto continue end

    -- skip blacklisted vehicles
    if gameplay_walk.isVehicleBlacklisted(candidateVeh:getId()) then goto continue end

    -- Skip parked/traffic props
    local vehKey = candidateVeh.JBeam
    local vehMainInfo = core_vehicles.getModel(vehKey)
    if vehMainInfo then
      local vehConfig = candidateVeh.partConfig
      local config_key = string.match(vehConfig, "vehicles/" .. vehKey .. "/(.*).pc")
      local configInfo = vehMainInfo.configs and vehMainInfo.configs[config_key] or vehMainInfo.model
      if configInfo["Type"] == "PropParked" or configInfo["Type"] == "PropTraffic" then
        goto continue
      end
    end

    if candidateVeh:getId() == currentVehId then
      currentOptionIndex = availableOptionsCount
    end
    availableOptionsCount = availableOptionsCount + 1

    ::continue::
  end

  return availableOptionsCount, currentOptionIndex
end

local function onVehicleSwitched(oldId, newId, player)
  -- Only process for player 0
  if player ~= 0 then return end

  -- Check if we have a valid new vehicle
  if newId == -1 then return end

  local veh = scenetree.findObjectById(newId)
  if not veh then return end

  -- Clear message if entering walking mode (unicycle)
  if veh:getJBeamFilename() == "unicycle" then
    guihooks.trigger('Message', {
      category = 'vehicleSwitch',
      clear = true
    })
    return
  end

  -- Get vehicle name and icon
  local vehicleName, vehicleIcon = getVehicleInfo(veh)
  if not vehicleName then return end
  local availableOptionsCount, currentOptionIndex = 1,0
  if not core_input_actionFilter.isActionBlocked("switch_next_vehicle") and not core_input_actionFilter.isActionBlocked("switch_previous_vehicle") then
    availableOptionsCount, currentOptionIndex = getSwitchableVehicleStats(newId)
  else

  end

  -- Display message with current vehicle icon
  guihooks.trigger('Message', {
    msg = vehicleName,
    ttl = 5,
    category = 'vehicleSwitch',
    icon = vehicleIcon,
    availableOptionsCount = availableOptionsCount,
    currentOptionIndex = currentOptionIndex
  })
end

M.onVehicleSwitched = onVehicleSwitched

return M

