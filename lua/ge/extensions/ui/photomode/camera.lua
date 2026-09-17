-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = { "ui_photomode_shared" }
local logTag = "ui_photomode_camera"

local function getCurrentLevelId()
  return type(getCurrentLevelIdentifier) == "function" and tostring(getCurrentLevelIdentifier() or "") or ""
end


local CAMERA_LIMITS = {
  fovMin = 10,
  fovMax = 120,
  speedMin = 2,
  speedMax = 300,
  rollMin = -90,
  rollMax = 90,
}

local CAMERA_DEFAULTS = {
  fov = 60,
  speed = 15,
  rollDeg = 0,
}

local CAMERA_EXPOSURE_DEFAULTS = {
  autoExposure = true,
  manualEV = 10,
}


local function readActiveCameraName()
  local getActiveCamName = ui_photomode_shared.getCoreCameraFunction("getActiveCamName")
  if not getActiveCamName then
    return nil
  end
  local ok, value = pcall(getActiveCamName, 0)
  if not ok then
    ui_photomode_shared.logDebug("getActiveCamName failed: " .. tostring(value))
    return nil
  end
  return type(value) == "string" and value or nil
end

local function isFreeCameraActive()
  if commands and type(commands.isFreeCamera) == "function" then
    local ok, value = pcall(commands.isFreeCamera)
    if ok then
      return value == true
    end
    ui_photomode_shared.logDebug("isFreeCamera failed: " .. tostring(value))
  end
  return readActiveCameraName() == "free"
end

local function readPlayerVehicleId()
  if not be or type(be.getPlayerVehicleID) ~= "function" then
    return nil
  end
  local ok, value = pcall(be.getPlayerVehicleID, be, 0)
  if not ok then
    ui_photomode_shared.logDebug("getPlayerVehicleID failed: " .. tostring(value))
    return nil
  end
  value = tonumber(value)
  if value == nil or value < 0 then
    return nil
  end
  return value
end

local function serializeVector3(value)
  if value == nil then
    return nil
  end
  local x = tonumber(value.x)
  local y = tonumber(value.y)
  local z = tonumber(value.z)
  if x == nil or y == nil or z == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = z,
  }
end

local function readRawCameraFov()
  local getFov = ui_photomode_shared.getCoreCameraFunction("getFovDeg")
  if not getFov then
    return nil
  end
  local ok, value = pcall(getFov)
  if not ok then
    ui_photomode_shared.logDebug("getFovDeg failed: " .. tostring(value))
    return nil
  end
  return tonumber(value)
end

local function readRawCameraSpeed()
  local getSpeed = ui_photomode_shared.getCoreCameraFunction("getSpeed")
  if not getSpeed then
    return nil
  end
  local ok, value = pcall(getSpeed)
  if not ok then
    ui_photomode_shared.logDebug("getSpeed failed: " .. tostring(value))
    return nil
  end
  return tonumber(value)
end

local function readSerializableCameraPosition()
  local getPositionXYZ = ui_photomode_shared.getCoreCameraFunction("getPositionXYZ")
  if not getPositionXYZ then
    return nil
  end
  local ok, x, y, z = pcall(getPositionXYZ)
  if not ok then
    ui_photomode_shared.logDebug("getPositionXYZ failed: " .. tostring(x))
    return nil
  end
  x = tonumber(x)
  y = tonumber(y)
  z = tonumber(z)
  if x == nil or y == nil or z == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = z,
  }
end

local function readSerializableCameraRotation()
  local getQuatXYZW = ui_photomode_shared.getCoreCameraFunction("getQuatXYZW")
  if not getQuatXYZW then
    return nil
  end
  local ok, x, y, z, w = pcall(getQuatXYZW)
  if not ok then
    ui_photomode_shared.logDebug("getQuatXYZW failed: " .. tostring(x))
    return nil
  end
  x = tonumber(x)
  y = tonumber(y)
  z = tonumber(z)
  w = tonumber(w)
  if x == nil or y == nil or z == nil or w == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = z,
    w = w,
  }
end

local function readCameraAngles()
  local getAngles = ui_photomode_shared.getCoreCameraFunction("getYawPitchRoll")
  if not getAngles then
    return {
      yawDeg = 0,
      pitchDown = 0,
      rollDeg = 0,
    }
  end
  local ok, value = pcall(getAngles)
  if not ok or type(value) ~= "table" then
    ui_photomode_shared.logDebug("getYawPitchRoll failed: " .. tostring(value))
    return {
      yawDeg = 0,
      pitchDown = 0,
      rollDeg = 0,
    }
  end
  return {
    yawDeg = tonumber(value.yawDeg) or 0,
    pitchDown = tonumber(value.pitchDown) or 0,
    rollDeg = tonumber(value.rollDeg) or 0,
  }
end

local function normalizeCameraFov(value)
  return ui_photomode_shared.clampNumber(value, CAMERA_LIMITS.fovMin, CAMERA_LIMITS.fovMax, CAMERA_DEFAULTS.fov)
end

local function normalizeCameraSpeed(value)
  return ui_photomode_shared.clampNumber(value, CAMERA_LIMITS.speedMin, CAMERA_LIMITS.speedMax, CAMERA_DEFAULTS.speed)
end

local function normalizeCameraRoll(value)
  return ui_photomode_shared.clampNumber(value, CAMERA_LIMITS.rollMin, CAMERA_LIMITS.rollMax, CAMERA_DEFAULTS.rollDeg)
end

local function readCameraSmoothMovement()
  local value = ui_photomode_shared.readSettingValue("cameraFreeSmoothMovement")
  if value == nil then
    return nil
  end
  return ui_photomode_shared.normalizeBoolean(value, false)
end

local function applyCameraSmoothMovement(value)
  if not settings or type(settings.setState) ~= "function" then
    return false, "camera_smooth_movement_unavailable"
  end

  local smoothMovement = ui_photomode_shared.normalizeBoolean(value, false)

  local ok = ui_photomode_shared.writeSettingsState({
    cameraFreeSmoothMovement = smoothMovement,
  })

  if not ok then
    return false, "camera_smooth_movement_set_failed"
  end

  ui_photomode_shared.notifySettingsUi()

  return true
end

local function serializeQuaternion(value)
  if value == nil then
    return nil
  end
  local x = tonumber(value.x)
  local y = tonumber(value.y)
  local z = tonumber(value.z)
  local w = tonumber(value.w)
  if x == nil or y == nil or z == nil or w == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = z,
    w = w,
  }
end

local function readCurrentVehicleCameraReference()
  if type(getPlayerVehicle) ~= "function" then
    return nil
  end

  local vehicle = getPlayerVehicle(0)
  if not vehicle then
    return nil
  end

  local ok, oobb = pcall(function()
    return vehicle:getSpawnWorldOOBB()
  end)
  if not ok or not oobb then
    ui_photomode_shared.logDebug("getSpawnWorldOOBB failed: " .. tostring(oobb))
    return nil
  end

  local vehiclePos = vec3(vehicle:getPosition())
  local axisX = vec3(oobb:getAxis(0))
  local axisY = vec3(oobb:getAxis(1))
  local axisZ = vec3(oobb:getAxis(2))
  local vehicleRotation = quatFromDir(axisY, axisZ)

  return {
    vehicle = vehicle,
    position = vehiclePos,
    axisX = axisX,
    axisY = axisY,
    axisZ = axisZ,
    rotation = vehicleRotation,
  }
end

local function buildRelativeFreeCameraBookmark()
  local vehicleReference = readCurrentVehicleCameraReference()
  local getPosition = ui_photomode_shared.getCoreCameraFunction("getPosition")
  local getQuat = ui_photomode_shared.getCoreCameraFunction("getQuat")
  if not vehicleReference or not getPosition or not getQuat then
    return nil
  end

  local posOk, cameraPos = pcall(getPosition)
  local rotOk, cameraQuat = pcall(getQuat)
  if not posOk or not rotOk then
    ui_photomode_shared.logDebug("relative freecam capture failed")
    return nil
  end

  local vehicleToCamera = vec3(cameraPos) - vehicleReference.position
  local offsetX = vehicleReference.axisX:dot(vehicleToCamera)
  local offsetY = vehicleReference.axisY:dot(vehicleToCamera)
  local offsetZ = vehicleReference.axisZ:dot(vehicleToCamera)
  local rotationOffset = quat(cameraQuat) * vehicleReference.rotation:inversed()
  local serializedRotationOffset = serializeQuaternion(rotationOffset)
  local fov = normalizeCameraFov(readRawCameraFov())
  if not serializedRotationOffset then
    ui_photomode_shared.logDebug("relative freecam bookmark capture skipped: rotation offset unavailable")
    return nil
  end
  if offsetX == nil or offsetY == nil or offsetZ == nil or fov == nil then
    ui_photomode_shared.logDebug("relative freecam bookmark capture skipped: offset unavailable")
    return nil
  end

  return {
    mode = "relativeFreecam",
    offset = {
      x = offsetX,
      y = offsetY,
      z = offsetZ,
    },
    rotOffset = serializedRotationOffset,
    fov = fov,
  }
end


local function readLocalExposureObject()
  if not scenetree or type(scenetree.findObject) ~= "function" then
    return nil
  end
  return scenetree.findObject("PostEffectLocalExposureObject")
end

local CAMERA_EXPOSURE_LIMITS = {
  manualEvMin = -20,
  manualEvMax = 20,
}

local function normalizeCameraManualEV(value)
  return ui_photomode_shared.clampNumber(value, CAMERA_EXPOSURE_LIMITS.manualEvMin, CAMERA_EXPOSURE_LIMITS.manualEvMax, 10)
end

local function captureCameraExposureState()
  local localExposureObject = readLocalExposureObject()

  if not localExposureObject then
    return {
      autoExposure = nil,
      manualEV = nil,
    }
  end

  return {
    autoExposure = ui_photomode_shared.normalizeBoolean(localExposureObject.autoExposure, true),
    manualEV = tonumber(localExposureObject.manualEV),
  }
end

local function applyCameraExposureStatePatch(partialState)
  if type(partialState) ~= "table" then
    return false, "camera_exposure_state_invalid"
  end

  local localExposureObject = readLocalExposureObject()
  if not localExposureObject then
    return false, "exposure_settings_unavailable"
  end

  local changed = false

  if partialState.autoExposure ~= nil then
    localExposureObject.autoExposure = ui_photomode_shared.normalizeBoolean(partialState.autoExposure, true)
    changed = true
  end

  if partialState.manualEV ~= nil then
    localExposureObject.manualEV = normalizeCameraManualEV(partialState.manualEV)
    changed = true
  end

  if not changed then
    return false, "camera_exposure_patch_empty"
  end

  return true
end

local function hasNodeGrabberVisibilityApi()
  return Engine ~= nil and type(Engine.NodeGrabber_setFixedNodesVisible) == "function"
end

local function readNodeGrabberFixedNodesVisible()
  if not Engine then
    return nil
  end

  local getter = Engine.NodeGrabber_getFixedNodesVisible
  if type(getter) ~= "function" then
    return nil
  end

  local ok, value = pcall(getter)
  if not ok then
    ui_photomode_shared.logDebug("NodeGrabber_getFixedNodesVisible failed: " .. tostring(value))
    return nil
  end

  return value == true
end

local function applyNodeGrabberFixedNodesVisible(visible)
  if not hasNodeGrabberVisibilityApi() then
    return false, "nodegrabber_unavailable"
  end

  visible = ui_photomode_shared.normalizeBoolean(visible, false)

  local setter = Engine.NodeGrabber_setFixedNodesVisible

  -- Most existing photomode code calls it as Engine.NodeGrabber_setFixedNodesVisible(value).
  local ok, err = pcall(setter, visible)
  if not ok then
    -- Fallback in case this runtime exposes it as a method-style binding.
    local okMethod, methodErr = pcall(setter, Engine, visible)
    if not okMethod then
      log("E", logTag, "NodeGrabber_setFixedNodesVisible failed: " .. tostring(err) .. " / " .. tostring(methodErr))
      return false, "nodegrabber_set_failed"
    end
  end

  ui_photomode_shared.S.nodeGrabberVisible = visible
  return true
end

local function captureNodeGrabberRestoreState()
  local currentVisible = readNodeGrabberFixedNodesVisible()

  -- If there is no getter, match old photomode behavior:
  -- hide on enter, show again on exit.
  if currentVisible == nil then
    currentVisible = true
  end

  ui_photomode_shared.S.sessionNodeGrabberRestoreState = currentVisible

  if hasNodeGrabberVisibilityApi() then
    applyNodeGrabberFixedNodesVisible(false)
  end
end

local function restoreNodeGrabberState()
  if ui_photomode_shared.S.sessionNodeGrabberRestoreState == nil then
    return
  end

  local restoreValue = ui_photomode_shared.S.sessionNodeGrabberRestoreState
  ui_photomode_shared.S.sessionNodeGrabberRestoreState = nil

  local ok, reason = applyNodeGrabberFixedNodesVisible(restoreValue)
  if not ok then
    ui_photomode_shared.logDebug("restoreNodeGrabberState skipped: " .. tostring(reason))
  end
end


local function captureCameraRestoreState()
  local cameraAngles = readCameraAngles()
  local exposureState = captureCameraExposureState()

  ui_photomode_shared.S.sessionCameraRestoreState = {
    pos = readSerializableCameraPosition(),
    rot = readSerializableCameraRotation(),
    fov = readRawCameraFov(),
    speed = readRawCameraSpeed(),
    rollDeg = tonumber(cameraAngles.rollDeg) or CAMERA_DEFAULTS.rollDeg,
    smoothMovement = readCameraSmoothMovement(),
    autoExposure = exposureState.autoExposure,
    manualEV = exposureState.manualEV,
    entryCameraName = readActiveCameraName(),
    restoreEntryCameraOnExit = false,
  }
end

local function activateSessionFreeCamera()
  if not ui_photomode_shared.S.sessionCameraRestoreState then
    return
  end
  if ui_photomode_shared.S.sessionCameraRestoreState.entryCameraName == "path" or isFreeCameraActive() then
    return
  end
  if not commands or type(commands.setFreeCamera) ~= "function" then
    return
  end
  local ok, err = pcall(commands.setFreeCamera)
  if not ok then
    log("E", logTag, "activateSessionFreeCamera failed: " .. tostring(err))
    return
  end
  if isFreeCameraActive() then
    ui_photomode_shared.S.sessionCameraRestoreState.restoreEntryCameraOnExit = true
  end
end

local function applyCameraFov(fov)
  local setFOV = ui_photomode_shared.getCoreCameraFunction("setFOV")
  if not setFOV then
    return false, "camera_api_unavailable"
  end
  local cameraTargetId = isFreeCameraActive() and 0 or readPlayerVehicleId()
  if cameraTargetId == nil then
    return false, "camera_api_unavailable"
  end
  local ok, err = pcall(setFOV, cameraTargetId, fov)
  if not ok then
    log("E", logTag, "setCameraFov failed: " .. tostring(err))
    return false, "camera_set_failed"
  end
  return true
end

local function applyCameraSpeed(speed)
  local setSpeed = ui_photomode_shared.getCoreCameraFunction("setSpeed")
  if not setSpeed then
    return false, "camera_api_unavailable"
  end
  local ok, err = pcall(setSpeed, speed)
  if not ok then
    log("E", logTag, "setCameraSpeed failed: " .. tostring(err))
    return false, "camera_set_failed"
  end
  return true
end

local function applyCameraRoll(rollDeg)
  if not isFreeCameraActive() then
    return false, "camera_mode_unsupported"
  end

  local setFreeCameraYawPitchRollDeg = ui_photomode_shared.getCoreCameraFunction("setFreeCameraYawPitchRollDeg")
  if not setFreeCameraYawPitchRollDeg then
    return false, "camera_api_unavailable"
  end

  local cameraAngles = readCameraAngles()
  local ok, err = pcall(
    setFreeCameraYawPitchRollDeg,
    cameraAngles.yawDeg,
    cameraAngles.pitchDown,
    rollDeg
  )
  if not ok then
    log("E", logTag, "setCameraRoll failed: " .. tostring(err))
    return false, "camera_set_failed"
  end

  return true
end

local function restoreCameraMode(restoreState)
  if not restoreState or restoreState.restoreEntryCameraOnExit ~= true then
    return
  end
  local entryCameraName = restoreState.entryCameraName
  if entryCameraName == nil or entryCameraName == "path" then
    return
  end

  if entryCameraName == "free" then
    if not commands or type(commands.setFreeCamera) ~= "function" then
      return
    end
    local ok, err = pcall(commands.setFreeCamera)
    if not ok then
      log("E", logTag, "restoreCameraMode free failed: " .. tostring(err))
    end
    return
  end

  local setByName = ui_photomode_shared.getCoreCameraFunction("setByName")
  if not setByName then
    return
  end
  local ok, err = pcall(setByName, 0, entryCameraName, false)
  if not ok then
    log("E", logTag, "restoreCameraMode failed: " .. tostring(err))
  end
end

local function ensureFreeCameraForTransform()
  local activeCameraName = readActiveCameraName()
  if activeCameraName == "path" then
    return false, "camera_mode_unsupported"
  end
  if isFreeCameraActive() then
    return true
  end
  if not commands or type(commands.setFreeCamera) ~= "function" then
    return false, "camera_api_unavailable"
  end
  local ok, err = pcall(commands.setFreeCamera)
  if not ok then
    log("E", logTag, "ensureFreeCameraForTransform failed: " .. tostring(err))
    return false, "camera_set_failed"
  end
  if isFreeCameraActive() then
    return true
  end
  return false, "camera_mode_switch_failed"
end

local function readBookmarkVector3(value)
  if type(value) ~= "table" then
    return nil
  end
  local x = tonumber(value.x)
  local y = tonumber(value.y)
  local z = tonumber(value.z)
  if x == nil or y == nil or z == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = z,
  }
end

local function readBookmarkQuaternion(value)
  if type(value) ~= "table" then
    return nil
  end
  local x = tonumber(value.x)
  local y = tonumber(value.y)
  local z = tonumber(value.z)
  local w = tonumber(value.w)
  if x == nil or y == nil or z == nil or w == nil then
    return nil
  end
  return {
    x = x,
    y = y,
    z = z,
    w = w,
  }
end

local function getBookmarkCameraData(bookmark)
  if type(bookmark) ~= "table" then
    return nil
  end
  if type(bookmark.camera) == "table" then
    return bookmark.camera
  end
  return bookmark
end

local function isRelativeFreeCameraBookmarkValid(bookmark)
  local bookmarkCamera = getBookmarkCameraData(bookmark)
  if type(bookmarkCamera) ~= "table" then
    return false
  end
  if bookmarkCamera.mode ~= "relativeFreecam" then
    return false
  end
  if not readBookmarkVector3(bookmarkCamera.offset) then
    return false
  end
  if not readBookmarkQuaternion(bookmarkCamera.rotOffset) then
    return false
  end
  return tonumber(bookmarkCamera.fov) ~= nil
end

local function restoreCameraState()
  if not ui_photomode_shared.S.sessionCameraRestoreState then
    return
  end

  local restoreState = ui_photomode_shared.S.sessionCameraRestoreState
  ui_photomode_shared.S.sessionCameraRestoreState = nil

  if restoreState.fov ~= nil then
    local ok, reason = applyCameraFov(restoreState.fov)
    if not ok then
      ui_photomode_shared.logDebug("restoreCameraState fov restore skipped: " .. tostring(reason))
    end
  end

  if restoreState.speed ~= nil then
    local ok, reason = applyCameraSpeed(restoreState.speed)
    if not ok then
      ui_photomode_shared.logDebug("restoreCameraState speed restore skipped: " .. tostring(reason))
    end
  end

  if restoreState.rollDeg ~= nil then
    applyCameraRoll(restoreState.rollDeg)
  end

  if restoreState.smoothMovement ~= nil then
    applyCameraSmoothMovement(restoreState.smoothMovement)
  end

  if restoreState.autoExposure ~= nil or restoreState.manualEV ~= nil then
    local exposurePatch = {}

    if restoreState.autoExposure ~= nil then
      exposurePatch.autoExposure = restoreState.autoExposure
    end

    if restoreState.manualEV ~= nil then
      exposurePatch.manualEV = restoreState.manualEV
    end

    applyCameraExposureStatePatch(exposurePatch)
  end

  restoreCameraMode(restoreState)

end

local function buildCameraState()
  local cameraAngles = readCameraAngles()
  local exposureState = captureCameraExposureState()
  local smoothMovement = readCameraSmoothMovement()
  local nodeGrabberVisible = readNodeGrabberFixedNodesVisible()
  if nodeGrabberVisible == nil then
    nodeGrabberVisible = ui_photomode_shared.S.nodeGrabberVisible == true
  end

  return {
    sessionActive = ui_photomode_shared.S.sessionActive == true,
    bookmarkAvailable = ui_photomode_shared.S.savedCameraBookmark ~= nil,
    freeBookmarkAvailable = ui_photomode_shared.S.savedCameraBookmark ~= nil,
    relativeBookmarkAvailable = isRelativeFreeCameraBookmarkValid(ui_photomode_shared.S.savedRelativeCameraBookmark),
    availability = {
      exposure = exposureState.autoExposure ~= nil or exposureState.manualEV ~= nil,
      nodeGrabber = hasNodeGrabberVisibilityApi(),
      smoothMovement = smoothMovement ~= nil,
    },
    pos = readSerializableCameraPosition(),
    rot = readSerializableCameraRotation(),
    fov = normalizeCameraFov(readRawCameraFov()),
    speed = normalizeCameraSpeed(readRawCameraSpeed()),
    yawDeg = cameraAngles.yawDeg,
    pitchDown = cameraAngles.pitchDown,
    rollDeg = normalizeCameraRoll(cameraAngles.rollDeg),
    autoExposure = exposureState.autoExposure,
    manualEV = exposureState.manualEV ~= nil and normalizeCameraManualEV(exposureState.manualEV) or nil,
    nodeGrabberVisible = nodeGrabberVisible,
    smoothMovement = smoothMovement,
  }
end

local function buildPhotomodeMetadataCameraState()
  local cameraState = buildCameraState()
  return {
    pos = cameraState.pos,
    rot = cameraState.rot,
    fov = cameraState.fov,
    speed = cameraState.speed,
    yawDeg = cameraState.yawDeg,
    pitchDown = cameraState.pitchDown,
    rollDeg = cameraState.rollDeg,
  }
end

local function restoreSessionCameraTransformState()
  local restoreState = ui_photomode_shared.S.sessionCameraRestoreState
  if type(restoreState) ~= "table" then
    return {
      ok = false,
      reason = "session_camera_restore_unavailable",
    }
  end

  local pos = readBookmarkVector3(restoreState.pos)
  local rot = readBookmarkQuaternion(restoreState.rot)
  if not pos or not rot then
    return {
      ok = false,
      reason = "session_camera_restore_invalid",
    }
  end

  local freeCameraOk, freeCameraReason = ensureFreeCameraForTransform()
  if not freeCameraOk then
    return {
      ok = false,
      reason = freeCameraReason or "camera_mode_unsupported",
    }
  end

  local setPosRot = ui_photomode_shared.getCoreCameraFunction("setPosRot")
  if not setPosRot then
    return {
      ok = false,
      reason = "camera_api_unavailable",
    }
  end

  local ok, err = pcall(setPosRot, 0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  if not ok then
    log("E", logTag, "restoreSessionCameraTransformState setPosRot failed: " .. tostring(err))
    return {
      ok = false,
      reason = "camera_set_failed",
    }
  end

  if restoreState.fov ~= nil then
    local fovOk, fovReason = applyCameraFov(normalizeCameraFov(restoreState.fov))
    if not fovOk then
      return {
        ok = false,
        reason = fovReason or "camera_set_failed",
      }
    end
  end

  return {
    state = buildCameraState(),
  }
end

local function buildCurrentCameraBookmark()
  local pos = readSerializableCameraPosition()
  local rot = readSerializableCameraRotation()
  if not pos or not rot then
    return nil
  end

  local cameraAngles = readCameraAngles()
  return {
    id = "saved",
    label = "Saved camera",
    camera = {
      mode = "absolute",
      pos = pos,
      rot = rot,
      fov = normalizeCameraFov(readRawCameraFov()),
      rollDeg = normalizeCameraRoll(cameraAngles.rollDeg),
    },
  }
end

local function captureSavedCameraBookmark()
  local worldBookmark = buildCurrentCameraBookmark()
  if not worldBookmark then
    ui_photomode_shared.logDebug("saved camera bookmark capture skipped")
    return false
  end

  ui_photomode_shared.S.savedCameraBookmark = worldBookmark
  local relativeBookmark = buildRelativeFreeCameraBookmark()
  if relativeBookmark then
    ui_photomode_shared.S.savedRelativeCameraBookmark = {
      id = "savedRelative",
      label = "Saved relative camera",
      camera = relativeBookmark,
    }
  else
    ui_photomode_shared.S.savedRelativeCameraBookmark = nil
  end

  return true
end


function M.saveCurrentCameraBookmark()
  if not captureSavedCameraBookmark() then
    return {
      ok = false,
      reason = "camera_state_unavailable",
      state = buildCameraState(),
    }
  end

  return {
    state = buildCameraState(),
  }
end


function M.setCameraFov(value)
  local fov = normalizeCameraFov(value)
  local ok, reason = applyCameraFov(fov)
  if not ok then
    return {
      ok = false,
      reason = reason or "camera_set_failed",
      value = fov,
    }
  end

  return {
    value = fov,
  }
end

function M.setCameraExposureState(partialState)
  if type(partialState) ~= "table" then
    return {
      ok = false,
      reason = "camera_exposure_state_invalid",
      state = buildCameraState(),
    }
  end

  local ok, reason = applyCameraExposureStatePatch(partialState)
  if not ok then
    return {
      ok = false,
      reason = reason or "camera_exposure_set_failed",
      state = buildCameraState(),
    }
  end

  return {
    state = buildCameraState(),
  }
end

function M.setCameraSpeed(value)
  local speed = normalizeCameraSpeed(value)
  local ok, reason = applyCameraSpeed(speed)
  if not ok then
    return {
      ok = false,
      reason = reason or "camera_set_failed",
      value = speed,
    }
  end

  return {
    value = speed,
  }
end

function M.setCameraRoll(value)
  local rollDeg = normalizeCameraRoll(value)
  local ok, reason = applyCameraRoll(rollDeg)
  if not ok then
    return {
      ok = false,
      reason = reason or "camera_set_failed",
      value = rollDeg,
    }
  end

  return {
    value = rollDeg,
  }
end

function M.restoreCameraBookmark(bookmark)
  local bookmarkCamera = getBookmarkCameraData(bookmark)
  local relativeOffset = readBookmarkVector3(bookmarkCamera and bookmarkCamera.offset)
  local relativeRotationOffset = readBookmarkQuaternion(bookmarkCamera and bookmarkCamera.rotOffset)
  if (bookmarkCamera and bookmarkCamera.mode == "relativeFreecam") or (relativeOffset and relativeRotationOffset) then
    local fov = tonumber(bookmarkCamera and bookmarkCamera.fov)
    local vehicleReference = readCurrentVehicleCameraReference()
    if not relativeOffset or not relativeRotationOffset or fov == nil then
      return {
        ok = false,
        reason = "bookmark_invalid",
      }
    end

    local freeCameraOk, freeCameraReason = ensureFreeCameraForTransform()
    if not freeCameraOk then
      return {
        ok = false,
        reason = freeCameraReason or "camera_mode_unsupported",
      }
    end

    if not vehicleReference then
      return {
        ok = false,
        reason = "vehicle_unavailable",
      }
    end
    local setPosRot = ui_photomode_shared.getCoreCameraFunction("setPosRot")
    if not setPosRot then
      return {
        ok = false,
        reason = "camera_api_unavailable",
      }
    end

    local finalPos = vehicleReference.position
      + vehicleReference.axisX * relativeOffset.x
      + vehicleReference.axisY * relativeOffset.y
      + vehicleReference.axisZ * relativeOffset.z
    local finalRot = quat(
      relativeRotationOffset.x,
      relativeRotationOffset.y,
      relativeRotationOffset.z,
      relativeRotationOffset.w
    ) * vehicleReference.rotation

    local ok, err = pcall(setPosRot, 0, finalPos.x, finalPos.y, finalPos.z, finalRot.x, finalRot.y, finalRot.z, finalRot.w)
    if not ok then
      log("E", logTag, "restoreCameraBookmark relative setPosRot failed: " .. tostring(err))
      return {
        ok = false,
        reason = "camera_set_failed",
      }
    end

    fov = normalizeCameraFov(fov)
    local fovOk, fovReason = applyCameraFov(fov)
    if not fovOk then
      return {
        ok = false,
        reason = fovReason or "camera_set_failed",
      }
    end

    return {
      state = buildCameraState(),
    }
  end

  local pos = readBookmarkVector3(bookmarkCamera and bookmarkCamera.pos)
  local rot = readBookmarkQuaternion(bookmarkCamera and bookmarkCamera.rot)
  local fov = tonumber(bookmarkCamera and bookmarkCamera.fov)
  local rollDeg = tonumber(bookmarkCamera and bookmarkCamera.rollDeg)
  if not pos or not rot then
    return {
      ok = false,
      reason = "bookmark_invalid",
    }
  end

  local freeCameraOk, freeCameraReason = ensureFreeCameraForTransform()
  if not freeCameraOk then
    return {
      ok = false,
      reason = freeCameraReason or "camera_mode_unsupported",
    }
  end

  local setPosRot = ui_photomode_shared.getCoreCameraFunction("setPosRot")
  if not setPosRot then
    return {
      ok = false,
      reason = "camera_api_unavailable",
    }
  end

  local ok, err = pcall(setPosRot, 0, pos.x, pos.y, pos.z, rot.x, rot.y, rot.z, rot.w)
  if not ok then
    log("E", logTag, "restoreCameraBookmark setPosRot failed: " .. tostring(err))
    return {
      ok = false,
      reason = "camera_set_failed",
    }
  end

  if fov ~= nil then
    fov = normalizeCameraFov(fov)
    local fovOk, fovReason = applyCameraFov(fov)
    if not fovOk then
      return {
        ok = false,
        reason = fovReason or "camera_set_failed",
      }
    end
  end

  if rollDeg ~= nil then
    rollDeg = normalizeCameraRoll(rollDeg)
    local rollOk, rollReason = applyCameraRoll(rollDeg)
    if not rollOk then
      return {
        ok = false,
        reason = rollReason or "camera_set_failed",
      }
    end
  end

  return {
    state = buildCameraState(),
  }
end

function M.restoreSavedFreeCameraBookmark()
  if not ui_photomode_shared.S.savedCameraBookmark then
    return {
      ok = false,
      reason = "bookmark_unavailable",
    }
  end

  return M.restoreCameraBookmark(ui_photomode_shared.S.savedCameraBookmark)
end

function M.restoreSavedRelativeCameraBookmark()
  if not isRelativeFreeCameraBookmarkValid(ui_photomode_shared.S.savedRelativeCameraBookmark) then
    ui_photomode_shared.S.savedRelativeCameraBookmark = nil
    return {
      ok = false,
      reason = "bookmark_unavailable",
    }
  end

  return M.restoreCameraBookmark(ui_photomode_shared.S.savedRelativeCameraBookmark)
end

function M.resetCameraDefaults()
  applyCameraSmoothMovement(false)

  local speedOk, speedReason = applyCameraSpeed(CAMERA_DEFAULTS.speed)
  if not speedOk then
    return {
      ok = false,
      reason = speedReason or "camera_set_failed",
    }
  end

  local rollOk, rollReason = applyCameraRoll(CAMERA_DEFAULTS.rollDeg)
  if not rollOk then
    return {
      ok = false,
      reason = rollReason or "camera_set_failed",
    }
  end

  local freeCameraOk, freeCameraReason = ensureFreeCameraForTransform()
  if not freeCameraOk then
    return {
      ok = false,
      reason = freeCameraReason or "camera_mode_unsupported",
    }
  end

  applyCameraExposureStatePatch({
    autoExposure = CAMERA_EXPOSURE_DEFAULTS.autoExposure,
    manualEV = CAMERA_EXPOSURE_DEFAULTS.manualEV,
  })

  return {
    state = buildCameraState(),
  }
end

function M.getCameraState()
  return buildCameraState()
end

function M.capturePresetState(options)
  options = type(options) == "table" and options or {}
  local presetType = options.cameraPresetType == "vehicle" and "vehicle" or "scene"
  local state = buildCameraState()

  local camera = nil
  if presetType == "vehicle" then
    camera = buildRelativeFreeCameraBookmark()
    if not camera then
      return nil
    end
  else
    camera = {
      mode = "absolute",
      pos = state.pos,
      rot = state.rot,
      fov = state.fov,
      rollDeg = state.rollDeg,
    }
  end

  local out = {
    cameraPresetType = presetType,
    camera = camera,
    speed = state.speed,
    smoothMovement = state.smoothMovement,
    autoExposure = state.autoExposure,
    manualEV = state.manualEV,
  }

  if presetType == "scene" then
    out.levelId = getCurrentLevelId()
  end

  return out
end

function M.captureDefaultPresetState()
  local state = ui_photomode_shared.S.sessionCameraRestoreState
  if type(state) ~= "table" then
    return nil
  end

  return {
    cameraPresetType = "scene",
    levelId = getCurrentLevelId(),
    fov = state.fov ~= nil and normalizeCameraFov(state.fov) or nil,
    rollDeg = state.rollDeg ~= nil and normalizeCameraRoll(state.rollDeg) or nil,
    speed = state.speed ~= nil and normalizeCameraSpeed(state.speed) or nil,
    smoothMovement = state.smoothMovement,
    autoExposure = state.autoExposure,
    manualEV = state.manualEV ~= nil and normalizeCameraManualEV(state.manualEV) or nil,
  }
end

function M.applyPresetState(state)
  local cameraState = type(state) == "table" and state or {}
  if cameraState.cameraPresetType == "scene" and cameraState.levelId and cameraState.levelId ~= getCurrentLevelId() then
    return { ok = false, reason = "preset_level_mismatch" }
  end

  local bookmark = cameraState.camera or cameraState
  if type(bookmark) == "table"
    and (
      bookmark.pos ~= nil
        or bookmark.rot ~= nil
        or bookmark.offset ~= nil
        or bookmark.rotOffset ~= nil
    )
  then
    local bookmarkResult = M.restoreCameraBookmark(bookmark)
    if bookmarkResult and bookmarkResult.ok == false then
      return bookmarkResult
    end
  else
    if cameraState.fov ~= nil then
      local ok, reason = applyCameraFov(normalizeCameraFov(cameraState.fov))
      if not ok then
        return { ok = false, reason = reason or "camera_set_failed" }
      end
    end

    if cameraState.rollDeg ~= nil then
      local ok, reason = applyCameraRoll(normalizeCameraRoll(cameraState.rollDeg))
      if not ok then
        return { ok = false, reason = reason or "camera_set_failed" }
      end
    end
  end

  if cameraState.speed ~= nil then
    local ok, reason = applyCameraSpeed(normalizeCameraSpeed(cameraState.speed))
    if not ok then
      return { ok = false, reason = reason or "camera_set_failed" }
    end
  end

  if cameraState.smoothMovement ~= nil then
    applyCameraSmoothMovement(cameraState.smoothMovement)
  end

  if cameraState.autoExposure ~= nil or cameraState.manualEV ~= nil then
    applyCameraExposureStatePatch({
      autoExposure = cameraState.autoExposure,
      manualEV = cameraState.manualEV,
    })
  end

  return { state = buildCameraState() }
end

local function buildCameraBookmarkPreset(bookmark, index)
  local pos = bookmark and bookmark.getPosition and bookmark:getPosition() or nil
  local rot = bookmark and bookmark.getRotation and bookmark:getRotation() or nil
  local serializedPos = serializeVector3(pos)
  local serializedRot = serializeQuaternion(rot)
  if not serializedPos or not serializedRot then
    return nil
  end

  local name = bookmark.getInternalName and bookmark:getInternalName() or ""
  if name == "" then
    name = "Camera bookmark " .. tostring(index)
  end

  return {
    id = "__cameraBookmark_" .. tostring(bookmark:getID()),
    type = "camera",
    version = 1,
    name = name,
    temporary = true,
    source = "cameraBookmark",
    data = {
      cameraPresetType = "scene",
      levelId = getCurrentLevelId(),
      camera = {
        mode = "absolute",
        pos = serializedPos,
        rot = serializedRot,
      },
    },
  }
end

function M.getTemporaryPresetList()
  if not scenetree or type(scenetree.findClassObjects) ~= "function" or type(scenetree.findObject) ~= "function" then
    return {}
  end

  local presets = {}
  for index, id in ipairs(scenetree.findClassObjects("CameraBookmark") or {}) do
    local preset = buildCameraBookmarkPreset(scenetree.findObject(id), index)
    if preset then
      presets[#presets + 1] = preset
    end
  end
  return presets
end

function M.setNodeGrabberVisible(value)
  if type(value) == "table" then
    value = value.nodeGrabberVisible
  end

  local ok, reason = applyNodeGrabberFixedNodesVisible(value)
  if not ok then
    return {
      ok = false,
      reason = reason or "nodegrabber_set_failed",
      state = buildCameraState(),
    }
  end

  return {
    value = ui_photomode_shared.normalizeBoolean(value, false),
    state = buildCameraState(),
  }
end

function M.setCameraSmoothMovement(value)
  if type(value) == "table" then
    value = value.smoothMovement
  end

  local ok, reason = applyCameraSmoothMovement(value)
  if not ok then
    return {
      ok = false,
      reason = reason or "camera_smooth_movement_set_failed",
      state = buildCameraState(),
    }
  end

  return {
    value = ui_photomode_shared.normalizeBoolean(value, false),
    state = buildCameraState(),
  }
end


M.captureRestoreState = captureCameraRestoreState
M.activateSessionFreeCamera = activateSessionFreeCamera
M.restoreSessionCameraTransformState = restoreSessionCameraTransformState
M.restoreState = restoreCameraState
M.captureNodeGrabberRestoreState = captureNodeGrabberRestoreState
M.restoreNodeGrabberState = restoreNodeGrabberState
M.buildState = buildCameraState
M.buildMetadataState = buildPhotomodeMetadataCameraState

return M
