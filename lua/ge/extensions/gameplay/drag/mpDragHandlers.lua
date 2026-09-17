-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- All clients: initialises race state in general, stores minimal ref in mpState, loads strip data.
-- data fields: race (full snapshot), raceId, creatorId, lobbyId
local function handleDragSessionStarted(state, bridge, client, senderId, recpIds, data)
  if not data or not data.race then return end
  local r = data.race
  local raceId = data.raceId

  gameplay_drag_core.setRaceState(raceId, {
    players = r.players or {},
    queue = r.queue or {},
    currentPairIndex = r.currentPairIndex or 0,
    isStarted = r.isStarted or false,
    treeType = r.treeType or ".500",
    creatorId = data.creatorId or r.creatorId,
    poiData = r.poiData,
    lobbyId = data.lobbyId or r.lobbyId,
    finishTimes = {},
    timerValues = {},
  })
  state.dragRaces = state.dragRaces or {}
  state.dragRaces[raceId] = { id = raceId, lobbyId = data.lobbyId or r.lobbyId, poiKey = r.poiKey }

  gameplay_drag_core.setDragRaceData(r.poiData and deepcopy(r.poiData) or nil)

  local localPlayerId = bridge.getLocalPlayerId and bridge.getLocalPlayerId()
  local players = r.players or {}
  if localPlayerId and players[localPlayerId] and bridge.setLocalClientActiveRace then
    local pd = players[localPlayerId]
    bridge.setLocalClientActiveRace(raceId, r.poiData, pd.lane or 1, r.treeType or ".500")
  end
  extensions.hook("onDragRaceListChanged")
  extensions.hook("onDragRacePlayersUpdated", players)
end

-- All clients + host: marks race as started in general and local state.
-- data fields: raceId
local function handleDragRaceStarted(state, bridge, client, senderId, recpIds, data)
  if not data or not data.raceId then return end
  gameplay_drag_core.setRaceState(data.raceId, { isStarted = true })
  if state.localClientActiveRace and state.localClientActiveRace.id == data.raceId then
    state.localClientActiveRace.isStarted = true
  end
  extensions.hook("onDragRaceStarted", data.raceId)
  extensions.hook("onDragRaceStateChanged", data.raceId)
end

-- All clients + host: stores countdown sync timestamps per-race, forwards to general.
-- data fields: type="countdownStart", raceId, startTime (host clock), randValue
local function handleDragRaceCountdownStart(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "countdownStart" then return end
  local raceId = data.raceId
  if raceId and state.dragRaces and state.dragRaces[raceId] then
    local entry = state.dragRaces[raceId]
    entry.syncCountdownStart = data.startTime
    entry.syncRandValue = data.randValue
    entry.localCountdownStart = os.clockhp()
  end
  gameplay_drag_core.onDragRaceCountdownStart(data.startTime, data.randValue)
  extensions.hook("onDragRaceCountdownStart", data.startTime, data.randValue)
end

-- All clients + host: stores race start sync timestamp per-race, forwards to general.
-- data fields: type="raceStart", raceId, startTime (host clock)
local function handleDragRaceStart(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "raceStart" then return end
  local raceId = data.raceId
  if raceId and state.dragRaces and state.dragRaces[raceId] then
    local entry = state.dragRaces[raceId]
    entry.syncRaceStart = data.startTime
    entry.localRaceStart = os.clockhp()
  end
  gameplay_drag_core.onDragRaceStart(data.startTime)
  extensions.hook("onDragRaceStart", data.startTime)
end

-- All clients: updates players and queue in general when a new player joins mid-session.
-- data fields: type="dragRacePlayerJoined", raceId, players, queue
local function handleDragRacePlayerJoined(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "dragRacePlayerJoined" or not data.raceId then return end
  if data.players then
    gameplay_drag_core.setRaceState(data.raceId, { players = data.players })
  end
  if data.queue then
    gameplay_drag_core.setRaceState(data.raceId, { queue = data.queue })
  end
  local players = data.players or (bridge.getRaceState and bridge.getRaceState(data.raceId) and bridge.getRaceState(data.raceId).players)
  extensions.hook("onDragRaceListChanged")
  extensions.hook("onDragRacePlayersUpdated", players or {})
end

-- All clients + host: applies tree light state so display/UI match.
-- data fields: lane, lightState
local function handleDragRaceTreeLights(state, bridge, client, senderId, recpIds, data)
  if not data or not data.lane or not data.lightState then return end
  extensions.hook("onDragRaceTreeLights", data.lane, data.lightState)
end

-- All clients + host: applies winning light for a lane.
-- data fields: lane
local function handleDragRaceWinningLights(state, bridge, client, senderId, recpIds, data)
  if not data or not data.lane then return end
  extensions.hook("onDragRaceWinningLights", data.lane)
end

-- Host only: receives client tree light update, applies locally and broadcasts to other clients.
-- data fields: type="treeLightUpdate", raceId, lane, lightState
local function handleDragRaceTreeLightUpdate(state, bridge, client, senderId, recpIds, data)
  if not bridge or not bridge.isSessionHost or not bridge.isSessionHost() then return end
  if not data or data.type ~= "treeLightUpdate" or not data.lane or not data.lightState then return end
  extensions.hook("onDragRaceTreeLights", data.lane, data.lightState)
  if not data.raceId then return end
  local clientIds = bridge.getTimerRecipientClientIds and bridge.getTimerRecipientClientIds(data.raceId)
  if clientIds and next(clientIds) and bridge.sendToClientIds then
    local myCid = bridge.getLocalClientId and bridge.getLocalClientId()
    if myCid then clientIds[myCid] = nil end
    if next(clientIds) then
      bridge.sendToClientIds(clientIds, "dragRaceTreeLights", { type = "treeLights", raceId = data.raceId, lane = data.lane, lightState = data.lightState })
    end
  end
end

-- Host only: client sends local clock at finish; host maps to host clock via synclib, computes elapsed, broadcasts.
-- data fields: type="finishTime", raceId, rawTime (client os.clockhp() at finish)
local function handleDragRaceFinishTime(state, bridge, client, senderId, recpIds, data)
  if not bridge or not bridge.isSessionHost or not bridge.isSessionHost() then return end
  if not data or data.type ~= "finishTime" then return end
  local playerId = client and bridge.getPlayerIdByClientId and bridge.getPlayerIdByClientId(client.id)
  if not playerId then return end
  local raceId = data.raceId
  if not raceId then return end
  local entry = state.dragRaces and state.dragRaces[raceId]
  if not entry then return end
  local hostStart = entry.syncRaceStart
  if not hostStart then return end
  local rawTime = data.rawTime or data.finishTime
  if not rawTime then return end
  -- Map sender's clock to host clock so elapsed is comparable; no mapping needed for host's own finish.
  local finishTimeHostClock = rawTime
  local myCid = bridge.getLocalClientId and bridge.getLocalClientId()
  if client and client.id and myCid and client.id ~= myCid then
    if multiplayer_synclib and multiplayer_synclib.mapOtherClock then
      local mapped = multiplayer_synclib.mapOtherClock(client.id, rawTime)
      if mapped and type(mapped) == "number" and mapped > 0 then
        finishTimeHostClock = mapped
      else
        -- synclib not yet calibrated for this client; use raw time as best-effort fallback.
        log('W', 'drag_handlers', string.format('synclib.mapOtherClock returned %s for client %s — using raw time', tostring(mapped), tostring(client.id)))
      end
    else
      -- multiplayer_synclib extension not loaded; use raw time as best-effort fallback.
      log('W', 'drag_handlers', string.format('multiplayer_synclib not available — using raw time for client %s', tostring(client.id)))
    end
  end
  local elapsed = finishTimeHostClock - hostStart
  local stateGet = bridge.getRaceState and bridge.getRaceState(raceId)
  local finishTimes = (stateGet and stateGet.finishTimes) or {}
  finishTimes[playerId] = elapsed
  gameplay_drag_core.setRaceState(raceId, { finishTimes = finishTimes })
  local clientIds = bridge.getTimerRecipientClientIds and bridge.getTimerRecipientClientIds(raceId)
  if clientIds and next(clientIds) and bridge.sendToClientIds then
    if myCid then clientIds[myCid] = nil end
    if next(clientIds) then
      bridge.sendToClientIds(clientIds, "dragRaceFinishTimeBroadcast", {
        type = "finishTimeBroadcast", raceId = raceId, playerId = playerId, finishTime = elapsed
      })
    end
  end
  extensions.hook("onDragRaceFinishTimesUpdated", finishTimes)
end

-- All clients: applies authoritative timer update from host, updates vehicleId and configName if available.
-- data fields: type="timerUpdate", raceId, playerId, vehicleId, timerName, timerValue, configName
local function handleDragRaceTimerUpdate(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "timerUpdate" or not data.raceId then return end
  local stateGet = bridge.getRaceState and bridge.getRaceState(data.raceId)
  if not stateGet then return end
  local timerValues = stateGet.timerValues or {}
  local pid = data.playerId
  if not pid then return end
  if not timerValues[pid] then timerValues[pid] = {} end
  timerValues[pid][data.timerName] = data.timerValue
  local players = stateGet.players or {}
  if players[pid] and data.vehicleId and data.vehicleId ~= -1 then
    players[pid].vehicleId = data.vehicleId
  end
  if players[pid] and data.configName then
    players[pid].configName = data.configName
  end
  gameplay_drag_core.setRaceState(data.raceId, { timerValues = timerValues, players = players })
  extensions.hook("onDragRaceTimerUpdated", data.raceId, pid, data.timerName, data.timerValue)
  extensions.hook("onDragRaceTimerValuesUpdated", timerValues)
end

-- Host only: receives timer update from client, stores in general and broadcasts to other clients.
-- data fields: type="timerUpdateRequest", raceId, vehicleId, timerName, timerValue, configName
local function handleDragRaceTimerUpdateRequest(state, bridge, client, senderId, recpIds, data)
  if not bridge or not bridge.isSessionHost or not bridge.isSessionHost() then return end
  if not data or data.type ~= "timerUpdateRequest" or not data.raceId then return end
  local playerId = client and bridge.getPlayerIdByClientId and bridge.getPlayerIdByClientId(client.id)
  if not playerId then return end
  local stateGet = bridge.getRaceState and bridge.getRaceState(data.raceId)
  if not stateGet then return end
  local timerValues = stateGet.timerValues or {}
  if not timerValues[playerId] then timerValues[playerId] = {} end
  timerValues[playerId][data.timerName] = data.timerValue
  local players = stateGet.players or {}
  if players[playerId] and data.vehicleId and data.vehicleId ~= -1 then
    players[playerId].vehicleId = data.vehicleId
  end
  if players[playerId] and data.configName then
    players[playerId].configName = data.configName
  end
  gameplay_drag_core.setRaceState(data.raceId, { timerValues = timerValues, players = players })
  local clientIds = bridge.getTimerRecipientClientIds and bridge.getTimerRecipientClientIds(data.raceId)
  if clientIds and next(clientIds) and bridge.sendToClientIds then
    local myCid = bridge.getLocalClientId and bridge.getLocalClientId()
    if myCid then clientIds[myCid] = nil end
    if next(clientIds) then
      bridge.sendToClientIds(clientIds, "dragRaceTimerUpdate", {
        type = "timerUpdate", raceId = data.raceId, playerId = playerId, vehicleId = data.vehicleId, timerName = data.timerName, timerValue = data.timerValue, configName = data.configName
      })
    end
  end
  extensions.hook("onDragRaceTimerUpdated", data.raceId, playerId, data.timerName, data.timerValue)
  extensions.hook("onDragRaceTimerValuesUpdated", timerValues)
end

-- All clients: applies finish time broadcast from host.
-- data fields: type="finishTimeBroadcast", raceId, playerId, finishTime (elapsed seconds)
local function handleDragRaceFinishTimeBroadcast(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "finishTimeBroadcast" or not data.raceId then return end
  local stateGet = bridge.getRaceState and bridge.getRaceState(data.raceId)
  local finishTimes = (stateGet and stateGet.finishTimes) or {}
  finishTimes[data.playerId] = data.finishTime
  gameplay_drag_core.setRaceState(data.raceId, { finishTimes = finishTimes })
  extensions.hook("onDragRaceFinishTimesUpdated", finishTimes)
end

-- All clients: applies reset from host — clears timers, updates queue, resets sync state.
-- data fields: type="dragRaceReset", raceId, queue, currentPairIndex
local function handleDragRaceReset(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "dragRaceReset" or not data.raceId then return end
  gameplay_drag_core.setRaceState(data.raceId, {
    isStarted = false,
    finishTimes = {},
    timerValues = {},
    queue = data.queue,
    currentPairIndex = data.currentPairIndex,
  })
  if state then
    local entry = state.dragRaces and state.dragRaces[data.raceId]
    if entry then
      entry.syncCountdownStart = nil
      entry.syncRaceStart = nil
      entry.syncRandValue = nil
      entry.localCountdownStart = nil
      entry.localRaceStart = nil
      entry.countdownTriggeredForHeatKey = nil
    end
    if state.localClientActiveRace and state.localClientActiveRace.id == data.raceId then
      state.localClientActiveRace.isStarted = false
      state.localClientActiveRace.timerValues = {}
    end
  end
  extensions.hook("onDragRaceReset", data.raceId)
  extensions.hook("onDragRaceStateChanged", data.raceId)
  extensions.hook("onDragRaceFinishTimesUpdated", {})
  extensions.hook("onDragRaceTimerValuesUpdated", {})
end

-- All clients: host cancelled the drag session — clear race state and notify extensions.
-- data fields: type="dragRaceCancelled", raceId
local function handleDragRaceCancelled(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "dragRaceCancelled" or not data.raceId then return end
  local raceId = data.raceId
  gameplay_drag_core.clearRaceState(raceId)
  if state then
    if state.dragRaces then state.dragRaces[raceId] = nil end
    if state.localClientActiveRace and state.localClientActiveRace.id == raceId then
      state.localClientActiveRace = nil
      if bridge and bridge.clearLocalClientActiveRace then bridge.clearLocalClientActiveRace() end
    end
  end
  extensions.hook("onDragRaceListChanged")
  extensions.hook("onDragRaceCancelled", raceId)
end

-- All clients: host updated drag rules — apply to local race state and save locally.
-- data fields: type="rulesUpdate", raceId, dragType, treeType, importantTimerId
local function handleDragRaceRulesUpdate(state, bridge, client, senderId, recpIds, data)
  if not data or data.type ~= "rulesUpdate" or not data.raceId then return end
  local raceId = data.raceId
  local stateGet = bridge and bridge.getRaceState and bridge.getRaceState(raceId)
  if stateGet then
    if data.treeType then stateGet.treeType = data.treeType end
    if stateGet.poiData then
      if data.dragType then stateGet.poiData.dragType = data.dragType end
      if data.importantTimerId then stateGet.poiData.importantTimerId = data.importantTimerId end
      if data.treeType and stateGet.poiData.prefabs and stateGet.poiData.prefabs.christmasTree then
        stateGet.poiData.prefabs.christmasTree.treeType = data.treeType
      end
    end
    gameplay_drag_core.setRaceState(raceId, stateGet)
  end
  -- Also update the live dragData so timeslip/display use the new rules immediately on this client
  local gData = gameplay_drag_core.getData()
  if gData then
    if data.importantTimerId then gData.importantTimerId = data.importantTimerId end
    if data.dragType then gData.dragType = data.dragType end
    if data.treeType then
      if not gData.prefabs then gData.prefabs = {} end
      if not gData.prefabs.christmasTree then gData.prefabs.christmasTree = {} end
      gData.prefabs.christmasTree.treeType = data.treeType
    end
  end
  -- Save rules locally so they persist
  local poiData = stateGet and stateGet.poiData
  local stripId = poiData and (poiData.id or poiData._fnWithoutExt)
  local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
  if levelId and stripId then
    local ok, presetManager = pcall(require, "multiplayer.gamemodes.drag.util.presetManager")
    if ok and presetManager then
      presetManager.savePreset(levelId, stripId, {
        dragType = data.dragType,
        treeType = data.treeType,
        importantTimerId = data.importantTimerId,
      })
    else
      log('W', 'drag_handlers', 'Multiplayer preset manager unavailable, drag rules update was not saved locally')
    end
  end
end

-- Host only: client just loaded the drag extension and requests the current session state.
-- Responds with a dragSessionStarted snapshot so the client can catch up.
local function handleDragRaceStateRequest(state, bridge, client, senderId, recpIds, data)
  if not bridge or not bridge.isSessionHost or not bridge.isSessionHost() then return end
  if not state or not state.dragRaces or not next(state.dragRaces) then return end
  local sessionPlayers = bridge.getSessionPlayers and bridge.getSessionPlayers()
  for raceId, entry in pairs(state.dragRaces) do
    local raceState = bridge.getRaceState and bridge.getRaceState(raceId)
    if raceState then
      local creatorName = "Unknown"
      if sessionPlayers and raceState.creatorId and sessionPlayers[raceState.creatorId] then
        creatorName = sessionPlayers[raceState.creatorId].persona or "Unknown"
      end
      local clientId = client and client.id
      if clientId and bridge.sendToClientIds then
        bridge.sendToClientIds({[clientId] = true}, "dragSessionStarted", {
          type = "dragSessionStarted",
          raceId = raceId,
          lobbyId = entry.lobbyId,
          creatorId = raceState.creatorId,
          creatorName = creatorName,
          race = {
            id = raceId,
            poiKey = entry.poiKey,
            lobbyId = entry.lobbyId,
            creatorId = raceState.creatorId,
            creatorName = creatorName,
            treeType = raceState.treeType,
            isStarted = raceState.isStarted,
            players = raceState.players,
            queue = raceState.queue,
            currentPairIndex = raceState.currentPairIndex,
            poiData = raceState.poiData,
          },
        })
        -- If the race is already live, follow up with dragRaceStarted so the client's
        -- isStarted flag is set correctly (the original broadcast arrived before this
        -- extension was loaded and was lost).
        if raceState.isStarted then
          bridge.sendToClientIds({[clientId] = true}, "dragRaceStarted", {
            type = "dragRaceStarted",
            raceId = raceId,
          })
        end
      end
    end
  end
end

local handlers = {
  dragSessionStarted = handleDragSessionStarted,
  dragRaceStarted = handleDragRaceStarted,
  dragRaceCountdownStart = handleDragRaceCountdownStart,
  dragRaceStart = handleDragRaceStart,
  dragRacePlayerJoined = handleDragRacePlayerJoined,
  dragRaceTreeLights = handleDragRaceTreeLights,
  dragRaceWinningLights = handleDragRaceWinningLights,
  dragRaceTreeLightUpdate = handleDragRaceTreeLightUpdate,
  dragRaceFinishTime = handleDragRaceFinishTime,
  dragRaceTimerUpdate = handleDragRaceTimerUpdate,
  dragRaceTimerUpdateRequest = handleDragRaceTimerUpdateRequest,
  dragRaceFinishTimeBroadcast = handleDragRaceFinishTimeBroadcast,
  dragRaceReset = handleDragRaceReset,
  dragRaceCancelled = handleDragRaceCancelled,
  dragRaceRulesUpdate = handleDragRaceRulesUpdate,
  dragRaceStateRequest = handleDragRaceStateRequest,
}

M.handle = function(msgName, state, bridge, client, senderId, recpIds, data, packetClock, recvClock, msgNumber)
  local h = handlers[msgName]
  if h then
    h(state, bridge, client, senderId, recpIds, data)
  end
end

return M
