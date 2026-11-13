-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY MISSION TRACKER

  Tracks the mission funnel: which missions are started, how they are configured,
  and how they end. The missionRunning activity carries the duration.

  Note: do not put a 'name' key into the activity data, it would replace the
  activity name and the start and end events could no longer be paired.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local missionData

-- Fires once the mission is actually running, for every start path including the ones that
-- load a level first. startedFrom is missionScreen (in level), gameplaySelector, discover or
-- withinMission (retry, next mission or reconfigure from the end screen). Starts from career
-- tutorials, activity flows, multiplayer or scenarios report other.
local function onAnyMissionChanged(state, mission, userSettings, startedFrom)
  if state ~= "started" or not mission then return end
  -- also fires when onStart failed, that mission is never stopped
  if not mission._isOngoing then return end

  extensions.telemetry_core.startActivity("missionRunning", {
    missionId = mission.id,
    author = mission.author,
    userSettings = userSettings,
    startedFrom = startedFrom or "other",
  })

  missionData = {
    missionId = mission.id,
    firstStartScreenDone = false,
    attemptsCompleted = 0,
  }
end

local function endMission(outcome)
  if not missionData then return end
  local missionId = missionData.missionId
  missionData = nil

  extensions.telemetry_core.endActivity("missionRunning", {
    missionId = missionId,
    outcome = outcome,
  })
end

-- The start and end screen nodes are also used outside missions, split screen gamemodes
-- for example, so both events are only counted while a mission runs
local function onUIStartButtonClicked()
  if not missionData then return end
  extensions.telemetry_core.addEvent({
    name = "missionStartButtonClicked",
    missionId = missionData.missionId,
  })
end

-- Counterpart of missionStartScreenOpened. Carries no result: the screen is told what to
-- show from elsewhere, and a mission built on the endScreenWhole node never fires this at
-- all. The results come from onMissionAttemptAggregated below.
local function onEndScreenUIOpened()
  if not missionData then return end
  extensions.telemetry_core.addEvent({
    name = "missionEndScreenOpened",
    missionId = missionData.missionId,
  })
end

-- A mission spawned vehicle if there is one, otherwise the car the player arrived in
local function getMissionVehicle(mission)
  local setup = mission.setupModules and mission.setupModules.vehicles
  local vid = (setup and setup.enabled and setup.vehId)
    or (mission._startingInfo and mission._startingInfo.vehId)
  if not vid then return nil end

  return extensions.telemetry_vehicleInfo.getData(vid)
end

-- Fires as the attempt is saved, the one point where the whole result exists as a single
-- table. Which of the data fields are filled depends on the mission type.
local function onMissionAttemptAggregated(attempt, mission, progressKey)
  local data = attempt.data or {}
  local vehicle = getMissionVehicle(mission)
  if missionData then
    missionData.attemptsCompleted = missionData.attemptsCompleted + 1
  end

  extensions.telemetry_core.addEvent({
    name = "missionAttemptCompleted",
    missionId = mission.id,
    progressKey = progressKey,
    -- completed, passed, attempted, failed or none, derived from the stars
    outcome = attempt.type,
    attemptNumber = attempt.attemptNumber,
    stars = attempt.unlockedStars,
    elapsed = data.time or data.totalTime, -- seconds
    penalty = data.penalty,                -- seconds
    points = data.points or data.pointsAchieved,
    model = vehicle and vehicle.model,
    config = vehicle and vehicle.config,
  })
end

local function onStartScreenFinishedBuilding()
  if not missionData then return end -- Guard against running flowgraph without mission context
  if not missionData.firstStartScreenDone then
    missionData.firstStartScreenDone = true

    extensions.telemetry_core.addEvent({
      name = "missionStartScreenOpened",
    })
  end
end

local function onRecoveryPromptButtonPressed(id)
  if id == "restartMission" then
    extensions.telemetry_core.addEvent({
      name = "missionRestarted",
      missionId = gameplay_missions_missionManager.getForegroundMissionId()
    })
  end
end

local function onMissionReconfigured(data)
  local changedSettings = {}
  for key, value in pairs(data.newUserSettings) do
    if data.oldUserSettings[key] ~= value then
      changedSettings[key] = value
    end
  end
  extensions.telemetry_core.addEvent({
    name = "missionReconfigured",
    missionId = data.mission.id,
    changedSettings = changedSettings,
  })
end

-- Fires when the mission is closed early, before it would stop on its own. attemptsCompleted
-- is 0 when the player left without finishing a single attempt. byPlayer is false when the
-- game closed the mission itself, for example after a failed vehicle spawn.
-- Missions that handle the abandon themselves still stop afterwards, the activity is already
-- closed by then.
local function onMissionAbandoned(mission, byPlayer)
  if not missionData or missionData.missionId ~= mission.id then return end

  extensions.telemetry_core.addEvent({
    name = "missionAbandoned",
    missionId = mission.id,
    byPlayer = byPlayer == true,
    attemptsCompleted = missionData.attemptsCompleted,
  })
  endMission("abandoned")
end

-- Every stop passes through here, including the instant one on a level change, a return to
-- the main menu or a career start, which skips onMissionStopped
local function onAnyMissionWillChange(state, mission)
  if state ~= "stopped" or not mission then return end
  if not missionData or missionData.missionId ~= mission.id then return end
  endMission("stopped")
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
-- game exit, a lua reload and disabling the tracker all unload it, the core unloads the
-- trackers before their onExit would run
M.onExtensionUnloaded = function() endMission("trackerUnloaded") end

M.onUIStartButtonClicked = onUIStartButtonClicked
M.onEndScreenUIOpened = onEndScreenUIOpened
M.onMissionAttemptAggregated = onMissionAttemptAggregated
M.onStartScreenFinishedBuilding = onStartScreenFinishedBuilding
M.onRecoveryPromptButtonPressed = onRecoveryPromptButtonPressed
M.onMissionReconfigured = onMissionReconfigured

M.onMissionAbandoned = onMissionAbandoned
M.onAnyMissionWillChange = onAnyMissionWillChange
M.onAnyMissionChanged = onAnyMissionChanged

return M
