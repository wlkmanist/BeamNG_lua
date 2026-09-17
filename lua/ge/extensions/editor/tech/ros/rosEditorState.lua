-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local im = ui_imgui
local CONSTANTS = require('tech/ros/constants')

local M = {}

M.LOG_TAG = 'ros2Editor'
M.WINDOW_ID = 'ros2Editor###main'
M.WINDOW_SIZE = im.ImVec2(720, 520)
M.EDIT_MODE_TITLE = 'ROS 2 Editor'

M.isPanelActive = false
M.sceneVehicleRows = {}
M.selectedVehicleRowIndex = 1
M.draftWorkByVehicleId = {}
M.rosDefaultsDocument = nil
M.rosLibLoadError = nil
M.sensorTypeNamesInOrder = {}
M.selectedSensorRowIndex = im.IntPtr(0)
M.sensorIdEditBuffer = nil
M.sensorIdBufferCacheKey = ''
M.publishAllScalarsPtr = im.BoolPtr(false)
M.scalarFieldRowPtr = im.BoolPtr(false)
M.stickToVehiclePtr = im.BoolPtr(true)
M.scalarFieldFilterBuffer = im.ArrayChar(CONSTANTS.ROS_EDITOR_IMGUI_TEXT_BUFFER, '')
M.scalarFieldFilterContext = ''
M.rosGizmoBeginRotation = quat(0, 0, 0, 1)

function M.invalidateSensorIdBuffer()
  M.sensorIdBufferCacheKey = ''
end

return M
