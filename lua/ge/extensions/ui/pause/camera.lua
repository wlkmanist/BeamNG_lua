-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local ORBIT_SPEED_DEG_PER_SEC = -5.5

local state = {
  pauseSessionActive = false,
  pauseSessionCameraName = nil,
  pauseSessionVehicleId = nil,
  pauseSessionOrbitState = nil,
  active = false,
  orbiting = false,
  stoppedByManualInput = false,
  previousCameraName = nil,
  switchedToOrbit = false,
  lastTimeSinceRotationMs = nil,
}

local function getPlayerVehicleId()
  if not be or not be.getPlayerVehicleID then return nil end
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId < 0 then return nil end
  return vehId
end

local function getActiveCameraName()
  if not core_camera or not core_camera.getActiveCamName then return nil end
  return core_camera.getActiveCamName(0)
end

local function captureRotationClock()
  if core_camera and core_camera.timeSinceLastRotation then
    state.lastTimeSinceRotationMs = core_camera.timeSinceLastRotation()
  else
    state.lastTimeSinceRotationMs = nil
  end
end

local function getOrbitRotation(vehId)
  if not core_camera or not core_camera.getCameraDataById then return nil end
  local cameras = core_camera.getCameraDataById(vehId)
  local orbitCamera = cameras and cameras.orbit or nil
  if not orbitCamera or not orbitCamera.camRot then return nil end
  return vec3(orbitCamera.camRot)
end

local function captureOrbitState(vehId)
  if not core_camera or not core_camera.getCameraDataById then return nil end
  local cameras = core_camera.getCameraDataById(vehId)
  local orbitCamera = cameras and cameras.orbit or nil
  if not orbitCamera then return nil end

  local orbitState = {}
  if orbitCamera.camRot then
    orbitState.camRot = vec3(orbitCamera.camRot)
  end
  if orbitCamera.camDist ~= nil then
    orbitState.camDist = orbitCamera.camDist
  end
  if orbitCamera.orbitOffset then
    orbitState.orbitOffset = vec3(orbitCamera.orbitOffset)
  end

  if not orbitState.camRot and orbitState.camDist == nil and not orbitState.orbitOffset then
    return nil
  end
  return orbitState
end

local function restoreOrbitState(vehId, orbitState)
  if not core_camera or not orbitState then return false end
  if not vehId then return false end

  if orbitState.camRot and core_camera.setRotation then
    core_camera.setRotation(vehId, orbitState.camRot)
  end
  if orbitState.camDist ~= nil and core_camera.setDistance then
    core_camera.setDistance(vehId, orbitState.camDist)
  end
  if orbitState.orbitOffset and core_camera.setOffset then
    core_camera.setOffset(vehId, orbitState.orbitOffset)
  end
  return true
end

local function normalizeYaw(yawDeg)
  local yaw = yawDeg
  if yaw > 180 then yaw = yaw - 360 end
  if yaw < -180 then yaw = yaw + 360 end
  return yaw
end

local function beginPauseSession()
  if true then return end
  if state.pauseSessionActive then return true end
  local sessionVehicleId = getPlayerVehicleId()
  local sessionCameraName = getActiveCameraName()

  state.pauseSessionActive = true
  state.pauseSessionCameraName = sessionCameraName
  state.pauseSessionVehicleId = sessionVehicleId
  state.pauseSessionOrbitState = nil

  if sessionCameraName == "orbit" and sessionVehicleId then
    state.pauseSessionOrbitState = captureOrbitState(sessionVehicleId)
  end

  return true
end

function M.start()
  if true then return end
  local vehId = getPlayerVehicleId()
  if not vehId then return false end
  if not core_camera then return false end

  beginPauseSession()

  state.active = true
  state.orbiting = true
  state.stoppedByManualInput = false
  state.previousCameraName = state.pauseSessionCameraName or getActiveCameraName()
  state.switchedToOrbit = state.previousCameraName ~= "orbit"

  if core_camera.setByName then
    core_camera.setByName(0, "orbit")
  end

  captureRotationClock()
  return true
end

function M.stop()
  if true then return end
  if not state.active then return false end
  state.active = false
  state.orbiting = false
  state.stoppedByManualInput = false
  state.lastTimeSinceRotationMs = nil

  if state.switchedToOrbit and state.previousCameraName and state.previousCameraName ~= "orbit" then
    if core_camera and core_camera.setByName then
      core_camera.setByName(0, state.previousCameraName)
    end
  end

  state.previousCameraName = nil
  state.switchedToOrbit = false
  return true
end

function M.beginPauseSession()
  if true then return end
  return beginPauseSession()
end

function M.endPauseSession()
  if true then return end
  M.stop()

  local targetCameraName = state.previousCameraName
  local targetVehicleId = state.pauseSessionVehicleId
  local targetOrbitState = state.pauseSessionOrbitState
  state.pauseSessionActive = false
  state.pauseSessionCameraName = nil
  state.pauseSessionVehicleId = nil
  state.pauseSessionOrbitState = nil

  if targetCameraName and core_camera and core_camera.setByName then
    core_camera.setByName(0, targetCameraName)
  end
  if targetCameraName == "orbit" then
    restoreOrbitState(targetVehicleId or getPlayerVehicleId(), targetOrbitState)
  end
  return true
end

function M.onUpdate(dtReal)
  if not state.active or not state.orbiting then return end
  local vehId = getPlayerVehicleId()
  if not vehId then return end
  if not core_camera then return end

  local activeCameraName = getActiveCameraName()
  if activeCameraName ~= "orbit" then
    state.orbiting = false
    return
  end

  local currentTimeSinceRotationMs = core_camera.timeSinceLastRotation and core_camera.timeSinceLastRotation() or nil
  if currentTimeSinceRotationMs and state.lastTimeSinceRotationMs and currentTimeSinceRotationMs + 1 < state.lastTimeSinceRotationMs then
    state.orbiting = false
    state.stoppedByManualInput = true
    state.lastTimeSinceRotationMs = currentTimeSinceRotationMs
    return
  end
  if currentTimeSinceRotationMs then
    state.lastTimeSinceRotationMs = currentTimeSinceRotationMs
  end

  local rotation = getOrbitRotation(vehId)
  if not rotation then return end

  rotation.x = normalizeYaw(rotation.x - ORBIT_SPEED_DEG_PER_SEC * (dtReal or 0))

  if core_camera.setRotation then
    core_camera.setRotation(vehId, rotation)
  end
end

function M.debugState()
  return deepcopy(state)
end

return M
