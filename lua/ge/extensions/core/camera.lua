-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.dependencies = {'core_vehicle_manager', 'core_environment'}

-- input handlers + the per-frame update loop live in split-out submodules; both are wired
-- via their setup() near the bottom, once this file's shared state + helpers exist
local cameraInput = require('core/cameraInput')
local cameraUpdate = require('core/cameraUpdate')

local multicams = { "onboard" }
local pendingTrigger = nil
local configuration = {}  -- shared camera-menu config: { {name=foo, enabled=true}, {name=bar, enabled=false}, ... }
local freeCameraConfiguration = {}
local currentVersion = 1

M.speedFactor = 1 -- used to fix too smooth and slow camera movement when creating thumbnails

-- per-context player input state (look/zoom/move). MoveManager is repointed to the
-- context being updated so the camera modes read the right player's input.
local function newMove()
  return {
    rollRight = 0, rollLeft = 0, pitchUp = 0, pitchDown = 0,
    yawRight = 0, yawLeft = 0, zoomIn = 0, zoomOut = 0,
    absXAxis = 0, absYAxis = 0, absZAxis = 0,
    forward = 0, backward = 0, up = 0, down = 0, left = 0, right = 0,
    pitchRelative = 0, yawRelative = 0, rollRelative = 0
  }
end
local moveManager = newMove()
MoveManager = moveManager

-- A camera "context" = one camera output target ("what the camera is used for").
-- The default "main" context drives the player view (RenderView "main"); extra
-- contexts drive other RenderViews (e.g. streamed views) reusing the same camera
-- modes and the same update pipeline. State that used to be module-global lives
-- per context so contexts don't fight over selection/smoothing.
--   vehicleCamerasCache: { vid1={focusedCamName=orbit, cameras={orbit=C, ...}}, ... }
local MAIN_CONTEXT = "main"

local function newCamData()
  local resPos, resTargetPos, resRot = vec3(), vec3(), quat()
  -- resPos/resTargetPos/resRot are the canonical res vecs; res.* is re-pointed to
  -- them every frame (camera modes may replace data.res.pos with a fresh vec)
  return { veh = 0, vid = 0, dtSim = 0.0001, dtReal = 0.0001, dtRaw = 0.0001, dt = 0.0001, speed = 30, pos=vec3(), prevPos = vec3(), vehPos=vec3(), prevVehPos=vec3(), vel=vec3(), prevVel=vec3(),
    resPos = resPos, resTargetPos = resTargetPos, resRot = resRot,
    res = {pos = resPos, targetPos = resTargetPos, rot = resRot, fov = 60} }
end

local function newContext(id, renderView, player, vehiclePlayer)
  return {
    id = id,
    renderView = renderView or MAIN_CONTEXT, -- RenderView name this context outputs to
    isMain = (id == MAIN_CONTEXT),
    player = player or 0,       -- input player / seat this context follows
    vehiclePlayer = vehiclePlayer, -- optional: take the vehicle (its cameras) from this seat instead of `player`, so a view can show another seat's car while a dedicated input player drives it
    move = (id == MAIN_CONTEXT) and moveManager or newMove(), -- per-player input state
    activeGlobalCameraName = nil,
    requestedCam = {},          -- {vid = {name=foo, customData=bar}}
    lastVehicleName = nil,      -- used to detect vehicle switches
    vehicleCamerasCache = nil,  -- per-context vehicle camera instances (lazy)
    globalCamerasCache = nil,   -- per-context global camera instances (lazy)
    runningCamsOrderCache = nil,
    camData = newCamData(),
    finalCameraData = {pos = vec3(), rot = quat(), fovDeg = 0},
    validData = nil,
    lastValidData = { fov=60, pos=vec3(), rot=quat() }, -- protect against NaNs on the first frame
  }
end

local contexts = {}
local mainContext = newContext(MAIN_CONTEXT, MAIN_CONTEXT)
contexts[MAIN_CONTEXT] = mainContext

-- A context can be addressed three ways:
--   * by player (a seat): ctxForPlayer(player) -> the view that player drives. player 0
--     is the main view by default; split-screen remaps each player to their own view.
--     All per-player camera control (look, zoom, selection, reset, free-cam) routes
--     through here so players don't fight over a shared view.
--   * by id (a view name): getContext(id) -> a specific view (nil -> main).
--   * by vehicle id: the VID-addressed helpers below, which always act on the main view.
local contextByPlayer = {[0] = mainContext}
local function ctxForPlayer(player)
  return (player ~= nil and contextByPlayer[player]) or mainContext
end
local function moveFor(player)
  return ctxForPlayer(player).move
end

-- resolve a context by id (view name); nil -> main view
local function getContext(id)
  if id == nil then return mainContext end
  return contexts[id]
end

local function addVehicleData(vid, target, ctx)
  ctx = ctx or mainContext
  local vdata = target[vid] or {}
  local focusedCamNamePrevious = ((ctx.vehicleCamerasCache or {})[vid] or {}).focusedCamName
  M.processVehicleCameraConfigChanged(vid, vdata, focusedCamNamePrevious, ctx)
  target[vid] = vdata
end

local function getVehicleData(ctx)
  ctx = ctx or mainContext
  if not ctx.vehicleCamerasCache then
    local result = {}
    for i=0, be:getObjectCount()-1 do
      local vid = be:getObject(i):getId()
      addVehicleData(vid, result, ctx)
    end
    ctx.vehicleCamerasCache = result
  end
  return ctx.vehicleCamerasCache
end

local function delVehicleData(vid, ctx)
  getVehicleData(ctx)[vid] = nil
end

local function onVehicleSpawned(vid)
  for _, ctx in pairs(contexts) do
    addVehicleData(vid, getVehicleData(ctx), ctx)
  end
end

local function onVehicleDestroyed(vid)
  for _, ctx in pairs(contexts) do
    delVehicleData(vid, ctx)
  end
end

-- constructors for all camera types (cached)
local camDirectory = '/lua/ge/extensions/core/cameraModes'
local constructorsCache
local function getConstructors()
  if not constructorsCache then
    constructorsCache = {}
    for _,file in ipairs(FS:findFiles(camDirectory, "*.lua", 1, false, false)) do
      local _,camMode,_ = path.splitWithoutExt(file)
      constructorsCache[camMode] = require('core/cameraModes/' .. camMode)
    end
  end
  return constructorsCache
end

-- cameras that always exist once (even if no vehicle is spawned), per context
local function getGlobalCameras(ctx)
  ctx = ctx or mainContext
  if not ctx.globalCamerasCache then
    ctx.globalCamerasCache = {}
    for camName,constructor in pairs(getConstructors()) do
      local cam = constructor()
      if cam.isGlobal then
        ctx.globalCamerasCache[camName] = cam
      end
    end
  end
  return ctx.globalCamerasCache
end

-- cameras that always run (except when using the old C++ camera path, e.g. shift+c camera, some World Editor cameras, etc)
local function getRunningCamsOrder(ctx)
  ctx = ctx or mainContext
  if not ctx.runningCamsOrderCache then
    ctx.runningCamsOrderCache = {}
    for camName,cam in pairs(getGlobalCameras(ctx)) do
      if cam.runningOrder then
        table.insert(ctx.runningCamsOrderCache, {name=camName, cam=cam})
      end
    end
    table.sort(ctx.runningCamsOrderCache, function(a,b) return a.cam.runningOrder < b.cam.runningOrder end)
  end
  return ctx.runningCamsOrderCache
end

local function ensureFreeCameraConfiguration(ctx)
  if #freeCameraConfiguration > 0 then return end
  ctx = ctx or mainContext

  local cameras = getGlobalCameras(ctx)
  local defaults = {}
  for name, camera in pairs(cameras) do
    if camera.group == "world" then
      defaults[#defaults + 1] = {name = name, order = camera.groupOrder or 100}
    end
  end
  table.sort(defaults, function(a, b)
    if a.order ~= b.order then return a.order < b.order end
    return a.name < b.name
  end)

  local saved = settings.getValue('freeCameraConfig')
  if saved and saved ~= "" then
    if type(saved) == "string" then saved = jsonDecode(saved:gsub("'", '"')) end
    saved = saved and saved.data
  end

  local configured = {}
  if type(saved) == "table" then
    for _, entry in ipairs(saved) do
      local camera = cameras[entry.name]
      if camera and camera.group == "world" and not configured[entry.name] then
        freeCameraConfiguration[#freeCameraConfiguration + 1] = {
          name = entry.name,
          enabled = entry.enabled ~= false
        }
        configured[entry.name] = true
      end
    end
  end

  for _, entry in ipairs(defaults) do
    if not configured[entry.name] then
      local camera = cameras[entry.name]
      freeCameraConfiguration[#freeCameraConfiguration + 1] = {
        name = entry.name,
        enabled = camera.disabledByDefault ~= true
      }
    end
  end
end

-- Cameras in a named group (e.g. "world"), in configured order.
-- Disabled world cameras stay available to Options but are skipped while cycling.
local function getGroupCams(ctx, groupName, includeDisabled)
  ctx = ctx or mainContext
  local cameras = getGlobalCameras(ctx)
  local result = {}

  if groupName == "world" then
    ensureFreeCameraConfiguration(ctx)
    for _, entry in ipairs(freeCameraConfiguration) do
      local camera = cameras[entry.name]
      if camera and camera.group == groupName and (includeDisabled or entry.enabled) then
        result[#result + 1] = entry.name
      end
    end
    return result
  end

  for name, camera in pairs(cameras) do
    if camera.group == groupName then result[#result + 1] = name end
  end
  table.sort(result, function(a, b)
    local oa, ob = cameras[a].groupOrder or 100, cameras[b].groupOrder or 100
    if oa ~= ob then return oa < ob end
    return a < b
  end)
  return result
end

local function getCameraGroups(ctx)
  ctx = ctx or mainContext
  local minOrder = {}
  for _, camera in pairs(getGlobalCameras(ctx)) do
    if camera.group and #getGroupCams(ctx, camera.group) > 0 then
      local order = camera.groupOrder or 100
      if not minOrder[camera.group] or order < minOrder[camera.group] then
        minOrder[camera.group] = order
      end
    end
  end
  local names = {}
  for name in pairs(minOrder) do names[#names + 1] = name end
  table.sort(names, function(a, b)
    if minOrder[a] ~= minOrder[b] then return minOrder[a] < minOrder[b] end
    return a < b
  end)
  return names
end

local function nextCameraGroup(groups, active)
  if active == false or #groups == 0 then return nil end
  local current = 0
  if active then
    for i, group in ipairs(groups) do
      if group == active then current = i break end
    end
    if current == 0 then return nil end
  end
  return groups[(current + 1) % (#groups + 1)]
end

-- gather data used by Options > Cameras and other code
local function getExtendedConfig(vdata)
  local config = deepcopy(configuration)
  local slotId = 1
  for _, v in ipairs(config) do
    local visible = vdata.cameras[v.name] and not vdata.cameras[v.name].hidden
    v.hidden = not visible
    -- set the binding camera number (keys 1 to 9, for example)
    if visible then
      v.slotId = slotId
      slotId = slotId + 1
    end
  end
  return config
end

local function getExtendedFreeCameraConfig(ctx)
  ctx = ctx or mainContext
  ensureFreeCameraConfiguration(ctx)
  local cameras = getGlobalCameras(ctx)
  local config = deepcopy(freeCameraConfiguration)
  for _, entry in ipairs(config) do
    entry.hidden = not (cameras[entry.name] and cameras[entry.name].group == "world")
  end
  return config
end

local function getConfigurationReadOnly()
  return deepcopy(configuration)
end

local function getFreeCameraConfigurationReadOnly()
  ensureFreeCameraConfiguration()
  return deepcopy(freeCameraConfiguration)
end

local function getVdata(player, ctx)
  local veh = getPlayerVehicle((ctx and ctx.vehiclePlayer) or player)
  if not veh then return end
  return getVehicleData(ctx)[veh:getId()]
end

-- get icon from camera object, with fallback
local function getCameraIcon(camName, camera)
  if camera and camera.icon then
    return camera.icon
  end
  return "info"
end

local function isUnicycle(vehId)
  return not mainContext.activeGlobalCameraName and core_vehicle_manager and core_vehicle_manager.getPlayerVehicleData() and core_vehicle_manager.getVehicleData(vehId).mainPartName == "unicycle"
end

-- send data to Messages UI app
local function displayCameraNameUI(player)
  local ctx = ctxForPlayer(player)
  local globalName = ctx.activeGlobalCameraName
  local globalCamera = globalName and getGlobalCameras(ctx)[globalName]
  if globalCamera and globalCamera.group then
    local list = getGroupCams(ctx, globalCamera.group)
    local index = 0
    for i, name in ipairs(list) do
      if name == globalName then index = i - 1 break end
    end
    local actionItems = fillActionLabels({
      { action = "switch_camera_next" },
      { action = "toggleCamera" },
      { action = "moveforwardbackward" },
      { action = "moveforward" },
      { action = "movebackward" },
      { action = "movefast" },
      { action = "changeCameraSpeed" },
    })
    guihooks.trigger('Message', {
      txt = 'ui.camera.switched',
      context = {name = 'ui.camera.mode.' .. globalName},
      ttl = 9999,
      category = 'cameramode',
      icon = "survellianceCamera",
      actionItems = actionItems,
      availableOptionsCount = #list,
      currentOptionIndex = index,
    })
    return
  end

  local vdata = getVdata(player, ctxForPlayer(player))
  if not vdata then return end
  if not vdata.focusedCamName then return end
  local playerVehicle = getPlayerVehicle(player)
  if playerVehicle and isUnicycle(playerVehicle:getId()) then return end

  local availableOptionsCount = 0
  local currentOptionIndex = 0
  for _, config in ipairs(configuration) do
    local enabled = config.enabled
    local visible = vdata.cameras[config.name] and not vdata.cameras[config.name].hidden
    if visible and enabled then
      if config.name == vdata.focusedCamName then
        currentOptionIndex = availableOptionsCount -- 0-based index
      end
      availableOptionsCount = availableOptionsCount + 1
    end
  end

  guihooks.trigger('Message', {
    txt = 'ui.camera.switched',
    context = {name = 'ui.camera.mode.' .. vdata.focusedCamName},
    ttl = 5,
    category = 'cameramode',
    icon = "survellianceCamera",
    availableOptionsCount = availableOptionsCount,
    currentOptionIndex = currentOptionIndex
  })
end

local function onCameraToggled(data)
  displayCameraNameUI(0)
end

local function getCamIdFromName(camName)
  for id,config in ipairs(configuration) do
    if config.name == camName then
      return id
    end
  end
end
-- send configuration to Options > Cameras menu
local function updateOptionsUI(vdata, forcedCamName)
  local config = getExtendedConfig(vdata)
  local activeGlobal = mainContext.activeGlobalCameraName
  local activeGlobalCamera = activeGlobal and getGlobalCameras()[activeGlobal]
  guihooks.trigger('CameraConfigChanged', {
    cameraConfig = config,
    focusedCamName = not activeGlobal and (forcedCamName or vdata.focusedCamName) or nil,
    freeCameraConfig = getExtendedFreeCameraConfig(),
    focusedFreeCameraName = activeGlobalCamera and activeGlobalCamera.group == "world" and activeGlobal or nil,
  })
end

local function saveConfiguration(vdata)
  updateOptionsUI(vdata)
  settings.setValue('cameraConfig', jsonEncode({ version=currentVersion, data=configuration }))
end

local function saveFreeCameraConfiguration(vdata)
  settings.setValue('freeCameraConfig', jsonEncode({version = currentVersion, data = freeCameraConfiguration}))
  if vdata then updateOptionsUI(vdata) end
end

-- send data to UI apps and other things
local function notifyUI(vdata, forcedCamName)
  vdata = vdata or getVdata(0)
  local camName = forcedCamName or (vdata and vdata.focusedCamName)
  if not camName then return end
  -- tell JS for hiding the apps in cockpit for example
  guihooks.trigger('onCameraNameChanged', {name = camName})
  extensions.hook('onCameraModeChanged', camName)
  updateOptionsUI(vdata)
end

-- request/send data to Options > Cameras menu
local function requestConfig(forcedCamName)
  local vdata = getVdata(0)
  if not vdata then return nil end
  updateOptionsUI(vdata, forcedCamName)
end

local function clearInputs(mm)
  mm = mm or MoveManager
  mm.rollRight = 0
  mm.rollLeft = 0
  mm.pitchUp = 0
  mm.pitchDown = 0
  mm.yawRight = 0
  mm.yawLeft = 0
  mm.zoomIn = 0
  mm.zoomOut = 0
end

local function changeOrder(camId, offset)
  local vdata = getVdata(0)
  if not vdata then return end
  -- iterate through cameras, skipping hidden cams
  local newIdx = camId
  local n = #configuration
  for i = 1, n do
    newIdx = clamp(newIdx + offset, 1, n)
    if not configuration[newIdx].hidden then break end
  end
  if newIdx == camId then return end

  -- move camera to the calculated new index
  configuration[camId], configuration[newIdx] = configuration[newIdx], configuration[camId]

  -- update the focused camera too
  local focusedCamId = getCamIdFromName(vdata.focusedCamName)
  if focusedCamId == newIdx then
    vdata.focusedCamName = configuration[camId].name
  elseif focusedCamId == camId then
    vdata.focusedCamName = configuration[newIdx].name
  end

  saveConfiguration(vdata)
end

local function toggleEnabledCameraById(camId)
  if camId > #configuration then return end
  if camId < 1 then return end
  local vdata = getVdata(0)
  if not vdata then return end
  configuration[camId].enabled = not configuration[camId].enabled
  saveConfiguration(vdata)
end

local function changeFreeCameraOrder(camId, offset)
  ensureFreeCameraConfiguration()
  local newIndex = camId + offset
  if camId < 1 or camId > #freeCameraConfiguration then return end
  if newIndex < 1 or newIndex > #freeCameraConfiguration then return end
  freeCameraConfiguration[camId], freeCameraConfiguration[newIndex] = freeCameraConfiguration[newIndex], freeCameraConfiguration[camId]
  saveFreeCameraConfiguration(getVdata(0))
end

local function toggleFreeCameraEnabledById(camId)
  ensureFreeCameraConfiguration()
  local entry = freeCameraConfiguration[camId]
  if not entry then return end
  entry.enabled = not entry.enabled
  saveFreeCameraConfiguration(getVdata(0))
end

local function setGlobalCameraByName(name, withTransition, customData, ctx)
  ctx = ctx or mainContext
  -- clearing to the vehicle camera needs a vehicle: a view may take its vehicle from
  -- vehiclePlayer (its input player has none), so check that seat
  if not name and not getPlayerVehicle(ctx.vehiclePlayer or ctx.player) then return end
  local globalCams = getGlobalCameras(ctx)
  local newCam = globalCams[name]
  if name and not newCam then return end

  -- process old cam
  local oldCam = globalCams[ctx.activeGlobalCameraName]
  if oldCam and type(oldCam.onCameraChanged) == 'function' then oldCam:onCameraChanged(false) end

  -- process new cam
  ctx.activeGlobalCameraName = name
  if newCam then
    if newCam.setCustomData then newCam:setCustomData(customData or {}) end
    if type(newCam.onCameraChanged) == 'function' then newCam:onCameraChanged(true) end
  end

  if ctx.isMain then
    extensions.hook("onGlobalCameraSet", name)
    local vdata = getVdata(ctx.player, ctx)
    if vdata then updateOptionsUI(vdata) end
  end
end

local function enterGroupCam(name, ctx)
  local camera = getGlobalCameras(ctx)[name]
  if not camera then return false end
  if camera.setPosition then camera:setPosition(vec3(ctx.finalCameraData.pos)) end
  if camera.setRotation then camera:setRotation(quat(ctx.finalCameraData.rot)) end
  setGlobalCameraByName(name, nil, nil, ctx)
  return true
end

local function cycleGroupCam(ctx, groupName, offset, player)
  local list = getGroupCams(ctx, groupName)
  if #list == 0 then return end
  local index = 1
  for i, name in ipairs(list) do
    if name == ctx.activeGlobalCameraName then index = i break end
  end
  enterGroupCam(list[((index - 1 + offset) % #list) + 1], ctx)
  displayCameraNameUI(player)
end

local function cycleCameraGroup(player)
  local ctx = ctxForPlayer(player)
  local active = false
  if not ctx.activeGlobalCameraName then
    active = nil
  else
    local camera = getGlobalCameras(ctx)[ctx.activeGlobalCameraName]
    active = (camera and camera.group) or false
  end
  local nextGroup = nextCameraGroup(getCameraGroups(ctx), active)
  local list = nextGroup and getGroupCams(ctx, nextGroup)
  if list and #list > 0 then
    enterGroupCam(list[1], ctx)
  else
    setGlobalCameraByName(nil, nil, nil, ctx)
  end
  if ctx.isMain then
    extensions.hook("onCameraToggled", {cameraType = ctx.activeGlobalCameraName and 'FreeCam' or 'GameCam'})
  end
  displayCameraNameUI(player)
end

local function getConfigByName(camName)
  for i,config in ipairs(configuration) do
    if config.name == camName then
      return config
    end
  end
end

local function _setVehicleCameraByIndex(vdata, focusedCamId, ctx)
  ctx = ctx or mainContext
  -- satefy checks
  if focusedCamId > #configuration then focusedCamId = 1 end
  if focusedCamId < 1 then focusedCamId = 1 end

  -- tell cameras about the focus change
  local success = false
  local camConfig = configuration[focusedCamId]
  if camConfig then
    local newCam = vdata.cameras[camConfig.name]
    if newCam then
      newCam.focused = true
      if type(newCam.onCameraChanged) == 'function' then
        newCam:onCameraChanged(true)
      end
      success = true
    end
  end
  if success then
    log("D","", "Camera switched to "..dumps(camConfig.name))
    local oldCam = vdata.cameras[vdata.focusedCamName]
    if oldCam then
      oldCam.focused = false
      if type(oldCam.onCameraChanged) == 'function' then
        oldCam:onCameraChanged(false)
      end
    end

    -- set it actually. This is the only function that is allowed to change focusedCamName directly
    vdata.focusedCamName = configuration[focusedCamId].name
    if ctx.isMain then -- player input + the cameras menu only reflect the main context
      clearInputs()
      notifyUI(vdata)
    end
  else
    log("D","", "Camera not switched to anything")
  end
  return success
end

local function _setVehicleCameraByName(vdata, camName, withTransition, ctx)
  ctx = ctx or mainContext
  for camId, config in ipairs(configuration) do
    if config.name == camName then
      local success = _setVehicleCameraByIndex(vdata, camId, ctx)
      if withTransition then
        getGlobalCameras(ctx).transition:start()
      end
      return success
    end
  end
  log("E", "", "Unable to switch to requested camera: '"..dumps(camName).."'")
  return false
end

local function setVehicleCameraByName(player, name, withTransition, customData, ctx)
  ctx = ctx or mainContext
  local veh = getPlayerVehicle((ctx and ctx.vehiclePlayer) or player) -- a view takes its vehicle from vehiclePlayer (its input player may have none)
  if not veh then
    log("E", "", "Player #"..dumps(player).." is not seated in a vehicle")
    return false
  end

  local vid = veh:getId()
  local vdata = getVehicleData(ctx)[vid]
  if not vdata then
    -- store the request for when we get the data
    ctx.requestedCam[vid] = { name = name, customData = customData }
    return false
  end

  if ctx.activeGlobalCameraName then
    setGlobalCameraByName(nil, nil, nil, ctx)
  end
  local res = _setVehicleCameraByName(vdata, name, withTransition, ctx)
  if res and vdata.cameras[name].setCustomData then
    vdata.cameras[name]:setCustomData( customData )
  end
  return res
end

local function setVehicleCameraByNameWithId(vehId, name, withTransition, customData, ctx)
  ctx = ctx or mainContext
  if not vehId then return end
  local veh = scenetree.findObjectById(vehId)
  if not veh then
    log("E", "", "Player #"..dumps(player).." is not seated in a vehicle")
    return false
  end

  local vid = veh:getId()
  local vdata = getVehicleData(ctx)[vid]
  if not vdata then
    -- store the request for when we get the data
    ctx.requestedCam[vid] = { name = name, customData = customData }
    return false
  end

  if ctx.activeGlobalCameraName then
    setGlobalCameraByName(nil, nil, nil, ctx)
  end
  local res = _setVehicleCameraByName(vdata, name, withTransition, ctx)
  if res and vdata.cameras[name].setCustomData then
    vdata.cameras[name]:setCustomData( customData )
  end
  return res
end

local function set(camName, withTransition, customData, player, ctx)
  ctx = ctx or ctxForPlayer(player)
  if player then
    setVehicleCameraByName(player, camName, withTransition, customData, ctx)
  else
    setGlobalCameraByName(camName, withTransition, customData, ctx)
  end
end

--TODO handle transition from global to vehicle camera and viceversa? wasFocused, .focus, and all of that?
--TODO or keep global cameras as overlay for vehicle cameras, all running at ocne?
local function setByName(...)
  local arg = {...}
  local player, camName, withTransition, customData
  if type(arg[1]) == "number" then
    player, camName, withTransition, customData = unpack(arg, 1, table.maxn(arg)) -- without arguments, unpack can stop at the first nil it encounters, cutting the row short
  else
    camName, withTransition, customData = unpack(arg, 1, table.maxn(arg)) -- without arguments, unpack can stop at the first nil it encounters, cutting the row short
  end
  local isGlobal = (camName == nil) or getGlobalCameras()[camName]
  if isGlobal then player = nil end
  set(camName, withTransition, customData, player)
end

local function setCameraByNameFromOptions(player, camName)
  local ctx = ctxForPlayer(player)
  local globalCamera = getGlobalCameras(ctx)[camName]
  if globalCamera and globalCamera.group == "world" then
    if not enterGroupCam(camName, ctx) then return false end
    if ctx.isMain then
      extensions.hook("onCameraToggled", {cameraType = "FreeCam"})
    end
    displayCameraNameUI(player)
    return true
  end

  local success = setVehicleCameraByName(player, camName, nil, nil, ctx)
  if success then displayCameraNameUI(player) end
  return success
end

local nodePos = vec3()
local function isWithinRadius(cameraName, camPos, veh, vdata, radius)
  if not vdata.cameras[cameraName] then return false end
  nodePos:set(veh:getNodeAbsPositionXYZ(vdata.cameras[cameraName].camNodeID))
  return nodePos:squaredDistance(camPos) < radius * radius
end



local bbCenter, bbHalfAxis0, bbHalfAxis1, bbHalfAxis2 = vec3(), vec3(), vec3(), vec3()
local function isCameraInside(player, camPos)
  local veh = getPlayerVehicle(player)
  if not veh then return 0 end
  local vehId = veh:getId()
  local vdata = getVehicleData()[vehId]
  if not vdata then return 0 end
  if isUnicycle(vehId) then return 0 end

  bbCenter:set(be:getObjectOOBBCenterXYZ(vehId))
  bbHalfAxis0:set(be:getObjectOOBBHalfAxisXYZ(vehId, 0))
  bbHalfAxis1:set(be:getObjectOOBBHalfAxisXYZ(vehId, 1))
  bbHalfAxis2:set(be:getObjectOOBBHalfAxisXYZ(vehId, 2))

  if not containsOBB_point(bbCenter, bbHalfAxis0, bbHalfAxis1, bbHalfAxis2, camPos) then return 0 end

  return (isWithinRadius("onboard.driver", camPos, veh, vdata, 0.6) or isWithinRadius("onboard.rider", camPos, veh, vdata, 0.6)) and 1 or 0
end

local function getCameraDataById(vid)
  local vehData = getVehicleData()[vid]
  if vehData then
    return vehData.cameras
  end
end

local function getDriverDataById(vehId)
  local camNodeID, rightHandDrive, rightHandDoor = nil, false, false
  local vdata = getVehicleData()[vehId]
  if not vdata         then return camNodeID, rightHandDrive, rightHandDoor end
  if not vdata.cameras then return camNodeID, rightHandDrive, rightHandDoor end
  local cam = vdata.cameras["onboard.driver"]
  if not cam           then return camNodeID, rightHandDrive, rightHandDoor end
  camNodeID, rightHandDrive, rightHandDoor = cam.camNodeID, cam.rightHandCamera or false, cam.rightHandDoor or false -- convert nil to false
  return camNodeID, rightHandDrive, rightHandDoor
end

local function getDriverData(veh)
  return getDriverDataById(veh and veh:getId())
end

local function getActiveCamName(player)
  local ctx = ctxForPlayer(player)
  if ctx.activeGlobalCameraName then return ctx.activeGlobalCameraName end
  local vid = be:getPlayerVehicleID(player or 0)
  if vid == -1 then return end -- no LUA camera is being used atm
  local camName
  if ctx.requestedCam[vid] then
    camName = ctx.requestedCam[vid].name
  else
    local vdata = getVehicleData(ctx)[vid]
    if vdata then
      camName = vdata.focusedCamName
    else
      log('W', '', 'Unable to find vdata for player '..tostring(player))
    end
  end
  return camName
end

local function getActiveCamNameByVehId(vehId)
  if not vehId then return end
  local veh = scenetree.findObjectById(vehId)
  if not veh then return end -- no LUA camera is being used atm
  local camName
  local vid = veh:getId()
  if mainContext.requestedCam[vid] then
    camName = mainContext.requestedCam[vid].name
  else
    local vdata = getVehicleData()[vid]
    if vdata then
      camName = vdata.focusedCamName
    else
      log('W', '', 'Unable to find vdata for player '..tostring(player))
    end
  end
  return camName
end

local function setBySlotId(player, slotId)
  local ctx = ctxForPlayer(player)
  local vdata = getVdata(player, ctx)
  if not vdata then return end
  local config = getExtendedConfig(vdata)
  for k,v in ipairs(config) do
    if v.slotId == slotId then
      -- if in global camera, exit it
      if ctx.activeGlobalCameraName then
        setGlobalCameraByName(nil, nil, nil, ctx)
      end
      _setVehicleCameraByIndex(vdata, k, ctx)
      displayCameraNameUI(player)
      if ctx.isMain then saveConfiguration(vdata) end
      return
    end
  end
end

local function initCam(camera, jbeamConfig, constructor)
  local jbeamConfig = deepcopy(jbeamConfig)

  -- sanitization
  if type(jbeamConfig.distance) == 'string' then jbeamConfig.distance = tonumber(jbeamConfig.distance) end
  if type(jbeamConfig.distanceMin) == 'string' then jbeamConfig.distanceMin = tonumber(jbeamConfig.distanceMin) end

  if camera then
    camera.camBase = nil
    camera.defaultRotation = nil
    tableMergeRecursive(camera, jbeamConfig)
    if type(camera.onVehicleCameraConfigChanged) == 'function' then
      camera:onVehicleCameraConfigChanged()
    end
  else
    camera = constructor(jbeamConfig)
  end
  if camera.isFilter then return end
  if camera.isGlobal then return end
  camera.hidden = camera.hidden == true -- convert to boolean
  camera.focused = false -- make sure its set to inactive on start --TODO why track this here?
  return camera
end

-- TODO trigger this also for global cameras?
local function processVehicleCameraConfigChanged(vid, vdata, focusedCamNamePrevious, ctx)
  ctx = ctx or mainContext
  local camerasOld = vdata.cameras or {}
  vdata.cameras = {}
  local vmvd = extensions.core_vehicle_manager.getVehicleData(vid)
  if vmvd then
    vmvd = vmvd.vdata
  else
    return
  end

  local refNodes = vmvd.refNodes[0]
  local vmcd = vmvd.cameraData or {}
  local camConfigs = {}
  for camMode,constructor in pairs(getConstructors()) do
    if tableFindKey(multicams, camMode) then
      local jbeamConfigs = vmcd[camMode] or {}
      for i,jbeamConfig in pairs(jbeamConfigs) do
        table.insert(camConfigs, {name=camMode.."."..jbeamConfig.name, constructor=constructor, jbeamConfig=jbeamConfig})
      end
    else
      local jbeamConfig = vmcd[camMode] or {}
      table.insert(camConfigs, {name=camMode, constructor=constructor, jbeamConfig=jbeamConfig})
    end
  end
  for k,v in ipairs(camConfigs) do
    if v.name ~= "onboard.driver" and string.lower(v.name) == "onboard.driver" then
      log("W", "", "Possibly incorrect camera name '"..v.name.."' (rename to 'onboard.driver'?)")
    end
    local cam = initCam(camerasOld[v.name], v.jbeamConfig, v.constructor)
    if cam then
      if cam.setRefNodes then
        local refNodes = (vmvd.cameraRefNodes and vmvd.cameraRefNodes[v.name]) or refNodes
        cam:setRefNodes(refNodes.ref, refNodes.left, refNodes.back)
      end
      vdata.cameras[v.name] = cam
    end
  end

  if not arrayFindValueIndex(tableKeys(vdata.cameras), "onboard.driver") then
    vdata.cameras.driver = nil -- there's no driver data to feed the driver cam, so remove it
  end

  -- The camera-menu configuration is shared and owned/persisted by the main
  -- context only; extra contexts reuse it as-is (building it once if needed).
  if ctx.isMain or #configuration == 0 then
  -- initial camera config
  local initialConfiguration = {
     {name="orbit"}
    ,{name="driver"}
    ,{name="onboard.hood"}
    ,{name="external"}
    ,{name="relative"}
    ,{name="chase"}
    ,{name="droneChase"}
  }
  local savedConfiguration = settings.getValue('cameraConfig')
  if savedConfiguration and savedConfiguration ~= "" then
    -- fix INI values that passed through javascript (e.g. when opening Options menu)
    savedConfiguration = savedConfiguration:gsub("'",'"')
    -- and then deserialize, so we can follow the user settings
    savedConfiguration = jsonDecode(savedConfiguration)
    -- if user settings version is good, go ahead and use it
    if savedConfiguration and (savedConfiguration.version or 0) >= currentVersion then
      initialConfiguration = savedConfiguration.data
    end
  end

  -- fill pre-configured cameras (even if it's a disabled/unknown camera)
  configuration = {}
  for k,v in ipairs(initialConfiguration) do
    local enabled = v.enabled
    if enabled == nil then
      enabled = true
      local cam = vdata.cameras[v.name]
      if cam then
        enabled = cam.disabledByDefault ~= true
      end
    end
    table.insert(configuration, {name=v.name, enabled=enabled})
  end

  -- append non-configured cameras
  local renaminingCamNames = {}
  for name, cam in pairs(vdata.cameras) do
    local configured = false
    for _,v in ipairs(configuration) do
      if v.name == name then configured = true end
    end
    if not configured then
      table.insert(renaminingCamNames, name)
    end
  end

  -- now, a bit more complex: order the remaining cameras with their order number (if present) or jbeam order
  while #renaminingCamNames > 0 do
    local orderMin = 99999
    local lowestOrderId = nil
    for k, name in ipairs(renaminingCamNames) do
      -- locate idx with the minimum order value
      local cam = vdata.cameras[name]
      if cam.order then
        if type(cam.order) == 'number' then
          if cam.order < orderMin then
            orderMin = cam.order
            lowestOrderId = k
          end
        else
          log("E", "", "Incorrectly defined camera, 'order' field is not numeric: "..dumps(type(order)))
        end
      end
    end

    if not lowestOrderId then
      -- no ordering? simply take first one then
      lowestOrderId = 1
    end

    local name = renaminingCamNames[lowestOrderId]
    local enabled = vdata.cameras[name].disabledByDefault ~= true
    table.insert(configuration, {name=name, enabled=enabled})
    table.remove(renaminingCamNames, lowestOrderId)
  end
  end -- shared configuration build

  -- 1st try: we got a saved request, honour it before anything else
  local cameraSet = false
  if ctx.requestedCam[vid] then
    cameraSet = _setVehicleCameraByName(vdata, ctx.requestedCam[vid].name, nil, ctx)
    if cameraSet and vdata.cameras[ctx.requestedCam[vid].name].setCustomData then
      vdata.cameras[ctx.requestedCam[vid].name]:setCustomData( ctx.requestedCam[vid].customData )
    end
    ctx.requestedCam[vid] = nil
  end

  -- 2nd try: let's continue using the previous cam (which may have disappeared if we replaced the vehicle)
  if not cameraSet and focusedCamNamePrevious then
    cameraSet = _setVehicleCameraByName(vdata, focusedCamNamePrevious, nil, ctx)
  end

  -- 3rd try: let's find the first 'enabled' camera and use it (i.e. the default camera)
  if not cameraSet then
    for k,v in pairs(configuration) do
      if v.enabled and vdata.cameras[v.name] and not vdata.cameras[v.name].hidden then
        cameraSet = _setVehicleCameraByIndex(vdata, k, ctx)
        if cameraSet then break end
      end
    end
  end

  -- 4th try: let's find the first 'visible' camera and use it
  if not cameraSet then
    for k,v in pairs(configuration) do
      if vdata.cameras[v.name] then
        cameraSet = _setVehicleCameraByIndex(vdata, k, ctx)
        if cameraSet then break end
      end
    end
  end

  -- 5th try: panic and don't keep calm
  if not cameraSet then
    log("E", "", "Unable to find a single usable camera, not even 'orbit' fallback. All bets are off from this point on")
  end
  if ctx.isMain then saveConfiguration(vdata) end
end
M.processVehicleCameraConfigChanged = processVehicleCameraConfigChanged

local function vehicleChanged(oldVehId, newVehId, ctx)
  ctx = ctx or mainContext
  if oldVehId then
    -- disable all cameras
    local vdata = getVehicleData(ctx)[oldVehId]
    if vdata then
      for camName, camera in pairs(vdata.cameras) do
        camera.wasFocused = vdata.focusedCamName == camName
        camera.focused = false
        if camera.wasFocused then
          if type(camera.onCameraChanged) == 'function' then
            camera:onCameraChanged(camera.focused)
          end
        end
      end
    end
  end

  if newVehId then
    -- enable previously disabled cameras
    local vdata = getVehicleData(ctx)[newVehId]
    if vdata then
      for _, camera in pairs(vdata.cameras) do
        if camera.wasFocused == true then
          camera.focused = true
          if type(camera.onCameraChanged) == 'function' then
            camera:onCameraChanged(camera.focused)
          end
        end
        camera.wasFocused = nil
      end
      if ctx.isMain then notifyUI(vdata) end
    end
  end
end

-- Canonical camera basis vectors (single source of truth)
local upVec = vec3(0, 0, 1)
local fwdVec = vec3(0, 1, 0)
local rightVec = vec3(1, 0, 0)

local function setFreeCameraYawPitchRollDeg(yawDeg, pitchDownDeg, rollDeg)
  if mainContext.activeGlobalCameraName ~= 'free' then return end

  local y = tonumber(yawDeg)
  local p = tonumber(pitchDownDeg)
  local r = tonumber(rollDeg)
  if not (y and p and r) then return end

  -- +pitchDown means looking down
  local yaw = math.rad(y)
  local pitch = math.rad(p)
  local roll = math.rad(r)

  local cp = math.cos(pitch)
  local sp = math.sin(pitch)
  local sy = math.sin(yaw)
  local cy = math.cos(yaw)

  local fwd = vec3(sy * cp, cy * cp, -sp):normalized()
  local up0 = upVec - fwd * upVec:dot(fwd)
  if up0:squaredLength() < 1e-12 then
    up0 = vec3(rightVec) - fwd * vec3(rightVec):dot(fwd)
  end
  up0:normalize()

  local c = math.cos(roll)
  local s = math.sin(roll)
  local up = up0 * c + fwd:cross(up0) * s
  up:normalize()

  local q = quatFromDir(fwd, up)

  local cam = getGlobalCameras().free
  if cam then
    if cam.setRotation then cam:setRotation(q) end
    if cam.angularVelocity then cam.angularVelocity:set(0, 0, 0) end
  end

  setCameraRotC(q.x, q.y, q.z, q.w)
  mainContext.finalCameraData.rot:set(q)
end

local function setVehicleCameraByIndexOffset(player, offset)
  local ctx = ctxForPlayer(player)
  if ctx.activeGlobalCameraName then
    local current = getGlobalCameras(ctx)[ctx.activeGlobalCameraName]
    if current and current.group then
      cycleGroupCam(ctx, current.group, offset, player)
    else
      setGlobalCameraByName(nil, nil, nil, ctx)
      displayCameraNameUI(player)
    end
    return
  end

  local vdata = getVdata(player, ctx)
  if not vdata then return end

  -- this loop is supposed to skip over hidden/disabled cameras
  local focusedCamId = getCamIdFromName(vdata.focusedCamName)
  for i = 1, #configuration do
    focusedCamId = focusedCamId + offset
    if focusedCamId > #configuration then focusedCamId = 1 end
    if focusedCamId < 1 then focusedCamId = #configuration end
    local m = configuration[focusedCamId]
    local enabled = m.enabled
    local visible = vdata.cameras[m.name] and not vdata.cameras[m.name].hidden
    if visible and enabled then break end
  end

  _setVehicleCameraByIndex(vdata, focusedCamId, ctx)
  displayCameraNameUI(player)
  getGlobalCameras(ctx).transition:start()
end

-- dispatch a camera method within a context: the active global camera (unless a
-- specific camName is given) else the vehicle's focused camera. camId is a vehicle
-- id or a {vehId, camName} table.
local function proxy_camId(ctx, camId, fct, ...)
  local vehID, camName
  if type(camId) == "number" then
    vehID = camId
  elseif type(camId) == "table" then
    vehID = camId.vehId
    camName = camId.camName
  else
    log("E", "", "Unrecognized parameter camId: "..dumps(camId))
  end

  if not camName then
    local globalCam = getGlobalCameras(ctx)[ctx.activeGlobalCameraName]
    if globalCam then
      if globalCam[fct] then
        return globalCam[fct](globalCam, ...)
      end
    end
  end

  local vdata = getVehicleData(ctx)[vehID]
  if not vdata then return end

  local c = vdata.cameras[camName or vdata.focusedCamName]
  if c and type(c[fct]) == 'function' then
    return c[fct](c, ...) -- c = self
  end
end

-- same dispatch addressed by player: resolves the player's view, then its active
-- global camera or the player vehicle's focused camera
local function proxy_PID(player, fct, ...)
  local ctx = ctxForPlayer(player)
  local globalCam = getGlobalCameras(ctx)[ctx.activeGlobalCameraName]
  if globalCam then
    if globalCam[fct] then
      return globalCam[fct](globalCam, ...)
    end
  else
    local vid = be:getPlayerVehicleID(player)
    if vid < 0 then return end -- player is not seated in any vehicle at the moment
    return proxy_camId(ctx, vid, fct, ...)
  end
end

--- VID: addressed by vehicle id; act on the main view's camera instances (tech /
--- scenario / streaming code targeting a vehicle, not a player's seat)

local function resetCameraByID(vid, ...)
  return proxy_camId(mainContext, vid, 'reset', ...)
end

local function setRotation(vid, ...)
  if mainContext.activeGlobalCameraName == 'free' then
    local rot = (...)
    if rot ~= nil then
      setCameraRotC(rot.x, rot.y, rot.z, rot.w)
      mainContext.finalCameraData.rot:set(rot)
    end
  end

  return proxy_camId(mainContext, vid, 'setRotation', ...)
end

local function setFOV(vid, ...)
  if mainContext.activeGlobalCameraName == 'free' then
    local fov = (...)
    if fov ~= nil then
      setCameraFovDegC(fov)
      mainContext.finalCameraData.fovDeg = fov
    end
  end

  return proxy_camId(mainContext, vid, 'setFOV', ...)
end

local function setOffset(vid, ...)
  return proxy_camId(mainContext, vid, 'setOffset', ...)
end

local function setup(vid, ...)
  return proxy_camId(mainContext, vid, 'setup', ...)
end

local function setRefNodes(vid, ...)
  return proxy_camId(mainContext, vid, 'setRefNodes', ...)
end

local function setRef(vid, ...)
  return proxy_camId(mainContext, vid, 'setRef', ...)
end

local function setTargetMode(vid, ...)
  return proxy_camId(mainContext, vid, 'setTargetMode', ...)
end

local function setDefaultDistance(vid, ...)
  return proxy_camId(mainContext, vid, 'setDefaultDistance', ...)
end

local function setDistance(vid, ...)
  return proxy_camId(mainContext, vid, 'setDistance', ...)
end

local function setMaxDistance(vid, ...)
  return proxy_camId(mainContext, vid, 'setMaxDistance', ...)
end

local function setDefaultRotation(vid, ...)
  return proxy_camId(mainContext, vid, 'setDefaultRotation', ...)
end

local function setSkipFovModifier(vid, ...)
  return proxy_camId(mainContext, vid, 'setSkipFovModifier', ...)
end

--- PID: addressed by player/seat; act on that player's own view, so split-screen
--- players drive their own camera (player 0 = main view)

local function setPosition(pid, ...)
  if mainContext.activeGlobalCameraName == 'free' then
    local pos = (...)
    if pos ~= nil then
      setCameraPosC(pos.x, pos.y, pos.z)
      mainContext.finalCameraData.pos:set(pos)
    end
  end

  return proxy_PID(pid, 'setPosition', ...)
end

local function setSmoothedCam(pid, ...)
  return proxy_PID(pid, 'setSmoothedCam', ...)
end

local function setNewtonRotation(pid, ...)
  return proxy_PID(pid, 'setNewtonRotation', ...)
end

local function setNewtonTranslation(pid, ...)
  return proxy_PID(pid, 'setNewtonTranslation', ...)
end

local function globalCameraFunction(globalCameraName, functionName, ...)
  local cam = getGlobalCameras()[globalCameraName]
  if not cam then
    log("E", "", "Camera "..dumps(globalCameraName).." not found, cannot call its "..dumps(functionName).." function")
    return
  end
  if not cam[functionName] then
    log("E", "", "Camera "..dumps(globalCameraName).." function "..dumps(functionName).." is invalid, cannot call it")
    return
  end
  return cam[functionName](cam, ...)
end

local function proxy_Player(fct, ...)
  local player = 0
  return proxy_PID(player, fct, ...)
end

local function onTrigger(trigger)
  if not trigger or not trigger.subjectID then return end

  local player = 0
  local vid = be:getPlayerVehicleID(player)
  local otherId = nil
  local triggerTargetOverride = nil
  if trigger.triggerOverride then
    local overrideObj = scenetree.findObject(trigger.triggerOverride)
    if overrideObj then
      otherId = overrideObj:getId()
    end
    if otherId == trigger.subjectID then
      triggerTargetOverride = trigger.triggerOverride
    end
  end

  if vid < 0 and not otherId then return end

  if not commands.isFreeCamera() then
    -- TODO FIXME: this spams the whole UI, needs to be a stream
    --guihooks.trigger('cameraDistance', {state = 'notfree'}) -- TODO: convert into stream
  end

  if trigger.subjectID ~= vid and trigger.subjectID ~= otherId then return end

  local triggeredDuringSpawning = false
  local scenario = scenario_scenarios and scenario_scenarios.getScenario()
  if scenario and (scenario.state == nil or (scenario.state == 'pre-start' or scenario.state == 'restart')) then
    triggeredDuringSpawning = true
  end

  if getActiveCamName() == 'path' or triggeredDuringSpawning then
    if type(trigger.cameraOnEnter) == 'string' and trigger.cameraOnEnter ~= "" then
      local cam = scenetree.findObject(trigger.cameraOnEnter)
      if cam.showApps ~= '1' then
        guihooks.trigger('appContainer:loadLayoutByType', "scenario_cinematic_start")
      end
      pendingTrigger = trigger
      return
    end
  end

  if trigger.event == 'exit' and trigger.cameraOnLeave == true then
    setGlobalCameraByName(nil)
    local vdata = getVehicleData()[vid]
    if vdata then
      notifyUI(vdata)
    end
  elseif trigger.event == 'enter' and type(trigger.cameraOnEnter) == 'string' and trigger.cameraOnEnter ~= "" then
    local cam = scenetree.findObject(trigger.cameraOnEnter)
    if cam then
      setGlobalCameraByName("observer", nil, {cam = cam, targetOverride = triggerTargetOverride or cam.targetOverride})
    else
      log('E', 'camera', 'camera not found for trigger: ' .. dumps(trigger.cameraOnEnter))
    end
  end
end

local function resetCamera(player)
  clearInputs(moveFor(player))
  extensions.hook("onCameraReset")
  return proxy_PID(player, 'reset')
end

local function hotkey(player, hotkeyid, modifier)
  return proxy_PID(player, 'hotkey', hotkeyid, modifier)
end

local function onVehicleResetted(vid, ...)
  local vdata = getVehicleData()[vid]
  if not vdata then return end
  local c = vdata.cameras[vdata.focusedCamName]
  if not c then return end
  local resetCamOnVehicleReset = c.resetCameraOnVehicleReset ~= false

  if resetCamOnVehicleReset and not mainContext.activeGlobalCameraName then
    resetCameraByID(vid, ...)
  end
end

local function onMouseLocked(locked)
  local player = 0
  if commands.isFreeCamera() then return end
  return proxy_PID(player, 'mouseLocked', locked)
end

local function onDespawnObject(vid, isReloading)
  if isReloading == false then
    for _, ctx in pairs(contexts) do delVehicleData(vid, ctx) end
  end
end

-- run the desired function on all cameras of every context
local function proxy_all(functionName, ...)
  for _, ctx in pairs(contexts) do
    for vid, vdata in pairs(getVehicleData(ctx)) do
      for _, cam in pairs(vdata.cameras) do
        if cam[functionName] then
          cam[functionName](cam, ...)
        end
      end
    end
    for _,cam in pairs(getGlobalCameras(ctx)) do
      if cam[functionName] then
        cam[functionName](cam, ...)
      end
    end
  end
end

local function onSettingsChanged(...)
  if commands.isFreeCamera() then
    setSmoothedCam(0, settings.getValue('cameraFreeSmoothMovement'))
  end
  proxy_all("onSettingsChanged", ...)
end

local function resetConfiguration()
  settings.setValue('cameraConfig', "")
  settings.setValue('freeCameraConfig', "")
  table.clear(freeCameraConfiguration)
  for _, ctx in pairs(contexts) do
    for vid, vdata in pairs(getVehicleData(ctx)) do
      processVehicleCameraConfigChanged(vid, vdata, vdata.focusedCamName, ctx)
    end
  end
end

local function onScenarioRestarted(...)
  proxy_all("onScenarioRestarted", ...)
end

local function onScenarioChange(...)
  proxy_all("onScenarioChange", ...)
  local arg = {...}
  local scenario = arg[1]
  if pendingTrigger and scenario and scenario.state == 'running' then
    log('I', 'camera', 'onScenarioChange processing pendingTrigger...')
    local tempTrigger = deepcopy(pendingTrigger)
    pendingTrigger = nil
    onTrigger(tempTrigger)
  end
end

local function onVehicleSwitched(oldId, newId, player)
  -- TODO: Handle other players
  if player ~= 0 then return end

  if not M.getActiveGlobalCameraName() then
    getGlobalCameras().transition:start(true)
  end
  proxy_all("onVehicleSwitched", oldId, newId, player)
  M.displayCameraNameUI(0)
end

local function onSerialize()
  local data = {}
  -- global cameras
  data.globalCameras = {}
  for k,cam in pairs(getGlobalCameras()) do
    if cam.onSerialize then cam:onSerialize() end
    data.globalCameras[k] = serialize(cam)
  end

  -- per-vehicle cameras
  data.vehicleCameras = {}
  for vid, vdata in pairs(getVehicleData()) do
    data.vehicleCameras[vid] = {}
    data.vehicleCameras[vid].cameras = {}
    data.vehicleCameras[vid].focusedCamName = vdata.focusedCamName
    for camName,cam in pairs(vdata.cameras) do
      data.vehicleCameras[vid].cameras[camName] = serialize(cam)
    end
  end
  data.vehicleCameras = convertVehicleIdKeysToVehicleNameKeys(data.vehicleCameras)

  -- general camera data (the main context is the player view we persist)
  data.activeGlobalCameraName = mainContext.activeGlobalCameraName
  data.lastVehicleName = mainContext.lastVehicleName
  data.pendingTrigger = pendingTrigger
  data.requestedCam = mainContext.requestedCam
  return data
end

local function onDeserialized(data)
  -- general camera data
  mainContext.lastVehicleName = data.lastVehicleName
  pendingTrigger = data.pendingTrigger
  mainContext.requestedCam = data.requestedCam or {}

  -- global cameras
  for camName, cam in pairs(getGlobalCameras()) do
    if data.globalCameras[camName] then
      tableMergeRecursive(cam, deserialize(data.globalCameras[camName]))
      if cam.onDeserialized then cam:onDeserialized() end
    end
  end

  -- per-vehicle cameras
  data.vehicleCameras = convertVehicleNameKeysToVehicleIdKeys(data.vehicleCameras)
  for vid, vdata in pairs(getVehicleData()) do
    local svdata = data.vehicleCameras[vid]
    for camName,cam in pairs(vdata.cameras) do
      if svdata then
        if svdata.cameras[camName] then
          tableMergeRecursive(cam, deserialize(svdata.cameras[camName]))
        end
        if camName == svdata.focusedCamName then
          vdata.focusedCamName = svdata.focusedCamName
        end
      end
    end
  end

  -- vehicle cameras will have attempted to remove the global cam name, so overwrite that now
  mainContext.activeGlobalCameraName = data.activeGlobalCameraName
end

local function invalidateCaches()
  constructorsCache = nil
  for _, ctx in pairs(contexts) do
    ctx.globalCamerasCache = nil
    ctx.runningCamsOrderCache = nil
    ctx.vehicleCamerasCache = nil
  end
end

local function onFileChanged(filePath, changeType)
  if (changeType == "added" or changeType == "deleted") and string.startswith(filePath, '/lua/ge/extensions/core/cameraModes/') then
    invalidateCaches()
  end
end

local function onClientEndMission()
  -- clear the camera object of the render view so we dont access a garbage reference
  local mainRenderView = RenderViewManagerInstance:getView('main')
  if mainRenderView then
    mainRenderView:clearCameraObject()
  end
end

local function setFastSpeedModifier(enabled)
  mainContext.camData.fastSpeedModifier = enabled
end

local function setPosRot(pid, px, py, pz, rx, ry, rz, rw)
  if not commands.isFreeCamera() then return end
  core_camera.setPosition(pid, vec3(px, py, pz))
  if rx and ry and rz and rw then
    core_camera.setRotation(pid, quat(rx, ry, rz, rw))
  end
end

local function setSpeed(speed, ctxId)
  local ctx = getContext(ctxId)
  if ctx then ctx.camData.speed = speed end
end

local function getSpeed(ctxId)
  local ctx = getContext(ctxId)
  return ctx and ctx.camData.speed
end

local function setLookBack(player, enabled)
  ctxForPlayer(player).camData.lookBack = enabled
end

local function getLookBack()
  return mainContext.camData.lookBack
end

local function setCameraUnicycleZoom(value)
  mainContext.camData.unicycleZoom = value
end

local function getCameraUnicycleZoom()
  return mainContext.camData.unicycleZoom
end

local function setCameraDriverZoom(value, player)
  ctxForPlayer(player).camData.driverZoom = value
end

local function getCameraDriverZoom(player)
  return ctxForPlayer(player).camData.driverZoom
end

local function driverZoomToggle(player)
  setCameraDriverZoom(tonumber(getCameraDriverZoom(player) or 0) > 0.5 and 0 or 1, player)
end

-- getters default to the main (player) context; pass a context id to read another
local function getPosition(ctxId)
  return vec3(getContext(ctxId).finalCameraData.pos)
end

local function getPositionXYZ(ctxId)
  local pos = getContext(ctxId).finalCameraData.pos
  return pos.x, pos.y, pos.z
end

local function getUp(ctxId)
  local res = vec3(upVec)
  res:setRotate(getContext(ctxId).finalCameraData.rot)
  return res
end

local function getRight(ctxId)
  local res = vec3(rightVec)
  res:setRotate(getContext(ctxId).finalCameraData.rot)
  return res
end

local function getForward(ctxId)
  local res = vec3(fwdVec)
  res:setRotate(getContext(ctxId).finalCameraData.rot)
  return res
end

local resVec = vec3()
local function getForwardXYZ(ctxId)
  resVec:set(fwdVec)
  resVec:setRotate(getContext(ctxId).finalCameraData.rot)
  return resVec.x, resVec.y, resVec.z
end

local function getQuat(ctxId)
  return quat(getContext(ctxId).finalCameraData.rot)
end

-- Returns yawDeg (+Y = 0), pitchDown (+ when looking down), and rollDeg in one call.
local function getYawPitchRoll()
  local worldUp = vec3(0, 0, 1)
  local f = getForward():normalized()
  local u = getUp():normalized()

  local yawDeg = math.deg(math.atan2(f.x, f.y))
  local pitchDown = math.deg(math.asin(clamp(-f:dot(worldUp), -1, 1)))

  local wUpProj = (worldUp - f * worldUp:dot(f)):normalized()
  local uProj = (u - f * u:dot(f)):normalized()
  local rollDeg = math.deg(math.atan2(wUpProj:cross(uProj):dot(f), wUpProj:dot(uProj)))

  return {yawDeg = yawDeg, pitchDown = pitchDown, rollDeg = rollDeg}
end

local function getQuatXYZW(ctxId)
  local rot = getContext(ctxId).finalCameraData.rot
  return rot.x, rot.y, rot.z, rot.w
end

local function getFovDeg(ctxId)
  return getContext(ctxId).finalCameraData.fovDeg
end

local function getFovRad(ctxId)
  return (getContext(ctxId).finalCameraData.fovDeg * math.pi) / 180
end

local function changeSpeed(val)
  if editor and editor.disableCameraZoom then return end
  local camData = mainContext.camData
  local multiplier = 1 + math.abs(val)*0.2
  if val > 0 then camData.speed = camData.speed * multiplier end
  if val < 0 then camData.speed = camData.speed / multiplier end
  setSpeed(clamp(camData.speed, 2, 100))

  ui_message({txt="ui.camera.speed", context={speed=camData.speed}}, 2, "cameraspeed")
  if editor and editor.active and editor.showNotification then
    editor.showNotification(string.format("Camera Speed: %.2f", camData.speed), nil, "CamSpeed", nil, false)
  end
end

local function getActiveGlobalCameraName(player)
  return ctxForPlayer(player).activeGlobalCameraName
end

-- Camera contexts -------------------------------------------------------------
-- A context is an extra camera output ("what the camera is for") that drives its
-- own RenderView, reusing every existing camera mode. The "main" context is the
-- player view. Create one, point it at a RenderView and the input player/seat it
-- follows, then select a camera on it with setContextCamera and read it back via
-- the get*(ctxId) getters. The render target (resolution / namedTexTargetColor)
-- of the RenderView is owned by the caller (e.g. split-screen / video-stream
-- wiring); here we only drive the camera each frame. vehiclePlayer (optional)
-- makes the context show another seat's vehicle (and its cameras) while `player`
-- only drives the input, so e.g. the video stream can spawn a freely-controlled
-- view of the local player's car without stealing the player's own input.
local function createContext(id, renderView, player, vehiclePlayer)
  if id == nil or id == MAIN_CONTEXT then return mainContext end
  local ctx = contexts[id]
  if not ctx then
    ctx = newContext(id, renderView or id, player, vehiclePlayer)
    contexts[id] = ctx
  else
    if renderView then ctx.renderView = renderView end
    if player ~= nil then ctx.player = player end
    if vehiclePlayer ~= nil then ctx.vehiclePlayer = vehiclePlayer end
  end
  contextByPlayer[ctx.player] = ctx -- route this player's look input to this view
  return ctx
end

local function destroyContext(id)
  if id == nil or id == MAIN_CONTEXT then return end -- never destroy the player view
  local ctx = contexts[id]
  if ctx and contextByPlayer[ctx.player] == ctx then
    contextByPlayer[ctx.player] = (ctx.player == 0) and mainContext or nil
  end
  contexts[id] = nil
end

local function getContextIds()
  local ids = {}
  for id in pairs(contexts) do table.insert(ids, id) end
  return ids
end

-- Select a camera on a context without touching the player. camName nil or a
-- global-camera name -> global camera; otherwise the player vehicle's camera.
local function setContextCamera(id, camName, withTransition, customData)
  local ctx = contexts[id]
  if not ctx then log("E", "", "Unknown camera context: "..dumps(id)); return false end
  local isGlobal = (camName == nil) or getGlobalCameras(ctx)[camName] ~= nil
  -- seed a freshly-selected global camera (e.g. free) with the view's current
  -- transform so toggling into it doesn't snap to a default pose
  if camName and isGlobal then
    local cam = getGlobalCameras(ctx)[camName]
    if cam and cam.setPosition then cam:setPosition(vec3(ctx.finalCameraData.pos)) end
    if cam and cam.setRotation then cam:setRotation(quat(ctx.finalCameraData.rot)) end
  end
  -- a global camera must go through the global path (player = nil); only a vehicle
  -- camera carries the context's player. (note: `isGlobal and nil or ctx.player`
  -- would always yield ctx.player, since `and nil` collapses - hence the explicit form)
  return set(camName, withTransition, customData, (not isGlobal) and ctx.player or nil, ctx)
end

-- The active camera object of a context (the global/free camera, else the vehicle's focused one).
local function activeCamOf(ctx)
  if ctx.activeGlobalCameraName then return getGlobalCameras(ctx)[ctx.activeGlobalCameraName] end
  local vdata = getVdata(ctx.player, ctx)
  return vdata and vdata.cameras[vdata.focusedCamName]
end

-- Light, JSON-safe snapshot of a context's camera, enough to put it back where it was
-- (video-stream views persist this across reloads). nil id = the main view. pos/rot/fov is
-- the world transform (restores a free/global cam, and seeds a fresh free view where this one
-- looks); `data` is the active camera mode's own state - each mode that has movable state
-- implements serialize/deserialize (e.g. relative's offset, orbit's rotation+distance).
local function getContextCameraState(id)
  local ctx = (id == nil) and mainContext or contexts[id]
  if not ctx then return nil end
  local fc = ctx.finalCameraData
  local vdata = getVdata(ctx.player, ctx)
  local cam = activeCamOf(ctx)
  local state = {
    cam = ctx.activeGlobalCameraName or (vdata and vdata.focusedCamName) or nil,
    pos = { x = fc.pos.x, y = fc.pos.y, z = fc.pos.z },
    rot = { x = fc.rot.x, y = fc.rot.y, z = fc.rot.z, w = fc.rot.w },
    fov = fc.fovDeg,
  }
  if cam and cam.serialize then state.data = cam:serialize() end
  return state
end

-- Restore a context's camera from getContextCameraState's snapshot. A mode with deserialize
-- restores its own state (relative offset, orbit rotation/distance, ...); a free/global cam
-- without one is placed at the saved world pose.
local function setContextCameraState(id, state)
  local ctx = contexts[id]
  if not ctx or type(state) ~= 'table' then return end
  local isGlobal = (state.cam == nil) or state.cam == 'free' or getGlobalCameras(ctx)[state.cam] ~= nil
  setContextCamera(id, isGlobal and (state.cam or 'free') or state.cam)
  local cam = activeCamOf(ctx)
  if not cam then return end
  if cam.deserialize and state.data ~= nil then
    cam:deserialize(state.data)
  elseif isGlobal then -- free/global cam: place it at the saved world pose
    if state.pos and cam.setPosition then cam:setPosition(vec3(state.pos.x, state.pos.y, state.pos.z)) end
    if state.rot and cam.setRotation then cam:setRotation(quat(state.rot.x, state.rot.y, state.rot.z, state.rot.w)) end
    if state.fov and cam.setFOV then cam:setFOV(state.fov) end
  end
end

-- Tunable params of a context's active camera, for the camera-control / video-stream UI.
-- Each camera mode owns its full param list (its listParams/setParam); this only resolves
-- the active camera and delegates. Descriptors are self-describing: { key, title, kind =
-- 'range'|'bool'|'choice'|'slots', type = 'float'|'int'|'bool'|'enum', value,
-- [icon (Font Awesome solid class, e.g. 'fa-expand'), default, min, max, step, unit, options] }.
local function getContextCameraParams(id)
  local ctx = (id == nil) and mainContext or contexts[id]
  if not ctx then return {} end
  local cam = activeCamOf(ctx)
  return (cam and cam.listParams) and cam:listParams(id) or {}
end

-- Apply one tunable to a context's active camera (nil id = the main player view), delegating
-- to the camera mode's own setParam.
local function setContextCameraParam(id, key, value)
  local ctx = (id == nil) and mainContext or contexts[id]
  if not ctx then return end
  local cam = activeCamOf(ctx)
  if cam and cam.setParam then cam:setParam(key, value, id) end
end

-- wire the split-out submodules now that this file's shared state + helpers exist
cameraInput.setup({ moveFor = moveFor, getFovDeg = getFovDeg })
cameraUpdate.setup({
  contexts = contexts, mainContext = mainContext, moveManager = moveManager,
  getConfiguration = function() return configuration end,
  getGlobalCameras = getGlobalCameras, getVehicleData = getVehicleData, getRunningCamsOrder = getRunningCamsOrder,
  setGlobalCameraByName = setGlobalCameraByName, set = set, vehicleChanged = vehicleChanged,
  isWithinRadius = isWithinRadius, isUnicycle = isUnicycle, cameraM = M,
})

-- callbacks
M.onPreRender = cameraUpdate.onPreRender -- just update the camera right before the rendering
M.onTrigger = onTrigger
M.onSettingsChanged = onSettingsChanged
M.onVehicleResetted = onVehicleResetted
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleSwitched = onVehicleSwitched
M.onDespawnObject = onDespawnObject
M.onVehicleDestroyed = onVehicleDestroyed
M.onScenarioRestarted = onScenarioRestarted
M.onScenarioChange = onScenarioChange
M.onFileChanged = onFileChanged
M.onMouseLocked = onMouseLocked
M.onClientPostStartMission = cameraUpdate.onClientPostStartMission
M.onClientEndMission = onClientEndMission


-- internal things
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

-- functions used by other GE lua code
M.clearInputs = clearInputs
M.resetCameraByID = resetCameraByID
M.setRotation = setRotation
M.setFOV = setFOV
M.setOffset = setOffset
M.setRefNodes = setRefNodes
M.setRef = setRef
M.setTargetMode = setTargetMode
M.setDefaultDistance = setDefaultDistance
M.setDistance = setDistance
M.setMaxDistance = setMaxDistance
M.setDefaultRotation = setDefaultRotation
M.setSkipFovModifier = setSkipFovModifier
M.setFastSpeedModifier = setFastSpeedModifier
M.changeSpeed = changeSpeed
M.setPosition = setPosition
M.setSmoothedCam = setSmoothedCam
M.setNewtonRotation = setNewtonRotation
M.setNewtonTranslation = setNewtonTranslation
M.setByName = setByName
M.setCameraByNameFromOptions = setCameraByNameFromOptions
M.setVehicleCameraByNameWithId = setVehicleCameraByNameWithId
M.exitCinematicCamera = function() setGlobalCameraByName(nil) end -- retrocompatibility layer
M.toggleEnabledById = toggleEnabledCameraById
M.toggleFreeCameraEnabledById = toggleFreeCameraEnabledById
M.setBySlotId = setBySlotId
M.changeOrder = changeOrder
M.changeFreeCameraOrder = changeFreeCameraOrder
M.getCameraDataById = getCameraDataById
M.getDriverData = getDriverData
M.getDriverDataById = getDriverDataById
M.getActiveCamName = getActiveCamName
M.getActiveCamNameByVehId = getActiveCamNameByVehId
M.getConfigurationReadOnly = getConfigurationReadOnly
M.getFreeCameraConfigurationReadOnly = getFreeCameraConfigurationReadOnly
M.displayCameraNameUI = displayCameraNameUI
M.onCameraToggled = onCameraToggled
M.isCameraInside = isCameraInside
M.timeSinceLastRotation = cameraInput.timeSinceLastRotation
M.getGlobalCameras = getGlobalCameras
M.getGroupCams = getGroupCams
M.getCameraGroups = getCameraGroups
M.nextCameraGroup = nextCameraGroup
M.objectTeleported = objectTeleported   -- deprecated API, please use 'objectTeleported' directly, instead of using 'core_camera.objectTeleported'
M.setGlobalCameraByName = setGlobalCameraByName
M.setPosRot = setPosRot
M.setSpeed = setSpeed
M.getSpeed = getSpeed
M.getLookBack = getLookBack
M.getActiveGlobalCameraName = getActiveGlobalCameraName

-- camera contexts (extra views, e.g. video streaming)
M.createContext = createContext
M.destroyContext = destroyContext
M.getContextIds = getContextIds
M.setContextCamera = setContextCamera
M.getContextCameraState = getContextCameraState
M.setContextCameraState = setContextCameraState
M.getContextCameraParams = getContextCameraParams
M.setContextCameraParam = setContextCameraParam

M.getPosition = getPosition
M.getPositionXYZ = getPositionXYZ
M.getUp = getUp
M.getRight = getRight
M.getForward = getForward
M.getForwardXYZ = getForwardXYZ
M.getQuat = getQuat
M.getQuatXYZW = getQuatXYZW
M.getYawPitchRoll = getYawPitchRoll
M.setFreeCameraYawPitchRollDeg = setFreeCameraYawPitchRollDeg
M.getFovDeg = getFovDeg
M.getFovRad = getFovRad

M.proxy_Player = proxy_Player
M.globalCameraFunction = globalCameraFunction

-- functions used by UI options
M.requestConfig = requestConfig
M.notifyUI = notifyUI
M.resetConfiguration = resetConfiguration

-- functions used from the input code
M.setVehicleCameraByIndexOffset = setVehicleCameraByIndexOffset
M.cycleCameraGroup = cycleCameraGroup
M.resetCamera = resetCamera
M.setLookBack = setLookBack
M.setCameraUnicycleZoom = setCameraUnicycleZoom
M.setCameraDriverZoom = setCameraDriverZoom
M.getCameraDriverZoom = getCameraDriverZoom
M.driverZoomToggle = driverZoomToggle
M.hotkey = hotkey
M.rotate_pitch = cameraInput.rotate_pitch
M.rotate_pitch_up = cameraInput.rotate_pitch_up
M.rotate_pitch_down = cameraInput.rotate_pitch_down
M.rotate_yaw = cameraInput.rotate_yaw
M.rotate_yaw_left = cameraInput.rotate_yaw_left
M.rotate_yaw_right = cameraInput.rotate_yaw_right
M.cameraZoom = cameraInput.cameraZoom
M.rotate_yaw_relative = cameraInput.rotate_yaw_relative
M.rotate_pitch_relative = cameraInput.rotate_pitch_relative
M.rotate_roll_right = cameraInput.rotate_roll_right
M.rotate_roll_left = cameraInput.rotate_roll_left

M.yawAbs = cameraInput.yawAbs
M.rollAbs = cameraInput.rollAbs
M.pitchAbs = cameraInput.pitchAbs
M.xAxisAbs = cameraInput.xAxisAbs
M.yAxisAbs = cameraInput.yAxisAbs
M.zAxisAbs = cameraInput.zAxisAbs
M.yAxisMoveStep = cameraInput.yAxisMoveStep

M.moveleft     = cameraInput.moveleft
M.moveright    = cameraInput.moveright
M.moveforward  = cameraInput.moveforward
M.movebackward = cameraInput.movebackward
M.moveup       = cameraInput.moveup
M.movedown     = cameraInput.movedown
M.moveForwardBackward = cameraInput.moveForwardBackward
M.moveLeftRight = cameraInput.moveLeftRight
M.getLastFilter = cameraInput.getLastFilter
M.getLastCameraMovementType = cameraInput.getLastCameraMovementType

M.onReplayStateChanged = function(newState)
  -- Only clear the vehicle camera cache when leaving replay *playback*.
  -- Stopping a recording also transitions to 'inactive', and clearing the cache there
  -- resets the current camera mode/offset/zoom (regression).
  if newState.state == 'inactive' and M.previousReplayStateName == 'playback' then
    -- Due to the replay system destroying vehicles that are in the scene but not in the video it is about to play, the camera system
    -- responds to the onDestroyVehicle callback by removing entries from the vehicle cache. This is a destructive change that the camera system
    -- cannot recover from when the replay is over and "ejected".
    -- This is particularlly important when trying to return to the game state as it was BEFORE playing a replay video.
    -- The vehicles that were removed are returned to the scene somehow but the cache is not updated. Investigate why later.
    for _, ctx in pairs(contexts) do ctx.vehicleCamerasCache = nil end
  end

  M.previousReplayStateName = newState.state
end

return M
