-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Automatically stops and holds the vehicle after a detected crash

local M = {}
M.type = "auxiliary"
M.defaultOrder = 700

local abs = math.abs

local state = "idle"
local brakeThreshold = 0
local crashCounter = 0
local crashCountThreshold = 0
local lastThrottle = 0

local validStates = {
  idle = true,
  braking = true,
  holding = true,
  disabled = true
}

local stateData
local stateDataNameState
local stateDataNameCrashCounter

local function updateGFX(dt)
  if state == "idle" then
    --we specifically DO care for the sign of Z here to avoid false trigges on jumps and heavy compressions
    if (abs(sensors.gx2) > brakeThreshold or abs(sensors.gy2) > brakeThreshold) or ((sensors.gz2 - powertrain.currentGravity) > brakeThreshold) then
      -- print(abs(sensors.gx2))
      -- print(abs(sensors.gy2))
      -- print((sensors.gz2))
      -- print("---")
      state = "braking"
      crashCounter = crashCounter + 1
      electrics.set_warn_signal(true)
      guihooks.messageForSeatedPlayers("vehicle.postCrashBrake.impact", 10, "vehicle.postCrashBrake.impact")
      electrics.values.postCrashBrakeTriggered = 1
    end
  elseif state == "braking" then
    electrics.values.brake = 1
    electrics.values.throttle = 0
    input.event("throttle", 0, 0)

    if abs(electrics.values.wheelspeed) < 0.5 or electrics.values.gearIndex < 0 then
      input.event("parkingbrake", 1, 0)
      state = "holding"
      lastThrottle = input.throttle
    end
  elseif state == "holding" then
    electrics.values.brake = 1
    if input.throttle > lastThrottle * 1.1 or abs(electrics.values.wheelspeed) > 5 then
      input.event("parkingbrake", 0, 0)
      electrics.set_warn_signal(false)
      electrics.values.postCrashBrakeTriggered = nil
      state = crashCounter <= crashCountThreshold and "idle" or "disabled"
    end
    lastThrottle = input.throttle
  end
end

local function applyRemotePostCrashState(newState)
  local wasActive = state == "braking" or state == "holding"
  state = newState

  if state == "braking" or state == "holding" then
    electrics.set_warn_signal(true)
    electrics.values.postCrashBrakeTriggered = 1
    if state == "holding" then
      input.event("parkingbrake", 1, 0)
      lastThrottle = input.throttle
    end
  elseif wasActive then
    input.event("parkingbrake", 0, 0)
    electrics.set_warn_signal(false)
    electrics.values.postCrashBrakeTriggered = nil
  end
end

local function init(jbeamData)
  stateData = {}
  stateDataNameState = M.name .. "_state"
  stateDataNameCrashCounter = M.name .. "_crashCounter"

  --if the hazards are still active from before reset, deactivate them
  if state == "holding" or state == "braking" then
    electrics.set_warn_signal(false)
  end

  electrics.values.postCrashBrakeTriggered = nil

  state = "idle"
  crashCounter = 0
  lastThrottle = 0
  brakeThreshold = jbeamData.brakeThreshold or 50 --m/s²
  crashCountThreshold = jbeamData.crashCountThreshold or 3
end

local function getState()
  stateData[stateDataNameState] = state
  stateData[stateDataNameCrashCounter] = crashCounter
  return stateData
end

local function setState(data)
  if not data then
    return
  end

  local newCrashCounter = data[stateDataNameCrashCounter]
  if type(newCrashCounter) == "number" and newCrashCounter == newCrashCounter and newCrashCounter >= 0 and newCrashCounter % 1 == 0 then
    crashCounter = newCrashCounter
  end

  local newState = data[stateDataNameState]
  if validStates[newState] and newState ~= state then
    applyRemotePostCrashState(newState)
  end
end

M.init = init
M.updateGFX = updateGFX

M.getState = getState
M.setState = setState

return M
