-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local utilRos = require('tech/ros/util')

local M = {}

M.CREATE_KEY_DISPLAY_ORDER = {
  'size', 'resolution',
  'fovY', 'nearFarPlanes',
  'verticalResolution', 'horizontalResolution',
  'verticalAngle', 'horizontalAngle',
  'frequency', 'minDistance', 'maxDistance', 'isRotate', 'is360', 'isAnnotated',
  'rangeMin', 'rangeMax', 'halfAngleDeg', 'velMin', 'velMax',
  'rangeMinCutoff', 'rangeDirectMaxCutoff',
  'refLon', 'refLat',
  'smootherStrength', 'isUsingGravity', 'isAllowWheelNodes',
  'renderColours', 'renderAnnotations', 'renderDepth',
  'autoExposure', 'manualExposure',
  'isVisualised',
}

local CREATE_KEY_RANK = {}
for index, key in ipairs(M.CREATE_KEY_DISPLAY_ORDER) do
  CREATE_KEY_RANK[key] = index
end

M.CONFIG_KEY_DISPLAY_NAMES = {
  pos = 'Position (vehicle space)',
  dir = 'Direction (vehicle space)',
  up = 'Up vector (vehicle space)',
  size = 'Resolution (width x height, px)',
  update_rate_hz = 'Update rate (Hz)',
  fovY = 'Vertical field of view (°)',
  nearFarPlanes = 'Near / far planes (m)',
  renderColours = 'Render colours',
  renderAnnotations = 'Render annotations',
  renderDepth = 'Render depth',
  autoExposure = 'Auto exposure',
  manualExposure = 'Manual exposure',
  isVisualised = 'Show sensor in scene',
  isUsingGravity = 'Use gravity',
  refLon = 'Reference longitude',
  refLat = 'Reference latitude',
  rangeMinCutoff = 'Range minimum (m)',
  rangeDirectMaxCutoff = 'Range maximum (m)',
  smootherStrength = 'IMU smoothing strength',
  isAllowWheelNodes = 'Wheel nodes affect center of mass',
  verticalResolution = 'Vertical resolution (rays)',
  horizontalResolution = 'Horizontal resolution (rays)',
  verticalAngle = 'Vertical FOV (°)',
  horizontalAngle = 'Horizontal FOV (°)',
  frequency = 'Spin frequency (Hz)',
  minDistance = 'Min range (m)',
  maxDistance = 'Max range (m)',
  isRotate = 'Rotating lidar',
  is360 = '360° scan',
  isAnnotated = 'Annotated points',
  rangeBins = 'Range bins',
  azimuthBins = 'Azimuth bins',
  velBins = 'Velocity bins',
  rangeMin = 'Range min (m)',
  rangeMax = 'Range max (m)',
  halfAngleDeg = 'Horizontal half-angle (°)',
  velMin = 'Velocity min (m/s)',
  velMax = 'Velocity max (m/s)',
}

M.CONFIG_KEY_TOOLTIPS = {
  pos = 'Position along vehicle forward (X), right (Y), and up (Z).',
  dir = 'Direction vector along vehicle forward (X), right (Y), and up (Z).',
  up = 'Up vector along vehicle forward (X), right (Y), and up (Z).',
  size = 'Width and height in pixels (sensor buffer / render target).',
  update_rate_hz = 'Target update and publish rate (Hz) when the framerate limiter is enabled.',
  fovY = 'Vertical field of view in degrees.',
  nearFarPlanes = 'Near and far clip distances in metres.',
  renderColours = 'Capture the colour image.',
  renderAnnotations = 'Capture semantic annotations.',
  renderDepth = 'Capture the depth buffer.',
  autoExposure = 'Match main camera exposure.',
  manualExposure = 'Fixed linear exposure when auto is off (must be > 0).',
  isVisualised = 'Draw the sensor gizmo / debug visualization in the scene.',
  isUsingGravity = 'Include gravity in reported IMU acceleration.',
  refLon = 'Reference longitude for reported positions (degrees).',
  refLat = 'Reference latitude for reported positions (degrees).',
  rangeMinCutoff = 'Minimum range reported by the ultrasonic model (m).',
  rangeDirectMaxCutoff = 'Maximum direct range for the ultrasonic model (m).',
  smootherStrength = 'Low-pass smoothing strength for IMU outputs.',
  isAllowWheelNodes = 'When enabled, wheel node masses are included in the reported center of mass.',
  verticalResolution = 'Number of vertical lidar channels.',
  horizontalResolution = 'Number of horizontal angular samples (used with vertical count for ROS blob max points).',
  verticalAngle = 'Vertical field of view (degrees).',
  horizontalAngle = 'Horizontal field of view (degrees).',
  frequency = 'Spin / scan repeat rate (Hz).',
  minDistance = 'Minimum range in metres (closest returned hits).',
  maxDistance = 'Maximum range in metres.',
  isRotate = 'Use a rotating lidar motion model.',
  is360 = 'Full 360 degree horizontal coverage.',
  isAnnotated = 'Include annotation data in lidar points.',
}

M.AXIS_LABEL_COLORS = {
  im.ImVec4(0.88, 0.32, 0.32, 1), -- Red
  im.ImVec4(0.38, 0.78, 0.38, 1), -- Green
  im.ImVec4(0.40, 0.52, 0.95, 1), -- Blue
}

M.SENSOR_TYPE_ICON_ATLAS_NAMES = {
  camera = 'survellianceCamera',
  gps = 'public',
  advancedimu = 'gyroscope',
  lidar = 'carWithLidar',
  radar = 'radar',
  ultrasonic = 'proximitySensorsOutline',
  electrics = 'flash_on',
  gforces = 'trending_flat',
  state = 'directions_car',
  time = 'schedule',
  idealradar = 'radarIdeal',
  roads = 'roadInfo',
  powertrain = 'drivetrainGeneric',
  mesh = 'mesh9Cells',
  damage = 'warning',
}

function M.sortNonPlacementCreateKeys(keys)
  table.sort(keys, function(a, b)
    local ra = CREATE_KEY_RANK[a] or math.huge
    local rb = CREATE_KEY_RANK[b] or math.huge
    if ra ~= rb then return ra < rb end
    return tostring(a) < tostring(b)
  end)
end

function M.displayNameForConfigKey(key)
  return M.CONFIG_KEY_DISPLAY_NAMES[key] or tostring(key)
end

function M.setConfigKeyItemTooltip(key)
  local tip = M.CONFIG_KEY_TOOLTIPS[key]
  if tip then im.SetItemTooltip(tip) end
end

function M.sensorTypeIs(sensor, typeKeyLowercase)
  return utilRos.getSensorType(sensor and sensor.type) == typeKeyLowercase
end

function M.floatFormatString(editorState)
  if editorState.cachedFloatFormatString then return editorState.cachedFloatFormatString end
  local digits = (editor.getPreference and editor.getPreference('ui.general.floatDigitCount')) or 3
  editorState.cachedFloatFormatString = '%0.' .. tostring(digits) .. 'f'
  return editorState.cachedFloatFormatString
end

function M.resolveSensorTypeIcon(sensorTypeName)
  if not editor.icons or not sensorTypeName then return nil end
  local iconName = M.SENSOR_TYPE_ICON_ATLAS_NAMES[sensorTypeName:lower()]
  if iconName then return editor.icons[iconName] end
  return editor.icons.lens or editor.icons.code
end

function M.drawSensorTypeIcon(sensorTypeName, pixelSize)
  local iconTexture = M.resolveSensorTypeIcon(sensorTypeName)
  if iconTexture then
    editor.uiIconImage(iconTexture, pixelSize)
    im.SameLine()
  end
end

return M
