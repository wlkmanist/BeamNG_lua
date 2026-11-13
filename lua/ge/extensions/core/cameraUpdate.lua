-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Per-frame camera update loop, split out of core/camera.lua. The main player view
-- and extra RenderView contexts (split-screen, video stream) are processed separately:
-- they share the same camera modes, but OpenXR, shadows, SSAO and the onCameraPreRender
-- hook only run on the main view. core_camera injects its state + helpers via setup()
-- and exposes M.onPreRender / M.onClientPostStartMission as its callbacks.

local cameraInput = require('core/cameraInput')

local M = {}

-- injected by core/camera.lua (its shared state + selection/registry/config helpers)
local extraContexts, mainContext, moveManager
local getGlobalCameras, getVehicleData, getRunningCamsOrder
local setGlobalCameraByName, set, vehicleChanged
local isInsideBasedOnCameras, isUnicycle
local cameraM

function M.setup(deps)
  extraContexts = deps.extraContexts
  mainContext = deps.mainContext
  moveManager = deps.moveManager
  getGlobalCameras = deps.getGlobalCameras
  getVehicleData = deps.getVehicleData
  getRunningCamsOrder = deps.getRunningCamsOrder
  setGlobalCameraByName = deps.setGlobalCameraByName
  set = deps.set
  vehicleChanged = deps.vehicleChanged
  isInsideBasedOnCameras = deps.isInsideBasedOnCameras
  isUnicycle = deps.isUnicycle
  cameraM = deps.cameraM
end

-- sun shadow distance scale when attached to a vehicle, 0.5 of 1500 is a 750m cap, kept generous
-- enough that big and distant casters still cast shadows, the shorter range packs more resolution into
-- the fixed cascade layout so it is sharper than the full range detached camera
local drivingShadowDistanceScale = 0.5
local lastShadowDistanceScale = nil
local lastSdsmFitEnabled = nil

-- Reduces the SSAO radius when the camera is inside the vehicle interior
local isCameraInsidePrevious -- nil until the first update, so a level load re-applies a known radius
local function updateInteriorSSAO(veh)
  local camPos = mainContext.finalCameraData.pos
  local isCameraInsideNow = false

  -- no vehicle, a unicycle or a vehicle without camera data all count as outside, so the radius
  -- always returns to the exterior value instead of staying stuck at the interior one
  if veh then
    local vehId = veh:getId()
    local vdata = getVehicleData()[vehId]
    if vdata and not isUnicycle(vehId) then
      isCameraInsideNow = isInsideBasedOnCameras(camPos, veh, vdata, 0.6)
    end
  end

  if isCameraInsideNow ~= isCameraInsidePrevious and not (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then
    local inside = isCameraInsideNow and veh:getSpawnWorldOOBB():isContained(camPos)
    if scenetree.SSAOPostFx then scenetree.SSAOPostFx:setRadiusTarget((inside and 0.5) or 1.5) end
  end
  isCameraInsidePrevious = isCameraInsideNow
end

-- level-defined nearClip handling
local levelNearClip
local function getLevelNearClip()
  if levelNearClip == nil then
    if not VariableRegistry.get("$loadingLevel") then
      levelNearClip = scenetree.theLevelInfo and scenetree.theLevelInfo.nearClip
      levelNearClip = levelNearClip or false -- disables re-checking if the map has no nearclip
    end
  end
  return levelNearClip
end

function M.onClientPostStartMission()
  levelNearClip = nil
  isCameraInsidePrevious = nil
end

-- guard against sending NaN and inf to C++, which will put it in an unrecoverable
-- state (validData/lastValidData are per context)
local function validateData(ctx, data)
  local lastValidData = ctx.lastValidData
  local valid = not(isnaninf(data.res.fov + data.res.pos:squaredLength()) or isnaninf(data.res.rot:squaredNorm()))
  if valid then
    -- all is ok, let's save this data for render
    lastValidData.fov = data.res.fov
    lastValidData.pos:set(data.res.pos)
    lastValidData.rot:set(data.res.rot)
  else
    if ctx.validData ~= valid then
      log("E", "", "Invalid camera calculations detected (should only happen after a vehicle instability)")
      log("D", "", "Attempting to fix invalid camera data: "..dumps(data))
    end
    data.res.fov = lastValidData.fov
    data.res.pos:set(lastValidData.pos)
    data.res.rot:set(lastValidData.rot)
  end
  ctx.validData = valid
  return valid
end

local function updateCameraData(ctx)
  local res = ctx.camData.res
  ctx.finalCameraData.pos:set(res.pos)
  ctx.finalCameraData.rot:set(res.rot)
  ctx.finalCameraData.fovDeg = res.fov
end

local function notifyCameraChanged(ctx, camName, vid)
  if camName == ctx.lastCamName and vid == ctx.lastCamVid then return end
  ctx.lastCamName = camName
  ctx.lastCamVid = vid
  extensions.hook("onCameraChanged", ctx.player or 0, camName, vid)
end

-- Fill camData for this frame and detect vehicle switches. Shared by main and extra views.
local function beginContextUpdate(ctx, dtReal, dtSim, dtRaw)
  local camData = ctx.camData
  local player = ctx.player or 0
  local veh = getPlayerVehicle(ctx.vehiclePlayer or player) -- vehicle (and its cameras) may come from a different seat than the input player
  local vid = veh and veh:getId()

  -- fixup res if a reference in it has been altered
  camData.resPos:set(camData.pos)
  camData.resTargetPos:set(0, 0, 0)
  camData.resRot:set(0,0,0,1)
  camData.res.pos = camData.resPos
  camData.res.targetPos = camData.resTargetPos
  camData.res.rot = camData.resRot
  camData.res.ortho = false -- perspective unless the active camera opts into orthographic (topDown); reset so it can't leak between modes

  camData.veh = veh
  camData.vid = vid
  camData.player = player -- seat this view follows; lets camera modes address their own view
  camData.dtSim = dtSim * cameraM.speedFactor-- smoothed dt used by physics, includes time scaling
  camData.dtReal = dtReal * cameraM.speedFactor -- smoothed gfx render dt
  camData.dtRaw = dtRaw  * cameraM.speedFactor -- gfx render dt, in seconds from wall clock
  camData.dt = dtReal * cameraM.speedFactor
  camData.prevPos:set(camData.pos)
  camData.prevVehPos:set(camData.vehPos)
  camData.renderView = ctx.renderView -- the gameengine.lua output filter sends res to this RenderView
  camData.openxrSessionRunning = false

  if veh then
    camData.pos:set(veh:getPositionXYZ()) -- scene object position - this jumps on the floating point grid
    camData.vehPos:set(veh:getRefNodeAbsPositionXYZ()) -- vehicle's actual position on a double precision grid
  else
    camData.pos:set(0,0,0)
    camData.vehPos:set(0,0,0)
  end

  local paused = dtSim < 0.00001
  if paused then
    camData.teleported = false
  else
    camData.prevVel:set(camData.vel)
    camData.vel:set(camData.vehPos)
    camData.vel:setSub(camData.prevVehPos)
    camData.vel:setScaled(1/dtSim)
    camData.teleported = objectTeleported(camData.pos, camData.prevPos, camData.prevVel, dtSim)
    if camData.teleported then
      camData.vel:set(0,0,0)
    end
  end

  if veh and vid ~= ctx.lastVehicleId then
    vehicleChanged(ctx.lastVehicleId, vid, ctx)
    ctx.lastVehicleId = vid
  end

  camData.res.targetPos:set(camData.pos)   -- tracked target
  camData.res.fov = 60
  camData.res.nearClip = getLevelNearClip() or 0.1 -- choose a sane default if the level hasn't defined a nearclip

  return camData, veh, vid
end

-- Drive the selected global or vehicle camera. globalCam is the context's active global camera
-- (nil drives the vehicle camera), resolved by the caller since main also needs it for shadows. Returns:
--   'ok'        camera updated, run filters
--   'abort'     nothing this frame (no vdata, or orbit fallback already applied)
--   'need-free' vehicle cam missing and orbit missing; caller last-resorts to free cam
-- Second return is true when a global camera update() succeeded (main fires onCameraPreRender).
local function updateSelectedCamera(ctx, camData, vid, globalCam)
  if globalCam then
    notifyCameraChanged(ctx, ctx.activeGlobalCameraName, vid)
    if globalCam:update(camData) then
      return 'ok', true
    end
    setGlobalCameraByName(nil, nil, nil, ctx)
    return 'ok', false
  end

  local vdata = getVehicleData(ctx)[vid]
  if not vdata then
    return 'abort'
  end
  local camName = isUnicycle(vid, ctx) and "unicycle" or vdata.focusedCamName
  local cam = vdata.cameras[camName]
  if cam and vdata.focusedCamName then
    notifyCameraChanged(ctx, camName, vid)
    cam:update(camData)
    -- if present, clean up NaN/infs in camera state, by re-initting it
    if not validateData(ctx, camData) and cam.init then
      cam:init()
    end
    camData.dt = camData.dtReal -- revert back to gfx dt, in case one filter switched it
    return 'ok'
  end

  local fallbackCamName = "orbit"
  local fallbackCam = vdata.cameras[fallbackCamName]
  if fallbackCam then
    log("E", "", "Vehicle cam \""..dumps(vdata.focusedCamName).."\" not found. Falling back to \""..dumps(fallbackCamName).."\"")
    set(fallbackCamName, nil, nil, 0, ctx)
    return 'abort'
  end
  return 'need-free', nil, vdata.focusedCamName
end

-- Running cameras (incl. the gameengine.lua output filter, which sends res to camData.renderView)
-- plus per-frame relative-look clear and finalCameraData copy.
local function updateGlobalCameras(ctx, camData)
  for _,v in ipairs(getRunningCamsOrder(ctx)) do
    v.cam:update(camData)
  end

  -- clear relative look each frame so mouse/relative input doesn't accumulate (per context)
  MoveManager.yawRelative = 0
  MoveManager.pitchRelative = 0
  MoveManager.rollRelative = 0

  updateCameraData(ctx)
end

local function updateMainShadows(globalCam)
  -- Keep cascade coverage stable; retain the tighter split distribution while driving.
  local targetShadowScale = globalCam and 1.0 or drivingShadowDistanceScale
  local targetSdsmFit = false
  if PSSMLightShadowMap then
    if targetShadowScale ~= lastShadowDistanceScale then
      PSSMLightShadowMap.sdsmMaxDistanceScale = targetShadowScale
      lastShadowDistanceScale = targetShadowScale
    end
    if targetSdsmFit ~= lastSdsmFitEnabled then
      PSSMLightShadowMap.sdsmFitEnabled = targetSdsmFit
      lastSdsmFitEnabled = targetSdsmFit
    end
  end
end

local function updateMainContext(dtReal, dtSim, dtRaw)
  local ctx = mainContext
  local camData, veh, vid = beginContextUpdate(ctx, dtReal, dtSim, dtRaw)
  camData.openxrSessionRunning = render_openxr and render_openxr.isSessionRunning() or false

  local globalCam = getGlobalCameras(ctx)[ctx.activeGlobalCameraName]
  updateMainShadows(globalCam)

  local result, ranGlobal, missingCamName = updateSelectedCamera(ctx, camData, vid, globalCam)
  if result == 'ok' then
    if ranGlobal then extensions.hook("onCameraPreRender", camData) end
  elseif result == 'need-free' then
    log("E", "", "Vehicle cam \""..dumps(missingCamName).."\" not found. Fallback cam \""..dumps("orbit").."\" not found either. Falling back to free camera")
    commands.setFreeCamera()
    return
  else
    return
  end

  updateGlobalCameras(ctx, camData)
  cameraInput.tickAbsAxes(dtReal) -- spacemouse absolute axes are a single-device, main-only concern
  updateInteriorSSAO(veh)
end

-- No camera this frame (e.g. the player has no vehicle): keep sending the last pose to the RenderView,
-- since its projection is only rebuilt from its current resolution when a pose is sent
local function holdLastPose(ctx, camData)
  local final = ctx.finalCameraData
  if final.fovDeg <= 0 then return end -- no pose sent yet
  camData.res.pos:set(final.pos)
  camData.res.rot:set(final.rot)
  camData.res.fov = final.fovDeg
  getGlobalCameras(ctx).gameengine:update(camData)
end

local function updateExtraContext(ctx, dtReal, dtSim, dtRaw)
  MoveManager = ctx.move -- camera modes read this player's input while updating this context
  local camData, _, vid = beginContextUpdate(ctx, dtReal, dtSim, dtRaw)

  local result = updateSelectedCamera(ctx, camData, vid, getGlobalCameras(ctx)[ctx.activeGlobalCameraName])
  if result == 'need-free' then
    setGlobalCameraByName('free', nil, nil, ctx) -- keep the fallback local to this context (don't disturb the player)
    return
  elseif result ~= 'ok' then
    holdLastPose(ctx, camData)
    return
  end

  updateGlobalCameras(ctx, camData)
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  if not levelLoaded then return end
  updateMainContext(dtReal, dtSim, dtRaw)
  for _, ctx in pairs(extraContexts) do
    updateExtraContext(ctx, dtReal, dtSim, dtRaw)
  end
  MoveManager = moveManager -- restore the main input state as the default between frames
end

return M
