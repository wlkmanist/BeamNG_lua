-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local minDistance = 0.8 --m
local minVelToStop = 15 --m/s

local dragData
local logTag = ""

local tmp = vec3()
local function calculateDistanceFromStagePos(racer)
  dragData = gameplay_drag_general.getData()
  tmp:set(racer.frontWheelCenter)
  tmp:setSub(dragData.strip.lanes[racer.lane].waypoints.stage.transform.pos)
  return tmp:dot(dragData.strip.lanes[racer.lane].stageToEndNormalized)
end
M.calculateDistanceFromStagePos = calculateDistanceFromStagePos

local function areFrontWheelsParallelToLine(racer, lineTransform)
  if not lineTransform then
    log('E', logTag, 'Invalid line definition.')
    return false
  end

  -- Check if the two directions are parallel by comparing their dot product
  local dotProduct = racer.vehDirectionVector:dot(lineTransform.y)
  local tolerance = 0.70
  return math.abs(dotProduct) >= tolerance
end

local function isRacerInsideBoundary(racer)
  dragData = gameplay_drag_general.getData()
  local playerLane = racer.lane
  if not playerLane or not dragData.strip.lanes[playerLane] then
    log('E', logTag, 'No valid lane found for racer: ' .. racer.vehId)
    return false
  end

  local boundary = dragData.strip.lanes[playerLane].boundary.transform
  if not boundary or type(boundary) ~= "table" then
    log('E', logTag, 'No valid boundary found for racer: ' .. racer.vehId)
    return false
  end
  local x, y, z = boundary.rot * vec3(boundary.scl.x,0,0), boundary.rot * vec3(0,boundary.scl.y,0), boundary.rot * vec3(0,0,boundary.scl.z)
  return containsOBB_point(boundary.pos, x, y, z, racer.vehPos )
end
M.isRacerInsideBoundary = isRacerInsideBoundary

local function stopAiVehicle(racer)
  local veh = scenetree.findObjectById(racer.vehId)
  if veh then
    veh:queueLuaCommand('ai.setTarget("drag_stop")')
    veh:queueLuaCommand('ai:scriptStop('..tostring(true)..','..tostring(true)..')')
    log('I', logTag, 'AI stopped on vehicle: ', racer.vehId)
  end
end

-- -----------------
--PUBLIC FUNCTIONS--
-- -----------------

--This is called from the dragRace/display.lua once the christmasTree is finished or any other system determine that the race must start
M.startRaceFromTree = function(vehId)
  dragData = gameplay_drag_general.getData()
  if not dragData then return end
  dragData.racers[vehId].phases[dragData.racers[vehId].currentPhase].completed = true
end

M.stage = function(phase, racer, dtSim)
  dragData = gameplay_drag_general.getData()
  if not dragData then log('E', logTag, 'No drag data aviable, stopping phase') return end

  if not phase.completed then
    local distance = calculateDistanceFromStagePos(racer)
    if not distance then --If there is no distance return the next frame
      log("E", logTag, 'No distance found')
      return
    end
    if not racer.isPlayable then
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          phase.started = true
          racer.vehObj = scenetree.findObjectById(racer.vehId)
          racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
          racer.vehObj:queueLuaCommand('ai.setSpeedMode("' .. dragData.strip.lanes[racer.lane].waypoints.stage.waypoint.mode .. '")')
          racer.vehObj:queueLuaCommand('controller.setFreeze(0)')
          racer.vehObj:queueLuaCommand([[
            local nc = controller.getController("nitrousOxideInjection")
            if nc then
              local engine = powertrain.getDevice("mainEngine")
              if engine and engine.nitrousOxideInjection and not engine.nitrousOxideInjection.isArmed then
                nc.toggleActive()
              end
            end]])
          racer.vehObj:queueLuaCommand('ai.setSpeed('.. (dragData.strip.lanes[racer.lane].waypoints.stage.waypoint.speed - (distance/4)) ..')')
          racer.vehObj:queueLuaCommand('ai.setTarget("'..dragData.strip.lanes[racer.lane].waypoints.endLine.name..'")')
          extensions.hook("stageStarted")
          log('I', logTag, racer.vehId .. " started stage " .. " command sended" ..dragData.strip.lanes[racer.lane].waypoints.stage.name)
        end
      end
      if distance > -5 and distance < -0.178 then
        racer.vehObj:queueLuaCommand('ai.setSpeedMode("' .. dragData.strip.lanes[racer.lane].waypoints.stage.waypoint.mode .. '")')
        racer.vehObj:queueLuaCommand('ai.setSpeed('.. (dragData.strip.lanes[racer.lane].waypoints.stage.waypoint.speed) ..')')
      elseif distance > -0.178 and distance < -0.05 then
        extensions.hook("preStageEnded", racer.vehId)
        log('I', logTag, racer.vehId .. " completed prestage")
      elseif distance > -0.05 then
        phase.completed = true
        stopAiVehicle(racer)
        extensions.hook("stageEnded", racer.vehId)
        log('I', logTag, "Stage completed for vehicle: " .. racer.vehId)
        return
      end
    else
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          phase.started = true
          extensions.hook("stageStarted")
          log('I', logTag, racer.vehId .. " started stage" )
        end
      end
      if distance < -0.278 then
        extensions.hook("preStageStarted", racer.vehId)
        phase.completeTimer = 0
      elseif distance >= -0.278 and distance <= -0.1 then
        extensions.hook("preStageEnded", racer.vehId)
        phase.completeTimer = 0
      elseif distance > 0 and distance <= 0.1 and areFrontWheelsParallelToLine(racer, dragData.strip.lanes[racer.lane].waypoints.stage.transform) then
        extensions.hook("dragRaceStageEndedDeep", racer.vehId)
        phase.completeTimer = (phase.completeTimer or 0) + dtSim
        if phase.completeTimer > 1 then
          phase.completed = true
          log('I', logTag, "Stage completed for vehicle: " .. racer.vehId)
          return
        end
      elseif distance > 0.1 then
        extensions.hook("dragRaceOutForward", racer.vehId)
        phase.completeTimer = 0
      elseif areFrontWheelsParallelToLine(racer, dragData.strip.lanes[racer.lane].waypoints.stage.transform) then
        extensions.hook("stageEnded", racer.vehId)
        phase.completeTimer = (phase.completeTimer or 0) + dtSim
        gameplay_drag_general.clearTimeslip()

        if phase.completeTimer > 1 then
          phase.completed = true
          log('I', logTag, "Stage completed for vehicle: " .. racer.vehId)
          return
        end
      else
        extensions.hook("dragRaceOutParallel", racer.vehId)
        phase.completeTimer = 0
      end
    end
  end
end

M.countdown = function(phase, racer, dtSim)
  dragData = gameplay_drag_general.getData()
  if not dragData then log('E', logTag, 'No drag data aviable, stopping phase') return end

  if not phase.completed then
    local distance = calculateDistanceFromStagePos(racer)
    if not distance then --If there is no distance return the next frame
      log("E", logTag, 'No distance found, returning nil')
      return
    end
    if not racer.isPlayable then
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          racer.vehObj = scenetree.findObjectById(racer.vehId)
          racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
          racer.vehObj:queueLuaCommand([[
            local ts = controller.getController("twoStep")
            if ts then
              ts.toggleTwoStep()
            end]])
            racer.vehObj:queueLuaCommand('if electrics.values.jatoInput then electrics.values.jatoInput = 1 end')
            racer.vehObj:queueLuaCommand([[
            local tb = controller.getController("transbrake")
            if tb then
              tb.setTransbrake(true)
            end]])
            racer.vehObj:queueLuaCommand('controller.setFreeze(1)')
            racer.vehObj:queueLuaCommand('ai.setSpeed('.. dragData.strip.lanes[racer.lane].waypoints.endLine.waypoint.speed ..')')
            racer.vehObj:queueLuaCommand('ai.setTarget("'..dragData.strip.lanes[racer.lane].waypoints.endLine.name..'")')
          extensions.hook("startDragCountdown")
          phase.started = true
          log('I', logTag, 'Starting countdown for '..racer.vehId)
        end
      end
    else
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          extensions.hook("startDragCountdown")
          phase.started = true
          log('I', logTag, 'Starting countdown for '..racer.vehId)
        end
      end
    end
    --Determines if the vehicle moved too much during the tree lights countdown.
    if distance < -0.2 or distance > 0.2 then
      racer.isDesqualified = true
      racer.desqualifiedReason = "missions.dragRace.gameplay.disqualified.jumping"
      extensions.hook("jumpDescualifiedDrag", racer.vehId)
      log('I', logTag, 'Desqualifying '..racer.vehId)
    end
  end
end

M.race = function(phase, racer, dtSim)
  dragData = gameplay_drag_general.getData()
  if not dragData then log('E', logTag, 'No drag data aviable, stopping phase') return end

  if not phase.completed then
    if not racer.isPlayable then
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          racer.vehObj = scenetree.findObjectById(racer.vehId)
          racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
          racer.vehObj:queueLuaCommand('ai.setAggression(2)')
          racer.vehObj:queueLuaCommand('controller.setFreeze(0)')
          racer.vehObj:queueLuaCommand('ai.setSpeedMode("' .. dragData.strip.lanes[racer.lane].waypoints.endLine.waypoint.mode .. '")')
          --veh:queueLuaCommand('ai.setSpeed('.. dragData.strip.lanes[racer.lane].waypoints.endLine.waypoint.wpSpeed ..')')
          racer.vehObj:queueLuaCommand([[
            local ts = controller.getController("twoStep")
            if ts then
              ts.toggleTwoStep()
            end]])
          racer.vehObj:queueLuaCommand([[
            local tb = controller.getController("transbrake")
            if tb then
              tb.setTransbrake(false)
            end]])
          racer.vehObj:queueLuaCommand('ai.setTarget("'..dragData.strip.lanes[racer.lane].waypoints.endLine.name..'")')
          phase.started = true
          extensions.hook("dragRaceStarted")
          log('I', logTag, 'Starting Phase '..phase.name..' for '..racer.vehId)
        end
      end

    else
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          phase.started = true
          extensions.hook("dragRaceStarted")
          log('I', logTag, 'Starting Phase '..phase.name..' for '..racer.vehId)
        end
      end
    end
    if racer.timers.time_1_4.isSet then
      phase.completed = true
      extensions.hook("dragRaceEndLineReached", racer.vehId)
      log('I', logTag, 'Completed Phase '..phase.name..' for '..racer.vehId)
      if not gameplay_missions_missionManager.getForegroundMissionId() then
        gameplay_drag_general.sendTimeslipDataToUi()
      end
      return
    else
      if not isRacerInsideBoundary(racer) then
        racer.isDesqualified = true
        racer.desqualifiedReason = "missions.dragRace.gameplay.disqualified.outOfLane"
        extensions.hook("jumpDescualifiedDrag", racer.vehId)
      end
      local distance = calculateDistanceFromStagePos(racer)
      if distance < -0.33 then
        racer.isDesqualified = true
        racer.desqualifiedReason = "missions.dragRace.gameplay.disqualified.outOfLane"
        extensions.hook("jumpDescualifiedDrag", racer.vehId)
      end
    end
  end
end

M.stop =  function(phase, racer, dtSim)
  dragData = gameplay_drag_general.getData()
  if not dragData then log('E', logTag, 'No drag data aviable, stopping phase') return end

  if not phase.completed then
    if not racer.isPlayable then
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          racer.vehObj = scenetree.findObjectById(racer.vehId)
          racer.vehObj:queueLuaCommand('ai.setState({mode = "manual"})')
          racer.vehObj:queueLuaCommand('ai.setAggression(0.1)')
          racer.vehObj:queueLuaCommand('if electrics.values.jatoInput then electrics.values.jatoInput = 0 end')
          racer.vehObj:queueLuaCommand([[local nc = controller.getController("nitrousOxideInjection")
          if nc then
            local engine = powertrain.getDevice("mainEngine")
            if engine and engine.nitrousOxideInjection and engine.nitrousOxideInjection.isArmed then
              nc.toggleActive()
            end
          end]])
          racer.vehObj:queueLuaCommand('ai.setSpeedMode("' .. dragData.strip.lanes[racer.lane].waypoints.spawn.waypoint.mode .. '")')
          racer.vehObj:queueLuaCommand('ai.setSpeed('.. (minVelToStop/2) ..')')
          racer.vehObj:queueLuaCommand('ai.setTarget("drag_stop")')
          phase.started = true
          extensions.hook("stoppingVehicleDrag", racer.vehId)
        end
      end
    else
      if not phase.started then
        local timer = phase.timerOffset + dtSim
        phase.timerOffset = timer
        if  phase.timerOffset >= phase.startedOffset then
          phase.started = true
          extensions.hook("stoppingVehicleDrag", racer.vehId)
        end
      end
    end
    if racer.vehSpeed <= minVelToStop then
      extensions.hook("dragRaceVehicleStopped", racer.vehId)
      phase.completed = true
      log('I', logTag, 'Completed Phase '..phase.name..' for '..racer.vehId)
    end
  end
end

-- local function returnToStart(racer.vehId)
--   if not phase.completed  then
--     if racer.canBeTeleported then
--       if racer.canBeReseted then
--         spawn.safeTeleport(veh, dragData.strip.lanes[racer.lane].spawn.transform.pos, dragData.strip.lanes[racer.lane].spawn.transform.rot, nil, nil, nil, true)
--         phase.completed = true
--         log('I', logTag, 'Completed Phase '..phase.name..' for '..racer.vehId)
--         extensions.hook("dragRaceReturnCompleted", racer.vehId)
--       else
--         spawn.safeTeleport(veh, dragData.strip.lanes[racer.lane].spawn.transform.pos, dragData.strip.lanes[racer.lane].spawn.transform.rot, nil, nil, nil, false)
--         phase.completed = true
--         log('I', logTag, 'Completed Phase '..phase.name..' for '..racer.vehId)
--         extensions.hook("dragRaceReturnCompleted", racer.vehId)
--       end
--     else
--       local distanceToSpawn = calculateDistance(racer.vehId, dragData.strip.lanes[racer.lane].spawn.transform.pos)
--       if not racer.isPlayale and not phase.started then
--         log('E', logTag, 'Vehicle '.. racer.vehId ..' cannot be teleported back to start! The AI will drive back to the start')
--         veh:queueLuaCommand('ai.setState({mode = "manual"})')
--         --dump(tostring(dragData.strip.returnWaypoints))
--         veh:queueLuaCommand('ai.driveUsingPath{ wpTargetList = ' .. tostring(dragData.strip.returnWaypoints) .. ', driveInLane = on, avoidCars = on, routeSpeed = '..dragData.strip.lanes[racer.lane].spawn.waypoint.wpSpeed..', routeSpeedMode = mode, aggression = 0.3}')
--         phase.started = true
--       end

--       if distanceToSpawn < 10 then
--         phase.completed = true

--         extensions.hook("dragRaceReturnCompleted", racer.vehId)
--       end
--     end
--   end
-- end

M.updateRacer = function(racer)
  local veh = scenetree.findObjectById(racer.vehId)
  racer.vehPos:set(veh:getPositionXYZ())
  racer.vehDirectionVector:set(veh:getDirectionVectorXYZ())
  racer.vehDirectionVectorUp:set( veh:getDirectionVectorUpXYZ())
  -- todo: optimize...
  racer.vehRot = quatFromDir(racer.vehDirectionVector, racer.vehDirectionVectorUp)

  racer.vehVelocity:set(veh:getVelocityXYZ())
  racer.prevSpeed = racer.vehSpeed
  racer.vehSpeed = racer.vehVelocity:length()

  -- front wheelcenter
  racer.frontWheelCenter:set(0,0,0)
  for _, offset in ipairs(racer.wheelsOffsets) do
    racer.frontWheelCenter:setAdd(racer.vehRot*offset)
  end
  racer.frontWheelCenter:setScaled(racer.wheelCountInv)
  racer.frontWheelCenter:setAdd(racer.vehPos)
end

return M