-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local CONSTANTS = require('tech/ros/constants')
local sensorConfigUtil = require('editor/tech/sensorConfiguration/utilities')
local persistence = require('editor/tech/ros/rosEditorPersistence')
local fieldCatalog = require('editor/tech/ros/editorFieldCatalog')
local dbgDraw = require('utils/debugDraw')

local M = {}

local function vec3FromArray(arr, dx, dy, dz)
  if type(arr) == 'table' and type(arr[1]) == 'number' and type(arr[2]) == 'number' and type(arr[3]) == 'number' then
    return vec3(arr[1], arr[2], arr[3])
  end
  return vec3(dx, dy, dz)
end

local function orthonormalCoeffBasis(dirWorld, upWorld, crossEps)
  local fwd = dirWorld:normalized()
  local up = upWorld:normalized()
  local right = fwd:cross(up)
  local rightLength = right:length()
  if rightLength < crossEps then
    right = vec3(0, 0, 1):cross(fwd)
    rightLength = right:length()
  end
  right = right / rightLength
  up = right:cross(fwd):normalized()
  return fwd, right, up
end

local function rosGizmoMatrixAt(worldPos, dirWorld, upWorld, crossEps)
  local fwd, right, up = orthonormalCoeffBasis(dirWorld, upWorld, crossEps)
  local m = MatrixF(true)
  m:setColumn(0, fwd)
  m:setColumn(1, right)
  m:setColumn(2, up)
  m:setColumn(3, worldPos)
  return m
end

local function renderRosCoeffPositionAxes(posWorld, dirWorld, upWorld, lineWidth, crossEps)
  local fwd, right, up = orthonormalCoeffBasis(dirWorld, upWorld, crossEps)
  local cx, cy, cz = color(255, 0, 0, 255), color(0, 255, 0, 255), color(0, 0, 255, 255)
  dbgDraw.drawLineInstance_MinArg(posWorld, posWorld + fwd, lineWidth, cx)
  dbgDraw.drawLineInstance_MinArg(posWorld, posWorld + right, lineWidth, cy)
  dbgDraw.drawLineInstance_MinArg(posWorld, posWorld + up, lineWidth, cz)
end

local function worldForwardUpFromCreate(createTable, vehicleObj)
  local dirCoeff = vec3FromArray(createTable.dir, 1, 0, 0)
  local upCoeff = vec3FromArray(createTable.up, 0, 0, 1)
  local dirWorld = sensorConfigUtil.coeffs2PosVS(dirCoeff, vehicleObj):normalized()
  local upWorld = sensorConfigUtil.coeffs2PosVS(upCoeff, vehicleObj):normalized()
  return dirWorld, upWorld
end

local function worldPosFromCreateCoeffs(createTable, vehicleObj)
  local posCoeff = vec3(createTable.pos[1], createTable.pos[2], createTable.pos[3])
  return sensorConfigUtil.coeffs2PosVS(posCoeff, vehicleObj) + vehicleObj:getPosition()
end

local function beamProxyFromEffectiveCreate(createTable)
  return {
    rangeRoundness = createTable.rangeRoundness or -1.15,
    rangeCutoffSensitivity = createTable.rangeCutoffSensitivity or 1,
    rangeShape = createTable.rangeShape or 1,
    rangeFocus = createTable.rangeFocus or 0.1,
    rangeMinCutoff = createTable.rangeMinCutoff or 0.1,
    rangeDirectMaxCutoff = createTable.rangeDirectMaxCutoff or 50,
  }
end

local function isRosWorldEditModeActive(editorState)
  return editor.editMode and editor.editMode.displayName == editorState.EDIT_MODE_TITLE
end

-- Resolves selected vehicle, sensor, and its default-entry. Returns nil tuple if anything is missing.
local function tryGetGizmoContext(editorState)
  local vehicleId = persistence.getSelectedVehicleId(editorState)
  if not vehicleId then return nil end
  local vehicleObj = be:getObjectByID(vehicleId)
  if not vehicleObj then return nil end
  local draftWork = editorState.draftWorkByVehicleId[vehicleId]
  if not draftWork then return nil end
  local sensor = draftWork.sensors[editorState.selectedSensorRowIndex[0] + 1]
  if not sensor then return nil end
  local defaultEntry = persistence.getDefaultSensorEntry(editorState, sensor.type)
  if not defaultEntry then return nil end
  return vehicleObj, sensor, defaultEntry
end

local function gizmoBeginDrag(editorState)
  local vehicleObj, sensor, defaultEntry = tryGetGizmoContext(editorState)
  if not vehicleObj then return end
  local createTable = persistence.effectiveSensorCreateTable(sensor, defaultEntry)
  local dirWorld, upWorld = worldForwardUpFromCreate(createTable, vehicleObj)
  editorState.rosGizmoBeginRotation = quatFromDir(dirWorld, upWorld)
end

local function gizmoDragging(editorState)
  if not isRosWorldEditModeActive(editorState) then return end
  local vehicleObj, sensor = tryGetGizmoContext(editorState)
  if not vehicleObj then return end
  local createTable = persistence.ensureSensorCreateTable(sensor)
  local mode = editor.getAxisGizmoMode()

  if mode == editor.AxisGizmoMode_Translate then
    local posVS = editor.getAxisGizmoTransform():getColumn(3) - vehicleObj:getPosition()
    local posCoeff = sensorConfigUtil.posVS2Coeffs(posVS, vehicleObj)
    createTable.pos = { posCoeff.x, posCoeff.y, posCoeff.z }
    return
  end

  if mode == editor.AxisGizmoMode_Rotate then
    local rotMat = editor.getAxisGizmoTransform()
    local q2 = QuatF(0, 0, 0, 1)
    q2:setFromMatrix(rotMat)
    local dir, up
    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      dir = vec3(rotMat:getColumn(0)):normalized()
      up = vec3(rotMat:getColumn(2)):normalized()
    else
      local quatRot = editorState.rosGizmoBeginRotation * quat(q2)
      dir, up = quatRot:toDirUp()
    end
    local dirSensor, upSensor = sensorConfigUtil.vS2Sensor(dir, up, vehicleObj)
    createTable.dir = { dirSensor.x, dirSensor.y, dirSensor.z }
    createTable.up = { upSensor.x, upSensor.y, upSensor.z }
  end
end

local function handleRosSensorGimbals(editorState, worldPos, dirWorld, upWorld)
  local transform
  if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
    transform = rosGizmoMatrixAt(worldPos, dirWorld, upWorld, CONSTANTS.ROS_EDITOR_ORTHONORMAL_CROSS_EPS)
  else
    transform = MatrixF(true)
    transform:setColumn(3, worldPos)
  end
  editor.setAxisGizmoTransform(transform)
  editor.updateAxisGizmo(
    function() gizmoBeginDrag(editorState) end,
    function() end,
    function() gizmoDragging(editorState) end)
  editor.drawAxisGizmo()
end

local function drawAllSensorPreviews(editorState, draftWork, vehicleObj)
  for i = 1, #draftWork.sensors do
    local sensor = draftWork.sensors[i]
    local defaultEntry = persistence.getDefaultSensorEntry(editorState, sensor.type)
    if defaultEntry then
      local createTable = persistence.effectiveSensorCreateTable(sensor, defaultEntry)
      if createTable.pos then
        local pos = worldPosFromCreateCoeffs(createTable, vehicleObj)
        local dirWorld, upWorld = worldForwardUpFromCreate(createTable, vehicleObj)
        local rightWorld = dirWorld:cross(upWorld)
        sensorConfigUtil.renderSensorBoxAndFrame(pos, dirWorld, upWorld, rightWorld)
        if fieldCatalog.sensorTypeIs(sensor, 'ultrasonic') or fieldCatalog.sensorTypeIs(sensor, 'radar') then
          sensorConfigUtil.renderBeamShape(beamProxyFromEffectiveCreate(createTable),
            pos, dirWorld, upWorld, rightWorld)
        end
      end
    end
  end
end

function M.drawRosViewportSensorOverlays(editorState)
  if not editorState.isPanelActive or not isRosWorldEditModeActive(editorState) then return end
  local vehicleId = persistence.getSelectedVehicleId(editorState)
  if not vehicleId then return end
  local vehicleObj = be:getObjectByID(vehicleId)
  if not vehicleObj then return end
  local draftWork = editorState.draftWorkByVehicleId[vehicleId]
  if not draftWork then return end

  drawAllSensorPreviews(editorState, draftWork, vehicleObj)

  local sensor = draftWork.sensors[editorState.selectedSensorRowIndex[0] + 1]
  if not sensor then return end
  local defaultEntry = persistence.getDefaultSensorEntry(editorState, sensor.type)
  if not defaultEntry then return end
  local createTable = persistence.effectiveSensorCreateTable(sensor, defaultEntry)
  if not createTable.pos then return end

  local dirWorld, upWorld = worldForwardUpFromCreate(createTable, vehicleObj)
  local worldPos = worldPosFromCreateCoeffs(createTable, vehicleObj)
  handleRosSensorGimbals(editorState, worldPos, dirWorld, upWorld)
  renderRosCoeffPositionAxes(worldPos, dirWorld, upWorld,
    CONSTANTS.ROS_EDITOR_DEBUG_AXIS_LINE_WIDTH, CONSTANTS.ROS_EDITOR_ORTHONORMAL_CROSS_EPS)
end

return M
