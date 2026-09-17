-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

require("utils")

local M = {}

local freeCamActiveBefore = nil -- true if free cam was active before recovery (skip driving recovery orbit; do not force game cam at end)
local recoveryCameraEnabled = false

local function isRecoveryCameraEnabled()
  if not settings.getValue("multiseat") then return true end
  return false
end

local function beginRecoveryCamera(vehicleId)
  freeCamActiveBefore = nil
  recoveryCameraEnabled = isRecoveryCameraEnabled()
  if not recoveryCameraEnabled then return end
  freeCamActiveBefore = commands.isFreeCamera()
  commands.setFreeCamera()
end

local function setRecoveryCameraPosRot(vehicleId, px, py, pz, qx, qy, qz, qw)
  if not recoveryCameraEnabled then return end
  if freeCamActiveBefore then return end
  if not core_camera then return end
  core_camera.setPosRot(0, px, py, pz, qx, qy, qz, qw)
end

local function endRecoveryCamera(vehicleId)
  local hadFreeCam = freeCamActiveBefore
  freeCamActiveBefore = nil
  if not recoveryCameraEnabled then return end
  if not hadFreeCam then
    commands.setGameCamera()
  end
end

M.beginRecoveryCamera = beginRecoveryCamera
M.endRecoveryCamera = endRecoveryCamera
M.setRecoveryCameraPosRot = setRecoveryCameraPosRot

return M
