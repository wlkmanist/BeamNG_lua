-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {'gameplay_drag_core', 'gameplay_drag_times', 'gameplay_drag_saveSystem'}

local minVelToStop = 15 -- m/s
local stopPhaseMaxDistance = 300 -- m;
local dialsData = {}
local logTag = ""

local stageApproachSlope = 0.1      -- extra m/s of approach speed per meter behind the stage line
local stageApproachBonusMax = 2     -- hard cap (m/s) on the extra approach speed far from the line

local stageCreepZone = 0.5          -- distance (m) behind the stage line where the AI brakes then creeps in
local stageCreepSpeed = 0.5         -- very low velocity (m/s) used to creep the last bit into the stage line
local stageCreepBrakeTime = 0.4     -- seconds to hold the brake before creeping

local remoteStagingHoldTimers = {} -- key: lane number, value: os.clockhp() timestamp

local DQ_RESTAMP_DELAY = 6.0  -- seconds after DQ before the re-stage zone check activates
local dqRestageState = nil    -- { vehId, lane, timer } or nil when inactive

-- Stuck/crash DNF detection (race phase only). Checked periodically, not every frame.
local stuckCheckInterval = 3      -- seconds between stuck/crash checks
local stuckMinDistance = 3        -- min meters the racer must cover between checks while racing
local upVectorMin = 0.2           -- up-vector z below this means the car is flipped/on its side

-- AI launch pitch control: ease off throttle when the nose pitches up too hard so hard
-- launches don't backflip the car. Uses the forward-vector z component (sin of pitch).
local aiPitchSoft = 0.30          -- nose-up pitch where throttle starts being reduced (~17 deg)
local aiPitchHard = 0.55          -- nose-up pitch where throttle hits the minimum (~33 deg)
local aiThrottleMin = 0.5         -- lowest throttle override applied during a big wheelie

local stagePos

local function onExtensionLoaded()
  if not gameplay_drag_core then
    log("E", "drag_phaseHandlers", "gameplay_drag_core is not available. PhaseHandlers cannot function without core module.")
    return
  end
end

local function getFrontWheelDistanceFromStagePos(racer)
  local dragData = gameplay_drag_core.getData()
  if not dragData or not racer._wheelDistances or not racer.frontWheelId then
    return nil
  end
  return racer._wheelDistances[racer.frontWheelId]:dot(dragData.strip.lanes[racer.lane].stageToEndNormalized)
end

local function calculateDistanceOfAllWheelsFromStagePos(racer)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  stagePos = dragData.strip.lanes[racer.lane].waypoints.stage.transform.position
  racer._wheelDistances = {}
  for k, wheel in pairs(racer.wheelsCenter) do
    racer._wheelDistances[k] = racer._wheelDistances[k] or vec3()
    racer._wheelDistances[k]:set(wheel.pos)
    racer._wheelDistances[k]:setSub(stagePos)
  end
end

local function areFrontWheelsParallelToLine(racer, lineTransform)
  if not lineTransform then
    log('E', logTag, 'Invalid line definition.')
    return false
  end
  local dotProduct = racer.vehDirectionVector:dot(lineTransform.y)
  local tolerance = 0.70
  return math.abs(dotProduct) >= tolerance
end

local function isRacerInsideBoundary(racer)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return false end
  if racer.vehicleRemoved or not racer.vehId then return false end

  local playerLane = racer.lane
  if not playerLane or not dragData.strip.lanes[playerLane] then
    log('E', logTag, 'No valid lane found for racer: ' .. racer.vehId)
    return false
  end

  local laneData = dragData.strip.lanes[playerLane]
  if not laneData.zone or not laneData.zone.containsPoint2D then
    log('E', logTag, 'isRacerInsideBoundary: no zone for lane ' .. tostring(playerLane) .. ' vehId ' .. tostring(racer.vehId))
    return false
  end
  if not racer.vehPos then
    log('E', logTag, 'isRacerInsideBoundary: no vehPos for vehId ' .. tostring(racer.vehId))
    return false
  end

  -- Prefer wheel-center checks to ensure the whole car stays in-lane.
  if racer.wheelsCenter and next(racer.wheelsCenter) then
    for _, wheelData in pairs(racer.wheelsCenter) do
      local wheelPos = wheelData and wheelData.pos or nil
      if not wheelPos or not laneData.zone:containsPoint2D(wheelPos) then
        return false
      end
    end
    return true
  end

  return laneData.zone:containsPoint2D(racer.vehPos)
end

local function isRacerOutsideLane(racer)
  return racer and not isRacerInsideBoundary(racer)
end

local function stopAiVehicle(racer)
  if racer.vehicleRemoved or not racer.vehId then return end
  local veh = scenetree.findObjectById(racer.vehId)
  if veh then
    local dragData = gameplay_drag_core.getData()
    local wps = dragData and dragData.strip and dragData.strip.waypoints
    local laneData = dragData and dragData.strip.lanes[racer.lane]
    local stopName = (wps and wps.drag_stop and wps.drag_stop.name) or (laneData and laneData.autoStopName)
    if stopName then
      veh:queueLuaCommand('ai.setTarget("' .. stopName .. '")')
    end
    veh:queueLuaCommand('ai:scriptStop(' .. tostring(true) .. ',' .. tostring(true) .. ')')
  end
end

local function getNetworkTimersForRacer(racer)
  return gameplay_drag_times.getNetworkTimersForRacer(racer)
end

local function getRacerTimerValue(racer, timerId)
  return gameplay_drag_times.getRacerTimerValue(racer, timerId) or 0
end

local function getImportantTimerValue(racer, data)
  return gameplay_drag_times.getImportantTimerValue(racer, data) or 0
end

local function getReactionTimerValue(racer)
  return gameplay_drag_times.getReactionTimerValue(racer) or 0
end

local function getImportantTimerValueForWin(racer, data)
  return gameplay_drag_times.getImportantTimerValueForWin(racer, data) or 0
end

local function isRacerDisqualified(racer)
  if not racer then return false end
  if racer.isDisqualified ~= nil then return racer.isDisqualified end
  return racer.isDesqualified or false
end

local function setRacerDisqualification(racer, reason)
  if not racer then return end
  local dqReason = reason or "None"
  racer.isDisqualified = true
  racer.disqualifiedReason = dqReason
  -- Legacy aliases kept for compatibility during migration.
  racer.isDesqualified = true
  racer.desqualifiedReason = dqReason
end

local function getRaceEndTimerId(data)
  if not data then return "time_1_4" end
  if data.raceEndTimerId then return data.raceEndTimerId end
  local importantId = data.importantTimerId or "time_1_4"
  local timerConfig = data.timers or (gameplay_drag_saveSystem and gameplay_drag_saveSystem.DEFAULT_TIMERS) or {}
  local maxDistTimerId = nil
  local maxDist = -1
  for _, t in ipairs(timerConfig) do
    local id = t.id or ("timer_" .. #timerConfig)
    if t.distance and t.distance > maxDist then
      maxDist = t.distance
      maxDistTimerId = id
    end
  end
  data.raceEndTimerId = maxDistTimerId or importantId
  return data.raceEndTimerId
end

local function updateLightState(racer, pairId, lightType, newState, onEvent, offEvent)
  if racer.beamState[pairId][lightType] ~= newState then
    racer.beamState[pairId][lightType] = newState
    extensions.hook(newState and onEvent or offEvent, racer.vehId)
  end
end

local preStageThreshold = -0.178
local stageThreshold = 0
local exitThreshold = 0.4
local function processTreeLights(racer, pairId, distance, inLane)
  if not inLane or math.abs(distance) > exitThreshold then
    updateLightState(racer, pairId, "preStage", false, "preStageLightOn", "preStageLightOff")
    updateLightState(racer, pairId, "stage", false, "stageLightOn", "stageLightOff")
    return
  end

  local preStageNew = distance >= preStageThreshold - 0.178 and distance < preStageThreshold + 0.178
  local stageNew = distance >= stageThreshold - 0.178 and distance < stageThreshold + 0.178

  updateLightState(racer, pairId, "preStage", preStageNew, "preStageLightOn", "preStageLightOff")
  updateLightState(racer, pairId, "stage", stageNew, "stageLightOn", "stageLightOff")
end

local function disqualifyRacer(racer, reason)
  -- Never disqualify during staging (phase 1); only countdown (2) or race (3).
  if racer.currentPhase == 1 then
    return
  end

  local dragData = gameplay_drag_core.getData()
  local ctx = gameplay_drag_core.getGameplayContext and gameplay_drag_core.getGameplayContext() or "freeroam"
  if ctx ~= "freeroam" and dragData and not dragData.isStarted then
    return
  end
  if not isRacerDisqualified(racer) then
    setRacerDisqualification(racer, reason)

    if not racer.isPlayable then
      racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = nil')
    end
    extensions.hook("setDisqualifiedLights", racer.vehId)
  end
end

local stageJumpDqBuffer = 0.02 -- small buffer beyond stage boundary to absorb physics micro-oscillations during countdown
local disqualificationChecks = {
  stageJump = function(racer)
    local distance = getFrontWheelDistanceFromStagePos(racer)
    if distance < -0.178 - stageJumpDqBuffer or distance > 0.178 + stageJumpDqBuffer then
      return true, "missions.dragRace.gameplay.disqualified.jumping"
    end
    return false
  end,

  outOfBounds = function(racer, distance)
    return not isRacerInsideBoundary(racer) or distance < -0.33,
           "missions.dragRace.gameplay.disqualified.outOfLane"
  end,

  stationaryTooLong = function(racer, timer)
    return racer.vehSpeed < 1 and timer > 5,
           "missions.dragRace.gameplay.disqualified.stationaryTooLong"
  end
}

local function generateWinData()
  local dragData = gameplay_drag_core.getData()
  if not dragData then return {} end
  local ext = gameplay_drag_core.getExtension()
  if not ext or not ext.generateWinData then return {} end
  local winnerList = ext.generateWinData(dragData)
  if winnerList and #winnerList > 0 then
    local winner = winnerList[1]
    if dragData.racers and dragData.racers[winner.vehId] then
      extensions.hook("onWinnerLightOn", dragData.racers[winner.vehId].lane)
    end
  end
  return winnerList or {}
end

-- Phase transition state (abort via setPhaseTransitionAbort from onPhaseTransition hook).
local racerTransitionLocks = {}
local phaseTransitionAbortFlags = {}

local function clearRacerTransitionLock(vehId)
  if vehId then
    racerTransitionLocks[vehId] = nil
    phaseTransitionAbortFlags[vehId] = nil
  else
    racerTransitionLocks = {}
    phaseTransitionAbortFlags = {}
  end
end

local function setPhaseTransitionAbort(vehId)
  if vehId then phaseTransitionAbortFlags[vehId] = true end
end

local function changeRacerPhase(racer, expectedCurrentPhase)
  if not racer then return false end
  if racer.vehicleRemoved then return true end
  if not racer.vehId then return true end
  if racer.isFinished then return true end

  local vehId = racer.vehId
  if racerTransitionLocks[vehId] then
    log('W', logTag, string.format('Racer %d phase transition already in progress, ignoring duplicate call', vehId))
    return false
  end

  local dragData = gameplay_drag_core.getData()
  if not dragData then return false end

  local currentPhase = racer.currentPhase
  if expectedCurrentPhase and currentPhase ~= expectedCurrentPhase then
    log('W', logTag, string.format('Racer %d phase validation failed: expected %d, got %d', vehId, expectedCurrentPhase, currentPhase))
    return false
  end

  local index = currentPhase + 1
  local newPhase = (index <= #dragData.phases) and index or nil

  -- Racer must stay inside lane to enter countdown/race (skip for remote stubs with no position data).
  local isRemoteStub = racer.isLocalRacer == false or (racer.vehId and racer.vehId < 0)
  if not isRemoteStub and (newPhase == 2 or newPhase == 3) and not isRacerInsideBoundary(racer) then
    log('W', logTag, string.format('Blocked phase transition out of lane vehId=%s: %s -> %s',
      tostring(vehId), tostring(currentPhase), tostring(newPhase)))
    return false
  end

  local raceId = nil
  if gameplay_drag_core then
    local raceState = gameplay_drag_core.getRaceState()
    if raceState then raceId = raceState.id end
  end

  local oldPhase = currentPhase
  local newPhaseName = newPhase and (dragData.phases[newPhase] and dragData.phases[newPhase].name or "unknown") or "finished"

  if newPhase then
    phaseTransitionAbortFlags[vehId] = false
    extensions.hook("onPhaseTransition", raceId, vehId, oldPhase, newPhase)
    if phaseTransitionAbortFlags[vehId] then
      log('W', logTag, string.format('Phase transition aborted by hook for racer %d: %d -> %d', vehId, oldPhase, newPhase))
      phaseTransitionAbortFlags[vehId] = nil
      return false
    end
    phaseTransitionAbortFlags[vehId] = nil
  end

  racerTransitionLocks[vehId] = true
  if index > #dragData.phases then
    racer.isFinished = true
  else
    racer.currentPhase = newPhase
  end
  racerTransitionLocks[vehId] = nil

  if newPhase then
    extensions.hook("onRacerPhaseTransition", vehId, oldPhase, newPhase, newPhaseName)
  else
    extensions.hook("onRacerPhaseTransition", vehId, oldPhase, nil, "finished")
  end
  return true
end

local function changeAllPhases()
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  for vehId, racer in pairs(dragData.racers) do
    local phase = racer.phases and racer.phases[racer.currentPhase]
    if phase and phase.completed then
      changeRacerPhase(racer, racer.currentPhase)
    end
  end
end

local randomDelayTimer = 0
local function startRaceFromTree(vehId)
  local dragData = gameplay_drag_core.getData()
  if not dragData then
    return
  end
  if not dragData.racers or not dragData.racers[vehId] then
    return
  end
  local racer = dragData.racers[vehId]

  if not racer.phases or not racer.currentPhase or not racer.phases[racer.currentPhase] then
    return
  end

  local currentPhase = racer.phases[racer.currentPhase]
  if currentPhase.name ~= "countdown" then
    return
  end

  if not racer.isPlayable then
    randomDelayTimer = math.random() / 2
  end

  currentPhase.completed = true
end

--[[
  Checks if all racers are properly staged (ready for countdown).
  A racer is considered staged if:
  - They are in phase 1 (stage phase)
  - Their phase 1 is completed (they've reached the staging beam)

  @param dragData - The drag race data (optional, will fetch if not provided)
  @return true if all racers are staged, false otherwise
  @return number of staged racers
  @return total number of racers
]]
local function areAllRacersStaged(dragData)
  dragData = dragData or gameplay_drag_core.getData()
  if not dragData or not dragData.racers then
    return false, 0, 0
  end

  local totalCount = 0
  local stagedCount = 0
  local allStaged = true

  for vehId, racer in pairs(dragData.racers) do
    totalCount = totalCount + 1
    -- Only count as staged when explicitly staged or finished; never treat vehicleRemoved as staged (MP: wait for remote staging).
    if racer.isFinished then
      stagedCount = stagedCount + 1
    elseif racer.currentPhase ~= 1 then
      allStaged = false
    elseif racer.phases and racer.phases[1] and racer.phases[1].completed then
      local isRemoteStub = racer.isLocalRacer == false or (racer.vehId and racer.vehId < 0)
      if not isRemoteStub and isRacerOutsideLane(racer) then
        allStaged = false
      else
        stagedCount = stagedCount + 1
      end
    else
      allStaged = false
    end
  end

  if totalCount == 0 then
    return false, 0, 0
  end

  local result = allStaged and stagedCount == totalCount
  return result, stagedCount, totalCount
end

local function stage(phase, racer, dtSim)
  local dragData = gameplay_drag_core.getData()
  if not dragData or phase.completed then return end
  if racer.vehicleRemoved or not racer.vehId then return end

  local distance = getFrontWheelDistanceFromStagePos(racer)
  if not distance then return end

  -- Only send staging distance for the local player's vehicle
  if racer.vehId == be:getPlayerVehicleID(0) then
    guihooks.trigger("updateStageApp", distance)
  end

  local laneData = dragData.strip.lanes[racer.lane]
  local stageWaypoint = laneData.waypoints.stage.waypoint
  local vehObj = scenetree.findObjectById(racer.vehId)
  if not vehObj then return end
  racer.vehObj = vehObj
  local inLane = isRacerInsideBoundary(racer)

  if not inLane then
    phase.completeTimer = 0
    return
  end

  if not racer.isPlayable then
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim
      if phase.timerOffset >= phase.startedOffset then
        phase.started = true
        local aiTarget = laneData.waypoints.endLine.name

        racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
        racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = nil')
        racer.vehObj:queueLuaCommand('ai.setSpeedMode("set")')
        racer.vehObj:queueLuaCommand('ai.setSpeed(0)')
        racer.vehObj:queueLuaCommand('controller.setFreeze(0)')
        racer.vehObj:queueLuaCommand([[
          local nc = controller.getController("nitrousOxideInjection")
          if nc then
            local engine = powertrain.getDevice("mainEngine")
            if engine and engine.nitrousOxideInjection and not engine.nitrousOxideInjection.isArmed then
              nc.toggleActive()
            end
          end
        ]])
        racer.vehObj:queueLuaCommand('ai.setTarget("' .. aiTarget .. '")')
        extensions.hook("stageStarted")
      end
    end

    if phase.started then
      if racer.beamState[racer.frontWheelId].stage then
        phase.completed = true
        stopAiVehicle(racer)
        return
      elseif distance < -0.178 then
        if distance > -stageCreepZone then
          -- within half a meter of the stage line: brake to a near stop, then creep in at a very low velocity
          if not phase.creepPhase then
            phase.creepPhase = "brake"
            phase.creepBrakeTimer = 0
            racer.vehObj:queueLuaCommand('ai.setSpeedMode("set")')
            racer.vehObj:queueLuaCommand('ai.setSpeed(0)')
          elseif phase.creepPhase == "brake" then
            phase.creepBrakeTimer = phase.creepBrakeTimer + dtSim
            if phase.creepBrakeTimer >= stageCreepBrakeTime then
              phase.creepPhase = "creep"
              racer.vehObj:queueLuaCommand('ai.setSpeedMode("set")')
              racer.vehObj:queueLuaCommand('ai.setSpeed(' .. stageCreepSpeed .. ')')
            end
          end
        else
          phase.creepPhase = nil
          local approachBonus = math.min(stageApproachBonusMax, math.max(0, -distance) * stageApproachSlope)
          local approachSpeed = stageWaypoint.speed + approachBonus
          racer.vehObj:queueLuaCommand('ai.setSpeedMode("set")')
          racer.vehObj:queueLuaCommand('ai.setSpeed(' .. approachSpeed .. ')')
        end
      end
    end
  else
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim
      if phase.timerOffset >= phase.startedOffset then
        phase.started = true
        extensions.hook("stageStarted")
      end
    end

    local frontWheelState = racer.beamState[racer.frontWheelId]
    if not frontWheelState.preStage and not frontWheelState.stage then
      phase.completeTimer = 0
    end

    if frontWheelState.stage and inLane and areFrontWheelsParallelToLine(racer, laneData.waypoints.stage.transform) then
      phase.completeTimer = (phase.completeTimer or 0) + dtSim

      if phase.completeTimer > 1 then
        phase.completed = true
        return
      end
    else
      phase.completeTimer = 0
    end
  end
end

local function setRemoteStagingState(data, lane, staged)
  if not data or not data.racers then return end
  if staged then
    if not remoteStagingHoldTimers[lane] then
      remoteStagingHoldTimers[lane] = os.clockhp()
    end
  else
    remoteStagingHoldTimers[lane] = nil
    for _, racer in pairs(data.racers) do
      if racer.lane == lane and racer.phases and racer.phases[1] then
        racer.phases[1].completed = false
      end
    end
  end
end

local function updateRemoteStagingHoldTimers()
  if not next(remoteStagingHoldTimers) then return end
  local data = gameplay_drag_core.getData()
  if not data or not data.racers then return end
  local now = os.clockhp()
  for lane, startTime in pairs(remoteStagingHoldTimers) do
    if now - startTime >= 1.0 then
      for _, racer in pairs(data.racers) do
        if racer.lane == lane and racer.phases and racer.phases[1] then
          racer.phases[1].completed = true
        end
      end
      remoteStagingHoldTimers[lane] = nil
    end
  end
end

local function clearRemoteStagingHoldTimers()
  remoteStagingHoldTimers = {}
end

local function clearDqRestageState()
  dqRestageState = nil
end

local function checkFreeroamDqReStage(dtSim)
  if gameplay_drag_core.getGameplayContext() ~= "freeroam" then
    dqRestageState = nil
    return
  end
  if gameplay_drag_core.getDragGamemode and gameplay_drag_core.getDragGamemode() then
    dqRestageState = nil
    return
  end

  local data = gameplay_drag_core.getData()
  if not data or not data.racers or not data.strip or not data.strip.lanes then
    dqRestageState = nil
    return
  end

  local racer
  for _, r in pairs(data.racers) do
    if r.isPlayable and not r.isFinished and isRacerDisqualified(r) then racer = r; break end
  end
  if not racer then dqRestageState = nil; return end

  local vehId = racer.vehId
  if not dqRestageState or dqRestageState.vehId ~= vehId then
    dqRestageState = { vehId = vehId, lane = racer.lane, timer = 0 }
  end

  dqRestageState.timer = dqRestageState.timer + dtSim
  if dqRestageState.timer < DQ_RESTAMP_DELAY then return end

  local veh = scenetree.findObjectById(vehId)
  if not veh then return end

  local laneData  = data.strip.lanes[dqRestageState.lane]
  local stagePos  = laneData.waypoints.stage.transform.position
  local stageFwd = laneData.waypoints.stage.transform.rot * vec3(0, 1, 0)
  local vehPos    = veh:getPosition()


  local distance = vec3(vehPos - stagePos):dot(stageFwd)

  -- more than 6m: the player did a false start but still drives along the track. dont show anything, wait for them to either reverse back to the staging area or drive to the end of the lane
  if distance > 6 then
    return
  end

  -- if the player reversed back too far already when the timer finishes, just reset the drag area
  if distance <= -15 then
    return "leftArea"
  end

  -- otherwise: wait before the player goes back before the staging line, 6-15m before the staging line, and notify the player
  if distance < -6 and distance > -15 then
    local resetLane = dqRestageState.lane
    dqRestageState = nil
    gameplay_drag_core.reset({ raceState = true, racers = true, timeslip = true, transitionLock = true, treeLightStaging = true, hooks = true })
    gameplay_drag_core.startDragRaceActivity(resetLane)
    return
  end

  if not dqRestageState.notifiedPlayer then
    dqRestageState.notifiedPlayer = true
    local messageData = {{"Reverse to re-stage", 5, 0, false}}
    guihooks.trigger('DragRaceTreeFlashMessage', messageData)
    ui_appContainers.showApp('topCenter', 'flashMessage')
    guihooks.trigger('ScenarioFlashMessage', { msg = "Reverse to re-stage", ttl = 5, big = false })
  end

end

local function countdown(phase, racer, dtSim)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end

  if phase.completed then return end
  if racer.vehicleRemoved or not racer.vehId then return end

  local distance = getFrontWheelDistanceFromStagePos(racer)
  if not distance then return end

  local vehObj = scenetree.findObjectById(racer.vehId)
  if not vehObj then return end
  racer.vehObj = vehObj
  local inLane = isRacerInsideBoundary(racer)

  if not inLane then
    if not isRacerDisqualified(racer) then
      racer.reactionTimeInvalid = true
      startRaceFromTree(racer.vehId)
      disqualifyRacer(racer, "missions.dragRace.gameplay.disqualified.outOfLane")
    end
    return
  end

  if not racer.isPlayable then
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
        racer.vehObj:queueLuaCommand('ai.setAggression(2)')
        racer.vehObj:queueLuaCommand('ai.setParameters({understeerThrottleControl = "off", oversteerThrottleControl = "off", throttleTcs = "off"})')
        racer.vehObj:queueLuaCommand([[
          local ts = controller.getController("twoStep")
          if ts then ts.toggleTwoStep() end
        ]])
        racer.vehObj:queueLuaCommand([[
          local tb = controller.getController("transbrake")
          if tb then
            tb.toggleTransbrake()
          else
            controller.setFreeze(1)
          end
        ]])
        -- Build revs at full throttle while held (transbrake / two-step caps the launch RPM)
        -- so the car is ready to launch as hard as possible the instant the tree goes green.
        racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = 1')
        extensions.hook("startDragCountdown", racer.vehId, dialsData[racer.vehId])
        phase.started = true
      end
    end
  else
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        extensions.hook("startDragCountdown", racer.vehId, dialsData[racer.vehId])
        phase.started = true
      end
    end
  end

  -- Only DQ for stage jump when actually in countdown phase (phase 2); never during staging (phase 1). Skip racers with no local vehicle (MP stub).
  if not isRacerDisqualified(racer) and not racer.vehicleRemoved and racer.vehObj and racer.treeStarted and racer.currentPhase == 2 then
    local shouldDQ, reason = disqualificationChecks.stageJump(racer)
    if shouldDQ then
      -- Same early-countdown-end issue as above: this jump happens before the real green light.
      racer.reactionTimeInvalid = true
      startRaceFromTree(racer.vehId)
      disqualifyRacer(racer, reason)
    end
  end

  if not isRacerDisqualified(racer) then
    local shouldDQ, reason = disqualificationChecks.outOfBounds(racer, distance)
    if shouldDQ then
      racer.reactionTimeInvalid = true
      startRaceFromTree(racer.vehId)
      disqualifyRacer(racer, reason)
    end
  end
end

-- Periodic stuck/crash detection for any racer during the race phase.
-- Returns shouldDQ, reason. Only does real work once every stuckCheckInterval seconds.
local function checkRacerStuckOrCrashed(racer, dtSim)
  racer._stuckTimer = (racer._stuckTimer or 0) + dtSim
  if racer._stuckTimer < stuckCheckInterval then return false end
  racer._stuckTimer = 0

  -- Flipped / on its side: the up vector no longer points up.
  if racer.vehDirectionVectorUp and racer.vehDirectionVectorUp.z < upVectorMin then
    return true, "missions.dragRace.gameplay.disqualified.crashed"
  end

  -- Stuck: barely moved since the previous check. Seed the reference position the first time.
  if not racer._stuckCheckPos then
    racer._stuckCheckPos = vec3()
    racer._stuckCheckPos:set(racer.vehPos)
    return false
  end
  local moved = racer.vehPos:distance(racer._stuckCheckPos)
  racer._stuckCheckPos:set(racer.vehPos)
  if moved < stuckMinDistance then
    return true, "missions.dragRace.gameplay.disqualified.stationaryTooLong"
  end

  return false
end

-- Ease off the AI throttle when the nose pitches up too hard, to avoid launch backflips.
-- Recalculated and applied every frame so it tracks the live pitch closely.
local function updateAiPitchThrottle(racer)
  if not racer.vehObj or not racer.vehDirectionVector then return end
  local pitch = racer.vehDirectionVector.z -- > 0 means the nose is pointing up
  local target = 1
  if pitch > aiPitchSoft then
    local t = (pitch - aiPitchSoft) / (aiPitchHard - aiPitchSoft)
    t = math.min(math.max(t, 0), 1)
    target = 1 - t * (1 - aiThrottleMin)
  end
  racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = ' .. target)
end

local function race(phase, racer, dtSim)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end

  if phase.completed then return end
  if racer.vehicleRemoved or not racer.vehId then return end

  local laneData = dragData.strip.lanes[racer.lane]
  local endLine = laneData.waypoints.endLine
  local vehObj = scenetree.findObjectById(racer.vehId)
  if not vehObj then return end
  racer.vehObj = vehObj

  if not isRacerInsideBoundary(racer) then
    if not isRacerDisqualified(racer) then
      disqualifyRacer(racer, "missions.dragRace.gameplay.disqualified.outOfLane")
    end
    return
  end

  if not racer.isPlayable then
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim
      randomDelayTimer = randomDelayTimer - dtSim

      if phase.timerOffset >= phase.startedOffset and randomDelayTimer <= 0 then
        local aiSpeed = endLine.waypoint.speed
        local aiMode = endLine.waypoint.mode
        local aiTarget = endLine.name
        racer.vehObj:queueLuaCommand('if electrics.values.jatoInput then electrics.values.jatoInput = 1 end')
        racer.vehObj:queueLuaCommand([[
          local tb = controller.getController("transbrake")
          if tb then
            tb.toggleTransbrake()
          else
            controller.setFreeze(0)
          end
        ]])
        racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = 1')
        racer.vehObj:queueLuaCommand('ai.setSpeed(' .. aiSpeed .. ')')
        racer.vehObj:queueLuaCommand('ai.setSpeedMode("' .. aiMode .. '")')
        racer.vehObj:queueLuaCommand('ai.setTarget("' .. aiTarget .. '")')

        phase.started = true
        extensions.hook("dragRaceStarted", racer.vehId)
      end
    end
  else
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        phase.started = true
        extensions.hook("dragRaceStarted", racer.vehId)
        racer.finishBoundTimer = 0
      end
    end
  end

  if phase.started and not racer.isFinished then
    -- Pitch-limited throttle is an AI-only launch aid (the player controls their own throttle).
    if not racer.isPlayable then
      updateAiPitchThrottle(racer)
    end

    -- Stuck/crash DNF runs for every racer; notification is gated to the player downstream.
    if not isRacerDisqualified(racer) then
      local shouldDQ, reason = checkRacerStuckOrCrashed(racer, dtSim)
      if shouldDQ then
        if not racer.isPlayable then
          stopAiVehicle(racer)
        end
        disqualifyRacer(racer, reason)
        -- Advance past the race phase so a stuck/crashed racer doesn't block the race.
        phase.completed = true
        return
      end
    end
  end

  -- Race phase ends when the farthest-distance timer is set, not the important timer.
  -- Timer id is cached on dragData and computed once (fallback only when not precomputed).
  local raceEndTimerId = getRaceEndTimerId(dragData)
  local raceEndTimer = racer.timers and racer.timers[raceEndTimerId]
  if raceEndTimer and raceEndTimer.isSet then
    phase.completed = true
    extensions.hook("dragRaceEndLineReached", racer.vehId)

    local drag = gameplay_drag_core.getDragGamemode()
    local isMP = drag and drag.isMultiplayer and drag.isMultiplayer()
    if isMP then
      local rawFinishTime = os.clockhp()
      local mpsm = multiplayer_sessionManager
      if mpsm then
        local activeRace = drag and drag.getLocalClientActiveRace and drag.getLocalClientActiveRace()
        mpsm.sendSessionHost("dragRaceFinishTime", {
          type = "finishTime",
          raceId = activeRace and activeRace.id or nil,
          vehicleId = racer.vehId,
          rawTime = rawFinishTime
        })
      end
    end

    -- In MP, remote racers' timers are never set locally. Win data, timeslip, and history
    -- are triggered later by onDragRaceTimerUpdated once ALL network timer values arrive.
    if not isMP then
      local allRacersFinished = true
      for _, r in pairs(dragData.racers) do
        if r.isFinished or r.vehicleRemoved then
          -- count as finished
        else
          local rEnd = r.timers and r.timers[raceEndTimerId]
          if not rEnd or not rEnd.isSet then
            allRacersFinished = false
            break
          end
        end
      end
      if allRacersFinished then
        generateWinData()
      end
      if not gameplay_missions_missionManager.getForegroundMissionId() then
        gameplay_drag_core.sendTimeslipDataToUi()
      end
      if racer.isPlayable then
        gameplay_drag_core.saveDialTimes()
      end
    else
      -- MP: mark that the local racer has finished; timeslip/win/display triggered by onDragRaceTimerUpdated
      if not gameplay_missions_missionManager.getForegroundMissionId() then
        gameplay_drag_core.sendTimeslipDataToUi()
      end
    end
    return
  end

  if racer.vehSpeed < 1 then
    racer.finishBoundTimer = (racer.finishBoundTimer or 0) + dtSim
    local shouldDQ, reason = disqualificationChecks.stationaryTooLong(racer, racer.finishBoundTimer)
    if shouldDQ then
      racer.finishBoundTimer = 0
      disqualifyRacer(racer, reason)
    end
  else
    racer.finishBoundTimer = 0
  end

  local distance = getFrontWheelDistanceFromStagePos(racer)
  if not isRacerDisqualified(racer) then
    local shouldDQ, reason = disqualificationChecks.outOfBounds(racer, distance)
    if shouldDQ then
      disqualifyRacer(racer, reason)
    end
  end
end

local function stop(phase, racer, dtSim)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  if phase.completed then return end
  if racer.vehicleRemoved or not racer.vehId then return end

  local laneData = dragData.strip.lanes[racer.lane]
  local spawnWaypoint = laneData.waypoints.spawn.waypoint
  local vehObj = scenetree.findObjectById(racer.vehId)
  if not vehObj then return end
  racer.vehObj = vehObj

  if not racer.isPlayable then
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = nil')
        racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
        racer.vehObj:queueLuaCommand('ai.setAggression(0.3)')
        racer.vehObj:queueLuaCommand('if electrics.values.jatoInput then electrics.values.jatoInput = 0 end')

        racer.vehObj:queueLuaCommand([[
          local nc = controller.getController("nitrousOxideInjection")
          if nc then
            local engine = powertrain.getDevice("mainEngine")
            if engine and engine.nitrousOxideInjection and engine.nitrousOxideInjection.isArmed then
              nc.toggleActive()
            end
          end
        ]])
        racer.vehObj:queueLuaCommand('ai.setSpeedMode("off")')
        local wps = dragData.strip.waypoints
        local stopName = (wps and wps.drag_stop and wps.drag_stop.name) or laneData.autoStopName
        if stopName then
          racer.vehObj:queueLuaCommand('ai.setTarget("' .. stopName .. '")')
        end

        phase.started = true
        racer._stopPhaseStartDistance = racer.currentDistanceFromOrigin or 0
        extensions.hook("stoppingVehicleDrag", racer.vehId)
      end
    end
  else
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        phase.started = true
        racer._stopPhaseStartDistance = racer.currentDistanceFromOrigin or 0
        extensions.hook("stoppingVehicleDrag", racer.vehId)
      end
    end
  end

  local distanceTraveled = racer._stopPhaseStartDistance and (racer.currentDistanceFromOrigin or racer._stopPhaseStartDistance) - racer._stopPhaseStartDistance or 0

  if racer.vehSpeed <= minVelToStop or distanceTraveled >= stopPhaseMaxDistance then
    extensions.hook("dragRaceVehicleStopped", racer.vehId)
    phase.completed = true
  end
end

local function emergencyStop(phase, racer, dtSim)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end
  if phase.completed then return end
  if racer.vehicleRemoved or not racer.vehId then return end

  local vehObj = scenetree.findObjectById(racer.vehId)
  if not vehObj then return end
  racer.vehObj = vehObj

  if not racer.isPlayable then
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        racer.vehObj:queueLuaCommand('electrics.values.throttleOverride = nil')
        racer.vehObj:queueLuaCommand('if electrics.values.jatoInput then electrics.values.jatoInput = 0 end')

        racer.vehObj:queueLuaCommand([[
          local nc = controller.getController("nitrousOxideInjection")
          if nc then
            local engine = powertrain.getDevice("mainEngine")
            if engine and engine.nitrousOxideInjection and engine.nitrousOxideInjection.isArmed then
              nc.toggleActive()
            end
          end
        ]])

        racer.vehObj:queueLuaCommand('ai.setSpeedMode("set")')
        racer.vehObj:queueLuaCommand('ai.setSpeed(0)')

        phase.started = true
      end
    end
  else
    if not phase.started then
      phase.timerOffset = phase.timerOffset + dtSim

      if phase.timerOffset >= phase.startedOffset then
        phase.started = true
      end
    end
  end

  if racer.vehSpeed <= 0.01 then
    phase.completed = true
  end
end

local function updateRacer(racer)
  local dragData = gameplay_drag_core.getData()
  if not dragData then return end

  if not racer then return end
  if racer.vehicleRemoved or not racer.vehId or racer.vehId < 0 then return end

  local vehObj = scenetree.findObjectById(racer.vehId)
  if not vehObj then
    racer.isValid = false
    return
  end
  racer.vehObj = vehObj

  if not racer.vehPos then racer.vehPos = vec3() end
  if not racer.vehDirectionVector then racer.vehDirectionVector = vec3() end
  if not racer.vehDirectionVectorUp then racer.vehDirectionVectorUp = vec3() end
  if not racer.vehVelocity then racer.vehVelocity = vec3() end

  racer.vehPos:set(racer.vehObj:getPositionXYZ())
  racer.vehDirectionVector:set(racer.vehObj:getDirectionVectorXYZ())
  racer.vehDirectionVectorUp:set(racer.vehObj:getDirectionVectorUpXYZ())
  racer.vehRot = quatFromDir(racer.vehDirectionVector, racer.vehDirectionVectorUp)

  racer.vehVelocity:set(racer.vehObj:getVelocityXYZ())
  racer.prevSpeed = racer.vehSpeed or 0
  racer.vehSpeed = racer.vehVelocity:length()

  if not dragData.strip or not dragData.strip.lanes or not dragData.strip.lanes[racer.lane] then
    return
  end

  local stageToEndNorm = dragData.strip.lanes[racer.lane].stageToEndNormalized

  if not racer.allWheelsOffsets then
    racer.allWheelsOffsets = {}
  end
  if not racer.wheelsCenter then
    racer.wheelsCenter = {}
  end

  for k, offset in pairs(racer.allWheelsOffsets) do
    if not racer.wheelsCenter[k] then
      racer.wheelsCenter[k] = {
        pos = vec3(),
        wheelCountInv = 1/#offset
      }
    end
    racer.wheelsCenter[k].pos:set(0, 0, 0)
    for _, wheel in ipairs(offset) do
      racer.wheelsCenter[k].pos:setAdd(racer.vehRot * wheel)
    end
    racer.wheelsCenter[k].pos:setScaled(racer.wheelsCenter[k].wheelCountInv)
    racer.wheelsCenter[k].pos:setAdd(racer.vehPos)
  end

  calculateDistanceOfAllWheelsFromStagePos(racer)

  if not racer.beamState then
    racer.beamState = {}
  end

  local inLane = isRacerInsideBoundary(racer)
  for k, distVec in pairs(racer._wheelDistances or {}) do
    if not racer.beamState[k] then
      racer.beamState[k] = {preStage = false, stage = false}
    end
    processTreeLights(racer, k, distVec:dot(stageToEndNorm), inLane)
  end

  racer.currentDistanceFromOrigin = getFrontWheelDistanceFromStagePos(racer)
  racer.previousDistanceFromOrigin = racer.currentDistanceFromOrigin or 0
end

local function setDialsData(data)
  local count = #data

  if count == 1 then
    dialsData[data[1].vehId] = 0
    return
  end

  if count == 2 then
    local dial1, dial2 = data[1].dial, data[2].dial
    local diff = math.abs(dial1 - dial2)

    local offset1, offset2 = (dial1 < dial2) and diff or 0, (dial1 > dial2) and diff or 0

    dialsData[data[1].vehId] = offset1
    dialsData[data[2].vehId] = offset2
    return
  end

  for _, value in ipairs(data) do
    dialsData[value.vehId] = value.dial
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.getFrontWheelDistanceFromStagePos = getFrontWheelDistanceFromStagePos
M.calculateDistanceOfAllWheelsFromStagePos = calculateDistanceOfAllWheelsFromStagePos
M.isRacerInsideBoundary = isRacerInsideBoundary
M.getImportantTimerValueForWin = getImportantTimerValueForWin
M.generateWinData = generateWinData
M.changeRacerPhase = changeRacerPhase
M.changeAllPhases = changeAllPhases
M.clearRacerTransitionLock = clearRacerTransitionLock
M.setPhaseTransitionAbort = setPhaseTransitionAbort
M.areAllRacersStaged = areAllRacersStaged
M.setRemoteStagingState = setRemoteStagingState
M.updateRemoteStagingHoldTimers = updateRemoteStagingHoldTimers
M.clearRemoteStagingHoldTimers = clearRemoteStagingHoldTimers
M.startRaceFromTree = startRaceFromTree
M.stage = stage
M.countdown = countdown
M.race = race
M.stop = stop
M.emergencyStop = emergencyStop
M.updateRacer = updateRacer
M.setDialsData = setDialsData
M.checkFreeroamDqReStage = checkFreeroamDqReStage
M.clearDqRestageState = clearDqRestageState
M.disqualifyRacer = disqualifyRacer
M.onDragClear = function()
  clearRemoteStagingHoldTimers()
  clearDqRestageState()
end

return M