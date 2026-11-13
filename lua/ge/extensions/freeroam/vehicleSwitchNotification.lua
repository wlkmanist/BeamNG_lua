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

local function showPresenceNotification(player, presence)
  if not presence then return end
  local veh = scenetree.findObjectById(presence.vehicleId)
  if not veh then return end
  local vehicleName, vehicleIcon = getVehicleInfo(veh)
  if not vehicleName then return end

  local message
  if presence.seatId then
    local seatName = presence.seatId
    if gameplay_seatOccupants and gameplay_seatOccupants.getSeats then
      for _, seat in ipairs(gameplay_seatOccupants.getSeats(presence.vehicleId) or {}) do
        if seat.seatId == presence.seatId then
          if seat.displayName then
            seatName = _tr(seat.displayName)
          else
            seatName = _tr(seat.defaultPermissionMode == "driver"
              and "ui.gameplay.seatOccupants.driverSeat"
              or "ui.gameplay.seatOccupants.passengerSeat")
          end
          break
        end
      end
    end
    message = core_locales.contextTranslate("ui.vehicleSwitchNotification.seat", {
      vehicle = vehicleName,
      seat = seatName,
    })
  else
    local messageId = presence.permissionMode == "passenger"
      and "ui.vehicleSwitchNotification.unseatedSpectator"
      or "ui.vehicleSwitchNotification.unseatedFullControls"
    message = core_locales.contextTranslate(messageId, {
      vehicle = vehicleName,
    })
  end

  local availableOptionsCount, currentOptionIndex = 1, 0
  if not core_input_actionFilter.isActionBlocked("switch_next_vehicle")
      and not core_input_actionFilter.isActionBlocked("switch_previous_vehicle") then
    availableOptionsCount, currentOptionIndex = getSwitchableVehicleStats(presence.vehicleId)
  end
  guihooks.trigger("Message", {
    msg = message,
    ttl = 5,
    category = "vehicleSwitch" .. tostring(player),
    icon = vehicleIcon,
    player = player,
    availableOptionsCount = availableOptionsCount,
    currentOptionIndex = currentOptionIndex,
  })
end

local function onVehicleSwitched(_, newId, player)
  player = player or 0
  local veh = newId and newId ~= -1 and scenetree.findObjectById(newId)
  if not veh or veh:getJBeamFilename() == "unicycle" then
    guihooks.trigger("Message", {
      category = "vehicleSwitch" .. tostring(player),
      player = player,
      clear = true,
    })
  end
end

local function onPlayerVehiclePresenceChanged(player, _, presence)
  showPresenceNotification(player or 0, presence)
end

M.onVehicleSwitched = onVehicleSwitched
M.onPlayerVehiclePresenceChanged = onPlayerVehiclePresenceChanged

return M

