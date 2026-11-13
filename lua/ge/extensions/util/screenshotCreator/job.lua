-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "core_camera",
  "core_vehicles",
  "core_vehicle_manager",
  "ui_vehicleSelector_general",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_vehicleSetup",
  "util_screenshotCreator_capture",
  "util_screenshotCreator_lightingSetup",
  "util_screenshotCreator_framing_configured",
  "util_screenshotCreator_framingManager",
  "util_screenshotCreator_modelSelection",
  "util_screenshotCreator_shippedConfigs"
}

-- Cooperating extension API:
-- settings.getFramingContext(), settings.getCaptureContext(), settings.beginWork(), settings.finishWork()
-- thumbnailConfig.getPauseDelay(modelName, configName)
-- vehicleSetup.placeVehicleForThumbnail(), waitForVehicleToSettle(), setLowBeams()
-- capture.takeThumbnailScreenshot(filepath, camera, callback, uniqueId, options)
-- framingManager.getSelectedModeId(), framingManager.resolve(modeId, context)
-- modelSelection.getSelectedModels()

local workerCoroutine
local forceQuit = false
local progress = {completed = 0, total = 0, current = ""}
local review
local runDone = false
local environmentOverrideActive = false
local captureWarmupSeconds = 2
local savedPhysicsState

local previousFov
local cameraSet = false

local function isBatch()
  local args = Engine.getStartingArgs()
  local probability = 0
  for i = 1, #args do
    local arg = args[i]:stripchars('"')
    if arg == "-onLevelLoad_ext" or arg == "'util/createThumbnails'" then
      probability = probability + 1
    end
  end
  return probability > 1
end

local function normalizeFolder(path)
  path = type(path) == "string" and path or ""
  if path ~= "" and path:sub(-1) ~= "/" then
    path = path .. "/"
  end
  return path
end

local function getModelName(vehicle)
  return vehicle and (vehicle.jbeam or vehicle.JBeam) or nil
end

local function yieldSeconds(seconds)
  local start = os.clock()
  while os.clock() - start < seconds do
    coroutine.yield()
  end
end

local function getSettingsSnapshot()
  local captureContext = util_screenshotCreator_settings.getCaptureContext()
  local framingContext = util_screenshotCreator_settings.getFramingContext(captureContext.resolution)
  return {
    capture = captureContext,
    framing = framingContext,
    fileEnding = captureContext.fileEnding or ".jpg",
    outputFolder = captureContext.outputDestinationIndex == 1 and "screenshots/showroom/" or "vehicles/",
    fov = framingContext.fieldOfView,
    nearPlane = framingContext.nearPlane,
    captureTimeout = 5
  }
end

local function resolveFramingMode(modeId)
  if type(modeId) == "string" and modeId ~= "" then
    return modeId
  end
  return util_screenshotCreator_framingManager.getSelectedModeId()
end

local function setCamera(camera, settingsSnapshot)
  if type(camera) ~= "table" or not camera.pos or not camera.rot then
    return false
  end

  previousFov = core_camera.getFovDeg()
  core_camera.setByName(0, "free")
  core_camera.setPosRot(
    0,
    camera.pos.x,
    camera.pos.y,
    camera.pos.z,
    camera.rot.x,
    camera.rot.y,
    camera.rot.z,
    camera.rot.w
  )
  core_camera.setFOV(0, camera.fov or settingsSnapshot.fov)
  cameraSet = true
  return true
end

local function resetCamera()
  core_camera.setByName(0, "orbit")
  core_camera.setFOV(0, previousFov or 60)
  cameraSet = false
end

local function notifyCompletion(workOptions)
  local completedConfig = review and review.configs and review.configs[#review.configs] or nil
  if type(workOptions.onDoneHook) == "string" and workOptions.onDoneHook ~= "" then
    guihooks.trigger(workOptions.onDoneHook, completedConfig or {})
  end
end

local function restorePhysicsState()
  if not savedPhysicsState then return true end
  local state = savedPhysicsState
  local ok, err = pcall(function()
    be:setPhysicsSpeedFactor(state.speedFactor)
    if be:getPhysicsSpeedFactor() ~= state.speedFactor then
      error("Physics speed factor did not restore exactly")
    end
    be:setPhysicsRunning(state.running)
    if be:getPhysicsRunning() ~= state.running then
      error("Physics running state did not restore exactly")
    end
  end)
  if not ok then
    log("E", "screenshotCreatorJob", "Unable to restore physics state: " .. tostring(err))
    return false
  end
  savedPhysicsState = nil
  return true
end

local function beginPhysicsOwnership()
  if savedPhysicsState and not restorePhysicsState() then return false end
  if not be or not be.getPhysicsRunning or not be.setPhysicsRunning
    or not be.getPhysicsSpeedFactor or not be.setPhysicsSpeedFactor
  then
    log("E", "screenshotCreatorJob", "Physics state APIs are unavailable")
    return false
  end
  savedPhysicsState = {
    running = be:getPhysicsRunning(),
    speedFactor = be:getPhysicsSpeedFactor()
  }
  return true
end

local function setPhysicsForSettling()
  be:setPhysicsSpeedFactor(1)
  be:setPhysicsRunning(true)
end

local function freezePhysics()
  be:setPhysicsRunning(false)
  return not be:getPhysicsRunning()
end

local function waitForVehicleToSettle(modelName, configName, captureSettings)
  setPhysicsForSettling()
  util_screenshotCreator_vehicleSetup.waitForVehicleToSettle(modelName, configName, captureSettings)
  if captureSettings.freezePhysics ~= false and not freezePhysics() then
    log("E", "screenshotCreatorJob", "Unable to keep physics frozen after vehicle settle")
    return false
  end
  return true
end

local function completeRun(workOptions)
  freezePhysics()
  runDone = true
  notifyCompletion(workOptions)
end

local function abortRun()
  freezePhysics()
  if util_screenshotCreator_lightingSetup then util_screenshotCreator_lightingSetup.restore() end
end

local function finishEnvironmentOverride()
  if util_screenshotCreator_lightingSetup then util_screenshotCreator_lightingSetup.restore() end
  if not environmentOverrideActive then return end
  environmentOverrideActive = false
  if util_screenshotCreator_settings then util_screenshotCreator_settings.finishWork() end
end

local function buildSelectedWorkItems(selection)
  local items = {}
  local onlyDefaults = selection == "selectedModelDefaults"
  for _, modelName in pairs(util_screenshotCreator_modelSelection.getSelectedModels()) do
    local modelData = core_vehicles.getModel(modelName)
    local configs = modelData and modelData.configs or {}
    if onlyDefaults then
      local defaultKey = modelData and modelData.model and modelData.model.default_pc
      local defaultConfig = defaultKey and configs[defaultKey]
      configs = defaultConfig and {defaultConfig} or {}
    end
    for _, configData in pairs(configs) do
      table.insert(items, {
        modelName = modelName,
        modelKey = configData.model_key or modelName,
        configName = configData.key,
        configData = configData,
        isDefaultConfig = configData.is_default_config == true
          or configData.key == (modelData.model and modelData.model.default_pc)
      })
    end
  end
  return items
end

local function buildExplicitWorkItems(targets)
  if type(targets) ~= "table" or #targets == 0 then return nil, "No capture targets were provided" end
  if #targets > 2000 then return nil, "Too many capture targets" end
  local items = {}
  local seen = {}
  for index, target in ipairs(targets) do
    local modelName = type(target) == "table" and target.model or nil
    local configName = type(target) == "table" and target.config or nil
    if type(modelName) ~= "string" or modelName == ""
      or type(configName) ~= "string" or configName == ""
    then
      return nil, "Invalid capture target at index " .. tostring(index)
    end
    local modelData = core_vehicles.getModel(modelName)
    local configData
    for _, candidate in pairs(modelData and modelData.configs or {}) do
      if candidate.key == configName then
        configData = candidate
        break
      end
    end
    if not configData then
      return nil, "Unknown vehicle config: " .. modelName .. "/" .. configName
    end
    local key = modelName .. "\0" .. configName
    if not seen[key] then
      seen[key] = true
      items[#items + 1] = {
        modelName = modelName,
        modelKey = configData.model_key or modelName,
        configName = configName,
        configData = configData,
        isDefaultConfig = configData.is_default_config == true
          or configName == (modelData.model and modelData.model.default_pc)
      }
    end
  end
  if #items == 0 then return nil, "No unique capture targets were provided" end
  return items
end

local function getCurrentWorkItem(workOptions, vehicle)
  local configName = workOptions.configName
  if type(configName) ~= "string" or configName == "" then
    configName = workOptions.selection
  end
  local modelName = getModelName(vehicle) or "vehicle"
  local modelData = core_vehicles.getModel(modelName)
  local defaultConfig = modelData and modelData.model and modelData.model.default_pc
  return {
    vehicle = vehicle,
    modelName = modelName,
    modelKey = modelName,
    configName = configName,
    isCurrent = true,
    isDefaultConfig = configName == defaultConfig
  }
end

local function makeOutputPath(item, workOptions, settingsSnapshot, sampleOutputFolder)
  local fileEnding = settingsSnapshot.fileEnding or ".jpg"
  if sampleOutputFolder then
    return string.format("%s%s_%s%s", sampleOutputFolder, item.modelKey, item.configName, fileEnding)
  end
  if item.isCurrent and type(workOptions.outputPath) == "string" and workOptions.outputPath ~= "" then
    return workOptions.outputPath
  end
  if item.isCurrent then
    local vehicleData = core_vehicle_manager.getVehicleData(item.vehicle:getId())
    local vehicleDirectory = vehicleData and vehicleData.vehicleDirectory or ("vehicles/" .. item.modelKey .. "/")
    return normalizeFolder(vehicleDirectory) .. item.configName .. fileEnding
  end
  return normalizeFolder(settingsSnapshot.outputFolder or "vehicles/") ..
    item.modelKey .. "/" .. item.configName .. fileEnding
end

local function copyComparisonThumbnail(item, settingsSnapshot, sampleOutputFolder)
  if not sampleOutputFolder then return end
  local fileEnding = settingsSnapshot.fileEnding or ".jpg"
  local existingPath
  if item.isCurrent then
    local vehicleData = core_vehicle_manager.getVehicleData(item.vehicle:getId())
    if vehicleData then
      existingPath = normalizeFolder(vehicleData.vehicleDirectory) .. item.configName .. fileEnding
    end
  else
    existingPath = "vehicles/" .. item.modelKey .. "/" .. item.configName .. fileEnding
  end
  if existingPath and FS:fileExists(existingPath) then
    FS:copyFile(existingPath, sampleOutputFolder .. item.modelKey .. "_" .. item.configName .. "_existing" .. fileEnding)
  end
end

local function getCamera(framingContext)
  if framingContext.cameraOverridePolicy == "useSaved" then
    local override, overrideError =
      util_screenshotCreator_framing_configured.resolveOverride(framingContext)
    if overrideError then
      log("E", "screenshotCreatorJob", "Configured camera lookup failed: " .. tostring(overrideError))
      return nil
    end
    if override then return override end
  end
  local camera, resolveError = util_screenshotCreator_framingManager.resolve(
    framingContext.framingModeId,
    framingContext
  )
  if type(camera) ~= "table" or not camera.pos or not camera.rot then
    log("E", "screenshotCreatorJob", "Framing did not return a valid camera: " .. tostring(resolveError))
    return nil
  end
  return camera
end

local function captureAndWait(captureContext, timeout)
  local done = false
  local success = false
  util_screenshotCreator_capture.takeThumbnailScreenshot(
    captureContext.filepath,
    captureContext.camera,
    function(captureSuccess)
      done = true
      success = captureSuccess == true
    end,
    captureContext.vehicle:getId(),
    {
      resolution = captureContext.resolution,
      supersampling = captureContext.superSampling,
      fov = captureContext.fieldOfView,
      nearPlane = captureContext.nearPlane
    }
  )

  local waitStart = os.clock()
  while not done and not forceQuit and os.clock() - waitStart < timeout do
    coroutine.yield()
  end
  if not done then
    log("W", "screenshotCreatorJob", "Timed out waiting for capture: " .. tostring(captureContext.filepath))
  end
  if not done or not success then
    log("E", "thumbnail", "Stopping thumbnail generation after failed capture: " .. tostring(captureContext.filepath))
    return false
  end

  local fileWaitStart = os.clock()
  while (not FS:fileExists(captureContext.filepath) or FS:fileSize(captureContext.filepath) <= 0)
    and os.clock() - fileWaitStart < 2
  do
    coroutine.yield()
  end
  local currentArtifact = FS:fileExists(captureContext.filepath)
    and FS:fileSize(captureContext.filepath) > 0
  if not currentArtifact then FS:removeFile(captureContext.filepath) end
  return currentArtifact
end

local function getDefaultOutputPath(modelKey, outputPath)
  if type(modelKey) ~= "string" or modelKey == "" then return nil end
  if type(outputPath) ~= "string" or outputPath == "" then return nil end
  local extension = outputPath:match("(%.[^./\\]+)$")
  if not extension then return nil end
  return "vehicles/" .. modelKey .. "/default" .. extension:lower()
end

local function publishDefaultThumbnail(modelKey, outputPath)
  local defaultPath = getDefaultOutputPath(modelKey, outputPath)
  if not defaultPath then
    log("E", "screenshotCreatorJob", "Unable to resolve default thumbnail path from: " .. tostring(outputPath))
    return false
  end
  if defaultPath ~= outputPath then
    local copyResult = FS:copyFile(outputPath, defaultPath)
    if copyResult ~= true and copyResult ~= 0 then
      log("E", "screenshotCreatorJob", "Unable to publish default thumbnail: " .. defaultPath)
      return false
    end
  end
  if not FS:fileExists(defaultPath) or FS:fileSize(defaultPath) <= 0 then
    log("E", "screenshotCreatorJob", "Published default thumbnail is missing or empty: " .. defaultPath)
    return false
  end
  log("I", "screenshotCreatorJob", "Published default thumbnail: " .. defaultPath)
  return true
end

local function finalizeCapture(captureContext, captureSuccess, outputPath)
  if not captureSuccess then return false end
  if type(outputPath) ~= "string" or outputPath == ""
    or not FS:fileExists(outputPath) or FS:fileSize(outputPath) <= 0
  then
    log("E", "screenshotCreatorJob", "Successful capture did not produce a current-run artifact: " .. tostring(outputPath))
    return false
  end
  if captureContext.isDefaultConfig and not publishDefaultThumbnail(captureContext.modelKey, outputPath) then
    return false
  end
  ui_vehicleSelector_general.clearCache()
  return true
end

local function processWorkItem(item, workOptions, settingsSnapshot, runContext)
  util_screenshotCreator_lightingSetup.restore()
  local filepath = makeOutputPath(item, workOptions, settingsSnapshot, runContext.sampleOutputFolder)
  progress.current = item.modelKey .. "/" .. tostring(item.configName)

  local skipMissing = workOptions.onlyMissingThumbnails == true
    and not runContext.sampleOutputFolder
    and (settingsSnapshot.outputFolder or "vehicles/") == "vehicles/"
    and FS:fileExists(filepath)
  local skipUnshipped = not item.isCurrent
    and workOptions.shippedConfigsOnly
    and not util_screenshotCreator_shippedConfigs.isConfigShipped(item.modelKey, item.configName)
  if skipMissing or skipUnshipped then
    return {
      vehName = progress.current,
      status = "skipped",
      thumbnailPath = filepath
    }
  end

  if workOptions.comparison then
    copyComparisonThumbnail(item, settingsSnapshot, runContext.sampleOutputFolder)
  end

  local vehicle = item.vehicle
  if not item.isCurrent then
    setPhysicsForSettling()
    vehicle = core_vehicles.replaceVehicle(item.modelKey, {config = item.configName, licenseText = "BeamNG"})
    local pauseDelay = util_screenshotCreator_thumbnailConfig.getPauseDelay(item.modelName, item.configName)
    if pauseDelay <= 0 then
      yieldSeconds(0.7)
      vehicle = getPlayerVehicle(0)
    end
  end

  if not vehicle then
    log("E", "screenshotCreatorJob", "Vehicle replacement did not return a vehicle")
    return {
      vehName = progress.current,
      status = "failed",
      thumbnailPath = filepath
    }
  end

  log("D", "startWork", "Placing vehicle at thumbnail reference transform")
  util_screenshotCreator_vehicleSetup.placeVehicleForThumbnail(
    vehicle,
    item.configName,
    not item.isCurrent and runContext.initialPosition or nil,
    not item.isCurrent and runContext.initialRotation or nil
  )
  if not item.isCurrent then
    vehicle:queueLuaCommand("input.event('parkingbrake', 1, 1)")
    vehicle:queueLuaCommand("input.event('throttle', 0, 2)")
    vehicle:queueLuaCommand("controller.mainController.setEngineIgnition(false)")
  end
  util_screenshotCreator_vehicleSetup.setLowBeams(vehicle, workOptions.lowBeamsEnabled)
  if not waitForVehicleToSettle(
    item.modelName,
    item.configName,
    settingsSnapshot.capture
  ) then
    return {
      vehName = progress.current,
      status = "failed",
      thumbnailPath = filepath
    }
  end
  if forceQuit then return nil end
  if settingsSnapshot.capture.freezePhysics ~= false then
    if not freezePhysics() then
      log("E", "screenshotCreatorJob", "Unable to keep physics frozen before capture")
      return {
        vehName = progress.current,
        status = "failed",
        thumbnailPath = filepath
      }
    end
  end
  local pauseDelay = util_screenshotCreator_thumbnailConfig.getPauseDelay(item.modelName, item.configName)
  if workOptions.lowBeamsEnabled and pauseDelay <= 0 then
    yieldSeconds(0.2)
  end

  util_screenshotCreator_settings.applyReflections()
  if not util_screenshotCreator_settings.applyExposure() then
    log("E", "screenshotCreatorJob", "Unable to apply the configured exposure before capture")
    return {
      vehName = progress.current,
      status = "failed",
      thumbnailPath = filepath
    }
  end

  local captureResolution = settingsSnapshot.capture.resolution
  local framingContext = util_screenshotCreator_settings.getFramingContext(captureResolution)
  framingContext.vehicle = vehicle
  framingContext.modelName = item.modelName
  framingContext.configName = item.configName
  framingContext.framingModeId = runContext.framingModeId
  framingContext.cameraOverridePolicy = workOptions.cameraOverridePolicy
  framingContext.preview = false
  local camera = getCamera(framingContext)
  local captureSuccess = false
  if camera then
    local lightingAdjusted = util_screenshotCreator_lightingSetup.adjust(vehicle, camera)
    if not lightingAdjusted then
      log("E", "screenshotCreatorJob", "Unable to prepare screenshot lighting")
      return {
        vehName = progress.current,
        status = "failed",
        thumbnailPath = filepath
      }
    end
    yieldSeconds(captureWarmupSeconds)
    if forceQuit then
      util_screenshotCreator_lightingSetup.restore()
      return nil
    end
    local captureContext = deepcopy(settingsSnapshot.capture)
    captureContext.resolution = captureResolution
    captureContext.vehicle = vehicle
    captureContext.modelName = item.modelName
    captureContext.modelKey = item.modelKey
    captureContext.configName = item.configName
    captureContext.filepath = filepath
    captureContext.camera = camera
    captureContext.isDefaultConfig = not workOptions.sample and item.isDefaultConfig
    captureContext.framingModeId = runContext.framingModeId
    captureContext.fieldOfView = settingsSnapshot.framing.fieldOfView
    captureContext.nearPlane = settingsSnapshot.framing.nearPlane
    captureSuccess = captureAndWait(captureContext, settingsSnapshot.captureTimeout or 5)
    captureSuccess = finalizeCapture(captureContext, captureSuccess, filepath)
    local lightingRestored = util_screenshotCreator_lightingSetup.restore()
    if not lightingRestored then
      log("E", "screenshotCreatorJob", "Unable to restore screenshot lighting")
      captureSuccess = false
    end
    if forceQuit then return nil end
  end

  return {
    vehName = item.isCurrent and runContext.currentVehicleDirectory or progress.current,
    camName = camera and camera.name or nil,
    status = captureSuccess and "done" or "failed",
    thumbnailPath = filepath
  }
end

local function runWork(workOptions, settingsSnapshot)
  log("I", "screenshotCreatorJob", "Starting thumbnail work coroutine")
  local workVehicle = workOptions.vehicleId and getObjectByID(workOptions.vehicleId) or getPlayerVehicle(0)
  if not workVehicle then
    log("E", "screenshotCreatorJob", "No vehicle available for thumbnail work")
    util_screenshotCreator_settings.finishWork()
    forceQuit = true
    runDone = true
    return
  end

  local isModelSelection = workOptions.selection == "selectedModels"
    or workOptions.selection == "selectedModelDefaults"
  local items = workOptions.explicitItems
    or (isModelSelection and buildSelectedWorkItems(workOptions.selection))
    or {getCurrentWorkItem(workOptions, workVehicle)}

  progress.total = #items
  local vehicleData = core_vehicle_manager.getVehicleData(workVehicle:getId())
  local runContext = {
    framingModeId = review.framingModeId,
    sampleOutputFolder = review.sampleOutputFolder,
    initialPosition = vec3(workVehicle:getPosition()),
    initialRotation = quat(workVehicle:getRotation()),
    currentVehicleDirectory = vehicleData and vehicleData.vehicleDirectory or nil
  }

  for index, item in ipairs(items) do
    if forceQuit then
      abortRun()
      return
    end

    local result = processWorkItem(item, workOptions, settingsSnapshot, runContext)
    if not result then
      abortRun()
      return
    end
    table.insert(review.configs, result)
    progress.completed = progress.completed + 1

    if result.status == "failed" then
      forceQuit = true
      if index < #items then
        abortRun()
        return
      end
    end
  end

  completeRun(workOptions)
end

local function sanitizeWorkOptions(workOptions)
  if type(workOptions) ~= "table" then
    workOptions = {
      selection = "selectedModels",
      onlyMissingThumbnails = false
    }
  end
  workOptions.selection = workOptions.selection or "selectedModels"
  workOptions.lowBeamsEnabled = workOptions.lowBeamsEnabled == true
  workOptions.sample = workOptions.sample == true
  workOptions.comparison = workOptions.comparison == true
  workOptions.cameraOverridePolicy = workOptions.cameraOverridePolicy == "useSaved"
    and "useSaved"
    or "ignore"
  if workOptions.shippedConfigsOnly == nil then
    workOptions.shippedConfigsOnly = workOptions.shippedOnly ~= false
  else
    workOptions.shippedConfigsOnly = workOptions.shippedConfigsOnly == true
  end
  return workOptions
end

local function startWork(workOptions)
  if workerCoroutine then
    log("E", "screenshotCreatorJob", "Worker coroutine already exists")
    return false
  end

  workOptions = sanitizeWorkOptions(workOptions)
  if workOptions.targets ~= nil then
    local items, targetError = buildExplicitWorkItems(workOptions.targets)
    if not items then
      log("E", "screenshotCreatorJob", targetError)
      return false
    end
    workOptions.explicitItems = items
  end
  local settingsSnapshot = getSettingsSnapshot()
  if not beginPhysicsOwnership() then return false end
  local sampleOutputFolder
  if workOptions.sample then
    sampleOutputFolder = "screenshots/thumbnailSamples/" .. os.date("%Y-%m-%d_%H-%M-%S") .. "/"
    FS:directoryCreate(sampleOutputFolder, true)
  end

  forceQuit = false
  runDone = false
  progress = {completed = 0, total = 0, current = ""}
  review = {
    onlyMissingThumbnails = workOptions.onlyMissingThumbnails,
    shippedConfigsOnly = workOptions.shippedConfigsOnly,
    lowBeamsEnabled = workOptions.lowBeamsEnabled,
    selection = workOptions.selection,
    framingModeId = resolveFramingMode(workOptions.framingModeId),
    cameraOverridePolicy = workOptions.cameraOverridePolicy,
    sampleOutputFolder = sampleOutputFolder,
    configs = {}
  }
  util_screenshotCreator_settings.beginWork()
  environmentOverrideActive = true
  workerCoroutine = coroutine.create(function()
    runWork(workOptions, settingsSnapshot)
  end)
  return true
end

local function normalizePreviewOptions(modeOrOptions, fixedRotation)
  local options
  if type(modeOrOptions) == "table" then
    options = modeOrOptions
  else
    options = {
      framingModeId = modeOrOptions,
      fixedRotation = fixedRotation
    }
  end
  options.framingModeId = resolveFramingMode(options.framingModeId)
  return options
end

local function startPreviewInternal(vehicle, configName, options)
  if workerCoroutine or not vehicle then return false end

  local modelName = getModelName(vehicle)
  local settingsSnapshot = getSettingsSnapshot()
  forceQuit = false
  progress = {
    completed = 0,
    total = 1,
    current = tostring(modelName) .. "/" .. tostring(configName)
  }
  if not beginPhysicsOwnership() then return false end
  freezePhysics()
  workerCoroutine = coroutine.create(function()
    local resetPosition
    local resetRotation
    if options.delayedPreview then
      resetPosition, resetRotation = util_screenshotCreator_vehicleSetup.getResetTransform(vehicle)
    end
    util_screenshotCreator_vehicleSetup.placeVehicleForThumbnail(
      vehicle,
      configName,
      resetPosition,
      resetRotation
    )
    if options.delayedPreview then
      setPhysicsForSettling()
      yieldSeconds(util_screenshotCreator_thumbnailConfig.getPauseDelay(modelName, configName))
      if settingsSnapshot.capture.freezePhysics ~= false then freezePhysics() end
    else
      waitForVehicleToSettle(
        modelName,
        configName,
        settingsSnapshot.capture
      )
    end
    if forceQuit then return end

    local framingContext = deepcopy(settingsSnapshot.framing)
    framingContext.vehicle = vehicle
    framingContext.modelName = modelName
    framingContext.configName = configName
    framingContext.framingModeId = options.framingModeId
    framingContext.fixedRotation = options.fixedRotation
    framingContext.preview = true
    local camera = getCamera(framingContext)
    if camera and setCamera(camera, settingsSnapshot) then
      progress.completed = 1
    end
  end)
  return true
end

local function startPreview(vehicle, configName, modeOrOptions, fixedRotation)
  return startPreviewInternal(vehicle, configName, normalizePreviewOptions(modeOrOptions, fixedRotation))
end

local function startPreviewWithDelay(vehicle, configName, modeOrOptions, fixedRotation)
  local modelName = getModelName(vehicle)
  if not modelName or util_screenshotCreator_thumbnailConfig.getPauseDelay(modelName, configName) <= 0 then
    return false
  end
  local options = normalizePreviewOptions(modeOrOptions, fixedRotation)
  options.delayedPreview = true
  return startPreviewInternal(vehicle, configName, options)
end

local function stop()
  if not workerCoroutine then return false end
  forceQuit = true
  return true
end

local function onPreRender()
  if not workerCoroutine then return end

  local errorFree, value = coroutine.resume(workerCoroutine)
  if not errorFree then
    log("E", "screenshotCreatorJob", "workerCoroutine: " .. tostring(value))
    log("E", "screenshotCreatorJob", debug.traceback(workerCoroutine))
    abortRun()
  end
  if coroutine.status(workerCoroutine) == "dead" then
    workerCoroutine = nil
    finishEnvironmentOverride()
    restorePhysicsState()
    if isBatch() then
      shutdown(0)
    end
  end
end

local function consumeRunDone()
  local value = runDone
  runDone = false
  return value
end

local function clearRunDone()
  runDone = false
end

local function onSerialize()
  return {
    progress = progress,
    review = review,
    runDone = runDone,
    previousFov = previousFov,
    cameraSet = cameraSet
  }
end

local function onDeserialized(data)
  if type(data) ~= "table" then return end
  progress = data.progress or {completed = 0, total = 0, current = ""}
  review = data.review
  runDone = data.runDone == true
  previousFov = data.previousFov
  cameraSet = data.cameraSet == true
end

local function onExtensionUnloaded()
  forceQuit = true
  if workerCoroutine then abortRun() end
  workerCoroutine = nil
  finishEnvironmentOverride()
  restorePhysicsState()
end

M.startWork = startWork
M.startPreview = startPreview
M.startPreviewWithDelay = startPreviewWithDelay
M.stop = stop
M.isRunning = function() return workerCoroutine ~= nil end
M.getProgress = function() return progress end
M.getReviewData = function() return review end
M.consumeRunDone = consumeRunDone
M.clearRunDone = clearRunDone
M.resetCamera = resetCamera
M.isCameraSet = function() return cameraSet end
M.onPreRender = onPreRender
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onExtensionUnloaded
M.onExit = onExtensionUnloaded

return M
