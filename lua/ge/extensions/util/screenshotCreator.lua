-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local im = ui_imgui
local imguiUtils = require('ui/imguiUtils')
local vehicleActionMaps = {"VehicleCommonActionMap", "VehicleSpecificActionMap"}

M.dependencies = {"ui_imgui", "render_renderViews"}
M.state = {show= false}

local cameraConfigFile

-- Of the currently spawned vehicle
local currConfigName
local currModelName

-- helper variables
local columnFlags = bit.bor(im.TableColumnFlags_NoResize, im.TableColumnFlags_WidthStretch)
local tableFlags = bit.bor(im.TableFlags_NoBordersInBody, im.TableFlags_SizingStretchProp)
local imVec24x24 = im.ImVec2(24,24)
local imVec32x32 = im.ImVec2(32, 32)
local imVec4Yellow = im.ImVec4(1,1,0,1)
local imVec4Red = im.ImVec4(1,0,0,1)
local imVec4Green = im.ImVec4(0,1,0,1)

local workerCoroutine = nil
local forceQuit = false

local windowOpen = im.BoolPtr(false)
local initialWindowSize = im.ImVec2(300, 500)
local runDone = false
local plRes

local vehList -- table array  {vehFolder, boolptr, nameStr, config number?}

local userDefinedDynamicReflections -- used to revert "GraphicDynReflectionEnabled" back to what the user had
local userDefinedSkipLicensePlates

local thumbnailConfig = {
  fileEnding = ".jpg",
  fov = 20,
  nearPlane = 0.1,
}
local framingCameraAxisDownOffset = 0.10

local presetOutputDestinations = {
  "Vehicle thumbnails",
  "Screenshot/showroom folder"
}

local presetResolutions = { -- name, width, height
  {'thumbnail', 500, 281},
  {'thumbnail temp', 2000, 1124},
  {'720p'   ,  1280, 720},
  {'1080p'  , 1920, 1080},
  {'Square' , 1920, 1920},
  {'WQHD'   , 2560, 1440},
  {'UWQHD'  , 3440, 1440},
  {'4k'     , 3840, 2160},
  {'8k'     , 8192, 4320},
}

local thumbnailSafeMargins = {
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
local vehicleSafeMargin = {top = 12, right = 12, left = 5, bottom = 1}

local thumbnailDefaultValues = { -- default values for imgui controls
  ouputDestination = 1, -- "Vehicle thumbnails"
  resolution = 2, -- "500 * 281"
  dynamicReflectionsEnabled = false,
  lowBeamsEnabled = false
}

local reviewData

local ctrls = { -- imgui controls
  generateMissingThumbnailsOnly = im.BoolPtr(false),
  reloadUIOnJobFinished = im.BoolPtr(true),
  camSpeedPtr = im.FloatPtr(core_camera.getSpeed()),
  drivingEnabled = true,
  uiToggled = true,
  cameraOverlayEnabled = im.BoolPtr(true),
  includeMarginInScreenshot = im.BoolPtr(false),
  selectedCameraOverlayMarginPtr = im.IntPtr(thumbnailSafeMargins.defaultTargetIndex),
  cameraCompositionOverlayEnabled = im.BoolPtr(false),
  framingBoundsDebugEnabled = im.BoolPtr(false),
  framingInputsDebugEnabled = im.BoolPtr(false),
  skipCustomCameras = im.BoolPtr(false),
  useFramingMargins = im.BoolPtr(true),
  resolutionToggled = false,
  keepAspectRatio = im.BoolPtr(false),
  multiplyRes = im.FloatPtr(2),
  dynamicReflectionsEnabled = im.BoolPtr(thumbnailDefaultValues.dynamicReflectionsEnabled),
  lowBeamsEnabled = im.BoolPtr(thumbnailDefaultValues.lowBeamsEnabled)
}

-- check if current settings are the same as the defaults ones
local function isDefaultConfig()
  return ctrls.currOuputDestinationPtr[0] == thumbnailDefaultValues.ouputDestination -1
    and ctrls.currResolutionsPtr[0] == thumbnailDefaultValues.resolution - 1
    and ctrls.dynamicReflectionsEnabled[0] == thumbnailDefaultValues.dynamicReflectionsEnabled
    and ctrls.lowBeamsEnabled[0] == thumbnailDefaultValues.lowBeamsEnabled
end

-- check if the user wants to update the vehicles thumbnails, if the current settings match the default thumbnail settings
local function isThumbnailConfigGood()
  return not(presetOutputDestinations[ctrls.currOuputDestinationPtr[0]+1] == "Vehicle thumbnails"
  and ctrls.currResolutionsPtr[0] + 1 ~= thumbnailDefaultValues.resolution)
end

local function isInShowroom()
  return getCurrentLevelIdentifier() == "showroom_v2"
end

local function sanitizeVehConfigName(dirtyName)
  return string.match(dirtyName, "([^/]+)%.pc$")
end

local function trySetDynamicReflections(value)
  if isInShowroom() then
    settings.setValue('GraphicDynReflectionEnabled', value)
  end
end

local function trySetGeneratePlates(value)
  if isInShowroom() then
    settings.setValue('SkipGenerateLicencePlate', value)
  end
end

local function setLowBeams(veh, enabled)
  if veh and enabled then
    veh:queueLuaCommand("electrics.setLightsState(1)")
  end
end

local function populateVehGui()
  vehList = {}
  local models = core_vehicles.getModelList().models --because
  local modelKeys={}
  for k,_ in pairs(models) do table.insert(modelKeys,k) end
  table.sort(modelKeys)
  for _,k in ipairs(modelKeys) do
    local v = models[k]
    vehList[_] = {k,im.BoolPtr(false), (v.Brand and (v.Brand.." ") or "") ..v.Name }
  end
  table.sort(vehList, function(a,b) return a[3]<b[3] end )
end

local function getSelectedVehCount()
  if not vehList then populateVehGui() end
  local count = 0
  for k, v in pairs(vehList) do
    if v[2][0] then
      count = count + 1
    end
  end
  return count
end

local function isBatch()
  local cmdArgs = Engine.getStartingArgs()
  local probability = 0
  for i = 1, #cmdArgs do
    local arg = cmdArgs[i]
    arg = arg:stripchars('"')
    if arg == "-onLevelLoad_ext" or arg == "'util/createThumbnails'" then
      probability = probability +1
    end
  end
  return probability > 1
end

local function yieldSec(yieldfn,sec)
  local start  = os.clock()
  while (start+sec)>os.clock() do
    yieldfn()
  end
end

local function onPreRender(dt)
  if workerCoroutine ~= nil then
    local errorfree, value = coroutine.resume(workerCoroutine)
    if not errorfree then
      log('E', '', "workerCoroutine: "..value)
      log("E", '', debug.traceback(workerCoroutine))
    end
    if coroutine.status(workerCoroutine) == "dead" then
      workerCoroutine = nil
      if isBatch() then
        log('E', '', 'coroutine BROKE')
        shutdown(0)
      end
    end
  end
end

local function resolveThumbnailMarginTarget(margin)
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

  for _, target in ipairs(thumbnailSafeMargins.targets) do
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

local function getThumbnailMarginTarget(index)
  return resolveThumbnailMarginTarget(thumbnailSafeMargins.targets[(index or thumbnailSafeMargins.defaultTargetIndex) + 1])
    or resolveThumbnailMarginTarget(thumbnailSafeMargins.targets[thumbnailSafeMargins.defaultTargetIndex + 1])
end

local function addVehicleSafeMargin(margin)
  if not margin then return nil end
  return {
    name = margin.name,
    left = margin.left + vehicleSafeMargin.left,
    right = margin.right + vehicleSafeMargin.right,
    top = margin.top + vehicleSafeMargin.top,
    bottom = margin.bottom + vehicleSafeMargin.bottom,
    extraBottom = margin.extraBottom,
    color = margin.color
  }
end


local function applyCameraRotationToFramingData(framingData, camRot)
  framingData.camRot = camRot
  framingData.camRight = camRot * vec3(1,0,0)
  framingData.camForward = camRot * vec3(0,1,0)
  framingData.camUp = camRot * vec3(0,0,1)
end

local function getVehicleFramingData(veh)
  local bb = veh:getSpawnWorldOOBB()
  local bbCenter = bb:getCenter()
  local axis0, axis1, axis2 = bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)
  local halfExtents = bb:getHalfExtents()

  local camOffsetAxisLocal = vec3(-0.75, -0.66, 0.07):normalized()
  local camOffsetAxis = (axis0 * camOffsetAxisLocal.x + axis1 * camOffsetAxisLocal.y + axis2 * camOffsetAxisLocal.z):normalized()
  local camAxisCenter = bbCenter - axis2 * framingCameraAxisDownOffset
  local lookAtPoint = camAxisCenter - (axis1 * halfExtents.y / 8)
  local camRot = quatFromDir(-camOffsetAxis, axis2)

  local allNodes = {}
  for i = 0, veh:getNodeCount() - 1 do
    local node = veh:getNodePosition(i)
    table.insert(allNodes, node)
  end

  local maxNodesPerExtent = 100
  local skippedExtremeNodesPerExtent = 0
  -- for every axis, get the nodes with the most extent in both directions
  local extentNodes = {}
  for i, axis in ipairs({axis0, axis1, axis2}) do
    local maxNodes = {}
    local minNodes = {}
    for _, node in ipairs(allNodes) do
      local extent = node:dot(axis)
      table.insert(maxNodes, {extent = extent, node = node})
      table.insert(minNodes, {extent = extent, node = node})
    end

    table.sort(maxNodes, function(a, b) return a.extent > b.extent end)
    table.sort(minNodes, function(a, b) return a.extent < b.extent end)

    local maxCount = math.min(maxNodesPerExtent + skippedExtremeNodesPerExtent, #maxNodes)
    local minCount = math.min(maxNodesPerExtent + skippedExtremeNodesPerExtent, #minNodes)
    for nodeIndex = skippedExtremeNodesPerExtent + 1, maxCount do
      table.insert(extentNodes, {axis = axis, node = maxNodes[nodeIndex].node + veh:getPosition(), index = i})
    end
    for nodeIndex = skippedExtremeNodesPerExtent + 1, minCount do
      table.insert(extentNodes, {axis = axis, node = minNodes[nodeIndex].node + veh:getPosition(), index = i})
    end
  end

  local framingPoints = {}

  local function addExtentFramingPoints(point)
    if not point then return end
    table.insert(framingPoints, {name = "extent", point = point, color = {0.2, 0.8, 1}})
  end

  for _, extentNode in ipairs(extentNodes) do
    addExtentFramingPoints(extentNode.node)
  end

  local framingData = {
    bb = bb,
    center = bbCenter,
    camAxisCenter = camAxisCenter,
    axis0 = axis0,
    axis1 = axis1,
    axis2 = axis2,
    halfExtents = halfExtents,
    camOffsetAxis = camOffsetAxis,
    lookAtPoint = lookAtPoint,
    framingPoints = framingPoints,
  }
  applyCameraRotationToFramingData(framingData, camRot)
  return framingData
end

local function getFramingMargin(resolution)
  if ctrls.useFramingMargins[0] and resolution and resolution[1] == thumbnailSafeMargins.width and resolution[2] == thumbnailSafeMargins.height then
    return addVehicleSafeMargin(getThumbnailMarginTarget(ctrls.selectedCameraOverlayMarginPtr and ctrls.selectedCameraOverlayMarginPtr[0]))
  end
  return {left = 0, right = 0, top = 0, bottom = 0, extraBottom = 0}
end

local function getFramingProjectionBounds(fov, aspectRatio, resolution, margin)
  local width = resolution and resolution[1] or thumbnailSafeMargins.width
  local height = resolution and resolution[2] or thumbnailSafeMargins.height
  local halfVerticalTan = math.tan((fov / 180 * math.pi) / 2)
  local halfHorizontalTan = halfVerticalTan * aspectRatio

  margin = margin or {left = 0, right = 0, top = 0, bottom = 0}
  return {
    xMin = ((margin.left / width) * 2 - 1) * halfHorizontalTan,
    xMax = (((width - margin.right) / width) * 2 - 1) * halfHorizontalTan,
    yMin = ((margin.bottom / height) * 2 - 1) * halfVerticalTan,
    yMax = (1 - (margin.top / height) * 2) * halfVerticalTan,
  }
end

local function projectFramingPoint(framingData, point)
  local toPoint = point - framingData.lookAtPoint
  return {
    right = toPoint:dot(framingData.camRight),
    up = toPoint:dot(framingData.camUp),
    forward = toPoint:dot(framingData.camForward)
  }
end

local function getFitIntervalsAtDistance(framingData, bounds, distance, nearPlane)
  local xMin, xMax = -math.huge, math.huge
  local yMin, yMax = -math.huge, math.huge

  for _, framingPoint in ipairs(framingData.framingPoints) do
    local projected = framingPoint.projected or projectFramingPoint(framingData, framingPoint.point)
    framingPoint.projected = projected

    local depth = projected.forward + distance
    if depth <= nearPlane then
      return nil
    end

    local pointXMin = projected.right - bounds.xMax * depth
    local pointXMax = projected.right - bounds.xMin * depth
    local pointYMin = projected.up - bounds.yMax * depth
    local pointYMax = projected.up - bounds.yMin * depth

    xMin = math.max(xMin, pointXMin)
    xMax = math.min(xMax, pointXMax)
    yMin = math.max(yMin, pointYMin)
    yMax = math.min(yMax, pointYMax)

    if xMin > xMax or yMin > yMax then
      return nil
    end
  end

  return {xMin = xMin, xMax = xMax, yMin = yMin, yMax = yMax}
end

local function solveCameraFit(framingData, bounds, nearPlane)
  local minForward = math.huge
  for _, framingPoint in ipairs(framingData.framingPoints) do
    local projected = projectFramingPoint(framingData, framingPoint.point)
    framingPoint.projected = projected
    minForward = math.min(minForward, projected.forward)
  end

  local lowDistance = math.max(nearPlane - minForward + 0.01, 0.01)
  local highDistance = math.max(lowDistance, framingData.halfExtents:length() * 2, 1)
  local intervals = getFitIntervalsAtDistance(framingData, bounds, highDistance, nearPlane)
  local maxDistance = math.max(highDistance * 128, 1000)

  while not intervals and highDistance < maxDistance do
    lowDistance = highDistance
    highDistance = highDistance * 2
    intervals = getFitIntervalsAtDistance(framingData, bounds, highDistance, nearPlane)
  end

  if not intervals then
    return nil
  end

  for _ = 1, 32 do
    local testDistance = (lowDistance + highDistance) * 0.5
    local testIntervals = getFitIntervalsAtDistance(framingData, bounds, testDistance, nearPlane)
    if testIntervals then
      highDistance = testDistance
      intervals = testIntervals
    else
      lowDistance = testDistance
    end
  end

  intervals = getFitIntervalsAtDistance(framingData, bounds, highDistance, nearPlane) or intervals

  local preferredX = -((bounds.xMin + bounds.xMax) * 0.5) * highDistance
  local preferredY = -((bounds.yMin + bounds.yMax) * 0.5) * highDistance
  local offsetX = clamp(preferredX, intervals.xMin, intervals.xMax)
  local offsetY = clamp(preferredY, intervals.yMin, intervals.yMax)

  return {
    distance = highDistance,
    offsetX = offsetX,
    offsetY = offsetY,
    intervals = intervals
  }
end

local function getProjectedClearance(framingPoint, camPos, framingData, fov, aspectRatio, resolution, margin)
  local toPoint = framingPoint.point - camPos
  local depth = toPoint:dot(framingData.camForward)
  if depth <= 0 then return nil end

  local halfHeight = math.tan((fov / 180 * math.pi) / 2) * depth
  local halfWidth = halfHeight * aspectRatio
  if halfWidth <= 0 or halfHeight <= 0 then return nil end

  local screenX = ((toPoint:dot(framingData.camRight) / halfWidth) + 1) * 0.5 * resolution[1]
  local screenY = (1 - (toPoint:dot(framingData.camUp) / halfHeight)) * 0.5 * resolution[2]
  local clearances = {
    {side = "left", value = screenX - margin.left},
    {side = "right", value = resolution[1] - margin.right - screenX},
    {side = "top", value = screenY - margin.top},
    {side = "bottom", value = resolution[2] - margin.bottom - screenY},
  }
  local closest = clearances[1]
  for i = 2, #clearances do
    if clearances[i].value < closest.value then
      closest = clearances[i]
    end
  end
  return closest, screenX, screenY, depth
end

local function frameVehicleWithRotation(veh, camRot, fov, nearPlane, aspectRatio, resolution)
  nearPlane = nearPlane or 0.1

  local framingData = getVehicleFramingData(veh)
  if camRot then
    applyCameraRotationToFramingData(framingData, camRot)
  end

  local margin = getFramingMargin(resolution)
  local bounds = getFramingProjectionBounds(fov, aspectRatio, resolution, margin)
  local fit = solveCameraFit(framingData, bounds, nearPlane)
  local boundBy = "fallback"
  local finalCamPos

  if fit then
    finalCamPos = framingData.lookAtPoint - framingData.camForward * fit.distance + framingData.camRight * fit.offsetX + framingData.camUp * fit.offsetY
  else
    fit = {
      distance = math.max(1, framingData.halfExtents:length() * 2),
      offsetX = 0,
      offsetY = 0
    }
    finalCamPos = framingData.lookAtPoint - framingData.camForward * fit.distance
  end

  if resolution and resolution[1] and resolution[2] and resolution[2] ~= 0 then
    for _, framingPoint in ipairs(framingData.framingPoints) do
      local closest, screenX, screenY, depth = getProjectedClearance(framingPoint, finalCamPos, framingData, fov, aspectRatio, resolution, margin)
      if closest then
        framingPoint.marginDistance = closest.value
        framingPoint.marginDistanceSide = closest.side
        framingPoint.screenX = screenX
        framingPoint.screenY = screenY
        framingPoint.framingDistance = depth
      end
    end
  end

  local lowestClearancePoint
  for _, framingPoint in ipairs(framingData.framingPoints) do
    if framingPoint.marginDistance and (not lowestClearancePoint or framingPoint.marginDistance < lowestClearancePoint.marginDistance) then
      lowestClearancePoint = framingPoint
    end
  end
  if lowestClearancePoint then
    boundBy = lowestClearancePoint.marginDistanceSide or boundBy
  end

  framingData.finalCamPos = finalCamPos
  framingData.finalCamRot = framingData.camRot
  framingData.boundBy = boundBy
  framingData.fit = fit

  --if boundBy then
    --local modelName = tostring(veh.jbeam or veh.JBeam or "unknown")
    --local resolutionKey = resolution and (tostring(resolution[1]) .. "x" .. tostring(resolution[2])) or "unknown"
    --log("I", "screenshotCreator", string.format("frameVehicle: best fit %s (%s) for %s at %s, distance=%.2fm, offset=(%.2f, %.2f), margin=%.0fpx %s", boundPointName or boundBy, boundBy, modelName, resolutionKey, fit.distance or 0, fit.offsetX or 0, fit.offsetY or 0, (boundSourcePoint and boundSourcePoint.marginDistance) or 0, (boundSourcePoint and boundSourcePoint.marginDistanceSide) or ""))
  --end

  return finalCamPos, framingData.camRot, framingData
end

local function frameVehicle(veh, fov, nearPlane, aspectRatio, resolution)
  return frameVehicleWithRotation(veh, nil, fov, nearPlane, aspectRatio, resolution)
end

local function getListOfSelectedModels()
  if not vehList then populateVehGui() end
  local models = {}
  -- Add the selection
  for k, v in pairs(vehList) do
    if v[2][0] then
      table.insert(models, v[1])
    end
  end

  -- If no selection, then add the player's model by default
  if not models[1] then
    models = {getPlayerVehicle(0).JBeam}
  end

  return models
end

local function loadCameraConfig()
  cameraConfigFile = jsonReadFile("/settings/thumbnailCameraConfig.json")
  if not cameraConfigFile or not next(cameraConfigFile) then
    cameraConfigFile = {
      vehModels = {},
      vehConfigs = {}
    }
  end
end

local function saveCameraConfig()
  jsonWriteFile("/settings/thumbnailCameraConfig.json", cameraConfigFile, true)
end

local function getThumbnailResolution()
  local thumbnailPreset = presetResolutions[thumbnailDefaultValues.resolution - 1]
  return {thumbnailPreset[2], thumbnailPreset[3]}
end

local function getCurrentResolution()
  if not windowOpen[0] then
    return getThumbnailResolution()
  else
    local presetRes = presetResolutions[ctrls.currResolutionsPtr[0]]
    if not presetRes then -- if we are not using a preset, ie, if we are a custom res
      return {ctrls.imageResolution[0], ctrls.imageResolution[1]}
    else
      return {presetRes[2], presetRes[3]}
    end
  end
end

local function getCameraConfig(modelName, configName)
  if not cameraConfigFile then loadCameraConfig() end

  local cameraConfigs = {}
  if not cameraConfigFile.vehConfigs[modelName.."/"..configName] then
    cameraConfigFile.vehConfigs[modelName.."/"..configName] = {
      configCamEnabled = false,
      modelCamEnabled = false
    }
  end
  cameraConfigs.vehCamConfig = cameraConfigFile.vehConfigs[modelName.."/"..configName]

  if cameraConfigFile.vehModels[modelName] then
    cameraConfigs.modelCamConfig = cameraConfigFile.vehModels[modelName]
  end
  return cameraConfigs
end

local function getCameraOffsets()
  -- get the unit vectors for vehicle coordinate system
  local veh = getPlayerVehicle(0)
  local bb = veh:getSpawnWorldOOBB()
  local x, y, z  = bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)

  -- get vector from vehicle to camera
  local vehToCam = core_camera.getPosition() - veh:getPosition()

  -- un-rotate the camera rotation (remove vehicle rotation)
  local vehicleRotation = quatFromDir(bb:getAxis(1),  bb:getAxis(2))
  local vehicleRotationInverse = vehicleRotation:inversed()

  local unRotatedCamRotation = core_camera.getQuat() * vehicleRotationInverse

  -- split that offset into components using the vehicle unit vectors
  local xOff = x:dot(vehToCam)
  local yOff = y:dot(vehToCam)
  local zOff = z:dot(vehToCam)
  local offset = vec3(xOff, yOff, zOff)

  return offset, unRotatedCamRotation
end

local function rewindCameraOffsets(posOffset, rotOffset)
  local veh = getPlayerVehicle(0)
  local bb = veh:getSpawnWorldOOBB()
  local x, y, z  = bb:getAxis(0), bb:getAxis(1), bb:getAxis(2)

  local offset = x * posOffset.x + y*posOffset.y + z*posOffset.z
  local finalPos = offset+veh:getPosition()

  -- rotate the camera rotation by the car rotation
  local vehicleRotation = quatFromDir(bb:getAxis(1),  bb:getAxis(2))
  local finalRot = rotOffset * vehicleRotation

  return finalPos, finalRot
end


local function getFinalCameraPosAndRotForVehicle(vehicle, configName)
  local cameraConfigs = getCameraConfig(vehicle.jbeam, configName)
  local p, r

  if not ctrls.skipCustomCameras[0] and cameraConfigs.vehCamConfig then
    if cameraConfigs.vehCamConfig.configCamEnabled then
      p, r = rewindCameraOffsets(cameraConfigs.vehCamConfig.cameraConfig.posOffset, cameraConfigs.vehCamConfig.cameraConfig.rotOffset)
      return p, r, "config camera"
    elseif cameraConfigs.vehCamConfig.modelCamEnabled then
      p, r = rewindCameraOffsets(cameraConfigs.modelCamConfig.cameraConfig.posOffset, cameraConfigs.modelCamConfig.cameraConfig.rotOffset)
      return p, r, "model camera"
    end
  end

  local currRes = getCurrentResolution()
  p, r = frameVehicle(vehicle, thumbnailConfig.fov, thumbnailConfig.nearPlane, currRes[1] / currRes[2], currRes)
  return p, r, "procedural camera"
end

local function takeThumbnailScreenshot(filepath, camera, callback, uniqueId)
  if type(filepath) ~= "string" or filepath == "" or type(camera) ~= "table" then
    if callback then callback() end
    return
  end
  if not camera.pos or not camera.rot then
    log('W', 'thumbnail', 'takeThumbnailScreenshot: missing camera pos or rot')
    if callback then callback() end
    return
  end

  local currRes = getCurrentResolution()
  local ss = ctrls.superSamplingPtr and ctrls.superSamplingPtr[0] or 4.0
  local ssResX = math.floor(currRes[1] * ss)
  local ssResY = math.floor(currRes[2] * ss)

  local renderViewName = "thumbnail"
  if uniqueId ~= nil then
    renderViewName = renderViewName .. tostring(uniqueId)
  end
  local renderViewOptions = {
    renderViewName = renderViewName,
    screenshotDelay = camera.screenshotDelay or 0,
    resolution = vec3(ssResX, ssResY, 0), -- render bigger
    downscaleFactor = ss,
    copyMainViewExposure = true,
    rot = camera.rot,
    pos = camera.pos,
    fov = camera.fov or thumbnailConfig.fov,
    nearPlane = camera.nearPlane or thumbnailConfig.nearPlane,
    filename = filepath
  }

  log('I', '', "Saved screenshot:" .. renderViewOptions.filename)
  render_renderViews.takeScreenshot(renderViewOptions, callback)
end

local function takeThumbnail(options)
  local screenshotDone = false
  local screenshotSuccess = false
  local vehicle = options.vehicle
  local camPos, camRot, camName = getFinalCameraPosAndRotForVehicle(vehicle, options.configName)

  --core_camera.setByName(0, "free")
  --core_camera.setPosRot(0, camPos.x, camPos.y, camPos.z, camRot.x, camRot.y, camRot.z, camRot.w)
  --core_camera.setFOV(0, thumbnailConfig.fov)
  coroutine.yield()

  takeThumbnailScreenshot(options.filepath, {
    pos = camPos,
    rot = camRot,
  }, function(success)
    screenshotDone = true
    screenshotSuccess = success == true
    if screenshotSuccess then
      -- update vehicle selector so the new thumbnail is shown
      ui_vehicleSelector_general.clearCache()
    end
  end, vehicle:getId())

  local screenshotWaitStart = os.clock()
  while not screenshotDone and (os.clock() - screenshotWaitStart) < 5 do
    coroutine.yield()
  end
  if not screenshotDone then
    log('W', 'thumbnail', 'Timed out waiting for screenshot callback: ' .. tostring(options.filepath))
  end
  if not screenshotSuccess then
    log('E', 'thumbnail', 'Stopping thumbnail generation after failed capture: ' .. tostring(options.filepath))
    forceQuit = true
    return camName, false
  end

  if not FS:fileExists(options.filepath) then
    local fileWaitStart = os.clock()
    while not FS:fileExists(options.filepath) and (os.clock() - fileWaitStart) < 2 do
      coroutine.yield()
    end
  end


  if options.isDefaultConfig then
    local src = options.filepath
    local dst = 'vehicles/' .. options.modelKey .. '/default' .. thumbnailConfig.fileEnding

    if FS:fileExists(src) then
      FS:copyFile(src, dst)
      log('I', 'thumbnail', 'Copied default thumbnail: ' .. dst)
    else
      log('W', 'thumbnail', 'Source thumbnail missing, cannot copy default: ' .. src)
    end
  end
  return camName, true
end

local function startWork(workOptions)
  -- Sanitizing workOptions
  if not workOptions or type(workOptions) ~= 'table' then
    workOptions = {
      selection = "selectedModels", -- "selectedModels" or currConfigName
      onlyMissingThumbnails = false,
    }
  end
  if not workOptions.selection then workOptions.selection = "selectedModels" end
  workOptions.lowBeamsEnabled = workOptions.lowBeamsEnabled == true

  if workerCoroutine then
    log('E', "startWork", "coroutine already exist")
    return false
  end

  -- reset reviewData for each run
  reviewData = {
    onlyMissingThumbnails = workOptions.onlyMissingThumbnails,
    lowBeamsEnabled = workOptions.lowBeamsEnabled,
    selection = workOptions.selection,
    configs = {}
  }

  -- main thing
  workerCoroutine = coroutine.create(function()
    log('I', '', "Starting thumbnail work coroutine")
    trySetDynamicReflections(ctrls.dynamicReflectionsEnabled[0])
    trySetGeneratePlates(true)

    local listOfSelectedModels = getListOfSelectedModels()

    forceQuit = false

    be:setPhysicsSpeedFactor(2)

    local inititialPos = getPlayerVehicle(0):getPosition()

    if workOptions.selection == "selectedModels" then -- take thumbnails of the selected models
      for _, modelName in pairs(listOfSelectedModels) do
        for _, configData in pairs(core_vehicles.getModel(modelName).configs) do
          if forceQuit then
            be:setPhysicsSpeedFactor(0)
            return
          end

          -- generate the thumbnail filename
          local folder = "vehicles/"
          local vehName = configData.model_key .. "/" .. configData.key

          if windowOpen[0] and ctrls.currOuputDestinationPtr[0] == 1 then
            folder = "screenshots/showroom/"
          end
          local filepath = folder .. vehName ..thumbnailConfig.fileEnding

          local skip = workOptions.onlyMissingThumbnails and windowOpen[0] and ctrls.currOuputDestinationPtr[0] == 0 and FS:fileExists(filepath)

          local camName
          local status
          if not skip then -- replace vehicle
            core_vehicles.replaceVehicle(configData.model_key, { config = configData.key, licenseText = "BeamNG"})
            yieldSec(coroutine.yield, 0.7)
            -- attempt keeping vehicle in place
            local newVehicle = getPlayerVehicle(0)
            if inititialPos then
              log("D", "startWork", 'Teleporting vehicle to initial location')
              spawn.safeTeleport(newVehicle, inititialPos, quatFromDir(newVehicle:getDirectionVector()))
            else
              log("D", "startWork", 'Initial location is missing')
            end

            yieldSec(coroutine.yield, 1.7)

            newVehicle:queueLuaCommand("input.event('parkingbrake', 1, 1)")
            newVehicle:queueLuaCommand("input.event('throttle', 0, 2)")
            newVehicle:queueLuaCommand("controller.mainController.setEngineIgnition(false)")
            setLowBeams(newVehicle, workOptions.lowBeamsEnabled)
            if workOptions.lowBeamsEnabled then
              yieldSec(coroutine.yield, 0.2)
            end

            local screenshotSuccess
            camName, screenshotSuccess = takeThumbnail(
              {
                vehicle = newVehicle,
                configName = currConfigName,
                filepath = filepath,
                modelKey = configData.model_key,
                isDefaultConfig = configData.is_default_config
              }
            )
            status = screenshotSuccess and "done" or "failed"
          else
            status = "skipped"
          end
          table.insert(reviewData.configs, {vehName = vehName, camName = camName, status = status, thumbnailPath = filepath})
        end
      end
    else -- take thumbnail of the current vehicle only
      local playerVehicle = getPlayerVehicle(0)
      local vehManager = extensions.core_vehicle_manager
      local playerVehicleData = vehManager.getPlayerVehicleData()
      local filepath = workOptions.outputPath
      if type(filepath) ~= "string" or filepath == "" then
        filepath = playerVehicleData.vehicleDirectory .. workOptions.selection..thumbnailConfig.fileEnding
      end
      local configName = workOptions.configName
      if type(configName) ~= "string" or configName == "" then
        configName = workOptions.selection
      end

      setLowBeams(playerVehicle, workOptions.lowBeamsEnabled)
      if workOptions.lowBeamsEnabled then
        yieldSec(coroutine.yield, 0.2)
      end

      local camName, screenshotSuccess = takeThumbnail({vehicle = playerVehicle, filepath = filepath, configName = configName})
      table.insert(reviewData.configs, {camName = camName, vehName = playerVehicleData.vehicleDirectory, status = screenshotSuccess and "done" or "failed", thumbnailPath = filepath})
    end

    be:setPhysicsSpeedFactor(0)

    -- when the job is finished
    runDone = true
    if type(workOptions.onDoneHook) == "string" and workOptions.onDoneHook ~= "" then
      guihooks.trigger(workOptions.onDoneHook, reviewData and reviewData.configs and reviewData.configs[#reviewData.configs] or {})
    end
    if type(workOptions.internalCompletionCallback) == "function" then
      local completedConfig = reviewData and reviewData.configs and reviewData.configs[#reviewData.configs] or nil
      workOptions.internalCompletionCallback(
        completedConfig and completedConfig.status == "done" or false,
        completedConfig and completedConfig.thumbnailPath or nil,
        workOptions.completionToken
      )
    end
    if windowOpen[0] and ctrls.reloadUIOnJobFinished[0] then
      reloadUI()
    end
  end)
  return true
end

local function selectPlayerVehicle()
  if not vehList then populateVehGui() end
  local playerVehicle = getPlayerVehicle(0)
  if playerVehicle then
    for _,v in ipairs(vehList) do
      v[2][0] = v[1] == playerVehicle.JBeam
    end
  else
    log("E", "selectCurVeh", "Failed to get current vehicle")
  end
end

local function resetToDefaultValues()
  ctrls.currOuputDestinationPtr = im.IntPtr(thumbnailDefaultValues.ouputDestination - 1)
  ctrls.currResolutionsPtr = im.IntPtr(thumbnailDefaultValues.resolution - 1)
  local currRes = getCurrentResolution()
  ctrls.imageResolution = im.ArrayInt(3)
  ctrls.imageResolution[0] = currRes[1]
  ctrls.imageResolution[1] = currRes[2]
  ctrls.dynamicReflectionsEnabled[0] = thumbnailDefaultValues.dynamicReflectionsEnabled
  ctrls.lowBeamsEnabled[0] = thumbnailDefaultValues.lowBeamsEnabled
end

local previousFov
local isCameraSet = true
local function setCamera(p, r)
  previousFov = core_camera.getFovDeg()
  core_camera.setByName(0, "free")
  core_camera.setPosRot(0, p.x, p.y, p.z, r.x, r.y, r.z, r.w)
  core_camera.setFOV(0, thumbnailConfig.fov)
  isCameraSet = true
end

local function resetCamera()
  core_camera.setByName(0, "orbit")
  core_camera.setFOV(0, previousFov or 60)
  isCameraSet = false
end

local function setDimHelper(w, h)
  local vm = GFXDevice.getVideoMode()
  if not plRes then
    plRes = {vm.width, vm.height}
  end
  if vm.width == w and vm.height == h and vm.displayMode == "Borderless" then
    -- nothing to change
    return
  end
  log('I', '', "requesting new video mode")
  vm.width = w
  vm.height = h
  vm.displayMode = "Borderless"
  GFXDevice.setVideoMode(vm)
end

local function drawCameraOverlay()
  if not ctrls.cameraOverlayEnabled[0] and not ctrls.cameraCompositionOverlayEnabled[0] then return end

  local currRes = getCurrentResolution()
  if not currRes[1] or not currRes[2] or currRes[2] == 0 then return end
  local isThumbnailResolution = currRes[1] == thumbnailSafeMargins.width and currRes[2] == thumbnailSafeMargins.height
  local showMargins = ctrls.cameraOverlayEnabled[0] and ctrls.currResolutionsPtr and ctrls.currResolutionsPtr[0] == 1 and isThumbnailResolution
  if not showMargins and not ctrls.cameraCompositionOverlayEnabled[0] then return end

  local pos = core_camera.getPosition()
  local rot = core_camera.getQuat()
  local dist = 1
  local aspectRatio = currRes[1] / currRes[2]
  local halfHeight = math.tan((thumbnailConfig.fov * math.pi / 180) / 2) * dist
  local halfWidth = halfHeight * aspectRatio

  local right = rot * vec3(1,0,0)
  local forward = rot * vec3(0,1,0)
  local up = rot * vec3(0,0,1)
  local center = pos + forward * dist

  local function planePoint(pixelX, pixelY)
    local x = -halfWidth + (pixelX / currRes[1]) * halfWidth * 2
    local y = halfHeight - (pixelY / currRes[2]) * halfHeight * 2
    return center + right * x + up * y
  end

  local function drawLine(x1, y1, x2, y2, color, lineWidth)
    debugDrawer:drawLineInstance(planePoint(x1, y1), planePoint(x2, y2), lineWidth or 3, color, false)
  end

  local function drawRect(left, top, right, bottom, color, lineWidth)
    drawLine(left, top, right, top, color, lineWidth)
    drawLine(right, top, right, bottom, color, lineWidth)
    drawLine(right, bottom, left, bottom, color, lineWidth)
    drawLine(left, bottom, left, top, color, lineWidth)
  end

  drawRect(0, 0, currRes[1], currRes[2], ColorF(1, 0, 0, 1))
  if showMargins then
    local margin = getThumbnailMarginTarget(ctrls.selectedCameraOverlayMarginPtr[0])
    if margin then
      local vehicleMargin = addVehicleSafeMargin(margin)
      drawRect(margin.left, margin.top, currRes[1] - margin.right, currRes[2] - margin.bottom, ColorF(0, 1, 0, 0.7), 3)
      drawLine(margin.left, currRes[2] - margin.extraBottom, currRes[1] - margin.right, currRes[2] - margin.extraBottom, ColorF(0, 1, 0, 0.45), 2)
      drawRect(vehicleMargin.left, vehicleMargin.top, currRes[1] - vehicleMargin.right, currRes[2] - vehicleMargin.bottom, ColorF(0.2, 0.45, 1, 0.75), 2)
    end
  end

  if ctrls.cameraCompositionOverlayEnabled[0] then
    local thirdColor = ColorF(0.3, 0.6, 1, 0.65)
    local centerColor = ColorF(1, 1, 1, 0.75)

    drawLine(currRes[1] / 3, 0, currRes[1] / 3, currRes[2], thirdColor)
    drawLine(currRes[1] * 2 / 3, 0, currRes[1] * 2 / 3, currRes[2], thirdColor)
    drawLine(0, currRes[2] / 3, currRes[1], currRes[2] / 3, thirdColor)
    drawLine(0, currRes[2] * 2 / 3, currRes[1], currRes[2] * 2 / 3, thirdColor)
    drawLine(currRes[1] / 2, 0, currRes[1] / 2, currRes[2], centerColor)
    drawLine(0, currRes[2] / 2, currRes[1], currRes[2] / 2, centerColor)
  end
end

local function drawVehicleFramingDebug()
  if not ctrls.framingBoundsDebugEnabled[0] and not ctrls.framingInputsDebugEnabled[0] then return end

  local veh = getPlayerVehicle(0)
  if not veh then return end

  local currRes = getCurrentResolution()
  local _, _, framingData = frameVehicle(veh, thumbnailConfig.fov, thumbnailConfig.nearPlane, currRes[1] / currRes[2], currRes)
  if ctrls.framingBoundsDebugEnabled[0] then
    local corners = {
      framingData.bb:getPoint(0),
      framingData.bb:getPoint(3),
      framingData.bb:getPoint(7),
      framingData.bb:getPoint(4),
      framingData.bb:getPoint(1),
      framingData.bb:getPoint(2),
      framingData.bb:getPoint(6),
      framingData.bb:getPoint(5)
    }
    local lineColor = ColorF(1, 0.5, 0, 0.5)

    debugDrawer:drawLineInstance(corners[1], corners[2], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[2], corners[3], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[3], corners[4], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[4], corners[1], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[5], corners[6], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[6], corners[7], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[7], corners[8], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[8], corners[5], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[1], corners[5], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[2], corners[6], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[3], corners[7], 2, lineColor, false)
    debugDrawer:drawLineInstance(corners[4], corners[8], 2, lineColor, false)
  end

  if ctrls.framingInputsDebugEnabled[0] then
    local center = framingData.center
    local camAxisCenter = framingData.camAxisCenter
    local axisLength = math.max(1, framingData.halfExtents:length())

    debugDrawer:drawSphere(center, 0.08, ColorF(1, 1, 1, 0.8))
    debugDrawer:drawSphere(camAxisCenter, 0.08, ColorF(1, 1, 0, 0.8))
    debugDrawer:drawSphere(framingData.lookAtPoint, 0.08, ColorF(0.1, 1, 0.1, 0.8))

    debugDrawer:drawLineInstance(center, center + framingData.axis0 * axisLength, 1, ColorF(1, 0, 0, 0.5), false)
    debugDrawer:drawLineInstance(center, center + framingData.axis1 * axisLength, 1, ColorF(0, 1, 0, 0.5), false)
    debugDrawer:drawLineInstance(center, center + framingData.axis2 * axisLength, 1, ColorF(0, 0.4, 1, 0.5), false)
    debugDrawer:drawLineInstance(camAxisCenter, camAxisCenter + framingData.camOffsetAxis * axisLength, 3, ColorF(1, 1, 0, 1), false)

    for _, framingPoint in ipairs(framingData.framingPoints) do
      local color = framingPoint.color or {0.2, 0.8, 1}
      debugDrawer:drawSphere(framingPoint.point, 0.035, ColorF(color[1], color[2], color[3], 0.8))
    end

    debugDrawer:drawTextAdvanced(center + vec3(0, 0, 0.5), String("OOBB center"), ColorF(1, 1, 1, 1), true, false, ColorI(0, 0, 0, 192))
    debugDrawer:drawTextAdvanced(camAxisCenter, String("camera axis center"), ColorF(1, 1, 0, 1), true, false, ColorI(0, 0, 0, 192))
    debugDrawer:drawTextAdvanced(framingData.lookAtPoint, String("camera target"), ColorF(0.1, 1, 0.1, 1), true, false, ColorI(0, 0, 0, 192))
  end
end

local lastFrameImageResolution = {}
local function onUpdate(dtReal, dtSim, dtRaw)
  if windowOpen[0] ~= true then return end
  if not editor or not editor.icons then return end

  local isRunning = workerCoroutine ~= nil

  im.SetNextWindowSize(initialWindowSize, im.Cond_FirstUseEver)

  if im.Begin("Vehicle Screenshot Creator (WIP)", windowOpen) then
    if not vehList then populateVehGui() end
    local partConfig = getPlayerVehicle(0).partConfig

    if not string.endswith(partConfig, ".pc") then
      im.Text("ERROR: Player vehicle does not originate from a part config file (.pc). Please choose a vehicle that does.")
      goto continue
    end

    currConfigName = sanitizeVehConfigName(partConfig)
    currModelName = getPlayerVehicle(0).jbeam

    -- we set the default values
    if not ctrls.currOuputDestinationPtr then
      resetToDefaultValues()
    end
    if not isRunning or ctrls.includeMarginInScreenshot[0] then
      drawCameraOverlay()
      drawVehicleFramingDebug()
    end

    if isRunning then
      if editor.uiIconImageButton(editor.icons.stop, imVec32x32, im.ImColorByRGB(0,255,0,255).Value, nil, nil) then
        forceQuit = true
      end
      if im.IsItemHovered() then im.BeginTooltip() im.Text("Stop") im.EndTooltip() end
    else
      if editor.uiIconImageButton(editor.icons.play_arrow, imVec32x32, im.ImColorByRGB(0,255,0,127).Value, nil, nil) then
        startWork({selection = "selectedModels", onlyMissingThumbnails = ctrls.generateMissingThumbnailsOnly[0], lowBeamsEnabled = ctrls.lowBeamsEnabled[0]})
      end
      if im.IsItemHovered() then im.BeginTooltip() im.Text("Run (".. getSelectedVehCount() .. ") selected models (See 'Selection'tab). If none are selected, player's vehicle model will run by default") im.EndTooltip() end

      im.SameLine()

      if editor.uiIconImageButton(editor.icons.play_arrow, imVec32x32, imVec4Yellow, nil, nil) then
        startWork({selection = currConfigName, lowBeamsEnabled = ctrls.lowBeamsEnabled[0]})
      end
      if im.IsItemHovered() then im.BeginTooltip() im.Text("Only update thumbnail of current config : '"..currConfigName .."' (Will not update the config itself!)") im.EndTooltip() end

      im.Checkbox("Generate missing thumbnails only", ctrls.generateMissingThumbnailsOnly)
      if im.IsItemHovered() then im.BeginTooltip() im.Text("Checks if the thumbnail file is missing. A blank/white thumbnail is not a missing thumbnail") im.EndTooltip() end
      im.SameLine()
      im.Checkbox("Reload UI when run is finished", ctrls.reloadUIOnJobFinished)
      if im.IsItemHovered() then im.BeginTooltip() im.Text("If not, opening the vehicle menu after updating the thumbnails, won't show the new thumbnails") im.EndTooltip() end

      im.Dummy(im.ImVec2(1, 5))
    end

    if isRunning then im.BeginDisabled() end
    if im.BeginTabBar("main Menu##") then
      if im.BeginTabItem('Output') then
        if isDefaultConfig() then
          im.BeginDisabled()
        end
        if editor.uiIconImageButton(editor.icons.undo, imVec32x32, nil, nil, nil) then
          resetToDefaultValues()
        end
        im.tooltip("Restore settings to thumbnail's")
        if isDefaultConfig() then
          im.EndDisabled()
        end

        -- this build the string from the presets to feed the Combo2
        local s = ""
        for _, r in ipairs(presetOutputDestinations) do
          s = s .. r .. '\0'
        end
        ctrls.outputDestinationsStr = s
        im.Combo2("Output destination", ctrls.currOuputDestinationPtr, ctrls.outputDestinationsStr)

        im.Dummy(im.ImVec2(1, 20))

        -- this build the string from the presets to feed the Combo2
        local s = 'custom\0'
        for _, r in ipairs(presetResolutions) do
          s = s .. r[1] .. ' - ' .. r[2] .. ' x ' .. r[3] .. '\0'
        end
        ctrls.presetResolutionsComboStr = s .. '\0'
        im.Combo2("Common Resolutions", ctrls.currResolutionsPtr, ctrls.presetResolutionsComboStr)

        -- make sure the final image resolution is updated
        if ctrls.currResolutionsPtr[0] > 0 then
          local preset = presetResolutions[ctrls.currResolutionsPtr[0]]
          ctrls.imageResolution[0] = preset[2]
          ctrls.imageResolution[1] = preset[3]
        end

        im.Checkbox("Keep aspect ratio on manual resolution change", ctrls.keepAspectRatio)

        local recalculate = false

        im.InputFloat("##mul", ctrls.multiplyRes)
        im.SameLine()
        if im.Button("Multiply current res") then
          if ctrls.multiplyRes[0] > 0 then
            ctrls.imageResolution[1] = ctrls.imageResolution[1] * ctrls.multiplyRes[0]
            ctrls.imageResolution[0] = ctrls.imageResolution[0] * ctrls.multiplyRes[0]

            recalculate = true
          end
        end

        if im.InputInt2("Final image resolution", ctrls.imageResolution, im.InputTextFlags_EnterReturnsTrue) then

          -- check if we want to keep the aspect ratio
          if ctrls.keepAspectRatio[0] then
            if lastFrameImageResolution[0] == ctrls.imageResolution[0] then
              local ratio = ctrls.imageResolution[1] / lastFrameImageResolution[1]
              ctrls.imageResolution[0] = lastFrameImageResolution[0] * ratio
            elseif lastFrameImageResolution[1] == ctrls.imageResolution[1] then
              local ratio = ctrls.imageResolution[0] / lastFrameImageResolution[0]
              ctrls.imageResolution[1] = lastFrameImageResolution[1] * ratio
            end
          end

          recalculate = true
        end


        if recalculate then
          local found = false
          -- check if custom resolution matches one of the presets, otherwise use custom
          for i, r in ipairs(presetResolutions) do
            if ctrls.currResolutionsPtr and ctrls.imageResolution[0] == r[2] and ctrls.imageResolution[1] == r[3] then
              ctrls.currResolutionsPtr[0] = i
              found = true
              break
            end
          end
          if not found then
            ctrls.currResolutionsPtr[0] = 0 -- custom
          end
        end

        if im.Button(ctrls.resolutionToggled and "Reset resolution" or "Preview resolution") then
          ctrls.resolutionToggled = not ctrls.resolutionToggled
          if ctrls.resolutionToggled then
            setDimHelper(ctrls.imageResolution[0], ctrls.imageResolution[1])
          else
            setDimHelper(plRes[1], plRes[2])
          end
        end
        im.SameLine()
        if im.Button("Toggle UI apps") then
          ctrls.uiToggled = not ctrls.uiToggled
          if ctrls.uiToggled then
            core_gamestate.setGameState('freeroam', 'freeroam', 'freeroam')
          else
            core_gamestate.setGameState('freeroam', {}, 'freeroam')
          end
        end
        if not isThumbnailConfigGood() then
          editor.uiIconImage(editor.icons.warning, imVec24x24, imVec4Yellow)
          im.SameLine()
          im.PushStyleColor2(im.Col_Text, imVec4Yellow)
          im.TextWrapped(string.format("Correct size for vehicles thumbnails are 500 * 281 and you have chosen %i * %i", getCurrentResolution()[1], getCurrentResolution()[2]))
          im.PopStyleColor()
        else
          im.Dummy(im.ImVec2(1, 20))
        end

        if not ctrls.superSamplingPtr then
          ctrls.superSamplingPtr = im.FloatPtr(4.0)
        end

        im.SliderFloat("Super Sampling", ctrls.superSamplingPtr, 1.0, 4.0, "%.2fx")

        im.Checkbox("Enable dynamic reflections", ctrls.dynamicReflectionsEnabled)
        im.Checkbox("Enable low beams", ctrls.lowBeamsEnabled)

        ----------------------------------------------------------------------------
        -- this is the same math as in the c++ side
        local s = ctrls.superSamplingPtr[0]
        local x = ctrls.imageResolution[0] * s
        local y = ctrls.imageResolution[1] * s
        x = math.floor(x)
        y = math.floor(y)

        im.Dummy(im.ImVec2(1, 20))

        im.TextUnformatted('Internal resolution: ' .. tostring(x) .. ' x ' .. tostring(y))
        im.TextUnformatted('Megapixel = ' .. string.format('%0.2f', x * y / 1000000))
        local rawSize = x * y * 3 -- RGB = 3 byte
        im.TextUnformatted('Raw image size = ' .. (bytes_to_string(rawSize)))
        im.TextUnformatted('Estimated JPG file size = ' .. (bytes_to_string(rawSize * 0.14)))

        im.EndTabItem()
      end
      if im.BeginTabItem("Debug") then
        im.Checkbox("Show margin overlay", ctrls.cameraOverlayEnabled)
        im.tooltip("Draws the thumbnail frame and target-specific safe margins using the current camera.")
        im.Checkbox("Include margin in screenshot", ctrls.includeMarginInScreenshot)
        im.tooltip("When enabled, debug margin lines remain visible while screenshots are being captured.")
        local marginOptions = ""
        for _, margin in ipairs(thumbnailSafeMargins.targets) do
          marginOptions = marginOptions .. margin.name .. "\0"
        end
        im.Combo2("Margin overlay size", ctrls.selectedCameraOverlayMarginPtr, marginOptions)
        im.Checkbox("Show composition overlay", ctrls.cameraCompositionOverlayEnabled)
        im.tooltip("Draws thirds and center guide lines using the current camera.")
        im.Checkbox("Show framing bounding box", ctrls.framingBoundsDebugEnabled)
        im.tooltip("Draws the vehicle spawn-world oriented bounding box used by procedural framing.")
        im.Checkbox("Show framing inputs", ctrls.framingInputsDebugEnabled)
        im.tooltip("Draws the OOBB center, fit points, camera target, and axes used by procedural framing.")
        im.Checkbox("Always use auto framing", ctrls.skipCustomCameras)
        im.tooltip("Ignore saved config/model cameras and use procedural auto framing for preview and thumbnail generation.")

        im.Separator()
        im.TextUnformatted("Legend")
        local function legendItem(color, label)
          im.PushStyleColor2(im.Col_Text, im.ImVec4(color[1], color[2], color[3], color[4] or 1))
          im.TextUnformatted(label)
          im.PopStyleColor()
        end
        local hasLegend = false
        if ctrls.cameraOverlayEnabled[0] then
          legendItem({1, 0, 0, 1}, "Red: full thumbnail frame")
          legendItem({0, 1, 0, 0.7}, "Green: selected safe margin")
          legendItem({0.2, 0.45, 1, 0.75}, "Blue: vehicle-safe margin")
          hasLegend = true
        end
        if ctrls.cameraCompositionOverlayEnabled[0] then
          legendItem({0.3, 0.6, 1, 0.65}, "Light blue: rule-of-thirds lines")
          legendItem({1, 1, 1, 0.75}, "White: center lines")
          hasLegend = true
        end
        if ctrls.framingBoundsDebugEnabled[0] then
          legendItem({1, 0.5, 0, 0.5}, "Orange: vehicle OOBB")
          hasLegend = true
        end
        if ctrls.framingInputsDebugEnabled[0] then
          legendItem({1, 1, 1, 0.75}, "White: OOBB center")
          legendItem({1, 1, 0, 1}, "Yellow: camera axis center / camera direction")
          legendItem({0.1, 1, 0.1, 1}, "Bright green: camera target")
          legendItem({0.2, 0.8, 1, 1}, "Cyan: framing points")
          hasLegend = true
        end
        if not hasLegend then
          im.TextUnformatted("Enable a debug option to show its legend.")
        end

        im.EndTabItem()
      end
      if im.BeginTabItem("Models selection") then
        if im.SmallButton("Player Vehicle Model") then
          selectPlayerVehicle()
        end
        im.SameLine()
        if im.SmallButton("Select All") then
          for _,v in ipairs(vehList) do
            v[2][0] = true
          end
        end
        im.SameLine()
        if im.SmallButton("Unselect All") then
          for _,v in ipairs(vehList) do
            v[2][0] = false
          end
        end
        im.SameLine()
        if im.SmallButton("Invert Selection") then
          for _,v in ipairs(vehList) do
            v[2][0] = not v[2][0]
          end
        end

        local halfWidth = im.GetContentRegionAvailWidth() / 2
        if im.BeginChild1("unselectedSection", im.ImVec2(halfWidth, 0), true) then
          im.Text("Unselected Models")
          if im.BeginChild1("unselectedVehs", im.ImVec2(0,0), true) then
            if vehList then
              for _,v in ipairs(vehList) do
                if not v[2][0] then
                  im.Selectable2(v[3] .. " (" ..v[1] .. ")",v[2])
                end
              end
            end
          end
        end
        im.EndChild()
        im.EndChild()

        im.SameLine()
        if im.BeginChild1("selected", im.ImVec2(halfWidth, 0), true) then
          im.Text("Selected Models")
          if im.BeginChild1("selectedVehs", im.ImVec2(0,0), true) then
            if vehList then
              for _,v in ipairs(vehList) do
                if v[2][0] then
                  im.Selectable2(v[3] .. " (" ..v[1] .. ")",v[2])
                end
              end
            end
          end
        end

        im.EndChild()
        im.EndChild()

        im.EndTabItem()
      end
      if im.BeginTabItem("Manual controls") then

        im.TextWrapped("This tab is used to override the procedural camera placement per model and/or config, during the generation of thumbnails")
        im.TextWrapped("A vehicle config's camera will override its model camera")

        im.Dummy(im.ImVec2(1, 10))

        im.TextWrapped("The ")
        local _, _, camName = getFinalCameraPosAndRotForVehicle(getPlayerVehicle(0), currConfigName)

        im.PushStyleColor2(im.Col_Text, imVec4Green)
        im.SameLine()
        im.TextWrapped(camName)
        im.PopStyleColor()
        im.tooltip("To disable procedural camera placement during thumbnail generation, enable either one of the manual camera placement below")
        im.SameLine()
        im.TextWrapped(" will be used for the spawned config.")
        im.Dummy(im.ImVec2(1, 10))

        im.Checkbox("Use framing margins", ctrls.useFramingMargins)
        im.tooltip("When enabled, automatic camera framing keeps the vehicle inside the thumbnail target margins.")
        im.Dummy(im.ImVec2(1, 5))

        if currConfigName == "default" then
          im.PushStyleColor2(im.Col_Text, imVec4Red)
          editor.uiIconImage(editor.icons.error, imVec24x24, imVec4Red)
          im.SameLine()
          im.TextWrapped("Current vehicle is your own 'default' vehicle. Spawn a vehicle from the vehicle selector (Will be fixed)")
          im.PopStyleColor()
        else
          if im.Button("Preview final thumbnail") then
            local p, r = getFinalCameraPosAndRotForVehicle(getPlayerVehicle(0), currConfigName)
            setCamera(p, r)
          end
          im.SameLine()
          if im.Button("Frame Vehicle") then
            local currRes = getCurrentResolution()
            local p, r = frameVehicle(getPlayerVehicle(0), thumbnailConfig.fov, thumbnailConfig.nearPlane, currRes[1] / currRes[2], currRes)
            setCamera(p, r)
          end
          im.SameLine()
          if im.Button("Frame Vehicle (keep angle)") then
            local currRes = getCurrentResolution()
            local currentRot = core_camera.getQuat()
            local p = frameVehicleWithRotation(getPlayerVehicle(0), currentRot, thumbnailConfig.fov, thumbnailConfig.nearPlane, currRes[1] / currRes[2], currRes)
            setCamera(p, currentRot)
          end
          im.SameLine()
          if im.Button("Game Camera") then
            resetCamera()
          end
          if isCameraSet then
            if editor.uiSliderFloat("Camera Speed", ctrls.camSpeedPtr, 2, 100, "%.1f") then
              core_camera.setSpeed(ctrls.camSpeedPtr[0])
            end
          end

          im.Dummy(im.ImVec2(1, 5))
          if im.Button(ctrls.drivingEnabled and "Disable driving" or "Enable driving") then
            ctrls.drivingEnabled = not ctrls.drivingEnabled

            for _, mapName in ipairs(vehicleActionMaps) do
              local map = scenetree.findObject(mapName)
              if map then
                map:setEnabled(ctrls.drivingEnabled)
              end
            end
          end
          if im.IsItemHovered() then im.BeginTooltip() im.Text("Enable or disable vehicle's controls") im.EndTooltip() end
          im.Dummy(im.ImVec2(1, 10))

          local imguiHeight = 230
          if im.BeginChild1("Parent parent", im.ImVec2(0, imguiHeight), true) then
            if im.BeginChild1("Config list", im.ImVec2(im.GetContentRegionAvailWidth() / 2, 0), nil) then
              if im.BeginTable('Model configs', 4, tableFlags) then
                im.TableSetupColumn("Config name", columnFlags, 16)
                im.TableSetupColumn("Config cam", columnFlags, 7)
                im.TableSetupColumn("Model cam", columnFlags, 7)
                im.TableSetupColumn("Spawn", columnFlags, 7)
                im.TableNextColumn()
                im.Text("Config name")
                im.TableNextColumn()
                im.Text("Config cam")
                im.TableNextColumn()
                im.Text("Model cam")
                im.TableNextColumn()
                im.TableNextColumn()

                local isCurrent
                for _, configData in pairs(core_vehicles.getModel(currModelName).configs) do
                  isCurrent = configData.key == currConfigName
                  local cameraConfigs = getCameraConfig(configData.model_key, configData.key)
                  im.Text(configData.key)
                  if isCurrent then
                    im.SameLine()
                    im.Text("(Current)")
                  end
                  im.TableNextColumn()
                  if cameraConfigs.vehCamConfig.cameraConfig then
                    local enabledPtr = im.BoolPtr(cameraConfigs.vehCamConfig.configCamEnabled)
                    if im.Checkbox("##"..configData.key, enabledPtr) then
                      cameraConfigs.vehCamConfig.configCamEnabled = enabledPtr[0]
                      saveCameraConfig()
                    end
                    im.SameLine(42)
                    if editor.uiIconImageButton(editor.icons.switch_camera, imVec24x24, im.ImColorByRGB(0,255,0,127).Value, nil, nil) then
                      local p,r = rewindCameraOffsets(cameraConfigs.vehCamConfig.cameraConfig.posOffset, cameraConfigs.vehCamConfig.cameraConfig.rotOffset)
                      setCamera(p, r)
                    end
                    im.tooltip(string.format("Click to set camera to '%s' config's camera", configData.key))
                  else
                    im.Text("None")
                  end
                  im.TableNextColumn()
                  if cameraConfigs.modelCamConfig then
                    local enabledPtr = im.BoolPtr(cameraConfigs.vehCamConfig.modelCamEnabled)
                    if im.Checkbox("##"..configData.key..".", enabledPtr) then
                      cameraConfigs.vehCamConfig.modelCamEnabled = enabledPtr[0]
                      saveCameraConfig()
                    end
                  else
                    im.Text("None")
                  end
                  im.TableNextColumn()
                  if not isCurrent then
                    if im.Button("Spawn##"..configData.key) then
                      core_vehicles.replaceVehicle(configData.model_key, { config = configData.key, licenseText = "BeamNG"})
                    end
                  end
                  im.TableNextColumn()
                end
                im.EndTable()
              end
            end
            im.EndChild()
            im.SameLine()

            local cameraConfigs = getCameraConfig(currModelName, currConfigName)
            if im.BeginChild1("Config custom camera", im.ImVec2(im.GetContentRegionAvailWidth() / 2, 0), true) then
              if cameraConfigs.vehCamConfig and cameraConfigs.vehCamConfig.cameraConfig then
                editor.uiIconImage(editor.icons.check, imVec24x24, imVec4Green)
                im.SameLine()
                im.TextWrapped("Current vehicle config has a custom camera")
                if im.Button("Set camera to config camera") then
                  local p,r = rewindCameraOffsets(cameraConfigs.vehCamConfig.cameraConfig.posOffset, cameraConfigs.vehCamConfig.cameraConfig.rotOffset)
                  setCamera(p, r)
                end

                local enabledPtr = im.BoolPtr(cameraConfigs.vehCamConfig.configCamEnabled)
                if im.Checkbox("Enabled", enabledPtr) then
                  cameraConfigs.vehCamConfig.configCamEnabled = enabledPtr[0]
                  saveCameraConfig()
                end
                im.tooltip("If enabled, will use the current vehicle config's custom camera during thumbnail generation.")
              else
                editor.uiIconImage(editor.icons.error, imVec24x24, imVec4Red)
                im.SameLine()
                im.TextWrapped("Current vehicle config doesn't have a custom camera")
              end
              if im.Button("Overwrite config camera") then
                local s = currModelName.."/"..currConfigName
                local posOffset, rotOffset = getCameraOffsets()
                cameraConfigFile.vehConfigs[s] = {
                  cameraConfig = {posOffset=posOffset, rotOffset=rotOffset}
                }
                if not cameraConfigFile.vehConfigs[s] then
                  cameraConfigFile.vehConfigs[s] = {}
                end
                cameraConfigFile.vehConfigs[s].modelCamEnabled = false
                cameraConfigFile.vehConfigs[s].configCamEnabled = true
                saveCameraConfig()
              end
              im.tooltip("Will save the current camera's position and rotation for current vehicle config only")
            end
            im.EndChild()
            im.SameLine()
            if im.BeginChild1("Model custom camera", nil, true) then
              if cameraConfigs.vehCamConfig and cameraConfigs.vehCamConfig.configCamEnabled then
                im.TextWrapped("Vehicle config's manual camera overrides the vehicle model camera. Since the current vehicle config camera is enabled, this window is deactivated")
              else
                if cameraConfigs.modelCamConfig then
                  editor.uiIconImage(editor.icons.check, imVec24x24, imVec4Green)
                  im.SameLine()
                  im.TextWrapped("Current model has a custom camera")
                  if im.Button("Set camera to model camera") then
                    local p,r = rewindCameraOffsets(cameraConfigs.modelCamConfig.cameraConfig.posOffset, cameraConfigs.modelCamConfig.cameraConfig.rotOffset)
                    setCamera(p, r)
                  end

                  local enabledPtr = im.BoolPtr(cameraConfigs.vehCamConfig.modelCamEnabled)
                  if im.Checkbox("Enabled", enabledPtr) then
                    cameraConfigs.vehCamConfig.modelCamEnabled = enabledPtr[0]
                    saveCameraConfig()
                  end
                  im.tooltip("If enabled, will use the current vehicle model's custom camera during thumbnail generation.")

                else
                  editor.uiIconImage(editor.icons.error, imVec24x24, imVec4Red)
                  im.SameLine()
                  im.TextWrapped("Current model doesn't have a custom camera")
                end
                if im.Button("Overwrite model camera") then
                  local s = currModelName.."/"..currConfigName
                  local posOffset, rotOffset = getCameraOffsets()
                  cameraConfigFile.vehModels[currModelName] = {
                    cameraConfig = {posOffset=posOffset, rotOffset=rotOffset}
                  }
                  if not cameraConfigFile.vehConfigs[s] then
                    cameraConfigFile.vehConfigs[s] = {}
                  end
                  cameraConfigFile.vehConfigs[s].modelCamEnabled = true
                  cameraConfigFile.vehConfigs[s].configCamEnabled = false
                  saveCameraConfig()
                end
                im.tooltip("Will save the current camera's position and rotation for current model")
              end
            end
            im.EndChild()
          end
          im.EndChild()

        end
        im.EndTabItem()
      end

      if runDone then im.PushStyleColor2(im.Col_Text, imVec4Red) end
      if im.BeginTabItem("Last run review") then
        if im.Button("Open user's vehicle folder") then
          if not fileExistsOrNil('/vehicles/') then  -- create dir if it doesnt exist
            FS:directoryCreate('/vehicles/', true)
          end
          Engine.Platform.exploreFolder('/vehicles/')
        end
        im.SameLine()
        if im.Button("Open user's screenshot/showroom folder") then
          if not fileExistsOrNil('/screenshots/showroom/') then  -- create dir if it doesnt exist
            FS:directoryCreate('/screenshots/showroom/', true)
          end
          Engine.Platform.exploreFolder('/screenshots/showroom/')
        end

        if reviewData and next(reviewData) then
          local totalSkipped = 0
          local totalDone = 0

          local halfWidth = im.GetContentRegionAvailWidth() / 2
          if im.BeginChild1("Vehicle list info", im.ImVec2(halfWidth, 0), true) then
            im.Text("Thumbnail status list : ")
            im.Dummy(im.ImVec2(1, 10))

            if im.BeginTable('Status list', 4, tableFlags) then
              im.TableSetupColumn("Veh name", columnFlags, 11)
              im.TableSetupColumn("Status", columnFlags, 6)
              im.TableSetupColumn("Camera", columnFlags, 12)
              im.TableSetupColumn("Preview", columnFlags, 7)
              im.TableNextColumn()
              im.Text("Veh name")
              im.TableNextColumn()
              im.Text("Status")
              im.TableNextColumn()
              im.Text("Camera")
              im.TableNextColumn()
              im.TableNextColumn()
              for _, data in ipairs(reviewData.configs) do
                im.Text(data.vehName)
                im.TableNextColumn()

                im.Text(data.status)
                im.TableNextColumn()

                im.Text(data.camName or "")
                im.TableNextColumn()

                if data.status == "skipped" then
                  totalSkipped = totalSkipped + 1
                elseif data.status == "done" then
                  totalDone = totalDone + 1
                end

                im.BeginDisabled()
                if im.Button("Preview") then
                end
                if im.IsItemHovered() then
                  local thumb = imguiUtils.texObj(data.thumbnailPath)
                  im.BeginTooltip()
                  im.Image(thumb.texId, thumb.size, im.ImVec2(0, 0), im.ImVec2(1, 1))
                  im.EndTooltip()
                end
                im.TableNextColumn()
                im.EndDisabled()

              end
              im.EndTable()
            end
          end
          im.EndChild()

          im.SameLine()

          if im.BeginChild1("Run info", im.ImVec2(halfWidth, 0), true) then

            im.Text("General info : ")
            im.Dummy(im.ImVec2(1, 10))
            im.Text("Generate missing thumbnails only : " .. (reviewData.onlyMissingThumbnails and "Yes" or "No"))
            im.Text("Low beams enabled : " .. (reviewData.lowBeamsEnabled and "Yes" or "No"))
            im.Text("Total done : " .. totalDone)
            im.Text("Total skipped : " .. totalSkipped)
          end
          im.EndChild()
        else
          im.Text("There is no last run to review")
        end

        im.EndTabItem()

        runDone = false
      end
      if runDone then im.PopStyleColor() end
    end
    im.EndTabBar()

    if isRunning then im.EndDisabled() end
  end

  ::continue::
  im.End()

  lastFrameImageResolution[0] = ctrls.imageResolution[0]
  lastFrameImageResolution[1] = ctrls.imageResolution[1]
end

local function onExtensionLoaded()
  -- save the user setting to revert it back when leaving the showroom
  if isInShowroom() then
    userDefinedDynamicReflections = settings.getValue("GraphicDynReflectionEnabled")
    userDefinedSkipLicensePlates = settings.getValue("SkipGenerateLicencePlate")
    local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
    if localExposure then
      localExposure.autoExposure = false
      localExposure.manualEV = 10
    end
  end
  trySetDynamicReflections(ctrls.dynamicReflectionsEnabled[0])
  trySetGeneratePlates(true)
end

local function onExtensionUnloaded()
  trySetDynamicReflections(userDefinedDynamicReflections)
  trySetGeneratePlates(userDefinedSkipLicensePlates)
  local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
  if localExposure then
    localExposure.autoExposure = true
  end

  log('I', '', "Module unloaded")
end

local function openWindow()
  extensions.editor_main.initializeModules()
  windowOpen[0] = true
end

local function onSerialize()
  return {
    windowOpen = windowOpen[0],
    userDefinedDynamicReflections = userDefinedDynamicReflections,
    userDefinedSkipLicensePlates = userDefinedSkipLicensePlates,
    generateMissingThumbnailsOnly = ctrls.generateMissingThumbnailsOnly[0],
    reloadUIOnJobFinished = ctrls.reloadUIOnJobFinished[0],
    resolutionPtr = (ctrls.currResolutionsPtr and ctrls.currResolutionsPtr[0]) or thumbnailDefaultValues.resolution,
    reviewData = reviewData,
    runDone = runDone,
    previousFov = previousFov,
    isCameraSet = isCameraSet,
    plRes = plRes,
    keepAspectRatio = ctrls.keepAspectRatio[0],
    dynamicReflectionsEnabled = ctrls.dynamicReflectionsEnabled[0],
    lowBeamsEnabled = ctrls.lowBeamsEnabled[0],
    cameraOverlayEnabled = ctrls.cameraOverlayEnabled[0],
    includeMarginInScreenshot = ctrls.includeMarginInScreenshot[0],
    selectedCameraOverlayMargin = ctrls.selectedCameraOverlayMarginPtr[0],
    cameraCompositionOverlayEnabled = ctrls.cameraCompositionOverlayEnabled[0],
    framingBoundsDebugEnabled = ctrls.framingBoundsDebugEnabled[0],
    framingInputsDebugEnabled = ctrls.framingInputsDebugEnabled[0],
    skipCustomCameras = ctrls.skipCustomCameras[0],
    useFramingMargins = ctrls.useFramingMargins[0]
  }
end

local function onDeserialized(data)
  if data.windowOpen ~= nil then
    resetToDefaultValues()

    windowOpen[0] = data.windowOpen
    userDefinedDynamicReflections = data.userDefinedDynamicReflections
    userDefinedSkipLicensePlates = data.userDefinedSkipLicensePlates
    reviewData = data.reviewData or {}
    ctrls.generateMissingThumbnailsOnly[0] = data.generateMissingThumbnailsOnly
    ctrls.currResolutionsPtr[0] = data.resolutionPtr
    ctrls.reloadUIOnJobFinished[0] = data.reloadUIOnJobFinished
    runDone = data.runDone
    previousFov = data.previousFov
    isCameraSet = data.isCameraSet
    plRes = data.plRes
    ctrls.keepAspectRatio[0] = data.keepAspectRatio
    ctrls.dynamicReflectionsEnabled[0] = data.dynamicReflectionsEnabled == true
    ctrls.lowBeamsEnabled[0] = data.lowBeamsEnabled == true
    ctrls.cameraOverlayEnabled[0] = data.cameraOverlayEnabled ~= false
    ctrls.includeMarginInScreenshot[0] = data.includeMarginInScreenshot == true
    ctrls.selectedCameraOverlayMarginPtr[0] = clamp(data.selectedCameraOverlayMargin or thumbnailSafeMargins.defaultTargetIndex, 0, #thumbnailSafeMargins.targets - 1)
    ctrls.cameraCompositionOverlayEnabled[0] = data.cameraCompositionOverlayEnabled == true
    ctrls.framingBoundsDebugEnabled[0] = data.framingBoundsDebugEnabled == true
    ctrls.framingInputsDebugEnabled[0] = data.framingInputsDebugEnabled == true
    ctrls.skipCustomCameras[0] = data.skipCustomCameras == true
    ctrls.useFramingMargins[0] = data.useFramingMargins ~= false
  end
end

M.onPreRender = onPreRender
M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.openWindow = openWindow
M.startWork = startWork
M.onSerialize = onSerialize
M.onDeserialized = onDeserialized

M.frameVehicle = frameVehicle
M.takeThumbnailScreenshot = takeThumbnailScreenshot
return M
