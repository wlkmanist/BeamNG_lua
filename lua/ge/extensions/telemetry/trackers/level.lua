-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY LEVEL TRACKER

  Tracks which levels are played and for how long, plus the scenario lifecycle.

  How long the level took to load rides along on the end of the levelLoaded activity. The
  load is only finished well after the activity opened, so it cannot go on the start of it.

  The per frame collision and damage tracking that used to live here was removed:
  it produced far too many events to be useful.
]]

local M = {}
M.dependencies = {'telemetry_core'}

-- Set while a level or scenario is running, so it can be closed on level change
local activeLevel = nil
local activeScenario = nil

-- When the load started, and how long it took once the world says it is playable
local loadStartedAt = nil
local loadMs = nil

local function endScenario(result)
  if not activeScenario then return end

  extensions.telemetry_core.endActivity("scenarioRunning", {
    scenarioName = activeScenario.scenarioName,
    file = activeScenario.file,
    result = result,
  })
  activeScenario = nil
end

local function endLevel()
  endScenario("aborted")

  if not activeLevel then return end
  extensions.telemetry_core.endActivity("levelLoaded", {
    levelName = activeLevel.levelName,
    loadMs = loadMs,
  })
  activeLevel = nil
  loadMs = nil

  -- leaving a level is a good checkpoint, a later crash cannot lose what we have so far
  extensions.telemetry_core.triggerReportWrite()
end

-- The top of the load pipeline, before the datablocks, the objects and the physics. Fires on
-- every load, restarts included. Entering a level the game is already in skips it, and that
-- level is then reported without a load time rather than with the previous one.
local function onClientPreStartMission(levelPath)
  loadStartedAt = os.clockhp()
  loadMs = nil
end

local function onClientStartMission(levelPath)
  activeLevel = {levelName = levelPath}
  loadMs = nil
  extensions.telemetry_core.startActivity("levelLoaded", activeLevel)
end

--[[
  State 2 is the first moment the player can drive: the camera has its control object and the
  player vehicle reports its render materials ready. That is later than onClientStartMission,
  which still runs with the loading screen up.

  Two things to know about the number. The material wait inside state 2 gives up after five
  seconds, so a very slow load reports the point it gave up rather than the point it finished.
  And a level with no player vehicle reaches state 2 immediately, so it looks quick.
]]
local function onWorldReadyState(state)
  if state ~= 2 or not loadStartedAt then return end

  loadMs = math.floor((os.clockhp() - loadStartedAt) * 1000 + 0.5)
  loadStartedAt = nil
end

local function onClientEndMission(levelPath)
  endLevel()
end

local function onScenarioLoaded(scenario)
  activeScenario = {scenarioName = scenario.name, file = scenario.sourceFile}
  extensions.telemetry_core.startActivity("scenarioRunning", activeScenario)
end

local function onScenarioFinished(scenario)
  local failed = scenario.pooledResults[1] and scenario.pooledResults[1].failed
  endScenario(failed and "failed" or "success")
end

local function onScenarioRestarted(scenario)
  endScenario("restarted")
  onScenarioLoaded(scenario)
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")

  -- a lua reload starts a new session in the middle of a level, and onClientStartMission
  -- will not fire again, so reopen the activity here. It carries no load time, this
  -- session did not see the load.
  local levelPath = getMissionFilename()
  if levelPath and levelPath ~= "" then onClientStartMission(levelPath) end
end

-- close the open activities so the session file is not left with dangling starts
local function onExit()
  endLevel()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExit = onExit
-- a lua reload tears the trackers down without an onExit, so close the activities here too
M.onExtensionUnloaded = endLevel

M.onClientPreStartMission = onClientPreStartMission
M.onClientStartMission = onClientStartMission
M.onWorldReadyState = onWorldReadyState
M.onClientEndMission = onClientEndMission
M.onScenarioLoaded = onScenarioLoaded
-- flowgraph scenarios never reach scenario_scenarios, so onScenarioLoaded does not fire
-- for them. They carry no finish signal either, so endLevel closes them as aborted.
M.onFlowgraphScenarioStarted = onScenarioLoaded
M.onScenarioFinished = onScenarioFinished
M.onScenarioRestarted = onScenarioRestarted

return M
