-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'vehicleSignalData'

local cData = {}
local isReady = false

local function setData(data)
  cData = data or {}
  isReady = true
end

-- queueGameEngineLua resolves GE globals, not require() tables.
local function ensureExtensionRegistered()
  if rawget(_G, 'util_vehicleSignalData') ~= nil then
    return
  end
  extensions.load('util/vehicleSignalData')
  if rawget(_G, 'util_vehicleSignalData') == nil then
    rawset(_G, 'util_vehicleSignalData', M)
    log('W', logTag, 'registered util_vehicleSignalData from module table (extensions.load did not set _G)')
  end
end

local function ensureCosimEditorRegistered()
  if rawget(_G, 'editor_cosimulationSignalEditor') == nil then
    extensions.load('editor_cosimulationSignalEditor')
  end
end

local function updateCollectedVehicleData(collectedData)
  cData = lpack.decode(collectedData)
  isReady = true
  -- Cosim editor tracks isVluaDataReturned separately from this module's isReady.
  if editor_cosimulationSignalEditor and editor_cosimulationSignalEditor.updateCollectedVehicleData then
    editor_cosimulationSignalEditor.updateCollectedVehicleData(collectedData)
  end
end

local function requestVehicleData(vid)
  cData = {}
  isReady = false
  -- vehicleSearcher posts to editor_cosimulationSignalEditor; util is fallback for older vlua.
  ensureCosimEditorRegistered()
  ensureExtensionRegistered()
  log('I', logTag, string.format('requestVehicleData vid=%s cosimLoaded=%s utilLoaded=%s',
    tostring(vid),
    tostring(rawget(_G, 'editor_cosimulationSignalEditor') ~= nil),
    tostring(rawget(_G, 'util_vehicleSignalData') ~= nil)))
  be:queueObjectLua(vid, "extensions.tech_vehicleSearcher.collectVehicleData()")
end

local function getData()
  return cData, isReady
end

local function clear()
  isReady = false
end

M.setData = setData
M.updateCollectedVehicleData = updateCollectedVehicleData
M.requestVehicleData = requestVehicleData
M.getData = getData
M.clear = clear
M.ensureExtensionRegistered = ensureExtensionRegistered
M.ensureCosimEditorRegistered = ensureCosimEditorRegistered

return M
