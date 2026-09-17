-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local utilRos = require('tech/ros/util')

local PACKAGED_ROS_DEFAULTS = '/lua/ge/extensions/tech/ros/rosDefaults.json'
local PREF_LAST_ROS_LIB_PATH = 'ros2Editor.general.lastRosLibPath'

local M = {}

function M.getRosCore()
  if not extensions.isExtensionLoaded('tech_ros_GECore') then
    extensions.load('tech_ros_GECore')
  end
  return extensions.tech_ros_GECore
end

function M.isRosLibLoaded()
  local rosCore = M.getRosCore()
  return rosCore ~= nil and rosCore.isRosLibLoaded and rosCore.isRosLibLoaded()
end

function M.getRosLibPath()
  local rosCore = M.getRosCore()
  return rosCore and rosCore.getRosLibPath and rosCore.getRosLibPath()
end

function M.getLastRosLibPathSuggestion()
  local libPath = editor.getPreference(PREF_LAST_ROS_LIB_PATH)
  return type(libPath) == 'string' and libPath ~= '' and libPath or nil
end

function M.loadRosLib(editorState, libPath)
  local rosCore = M.getRosCore()
  if not rosCore or not rosCore.loadRosLib then
    editorState.rosLibLoadError = 'ROS 2 GE core could not be loaded.'
    return false
  end
  local ok, err = rosCore.loadRosLib(libPath)
  if ok then
    editorState.rosLibLoadError = nil
    editor.setPreference(PREF_LAST_ROS_LIB_PATH, libPath)
  else
    editorState.rosLibLoadError = err or 'Failed to load the ROS 2 library.'
  end
  return ok
end

function M.browseAndLoadRosLib(editorState)
  local constants = require('tech/ros/constants')
  extensions.editor_fileDialog.openFile(
    function(data)
      local realPath = FS:getFileRealPath(data.filepath)
      if not realPath or realPath == '' then
        editorState.rosLibLoadError = 'Could not resolve the selected file.'
        return
      end
      M.loadRosLib(editorState, realPath)
    end,
    { { 'ROS 2 library', constants.ROS_LIB_EXTENSION } },
    false,
    constants.ROS_LIB_DEFAULT_DIR)
end

local function loadDefaultsDocument()
  local doc = utilRos.readJsonFile('tech/rosDefaults.json')
  if doc and doc.sensors then return doc end
  doc = jsonReadFile(PACKAGED_ROS_DEFAULTS)
  if doc and doc.sensors then
    if not FS:directoryExists('tech') then FS:directoryCreate('tech', true) end
    jsonWriteFile('tech/rosDefaults.json', doc, true)
  end
  return doc
end

function M.loadRosDefaultsIfNeeded(editorState)
  if editorState.rosDefaultsDocument ~= nil then return true end
  local doc = loadDefaultsDocument()
  if not doc or not doc.sensors then
    log('E', editorState.LOG_TAG, 'Could not load ROS defaults document.')
    return false
  end
  editorState.rosDefaultsDocument = doc
  table.clear(editorState.sensorTypeNamesInOrder)
  local seen = {}
  for _, entry in ipairs(doc.sensors) do
    local typeName = entry.type
    if type(typeName) == 'string' and typeName ~= '' and not seen[typeName] then
      seen[typeName] = true
      editorState.sensorTypeNamesInOrder[#editorState.sensorTypeNamesInOrder + 1] = typeName
    end
  end
  return #editorState.sensorTypeNamesInOrder > 0
end

function M.getDefaultSensorEntry(editorState, sensorTypeName)
  if not editorState.rosDefaultsDocument then return nil end
  local want = utilRos.getSensorType(sensorTypeName)
  if not want then return nil end
  for _, entry in ipairs(editorState.rosDefaultsDocument.sensors) do
    if utilRos.getSensorType(entry.type) == want then return entry end
  end
  return nil
end

function M.refreshSceneVehicleRows(editorState)
  table.clear(editorState.sceneVehicleRows)
  for vehicleId, vehicleObj in activeVehiclesIterator() do
    editorState.sceneVehicleRows[#editorState.sceneVehicleRows + 1] = {
      vehicleId = vehicleId,
      vehicleObj = vehicleObj,
      displayName = vehicleObj:getName(),
      jbeamName = vehicleObj.JBeam,
    }
  end
end

function M.removeDraftConfigsForDespawnedVehicles(editorState)
  local alive = {}
  for _, row in ipairs(editorState.sceneVehicleRows) do alive[row.vehicleId] = true end
  for vehicleId in pairs(editorState.draftWorkByVehicleId) do
    if not alive[vehicleId] then editorState.draftWorkByVehicleId[vehicleId] = nil end
  end
end

function M.getOrCreateDraftWork(editorState, vehicleId)
  local draft = editorState.draftWorkByVehicleId[vehicleId]
  if draft == nil then
    draft = { sensors = {} }
    editorState.draftWorkByVehicleId[vehicleId] = draft
  end
  return draft
end

function M.getSelectedVehicleId(editorState)
  local row = editorState.sceneVehicleRows[editorState.selectedVehicleRowIndex]
  return row and row.vehicleId or nil
end

function M.ensureSensorCreateTable(sensor)
  sensor.config = sensor.config or {}
  sensor.config.create = sensor.config.create or {}
  return sensor.config.create
end

local function isDictTable(value)
  return type(value) == 'table' and value[1] == nil
end

local function deepMerge(base, overrides)
  local result = utilRos.deepCopy(base or {})
  if type(overrides) ~= 'table' then return result end
  for key, value in pairs(overrides) do
    if isDictTable(value) and isDictTable(result[key]) then
      result[key] = deepMerge(result[key], value)
    else
      result[key] = utilRos.deepCopy(value)
    end
  end
  return result
end

function M.effectiveSensorCreateTable(sensor, defaultEntry)
  if not sensor then return {} end
  local defaultCreate = defaultEntry and defaultEntry.config and defaultEntry.config.create
  local userCreate = sensor.config and sensor.config.create
  return deepMerge(defaultCreate, userCreate)
end

local function buildLaunchConfig(editorState, draftWork)
  local config = { sensors = {} }
  for _, sensor in ipairs(draftWork.sensors) do
    local def = M.getDefaultSensorEntry(editorState, sensor.type)
    local out = def and utilRos.deepCopy(def) or {}
    out.id = sensor.id
    out.type = sensor.type
    if sensor.config then out.config = utilRos.deepCopy(sensor.config) end
    if sensor.restrictFields and sensor.fields and #sensor.fields > 0 then
      local selected = {}
      for _, name in ipairs(sensor.fields) do selected[name] = true end
      local kept = {}
      for _, field in ipairs(out.fields or {}) do
        if type(field) == 'table' and selected[field.name] then kept[#kept + 1] = field end
      end
      out.fields = kept
    end
    config.sensors[#config.sensors + 1] = out
  end
  return config
end

function M.launchRosForVehicle(editorState, vehicleId)
  if not vehicleId then return end
  local rosCore = M.getRosCore()
  if not rosCore or not rosCore.startRos then
    log('E', editorState.LOG_TAG, 'launchRosForVehicle: tech_ros_GECore not loaded.')
    return
  end
  local draftWork = M.getOrCreateDraftWork(editorState, vehicleId)
  if #draftWork.sensors < 1 then return end
  rosCore.startRos(vehicleId, buildLaunchConfig(editorState, draftWork))
end

function M.stopRosForVehicle(editorState, vehicleId)
  if not vehicleId then return end
  local rosCore = M.getRosCore()
  if not rosCore or not rosCore.stopRos then
    log('E', editorState.LOG_TAG, 'stopRosForVehicle: tech_ros_GECore not loaded.')
    return
  end
  rosCore.stopRos(vehicleId)
end

function M.saveDraftToTemplateFile(editorState, vehicleId)
  if not vehicleId then return end
  local draftWork = M.getOrCreateDraftWork(editorState, vehicleId)
  extensions.editor_fileDialog.saveFile(
    function(data)
      local export = buildLaunchConfig(editorState, draftWork)
      local file = io.open(data.filepath, 'w')
      if file then
        file:write(jsonEncode(export))
        file:close()
      end
    end,
    { { 'ROS template', '.json' } },
    false,
    '/')
end

function M.loadTemplateFileIntoDraft(editorState, vehicleId)
  if not vehicleId then return end
  extensions.editor_fileDialog.openFile(
    function(data)
      local root = utilRos.readJsonFile(data.filepath)
      if not root or type(root.sensors) ~= 'table' then return end
      editorState.draftWorkByVehicleId[vehicleId] = utilRos.deepCopy(root)
      for _, sensor in ipairs(editorState.draftWorkByVehicleId[vehicleId].sensors) do
        if sensor.fields and #sensor.fields > 0 then sensor.restrictFields = true end
      end
      if vehicleId == M.getSelectedVehicleId(editorState) then
        editorState.selectedSensorRowIndex[0] = 0
        editorState.invalidateSensorIdBuffer()
      end
    end,
    { { 'ROS template', '.json' } },
    false,
    '/')
end

return M
