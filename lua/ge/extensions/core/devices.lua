-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local beamOrange = vec3(255,102,0)

local vehicleRPMledState = {}
local playerColors = {}

local function getPlayerDeviceNames()
  local playerDeviceNames = {}
  for deviceName, playerNumber in pairs(core_input_bindings.assignedPlayers or {}) do
    if playerNumber ~= nil then
      playerDeviceNames[playerNumber] = playerDeviceNames[playerNumber] or {}
      table.insert(playerDeviceNames[playerNumber], deviceName)
    end
  end

  return playerDeviceNames
end

local function updateLightStatesForDevices()
  if not Device then return end
  local playerDeviceNames = getPlayerDeviceNames()

  for playerNumber, deviceNames in pairs(playerDeviceNames) do
    local playerVehId = be:getPlayerVehicleID(playerNumber)
    local veh = playerVehId and getObjectByID(playerVehId)
    local ffbConfig = veh and core_input_bindings.getFFBConfigForAction(veh, "steering")
    local lightingMode = ffbConfig and ffbConfig.ffbParams and ffbConfig.ffbParams.deviceLightingMode
    local playerColor = playerColors[playerNumber]
    for _, deviceName in ipairs(deviceNames) do
      local color = playerColor and playerColor or beamOrange
      if lightingMode == "default" then
        if vehicleRPMledState[playerVehId] then
          Device.resetRGB(deviceName)
        else
          Device.setRGB(deviceName, color.x, color.y, color.z)
        end
      else
        Device.setRGB(deviceName, color.x, color.y, color.z)
      end
    end
  end
end

local function isPlayerVehicleId(vehicleId)
  for deviceName, playerNumber in pairs(core_input_bindings.assignedPlayers or {}) do
    local playerVehId = be:getPlayerVehicleID(playerNumber)
    if playerVehId >= 0 and playerVehId == vehicleId then
      return true
    end
  end
  return false
end

local function onVehicleDestroyed(vehicleId)
  vehicleRPMledState[vehicleId] = nil
end

local function onBeforeVehicleReplaced(vehicleId)
  vehicleRPMledState[vehicleId] = nil
end

local function onVehicleRPMledStateChanged(vehicleId, shiftLEDsInUse)
  if vehicleRPMledState[vehicleId] == shiftLEDsInUse then return end
  vehicleRPMledState[vehicleId] = shiftLEDsInUse
  if isPlayerVehicleId(vehicleId) then
    updateLightStatesForDevices()
  end
end

local function onFFBConfigChanged()
  updateLightStatesForDevices()
end

local function setPlayerColors(colors)
  playerColors = colors or {}
  updateLightStatesForDevices()
end

M.setPlayerColors = setPlayerColors
M.onFFBConfigChanged = onFFBConfigChanged
M.onVehicleRPMledStateChanged = onVehicleRPMledStateChanged
M.onVehicleDestroyed = onVehicleDestroyed
M.onBeforeVehicleReplaced = onBeforeVehicleReplaced

return M
