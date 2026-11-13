-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Run with:
-- extensions.testFramework_TestManager:runTestFiles("performanceSpatialGameplayExit")

local M = {}
local gameplayExit = require("ge/extensions/telemetry/performanceSpatialGameplayExit")

local function assertActivity(ctx, actual, expected)
  ctx:assert(actual ~= nil, "activity must resolve")
  ctx:assertEqual(actual.activityType, expected.activityType)
  ctx:assertEqual(actual.activityId, expected.activityId)
end

local function vehicle(position)
  return {
    getPosition = function()
      return {x = position.x, y = position.y, z = position.z}
    end,
  }
end

local function sources(overrides)
  local result = {
    getCurrentLevelIdentifier = function() return "italy" end,
    be = {
      getPlayerVehicle = function() return vehicle({x = 1.24, y = -2.26, z = 3.01}) end,
    },
    core_camera = {
      getPositionXYZ = function() return 10.04, 20.06, 30.01 end,
    },
  }
  for key, value in pairs(overrides or {}) do result[key] = value end
  return result
end

function M.testMissionTakesPrecedence(ctx)
  local source = sources({
    gameplay_missions_missionManager = {
      getForegroundMissionId = function() return "italy/timeTrial/001" end,
    },
    gameplay_drag_core = {
      getDragIsStarted = function() return true end,
      getGameplayContext = function() return "freeroam" end,
      getData = function() return {_fnWithoutExt = "drag"} end,
      getPoiKey = function() return "italy:drag" end,
    },
  })

  assertActivity(ctx, gameplayExit.resolveActivity(source), {
    activityType = "mission",
    activityId = "italy/timeTrial/001",
  })
end

function M.testAttemptBasedActivityFamilies(ctx)
  local cases = {
    {
      expected = {activityType = "scenario", activityId = "quickRace/test"},
      source = {
        scenario_scenarios = {
          getScenario = function()
            return {state = "running", sourceFile = "quickRace/test"}
          end,
        },
      },
    },
    {
      expected = {activityType = "freeformDelivery", activityId = "/gameplay/delivery/test"},
      source = {
        gameplay_freeformDelivery_freeformDelivery = {
          isActive = function() return true end,
          getCurrentDelivery = function()
            return {_basePath = "/gameplay/delivery/test"}
          end,
        },
      },
    },
    {
      expected = {activityType = "careerDelivery"},
      source = {
        career_modules_delivery_general = {
          isDeliveryModeActive = function() return true end,
        },
      },
    },
    {
      expected = {activityType = "testDrive"},
      source = {
        career_modules_testDrive = {isActive = function() return true end},
      },
    },
    {
      expected = {activityType = "vehicleCertification"},
      source = {
        career_modules_vehiclePerformance = {
          isTestInProgress = function() return true end,
        },
      },
    },
    {
      expected = {activityType = "freeroamDrag", activityId = "italy:strip"},
      source = {
        gameplay_drag_core = {
          getDragIsStarted = function() return true end,
          getGameplayContext = function() return "freeroam" end,
          getData = function() return {strip = {}} end,
          getPoiKey = function() return "italy:strip" end,
        },
      },
    },
    {
      expected = {activityType = "freeroamDrift"},
      source = {
        gameplay_drift_freeroam_driftSpots = {
          getIsInFreeroamChallenge = function() return true end,
        },
      },
    },
    {
      expected = {activityType = "freeroamCrawl", activityId = "/levels/utah/crawls/test"},
      source = {
        gameplay_crawl_general = {
          activeTrail = {
            isFromMission = false,
            trail = {_filePath = "/levels/utah/crawls/test"},
          },
        },
        gameplay_crawl_utils = {
          getActiveCrawlerId = function() return 123 end,
        },
      },
    },
  }

  for _, case in ipairs(cases) do
    assertActivity(
      ctx,
      gameplayExit.resolveActivity(sources(case.source)),
      case.expected)
  end
end

function M.testCaptureUsesVehicleThenCamera(ctx)
  local event = gameplayExit.capture(
    "worldExit", {activityType = "testDrive"}, nil, sources())

  ctx:assertEqual(event.position.x, 1.2)
  ctx:assertEqual(event.position.y, -2.3)
  ctx:assertEqual(event.position.z, 3)
  ctx:assertEqual(event.positionSource, "vehicle")

  local source = sources({
    be = {getPlayerVehicle = function() return nil end},
  })
  event = gameplayExit.capture("gameExit", {activityType = "testDrive"}, nil, source)
  ctx:assertEqual(event.position.x, 10)
  ctx:assertEqual(event.position.y, 20.1)
  ctx:assertEqual(event.position.z, 30)
  ctx:assertEqual(event.positionSource, "camera")
end

function M.testCaptureValidatesContextAndLevel(ctx)
  local event = gameplayExit.capture("abort", {
    activityType = "careerDelivery",
    activityId = 123,
  }, {italy = true}, sources())

  ctx:assertEqual(event.name, "gameplayActivityExit")
  ctx:assertEqual(event.activityId, "123")
  ctx:assertEqual(event.exitKind, "abort")
  event = gameplayExit.capture("abort", {
    activityType = "mission",
    activityId = "mission@night",
  }, nil, sources())
  ctx:assert(event ~= nil, "invalid ids must not discard the exit")
  ctx:assert(event.activityId == nil, "invalid ids must be omitted")
  ctx:assert(gameplayExit.capture(
    "failure", {activityType = "mission"}, nil, sources()) == nil)
  ctx:assert(gameplayExit.capture(
    "abort", {activityType = "unknown"}, nil, sources()) == nil)
  ctx:assert(gameplayExit.capture(
    "abort", {activityType = "mission"}, {utah = true}, sources()) == nil)
end

function M.testCompletedScenarioIsNotActive(ctx)
  local source = sources({
    scenario_scenarios = {
      getScenario = function()
        return {state = "post", sourceFile = "quickRace/test"}
      end,
    },
  })

  ctx:assert(gameplayExit.resolveActivity(source) == nil)
end

function M.testConcludingDriftIsNotActive(ctx)
  local source = sources({
    gameplay_drift_freeroam_driftSpots = {
      getIsInFreeroamChallenge = function() return true end,
      getIsInTheConcludingPhase = function() return true end,
    },
  })

  ctx:assert(gameplayExit.resolveActivity(source) == nil)
end

function M.testCompletedDragIsNotActive(ctx)
  local source = sources({
    gameplay_drag_core = {
      getDragIsStarted = function() return true end,
      getGameplayContext = function() return "freeroam" end,
      getData = function() return {isCompleted = true, strip = {}} end,
      getPoiKey = function() return "italy:strip" end,
    },
  })

  ctx:assert(gameplayExit.resolveActivity(source) == nil)
end

function M.testDragUsesTopLevelDataAndCurrentLevel(ctx)
  local dragData = {_fnWithoutExt = "strip", strip = {}}
  local source = sources({
    gameplay_drag_core = {
      getDragIsStarted = function() return true end,
      getGameplayContext = function() return "freeroam" end,
      getData = function() return dragData end,
      getPoiKey = function(data)
        ctx:assert(data == dragData, "drag key must use top-level drag data")
        return ":" .. data._fnWithoutExt
      end,
    },
  })

  assertActivity(ctx, gameplayExit.resolveActivity(source), {
    activityType = "freeroamDrag",
    activityId = "italy:strip",
  })
end

function M.testActiveAttemptTakesPrecedenceOverCareerDelivery(ctx)
  local attempts = {
    {
      expected = {activityType = "freeroamDrag", activityId = "italy:strip"},
      source = {
        gameplay_drag_core = {
          getDragIsStarted = function() return true end,
          getGameplayContext = function() return "freeroam" end,
          getData = function() return {_fnWithoutExt = "strip"} end,
          getPoiKey = function(data) return ":" .. data._fnWithoutExt end,
        },
      },
    },
    {
      expected = {activityType = "freeroamDrift"},
      source = {
        gameplay_drift_freeroam_driftSpots = {
          getIsInFreeroamChallenge = function() return true end,
          getIsInTheConcludingPhase = function() return false end,
        },
      },
    },
    {
      expected = {activityType = "freeroamCrawl", activityId = "crawl-trail"},
      source = {
        gameplay_crawl_general = {
          activeTrail = {
            isFromMission = false,
            trail = {id = "crawl-trail"},
          },
        },
        gameplay_crawl_utils = {
          getActiveCrawlerId = function() return 123 end,
        },
      },
    },
  }

  for _, case in ipairs(attempts) do
    case.source.career_modules_delivery_general = {
      isDeliveryModeActive = function() return true end,
    }
    assertActivity(
      ctx,
      gameplayExit.resolveActivity(sources(case.source)),
      case.expected)
  end
end

function M.testCompletedCrawlIsNotActive(ctx)
  local source = sources({
    gameplay_crawl_general = {
      activeTrail = {
        isFromMission = false,
        trail = {_filePath = "/levels/utah/crawls/test"},
      },
    },
    gameplay_crawl_utils = {
      getActiveCrawlerId = function() return 123 end,
      getCrawlState = function() return {isCompleted = true} end,
    },
  })

  ctx:assert(gameplayExit.resolveActivity(source) == nil)
end

return M
