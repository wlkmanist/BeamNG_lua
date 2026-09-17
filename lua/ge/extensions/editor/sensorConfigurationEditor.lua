-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

if not Research then return M end

local logTag = 'sensorConfigurationEditor'

-- External modules used.
local util = require('editor/tech/sensorConfiguration/utilities')                                   -- A utility class for the sensor configuration editors.
local conversions = require('editor/tech/sensorConfiguration/conversions')                          -- A utility class for the sensor configuration editors.
local techUtils = require('tech/techUtils')

-- Module constants.
local im = ui_imgui
local abs, min, max, floor, ceil = math.abs, math.min, math.max, math.floor, math.ceil
local sqrt, pow = math.sqrt, math.pow

-- Module constants (UI).
local toolWinName, toolWinSize = 'SensorConfigurationEditor', im.ImVec2(300, 230)                   -- The main tool window of the editor. The main UI entry point.
local attachedSensorsWinName, attachedSensorsWinSize = 'AttachedSensorsWindow', im.ImVec2(230, 290) -- The per-vehicle 'attached sensors' window.
local sensorPropWinName, sensorPropWinSize = 'SensorPropertiesWindow', im.ImVec2(290, 880)          -- The per-sensor 'sensor properties' window.
local isAttachedSensorsWinOpen = false
local isSensorPropWinOpen = false
local stype = extensions.tech_sensors.stype
local previewConfigs = {
  [stype.tCamera] = {
    winBaseName = 'CameraPreviewWindow',
    winSize = im.ImVec2(290, 600),
    render = nil,
    cleanup = function(sensor) extensions.tech_cameraPreview.stopVisualizeCameraById(sensor.id) end,
    icon = nil,
    buttonId = 'previewSensorButton',
    tooltip = 'Preview camera outputs.',
    openPreviews = {}
  },
  [stype.tIMU] = {
    winBaseName = 'IMUPreviewWindow',
    winSize = im.ImVec2(290, 600),
    render = nil,
    cleanup = nil,
    icon = nil,
    buttonId = 'previewIMUSensorButton',
    tooltip = 'Preview IMU sensor data.',
    openPreviews = {}
  },
  [stype.tUltrasonic] = {
    winBaseName = 'UltrasonicPreviewWindow',
    winSize = im.ImVec2(400, 200),
    render = nil,
    cleanup = nil,
    icon = nil,
    buttonId = 'previewUltrasonicSensorButton',
    tooltip = 'Preview Ultrasonic sensor data.',
    openPreviews = {}
  }
}
local previewIdCounter = 0
local ctrSensor = {                                                                                 -- Incrementable unique id counters for each sensor type.
  [stype.tCamera] = 1,
  [stype.tLiDAR] = 1,
  [stype.tUltrasonic] = 1,
  [stype.tRADAR] = 1,
  [stype.tIMU] = 1,
  [stype.tGPS] = 1
}
local dullWhite = im.ImVec4(1, 1, 1, 0.5)                                                           -- Some commonly-used Imgui colour vectors.
local redB = im.ImVec4(0.7, 0.5, 0.5, 1)
local greenB, greenD = im.ImVec4(0.5, 0.7, 0.5, 1), im.ImVec4(0.5, 0.7, 0.5, 0.5)
local blueB, blueD = im.ImVec4(0.5, 0.5, 0.7, 1), im.ImVec4(0.5, 0.5, 0.7, 0.5)
local gray = im.ImVec4(0.5, 0.5, 0.5, 1)
local sensorIcon = im.ImVec2(32, 32)                                                                -- Some commonly-used Imgui icon size vectors.
local beginDragRotation = vec3(0, 0)

-- Module state (back-end).
local vehicles = {}                                                                                 -- An ordered list of all vehicles currently in the scene.
local sensorConfigs = {}                                                                            -- An ordered list of attached sensors, for all vehicles, keyed by id.
local selectedVehicleIdx = 1                                                                        -- The index of the selected vehicle, in the vehicles list.
local selectedSensorIdx = 1                                                                         -- The index of the selected sensor, in the attached sensors list.
local isSensorConfigurationEditor = false                                                           -- A flag which indicates if this editor is currently active.
local isPlaceMode = false                                                                           -- A flag which indicates if the editor is in 'place sensor' mode, or not.
local placing = nil                                                                                 -- The type of sensor being placed, when using 'place sensor' mode.
local poiData = {}                                                                                  -- A table containing the collected POI data from vlua.
local isVluaDataReturned = false                                                                    -- A flag which indicates if requested vlua data has been returned to ge lua.
local isRequestSent = false                                                                         -- A flag which indicates if a request has been sent to vlua.

local pythonCodeLen = 4096
local pythonCodePtr = im.ArrayChar(pythonCodeLen)

local plotLen = 600
local plotOffset = 0
local plotSize = im.ImVec2(500, 70)
local imuPlotData = {}

-- The callback function for use when collecting vehicle POI data from vlua.
local function updateCollectedVehiclePOIData(collectedData)
  poiData, isVluaDataReturned = lpack.decode(collectedData), true
end

-- The callback function for begin axis gizmo dragging.
local function gizmoBeginDrag()
  local vehicle = vehicles[selectedVehicleIdx]
  local vid, veh = vehicle.vid, vehicle.veh
  local sensors = sensorConfigs[vid]
  local s = sensors[selectedSensorIdx]
  local dir, up = util.sensor2VS(s.dir, s.up, veh)
  beginDragRotation = quatFromDir(dir, up)
end

-- The callback function for end axis gizmo dragging.
local function gizmoEndDrag()
end

-- The callback function for continuing axis gizmo dragging.
local function gizmoDragging()
  local vehicle = vehicles[selectedVehicleIdx]
  local vid, veh = vehicle.vid, vehicle.veh
  local sensors = sensorConfigs[vid]
  local s = sensors[selectedSensorIdx]
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Translate then                               -- Handle dragging on the translation gizmo.
    local posVS = editor.getAxisGizmoTransform():getColumn(3) - veh:getPosition()
    local c = util.posVS2Coeffs(posVS, veh)
    s.pos:set(c.x, c.y, c.z)
    return
  end
  if editor.getAxisGizmoMode() == editor.AxisGizmoMode_Rotate then                                  -- Handle dragging on the rotational gizmo.
    local rotMat = editor.getAxisGizmoTransform()
    local q2 = QuatF(0, 0, 0, 1)
    q2:setFromMatrix(rotMat)
    if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
      local q = quat(q2)
      local dir, up = q:toDirUp()
      s.dir, s.up = util.vS2Sensor(dir, up, veh)
    else
      local q = beginDragRotation * quat(q2)
      local dir, up = q:toDirUp()
      s.dir, s.up = util.vS2Sensor(dir, up, veh)
    end
  end
end

-- Handles the gimbals for translational and rotational adjustment of sensor poses.
local function handleGimbals(pos)
  local rotation = nil
  if editor.getAxisGizmoAlignment() == editor.AxisGizmoAlignment_Local then
    local vehicle = vehicles[selectedVehicleIdx]
    local vid, veh = vehicle.vid, vehicle.veh
    local sensors = sensorConfigs[vid]
    local s = sensors[selectedSensorIdx]
    local dir, up = util.sensor2VS(s.dir, s.up, veh)
    local q = quatFromDir(dir, up)
    rotation = QuatF(q.x, q.y, q.z, q.w)
  else
    rotation = QuatF(0, 0, 0, 1)
  end
  local transform = rotation:getMatrix()
  transform:setPosition(pos)
  editor.setAxisGizmoTransform(transform)
  editor.updateAxisGizmo(gizmoBeginDrag, gizmoEndDrag, gizmoDragging)
  editor.drawAxisGizmo()
end

-- Populate the current vehicles list.
local function getCurrentVehicleList()
  table.clear(vehicles)
  local ctr = 1
  for vid, veh in activeVehiclesIterator() do
    vehicles[ctr] = {
      vid = vid, veh = veh, name = veh:getName(),
      jBeam = veh.JBeam, config = veh:getField('partConfig', '0')}
    ctr = ctr + 1
    if not sensorConfigs[vid] then
      sensorConfigs[vid] = {}                                                                       -- If there is no allocated space for this vehicle, allocate it now.
    end
  end
end

-- Determines if the given sensor collection contains a sensor of the given type, or not.
local function doesContainSensorType(sensors, t)
  if sensors then
    local numSensors = #sensors
    for i = 1, numSensors do
      if sensors[i].type == t then
        return true
      end
    end
  end
  return false
end

-- Counts the number of sensors of the given type, in the given collection.
-- [Also returns the id for each, in a table].
local function numberOfSensorType(sensors, t)
  local ctr, ids = 0, {}
  if sensors then
    local numSensors = #sensors
    for i = 1, numSensors do
      if sensors[i].type == t then
        ctr = ctr + 1
        ids[ctr] = i
      end
    end
  end
  return ctr, ids
end

-- Handles the finishing of placing a sensor.
local function handleFinishPlacingSensor(posVS)
  local vehicle = vehicles[selectedVehicleIdx]
  local vid, veh = vehicle.vid, vehicle.veh
  local sensors = sensorConfigs[vid]
  local pos = util.posVS2Coeffs(posVS, veh)
  local newSensor = conversions.createNewSensor(placing, ctrSensor[placing], pos)
  if newSensor ~= nil then
    sensors[#sensors + 1] = newSensor
    ctrSensor[placing] = ctrSensor[placing] + 1
  end
  isPlaceMode, placing = false, nil
  selectedSensorIdx = #sensors
end

-- Handles the switching between 'edit mode' and 'live mode', for a given sensor.
local function handleEditLiveModeSwitch(sensors, idx)
  local vehicle = vehicles[selectedVehicleIdx]
  if sensors[idx].isLive then
    conversions.makeSensorLive(sensors[idx], vehicle)
  else
    conversions.makeSensorNotLive(sensors[idx], vehicle)
  end
end

-- Handles the placing of sensors.
-- [Note: not all sensors require placement].
local function handlePlaceSensor()
  local ray = getCameraMouseRay()
  local rayPos, rayDir = ray.pos, ray.dir
  local vehicle = vehicles[selectedVehicleIdx]
  local pInt = Research.SensorMatrixManager.intersectRayMesh(vehicle.vid, rayPos, rayDir)
  if pInt:squaredLength() > 1e-7 then
    util.drawMouseSphere(pInt)
    if im.IsMouseClicked(0) then
      handleFinishPlacingSensor(pInt - vehicle.veh:getPosition())
    end
  end
end

local function findPreview(sensorType, vehicleIdx, sensorIdx)
  local config = previewConfigs[sensorType]
  if not config then return nil end
  for i, preview in ipairs(config.openPreviews) do
    if preview.vehicleIdx == vehicleIdx and preview.sensorIdx == sensorIdx then
      return preview, i
    end
  end
  return nil
end

local function addPreview(sensorType, vehicleIdx, sensorIdx)
  previewIdCounter = previewIdCounter + 1
  local config = previewConfigs[sensorType]
  local winName = config.winBaseName .. previewIdCounter
  local preview = {
    vehicleIdx = vehicleIdx,
    sensorIdx = sensorIdx,
    winName = winName,
    id = previewIdCounter
  }
  table.insert(config.openPreviews, preview)
  editor.registerWindow(winName, config.winSize)
  return preview
end

local function removePreview(sensorType, previewIdx)
  local config = previewConfigs[sensorType]
  if config and config.openPreviews[previewIdx] then
    editor.hideWindow(config.openPreviews[previewIdx].winName)
    table.remove(config.openPreviews, previewIdx)
  end
end

-- Removes the given sensor.
local function removeSensor(sensors, idx)
  local sensor = sensors[idx]
  sensor.isLive = false
  handleEditLiveModeSwitch(sensors, idx)
  if sensor.type == stype.tIMU and sensor.id then
    imuPlotData[sensor.id] = nil
  end
  local config = previewConfigs[sensor.type]
  if config then
    for i = #config.openPreviews, 1, -1 do
      local preview = config.openPreviews[i]
      if preview.vehicleIdx == selectedVehicleIdx then
        if preview.sensorIdx == idx then
          removePreview(sensor.type, i)
        elseif preview.sensorIdx > idx then
          preview.sensorIdx = preview.sensorIdx - 1
        end
      end
    end
  end
  table.remove(sensors, idx)
end

local function getPythonCode()
  local vehicle = vehicles[selectedVehicleIdx]
  local sensors = sensorConfigs[vehicle.vid]

  extensions.tech_pythonExport.getFullConfig(vehicle.veh, sensors, pythonCodePtr)
end

-- Saves the current sensor configuration to disk.
local function saveConfiguration()
  extensions.editor_fileDialog.saveFile(
    function(data)
      local vehicle = vehicles[selectedVehicleIdx]
      local d = {
        jBeam = vehicle.jBeam,
        config = vehicle.config,
        sensors = sensorConfigs[vehicle.vid] }
      jsonWriteFile(data.filepath, d, true)
    end,
    {{"JSON",".json"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Loads a previously-saved sensor configuration from disk.
local function loadConfiguration()
  extensions.editor_fileDialog.openFile(
    function(data)
      local vehicle = vehicles[selectedVehicleIdx]
      local vid = vehicle.vid
      local loadedJson = jsonReadFile(data.filepath)
      local d = loadedJson.data and lpack.decode(loadedJson.data) or techUtils.tableToVec3Recursive(loadedJson)
      d = techUtils.migrateOldKeysRecursive(d)
      if vehicle.jBeam ~= d.jBeam or vehicle.config ~= d.config then
        log('W', logTag, 'The selected vehicle does not fully match the vehicle stored with the configuration -- some sensors may attach at the wrong positions.')
      end
      local oldSensors = sensorConfigs[vid]
      for i = #oldSensors, 1, -1 do
        removeSensor(oldSensors, i)
      end
      table.clear(sensorConfigs[vid])
      local sensors = d.sensors
      local numSensors = #sensors
      for i = 1, numSensors do
        sensors[i].isLive = false
        sensorConfigs[vid][i] = sensors[i]
      end
    end,
    {{"JSON",".json"}},
    false,
    "/")
end

-- Manages the main tool window.
local function manageMainToolWindow()
  if editor.beginWindow(toolWinName, "Scene Vehicles###210", im.WindowFlags_NoTitleBar) then
    im.Separator()
    if im.BeginListBox("", im.ImVec2(287, 180), im.WindowFlags_ChildWindow) then
      local numVehicles = #vehicles
      selectedVehicleIdx = max(1, min(numVehicles, selectedVehicleIdx))
      for i = 1, numVehicles do
        local vehicle = vehicles[i]
        im.Columns(4, "sceneVehiclesListBoxColumns", false)
        im.SetColumnWidth(0, 175)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)
        im.SetColumnWidth(3, 32)

        -- Handle the individual row selection.
        local vName = tostring(vehicle.vid .. ": " .. vehicle.name .. " - " .. vehicle.jBeam)
        if im.Selectable1(vName, i == selectedVehicleIdx, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
          if i ~= selectedVehicleIdx then
            selectedVehicleIdx = i
            isRequestSent, isVluaDataReturned = false, false
          end
        end
        im.SameLine()
        im.NextColumn()

        -- 'Remove Vehicle' button.
        if #vehicles > 1 then
          if editor.uiIconImageButton(editor.icons.trashBin2, im.ImVec2(22, 22), redB, nil, nil, 'removeVehicleButton' .. i) then
            vehicles[i].veh:delete()
            selectedVehicleIdx = min(numVehicles, selectedVehicleIdx)
            editor.endWindow()
            return
          end
          im.tooltip('Remove this vehicle from scene.')
        end
        im.SameLine()
        im.NextColumn()

        -- 'Go To Vehicle' button.
        if editor.uiIconImageButton(editor.icons.cameraFocusOnVehicle2, im.ImVec2(21, 21), greenB, nil, nil, 'goToVehicleButton' .. i) then
          core_camera.setByName(0, "orbit", false)
          be:enterVehicle(0, scenetree.findObject(vehicle.vid))
          if i ~= selectedVehicleIdx then
            selectedVehicleIdx = i
          end
          isRequestSent, isVluaDataReturned = false, false
        end
        im.tooltip('Go to the selected vehicle.')
        im.SameLine()
        im.NextColumn()

        -- 'Open Attached Sensors Window' button.
        local btnCol = blueB
        if isAttachedSensorsWinOpen and i == selectedVehicleIdx then btnCol = blueD end
        if editor.uiIconImageButton(editor.icons.wifi, im.ImVec2(19, 19), btnCol, nil, nil, 'openAttachedSensorsWinButton' .. i) then
          if i == selectedVehicleIdx or not isAttachedSensorsWinOpen then
            isAttachedSensorsWinOpen = not isAttachedSensorsWinOpen                                 -- Only toggle window open/closed if this is the same vehicle.
          end
          if isAttachedSensorsWinOpen then                                                          -- If window is open and this is a different vehicle, just update the window.
            editor.showWindow(attachedSensorsWinName)
          else
            editor.hideWindow(attachedSensorsWinName)
          end
          selectedVehicleIdx = i
          isRequestSent, isVluaDataReturned = false, false
        end
        im.tooltip('Open the attached sensors window for this vehicle.')
        im.NextColumn()

        im.Separator()
      end
      im.EndListBox()
    end
    im.Separator()
  end
  editor.endWindow()
end

-- Manages the attached sensors window.
local function manageAttachedSensorsWindow()
  local veh = vehicles[selectedVehicleIdx]
  if veh then
    if editor.beginWindow(attachedSensorsWinName, veh.name .. " [sensors]###211", im.WindowFlags_AlwaysAutoResize) then
      im.Separator()
      local vid = veh.vid
      if not sensorConfigs[vid] then
        sensorConfigs[vid] = {}
      end
      local sensors = sensorConfigs[vid]
      local numSensors = #sensors
      if im.BeginListBox("", im.ImVec2(222, 180), im.WindowFlags_ChildWindow) then
        for i = 1, numSensors do
          im.Columns(4, "attachedSensorsListBoxColumns", false)
          im.SetColumnWidth(0, 110)
          im.SetColumnWidth(1, 32)
          im.SetColumnWidth(2, 32)
          im.SetColumnWidth(3, 32)

          -- Handle the individual row selection.
          local sensor = sensors[i]
          if im.Selectable1(sensor.name, i == selectedSensorIdx, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
            if i ~= selectedSensorIdx then
              selectedSensorIdx = i
              if sensor.isLive and isSensorPropWinOpen then
                editor.hideWindow(sensorPropWinName)
                isSensorPropWinOpen = false
              end
            end
          end
          im.SameLine()
          im.NextColumn()

          -- 'Remove Sensor' button.
          if editor.uiIconImageButton(editor.icons.trashBin2, im.ImVec2(22, 22), redB, nil, nil, 'removeSensorButton' .. i) then
            selectedSensorIdx = min(numSensors, selectedSensorIdx)
            removeSensor(sensors, i)
            editor.endWindow()
            return
          end
          im.tooltip('Remove this sensor from the configuration.')
          im.SameLine()
          im.NextColumn()

          -- 'Edit Sensor' button.
          -- [This is only available if the sensor is not live].
          if not sensor.isLive then
            local btnCol = greenB
            if isSensorPropWinOpen and i == selectedSensorIdx then btnCol = greenD end
            if editor.uiIconImageButton(editor.icons.build, im.ImVec2(21, 21), btnCol, nil, nil, 'editSensorButton' .. i) then
              if i == selectedSensorIdx or not isSensorPropWinOpen then
                isSensorPropWinOpen = not isSensorPropWinOpen                                       -- Only toggle window open/closed if this is the same sensor.
              end
              if isSensorPropWinOpen then                                                           -- If window is open and this is a different sensor, just update the fields.
                editor.showWindow(sensorPropWinName)
              else
                editor.hideWindow(sensorPropWinName)
              end
              selectedSensorIdx = i
            end
            im.tooltip('Edit the selected sensor.')
          else
            local config = previewConfigs[sensor.type]
            if config then
              local preview, previewIdx = findPreview(sensor.type, selectedVehicleIdx, i)
              local btnCol = greenB
              if preview then btnCol = greenD end
              if editor.uiIconImageButton(config.icon, im.ImVec2(21, 21), btnCol, nil, nil, config.buttonId .. i) then
                if preview then
                  removePreview(sensor.type, previewIdx)
                else
                  preview = addPreview(sensor.type, selectedVehicleIdx, i)
                  editor.showWindow(preview.winName)
                end
                isSensorPropWinOpen = false
                selectedSensorIdx = i
              end
              im.tooltip(config.tooltip)
            end
          end
          im.SameLine()
          im.NextColumn()

          -- 'Live Sensor' toggle button.
          local btnCol, btnIcon = blueB, editor.icons.wifi
          if sensor.isLive then btnCol, btnIcon = blueD, editor.icons.wifi_lock end
          if editor.uiIconImageButton(btnIcon, im.ImVec2(19, 19), btnCol, nil, nil, 'toggleLiveSensorButton' .. i) then
            sensor.isLive = not sensor.isLive
            handleEditLiveModeSwitch(sensors, i)
            if isSensorPropWinOpen and i == selectedSensorIdx then
              editor.hideWindow(sensorPropWinName)
              isSensorPropWinOpen = false
            end
            local preview, previewIdx = findPreview(sensor.type, selectedVehicleIdx, i)
            if preview then
              removePreview(sensor.type, previewIdx)
            end
          end
          im.tooltip('Toggle between Edit and Live modes.')
          im.NextColumn()

          im.Separator()
        end
        im.EndListBox()
      end
      im.Separator()

      -- 'Add Camera Sensor' button.
      if editor.uiIconImageButton(editor.icons.survellianceCamera, sensorIcon, greenB, nil, nil, 'addNewCamera') then
        placing, isPlaceMode = stype.tCamera, true
      end
      im.tooltip('Add a Camera Sensor to the configuration.')
      im.SameLine()

      -- 'Add LiDAR Sensor' button.
      if editor.uiIconImageButton(editor.icons.carWithLidar, sensorIcon, greenB, nil, nil, 'addNewLiDAR') then
        placing, isPlaceMode = stype.tLiDAR, true
      end
      im.tooltip('Add a LiDAR Sensor to the configuration.')
      im.SameLine()

      -- 'Add Ultrasonic Sensor' button.
      if editor.uiIconImageButton(editor.icons.proximitySensorsOutline, sensorIcon, greenB, nil, nil, 'addNewUltrasonic') then
        placing, isPlaceMode = stype.tUltrasonic, true
      end
      im.tooltip('Add an Ultrasonic Sensor to the configuration.')
      im.SameLine()

      -- 'Add RADAR Sensor' button.
      if editor.uiIconImageButton(editor.icons.radar, sensorIcon, greenB, nil, nil, 'addNewRADAR') then
        placing, isPlaceMode = stype.tRADAR, true
      end
      im.tooltip('Add a RADAR Sensor to the configuration.')
      im.SameLine()

      -- 'Add IMU Sensor' button.
      if editor.uiIconImageButton(editor.icons.gyroscope, sensorIcon, greenB, nil, nil, 'addNewIMU') then
        placing, isPlaceMode = stype.tIMU, true
      end
      im.tooltip('Add an IMU Sensor to the configuration.')
      im.SameLine()

      -- 'Add GPS Sensor' button.
      if editor.uiIconImageButton(editor.icons.public, sensorIcon, greenB, nil, nil, 'addNewGPS') then
        placing, isPlaceMode = stype.tGPS, true
      end
      im.tooltip('Add a GPS Sensor to the configuration.')

      -- Check if each of the one-time, non-placeable sensors are present in this configuration.
      local isIdealRadarSensor = doesContainSensorType(sensors, stype.tIdealRADAR)
      local isRoadsSensor = doesContainSensorType(sensors, stype.tRoads)
      local isPowertrainSensor = doesContainSensorType(sensors, stype.tPowertrain)
      local isMeshSensor = doesContainSensorType(sensors, stype.tMesh)

      -- 'Add Ideal RADAR Sensor' button.
      local btnCol = blueB
      if isIdealRadarSensor then btnCol = blueD end
      if editor.uiIconImageButton(editor.icons.radarIdeal, sensorIcon, btnCol, nil, nil, 'addNewIdealRADAR') then
        if not isIdealRadarSensor then                                                              -- There can be only one sensor of this type. No placing required.
          sensors[#sensors + 1] = {
            isLive = false,
            id = nil,
            name = 'Ideal RADAR',
            type = stype.tIdealRADAR,
            physicsUpdateTime = 0.015,
            GFXUpdateTime = 0.1 }
        end
      end
      im.tooltip('Add an Ideal RADAR Sensor to the configuration (only one per vehicle).')
      im.SameLine()

      -- 'Add Roads Info Sensor' button.
      local btnCol = blueB
      if isRoadsSensor then btnCol = blueD end
      if editor.uiIconImageButton(editor.icons.roadInfo, sensorIcon, btnCol, nil, nil, 'addNewRoadsSensor') then
        if not isRoadsSensor then                                                                   -- There can be only one sensor of this type. No placing required.
          sensors[#sensors + 1] = {
            isLive = false,
            id = nil,
            name = 'Local Roads [Info]',
            type = stype.tRoads,
            physicsUpdateTime = 0.015,
            GFXUpdateTime = 0.1 }
        end
      end
      im.tooltip('Add a Roads Sensor to the configuration (only one per vehicle).')
      im.SameLine()

      -- 'Add Powertrain Info Sensor' button.
      local btnCol = blueB
      if isPowertrainSensor then btnCol = blueD end
      if editor.uiIconImageButton(editor.icons.drivetrainGeneric, sensorIcon, btnCol, nil, nil, 'addNewPowertrain') then
        if not isPowertrainSensor then                                                              -- There can be only one sensor of this type. No placing required.
          sensors[#sensors + 1] = {
            isLive = false,
            id = nil,
            name = 'Powertrain [Info]',
            type = stype.tPowertrain,
            physicsUpdateTime = 0.015,
            GFXUpdateTime = 0.1 }
        end
      end
      im.tooltip('Add a Powertrain Sensor to the configuration (only one per vehicle).')
      im.SameLine()

      -- 'Add Mesh Info Sensor' button.
      local btnCol = blueB
      if isMeshSensor then btnCol = blueD end
      if editor.uiIconImageButton(editor.icons.mesh9Cells, sensorIcon, btnCol, nil, nil, 'addNewMesh') then
        if not isMeshSensor then                                                                    -- There can be only one sensor of this type. No placing required.
          sensors[#sensors + 1] = {
            isLive = false,
            id = nil,
            name = 'Mesh Distribution',
            type = stype.tMesh,
            physicsUpdateTime = 0.015,
            GFXUpdateTime = 0.1 }
        end
      end
      im.tooltip('Add a Mesh Sensor to the configuration (only one per vehicle).')
      im.SameLine()

      -- 'Save Sensor Configuration' button.
      if editor.uiIconImageButton(editor.icons.floppyDisk, sensorIcon, nil, nil, nil, 'saveSensorConfig') then
        saveConfiguration()
      end
      im.tooltip('Save the current sensor configuration, for this vehicle, to disk.')
      im.SameLine()

      -- 'Load Sensor Configuration' button.
      if editor.uiIconImageButton(editor.icons.folder, sensorIcon, dullWhite, nil, nil, 'loadSensorConfig') then
        loadConfiguration()
      end
      im.tooltip('Load a sensor configuration, for this vehicle, from disk.')

      -- 'Export to Python' button.
      im.Separator()
      if im.Button('Export Python code...') then
        getPythonCode()
        im.OpenPopup("Python Code")
      end
      im.SameLine()

      if im.BeginPopupModal("Python Code", nil, im.WindowFlags_AlwaysAutoResize) then
        im.Text("You can use this code to recreate the configuration in BeamNGpy:")
        im.InputTextMultiline("##pythonCode", pythonCodePtr, pythonCodeLen, im.ImVec2(1200, 400))
        im.Separator()
        if im.Button("Copy to clipboard") then
          setClipboard(ffi.string(pythonCodePtr))
        end
        im.SameLine()
        if im.Button("Close popup") then
          im.CloseCurrentPopup()
        end
        im.EndPopup()
      end
    else
      isAttachedSensorsWinOpen = false  -- Handle window close.
    end
  end
  editor.endWindow()
end

local function showNoDataMessage()
  im.TextColored(gray, "Waiting for sensor data...")
  im.Text("Make sure the vehicle is active and the sensor is live.")
end

local function renderCameraPreview(sensor, vehicle, dt)
  im.TextColored(gray, "Note: At least 'High' graphic setting is recommended for quality previews.")
  local ptr = im.BoolPtr(sensor.forceGimbals)
  im.Checkbox("Show gizmo", ptr)
  im.Separator()
  sensor.forceGimbals = ptr[0]
  if sensor.forceGimbals then
    if sensor.nextPreviewUpdate ~= nil then
      sensor.nextPreviewUpdate = sensor.nextPreviewUpdate - dt
    end
    if sensor.nextPreviewUpdate == nil or sensor.nextPreviewUpdate < 0 then
        simTimeAuthority.pause(false, false) -- TODO: after sensors are fixed to update on paused physics, we can remove
      conversions.updateLiveSensorPositionDirection(sensor, vehicle)
      sensor.nextPreviewUpdate = sensor.requestedUpdateTime * 2
    end
  else
    sensor.nextPreviewUpdate = nil
  end
  extensions.tech_cameraPreview.visualizeCameraById(sensor.id)
end

local function renderIMUPreview(sensor)
  local sensorId = sensor.id
  local plotData = imuPlotData[sensorId]
  if not plotData then
    plotData = {
      accX = im.ArrayFloat(plotLen), accY = im.ArrayFloat(plotLen), accZ = im.ArrayFloat(plotLen),
      angVelX = im.ArrayFloat(plotLen), angVelY = im.ArrayFloat(plotLen), angVelZ = im.ArrayFloat(plotLen),
      lastAccX = 0, lastAccY = 0, lastAccZ = 0, lastAngVelX = 0, lastAngVelY = 0, lastAngVelZ = 0, hasData = false
    }
    imuPlotData[sensorId] = plotData
  end

  local readings = extensions.tech_sensors.getAdvancedIMUReadings(sensorId)
  if readings and readings[0] then
    local data = readings[0]
    if data.accSmooth then
      plotData.lastAccX = data.accSmooth[1] or 0
      plotData.lastAccY = data.accSmooth[3] or 0
      plotData.lastAccZ = data.accSmooth[2] or 0
    end
    if data.angVel then
      plotData.lastAngVelX = data.angVel[1] or 0
      plotData.lastAngVelY = data.angVel[2] or 0
      plotData.lastAngVelZ = data.angVel[3] or 0
    end
    plotData.hasData = true
  end

  if plotData.hasData then
    plotData.accX[plotOffset] = plotData.lastAccX
    plotData.accY[plotOffset] = plotData.lastAccY
    plotData.accZ[plotOffset] = plotData.lastAccZ
    plotData.angVelX[plotOffset] = plotData.lastAngVelX
    plotData.angVelY[plotOffset] = plotData.lastAngVelY
    plotData.angVelZ[plotOffset] = plotData.lastAngVelZ
    local nextOffset = plotOffset + 1 >= plotLen and 0 or plotOffset + 1

    im.TextColored(greenB, "Acceleration (m/s²)")
    im.Spacing()
    im.Text("Forward/Backward")
    im.PlotLines1("##forward/backward", plotData.accX, plotLen, nextOffset, string.format("%+7.2f m/s²", plotData.lastAccX), FLT_MAX, FLT_MAX, plotSize)
    im.Text("Right/Left")
    im.PlotLines1("##right/left", plotData.accY, plotLen, nextOffset, string.format("%+7.2f m/s²", plotData.lastAccY), FLT_MAX, FLT_MAX, plotSize)
    im.Text("Up/Down")
    im.PlotLines1("##up/down", plotData.accZ, plotLen, nextOffset, string.format("%+7.2f m/s²", plotData.lastAccZ), FLT_MAX, FLT_MAX, plotSize)
    im.Spacing()
    im.Separator()
    im.Spacing()
    im.TextColored(greenB, "Angular Velocity (rad/s)")
    im.Spacing()
    im.Text("Pitch")
    im.PlotLines1("##angVelX", plotData.angVelX, plotLen, nextOffset, string.format("%+7.3f rad/s", plotData.lastAngVelX), FLT_MAX, FLT_MAX, plotSize)
    im.Text("Roll")
    im.PlotLines1("##angVelY", plotData.angVelY, plotLen, nextOffset, string.format("%+7.3f rad/s", plotData.lastAngVelY), FLT_MAX, FLT_MAX, plotSize)
    im.Text("Yaw")
    im.PlotLines1("##angVelZ", plotData.angVelZ, plotLen, nextOffset, string.format("%+7.3f rad/s", plotData.lastAngVelZ), FLT_MAX, FLT_MAX, plotSize)
  else
    showNoDataMessage()
  end
end

local function renderUltrasonicPreview(sensor)
  local currentDist = extensions.tech_sensors.getUltrasonicReadings(sensor.id)["distance"]
  local minDist, maxDist = sensor.nearFarPlanes[1], sensor.nearFarPlanes[2]

  im.TextColored(greenB, "Distance Measurement")
  im.Spacing()
  im.Text(string.format("Range: %.2f m - %.2f m", minDist, maxDist))
  im.Spacing()

  if currentDist then
    im.Text(string.format("Current: %.2f m", currentDist))
    im.Spacing()

    local sliderWidth, sliderHeight, padding = 350, 40, 10
    local drawList = im.GetWindowDrawList()
    local cursorPos = im.GetCursorScreenPos()
    local sliderStart = im.ImVec2(cursorPos.x + padding, cursorPos.y)
    local sliderEnd = im.ImVec2(cursorPos.x + padding + sliderWidth, cursorPos.y + sliderHeight)

    local bgColor = im.GetColorU322(im.ImVec4(0.3, 0.3, 0.3, 1.0))
    local borderColor = im.GetColorU322(im.ImVec4(0.6, 0.6, 0.6, 1.0))
    local markerColor = im.GetColorU322(greenB)

    im.ImDrawList_AddRectFilled(drawList, sliderStart, sliderEnd, bgColor)
    im.ImDrawList_AddRect(drawList, sliderStart, sliderEnd, borderColor, 0, 0, 2)

    local normalizedPos = max(0, min(1, (currentDist - minDist) / (maxDist - minDist)))
    local markerX = sliderStart.x + normalizedPos * sliderWidth

    im.ImDrawList_AddLine(drawList, im.ImVec2(markerX, sliderStart.y), im.ImVec2(markerX, sliderEnd.y), markerColor, 4)
    im.ImDrawList_AddCircleFilled(drawList, im.ImVec2(markerX, sliderStart.y + sliderHeight * 0.5), 8, markerColor)

    im.Dummy(im.ImVec2(sliderWidth + padding * 2, sliderHeight + 10))
  else
    showNoDataMessage()
  end
end

previewConfigs[stype.tCamera].render = renderCameraPreview
previewConfigs[stype.tIMU].render = renderIMUPreview
previewConfigs[stype.tUltrasonic].render = renderUltrasonicPreview

local function initPreviewIcons()
  previewConfigs[stype.tCamera].icon = editor.icons.photo_camera
  previewConfigs[stype.tIMU].icon = editor.icons.gyroscope
  previewConfigs[stype.tUltrasonic].icon = editor.icons.proximitySensorsOutline
end

local function managePreviewWindow(sensorType, dt)
  local config = previewConfigs[sensorType]
  if not config then return end

  for i = #config.openPreviews, 1, -1 do
    local preview = config.openPreviews[i]
    local vehicle = vehicles[preview.vehicleIdx]
    local shouldRemove = false

    if not vehicle then
      shouldRemove = true
    else
      local sensors = sensorConfigs[vehicle.vid]
      if not sensors then
        shouldRemove = true
      else
        local sensor = sensors[preview.sensorIdx]
        if not sensor or not sensor.isLive or sensor.type ~= sensorType then
          shouldRemove = true
        else
          if editor.beginWindow(preview.winName, sensor.name .. " [Preview]###" .. preview.id, im.flags(im.WindowFlags_NoCollapse)) then
            config.render(sensor, vehicle, dt)
          else
            if config.cleanup then config.cleanup(sensor) end
            shouldRemove = true
          end
          editor.endWindow(preview.winName)
        end
      end
    end

    if shouldRemove then
      removePreview(sensorType, i)
    end
  end
end

-- Manages the sensor properties Open/close the roads list window.
local function manageSensorPropWindow()
  if isSensorPropWinOpen then
    local vehicle = vehicles[selectedVehicleIdx]
    local vid, veh = vehicle.vid, vehicle.veh
    local sensors = sensorConfigs[vid]
    local sensor = sensors[selectedSensorIdx]
    if not sensor then
      editor.hideWindow(sensorPropWinName)
      isSensorPropWinOpen = false
      return
    end
    local ctr = 1
    if editor.beginWindow(sensorPropWinName, sensor.name .. " [Edit Properties]###3", im.flags(im.WindowFlags_NoCollapse)) then
      if sensor.type == stype.tCamera then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Position' input box.
        im.TextColored(greenB, 'Camera Position (Relative To Vehicle Center):')
        local oldVal = sensor.pos.x
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[X-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the X-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.x = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.y
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Y-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Y-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.y = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.z
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Z-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Z-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.z = uiVal[0]
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.toCOMWithWheels, sensorIcon, blueB, nil, nil, 'posCOGWithWheelsInc') then
          local p = poiData.cogWithWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (with wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.toCOM, sensorIcon, blueB, nil, nil, 'posCOGWithoutWheelsInc') then
          local p = poiData.cogWithoutWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (without wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontAxleMidpoint, sensorIcon, blueB, nil, nil, 'posFrontAxleMid') then
          local p = poiData.frontAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the front axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearAxleMidpoint, sensorIcon, blueB, nil, nil, 'posRearAxleMid') then
          local p = poiData.rearAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the rear axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleFront') then
          local p = poiData.vehFront
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle front bumper midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleRear') then
          local p = poiData.vehRear
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle rear bumper midpoint.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Size/Resolution' input box.
        im.TextColored(greenB, 'Camera Resolution:')
        local oldVal = sensor.size[1]
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Horizontal Resolution ###" .. tostring(ctr), uiVal, 10, nil)
        im.tooltip('Set the horizontal resolution of the sensor, in pixels.')
        im.PopItemWidth()
        sensor.size[1] = max(10, min(10000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.size[2]
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Vertical Resolution ###" .. tostring(ctr), uiVal, 10, nil)
        im.tooltip('Set the vertical resolution of the sensor, in pixels.')
        im.PopItemWidth()
        sensor.size[2] = max(10, min(100000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Frustum Parameters' input box.
        im.TextColored(greenB, 'Camera Frustum:')
        local oldVal = sensor.fovY
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Field Of View ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f deg")
        im.tooltip('Set the field of view of the sensor.')
        im.PopItemWidth()
        sensor.fovY = max(1.0, min(179.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.nearFarPlanes[1]
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Near Plane Distance ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the near plane distance of the sensor (min depth cutoff).')
        im.PopItemWidth()
        sensor.nearFarPlanes[1] = max(0.01, min(sensor.nearFarPlanes[2] - 0.1, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.nearFarPlanes[2]
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Far Plane Distance ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the far plane distance of the sensor (max depth cutoff).')
        im.PopItemWidth()
        sensor.nearFarPlanes[2] = max(sensor.nearFarPlanes[1] + 0.1, min(10000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Update Time' input box.
        im.TextColored(greenB, 'Camera Update Properties:')
        local oldVal = sensor.requestedUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Refresh Rate ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.requestedUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set Update Priority' slider.
        local oldVal = sensor.updatePriority
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.SliderFloat("Update Priority [0, 1]", uiVal, 0.0, 1.0, "%.3f")
        im.tooltip('The update priority of the sensor [0 = highest, 1 = lowest]. This is used for GPU scheduling')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.updatePriority = max(0.0, min(1.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Is Visualised' checkbox.
        im.TextColored(greenB, 'Camera Operation Flags:')
        local oldVal = sensor.renderColours
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Render Color Image", uiVal)
        im.tooltip('Toggle whether to include the colour image in output.')
        sensor.renderColours = uiVal[0]
        local oldVal = sensor.renderAnnotations
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Render Class Annotations", uiVal)
        im.tooltip('Toggle whether to include class annotations (segmentation) in output.')
        sensor.renderAnnotations = uiVal[0]
        local oldVal = sensor.renderInstance
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Render Instance Annotations", uiVal)
        im.tooltip('Toggle whether to include instance annotations (segmentation) in output.')
        sensor.renderInstance = uiVal[0]
        local oldVal = sensor.renderDepth
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Render Depth Image", uiVal)
        im.tooltip('Toggle whether to include the depth image in output.')
        sensor.renderDepth = uiVal[0]
        local oldVal = sensor.renderTranslucentAsOpaqueDepth or false
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Render Translucents In Depth", uiVal)
        im.tooltip('Include translucent surfaces in the depth image. Requires Render Depth Image.')
        sensor.renderTranslucentAsOpaqueDepth = uiVal[0]
        local oldVal = sensor.isVisualised
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Visualise On Map", uiVal)
        im.tooltip('Toggle whether to visualise the sensor, or not.')
        sensor.isVisualised = uiVal[0]

        -- 'Snap To Vehicle' checkbox.
        local oldVal = sensor.isSnappingDesired
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Snap To Vehicle", uiVal)
        im.tooltip('Toggle whether to snap the sensor to the vehicle mesh, on creation.')
        sensor.isSnappingDesired = uiVal[0]

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()

      elseif sensor.type == stype.tLiDAR then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- LiDAR Mode Selection buttons.
        local lMode, isRotate, is360 = 'Full360', sensor.isRotate, sensor.is360
        if is360 and not isRotate then
          lMode = 'Full360'
        elseif not is360 and isRotate then
          lMode = 'LFO'
        elseif not is360 and not isRotate then
          lMode = 'Static'
        end
        im.TextColored(greenB, 'LiDAR Operating Mode: [' .. lMode .. ']')
        local btnCol = blueB
        if lMode == 'Full360' then btnCol = blueD end
        if editor.uiIconImageButton(editor.icons.lidarPatternFullArcHighFreq, sensorIcon, btnCol, nil, nil, 'LiDAR360Mode') then
          sensor.is360, sensor.isRotate = true, false
        end
        im.tooltip("Set the LiDAR to operate in 'Full 360 Degrees' mode.")
        im.SameLine()
        local btnCol = blueB
        if lMode == 'LFO' then btnCol = blueD end
        if editor.uiIconImageButton(editor.icons.lidarPatternFullArcMidFreq, sensorIcon, btnCol, nil, nil, 'LiDARLFOMode') then
          sensor.is360, sensor.isRotate = false, true
        end
        im.tooltip("Set the LiDAR to operate in 'LFO' (low-frequency rotation) mode.")
        im.SameLine()
        local btnCol = blueB
        if lMode == 'Static' then btnCol = blueD end
        if editor.uiIconImageButton(editor.icons.lidarPatternNarrowArc, sensorIcon, btnCol, nil, nil, 'LiDARStaticMode') then
          sensor.is360, sensor.isRotate = false, false
        end
        im.tooltip("Set the LiDAR to operate in 'Static' (no rotation) mode.")
        im.SameLine()

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Position' input box.
        im.TextColored(greenB, 'LiDAR Position (Relative To Vehicle Center):')
        local oldVal = sensor.pos.x
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[X-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the X-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.x = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.y
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Y-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Y-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.y = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.z
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Z-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Z-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.z = uiVal[0]
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.toCOMWithWheels, sensorIcon, blueB, nil, nil, 'posCOGWithWheelsInc') then
          local p = poiData.cogWithWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (with wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.toCOM, sensorIcon, blueB, nil, nil, 'posCOGWithoutWheelsInc') then
          local p = poiData.cogWithoutWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (without wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontAxleMidpoint, sensorIcon, blueB, nil, nil, 'posFrontAxleMid') then
          local p = poiData.frontAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the front axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearAxleMidpoint, sensorIcon, blueB, nil, nil, 'posRearAxleMid') then
          local p = poiData.rearAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the rear axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleFront') then
          local p = poiData.vehFront
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle front bumper midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleRear') then
          local p = poiData.vehRear
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle rear bumper midpoint.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Core Properties' input boxes.
        im.TextColored(greenB, 'LiDAR Core Properties:')
        local oldVal = sensor.verticalResolution
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Vertical Resolution ###" .. tostring(ctr), uiVal, 1, nil)
        im.tooltip('Set the number of vertical resolution levels.')
        im.PopItemWidth()
        sensor.verticalResolution = max(1, min(1000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.verticalAngle
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Vertical Field Of View ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f deg")
        im.tooltip('Set the vertical field of view, in degrees.')
        im.PopItemWidth()
        sensor.verticalAngle = max(1.0, min(179.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.horizontalAngle
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Horizontal Field Of View ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f deg")
        im.tooltip('Set the horizontal field of view, in degrees.')
        im.PopItemWidth()
        sensor.horizontalAngle = max(1.0, min(179.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.frequency
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Rotation Frequency (Hz) ###" .. tostring(ctr), uiVal, 1, nil)
        im.tooltip('Set the rotation frequency, in Hz.')
        im.PopItemWidth()
        sensor.frequency = max(1, min(20, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.maxDistance
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Max Detection Range ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the sensor maximum detection range, in meters.')
        im.PopItemWidth()
        sensor.maxDistance = max(10.0, min(9999.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Update Time' input box.
        im.TextColored(greenB, 'LiDAR Update Properties:')
        local oldVal = sensor.requestedUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Refresh Rate ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.requestedUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set Update Priority' slider.
        local oldVal = sensor.updatePriority
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.SliderFloat("Update Priority [0, 1]", uiVal, 0.0, 1.0, "%.3f")
        im.tooltip('The update priority of the sensor [0 = highest, 1 = lowest]. This is used for GPU scheduling')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.updatePriority = max(0.0, min(1.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Is Annotated' checkbox.
        im.TextColored(greenB, 'LiDAR Operation Flags:')
        local oldVal = sensor.isAnnotated
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Include Segmentation Data", uiVal)
        im.tooltip('Toggle whether to include segmentation info (semantic annotations).')
        sensor.isAnnotated = uiVal[0]

        -- 'Is Visualised' checkbox.
        local oldVal = sensor.isVisualised
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Visualise On Map", uiVal)
        im.tooltip('Toggle whether to visualise the sensor, or not.')
        sensor.isVisualised = uiVal[0]

        -- 'Snap To Vehicle' checkbox.
        local oldVal = sensor.isSnappingDesired
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Snap To Vehicle", uiVal)
        im.tooltip('Toggle whether to snap the sensor to the vehicle mesh, on creation.')
        sensor.isSnappingDesired = uiVal[0]

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()

      elseif sensor.type == stype.tUltrasonic then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Position' input box.
        im.TextColored(greenB, 'Ultrasonic Position (Relative To Vehicle Center):')
        local oldVal = sensor.pos.x
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[X-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the X-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.x = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.y
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Y-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Y-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.y = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.z
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Z-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Z-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.z = uiVal[0]
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.toCOMWithWheels, sensorIcon, blueB, nil, nil, 'posCOGWithWheelsInc') then
          local p = poiData.cogWithWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (with wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.toCOM, sensorIcon, blueB, nil, nil, 'posCOGWithoutWheelsInc') then
          local p = poiData.cogWithoutWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (without wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontAxleMidpoint, sensorIcon, blueB, nil, nil, 'posFrontAxleMid') then
          local p = poiData.frontAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the front axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearAxleMidpoint, sensorIcon, blueB, nil, nil, 'posRearAxleMid') then
          local p = poiData.rearAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the rear axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleFront') then
          local p = poiData.vehFront
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle front bumper midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleRear') then
          local p = poiData.vehRear
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle rear bumper midpoint.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Size/Resolution' input box.
        im.TextColored(greenB, 'Ultrasonic Resolution:')
        local oldVal = sensor.size[1]
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Horizontal Resolution ###" .. tostring(ctr), uiVal, 10, nil)
        im.tooltip('Set the horizontal resolution of the sensor, in pixels.')
        im.PopItemWidth()
        sensor.size[1] = max(10, min(10000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.size[2]
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Vertical Resolution ###" .. tostring(ctr), uiVal, 10, nil)
        im.tooltip('Set the vertical resolution of the sensor, in pixels.')
        im.PopItemWidth()
        sensor.size[2] = max(10, min(100000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Frustum Parameters' input box.
        im.TextColored(greenB, 'Ultrasonic Frustum:')
        local oldVal = sensor.fovY
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Field Of View ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f deg")
        im.tooltip('Set the field of view of the sensor.')
        im.PopItemWidth()
        sensor.fovY = max(1.0, min(179.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.nearFarPlanes[1]
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Near Plane Distance ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the near plane distance of the sensor (min depth cutoff).')
        im.PopItemWidth()
        sensor.nearFarPlanes[1] = max(0.01, min(sensor.nearFarPlanes[2] - 0.1, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.nearFarPlanes[2]
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Far Plane Distance ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the far plane distance of the sensor (max depth cutoff).')
        im.PopItemWidth()
        sensor.nearFarPlanes[2] = max(sensor.nearFarPlanes[1] + 0.1, min(10000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Core Properties' input boxes.
        im.TextColored(greenB, 'Ultrasonic Beam Properties:')
        local oldVal = sensor.rangeRoundness
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Roundness ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip("Set the 'roundness' of the beam shape.")
        im.PopItemWidth()
        sensor.rangeRoundness = max(-100.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeCutoffSensitivity
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Cutoff Sensitivity ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip('Set the sensitivity of the range cutoff.')
        im.PopItemWidth()
        sensor.rangeCutoffSensitivity = max(0.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeShape
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Shape ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip('Set the shape across the beam range.')
        im.PopItemWidth()
        sensor.rangeShape = max(-100.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeFocus
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Focus ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip('Set the sharpness of the shape across the beam range.')
        im.PopItemWidth()
        sensor.rangeFocus = max(-100.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeMinCutoff
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Min Cutoff ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f m")
        im.tooltip('Set the near plane, in meters.')
        im.PopItemWidth()
        sensor.rangeMinCutoff = max(0.1, min(20.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeDirectMaxCutoff
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Direct Max Cutoff ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f m")
        im.tooltip('Set the far plane, in meters.')
        im.PopItemWidth()
        sensor.rangeDirectMaxCutoff = max(0.1, min(20.0, uiVal[0]))
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.triangleBeam, sensorIcon, blueB, nil, nil, 'usPreset1') then
          sensor.rangeRoundness = -2
          sensor.rangeCutoffSensitivity = 0.0004
          sensor.rangeShape = 0.0
          sensor.rangeFocus = 0.344
          sensor.rangeMinCutoff = 0.1
          sensor.rangeDirectMaxCutoff = 9.9
          sensor.nearFarPlanes = { 0.1, 11.0 }
        end
        im.tooltip('Set preset beam shape: Triangular, 7m range.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.thinBulbBeam, sensorIcon, blueB, nil, nil, 'usPreset2') then
          sensor.rangeRoundness = -2
          sensor.rangeCutoffSensitivity = 0
          sensor.rangeShape = 0.28
          sensor.rangeFocus = 0.315
          sensor.rangeMinCutoff = 0.1
          sensor.rangeDirectMaxCutoff = 9.9
          sensor.nearFarPlanes = { 0.1, 11.0 }
        end
        im.tooltip('Set preset beam shape: Thin bulb, 8m range.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.thinnerBulbBeam, sensorIcon, blueB, nil, nil, 'usPreset3') then
          sensor.rangeRoundness = -2
          sensor.rangeCutoffSensitivity = 0
          sensor.rangeShape = 0.09
          sensor.rangeFocus = 0.686
          sensor.rangeMinCutoff = 0.1
          sensor.rangeDirectMaxCutoff = 10.0
          sensor.nearFarPlanes = { 0.1, 11.0 }
        end
        im.tooltip('Set preset beam shape: Ultra thin bulb, 8m range.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.sphericalBeam, sensorIcon, blueB, nil, nil, 'usPreset4') then
          sensor.rangeRoundness = 0.7
          sensor.rangeCutoffSensitivity = 0.0001
          sensor.rangeShape = 0.09
          sensor.rangeFocus = 0.744
          sensor.rangeMinCutoff = 0.1
          sensor.rangeDirectMaxCutoff = 5.2
          sensor.nearFarPlanes = { 0.1, 6.0 }
        end
        im.tooltip('Set preset beam shape: Spherical, 5m range.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.flatBulbBeam, sensorIcon, blueB, nil, nil, 'usPreset5') then
          sensor.rangeRoundness = -0.01
          sensor.rangeCutoffSensitivity = 0.002
          sensor.rangeShape = 0.33
          sensor.rangeFocus = 0.344
          sensor.rangeMinCutoff = 0.1
          sensor.rangeDirectMaxCutoff = 9.9
          sensor.nearFarPlanes = { 0.1, 11.0 }
        end
        im.tooltip('Set preset beam shape: Flat head bulb, 5m range.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.tulipBeam, sensorIcon, blueB, nil, nil, 'usPreset6') then
          sensor.rangeRoundness = -1.18
          sensor.rangeCutoffSensitivity = 0
          sensor.rangeShape = 0.14
          sensor.rangeFocus = 0.52
          sensor.rangeMinCutoff = 0.1
          sensor.rangeDirectMaxCutoff = 10.1
          sensor.nearFarPlanes = { 0.1, 11.0 }
        end
        im.tooltip('Set preset beam shape: Tulip, 10m (long) range.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Core Properties' input boxes.
        im.TextColored(greenB, 'Ultrasonic Detection Properties:')
        local oldVal = sensor.sensitivity
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensitivity ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f")
        im.tooltip("Set the detection sensitivity.")
        im.PopItemWidth()
        sensor.sensitivity = max(0.1, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.fixedWindowSize
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Window Width ###" .. tostring(ctr), uiVal, 1, nil)
        im.tooltip('Set the width of the window used in processing the returns.')
        im.PopItemWidth()
        sensor.fixedWindowSize = max(1, min(10000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Update Time' input box.
        im.TextColored(greenB, 'Ultrasonic Update Properties:')
        local oldVal = sensor.requestedUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Refresh Rate ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.requestedUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set Update Priority' slider.
        local oldVal = sensor.updatePriority
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.SliderFloat("Update Priority [0, 1]", uiVal, 0.0, 1.0, "%.3f")
        im.tooltip('The update priority of the sensor [0 = highest, 1 = lowest]. This is used for GPU scheduling')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.updatePriority = max(0.0, min(1.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Is Visualised' checkbox.
        im.TextColored(greenB, 'Ultrasonic Operation Flags:')
        local oldVal = sensor.isVisualised
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Visualise On Map", uiVal)
        im.tooltip('Toggle whether to visualise the sensor, or not.')
        sensor.isVisualised = uiVal[0]

        -- 'Snap To Vehicle' checkbox.
        local oldVal = sensor.isSnappingDesired
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Snap To Vehicle", uiVal)
        im.tooltip('Toggle whether to snap the sensor to the vehicle mesh, on creation.')
        sensor.isSnappingDesired = uiVal[0]

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()

      elseif sensor.type == stype.tRADAR then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Position' input box.
        im.TextColored(greenB, 'RADAR Position (Relative To Vehicle Center):')
        local oldVal = sensor.pos.x
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[X-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the X-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.x = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.y
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Y-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Y-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.y = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.z
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Z-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Z-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.z = uiVal[0]
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.toCOMWithWheels, sensorIcon, blueB, nil, nil, 'posCOGWithWheelsInc') then
          local p = poiData.cogWithWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (with wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.toCOM, sensorIcon, blueB, nil, nil, 'posCOGWithoutWheelsInc') then
          local p = poiData.cogWithoutWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (without wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontAxleMidpoint, sensorIcon, blueB, nil, nil, 'posFrontAxleMid') then
          local p = poiData.frontAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the front axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearAxleMidpoint, sensorIcon, blueB, nil, nil, 'posRearAxleMid') then
          local p = poiData.rearAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the rear axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleFront') then
          local p = poiData.vehFront
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle front bumper midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleRear') then
          local p = poiData.vehRear
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle rear bumper midpoint.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Size/Resolution' input box.
        im.TextColored(greenB, 'RADAR Resolution:')
        local oldVal = sensor.size[1]
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Horizontal Resolution ###" .. tostring(ctr), uiVal, 10, nil)
        im.tooltip('Set the horizontal resolution of the sensor, in pixels.')
        im.PopItemWidth()
        sensor.size[1] = max(10, min(10000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.size[2]
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Vertical Resolution ###" .. tostring(ctr), uiVal, 10, nil)
        im.tooltip('Set the vertical resolution of the sensor, in pixels.')
        im.PopItemWidth()
        sensor.size[2] = max(10, min(100000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Frustum Parameters' input box.
        im.TextColored(greenB, 'RADAR Frustum:')
        local oldVal = sensor.fovY
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Field Of View ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f deg")
        im.tooltip('Set the field of view of the sensor.')
        im.PopItemWidth()
        sensor.fovY = max(1.0, min(179.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.nearFarPlanes[1]
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Near Plane Distance ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the near plane distance of the sensor (min depth cutoff).')
        im.PopItemWidth()
        sensor.nearFarPlanes[1] = max(0.01, min(sensor.nearFarPlanes[2] - 0.1, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.nearFarPlanes[2]
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Far Plane Distance ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f m")
        im.tooltip('Set the far plane distance of the sensor (max depth cutoff).')
        im.PopItemWidth()
        sensor.nearFarPlanes[2] = max(sensor.nearFarPlanes[1] + 0.1, min(10000, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Core Properties' input boxes.
        im.TextColored(greenB, 'RADAR Beam Properties:')
        local oldVal = sensor.rangeRoundness
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Roundness ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip("Set the 'roundness' of the beam shape.")
        im.PopItemWidth()
        sensor.rangeRoundness = max(-100.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeCutoffSensitivity
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Cutoff Sensitivity ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip('Set the sensitivity of the range cutoff.')
        im.PopItemWidth()
        sensor.rangeCutoffSensitivity = max(0.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeShape
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Shape ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip('Set the shape across the beam range.')
        im.PopItemWidth()
        sensor.rangeShape = max(-100.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeFocus
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Focus ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f")
        im.tooltip('Set the sharpness of the shape across the beam range.')
        im.PopItemWidth()
        sensor.rangeFocus = max(-100.0, min(100.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeMinCutoff
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Min Cutoff ###" .. tostring(ctr), uiVal, 0.1, nil, "%.4f m")
        im.tooltip('Set the near plane, in meters.')
        im.PopItemWidth()
        sensor.rangeMinCutoff = max(0.1, min(1000.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeDirectMaxCutoff
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Range Direct Max Cutoff ###" .. tostring(ctr), uiVal, 1.0, nil, "%.4f m")
        im.tooltip('Set the far plane, in meters.')
        im.PopItemWidth()
        sensor.rangeDirectMaxCutoff = max(0.1, min(1000.0, uiVal[0]))
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.shortRangeBeam1, sensorIcon, blueB, nil, nil, 'usPreset1') then
          sensor.rangeRoundness = -1.27
          sensor.rangeCutoffSensitivity = 0.0
          sensor.rangeShape = 0.09
          sensor.rangeFocus = 0.54
          sensor.rangeMinCutoff = 0.5
          sensor.rangeDirectMaxCutoff = 30.0
          sensor.nearFarPlanes = { 0.5, 30.0 }
        end
        im.tooltip('Set preset beam shape: Short Range (0.5m - 30m).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.midRangeBeam1, sensorIcon, blueB, nil, nil, 'usPreset2') then
          sensor.rangeRoundness = -1.27
          sensor.rangeCutoffSensitivity = 0
          sensor.rangeShape = 0.09
          sensor.rangeFocus = 0.466
          sensor.rangeMinCutoff = 1.0
          sensor.rangeDirectMaxCutoff = 70.0
          sensor.nearFarPlanes = { 1.0, 70.0 }
        end
        im.tooltip('Set preset beam shape: Medium Range (1m - 70m).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.longRangeBeam1, sensorIcon, blueB, nil, nil, 'usPreset3') then
          sensor.rangeRoundness = -1.27
          sensor.rangeCutoffSensitivity = 0
          sensor.rangeShape = 0.09
          sensor.rangeFocus = 0.37
          sensor.rangeMinCutoff = 10.0
          sensor.rangeDirectMaxCutoff = 300.0
          sensor.nearFarPlanes = { 10.0, 300.0 }
        end
        im.tooltip('Set preset beam shape: Long Range (10m - 250m).')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Core Properties' input boxes.
        im.TextColored(greenB, 'RADAR Post-Processing Properties:')
        local oldVal = sensor.rangeBins
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Range Bins ###" .. tostring(ctr), uiVal, 1, nil)
        im.tooltip('Set the number of bins to divide the data into, in the range dimension.')
        im.PopItemWidth()
        sensor.rangeBins = max(10, min(1000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.azimuthBins
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Azimuth Bins ###" .. tostring(ctr), uiVal, 1, nil)
        im.tooltip('Set the number of bins to divide the data into, in the azimuth dimension.')
        im.PopItemWidth()
        sensor.azimuthBins = max(10, min(1000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.velBins
        local uiVal = im.IntPtr(oldVal)
        im.PushItemWidth(130)
        im.InputInt("Velocity Bins ###" .. tostring(ctr), uiVal, 1, nil)
        im.tooltip('Set the number of bins to divide the data into, in the velocity dimension.')
        im.PopItemWidth()
        sensor.velBins = max(10, min(1000, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeMin
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Min Range ###" .. tostring(ctr), uiVal, 1, nil, "%.2f")
        im.tooltip("Set the minimum range to display in the data.")
        im.PopItemWidth()
        sensor.rangeMin = max(0.1, min(1000.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.rangeMax
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Max Range ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f")
        im.tooltip("Set the maximum range to display in the data.")
        im.PopItemWidth()
        sensor.rangeMax = max(0.1, min(1000.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.velMin
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Min Velocity ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f")
        im.tooltip("Set the minimum velocity to display in the data.")
        im.PopItemWidth()
        sensor.velMin = max(-250.0, min(250.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.velMax
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Max Velocity ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f")
        im.tooltip("Set the maximum velocity to display in the data.")
        im.PopItemWidth()
        sensor.velMax = max(-250.0, min(250.0, uiVal[0]))
        ctr = ctr + 1
        local oldVal = sensor.halfAngleDeg
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Azimuth Half-Angle ###" .. tostring(ctr), uiVal, 1.0, nil, "%.2f deg")
        im.tooltip("Set the azimuth half-angle, used in data display.")
        im.PopItemWidth()
        sensor.halfAngleDeg = max(10.0, min(179.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Update Time' input box.
        im.TextColored(greenB, 'RADAR Update Properties:')
        local oldVal = sensor.requestedUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Refresh Rate ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.requestedUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set Update Priority' slider.
        local oldVal = sensor.updatePriority
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.SliderFloat("Update Priority [0, 1]", uiVal, 0.0, 1.0, "%.3f")
        im.tooltip('The update priority of the sensor [0 = highest, 1 = lowest]. This is used for GPU scheduling')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.updatePriority = max(0.0, min(1.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Is Visualised' checkbox.
        im.TextColored(greenB, 'RADAR Operation Flags:')
        local oldVal = sensor.isVisualised
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Visualise On Map", uiVal)
        im.tooltip('Toggle whether to visualise the sensor, or not.')
        sensor.isVisualised = uiVal[0]

        -- 'Snap To Vehicle' checkbox.
        local oldVal = sensor.isSnappingDesired
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Snap To Vehicle", uiVal)
        im.tooltip('Toggle whether to snap the sensor to the vehicle mesh, on creation.')
        sensor.isSnappingDesired = uiVal[0]

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()

      elseif sensor.type == stype.tIMU then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Position' input box.
        im.TextColored(greenB, 'IMU Position (Relative To Vehicle Center):')
        local oldVal = sensor.pos.x
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[X-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the X-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.x = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.y
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Y-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Y-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.y = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.z
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Z-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Z-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.z = uiVal[0]
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.toCOMWithWheels, sensorIcon, blueB, nil, nil, 'posCOGWithWheelsInc') then
          local p = poiData.cogWithWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (with wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.toCOM, sensorIcon, blueB, nil, nil, 'posCOGWithoutWheelsInc') then
          local p = poiData.cogWithoutWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (without wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontAxleMidpoint, sensorIcon, blueB, nil, nil, 'posFrontAxleMid') then
          local p = poiData.frontAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the front axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearAxleMidpoint, sensorIcon, blueB, nil, nil, 'posRearAxleMid') then
          local p = poiData.rearAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the rear axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleFront') then
          local p = poiData.vehFront
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle front bumper midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleRear') then
          local p = poiData.vehRear
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle rear bumper midpoint.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set (Physics) Update Time' input box.
        im.TextColored(greenB, 'IMU Update Properties:')
        local oldVal = sensor.physicsUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Update Time", uiVal, 0.01, 60.0, "%.3f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.physicsUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set GFX Update (Collecting) Time' slider.
        local oldVal = sensor.GFXUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Data Collect Time", uiVal, 0.1, 360.0, "%.3f s")
        im.tooltip('Set the time between new batch data packets being made available to user.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.GFXUpdateTime = max(0.0, min(360.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Smoother Strength' input box.
        im.TextColored(greenB, 'IMU Post-Processing Properties:')
        local oldVal = sensor.smootherStrength
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Smoother Strength", uiVal, 0.0, 5.0, "%.1f")
        im.tooltip('Set the strength of the smoothing of the accelerometer and gyroscopic data.')
        im.PopItemWidth()
        sensor.smootherStrength = max(0.0, min(5.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Is Using Gravity' checkbox.
        im.TextColored(greenB, 'IMU Operation Flags:')
        local oldVal = sensor.isUsingGravity
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Include Gravity", uiVal)
        im.tooltip('Toggle whether to include gravity in the readings, or not.')
        sensor.isUsingGravity = uiVal[0]

        -- 'Is Visualised' checkbox.
        local oldVal = sensor.isVisualised
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Visualise On Map", uiVal)
        im.tooltip('Toggle whether to visualise the sensor, or not.')
        sensor.isVisualised = uiVal[0]

        -- 'Snap To Vehicle' checkbox.
        local oldVal = sensor.isSnappingDesired
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Snap To Vehicle", uiVal)
        im.tooltip('Toggle whether to snap the sensor to the vehicle mesh, on creation.')
        sensor.isSnappingDesired = uiVal[0]

        -- 'Allow Wheel Nodes' checkbox.
        local oldVal = sensor.isAllowWheelNodes
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Allow Wheel Nodes (On Snap)", uiVal)
        im.tooltip('Toggle whether to allow attachment to wheel nodes, or not.')
        sensor.isAllowWheelNodes = uiVal[0]

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()

      elseif sensor.type == stype.tGPS then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Position' input box.
        im.TextColored(greenB, 'GPS Position (Relative To Vehicle Center):')
        local oldVal = sensor.pos.x
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[X-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the X-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.x = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.y
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Y-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Y-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.y = uiVal[0]
        ctr = ctr + 1
        local oldVal = sensor.pos.z
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("[Z-Axis] ###" .. tostring(ctr), uiVal, 0.01, nil, "%.4f m")
        im.tooltip('Set the sensor position on the Z-Axis, relative to vehicle center.')
        im.PopItemWidth()
        sensor.pos.z = uiVal[0]
        ctr = ctr + 1
        if editor.uiIconImageButton(editor.icons.toCOMWithWheels, sensorIcon, blueB, nil, nil, 'posCOGWithWheelsInc') then
          local p = poiData.cogWithWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (with wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.toCOM, sensorIcon, blueB, nil, nil, 'posCOGWithoutWheelsInc') then
          local p = poiData.cogWithoutWheels
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the Center-Of-Gravity (without wheels included).')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontAxleMidpoint, sensorIcon, blueB, nil, nil, 'posFrontAxleMid') then
          local p = poiData.frontAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the front axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearAxleMidpoint, sensorIcon, blueB, nil, nil, 'posRearAxleMid') then
          local p = poiData.rearAxleMidpoint
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the rear axle midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.frontBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleFront') then
          local p = poiData.vehFront
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle front bumper midpoint.')
        im.SameLine()
        if editor.uiIconImageButton(editor.icons.rearBumperMidpoint, sensorIcon, blueB, nil, nil, 'posVehicleRear') then
          local p = poiData.vehRear
          sensor.pos = util.posVS2Coeffs(vec3(p.x, p.y, p.z), veh)
        end
        im.tooltip('Re-position sensor at the vehicle rear bumper midpoint.')

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set (Physics) Update Time' input box.
        im.TextColored(greenB, 'GPS Update Properties:')
        local oldVal = sensor.physicsUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Update Time", uiVal, 0.01, 60.0, "%.3f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.physicsUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set GFX Update (Collecting) Time' slider.
        local oldVal = sensor.GFXUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Data Collect Time", uiVal, 0.1, 360.0, "%.3f s")
        im.tooltip('Set the time between new batch data packets being made available to user.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.GFXUpdateTime = max(0.0, min(360.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set Acceleration Window Width (Smoothing)' input box.
        im.TextColored(greenB, 'GPS Localization Properties:')
        local oldVal = sensor.refLon
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Origin Longitude", uiVal, 0.01, 359.9, "%.6f deg")
        im.tooltip('Set the longitude of the origin position.')
        im.PopItemWidth()
        sensor.refLon = max(-180, min(180.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set Gyroscopic Window Width (Smoothing)' slider.
        local oldVal = sensor.refLat
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Origin Latitude", uiVal, 0.01, 359.9, "%.6f deg")
        im.tooltip('Set the latitude of the origin position.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.refLat = max(-90.0, min(90.0, uiVal[0]))
        ctr = ctr + 1

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Is Visualised' checkbox.
        im.TextColored(greenB, 'GPS Operation Flags:')
        local oldVal = sensor.isVisualised
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Visualise On Map", uiVal)
        im.tooltip('Toggle whether to visualise the sensor, or not.')
        sensor.isVisualised = uiVal[0]

        -- 'Snap To Vehicle' checkbox.
        local oldVal = sensor.isSnappingDesired
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Snap To Vehicle", uiVal)
        im.tooltip('Toggle whether to snap the sensor to the vehicle mesh, on creation.')
        sensor.isSnappingDesired = uiVal[0]

        -- 'Allow Wheel Nodes' checkbox.
        local oldVal = sensor.isAllowWheelNodes
        local uiVal = im.BoolPtr(oldVal)
        im.Checkbox("Allow Wheel Nodes (On Snap)", uiVal)
        im.tooltip('Toggle whether to allow attachment to wheel nodes, or not.')
        sensor.isAllowWheelNodes = uiVal[0]

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()

      elseif sensor.type == stype.tIdealRADAR then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        im.TextColored(greenB, 'Ideal RADAR Sensor:')
        im.Text("Including this sensor will provide info about")
        im.Text("the closest vehicles in range, such as:")
        im.Text("vehicle position, velocity and acceleration.")
        im.Dummy(im.ImVec2(5, 0))
        im.TextColored(redB, "This sensor does not require attachment/placing.")
        im.TextColored(redB, "Only one instance of this sensor per vehicle.")

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set (Physics) Update Time' input box.
        im.TextColored(greenB, 'Ideal RADAR Update Properties:')
        local oldVal = sensor.physicsUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Update Time", uiVal, 0.01, 60.0, "%.3f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.physicsUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set GFX Update (Collecting) Time' slider.
        local oldVal = sensor.GFXUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Data Collect Time", uiVal, 0.1, 360.0, "%.3f s")
        im.tooltip('Set the time between new batch data packets being made available to user.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.GFXUpdateTime = max(0.0, min(360.0, uiVal[0]))
        ctr = ctr + 1

      elseif sensor.type == stype.tRoads then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        im.TextColored(greenB, 'Local Road Info Sensor:')
        im.Text("Including this sensor will provide info about")
        im.Text("the nearby road layout to the vehicle, such as:")
        im.Text("relative distances to centerline and road edges,")
        im.Text("local road heading and curvature, spline data.")
        im.Dummy(im.ImVec2(5, 0))
        im.TextColored(redB, "This sensor does not require attachment/placing.")
        im.TextColored(redB, "Only one instance of this sensor per vehicle.")

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set (Physics) Update Time' input box.
        im.TextColored(greenB, 'Road Info Sensor Update Properties:')
        local oldVal = sensor.physicsUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Update Time", uiVal, 0.01, 60.0, "%.3f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.physicsUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set GFX Update (Collecting) Time' slider.
        local oldVal = sensor.GFXUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Data Collect Time", uiVal, 0.1, 360.0, "%.3f s")
        im.tooltip('Set the time between new batch data packets being made available to user.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.GFXUpdateTime = max(0.0, min(360.0, uiVal[0]))
        ctr = ctr + 1

      elseif sensor.type == stype.tPowertrain then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        im.TextColored(greenB, 'Powertrain Info Sensor:')
        im.Text("Including this sensor will provide info about")
        im.Text("the vehicle powertrain, such as:")
        im.Text("torque values, electric devices, etc.")
        im.Dummy(im.ImVec2(5, 0))
        im.TextColored(redB, "This sensor does not require attachment/placing.")
        im.TextColored(redB, "Only one instance of this sensor per vehicle.")

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set (Physics) Update Time' input box.
        im.TextColored(greenB, 'Powertrain Info Update Properties:')
        local oldVal = sensor.physicsUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Update Time", uiVal, 0.01, 60.0, "%.3f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.physicsUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set GFX Update (Collecting) Time' slider.
        local oldVal = sensor.GFXUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Data Collect Time", uiVal, 0.1, 360.0, "%.3f s")
        im.tooltip('Set the time between new batch data packets being made available to user.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.GFXUpdateTime = max(0.0, min(360.0, uiVal[0]))
        ctr = ctr + 1

      elseif sensor.type == stype.tMesh then

        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        im.TextColored(greenB, 'Mesh Distribution Info Sensor:')
        im.Text("Including this sensor will provide quantities:")
        im.Text("force, stress, mass and velocity, distributed:")
        im.Text("across the vehicle mesh (nodes and beams).")
        im.Text("The mesh  geometry is also available.")
        im.Dummy(im.ImVec2(5, 0))
        im.TextColored(redB, "This sensor does not require attachment/placing.")
        im.TextColored(redB, "Only one instance of this sensor per vehicle.")

        im.Dummy(im.ImVec2(5, 0))
        im.Separator()
        im.Dummy(im.ImVec2(5, 0))

        -- 'Set (Physics) Update Time' input box.
        im.TextColored(greenB, 'Mesh Distribution Info Update Properties:')
        local oldVal = sensor.physicsUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushItemWidth(130)
        im.InputFloat("Sensor Update Time", uiVal, 0.01, 60.0, "%.3f s")
        im.tooltip('Set the time between sensor updates.')
        im.PopItemWidth()
        sensor.physicsUpdateTime = max(0.0001, min(60.0, uiVal[0]))
        ctr = ctr + 1

        -- 'Set GFX Update (Collecting) Time' slider.
        local oldVal = sensor.GFXUpdateTime
        local uiVal = im.FloatPtr(oldVal)
        im.PushStyleVar1(im.StyleVar_GrabMinSize, 20)
        im.PushItemWidth(130)
        im.InputFloat("Data Collect Time", uiVal, 0.1, 360.0, "%.3f s")
        im.tooltip('Set the time between new batch data packets being made available to user.')
        im.PopItemWidth()
        im.PopStyleVar()
        sensor.GFXUpdateTime = max(0.0, min(360.0, uiVal[0]))
        ctr = ctr + 1

      end
    else
      isSensorPropWinOpen = false -- Handle window close.
    end
    editor.endWindow()
  end
end

-- World editor main callback for rendering the UI.
local function onEditorGui(dt)
  if not isSensorConfigurationEditor then
    return
  end

  -- Manage the back end.
  getCurrentVehicleList()

  if not vehicles[selectedVehicleIdx] then
    return
  end

  -- Dispatch a request to vlua, to collect all the POI data.
  if not isRequestSent then
    table.clear(poiData)
    isRequestSent, isVluaDataReturned = true, false
    local vid = vehicles[selectedVehicleIdx].vid
    be:queueObjectLua(vid, "extensions.tech_vehiclePOI.collectVehiclePOIData('editor_sensorConfigurationEditor.updateCollectedVehiclePOIData')")
  end

  -- Do not go any further until the requested data has been returned from vlua.
  if not isVluaDataReturned then
    return false
  end
  isVluaDataReturned = true

  -- Handle the placing of new sensors, if required.
  if isPlaceMode then
    handlePlaceSensor()
  end

  -- Render 'edit sphere' markers at each sensor in the configuration.
  local vehicle = vehicles[selectedVehicleIdx]
  local vid, veh = vehicle.vid, vehicle.veh
  local vPos = veh:getPosition()
  local sensors = sensorConfigs[vid]
  local numSensors = #sensors
  for i = 1, numSensors do
    local s = sensors[i]
    if not s.isLive and s.pos then
      local pos = util.coeffs2PosVS(s.pos, veh) + vPos
      local fwd, up = util.sensor2VS(s.dir, s.up, veh)
      local right = fwd:cross(up)
      util.renderSensorBoxAndFrame(pos, fwd, up, right)
      if s.type == stype.tUltrasonic or s.type == stype.tRADAR then
        util.renderBeamShape(s, pos, fwd, up, right)
      end
    end
  end

  if not isPlaceMode then
    local s = sensors[selectedSensorIdx]
    if s and s.pos and (not s.isLive or s.forceGimbals) then
      local posWS = util.coeffs2PosVS(s.pos, veh) + vPos
      local dir, up = util.sensor2VS(s.dir, s.up, veh)
      handleGimbals(posWS)
      util.renderLocalFrame(posWS, dir, up)
    end
  end

  -- Keep the UI indexing in range.
  selectedVehicleIdx = max(1, min(#vehicles, selectedVehicleIdx))
  selectedSensorIdx = max(1, min(#sensors, selectedSensorIdx))

  -- Manage the front end.
  manageMainToolWindow()
  manageAttachedSensorsWindow()
  manageSensorPropWindow()
  managePreviewWindow(stype.tCamera, dt)
  managePreviewWindow(stype.tIMU, dt)
  managePreviewWindow(stype.tUltrasonic, dt)

  if be:getEnabled() and #previewConfigs[stype.tIMU].openPreviews > 0 then
    plotOffset = plotOffset + 1 >= plotLen and 0 or plotOffset + 1
  end
end

-- Called when the 'Sensor Configuration Editor' icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isSensorConfigurationEditor = true
end

-- Called when the 'Sensor Configuration Editor' is exited.
local function onDeactivate()
  editor.hideWindow(toolWinName)
  editor.hideWindow(attachedSensorsWinName)
  editor.hideWindow(sensorPropWinName)
  for _, config in pairs(previewConfigs) do
    for _, preview in ipairs(config.openPreviews) do
      editor.hideWindow(preview.winName)
    end
    table.clear(config.openPreviews)
  end
  isSensorConfigurationEditor = false
  isAttachedSensorsWinOpen = false
  isSensorPropWinOpen = false
end

local function loadExistingSensor(sensorType, sensorId, conf)
  local existingSensor = conversions.getLiveSensorConfiguration(sensorType, sensorId, conf)
  if not sensorConfigs[existingSensor.vid] then
    sensorConfigs[existingSensor.vid] = {existingSensor}
    if ctrSensor[sensorType] ~= nil then
      ctrSensor[sensorType] = ctrSensor[sensorType] + 1
    end
  else
    local sensors = sensorConfigs[existingSensor.vid]
    for sid = 1, #sensors + 1 do
      if sensors[sid] == nil then
        sensors[sid] = existingSensor
        if ctrSensor[sensorType] ~= nil then
          ctrSensor[sensorType] = ctrSensor[sensorType] + 1
        end
      end
      if sensors[sid].name == conf.name then
        sensors[sid] = tableMerge(sensors[sid], existingSensor)
        return
      end
    end
  end
end

local function loadExistingSensors()
  local activeSensors = extensions.tech_sensors.getActiveSensors()
  for i = 1, #activeSensors do
    local sensorType, sensorId = unpack(activeSensors[i])
    local conf = extensions.tech_sensors.getSensorConfiguration(sensorType, sensorId)
    if not conf.isStatic then
      loadExistingSensor(sensorType, sensorId, conf)
    end
  end
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  if not tech_license.isValid() then return end
  editor.editModes.sensorConfigurationEditMode = {
    displayName = "Edit Sensor Configuration",
    onUpdate = nop,
    onActivate = onActivate,
    onDeactivate = onDeactivate,
    icon = editor.icons.carSensors,
    iconTooltip = "Sensor Configuration Editor",
    auxShortcuts = {},
    hideObjectIcons = true }
  initPreviewIcons()
  editor.registerWindow(toolWinName, toolWinSize)
  editor.registerWindow(attachedSensorsWinName, attachedSensorsWinSize)
  editor.registerWindow(sensorPropWinName, sensorPropWinSize)
  loadExistingSensors()
end

-- Pull live vehicle sensors into sensorConfigs (IMU/GPS/etc. created via API or other tools).
M.syncFromActiveSensors = loadExistingSensors

-- Serialization function.
local function onSerialize()
  for v = 1, #vehicles do
    local oldSensors = sensorConfigs[vehicles[v].vid]
    if oldSensors then
      for i = 1, #oldSensors do
        oldSensors[i].isLive = false
        handleEditLiveModeSwitch(oldSensors, i)
      end
    end
  end
  return { d = lpack.encode(sensorConfigs), ctrSensor = ctrSensor }
end

-- Deserialization function.
local function onDeserialized(dataIn)
  getCurrentVehicleList()
  table.clear(sensorConfigs)
  local data = lpack.decode(dataIn.d)
  ctrSensor = dataIn.ctrSensor
  for i = 1, #vehicles do
    local v = vehicles[i]
    if data[v.vid] then
      sensorConfigs[v.vid] = data[v.vid]
    end
  end
end

local function onSensorCreated(sensorType, sensorId)
  local conf = extensions.tech_sensors.getSensorConfiguration(sensorType, sensorId)
  if conf ~= nil and not conf.isStatic and conf.name ~= nil then
    loadExistingSensor(sensorType, sensorId, conf)
  end
end

local function onSensorRemoved(sensorType, sensorId)
  for i = 1, #sensorConfigs do
    local sensors = sensorConfigs[i]
    for j = 1, #sensors do
      if sensors[j].id == sensorId and sensors[j].isLive then
        table.remove(sensors, j)
        return
      end
    end
  end
end

-- Public interface.
M.sensorConfigs =                                         sensorConfigs

M.doesContainSensorType =                                 doesContainSensorType
M.numberOfSensorType =                                    numberOfSensorType
M.updateCollectedVehiclePOIData =                         updateCollectedVehiclePOIData
M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onSerialize =                                           onSerialize
M.onDeserialized =                                        onDeserialized
M.onSensorCreated =                                       onSensorCreated
M.onSensorRemoved =                                       onSensorRemoved

return M
