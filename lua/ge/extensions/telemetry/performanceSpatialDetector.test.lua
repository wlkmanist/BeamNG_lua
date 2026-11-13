-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("performanceSpatialDetector")

local M = {}
local Detector = require("ge/extensions/telemetry/performanceSpatialDetector")

local function newDetector(overrides)
  local config = {
    dipFpsThreshold = 30,
    dipFrameTimeRatio = 2,
    dipMinDurationMs = 250,
    dipCooldownSeconds = 0,
    maxDipEventsPerSession = 100,
  }
  for key, value in pairs(overrides or {}) do config[key] = value end
  return Detector.new(config)
end

local function seed(detector, frameMs)
  detector:update(0, 1000 / frameMs, frameMs)
end

function M.testAbsoluteDip(ctx)
  local detector = newDetector({dipFrameTimeRatio = 3})
  seed(detector, 25)

  detector:update(100, 25, 40)
  detector:update(350, 25, 40)
  local _, event = detector:update(400, 40, 25)

  ctx:assert(event ~= nil, "sustained absolute dip must emit on recovery")
  ctx:assertEqual(event.trigger, "absolute")
end

function M.testRelativeDip(ctx)
  local detector = newDetector()
  seed(detector, 10)

  detector:update(100, 50, 20)
  detector:update(350, 50, 20)
  local _, event = detector:update(400, 100, 10)

  ctx:assert(event ~= nil, "sustained relative dip must emit on recovery")
  ctx:assertEqual(event.trigger, "relative")
end

function M.testDipMustBeSustained(ctx)
  local detector = newDetector()
  seed(detector, 10)

  detector:update(100, 50, 20)
  local _, event = detector:update(349, 100, 10)

  ctx:assert(event == nil, "a dip shorter than the minimum must not emit")
  detector:update(500, 50, 20)
  detector:update(750, 50, 20)
  _, event = detector:update(800, 100, 10)
  ctx:assert(event ~= nil, "a dip lasting the minimum must emit")
end

function M.testRecoveryWithoutObservedDurationDoesNotEmit(ctx)
  local detector = newDetector()
  seed(detector, 10)

  detector:update(100, 50, 20)
  local _, event = detector:update(350, 100, 10)

  ctx:assert(event == nil, "one sampled hitch must not imply a sustained dip")
end

function M.testRecoveryEmitsWorstFrameOnce(ctx)
  local detector = newDetector()
  seed(detector, 10)

  local capture = detector:update(100, 50, 20)
  ctx:assert(capture == true, "first dip frame must be captured")
  capture = detector:update(230, 40, 25)
  ctx:assert(capture == true, "worse dip frame must replace the capture")
  detector:update(360, 50, 20)

  local _, event = detector:update(500, 100, 10)
  ctx:assert(event ~= nil, "recovery must emit the dip")
  ctx:assertEqual(event.durationMs, 260)
  ctx:assertEqual(event.worstAgoMs, 270)
  ctx:assertNear(event.baselineFrameMs, 10, 0.001)
  ctx:assertEqual(event.trigger, "relative")
  ctx:assertEqual(event.dipFpsThreshold, 30)
  ctx:assertEqual(event.dipFrameTimeRatio, 2)
  ctx:assertEqual(event.dipMinDurationMs, 250)

  _, event = detector:update(600, 100, 10)
  ctx:assert(event == nil, "recovery must emit only once")
end

function M.testIntentionalCapDisablesAbsoluteTrigger(ctx)
  local detector = newDetector({dipFrameTimeRatio = 3})
  seed(detector, 25)

  local capture, event = detector:update(100, 20, 50, false)

  ctx:assert(capture == false, "a capped frame must not start an absolute dip")
  ctx:assert(event == nil, "a capped frame must not emit a dip")
end

function M.testOpenSustainedDipCanBeFinished(ctx)
  local detector = newDetector()
  seed(detector, 10)

  detector:update(100, 50, 20)
  detector:update(350, 50, 20)
  local event = detector:finish(400)

  ctx:assert(event ~= nil, "a sustained open dip must finish on context exit")
  ctx:assertEqual(event.durationMs, 250)
end

function M.testLongDipIsSegmented(ctx)
  local detector = newDetector()
  seed(detector, 10)

  detector:update(100, 50, 20)
  local _, event = detector:update(1800100, 50, 20)

  ctx:assert(event ~= nil, "a long dip must emit before migration bounds")
  ctx:assertEqual(event.durationMs, 1800000)
end

function M.testCooldownSuppressesDip(ctx)
  local detector = newDetector({dipCooldownSeconds = 1})
  seed(detector, 25)

  detector:update(100, 20, 50)
  detector:update(350, 20, 50)
  local _, first = detector:update(400, 40, 25)
  ctx:assert(first ~= nil, "first dip must emit")
  ctx:assertEqual(first.trigger, "both")

  detector:update(500, 20, 50)
  detector:update(800, 20, 50)
  local _, suppressed = detector:update(900, 40, 25)
  ctx:assert(suppressed == nil, "dip inside cooldown must not emit")

  detector:update(1400, 20, 50)
  detector:update(1650, 20, 50)
  local _, second = detector:update(1700, 40, 25)
  ctx:assert(second ~= nil, "dip after cooldown must emit")
end

function M.testSessionCapSuppressesDip(ctx)
  local detector = newDetector({maxDipEventsPerSession = 1})
  seed(detector, 25)

  detector:update(100, 20, 50)
  detector:update(350, 20, 50)
  local _, first = detector:update(400, 40, 25)
  ctx:assert(first ~= nil, "first dip must emit")

  detector:update(500, 20, 50)
  detector:update(750, 20, 50)
  local _, second = detector:update(800, 40, 25)
  ctx:assert(second == nil, "dip over the session cap must not emit")
end

return M
