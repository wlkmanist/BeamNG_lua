-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")

local M = {}

local activeRecoveries = {}

local function isRecoveryCameraEnabled(player)
  if not settings.getValue("multiseat") then return true end
  return core_camera ~= nil and core_camera.getContextIdForPlayer(player) ~= nil
end

local function getPlayerIdForVehicle(vehicleId)
  if not vehicleId or not be then return nil end
  local players = (core_multiseat and core_multiseat.getPlayers()) or {0}
  for _, player in ipairs(players) do
    if be:getPlayerVehicleID(player) == vehicleId then
      return player
    end
  end
  return nil
end

local function beginRecoveryCamera(vehicleId)
  activeRecoveries[vehicleId] = nil
  local player = getPlayerIdForVehicle(vehicleId)
  if not player then return end -- nobody is seated in this vehicle, so there is no camera to take over
  if not isRecoveryCameraEnabled(player) then return end
  local freeCamActiveBefore = commands.isFreeCamera(player)
  activeRecoveries[vehicleId] = {player = player, freeCamActiveBefore = freeCamActiveBefore}
  if freeCamActiveBefore then return end
  commands.setFreeCamera(player)
end

local function setRecoveryCameraPosRot(vehicleId, px, py, pz, qx, qy, qz, qw)
  local recovery = activeRecoveries[vehicleId]
  if not recovery or recovery.freeCamActiveBefore then return end
  if not core_camera then return end
  core_camera.setPosRot(recovery.player, px, py, pz, qx, qy, qz, qw)
end

local function endRecoveryCamera(vehicleId)
  local recovery = activeRecoveries[vehicleId]
  activeRecoveries[vehicleId] = nil
  if not recovery or recovery.freeCamActiveBefore then return end
  commands.setGameCamera(recovery.player)
end

local function onDespawnObject(vehicleId)
  activeRecoveries[vehicleId] = nil -- a recovery that never ends must not keep a stale seat mapping
end

M.onDespawnObject = onDespawnObject
M.beginRecoveryCamera = beginRecoveryCamera
M.endRecoveryCamera = endRecoveryCamera
M.setRecoveryCameraPosRot = setRecoveryCameraPosRot

return M
