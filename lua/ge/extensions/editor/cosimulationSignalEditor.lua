-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}


local logTag = 'cosimulationSignalEditor'

local sensorMgr = require('extensions/tech/sensors')
local vSensors = require('editor/sensorConfigurationEditor')                                        -- The sensor configuration (vehicles) module.
local dat = require('tech/cosimulationNames')
local csvlib = require('csvlib')
local signalListGenerator = require('util/signalListGenerator')
local vehicleSignalData = require('util/vehicleSignalData')

-- Module constants.
local im = ui_imgui
local abs, min, max, floor, ceil = math.abs, math.min, math.max, math.floor, math.ceil

-- Module constants (UI).
local names, groups = dat.names, dat.groups                                                         -- The common string values used with cosimulation coupling.
local toolWinName, toolWinSize = 'cosimulationSignalEditor', im.ImVec2(580, 225)                    -- The main tool window of the editor. The main UI entry point.
local signalsWinName, signalsWinSize = 'SignalsWindow', im.ImVec2(750, 600)                         -- The vehicle signals window.
local isSignalsWinOpen = false                                                                      -- A flag which indicates if the vehicle signals window is open or closed.
local dullWhite = im.ImVec4(1, 1, 1, 0.5)                                                           -- Some commonly-used Imgui colour vectors.
local redB, redD = im.ImVec4(0.7, 0.5, 0.5, 1), im.ImVec4(0.7, 0.5, 0.5, 0.5)
local greenB, greenD = im.ImVec4(0.5, 0.7, 0.5, 1), im.ImVec4(0.5, 0.7, 0.5, 0.5)
local blueB, blueD = im.ImVec4(0.5, 0.5, 0.7, 1), im.ImVec4(0.5, 0.5, 0.7, 0.5)
local orangeB = im.ImVec4(184/255, 127/255, 75/255, 1)

-- Module state (back-end).
local vehicles = {}                                                                                 -- An ordered list of all vehicles currently in the scene.
local signals = {}                                                                                  -- An ordered list of available vehicle signals.
local cData = {}                                                                                    -- A table containing the collected data from vlua.
local selectedVehicleIdx = 1                                                                        -- The index of the selected vehicle, in the vehicles list.
local isCosimulationSignalEditor = false                                                            -- A flag which indicates if this editor is currently active.
local isExecuting = false                                                                           -- A flag which indicates if the coupling is currently being executed.
local isVluaDataReturned = false                                                                    -- A flag which indicates if requested vlua data has returned to ge lua.
local isRequestSent = false                                                                         -- A flag which indicates if a request has been sent to vlua.

-- True until buildSignalList has run for the current category filter / vehicle data generation.
local signalsListNeedsRebuild = true

-- Module state (front-end).
local compTime3rdParty = im.FloatPtr(0.0005)                                                        -- The expected 3rd party computation time (per cycle).
local pingTime = im.FloatPtr(0.00001)                                                               -- The expected udp socket ping time.
local sIP, rIP = im.ArrayChar(16, "127.0.0.1"), im.ArrayChar(16, "127.0.0.1")                       -- The IP addresses for the udp communication (3rd party computer).
local sPort, rPort = im.IntPtr(64890), im.IntPtr(64891)                                             -- The port numbers for the udp communication.


local isKinematics, isDriver, isWheels = im.BoolPtr(true), im.BoolPtr(true), im.BoolPtr(true)
local isElectrics, isPowertrain, isSensors = im.BoolPtr(true), im.BoolPtr(true), im.BoolPtr(true)
local isPose = im.BoolPtr(false)                                                                    -- A flag which indicates whether to store the vehicle pose, or not.

-- Set when "Select all listed" / "Unselect all listed" is clicked; applied after signal list rebuild.
local pendingSelectAllListed = false
local pendingUnselectAllListed = false

-- Text filter for the signals list (group, name, description, type).
local signalListFilterBuf = im.ArrayChar(256, "")
-- When enabled, only rows currently set to incoming (From / 3rd party -> BeamNG) are shown.
local showIncomingDirectionOnly = im.BoolPtr(false)

local function trimString(s)
  return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function signalRowMatchesFilter(signal)
  if showIncomingDirectionOnly[0] then
    if signal.readOnly or not signal.isFrom then
      return false
    end
  end
  local q = trimString(string.lower(ffi.string(signalListFilterBuf)))
  if q == "" then
    return true
  end
  local function fieldMatches(v)
    return string.find(string.lower(tostring(v or "")), q, 1, true)
  end
  return fieldMatches(signal.groupName) or fieldMatches(signal.name) or fieldMatches(signal.description) or fieldMatches(signal.type)
end

-- Persists include/from/mode choices across signal list rebuilds (category toggles, reload).
local savedSignalChoices = {}

local function signalSelectionKey(s)
  return s.groupName .. '\0' .. s.name
end

local function snapshotSignalChoicesFrom(list)
  for i = 1, #list do
    local s = list[i]
    savedSignalChoices[signalSelectionKey(s)] = {
      isIncluded = s.isIncluded,
      isFrom = s.isFrom,
      isMultiply = s.isMultiply,
      isAdd = s.isAdd,
      isFreeze = s.isFreeze,
    }
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
      if not s.readOnly then
        s.isFrom = p.isFrom
        s.isMultiply = p.isMultiply
        s.isAdd = p.isAdd
        s.isFreeze = p.isFreeze
      else
        s.isFrom = false
      end
    end
  end
end


-- Compute the vehicle space position of a sensor, given the local reference frame coefficients.
local function coeffs2PosVS(c, veh)
  local fwd, up = veh:getDirectionVector(), veh:getDirectionVectorUp()
  fwd:normalize()
  up:normalize()
  local right = fwd:cross(up)
  return c.x * fwd + c.y * right + c.z * up
end

-- Compute the vehicle space/world space frame of a sensor, given the local reference frame.
local function sensor2VS(dirLoc, upLoc, veh)
  local fwd, up = veh:getDirectionVector(), veh:getDirectionVectorUp()
  fwd:normalize()
  up:normalize()
  local right = fwd:cross(up)
  return vec3(fwd:dot(dirLoc), right:dot(dirLoc), up:dot(dirLoc)), vec3(fwd:dot(upLoc), right:dot(upLoc), up:dot(upLoc))
end

-- The callback function for use when collecting vehicle data from vlua.
local function updateCollectedVehicleData(collectedData)
  cData, isVluaDataReturned = lpack.decode(collectedData), true
  vehicleSignalData.setData(cData)
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
    -- Match sensorConfigurationEditor: ensure a sensor table exists per vid so cosim/VSL see the same config.
    if not vSensors.sensorConfigs[vid] then
      vSensors.sensorConfigs[vid] = {}
    end
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
  local vid = vehicle.vid
  local sensors = vSensors.sensorConfigs[vid]
  signals = signalListGenerator.buildSignalList({
    includeKinematics = isKinematics[0],
    includeDriver = isDriver[0],
    includeWheels = isWheels[0],
    includeElectrics = isElectrics[0],
    includePowertrain = isPowertrain[0],
    includeSensors = isSensors[0],
    cData = cData,
    sensors = sensors
  })
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

-- Populates the current available signals list.
local function updateSignalsList()
  if not isVluaDataReturned then
    if not isRequestSent then
      isRequestSent = true
      local vehicle = vehicles[selectedVehicleIdx]
      if vehicle then
        vehicleSignalData.requestVehicleData(vehicle.vid)
      end
    end
    return false
  end
  isRequestSent = false
  return buildSignalsListFromCache()
end

local function requestSelectAllListed()
  syncSensorConfigsFromVehicle()
  pendingUnselectAllListed = false
  if signalsListNeedsRebuild or #signals < 1 then
    pendingSelectAllListed = true
    if not isVluaDataReturned then
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
    if not isVluaDataReturned then
      invalidateVehicleSignalData()
    end
    markSignalsListStale()
    return
  end
  applyUnselectAllListed()
end

-- Unlink all signals (reset configuration).
local function unlinkAllSignals()
  clearSignalChoicesStorage()
  local numSignals = #signals
  for i = 1, numSignals do
    signals[i].isIncluded = false
  end
end


-- Fetches two ordered arrays containing the included 'to' and 'from' signals, respectively.
local function getToFromSignals()
  local to, from, tCtr, fCtr, numSignals = {}, {}, 1, 1, #signals
  for i = 1, numSignals do
    local sig = signals[i]
    if sig.isIncluded then
      if sig.isFrom then
        from[fCtr] = sig
        fCtr = fCtr + 1
      else
        to[tCtr] = sig
        tCtr = tCtr + 1
      end
    end
  end
  return to, from
end

-- Saves the current signals configuration state to file.
local function saveConfiguration(vehicle)
  extensions.editor_fileDialog.saveFile(
    function(data)
      local h = dat.headers
      local csv = csvlib.newCSV(h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8])

      -- Write the 'to' signal list.
      -- [The mode is not applicable to outgoing signals - the 3rd party can handle them any way it chooses there].
      local numSig = #signals
      for i = 1, numSig do
        local s = signals[i]
        if s.isIncluded then
          if not s.isFrom then
            csv:add('signalTo', s.groupName, s.name, nil, s.type, s.description, nil, nil)
          end
        end
      end

       -- Write the 'from' signal list, including all requested channels for every included signal.
       for i = 1, numSig do
        local s = signals[i]
        if s.isIncluded then
          if s.isFrom then
            csv:add('signalFrom', s.groupName, s.name, 'value', s.type, s.description, nil, nil)
            if s.isMultiply then csv:add('signalFrom', s.groupName, s.name, 'multiply', s.type, s.description, nil, nil) end
            if s.isAdd then csv:add('signalFrom', s.groupName, s.name, 'add', s.type, s.description, nil, nil) end
            if s.isFreeze then csv:add('signalFrom', s.groupName, s.name, 'freeze', 'boolean', s.description, nil, nil) end
          end
        end
      end

      -- Write the vehicle identifier and pose info.
      local vehicle = vehicles[selectedVehicleIdx]
      csv:add('vehicle', nil, 'Vehicle Model', vehicle.jBeam, "string", nil, nil, nil)
      csv:add('vehicle', nil, 'Vehicle Config', vehicle.config, "string", nil, nil, nil)
      if isPose[0] then
        local veh = vehicle.veh
        local pos, rot = veh:getPosition(), quatFromDir(veh:getDirectionVector(), veh:getDirectionVectorUp())
        csv:add('vehicle', nil, 'posX', tostring(pos.x), "number", nil, nil, nil)
        csv:add('vehicle', nil, 'posY', tostring(pos.y), "number", nil, nil, nil)
        csv:add('vehicle', nil, 'posZ', tostring(pos.z), "number", nil, nil, nil)
        csv:add('vehicle', nil, 'rotX', tostring(rot.x), "number", nil, nil, nil)
        csv:add('vehicle', nil, 'rotY', tostring(rot.y), "number", nil, nil, nil)
        csv:add('vehicle', nil, 'rotZ', tostring(rot.z), "number", nil, nil, nil)
        csv:add('vehicle', nil, 'rotW', tostring(rot.w), "number", nil, nil, nil)
      end

      -- Write the connection/socket info.
      csv:add('connection', nil, '3rd Party Computation Time', tostring(compTime3rdParty[0]), 'number', nil, nil, nil)
      csv:add('connection', nil, 'Ping Time', tostring(pingTime[0]), 'number', nil, nil, nil)
      csv:add('connection', 'otherUDP', 'IP', ffi.string(sIP), 'string', nil, nil, nil)
      csv:add('connection', 'otherUDP', 'port', tostring(sPort[0]), 'number', nil, nil, nil)
      csv:add('connection', 'beamngUDP', 'IP', ffi.string(rIP), 'string', nil, nil, nil)
      csv:add('connection', 'beamngUDP', 'port', tostring(rPort[0]), 'number', nil, nil, nil)

      -- Write the sensor info.
      local vid = vehicle.vid
      local sensors = vSensors.sensorConfigs[vid]
      local numIMU, IMUids = vSensors.numberOfSensorType(sensors, 'IMU')
      for i = 1, numIMU do
        local sensor = sensors[IMUids[i]]
        local name = sensor.name
        csv:add('sensors', name, 'posX', tostring(sensor.pos.x), 'number', nil, nil, nil)
        csv:add('sensors', name, 'posY', tostring(sensor.pos.y), 'number', nil, nil, nil)
        csv:add('sensors', name, 'posZ', tostring(sensor.pos.z), 'number', nil, nil, nil)
        csv:add('sensors', name, 'dirX', tostring(sensor.dir.x), 'number', nil, nil, nil)
        csv:add('sensors', name, 'dirY', tostring(sensor.dir.y), 'number', nil, nil, nil)
        csv:add('sensors', name, 'dirZ', tostring(sensor.dir.z), 'number', nil, nil, nil)
        csv:add('sensors', name, 'upX', tostring(sensor.up.x), 'number', nil, nil, nil)
        csv:add('sensors', name, 'upY', tostring(sensor.up.y), 'number', nil, nil, nil)
        csv:add('sensors', name, 'upZ', tostring(sensor.up.z), 'number', nil, nil, nil)
        csv:add('sensors', name, 'physicsUpdateTime', tostring(sensor.physicsUpdateTime), 'number', nil, nil, nil)
        csv:add('sensors', name, 'GFXUpdateTime', tostring(sensor.GFXUpdateTime), 'number', nil, nil, nil)
        csv:add('sensors', name, 'isUsingGravity', tostring(sensor.isUsingGravity), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isAllowWheelNodes', tostring(sensor.isAllowWheelNodes), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'smootherStrength', tostring(sensor.smootherStrength), 'number', nil, nil, nil)
        csv:add('sensors', name, 'isVisualised', tostring(sensor.isVisualised), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isStatic', tostring(sensor.isStatic), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isSnappingDesired', tostring(sensor.isSnappingDesired), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isForceInsideTriangle', tostring(sensor.isForceInsideTriangle), 'boolean', nil, nil, nil)
      end
      local numGPS, GPSids = vSensors.numberOfSensorType(sensors, 'GPS')
      for i = 1, numGPS do
        local sensor = sensors[GPSids[i]]
        local name = sensor.name
        csv:add('sensors', name, 'posX', tostring(sensor.pos.x), 'number', nil, nil, nil)
        csv:add('sensors', name, 'posY', tostring(sensor.pos.y), 'number', nil, nil, nil)
        csv:add('sensors', name, 'posZ', tostring(sensor.pos.z), 'number', nil, nil, nil)
        csv:add('sensors', name, 'dirX', tostring(sensor.dir.x), 'number', nil, nil, nil)
        csv:add('sensors', name, 'dirY', tostring(sensor.dir.y), 'number', nil, nil, nil)
        csv:add('sensors', name, 'dirZ', tostring(sensor.dir.z), 'number', nil, nil, nil)
        csv:add('sensors', name, 'upX', tostring(sensor.up.x), 'number', nil, nil, nil)
        csv:add('sensors', name, 'upY', tostring(sensor.up.y), 'number', nil, nil, nil)
        csv:add('sensors', name, 'upZ', tostring(sensor.up.z), 'number', nil, nil, nil)
        csv:add('sensors', name, 'physicsUpdateTime', tostring(sensor.physicsUpdateTime), 'number', nil, nil, nil)
        csv:add('sensors', name, 'GFXUpdateTime', tostring(sensor.GFXUpdateTime), 'number', nil, nil, nil)
        csv:add('sensors', name, 'isAllowWheelNodes', tostring(sensor.isAllowWheelNodes), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'refLon', tostring(sensor.refLon), 'number', nil, nil, nil)
        csv:add('sensors', name, 'refLat', tostring(sensor.refLat), 'number', nil, nil, nil)
        csv:add('sensors', name, 'isVisualised', tostring(sensor.isVisualised), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isStatic', tostring(sensor.isStatic), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isSnappingDesired', tostring(sensor.isSnappingDesired), 'boolean', nil, nil, nil)
        csv:add('sensors', name, 'isForceInsideTriangle', tostring(sensor.isForceInsideTriangle), 'boolean', nil, nil, nil)
      end
      local numIR, IRids = vSensors.numberOfSensorType(sensors, 'idealRADAR')
      for i = 1, numIR do
        local sensor = sensors[IRids[i]]
        local name = sensor.name
        csv:add('sensors', name, 'physicsUpdateTime', tostring(sensor.physicsUpdateTime), 'number', nil, nil, nil)
        csv:add('sensors', name, 'GFXUpdateTime', tostring(sensor.GFXUpdateTime), 'number', nil, nil, nil)
      end
      local numRS, RSids = vSensors.numberOfSensorType(sensors, 'roads')
      for i = 1, numRS do
        local sensor = sensors[RSids[i]]
        local name = sensor.name
        csv:add('sensors', name, 'physicsUpdateTime', tostring(sensor.physicsUpdateTime), 'number', nil, nil, nil)
        csv:add('sensors', name, 'GFXUpdateTime', tostring(sensor.GFXUpdateTime), 'number', nil, nil, nil)
      end

      csv:write(data.filepath)
    end,
    {{"csv",".csv"}},
    false,
    "/",
    "File already exists.\nDo you want to overwrite the file?")
end

-- Loads a signals configuration state from file, if appropriate.
local function loadConfiguration(vehicle)
  extensions.editor_fileDialog.openFile(
    function(data)

      -- Get the original signals list and remove all linking.
      markSignalsListStale()
      if not updateSignalsList() then
        log('W', logTag, 'loadConfiguration: vehicle signal data not ready yet')
        return
      end
      signalsListNeedsRebuild = false
      unlinkAllSignals()

      -- Read the .csv file into a lines structure.
      local csv = csvlib.readFileCSV(data.filepath)

      -- Collect all the 'To' signals, and set them in the vehicle signals array.
      local numLines, numSignals = #csv, #signals
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'signalTo' then
          for j = 1, numSignals do
            local s = signals[j]
            if d[2] == s.groupName and d[3] == s.name then
              s.isIncluded, s.isFrom = true, false
              break
            end
          end
        end
      end

      -- Collect all the 'From' signals, and set them in the vehicle signals array.
      local fromGroup = {}
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'signalFrom' then
          local name = d[3]
          if not fromGroup[name] then
            fromGroup[name] = { type = d[5], groupName = d[2], name = name, isMultiply = false, isAdd = false, isFreeze = false }
          end
          local mode = d[4]
          if mode == 'multiply' then fromGroup[name].isMultiply = true end
          if mode == 'add' then fromGroup[name].isAdd = true end
          if mode == 'freeze' then fromGroup[name].isFreeze = true end
        end
      end
      for name, c in pairs(fromGroup) do
        for j = 1, numSignals do
          local s = signals[j]
          if c.groupName == s.groupName and name == s.name then
            s.isIncluded, s.isFrom = true, true
            s.isMultiply, s.isAdd, s.isFreeze = c.isMultiply, c.isAdd, c.isFreeze
            break
          end
        end
      end

      -- Check the vehicle against the vehicle in the .csv file, and issue a warning if it is different.
      local jBeam, config = vehicle.jBeam, vehicle.config
      local posX, posY, posZ, rotX, rotY, rotZ, rotW = nil, nil, nil, nil, nil, nil, nil
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'vehicle' then
          if d[3] == 'Vehicle Model' and d[4] ~= jBeam then
            log('W', logTag, 'Vehicle (jBeam) in .csv different to currently-selected vehicle!')
            break
          end
          if d[3] == 'Vehicle Config' and d[4] ~= config then
            log('W', logTag, 'Vehicle (config) in .csv different to currently-selected vehicle!')
            break
          end
          if d[3] == 'posX' then posX = tonumber(d[4]) end
          if d[3] == 'posY' then posY = tonumber(d[4]) end
          if d[3] == 'posZ' then posZ = tonumber(d[4]) end
          if d[3] == 'rotX' then rotX = tonumber(d[4]) end
          if d[3] == 'rotY' then rotY = tonumber(d[4]) end
          if d[3] == 'rotZ' then rotZ = tonumber(d[4]) end
          if d[3] == 'rotW' then rotW = tonumber(d[4]) end
        end
      end

      -- If the vehicle pose was provided in the .csv, set the flag and teleport the vehicle to the given pose.
      isPose = im.BoolPtr(false)
      if posX then
        isPose = im.BoolPtr(true)
        spawn.safeTeleport(vehicle.veh, vec3(posX, posY, posZ), quat(rotX, rotY, rotZ, rotW))
      end

      -- Collect the connection data, and set the appropriate module state variables.
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'connection' then
          if d[3] == '3rd Party Computation Time' then compTime3rdParty = im.FloatPtr(tonumber(d[4])) end
          if d[3] == 'Ping Time' then pingTime = im.FloatPtr(tonumber(d[4])) end
          if d[2] == 'otherUDP' then
            if d[3] == 'IP' then sIP = im.ArrayChar(128, d[4]) end
            if d[3] == 'port' then sPort = im.IntPtr(tonumber(d[4])) end
          end
          if d[2] == 'beamngUDP' then
            if d[3] == 'IP' then rIP = im.ArrayChar(128, d[4]) end
            if d[3] == 'port' then rPort = im.IntPtr(tonumber(d[4])) end
          end
        end
      end

      -- Identify all the sensors listed in the .csv file, and store their names in a hashtable.
      local IMUsTable, GPSsTable, idealRADARsTable, roadsTable = {}, {}, {}, {}
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'sensors' then
          local sensorName = d[2]
          if string.find(sensorName, 'IMU') then IMUsTable[sensorName] = true end
          if string.find(sensorName, 'GPS') then GPSsTable[sensorName] = true end
          if sensorName == 'Ideal RADAR' then idealRADARsTable[sensorName] = true end
          if sensorName == 'Local Roads [Info]' then roadsTable[sensorName] = true end
        end
      end

    end,
    {{"csv",".csv"}},
    false,
    "/")
end

-- Executes the coupling.
local function execute()
  extensions.editor_fileDialog.openFile(
    function(data)
      isExecuting = true

      -- Read the .csv file into a lines structure.
      local csv = csvlib.readFileCSV(data.filepath)

      -- Collect all the 'To' signals.
      local signalsTo, ctr, numLines = {}, 1, #csv
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'signalTo' then
          signalsTo[ctr] = { type = d[5], groupName = d[2], name = d[3] }
          ctr = ctr + 1
        end
      end

      -- Collect all the 'From' signals.
      local signalsFrom, ctr = {}, 1
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'signalFrom' then
          signalsFrom[ctr] = {
            type = d[5], groupName = d[2], name = d[3],
            isValue = d[4] == 'value', isMultiply = d[4] == 'multiply', isAdd = d[4] == 'add', isFreeze = d[4] == 'freeze' }
          ctr = ctr + 1
        end
      end

      -- Check the vehicle against the vehicle in the .csv file, and issue a warning if it is different.
      local vehicle = vehicles[selectedVehicleIdx]
      local jBeam, config = vehicle.jBeam, vehicle.config
      local posX, posY, posZ, rotX, rotY, rotZ, rotW = nil, nil, nil, nil, nil, nil, nil
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'vehicle' then
          if d[3] == 'Vehicle Model' and d[4] ~= jBeam then
            log('W', logTag, 'Vehicle (jBeam) in .csv different to currently-selected vehicle!')
            break
          end
          if d[3] == 'Vehicle Config' and d[4] ~= config then
            log('W', logTag, 'Vehicle (config) in .csv different to currently-selected vehicle!')
            break
          end
          if d[3] == 'posX' then posX = tonumber(d[4]) end
          if d[3] == 'posY' then posY = tonumber(d[4]) end
          if d[3] == 'posZ' then posZ = tonumber(d[4]) end
          if d[3] == 'rotX' then rotX = tonumber(d[4]) end
          if d[3] == 'rotY' then rotY = tonumber(d[4]) end
          if d[3] == 'rotZ' then rotZ = tonumber(d[4]) end
          if d[3] == 'rotW' then rotW = tonumber(d[4]) end
        end
      end

      -- If the vehicle pose was provided in the .csv, teleport the vehicle to the given pose.
      -- Also move the camera to the vehicle.
      if posX then
        spawn.safeTeleport(vehicle.veh, vec3(posX, posY, posZ), quat(rotX, rotY, rotZ, rotW))
      end
      core_camera.setByName(0, "orbit", false)
      be:enterVehicle(0, scenetree.findObject(vehicle.vid))

      -- Collect the connection data, and set the appropriate module state variables.
      local time3rdParty, roundTripTime, udpSendIP, udpReceiveIP, udpSendPort, udpReceivePort = nil, nil, nil, nil, nil, nil
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'connection' then
          if d[3] == '3rd Party Computation Time' then time3rdParty = tonumber(d[4]) end
          if d[3] == 'Ping Time' then roundTripTime = tonumber(d[4]) end
          if d[2] == 'otherUDP' then
            if d[3] == 'IP' then udpSendIP = ffi.string(im.ArrayChar(128, d[4])) or '127.0.0.1' end
            if d[3] == 'port' then udpSendPort = tonumber(d[4]) end
          end
          if d[2] == 'beamngUDP' then
            if d[3] == 'IP' then udpReceiveIP = ffi.string(im.ArrayChar(128, d[4])) or '127.0.0.1' end
            if d[3] == 'port' then udpReceivePort = tonumber(d[4]) end
          end
        end
      end

      -- Identify all the sensors listed in the .csv file, and store their names in a hashtable.
      local IMUsTable, GPSsTable, idealRADARsTable, roadsTable = {}, {}, {}, {}
      local IMUsArray, GPSsArray, idealRADARsArray, roadsArray = {}, {}, {}, {}
      local iCtr, gCtr, irCtr, rCtr = 1, 1, 1, 1
      for i = 2, numLines do
        local d = csv[i]
        if d[1] == 'sensors' then
          local sensorName = d[2]
          if string.find(sensorName, 'IMU') and not IMUsTable[sensorName] then
            IMUsTable[sensorName] = true
            IMUsArray[iCtr] = sensorName
            iCtr = iCtr + 1
          end
          if string.find(sensorName, 'GPS') and not GPSsTable[sensorName] then
            GPSsTable[sensorName] = true
            GPSsArray[gCtr] = sensorName
            gCtr = gCtr + 1
          end
          if sensorName == 'Ideal RADAR' and not idealRADARsTable[sensorName] then
            idealRADARsTable[sensorName] = true
            idealRADARsArray[irCtr] = sensorName
            irCtr = irCtr + 1
          end
          if sensorName == 'Local Roads [Info]' and not roadsTable[sensorName] then
            roadsTable[sensorName] = true
            roadsArray[rCtr] = sensorName
            rCtr = rCtr + 1
          end
        end
      end

      -- Collect all the data for each identified sensor.
      local IMUs, GPSs, idealRADARs, roadsSensors = {}, {}, {}, {}
      for j = 1, #IMUsArray do
        local sensorName = IMUsArray[j]
        IMUs[j] = { name = sensorName, pos = vec3(0, 0), dir = vec3(0, 0), up = vec3(0, 0)}
        for i = 2, numLines do
          local d = csv[i]
          if d[2] == sensorName then
            local val = d[4]
            if val == 'true' then val = true elseif val == 'false' then val = false elseif val == 'nil' then val = false else val = tonumber(val) end
            if d[3] == 'posX' then IMUs[j].pos.x = val
            elseif d[3] == 'posY' then IMUs[j].pos.y = val
            elseif d[3] == 'posZ' then IMUs[j].pos.z = val
            elseif d[3] == 'dirX' then IMUs[j].dir.x = val
            elseif d[3] == 'dirY' then IMUs[j].dir.y = val
            elseif d[3] == 'dirZ' then IMUs[j].dir.z = val
            elseif d[3] == 'upX' then IMUs[j].up.x = val
            elseif d[3] == 'upY' then IMUs[j].up.y = val
            elseif d[3] == 'upZ' then IMUs[j].up.z = val
            else IMUs[j][d[3]] = val end
          end
        end
      end
      for j = 1, #GPSsArray do
        local sensorName = GPSsArray[j]
        GPSs[j] = { name = sensorName, pos = vec3(0, 0), dir = vec3(0, 0), up = vec3(0, 0)}
        for i = 2, numLines do
          local d = csv[i]
          if d[2] == sensorName then
            local val = d[4]
            if val == 'true' then val = true elseif val == 'false' then val = false elseif val == 'nil' then val = false else val = tonumber(val) end
            if d[3] == 'posX' then GPSs[j].pos.x = val
            elseif d[3] == 'posY' then GPSs[j].pos.y = val
            elseif d[3] == 'posZ' then GPSs[j].pos.z = val
            elseif d[3] == 'dirX' then GPSs[j].dir.x = val
            elseif d[3] == 'dirY' then GPSs[j].dir.y = val
            elseif d[3] == 'dirZ' then GPSs[j].dir.z = val
            elseif d[3] == 'upX' then GPSs[j].up.x = val
            elseif d[3] == 'upY' then GPSs[j].up.y = val
            elseif d[3] == 'upZ' then GPSs[j].up.z = val
            else GPSs[j][d[3]] = val end
          end
        end
      end
      for j = 1, #idealRADARsArray do
        local sensorName = idealRADARsArray[j]
        idealRADARs[j] = { name = sensorName }
        for i = 2, numLines do
          local d = csv[i]
          if d[2] == sensorName then
            local val = d[4]
            if val == 'true' then val = true elseif val == 'false' then val = false elseif val == 'nil' then val = false else val = tonumber(val) end
            idealRADARs[j][d[3]] = val
          end
        end
      end
      for j = 1, #roadsArray do
        local sensorName = roadsArray[j]
        roadsSensors[j] = { name = sensorName }
        for i = 2, numLines do
          local d = csv[i]
          if d[2] == sensorName then
            local val = d[4]
            if val == 'true' then val = true elseif val == 'false' then val = false elseif val == 'nil' then val = false else val = tonumber(val) end
            roadsSensors[j][d[3]] = val
          end
        end
      end

      -- Create the sensor map by sending a message to gelua to do so.
      -- [This is also where we create the sensor instances, and ensure the 'sensors' extension is loaded].
      extensions.load('tech_sensors')
      local mapIMUs, mapGPSs, mapIdealRADARs, mapRoads = {}, {}, {}, {}
      local vid, veh, sensorMap = vehicle.vid, vehicle.veh, {}
      for i = 1, #IMUs do
        IMUs[i].pos= coeffs2PosVS(IMUs[i].pos, veh)
        IMUs[i].dir, IMUs[i].up = sensor2VS(IMUs[i].dir, IMUs[i].up, veh)
        mapIMUs[i] = { name = IMUs[i].name, id = sensorMgr.createAdvancedIMU(vid, IMUs[i]) }
      end
      for i = 1, #GPSs do
        GPSs[i].pos= coeffs2PosVS(GPSs[i].pos, veh)
        GPSs[i].dir, GPSs[i].up = sensor2VS(GPSs[i].dir, GPSs[i].up, veh)
        mapGPSs[i] = { name = GPSs[i].name, id = sensorMgr.createGPS(vid, GPSs[i]) }
      end
      for i = 1, #idealRADARs do
        mapIdealRADARs[i] = { name = idealRADARs[i].name, id = sensorMgr.createIdealRADARSensor(vid, idealRADARs[i]) }
      end
      for i = 1, #roadsSensors do
        mapRoads[i] = { name = roadsSensors[i].name, id = sensorMgr.createRoadsSensor(vid, roadsSensors[i]) }
      end
      sensorMap = { IMUs = mapIMUs, GPSs = mapGPSs, idealRADARs = mapIdealRADARs, roads = mapRoads }

      local cData = {
        signalsTo = signalsTo, signalsFrom = signalsFrom,
        sensorMap = sensorMap,
        time3rdParty = time3rdParty, pingTime = roundTripTime,
        udpSendPort = udpSendPort, udpReceivePort = udpReceivePort,
        udpSendIP = udpSendIP, udpReceiveIP = udpReceiveIP,
        enableVSL = false,
        enableCosim = true,
      }
      local preload = "local c=controller.getController('cosimulationCoupling');if c then c.stop();controller.unloadControllerExternal('cosimulationCoupling') end;"
      be:queueObjectLua(vid, preload .. string.format("controller.loadControllerExternal('tech/cosimulationCoupling', 'cosimulationCoupling', %s)", serialize(lpack.encode({cData}))))

    end,
    {{"csv",".csv"}},
    false,
    "/")
end

-- Stops executing the coupling.
local function stopExecute()
  be:queueObjectLua(vehicles[selectedVehicleIdx].vid, "controller.getController('cosimulationCoupling').stop()")
  be:queueObjectLua(vehicles[selectedVehicleIdx].vid, "controller.unloadControllerExternal('cosimulationCoupling')")
  isExecuting = false
end




-- Manage the main tool window.
local function manageMainToolWindow()
  if editor.beginWindow(toolWinName, "Scene Vehicles###1", im.WindowFlags_NoTitleBar) then
    im.Separator()
    local listWidth = toolWinSize.x - 125  -- account for scrollbar width
    local listHeight = toolWinSize.y - 30
    if im.BeginListBox("", im.ImVec2(listWidth, listHeight), im.WindowFlags_ChildWindow) then
      local numVehicles = #vehicles
      selectedVehicleIdx = math.max(1, math.min(numVehicles, selectedVehicleIdx))

      for i = 1, numVehicles do
        local veh = vehicles[i]
        -- im.Columns(8, "sceneVehiclesListBoxColumns", false) -- Adjusted number of columns to 8 to include dropdown.
        im.Columns(7, "sceneVehiclesListBoxColumns", false) -- Adjusted number of columns to 8 to include dropdown.
        im.SetColumnWidth(0, 260)
        im.SetColumnWidth(1, 32)
        im.SetColumnWidth(2, 32)
        im.SetColumnWidth(3, 32)
        im.SetColumnWidth(4, 32)
        im.SetColumnWidth(5, 32)
        im.SetColumnWidth(6, 32)
        -- im.SetColumnWidth(7, 110) -- Adjusted for the dropdown.

        -- Handle the individual row selection.
        local vName = tostring(veh.vid .. ": " .. veh.name .. " - " .. veh.jBeam)
        if im.Selectable1(vName, i == selectedVehicleIdx, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then
          if i ~= selectedVehicleIdx and not isExecuting then
            -- when executing it should not be possible to select another vehicle
            -- because clicking "stop coupling" on a different vehicle would not work correctly
            -- this is also why the "remove vehicle" button is disabled when executing
            selectedVehicleIdx = i
            clearSignalChoicesStorage()
            invalidateVehicleSignalData()
            markSignalsListStale()
            return
          end
        end
        im.NextColumn()

        -- 'Remove Vehicle' button.
        do
          local text = 'Remove this vehicle from scene.'
          if editor.uiIconImageButton(editor.icons.trashBin2, im.ImVec2(22, 22), redB, nil, nil, 'removeVehicleButton' .. i) then
            if not isExecuting then
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
          if isExecuting then
            text = 'Cannot remove vehicle while coupling is active.'
          end
          im.tooltip(text)
        end
        im.NextColumn()

        -- 'Go To Vehicle' button.
        if editor.uiIconImageButton(editor.icons.cameraFocusOnVehicle2, im.ImVec2(21, 21), greenB, nil, nil, 'goToVehicleButton' .. i) then
          core_camera.setByName(0, "orbit", false)
          be:enterVehicle(0, scenetree.findObject(veh.vid))
          if i ~= selectedVehicleIdx and not isExecuting then
            selectedVehicleIdx = i
            clearSignalChoicesStorage()
            invalidateVehicleSignalData()
            markSignalsListStale()
            return
          end
        end
        im.tooltip('Go to the selected vehicle.')
        im.NextColumn()

        -- 'Open Signals Window' button.
        local btnCol = blueB
        if isSignalsWinOpen and i == selectedVehicleIdx then btnCol = blueD end
        if editor.uiIconImageButton(editor.icons.code, im.ImVec2(19, 19), btnCol, nil, nil, 'openSignalsWinButton' .. i) then
          if i == selectedVehicleIdx or not isSignalsWinOpen then
            isSignalsWinOpen = not isSignalsWinOpen
          end
          if isSignalsWinOpen then
            editor.showWindow(signalsWinName)
          else
            editor.hideWindow(signalsWinName)
          end
          if i ~= selectedVehicleIdx then
            clearSignalChoicesStorage()
            invalidateVehicleSignalData()
            markSignalsListStale()
            return
          end
          selectedVehicleIdx = i
        end
        im.tooltip('Open the signals window for this vehicle.')
        im.NextColumn()

        -- 'Start/Stop Coupling' toggle button.
        if selectedVehicleIdx == i then
          local btnCol = dullWhite
          local btnIcon = editor.icons.jointUnlocked
          local btnText = 'Start coupling with 3rd party.'
          local btnTextStop = 'Stop coupling with 3rd party.'
          if isExecuting then
            btnCol, btnIcon, btnText = orangeB, editor.icons.jointLocked, btnTextStop
          end
          if editor.uiIconImageButton(btnIcon, im.ImVec2(19, 19), btnCol, nil, nil, 'executeToggleButton' .. i) then
            if not isExecuting then
              execute()
            else
              stopExecute()
            end
          end
          im.tooltip(btnText)
        end
        im.NextColumn()

        -- 'Save Signals Configuration' button.
        if selectedVehicleIdx == i then
          if editor.uiIconImageButton(editor.icons.floppyDisk, im.ImVec2(19, 19), nil, nil, nil, 'saveSignalsConfig' .. i) then
            saveConfiguration(vehicles[i])
          end
          im.tooltip('Save the current signals configuration, for this vehicle, to disk.')
        end
        im.NextColumn()

        -- 'Load Signals Configuration' button.
        if selectedVehicleIdx == i then
          if editor.uiIconImageButton(editor.icons.folder, im.ImVec2(19, 19), dullWhite, nil, nil, 'loadSignalsConfig' .. i) then
            loadConfiguration(vehicles[i])
          end
          im.tooltip('Load a signals configuration, for this vehicle, from disk.')
        end
        im.NextColumn()
      end
      im.EndListBox()
    end
    im.Separator()
  end
  editor.endWindow()
end





local function manageVehicleSignalsWindow()
  if isSignalsWinOpen and vehicles[selectedVehicleIdx] then
    if editor.beginWindow(signalsWinName, vehicles[selectedVehicleIdx].name .. " [available signals]###2") then
      local toCtr, fromCtr = 1, 1

      -- Top row of checkboxes for each available signals group.
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      -- Category toggles: same behavior as vslSignalEditor — always rebuild the list on change.
      -- (Previous cosim-only logic omitted "Sensors" from sibling checks and could block refresh, leaving a stale list without IMU/GPS rows.)
      if im.Checkbox("Kinematics", isKinematics) then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        markSignalsListStale()
      end
      im.tooltip('Include the Kinematics signals group.')
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      if im.Checkbox("Driver", isDriver) then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        markSignalsListStale()
      end
      im.tooltip('Include the Driver signals group.')
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      if im.Checkbox("Wheels", isWheels) then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        markSignalsListStale()
      end
      im.tooltip('Include the Wheels signals group.')
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      if im.Checkbox("Electrics", isElectrics) then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        markSignalsListStale()
      end
      im.tooltip('Include the Electrics signals group.')
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      if im.Checkbox("Powertrain", isPowertrain) then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        markSignalsListStale()
      end
      im.tooltip('Include the Powertrain signals group.')
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      if im.Checkbox("Sensors", isSensors) then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        markSignalsListStale()
      end
      im.tooltip('Include the Attached Sensors signals group.')

      im.Separator()

      im.PushItemWidth(420)
      im.InputText("Filter signals##cosimSigFilter", signalListFilterBuf)
      im.PopItemWidth()
      im.SameLine()
      im.TextColored(dullWhite, "(group, name, description, type)")
      im.tooltip("Filter by partial text match. To/From indices and message size still count all signals.")
      im.Checkbox("Incoming (From) only##cosimInSigOnly", showIncomingDirectionOnly)
      im.tooltip("Show only signals set to incoming direction (3rd party -> BeamNG). Read-only (outgoing) rows are hidden.")

      im.Separator()

      -- Signals listbox.
      if im.BeginListBox("", im.ImVec2(665, 370), im.WindowFlags_ChildWindow) then
        local numSignals = #signals
        local lastVisibleGroupName = nil
        for i = 1, numSignals do
          local signal = signals[i]
          -- To/From indices and message-size counters must include every row, even when filtered out.
          local posStr, ctrCol = ' ', greenB
          if signal.isIncluded then
            if signal.isFrom then
              posStr, ctrCol = tostring(fromCtr), redB
              fromCtr = fromCtr + 1
              if signal.isMultiply then
                posStr = posStr .. 'M'
                fromCtr = fromCtr + 1
              end
              if signal.isAdd then
                posStr = posStr .. 'A'
                fromCtr = fromCtr + 1
              end
              if signal.isFreeze then
                posStr = posStr .. 'F'
                fromCtr = fromCtr + 1
              end
            else
              posStr = tostring(toCtr)
              toCtr = toCtr + 1
            end
          end

          if signalRowMatchesFilter(signal) then
          if lastVisibleGroupName and lastVisibleGroupName ~= signal.groupName then
            im.Separator()
          end
          lastVisibleGroupName = signal.groupName

          im.Columns(6, "vehSignalsListBoxColumns", true)
          im.SetColumnWidth(0, 40)
          im.SetColumnWidth(1, 65)
          im.SetColumnWidth(2, 110)
          im.SetColumnWidth(3, 325)
          im.SetColumnWidth(4, 66)
          im.SetColumnWidth(5, 32)

          -- Handle the individual row selection.
          if im.Selectable1("##sigRow"..i, false, bit.bor(im.SelectableFlags_SpanAllColumns, im.SelectableFlags_AllowItemOverlap)) then end
          im.SameLine()

          -- 'Include Signal' checkbox.
          if signals[i].isIncluded then
            if editor.uiIconImageButton(editor.icons.check_box, im.ImVec2(20, 20), redB, nil, nil, 'includeSignalButton') then
              signals[i].isIncluded = false
            end
            im.tooltip('Do not include this signal in the vehicle signals configuration.')
          else
            if editor.uiIconImageButton(editor.icons.check_box_outline_blank, im.ImVec2(20, 20), redD, nil, nil, 'discludeSignalButton') then
              signals[i].isIncluded = true
            end
            im.tooltip('Include this signal in the vehicle signals configuration.')
          end
          im.SameLine()
          im.NextColumn()

          -- Currently-assigned signal position (index in configuration file).
          im.TextColored(ctrCol, posStr)
          im.NextColumn()

          -- Signal group name, name, and data type.
          im.TextColored(blueB, signal.groupName)
          im.SameLine()
          im.NextColumn()
          im.TextColored(greenB, signal.description)
          im.SameLine()
          im.NextColumn()
          local type, typeCol = signal.type, redB
          if type == 'boolean' then
            typeCol = greenB
          elseif type == 'string' then
            typeCol = blueB
          end
          im.TextColored(typeCol, type)
          im.SameLine()
          im.NextColumn()

          -- 'To / From Direction' button.
          -- [Choice is only for available for signals which are not read only].
          if signal.readOnly then
            if editor.uiIconImageButton(editor.icons.fast_forward, im.ImVec2(20, 20), greenD, nil, nil, 'signalReadOnlyButton') then
            end
            im.tooltip('This signal is read only, and goes from BeamNG -> 3rd Party.')
          else
            if signal.isFrom then
              if editor.uiIconImageButton(editor.icons.fast_rewind, im.ImVec2(20, 20), greenB, nil, nil, 'signalFromButton') then
                  signal.isFrom = false
              end
              im.tooltip('Current Direction: 3rd Party -> BeamNG.')
            else
              if editor.uiIconImageButton(editor.icons.fast_forward, im.ImVec2(20, 20), greenB, nil, nil, 'signalToButton') then
                signal.isFrom = true
              end
              im.tooltip('Current Direction: BeamNG -> 3rd Party.')
            end
          end

          im.NextColumn()
          end
        end
        im.EndListBox()
      end
      im.Separator()

      -- 'Reload Signals' button.
      if editor.uiIconImageButton(editor.icons.autorenew, im.ImVec2(28, 28), nil, nil, nil, 'reloadSignals') then
        if #signals > 0 then snapshotSignalChoicesFrom(signals) end
        invalidateVehicleSignalData()
        markSignalsListStale()
      end
      im.tooltip("Reload available signals.")
      im.SameLine()

      -- 'Unlink All Signals' button.
      if editor.uiIconImageButton(editor.icons.unlink, im.ImVec2(28, 28), nil, nil, nil, 'unlinkAllSignals') then
        unlinkAllSignals()
      end
      im.tooltip("Unlink all selected signals (reset configuration).")
      im.SameLine()

      if im.Button("Select all listed##cosimSelectAllListed") then
        requestSelectAllListed()
      end
      im.tooltip("Include every signal row currently listed (respects category checkboxes, not the text filter). Watch UDP size limits.")
      im.SameLine()

      if im.Button("Unselect all listed##cosimUnselectAllListed") then
        requestUnselectAllListed()
      end
      im.tooltip("Clear inclusion for every signal row currently listed (respects category checkboxes, not the text filter).")
      im.SameLine()


      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()

      -- Display the proposed message sizes.
      im.Dummy(im.ImVec2(5, 0))
      im.SameLine()
      local fromKb, toKb, fromWarn, toWarn = fromCtr * 0.008, toCtr * 0.008, '', ''
      local fromCol, toCol = greenB, greenB
      if fromKb > 1.5 then fromCol, fromWarn = redB, '  [WARNING: > 1 MPC]' end
      if toKb > 1.5 then toCol, toWarn = redB, '  [WARNING: > 1 MPC]' end
      im.TextColored(fromCol, '                            From: ' .. fromKb .. '/1.5kb' .. fromWarn)
      im.SameLine()
      im.TextColored(toCol, '                       To: ' .. toKb .. '/1.5kb' .. toWarn)

      im.Separator()

      -- 'Store Vehicle Pose' checkbox.
      im.Checkbox("Store Pos/Rot", isPose)
      im.tooltip('Toggle whether to store the vehicle pose (position and rotation) with configuration file.')
      im.SameLine()

      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()

      -- 3rd party computation time input box.
      im.PushItemWidth(200)
      im.InputFloat("3rd Party Computation Time", compTime3rdParty, 1e-4, 0.0, "%.5f s")
      compTime3rdParty = im.FloatPtr(max(1e-4, min(1e4, compTime3rdParty[0])))
      im.tooltip('The expected computation time for each 3rd party cycle in the coupling.')
      im.PopItemWidth()
      im.SameLine()

      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()
      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()

      -- UDP ping time input box.
      im.PushItemWidth(200)
      im.InputFloat("UDP Ping Time", pingTime, 1e-5, 0.0, "%.5f s")
      pingTime = im.FloatPtr(max(1e-5, min(1e4, pingTime[0])))
      im.tooltip('The expected udp socket ping time.')
      im.PopItemWidth()

      im.Separator()

      -- Third party IP and socket.
      im.Text('3rd Party IP/port:')
      im.SameLine()
      im.PushItemWidth(80)
      im.InputText("###300", sIP)
      im.ArrayChar(128, "Server description")
      im.tooltip('Set the IP address on the 3rd party computer.')
      im.PopItemWidth()
      im.SameLine()
      im.PushItemWidth(120)
      im.InputInt("###301", sPort, 10, nil)
      im.tooltip('Set the port number on the 3rd party computer.')
      im.PopItemWidth()
      sPort = im.IntPtr(max(1025, min(65536, sPort[0])))
      im.SameLine()

      im.Dummy(im.ImVec2(15, 0))
      im.SameLine()

      -- BeamNG IP and socket.
      im.Text('BeamNG IP/port:')
      im.SameLine()
      im.PushItemWidth(80)
      im.InputText("###302", rIP)
      im.tooltip('Set the IP address on the BeamNG computer.')
      im.PopItemWidth()
      im.SameLine()
      im.PushItemWidth(120)
      im.InputInt("###303", rPort, 10, nil)
      im.tooltip('Set the port number on the 3rd party computer.')
      im.PopItemWidth()
      rPort = im.IntPtr(max(1025, min(65536, rPort[0])))

    else
      editor.hideWindow(signalsWinName) -- Handle window close.
      isSignalsWinOpen = false
    end
    editor.endWindow()
  end
end

-- World editor main callback for rendering the UI.
local function onEditorGui()
  if not isCosimulationSignalEditor then
    return
  end

  -- Update the vehicles list to show what is currently available in the scene.
  getCurrentVehicleList()

  -- Compute the signals list, if required.
  if #vehicles > 0 and signalsListNeedsRebuild then
    if not updateSignalsList() then
      return
    end
    signalsListNeedsRebuild = false
  end

  -- Manage the front end.
  manageMainToolWindow()
  manageVehicleSignalsWindow()
end

-- Called when the 'Cosimulation Signal Editor' icon is pressed.
local function onActivate()
  editor.clearObjectSelection()
  editor.showWindow(toolWinName)
  isCosimulationSignalEditor = true
  syncSensorConfigsFromVehicle()
  signalsListNeedsRebuild = true
end

-- Called when the 'Cosimulation Signal Editor' is exited.
local function onDeactivate()
  editor.hideWindow(toolWinName)
  editor.hideWindow(signalsWinName)
  isCosimulationSignalEditor = false
  isSignalsWinOpen = false
end

-- Called upon world editor initialization.
local function onEditorInitialized()
  if tech_license.isValid() then
    vehicleSignalData.ensureCosimEditorRegistered()
    vehicleSignalData.ensureExtensionRegistered()
    editor.editModes.cosimulationSignalEditMode = {
      displayName = "Edit Co-Simulation Signals",
      onUpdate = nop,
      onActivate = onActivate,
      onDeactivate = onDeactivate,
      icon = editor.icons.jointLocked,
      iconTooltip = "Co-Simulation Editor",
      auxShortcuts = {},
      hideObjectIcons = true }
    editor.registerWindow(toolWinName, toolWinSize)
    editor.registerWindow(signalsWinName, signalsWinSize)
  end
end

-- Callback for when the vehicle has been changed.
local function onVehicleReplaced(vid)
  clearSignalChoicesStorage()
  invalidateVehicleSignalData()
  markSignalsListStale()
end

-- Serialization function.
local function onVehicleSpawned(vid)
  isExecuting = false
  log('I', logTag, 'On vehicle spawn - called on CTRL + R to reset coupling.')
end


-- Public interface.
M.updateCollectedVehicleData =                            updateCollectedVehicleData
M.onEditorGui =                                           onEditorGui
M.onEditorInitialized =                                   onEditorInitialized
M.onVehicleReplaced =                                     onVehicleReplaced
M.onVehicleSpawned =                                      onVehicleSpawned

return M
