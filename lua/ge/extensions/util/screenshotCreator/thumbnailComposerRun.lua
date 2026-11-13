-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_imgui",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_lightingSetup",
  "util_screenshotCreator_thumbnailCapturePipeline",
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_thumbnailPaths",
  "util_screenshotCreator_thumbnailTargets"
}

local logTag = "thumbnailComposerV2"
local runSequence = 0
local activeRun
local workerCoroutine
local forceQuit = false
local savedPhysicsState
local savedSettings
local savedSessionSnapshot
local applySessionSnapshot

-- applied for the duration of a run: the reference in-game graphics (resolution and display mode stay untouched)
-- and no seat occupants. License plates stay with the showroom session, which restores them on leave.
local captureSettings = {
  GraphicOverallQuality = "Custom",
  GraphicMeshQuality = "Ultra",
  GraphicTextureQuality = "Normal",
  GraphicLightingQuality = "Ultra",
  GraphicCloudsQuality = "High",
  GraphicShadowsQuality = "Ultra",
  GraphicClusteredQuality = "Ultra",
  GraphicTerrainQuality = "High",
  GraphicDynReflectionQuality = "High",
  GraphicDynReflectionFacesPerupdate = 2,
  GraphicDynMirrorsQuality = "High",
  GraphicDynMirrorsDetail = 0.75,
  GraphicAnisotropic = 16,
  GraphicAntialias = 4,
  GraphicAntialiasType = "smaa",
  GraphicUpscalingQuality = 1,
  GraphicUpscalingSharpness = 0,
  GraphicEVCompensation = 0,
  GraphicGrassDensity = 1,
  GraphicMaxDecalCount = 8000,
  PostFXDOFGeneralEnabled = true,
  PostFXMotionBlurEnabled = false,
  PostFXSSAOGeneralEnabled = true,
  PostFXSSAOGeneralQuality = "High",
  PostFXSpecularOcclusionEnabled = false,
  PostFXSSREnabled = true,
  PostFXSSRQuality = "High",
  PostFXScreenSpaceShadowsEnabled = true,
  PostFXScreenSpaceShadowsQuality = "High",
  lastSplitCastersEnabled = true,
  vehicleShadowEnabled = true,
  enableSeatOccupants = false
}

-- blur ramps from blurStartFromWall metres in front of the background wall to full at the wall
local blurStartFromWall = 8
local blurStrength = 0
local dofTargetScale -- engine value while our DOF is active
local exposureEV -- forced EV, nil keeps the level exposure
local savedExposure -- engine exposure while ours is forced
local previewCameraState

local function emit(handlers, ownerId, name, data)
  if type(handlers) ~= "table" or type(handlers.emit) ~= "function" then return end
  local ok, err = pcall(handlers.emit, ownerId, name, data or {})
  if not ok then log("E", logTag, "Unable to emit " .. tostring(name) .. ": " .. tostring(err)) end
end

local function getOutputResolution(message)
  return {
    clamp(math.floor(tonumber(message.outputWidth) or 500), 16, 8192),
    clamp(math.floor(tonumber(message.outputHeight) or 281), 16, 8192)
  }
end

local function setViewOptions(message)
  blurStrength = clamp(tonumber(message.backgroundBlur) or 0, 0, 1)
  blurStartFromWall = clamp(tonumber(message.blurStartDistance) or 8, 0.5, 30)
  exposureEV = message.forceExposure == true and clamp(tonumber(message.exposureEV) or 8.3, -20, 20) or nil
end

-- autoExposure is toggled around the EV write so the post effect picks the new value up
local function setExposure(auto, ev)
  local exposure = scenetree.findObject("PostEffectLocalExposureObject")
  if not exposure then return end
  exposure.autoExposure = not auto
  exposure.manualEV = ev
  exposure.autoExposure = auto
end

local function restoreExposure()
  if not savedExposure then return end
  setExposure(savedExposure.auto, savedExposure.ev)
  savedExposure = nil
end

local function applyExposure()
  local exposure = scenetree.findObject("PostEffectLocalExposureObject")
  if not exposure or (savedExposure and not exposure.autoExposure and math.abs(exposure.manualEV - exposureEV) < 0.001) then return end
  savedExposure = savedExposure or {auto = exposure.autoExposure, ev = exposure.manualEV}
  setExposure(false, exposureEV)
end

local function restoreDof()
  if not dofTargetScale then return end
  local dof = scenetree.findObject("DOFPostEffect")
  if dof then
    dof:setField("targetScale", 0, dofTargetScale)
    require("client/postFx/dof").updateDOFSettings()
  end
  dofTargetScale = nil
end

-- DOF works in view depth, so refocus every frame from the wall seen by the current capture camera
local function applyDof()
  local dof = scenetree.findObject("DOFPostEffect")
  local camPos, forward = core_camera.getPosition(), core_camera.getForward()
  local flat = vec3(forward.x, forward.y, 0):normalized()
  local hit = dof and Engine.castRay(camPos, camPos + flat * 300, true, true)
  if not hit then return end
  local farDist = tonumber(VariableRegistry.get("$Param::FarDist")) or 300
  local depthScale = flat:dot(forward) / farDist
  local wall = hit.dist * depthScale
  local start = math.max(0, hit.dist - blurStartFromWall / math.max(math.abs(flat:dot(hit.norm)), 0.1)) * depthScale
  -- DOF_Final: far CoC = 1 - exp(-2000 * (farSlope * (depth - focal) - focal)) with nearSlope -1, ranges 0
  local slope = 0.0015 / math.max(wall - start, 1e-5)
  dof.autoFocusEnabled = false
  dof.minRange, dof.maxRange = 0, 0
  dof.nearSlope, dof.nearBlurMax = -1, 0
  dof.farSlope, dof.farBlurMax = slope, 1
  dof.focalDist = slope * start / (1 + slope) * farDist
  if not dofTargetScale then
    dofTargetScale = dof:getField("targetScale", 0)
    dof:enable()
  end
  -- the largest DOF blur is a fixed kernel on this downsampled buffer, so a smaller buffer blurs wider
  local scale = 0.4 - 0.32 * blurStrength
  if math.abs(tonumber(dof:getField("targetScale", 0):match("%S+")) - scale) > 0.001 then
    dof:setField("targetScale", 0, scale .. " " .. scale)
  end
end

local function stopPreview()
  if not previewCameraState then return end
  core_camera.setContextCameraState(nil, previewCameraState)
  previewCameraState = nil
  if util_screenshotCreator_lightingSetup then util_screenshotCreator_lightingSetup.restore() end
end

local function startPreview(message)
  local vehicle = getPlayerVehicle(0)
  if not vehicle or activeRun then return end
  setViewOptions(message)
  local configName = util_screenshotCreator_thumbnailTargets.normalizeConfigName(vehicle.partConfig)
  local camera, context = util_screenshotCreator_thumbnailCapturePipeline.resolveCamera(vehicle, vehicle.jbeam, configName, getOutputResolution(message))
  if not camera then return end
  previewCameraState = previewCameraState or core_camera.getContextCameraState(nil)
  core_camera.setByName(0, "free")
  core_camera.setPosRot(0, camera.pos.x, camera.pos.y, camera.pos.z, camera.rot.x, camera.rot.y, camera.rot.z, camera.rot.w)
  core_camera.setFOV(0, camera.fov or context.fieldOfView)
  util_screenshotCreator_lightingSetup.adjust(vehicle, camera)
end

local function restorePhysicsState()
  if not savedPhysicsState then return true end
  local state = savedPhysicsState
  local ok, err = pcall(function()
    be:setPhysicsSpeedFactor(state.speedFactor)
    be:setPhysicsRunning(state.running)
  end)
  savedPhysicsState = nil
  if not ok then
    log("E", logTag, "Unable to restore physics state: " .. tostring(err))
    return false
  end
  return true
end

local function beginPhysicsOwnership()
  if savedPhysicsState and not restorePhysicsState() then return false end
  if not be or not be.getPhysicsRunning or not be.setPhysicsRunning
    or not be.getPhysicsSpeedFactor or not be.setPhysicsSpeedFactor
  then
    log("E", logTag, "Physics state APIs are unavailable")
    return false
  end
  savedPhysicsState = {
    running = be:getPhysicsRunning(),
    speedFactor = be:getPhysicsSpeedFactor()
  }
  return true
end

local function applyCaptureSettings()
  if util_screenshotCreator_settings and util_screenshotCreator_settings.getEnvironmentSnapshot then
    savedSessionSnapshot = util_screenshotCreator_settings.getEnvironmentSnapshot()
    applySessionSnapshot = util_screenshotCreator_settings.applyEnvironmentSnapshot
  end
  savedSettings = {}
  for key, value in pairs(captureSettings) do
    savedSettings[key] = settings.getValue(key)
    -- an unset boolean reads as nil, which setState can't restore
    if savedSettings[key] == nil and type(value) == "boolean" then savedSettings[key] = false end
  end
  settings.setState(captureSettings)
end

local function restoreSettings(leaving)
  if not savedSettings then return end
  settings.setState(savedSettings)
  savedSettings = nil
  if leaving then
    if savedSessionSnapshot and applySessionSnapshot then applySessionSnapshot(savedSessionSnapshot) end
  elseif util_screenshotCreator_settings and util_screenshotCreator_settings.applyEnvironment then
    util_screenshotCreator_settings.applyEnvironment()
  end
end

local function cleanupRunState(leaving)
  util_screenshotCreator_thumbnailCapturePipeline.resetRenderState()
  restoreSettings(leaving)
  restorePhysicsState()
end

local function failRun(reason, cancelled)
  if not activeRun then return end
  local ownerId = activeRun.ownerId
  local runId = activeRun.runId
  local handlers = activeRun.handlers
  forceQuit = true
  cleanupRunState()
  activeRun = nil
  workerCoroutine = nil
  log(cancelled and "I" or "E", logTag, tostring(reason))
  emit(handlers, ownerId, "Failed", {
    runId = runId,
    error = tostring(reason or "Thumbnail capture failed"),
    cancelled = cancelled == true
  })
end

local function sendProgress(ownerId, runId, completed, total, current, handlers)
  emit(handlers, ownerId, "Progress", {
    runId = runId,
    stage = "capture",
    completed = completed,
    total = total,
    current = current
  })
end

local function runWork(options)
  local ownerId = activeRun.ownerId
  local runId = activeRun.runId
  local handlers = activeRun.handlers
  local workVehicle = getPlayerVehicle(0)
  local settingsSnapshot = {
    capture = util_screenshotCreator_settings.getCaptureContext(),
    captureTimeout = 5
  }
  local runContext = {
    initialPosition = workVehicle and vec3(workVehicle:getPosition()) or nil,
    initialRotation = workVehicle and quat(workVehicle:getRotation()) or nil
  }

  for index, item in ipairs(activeRun.items) do
    if forceQuit then failRun("Cancelled", true) return end
    local result = util_screenshotCreator_thumbnailCapturePipeline.processWorkItem(
      item,
      index,
      #activeRun.items,
      settingsSnapshot,
      runContext,
      {
        captureMode = options.captureMode,
        outputResolution = options.outputResolution,
        isCancelled = function() return forceQuit end,
        sendProgress = function(completed, total, current)
          sendProgress(ownerId, runId, completed, total, current, handlers)
        end
      }
    )
    if not result then failRun("Cancelled", true) return end
    result.runId = runId
    result.itemId = tostring(index)
    result.index = index
    result.total = #activeRun.items
    result.current = result.current or item.modelKey .. "/" .. item.configName
    emit(handlers, ownerId, "ItemResult", result)
    sendProgress(ownerId, runId, index, #activeRun.items, result.current, handlers)
    if result.status == "failed" then
      failRun(result.error or "Capture failed")
      return
    end
  end

  cleanupRunState()
  emit(handlers, ownerId, "RunComplete", {runId = runId})
  activeRun = nil
end

function M.sendStatus(ownerId, handlers)
  local vehicle = getPlayerVehicle(0)
  local modelName = vehicle and (vehicle.jbeam or vehicle.JBeam)
  local configName = vehicle and util_screenshotCreator_thumbnailTargets.normalizeConfigName(vehicle.partConfig)
  emit(handlers, tostring(ownerId or ""), "Status", {
    active = activeRun ~= nil,
    runId = activeRun and activeRun.runId or nil,
    currentModel = modelName,
    currentConfig = configName,
    currentFlipped = modelName and util_screenshotCreator_thumbnailConfig.getRotation(modelName, configName) == 180 or false
  })
end

function M.subscribe(ownerId, handlers)
  ownerId = tostring(ownerId or "")
  M.sendStatus(ownerId, handlers)
  emit(handlers, ownerId, "Catalog", {
    models = util_screenshotCreator_thumbnailTargets.buildModelCatalog(),
    resolutions = util_screenshotCreator_settings.getResolutions()
  })
end

-- message: targets (nil captures the player vehicle), captureMode ("defaults" writes default.jpg, otherwise
-- one file per config), missingOnly, outputWidth/outputHeight and the blur/exposure view options
function M.start(ownerId, message, handlers)
  ownerId = tostring(ownerId or "")
  message = type(message) == "table" and message or {}
  if activeRun or workerCoroutine then
    emit(handlers, ownerId, "Failed", {error = "A thumbnail capture is already running"})
    return false
  end

  local items, itemError = util_screenshotCreator_thumbnailTargets.resolveStartMessage(message)
  if not items then
    emit(handlers, ownerId, "Failed", {error = itemError or "Invalid capture targets"})
    return false
  end
  if message.missingOnly == true then
    local missing = {}
    for _, item in ipairs(items) do
      if not util_screenshotCreator_thumbnailPaths.hasThumbnail(item) then missing[#missing + 1] = item end
    end
    items = missing
    if #items == 0 then
      emit(handlers, ownerId, "Failed", {error = "The selected vehicles have no missing thumbnails"})
      return false
    end
  end
  if not beginPhysicsOwnership() then
    emit(handlers, ownerId, "Failed", {error = "Unable to take physics ownership"})
    return false
  end

  stopPreview()
  setViewOptions(message)
  applyCaptureSettings()
  runSequence = runSequence + 1
  local runId = string.format("%d_%d", os.time(), runSequence)
  forceQuit = false
  activeRun = {
    ownerId = ownerId,
    runId = runId,
    items = items,
    handlers = handlers
  }
  local options = {
    captureMode = message.captureMode == "defaults" and "defaults" or "all",
    outputResolution = getOutputResolution(message)
  }
  workerCoroutine = coroutine.create(function() runWork(options) end)
  sendProgress(ownerId, runId, 0, #items, "", handlers)
  return true
end

function M.cancel(ownerId)
  if not activeRun or (ownerId and activeRun.ownerId ~= tostring(ownerId)) then return false end
  forceQuit = true
  failRun("Cancelled", true)
  return true
end

function M.isActive(ownerId)
  if not activeRun then return false end
  return not ownerId or activeRun.ownerId == tostring(ownerId)
end

function M.onPreRender()
  local worker = workerCoroutine
  if worker then
    local ok, err = coroutine.resume(worker)
    if not ok then
      log("E", logTag, "workerCoroutine: " .. tostring(err))
      log("E", logTag, debug.traceback(worker))
      failRun(err or "Capture failed")
    elseif workerCoroutine == worker and coroutine.status(worker) == "dead" then
      workerCoroutine = nil
    end
  end

  local active = previewCameraState or activeRun
  if blurStrength > 0 and active then applyDof() else restoreDof() end
  if exposureEV and active then applyExposure() else restoreExposure() end
end

function M.onExtensionUnloaded()
  forceQuit = true
  savedExposure = nil
  stopPreview()
  restoreDof()
  cleanupRunState(true)
  activeRun = nil
  workerCoroutine = nil
end
M.onClientEndMission = M.onExtensionUnloaded
M.onExit = M.onExtensionUnloaded

-- thumbnail section of the showroom_thumbnails "Showroom Tools" window, drawn inside the flowgraph's imgui window
local im = ui_imgui
local showroomOwnerId = "showroomTools"
local ui = {
  backgroundBlur = im.FloatPtr(0.9),
  blurStartDistance = im.FloatPtr(8),
  forceExposure = im.BoolPtr(true),
  exposureEV = im.FloatPtr(8.3),
  outputSize = im.ArrayInt(2),
  resolutionIndex = im.IntPtr(1), -- 0 is custom, the presets follow in settings order
  checkbox = im.BoolPtr(false),
  gridSize = im.ImVec2(0, 0),
  selected = {},
  progress = {completed = 0, total = 0, current = ""},
  status = ""
}
ui.outputSize[0], ui.outputSize[1] = 500, 281

local showroomHandlers = {emit = function(_, name, data)
  if name == "Progress" then
    ui.progress.completed, ui.progress.total, ui.progress.current = data.completed, data.total, data.current or ""
  elseif name == "RunComplete" then
    ui.status = string.format("Saved %d thumbnail(s)", ui.progress.total)
  elseif name == "Failed" then
    ui.status = data.cancelled and "Cancelled" or tostring(data.error)
  end
end}

local function loadShowroomCatalog()
  ui.models = util_screenshotCreator_thumbnailTargets.buildModelCatalog()
  ui.resolutions = util_screenshotCreator_settings.getResolutions()
  ui.resolutionItems = "Custom\0"
  for _, preset in ipairs(ui.resolutions) do
    ui.resolutionItems = ui.resolutionItems .. string.format("%s - %d x %d\0", preset[1], preset[2], preset[3])
  end
  ui.resolutionItems = ui.resolutionItems .. "\0"
end

local function startShowroom(message)
  message.backgroundBlur = ui.backgroundBlur[0]
  message.blurStartDistance = ui.blurStartDistance[0]
  message.forceExposure = ui.forceExposure[0]
  message.exposureEV = ui.exposureEV[0]
  message.outputWidth = ui.outputSize[0]
  message.outputHeight = ui.outputSize[1]
  ui.status = ""
  ui.progress.completed, ui.progress.total, ui.progress.current = 0, 0, ""
  M.start(showroomOwnerId, message, showroomHandlers)
end

local function startShowroomSelected(missingOnly)
  local modelKeys = {}
  for _, model in ipairs(ui.models) do
    if ui.selected[model.key] then modelKeys[#modelKeys + 1] = model.key end
  end
  local targets = util_screenshotCreator_thumbnailTargets.buildShippedTargets(modelKeys)
  if #targets == 0 then
    ui.status = "The selected vehicles have no shipped configs"
    return
  end
  startShowroom({targets = targets, missingOnly = missingOnly})
end

local function drawShowroomRenderOptions()
  im.SliderFloat("Background blur", ui.backgroundBlur, 0, 1, "%.2f")
  im.SliderFloat("Blur start from wall", ui.blurStartDistance, 0.5, 30, "%.1f m")
  im.Checkbox("Force exposure", ui.forceExposure)
  im.BeginDisabled(not ui.forceExposure[0])
  im.SliderFloat("Exposure", ui.exposureEV, -20, 20, "%.1f EV")
  im.EndDisabled()
  if im.Combo2("Resolution", ui.resolutionIndex, ui.resolutionItems) and ui.resolutionIndex[0] > 0 then
    local preset = ui.resolutions[ui.resolutionIndex[0]]
    ui.outputSize[0], ui.outputSize[1] = preset[2], preset[3]
  end
  if im.InputInt2("Width x height", ui.outputSize) then ui.resolutionIndex[0] = 0 end
end

local function drawShowroomVehicleGrid()
  im.TextUnformatted(string.format("Vehicles (%d selected)", tableSize(ui.selected)))
  im.SameLine()
  if im.SmallButton("All") then
    for _, model in ipairs(ui.models) do ui.selected[model.key] = true end
  end
  im.SameLine()
  if im.SmallButton("None") then ui.selected = {} end
  im.SameLine()
  if im.SmallButton("Current") then
    local vehicle = getPlayerVehicle(0)
    ui.selected = vehicle and {[vehicle.jbeam] = true} or {}
  end

  ui.gridSize.y = 200 * im.uiscale[0]
  if im.BeginChild1("##showroomVehicles", ui.gridSize, true) then
    if im.BeginTable("##showroomVehicleGrid", 3) then
      for _, model in ipairs(ui.models) do
        im.TableNextColumn()
        ui.checkbox[0] = ui.selected[model.key] == true
        if im.Checkbox(model.label .. "##" .. model.key, ui.checkbox) then
          ui.selected[model.key] = ui.checkbox[0] or nil
        end
      end
      im.EndTable()
    end
  end
  im.EndChild()
end

local function drawShowroomProgress()
  local progress = ui.progress
  local fraction = progress.total > 0 and progress.completed / progress.total or 0
  im.ProgressBar(fraction, nil, string.format("%d / %d", progress.completed, progress.total))
  im.TextUnformatted(progress.current ~= "" and progress.current or "Preparing...")
  if im.Button("Cancel") then M.cancel(showroomOwnerId) end
end

function M.drawShowroomTools()
  if not ui.models then loadShowroomCatalog() end

  im.BeginDisabled(activeRun ~= nil)
  drawShowroomRenderOptions()
  drawShowroomVehicleGrid()
  if im.Button("Capture current config") then startShowroom({}) end
  local selectedCount = tableSize(ui.selected)
  im.BeginDisabled(selectedCount == 0)
  if im.Button(string.format("Capture all configs (%d models)", selectedCount)) then startShowroomSelected(false) end
  im.SameLine()
  if im.Button(string.format("Capture missing thumbnails (%d models)", selectedCount)) then startShowroomSelected(true) end
  im.EndDisabled()
  im.EndDisabled()

  if M.isActive(showroomOwnerId) then
    drawShowroomProgress()
  elseif ui.status ~= "" then
    im.TextWrapped(ui.status)
  end
end

M.setViewOptions = setViewOptions
M.startPreview = startPreview
M.stopPreview = stopPreview

return M
