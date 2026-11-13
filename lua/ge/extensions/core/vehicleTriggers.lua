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

local normalTriggerDistance = 50
local unicycleTriggerDistance = 3
local w2sCamRight = vec3()
local w2sCamForward = vec3()
local w2sCamUp = vec3()
local w2sToPoint = vec3()
local w2sContextValid = false
local w2sContextCamPos = vec3()
local w2sContextHalfTan = 0
local w2sContextAspect = 0

local M = { state = {} }
M.dependencies = { "core_vehicle_triggerLabelPlacement", "core_input_actionFilter" }
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
M.state.currentlyUsedTriggers = {} -- currently held trigger hit, per player index
M.state.debugEnabled = false
M.state.crosshairVisibleStream = nil
M.state.crosshairHoveredStream = nil
M.state.crosshairVisible = false
M.state.activeCamName = "n/a"
M.state.timeSinceLastMovedMs = nil
M.state.crosshairTimedOut = false
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
local DEBUG_DRAW_WALKING_HELD_TRIGGER_LINE = true
local walkingHeldTriggerLineColor = ColorF(1, 0.25, 0, 1)

local crosshairStreamName = "vehicleTriggerCrosshairVisible"
local crosshairTargetStreamName = "vehicleTriggerCrosshairTarget"
local crosshairViewsStreamName = "vehicleTriggerCrosshairViews"
local lastCrosshairStreamVisible = nil
local lastCrosshairStreamHovered = nil
local reusedCrosshairTargetStreamPayload = {}
local lastCrosshairTargetX = nil
local lastCrosshairTargetY = nil
local lastCrosshairTargetAction0 = nil
local lastCrosshairTargetAction1 = nil
local lastCrosshairTargetAction2 = nil
local lastCrosshairTargetIcon0 = nil
local lastCrosshairTargetIcon1 = nil
local lastCrosshairTargetIcon2 = nil
local lastCrosshairTargetBindingAction0 = nil
local lastCrosshairTargetBindingAction1 = nil
local lastCrosshairTargetBindingAction2 = nil
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

local function rotateVecByQuatInPlace(outVec, qx, qy, qz, qw, inX, inY, inZ)
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

local function setCrosshairTargetStream(x, y, actionTitles, triggerColor, labelPlacement, hoveredTriggerName, bindingActions, actionIcons)
  if p then p:add("05b_targetStream_begin") end
  local xRounded = x and round(x*10000)/10000 or nil
  local yRounded = y and round(y*10000)/10000 or nil
  local action0 = actionTitles and actionTitles.action0 or nil
  local action1 = actionTitles and actionTitles.action1 or nil
  local action2 = actionTitles and actionTitles.action2 or nil
  local icon0 = actionIcons and actionIcons.action0 or nil
  local icon1 = actionIcons and actionIcons.action1 or nil
  local icon2 = actionIcons and actionIcons.action2 or nil
  local bindingAction0 = bindingActions and bindingActions.action0 or nil
  local bindingAction1 = bindingActions and bindingActions.action1 or nil
  local bindingAction2 = bindingActions and bindingActions.action2 or nil
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
    and icon0 == lastCrosshairTargetIcon0
    and icon1 == lastCrosshairTargetIcon1
    and icon2 == lastCrosshairTargetIcon2
    and bindingAction0 == lastCrosshairTargetBindingAction0
    and bindingAction1 == lastCrosshairTargetBindingAction1
    and bindingAction2 == lastCrosshairTargetBindingAction2
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
  lastCrosshairTargetIcon0 = icon0
  lastCrosshairTargetIcon1 = icon1
  lastCrosshairTargetIcon2 = icon2
  lastCrosshairTargetBindingAction0 = bindingAction0
  lastCrosshairTargetBindingAction1 = bindingAction1
  lastCrosshairTargetBindingAction2 = bindingAction2
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
  payload.icon0 = icon0
  payload.icon1 = icon1
  payload.icon2 = icon2
  payload.bindingAction0 = bindingAction0
  payload.bindingAction1 = bindingAction1
  payload.bindingAction2 = bindingAction2
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

-- one reticule per split screen view, the single player crosshair is centered by the UI itself
local crosshairViewsPayload = { views = {} }
local crosshairViewsDirty = false

local function setCrosshairView(index, player, x, y, hovered, visible)
  local views = crosshairViewsPayload.views
  local view = views[index]
  if not view then
    view = {}
    views[index] = view
    crosshairViewsDirty = true
  end
  if view.player ~= player or view.x ~= x or view.y ~= y or view.hovered ~= hovered or view.visible ~= visible then
    view.player, view.x, view.y, view.hovered, view.visible = player, x, y, hovered, visible
    crosshairViewsDirty = true
  end
  return view
end

local function publishCrosshairViews(count)
  local views = crosshairViewsPayload.views
  for i = #views, count + 1, -1 do
    views[i] = nil
    crosshairViewsDirty = true
  end
  if not crosshairViewsDirty then return end
  crosshairViewsDirty = false
  guihooks.triggerStream(crosshairViewsStreamName, crosshairViewsPayload)
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

local clientOrigin = Point2I(0, 0)

-- cursor position in window client pixels, plus the client size
local function getCursorClientXY()
  local canvas = scenetree.findObject("Canvas")
  if not canvas then return nil end
  if not canvas.getCursorPosXY or not canvas.getWindowClientSizeXY or not canvas.clientToScreenXY then return nil end

  local cursorX, cursorY = canvas:getCursorPosXY()
  local clientW, clientH = canvas:getWindowClientSizeXY()
  local clientOriginX, clientOriginY = canvas:clientToScreenXY(clientOrigin)
  if not cursorX or not clientW or not clientH or clientW <= 0 or clientH <= 0 or not clientOriginX or not clientOriginY then
    return nil
  end

  return cursorX - clientOriginX, cursorY - clientOriginY, clientW, clientH
end

local reusableMousePos = {}
local function getMousePos()
  local canvas = scenetree.findObject("Canvas")
  if not canvas or not canvas.getCursorPosXY then return nil end
  reusableMousePos.x, reusableMousePos.y = canvas:getCursorPosXY()
  return reusableMousePos
end

local function getCursorPercent01()
  local localX, localY, clientW, clientH = getCursorClientXY()
  if not localX then return nil end
  return {x = localX / clientW, y = localY / clientH}
end

local function updateWorldPosToScreenContext(ctxId, viewWidth, viewHeight)
  w2sContextValid = false
  if not core_camera or not core_camera.getPositionXYZ or not core_camera.getQuatXYZW then return false end
  local camX, camY, camZ = core_camera.getPositionXYZ(ctxId)
  local qx, qy, qz, qw = core_camera.getQuatXYZW(ctxId)
  if not camX or not qx then return false end

  if not viewWidth or not viewHeight then
    local canvas = scenetree.findObject("Canvas")
    if not canvas or not canvas.getWindowClientSizeXY then return false end
    viewWidth, viewHeight = canvas:getWindowClientSizeXY()
  end
  if not viewWidth or not viewHeight or viewWidth <= 0 or viewHeight <= 0 then return false end

  local fovRad = core_camera.getFovRad and core_camera.getFovRad(ctxId) or nil
  if not fovRad or fovRad <= 0 then return false end
  local aspect = viewWidth / viewHeight
  if aspect <= 0 then return false end

  local halfTan = math.tan(fovRad * 0.5)
  if halfTan == 0 then return false end

  rotateVecByQuatInPlace(w2sCamRight, qx, qy, qz, qw, 1, 0, 0)
  rotateVecByQuatInPlace(w2sCamForward, qx, qy, qz, qw, 0, 1, 0)
  rotateVecByQuatInPlace(w2sCamUp, qx, qy, qz, qw, 0, 0, 1)

  w2sContextCamPos:set(camX, camY, camZ)
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

local function isPlayerUnicycle(player)
  if not player or player == 0 then return M.state.isUnicycle end
  local vehicleData = core_vehicle_manager.getVehicleData(be:getPlayerVehicleID(player))
  return vehicleData and vehicleData.mainPartName == "unicycle" or false
end

local function getTriggerRaycastDistance(player)
  local activeCamName = core_camera and core_camera.getActiveCamName and core_camera.getActiveCamName(player or 0) or ""
  local isOccupantCam = activeCamName == "driver" or activeCamName:find("^occupant%.", 1) ~= nil
  local isFreeCam = (commands and commands.isFreeCamera and commands.isFreeCamera()) or activeCamName == "free"

  if isPlayerUnicycle(player) or isOccupantCam then
    return unicycleTriggerDistance
  end
  if isFreeCam then
    return normalTriggerDistance
  end
  return normalTriggerDistance
end

local splitScreenPlayersBuffer = {}
local splitScreenPlayers = nil
local function refreshSplitScreenPlayers()
  splitScreenPlayers = nil
  if render_splitScreen and render_splitScreen.getCurrentConfiguration() and not render_splitScreen.isSharedView() then
    splitScreenPlayers = render_splitScreen.getPlayers(splitScreenPlayersBuffer)
  end
end

local mousePlayer = -1 -- player owning a mouse device, -1 when nobody does
local mousePlayerDirty = true

local function getMousePlayer()
  if mousePlayerDirty then
    mousePlayerDirty = false
    mousePlayer = -1
    local assignedPlayers = core_input_bindings and core_input_bindings.getAssignedPlayers()
    if assignedPlayers then
      for deviceName, player in pairs(assignedPlayers) do
        if player and player >= 0 and string.startswith(deviceName, "mouse") then
          mousePlayer = player
          break
        end
      end
    end
  end
  return mousePlayer
end

-- like the single player aim mode: the mouse player points with the cursor as long as he keeps
-- using his mouse, and aims with the center of his view once he switches to a controller
local mousePlayerUsesCursor = true
local lastCursorX, lastCursorY

local function updateMousePlayerAimMode(mousePos)
  if not mousePos then return end
  local mouseMoved = lastCursorX ~= nil and (mousePos.x ~= lastCursorX or mousePos.y ~= lastCursorY)
  lastCursorX, lastCursorY = mousePos.x, mousePos.y
  if mouseMoved then mousePlayerUsesCursor = true end
end

local viewRects = {}
local function getViewRect(ctxId, rv)
  local rect = viewRects[ctxId]
  if not rect then
    local composite = rv.compositeRect
    local point, extent = composite.point, composite.extent
    rect = {x = point.x, y = point.y, w = extent.x, h = extent.y}
    viewRects[ctxId] = rect
  end
  return rect
end

-- ray through the mouse cursor inside the split-screen view of the given camera context.
-- nil when the cursor is unusable or hovering somebody else's view
local function getCursorRayInView(ctxId)
  if not mousePlayerUsesCursor or not M.state.cursorVisible then return nil end
  local rv = RenderViewManagerInstance and RenderViewManagerInstance:getView(ctxId)
  if not rv then return nil end

  local cursorX, cursorY = getCursorClientXY()
  if not cursorX then return nil end

  local rect = getViewRect(ctxId, rv)
  local viewX = cursorX - rect.x
  local viewY = cursorY - rect.y
  if viewX < 0 or viewY < 0 or viewX > rect.w or viewY > rect.h then return nil end

  local ok, pos, dir = rv:getUnprojectedRayPosDir(viewX, viewY)
  if not ok then return nil end
  return pos, dir
end

local raycastPos = vec3()
local raycastDir = vec3()

-- a player looking through his own camera context aims with the center of his view, except for the mouse player while he is in cursor aiming mode.
local function raycastForPlayer(player)
  local distance = getTriggerRaycastDistance(player)
  local ctxId = splitScreenPlayers and core_camera.getContextIdForPlayer(player or 0) or nil
  if ctxId then
    if (player or 0) == getMousePlayer() and mousePlayerUsesCursor then
      local cursorPos, cursorDir = getCursorRayInView(ctxId)
      if not cursorPos then return nil end
      return be:triggerRaycastClosestRay(cursorPos, cursorDir, distance)
    end
    raycastPos:set(core_camera.getPositionXYZ(ctxId))
    raycastDir:set(core_camera.getForwardXYZ(ctxId))
    return be:triggerRaycastClosestRay(raycastPos, raycastDir, distance)
  end
  return be:triggerRaycastClosest(distance, M.state.useCursorCoordinates)
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

  local enableFreeCameraCrosshair = isSettingEnabled("enableVehicleTriggerCrosshairFreeCamera")
  local enableWalkingCrosshair = isSettingEnabled("enableVehicleTriggerCrosshairWalkingMode")
  local enableInternalCameraCrosshair = isSettingEnabled("enableVehicleTriggerCrosshairInternalCameras")

  M.state.canUseVehicleTriggerCrosshair = (commands.isFreeCamera() and enableFreeCameraCrosshair) or (M.state.isUnicycle and enableWalkingCrosshair)
  if not M.state.canUseVehicleTriggerCrosshair and enableInternalCameraCrosshair then
    local playerVehicleId = be:getPlayerVehicleID(0)
    if playerVehicleId and playerVehicleId ~= -1 then
      local cameraDataByName = core_camera.getCameraDataById(playerVehicleId)
      local activeCamera = cameraDataByName and cameraDataByName[M.state.activeCamName]
      M.state.canUseVehicleTriggerCrosshair = activeCamera and activeCamera.canUseVehicleTriggerCrosshair == true or false
    end
  end
end

local crosshairTimeoutMs = 1500
local crosshairIdleMs = {} -- per player, every player fades out his own crosshair
local lastRotationAgeMs = {}

local function hasCrosshairTimedOut(player)
  return (crosshairIdleMs[player] or 0) > crosshairTimeoutMs
end

-- the crosshair fades out after a moment without camera rotation, it stays while it sits on a target
local function updateCrosshairTimeout(player, dtReal, holdOnTarget)
  local rotationAge = core_camera and core_camera.timeSinceLastRotation and core_camera.timeSinceLastRotation(player) or nil
  local previousAge = lastRotationAgeMs[player]
  local cameraMoved = rotationAge ~= nil and previousAge ~= nil and rotationAge < previousAge
  lastRotationAgeMs[player] = rotationAge

  local idleMs = crosshairIdleMs[player] or 0
  if cameraMoved then
    idleMs = 0
  elseif not holdOnTarget then
    idleMs = idleMs + (dtReal * 1000)
  end
  crosshairIdleMs[player] = idleMs

  return idleMs > crosshairTimeoutMs, idleMs
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
    or M.state.currentlyUsedTriggers[0]
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

local function executeLink(vdata, lnk, actionValue, vehicleId, player)
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
      extensions.hook("onVehicleTriggersExecuteLink", lnk, actionValue, vehicleId, player)
      return core_input_actions.executeCommand(vdata.inputActions[lnk.inputAction], value, vehicleId, player, lnk.triggerId)
    elseif lnk.namespace == 'common' then
      if lnk.commonLua then
        if not vdata.inputActions[lnk.inputAction] then
          log('E', 'triggers', 'input action not found: ' .. tostring(lnk.inputAction))
          return 0
        end
        extensions.hook("onVehicleTriggersExecuteLink", lnk, actionValue, vehicleId, player)
        return core_input_actions.executeCommand(vdata.inputActions[lnk.inputAction], value, vehicleId, player, lnk.triggerId)
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
    extensions.hook("onVehicleTriggersExecuteLink", lnk, actionValue, vehicleId, player)
    return core_input_actions.executeCommand(lnk.targetEvent, actionValue, vehicleId, player, lnk.triggerId)
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
local function findBindingForAction(actionStr, desiredInverted, player)
  local preferredPad = core_camera and core_camera.getLastFilter and core_camera.getLastFilter() == FILTER_PAD
  local recentDevices = core_input_bindings.getRecentDevices and core_input_bindings.getRecentDevices() or {}
  local assignedPlayers = player ~= nil and core_input_bindings.getAssignedPlayers and core_input_bindings.getAssignedPlayers() or nil
  local recentRank = {}
  for i, devname in ipairs(recentDevices) do
    recentRank[devname] = i
  end

  local bestDeviceName, bestBinding, bestScore = nil, nil, -math.huge

  for _, device in ipairs(core_input_bindings.bindings or {}) do
    local contents = device.contents or {}
    local deviceType = contents.devicetype
    for _, b in ipairs(contents.bindings or {}) do
      local assignedToPlayer = not assignedPlayers or assignedPlayers[device.devname] == player
      if assignedToPlayer and b.action == actionStr and ((b.isInverted or false) == (desiredInverted or false)) then
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

-- the vehicle configuration screen points and clicks at the vehicle itself, where a trigger would open
-- a door or take the player out of the seat
local function isVehicleConfigurationRoute(routeName)
  return type(routeName) == "string" and routeName:find("^pause%.vehicle%.configurationcombined") ~= nil
end

local function isEnabled()
  local simPaused = simTimeAuthority.getPause() == true
  local simUnpaused = not simPaused
  local inPlayableContext = (M.state.isPlayRoute or simUnpaused) and not isVehicleConfigurationRoute(M.state.currentRouteName)
  local cefCaptureBlocksInteraction = M.state.useCursorCoordinates and M.state.cefMouseCaptured
  local photomodeCaptureInProgress = false
  local capabilities = gameplay_discover_firstDrive_capabilities
  local firstDriveAllowsInteraction = not capabilities
    or not capabilities.isSessionActive
    or not capabilities.isSessionActive()
    or capabilities.isAllowed("vehicleTriggers")

  photomodeCaptureInProgress = ui_pause_photomode and ui_pause_photomode.isCaptureInProgress() == true or false
  local modalPopupOpen = core_input_bindings and core_input_bindings.isModalPopupOpen() or false

  M.state.allowInteraction = (
    firstDriveAllowsInteraction
    and not modalPopupOpen -- modal popups own the controller confirm button
    and not photomodeCaptureInProgress -- only disallow while photomode is actively taking a picture
    and M.state.cefVisible -- cef must be visible
    and inPlayableContext -- allow outside /play too, as long as the simulation is not paused
    and (
      splitScreenPlayers ~= nil -- split screen falls back to view center aiming, so an unusable cursor must not block anybody
      or (
        not cefCaptureBlocksInteraction -- CEF hover/capture should only block trigger interaction in cursor mode
        and not M.state.mouseLocked -- disable while mouse is locked
        and not (M.state.useCursorCoordinates and not M.state.cursorVisible) -- cursor mode requires visible cursor
      )
    )
  )
  return M.state.allowInteraction
end

local hoveredTriggerId = {}
local lastActionsList = nil
local hoveredActionTitles = nil
local hoveredActionIcons = nil
local hoveredBindingActions = nil
local hoveredTriggerColor = nil
local hoveredTriggerName = nil
local hoveredLabelPlacement = nil
local ALL_PLAYERS_MASK = -1
local hoveredActionMapAvailability = { action0 = 0, action1 = 0, action2 = 0 }
local actionMapMaskOwner = "vehicleTriggers"
local vehicleInteractionActionMapNames = {
  action0 = "VehicleInteraction0",
  action1 = "VehicleInteraction1",
  action2 = "VehicleInteraction2",
}
local vehicleInteractionActionMapsActive = { action0 = 0, action1 = 0, action2 = 0 }

local function clearHoveredActionMapAvailability()
  hoveredActionMapAvailability.action0 = 0
  hoveredActionMapAvailability.action1 = 0
  hoveredActionMapAvailability.action2 = 0
end

local function resolveTriggerActionPresentation(player, vehicleId, triggerId, trigger, actionKey, lnk, action)
  local data = {
    player = player or 0,
    vehicleId = vehicleId,
    triggerId = triggerId,
    trigger = trigger,
    actionKey = actionKey,
    link = lnk,
    action = action,
    actionName = lnk.inputAction,
    title = _tr(action.title),
  }
  extensions.hook("onVehicleTriggerActionLabel", data)
  return data
end

local function syncVehicleInteractionActionMaps(desiredMaps)
  local desiredAction0 = desiredMaps and desiredMaps.action0 or 0
  local desiredAction1 = desiredMaps and desiredMaps.action1 or 0
  local desiredAction2 = desiredMaps and desiredMaps.action2 or 0

  if desiredAction0 ~= vehicleInteractionActionMapsActive.action0 then
    if desiredAction0 ~= 0 then
      core_input_actionFilter.setActionMapPlayerMask(actionMapMaskOwner, vehicleInteractionActionMapNames.action0, desiredAction0)
      if vehicleInteractionActionMapsActive.action0 == 0 then
        pushActionMap(vehicleInteractionActionMapNames.action0)
      end
    else
      popActionMap(vehicleInteractionActionMapNames.action0)
      core_input_actionFilter.clearActionMapPlayerMask(actionMapMaskOwner, vehicleInteractionActionMapNames.action0)
    end
    vehicleInteractionActionMapsActive.action0 = desiredAction0
  end

  if desiredAction1 ~= vehicleInteractionActionMapsActive.action1 then
    if desiredAction1 ~= 0 then
      core_input_actionFilter.setActionMapPlayerMask(actionMapMaskOwner, vehicleInteractionActionMapNames.action1, desiredAction1)
      if vehicleInteractionActionMapsActive.action1 == 0 then
        pushActionMap(vehicleInteractionActionMapNames.action1)
      end
    else
      popActionMap(vehicleInteractionActionMapNames.action1)
      core_input_actionFilter.clearActionMapPlayerMask(actionMapMaskOwner, vehicleInteractionActionMapNames.action1)
    end
    vehicleInteractionActionMapsActive.action1 = desiredAction1
  end

  if desiredAction2 ~= vehicleInteractionActionMapsActive.action2 then
    if desiredAction2 ~= 0 then
      core_input_actionFilter.setActionMapPlayerMask(actionMapMaskOwner, vehicleInteractionActionMapNames.action2, desiredAction2)
      if vehicleInteractionActionMapsActive.action2 == 0 then
        pushActionMap(vehicleInteractionActionMapNames.action2)
      end
    else
      popActionMap(vehicleInteractionActionMapNames.action2)
      core_input_actionFilter.clearActionMapPlayerMask(actionMapMaskOwner, vehicleInteractionActionMapNames.action2)
    end
    vehicleInteractionActionMapsActive.action2 = desiredAction2
  end

  local anyActive = vehicleInteractionActionMapsActive.action0 ~= 0 or vehicleInteractionActionMapsActive.action1 ~= 0 or vehicleInteractionActionMapsActive.action2 ~= 0
  local anyDesired = desiredAction0 ~= 0 or desiredAction1 ~= 0 or desiredAction2 ~= 0
  M.state.vehicleInteractionActionMapDesired = anyDesired
  M.state.vehicleInteractionActionMapActive = anyActive
  M.state.vehicleInteractionActionMapsDesired.action0 = desiredAction0 ~= 0
  M.state.vehicleInteractionActionMapsDesired.action1 = desiredAction1 ~= 0
  M.state.vehicleInteractionActionMapsDesired.action2 = desiredAction2 ~= 0
  M.state.vehicleInteractionActionMapsActive.action0 = vehicleInteractionActionMapsActive.action0 ~= 0
  M.state.vehicleInteractionActionMapsActive.action1 = vehicleInteractionActionMapsActive.action1 ~= 0
  M.state.vehicleInteractionActionMapsActive.action2 = vehicleInteractionActionMapsActive.action2 ~= 0
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
  hoveredActionIcons = nil
  hoveredBindingActions = nil
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

local function handleCurrentlyUsedTrigger(player)
  local usedTrigger = M.state.currentlyUsedTriggers[player or 0]
  local vehicleObj = getObjectByID(usedTrigger.v)
  if not vehicleObj then
    log("E", "", "Invalid vehicle id "..dumps(usedTrigger.v).." for vehicle trigger "..dumps(usedTrigger.t))
    return false
  end

  local triggerObj = vehicleObj:getTrigger(usedTrigger.t)
  if not triggerObj then
    log("E", "", "Invalid vehicle trigger "..dumps(usedTrigger.t).." for vehicle id "..dumps(usedTrigger.v))
    return false
  end

  if DEBUG_DRAW_WALKING_HELD_TRIGGER_LINE and isPlayerUnicycle(player) then
    local cameraPos = core_camera.getPosition(core_camera.getContextIdForPlayer(player or 0))
    local triggerCenter = triggerObj:getCenter()
    if cameraPos and triggerCenter then
      debugDrawer:drawLine(cameraPos, triggerCenter, walkingHeldTriggerLineColor)
    end
  end

  triggerObj:setUsedThisFrame() -- this will highlight the trigger visually
  return true
end

local function findHoveredTrigger()
  local hit = raycastForPlayer(0)
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
  if not hit then
    clearBindingsLegend()
    hoveredActionTitles = nil
    hoveredActionIcons = nil
    hoveredBindingActions = nil
    hoveredTriggerColor = nil
    hoveredTriggerName = nil
    hoveredLabelPlacement = nil
    clearHoveredActionMapAvailability()
    return
  end

  hoveredActionTitles = nil
  hoveredActionIcons = nil
  hoveredBindingActions = nil
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
  local actionIcons = {}
  local bindingActions = {}
  for actionIdx = 0, 2 do
    local actionKey = "action" .. tostring(actionIdx)
    local links = linkByAction[actionKey]
    local lnk = type(links) == "table" and links[1] or nil
    if lnk and lnk.inputAction then
      local actionName = lnk.inputAction
      local action = vData.vdata.inputActions[actionName]
      if action then
        local presentation = resolveTriggerActionPresentation(0, hit.v, hit.t, trigger, actionKey, lnk, action)
        actionTitles[actionKey] = presentation.title
        actionIcons[actionKey] = presentation.icon
        if presentation.color then
          hoveredTriggerColor = normalizeTriggerColor(presentation.color)
        end
        hoveredActionMapAvailability[actionKey] = ALL_PLAYERS_MASK

        local actionStr = actionName
        if action.vehicle then
          actionStr = action.vehicle .. "__" .. actionStr
        end
        bindingActions[actionKey] = actionStr

        local desiredInverted = lnk.isInverted == true
        local bindingDev, actionBinding = findBindingForAction(actionStr, desiredInverted)
        if actionBinding and bindingDev then
          table.insert(actionsList, {action = actionStr, label = presentation.title, bindings = {{device = bindingDev, control = actionBinding.control}}})
        end
      end
    end
  end

  hoveredActionTitles = next(actionTitles) and actionTitles or nil
  hoveredActionIcons = next(actionIcons) and actionIcons or nil
  hoveredBindingActions = next(bindingActions) and bindingActions or nil
  if #actionsList > 0 then
    lastActionsList = actionsList
    ui_bindingsLegend.addActions("vehicleTriggers", actionsList, {priority = 8.1, hideConstant = true})
  else
    clearBindingsLegend()
  end
end

local function collectTriggerActionAvailability(hit, out, playerMask)
  if not (hit and hit.v ~= nil and hit.t ~= nil) then return end
  local vData = extensions.core_vehicle_manager.getVehicleData(hit.v)
  local linkByAction = vData and vData.vdata and vData.vdata.triggerEventLinksDict and vData.vdata.triggerEventLinksDict[hit.t]
  if not linkByAction then return end
  for actionIdx = 0, 2 do
    local actionKey = "action" .. tostring(actionIdx)
    local links = linkByAction[actionKey]
    local lnk = type(links) == "table" and links[1] or nil
    if lnk and lnk.inputAction and vData.vdata.inputActions[lnk.inputAction] then
      out[actionKey] = bit.bor(out[actionKey], playerMask)
    end
  end
end

local splitScreenTargetFields = {
  "targetX", "targetY",
  "action0", "action1", "action2",
  "icon0", "icon1", "icon2",
  "bindingAction0", "bindingAction1", "bindingAction2",
  "colorR", "colorG", "colorB", "colorA",
  "labelX", "labelY", "labelTx", "labelTy",
}

local function setCrosshairViewValue(view, key, value)
  if view[key] == value then return end
  view[key] = value
  crosshairViewsDirty = true
end

local function clearCrosshairViewTarget(view)
  setCrosshairViewValue(view, "targetPlayer", nil)
  setCrosshairViewValue(view, "vehicleId", nil)
  setCrosshairViewValue(view, "triggerId", nil)
  for _, key in ipairs(splitScreenTargetFields) do
    setCrosshairViewValue(view, key, nil)
  end
end

local function updateCrosshairViewTarget(view, hit, ctxId, refreshPlacement)
  if not (view and hit and hit.v ~= nil and hit.t ~= nil) then
    if view then clearCrosshairViewTarget(view) end
    return
  end

  local targetChanged = view.targetPlayer ~= view.player or view.vehicleId ~= hit.v or view.triggerId ~= hit.t
  if not targetChanged and not refreshPlacement then return end

  local vData = extensions.core_vehicle_manager.getVehicleData(hit.v)
  local triggerData = vData and vData.vdata and vData.vdata.triggers and vData.vdata.triggers[hit.t] or nil
  local vehicleObj = getObjectByID(hit.v)
  local triggerObj = vehicleObj and vehicleObj:getTrigger(hit.t) or nil
  if not (triggerData and vehicleObj and triggerObj) then
    clearCrosshairViewTarget(view)
    return
  end

  setCrosshairViewValue(view, "targetPlayer", view.player)
  setCrosshairViewValue(view, "vehicleId", hit.v)
  setCrosshairViewValue(view, "triggerId", hit.t)

  local linkByAction = vData.vdata.triggerEventLinksDict and vData.vdata.triggerEventLinksDict[hit.t] or {}
  local inputActions = vData.vdata.inputActions or {}
  local actionColor
  for actionIdx = 0, 2 do
    local actionKey = "action" .. tostring(actionIdx)
    local links = linkByAction[actionKey]
    local lnk = type(links) == "table" and links[1] or nil
    local action = lnk and lnk.inputAction and inputActions[lnk.inputAction] or nil
    local presentation = action and resolveTriggerActionPresentation(view.player, hit.v, hit.t, triggerData, actionKey, lnk, action) or nil
    setCrosshairViewValue(view, actionKey, presentation and presentation.title or nil)
    setCrosshairViewValue(view, "icon" .. tostring(actionIdx), presentation and presentation.icon or nil)
    actionColor = presentation and presentation.color or actionColor
    local bindingAction = nil
    if action then
      bindingAction = action.vehicle and action.vehicle .. "__" .. lnk.inputAction or lnk.inputAction
      local bindingDev, actionBinding = findBindingForAction(bindingAction, lnk.isInverted == true, view.player)
      if not (bindingDev and actionBinding) then bindingAction = nil end
    end
    setCrosshairViewValue(view, "bindingAction" .. tostring(actionIdx), bindingAction)
  end

  local color = normalizeTriggerColor(actionColor or triggerData.color)
  setCrosshairViewValue(view, "colorR", color and color.r or nil)
  setCrosshairViewValue(view, "colorG", color and color.g or nil)
  setCrosshairViewValue(view, "colorB", color and color.b or nil)
  setCrosshairViewValue(view, "colorA", color and color.a or nil)

  local rv = RenderViewManagerInstance and RenderViewManagerInstance:getView(ctxId)
  local viewRect = rv and getViewRect(ctxId, rv) or nil
  if not (viewRect and updateWorldPosToScreenContext(ctxId, viewRect.w, viewRect.h)) then
    setCrosshairViewValue(view, "targetX", nil)
    setCrosshairViewValue(view, "targetY", nil)
    setCrosshairViewValue(view, "labelX", nil)
    setCrosshairViewValue(view, "labelY", nil)
    setCrosshairViewValue(view, "labelTx", nil)
    setCrosshairViewValue(view, "labelTy", nil)
    return
  end

  local triggerCenter = triggerObj:getCenter()
  local triggerCenterScreen = triggerCenter and worldPosToScreenPercent01(triggerCenter, {}) or nil
  setCrosshairViewValue(view, "targetX", triggerCenterScreen and triggerCenterScreen.x or nil)
  setCrosshairViewValue(view, "targetY", triggerCenterScreen and triggerCenterScreen.y or nil)

  local placement = core_vehicle_triggerLabelPlacement.computeForTrigger(
    vehicleObj,
    triggerObj,
    triggerData,
    worldPosToScreenPercent01,
    p,
    triggerCenter,
    triggerCenterScreen
  )
  setCrosshairViewValue(view, "labelX", placement and placement.labelX or nil)
  setCrosshairViewValue(view, "labelY", placement and placement.labelY or nil)
  setCrosshairViewValue(view, "labelTx", placement and placement.labelTx or nil)
  setCrosshairViewValue(view, "labelTy", placement and placement.labelTy or nil)
end

local function canPlayerUseCrosshair(player)
  local activeCamName = core_camera.getActiveCamName(player) or ""
  local canUse = activeCamName == "free" or (isPlayerUnicycle(player) and isSettingEnabled("enableVehicleTriggerCrosshairWalkingMode"))
  if not canUse and isSettingEnabled("enableVehicleTriggerCrosshairInternalCameras") then
    local vehicleId = be:getPlayerVehicleID(player)
    if vehicleId and vehicleId ~= -1 then
      local cameraDataByName = core_camera.getCameraDataById(vehicleId)
      local activeCamera = cameraDataByName and cameraDataByName[activeCamName]
      canUse = activeCamera and activeCamera.canUseVehicleTriggerCrosshair == true or false
    end
  end
  return canUse
end

-- returns the middle of the player's view, in window coordinates for the UI
local function computeViewCenter01(ctxId)
  local rv = RenderViewManagerInstance and RenderViewManagerInstance:getView(ctxId)
  if not rv then return nil end
  local canvas = scenetree.findObject("Canvas")
  if not canvas or not canvas.getWindowClientSizeXY then return nil end
  local clientW, clientH = canvas:getWindowClientSizeXY()
  if not clientW or not clientH or clientW <= 0 or clientH <= 0 then return nil end

  local rect = getViewRect(ctxId, rv)
  return (rect.x + rect.w * 0.5) / clientW, (rect.y + rect.h * 0.5) / clientH
end

local viewCenterX, viewCenterY = {}, {}
local function onSplitScreenLayoutChanged()
  table.clear(viewCenterX)
  table.clear(viewCenterY)
  table.clear(viewRects)
end

local function getViewCenter01(ctxId)
  if not ctxId then return nil end
  local x = viewCenterX[ctxId]
  if x == nil then -- a missing center means the view was not ready yet, so it keeps being retried
    x, viewCenterY[ctxId] = computeViewCenter01(ctxId)
    viewCenterX[ctxId] = x
  end
  return x, viewCenterY[ctxId]
end

local splitScreenActionAvailability = { action0 = 0, action1 = 0, action2 = 0 }
local splitScreenHits = {}

local function updateSplitScreen(players, dtReal)
  local allowInteraction = isEnabled()
  VehicleTrigger.renderFilterObjectId = 0
  VehicleTrigger.renderingEnabled = allowInteraction
  VehicleTrigger.proximityRenderingEnabled = false -- one player's aim would reveal triggers in every view
  VehicleTrigger.enabled = allowInteraction
  M.state.crosshairHasTarget = false
  clearBindingsLegend()
  setCrosshairTargetStream(nil, nil, nil, nil, nil)
  setCrosshairStream(false, false)

  if not allowInteraction then
    table.clear(M.state.currentlyUsedTriggers)
    clearHoveredTargetState()
    syncVehicleInteractionActionMaps(nil)
    publishCrosshairViews(0)
    return
  end

  local availability = splitScreenActionAvailability
  availability.action0, availability.action1, availability.action2 = 0, 0, 0
  table.clear(splitScreenHits)
  local refreshTargetPlacement = fpsLimiter:update(dtReal)
  local crosshairViewCount = 0
  for _, player in ipairs(players) do
    local usesCursor = player == getMousePlayer() and mousePlayerUsesCursor
    local canUseCrosshair = canPlayerUseCrosshair(player)
    local timedOut = not usesCursor and hasCrosshairTimedOut(player)
    local canAimAtTriggers = usesCursor or (canUseCrosshair and not timedOut)
    local hit = M.state.currentlyUsedTriggers[player]
    if hit then
      if not handleCurrentlyUsedTrigger(player) then
        M.state.currentlyUsedTriggers[player] = nil
        hit = nil
      end
    elseif canAimAtTriggers then
      hit = raycastForPlayer(player)
    end
    collectTriggerActionAvailability(hit, availability, bit.lshift(1, player))
    if hit then splitScreenHits[#splitScreenHits + 1] = hit end

    timedOut = updateCrosshairTimeout(player, dtReal, hit ~= nil and not usesCursor)
    local ctxId = core_camera.getContextIdForPlayer(player)
    local x, y = getViewCenter01(ctxId)
    if x then
      local visible = not usesCursor and not timedOut and canUseCrosshair
      crosshairViewCount = crosshairViewCount + 1
      local view = setCrosshairView(crosshairViewCount, player, x, y, visible and hit ~= nil, visible)
      updateCrosshairViewTarget(view, hit, ctxId, refreshTargetPlacement)
    end
  end
  publishCrosshairViews(crosshairViewCount)
  for _, hit in ipairs(splitScreenHits) do
    local vehicleObj = getObjectByID(hit.v)
    local triggerObj = vehicleObj and vehicleObj:getTrigger(hit.t)
    if triggerObj then triggerObj:setHitThisFrame() end
  end
  syncVehicleInteractionActionMaps(availability)
end

local function publishUiStreams(allowInteraction, suppressCrosshairThisFrame)
  if p then p:add("05a_publish_begin") end
  publishCrosshairViews(0)
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
    setCrosshairTargetStream(hoverScreen.x, hoverScreen.y, hoveredActionTitles, hoveredTriggerColor, hoveredLabelPlacement, hoveredTriggerName, hoveredBindingActions, hoveredActionIcons)
    if p then p:add("05a_allowed_targetStreamHovered") end
  else
    if p then p:add("05a_allowed_noTarget") end
    hoveredActionTitles = nil
    hoveredBindingActions = nil
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
  refreshSplitScreenPlayers()
  refreshPlayerContextState()
  updateWorldPosToScreenContext()
  local mousePos = getMousePos()
  updateMouseInteractionState(mousePos)
  if p then p:add("01_refreshContextAndInput") end

  if splitScreenPlayers then
    updateMousePlayerAimMode(mousePos)
    updateSplitScreen(splitScreenPlayers, dtReal)
    if p then p:finish(true) end
    return
  end

  -- 2) Compute interaction gate and apply trigger system toggles.
  local allowInteraction = isEnabled()
  if not allowInteraction and M.state.currentlyUsedTriggers[0] then
    M.state.currentlyUsedTriggers[0] = nil
  end
  local renderFilterObjectId = M.state.isUnicycle and 0 or be:getPlayerVehicleID(0) -- restrict the triggers to your own vehicle unless you're in 1st person (you should use all vehicles triggers)
  renderFilterObjectId = 0 -- temporary change to allow interaction with all vehicles (such as attached trailers), to be reconsidered after some testing

  local disableTriggerSystemThisFrame = allowInteraction
    and not M.state.currentlyUsedTriggers[0]
    and not M.state.mouseInUse
    and M.state.crosshairTimedOut

  VehicleTrigger.renderFilterObjectId = renderFilterObjectId
  VehicleTrigger.renderingEnabled = allowInteraction and not disableTriggerSystemThisFrame
  VehicleTrigger.proximityRenderingEnabled = true
  -- highlights read trigger positions from the engine, which only updates them while the trigger system is enabled
  local hasHighlights = core_vehicle_vehicleTriggerHighlight and core_vehicle_vehicleTriggerHighlight.hasHighlightedTriggers()
  VehicleTrigger.enabled = (allowInteraction and not disableTriggerSystemThisFrame) or hasHighlights == true
  if p then p:add("02_gateAndToggleTriggerSystem") end

  local suppressCrosshairThisFrame = disableTriggerSystemThisFrame
  local prof03aAdded = false
  local prof03bAdded = false
  local prof03cAdded = false

  -- 3) Process trigger interaction state (currently-used vs hovered).
  if allowInteraction then
    if M.state.currentlyUsedTriggers[0] then
      M.state.crosshairHasTarget = true
      if not handleCurrentlyUsedTrigger(0) then
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
  M.state.crosshairTimedOut, M.state.timeSinceLastMovedMs =
    updateCrosshairTimeout(0, dtReal, M.state.crosshairHasTarget and not M.state.useCursorCoordinates)
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

local function triggerEvent(actionStr, actionValue, triggerId, vehicleId, vdata, player)
  if not vdata.triggerEventLinksDict then return end
  if type(vdata.triggerEventLinksDict[triggerId]) ~= 'table' then return end
  if type(vdata.triggerEventLinksDict[triggerId][actionStr]) ~= 'table' then return end

  -- TODO: this is overly simplistic and serves as a prototype :)
  for _, lnk in pairs(vdata.triggerEventLinksDict[triggerId][actionStr]) do
    local actionsExecuted = executeLink(vdata, lnk, actionValue, vehicleId, player)
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
local function triggerEventWithoutVdata(actionNum, actionValue, triggerId, vehicleId, player)
  local vData = extensions.core_vehicle_manager.getVehicleData(vehicleId)
  local actionStr = 'action'..tostring(actionNum)
  return triggerEvent(actionStr, actionValue, triggerId, vehicleId, vData.vdata, player)
end

local currentTriggerHit
-- typically executed by the input actions "triggerAction0" 1 and 2
local function onActionEvent(actionNumber, inputValue, player)
  --print(string.format("onActionEvent: %d, %f, player %s", actionNumber, inputValue, tostring(player)))
  player = player or 0
  if inputValue == 0 and M.state.currentlyUsedTriggers[player] then
    currentTriggerHit = M.state.currentlyUsedTriggers[player]
    M.state.currentlyUsedTriggers[player] = nil
  else
    if not isEnabled() then return false end
    local usesCursor = player == getMousePlayer() and mousePlayerUsesCursor
    if splitScreenPlayers and not usesCursor and (not canPlayerUseCrosshair(player) or hasCrosshairTimedOut(player)) then return false end
    currentTriggerHit = raycastForPlayer(player)
  end
  if not currentTriggerHit then return true end

  local vData = extensions.core_vehicle_manager.getVehicleData(currentTriggerHit.v)
  if vData and vData.vdata and type(vData.vdata.triggers) == 'table' then
    local trigger = vData.vdata.triggers[currentTriggerHit.t]
    if trigger then
      --print(inputValue)
      triggerEvent('action' .. tostring(actionNumber), inputValue, currentTriggerHit.t, currentTriggerHit.v, vData.vdata, player)
      if inputValue ~= 0 then
        M.state.currentlyUsedTriggers[player] = currentTriggerHit
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
  core_input_actionFilter.clearActionMapPlayerMasks(actionMapMaskOwner)
  if data then
    setDebugEnabled(data.debugEnabled == true)
  end
end

local function onExtensionUnloaded()
  syncVehicleInteractionActionMaps(nil)
  core_input_actionFilter.clearActionMapPlayerMasks(actionMapMaskOwner)
  VehicleTrigger.renderingEnabled = false
  VehicleTrigger.enabled = false
end

local function onInputBindingsChanged()
  mousePlayerDirty = true
end

-- devices ordered by recent activity: the keyboard aims with neither, so the most recent mouse or
-- controller of the mouse player decides how he aims
local function onRecentDevicesChanged(recentDevices)
  local player = getMousePlayer()
  if player < 0 or not recentDevices then return end
  local assignedPlayers = core_input_bindings and core_input_bindings.getAssignedPlayers()
  if not assignedPlayers then return end

  for _, deviceName in ipairs(recentDevices) do
    if assignedPlayers[deviceName] == player and not string.startswith(deviceName, "keyboard") then
      mousePlayerUsesCursor = string.startswith(deviceName, "mouse")
      break
    end
  end
end

M.onExtensionUnloaded = onExtensionUnloaded
M.onCefVisibilityChanged = onCefVisibilityChanged
M.onUpdate = onUpdate
M.onActionEvent = onActionEvent
M.triggerEvent = triggerEvent
M.triggerEventWithoutVdata = triggerEventWithoutVdata
M.onCursorVisibilityChanged = onCursorVisibilityChanged
M.onMouseLocked = onMouseLocked
M.onInputBindingsChanged = onInputBindingsChanged
M.onRecentDevicesChanged = onRecentDevicesChanged
M.onSplitScreenLayoutChanged = onSplitScreenLayoutChanged
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.enableDebugUI = enableDebugUI
M.disableDebugUI = disableDebugUI
M.isEnabled = isEnabled
M.getTriggerRaycastDistance = getTriggerRaycastDistance
M.getCursorPercent01 = getCursorPercent01
M.worldPosToScreenPercent01 = worldPosToScreenPercent01

return M
