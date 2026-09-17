-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local ffi = ffi
local CONSTANTS = require('tech/ros/constants')
local utilRos = require('tech/ros/util')
local persistence = require('editor/tech/ros/rosEditorPersistence')
local fieldCatalog = require('editor/tech/ros/editorFieldCatalog')
local widgets = require('editor/tech/ros/rosEditorInspectorWidgets')

local CONFIG_KEY_DISPLAY_NAMES = fieldCatalog.CONFIG_KEY_DISPLAY_NAMES
local CONFIG_KEY_TOOLTIPS = fieldCatalog.CONFIG_KEY_TOOLTIPS
local AXIS_LABEL_COLORS = fieldCatalog.AXIS_LABEL_COLORS
local sensorTypeIs = fieldCatalog.sensorTypeIs
local displayNameForConfigKey = fieldCatalog.displayNameForConfigKey
local floatFormatString = fieldCatalog.floatFormatString

local M = {}

local PLACEMENT_CREATE_KEYS = { 'pos', 'dir', 'up' }
local PLACEMENT_KEY_SET = {}
for _, key in ipairs(PLACEMENT_CREATE_KEYS) do PLACEMENT_KEY_SET[key] = true end

local ALWAYS_HIDDEN_CREATE_KEYS = { isDirWorldSpace = true }

-- Create-keys hidden in the generic 'Sensor parameters' loop because dedicated UI handles them (or the value is irrelevant for the given sensor type).
local HIDDEN_CREATE_KEYS_BY_TYPE = {
  camera = {
    updatePriority = true,
    size = true, fovY = true, nearFarPlanes = true,
    renderColours = true, renderAnnotations = true, renderDepth = true,
    isVisualised = true,
    autoExposure = true, manualExposure = true,
    useManualEV = true, manualEV = true,
  },
  lidar = {
    verticalAngle = true, horizontalAngle = true,
    verticalResolution = true, horizontalResolution = true,
    frequency = true, isRotate = true,
    minDistance = true, maxDistance = true,
    isVisualised = true,
  },
  gps = {
    refLon = true, refLat = true,
    isVisualised = true,
  },
  advancedimu = { isVisualised = true },
  ultrasonic = {
    nearFarPlanes = true,
    rangeMin = true, rangeMax = true,
    rangeMinCutoff = true, rangeDirectMaxCutoff = true,
    isVisualised = true,
  },
  radar = {
    requestedUpdateTime = true, requested_update_time = true,
    updatePriority = true,
    size = true, fovY = true, nearFarPlanes = true,
    halfAngleDeg = true, velMin = true, velMax = true,
    rangeRoundness = true, rangeCutoffSensitivity = true, rangeShape = true, rangeFocus = true,
    rangeMinCutoff = true, rangeDirectMaxCutoff = true,
    rangeBins = true, azimuthBins = true, velBins = true,
    rangeMin = true, rangeMax = true,
    isVisualised = true,
  },
}

-- Every blob/GPU sensor exposes the unified update_rate_hz field at sensor.config.update_rate_hz.
local TYPES_WITH_UPDATE_RATE = {
  gps = true, advancedimu = true, ultrasonic = true, radar = true, lidar = true, camera = true,
  mesh = true, idealradar = true, roads = true, powertrain = true,
}

local function shouldSkipCreateKey(sensor, key)
  if ALWAYS_HIDDEN_CREATE_KEYS[key] then return true end
  local typeKey = utilRos.getSensorType(sensor.type)
  local hidden = typeKey and HIDDEN_CREATE_KEYS_BY_TYPE[typeKey]
  return hidden ~= nil and hidden[key] == true
end

local function collectNonPlacementCreateKeys(sensor, createTemplate)
  local keys = {}
  for key in pairs(createTemplate) do
    if not PLACEMENT_KEY_SET[key] and not shouldSkipCreateKey(sensor, key) then
      keys[#keys + 1] = key
    end
  end
  fieldCatalog.sortNonPlacementCreateKeys(keys)
  return keys
end

local function syncSensorIdEditBuffer(editorState, draftWork, sensorIndex1Based)
  local cacheKey = tostring(persistence.getSelectedVehicleId(editorState) or 0)
    .. ':' .. tostring(sensorIndex1Based) .. ':id'
  if editorState.sensorIdBufferCacheKey == cacheKey and editorState.sensorIdEditBuffer ~= nil then return end
  editorState.sensorIdBufferCacheKey = cacheKey
  local sensor = draftWork.sensors[sensorIndex1Based]
  editorState.sensorIdEditBuffer = im.ArrayChar(CONSTANTS.ROS_EDITOR_SENSOR_ID_BUFFER, (sensor and sensor.id) or '')
end

local function clearScalarFieldFilterForContext(editorState, contextKey)
  if contextKey ~= editorState.scalarFieldFilterContext then
    editorState.scalarFieldFilterContext = contextKey
    ffi.fill(editorState.scalarFieldFilterBuffer, CONSTANTS.ROS_EDITOR_IMGUI_TEXT_BUFFER, 0)
  end
end

local function scalarFieldRowPassesFilter(field, filterLower)
  if not filterLower or filterLower == '' then return true end
  if type(field) ~= 'table' or not field.name then return false end
  local uiName = field.UIName
  if type(uiName) ~= 'string' or uiName == '' then return false end
  return string.find(string.lower(uiName), filterLower, 1, true) ~= nil
end

local function drawScalarChannelsTable(editorState, sensor, defaultEntry, idx0, draftVehicleId)
  clearScalarFieldFilterForContext(editorState,
    tostring(draftVehicleId or 0) .. ':' .. tostring(sensor.id or '') .. ':' .. tostring(idx0))
  local filterLower = string.lower(ffi.string(editorState.scalarFieldFilterBuffer))

  im.PushStyleVar2(im.StyleVar_ItemSpacing, im.ImVec2(6 * im.uiscale[0], 4 * im.uiscale[0]))
  local availableWidth = im.GetContentRegionAvailWidth()
  im.SetNextItemWidth(math.max(160 * im.uiscale[0], availableWidth - 170 * im.uiscale[0]))
  im.InputTextWithHint('##rosScalarFlt' .. tostring(idx0), 'Filter by UI name...',
    editorState.scalarFieldFilterBuffer, CONSTANTS.ROS_EDITOR_IMGUI_TEXT_BUFFER)
  im.SetItemTooltip('Narrows the table only; every default field stays in the sensor type catalog.')

  im.SameLine()
  if im.SmallButton('All##rosFldAll' .. tostring(idx0)) then
    local fieldNames = {}
    for _, field in ipairs(defaultEntry.fields) do
      if type(field) == 'table' and field.name then
        fieldNames[#fieldNames + 1] = field.name
      end
    end
    sensor.fields = fieldNames
  end
  im.SetItemTooltip('Publish every default scalar for this sensor type.')

  im.SameLine()
  if im.SmallButton('None##rosFldNone' .. tostring(idx0)) then
    sensor.fields = {}
  end
  im.SetItemTooltip('Turn off publishing for all scalars in subset mode.')
  im.PopStyleVar()

  sensor.fields = sensor.fields or {}
  local selected = {}
  for _, name in ipairs(sensor.fields) do selected[name] = true end

  local tblFlags = bit.bor(
    im.TableFlags_RowBg, im.TableFlags_BordersInnerV, im.TableFlags_BordersOuterH,
    im.TableFlags_ScrollY, im.TableFlags_SizingStretchProp)

  if im.BeginTable('##rosScalarFldTbl' .. tostring(idx0), 2, tblFlags, im.ImVec2(-1, 220 * im.uiscale[0])) then
    im.TableSetupColumn('##pub', im.TableColumnFlags_WidthFixed, 30 * im.uiscale[0])
    im.TableSetupColumn('UI name', im.TableColumnFlags_WidthStretch)
    im.TableHeadersRow()

    for _, field in ipairs(defaultEntry.fields) do
      if type(field) == 'table' and field.name and scalarFieldRowPassesFilter(field, filterLower) then
        local fieldName = field.name
        im.TableNextRow()
        im.TableSetColumnIndex(0)
        editorState.scalarFieldRowPtr[0] = selected[fieldName] and true or false
        im.Checkbox('##fpub' .. fieldName .. tostring(idx0), editorState.scalarFieldRowPtr)
        if editorState.scalarFieldRowPtr[0] then
          selected[fieldName] = true
        else
          selected[fieldName] = nil
        end
        im.TableSetColumnIndex(1)
        local uiName = field.UIName
        im.Text((type(uiName) == 'string' and uiName ~= '') and uiName or '-')
      end
    end
    im.EndTable()
  end

  local rebuilt = {}
  for _, field in ipairs(defaultEntry.fields) do
    if type(field) == 'table' and field.name and selected[field.name] then
      rebuilt[#rebuilt + 1] = field.name
    end
  end
  sensor.fields = rebuilt
end

-- Unified ROS publish rate input (sensor.config.update_rate_hz). Used by every blob/GPU sensor.
local function drawUpdateRateHz(editorState, sensor, defaultEntry)
  if sensor.config.update_rate_hz == nil then
    sensor.config.update_rate_hz = tonumber(defaultEntry.config and defaultEntry.config.update_rate_hz)
      or CONSTANTS.ROS_DEFAULT_BLOB_PUBLISH_HZ
  end
  local floatPtr = im.FloatPtr(sensor.config.update_rate_hz)
  im.InputFloat(displayNameForConfigKey('update_rate_hz') .. '##rosRateHz' .. (sensor.id or ''), floatPtr,
    CONSTANTS.ROS_EDITOR_DRAG_STEP, CONSTANTS.ROS_EDITOR_DRAG_FAST_STEP, floatFormatString(editorState))
  fieldCatalog.setConfigKeyItemTooltip('update_rate_hz')
  sensor.config.update_rate_hz = floatPtr[0]
end

-- publish_mode 'fixed' = cap at update_rate_hz; 'max' = unlimited (pipeline uses UNLIMITED_TARGET_HZ).
local function drawPublishLimiterToggle(sensor, defaultEntry)
  if sensor.config.publish_mode == nil then
    sensor.config.publish_mode = (defaultEntry.config and defaultEntry.config.publish_mode) or 'fixed'
  end
  local limiterPtr = im.BoolPtr(sensor.config.publish_mode ~= 'max')
  if im.Checkbox('Enable framerate limiter##rosRateLimit' .. (sensor.id or ''), limiterPtr) then
    sensor.config.publish_mode = limiterPtr[0] and 'fixed' or 'max'
  end
  im.SetItemTooltip('When on, cap sensor updates and ROS publish rate to the Hz value below. When off, use maximum rate.')
end

-- Camera: radio-button image-stream selector (colours / annotations / depth).
local function drawCameraRenderStreamsGrid(createTable, template, sensorId)
  im.TextUnformatted('Image stream')
  im.SetItemTooltip('Exactly one camera output is captured into shared memory for ROS.')
  im.Dummy(im.ImVec2(0, 2))
  if createTable.renderColours == nil then createTable.renderColours = template.renderColours end
  if createTable.renderAnnotations == nil then createTable.renderAnnotations = template.renderAnnotations end
  if createTable.renderDepth == nil then createTable.renderDepth = template.renderDepth end

  local sel = 0
  if createTable.renderAnnotations == true then sel = 1
  elseif createTable.renderDepth == true then sel = 2 end

  local sid = tostring(sensorId or '')
  local function setStream(streamIndex)
    createTable.renderColours = streamIndex == 0
    createTable.renderAnnotations = streamIndex == 1
    createTable.renderDepth = streamIndex == 2
  end
  if im.RadioButton1('Colours##camStream' .. sid, sel == 0) then setStream(0) end
  fieldCatalog.setConfigKeyItemTooltip('renderColours')
  if im.RadioButton1('Annotations##camStream' .. sid, sel == 1) then setStream(1) end
  fieldCatalog.setConfigKeyItemTooltip('renderAnnotations')
  if im.RadioButton1('Depth##camStream' .. sid, sel == 2) then setStream(2) end
  fieldCatalog.setConfigKeyItemTooltip('renderDepth')
end

local function drawCameraExposureRow(editorState, createTable, template, sensorId)
  local sid = tostring(sensorId or '')
  if createTable.autoExposure == nil then createTable.autoExposure = template.autoExposure ~= false end
  if createTable.manualExposure == nil then
    createTable.manualExposure = tonumber(template.manualExposure) or CONSTANTS.ROS_DEFAULT_MANUAL_EXPOSURE
  end

  local autoPtr = im.BoolPtr(createTable.autoExposure ~= false)
  im.Checkbox(displayNameForConfigKey('autoExposure') .. '##camAutoExp' .. sid, autoPtr)
  fieldCatalog.setConfigKeyItemTooltip('autoExposure')
  createTable.autoExposure = autoPtr[0]

  im.SameLine(0, 20)
  if createTable.autoExposure then im.BeginDisabled() end
  local expPtr = im.FloatPtr(tonumber(createTable.manualExposure) or CONSTANTS.ROS_DEFAULT_MANUAL_EXPOSURE)
  im.SetNextItemWidth(math.max(130 * im.uiscale[0], im.GetContentRegionAvailWidth() * 0.38))
  im.InputFloat(displayNameForConfigKey('manualExposure') .. '##camManExp' .. sid, expPtr,
    CONSTANTS.ROS_MANUAL_EXPOSURE_DRAG_STEP, CONSTANTS.ROS_MANUAL_EXPOSURE_DRAG_FAST_STEP, CONSTANTS.ROS_MANUAL_EXPOSURE_INPUT_FORMAT)
  if createTable.autoExposure then im.EndDisabled() end
  fieldCatalog.setConfigKeyItemTooltip('manualExposure')
  local manual = expPtr[0] or CONSTANTS.ROS_DEFAULT_MANUAL_EXPOSURE
  if manual <= 0 then manual = CONSTANTS.ROS_DEFAULT_MANUAL_EXPOSURE end
  createTable.manualExposure = manual
end

local function drawCameraSensorParameters(editorState, sensor, defaultEntry, createTable)
  local template = defaultEntry.config.create

  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted(CONFIG_KEY_DISPLAY_NAMES.size)
  fieldCatalog.setConfigKeyItemTooltip('size')
  widgets.drawLabeledPairRow(editorState, createTable, 'size', template.size, 'createCam',
    'W', 'H', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[2])

  if createTable.fovY == nil then createTable.fovY = template.fovY end
  local floatPtrFov = im.FloatPtr(tonumber(createTable.fovY) or CONSTANTS.ROS_DEFAULT_CAMERA_FOV_DEG)
  im.InputFloat(displayNameForConfigKey('fovY') .. '##camFov' .. (sensor.id or ''), floatPtrFov,
    CONSTANTS.ROS_EDITOR_DRAG_STEP, CONSTANTS.ROS_EDITOR_DRAG_FAST_STEP, floatFormatString(editorState))
  fieldCatalog.setConfigKeyItemTooltip('fovY')
  createTable.fovY = floatPtrFov[0]

  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted(CONFIG_KEY_DISPLAY_NAMES.nearFarPlanes)
  fieldCatalog.setConfigKeyItemTooltip('nearFarPlanes')
  widgets.drawLabeledPairRow(editorState, createTable, 'nearFarPlanes', template.nearFarPlanes, 'createCamNf',
    'Near', 'Far', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[3])

  drawCameraRenderStreamsGrid(createTable, template, sensor.id)

  im.Dummy(im.ImVec2(0, 2))
  drawCameraExposureRow(editorState, createTable, template, sensor.id)
end

local function drawLidarResolutionAndBlobMaxPoints(sensor, defaultEntry, createTable)
  local templateCreate = defaultEntry.config.create
  local templateBlob = defaultEntry.config.blobLayout
  local templateMaxPts = templateBlob and templateBlob.maxPoints
  local sid = tostring(sensor.id or '')
  local templateV = math.max(1, math.floor(tonumber(templateCreate.verticalResolution) or 64))
  local v = math.max(1, math.floor(tonumber(createTable.verticalResolution) or templateV))
  createTable.verticalResolution = v
  if createTable.horizontalResolution == nil then
    createTable.horizontalResolution = math.max(1, math.floor((tonumber(templateMaxPts) or (v * 512)) / v))
  end
  local h = math.max(1, math.floor(tonumber(createTable.horizontalResolution) or 1))
  createTable.horizontalResolution = h

  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted('Resolution (rays)')
  im.SetItemTooltip('Vertical and horizontal ray counts. ROS blob max points = vertical x horizontal.')
  im.Dummy(im.ImVec2(0, 2))

  local style = im.GetStyle()
  local availableWidth = im.GetContentRegionAvailWidth()
  local labelPad = im.CalcTextSize('V').x + im.CalcTextSize('H').x + 12
  local fieldWidth = math.max(52, (availableWidth - labelPad - style.ItemSpacing.x * 3) * 0.5)

  im.TextColored(AXIS_LABEL_COLORS[1], 'V')
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local vPtr = im.FloatPtr(v)
  im.InputFloat('##lidVRes' .. sid, vPtr, 1, 4, '%.0f')
  im.PopItemWidth()
  v = math.max(1, math.floor((vPtr[0] or 0) + 0.5))
  createTable.verticalResolution = v

  im.SameLine(0, 10)
  im.TextColored(AXIS_LABEL_COLORS[2], 'H')
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local hPtr = im.FloatPtr(h)
  im.InputFloat('##lidHRes' .. sid, hPtr, 1, 4, '%.0f')
  im.PopItemWidth()
  h = math.max(1, math.floor((hPtr[0] or 0) + 0.5))
  createTable.horizontalResolution = h

  if templateMaxPts ~= nil then
    sensor.config.blobLayout = sensor.config.blobLayout or {}
    sensor.config.blobLayout.maxPoints = math.max(1, v * h)
  end
end

local function drawLidarRotateAndFrequencyRow(editorState, createTable, template, sensorId)
  local sid = tostring(sensorId or '')
  if createTable.isRotate == nil then createTable.isRotate = template.isRotate end
  if createTable.frequency == nil then createTable.frequency = template.frequency end

  local rotPtr = im.BoolPtr(createTable.isRotate == true)
  im.Checkbox(displayNameForConfigKey('isRotate') .. '##lidRot' .. sid, rotPtr)
  fieldCatalog.setConfigKeyItemTooltip('isRotate')
  createTable.isRotate = rotPtr[0]

  im.SameLine(0, 20)
  if not createTable.isRotate then im.BeginDisabled() end
  local fPtr = im.FloatPtr(tonumber(createTable.frequency) or 0)
  im.SetNextItemWidth(math.max(130 * im.uiscale[0], im.GetContentRegionAvailWidth() * 0.38))
  im.InputFloat(displayNameForConfigKey('frequency') .. '##lidFreq' .. sid, fPtr,
    CONSTANTS.ROS_EDITOR_DRAG_STEP, CONSTANTS.ROS_EDITOR_DRAG_FAST_STEP, floatFormatString(editorState))
  if not createTable.isRotate then im.EndDisabled() end
  fieldCatalog.setConfigKeyItemTooltip('frequency')
  createTable.frequency = fPtr[0]
end

local function drawTitledTwoScalarsRow(editorState, createTable, template, keyA, keyB, idScope,
                                       title, tooltip, labelA, labelB, colorA, colorB)
  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted(title)
  if tooltip then im.SetItemTooltip(tooltip) end
  im.Dummy(im.ImVec2(0, 2))
  widgets.drawTwoScalarsRow(editorState, createTable, template, keyA, keyB, idScope,
    labelA, labelB, colorA, colorB)
end

local function drawLidarSensorParameters(editorState, sensor, defaultEntry, createTable)
  local template = defaultEntry.config.create
  local sid = tostring(sensor.id or '')
  drawLidarResolutionAndBlobMaxPoints(sensor, defaultEntry, createTable)
  drawTitledTwoScalarsRow(editorState, createTable, template, 'verticalAngle', 'horizontalAngle', 'lid' .. sid,
    'Field of view (°)',
    (CONFIG_KEY_TOOLTIPS.verticalAngle or '') .. ' ' .. (CONFIG_KEY_TOOLTIPS.horizontalAngle or ''),
    'V', 'H', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[2])
  drawTitledTwoScalarsRow(editorState, createTable, template, 'minDistance', 'maxDistance', 'lidD' .. sid,
    'Range (m)',
    (CONFIG_KEY_TOOLTIPS.minDistance or '') .. ' ' .. (CONFIG_KEY_TOOLTIPS.maxDistance or ''),
    'Min', 'Max', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[3])
  drawLidarRotateAndFrequencyRow(editorState, createTable, template, sensor.id)
end

local function drawGpsSensorParameters(editorState, sensor, defaultEntry, createTable)
  local template = defaultEntry.config.create
  drawTitledTwoScalarsRow(editorState, createTable, template, 'refLon', 'refLat', 'gps' .. tostring(sensor.id or ''),
    'Reference longitude / latitude',
    'Reference longitude and latitude for reported positions (degrees).',
    'Lon', 'Lat', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[2])
end

local function drawUltrasonicSensorParameters(editorState, sensor, defaultEntry, createTable)
  local template = defaultEntry.config.create
  local templateNearFar = template.nearFarPlanes or { 0.05, 5.1 }
  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted(CONFIG_KEY_DISPLAY_NAMES.nearFarPlanes)
  fieldCatalog.setConfigKeyItemTooltip('nearFarPlanes')
  im.Dummy(im.ImVec2(0, 2))
  widgets.drawLabeledPairRow(editorState, createTable, 'nearFarPlanes', templateNearFar, 'createUsNf',
    'Near', 'Far', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[3])
  -- Ultrasonic range cutoffs mirror the near/far pair (single source of truth in the UI).
  local nf = createTable.nearFarPlanes
  createTable.rangeMin, createTable.rangeMax = nf[1], nf[2]
  createTable.rangeMinCutoff, createTable.rangeDirectMaxCutoff = nf[1], nf[2]
end

-- Radar full-horizontal-FOV input (writes halfAngleDeg = full / 2, clamped) + vertical FOV (fovY).
local function drawRadarFovRow(editorState, createTable, template, sensorId)
  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted('Field of view (°)')
  im.SetItemTooltip('Horizontal and vertical field of view in degrees.')
  local floatFormat = floatFormatString(editorState)
  local style = im.GetStyle()
  local availableWidth = im.GetContentRegionAvailWidth()
  local labelPad = im.CalcTextSize('H').x + im.CalcTextSize('V').x + 8
  local fieldWidth = math.max(52, (availableWidth - labelPad - style.ItemSpacing.x * 3) * 0.5)
  local half = tonumber(createTable.halfAngleDeg) or tonumber(template.halfAngleDeg)
    or CONSTANTS.ROS_RADAR_DEFAULT_HALF_ANGLE_DEG
  local horizFull = math.max(CONSTANTS.ROS_RADAR_HFOV_FULL_DEG_MIN,
    math.min(CONSTANTS.ROS_RADAR_HFOV_FULL_DEG_MAX, half * 2))
  local fovy = tonumber(createTable.fovY) or tonumber(template.fovY) or CONSTANTS.ROS_DEFAULT_CAMERA_FOV_DEG

  im.TextColored(AXIS_LABEL_COLORS[1], 'H')
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local floatPtrH = im.FloatPtr(horizFull)
  im.InputFloat('##rosRadFovH' .. tostring(sensorId or ''), floatPtrH,
    CONSTANTS.ROS_EDITOR_DRAG_STEP, CONSTANTS.ROS_EDITOR_DRAG_FAST_STEP, floatFormat)
  im.PopItemWidth()
  horizFull = math.max(CONSTANTS.ROS_RADAR_HFOV_FULL_DEG_MIN,
    math.min(CONSTANTS.ROS_RADAR_HFOV_FULL_DEG_MAX, floatPtrH[0]))
  createTable.halfAngleDeg = math.max(CONSTANTS.ROS_RADAR_HALF_ANGLE_DEG_MIN,
    math.min(CONSTANTS.ROS_RADAR_HALF_ANGLE_DEG_MAX, horizFull * 0.5))

  im.SameLine(0, 10)
  im.TextColored(AXIS_LABEL_COLORS[2], 'V')
  im.SameLine(0, 4)
  im.PushItemWidth(fieldWidth)
  local floatPtrV = im.FloatPtr(fovy)
  im.InputFloat('##rosRadFovV' .. tostring(sensorId or ''), floatPtrV,
    CONSTANTS.ROS_EDITOR_DRAG_STEP, CONSTANTS.ROS_EDITOR_DRAG_FAST_STEP, floatFormat)
  im.PopItemWidth()
  createTable.fovY = floatPtrV[0]
end

local function drawRadarSensorParameters(editorState, sensor, defaultEntry, createTable)
  local template = defaultEntry.config.create
  local sid = sensor.id or ''

  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted(CONFIG_KEY_DISPLAY_NAMES.size)
  fieldCatalog.setConfigKeyItemTooltip('size')
  widgets.drawLabeledPairRow(editorState, createTable, 'size', template.size or { 200, 200 }, 'createRadSz',
    'Horiz.', 'Vert.', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[2])

  drawRadarFovRow(editorState, createTable, template, sid)

  im.Dummy(im.ImVec2(0, 2))
  im.TextUnformatted(CONFIG_KEY_DISPLAY_NAMES.nearFarPlanes)
  fieldCatalog.setConfigKeyItemTooltip('nearFarPlanes')
  widgets.drawLabeledPairRow(editorState, createTable, 'nearFarPlanes', template.nearFarPlanes or { 0.1, 150.0 },
    'createRadNf', 'Near', 'Far', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[3])

  drawTitledTwoScalarsRow(editorState, createTable, template, 'velMin', 'velMax', 'rosRadVel' .. sid,
    'Velocity min / max (m/s)', 'Doppler / velocity display range.',
    'Min', 'Max', AXIS_LABEL_COLORS[1], AXIS_LABEL_COLORS[3])
end

local SENSOR_PARAMETER_DRAWERS = {
  camera = drawCameraSensorParameters,
  gps = drawGpsSensorParameters,
  lidar = drawLidarSensorParameters,
  ultrasonic = drawUltrasonicSensorParameters,
  radar = drawRadarSensorParameters,
}

local function drawPlacementSection(editorState, sensor, createTable, createTemplate)
  local hasPlacement = false
  for _, key in ipairs(PLACEMENT_CREATE_KEYS) do
    if createTemplate[key] ~= nil then hasPlacement = true break end
  end
  if not hasPlacement then return end

  widgets.drawRosCategoryHeader('Position and orientation')
  for _, key in ipairs(PLACEMENT_CREATE_KEYS) do
    if createTemplate[key] ~= nil then
      widgets.drawConfigKeyControl(editorState, createTable, key, createTemplate[key], 'create')
    end
  end

  if createTemplate.pos == nil then return end

  if sensor.config.stickToVehicle == nil then
    sensor.config.stickToVehicle = not sensorTypeIs(sensor, 'radar')
  end
  local sid = tostring(sensor.id or '')
  editorState.stickToVehiclePtr[0] = sensor.config.stickToVehicle ~= false
  im.Checkbox('Stick to vehicle mesh##rosStick' .. sid, editorState.stickToVehiclePtr)
  im.SetItemTooltip(sensorTypeIs(sensor, 'radar')
    and 'Optional for radar: snap can fail placement for some poses; leave off unless you need mesh snap.'
    or 'When enabled, snap position and orientation to the vehicle surface (gizmo placement).')
  sensor.config.stickToVehicle = editorState.stickToVehiclePtr[0]

  if createTemplate.isVisualised ~= nil then
    if createTable.isVisualised == nil then createTable.isVisualised = createTemplate.isVisualised end
    local visPtr = im.BoolPtr(createTable.isVisualised ~= false)
    im.SameLine(0, 24)
    im.Checkbox(displayNameForConfigKey('isVisualised') .. '##rosStickVis' .. sid, visPtr)
    fieldCatalog.setConfigKeyItemTooltip('isVisualised')
    createTable.isVisualised = visPtr[0]
  end
end

local function drawRatesSection(editorState, sensor, defaultEntry)
  local typeKey = utilRos.getSensorType(sensor.type)
  if not TYPES_WITH_UPDATE_RATE[typeKey] then return end

  widgets.drawRosCategoryHeader('Rates and publishing')
  drawPublishLimiterToggle(sensor, defaultEntry)
  if sensor.config.publish_mode ~= 'max' then
    drawUpdateRateHz(editorState, sensor, defaultEntry)
  end
end

local function drawSensorParametersSection(editorState, sensor, defaultEntry, createTable, createTemplate)
  local otherKeys = collectNonPlacementCreateKeys(sensor, createTemplate)
  local typeKey = utilRos.getSensorType(sensor.type)
  local typeDrawer = SENSOR_PARAMETER_DRAWERS[typeKey]
  if not typeDrawer and #otherKeys < 1 then return end

  widgets.drawRosCategoryHeader('Sensor parameters')
  if typeDrawer then typeDrawer(editorState, sensor, defaultEntry, createTable) end
  for _, key in ipairs(otherKeys) do
    widgets.drawConfigKeyControl(editorState, createTable, key, createTemplate[key], 'create')
  end
end

local function drawSensorConfigSections(editorState, sensor, defaultEntry)
  sensor.config = sensor.config or {}
  local createTemplate = defaultEntry and defaultEntry.config and defaultEntry.config.create
  local hasCreate = createTemplate and next(createTemplate) ~= nil
  local createTable = hasCreate and persistence.ensureSensorCreateTable(sensor) or nil

  if hasCreate then drawPlacementSection(editorState, sensor, createTable, createTemplate) end
  drawRatesSection(editorState, sensor, defaultEntry)
  if hasCreate then drawSensorParametersSection(editorState, sensor, defaultEntry, createTable, createTemplate) end
end

local function drawScalarFieldSubsetControls(editorState, sensor, defaultEntry, idx0)
  local hasFields = defaultEntry and defaultEntry.fields and #defaultEntry.fields > 0
  if not hasFields then
    sensor.restrictFields = false
    sensor.fields = nil
    return
  end

  editorState.publishAllScalarsPtr[0] = not sensor.restrictFields
  im.Checkbox('Publish all default signals##rosAllFields', editorState.publishAllScalarsPtr)
  im.SetItemTooltip('When off, use the table below to publish only selected scalar fields.')
  local wantSubsetOnly = not editorState.publishAllScalarsPtr[0]
  if wantSubsetOnly ~= sensor.restrictFields then
    sensor.restrictFields = wantSubsetOnly
    if sensor.restrictFields then
      sensor.fields = {}
      for _, field in ipairs(defaultEntry.fields) do
        if type(field) == 'table' and field.name then
          sensor.fields[#sensor.fields + 1] = field.name
        end
      end
    else
      sensor.fields = nil
    end
    editorState.invalidateSensorIdBuffer()
  end

  if sensor.restrictFields then
    widgets.drawRosCategoryHeader('Scalar channels')
    drawScalarChannelsTable(editorState, sensor, defaultEntry, idx0,
      persistence.getSelectedVehicleId(editorState))
  end
end

local function drawSelectedSensorInspector(editorState, draftWork)
  local sensorCount = #draftWork.sensors
  if sensorCount < 1 then
    im.TextWrapped('No sensors yet. Add one using the sensor type grid above the list.')
    return
  end

  local idx0 = math.max(0, math.min(sensorCount - 1, editorState.selectedSensorRowIndex[0]))
  editorState.selectedSensorRowIndex[0] = idx0
  local sensor = draftWork.sensors[idx0 + 1]
  if not sensor then return end

  widgets.drawRosCategoryHeader('ROS 2 topic')
  fieldCatalog.drawSensorTypeIcon(sensor.type, im.ImVec2(22 * im.uiscale[0], 22 * im.uiscale[0]))
  im.SameLine()
  im.AlignTextToFramePadding()
  im.Text(string.format('Sensor %d / %d', idx0 + 1, sensorCount))

  syncSensorIdEditBuffer(editorState, draftWork, idx0 + 1)
  im.InputText('Sensor id##rosSensorId', editorState.sensorIdEditBuffer, CONSTANTS.ROS_EDITOR_SENSOR_ID_BUFFER)
  im.SetItemTooltip('Unique id in the vehicle ROS config; used for topics and internal routing.')
  sensor.id = ffi.string(editorState.sensorIdEditBuffer)

  local defaultEntry = persistence.getDefaultSensorEntry(editorState, sensor.type or '')
  drawScalarFieldSubsetControls(editorState, sensor, defaultEntry, idx0)
  drawSensorConfigSections(editorState, sensor, defaultEntry)
end

M.drawSelectedSensorInspector = drawSelectedSensorInspector

return M
