-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'gameplay_drag_core', 'gameplay_achievement'}

-- Resets all non-dial timers for every racer.
local function reset()
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers then return end
  for _, racer in pairs(dragData.racers) do
    racer.timersStarted = false
    for _, t in pairs(racer.timers) do
      if t.type ~= "dialTimer" then
        t.value = 0
        if t.isSet ~= nil then
          t.isSet = false
        end
      end
    end
  end
end

-- Caches the drag gamemode reference for the current frame to avoid repeated lookups.
local function getDrag()
  return gameplay_drag_core.getDragGamemode()
end

local networkTimerCache = {
  raceId = nil,
  playersRef = nil,
  vehIdToPlayerId = {},
}

local function rebuildVehIdToPlayerIdMap(race)
  local map = {}
  local players = race and race.players or nil
  if players then
    for playerId, playerData in pairs(players) do
      local vehId = playerData and playerData.vehicleId
      if vehId and vehId ~= -1 then
        map[vehId] = playerId
      end
    end
  end
  networkTimerCache.vehIdToPlayerId = map
  networkTimerCache.playersRef = players
  networkTimerCache.raceId = race and race.id or nil
end

-- In MP, get network-broadcast timer values for a racer's vehicle. Returns table keyed by timerId, or nil.
function M.getNetworkTimersForRacer(racer)
  local drag = getDrag()
  if not drag or not drag.isMultiplayer or not drag.isMultiplayer() then return nil end
  local race = drag.getActiveDragRace and drag.getActiveDragRace()
  if not race or not race.timerValues or not race.players then return nil end

  if networkTimerCache.raceId ~= race.id or networkTimerCache.playersRef ~= race.players then
    rebuildVehIdToPlayerIdMap(race)
  end

  local playerId = networkTimerCache.vehIdToPlayerId[racer.vehId]
  local playerData = playerId and race.players[playerId] or nil
  if playerData and playerData.vehicleId == racer.vehId then
    return race.timerValues[playerId]
  end

  -- Player data may mutate in-place without replacing race.players; recover lazily on miss.
  for pid, pd in pairs(race.players) do
    if pd and pd.vehicleId == racer.vehId then
      networkTimerCache.vehIdToPlayerId[racer.vehId] = pid
      return race.timerValues[pid]
    end
  end
  return nil
end

function M.getRacerTimerValue(racer, timerId)
  local net = M.getNetworkTimersForRacer(racer)
  if net and net[timerId] then return net[timerId] end
  local t = racer.timers and racer.timers[timerId]
  return t and t.value or 0
end

function M.getImportantTimerValue(racer, data)
  local id = data and data.importantTimerId or "time_1_4"
  return M.getRacerTimerValue(racer, id)
end

function M.getReactionTimerValue(racer)
  local net = M.getNetworkTimersForRacer(racer)
  if net then
    for timerId, val in pairs(net) do
      if type(timerId) == "string" and timerId:find("reaction") then
        return val
      end
    end
  end
  for _, timer in pairs(racer.timers or {}) do
    if timer.type == "distanceTimer" and timer.distance and timer.distance < 0.5 then
      return timer.value or 0
    end
  end
  return 0
end

--- Effective time for win comparison: timer + reaction for time-type (distanceTimer), raw value for velocity.
function M.getImportantTimerValueForWin(racer, data)
  if not data then return M.getImportantTimerValue(racer, data) end
  local id = data.importantTimerId or "time_1_4"
  local timerConfig = data.timers or {}
  local val = M.getRacerTimerValue(racer, id)
  for _, t in ipairs(timerConfig) do
    if (t.id or "") == id then
      if t.type == "distanceTimer" then
        return val + M.getReactionTimerValue(racer)
      end
      return val
    end
  end
  return val + M.getReactionTimerValue(racer)
end

-- Sends a timer value to the MP host for synchronization.
-- drag: gamemode reference, raceState: current race state, vehId: vehicle ID, timerName: timer key, value: timer value
local function syncTimerValue(drag, vehId, timerName, value)
  local raceState = gameplay_drag_core.getRaceState()
  if raceState and raceState.id then
    drag.updateTimerValue(raceState.id, vehId, timerName, value)
  end
end

-- Per-frame timer update. Calculates elapsed time, distance/velocity splits, reaction time, and braking G.
local function onUpdate(dtReal, dtSim, dtRaw)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers or dragData.isCompleted then return end

  local drag = getDrag()
  local isMP = drag and drag.shouldSyncState and drag.shouldSyncState()

  if isMP then
    drag.checkTimerDrift()
  end

  for _, racer in pairs(dragData.racers) do
    -- Flush any passed-but-unset timers for finished/removed racers so MP gets full times (e.g. time_1_4 after 1000 ft).
    if (racer.vehicleRemoved or racer.isFinished) and isMP and drag then
      local timers = racer.timers
      local distanceFromOrigin = racer.currentDistanceFromOrigin or 0
      local timerValue = (timers and timers.timer and timers.timer.value) or 0
      if timers then
        for timerName, timer in pairs(timers) do
          if timer.distance and not timer.isSet and distanceFromOrigin >= timer.distance then
            if timer.type == "distanceTimer" then
              timer.value = timerValue
              timer.isSet = true
              syncTimerValue(drag, racer.vehId, timerName, timer.value)
            elseif timer.type == "velocity" then
              timer.value = racer.vehSpeed or racer.prevSpeed or 0
              timer.isSet = true
              syncTimerValue(drag, racer.vehId, timerName, timer.value)
            end
          end
        end
      end
      goto continue
    end
    if not racer.timersStarted then goto continue end

    local timers = racer.timers
    local timerValue = timers.timer.value

    if gameplay_drag_phaseHandlers then
      local distanceFromOrigin = racer.currentDistanceFromOrigin
      local prevDistance = racer.previousDistanceFromOrigin or distanceFromOrigin

      -- MP: use synchronized race start time. SP: accumulate dtSim.
      local raceStartTime = isMP and drag.getRaceStartTime and drag.getRaceStartTime()
      if raceStartTime then
        local now = os.clockhp()
        local raw = now - raceStartTime
        timerValue = math.max(0, raw)
        timers.timer.value = timerValue
      else
        timerValue = timerValue + dtSim
        timers.timer.value = timerValue
      end

      local reactionTimeJustSet = false
      local reactionTimeValue = 0

      for timerName, timer in pairs(timers) do
        if timer.distance and not timer.isSet and distanceFromOrigin >= timer.distance then
          local t = inverseLerp(prevDistance, distanceFromOrigin, timer.distance)

          if timer.type == "distanceTimer" then
            timer.value = timerValue - (1 - t) * dtSim
            timer.isSet = true
            if isMP then syncTimerValue(drag, racer.vehId, timerName, timer.value) end
            if timerName == "time_1_4" and timer.value <= 8.20 and gameplay_achievement and gameplay_achievement.unlockAchievement then
              local playerVehicleId = be:getPlayerVehicleID(0)
              local isPlayerRacer = racer.isLocalRacer == true or (racer.isLocalRacer == nil and (racer.vehId == playerVehicleId or racer.isPlayable))
              local isDisqualified = racer.isDisqualified ~= nil and racer.isDisqualified or racer.isDesqualified
              if isPlayerRacer and not racer.vehicleRemoved and not isDisqualified then
                gameplay_achievement.unlockAchievement("DRAG_QUARTER_MILE")
              end
            end
            if timer.distance < 0.5 then
              if racer.reactionTimeInvalid then
                timer.value = -1
              else
                reactionTimeJustSet = true
                reactionTimeValue = timer.value
                -- A reaction time that rounds to 0.000s is not humanly/AI-possible and indicates an exploit.
                if timer.value < 0.0005 then
                  local isDisqualified = racer.isDisqualified ~= nil and racer.isDisqualified or racer.isDesqualified
                  if not isDisqualified then
                    gameplay_drag_phaseHandlers.disqualifyRacer(racer, "missions.dragRace.gameplay.disqualified.reactionTime")
                  end
                end
              end
            end

          elseif timer.type == "velocity" then
            timer.value = lerp(racer.prevSpeed, racer.vehSpeed, t)
            timer.isSet = true
            if isMP then syncTimerValue(drag, racer.vehId, timerName, timer.value) end
          end
        end

        if timer.type == "timeToVelocity" and not timer.isSet and racer.vehSpeed > timer.velocity then
          timer.value = timerValue
          timer.isSet = true
          if isMP then syncTimerValue(drag, racer.vehId, timerName, timer.value) end
        end

        local currentPhase = racer.phases and racer.currentPhase and racer.phases[racer.currentPhase]
        if currentPhase and currentPhase.name == "emergencyStop" and currentPhase.started and timer.type == "brakingG" and not timer.isSet then
          if not timer.emergencyStopTime then
            timer.emergencyStopTime = timerValue
          end
          if (timerValue - timer.emergencyStopTime > 0.4) and not timer.startTime then
            timer.startTime = timerValue
            timer.startDistance = distanceFromOrigin
            timer.startSpeed = racer.vehSpeed
          elseif timer.startTime and ((timerValue - timer.startTime > timer.deltaTime) or racer.vehSpeed < 0.1) then
            timer.isSet = true
          end
        end
      end

      if reactionTimeJustSet then
        timers.timer.value = timers.timer.value - reactionTimeValue
      end

      racer.previousDistanceFromOrigin = distanceFromOrigin
    end

    ::continue::
  end
end

--- Marks a racer's timers as started (called when green light fires).
-- vehId: vehicle ID of the racer
local function dragRaceStarted(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not dragData.racers or not dragData.racers[vehId] then return end
  dragData.racers[vehId].timersStarted = true
end

local function resetDragRaceValues()
  reset()
end

M.reset = reset
M.dragRaceStarted = dragRaceStarted
M.resetDragRaceValues = resetDragRaceValues
M.onDragReset = function() reset() end
M.onDragClear = function() end
M.onUpdate = onUpdate

return M
