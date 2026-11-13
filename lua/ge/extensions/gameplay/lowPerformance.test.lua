-- Run with require('testFramework/TestManager'):runTestFiles('gameplay/lowPerformance')
local M = {}

local function runtime(mode)
  local state = {mode = mode or "freeroam", route = "play", fps = 60, triggers = {}, settings = {}, simpleMenu = false}
  local environment = setmetatable({
    require = function() return {getContext = function() return {mode = state.mode} end} end,
    getCurrentLevelIdentifier = function() return "test_level" end,
    render_openxr = false,
    settings = {
      getValue = function(key) return state.settings[key] end,
      setValue = function(key, value) state.settings[key] = value end,
    },
    simTimeAuthority = {getPause = function() return false end},
    Engine = {
      isProgramFocused = function() return true end,
      UI = {isSimpleMenu = function() return state.simpleMenu end},
    },
    editor = {isEditorActive = function() return false end},
    ui_router = {getCurrent = function() return {request = {name = state.route}} end},
    VariableRegistry = {get = function() return state.fps end},
    guihooks = {trigger = function(name, data)
      table.insert(state.triggers, name)
      state.lastData = data
    end},
    log = nop,
  }, {__index = _G})
  local chunk, err = loadfile('/lua/ge/extensions/gameplay/lowPerformance.lua')
  assert(chunk, err)
  setfenv(chunk, environment)
  return chunk(), state
end

local function runFrames(detector, state, fps, seconds)
  state.fps = fps
  local dt = 1 / fps
  for _ = 1, math.floor(seconds * fps) do detector.onUpdate(dt, dt, dt) end
end

local function countTriggers(state, name)
  local count = 0
  for _, triggered in ipairs(state.triggers) do
    if triggered == name then count = count + 1 end
  end
  return count
end

function M.testSustainedLowFpsEntersAndRecovers(ctx)
  local detector, state = runtime()
  runFrames(detector, state, 20, 12)
  ctx:assert(detector.isLowPerformance())
  ctx:assertEqual(countTriggers(state, "toastrMsg"), 1)
  runFrames(detector, state, 60, 15)
  ctx:assert(not detector.isLowPerformance())
end

function M.testDipShorterThanDwellDoesNotTrigger(ctx)
  local detector, state = runtime()
  runFrames(detector, state, 60, 10)
  -- the average stays under 25 for about 3 s, less than the 5 s dwell
  runFrames(detector, state, 5, 7)
  runFrames(detector, state, 60, 10)
  ctx:assert(not detector.isLowPerformance())
  ctx:assertEqual(countTriggers(state, "toastrMsg"), 0)

  runFrames(detector, state, 5, 12)
  ctx:assert(detector.isLowPerformance())
end

function M.testSkippedFramesRestartGrace(ctx)
  local detector, state = runtime()
  state.route = "pause"
  runFrames(detector, state, 10, 30)
  ctx:assert(not detector.isLowPerformance())

  state.route = "play"
  runFrames(detector, state, 10, 8)
  ctx:assert(not detector.isLowPerformance())
  detector.onVehicleSpawned()
  runFrames(detector, state, 10, 8)
  ctx:assert(not detector.isLowPerformance())

  detector.onScreenFadeState(1)
  runFrames(detector, state, 10, 30)
  ctx:assert(not detector.isLowPerformance())
  detector.onScreenFadeState(3)
  runFrames(detector, state, 10, 11)
  ctx:assert(detector.isLowPerformance())
end

function M.testCuratedContentIsNeverChecked(ctx)
  local detector, state = runtime("mission")
  runFrames(detector, state, 10, 30)
  ctx:assertEqual(#state.triggers, 0)

  state.mode = "freeroam"
  runFrames(detector, state, 20, 12)
  ctx:assert(detector.isLowPerformance())
  state.mode = "mission"
  ctx:assert(not detector.isLowPerformance())
  ctx:assertEqual(detector.getPauseNotice(), nil)
  runFrames(detector, state, 20, 2)
  state.mode = "freeroam"
  ctx:assert(not detector.isLowPerformance())
end

function M.testSpawnWarningOncePerEpisode(ctx)
  local detector, state = runtime()
  local spawned = 0
  local spawn = function() spawned = spawned + 1 end

  ctx:assertEqual(detector.confirmSpawn(spawn), nil)
  ctx:assertEqual(spawned, 1)

  runFrames(detector, state, 20, 12)
  ctx:assertEqual(detector.confirmSpawn(spawn), false)
  ctx:assertEqual(spawned, 1)
  detector.confirmPendingSpawn()
  ctx:assertEqual(spawned, 2)
  detector.confirmSpawn(spawn)
  ctx:assertEqual(spawned, 3)

  runFrames(detector, state, 60, 15)
  runFrames(detector, state, 20, 20)
  detector.confirmSpawn(spawn)
  detector.cancelPendingSpawn()
  ctx:assertEqual(spawned, 3)
  ctx:assertEqual(countTriggers(state, "showConfirmationDialog"), 2)
end

function M.testNotificationsCanBeMuted(ctx)
  local detector, state = runtime()
  local spawned = 0
  local spawn = function() spawned = spawned + 1 end

  runFrames(detector, state, 20, 12)
  ctx:assertEqual(detector.confirmSpawn(spawn), false)
  ctx:assertEqual(#state.lastData.buttons, 3)
  detector.muteAndConfirmPendingSpawn()
  ctx:assertEqual(spawned, 1)
  ctx:assertEqual(state.settings.notifyLowPerformance, false)

  -- detection keeps running while muted, it just shows nothing
  runFrames(detector, state, 60, 15)
  runFrames(detector, state, 20, 20)
  ctx:assert(detector.isLowPerformance())
  ctx:assertEqual(detector.getPauseNotice(), nil)
  ctx:assertEqual(detector.confirmSpawn(spawn), nil)
  ctx:assertEqual(spawned, 2)
  ctx:assertEqual(countTriggers(state, "toastrMsg"), 2)

  state.simpleMenu = true
  ctx:assert(detector.getPauseNotice() ~= nil)
  runFrames(detector, state, 60, 15)
  runFrames(detector, state, 20, 20)
  ctx:assertEqual(detector.confirmSpawn(spawn), false)
  ctx:assertEqual(#state.lastData.buttons, 2)
end

return M
