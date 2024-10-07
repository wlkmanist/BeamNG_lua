-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local logTag = ""
local startTimers = false
local dragData

local function clear()
  startTimers = false
end

local function onExtensionLoaded()
  if gameplay_drag_general then
    dragData = gameplay_drag_general.getData()
  end
  M.reset()
end

local function reset()
  -- TODO: this is dupliced in general.lua?
  if not dragData or not dragData.racers then return end
  log("I", logTag, "Resetting timers for "..#dragData.racers.." racers")
  for _, racer in pairs(dragData.racers) do
    if not racer.timers then
      --The value of the timers are in seconds, the distance is in meters
      racer.timers = {
        dial = {type = "timer", value = 0},
        timer = {type = "timer", value = 0},
        reactionTime = {type = "reactionTimer", value = 0, distance = 0.2, isSet = false, label = "Reaction Time"},
        time_60 = {type = "distanceTimer", value = 0, distance = 18.288, isSet = false, label = "Distance: 60ft / 18.28m"},
        time_330 = {type = "distanceTimer", value = 0, distance = 100.584, isSet = false, label = "Distance: 330ft / 100.58m"},
        time_1_8 = {type = "distanceTimer", value = 0, distance = 201.168, isSet = false, label = "Distance: 1/8th mile / 201.16m"},
        time_1000 = {type = "distanceTimer", value = 0, distance = 304.8, isSet = false, label = "Distance: 1000ft / 304.8m"},
        time_1_4 = {type = "distanceTimer", value = 0, distance = 402.336, isSet = false, label = "Distance: 1/4th mile / 402.34m"},
        velAt_1_8 = {type = "velocity", value = 0, distance = 201.168, isSet = false, label = "Distance: 1/8th mile / 201.16m"},
        velAt_1_4 = {type = "velocity", value = 0, distance = 402.336, isSet = false, label = "Distance: 1/4th mile / 402.34m"}
      }
    else
      for timerId,t in pairs(racer.timers) do
        t.value = 0
        t.isSet = false
      end
    end
  end
  startTimers = false
end
M.reset = reset


local function velocityInAllUnits(speed)
  return string.format("%0.2fmph | %0.2fkm/h", speed * 2.23694, speed * 3.6)
end

local function onUpdate(dtReal, dtSim, dtRaw)
  if not dragData or not dragData.racers then return end
  if startTimers and not dragData.isCompleted then
    for vehId, racer in pairs(dragData.racers) do

      -- update times
      local prevTime = racer.timers.timer.value
      local auxTimer = racer.timers.timer.value + dtSim
      racer.timers.timer.value = auxTimer

      -- get current distance
      local distanceFromOrigin = gameplay_drag_utils.calculateDistanceFromStagePos(racer)
      racer.previousDistanceFromOrigin = racer.previousDistanceFromOrigin or distanceFromOrigin

      -- reaction time
      if not racer.timers.reactionTime.isSet then
        if distanceFromOrigin >= racer.timers.reactionTime.distance then
          -- figure out when exactly the player crossed the reactionTime.distance
          -- t gives us the normalized value where 0.4 lies on the distance the player traveled this frame
          local t = inverseLerp(racer.previousDistanceFromOrigin, distanceFromOrigin, racer.timers.reactionTime.distance)
          -- then we can use that to find the time when it was crossed
          local time = t * dtSim
          -- so reaction time is some time between this frame and last
          racer.timers.reactionTime.value = prevTime + time
          -- and the current time is set so that that part of the frame is already "elapsed"
          racer.timers.timer.value = time

          racer.timers.reactionTime.isSet = true

          log('I', logTag, string.format("Racer %d (Lane %d) reaction time: %0.3fs", racer.vehId, racer.lane, racer.timers.reactionTime.value))
        end
      end

      -- all the other timers
      if racer.timers.reactionTime.isSet then
        for timerKey, timer in pairs(racer.timers) do
          if timer.distance and not timer.isSet and distanceFromOrigin >= timer.distance then
            local t = inverseLerp(racer.previousDistanceFromOrigin, distanceFromOrigin, timer.distance)
            if timer.type == "distanceTimer" then
              -- same thing as for reaction time
              timer.value = prevTime + t*dtSim
              timer.isSet = true
              log('I', logTag, string.format("Racer %d (Lane %d) took %0.3fs to reach %s", racer.vehId, racer.lane, timer.value, timer.label))
            end
            if timer.type == "velocity" then
              -- similar thing, but then interpolating the time once we have the normalized distance
              timer.value = lerp(dragData.racers[vehId].prevSpeed, dragData.racers[vehId].vehSpeed, t)
              timer.isSet = true
              log('I', logTag, string.format("Racer %d (Lane %d) velocity is %s at %s", racer.vehId, racer.lane, velocityInAllUnits(timer.value), timer.label))
            end
          end
        end
      end

      -- store the current distance for next frame
      racer.previousDistanceFromOrigin = distanceFromOrigin
    end
  end
end

local function preStageStarted()
  --reset()
end

local function dragRaceStarted()
  startTimers = true
end

local function resetDragRaceValues()
  reset()
end

--HOOKS
M.preStageStarted = preStageStarted
M.dragRaceStarted = dragRaceStarted
M.resetDragRaceValues = resetDragRaceValues

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
return M