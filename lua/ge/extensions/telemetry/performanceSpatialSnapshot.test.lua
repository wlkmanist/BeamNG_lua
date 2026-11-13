-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("performanceSpatialSnapshot")

local M = {}
local snapshot = require("ge/extensions/telemetry/performanceSpatialSnapshot")

local function capture(options)
  return snapshot.capture("italy", 60, 16.67, nil, options)
end

function M.testDetailedMetricsDefaultOff(ctx)
  local event = capture()

  ctx:assert(event.framePhases == nil, "frame phases must be opt-in")
  ctx:assert(event.renderStats == nil, "scene complexity must be opt-in")
end

function M.testRenderTimingCanBeEnabledAlone(ctx)
  local event = capture({renderTimingTrackingEnabled = true})

  ctx:assert(event.framePhases ~= nil, "frame phases must be captured")
  ctx:assert(event.renderStats == nil, "scene complexity must stay off")
end

function M.testSceneComplexityCanBeEnabledAlone(ctx)
  local event = capture({sceneComplexityTrackingEnabled = true})

  ctx:assert(event.framePhases == nil, "frame phases must stay off")
  ctx:assert(event.renderStats ~= nil, "scene complexity must be captured")
  ctx:assert(type(event.renderStats.visibleObjectCount) == "number",
    "the renderer's visible-object count must be captured")
end

return M
