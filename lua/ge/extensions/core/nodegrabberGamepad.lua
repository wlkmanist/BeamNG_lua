-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = { "ui_bindingsLegend" }

local floor = math.floor
local radToDeg = 180 / math.pi
local strengthAxis = 0

M.state = {
  active = false,
  actionMapActive = false,
  mouseActive = false,
  grabbing = false,
  previousCameraName = nil,
  previousRelativeData = nil,
  vehId = nil,
  strength = 30,
}

local legendActions = {
  {action = "nodegrabberPadMode"},
  {action = "nodegrabberPadGrab"},
  {action = "nodegrabberStrength"},
  {action = "nodegrabberAction"},
}

local mouseLegendActions = {
  {action = "nodegrabberAction"},
  {action = "nodegrabberStrength"}
}

local function setUiVisible(visible)
  ui_bindingsLegend.addActions("nodegrabberGamepad", visible and legendActions or {}, {priority = 8.2, hideConstant = true})
end

local function setMouseUiVisible(visible)
  ui_bindingsLegend.addActions("nodegrabberMouse", visible and mouseLegendActions or {}, {priority = 10.2, hideConstant = true})
end

local function syncActionMap()
  local shouldBeActive = M.state.active or M.state.mouseActive or M.state.grabbing
  if M.state.actionMapActive == shouldBeActive then return end
  if shouldBeActive then pushActionMap("Nodegrabber")
  else popActionMap("Nodegrabber") end
  M.state.actionMapActive = shouldBeActive
end

local function getRelativeCameraRotation(cameraRot, vehicleCameraRot)
  local relRot = quat(0, 0, 0, 1)
  relRot:setMulInv2(cameraRot, vehicleCameraRot)
  local euler = relRot:toEulerYXZ() * radToDeg
  return vec3(euler.x, 180 - euler.y, euler.z)
end

local function getRelativeCameraTransform()
  local vehicle = getPlayerVehicle(0)
  if not vehicle then return end

  local vehicleId = vehicle:getId()
  local cameraData = core_camera.getCameraDataById and core_camera.getCameraDataById(vehicleId)
  local relativeCamera = cameraData and cameraData.relative
  local refNodes = relativeCamera and relativeCamera.refNodes or {ref = 0, left = 1, back = 2}

  local refNode = vehicle:getNodePosition(refNodes.ref)
  local leftNode = vehicle:getNodePosition(refNodes.left)
  local backNode = vehicle:getNodePosition(refNodes.back)
  if not (refNode and leftNode and backNode) then return end

  local ref = vec3(refNode)
  local left = vec3(leftNode)
  local back = vec3(backNode)
  local dir = ref - back
  if dir:squaredLength() == 0 then return end
  dir = dir:normalized()

  local up = dir:cross(left)
  if up:squaredLength() == 0 then return end
  up = up:normalized()

  local vehicleCameraRot = quatFromDir(dir, up)
  local vehicleCameraRotInv = vehicleCameraRot:inversed()
  local cameraPos = core_camera.getPosition()
  local cameraRot = core_camera.getQuat()
  local offset = vehicleCameraRotInv * (cameraPos - vehicle:getPosition() - ref)
  local rot = getRelativeCameraRotation(cameraRot, vehicleCameraRot)
  return vehicleId, offset, rot, core_camera.getFovDeg()
end

local function switchToRelativeCamera()
  if core_camera.getActiveGlobalCameraName() then return end

  local vehicleId, offset, rot, fov = getRelativeCameraTransform()
  if not vehicleId then return end

  local activeCameraName = core_camera.getActiveCamName(0)
  M.state.previousCameraName = activeCameraName or nil
  local rel = core_camera.getCameraDataById(vehicleId).relative
  M.state.previousRelativeData = { vehicleId = vehicleId, pos = rel.pos and vec3(rel.pos) or nil, rot = rel.rot and vec3(rel.rot) or nil, fov = rel.manualzoom.fov }
  core_camera.setByName(0, "relative", false)
  rel:setOffset(offset)
  rel:setRotation(rot)
  rel:setFOV(fov)
end

local function restorePreviousCamera()
  if M.state.previousRelativeData then
    local p = M.state.previousRelativeData
    local rel = core_camera.getCameraDataById(p.vehicleId).relative
    if p.pos then rel:setOffset(p.pos) else rel.pos = nil end
    if p.rot then rel:setRotation(p.rot) else rel.rot = nil end
    rel:setFOV(p.fov)
    M.state.previousRelativeData = nil
  end
  if M.state.previousCameraName then core_camera.setByName(0, M.state.previousCameraName, false) end
  M.state.previousCameraName = nil
end

local function restoreStrength()
  be.nodeGrabber:setStrength(M.state.strength)
end

local strengthUIprev
local function updateUI()
  strengthUIprev = strengthUIprev or floor(M.state.strength + 0.5)
  local strengthUI = floor(M.state.strength + 0.5)
  if strengthUIprev == strengthUI then return end
  strengthUIprev = strengthUI
  ui_message({txt = "ui.nodegrabber.strength", context = {percent = strengthUI}}, 2, "nodegrabberStrength")
end

local function setNodeGrabberMode(enabled)
  if enabled then
    switchToRelativeCamera()
    be.nodeGrabber:setControllerMode(not M.state.mouseActive)
    be.nodeGrabber:renderNodes(true)
  else
    be.nodeGrabber:onMouseButton(false)
    strengthAxis = 0
    restoreStrength()
    be.nodeGrabber:renderNodes(M.state.mouseActive)
    be.nodeGrabber:setControllerMode(false)
    restorePreviousCamera()
  end
end

local function setActive(enabled)
  if M.state.active == enabled then return end
  M.state.active = enabled
  M.state.vehId = enabled and be:getPlayerVehicleID(0)
  setNodeGrabberMode(M.state.active)
  syncActionMap()
  setUiVisible(M.state.active)
end

function M.setMouseActive(enabled)
  if M.state.mouseActive == enabled then return end
  if enabled and M.state.active then setActive(false) end
  M.state.mouseActive = enabled
  be.nodeGrabber:setControllerMode(false)
  be.nodeGrabber:renderNodes(M.state.active or M.state.mouseActive or M.state.grabbing)
  if M.state.active and not M.state.mouseActive then be.nodeGrabber:setControllerMode(true) end
  syncActionMap()
end

function M.onNodegrab(grabbed)
  M.state.grabbing = grabbed
  setMouseUiVisible(grabbed)
  be.nodeGrabber:renderNodes(M.state.active or M.state.mouseActive or M.state.grabbing)
  syncActionMap()
end

function M.toggleActive()
  setActive(not M.state.active)
end

function M.setGrab(value)
  local grabbing = value > 0
  if grabbing then
    be.nodeGrabber:setStrength(value * M.state.strength)
  else
    restoreStrength()
  end
  be.nodeGrabber:onMouseButton(grabbing)
end

function M.fixCurrentNode()
  restoreStrength()
  be.nodeGrabber:fixCurrentNode()
end

function M.addStrength(value)
  M.state.strength = clamp(M.state.strength + value, 0, 100)
  be.nodeGrabber:setStrength(M.state.strength)
  updateUI()
end

function M.changeStrength(value, filterType)
  if filterType == 0 then
    M.addStrength(value * 5) -- binary button
  else
    strengthAxis = value -- analog axis
  end
end

function M.onUpdate(dtReal)
  if not M.state.active or strengthAxis == 0 then return end
  M.addStrength(strengthAxis * 50 * dtReal)
end

function M.onSerialize()
  M.setMouseActive(false)
  return M.state
end

-- automatically deactivate gamepad nodegrabber on certain events
function M.onExtensionUnloaded()                   setActive(false) end
function M.onCefVisibilityChanged(cefVisible)      if not cefVisible then setActive(false) end end
function M.onVehicleResetted(vehicleId)            if M.state.active and vehicleId == M.state.vehId then setActive(false) end end
function M.onBeforeVehicleReplaced(vehicleId)      if M.state.active and vehicleId == M.state.vehId then setActive(false) end end
function M.onDespawnObject(vehicleId, isReloading) if M.state.active and vehicleId == M.state.vehId and isReloading then setActive(false) end end
function M.onCameraModeChanged(cameraName)         if M.state.active and not M.state.grabbing and not M.state.mouseActive and cameraName ~= "relative" then if cameraName ~= M.state.previousCameraName then M.state.previousCameraName = nil end setActive(false) end end
function M.onGlobalCameraSet(cameraName)           if M.state.active and not M.state.grabbing and not M.state.mouseActive and cameraName then M.state.previousCameraName = nil setActive(false) end end

return M
