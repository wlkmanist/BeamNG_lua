-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("performanceSpatialConfig")

local M = {}
local spatialConfig = require("ge/extensions/telemetry/performanceSpatialConfig")

function M.testAdvancedCollectionDefaultsOff(ctx)
  local config = spatialConfig.read({})

  ctx:assertEqual(config.sampleIntervalSeconds, 0)
  ctx:assert(config.dipTrackingEnabled == false, "dip tracking must default off")
  ctx:assert(config.recoveryTrackingEnabled == false, "recovery tracking must default off")
  ctx:assert(config.gameplayExitTrackingEnabled == false,
    "gameplay exit tracking must default off")
  ctx:assert(config.shaderGenerationTrackingEnabled == false,
    "shader generation tracking must default off")
  ctx:assert(config.sceneComplexityTrackingEnabled == false,
    "scene complexity tracking must default off")
  ctx:assert(config.renderTimingTrackingEnabled == false,
    "render timing tracking must default off")
  ctx:assert(config.detector == nil, "an off tracker must not create a detector")
end

function M.testRecoveryTrackingIsExplicit(ctx)
  local config = spatialConfig.read({recoveryTrackingEnabled = true})

  ctx:assert(config.recoveryTrackingEnabled == true, "recovery tracking must be enabled")
end

function M.testGameplayExitTrackingIsExplicit(ctx)
  local config = spatialConfig.read({gameplayExitTrackingEnabled = true})

  ctx:assert(config.gameplayExitTrackingEnabled == true,
    "gameplay exit tracking must be enabled")
end

function M.testShaderGenerationTrackingIsExplicit(ctx)
  local config = spatialConfig.read({shaderGenerationTrackingEnabled = true})

  ctx:assert(config.shaderGenerationTrackingEnabled == true,
    "shader generation tracking must be enabled")
end

function M.testDetailedMetricsAreExplicit(ctx)
  local config = spatialConfig.read({
    sceneComplexityTrackingEnabled = true,
    renderTimingTrackingEnabled = true,
  })

  ctx:assert(config.sceneComplexityTrackingEnabled == true,
    "scene complexity tracking must be enabled")
  ctx:assert(config.renderTimingTrackingEnabled == true,
    "render timing tracking must be enabled")
end

function M.testLevelFilterBecomesLookup(ctx)
  local config = spatialConfig.read({
    spatialSampleIntervalSeconds = 30,
    levels = {"italy", "Utah"},
  })

  ctx:assert(config.levels.italy == true, "italy must be allowed")
  ctx:assert(config.levels.Utah == true, "Utah must be allowed")
  ctx:assert(config.levels.gridmap_v2 == nil, "unlisted levels must be rejected")
end

function M.testDipSettingsAreClamped(ctx)
  local config = spatialConfig.read({
    dipTrackingEnabled = true,
    dipFpsThreshold = 1000,
    dipFrameTimeRatio = 1,
    dipMinDurationMs = 1,
    dipCooldownSeconds = -1,
    maxDipEventsPerSession = 5000,
  })

  ctx:assertEqual(config.detector.dipFpsThreshold, 360)
  ctx:assertEqual(config.detector.dipFrameTimeRatio, 1.1)
  ctx:assertEqual(config.detector.dipMinDurationMs, 50)
  ctx:assertEqual(config.detector.dipCooldownSeconds, 0)
  ctx:assertEqual(config.detector.maxDipEventsPerSession, 1000)
end

return M
