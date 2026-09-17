-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.enabled = false
M.followRotation = false

M.offsetWorld = nil -- vec3

M.offsetLocal = nil
M.rotOffset   = nil

local function getVehPos(vid)
  local veh = scenetree.findObjectById(vid)
  if not veh then return nil end
  if veh.getRefNodeAbsPositionXYZ then
    local x,y,z = veh:getRefNodeAbsPositionXYZ()
    return vec3(x,y,z)
  end
  return vec3(veh:getPositionXYZ())
end

local function getVehRot(vid)
  local veh = scenetree.findObjectById(vid)
  if not veh then return nil end
  if veh.getRefNodeRotation then
    return quat(veh:getRefNodeRotation())
  end
  if veh.getRotation then
    return quat(veh:getRotation())
  end
  return nil
end
local function getYawOnlyQuat(q)
  local f = q * vec3(0, 1, 0)

  f.z = 0
  local len2 = f:squaredLength()
  if len2 < 1e-12 then
    return quat(0, 0, 0, 1)
  end
  f:normalize()

  local yaw = math.atan2(f.x, f.y)
  return quatFromAxisAngle(vec3(0, 0, 1), yaw)
end

function M.enable(en, opts)
  M.enabled = (en == true)
  M.followRotation = (opts and opts.followRotation) == true

  M.offsetWorld = nil
  M.offsetLocal = nil
  M.rotOffset   = nil

  if not M.enabled then return end

  -- only attach when free camera is active
  if core_camera.getActiveGlobalCameraName() ~= "free" then
    M.enabled = false
    return
  end

  local vid = be:getPlayerVehicleID(0)
  if not vid or vid < 0 then
    M.enabled = false
    return
  end

  local vpos = getVehPos(vid)
  if not vpos then
    M.enabled = false
    return
  end

  local camPos = core_camera.getPosition()
  local worldOffset = camPos - vpos

  if not M.followRotation then
    M.offsetWorld = worldOffset
    return
  end

  local vrotFull = getVehRot(vid)
  if not vrotFull then
    M.enabled = false
    return
  end

  local vrotYaw = getYawOnlyQuat(vrotFull)

  M.offsetLocal = vrotYaw:inversed() * worldOffset

  local camRot = core_camera.getQuat()
  M.rotOffset = vrotYaw:inversed() * camRot
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  if not M.enabled then return end
  if core_camera.getActiveGlobalCameraName() ~= "free" then return end

  local vid = be:getPlayerVehicleID(0)
  if not vid or vid < 0 then return end

  local vpos = getVehPos(vid)
  if not vpos then return end

  if not M.followRotation then
    if not M.offsetWorld then return end
    core_camera.setPosition(0, vpos + M.offsetWorld)
    return
  end

  if not M.offsetLocal or not M.rotOffset then return end

  local vrotFull = getVehRot(vid)
  if not vrotFull then return end

  local vrotYaw = getYawOnlyQuat(vrotFull)

  local camPos = vpos + (vrotYaw * M.offsetLocal)
  local camRot = vrotYaw * M.rotOffset

  core_camera.setPosRot(0,
    camPos.x, camPos.y, camPos.z,
    camRot.x, camRot.y, camRot.z, camRot.w
  )
end

return M