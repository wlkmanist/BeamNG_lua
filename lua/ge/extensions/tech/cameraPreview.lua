-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"tech_sensors"}

local im = ui_imgui

local enabled = false
local logTag = 'cameraPreview'

local deadCamCache = {}
local camData = {}

local MAX_DISPLAY_WIDTH = 512
local MAX_DISPLAY_HEIGHT = 512

local function unloadCamera(sensorId)
  camData[sensorId] = nil
end

local function getDisplaySize(size)
  local ratioX = MAX_DISPLAY_WIDTH / size.x
  local ratioY = MAX_DISPLAY_HEIGHT / size.y
  local displayRatio = math.min(ratioX, ratioY)
  if displayRatio >= 1 then
    return size
  end
  return im.ImVec2(size.x * displayRatio, size.y * displayRatio)
end

local function loadCamera(sensorId)
  local config = tech_sensors.getSensorConfiguration(tech_sensors.stype.tCamera, sensorId)
  local size = im.ImVec2(config.size[1], config.size[2])
  camData[sensorId] = {
    id = sensorId,
    visualize = im.BoolPtr(false),
    size = im.ImVec2(size.x, size.y),
    showColor = im.BoolPtr(true),
    showAnnotation = im.BoolPtr(false),
    showDepth = im.BoolPtr(false),
    renderColours = config.renderColours,
    renderAnnotations = config.renderAnnotations,
    renderDepth = config.renderDepth
  }
  camData[sensorId].displaySize = getDisplaySize(camData[sensorId].size)
end

local function loadCameras()
  local cameras = tech_sensors.getActiveCameraSensors()
  camData = {}
  for i = 1, #cameras do
    loadCamera(cameras[i])
  end
end

local function onExtensionLoaded()
  if not ResearchVerifier.isTechLicenseVerified() then
    enabled = false
    return
  end
  enabled = true
  loadCameras()
end

local function changeCamDebugState(cam)
  if cam.visualize[0] then
    Research.Camera.enableDebugVisualization(cam.id)
  else
    Research.Camera.disableDebugVisualization(cam.id)
  end
end

local horizontalLayout = im.BoolPtr(true)

local function boolToNum(x)
  return x and 1 or 0
end

local function visualizeCamera(cam)
  if cam.size.x ~= cam.displaySize.x or cam.size.y ~= cam.displaySize.y then
    im.Text('Camera resolution: (%d, %d), Display size: (%d, %d)', cam.size.x, cam.size.y, cam.displaySize.x, cam.displaySize.y)
  else
    im.Text('Camera resolution: (%d, %d)', cam.size.x, cam.size.y, cam.displaySize.x, cam.displaySize.y)
  end

  local numImages = boolToNum(cam.renderColours) + boolToNum(cam.renderAnnotations) + boolToNum(cam.renderDepth)

  if numImages > 1 then
    im.Checkbox("Horizontal layout", horizontalLayout)
  end
  if cam.renderColours then
    im.BeginGroup()
    im.Checkbox("Color##" .. cam.id, cam.showColor)
    if cam.showColor[0] then
      Research.Camera.displayColorImage(cam.id, cam.displaySize)
    end
    im.EndGroup()
    if horizontalLayout[0] then im.SameLine() end
  end
  if cam.renderAnnotations then
    im.BeginGroup()
    im.Checkbox("Annotation##" .. cam.id, cam.showAnnotation)
    if cam.showAnnotation[0] then
      Research.Camera.displayAnnotationImage(cam.id, cam.displaySize)
    end
    im.EndGroup()
    if horizontalLayout[0] then im.SameLine() end
  end
  if cam.renderDepth then
    im.BeginGroup()
    im.Checkbox("Depth##" .. cam.id, cam.showDepth)
    if cam.showDepth[0] then
      Research.Camera.displayDepthImage(cam.id, cam.displaySize)
    end
    im.EndGroup()
  end
end

local function visualizeCameraById(sensorId)
  local cam = camData[sensorId]
  if cam == nil then
    log('E', logTag, string.format('Camera with id %d not found.', sensorId))
    return
  end
  if not cam.visualize[0] then
    cam.visualize[0] = true
    changeCamDebugState(cam)
  end
  visualizeCamera(camData[sensorId])
end

local function stopVisualizeCameraById(sensorId)
  local cam = camData[sensorId]
  if cam == nil then
    log('E', logTag, string.format('Camera with id %d not found.', sensorId))
    return
  end
  if cam.visualize[0] then
    cam.visualize[0] = false
    changeCamDebugState(cam)
  end
end

local function getCamData()
  return camData
end

local function onSensorCreated(sensorType, sensorId)
  if not enabled then return end
  if sensorType == tech_sensors.stype.tCamera then
    loadCamera(sensorId)
  end
end

local function onSensorRemoved(sensorType, sensorId)
  if not enabled then return end
  if sensorType == tech_sensors.stype.tCamera then
    unloadCamera(sensorId)
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.onSensorCreated = onSensorCreated
M.onSensorRemoved = onSensorRemoved

M.getCamData = getCamData
M.changeCamDebugState = changeCamDebugState
M.visualizeCameraById = visualizeCameraById
M.stopVisualizeCameraById = stopVisualizeCameraById

return M
