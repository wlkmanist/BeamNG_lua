-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- EXPERIMENTAL MODULE. This is an experimental feature that WILL CHANGE in the future.
-- Don't use this API, it IS NOT stable.

local M = {}

local techVehicleUtils = require('tech/techVehicleUtils')
local computeMassProperties = techVehicleUtils.computeMassProperties
local getNodeInfo = techVehicleUtils.getNodeInfo

local records = {}
local time = 0
local step = 0
local sampleSteps = 1  -- positive integer n (records only every n-th simulation step)
local sampleStep = -1  -- negative when not recording
local updateStepFunction = nop
local recordedQuantities = nil
local quantityFunctions = {}

local nodeCache = nil

local function init()
  if not nodeCache then
    nodeCache = techVehicleUtils.getNodeCache()
  end
end

local function update(dt)
  if sampleStep == 0 then
    local data = { time = time }
    for _, item in ipairs(recordedQuantities) do
      local name = item.name
      local args = item.data
      local key = item.key or name
      local f = quantityFunctions[name] or nop
      data[key] = f(args)
    end
    table.insert(records, data)
  end
  step = step + 1
  time = time + dt
  time = round(time/dt) * (1/round(1/dt))
  updateStepFunction()
end

local function updateSampleStep()
  sampleStep = sampleStep + 1
  if sampleStep == sampleSteps then
    sampleStep = 0
  end
end

local function startRecording(quantities, steps)
  sampleSteps = steps or 1
  sampleStep = 0
  recordedQuantities = quantities
  if sampleSteps > 1 then
    updateStepFunction = updateSampleStep
  end
end

local function stopRecording()
  local rec = records
  updateStepFunction = nop
  sampleStep = -1
  recordedQuantities = nil
  records = {}
  return rec
end

local function fetchRecordedData()
  local rec = records
  records = {}
  return rec
end

local function isRecording()
  return sampleStep >= 0
end

-- Quantity query functions
quantityFunctions.mass_properties = function(args)
  return computeMassProperties(args.without_wheels or false)
end

quantityFunctions.node_info = function(args)
  local success, n = getNodeInfo(nodeCache, args.nodes)
  if not success then
    n = nil
  end
  return n
end

-- Public interface
M.init = init
M.update = update
M.startRecording = startRecording
M.stopRecording = stopRecording
M.fetchRecordedData = fetchRecordedData
M.isRecording = isRecording

return M
