-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Handles mouse input routed to Camera V2 and applies it to the existing free
-- camera. Input capture keeps each gesture on one control path, while inputs
-- Camera V2 does not handle continue through the stock path.

local M = {}

local im = ui_imgui
local canvas = require("client/canvas")
local registry = require("core/cameraControllerRegistry")
local orbit = require("editor/cameraV2/orbit")
local validation = require("editor/cameraV2/validation")
local zoom = require("editor/cameraV2/zoom")

local controllerId = "editor.cameraV2"
local active = false
local panState = nil
local focusTransition = nil
local middleOrbitLocked = false
local pendingWheel = 0
local pivotZoomActive = false
local focusDoubleClickFrame = -1
local focusDoubleClickConsumed = false
local relativeInputSuppressedFrame = -1
local planarPanHitPoint = nil
local planarPanHitDistance = nil
local wasdPanActive = false
local wasdPanCombinedWithOrbit = false
local mouseWarpThreshold = 250
local maximumMousePanVelocity = 4000
local focusMinimumDuration = 0.35
local focusMaximumDuration = 1
local panRayDistance = 100000
local panScaleReferenceDistance = 10

local function preference(name, fallback)
  local value = editor.getPreference("camera.cameraV2." .. name)
  return value == nil and fallback or value
end

local function mouseButtons()
  if preference("swapPanOrbitButtons", true) then return 1, 2 end
  return 2, 1
end

local function freeCameraActive()
  return editor.currentCameraType == editor.CameraType_Free
    and core_camera.getActiveGlobalCameraName() == "free"
end

local function cameraAvailable()
  return active
    and editor
    and editor.active
    and freeCameraActive()
    and editor.isViewportHovered()
    and not im.GetIO().WantCaptureMouse
end

local function cameraPanDistance(cameraPosition, rotation)
  local forward = rotation * vec3(0, 1, 0)
  if forward:length() <= 0.0001 then return math.max(core_camera.getSpeed(), 10) end
  forward:normalize()
  local hit = Engine.castRay(
    cameraPosition,
    cameraPosition + forward * panRayDistance,
    true,
    true)
  local point = hit and hit.pt and vec3(hit.pt) or nil
  return point and (point - cameraPosition):length()
      or math.max(core_camera.getSpeed(), 10),
    point
end

local function updatePlanarTranslationScale()
  planarPanHitPoint = nil
  planarPanHitDistance = nil
  if not core_camera or not core_camera.getGlobalCameras then return end
  local globalCams = core_camera.getGlobalCameras()
  local freeCamera = globalCams.free
  if not freeCamera then return end
  local inertiaDuration = clamp(preference("inertiaDuration", 0.35), 0.05, 2)
  local translationDrag = -math.log(0.05) / inertiaDuration
  local response = preference("zoomResponse", 20)
  freeCamera.planarTranslationDrag = translationDrag
  freeCamera.planarTranslationResponse = response
  if not freeCamera.planarTranslation then return end
  local distance, hitPoint = cameraPanDistance(
    vec3(core_camera.getPosition()),
    core_camera.getQuat())
  planarPanHitPoint = hitPoint
  planarPanHitDistance = hitPoint and distance or nil
  local scale = clamp(distance, 1, 5000) / panScaleReferenceDistance
  local speedMultiplier = clamp(preference("wasdPanSpeedMultiplier", 0.5), 0.05, 5)
  local fastSpeedMultiplier = clamp(
    preference("wasdPanFastSpeedMultiplier", 1.5),
    0.05,
    10)
  freeCamera.planarTranslationScale = scale
  freeCamera.planarTranslationDrag = translationDrag
  freeCamera.planarTranslationSpeedMultiplier = speedMultiplier
  freeCamera.planarTranslationFastSpeedMultiplier = fastSpeedMultiplier
end

local function setMiddleOrbitLocked(locked)
  if middleOrbitLocked == locked then return end
  middleOrbitLocked = locked
  if locked then canvas.hideCursor() else canvas.showCursor() end
end

local function setMousePanInput(velocity, active)
  if not core_camera or not core_camera.getGlobalCameras then return end
  local freeCamera = core_camera.getGlobalCameras().free
  if not freeCamera or not freeCamera.setPlanarTranslationInput then return end
  freeCamera:setPlanarTranslationInput(velocity, active)
end

local function cancelPan()
  setMousePanInput(nil, false)
  panState = nil
end

local function cancelFocusTransition()
  focusTransition = nil
end

local function updatePan(panButton, deltaTime)
  local started = im.IsMouseClicked(panButton)
  if panButton == 1 and im.IsMouseDown(panButton) then canvas.showCursor() end
  if started then
    zoom.cancel()
    orbit.reset()
    cancelFocusTransition()
    if core_camera.clearAngularMotion then
      core_camera.clearAngularMotion(0)
    elseif core_camera.clearMotion then
      core_camera.clearMotion(0)
    end
    local cameraPosition = vec3(core_camera.getPosition())
    local rotation = core_camera.getQuat()
    local distance = planarPanHitDistance
    local hitPoint = planarPanHitPoint
    if not distance then
      distance, hitPoint = cameraPanDistance(cameraPosition, rotation)
    end
    local panRight = rotation * vec3(1, 0, 0)
    panRight.z = 0
    panRight = panRight:length() > 0.0001 and panRight:normalized() or vec3(1, 0, 0)
    local panVertical = rotation * vec3(0, 0, 1)
    panVertical.z = 0
    if panVertical:length() > 0.0001 then
      panVertical:normalize()
    else
      panVertical = rotation * vec3(0, 1, 0)
      panVertical.z = 0
      panVertical = panVertical:length() > 0.0001
        and panVertical:normalized()
        or vec3(0, 1, 0)
    end
    panState = {
      button = panButton,
      right = panRight,
      vertical = panVertical,
      hitPoint = hitPoint,
      hitDistance = hitPoint and distance or nil,
      worldPerPixel = 2 * clamp(distance, 1, 5000)
        * math.tan(core_camera.getFovRad() * 0.5)
        / math.max(im.GetMainViewport().Size.y, 1)
    }
  end

  if not panState or panState.button ~= panButton then return end
  local buttonDown = im.IsMouseDown(panButton)
  if buttonDown then
    local delta = im.GetIO().MouseDelta
    if math.abs(delta.x) > mouseWarpThreshold
      or math.abs(delta.y) > mouseWarpThreshold then
      delta = im.ImVec2(0, 0)
    end
    local displacement =
      - panState.right * delta.x * panState.worldPerPixel
      + panState.vertical * delta.y * panState.worldPerPixel
    local velocity = displacement / math.max(deltaTime, 0.001)
    local speed = velocity:length()
    if speed > maximumMousePanVelocity then
      velocity = velocity * (maximumMousePanVelocity / speed)
    end
    if not validation.isValidPoint(velocity) then
      cancelPan()
      return
    end
    setMousePanInput(velocity, true)
  else
    cancelPan()
  end
end

local function translationRequested()
  return (MoveManager.forward or 0) ~= 0
    or (MoveManager.backward or 0) ~= 0
    or (MoveManager.left or 0) ~= 0
    or (MoveManager.right or 0) ~= 0
    or (MoveManager.up or 0) ~= 0
    or (MoveManager.down or 0) ~= 0
    or (MoveManager.absXAxis or 0) ~= 0
    or (MoveManager.absYAxis or 0) ~= 0
    or (MoveManager.absZAxis or 0) ~= 0
end

local function planarWasdRequested()
  if not translationRequested()
    or not core_camera
    or not core_camera.getGlobalCameras then
    return false
  end
  local freeCamera = core_camera.getGlobalCameras().free
  return freeCamera ~= nil and freeCamera.planarTranslation == true
end

local function updateWasdPanLifecycle()
  local requested = planarWasdRequested()
  if requested and not wasdPanActive then
    wasdPanCombinedWithOrbit = orbit.isOrbitActive()
    if not wasdPanCombinedWithOrbit then orbit.reset() end
  elseif requested and orbit.isOrbitActive() then
    wasdPanCombinedWithOrbit = true
  elseif not requested and wasdPanActive and wasdPanCombinedWithOrbit then
    orbit.markForReacquire()
    wasdPanCombinedWithOrbit = false
  end
  wasdPanActive = requested
end

local function focusDuration(lateralDistance, depth)
  local halfViewHeight = math.max(
    depth * math.tan(core_camera.getFovRad() * 0.5),
    0.001)
  local visualAmount = clamp(lateralDistance / halfViewHeight, 0, 1)
  return lerp(focusMinimumDuration, focusMaximumDuration, smoothstep(visualAmount))
end

local function focusEase(progress)
  local overshoot = 0.8
  local shifted = progress - 1
  return 1
    + (overshoot + 1) * shifted * shifted * shifted
    + overshoot * shifted * shifted
end

local function updateFocusTransition(deltaTime)
  if not focusTransition then return end
  local cameraPosition = vec3(core_camera.getPosition())
  if translationRequested()
    or not validation.isReasonablePoint(cameraPosition)
    or not validation.isReasonablePoint(focusTransition.expectedPosition)
    or (cameraPosition - focusTransition.expectedPosition):length() > 0.001
    or math.abs(core_camera.getQuat():dot(focusTransition.rotation)) < 0.99999 then
    cancelFocusTransition()
    return
  end

  focusTransition.elapsed = focusTransition.elapsed + deltaTime
  local progress = clamp(
    focusTransition.elapsed / focusTransition.duration,
    0,
    1)
  local position = focusTransition.startPosition
    + (focusTransition.targetPosition - focusTransition.startPosition)
      * focusEase(progress)
  if not validation.isReasonablePoint(position) then
    cancelFocusTransition()
    return
  end
  local terrainHeight = validation.terrainHeightAt(position)
  local minimumHeight = math.max(preference("zoomMinDistance", 0.25), 0.01)
  if terrainHeight and position.z < terrainHeight + minimumHeight then
    position.z = terrainHeight + minimumHeight
  end
  if progress >= 1 then position = vec3(focusTransition.targetPosition) end
  core_camera.setPosition(0, position)
  focusTransition.expectedPosition = vec3(position)
  if progress >= 1 then
    orbit.setPivot(focusTransition.focusPoint, "focus")
    cancelFocusTransition()
  end
end

function M.consumeFocusDoubleClick()
  local frame = im.GetFrameCount()
  if focusDoubleClickFrame == frame then return focusDoubleClickConsumed end
  focusDoubleClickFrame = frame
  focusDoubleClickConsumed = false
  if not cameraAvailable()
    or not im.IsMouseDoubleClicked(0)
    or im.IsAnyItemActive()
    or editor.keyModifiers.ctrl
    or editor.keyModifiers.shift
    or editor.keyModifiers.alt then
    return false
  end

  local ray = getCameraMouseRay()
  if not ray then return false end
  local direction = vec3(ray.dir)
  if direction:length() <= 0.0001 then return false end
  direction:normalize()
  local hit = Engine.castRay(ray.pos, vec3(ray.pos) + direction * 100000, true, true)
  local point = hit and hit.pt and vec3(hit.pt) or nil
  if not validation.isReasonablePoint(point) then return false end

  local cameraPosition = vec3(core_camera.getPosition())
  local forward = core_camera.getQuat() * vec3(0, 1, 0)
  if forward:length() <= 0.0001 then return false end
  forward:normalize()
  local relative = point - cameraPosition
  local depth = relative:dot(forward)
  if depth <= 0.001 then return false end
  local targetPosition = cameraPosition + relative - forward * depth
  if not validation.isReasonablePoint(targetPosition) then return false end
  local terrainHeight = validation.terrainHeightAt(targetPosition)
  local minimumHeight = math.max(preference("zoomMinDistance", 0.25), 0.01)
  if terrainHeight and targetPosition.z < terrainHeight + minimumHeight then
    targetPosition.z = terrainHeight + minimumHeight
  end

  M.cancel()
  if not registry.acquire(controllerId) then return false end
  core_camera.clearInputs()
  if core_camera.clearMotion then core_camera.clearMotion(0) end
  focusTransition = {
    startPosition = vec3(cameraPosition),
    targetPosition = vec3(targetPosition),
    expectedPosition = vec3(cameraPosition),
    rotation = quat(core_camera.getQuat()),
    focusPoint = vec3(point),
    elapsed = 0,
    duration = focusDuration((targetPosition - cameraPosition):length(), depth)
  }
  focusDoubleClickConsumed = true
  return true
end

function M.onEditorMouseWheel(value)
  if not active or not editor or not editor.active then return false end
  if not freeCameraActive() then return false end
  if not editor.isViewportHovered() or im.GetIO().WantCaptureMouse then return true end
  cancelPan()
  orbit.cancel()
  cancelFocusTransition()
  if not registry.acquire(controllerId) then return false end
  pendingWheel = pendingWheel + value
  return true
end

function M.onRelativeInput(axis, value, player)
  if (player or 0) ~= 0 then return false end
  if not cameraAvailable() then return false end
  local panButton, orbitButton = mouseButtons()
  if im.IsMouseDown(panButton) then
    return registry.acquire(controllerId)
  end
  if im.IsMouseDown(orbitButton) then
    cancelPan()
    zoom.cancel()
    cancelFocusTransition()
    if not registry.acquire(controllerId) then return false end
    orbit.onMouseInput(
      axis,
      value,
      preference("orbitAroundViewCenter", true) and 1 or 0,
      orbitButton)
    return true
  end
  if orbit.isOrbitActive() then return true end
  if preference("orbitAroundViewCenter", true) then return true end
  local frame = im.GetFrameCount()
  if relativeInputSuppressedFrame == frame then return true end
  if math.abs(value) > 0.000001
    and (panState or focusTransition or orbit.isActive() or zoom.isActive()) then
    M.cancel()
    relativeInputSuppressedFrame = frame
    return true
  end
  return false
end

local function hasActiveMotion()
  return panState ~= nil
    or focusTransition ~= nil
    or orbit.isActive()
    or zoom.isActive()
end

function M.update(deltaTime)
  if not active then return end
  if not cameraAvailable() then
    M.cancel()
    return
  end
  deltaTime = clamp(deltaTime or im.GetIO().DeltaTime or 0, 0, 0.05)
  updatePlanarTranslationScale()
  updateWasdPanLifecycle()
  if M.consumeFocusDoubleClick() then return end

  local panButton, orbitButton = mouseButtons()
  local actionFilter = extensions.core_input_actionFilter or core_input_actionFilter
  local wheelBlocked = actionFilter
    and actionFilter.isActionBlocked
    and actionFilter.isActionBlocked("editorCameraZoom")
  local wheelReserved = editor.disableCameraZoom
    or editor.keyModifiers
      and editor.keyModifiers.ctrl
      and editor.keyModifiers.alt
  local wheel = im.GetIO().MouseWheel
  if math.abs(wheel) <= 0.0001 then wheel = pendingWheel end
  pendingWheel = 0
  if not wheelBlocked and not wheelReserved and math.abs(wheel) > 0.0001
    and registry.acquire(controllerId) then
    cancelPan()
    orbit.cancel()
    cancelFocusTransition()
    local pivot = orbit.getZoomPivot()
    zoom.onMouseWheel(wheel, pivot)
    pivotZoomActive = pivot ~= nil and zoom.isActive()
  end
  local buttonGesture = im.IsMouseDown(panButton) or im.IsMouseDown(orbitButton)
  local lockMiddleOrbit = orbitButton == 2 and im.IsMouseDown(orbitButton)
  setMiddleOrbitLocked(lockMiddleOrbit)
  if buttonGesture and not registry.acquire(controllerId) then return end
  if im.IsMouseClicked(orbitButton) then
    cancelPan()
    zoom.cancel()
    cancelFocusTransition()
  end
  if not registry.isOwner(controllerId) then
    if hasActiveMotion() then M.cancel() end
    return
  end

  zoom.update(deltaTime)
  if pivotZoomActive then
    if not orbit.syncDistanceFromCamera() or not zoom.isActive() then
      pivotZoomActive = false
    end
  end
  updatePan(panButton, deltaTime)
  orbit.update(
    preference("orbitAroundViewCenter", true) and 1 or 0,
    orbitButton,
    deltaTime)
  updateFocusTransition(deltaTime)
  if not buttonGesture and not hasActiveMotion() then registry.release(controllerId) end
end

function M.activate()
  active = true
  M.cancel()
end

function M.cancel()
  cancelPan()
  zoom.cancel()
  orbit.cancel()
  if wasdPanCombinedWithOrbit then orbit.markForReacquire() end
  cancelFocusTransition()
  setMiddleOrbitLocked(false)
  pendingWheel = 0
  pivotZoomActive = false
  wasdPanActive = false
  wasdPanCombinedWithOrbit = false
  registry.release(controllerId)
end

function M.deactivate()
  active = false
  M.cancel()
  orbit.reset()
end

function M.lastZoomUsedTerrainOnly()
  return zoom.lastZoomUsedTerrainOnly()
end

function M.orbitDebugState()
  return orbit.getDebugState()
end

function M.panDebugState()
  if panState and panState.hitPoint then
    return {
      point = vec3(panState.hitPoint),
      distance = panState.hitDistance
    }
  end
  return planarPanHitPoint and {
    point = vec3(planarPanHitPoint),
    distance = planarPanHitDistance
  } or nil
end

function M.setPlanarTranslation(planar)
  planar = planar == true
  if not core_camera or not core_camera.getGlobalCameras then return end
  local globalCams = core_camera.getGlobalCameras()
  if globalCams.free then
    if globalCams.free.planarTranslation ~= planar and globalCams.free.clearMotion then
      globalCams.free:clearMotion()
    end
    if globalCams.free.clearPlanarTranslationInput then
      globalCams.free:clearPlanarTranslationInput()
    end
    if not planar and globalCams.free.clearPlanarTranslationMotion then
      globalCams.free:clearPlanarTranslationMotion()
    end
    globalCams.free.planarTranslation = planar
    globalCams.free.planarTranslationScale = 1
    globalCams.free.planarTranslationDrag = nil
    globalCams.free.planarTranslationSpeedMultiplier = nil
    globalCams.free.planarTranslationFastSpeedMultiplier = nil
    globalCams.free.planarTranslationResponse = nil
  end
  wasdPanActive = false
  wasdPanCombinedWithOrbit = false
end

return M
