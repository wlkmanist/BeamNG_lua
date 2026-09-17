-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'vslSignalEditor'

local vSensors = require('editor/sensorConfigurationEditor')
local sensorConversions = require('editor/tech/sensorConfiguration/conversions')
local signalListGenerator = require('util/signalListGenerator')
local vehicleSignalData = require('util/vehicleSignalData')
local csvlib = require('csvlib')
local dat = require('tech/cosimulationNames')
local groups = dat.groups

local function sensorStype()
  extensions.load('tech_sensors')
  return extensions.tech_sensors.stype
end

local im = ui_imgui
local max, min = math.max, math.min

local toolWinName, toolWinSize = 'vslSignalEditor', im.ImVec2(580, 160)
local signalsWinName, signalsWinSize = 'vslSignalsWindow', im.ImVec2(750, 600)
local isSignalsWinOpen = false
local dullWhite = im.ImVec4(1, 1, 1, 0.5)
local redB, redD = im.ImVec4(0.7, 0.5, 0.5, 1), im.ImVec4(0.7, 0.5, 0.5, 0.5)
local greenB = im.ImVec4(0.5, 0.7, 0.5, 1)
local blueB, blueD = im.ImVec4(0.5, 0.5, 0.7, 1), im.ImVec4(0.5, 0.5, 0.7, 0.5)
local orangeB = im.ImVec4(184/255, 127/255, 75/255, 1)

local vehicles = {}
local signals = {}
local selectedVehicleIdx = 1
local isEditorActive = false
local isVluaDataReturned = false
local isRequestSent = false

-- True until buildSignalList has run for the current category filter / vehicle data generation.
local signalsListNeedsRebuild = true
local cData = {}

local isKinematics = im.BoolPtr(true)
local isDriver = im.BoolPtr(true)
local isWheels = im.BoolPtr(true)
local isElectrics = im.BoolPtr(true)
local isPowertrain = im.BoolPtr(true)
local isSensors = im.BoolPtr(true)

-- Set when "Select all listed" / "Unselect all listed" is clicked; applied after signal list rebuild.
local pendingSelectAllListed = false
local pendingUnselectAllListed = false

-- Text filter for the signals list (group, name, description, type).
local signalListFilterBuf = im.ArrayChar(256, "")

local function trimString(s)
  return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function signalRowMatchesFilter(signal)
  local q = trimString(string.lower(ffi.string(signalListFilterBuf)))
  if q == "" then
    return true
  end
  local function fieldMatches(v)
    return string.find(string.lower(tostring(v or "")), q, 1, true)
  end
  return fieldMatches(signal.groupName) or fieldMatches(signal.name) or fieldMatches(signal.description) or fieldMatches(signal.type)
end

-- Persists isIncluded across signal list rebuilds (category toggles, reload).
local savedSignalChoices = {}

local function signalSelectionKey(s)
  return s.groupName .. '\0' .. s.name
end

local function snapshotSignalChoicesFrom(list)
  for i = 1, #list do
    local s = list[i]
    savedSignalChoices[signalSelectionKey(s)] = { isIncluded = s.isIncluded }
  end
end

local function clearSignalChoicesStorage()
  table.clear(savedSignalChoices)
end

local function applySavedSignalChoices(list)
  for i = 1, #list do
    local s = list[i]
    local p = savedSignalChoices[signalSelectionKey(s)]
    if p then
      s.isIncluded = p.isIncluded
    end
  end
end

local isLogging = false
-- Seconds between CSV rows; clamp matches cosimulation time fields (see editor_cosimulationSignalEditor).
local loggingSamplePeriodS = im.FloatPtr(0.0005)
local loggingFilepath = im.ArrayChar(256, "vsl_signals_log.csv")
local loggingStepMin = 1
-- Stride divisor for saved frequencySteps rows (vehicle logger step counter).
local vslFrequencyStepsScale = 2000

local function frequencyStepsFromSamplePeriodS()
  local period = min(1e4, max(1e-4, loggingSamplePeriodS[0]))
  return max(loggingStepMin, math.floor(period * vslFrequencyStepsScale + 0.5))
end

local function updateCollectedVehicleData(collectedData)
  cData, isVluaDataReturned = lpack.decode(collectedData), true
  vehicleSignalData.setData(cData)
end

local function getCurrentVehicleList()
  table.clear(vehicles)
  local ctr = 1
  for vid, veh in activeVehiclesIterator() do
    vehicles[ctr] = {
      vid = vid, veh = veh, name = veh:getName(),
      jBeam = veh.JBeam, config = veh:getField('partConfig', '0')}
    if not vSensors.sensorConfigs[vid] then
      vSensors.sensorConfigs[vid] = {}
    end
    ctr = ctr + 1
  end
end

local function syncSensorConfigsFromVehicle()
  extensions.load('tech_sensors')
  extensions.load('editor_sensorConfigurationEditor')
  if vSensors.syncFromActiveSensors then
    vSensors.syncFromActiveSensors()
  end
end

local function invalidateVehicleSignalData()
  isRequestSent, isVluaDataReturned = false, false
  vehicleSignalData.clear()
  table.clear(cData)
end

local function markSignalsListStale()
  signalsListNeedsRebuild = true
  table.clear(signals)
end

local function applySelectAllListed()
  for i = 1, #signals do
    signals[i].isIncluded = true
  end
  snapshotSignalChoicesFrom(signals)
  log('I', logTag, string.format('Select all listed: %d rows', #signals))
end

local function applyUnselectAllListed()
  for i = 1, #signals do
    signals[i].isIncluded = false
  end
  snapshotSignalChoicesFrom(signals)
  log('I', logTag, string.format('Unselect all listed: %d rows', #signals))
end

local function buildSignalsListFromCache()
  local vehicle = vehicles[selectedVehicleIdx]
  if not vehicle then
    return false
  end
  local sensors = vSensors.sensorConfigs[vehicle.vid]
  local allSignals = signalListGenerator.buildSignalList({
    includeKinematics = isKinematics[0],
    includeDriver = isDriver[0],
    includeWheels = isWheels[0],
    includeElectrics = isElectrics[0],
    includePowertrain = isPowertrain[0],
    includeSensors = isSensors[0],
    cData = cData,
    sensors = sensors
  })

  table.clear(signals)
  for i = 1, #allSignals do
    if allSignals[i].readOnly then
      allSignals[i].isFrom = false
      signals[#signals + 1] = allSignals[i]
    end
  end
  applySavedSignalChoices(signals)
  if pendingSelectAllListed then
    pendingSelectAllListed = false
    applySelectAllListed()
  elseif pendingUnselectAllListed then
    pendingUnselectAllListed = false
    applyUnselectAllListed()
  end
  return true
end

local function requestVehicleData()
  local vehicle = vehicles[selectedVehicleIdx]
  if not vehicle then
    return
  end
  isRequestSent = true
  vehicleSignalData.requestVehicleData(vehicle.vid)
end

local function updateSignalsList()
  syncSensorConfigsFromVehicle()

  local data, ready = vehicleSignalData.getData()
  if not ready then
    if not isRequestSent then
      requestVehicleData()
    end
    return false
  end
  isRequestSent = false
  isVluaDataReturned = true
  cData = data or {}
  return buildSignalsListFromCache()
end

local function requestSelectAllListed()
  syncSensorConfigsFromVehicle()
  pendingUnselectAllListed = false
  if signalsListNeedsRebuild or #signals < 1 then
    pendingSelectAllListed = true
    local _, ready = vehicleSignalData.getData()
    if not ready then
      invalidateVehicleSignalData()
    end
    markSignalsListStale()
    return
  end
  applySelectAllListed()
end

local function requestUnselectAllListed()
  syncSensorConfigsFromVehicle()
  pendingSelectAllListed = false
  if signalsListNeedsRebuild or #signals < 1 then
    pendingUnselectAllListed = true
    local _, ready = vehicleSignalData.getData()
    if not ready then
      invalidateVehicleSignalData()
    end
    markSignalsListStale()
    return
  end
  applyUnselectAllListed()
end

local function unlinkAllSignals()
  clearSignalChoicesStorage()
  for i = 1, #signals do
    signals[i].isIncluded = false
  end
end

local function getSelectedSignalsForLogging()
  local selected = {}
  for i = 1, #signals do
    local sig = signals[i]
    if sig.isIncluded then
      selected[#selected + 1] = {
        name = sig.name,
        groupName = sig.groupName,
        type = sig.type,
        description = sig.description
      }
    end
  end
  return selected
end

-- Sensor vlua controllers only exist after a config entry is toggled Live (id is assigned then).
-- If the user selects sensor signals but leaves sensors in Edit mode, auto-enable Live for those instances.
local function ensureSensorsLiveForLogging(vehicle, selected)
  local sensors = (vSensors.sensorConfigs and vSensors.sensorConfigs[vehicle.vid]) or {}
  if #sensors < 1 or #selected < 1 then
    return
  end

  local needIdealRadar, needRoads = false, false
  local needByName = {}
  for i = 1, #selected do
    local g = selected[i].groupName
    if g == groups.idealRADAR then
      needIdealRadar = true
    elseif g == groups.roadsSensor then
      needRoads = true
    elseif g and g ~= groups.kinematics and g ~= groups.wheels and g ~= groups.driver
        and g ~= groups.electrics and g ~= groups.powertrain then
      needByName[g] = true
    end
  end

  extensions.load('tech_sensors')
  local stype = sensorStype()
  for i = 1, #sensors do
    local s = sensors[i]
    if s and s.name and not s.isLive then
      local shouldLive = needByName[s.name] or false
      if needIdealRadar and s.type == stype.tIdealRADAR then
        shouldLive = true
      end
      if needRoads and s.type == stype.tRoads then
        shouldLive = true
      end
      if shouldLive then
        s.isLive = true
        sensorConversions.makeSensorLive(s, vehicle)
        log('I', logTag, 'Auto-enabled live sensor for VSL logging: ' .. tostring(s.name) .. ' id=' .. tostring(s.id))
      end
    end
  end
end

-- Build a {IMUs, GPSs, idealRADARs, roads} -> {{name, id}, ...} map of attached sensors for VSL logging.
-- Mirrors editor_cosimulationSignalEditor sensorMap construction so vlua resolver can find the right controllers.
-- We accept any sensor with an id (id is only assigned when the sensor was made live, so the vlua controller exists or recently existed).
-- Sensor type is inferred from name to keep parity with sensorConfigurationEditor.numberOfSensorType.
local function buildSensorMap(vid)
  local sensors = (vSensors.sensorConfigs and vSensors.sensorConfigs[vid]) or {}
  local stype = sensorStype()
  local IMUs, GPSs, idealRADARs, roads = {}, {}, {}, {}
  for i = 1, #sensors do
    local s = sensors[i]
    if s and s.name then
      if not s.id then
        log('W', logTag, 'Sensor not live (no id), skipped in sensorMap: ' .. tostring(s.name))
      else
        local nm = s.name
        if s.type == stype.tIMU or string.find(nm, 'IMU', 1, true) then
          IMUs[#IMUs + 1] = { name = nm, id = s.id }
        elseif s.type == stype.tGPS or string.find(nm, 'GPS', 1, true) then
          GPSs[#GPSs + 1] = { name = nm, id = s.id }
        elseif s.type == stype.tIdealRADAR or nm == 'Ideal RADAR' then
          idealRADARs[#idealRADARs + 1] = { name = nm, id = s.id }
        elseif s.type == stype.tRoads or nm == 'Local Roads [Info]' then
          roads[#roads + 1] = { name = nm, id = s.id }
        end
      end
    end
  end
  log('I', logTag, string.format('VSL sensorMap built for vid=%s : IMU=%d GPS=%d idealRADAR=%d roads=%d (raw sensorConfigs=%d)',
    tostring(vid), #IMUs, #GPSs, #idealRADARs, #roads, #sensors))
  for _, v in ipairs(IMUs) do log('I', logTag, '  IMU  : ' .. tostring(v.name) .. ' id=' .. tostring(v.id)) end
  for _, v in ipairs(GPSs) do log('I', logTag, '  GPS  : ' .. tostring(v.name) .. ' id=' .. tostring(v.id)) end
  for _, v in ipairs(idealRADARs) do log('I', logTag, '  iRdr : ' .. tostring(v.name) .. ' id=' .. tostring(v.id)) end
  for _, v in ipairs(roads) do log('I', logTag, '  roads: ' .. tostring(v.name) .. ' id=' .. tostring(v.id)) end
  return { IMUs = IMUs, GPSs = GPSs, idealRADARs = idealRADARs, roads = roads }
end

local function startSignalLogging()
  if isLogging then
    return
  end
  local vehicle = vehicles[selectedVehicleIdx]
  if not vehicle then
    return
  end
  local selected = getSelectedSignalsForLogging()
  if #selected == 0 then
    log('W', logTag, 'No signals selected for logging.')
    return
  end
  ensureSensorsLiveForLogging(vehicle, selected)
  local data, ready = vehicleSignalData.getData()
  local payload = {
    signals = selected,
    filepath = ffi.string(loggingFilepath),
    frequencySteps = frequencyStepsFromSamplePeriodS(),
    staticData = (ready and data and type(data) == 'table') and data or nil,
    sensorMap = buildSensorMap(vehicle.vid)
  }
  local vid = vehicle.vid
  be:queueObjectLua(vid, string.format("controller.loadControllerExternal('tech/vslSignalLogger', 'vslSignalLogger', %s)", serialize(lpack.encode({payload}))))
  isLogging = true
end

local function stopSignalLogging()
  if not isLogging then
    return
  end
  local vehicle = vehicles[selectedVehicleIdx]
  if vehicle then
    be:queueObjectLua(vehicle.vid, "controller.getController('vslSignalLogger').stopLogging()")
    be:queueObjectLua(vehicle.vid, "controller.unloadControllerExternal('vslSignalLogger')")
  end
  isLogging = false
end

-- Save the current signal selection to a CSV file.
local function saveConfiguration()
  extensions.editor_fileDialog.saveFile(
    function(data)
      local csv = csvlib.newCSV('type', 'groupName', 'name', 'description', 'dataType', 'filename', 'frequencySteps')

      -- Write the selected signals.
      local numSig = #signals
      for i = 1, numSig do
        local s = signals[i]
        if s.isIncluded then
          csv:add('signal', s.groupName, s.name, s.description, s.type, nil, nil)
        end
      end

      -- Write logging settings.
      csv:add('settings', nil, 'filename', ffi.string(loggingFilepath), 'string', nil, nil)
      csv:add('settings', nil, 'frequencySteps', tostring(frequencyStepsFromSamplePeriodS()), 'number', nil, nil)

      -- Write vehicle info.
      local vehicle = vehicles[selectedVehicleIdx]
      if vehicle then
        csv:add('vehicle', nil, 'model', vehicle.jBeam, 'string', nil, nil)
        csv:add('vehicle', nil, 'config', vehicle.config, 'string', nil, nil)
      end

      csv:write(data.filepath)
      log('I', logTag, 'Saved VSL config to: ' .. data.filepath)
    end,
    {{"csv",".csv"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Load a signal selection from a CSV file.
local function loadConfiguration()
  extensions.editor_fileDialog.openFile(
    function(data)
      -- Make sure signals list is populated first.
      isRequestSent = false
      updateSignalsList()
      unlinkAllSignals()

      local csv = csvlib.readFileCSV(data.filepath)
      local numLines, numSignals = #csv, #signals

      -- Apply signal selections.
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'signal' then
          for j = 1, numSignals do
            local s = signals[j]
            if d[2] == s.groupName and d[3] == s.name then
              s.isIncluded = true
              break
            end
          end
        end
      end

      -- Apply logging settings.
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'settings' then
          if d[3] == 'filename' then
            loggingFilepath = im.ArrayChar(256, d[4] or "vsl_signals_log.csv")
          end
          if d[3] == 'frequencySteps' then
            local steps = max(loggingStepMin, tonumber(d[4]) or 1)
            loggingSamplePeriodS = im.FloatPtr(min(1e4, max(1e-4, steps / vslFrequencyStepsScale)))
          end
        end
      end

      -- Warn if vehicle model differs.
      local vehicle = vehicles[selectedVehicleIdx]
      if vehicle then
        for i = 2, numLines do
          local d = csv[i]
          if d[1] == 'vehicle' and d[3] == 'model' and d[4] ~= vehicle.jBeam then
            log('W', logTag, 'Vehicle model in config (' .. tostring(d[4]) .. ') differs from selected vehicle (' .. vehicle.jBeam .. ').')
            break
          end
        end
      end

      log('I', logTag, 'Loaded VSL config from: ' .. data.filepath)
    end,
    {{"csv",".csv"}},
    false,
    "/")
end

local function manageMainWindow()
  if editor.beginWindow(toolWinName, "Scene Vehicles###vslMain", im.WindowFlags_NoTitleBar) then
    im.Separator()
    local listWidth = toolWinSize.x - 125
    local listHeight = toolWinSize.y - 30
    if im.BeginListBox("", im.ImVec2(listWidth, listHeight), im.WindowFlags_ChildWindow) then
      local numVehicles = #vehicles
      selectedVehicleIdx = math.max(1, math.min(numVehicles, selectedVehicleIdx))

      for i = 1, numVehicles do
        local veh = vehicles[i]
        im.Columns(7, "vslVehicleListColumns", false)
        im.SetColumnWidth(0, listWidth - 196)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)
        im.SetColumnWidth(3, 32)
        im.SetColumnWidth(4, 32)
        im.SetColumnWidth(5, 32)
        im.SetColumnWidth(6, 32)

        local vName = tostring(veh.vid .. ": " .. veh.name .. " - " .. veh.jBeam)
        if im.Selectable1(vName, i == selectedVehicleIdx, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
          if i ~= selectedVehicleIdx and not isLogging then
            selectedVehicleIdx = i
            clearSignalChoicesStorage()
            invalidateVehicleSignalData()
            markSignalsListStale()
            return
          end
        end
        im.NextColumn()

        -- Remove Vehicle button.
        do
          local text = 'Remove this vehicle from scene.'
          if editor.uiIconImageButton(editor.icons.trashBin2, im.ImVec2(22, 22), redB, nil, nil, 'removeVslVehicleButton' .. i) then
            if not isLogging then
              local vehToDelete = vehicles[i]
              vehToDelete.veh:delete()
              if not vehicles[selectedVehicleIdx] then
                clearSignalChoicesStorage()
                invalidateVehicleSignalData()
                markSignalsListStale()
                return
              end
              selectedVehicleIdx = math.min(numVehicles, selectedVehicleIdx)
              return
            end
          end
          if isLogging then
            text = 'Cannot remove vehicle while logging is active.'
          end
          im.tooltip(text)
        end
        im.NextColumn()

        -- Go To Vehicle button.
        if editor.uiIconImageButton(editor.icons.cameraFocusOnVehicle2, im.ImVec2(21, 21), greenB, nil, nil, 'goToVslVehicleButton' .. i) then
          core_camera.setByName(0, "orbit", false)
          be:enterVehicle(0, scenetree.findObject(veh.vid))
          if i ~= selectedVehicleIdx and not isLogging then
            selectedVehicleIdx = i
            clearSignalChoicesStorage()
            invalidateVehicleSignalData()
            markSignalsListStale()
            return
          end
        end
        im.tooltip('Go to the selected vehicle.')
        im.NextColumn()

        -- Open Signals Window button.
        local btnCol = blueB
        if isSignalsWinOpen and i == selectedVehicleIdx then btnCol = blueD end
        if editor.uiIconImageButton(editor.icons.code, im.ImVec2(19, 19), btnCol, nil, nil, 'openVslSignalsWinButton' .. i) then
          if i == selectedVehicleIdx or not isSignalsWinOpen then
            isSignalsWinOpen = not isSignalsWinOpen
          end
          if isSignalsWinOpen then
            editor.showWindow(signalsWinName)
          else
            editor.hideWindow(signalsWinName)
          end
          if i ~= selectedVehicleIdx and not isLogging then
            selectedVehicleIdx = i
            clearSignalChoicesStorage()
            invalidateVehicleSignalData()
            markSignalsListStale()
            return
          end
        end
        im.tooltip('Open the signals window for this vehicle.')
        im.NextColumn()

        -- Start/Stop Logging toggle button.
        if selectedVehicleIdx == i then
          local logCol = dullWhite
          local logIcon = editor.icons.play_arrow
          local logText = 'Start logging selected signals.'
          if isLogging then
            logCol, logIcon, logText = orangeB, editor.icons.stop, 'Stop logging selected signals.'
          end
          if editor.uiIconImageButton(logIcon, im.ImVec2(19, 19), logCol, nil, nil, 'toggleVslLogging' .. i) then
            if isLogging then
              stopSignalLogging()
            else
              startSignalLogging()
            end
          end
          im.tooltip(logText)
        end
        im.NextColumn()
        -- Save config button.
        if selectedVehicleIdx == i then
          if editor.uiIconImageButton(editor.icons.floppyDisk, im.ImVec2(19, 19), nil, nil, nil, 'saveVslConfigMain' .. i) then
            saveConfiguration()
          end
          im.tooltip('Save signal config to file.')
        end
        im.NextColumn()

        -- Load config button.
        if selectedVehicleIdx == i then
          if editor.uiIconImageButton(editor.icons.folder, im.ImVec2(19, 19), dullWhite, nil, nil, 'loadVslConfigMain' .. i) then
            loadConfiguration()
          end
          im.tooltip('Load signal config from file.')
        end
        im.NextColumn()

        im.Separator()
      end
      im.EndListBox()
    end
    im.Separator()
  end
  editor.endWindow()
end

local function manageSignalsWindow()
  if not isSignalsWinOpen or not vehicles[selectedVehicleIdx] then
    return
  end

  if editor.beginWindow(signalsWinName, vehicles[selectedVehicleIdx].name .. " [available signals]###vslSig") then
    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()
    if im.Checkbox("Kinematics", isKinematics) then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      markSignalsListStale()
    end
    im.SameLine()
    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()
    if im.Checkbox("Driver", isDriver) then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      markSignalsListStale()
    end
    im.SameLine()
    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()
    if im.Checkbox("Wheels", isWheels) then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      markSignalsListStale()
    end
    im.SameLine()
    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()
    if im.Checkbox("Electrics", isElectrics) then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      markSignalsListStale()
    end
    im.SameLine()
    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()
    if im.Checkbox("Powertrain", isPowertrain) then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      markSignalsListStale()
    end
    im.SameLine()
    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()
    if im.Checkbox("Sensors", isSensors) then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      markSignalsListStale()
    end

    im.Separator()

    im.PushItemWidth(420)
    im.InputText("Filter signals##vslSigFilter", signalListFilterBuf)
    im.PopItemWidth()
    im.SameLine()
    im.TextColored(dullWhite, "(group, name, description, type)")
    im.tooltip("Filter by partial text match. Signal indices still count all signals.")

    im.Separator()

    local numSignals = #signals
    local sigCtr = 1
    if im.BeginListBox("", im.ImVec2(665, 370), im.WindowFlags_ChildWindow) then
      local lastVisibleGroupName = nil
      for i = 1, numSignals do
        local signal = signals[i]
        -- Index counter must include every row, even when filtered out.
        local posStr, ctrCol = ' ', greenB
        if signal.isIncluded then
          posStr, ctrCol = tostring(sigCtr), redB
          sigCtr = sigCtr + 1
        end

        if signalRowMatchesFilter(signal) then
        if lastVisibleGroupName and lastVisibleGroupName ~= signal.groupName then
          im.Separator()
        end
        lastVisibleGroupName = signal.groupName

        im.Columns(5, "vslSignalsListBoxColumns", true)
        im.SetColumnWidth(0, 40)
        im.SetColumnWidth(1, 65)
        im.SetColumnWidth(2, 110)
        im.SetColumnWidth(3, 325)
        im.SetColumnWidth(4, 66)

        if im.Selectable1("##sigRow"..i, false, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then end
        im.SameLine()

        if signal.isIncluded then
          if editor.uiIconImageButton(editor.icons.check_box, im.ImVec2(20, 20), redB, nil, nil, 'includeSignalButton') then
            signal.isIncluded = false
          end
          im.tooltip('Do not include this signal in the logger.')
        else
          if editor.uiIconImageButton(editor.icons.check_box_outline_blank, im.ImVec2(20, 20), redD, nil, nil, 'discludeSignalButton') then
            signal.isIncluded = true
          end
          im.tooltip('Include this signal in the logger.')
        end
        im.SameLine()
        im.NextColumn()

        im.TextColored(ctrCol, posStr)
        im.NextColumn()
        im.TextColored(blueB, signal.groupName)
        im.NextColumn()
        im.TextColored(greenB, signal.description)
        im.NextColumn()
        local typeCol = redB
        if signal.type == 'boolean' then
          typeCol = greenB
        elseif signal.type == 'string' then
          typeCol = blueB
        end
        im.TextColored(typeCol, signal.type)
        im.NextColumn()
        end
      end
      im.EndListBox()
    end
    im.Separator()

    -- Reload signals button.
    if editor.uiIconImageButton(editor.icons.autorenew, im.ImVec2(28, 28), nil, nil, nil, 'reloadVslSignals') then
      if #signals > 0 then snapshotSignalChoicesFrom(signals) end
      invalidateVehicleSignalData()
      markSignalsListStale()
    end
    im.tooltip("Reload available signals.")
    im.SameLine()

    -- Unlink all signals button.
    if editor.uiIconImageButton(editor.icons.unlink, im.ImVec2(28, 28), nil, nil, nil, 'unlinkAllVslSignals') then
      unlinkAllSignals()
    end
    im.tooltip("Deselect all signals.")
    im.SameLine()

    if im.Button("Select all listed##vslSelectAllListed") then
      requestSelectAllListed()
    end
    im.tooltip("Include every signal row currently listed (respects category checkboxes, not the text filter).")
    im.SameLine()

    if im.Button("Unselect all listed##vslUnselectAllListed") then
      requestUnselectAllListed()
    end
    im.tooltip("Clear inclusion for every signal row currently listed (respects category checkboxes, not the text filter).")
    im.SameLine()

    -- Save configuration button.
    if editor.uiIconImageButton(editor.icons.floppyDisk, im.ImVec2(28, 28), nil, nil, nil, 'saveVslConfig') then
      saveConfiguration()
    end
    im.tooltip('Save the current signal selection to disk.')
    im.SameLine()

    -- Load configuration button.
    if editor.uiIconImageButton(editor.icons.folder, im.ImVec2(28, 28), dullWhite, nil, nil, 'loadVslConfig') then
      loadConfiguration()
    end
    im.tooltip('Load a signal selection from disk.')
    im.SameLine()

    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()

    -- Log filename.
    im.PushItemWidth(200)
    im.InputText("Log Filename", loggingFilepath)
    im.tooltip('Output filename or path for logging.')
    im.PopItemWidth()
    im.SameLine()

    im.Dummy(im.ImVec2(15, 0))
    im.SameLine()

    im.PushItemWidth(150)
    im.InputFloat("Sampling period (seconds)", loggingSamplePeriodS, 1e-4, 0.0, "%.5f s")
    loggingSamplePeriodS = im.FloatPtr(max(1e-4, min(1e4, loggingSamplePeriodS[0])))
    im.tooltip('Expected time between each CSV row.')
    im.PopItemWidth()

  else
    editor.hideWindow(signalsWinName)
    isSignalsWinOpen = false
  end
  editor.endWindow()
end

local function onEditorGui()
  if not isEditorActive then
    return
  end

  getCurrentVehicleList()
  selectedVehicleIdx = math.max(1, math.min(#vehicles, selectedVehicleIdx))

  if #vehicles > 0 and signalsListNeedsRebuild then
    if not updateSignalsList() then
      return
    end
    signalsListNeedsRebuild = false
  end

  manageMainWindow()
  manageSignalsWindow()
end

local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isEditorActive = true
  syncSensorConfigsFromVehicle()
  getCurrentVehicleList()
  invalidateVehicleSignalData()
  signalsListNeedsRebuild = true
  vehicleSignalData.ensureCosimEditorRegistered()
  vehicleSignalData.ensureExtensionRegistered()
end

local function onDeactivate()
  editor.hideWindow(toolWinName)
  editor.hideWindow(signalsWinName)
  isSignalsWinOpen = false
  isEditorActive = false
  stopSignalLogging()
end

local function onEditorInitialized()
  if tech_license.isValid() then
    vehicleSignalData.ensureCosimEditorRegistered()
    vehicleSignalData.ensureExtensionRegistered()
    editor.editModes.vslSignalEditMode = {
      displayName = "Vehicle Signal Logger",
      onUpdate = nop,
      onActivate = onActivate,
      onDeactivate = onDeactivate,
      icon = editor.icons.multiline_chart,
      iconTooltip = "Vehicle Signal Logger",
      auxShortcuts = {},
      hideObjectIcons = true }
    editor.registerWindow(toolWinName, toolWinSize)
    editor.registerWindow(signalsWinName, signalsWinSize)
  end
end

local function onVehicleReplaced(vid)
  clearSignalChoicesStorage()
  invalidateVehicleSignalData()
  markSignalsListStale()
  stopSignalLogging()
end

M.updateCollectedVehicleData = updateCollectedVehicleData
M.onEditorGui = onEditorGui
M.onEditorInitialized = onEditorInitialized
M.onVehicleReplaced = onVehicleReplaced

return M
