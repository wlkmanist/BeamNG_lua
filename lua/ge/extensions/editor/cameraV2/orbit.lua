-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Provides editor-style mouse looking: either rotate from the camera's current
-- position or circle around the surface at the center of the view. Orbiting is
-- constrained so it cannot pull the camera below the terrain.

local M = {}

local im = ui_imgui
local validation = require("editor/cameraV2/validation")
local orbit = nil
local rotateInPlace = nil
local orbitRayDistance = 100000
local orbitFallbackDistance = 50
local lastOrbitDistance = orbitFallbackDistance
local velocityBlend = 0.35
local deltaTimeBlend = 0.1
local inputWarpThreshold = 250
local maximumAngularVelocity = math.rad(900)
local angularVelocityCutoff = math.rad(0.01)

local function inputAvailable(mouseButton)
  return im.IsMouseDown(mouseButton)
    and not im.GetIO().WantCaptureMouse
    and editor.isViewportHovered()
end

local function newOrbitDrag(yaw, pitch)
  return {
    targetYaw = yaw,
    desiredPitch = pitch,
    yawInput = 0,
    pitchInput = 0,
    yawVelocity = 0,
    pitchVelocity = 0,
    smoothedDeltaTime = 0
  }
end

local function orbitLimits()
  local minimum = math.max(
    editor.getPreference("camera.cameraV2.zoomMinDistance") or 0.25,
    0.0001)
  local maximum = clamp(
    editor.getPreference("camera.cameraV2.zoomMaxDistance") or 2500,
    minimum,
    2500)
  return minimum, maximum
end

local function cameraForward()
  local forward = core_camera.getQuat() * vec3(0, 1, 0)
  if forward:length() > 0.0001 then forward:normalize() end
  return forward
end

local function centerRayPivot(cameraPosition, forward)
  local hit = Engine.castRay(
    cameraPosition,
    cameraPosition + forward * orbitRayDistance,
    true,
    true)
  return hit
    and hit.pt
    and validation.isPointOnRaySegment(
      hit.pt,
      cameraPosition,
      forward,
      orbitRayDistance)
    and vec3(hit.pt)
    or nil
end

local function setOrbitGeometry(interaction, cameraPosition, pivot)
  local offset = cameraPosition - pivot
  local distance = offset:length()
  if not validation.isFinite(distance) or distance <= 0.0001 then return false end
  interaction.pivot = vec3(pivot)
  interaction.distance = distance
  interaction.yaw = math.atan2(offset.x, -offset.y)
  interaction.pitch = -math.asin(clamp(offset.z / offset:length(), -1, 1))
  interaction.expectedPosition = vec3(cameraPosition)
  interaction.expectedRotation = quat(core_camera.getQuat())
  interaction.terrainLimited = false
  lastOrbitDistance = distance
  return true
end

local function initializeOrbitPose()
  local cameraPosition = vec3(core_camera.getPosition())
  if not validation.isReasonablePoint(cameraPosition) then return end
  local forward = cameraForward()
  if forward:length() <= 0.0001 then return end
  local centerPivot = centerRayPivot(cameraPosition, forward)
  local minimum, maximum = orbitLimits()
  local pivot = centerPivot
    or cameraPosition + forward * clamp(lastOrbitDistance, minimum, maximum)
  core_camera.clearInputs()
  if core_camera.clearAngularMotion then
    core_camera.clearAngularMotion(0)
  elseif core_camera.clearMotion then
    core_camera.clearMotion(0)
  end
  orbit = {
    source = centerPivot and "center hit" or "virtual",
    drag = nil,
    inertia = nil,
    reacquirePending = false
  }
  if not setOrbitGeometry(orbit, cameraPosition, pivot) then
    orbit = nil
  end
end

local function beginOrbitDrag()
  if orbit and orbit.reacquirePending then
    orbit = nil
  end
  if not orbit then initializeOrbitPose() end
  if not orbit then return false end
  if orbit.source == "virtual" then
    local cameraPosition = vec3(core_camera.getPosition())
    local forward = cameraForward()
    local pivot = forward:length() > 0.0001
      and centerRayPivot(cameraPosition, forward)
      or nil
    if pivot and setOrbitGeometry(orbit, cameraPosition, pivot) then
      orbit.source = "center hit"
    end
  end
  orbit.inertia = nil
  orbit.drag = newOrbitDrag(orbit.yaw, orbit.pitch)
  return true
end

local function beginRotateInPlace()
  local forward = core_camera.getQuat() * vec3(0, 1, 0)
  if forward:length() <= 0.0001 then return end
  forward:normalize()
  core_camera.clearInputs()
  if core_camera.clearAngularMotion then
    core_camera.clearAngularMotion(0)
  elseif core_camera.clearMotion then
    core_camera.clearMotion(0)
  end
  rotateInPlace = {
    yaw = math.atan2(forward.x, forward.y),
    pitch = math.asin(clamp(forward.z, -1, 1)),
    targetYaw = math.atan2(forward.x, forward.y),
    targetPitch = math.asin(clamp(forward.z, -1, 1)),
    yawInput = 0,
    pitchInput = 0,
    yawVelocity = 0,
    pitchVelocity = 0,
    smoothedDeltaTime = 0,
    coasting = false
  }
end

local function orbitPosition(yaw, pitch)
  local cosPitch = math.cos(pitch)
  return orbit.pivot + vec3(
    math.sin(yaw) * cosPitch,
    -math.cos(yaw) * cosPitch,
    -math.sin(pitch)) * orbit.distance
end

local function reconcileOrbitTranslation()
  local cameraPosition = vec3(core_camera.getPosition())
  local cameraRotation = core_camera.getQuat()
  if not validation.isReasonablePoint(cameraPosition)
    or not validation.isReasonablePoint(orbit.expectedPosition)
    or not validation.isValidQuaternion(cameraRotation)
    or not validation.isValidQuaternion(orbit.expectedRotation) then
    return false
  end
  if math.abs(cameraRotation:dot(orbit.expectedRotation)) < 0.99999 then
    local forward = cameraRotation * vec3(0, 1, 0)
    if forward:length() <= 0.0001 then return false end
    forward:normalize()
    local centerPivot = centerRayPivot(cameraPosition, forward)
    local pivot = centerPivot or cameraPosition + forward * orbit.distance
    orbit.source = centerPivot and "center hit" or "virtual"
    orbit.drag = nil
    orbit.inertia = nil
    return setOrbitGeometry(orbit, cameraPosition, pivot)
  end
  local pivot = orbit.pivot + cameraPosition - orbit.expectedPosition
  if not validation.isReasonablePoint(pivot) then return false end
  orbit.pivot = pivot
  orbit.expectedPosition = cameraPosition
  orbit.expectedRotation = quat(cameraRotation)
  return true
end

local function isOrbitPositionSafe(position)
  if not validation.isReasonablePoint(position) then return false end
  local terrainHeight = validation.terrainHeightAt(position)
  local minimumDistance = math.max(
    editor.getPreference("camera.cameraV2.zoomMinDistance") or 0.25,
    0.01)
  return not terrainHeight or position.z >= terrainHeight + minimumDistance
end

local function safePitchAtYaw(yaw, desiredPitch)
  local desiredPosition = orbitPosition(yaw, desiredPitch)
  if isOrbitPositionSafe(desiredPosition) then
    return desiredPitch, desiredPosition, false
  end

  local safePitch = math.rad(-85)
  local safePosition = orbitPosition(yaw, safePitch)
  if not isOrbitPositionSafe(safePosition) then return nil end
  local unsafePitch = desiredPitch
  for _ = 1, 12 do
    local middlePitch = (safePitch + unsafePitch) * 0.5
    local middlePosition = orbitPosition(yaw, middlePitch)
    if isOrbitPositionSafe(middlePosition) then
      safePitch = middlePitch
      safePosition = middlePosition
    else
      unsafePitch = middlePitch
    end
  end
  return safePitch, safePosition, true
end

local function velocityDeltaTime(interaction, deltaTime)
  if deltaTime > 0 then
    interaction.smoothedDeltaTime = interaction.smoothedDeltaTime > 0
      and interaction.smoothedDeltaTime
        + (deltaTime - interaction.smoothedDeltaTime) * deltaTimeBlend
      or deltaTime
  end
  return interaction.smoothedDeltaTime > 0.0001
    and interaction.smoothedDeltaTime
    or 0.016
end

local function trackAngularVelocity(interaction, yawDelta, pitchDelta, deltaTime)
  local estimateDeltaTime = velocityDeltaTime(interaction, deltaTime)
  local yawVelocity = clamp(
    yawDelta / estimateDeltaTime,
    -maximumAngularVelocity,
    maximumAngularVelocity)
  local pitchVelocity = clamp(
    pitchDelta / estimateDeltaTime,
    -maximumAngularVelocity,
    maximumAngularVelocity)
  interaction.yawVelocity = interaction.yawVelocity
    + (yawVelocity - interaction.yawVelocity) * velocityBlend
  interaction.pitchVelocity = interaction.pitchVelocity
    + (pitchVelocity - interaction.pitchVelocity) * velocityBlend
end

local function decayAngularVelocity(interaction, deltaTime)
  local duration = clamp(
    editor.getPreference("camera.cameraV2.inertiaDuration") or 0.35,
    0.05,
    2)
  local decay = math.exp(math.log(0.05) * deltaTime / duration)
  interaction.yawVelocity = interaction.yawVelocity * decay
  interaction.pitchVelocity = interaction.pitchVelocity * decay
  if math.abs(interaction.yawVelocity) < angularVelocityCutoff then
    interaction.yawVelocity = 0
  end
  if math.abs(interaction.pitchVelocity) < angularVelocityCutoff then
    interaction.pitchVelocity = 0
  end
end

local function angularVelocityStopped(interaction)
  return interaction.yawVelocity == 0 and interaction.pitchVelocity == 0
end

function M.onMouseInput(axis, value, mode, mouseButton)
  if not validation.isFinite(value) then return false end
  if not inputAvailable(mouseButton) then return false end
  if math.abs(value) > inputWarpThreshold then return true end
  if im.IsMouseClicked(mouseButton) then
    if mode == 1 then
      return beginOrbitDrag()
    end
    if not rotateInPlace then beginRotateInPlace() end
    return rotateInPlace ~= nil
  end

  local interaction
  if mode == 1 then
    rotateInPlace = nil
    if not orbit or not orbit.drag then beginOrbitDrag() end
    interaction = orbit and orbit.drag
  else
    orbit = nil
    if not rotateInPlace then beginRotateInPlace() end
    interaction = rotateInPlace
  end
  if not interaction then return false end
  local fov = core_camera.getFovDeg()
  if not validation.isFinite(fov) then return false end
  local input = fov * value / 4500
  if axis == "yaw" then
    interaction.yawInput = interaction.yawInput + input
  else
    interaction.pitchInput = interaction.pitchInput + input
  end
  return true
end

local function updateRotateInPlace(buttonDown, deltaTime)
  local interaction = rotateInPlace
  if not interaction then return end
  local previousYaw = interaction.yaw
  local previousPitch = interaction.pitch

  if buttonDown then
    interaction.coasting = false
    interaction.targetYaw = interaction.targetYaw
      + math.rad(interaction.yawInput * 10)
    interaction.targetPitch = clamp(
      interaction.targetPitch + math.rad(interaction.pitchInput * 10),
      math.rad(-85),
      math.rad(85))
    local amount = 1 - math.exp(
      -(editor.getPreference("camera.cameraV2.zoomResponse") or 20) * deltaTime)
    interaction.yaw = interaction.yaw
      + (interaction.targetYaw - interaction.yaw) * amount
    interaction.pitch = interaction.pitch
      + (interaction.targetPitch - interaction.pitch) * amount
  else
    if not interaction.coasting then
      interaction.coasting = true
      interaction.targetYaw = interaction.yaw
      interaction.targetPitch = interaction.pitch
    end
    interaction.yaw = interaction.yaw + interaction.yawVelocity * deltaTime
    local pitch = interaction.pitch + interaction.pitchVelocity * deltaTime
    interaction.pitch = clamp(pitch, math.rad(-85), math.rad(85))
    if interaction.pitch ~= pitch then interaction.pitchVelocity = 0 end
    decayAngularVelocity(interaction, deltaTime)
  end
  interaction.yawInput = 0
  interaction.pitchInput = 0

  local yawDelta = interaction.yaw - previousYaw
  local pitchDelta = interaction.pitch - previousPitch
  if buttonDown then
    trackAngularVelocity(interaction, yawDelta, pitchDelta, deltaTime)
  elseif angularVelocityStopped(interaction) then
    rotateInPlace = nil
  end
  if math.abs(yawDelta) <= 0.000001 and math.abs(pitchDelta) <= 0.000001 then return end

  local cosPitch = math.cos(interaction.pitch)
  local rotation = quatFromDir(vec3(
    math.sin(interaction.yaw) * cosPitch,
    math.cos(interaction.yaw) * cosPitch,
    math.sin(interaction.pitch)))
  if validation.isValidQuaternion(rotation) then
    core_camera.setRotation(0, rotation)
  end
end

local function updateOrbit(buttonDown, deltaTime)
  local interaction = orbit
  if not interaction then return end
  if not reconcileOrbitTranslation() then
    orbit = nil
    return
  end
  if buttonDown and not interaction.drag then
    interaction.inertia = nil
    interaction.drag = newOrbitDrag(interaction.yaw, interaction.pitch)
  elseif not buttonDown and interaction.drag then
    interaction.inertia = {
      yawVelocity = interaction.drag.yawVelocity,
      pitchVelocity = interaction.drag.pitchVelocity
    }
    interaction.drag = nil
  end

  local drag = interaction.drag
  local inertia = interaction.inertia
  if not buttonDown and not inertia then
    return
  end
  local previousYaw = interaction.yaw
  local previousPitch = interaction.pitch
  local previousDesiredPitch = drag and drag.desiredPitch or previousPitch
  local previousTerrainLimited = interaction.terrainLimited
  local proposedYaw
  local proposedDesiredPitch

  if buttonDown then
    drag.targetYaw = drag.targetYaw - math.rad(drag.yawInput * 10)
    local pitchInput = math.rad(drag.pitchInput * 10)
    if not (interaction.terrainLimited and pitchInput > 0) then
      drag.desiredPitch = clamp(
        drag.desiredPitch + pitchInput,
        math.rad(-85),
        math.rad(85))
    end
    local amount = 1 - math.exp(
      -(editor.getPreference("camera.cameraV2.zoomResponse") or 20) * deltaTime)
    proposedYaw = interaction.yaw
      + (drag.targetYaw - interaction.yaw) * amount
    proposedDesiredPitch = interaction.pitch
      + (drag.desiredPitch - interaction.pitch) * amount
  else
    proposedYaw = interaction.yaw + inertia.yawVelocity * deltaTime
    proposedDesiredPitch = clamp(
      interaction.pitch + inertia.pitchVelocity * deltaTime,
      math.rad(-85),
      math.rad(85))
  end
  if drag then
    drag.yawInput = 0
    drag.pitchInput = 0
  end

  local proposedPitch, position, terrainLimited = safePitchAtYaw(
    proposedYaw,
    proposedDesiredPitch)
  if proposedPitch then
    interaction.yaw = proposedYaw
    interaction.pitch = proposedPitch
    interaction.terrainLimited = terrainLimited
  else
    local fallbackPitch, fallbackPosition, fallbackLimited = safePitchAtYaw(
      previousYaw,
      proposedDesiredPitch)
    if not fallbackPitch then
      interaction.terrainLimited = previousTerrainLimited
      if drag then
        drag.desiredPitch = previousDesiredPitch
        drag.targetYaw = previousYaw
        drag.yawVelocity = 0
        drag.pitchVelocity = 0
      elseif inertia then
        inertia.yawVelocity = 0
        inertia.pitchVelocity = 0
      end
      if not buttonDown then interaction.inertia = nil end
      return
    end
    interaction.yaw = previousYaw
    interaction.pitch = fallbackPitch
    interaction.terrainLimited = fallbackLimited
    if drag then
      drag.targetYaw = previousYaw
      drag.yawVelocity = 0
    elseif inertia then
      inertia.yawVelocity = 0
    end
    position = fallbackPosition
  end

  local yawDelta = interaction.yaw - previousYaw
  local pitchDelta = interaction.pitch - previousPitch
  if buttonDown then
    trackAngularVelocity(drag, yawDelta, pitchDelta, deltaTime)
  else
    if interaction.terrainLimited and inertia.pitchVelocity > 0 then
      inertia.pitchVelocity = 0
    end
    decayAngularVelocity(inertia, deltaTime)
  end

  if math.abs(yawDelta) > 0.000001 or math.abs(pitchDelta) > 0.000001 then
    local rotation = quatFromDir(interaction.pivot - position)
    if not validation.isValidQuaternion(rotation)
      or not validation.isReasonablePoint(position) then
      orbit = nil
      return
    end
    core_camera.setPosRot(
      0,
      position.x,
      position.y,
      position.z,
      rotation.x,
      rotation.y,
      rotation.z,
      rotation.w)
    interaction.expectedPosition = vec3(position)
    interaction.expectedRotation = quat(rotation)
  end
  if not buttonDown and angularVelocityStopped(inertia) then
    interaction.inertia = nil
  end
end

function M.update(mode, mouseButton, deltaTime)
  deltaTime = clamp(deltaTime or im.GetIO().DeltaTime or 0, 0, 0.05)
  local buttonDown = im.IsMouseDown(mouseButton)
  if mode ~= 1 then
    if orbit then
      orbit.drag = nil
      orbit.inertia = nil
    end
    if buttonDown then
      updateRotateInPlace(true, deltaTime)
    else
      rotateInPlace = nil
    end
    return
  end
  rotateInPlace = nil
  if buttonDown and (not orbit or not orbit.drag) then beginOrbitDrag() end
  updateOrbit(buttonDown, deltaTime)
end

function M.isActive()
  return orbit and (orbit.drag ~= nil or orbit.inertia ~= nil)
    or rotateInPlace ~= nil
end

function M.isOrbitActive()
  return orbit ~= nil and (orbit.drag ~= nil or orbit.inertia ~= nil)
end

function M.hasPose()
  return orbit ~= nil
end

function M.getPivot()
  return orbit and vec3(orbit.pivot) or nil
end

function M.getZoomPivot()
  return orbit and orbit.source ~= "virtual" and vec3(orbit.pivot) or nil
end

function M.setPivot(pivot, source)
  pivot = pivot and vec3(pivot) or nil
  local cameraPosition = vec3(core_camera.getPosition())
  if not validation.isReasonablePoint(pivot)
    or not validation.isReasonablePoint(cameraPosition) then
    return false
  end
  local interaction = orbit or {}
  if not setOrbitGeometry(interaction, cameraPosition, pivot) then return false end
  interaction.source = source or "focus"
  interaction.drag = nil
  interaction.inertia = nil
  interaction.reacquirePending = false
  orbit = interaction
  return true
end

function M.syncDistanceFromCamera()
  if not orbit then return false end
  local cameraPosition = vec3(core_camera.getPosition())
  if not validation.isReasonablePoint(cameraPosition) then return false end
  local source = orbit.source
  if not setOrbitGeometry(orbit, cameraPosition, orbit.pivot) then return false end
  orbit.source = source
  return true
end

function M.getDebugState()
  return orbit and {
    source = orbit.source,
    distance = orbit.distance,
    pivot = vec3(orbit.pivot),
    moving = orbit.drag ~= nil or orbit.inertia ~= nil
  } or nil
end

function M.markForReacquire()
  if orbit then orbit.reacquirePending = true end
end

function M.cancel()
  if orbit then
    orbit.drag = nil
    orbit.inertia = nil
  end
  rotateInPlace = nil
end

function M.reset()
  orbit = nil
  rotateInPlace = nil
end

return M
