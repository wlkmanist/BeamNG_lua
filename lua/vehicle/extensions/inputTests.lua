-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min, max, abs, sqrt, floor, clockhp = math.min, math.max, math.abs, math.sqrt, math.floor, os.clockhp
local M = {}
local tests
local cr, prevClock
local histogramBucketCount, latencyTimeout = 30, 0.5
local wheelStoppedTimeout, wheelStoppedLimit = 7, 0.15
local oscillationMeasurementTimeLimit, oscillationStableTimeout = 10, 2
local tireLatencyNodeForce, contactPatchNodeCount = 5000, 5
local invalidSteeringThreshold = -1e9
local FFBID = -1

local function sendGeHook(hookName, data)
  obj:queueGameEngineLua(string.format("extensions.hook(%q, %s)", hookName, serialize(data)))
end

local function failRun(runId, message)
  for _, testId in ipairs(tests[runId].resultIds) do
    sendGeHook("onInputTestStats", {
      testId = testId,
      sampleCount = 0,
      unit = "ms",
      bucketPeakCount = 0,
      buckets = {},
      message = message,
    })
  end
  sendGeHook("onInputTestStatus", runId)
end

function M.update(dtSim, simWheelPos, hydroPos)
  local now = clockhp()
  local dt = prevClock and now - prevClock or dtSim
  prevClock = now
  local ok, runFFBCalc, nextHydroPos = coroutine.resume(cr, dt, simWheelPos, hydroPos)
  if not ok then
    local testId = M.running
    local message = string.format("Test failed with an internal error: %s", tostring(runFFBCalc))
    log("E", "", debug.traceback(cr, tostring(runFFBCalc)))
    prevClock, M.running, cr = nil, nil, nil
    hydros.testHook = nil
    failRun(testId, message)
    return false, hydroPos
  end
  if coroutine.status(cr) == "dead" then
    local testId = M.running
    prevClock, M.running, cr = nil, nil, nil
    hydros.testHook = nil
    sendGeHook("onInputTestStatus", testId)
  end
  return runFFBCalc, nextHydroPos
end

local function halfSampleMode(values, first, last)
  first = first or 1
  last = last or #values
  local n = last - first + 1
  if n <= 0 then return 0 end
  if n == 1 then return values[first] end
  if n == 2 then return (values[first] + values[last]) * 0.5 end
  if n == 3 then
    local leftWidth = values[first + 1] - values[first]
    local rightWidth = values[last] - values[first + 1]
    if leftWidth == rightWidth then return values[first + 1] end
    return leftWidth < rightWidth and (values[first] + values[first + 1]) * 0.5 or (values[first + 1] + values[last]) * 0.5
  end

  local windowSize = floor((n + 1) / 2)
  local bestFirst = first
  local bestWidth = values[first + windowSize - 1] - values[first]
  for i = first + 1, last - windowSize + 1 do
    local width = values[i + windowSize - 1] - values[i]
    if width < bestWidth then
      bestWidth = width
      bestFirst = i
    end
  end
  return halfSampleMode(values, bestFirst, bestFirst + windowSize - 1)
end

local function formatStatValue(value, unit, scale, unitDecimals)
  local scaled = value * scale
  if unit == "" then
    local absValue = abs(scaled)
    local decimals = absValue >= 100 and 1 or absValue >= 10 and 2 or absValue >= 1 and 3 or absValue >= 0.1 and 4 or absValue >= 0.01 and 5 or 6
    return (string.format("%." .. decimals .. "f", scaled):gsub("%.?0+$", ""))
  end
  return string.format("%." .. (unitDecimals or 1) .. "f%s", scaled, unit)
end

local function buildStats(testId, values, unit, scale, message, unitDecimals)
  table.sort(values)
  local sampleCount = #values
  local stats = {
    testId = testId,
    sampleCount = sampleCount,
    unit = unit,
    bucketPeakCount = 0,
    buckets = {},
  }
  if message then stats.message = message end
  if sampleCount == 0 then
    log("I", "", string.format("%s completed: no samples", testId))
    return stats
  end

  local median = values[floor((sampleCount + 1) / 2)]
  local hsMode = halfSampleMode(values)
  local minv, maxv = values[1], values[sampleCount]
  local trimCount = floor(sampleCount * 0.1)
  local trimmedFirst = 1 + trimCount
  local trimmedLast = sampleCount - trimCount
  local sum, sumsq = 0, 0
  for _, value in ipairs(values) do
    sum, sumsq = sum + value, sumsq + value * value
  end
  local average = sum / sampleCount
  local modeErrorSum = 0
  local modeErrorLowSum, modeErrorLowCount = 0, 0
  local modeErrorHighSum, modeErrorHighCount = 0, 0
  for i = trimmedFirst, trimmedLast do
    local delta = values[i] - hsMode
    modeErrorSum = modeErrorSum + abs(delta)
    if delta < 0 then
      modeErrorLowSum, modeErrorLowCount = modeErrorLowSum - delta, modeErrorLowCount + 1
    elseif delta > 0 then
      modeErrorHighSum, modeErrorHighCount = modeErrorHighSum + delta, modeErrorHighCount + 1
    end
  end
  local modeError = modeErrorSum / (trimmedLast - trimmedFirst + 1)
  local modeErrorLow = modeErrorLowCount > 0 and modeErrorLowSum / modeErrorLowCount or 0
  local modeErrorHigh = modeErrorHighCount > 0 and modeErrorHighSum / modeErrorHighCount or 0
  local stddev = sqrt(max(0, sumsq / sampleCount - average * average))
  stats.value = (testId == "systemResolutionTest" and maxv or hsMode) * scale
  stats.modeError, stats.modeErrorLow, stats.modeErrorHigh = modeError * scale, modeErrorLow * scale, modeErrorHigh * scale
  local displayRange = maxv - minv
  local bucketWidth = displayRange <= 0 and 0 or displayRange / histogramBucketCount

  for i = 1, histogramBucketCount do
    local bucketMin = i == 1 and minv or minv + (i - 1) * bucketWidth
    local bucketMax = i == histogramBucketCount and maxv or minv + i * bucketWidth
    stats.buckets[i] = {
      count = 0,
      min = bucketMin * scale,
      max = bucketMax * scale,
    }
  end

  for _, value in ipairs(values) do
    local bucket = stats.buckets[displayRange <= 0 and 1 or min(histogramBucketCount, floor((value - minv) / displayRange * histogramBucketCount) + 1)]
    bucket.count = bucket.count + 1
    stats.bucketPeakCount = max(stats.bucketPeakCount, bucket.count)
  end

  local fmt = function(value) return formatStatValue(value, unit, scale, unitDecimals) end
  log("I", "", string.format("%s completed: samples %s, average %s, median %s, half-sample mode %s, mode error %s (-%s/+%s), min %s, max %s, std dev %s",
    testId,
    sampleCount,
    fmt(average),
    fmt(median),
    fmt(hsMode),
    fmt(modeError),
    fmt(modeErrorLow),
    fmt(modeErrorHigh),
    fmt(minv),
    fmt(maxv),
    fmt(stddev)
  ))

  return stats
end

local function sendSystemStats(latencies, resolutions, frequencies)
  sendGeHook("onInputTestStats", buildStats("systemLatencyTest", latencies, "ms", 1000))
  sendGeHook("onInputTestStats", buildStats("systemResolutionTest", resolutions, "", 1))
  sendGeHook("onInputTestStats", buildStats("systemFrequencyTest", frequencies, "Hz", 1))
end

local up = vec3(0, 0, 1)
local function twistContactPatch(w, direction)
  -- find out the contact patch (assume the 5 bottom rubber nodes)
  local treadNodes = w.treadNodes or {}
  local bottomNodes = {}
  for _, nodeId in ipairs(treadNodes) do
    bottomNodes[#bottomNodes + 1] = {id = nodeId, pos = obj:getNodePosition(nodeId)}
  end
  table.sort(bottomNodes, function(a, b) return a.pos.z < b.pos.z end)
  local total = min(contactPatchNodeCount, #bottomNodes)
  if total == 0 then return false end
  -- calculate the contact patch center
  local center = vec3()
  for i = 1, total do center:setAdd(bottomNodes[i].pos) end
  center:setScaled(1 / total)
  -- apply forces to rotate the contact patch
  for i = 1, total do
    local radial = bottomNodes[i].pos
    radial:setSub(center)
    radial.z = 0
    obj:applyForceVector(bottomNodes[i].id, up:cross(radial:normalized()) * tireLatencyNodeForce * direction)
  end
  return true
end

local function twistContactPatches(direction)
  local applied = false
  for _, wheel in pairs(wheels and wheels.wheels or {}) do
    if wheel.name and wheel.name:sub(1, 1) == "F" then applied = twistContactPatch(wheel, direction) or applied end
  end
  if not applied then log("E", "", "Unable to apply a tire latency impulse: no suitable steering tire tread nodes found") end
end

local function applyFFB(torque)
  hydros.getForceFeedbackFunction()(obj, FFBID, 10*torque, 0, 0, 0)
end

local function recvHardwareSteering()
  local steering = hydros.getAngleFunction()(FFBID)
  local timestamp = clockhp()
  if steering > invalidSteeringThreshold then return steering, timestamp end
  log("E", "", string.format("Unable to retrieve steering wheel position via low latency recvSteering API (%s, %s)", dumps(FFBID), dumps(steering)))
  log("E", "", debug.tracesimple())
end

local function sameSteering(a, b)
  return abs(a-b) < 0.00005
end

local function stoppedDuration(steering, steeringPrev, now, stoppedSince)
  if not sameSteering(steering, steeringPrev) then return now, 0 end
  return stoppedSince, now - stoppedSince
end

local function recordSystemUpdate(resolutions, frequencies, steering, steeringPrev, now, before)
  if steering == steeringPrev then return before end
  resolutions[#resolutions + 1] = 2 / abs(steering - steeringPrev)
  if before then
    frequencies[#frequencies + 1] = 1 / (now - before)
  end
  return now
end

local function waitForHardwareWheelStopped(label, resolutions, frequencies)
  applyFFB(0)
  local start = clockhp()
  local stoppedSince = start
  local steeringPrev
  local before
  while true do
    local steering, now = recvHardwareSteering()
    if not steering then return false end
    steeringPrev = steeringPrev or steering
    before = recordSystemUpdate(resolutions, frequencies, steering, steeringPrev, now, before)
    local stoppedFor
    stoppedSince, stoppedFor = stoppedDuration(steering, steeringPrev, now, stoppedSince)
    if stoppedFor > wheelStoppedLimit then return true end
    steeringPrev = steering
    if now - start > wheelStoppedTimeout then break end
  end
  log("E", "", string.format("%s: timeout after %5.1fms while waiting for USB steering to stop, cannot perform test", label, wheelStoppedTimeout * 1000))
  return false
end

local function measureSystemLatency(label, force, resolutions, frequencies)
  local steeringStart, startTime = recvHardwareSteering()
  if not steeringStart then return end
  local steeringPrev = steeringStart
  local before
  applyFFB(force)
  while true do
    local steering, now = recvHardwareSteering()
    if not steering then return end
    before = recordSystemUpdate(resolutions, frequencies, steering, steeringPrev, now, before)
    if not sameSteering(steering, steeringPrev) then return now - startTime end
    steeringPrev = steering
    if now - startTime > latencyTimeout then break end
  end
  log("E", "", string.format("%s: USB steering wheel didn't react within %5.1fms. Test failed", label, latencyTimeout * 1000))
end

local function wheelStopped(dt, simWheelPos, hydroPos, label, runFFBCalc)
  local timeout = 0
  local stoppedSince = 0
  local simWheelPosPrev = simWheelPos
  while timeout < wheelStoppedTimeout do
    applyFFB(0)
    timeout = timeout + dt
    local stoppedFor
    stoppedSince, stoppedFor = stoppedDuration(simWheelPos, simWheelPosPrev, timeout, stoppedSince)
    if stoppedFor > wheelStoppedLimit then
      log("D", "", string.format("%s: Steering wheel stopped moving for %5.1fms after %5.1fms (angle: %.1f%%), lack of movement confirmed.", label, stoppedFor * 1000, timeout * 1000, simWheelPos * 100))
      return dt, simWheelPos, hydroPos
    end
    simWheelPosPrev = simWheelPos
    dt, simWheelPos, hydroPos = coroutine.yield(runFFBCalc, hydroPos)
  end
  log("E", "", string.format("%s: Steering wheel never stopped, cannot perform test", label))
  return false, simWheelPos, hydroPos
end

local function measureVehicleLatency(dt, simWheelPos, hydroPos, label, force)
  local elapsed = 0
  local simWheelPosPrev = simWheelPos
  while elapsed < latencyTimeout do
    if not sameSteering(simWheelPos, simWheelPosPrev) then return dt, simWheelPos, hydroPos, elapsed end
    simWheelPosPrev = simWheelPos
    twistContactPatches(force)
    dt, simWheelPos, hydroPos = coroutine.yield(true, hydroPos)
    elapsed = elapsed + dt
  end
  log("E", "", string.format("%s: Steering wheel never moved, cannot perform test", label))
  return dt, simWheelPos, hydroPos, nil
end

local function measureFFBImpulseLatency(dt, simWheelPos, hydroPos, label, force, isLastMeasurement)
  log("D", "", string.format("%s: Steering wheel stayed stopped for a while (angle: %.1f%%). Measuring latency...", label, simWheelPos * 100))
  applyFFB(force)
  local elapsed = 0
  local simWheelPosPrev = simWheelPos
  while true do
    if not sameSteering(simWheelPos, simWheelPosPrev) then
      if not isLastMeasurement then dt, simWheelPos, hydroPos = coroutine.yield(false, hydroPos) end
      return dt, simWheelPos, hydroPos, elapsed
    end
    elapsed = elapsed + dt
    if elapsed > latencyTimeout then break end
    simWheelPosPrev = simWheelPos
    dt, simWheelPos, hydroPos = coroutine.yield(false, hydroPos)
  end
  log("W", "", string.format("%s: Steering wheel never reacted. Test failed", label))
  return dt, simWheelPos, hydroPos, nil
end

-- MARK: oscillation tests
local function vehicleOscillationTest(dt, simWheelPos, hydroPos)
  local test = tests[M.running]
  -- artificially go offcenter, so that oscillations have a chance of happening
  local offcenterTime = 0.5
  local offcenterCountdown = offcenterTime
  local simWheelPosPrev = simWheelPos
  while offcenterCountdown > 0 do
    offcenterCountdown = offcenterCountdown - dt
    hydroPos = 0.3 * offcenterCountdown / offcenterTime
    simWheelPosPrev = simWheelPos
    dt, simWheelPos = coroutine.yield(true, hydroPos)
  end

  local originalForceCoef, originalForceCoefLowSpeed = hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed
  local factor = 0.1
  hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed = originalForceCoef * factor, originalForceCoefLowSpeed * factor

  -- target centerpoint, let ffb try to achieve it, measure the oscillations
  hydroPos = 0
  local amplitudes, frequencies = {}, {}
  local lastExtremumTimes = {}
  local measurementElapsed = 0
  local lastExtremumTime = 0
  local direction = not sameSteering(simWheelPos, simWheelPosPrev) and sign(simWheelPos - simWheelPosPrev)
  while measurementElapsed < oscillationMeasurementTimeLimit and #amplitudes < test.measurements do
    local prevTime = measurementElapsed
    simWheelPosPrev = simWheelPos
    dt, simWheelPos = coroutine.yield(true, hydroPos)
    measurementElapsed = measurementElapsed + dt
    if not sameSteering(simWheelPos, simWheelPosPrev) then
      local newDirection = sign(simWheelPos - simWheelPosPrev)
      if direction and newDirection ~= direction then
        local amplitude = 0.5 * abs(simWheelPosPrev) * v.data.input.steeringWheelLock
        amplitudes[#amplitudes + 1] = amplitude

        local period = lastExtremumTimes[direction] and prevTime - lastExtremumTimes[direction]
        local frequencyText = "--"
        if period and period > 0 then
          local frequency = 1 / period
          frequencyText = formatStatValue(frequency, "Hz", 1, 2)
          frequencies[#frequencies + 1] = frequency
        end
        log("I", "", string.format("Oscillation detected with amplitude: %s, frequency: %s", formatStatValue(amplitude, "º", 1), frequencyText))
        lastExtremumTimes[direction] = prevTime
        lastExtremumTime = prevTime
      end
      direction = newDirection
    end
    if measurementElapsed - lastExtremumTime > oscillationStableTimeout then break end
  end
  hydros.wheelFFBForceCoef, hydros.wheelFFBForceCoefLowSpeed = originalForceCoef, originalForceCoefLowSpeed
  sendGeHook("onInputTestStats", buildStats("oscillationTest", amplitudes, "º", 1))
  sendGeHook("onInputTestStats", buildStats("vehicleFrequencyTest", frequencies, "Hz", 1, nil, 2))
  return true, hydroPos
end

local function latencyTest(dt, simWheelPos, hydroPos)
  local test = tests[M.running]
  local resultId = test.resultIds[1]
  local values = {}
  local failureMessage
  for i = 10, 1, -1 do
    dt, simWheelPos, hydroPos = coroutine.yield(true, 0.1 * i)
  end

  for sample = 1, test.measurements do
    local label = string.format("%s %i/%i", resultId, sample, test.measurements)
    dt, simWheelPos, hydroPos = wheelStopped(dt, simWheelPos, hydroPos, label, test.runFFBCalc)
    if not dt then
      failureMessage = "Test failed: steering wheel never stopped."
      break
    end

    local latency
    dt, simWheelPos, hydroPos, latency = test.measure(dt, simWheelPos, hydroPos, label, sample % 2 == 1 and 1 or -1, sample == test.measurements)
    if latency == nil then
      failureMessage = "Test failed: steering wheel never reacted."
      break
    end

    log("I", "", string.format("%s: Steering wheel reacted in: %5.1fms", label, latency * 1000))
    values[sample] = latency
  end

  applyFFB(0)
  sendGeHook("onInputTestStats", buildStats(resultId, values, "ms", 1000, failureMessage))
  return test.runFFBCalc, hydroPos
end

local function systemTest(_, _, hydroPos)
  log("I", "", "Running system latency/resolution/frequency test")
  local test = tests[M.running]
  local latencies, resolutions, frequencies = {}, {}, {}

  if not waitForHardwareWheelStopped(string.format("%s setup", M.running), resolutions, frequencies) then
    sendSystemStats(latencies, resolutions, frequencies)
    return false, hydroPos
  end

  for sample = 1, test.measurements do
    local label = string.format("%s %i/%i", M.running, sample, test.measurements)
    if not waitForHardwareWheelStopped(label, resolutions, frequencies) then break end
    local latency = measureSystemLatency(label, sample % 2 == 1 and 1 or -1, resolutions, frequencies)
    applyFFB(0)
    if not latency then
      log("E", "", string.format("%s: Failed to measure system latency, aborting system latency test", label))
      break
    end
    local resolutionText = resolutions[#resolutions] and formatStatValue(resolutions[#resolutions], "", 1) or "--"
    local frequencyText = frequencies[#frequencies] and formatStatValue(frequencies[#frequencies], "Hz", 1) or "--"
    log("I", "", string.format("%s: latency: %5.1fms, resolution: %s, frequency: %s", label, latency * 1000, resolutionText, frequencyText))
    latencies[#latencies + 1] = latency
  end

  log("I", "", "Sending system latency/resolution/frequency test stats")
  sendSystemStats(latencies, resolutions, frequencies)
  return false, hydroPos
end

tests = {
  systemTest = { measurements = 30, run = systemTest, resultIds = {"systemFrequencyTest", "systemResolutionTest", "systemLatencyTest"} },
  simulationTest = { measurements = 30, run = latencyTest, runFFBCalc = false, measure = measureFFBImpulseLatency, resultIds = {"engineLatencyTest"} },
  vehicleTest = { measurements = 30, run = latencyTest, runFFBCalc = true, measure = measureVehicleLatency, resultIds = {"vehicleLatencyTest"} },
  vehicleOscillationTest = { measurements = 30, run = vehicleOscillationTest, resultIds = {"oscillationTest", "vehicleFrequencyTest"} },
}

function M.start(testId)
  FFBID = hydros.getFFBID()
  if FFBID < 0 then
    local message = string.format("Cannot run test '%s': No FFB ID found (%d)", testId, FFBID)
    log("E", "", message)
    failRun(testId, message)
    return
  end
  log("I", "", string.format("Started test: %s", testId))
  M.running = testId
  prevClock = nil
  cr = coroutine.create(tests[testId].run)
  hydros.testHook = M.update
end

M.onExtensionUnloaded = function() hydros.testHook = nil end
return M
