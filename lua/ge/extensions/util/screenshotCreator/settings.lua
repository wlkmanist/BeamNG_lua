-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"ui_imgui", "core_camera"}

local im = ui_imgui
local dynCaptureQuality = require("core/settings/dynCaptureQuality")
local reflectionRegistryKeys = {
  "$pref::BeamNGVehicle::dynamicReflection::enabled",
  "$pref::BeamNGVehicle::dynamicReflection::textureSize",
  "$pref::BeamNGVehicle::dynamicReflection::facesPerUpdate",
  "$pref::BeamNGVehicle::dynamicReflection::detail",
  "$pref::BeamNGVehicle::dynamicReflection::distance"
}

local thumbnailConfig = {
  fileEnding = ".jpg",
  fov = 20,
  nearPlane = 0.1
}

local framingDefaults = {
  cameraAxisDownOffset = 0.10,
  cameraHeight = 1.1,
  settleDelay = 1
}

local outputDestinations = {
  "Vehicle thumbnails",
  "Screenshot/showroom folder"
}

local resolutions = {
  {"thumbnail", 800, 448},
  {"thumbnail temp", 2000, 1124},
  {"720p", 1280, 720},
  {"1080p", 1920, 1080},
  {"Square", 1920, 1920},
  {"WQHD", 2560, 1440},
  {"UWQHD", 3440, 1440},
  {"4k", 3840, 2160},
  {"8k", 8192, 4320}
}

local safeMargins = {
  width = 500,
  height = 281,
  defaultTargetIndex = 6,
  targets = {
    {name = "tiny", left = 2, right = 2, top = 30, bottom = 32, extraBottom = 90, color = {1, 0.2, 0.2, 1}},
    {name = "small", left = 2, right = 2, top = 22, bottom = 22, extraBottom = 78, color = {1, 0.6, 0.1, 1}},
    {name = "medium", left = 2, right = 2, top = 19, bottom = 19, extraBottom = 62, color = {1, 1, 0.1, 1}},
    {name = "large", left = 2, right = 2, top = 21, bottom = 21, extraBottom = 51, color = {0.2, 1, 0.2, 1}},
    {name = "huge", left = 2, right = 2, top = 19, bottom = 25, extraBottom = 58, color = {0.1, 0.8, 1, 1}},
    {name = "list", left = 2, right = 2, top = 2, bottom = 2, extraBottom = 2, color = {0.8, 0.3, 1, 1}},
    {name = "minimal", minimal = true, color = {0.2, 1, 0.2, 0.55}}
  }
}

local vehicleSafeMargin = {top = 4, bottom = 2}
local dynamicReflectionQualities = {"Lowest", "Low", "Normal", "High", "Ultra"}
local dynamicReflectionQualitiesStr = table.concat(dynamicReflectionQualities, "\0") .. "\0"
local ultraReflectionQuality = #dynamicReflectionQualities - 1
local reflectionQualitySerializationVersion = 2
local lightRoles = {
  {id = "key", label = "Key"},
  {id = "fill", label = "Fill"},
  {id = "rim", label = "Rim"},
  {id = "top", label = "Top"},
  {id = "groundFill", label = "Ground fill"},
  {id = "horizonFill", label = "Horizon fill"}
}
local ssaoCaptureModes = {"on", "reduced", "off"}
local ssaoCaptureModesStr = "On\0Reduced (contrast 1)\0Off\0\0"
local cycloramaMaterialName = "showroom_v2_lighting_backdrop"
local cycloramaColor = im.ArrayFloat(3)
local cycloramaMaterialId

local defaults = {
  outputDestination = 1,
  resolution = 2,
  dynamicReflectionQuality = ultraReflectionQuality,
  lowBeamsEnabled = false,
  autoExposure = false,
  manualExposure = 8.3,
  fieldOfView = thumbnailConfig.fov,
  cameraHeight = framingDefaults.cameraHeight,
  horizontalFramingMargin = 32,
  superSampling = 3,
  shippedConfigsOnly = true,
  keepAspectRatio = false,
  useFramingMargins = true,
  settleDelay = 2,
  freezePhysics = true,
  lightingRigEnabled = true,
  exposureCorrection = true,
  parkingMarkup = false,
  lightRoleIntensity = {key = 1, rim = 1, fill = 1, top = 1, groundFill = 0.6, horizonFill = 1},
  lightRoleShadows = {key = true, rim = false, fill = false, top = true, groundFill = false, horizonFill = false},
  ssaoCaptureMode = 0
}

local ctrls = {
  outputDestination = im.IntPtr(defaults.outputDestination - 1),
  resolution = im.IntPtr(defaults.resolution - 1),
  imageResolution = im.ArrayInt(2),
  keepAspectRatio = im.BoolPtr(defaults.keepAspectRatio),
  resolutionMultiplier = im.FloatPtr(2),
  superSampling = im.FloatPtr(defaults.superSampling),
  shippedConfigsOnly = im.BoolPtr(defaults.shippedConfigsOnly),
  fieldOfView = im.FloatPtr(defaults.fieldOfView),
  cameraHeight = im.FloatPtr(defaults.cameraHeight),
  horizontalFramingMargin = im.FloatPtr(defaults.horizontalFramingMargin),
  dynamicReflectionQuality = im.IntPtr(defaults.dynamicReflectionQuality),
  lowBeamsEnabled = im.BoolPtr(defaults.lowBeamsEnabled),
  autoExposure = im.BoolPtr(defaults.autoExposure),
  manualExposure = im.FloatPtr(defaults.manualExposure),
  useFramingMargins = im.BoolPtr(defaults.useFramingMargins),
  cameraOverlayEnabled = im.BoolPtr(true),
  includeMarginInScreenshot = im.BoolPtr(false),
  selectedMargin = im.IntPtr(safeMargins.defaultTargetIndex),
  compositionOverlayEnabled = im.BoolPtr(false),
  framingBoundsDebugEnabled = im.BoolPtr(false),
  oobbDebugEnabled = im.BoolPtr(false),
  framingInputsDebugEnabled = im.BoolPtr(false),
  sample = im.BoolPtr(false),
  comparison = im.BoolPtr(false),
  settleDelay = im.FloatPtr(defaults.settleDelay),
  freezePhysics = im.BoolPtr(defaults.freezePhysics),
  lightingRigEnabled = im.BoolPtr(defaults.lightingRigEnabled),
  exposureCorrection = im.BoolPtr(defaults.exposureCorrection),
  parkingMarkup = im.BoolPtr(defaults.parkingMarkup),
  lightRoleIntensity = {},
  lightRoleShadows = {},
  ssaoCaptureMode = im.IntPtr(defaults.ssaoCaptureMode)
}
for _, role in ipairs(lightRoles) do
  ctrls.lightRoleIntensity[role.id] = im.FloatPtr(defaults.lightRoleIntensity[role.id])
  ctrls.lightRoleShadows[role.id] = im.BoolPtr(defaults.lightRoleShadows[role.id])
end

local outputDestinationsStr = table.concat(outputDestinations, "\0") .. "\0"
local resolutionComboStr
local marginComboStr
local lastImageResolution = {500, 281}
local previewResolutionActive = false
local originalVideoMode
local savedEnvironment = {}
local environmentCaptured = false
local spacingSize = im.ImVec2(0, 0)

local function addVerticalSpacing(height)
  spacingSize.x = im.uiscale[0]
  spacingSize.y = height * im.uiscale[0]
  im.Dummy(spacingSize)
end

local function copyArray(value)
  local result = {}
  for index, item in ipairs(value) do
    result[index] = type(item) == "table" and deepcopy(item) or item
  end
  return result
end

local function isInShowroom()
  if not getCurrentLevelIdentifier then return false end
  local level = getCurrentLevelIdentifier()
  return level == "showroom_v2_lighting"
    or level == "showroom_v2_lighting_simple"
end

local function resolveMarginTarget(margin)
  if not margin or not margin.minimal then return margin end

  local resolved = {
    name = margin.name,
    left = 0,
    right = 0,
    top = 0,
    bottom = 0,
    extraBottom = 0,
    color = margin.color
  }
  for _, target in ipairs(safeMargins.targets) do
    if not target.minimal then
      resolved.left = math.max(resolved.left, target.left)
      resolved.right = math.max(resolved.right, target.right)
      resolved.top = math.max(resolved.top, target.top)
      resolved.bottom = math.max(resolved.bottom, target.bottom)
      resolved.extraBottom = math.max(resolved.extraBottom, target.extraBottom)
    end
  end
  return resolved
end

local function getMarginTarget(index)
  local target = safeMargins.targets[(index or safeMargins.defaultTargetIndex) + 1]
  return resolveMarginTarget(target) or resolveMarginTarget(safeMargins.targets[safeMargins.defaultTargetIndex + 1])
end

local function addVehicleMargin(margin)
  if not margin then return nil end
  local horizontalMargin = ctrls.horizontalFramingMargin[0]
  return {
    name = margin.name,
    left = margin.left + horizontalMargin,
    right = margin.right + horizontalMargin,
    top = margin.top + vehicleSafeMargin.top,
    bottom = margin.bottom + vehicleSafeMargin.bottom,
    extraBottom = margin.extraBottom,
    color = margin.color
  }
end

local function scaleMargin(margin, resolution)
  if not margin or not resolution or not resolution[1] or not resolution[2] then return margin end
  local scaleX = resolution[1] / safeMargins.width
  local scaleY = resolution[2] / safeMargins.height
  return {
    name = margin.name,
    left = margin.left * scaleX,
    right = margin.right * scaleX,
    top = margin.top * scaleY,
    bottom = margin.bottom * scaleY,
    extraBottom = margin.extraBottom * scaleY,
    color = margin.color
  }
end

local function getThumbnailResolution()
  local preset = resolutions[defaults.resolution - 1]
  return {preset[2], preset[3]}
end

local function getCurrentResolution()
  local preset = resolutions[ctrls.resolution[0]]
  if preset then
    return {preset[2], preset[3]}
  end
  return {ctrls.imageResolution[0], ctrls.imageResolution[1]}
end

local function setImageResolution(width, height)
  width = math.max(1, math.floor(tonumber(width) or 1))
  height = math.max(1, math.floor(tonumber(height) or 1))
  ctrls.imageResolution[0] = width
  ctrls.imageResolution[1] = height

  ctrls.resolution[0] = 0
  for index, preset in ipairs(resolutions) do
    if width == preset[2] and height == preset[3] then
      ctrls.resolution[0] = index
      break
    end
  end
end

local function resetToDefaults()
  ctrls.outputDestination[0] = defaults.outputDestination - 1
  ctrls.resolution[0] = defaults.resolution - 1
  local resolution = getCurrentResolution()
  ctrls.imageResolution[0] = resolution[1]
  ctrls.imageResolution[1] = resolution[2]
  ctrls.keepAspectRatio[0] = defaults.keepAspectRatio
  ctrls.superSampling[0] = defaults.superSampling
  ctrls.shippedConfigsOnly[0] = defaults.shippedConfigsOnly
  ctrls.dynamicReflectionQuality[0] = defaults.dynamicReflectionQuality
  ctrls.lowBeamsEnabled[0] = defaults.lowBeamsEnabled
  ctrls.autoExposure[0] = defaults.autoExposure
  ctrls.manualExposure[0] = defaults.manualExposure
  ctrls.fieldOfView[0] = defaults.fieldOfView
  ctrls.cameraHeight[0] = defaults.cameraHeight
  ctrls.horizontalFramingMargin[0] = defaults.horizontalFramingMargin
  ctrls.useFramingMargins[0] = defaults.useFramingMargins
  ctrls.settleDelay[0] = defaults.settleDelay
  ctrls.freezePhysics[0] = defaults.freezePhysics
end

local function resetLightingSettings()
  ctrls.lightingRigEnabled[0] = defaults.lightingRigEnabled
  ctrls.exposureCorrection[0] = defaults.exposureCorrection
  ctrls.parkingMarkup[0] = defaults.parkingMarkup
  ctrls.ssaoCaptureMode[0] = defaults.ssaoCaptureMode
  for _, role in ipairs(lightRoles) do
    ctrls.lightRoleIntensity[role.id][0] = defaults.lightRoleIntensity[role.id]
    ctrls.lightRoleShadows[role.id][0] = defaults.lightRoleShadows[role.id]
  end
end

local function readRoleControls(controls)
  local values = {}
  for _, role in ipairs(lightRoles) do values[role.id] = controls[role.id][0] end
  return values
end

local function getLightingRig()
  local rig = {
    enabled = ctrls.lightingRigEnabled[0],
    exposureCorrection = ctrls.exposureCorrection[0],
    ssaoMode = ssaoCaptureModes[ctrls.ssaoCaptureMode[0] + 1] or "on",
    parkingMarkup = ctrls.parkingMarkup[0],
    roles = {}
  }
  for _, role in ipairs(lightRoles) do
    rig.roles[role.id] = {
      intensity = ctrls.lightRoleIntensity[role.id][0],
      shadows = ctrls.lightRoleShadows[role.id][0]
    }
  end
  return rig
end

local function drawCycloramaColor()
  local material = scenetree.findObject(cycloramaMaterialName)
  if not material then return end
  if cycloramaMaterialId ~= material:getID() then
    local values = {}
    for value in tostring(material:getField("baseColorFactor", 0) or ""):gmatch("%S+") do
      values[#values + 1] = tonumber(value)
    end
    for index = 0, 2 do cycloramaColor[index] = values[index + 1] or 1 end
    cycloramaMaterialId = material:getID()
  end
  if im.ColorEdit3("Cyclorama color", cycloramaColor) then
    material:setField("baseColorFactor", 0, string.format(
      "%.6f %.6f %.6f 1",
      cycloramaColor[0],
      cycloramaColor[1],
      cycloramaColor[2]
    ))
    material:reload()
  end
  im.tooltip("Edits the cyclorama material live. Save the level materials to keep it.")
end

local function drawLightingControls()
  drawCycloramaColor()
  im.Checkbox("Camera-relative lighting rig", ctrls.lightingRigEnabled)
  im.tooltip("Places level objects tagged with thumbnailRole around the vehicle and camera. Off keeps the level layout.")
  local rigDisabled = not ctrls.lightingRigEnabled[0]
  if rigDisabled then im.BeginDisabled() end
  for _, role in ipairs(lightRoles) do
    im.Checkbox("Shadows##" .. role.id, ctrls.lightRoleShadows[role.id])
    im.SameLine()
    im.SliderFloat(role.label .. " intensity", ctrls.lightRoleIntensity[role.id], 0, 4, "%.2fx")
  end
  im.tooltip("Multiplies the role's base illuminance at the vehicle.")
  im.Checkbox("Exposure correction", ctrls.exposureCorrection)
  im.tooltip("Scales key, fill, rim and top so the faces the camera sees get the same light for every asset size. With it on, the role sliders set the balance between roles, not the overall level.")
  if rigDisabled then im.EndDisabled() end
  im.Checkbox("Parking markup", ctrls.parkingMarkup)
  im.tooltip("Off hides ParkingSpotMarkup and ParkingSpotWheelstops during capture. On shows them for the shot, then restores the level.")
  im.Combo2("SSAO during capture", ctrls.ssaoCaptureMode, ssaoCaptureModesStr)
  im.tooltip("GTAO draws contour stripes on the smooth cyclorama. Reduced weakens them, Off removes them along with the vehicle AO.")
  im.TextDisabled("Applied on the next capture.")
end

local function getSelectedReflectionQuality()
  return dynamicReflectionQualities[ctrls.dynamicReflectionQuality[0] + 1] or "Ultra"
end

local function writeExposure(auto, ev)
  local exposure = scenetree and scenetree.findObject("PostEffectLocalExposureObject")
  if not exposure then return nil end
  if auto ~= nil then exposure.autoExposure = not auto end
  if ev ~= nil then exposure.manualEV = ev end
  if auto ~= nil then exposure.autoExposure = auto end
  return exposure
end

local function applyExposure()
  local exposure = writeExposure(ctrls.autoExposure[0], ctrls.manualExposure[0])
  return exposure ~= nil
    and exposure.autoExposure == ctrls.autoExposure[0]
    and math.abs(exposure.manualEV - ctrls.manualExposure[0]) < 0.001
end

local function applyReflections()
  if not isInShowroom() then return false end
  dynCaptureQuality.applyReflection(getSelectedReflectionQuality())
  return true
end

local function applyLicensePlates()
  if not isInShowroom() then return false end
  settings.setValue("SkipGenerateLicencePlate", true)
  return true
end

-- seatOccupants owns the occupant meshes and re-shows them on its own events (vehicle replace/reset callbacks,
-- camera changes), so it has to be switched off through its setting; setValue does not fire onSettingsChanged
local function setSeatOccupantsEnabled(enabled)
  settings.setValue("enableSeatOccupants", enabled)
  if gameplay_seatOccupants and gameplay_seatOccupants.onSettingsChanged then
    gameplay_seatOccupants.onSettingsChanged()
  end
end

local function captureEnvironment()
  if savedEnvironment.skipLicensePlates == nil then
    savedEnvironment.skipLicensePlates = settings.getValue("SkipGenerateLicencePlate") == true
    environmentCaptured = true
  end
  if savedEnvironment.dynamicReflectionRuntime == nil then
    savedEnvironment.dynamicReflectionRuntime = {}
    for _, key in ipairs(reflectionRegistryKeys) do
      savedEnvironment.dynamicReflectionRuntime[key] = VariableRegistry.get(key)
    end
    environmentCaptured = true
  end
  if savedEnvironment.autoExposure == nil then
    local localExposure = scenetree and scenetree.findObject("PostEffectLocalExposureObject")
    if localExposure then
      savedEnvironment.autoExposure = localExposure.autoExposure
      savedEnvironment.manualExposure = localExposure.manualEV
      environmentCaptured = true
    end
  end
  if savedEnvironment.seatOccupants == nil then
    savedEnvironment.seatOccupants = settings.getValue("enableSeatOccupants", true) ~= false
    environmentCaptured = true
  end
end

local function applyEnvironment(options)
  options = options or {}
  -- The fixed exposure is tuned for the thumbnail showroom, not gameplay maps.
  -- Other levels keep their current exposure, which the capture view copies.
  if not isInShowroom() then return end
  captureEnvironment()
  if options.applyExposure ~= false then applyExposure() end
  applyReflections()
  applyLicensePlates()
  setSeatOccupantsEnabled(false)
end

local function applyEnvironmentSnapshot(snapshot)
  local restored = true

  if snapshot.skipLicensePlates ~= nil then
    local previous = snapshot.skipLicensePlates == true
    settings.setValue("SkipGenerateLicencePlate", previous)
    if (settings.getValue("SkipGenerateLicencePlate") == true) ~= previous then
      log("E", "screenshotCreator", "License plate generation setting did not restore")
      restored = false
    end
  end

  if snapshot.seatOccupants ~= nil then
    local previous = snapshot.seatOccupants == true
    setSeatOccupantsEnabled(previous)
    if (settings.getValue("enableSeatOccupants", true) ~= false) ~= previous then
      log("E", "screenshotCreator", "Seat occupant setting did not restore")
      restored = false
    end
  end

  for key, value in pairs(snapshot.dynamicReflectionRuntime or {}) do
    local ok, err = pcall(VariableRegistry.set, key, value)
    local actual = ok and VariableRegistry.get(key)
    local matches = actual == value or (type(actual) == "number" and type(value) == "number" and math.abs(actual - value) < 0.001)
    if not ok or not matches then
      log("E", "screenshotCreator", "Dynamic reflection setting did not restore: " .. key .. " (" .. tostring(err) .. ")")
      restored = false
    end
  end

  if snapshot.autoExposure ~= nil or snapshot.manualExposure ~= nil then
    local exposure = writeExposure(snapshot.autoExposure, snapshot.manualExposure)
    if not exposure
      or (snapshot.autoExposure ~= nil and exposure.autoExposure ~= snapshot.autoExposure)
      or (snapshot.manualExposure ~= nil and math.abs(exposure.manualEV - snapshot.manualExposure) >= 0.001)
    then
      log("E", "screenshotCreator", "Exposure state did not restore")
      restored = false
    end
  end

  return restored
end

local function getEnvironmentSnapshot()
  if not environmentCaptured then return nil end
  return deepcopy(savedEnvironment)
end

local function restoreEnvironment()
  if not environmentCaptured then return true end
  if not applyEnvironmentSnapshot(savedEnvironment) then return false end
  savedEnvironment = {}
  environmentCaptured = false
  return true
end

local function isDefaultConfig()
  return ctrls.outputDestination[0] == defaults.outputDestination - 1
    and ctrls.resolution[0] == defaults.resolution - 1
    and ctrls.dynamicReflectionQuality[0] == defaults.dynamicReflectionQuality
    and ctrls.lowBeamsEnabled[0] == defaults.lowBeamsEnabled
    and ctrls.autoExposure[0] == defaults.autoExposure
    and ctrls.manualExposure[0] == defaults.manualExposure
    and ctrls.shippedConfigsOnly[0] == defaults.shippedConfigsOnly
    and ctrls.fieldOfView[0] == defaults.fieldOfView
    and ctrls.cameraHeight[0] == defaults.cameraHeight
    and ctrls.horizontalFramingMargin[0] == defaults.horizontalFramingMargin
end

local function isThumbnailConfigGood()
  return not (outputDestinations[ctrls.outputDestination[0] + 1] == "Vehicle thumbnails"
    and ctrls.resolution[0] + 1 ~= defaults.resolution)
end

local function getFramingMargin(resolution)
  if ctrls.useFramingMargins[0] and resolution and resolution[1] and resolution[2] then
    return scaleMargin(addVehicleMargin(getMarginTarget(ctrls.selectedMargin[0])), resolution)
  end
  return {left = 0, right = 0, top = 0, bottom = 0, extraBottom = 0}
end

local function getFramingContext(resolution)
  resolution = resolution or getCurrentResolution()
  return {
    fieldOfView = ctrls.fieldOfView[0],
    fov = ctrls.fieldOfView[0],
    nearPlane = thumbnailConfig.nearPlane,
    cameraHeight = ctrls.cameraHeight[0],
    cameraAxisDownOffset = framingDefaults.cameraAxisDownOffset,
    settleDelay = ctrls.settleDelay[0],
    resolution = {resolution[1], resolution[2]},
    aspectRatio = resolution[2] ~= 0 and resolution[1] / resolution[2] or 1,
    useMargins = ctrls.useFramingMargins[0],
    margin = getFramingMargin(resolution),
    debug = {
      drawBounds = ctrls.framingBoundsDebugEnabled[0],
      drawOobb = ctrls.oobbDebugEnabled[0],
      drawInputs = ctrls.framingInputsDebugEnabled[0]
    }
  }
end

local function getCaptureContext()
  local resolution = getCurrentResolution()
  local superSampling = ctrls.superSampling[0]
  return {
    outputDestinationIndex = ctrls.outputDestination[0],
    outputDestination = outputDestinations[ctrls.outputDestination[0] + 1],
    fileEnding = thumbnailConfig.fileEnding,
    resolution = resolution,
    superSampling = superSampling,
    supersampling = superSampling,
    internalResolution = {
      math.floor(resolution[1] * superSampling),
      math.floor(resolution[2] * superSampling)
    },
    dynamicReflectionQuality = getSelectedReflectionQuality(),
    lowBeamsEnabled = ctrls.lowBeamsEnabled[0],
    settleDelay = ctrls.settleDelay[0],
    freezePhysics = ctrls.freezePhysics[0],
    shippedConfigsOnly = ctrls.shippedConfigsOnly[0],
    autoExposure = ctrls.autoExposure[0],
    manualExposure = ctrls.manualExposure[0],
    includeMarginInScreenshot = ctrls.includeMarginInScreenshot[0],
    sample = ctrls.sample[0],
    comparison = ctrls.comparison[0]
  }
end

local function getJobSettings(options)
  options = options or {}
  local framing = getFramingContext(options.resolution)
  local capture = getCaptureContext()
  local outputFolder = capture.outputDestinationIndex == 0 and "vehicles/" or "screenshots/showroom/"

  return {
    fileEnding = capture.fileEnding,
    outputDestinationIndex = capture.outputDestinationIndex,
    outputDestination = capture.outputDestination,
    outputFolder = options.outputFolder or outputFolder,
    resolution = {capture.resolution[1], capture.resolution[2]},
    supersampling = capture.superSampling,
    superSampling = capture.superSampling,
    internalResolution = {capture.internalResolution[1], capture.internalResolution[2]},
    fov = framing.fieldOfView,
    fieldOfView = framing.fieldOfView,
    nearPlane = framing.nearPlane,
    cameraHeight = framing.cameraHeight,
    cameraAxisDownOffset = framing.cameraAxisDownOffset,
    settleDelay = framing.settleDelay,
    aspectRatio = framing.aspectRatio,
    useMargins = framing.useMargins,
    useFramingMargins = framing.useMargins,
    margin = deepcopy(framing.margin),
    dynamicReflectionQuality = capture.dynamicReflectionQuality,
    lowBeamsEnabled = options.lowBeamsEnabled == true or capture.lowBeamsEnabled,
    shippedConfigsOnly = options.shippedConfigsOnly == nil
      and capture.shippedConfigsOnly
      or options.shippedConfigsOnly == true,
    autoExposure = capture.autoExposure,
    manualExposure = capture.manualExposure,
    includeMarginInScreenshot = capture.includeMarginInScreenshot,
    sample = options.sample == true or capture.sample,
    comparison = options.comparison == true or capture.comparison,
    captureTimeout = math.max(tonumber(options.captureTimeout) or 5, 0.1),
    debug = deepcopy(framing.debug)
  }
end

local function beginWork(options)
  applyEnvironment(options)
end

local function finishWork()
  restoreEnvironment()
end

local function setPreviewResolution(enabled)
  enabled = enabled == true
  if enabled == previewResolutionActive then return end
  if not GFXDevice then return end

  local videoMode = GFXDevice.getVideoMode()
  if enabled then
    originalVideoMode = {
      width = videoMode.width,
      height = videoMode.height,
      displayMode = videoMode.displayMode
    }
    local resolution = getCurrentResolution()
    videoMode.width = resolution[1]
    videoMode.height = resolution[2]
    videoMode.displayMode = "Borderless"
  elseif originalVideoMode then
    videoMode.width = originalVideoMode.width
    videoMode.height = originalVideoMode.height
    videoMode.displayMode = originalVideoMode.displayMode
  end
  log("I", "screenshotCreator", "Requesting new video mode")
  GFXDevice.setVideoMode(videoMode)
  previewResolutionActive = enabled
end

local function drawOutputControls(options)
  options = options or {}

  if isDefaultConfig() then im.BeginDisabled() end
  if im.Button("Restore thumbnail defaults") then
    resetToDefaults()
    applyExposure()
    applyReflections()
  end
  if isDefaultConfig() then im.EndDisabled() end

  im.Combo2("Output destination", ctrls.outputDestination, outputDestinationsStr)
  im.Checkbox("Shipped configs only", ctrls.shippedConfigsOnly)
  im.tooltip("Hide models and skip configs excluded from the shipped build.")
  im.SliderFloat("Procedural field of view", ctrls.fieldOfView, 10, 100, "%.1f deg")
  im.tooltip("Used by procedural framing. Modes with a fixed FOV ignore this value.")
  im.SliderFloat("Procedural camera height", ctrls.cameraHeight, 0.1, 5, "%.2f m")
  im.tooltip("Height above the lowest enabled framing node.")
  im.SliderFloat("Horizontal framing margin", ctrls.horizontalFramingMargin, 0, 100, "%.0f px")
  im.tooltip("Extra left/right clearance at the 500 x 281 reference resolution.")
  addVerticalSpacing(20)

  if not resolutionComboStr then
    resolutionComboStr = "custom\0"
    for _, preset in ipairs(resolutions) do
      resolutionComboStr = resolutionComboStr .. preset[1] .. " - " .. preset[2] .. " x " .. preset[3] .. "\0"
    end
    resolutionComboStr = resolutionComboStr .. "\0"
  end

  im.Combo2("Common Resolutions", ctrls.resolution, resolutionComboStr)
  if ctrls.resolution[0] > 0 then
    local preset = resolutions[ctrls.resolution[0]]
    ctrls.imageResolution[0] = preset[2]
    ctrls.imageResolution[1] = preset[3]
  end

  im.Checkbox("Keep aspect ratio on manual resolution change", ctrls.keepAspectRatio)
  im.InputFloat("##resolutionMultiplier", ctrls.resolutionMultiplier)
  im.SameLine()
  if im.Button("Multiply current res") and ctrls.resolutionMultiplier[0] > 0 then
    setImageResolution(
      ctrls.imageResolution[0] * ctrls.resolutionMultiplier[0],
      ctrls.imageResolution[1] * ctrls.resolutionMultiplier[0])
  end

  if im.InputInt2("Final image resolution", ctrls.imageResolution, im.InputTextFlags_EnterReturnsTrue) then
    local width = ctrls.imageResolution[0]
    local height = ctrls.imageResolution[1]
    if ctrls.keepAspectRatio[0] and lastImageResolution[1] > 0 and lastImageResolution[2] > 0 then
      if width == lastImageResolution[1] then
        width = lastImageResolution[1] * height / lastImageResolution[2]
      elseif height == lastImageResolution[2] then
        height = lastImageResolution[2] * width / lastImageResolution[1]
      end
    end
    setImageResolution(width, height)
  end

  if im.Button(previewResolutionActive and "Reset resolution" or "Preview resolution") then
    setPreviewResolution(not previewResolutionActive)
  end
  if options.drawToggleUiApps then
    im.SameLine()
    options.drawToggleUiApps()
  end

  if not isThumbnailConfigGood() then
    local resolution = getCurrentResolution()
    local thumbnailResolution = getThumbnailResolution()
    im.TextWrapped(string.format(
      "Correct vehicle thumbnail size is %d x %d; the current size is %d x %d.",
      thumbnailResolution[1], thumbnailResolution[2], resolution[1], resolution[2]))
  else
    addVerticalSpacing(20)
  end

  im.SliderFloat("Super Sampling", ctrls.superSampling, 1, 4, "%.2fx")

  local previousQuality = ctrls.dynamicReflectionQuality[0]
  im.Combo2("Dynamic reflections", ctrls.dynamicReflectionQuality, dynamicReflectionQualitiesStr)
  if ctrls.dynamicReflectionQuality[0] ~= previousQuality then
    applyReflections()
  end

  if im.Checkbox("Automatic exposure", ctrls.autoExposure) then
    applyExposure()
  end
  im.tooltip("Disable automatic exposure to use the fixed custom exposure below.")
  if ctrls.autoExposure[0] then im.BeginDisabled() end
  if im.SliderFloat("Custom exposure", ctrls.manualExposure, -20, 20, "%.1f EV") then
    applyExposure()
  end
  if ctrls.autoExposure[0] then im.EndDisabled() end
  im.Checkbox("Enable low beams", ctrls.lowBeamsEnabled)
  im.SliderFloat("Physics settle delay", ctrls.settleDelay, 0, 10, "%.1f s")
  im.Checkbox("Freeze physics during capture", ctrls.freezePhysics)

  local capture = getCaptureContext()
  local width = capture.internalResolution[1]
  local height = capture.internalResolution[2]
  local rawSize = width * height * 3
  addVerticalSpacing(20)
  im.TextUnformatted("Internal resolution: " .. tostring(width) .. " x " .. tostring(height))
  im.TextUnformatted("Megapixel = " .. string.format("%0.2f", width * height / 1000000))
  if bytes_to_string then
    im.TextUnformatted("Raw image size = " .. bytes_to_string(rawSize))
    im.TextUnformatted("Estimated JPG file size = " .. bytes_to_string(rawSize * 0.14))
  end

  lastImageResolution[1] = ctrls.imageResolution[0]
  lastImageResolution[2] = ctrls.imageResolution[1]
end

local function drawOverlayControls()
  im.Checkbox("Show margin overlay", ctrls.cameraOverlayEnabled)
  im.tooltip("Draws the thumbnail frame and target-specific safe margins using the current camera.")
  im.Checkbox("Include margin in screenshot", ctrls.includeMarginInScreenshot)
  im.tooltip("Keeps debug margin lines visible while screenshots are captured.")

  if not marginComboStr then
    marginComboStr = ""
    for _, margin in ipairs(safeMargins.targets) do
      marginComboStr = marginComboStr .. margin.name .. "\0"
    end
    marginComboStr = marginComboStr .. "\0"
  end
  im.Combo2("Margin overlay size", ctrls.selectedMargin, marginComboStr)
  im.Checkbox("Show composition overlay", ctrls.compositionOverlayEnabled)
  im.Checkbox("Show framing bounding box", ctrls.framingBoundsDebugEnabled)
  im.Checkbox("Show OOBB", ctrls.oobbDebugEnabled)
  im.Checkbox("Show framing inputs", ctrls.framingInputsDebugEnabled)
  im.Checkbox("Sample", ctrls.sample)
  im.Checkbox("Comparison", ctrls.comparison)
end

local function drawCameraOverlay(fovOverride)
  if not ctrls.cameraOverlayEnabled[0] and not ctrls.compositionOverlayEnabled[0] then return end

  local resolution = getCurrentResolution()
  if not resolution[1] or not resolution[2] or resolution[2] == 0 then return end

  local position = core_camera.getPosition()
  local rotation = core_camera.getQuat()
  local distance = 1
  local halfHeight = math.tan(math.rad(fovOverride or ctrls.fieldOfView[0]) * 0.5) * distance
  local halfWidth = halfHeight * resolution[1] / resolution[2]
  local right = rotation * vec3(1, 0, 0)
  local forward = rotation * vec3(0, 1, 0)
  local up = rotation * vec3(0, 0, 1)
  local center = position + forward * distance

  local function planePoint(pixelX, pixelY)
    local x = -halfWidth + pixelX / resolution[1] * halfWidth * 2
    local y = halfHeight - pixelY / resolution[2] * halfHeight * 2
    return center + right * x + up * y
  end

  local function drawLine(x1, y1, x2, y2, color, width)
    debugDrawer:drawLineInstance(planePoint(x1, y1), planePoint(x2, y2), width or 3, color, false)
  end

  local function drawRect(left, top, rightEdge, bottom, color, width)
    drawLine(left, top, rightEdge, top, color, width)
    drawLine(rightEdge, top, rightEdge, bottom, color, width)
    drawLine(rightEdge, bottom, left, bottom, color, width)
    drawLine(left, bottom, left, top, color, width)
  end

  drawRect(0, 0, resolution[1], resolution[2], ColorF(1, 0, 0, 1))
  if ctrls.cameraOverlayEnabled[0] then
    local target = getMarginTarget(ctrls.selectedMargin[0])
    local margin = scaleMargin(target, resolution)
    local vehicleMargin = scaleMargin(addVehicleMargin(target), resolution)
    drawRect(margin.left, margin.top, resolution[1] - margin.right, resolution[2] - margin.bottom, ColorF(0, 1, 0, 0.7), 3)
    drawLine(margin.left, resolution[2] - margin.extraBottom, resolution[1] - margin.right, resolution[2] - margin.extraBottom, ColorF(0, 1, 0, 0.45), 2)
    drawRect(vehicleMargin.left, vehicleMargin.top, resolution[1] - vehicleMargin.right, resolution[2] - vehicleMargin.bottom, ColorF(0.2, 0.45, 1, 0.75), 2)
  end

  if ctrls.compositionOverlayEnabled[0] then
    local thirdColor = ColorF(0.3, 0.6, 1, 0.65)
    local centerColor = ColorF(1, 1, 1, 0.75)
    drawLine(resolution[1] / 3, 0, resolution[1] / 3, resolution[2], thirdColor)
    drawLine(resolution[1] * 2 / 3, 0, resolution[1] * 2 / 3, resolution[2], thirdColor)
    drawLine(0, resolution[2] / 3, resolution[1], resolution[2] / 3, thirdColor)
    drawLine(0, resolution[2] * 2 / 3, resolution[1], resolution[2] * 2 / 3, thirdColor)
    drawLine(resolution[1] / 2, 0, resolution[1] / 2, resolution[2], centerColor)
    drawLine(0, resolution[2] / 2, resolution[1], resolution[2] / 2, centerColor)
  end
end

local function serialize()
  return {
    outputDestination = ctrls.outputDestination[0],
    resolution = ctrls.resolution[0],
    imageResolution = {ctrls.imageResolution[0], ctrls.imageResolution[1]},
    keepAspectRatio = ctrls.keepAspectRatio[0],
    resolutionMultiplier = ctrls.resolutionMultiplier[0],
    superSampling = ctrls.superSampling[0],
    shippedConfigsOnly = ctrls.shippedConfigsOnly[0],
    fieldOfView = ctrls.fieldOfView[0],
    cameraHeight = ctrls.cameraHeight[0],
    horizontalFramingMargin = ctrls.horizontalFramingMargin[0],
    reflectionQualitySerializationVersion = reflectionQualitySerializationVersion,
    dynamicReflectionQuality = ctrls.dynamicReflectionQuality[0],
    lowBeamsEnabled = ctrls.lowBeamsEnabled[0],
    settleDelay = ctrls.settleDelay[0],
    freezePhysics = ctrls.freezePhysics[0],
    autoExposure = ctrls.autoExposure[0],
    manualExposure = ctrls.manualExposure[0],
    useFramingMargins = ctrls.useFramingMargins[0],
    cameraOverlayEnabled = ctrls.cameraOverlayEnabled[0],
    includeMarginInScreenshot = ctrls.includeMarginInScreenshot[0],
    selectedMargin = ctrls.selectedMargin[0],
    compositionOverlayEnabled = ctrls.compositionOverlayEnabled[0],
    framingBoundsDebugEnabled = ctrls.framingBoundsDebugEnabled[0],
    oobbDebugEnabled = ctrls.oobbDebugEnabled[0],
    framingInputsDebugEnabled = ctrls.framingInputsDebugEnabled[0],
    sample = ctrls.sample[0],
    comparison = ctrls.comparison[0],
    lightingRigEnabled = ctrls.lightingRigEnabled[0],
    exposureCorrection = ctrls.exposureCorrection[0],
    parkingMarkup = ctrls.parkingMarkup[0],
    lightRoleIntensity = readRoleControls(ctrls.lightRoleIntensity),
    lightRoleShadows = readRoleControls(ctrls.lightRoleShadows),
    ssaoCaptureMode = ctrls.ssaoCaptureMode[0]
  }
end

local function deserialize(data)
  if type(data) ~= "table" then return end
  resetToDefaults()
  resetLightingSettings()

  ctrls.outputDestination[0] = clamp(tonumber(data.outputDestination) or defaults.outputDestination - 1, 0, #outputDestinations - 1)
  ctrls.resolution[0] = clamp(tonumber(data.resolution or data.resolutionPtr) or defaults.resolution - 1, 0, #resolutions)
  if type(data.imageResolution) == "table" then
    ctrls.imageResolution[0] = math.max(1, tonumber(data.imageResolution[1]) or ctrls.imageResolution[0])
    ctrls.imageResolution[1] = math.max(1, tonumber(data.imageResolution[2]) or ctrls.imageResolution[1])
  end
  ctrls.keepAspectRatio[0] = data.keepAspectRatio == true
  ctrls.resolutionMultiplier[0] = math.max(0.01, tonumber(data.resolutionMultiplier) or 2)
  ctrls.superSampling[0] = clamp(tonumber(data.superSampling) or defaults.superSampling, 1, 4)
  ctrls.shippedConfigsOnly[0] = data.shippedConfigsOnly ~= false
  ctrls.fieldOfView[0] = clamp(tonumber(data.fieldOfView) or defaults.fieldOfView, 10, 100)
  ctrls.cameraHeight[0] = clamp(tonumber(data.cameraHeight) or defaults.cameraHeight, 0.1, 5)
  ctrls.horizontalFramingMargin[0] = clamp(
    tonumber(data.horizontalFramingMargin) or defaults.horizontalFramingMargin,
    0,
    100
  )

  local reflectionQuality = tonumber(data.dynamicReflectionQuality)
  if reflectionQuality == nil and data.dynamicReflectionsEnabled ~= nil then
    reflectionQuality = data.dynamicReflectionsEnabled and 3 or 0
  end
  if tonumber(data.reflectionQualitySerializationVersion) ~= reflectionQualitySerializationVersion
    and reflectionQuality ~= nil
  then
    reflectionQuality = reflectionQuality <= 0
      and ultraReflectionQuality
      or reflectionQuality - 1
  end
  ctrls.dynamicReflectionQuality[0] = clamp(reflectionQuality or defaults.dynamicReflectionQuality, 0, #dynamicReflectionQualities - 1)
  ctrls.lowBeamsEnabled[0] = data.lowBeamsEnabled == true
  ctrls.settleDelay[0] = clamp(tonumber(data.settleDelay) or defaults.settleDelay, 0, 10)
  ctrls.freezePhysics[0] = data.freezePhysics ~= false
  ctrls.autoExposure[0] = data.autoExposure == true
  ctrls.manualExposure[0] = clamp(tonumber(data.manualExposure) or defaults.manualExposure, -20, 20)
  ctrls.useFramingMargins[0] = data.useFramingMargins ~= false
  ctrls.cameraOverlayEnabled[0] = data.cameraOverlayEnabled ~= false
  ctrls.includeMarginInScreenshot[0] = data.includeMarginInScreenshot == true
  ctrls.selectedMargin[0] = clamp(tonumber(data.selectedMargin or data.selectedCameraOverlayMargin) or safeMargins.defaultTargetIndex, 0, #safeMargins.targets - 1)
  ctrls.compositionOverlayEnabled[0] = data.compositionOverlayEnabled == true or data.cameraCompositionOverlayEnabled == true
  ctrls.framingBoundsDebugEnabled[0] = data.framingBoundsDebugEnabled == true
  ctrls.oobbDebugEnabled[0] = data.oobbDebugEnabled == true
  ctrls.framingInputsDebugEnabled[0] = data.framingInputsDebugEnabled == true
  ctrls.sample[0] = data.sample == true
  ctrls.comparison[0] = data.comparison == true
  ctrls.lightingRigEnabled[0] = data.lightingRigEnabled ~= false
  ctrls.exposureCorrection[0] = data.exposureCorrection ~= false
  if data.parkingMarkup ~= nil then ctrls.parkingMarkup[0] = data.parkingMarkup == true end
  ctrls.ssaoCaptureMode[0] = clamp(
    tonumber(data.ssaoCaptureMode) or defaults.ssaoCaptureMode,
    0,
    #ssaoCaptureModes - 1
  )
  local roleIntensity = type(data.lightRoleIntensity) == "table" and data.lightRoleIntensity or {}
  local roleShadows = type(data.lightRoleShadows) == "table" and data.lightRoleShadows or {}
  for _, role in ipairs(lightRoles) do
    ctrls.lightRoleIntensity[role.id][0] = clamp(
      tonumber(roleIntensity[role.id]) or defaults.lightRoleIntensity[role.id],
      0,
      4
    )
    if roleShadows[role.id] ~= nil then ctrls.lightRoleShadows[role.id][0] = roleShadows[role.id] == true end
  end
  if isInShowroom() then
    applyExposure()
    applyReflections()
  end
end

local function applyLowBeams(vehicle, enabled)
  enabled = enabled == nil and ctrls.lowBeamsEnabled[0] or enabled
  if vehicle and enabled then
    vehicle:queueLuaCommand("electrics.setLightsState(1)")
  end
end

local function onExtensionLoaded()
  resetToDefaults()
  applyEnvironment()
end

local function onClientPostStartMission()
  if not isInShowroom() then return end
  ctrls.dynamicReflectionQuality[0] = ultraReflectionQuality
  log("I", "screenshotCreator", "Showroom detected, forcing dynamic reflections to Ultra")
  applyEnvironment()
end

local function onExtensionUnloaded()
  if previewResolutionActive then
    local ok, err = pcall(setPreviewResolution, false)
    if not ok then
      log("E", "screenshotCreator", "Unable to restore preview resolution: " .. tostring(err))
    end
  end
  restoreEnvironment()
end

resetToDefaults()

M.getControls = function() return ctrls end
M.getOutputControls = function()
  return {
    outputDestination = ctrls.outputDestination,
    resolution = ctrls.resolution,
    imageResolution = ctrls.imageResolution,
    shippedConfigsOnly = ctrls.shippedConfigsOnly,
    keepAspectRatio = ctrls.keepAspectRatio,
    resolutionMultiplier = ctrls.resolutionMultiplier
  }
end
M.getRenderControls = function()
  return {
    superSampling = ctrls.superSampling,
    shippedConfigsOnly = ctrls.shippedConfigsOnly,
    fieldOfView = ctrls.fieldOfView,
    cameraHeight = ctrls.cameraHeight,
    dynamicReflectionQuality = ctrls.dynamicReflectionQuality,
    lowBeamsEnabled = ctrls.lowBeamsEnabled,
    settleDelay = ctrls.settleDelay,
    freezePhysics = ctrls.freezePhysics,
    autoExposure = ctrls.autoExposure,
    manualExposure = ctrls.manualExposure
  }
end
M.getDefaults = function() return deepcopy(defaults) end
M.getThumbnailConfig = function() return deepcopy(thumbnailConfig) end
M.getFramingDefaults = function() return deepcopy(framingDefaults) end
M.getOutputDestinations = function() return copyArray(outputDestinations) end
M.getResolutions = function() return deepcopy(resolutions) end
M.getSafeMargins = function() return deepcopy(safeMargins) end
M.getVehicleSafeMargin = function() return deepcopy(vehicleSafeMargin) end
M.getDynamicReflectionQualities = function() return copyArray(dynamicReflectionQualities) end
M.getThumbnailResolution = getThumbnailResolution
M.getCurrentResolution = getCurrentResolution
M.setImageResolution = setImageResolution
M.getMarginTarget = getMarginTarget
M.addVehicleMargin = addVehicleMargin
M.scaleMargin = scaleMargin
M.getFramingMargin = getFramingMargin
M.getFramingContext = getFramingContext
M.getCaptureContext = getCaptureContext
M.getJobSettings = getJobSettings
M.getLightingRig = getLightingRig
M.drawLightingControls = drawLightingControls
M.isDefaultConfig = isDefaultConfig
M.isThumbnailConfigGood = isThumbnailConfigGood
M.resetToDefaults = resetToDefaults
M.drawOutputControls = drawOutputControls
M.drawOutput = drawOutputControls
M.drawOverlayControls = drawOverlayControls
M.drawCameraOverlay = drawCameraOverlay
M.drawOverlays = drawCameraOverlay
M.setPreviewResolution = setPreviewResolution
M.applyExposure = applyExposure
M.applyReflections = applyReflections
M.applyLicensePlates = applyLicensePlates
M.applyEnvironment = applyEnvironment
M.getEnvironmentSnapshot = getEnvironmentSnapshot
M.applyEnvironmentSnapshot = applyEnvironmentSnapshot
M.restoreEnvironment = restoreEnvironment
M.beginWork = beginWork
M.finishWork = finishWork
M.applyLowBeams = applyLowBeams
M.serialize = serialize
M.deserialize = deserialize
M.onSerialize = serialize
M.onDeserialized = deserialize
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onExtensionUnloaded
M.onExit = onExtensionUnloaded
M.onClientPostStartMission = onClientPostStartMission

return M
