-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Per-frame camera update loop, split out of core/camera.lua. Computes each camera
-- context (the main player view + any extra render-view contexts) by driving the
-- existing camera modes. core_camera injects its state + selection/registry helpers
-- via setup() and exposes M.onPreRender / M.onClientPostStartMission as its callbacks.

local cameraInput = require('core/cameraInput')

local M = {}

-- injected by core/camera.lua (its shared state + selection/registry/config helpers)
local contexts, mainContext, moveManager, getConfiguration
local getGlobalCameras, getVehicleData, getRunningCamsOrder
local setGlobalCameraByName, set, vehicleChanged
local isWithinRadius, isUnicycle
local cameraM

function M.setup(deps)
  contexts = deps.contexts
  mainContext = deps.mainContext
  moveManager = deps.moveManager
  getConfiguration = deps.getConfiguration
  getGlobalCameras = deps.getGlobalCameras
  getVehicleData = deps.getVehicleData
  getRunningCamsOrder = deps.getRunningCamsOrder
  setGlobalCameraByName = deps.setGlobalCameraByName
  set = deps.set
  vehicleChanged = deps.vehicleChanged
  isWithinRadius = deps.isWithinRadius
  isUnicycle = deps.isUnicycle
  cameraM = deps.cameraM
end

-- sun shadow distance scale when attached to a vehicle, 0.5 of 1500 is a 750m cap, kept generous
-- enough that big and distant casters still cast shadows, the shorter range packs more resolution into
-- the fixed cascade layout so it is sharper than the full range detached camera
local drivingShadowDistanceScale = 0.5
local lastShadowDistanceScale = nil

-- Reduces the SSAO radius when the camera is inside the vehicle interior
local isCameraInsidePrevious = false
local function updateInteriorSSAO(veh)
  if not veh then return false end

  local vehId = veh:getId()
  if isUnicycle(vehId) then return false end
  local camPos = mainContext.finalCameraData.pos
  local vdata = getVehicleData()[vehId]
  if not vdata then return false end

  local isCameraInsideNow = isWithinRadius("onboard.driver", camPos, veh, vdata, 0.6) or isWithinRadius("onboard.rider", camPos, veh, vdata, 0.6)
  if not (freeroam_bigMapMode and freeroam_bigMapMode.bigMapActive()) then
    local oobb = veh:getSpawnWorldOOBB()
    local inside = (isCameraInsideNow and oobb:isContained(camPos))
    if isCameraInsideNow ~= isCameraInsidePrevious then
      if scenetree.SSAOPostFx then scenetree.SSAOPostFx:setRadiusTarget((inside and 0.5) or 1.5) end
    end
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
  isCameraInsidePrevious = false
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

-- Compute one context's camera for this frame, reusing all the existing camera
-- modes. The main context drives the player view ("main" RenderView); extra
-- contexts drive their own RenderView. Player input (MoveManager), OpenXR, the
-- onCameraPreRender hook and interior-shadow tuning only apply to the main context.
local function updateContext(ctx, dtReal, dtSim, dtRaw)
  local camData = ctx.camData
  MoveManager = ctx.move -- camera modes read this player's input while updating this context
  local player = ctx.player or 0
  local veh = getPlayerVehicle(ctx.vehiclePlayer or player) -- vehicle (and its cameras) may come from a different seat than the input player
  local vid = veh and veh:getId()

  -- fixup res if a reference in it has been altered
  camData.resPos:set(camData.pos)
  camData.resTargetPos:set(0, 0, 0)
  camData.resRot:set(1,0,0,0)
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

  camData.openxrSessionRunning = ctx.isMain and render_openxr and render_openxr.isSessionRunning() or false
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

  if veh then
    local vehicleName = veh:getField('name', '')
    if vehicleName ~= ctx.lastVehicleName then
      local lastVehicle = ctx.lastVehicleName and scenetree.findObject(ctx.lastVehicleName) or nil
      local lastVehicleId = lastVehicle and lastVehicle:getId() or nil
      vehicleChanged(lastVehicleId, vid, ctx)
      ctx.lastVehicleName = vehicleName
    end
  end

  if not getConfiguration() then return end

  camData.res.targetPos:set(camData.pos)   -- tracked target
  camData.res.fov = 60
  camData.res.nearClip = getLevelNearClip() or 0.1 -- choose a sane default if the level hasn't defined a nearclip

  -- update the selected camera
  local globalCam = getGlobalCameras(ctx)[ctx.activeGlobalCameraName]

  -- attached to a vehicle cap the far shadow depth so the fixed cascade layout stays sharp near the car,
  -- a global camera opens it to the full range
  if ctx.isMain then
    local targetShadowScale = globalCam and 1.0 or drivingShadowDistanceScale
    if targetShadowScale ~= lastShadowDistanceScale and PSSMLightShadowMap then
      PSSMLightShadowMap.sdsmMaxDistanceScale = targetShadowScale
      lastShadowDistanceScale = targetShadowScale
    end
  end

  if globalCam then
    -- one of the global cameras
    if globalCam:update(camData) then
      if ctx.isMain then extensions.hook("onCameraPreRender", camData) end
    else
      setGlobalCameraByName(nil, nil, nil, ctx)
    end
  else
    -- one of the vehicle cameras
    local vdata = getVehicleData(ctx)[vid]
    if not vdata then
      --log("E", "", "No global cam used, and no vehicle exists either")
      return
    end
    local plvdata = core_vehicle_manager.getPlayerVehicleData()
    local isUnicycle = plvdata and plvdata.mainPartName == "unicycle"
    local camName = isUnicycle and "unicycle" or vdata.focusedCamName
    local cam = vdata.cameras[camName]
    if cam and vdata.focusedCamName then
      cam:update(camData)
      if not validateData(ctx, camData) and cam.init then cam:init() end -- if present, clean up NaN/infs in camera state, by re-initting it
    else
      local fallbackCamName = "orbit"
      local fallbackCam = vdata.cameras[fallbackCamName]
      if fallbackCam then
        log("E", "", "Vehicle cam \""..dumps(vdata.focusedCamName).."\" not found. Falling back to \""..dumps(fallbackCamName).."\"")
        set(fallbackCamName, nil, nil, 0, ctx)
      elseif ctx.isMain then
        log("E", "", "Vehicle cam \""..dumps(vdata.focusedCamName).."\" not found. Fallback cam \""..dumps(fallbackCamName).."\" not found either. Falling back to free camera")
        commands.setFreeCamera()
      else
        setGlobalCameraByName('free', nil, nil, ctx) -- keep the fallback local to this context (don't disturb the player)
      end
      return
    end
    camData.dt = camData.dtReal -- revert back to gfx dt, in case one filter switched it
  end

  -- running cameras (incl. the gameengine.lua output filter, which sends res to camData.renderView)
  for _,v in ipairs(getRunningCamsOrder(ctx)) do
    v.cam:update(camData)
  end

  -- clear relative look each frame so mouse/relative input doesn't accumulate (per context)
  MoveManager.yawRelative = 0
  MoveManager.pitchRelative = 0
  MoveManager.rollRelative = 0

  if ctx.isMain then -- spacemouse absolute axes are a single-device, main-only concern
    cameraInput.tickAbsAxes(dtReal)
  end

  updateCameraData(ctx)

  if ctx.isMain and veh then updateInteriorSSAO(veh) end

  MoveManager = moveManager -- restore the main input state as the default between frames
end

function M.onPreRender(dtReal, dtSim, dtRaw)
  if not levelLoaded then return end
  updateContext(mainContext, dtReal, dtSim, dtRaw) -- player view first
  for _, ctx in pairs(contexts) do
    if not ctx.isMain then updateContext(ctx, dtReal, dtSim, dtRaw) end
  end
end

return M
