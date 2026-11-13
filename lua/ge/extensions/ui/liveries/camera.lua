-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local M = {}

M.dependencies = {"editor_api_dynamicDecals"}

-- vehicle-relative orbit rotations, matching the presets used by garage mode and the livery editor
local VIEWS = {
  { id = "top", labelKey = "camera.position.top", icon = "cameraTop1", rotation = vec3(90, -90, 0) },
  { id = "left", labelKey = "ui.common.left", icon = "cameraSideLeft", rotation = vec3(-90, 0, 0) },
  { id = "right", labelKey = "camera.position.right", icon = "cameraSideRight", rotation = vec3(90, 0, 0) },
  { id = "back", labelKey = "camera.position.rear", icon = "cameraBack1", rotation = vec3(0, 0, 0) },
  { id = "front", labelKey = "camera.position.front", icon = "cameraFront1", rotation = vec3(180, 0, 0) },
}

local VIEWS_BY_ID = {}
for _, view in ipairs(VIEWS) do
  VIEWS_BY_ID[view.id] = view
end

local DECAL_SIDE_MIN_DOT = 0.98
local DECAL_SIDES = {
  { id = "top", direction = vec3(0, 0, -1) },
  { id = "left", direction = vec3(-1, 0, 0) },
  { id = "right", direction = vec3(1, 0, 0) },
  { id = "back", direction = vec3(0, -1, 0) },
  { id = "front", direction = vec3(0, 1, 0) },
}

local function getDecalSide(layer)
  if not layer.camDirection then return nil end

  local direction = vec3(layer.camDirection)
  if direction:squaredLength() < 1e-8 then return nil end
  direction:normalize()

  local closestSide
  local closestDot = -1
  for _, side in ipairs(DECAL_SIDES) do
    local dot = direction:dot(side.direction)
    if dot > closestDot then
      closestSide = side.id
      closestDot = dot
    end
  end

  return closestDot >= DECAL_SIDE_MIN_DOT and closestSide or nil
end

-- there is no completion callback for orbit preset changes (see core/cameraModes/orbit.lua),
-- so this is a bounded wait for the reset + smoothing to visually settle before the ui reacts
local VIEW_SETTLE_DELAY_S = 0.35

local VIEW_APPLIED_EVENT = "liveries_camera_viewApplied"

-- matches the decal transform rate scale, so the Small Increments switch also slows the free camera
local SMALL_INCREMENT_MULTIPLIER = 0.1

local isRunning = false
local previousDefaultRotation = nil
local activeJob = nil
local activeRequestId = 0

local transformActive = false
local capturedCameraName = nil
local transformCameraIsFree = true
local transformLayer = nil
local capturedDefaultRotation = nil

local function getOrbitCamData()
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId == -1 then return nil end
  local camData = core_camera.getCameraDataById(vehId)
  return camData and camData.orbit
end

-- mouse placement drives the decal cursor from the mouse, which needs orbit-style camera control
local function isUseMousePos()
  local api = extensions.editor_api_dynamicDecals
  return api ~= nil and api.isUseMousePos() or false
end

local function captureDefaultRotation()
  if capturedDefaultRotation then return end
  local orbit = getOrbitCamData()
  capturedDefaultRotation = orbit and orbit.defaultRotation and vec3(orbit.defaultRotation) or nil
end

local function cancelActiveJob()
  if activeJob then
    core_jobsystem.cancelJob(activeJob)
    activeJob = nil
  end
end

local function applyViewInJob(job, viewId, requestId)
  commands.setGameCamera()
  core_camera.setByName(0, "orbit", false)
  job.sleep(0.00001) -- sleep for one frame so the orbit cam can update correctly
  core_camera.setDefaultRotation(be:getPlayerVehicleID(0), VIEWS_BY_ID[viewId].rotation)
  core_camera.resetCamera(0)

  job.sleep(VIEW_SETTLE_DELAY_S)

  if requestId == activeRequestId then
    activeJob = nil
    guihooks.trigger(VIEW_APPLIED_EVENT, { view = viewId })
  end
end

M.setup = function()
  if isRunning then return end

  local orbit = getOrbitCamData()
  previousDefaultRotation = orbit and orbit.defaultRotation and vec3(orbit.defaultRotation) or nil

  isRunning = true
end

M.teardown = function()
  if not isRunning then return end

  M.stopTransform()

  cancelActiveJob()

  local orbit = getOrbitCamData()
  if orbit and previousDefaultRotation then
    orbit:setDefaultRotation(previousDefaultRotation)
  end

  previousDefaultRotation = nil
  isRunning = false
end

M.getViews = function()
  local views = {}
  for _, view in ipairs(VIEWS) do
    table.insert(views, { id = view.id, labelKey = view.labelKey, icon = view.icon })
  end
  return views
end

M.setView = function(viewId)
  if not VIEWS_BY_ID[viewId] then
    log("W", "liveries", "ui_liveries_camera.setView: unknown view " .. tostring(viewId))
    return false
  end

  cancelActiveJob()
  activeRequestId = activeRequestId + 1
  activeJob = core_jobsystem.create(applyViewInJob, nil, viewId, activeRequestId)
  return true
end

M.activateOrbitMode = function()
  commands.setGameCamera()
  core_camera.setByName(0, "orbit", false)
  return true
end

local function freeCameraToLayerInJob(job, layer, requestId)
  local veh = getPlayerVehicle(0)
  if not veh then return end

  commands.setFreeCamera()
  job.sleep(0.00001) -- sleep for one frame so the free cam can update correctly

  local refMat = veh:getRefNodeMatrix()
  local worldPos = vec3(refMat:mulP3F(layer.camPosition))
  local worldDir = quat(refMat:toQuatF()) * layer.camDirection
  core_camera.setPosition(0, worldPos)
  core_camera.setRotation(0, quatFromDir(worldDir))

  -- a newer request cancels this job before it gets here, but guard anyway
  if requestId == activeRequestId then
    activeJob = nil
  end
end

local function getOrbitRotationForLayer(layer)
  local dir = vec3(layer.camDirection)
  dir:normalize()

  local yaw = math.deg(math.atan2(dir.x, -dir.y))
  local pitch = math.deg(math.asin(clamp(dir.z, -1, 1)))
  return vec3(yaw, pitch, 0)
end

-- rotates the orbit camera onto the layer's angle without touching distance/zoom, so a reset
-- (or a later free-to-orbit toggle) lands on the same angle instead of snapping back
local function applyOrbitRotationForLayer(layer)
  local vehId = be:getPlayerVehicleID(0)
  if not vehId or vehId == -1 then return false end

  local rotation = getOrbitRotationForLayer(layer)
  core_camera.setDefaultRotation(vehId, rotation)
  core_camera.setRotation(vehId, rotation)
  return true
end

local function orbitCameraToLayerInJob(job, layer, requestId)
  job.sleep(0.00001)
  applyOrbitRotationForLayer(layer)

  if requestId == activeRequestId then
    activeJob = nil
  end
end

-- non-free cameras do not necessarily support orbit rotations, so activate orbit first
local function previewOrbitCameraToLayerInJob(job, layer, requestId)
  commands.setGameCamera()
  core_camera.setByName(0, "orbit", false)
  orbitCameraToLayerInJob(job, layer, requestId)
end

local function getLayerWithCameraPose(layerUid)
  if type(layerUid) ~= "string" then return nil end

  local api = extensions.editor_api_dynamicDecals
  if not api then return nil end

  local layer = api.getLayerByUid(layerUid)
  if not layer or layer.type ~= api.layerTypes.decal then return nil end
  if not layer.camPosition or not layer.camDirection then return nil end

  return layer
end

M.panToLayer = function(layerUid)
  local layer = getLayerWithCameraPose(layerUid)
  if not layer then
    log("W", "liveries", "ui_liveries_camera.panToLayer: no camera pose for layer " .. tostring(layerUid))
    return false
  end

  cancelActiveJob()
  activeRequestId = activeRequestId + 1
  activeJob = core_jobsystem.create(freeCameraToLayerInJob, nil, layer, activeRequestId)
  return true
end

-- orbit camera framing for a decal layer: preset side when orthographic, otherwise the layer's angle
M.orbitToLayer = function(layerUid)
  local layer = getLayerWithCameraPose(layerUid)
  if not layer then
    log("W", "liveries", "ui_liveries_camera.orbitToLayer: no camera pose for layer " .. tostring(layerUid))
    return false
  end

  local side = getDecalSide(layer)
  if side then
    return M.setView(side)
  end

  cancelActiveJob()
  activeRequestId = activeRequestId + 1
  activeJob = core_jobsystem.create(previewOrbitCameraToLayerInJob, nil, layer, activeRequestId)
  return true
end

-- snaps orthographic placements to their preset, otherwise restores the exact angle
M.previewLayer = function(layerUid)
  local layer = getLayerWithCameraPose(layerUid)
  if not layer then
    log("W", "liveries", "ui_liveries_camera.previewLayer: no camera pose for layer " .. tostring(layerUid))
    return false
  end

  local side = getDecalSide(layer)
  if side then
    return M.setView(side)
  end

  cancelActiveJob()
  activeRequestId = activeRequestId + 1

  if commands.isFreeCamera() then
    activeJob = core_jobsystem.create(freeCameraToLayerInJob, nil, layer, activeRequestId)
    return true
  end

  if core_camera.getActiveCamName(0) == "orbit" then
    return applyOrbitRotationForLayer(layer)
  end

  activeJob = core_jobsystem.create(previewOrbitCameraToLayerInJob, nil, layer, activeRequestId)
  return true
end

-- TODO: remove this. likely a guard that doesn't make sense anymore
local function captureCameraName()
  local name = core_camera.getActiveCamName(0)
  if not name or name == "free" then return "orbit" end
  return name
end

M.startTransformAtLayer = function(layerUid)
  if transformActive then return false end

  local layer = getLayerWithCameraPose(layerUid)
  if not layer then
    log("W", "liveries", "ui_liveries_camera.startTransformAtLayer: no camera pose for layer " .. tostring(layerUid))
    return false
  end

  transformActive = true
  transformLayer = layer
  capturedCameraName = captureCameraName()

  cancelActiveJob()
  activeRequestId = activeRequestId + 1

  -- mouse placement needs orbit control, so land on the decal's angle in orbit instead of free cam
  if isUseMousePos() then
    transformCameraIsFree = false
    captureDefaultRotation()
    activeJob = core_jobsystem.create(previewOrbitCameraToLayerInJob, nil, layer, activeRequestId)
    return true
  end

  transformCameraIsFree = true
  activeJob = core_jobsystem.create(freeCameraToLayerInJob, nil, layer, activeRequestId)
  return true
end

M.startTransform = function()
  if transformActive then return end

  transformActive = true
  transformLayer = nil
  capturedCameraName = captureCameraName()

  -- mouse placement needs orbit control, so keep the preset picked on the camera screen
  if isUseMousePos() then
    transformCameraIsFree = false
    commands.setGameCamera()
    core_camera.setByName(0, "orbit", false)
    return
  end

  transformCameraIsFree = true
  commands.setFreeCamera()
end

local function stopCameraMovement()
  core_camera.moveup(0, 0)
  core_camera.movedown(0, 0)
  core_camera.moveLeftRight(0, 0)
end

local function stopCameraRotation()
  local filterType = core_camera.getLastFilter()
  core_camera.rotate_yaw(0, filterType, 0)
  core_camera.rotate_pitch(0, filterType, 0)
end

local function switchTransformToOrbit()
  if not transformActive then return false end
  if not transformCameraIsFree then return true end

  -- a pose job from the previous mode must never land after the switch
  cancelActiveJob()
  activeRequestId = activeRequestId + 1

  stopCameraMovement()
  commands.setGameCamera()
  core_camera.setByName(0, "orbit", false)
  transformCameraIsFree = false

  -- an existing decal goes back to its own angle; a new decal keeps the preset picked
  -- on the camera screen
  if transformLayer then
    captureDefaultRotation()
    activeJob = core_jobsystem.create(orbitCameraToLayerInJob, nil, transformLayer, activeRequestId)
  end

  return true
end

M.ensureTransformOrbitMode = function()
  return switchTransformToOrbit()
end

M.toggleTransformCameraMode = function()
  if not transformActive then return false end

  if transformCameraIsFree then
    switchTransformToOrbit()
  else
    -- a pose job from the previous mode must never land after the toggle
    cancelActiveJob()
    activeRequestId = activeRequestId + 1
    stopCameraRotation()
    commands.setFreeCamera()
    transformCameraIsFree = true
  end

  return true
end

M.stopTransform = function()
  if not transformActive then return end

  transformActive = false
  transformCameraIsFree = true
  transformLayer = nil
  cancelActiveJob() -- a pending pose job must not land after the camera was handed back
  activeRequestId = activeRequestId + 1
  stopCameraMovement()
  stopCameraRotation()

  commands.setGameCamera()
  if capturedCameraName then
    core_camera.setByName(0, capturedCameraName, false)
    capturedCameraName = nil
  end

  if capturedDefaultRotation then
    local vehId = be:getPlayerVehicleID(0)
    if vehId and vehId ~= -1 then
      core_camera.setDefaultRotation(vehId, capturedDefaultRotation)
    end
    capturedDefaultRotation = nil
  end
  core_camera.resetCamera(0)
end

local function getMovementScale()
  if ui_liveries_decal and ui_liveries_decal.getSmallIncrements() then
    return SMALL_INCREMENT_MULTIPLIER
  end
  return 1
end

M.panUpDown = function(value, filterType, player)
  if not transformActive then return end
  if not transformCameraIsFree then
    core_camera.rotate_pitch(value, filterType, player)
    return
  end

  value = value * getMovementScale()

  if value > 0 then
    core_camera.moveup(value, 0)
    core_camera.movedown(0, 0)
  else
    core_camera.moveup(0, 0)
    core_camera.movedown(-value, 0)
  end
end

M.moveLeftRight = function(value, filterType, player)
  if not transformActive then return end
  if not transformCameraIsFree then
    core_camera.rotate_yaw(value, filterType, player)
    return
  end

  core_camera.moveLeftRight(value * getMovementScale(), 0)
end

return M
