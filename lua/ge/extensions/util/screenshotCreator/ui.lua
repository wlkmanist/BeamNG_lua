-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "ui_imgui",
  "editor_main",
  "core_camera",
  "core_vehicles",
  "core_gamestate",
  "freeroam_freeroam",
  "util_screenshotCreator_settings",
  "util_screenshotCreator_job",
  "util_screenshotCreator_lightingSetup",
  "util_screenshotCreator_thumbnailConfig",
  "util_screenshotCreator_framingManager",
  "util_screenshotCreator_modelSelection",
  "util_screenshotCreator_nodeOutpaint",
  "util_screenshotCreator_shippedConfigs"
}

local im = ui_imgui
local vehicleActionMaps = {"VehicleCommonActionMap", "VehicleSpecificActionMap"}
local initialWindowSize = im.ImVec2(0, 0)
local progressBarSize = im.ImVec2(0, 0)
local pitchColor = im.ImVec4(1, 0.35, 0.35, 1)
local rollColor = im.ImVec4(0.35, 1, 0.35, 1)
local yawColor = im.ImVec4(0.35, 0.65, 1, 1)
local heightColor = im.ImVec4(1, 0.7, 0.25, 1)
local distanceColor = im.ImVec4(0.35, 0.9, 0.9, 1)
local fovColor = im.ImVec4(0.8, 0.5, 1, 1)
local unshippedStrikeColor = im.GetColorU322(im.ImVec4(1, 0.35, 0.35, 0.9))
local strikeStart = im.ImVec2(0, 0)
local strikeEnd = im.ImVec2(0, 0)

local windowOpen = im.BoolPtr(false)
local windowWasOpen = false
local generateMissingThumbnailsOnly = im.BoolPtr(false)
local reloadUiOnJobFinished = im.BoolPtr(false)
local cameraSpeed = im.FloatPtr(core_camera.getSpeed())
local framingModeIndex = im.IntPtr(0)

local drivingEnabled = true
local uiAppsVisible = true
local runDone = false
local legacyReviewData
local manualCameraSet = false
local previousManualFov
local markupCount = 0
local markupCountValid = false

local function normalizeConfigName(configName)
  local normalized = tostring(configName or ""):gsub("\\", "/")
  normalized = normalized:match("([^/]+)$") or normalized
  normalized = normalized:gsub("%.pc$", ""):gsub("%.jpg$", "")
  return normalized ~= "" and normalized or nil
end

local function drawConfigName(text, shipped)
  local textPosition = im.GetCursorScreenPos()
  im.TextUnformatted(text)
  if shipped then return end

  local textSize = im.CalcTextSize(text)
  local strikeY = textPosition.y + textSize.y * 0.55
  strikeStart.x = textPosition.x
  strikeStart.y = strikeY
  strikeEnd.x = textPosition.x + textSize.x
  strikeEnd.y = strikeY
  im.ImDrawList_AddLine(
    im.GetWindowDrawList(),
    strikeStart,
    strikeEnd,
    unshippedStrikeColor,
    im.uiscale[0]
  )
end

local function getCurrentVehicleInfo()
  local vehicle = getPlayerVehicle(0)
  if not vehicle then return nil, nil, nil, "No player vehicle is available." end

  local partConfig = vehicle.partConfig
  local configName = normalizeConfigName(partConfig)
  if type(partConfig) ~= "string" or not partConfig:match("%.pc$") or not configName then
    return vehicle, nil, nil,
      "Player vehicle does not originate from a part config file (.pc). Please choose another vehicle."
  end
  return vehicle, vehicle.jbeam or vehicle.JBeam, configName
end

local function getSelectedModeId()
  return util_screenshotCreator_framingManager.getSelectedModeId()
end

local function getSelectedMode()
  local selectedModeId = getSelectedModeId()
  for _, mode in ipairs(util_screenshotCreator_framingManager.listModes()) do
    if mode.id == selectedModeId then return mode end
  end
end

local function drawFramingModeCombo()
  local modes = util_screenshotCreator_framingManager.listModes()
  if #modes == 0 then
    im.TextDisabled("No framing modes are registered.")
    return
  end

  local selectedModeId = getSelectedModeId()
  local items = ""
  local selectedIndex = 0
  for index, mode in ipairs(modes) do
    items = items .. (mode.label or mode.id) .. "\0"
    if mode.id == selectedModeId then selectedIndex = index - 1 end
  end
  framingModeIndex[0] = selectedIndex

  if im.Combo2("Framing mode", framingModeIndex, items .. "\0") then
    local mode = modes[framingModeIndex[0] + 1]
    if mode then
      local success, setError =
        util_screenshotCreator_framingManager.setSelectedModeId(mode.id)
      if not success then
        log("E", "screenshotCreatorUi", tostring(setError))
      end
    end
  end
  im.tooltip("The selected mode is used for previews and generated thumbnails.")
  local selectedMode = modes[framingModeIndex[0] + 1]
  if selectedMode and selectedMode.fixedFov then
    im.TextDisabled(string.format("This mode uses a fixed %.1f deg FOV.", selectedMode.fixedFov))
  end
  if selectedMode and selectedMode.fixedDistance then
    im.TextDisabled(string.format("This mode keeps a fixed %.1f m camera distance.", selectedMode.fixedDistance))
  end
end

local function setDriving(value)
  drivingEnabled = value == true
  for _, mapName in ipairs(vehicleActionMaps) do
    local actionMap = scenetree.findObject(mapName)
    if actionMap then actionMap:setEnabled(drivingEnabled) end
  end
end

local function toggleUiApps()
  uiAppsVisible = not uiAppsVisible
  if uiAppsVisible then
    core_gamestate.setGameState("freeroam", "freeroam", "freeroam")
  else
    core_gamestate.setGameState("freeroam", {}, "freeroam")
  end
end

local function restoreSessionState()
  if not drivingEnabled then setDriving(true) end
  if not uiAppsVisible then toggleUiApps() end
  if not util_screenshotCreator_settings then return end
  util_screenshotCreator_settings.setPreviewResolution(false)
  if not util_screenshotCreator_job or not util_screenshotCreator_job.isRunning() then
    util_screenshotCreator_settings.restoreEnvironment()
  end
end

local function setManualCamera(position, rotation)
  if not position or not rotation then return end
  previousManualFov = core_camera.getFovDeg()
  core_camera.setByName(0, "free")
  core_camera.setPosRot(
    0,
    position.x,
    position.y,
    position.z,
    rotation.x,
    rotation.y,
    rotation.z,
    rotation.w
  )
  core_camera.setFOV(0, util_screenshotCreator_settings.getFramingContext().fieldOfView)
  manualCameraSet = true
end

local function resetCamera()
  util_screenshotCreator_job.resetCamera()
  if manualCameraSet and previousManualFov then
    core_camera.setFOV(0, previousManualFov)
  end
  manualCameraSet = false
end

local function setCameraFromConfig(cameraConfig, vehicle, configName)
  if not cameraConfig or not cameraConfig.posOffset or not cameraConfig.rotOffset then return end
  local position, rotation = util_screenshotCreator_thumbnailConfig.rewindCameraOffsets(
    cameraConfig.posOffset,
    cameraConfig.rotOffset,
    vehicle,
    configName
  )
  setManualCamera(position, rotation)
end

local function getWorkOptions(selection)
  local controls = util_screenshotCreator_settings.getControls()
  local options = {
    selection = selection,
    onlyMissingThumbnails = generateMissingThumbnailsOnly[0],
    shippedConfigsOnly = controls.shippedConfigsOnly[0],
    lowBeamsEnabled = controls.lowBeamsEnabled[0],
    sample = controls.sample[0],
    comparison = controls.comparison[0],
    framingModeId = getSelectedModeId()
  }
  return options
end

local function drawWorkProgress()
  local progress = util_screenshotCreator_job.getProgress() or {}
  local total = tonumber(progress.total) or 0
  local completed = tonumber(progress.completed) or 0
  local fraction = total > 0 and completed / total or 0
  progressBarSize.x = 180 * im.uiscale[0]
  im.ProgressBar(
    fraction,
    progressBarSize,
    string.format("%d / %d", completed, total)
  )
  im.SameLine()
  im.TextUnformatted(progress.current ~= "" and progress.current or "Preparing...")
end

local function drawCameraInfo(vehicle)
  local angles = core_camera.getYawPitchRoll()
  im.TextUnformatted("Camera rotation:")
  im.SameLine()
  im.TextColored(pitchColor, string.format("Pitch %.2f deg", angles.pitchDown or 0))
  im.SameLine()
  im.TextColored(rollColor, string.format("Roll %.2f deg", angles.rollDeg or 0))
  im.SameLine()
  im.TextColored(yawColor, string.format("Yaw %.2f deg", angles.yawDeg or 0))

  local cameraPosition = core_camera.getPosition()
  local vehicleCenter = vehicle:getSpawnWorldOOBB():getCenter()
  local deltaX = cameraPosition.x - vehicleCenter.x
  local deltaY = cameraPosition.y - vehicleCenter.y
  local horizontalDistance = math.sqrt(deltaX * deltaX + deltaY * deltaY)
  im.TextUnformatted("Camera framing:")
  im.SameLine()
  im.TextColored(heightColor, string.format("Height %.2f m", cameraPosition.z))
  im.SameLine()
  im.TextColored(distanceColor, string.format("Distance %.2f m", horizontalDistance))
  im.SameLine()
  im.TextColored(fovColor, string.format("FOV %.2f deg", core_camera.getFovDeg()))
end

local function getSelectedSceneObjectIds()
  if not editor or not editor.selection or not editor.selection.object or not scenetree then return {} end

  local selectedIds = {}
  for _, objectId in ipairs(editor.selection.object) do
    local object = scenetree.findObjectById(objectId)
    if object and object:isSubClassOf("SceneObject") then
      selectedIds[#selectedIds + 1] = objectId
    end
  end
  return selectedIds
end

local function drawMarkupControls()
  if not markupCountValid then
    markupCount = util_screenshotCreator_lightingSetup.getMarkupCount()
    markupCountValid = true
  end
  local selectedIds = getSelectedSceneObjectIds()
  im.TextUnformatted(string.format("Parking markup: %d tagged SceneObject(s).", markupCount))
  im.SameLine()
  if im.SmallButton("Refresh parking markup") then
    markupCount = util_screenshotCreator_lightingSetup.getMarkupCount()
  end

  local editorAvailable = editor
    and editor.initialized
    and editor.setDynamicFieldValue
    and editor.selection
    and scenetree
  if not editorAvailable then
    im.TextDisabled("Open the World Editor to tag parking markup.")
  else
    if #selectedIds == 0 then im.BeginDisabled() end
    if im.Button("Tag selected SceneObjects as parking markup") then
      for _, objectId in ipairs(selectedIds) do
        editor.setDynamicFieldValue(objectId, "thumbnailLayer", "parkingMarkup")
      end
      markupCount = util_screenshotCreator_lightingSetup.getMarkupCount()
    end
    if #selectedIds == 0 then im.EndDisabled() end
    im.SameLine()
    if markupCount == 0 then im.BeginDisabled() end
    if im.Button("Clear parking markup tags") then
      util_screenshotCreator_lightingSetup.clearMarkupTags()
      if editor.setDirty then editor.setDirty() end
      markupCount = util_screenshotCreator_lightingSetup.getMarkupCount()
    end
    if markupCount == 0 then im.EndDisabled() end
  end

  if markupCount == 0 then
    im.TextDisabled("Tag parking markup here so the Parking markup toggle can hide it.")
  end
end

local function drawWorkControls(vehicle, configName, isRunning)
  if isRunning then
    if im.Button("Stop") then util_screenshotCreator_job.stop() end
    im.SameLine()
    drawWorkProgress()
    return
  end

  if im.Button("Open Showroom V2 Lighting Simple") then
    if not freeroam_freeroam.startFreeroamByName("showroom_v2_lighting_simple") then
      log("E", "screenshotCreator", "Unable to open showroom_v2_lighting_simple")
    end
  end
  im.tooltip("Loads the scripting-agnostic thumbnail showroom level.")

  drawMarkupControls()
  if im.Button("Run selected models") then
    util_screenshotCreator_job.startWork(getWorkOptions("selectedModels"))
  end
  im.tooltip(string.format(
    "Run %d selected model(s). The player vehicle model is used if none are selected.",
    util_screenshotCreator_modelSelection.getSelectedCount()
  ))
  im.SameLine()
  if im.Button("Run selected defaults") then
    util_screenshotCreator_job.startWork(getWorkOptions("selectedModelDefaults"))
  end

  if configName then
    im.SameLine()
    if im.Button("Run current config") then
      local options = getWorkOptions(configName)
      options.vehicleId = vehicle and vehicle:getId() or nil
      options.configName = configName
      options.onlyMissingThumbnails = false
      util_screenshotCreator_job.startWork(options)
    end
  end

  im.Checkbox("Generate missing thumbnails only", generateMissingThumbnailsOnly)
  im.tooltip("Only skips an existing file; a blank thumbnail is not considered missing.")
  im.SameLine()
  im.Checkbox("Reload UI when run is finished", reloadUiOnJobFinished)
end

local function previewVehicle(vehicle, configName, fixedRotation, delayed)
  if not vehicle or not configName then return end
  local options = {
    framingModeId = getSelectedModeId(),
    fixedRotation = fixedRotation
  }
  if delayed then
    util_screenshotCreator_job.startPreviewWithDelay(vehicle, configName, options)
  else
    util_screenshotCreator_job.startPreview(vehicle, configName, options)
  end
end

local function drawPreviewControls(vehicle, modelName, configName)
  local rotation = util_screenshotCreator_thumbnailConfig.getRotation(modelName, configName)
  local pauseDelay = util_screenshotCreator_thumbnailConfig.getPauseDelay(modelName, configName)
  im.TextUnformatted(string.format(
    "Thumbnail rotation: %.1f deg   Pause delay: %.2f s",
    rotation,
    pauseDelay
  ))

  if im.Button("Preview selected mode") then
    previewVehicle(vehicle, configName)
  end
  im.SameLine()
  if pauseDelay <= 0 then im.BeginDisabled() end
  if im.Button("Preview with delay") then
    previewVehicle(vehicle, configName, nil, true)
  end
  if pauseDelay <= 0 then im.EndDisabled() end
  im.tooltip(string.format(
    "Reset, run for %.2f seconds, pause, then frame the vehicle.",
    pauseDelay
  ))
  im.SameLine()
  local selectedMode = getSelectedMode()
  local supportsFixedRotation = not selectedMode or selectedMode.supportsFixedRotation ~= false
  if not supportsFixedRotation then im.BeginDisabled() end
  if im.Button("Preview keeping angle") then
    previewVehicle(vehicle, configName, core_camera.getQuat())
  end
  if not supportsFixedRotation then im.EndDisabled() end
  if not supportsFixedRotation then
    im.tooltip("This framing mode uses its own fixed camera angle.")
  end
  im.SameLine()
  if im.Button("Game camera") then resetCamera() end
end

local function drawConfigCameraControls(vehicle, modelName, configName, cameraConfigs)
  im.SeparatorText("Current config camera")
  local vehicleConfig = cameraConfigs.vehCamConfig
  local cameraConfig = vehicleConfig and vehicleConfig.cameraConfig

  if cameraConfig then
    if im.Button("Set camera to config camera") then
      setCameraFromConfig(cameraConfig, vehicle, configName)
    end
    local enabled = im.BoolPtr(vehicleConfig.configCamEnabled == true)
    if im.Checkbox("Enable config camera", enabled) then
      vehicleConfig.configCamEnabled = enabled[0]
      util_screenshotCreator_thumbnailConfig.saveVehicleConfig(modelName, configName, vehicleConfig)
    end
  else
    im.TextDisabled("Current config has no saved camera.")
  end

  if im.Button(cameraConfig and "Overwrite config camera" or "Save config camera") then
    local positionOffset, rotationOffset =
      util_screenshotCreator_thumbnailConfig.getCameraOffsets(configName, vehicle)
    cameraConfigs.vehCamConfig = {
      cameraConfig = {posOffset = positionOffset, rotOffset = rotationOffset},
      modelCamEnabled = false,
      configCamEnabled = true,
      rotation = vehicleConfig and vehicleConfig.rotation,
      pauseDelay = vehicleConfig and vehicleConfig.pauseDelay
    }
    util_screenshotCreator_thumbnailConfig.saveVehicleConfig(
      modelName,
      configName,
      cameraConfigs.vehCamConfig
    )
  end
end

local function drawModelCameraControls(vehicle, modelName, configName, cameraConfigs)
  im.SeparatorText("Model camera")
  local vehicleConfig = cameraConfigs.vehCamConfig
  local modelConfig = cameraConfigs.modelCamConfig
  local cameraConfig = modelConfig and modelConfig.cameraConfig

  if vehicleConfig.configCamEnabled then
    im.TextWrapped("The enabled config camera overrides the model camera.")
    return
  end

  if cameraConfig then
    if im.Button("Set camera to model camera") then
      setCameraFromConfig(cameraConfig, vehicle, configName)
    end
    local enabled = im.BoolPtr(vehicleConfig.modelCamEnabled == true)
    if im.Checkbox("Enable model camera for this config", enabled) then
      vehicleConfig.modelCamEnabled = enabled[0]
      util_screenshotCreator_thumbnailConfig.saveVehicleConfig(modelName, configName, vehicleConfig)
    end
  else
    im.TextDisabled("Current model has no saved camera.")
  end

  if im.Button(cameraConfig and "Overwrite model camera" or "Save model camera") then
    local positionOffset, rotationOffset =
      util_screenshotCreator_thumbnailConfig.getCameraOffsets(configName, vehicle)
    cameraConfigs.modelCamConfig = {
      cameraConfig = {posOffset = positionOffset, rotOffset = rotationOffset},
      rotation = modelConfig and modelConfig.rotation,
      pauseDelay = modelConfig and modelConfig.pauseDelay
    }
    vehicleConfig.modelCamEnabled = true
    vehicleConfig.configCamEnabled = false
    util_screenshotCreator_thumbnailConfig.saveModelConfig(
      modelName,
      cameraConfigs.modelCamConfig
    )
    util_screenshotCreator_thumbnailConfig.saveVehicleConfig(
      modelName,
      configName,
      vehicleConfig
    )
  end
end

local function drawModelConfigList(modelName, currentConfigName)
  local modelData = core_vehicles.getModel(modelName)
  local configs = modelData and modelData.configs or {}
  if not im.BeginTable("Model configs", 4, im.TableFlags_SizingStretchProp) then return end

  im.TableSetupColumn("Config")
  im.TableSetupColumn("Config camera")
  im.TableSetupColumn("Model camera")
  im.TableSetupColumn("Spawn")
  im.TableHeadersRow()

  for _, configData in pairs(configs) do
    local configName = configData.key
    local cameraConfigs =
      util_screenshotCreator_thumbnailConfig.getCameraConfig(configData.model_key, configName)
    local vehicleConfig = cameraConfigs.vehCamConfig

    im.TableNextRow()
    im.TableNextColumn()
    drawConfigName(
      configName .. (configName == currentConfigName and " (Current)" or ""),
      util_screenshotCreator_shippedConfigs.isConfigShipped(configData.model_key, configName)
    )

    im.TableNextColumn()
    if vehicleConfig.cameraConfig then
      local enabled = im.BoolPtr(vehicleConfig.configCamEnabled == true)
      if im.Checkbox("##configCamera" .. configName, enabled) then
        vehicleConfig.configCamEnabled = enabled[0]
        util_screenshotCreator_thumbnailConfig.saveVehicleConfig(
          configData.model_key,
          configName,
          vehicleConfig
        )
      end
    else
      im.TextDisabled("None")
    end

    im.TableNextColumn()
    if cameraConfigs.modelCamConfig and cameraConfigs.modelCamConfig.cameraConfig then
      local enabled = im.BoolPtr(vehicleConfig.modelCamEnabled == true)
      if im.Checkbox("##modelCamera" .. configName, enabled) then
        vehicleConfig.modelCamEnabled = enabled[0]
        util_screenshotCreator_thumbnailConfig.saveVehicleConfig(
          configData.model_key,
          configName,
          vehicleConfig
        )
      end
    else
      im.TextDisabled("None")
    end

    im.TableNextColumn()
    if configName ~= currentConfigName
      and im.SmallButton("Spawn##" .. configName)
    then
      core_vehicles.replaceVehicle(configData.model_key, {
        config = configName,
        licenseText = "BeamNG"
      })
    end
  end
  im.EndTable()
end

local function drawManualControls(vehicle, modelName, configName)
  im.TextWrapped(
    "Save and enable camera placement per model or config. An enabled config camera overrides its model camera."
  )
  im.Checkbox(
    "Use framing margins",
    util_screenshotCreator_settings.getControls().useFramingMargins
  )
  drawPreviewControls(vehicle, modelName, configName)

  if util_screenshotCreator_job.isCameraSet() or manualCameraSet then
    if im.SliderFloat("Camera speed", cameraSpeed, 2, 100, "%.1f") then
      core_camera.setSpeed(cameraSpeed[0])
    end
  end
  if im.Button(drivingEnabled and "Disable driving" or "Enable driving") then
    setDriving(not drivingEnabled)
  end
  im.tooltip("Enable or disable the vehicle action maps.")

  if configName == "default" then
    im.TextWrapped(
      "The current vehicle uses the generated default config. Spawn a named config before saving camera data."
    )
    return
  end

  im.Separator()
  drawModelConfigList(modelName, configName)
  local cameraConfigs =
    util_screenshotCreator_thumbnailConfig.getCameraConfig(modelName, configName)
  drawConfigCameraControls(vehicle, modelName, configName, cameraConfigs)
  drawModelCameraControls(vehicle, modelName, configName, cameraConfigs)
end

local function drawReview()
  if im.Button("Open user's vehicle folder") then
    if not FS:directoryExists("/vehicles/") then FS:directoryCreate("/vehicles/", true) end
    Engine.Platform.exploreFolder("/vehicles/")
  end
  im.SameLine()
  if im.Button("Open screenshot/showroom folder") then
    if not FS:directoryExists("/screenshots/showroom/") then
      FS:directoryCreate("/screenshots/showroom/", true)
    end
    Engine.Platform.exploreFolder("/screenshots/showroom/")
  end

  local review = util_screenshotCreator_job.getReviewData() or legacyReviewData
  if review and review.sampleOutputFolder then
    im.SameLine()
    if im.Button("Open sample folder") then
      Engine.Platform.exploreFolder("/" .. review.sampleOutputFolder)
    end
  end
  if not review or type(review.configs) ~= "table" or #review.configs == 0 then
    im.TextDisabled("There is no last run to review.")
    return
  end

  local doneCount, skippedCount, failedCount = 0, 0, 0
  if im.BeginTable("Screenshot run review", 4, im.TableFlags_SizingStretchProp) then
    im.TableSetupColumn("Vehicle")
    im.TableSetupColumn("Status")
    im.TableSetupColumn("Camera")
    im.TableSetupColumn("Preview")
    im.TableHeadersRow()
    for _, result in ipairs(review.configs) do
      if result.status == "done" then
        doneCount = doneCount + 1
      elseif result.status == "skipped" then
        skippedCount = skippedCount + 1
      elseif result.status == "failed" then
        failedCount = failedCount + 1
      end

      im.TableNextRow()
      im.TableNextColumn()
      im.TextUnformatted(tostring(result.vehName or ""))
      im.TableNextColumn()
      im.TextUnformatted(tostring(result.status or ""))
      im.TableNextColumn()
      im.TextUnformatted(tostring(result.camName or ""))
      im.TableNextColumn()
      if result.thumbnailPath and FS:fileExists(result.thumbnailPath) then
        if im.SmallButton("Open##" .. tostring(result.thumbnailPath)) then
          Engine.Platform.openFile(result.thumbnailPath)
        end
      else
        im.TextDisabled("Unavailable")
      end
    end
    im.EndTable()
  end
  im.TextUnformatted(string.format(
    "Done: %d   Skipped: %d   Failed: %d",
    doneCount,
    skippedCount,
    failedCount
  ))
  im.TextUnformatted("Shipped configs only: " .. (review.shippedConfigsOnly and "Yes" or "No"))
end

local function drawFramingDebug(vehicle, modelName, configName, isRunning)
  local framingContext = util_screenshotCreator_settings.getFramingContext()
  local debugOptions = framingContext.debug or {}
  if isRunning
    or (not debugOptions.drawBounds and not debugOptions.drawOobb and not debugOptions.drawInputs)
  then
    return
  end

  framingContext.vehicle = vehicle
  framingContext.modelName = modelName
  framingContext.configName = configName
  framingContext.framingModeId = getSelectedModeId()
  framingContext.preview = true
  local camera = util_screenshotCreator_framingManager.resolve(
    framingContext.framingModeId,
    framingContext
  )
  if camera then
    util_screenshotCreator_nodeOutpaint.drawFramingDebug(
      camera.framingData or camera.debugData,
      debugOptions
    )
  end
end

local function onUpdate()
  if util_screenshotCreator_job.consumeRunDone() then
    runDone = true
    legacyReviewData = nil
    if windowOpen[0] and reloadUiOnJobFinished[0] and type(reloadUI) == "function" then
      reloadUI()
    end
  end

  util_screenshotCreator_nodeOutpaint.beginUiFrame()
  if not windowOpen[0] then
    if windowWasOpen then restoreSessionState() end
    windowWasOpen = false
    util_screenshotCreator_nodeOutpaint.updateBrush({active = false})
    return
  end
  windowWasOpen = true

  local vehicle, modelName, configName, vehicleError = getCurrentVehicleInfo()
  local isRunning = util_screenshotCreator_job.isRunning()
  local settingsControls = util_screenshotCreator_settings.getControls()
  if not isRunning or settingsControls.includeMarginInScreenshot[0] then
    local selectedMode = getSelectedMode()
    util_screenshotCreator_settings.drawCameraOverlay(selectedMode and selectedMode.fixedFov)
  end
  if vehicle and configName then
    drawFramingDebug(vehicle, modelName, configName, isRunning)
  end

  initialWindowSize.x = 600 * im.uiscale[0]
  initialWindowSize.y = 700 * im.uiscale[0]
  im.SetNextWindowSize(initialWindowSize, im.Cond_FirstUseEver)
  if im.Begin("Vehicle Screenshot Creator (WIP)", windowOpen) then
    if vehicleError then
      im.TextWrapped("ERROR: " .. vehicleError)
    else
      drawWorkControls(vehicle, configName, isRunning)
      drawCameraInfo(vehicle)
      if isRunning then im.BeginDisabled() end
      if im.BeginTabBar("Screenshot Creator Tabs") then
        if im.BeginTabItem("Output") then
          util_screenshotCreator_settings.drawOutputControls({
            drawToggleUiApps = function()
              if im.Button(uiAppsVisible and "Hide UI apps" or "Show UI apps") then
                toggleUiApps()
              end
            end
          })
          im.EndTabItem()
        end
        if im.BeginTabItem("Lighting") then
          util_screenshotCreator_settings.drawLightingControls()
          im.EndTabItem()
        end
        if im.BeginTabItem("Debug") then
          drawFramingModeCombo()
          util_screenshotCreator_settings.drawOverlayControls()
          im.EndTabItem()
        end
        if im.BeginTabItem("Node outpainting") then
          util_screenshotCreator_nodeOutpaint.drawTab({
            vehicle = vehicle,
            configName = configName,
            autoFrame = function() previewVehicle(vehicle, configName) end
          })
          im.EndTabItem()
        end
        util_screenshotCreator_modelSelection.drawTab()
        if im.BeginTabItem("Manual controls") then
          drawFramingModeCombo()
          drawManualControls(vehicle, modelName, configName)
          im.EndTabItem()
        end
        local highlightReview = runDone
        if highlightReview then
          im.PushStyleColor2(im.Col_Text, im.ImVec4(1, 0.3, 0.3, 1))
        end
        if im.BeginTabItem("Last run review") then
          drawReview()
          runDone = false
          im.EndTabItem()
        end
        if highlightReview then im.PopStyleColor() end
        im.EndTabBar()
      end
      if isRunning then im.EndDisabled() end
    end
  end
  im.End()

  util_screenshotCreator_nodeOutpaint.updateBrush({
    active = windowOpen[0] and util_screenshotCreator_nodeOutpaint.isTabActive(),
    workerRunning = isRunning,
    vehicle = vehicle,
    configName = configName
  })
end

local function openWindow()
  local settingsModule = util_screenshotCreator_settings
    or extensions.util_screenshotCreator_settings
  if not settingsModule then
    local loaded, loadError = pcall(extensions.load, "util_screenshotCreator_settings")
    settingsModule = loaded and extensions.util_screenshotCreator_settings or nil
    if not settingsModule then
      log(
        "E",
        "screenshotCreator",
        "Unable to load screenshot creator settings: " .. tostring(loadError)
      )
      return false
    end
  end
  util_screenshotCreator_settings = settingsModule
  if editor_main and editor_main.initializeModules then
    editor_main.initializeModules()
  end
  settingsModule.applyEnvironment()
  windowOpen[0] = true
  return true
end

local function onSerialize()
  return {
    windowOpen = windowOpen[0],
    generateMissingThumbnailsOnly = generateMissingThumbnailsOnly[0],
    reloadUIOnJobFinished = reloadUiOnJobFinished[0],
    drivingEnabled = drivingEnabled,
    uiAppsVisible = uiAppsVisible,
    cameraSpeed = cameraSpeed[0],
    runDone = runDone,
    reviewData = legacyReviewData,
    framingModeId = getSelectedModeId(),
    previousFov = previousManualFov,
    isCameraSet = manualCameraSet
  }
end

local function hasLegacySettings(data)
  return data.resolutionPtr ~= nil
    or data.dynamicReflectionQuality ~= nil
    or data.fieldOfView ~= nil
    or data.cameraOverlayEnabled ~= nil
    or data.sample ~= nil
end

local function onDeserialized(data)
  if type(data) ~= "table" then return end
  if data.windowOpen ~= nil then windowOpen[0] = data.windowOpen == true end
  generateMissingThumbnailsOnly[0] = data.generateMissingThumbnailsOnly == true
  if data.reloadUIOnJobFinished ~= nil then
    reloadUiOnJobFinished[0] = data.reloadUIOnJobFinished == true
  end
  if data.drivingEnabled ~= nil then setDriving(data.drivingEnabled) end
  if data.uiAppsVisible ~= nil then uiAppsVisible = data.uiAppsVisible == true end
  cameraSpeed[0] = clamp(tonumber(data.cameraSpeed) or core_camera.getSpeed(), 2, 100)
  runDone = data.runDone == true
  legacyReviewData = data.reviewData
  previousManualFov = data.previousFov
  manualCameraSet = data.isCameraSet == true

  if hasLegacySettings(data) then
    util_screenshotCreator_settings.deserialize(data)
    util_screenshotCreator_nodeOutpaint.deserialize(data)
  end
  if data.framingModeId ~= nil or data.skipCustomCameras ~= nil then
    util_screenshotCreator_framingManager.migrateLegacyState(data)
  end
end

M.openWindow = openWindow
M.onUpdate = onUpdate
M.onExtensionUnloaded = restoreSessionState
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

return M
