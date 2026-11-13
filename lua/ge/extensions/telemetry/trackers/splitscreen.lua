-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY SPLIT SCREEN TRACKER

  Tracks split-screen sessions, how long each configuration is used, and the multiseat
  gamemodes played in them.

  splitScreenStarted and splitScreenStopped bracket a session within one level.
  splitScreenActive restarts whenever the player count, layout or mode changes.
]]

local M = {}
M.dependencies = {'telemetry_core'}

-- A start request is matched to the split screen start that follows it, which can be a
-- whole level load later. An older request belongs to a start that failed.
local requestTimeout = 300

local activityData = nil
local session = nil
local pendingRequest = nil
local gamemode = nil

local function endActivity()
  if not activityData then return end
  extensions.telemetry_core.endActivity("splitScreenActive", activityData)
  activityData = nil
end

local function startActivity(playerCount, layout, mode)
  local level = getCurrentLevelIdentifier() or "unknown"
  if activityData
    and activityData.playerCount == playerCount
    and activityData.layout == layout
    and activityData.mode == mode
    and activityData.level == level then
    return
  end

  endActivity()
  activityData = {
    playerCount = playerCount,
    layout = layout,
    mode = mode,
    level = level,
  }
  extensions.telemetry_core.startActivity("splitScreenActive", activityData)
end

-- entry is discover or multiseatSettings, activity is the gamemode id or freeroam
local function onSplitScreenStartRequested(entry, activity)
  pendingRequest = {
    entry = entry,
    activity = activity,
    fromMainMenu = getMissionFilename() == "",
    requestedAt = os.clockhp(),
  }
end

local function takeRequest()
  local request = pendingRequest
  pendingRequest = nil
  if request and os.clockhp() - request.requestedAt > requestTimeout then return nil end
  return request
end

-- Without a request, e.g. after a level change or a lua reload, the entry fields stay empty
local function startSession(playerCount, mode)
  local request = takeRequest()
  session = {startedAt = os.clockhp(), peakPlayerCount = playerCount}
  extensions.telemetry_core.addEvent({
    name = "splitScreenStarted",
    playerCount = playerCount,
    mode = mode,
    level = getCurrentLevelIdentifier() or "unknown",
    entry = request and request.entry,
    activity = request and request.activity,
    fromMainMenu = request and request.fromMainMenu,
  })
end

local function endSession(reason)
  if not session then return end
  extensions.telemetry_core.addEvent({
    name = "splitScreenStopped",
    reason = reason,
    duration = os.clockhp() - session.startedAt,
    peakPlayerCount = session.peakPlayerCount,
  })
  session = nil
end

local function onSplitScreenChanged(enabled, playerCount, layout, mode)
  if not enabled then
    endActivity()
    endSession("disabled")
    return
  end
  if session then
    session.peakPlayerCount = math.max(session.peakPlayerCount, playerCount)
  else
    startSession(playerCount, mode)
  end
  startActivity(playerCount, layout, mode)
end

local function endGamemode(reason)
  if not gamemode then return end
  extensions.telemetry_core.endActivity("splitScreenGamemode", {
    gamemodeId = gamemode.gamemodeId,
    reason = reason,
    finished = gamemode.finished,
  })
  gamemode = nil
end

-- Fires for every round, a restart from the end screen or the pause menu included
local function onMultiseatGamemodeLaunched(gamemodeId)
  endGamemode(gamemode and gamemode.gamemodeId == gamemodeId and "restarted" or "switched")
  gamemode = {gamemodeId = gamemodeId, finished = false}
  extensions.telemetry_core.startActivity("splitScreenGamemode", {
    gamemodeId = gamemodeId,
    playerCount = core_multiseat and #core_multiseat.getJoinedPlayers() or nil,
    level = getCurrentLevelIdentifier() or "unknown",
  })
end

-- The end screen of a round. Player indices are not reported, only the kind of result.
local function onMultiseatGamemodeFinished(gamemodeId, result)
  if gamemode then gamemode.finished = true end
  extensions.telemetry_core.addEvent({
    name = "splitScreenGamemodeFinished",
    gamemodeId = gamemodeId,
    tied = type(result) == "table" and result.tied == true,
    hasWinner = type(result) == "table" and result.winnerPlayer ~= nil,
  })
end

local function onMultiseatGamemodeStopped()
  endGamemode("stopped")
end

local function syncState()
  if not extensions.isExtensionLoaded("render_splitScreen") then return end
  onSplitScreenChanged(render_splitScreen.getCurrentConfiguration())
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
  syncState()
end

local function onClientStartMission()
  syncState()
end

local function onClientEndMission()
  endGamemode("levelEnded")
  endActivity()
  endSession("levelEnded")
end

local function closeAll()
  endGamemode("gameExit")
  endActivity()
  endSession("gameExit")
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = closeAll
M.onExit = closeAll
M.onClientStartMission = onClientStartMission
M.onClientEndMission = onClientEndMission
M.onSplitScreenChanged = onSplitScreenChanged
M.onSplitScreenStartRequested = onSplitScreenStartRequested
M.onMultiseatGamemodeLaunched = onMultiseatGamemodeLaunched
M.onMultiseatGamemodeFinished = onMultiseatGamemodeFinished
M.onMultiseatGamemodeStopped = onMultiseatGamemodeStopped

return M
