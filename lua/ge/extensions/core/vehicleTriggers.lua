-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- extensions.core_vehicleTriggers.enableDebugUI()
--
-- Interaction and visibility flow (high level):
-- - Input/camera state is refreshed first every frame. This computes aim mode:
--   cursor mode (raycast uses cursor coordinates) or crosshair mode
--   (raycast uses screen center).
-- - Crosshair mode is only allowed when the active camera and user settings
--   support canUseVehicleTriggerCrosshair; otherwise aim mode is forced to cursor mode.
-- - allowInteraction is true only when all of these are true:
--   no active photomode capture, CEF visible, route is /play or simulation is unpaused,
--   mouse not locked, and
--   if aim mode is cursor then cursor must be visible.
-- - When allowInteraction is false, trigger rendering/interaction are disabled,
--   legend actions are cleared, and crosshair stream is hidden.
-- - Crosshair stream publishes {visible, hovered}, where visible means crosshair
--   mode is currently active and hovered means the current raycast has a trigger.
-- - Crosshair timeout uses camera-rotation activity; it resets when camera moves,
--   pauses while crosshair is on a trigger, and hides crosshair mode on timeout
--   until movement resumes.

local im = ui_imgui
local normalTriggerDistance = 50
local unicycleTriggerDistance = 3
local w2sCamRight = vec3()
local w2sCamForward = vec3()
local w2sCamUp = vec3()
local w2sToPoint = vec3()
local w2sContextValid = false
local w2sContextCamPos = nil
local w2sContextHalfTan = 0
local w2sContextAspect = 0

local M = { state = {} }
M.dependencies = { "core_vehicle_triggerLabelPlacement" }
M.state.cefVisible = true

M.state.cursorVisibility = true
do
  local canvas = scenetree.findObject('Canvas')
  local pos = canvas and canvas:getCursorPos()
  if pos then M.state.cursorVisibility = pos.x ~= -1 and pos.y ~= -1 end
end
M.state.mouseLocked = false
M.state.cursorVisible = M.state.cursorVisibility and not M.state.mouseLocked
M.state.isUnicycle = false
M.state.lastMousePos = nil
M.state.mouseInUse = false
M.state.cameraMovementType = "relative"
M.state.lastCameraMovementType = nil
M.state.absoluteMovementStartMousePos = nil
M.state.useCursorCoordinates = false
M.state.currentlyUsedTrigger = nil
M.state.debugEnabled = false
M.state.crosshairVisibleStream = nil
M.state.crosshairHoveredStream = nil
M.state.crosshairVisible = false
M.state.activeCamName = "n/a"
M.state.timeSinceLastMovedMs = nil
M.state.crosshairTimedOut = false
M.state.lastRotationAgeMs = nil
M.state.crosshairHasTarget = false
M.state.canUseVehicleTriggerCrosshair = false
M.state.currentRouteName = nil
M.state.isPlayRoute = false
M.state.cefMouseCaptured = false
M.state.cefMouseCapturedRaw = false
M.state.cefMouseCapturedFrames = 0
M.state.allowInteraction = false
M.state.aimMode = "crosshair"
M.state.hoveredHitPosWorld = nil
M.state.hoveredHitPosScreen01 = nil
M.state.crosshairTargetScreenStream = nil
M.state.vehicleInteractionActionMapDesired = false
M.state.vehicleInteractionActionMapActive = false
M.state.vehicleInteractionActionMapsDesired = { action0 = false, action1 = false, action2 = false }
M.state.vehicleInteractionActionMapsActive = { action0 = false, action1 = false, action2 = false }

local fpsLimiter = newFPSLimiter(20)
local DEBUG_PROJECT_CORNERS_EVERY_FRAME = false

local crosshairStreamName = "vehicleTriggerCrosshairVisible"
local crosshairTargetStreamName = "vehicleTriggerCrosshairTarget"
local lastCrosshairStreamVisible = nil
local lastCrosshairStreamHovered = nil
local reusedCrosshairTargetStreamPayload = {}
local lastCrosshairTargetX = nil
local lastCrosshairTargetY = nil
local lastCrosshairTargetAction0 = nil
local lastCrosshairTargetAction1 = nil
local lastCrosshairTargetAction2 = nil
local lastCrosshairTargetColorR = nil
local lastCrosshairTargetColorG = nil
local lastCrosshairTargetColorB = nil
local lastCrosshairTargetColorA = nil
local lastCrosshairTargetName = nil
local lastCrosshairTargetLabelX = nil
local lastCrosshairTargetLabelY = nil
local lastCrosshairTargetLabelTx = nil
local lastCrosshairTargetLabelTy = nil
local lastCrosshairTargetLabelSide = nil
local lastCrosshairTargetBoundsMinX = nil
local lastCrosshairTargetBoundsMaxX = nil
local lastCrosshairTargetBoundsMinY = nil
local lastCrosshairTargetBoundsMaxY = nil
local lastCrosshairTargetBoundsCenterX = nil
local lastCrosshairTargetBoundsCenterY = nil
local p = nil -- set to LuaProfiler("vehicleTriggerProfiler") to enable
--p = LuaProfiler("vehicleTriggerProfiler")

local function rotateVecByQuatInPlace(outVec, quatValue, inX, inY, inZ)
  local qx, qy, qz, qw = quatValue.x, quatValue.y, quatValue.z, quatValue.w
  local tx = 2 * (qy * inZ - qz * inY)
  local ty = 2 * (qz * inX - qx * inZ)
  local tz = 2 * (qx * inY - qy * inX)
  outVec:set(
    inX - qw * tx + (qy * tz - qz * ty),
    inY - qw * ty + (qz * tx - qx * tz),
    inZ - qw * tz + (qx * ty - qy * tx)
  )
end

local function setCrosshairStream(visible, hovered)
  visible = visible == true
  hovered = hovered == true
  if lastCrosshairStreamVisible == visible and lastCrosshairStreamHovered == hovered then return end
  lastCrosshairStreamVisible = visible
  lastCrosshairStreamHovered = hovered
  M.state.crosshairVisibleStream = visible
  M.state.crosshairHoveredStream = hovered
  M.state.crosshairVisible = visible
  guihooks.triggerStream(crosshairStreamName, {
    visible = visible,
    hovered = hovered,
  })
end

local function setCrosshairTargetStream(x, y, actionTitles, triggerColor, labelPlacement, hoveredTriggerName)
  if p then p:add("05b_targetStream_begin") end
  local xRounded = x and round(x*10000)/10000 or nil
  local yRounded = y and round(y*10000)/10000 or nil
  local action0 = actionTitles and actionTitles.action0 and _tr(actionTitles.action0) or nil
  local action1 = actionTitles and actionTitles.action1 and _tr(actionTitles.action1) or nil
  local action2 = actionTitles and actionTitles.action2 and _tr(actionTitles.action2) or nil
  local colorR = triggerColor and triggerColor.r or nil
  local colorG = triggerColor and triggerColor.g or nil
  local colorB = triggerColor and triggerColor.b or nil
  local colorA = triggerColor and triggerColor.a or nil
  local labelX = labelPlacement and labelPlacement.labelX or nil
  local labelY = labelPlacement and labelPlacement.labelY or nil
  local labelTx = labelPlacement and labelPlacement.labelTx or nil
  local labelTy = labelPlacement and labelPlacement.labelTy or nil
  local labelSide = labelPlacement and labelPlacement.labelSide or nil
  local boundsMinX = labelPlacement and labelPlacement.bounds and labelPlacement.bounds.minX or nil
  local boundsMaxX = labelPlacement and labelPlacement.bounds and labelPlacement.bounds.maxX or nil
  local boundsMinY = labelPlacement and labelPlacement.bounds and labelPlacement.bounds.minY or nil
  local boundsMaxY = labelPlacement and labelPlacement.bounds and labelPlacement.bounds.maxY or nil
  local boundsCenterX = labelPlacement and labelPlacement.bounds and labelPlacement.bounds.centerX or nil
  local boundsCenterY = labelPlacement and labelPlacement.bounds and labelPlacement.bounds.centerY or nil
  local unchanged =
    xRounded == lastCrosshairTargetX
    and yRounded == lastCrosshairTargetY
    and action0 == lastCrosshairTargetAction0
    and action1 == lastCrosshairTargetAction1
    and action2 == lastCrosshairTargetAction2
    and colorR == lastCrosshairTargetColorR
    and colorG == lastCrosshairTargetColorG
    and colorB == lastCrosshairTargetColorB
    and colorA == lastCrosshairTargetColorA
    and hoveredTriggerName == lastCrosshairTargetName
    and labelX == lastCrosshairTargetLabelX
    and labelY == lastCrosshairTargetLabelY
    and labelTx == lastCrosshairTargetLabelTx
    and labelTy == lastCrosshairTargetLabelTy
    and labelSide == lastCrosshairTargetLabelSide
    and boundsMinX == lastCrosshairTargetBoundsMinX
    and boundsMaxX == lastCrosshairTargetBoundsMaxX
    and boundsMinY == lastCrosshairTargetBoundsMinY
    and boundsMaxY == lastCrosshairTargetBoundsMaxY
    and boundsCenterX == lastCrosshairTargetBoundsCenterX
    and boundsCenterY == lastCrosshairTargetBoundsCenterY
  if unchanged then
    if p then p:add("05b_targetStream_unchangedSkip") end
    return
  end

  lastCrosshairTargetX = xRounded
  lastCrosshairTargetY = yRounded
  lastCrosshairTargetAction0 = action0
  lastCrosshairTargetAction1 = action1
  lastCrosshairTargetAction2 = action2
  lastCrosshairTargetColorR = colorR
  lastCrosshairTargetColorG = colorG
  lastCrosshairTargetColorB = colorB
  lastCrosshairTargetColorA = colorA
  lastCrosshairTargetName = hoveredTriggerName
  lastCrosshairTargetLabelX = labelX
  lastCrosshairTargetLabelY = labelY
  lastCrosshairTargetLabelTx = labelTx
  lastCrosshairTargetLabelTy = labelTy
  lastCrosshairTargetLabelSide = labelSide
  lastCrosshairTargetBoundsMinX = boundsMinX
  lastCrosshairTargetBoundsMaxX = boundsMaxX
  lastCrosshairTargetBoundsMinY = boundsMinY
  lastCrosshairTargetBoundsMaxY = boundsMaxY
  lastCrosshairTargetBoundsCenterX = boundsCenterX
  lastCrosshairTargetBoundsCenterY = boundsCenterY

  local payload = reusedCrosshairTargetStreamPayload
  payload.x = xRounded
  payload.y = yRounded
  payload.action0 = action0
  payload.action1 = action1
  payload.action2 = action2
  payload.colorR = colorR
  payload.colorG = colorG
  payload.colorB = colorB
  payload.colorA = colorA
  payload.hoveredTriggerName = hoveredTriggerName
  payload.labelX = labelX
  payload.labelY = labelY
  payload.labelTx = labelTx
  payload.labelTy = labelTy
  payload.labelSide = labelSide
  payload.boundsMinX = boundsMinX
  payload.boundsMaxX = boundsMaxX
  payload.boundsMinY = boundsMinY
  payload.boundsMaxY = boundsMaxY
  payload.boundsCenterX = boundsCenterX
  payload.boundsCenterY = boundsCenterY
  if p then p:add("05b_targetStream_payloadPrepared") end
  M.state.crosshairTargetScreenStream = payload
  guihooks.triggerStream(crosshairTargetStreamName, payload)
  if p then p:add("05b_targetStream_triggered") end
end

local function refreshAimModeState()
  M.state.aimMode = M.state.useCursorCoordinates and "cursor" or "crosshair"
end

local function setDebugEnabled(enabled)
  enabled = enabled == true
  if M.state.debugEnabled == enabled then return end
  M.state.debugEnabled = enabled
  if enabled then
    extensions.load('core_vehicleTriggersDebug')
  else
    extensions.unload('core_vehicleTriggersDebug')
  end
end

local function isAnyControllerConnected()
  local inputDevices = Input.getRegisteredDevices()
  for _, d in ipairs(inputDevices) do
    if d ~= 'mouse0' and d ~= 'keyboard0' then
      return true
    end
  end
  return false
end

local function getCurrentRouteName()
  local router = ui_router or (extensions and extensions.ui_router)
  local currentRoute = router and router.getCurrent and router.getCurrent() or nil
  return currentRoute and currentRoute.resolved and currentRoute.resolved.name or nil
end

local function getCursorPercent01()
  local canvas = scenetree.findObject("Canvas")
  if not canvas then return nil end
  if not canvas.getCursorPos or not canvas.getWindowClientSizeXY or not canvas.clientToScreenXY then return nil end

  local cursorPos = canvas:getCursorPos()
  local clientW, clientH = canvas:getWindowClientSizeXY()
  local clientOriginX, clientOriginY = canvas:clientToScreenXY(Point2I(0, 0))
  if not cursorPos or not clientW or not clientH or clientW <= 0 or clientH <= 0 or not clientOriginX or not clientOriginY then
    return nil
  end

  local localX = cursorPos.x - clientOriginX
  local localY = cursorPos.y - clientOriginY
  return {x = localX / clientW, y = localY / clientH}
end

local function updateWorldPosToScreenContext()
  w2sContextValid = false
  if not core_camera or not core_camera.getPosition or not core_camera.getQuat then return false end
  local camPos = core_camera.getPosition()
  local camRot = core_camera.getQuat()
  if not camPos or not camRot then return false end

  local canvas = scenetree.findObject("Canvas")
  if not canvas or not canvas.getWindowClientSizeXY then return false end
  local clientW, clientH = canvas:getWindowClientSizeXY()
  if not clientW or not clientH or clientW <= 0 or clientH <= 0 then return false end

  local fovRad = core_camera.getFovRad and core_camera.getFovRad() or nil
  if not fovRad or fovRad <= 0 then return false end
  local aspect = clientW / clientH
  if aspect <= 0 then return false end

  local halfTan = math.tan(fovRad * 0.5)
  if halfTan == 0 then return false end

  rotateVecByQuatInPlace(w2sCamRight, camRot, 1, 0, 0)
  rotateVecByQuatInPlace(w2sCamForward, camRot, 0, 1, 0)
  rotateVecByQuatInPlace(w2sCamUp, camRot, 0, 0, 1)

  w2sContextCamPos = camPos
  w2sContextHalfTan = halfTan
  w2sContextAspect = aspect
  w2sContextValid = true
  return true
end

local function worldPosToScreenPercent01(worldPos, out)
  if not worldPos then return nil end
  if not w2sContextValid and not updateWorldPosToScreenContext() then return nil end

  w2sToPoint:setSub2(worldPos, w2sContextCamPos)

  local depth = w2sToPoint:dot(w2sCamForward)
  if not depth or depth <= 0 then return nil end

  local nx = w2sToPoint:dot(w2sCamRight) / (depth * w2sContextHalfTan * w2sContextAspect)
  local ny = w2sToPoint:dot(w2sCamUp) / (depth * w2sContextHalfTan)

  out = out or {}
  out.x = (nx + 1) * 0.5
  out.y = (1 - ny) * 0.5
  return out
end

local function getTriggerRaycastDistance()
  local activeCamName = core_camera and core_camera.getActiveCamName and core_camera.getActiveCamName(0) or ""
  local isDriverCam = activeCamName == "driver"
  local isFreeCam = (commands and commands.isFreeCamera and commands.isFreeCamera()) or activeCamName == "free"

  if M.state.isUnicycle or isDriverCam then
    return unicycleTriggerDistance
  end
  if isFreeCam then
    return normalTriggerDistance
  end
  return normalTriggerDistance
end

local function queueCmd(vehId, cmd)
  local vehObj = scenetree.findObject(vehId)
  if vehObj then
    vehObj:queueLuaCommand(cmd)
    if M.state.debugEnabled then
      log('I', 'triggers', 'Executing trigger code: ' .. tostring(cmd))
    end
  end
end

local function isSettingEnabled(settingName)
  return not (settings and settings.getValue and settings.getValue(settingName) == false)
end

local function refreshPlayerContextState()
  local vehicleData = core_vehicle_manager and core_vehicle_manager.getPlayerVehicleData()
  M.state.isUnicycle = vehicleData and vehicleData.mainPartName == "unicycle"
  M.state.currentRouteName = getCurrentRouteName()
  M.state.isPlayRoute = M.state.currentRouteName == "play"
  M.state.cefMouseCapturedRaw = type(getCEFFocusMouse) == "function" and getCEFFocusMouse() == true or false
  if M.state.cefMouseCapturedRaw then
    M.state.cefMouseCapturedFrames = (M.state.cefMouseCapturedFrames or 0) + 1
  else
    M.state.cefMouseCapturedFrames = 0
  end
  -- Apply a 1-frame delay: require 2 consecutive captured frames before disabling interaction.
  M.state.cefMouseCaptured = M.state.cefMouseCapturedFrames >= 2
  M.state.activeCamName = core_camera and core_camera.getActiveCamName and core_camera.getActiveCamName(0) or "n/a"
  M.state.cameraMovementType = core_camera.getLastCameraMovementType and core_camera.getLastCameraMovementType() or "relative"

  local enableWalkingCrosshair = isSettingEnabled("enableVehicleTriggerCrosshairWalkingMode")
  local enableInternalCameraCrosshair = isSettingEnabled("enableVehicleTriggerCrosshairInternalCameras")

  M.state.canUseVehicleTriggerCrosshair = commands.isFreeCamera() or (M.state.isUnicycle and enableWalkingCrosshair)
  if not M.state.canUseVehicleTriggerCrosshair and enableInternalCameraCrosshair then
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId and playerVehicleId ~= -1 then
      local cameraDataByName = core_camera.getCameraDataById(playerVehicleId)
      local activeCamera = cameraDataByName and cameraDataByName[M.state.activeCamName]
      M.state.canUseVehicleTriggerCrosshair = activeCamera and activeCamera.canUseVehicleTriggerCrosshair == true or false
    end
  end
end

local function updateCrosshairTimeout(dtReal)
  local rotationAge = core_camera and core_camera.timeSinceLastRotation and core_camera.timeSinceLastRotation() or nil
  local cameraMoved = false
  if rotationAge ~= nil and M.state.lastRotationAgeMs ~= nil and rotationAge < M.state.lastRotationAgeMs then
    cameraMoved = true
  end
  M.state.lastRotationAgeMs = rotationAge

  if M.state.timeSinceLastMovedMs == nil then
    M.state.timeSinceLastMovedMs = 0
  end

  if cameraMoved then
    M.state.timeSinceLastMovedMs = 0
  elseif not (M.state.crosshairHasTarget and not M.state.useCursorCoordinates) then
    M.state.timeSinceLastMovedMs = M.state.timeSinceLastMovedMs + (dtReal * 1000)
  end

  M.state.crosshairTimedOut = M.state.timeSinceLastMovedMs > 1500
end

local function setAbsoluteStartMousePos(pos)
  if not pos then
    M.state.absoluteMovementStartMousePos = nil
    return
  end
  local absStart = M.state.absoluteMovementStartMousePos or {}
  absStart.x = pos.x
  absStart.y = pos.y
  M.state.absoluteMovementStartMousePos = absStart
end

local function updateMouseInteractionState(mousePos)
  local cameraMovementType = M.state.cameraMovementType
  local hasRecentTriggerInteraction =
    M.state.crosshairHasTarget
    or M.state.currentlyUsedTrigger
    or (
      M.state.crosshairTargetScreenStream
      and (
        M.state.crosshairTargetScreenStream.x ~= nil
        or M.state.crosshairTargetScreenStream.y ~= nil
        or M.state.crosshairTargetScreenStream.action0 ~= nil
        or M.state.crosshairTargetScreenStream.action1 ~= nil
        or M.state.crosshairTargetScreenStream.action2 ~= nil
      )
    )

  if hasRecentTriggerInteraction then
    M.state.cursorVisible = true
    M.state.cursorVisibility = true
    local canvas = scenetree.findObject("Canvas")
    if canvas and canvas.showAndUnlockCursor then
      --canvas:showAndUnlockCursor()
    end
  end

  -- Track absolute-camera mouse movement from the moment the mode switches to absolute.
  if cameraMovementType ~= M.state.lastCameraMovementType then
    M.state.lastCameraMovementType = cameraMovementType
    if cameraMovementType == "absolute" and mousePos then
      setAbsoluteStartMousePos(mousePos)
      M.state.mouseInUse = false
    elseif cameraMovementType ~= "absolute" then
      M.state.absoluteMovementStartMousePos = nil
    end
  end

  if cameraMovementType == "absolute" then
    if M.state.absoluteMovementStartMousePos and mousePos then
      M.state.mouseInUse = mousePos.x ~= M.state.absoluteMovementStartMousePos.x or mousePos.y ~= M.state.absoluteMovementStartMousePos.y
    else
      M.state.mouseInUse = false
    end
    -- If camera rotation happens while still in absolute mode, hand control back from mouse.
    if M.state.mouseInUse and core_camera.timeSinceLastRotation and core_camera.timeSinceLastRotation() < 200 then
      M.state.mouseInUse = false
      if mousePos then
        setAbsoluteStartMousePos(mousePos)
      end
    end
  else
    M.state.mouseInUse = true
  end

  if not M.state.cursorVisible then
    M.state.mouseInUse = false
  end

  M.state.lastMousePos = mousePos
  M.state.useCursorCoordinates = (M.state.cursorVisible and M.state.mouseInUse) or cameraMovementType == "relative"
  if not M.state.canUseVehicleTriggerCrosshair then
    M.state.useCursorCoordinates = true
  end
  refreshAimModeState()
end

local function executeLink(vdata, lnk, actionValue, vehicleId)
  -- allow per-link value inversion from JBeam via {"invert": true}
  local value = actionValue
  if lnk and lnk.isInverted then
    value = -value
  end
  if lnk.version and lnk.version == 2 then
    --dump({'>>>>> executeLink', lnk.inputAction, actionValue, vehicleId})

    if lnk.namespace == 'vehicle' then
      if not vdata.inputActions[lnk.inputAction] then
        log('E', 'triggers', 'input action not found: ' .. tostring(lnk.inputAction))
        return 0
      end
      extensions.hook("onVehicleTriggersExecuteLink", lnk, actionValue, vehicleId)
      return core_input_actions.executeCommand(vdata.inputActions[lnk.inputAction], value, vehicleId)
    elseif lnk.namespace == 'common' then
      if lnk.commonLua then
        if not vdata.inputActions[lnk.inputAction] then
          log('E', 'triggers', 'input action not found: ' .. tostring(lnk.inputAction))
          return 0
        end
        extensions.hook("onVehicleTriggersExecuteLink", lnk, actionValue, vehicleId)
        return core_input_actions.executeCommand(vdata.inputActions[lnk.inputAction], value, vehicleId)
      end
      -- invoke c++ actionmap code
      if M.state.debugEnabled then
        ActionMap.debugEnabled = true
      end
      local triggerdBindingCount = ActionMap.triggerBindingByNameDigital(lnk.inputAction, actionValue > 0.9, os.clockhp(), vehicleId)
      if M.state.debugEnabled then
        ActionMap.debugEnabled = false
      end
      if M.state.debugEnabled and triggerdBindingCount == 0 then
        log('W', 'triggers', 'No binding triggered: ' .. tostring(lnk.inputAction) .. ' for value ' .. tostring(value) )
      end
    end

  else
  -- old: backward compatibility, using event section
    extensions.hook("onVehicleTriggersExecuteLink", lnk, actionValue, vehicleId)
    return core_input_actions.executeCommand(lnk.targetEvent, actionValue, vehicleId)
  end
  return 0
end

local function onCursorVisibilityChanged(visible)
  M.state.cursorVisibility = visible or VehicleTrigger.debug -- always visible in debug mode
  M.state.cursorVisible = M.state.cursorVisibility and not M.state.mouseLocked
end

local function onMouseLocked(locked)
  M.state.mouseLocked = locked
  M.state.cursorVisible = M.state.cursorVisibility and not M.state.mouseLocked
end

local function isControllerDeviceType(deviceType)
  return deviceType ~= "keyboard" and deviceType ~= "mouse"
end

-- Finds the best matching binding for an action.
-- Prefers controller bindings when last input is pad, otherwise prefers keyboard/mouse.
local function findBindingForAction(actionStr, desiredInverted)
  local preferredPad = core_camera and core_camera.getLastFilter and core_camera.getLastFilter() == FILTER_PAD
  local recentDevices = core_input_bindings.getRecentDevices and core_input_bindings.getRecentDevices() or {}
  local recentRank = {}
  for i, devname in ipairs(recentDevices) do
    recentRank[devname] = i
  end

  local bestDeviceName, bestBinding, bestScore = nil, nil, -math.huge

  for _, device in ipairs(core_input_bindings.bindings or {}) do
    local contents = device.contents or {}
    local deviceType = contents.devicetype
    for _, b in ipairs(contents.bindings or {}) do
      if b.action == actionStr and ((b.isInverted or false) == (desiredInverted or false)) then
        local score = 0
        local isController = isControllerDeviceType(deviceType)
        if preferredPad then
          if isController then score = score + 100 end
        else
          if deviceType == "keyboard" then
            score = score + 100
          elseif deviceType == "mouse" then
            score = score + 80
          end
        end

        local rank = recentRank[device.devname]
        if rank then
          score = score + math.max(0, 50 - rank)
        end

        if score > bestScore then
          bestScore = score
          bestDeviceName = device.devname
          bestBinding = b
        end
      end
    end
  end

  return bestDeviceName, bestBinding
end

local function isEnabled()
  local simPaused = simTimeAuthority.getPause() == true
  local simUnpaused = not simPaused
  local inPlayableContext = M.state.isPlayRoute or simUnpaused
  local cefCaptureBlocksInteraction = M.state.useCursorCoordinates and M.state.cefMouseCaptured
  local photomodeCaptureInProgress = false

  photomodeCaptureInProgress = ui_pause_photomode and ui_pause_photomode.isCaptureInProgress() == true or false

  M.state.allowInteraction = (
    not photomodeCaptureInProgress -- only disallow while photomode is actively taking a picture
    and M.state.cefVisible -- cef must be visible
    and inPlayableContext -- allow outside /play too, as long as the simulation is not paused
    and not cefCaptureBlocksInteraction -- CEF hover/capture should only block trigger interaction in cursor mode
    and not M.state.mouseLocked -- disable while mouse is locked
    and not (M.state.useCursorCoordinates and not M.state.cursorVisible) -- cursor mode requires visible cursor
  )
  return M.state.allowInteraction
end

local hoveredTriggerId = {}
local lastActionsList = nil
local hoveredActionTitles = nil
local hoveredTriggerColor = nil
local hoveredTriggerName = nil
local hoveredLabelPlacement = nil
local hoveredActionMapAvailability = { action0 = false, action1 = false, action2 = false }
local vehicleInteractionActionMapNames = {
  action0 = "VehicleInteraction0",
  action1 = "VehicleInteraction1",
  action2 = "VehicleInteraction2",
}
local vehicleInteractionActionMapsActive = { action0 = false, action1 = false, action2 = false }

local function clearHoveredActionMapAvailability()
  hoveredActionMapAvailability.action0 = false
  hoveredActionMapAvailability.action1 = false
  hoveredActionMapAvailability.action2 = false
end

local function syncVehicleInteractionActionMaps(desiredMaps)
  local desiredAction0 = desiredMaps and desiredMaps.action0 == true or false
  local desiredAction1 = desiredMaps and desiredMaps.action1 == true or false
  local desiredAction2 = desiredMaps and desiredMaps.action2 == true or false

  if desiredAction0 ~= vehicleInteractionActionMapsActive.action0 then
    if desiredAction0 then
      pushActionMap(vehicleInteractionActionMapNames.action0)
    else
      popActionMap(vehicleInteractionActionMapNames.action0)
    end
    vehicleInteractionActionMapsActive.action0 = desiredAction0
  end

  if desiredAction1 ~= vehicleInteractionActionMapsActive.action1 then
    if desiredAction1 then
      pushActionMap(vehicleInteractionActionMapNames.action1)
    else
      popActionMap(vehicleInteractionActionMapNames.action1)
    end
    vehicleInteractionActionMapsActive.action1 = desiredAction1
  end

  if desiredAction2 ~= vehicleInteractionActionMapsActive.action2 then
    if desiredAction2 then
      pushActionMap(vehicleInteractionActionMapNames.action2)
    else
      popActionMap(vehicleInteractionActionMapNames.action2)
    end
    vehicleInteractionActionMapsActive.action2 = desiredAction2
  end

  local anyActive = vehicleInteractionActionMapsActive.action0 or vehicleInteractionActionMapsActive.action1 or vehicleInteractionActionMapsActive.action2
  local anyDesired = desiredAction0 or desiredAction1 or desiredAction2
  M.state.vehicleInteractionActionMapDesired = anyDesired
  M.state.vehicleInteractionActionMapActive = anyActive
  M.state.vehicleInteractionActionMapsDesired.action0 = desiredAction0
  M.state.vehicleInteractionActionMapsDesired.action1 = desiredAction1
  M.state.vehicleInteractionActionMapsDesired.action2 = desiredAction2
  M.state.vehicleInteractionActionMapsActive.action0 = vehicleInteractionActionMapsActive.action0
  M.state.vehicleInteractionActionMapsActive.action1 = vehicleInteractionActionMapsActive.action1
  M.state.vehicleInteractionActionMapsActive.action2 = vehicleInteractionActionMapsActive.action2
end
local function clearBindingsLegend()
  if lastActionsList then
    lastActionsList = nil
    ui_bindingsLegend.addActions("vehicleTriggers", {})
  end
end

local function clearHoveredTargetState()
  M.state.hoveredHitPosWorld = nil
  M.state.hoveredHitPosScreen01 = nil
  hoveredActionTitles = nil
  hoveredTriggerColor = nil
  hoveredTriggerName = nil
  hoveredLabelPlacement = nil
  hoveredTriggerId.vehicleId = nil
  hoveredTriggerId.triggerId = nil
  clearHoveredActionMapAvailability()
end

local function normalizeTriggerColor(colorValue)
  if type(colorValue) ~= "table" then return {r = 0, g = 0, b = 1, a = 0.4} end
  local r = colorValue[1] or colorValue.r or colorValue.red
  local g = colorValue[2] or colorValue.g or colorValue.green
  local b = colorValue[3] or colorValue.b or colorValue.blue
  local a = colorValue[4] or colorValue.a or colorValue.alpha
  if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
  if type(a) ~= "number" then a = 1 end
  local function clamp01(v)
    return math.max(0, math.min(1, v))
  end
  return {
    r = clamp01(r),
    g = clamp01(g),
    b = clamp01(b),
    a = clamp01(a),
  }
end

local function handleCurrentlyUsedTrigger()
  M.state.crosshairHasTarget = true

  local vehicleObj = getObjectByID(M.state.currentlyUsedTrigger.v)
  if not vehicleObj then
    log("E", "", "Invalid vehicle id "..dumps(M.state.currentlyUsedTrigger.v).." for vehicle trigger "..dumps(M.state.currentlyUsedTrigger.t))
    return false
  end

  local triggerObj = vehicleObj:getTrigger(M.state.currentlyUsedTrigger.t)
  if not triggerObj then
    log("E", "", "Invalid vehicle trigger "..dumps(M.state.currentlyUsedTrigger.t).." for vehicle id "..dumps(M.state.currentlyUsedTrigger.v))
    return false
  end

  triggerObj:setUsedThisFrame() -- this will highlight the trigger visually
  return true
end

local function findHoveredTrigger()
  local hit = be:triggerRaycastClosest(getTriggerRaycastDistance(), M.state.useCursorCoordinates)
  if p then p:add("03a_raycast") end
  M.state.crosshairHasTarget = hit and hit.v ~= nil and hit.t ~= nil or false

  if not (hit and hit.v ~= nil and hit.t ~= nil) then
    M.state.hoveredHitPosWorld = nil
    M.state.hoveredHitPosScreen01 = nil
    hoveredLabelPlacement = nil
  end

  return hit
end

local function refreshHoveredLabelPlacement(hit)
  hoveredLabelPlacement = nil
  if not (hit and hit.v ~= nil and hit.t ~= nil) then return end

  local vehicleObj = getObjectByID(hit.v)
  local triggerObj = vehicleObj and vehicleObj:getTrigger(hit.t) or nil
  if not (vehicleObj and triggerObj) then return end

  local triggerCenter = triggerObj:getCenter()
  local triggerCenterScreen = nil
  if triggerCenter then
    local hoveredWorld = M.state.hoveredHitPosWorld or {}
    hoveredWorld.x = triggerCenter.x
    hoveredWorld.y = triggerCenter.y
    hoveredWorld.z = triggerCenter.z
    M.state.hoveredHitPosWorld = hoveredWorld
    triggerCenterScreen = worldPosToScreenPercent01(triggerCenter, M.state.hoveredHitPosScreen01 or {})
    M.state.hoveredHitPosScreen01 = triggerCenterScreen
  else
    M.state.hoveredHitPosWorld = nil
    M.state.hoveredHitPosScreen01 = nil
  end

  local vData = extensions.core_vehicle_manager.getVehicleData(hit.v)
  local triggerData = vData and vData.vdata and vData.vdata.triggers and vData.vdata.triggers[hit.t] or nil
  if core_vehicle_triggerLabelPlacement and core_vehicle_triggerLabelPlacement.computeForTrigger then
    hoveredLabelPlacement = core_vehicle_triggerLabelPlacement.computeForTrigger(
      vehicleObj,
      triggerObj,
      triggerData,
      worldPosToScreenPercent01,
      p
      ,
      triggerCenter,
      triggerCenterScreen
    )
  end
end

local function updateHoveredTriggerActions(hit)
  local changed = (hit and hit.v) ~= hoveredTriggerId.vehicleId or (hit and hit.t) ~= hoveredTriggerId.triggerId
  -- Rebuild action titles when they were temporarily cleared (e.g. one-frame interaction gate off)
  -- even if the hovered trigger id stayed the same.
  if not changed and hoveredActionTitles ~= nil then return end

  if not hit then
    clearBindingsLegend()
    hoveredActionTitles = nil
    hoveredTriggerColor = nil
    hoveredTriggerName = nil
    hoveredLabelPlacement = nil
    clearHoveredActionMapAvailability()
    return
  end

  hoveredActionTitles = nil
  hoveredTriggerColor = nil
  hoveredTriggerName = nil
  clearHoveredActionMapAvailability()
  local vData = extensions.core_vehicle_manager.getVehicleData(hit.v)
  if not (vData and vData.vdata and type(vData.vdata.triggers) == 'table') then return end

  local trigger = vData.vdata.triggers[hit.t]
  if not trigger then return end
  hoveredTriggerColor = normalizeTriggerColor(trigger.color)
  if type(trigger.name) == "string" and trigger.name ~= "" then
    hoveredTriggerName = trigger.name
  else
    hoveredTriggerName = string.format("%s:%s", tostring(hit.v), tostring(hit.t))
  end

  local linkByAction = vData.vdata.triggerEventLinksDict[hit.t] or {}
  local actionsList = {}
  local actionTitles = {}
  for actionIdx = 0, 2 do
    local actionKey = "action" .. tostring(actionIdx)
    local links = linkByAction[actionKey]
    local lnk = type(links) == "table" and links[1] or nil
    if lnk and lnk.inputAction then
      local actionName = lnk.inputAction
      local action = vData.vdata.inputActions[actionName]
      if action then
        actionTitles[actionKey] = action.title
        hoveredActionMapAvailability[actionKey] = true

        local actionStr = actionName
        if action.vehicle then
          actionStr = action.vehicle .. "__" .. actionStr
        end

        local desiredInverted = lnk.isInverted == true
        local bindingDev, actionBinding = findBindingForAction(actionStr, desiredInverted)
        if actionBinding and bindingDev then
          table.insert(actionsList, {action = actionStr, label = action.title, bindings = {{device = bindingDev, control = actionBinding.control}}})
        end
      end
    end
  end

  hoveredActionTitles = next(actionTitles) and actionTitles or nil
  if #actionsList > 0 then
    lastActionsList = actionsList
    ui_bindingsLegend.addActions("vehicleTriggers", actionsList, {priority = 8.1, hideConstant = true})
  else
    clearBindingsLegend()
  end
end

local function publishUiStreams(allowInteraction, suppressCrosshairThisFrame)
  if p then p:add("05a_publish_begin") end
  if not allowInteraction or suppressCrosshairThisFrame then
    if p then p:add("05a_branch_disallowed") end
    clearHoveredActionMapAvailability()
    hoveredTriggerColor = nil
    hoveredTriggerName = nil
    hoveredLabelPlacement = nil
    setCrosshairTargetStream(nil, nil, nil, nil, nil)
    if p then p:add("05a_disallowed_targetStream") end
    setCrosshairStream(false, false)
    if p then p:add("05a_disallowed_crosshairStream") end
    syncVehicleInteractionActionMaps(nil)
    if p then p:add("05a_disallowed_syncActionMaps") end
    return
  end

  if p then p:add("05a_branch_allowed") end
  local hoverScreen = M.state.hoveredHitPosScreen01
  if M.state.crosshairHasTarget and hoverScreen then
    if p then p:add("05a_allowed_hasTarget") end
    setCrosshairTargetStream(hoverScreen.x, hoverScreen.y, hoveredActionTitles, hoveredTriggerColor, hoveredLabelPlacement, hoveredTriggerName)
    if p then p:add("05a_allowed_targetStreamHovered") end
  else
    if p then p:add("05a_allowed_noTarget") end
    hoveredActionTitles = nil
    hoveredTriggerColor = nil
    hoveredTriggerName = nil
    hoveredLabelPlacement = nil
    setCrosshairTargetStream(nil, nil, nil, nil, nil)
    if p then p:add("05a_allowed_targetStreamCleared") end
  end

  -- Keep only the action maps that are valid for the currently hovered trigger.
  syncVehicleInteractionActionMaps(hoveredActionMapAvailability)
  if p then p:add("05a_allowed_syncActionMaps") end
  setCrosshairStream(M.state.useCursorCoordinates == false, M.state.crosshairHasTarget)
  if p then p:add("05a_allowed_crosshairStream") end
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if p then p:start() end

  -- 1) Refresh dynamic context and input-derived state.
  refreshPlayerContextState()
  updateWorldPosToScreenContext()
  local mousePos = im.GetMousePos()
  updateMouseInteractionState(mousePos)
  if p then p:add("01_refreshContextAndInput") end

  -- 2) Compute interaction gate and apply trigger system toggles.
  local allowInteraction = isEnabled()
  if not allowInteraction and M.state.currentlyUsedTrigger then
    M.state.currentlyUsedTrigger = nil
  end
  local renderFilterObjectId = M.state.isUnicycle and 0 or be:getPlayerVehicleID(0) -- restrict the triggers to your own vehicle unless you're in 1st person (you should use all vehicles triggers)
  renderFilterObjectId = 0 -- temporary change to allow interaction with all vehicles (such as attached trailers), to be reconsidered after some testing

  local disableTriggerSystemThisFrame = allowInteraction
    and not M.state.currentlyUsedTrigger
    and not M.state.mouseInUse
    and M.state.crosshairTimedOut

  VehicleTrigger.renderFilterObjectId = renderFilterObjectId
  VehicleTrigger.renderingEnabled = allowInteraction and not disableTriggerSystemThisFrame
  VehicleTrigger.enabled = allowInteraction and not disableTriggerSystemThisFrame
  if p then p:add("02_gateAndToggleTriggerSystem") end

  local suppressCrosshairThisFrame = disableTriggerSystemThisFrame
  local prof03aAdded = false
  local prof03bAdded = false
  local prof03cAdded = false

  -- 3) Process trigger interaction state (currently-used vs hovered).
  if allowInteraction then
    if M.state.currentlyUsedTrigger then
      if not handleCurrentlyUsedTrigger() then
        suppressCrosshairThisFrame = true
      end
    elseif disableTriggerSystemThisFrame then
      clearHoveredTargetState()
    else
      -- Refresh hovered raycast every frame, but throttle expensive label placement/projection work.
      local hit = findHoveredTrigger()
      if p then
        p:add("03a_findHoveredTrigger")
        prof03aAdded = true
      end
      if DEBUG_PROJECT_CORNERS_EVERY_FRAME then
        refreshHoveredLabelPlacement(hit)
      end
      if fpsLimiter:update(dtReal) then
        if not DEBUG_PROJECT_CORNERS_EVERY_FRAME then
          refreshHoveredLabelPlacement(hit)
        end
        if p then
          p:add("03b_refreshLabelPlacement")
          prof03bAdded = true
        end
        updateHoveredTriggerActions(hit)
        if p then
          p:add("03c_updateHoveredActions")
          prof03cAdded = true
        end
        hoveredTriggerId.vehicleId = hit and hit.v
        hoveredTriggerId.triggerId = hit and hit.t
      end
    end
  else
    clearBindingsLegend()
    clearHoveredTargetState()
  end
  if p then
    if not prof03aAdded then p:add("03a_findHoveredTrigger") end
    if not prof03bAdded then p:add("03b_refreshLabelPlacement") end
    if not prof03cAdded then p:add("03c_updateHoveredActions") end
  end

  -- 4) Update timeout state.
  updateCrosshairTimeout(dtReal)
  if M.state.crosshairTimedOut and not M.state.useCursorCoordinates then
    suppressCrosshairThisFrame = true
  end
  if p then p:add("04_updateTimeout") end

  -- 5) Publish UI-facing stream data in one place.
  publishUiStreams(allowInteraction, suppressCrosshairThisFrame)
  if p then
    p:add("05_publishUiStreams")
    p:finish(true)
  end
end

local function triggerEvent(actionStr, actionValue, triggerId, vehicleId, vdata)
  if not vdata.triggerEventLinksDict then return end
  if type(vdata.triggerEventLinksDict[triggerId]) ~= 'table' then return end
  if type(vdata.triggerEventLinksDict[triggerId][actionStr]) ~= 'table' then return end

  -- TODO: this is overly simplistic and serves as a prototype :)
  for _, lnk in pairs(vdata.triggerEventLinksDict[triggerId][actionStr]) do
    local actionsExecuted = executeLink(vdata, lnk, actionValue, vehicleId)
    if M.state.debugEnabled and actionsExecuted == 0 then
      local valuetext = tostring(actionValue)
      if actionValue == 1 then
        valuetext = valuetext .. ' [DOWN]'
      else
        valuetext = valuetext .. ' [UP]'
      end
      log('W', 'triggers', 'Nothing executed on value '.. valuetext .. ' for triggerEvent: ' .. dumps({lnk, actionValue}))
    end
  end
end

-- executed by C++ side (typically VR controllers)
local function triggerEventWithoutVdata(actionNum, actionValue, triggerId, vehicleId)
  local vData = extensions.core_vehicle_manager.getVehicleData(vehicleId)
  local actionStr = 'action'..tostring(actionNum)
  return triggerEvent(actionStr, actionValue, triggerId, vehicleId, vData.vdata)
end

local currentTriggerHit
-- typically executed by the input actions "triggerAction0" 1 and 2
local function onActionEvent(actionNumber, inputValue)
  --print(string.format("onActionEvent: %d, %f", actionNumber, inputValue))
  if inputValue == 0 and M.state.currentlyUsedTrigger then
    currentTriggerHit = M.state.currentlyUsedTrigger
    M.state.currentlyUsedTrigger = nil
  else
    if not isEnabled() then return false end
    currentTriggerHit = be:triggerRaycastClosest(getTriggerRaycastDistance(), M.state.useCursorCoordinates)
  end
  if not currentTriggerHit then return true end

  local vData = extensions.core_vehicle_manager.getVehicleData(currentTriggerHit.v)
  if vData and vData.vdata and type(vData.vdata.triggers) == 'table' then
    local trigger = vData.vdata.triggers[currentTriggerHit.t]
    if trigger then
      --print(inputValue)
      triggerEvent('action' .. tostring(actionNumber), inputValue, currentTriggerHit.t, currentTriggerHit.v, vData.vdata)
      if inputValue ~= 0 then
        M.state.currentlyUsedTrigger = currentTriggerHit
      end
    end
  end
end

local function onCefVisibilityChanged(cefVisible)
  M.state.cefVisible = cefVisible
  if not cefVisible then
    syncVehicleInteractionActionMaps(nil)
    setCrosshairTargetStream(nil, nil, nil, nil, nil)
    setCrosshairStream(false, false)
  end
end

local function enableDebugUI()
  setDebugEnabled(true)
end

local function disableDebugUI()
  setDebugEnabled(false)
end

local function onSerialize()
  syncVehicleInteractionActionMaps(nil)
  setCrosshairTargetStream(nil, nil, nil, nil, nil)
  setCrosshairStream(false, false)
  return {
    debugEnabled = M.state.debugEnabled,
  }
end

local function onDeserialized(data)
  if data then
    setDebugEnabled(data.debugEnabled == true)
  end
end

M.onCefVisibilityChanged = onCefVisibilityChanged
M.onUpdate = onUpdate
M.onActionEvent = onActionEvent
M.triggerEvent = triggerEvent
M.triggerEventWithoutVdata = triggerEventWithoutVdata
M.onCursorVisibilityChanged = onCursorVisibilityChanged
M.onMouseLocked = onMouseLocked
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.enableDebugUI = enableDebugUI
M.disableDebugUI = disableDebugUI
M.isEnabled = isEnabled
M.getTriggerRaycastDistance = getTriggerRaycastDistance
M.getCursorPercent01 = getCursorPercent01
M.worldPosToScreenPercent01 = worldPosToScreenPercent01

return M
