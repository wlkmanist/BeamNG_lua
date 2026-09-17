-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local vehicleLostMessage = "Vehicle lost while the test was running."
local tests = {
  { id = "systemFrequencyTest", runId = "systemTest" },
  { id = "systemResolutionTest", runId = "systemTest" },
  { id = "systemLatencyTest", runId = "systemTest" },
  { id = "engineLatencyTest", runId = "simulationTest" },
  { id = "vehicleLatencyTest", runId = "vehicleTest" },
  { id = "oscillationTest", runId = "vehicleOscillationTest" },
  { id = "vehicleFrequencyTest", runId = "vehicleOscillationTest" },
}
local testsById = {}
for _, test in ipairs(tests) do testsById[test.id] = test end

local state = {
  hasVehicle = false,
  runAllActive = false,
  tests = tests,
}

local runQueue, pausePrev

local function forRunRows(runId, fn)
  for _, test in ipairs(tests) do
    if test.runId == runId then fn(test) end
  end
end

function M.updateUI()
  state.hasVehicle = getPlayerVehicle(0) ~= nil
  guihooks.trigger("InputTestStateChanged", state)
end

local function finishTests(message)
  if message and state.runningTestId then
    forRunRows(state.runningTestId, function(test) test.message = message end)
  end
  state.runningTestId, state.runAllActive, runQueue = nil, false, nil
  if pausePrev ~= nil then simTimeAuthority.pause(pausePrev) end
  pausePrev = nil
  M.updateUI()
end

local function advanceQueue()
  local runId = runQueue and table.remove(runQueue, 1)
  if not runId then return finishTests() end
  local vehicle = getPlayerVehicle(0)
  if not vehicle then return finishTests(vehicleLostMessage) end
  state.runningTestId = runId
  vehicle:queueLuaCommand(string.format("extensions.load('inputTests') inputTests.start(%q)", runId))
  M.updateUI()
end

function M.startTests(runIds)
  if not runIds[1] then return M.updateUI() end

  runQueue = {}
  local seen = {}
  for _, runId in ipairs(runIds) do
    if not seen[runId] then
      seen[runId], runQueue[#runQueue + 1] = true, runId
    end
  end
  state.runAllActive = #runQueue > 1
  for _, runId in ipairs(runQueue) do
    forRunRows(runId, function(test) test.message, test.stats = nil, nil end)
  end
  if pausePrev == nil then pausePrev = simTimeAuthority.getPause() end
  if state.runningTestId then forRunRows(state.runningTestId, function(test) test.message = "Test restarted." end) end
  simTimeAuthority.pause(false)
  advanceQueue()
end

function M.onInputTestStats(stats)
  local test = testsById[stats.testId]
  if not test then return end
  test.message, test.stats = stats.message or (stats.sampleCount == 0 and "No samples recorded." or nil), stats
  M.updateUI()
end

function M.onInputTestStatus(testId)
  if state.runningTestId ~= testId then return end
  advanceQueue()
end

function M.onVehicleDestroyed()
  if state.runningTestId and not getPlayerVehicle(0) then return finishTests(vehicleLostMessage) end
  M.updateUI()
end

M.onVehicleSpawned, M.onVehicleSwitched = M.updateUI, M.updateUI

return M
