-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"

local logTag = 'vslSignalLogger'

local lpack = require('lpack')
local resolver = require('tech/signalResolver')

local isLogging = false
local stepCounter = 0
local linesWritten = 0
local frequencySteps = 1
local outputPath = nil
local selectedSignals = {}
local timeSinceStart = 0

log('I', logTag, 'VSL Signal Logger controller loaded.')

local function escapeCSV(value)
  if value == nil then
    return ""
  end
  local s = tostring(value)
  if string.find(s, '[,"]') then
    s = '"' .. string.gsub(s, '"', '""') .. '"'
  end
  return s
end

local function appendLine(line)
  if not outputPath then
    return
  end
  local f = io.open(outputPath, "a")
  if not f then
    return
  end
  f:write(line)
  f:close()
end

local function initLogFile()
  if not outputPath then
    return
  end
  local f = io.open(outputPath, "w")
  if not f then
    log('E', logTag, 'Failed to create log file: ' .. tostring(outputPath))
    return
  end
  local header = "timestamp"
  for i = 1, #selectedSignals do
    header = header .. "," .. escapeCSV(selectedSignals[i].name)
  end
  f:write(header .. "\r\n")
  f:close()
end

local function init(jbeamData)
  local data = lpack.decode(jbeamData)
  local payload = data[1]
  selectedSignals = payload.signals or {}
  outputPath = payload.filepath
  frequencySteps = tonumber(payload.frequencySteps) or 1
  if frequencySteps < 1 then
    frequencySteps = 1
  end
  if resolver.setStaticKinematicsData then
    resolver.setStaticKinematicsData(payload.staticData or payload.cData or {})
  end
  if resolver.setSensorMap then
    resolver.setSensorMap(payload.sensorMap or {})
  end
  stepCounter = 0
  timeSinceStart = 0
  linesWritten = 0
  isLogging = true
  log('I', logTag, 'START logging: ' .. #selectedSignals .. ' signals, freq=' .. frequencySteps .. ', file=' .. tostring(outputPath))
  initLogFile()
end

local function startLogging()
  isLogging = true
  log('I', logTag, 'Logging resumed.')
end

local function stopLogging()
  if isLogging then
    log('I', logTag, 'STOP logging. Rows written: ' .. linesWritten .. ', steps: ' .. stepCounter .. ', file=' .. tostring(outputPath))
  end
  isLogging = false
end

local function update(dt)
  if not isLogging then
    return
  end
  stepCounter = stepCounter + 1
  timeSinceStart = timeSinceStart + dt
  if stepCounter % frequencySteps ~= 0 then
    return
  end
  local line = tostring(timeSinceStart)
  for i = 1, #selectedSignals do
    local value = resolver.resolve(selectedSignals[i])
    line = line .. "," .. escapeCSV(value)
  end
  appendLine(line .. "\r\n")
  linesWritten = linesWritten + 1
  if linesWritten == 1 then
    log('I', logTag, 'First data row written.')
  end
  if linesWritten % 1000 == 0 then
    log('I', logTag, 'Logging progress: ' .. linesWritten .. ' rows, time=' .. string.format("%.2f", timeSinceStart) .. 's')
  end
end

M.init = init
M.startLogging = startLogging
M.stopLogging = stopLogging
M.update = update

return M
