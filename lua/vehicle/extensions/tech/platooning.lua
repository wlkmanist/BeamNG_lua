-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local state
local lastSpeed
local filteredLongAccel = 0.0
local lastKinematicsVersion
local lastKinematicsTime = 0.0
local staleKinematicsFrames = 0
local lostTrackNotified = false

local kinematicsTimeout = 0.5
local maxStaleKinematicsFrames = 5
local targetSpeedMargin = 5.0
local leaderAccMode = 3
local aiModes = {[0] = "manual", [1] = "span", [2] = "traffic"}

local function horizSpeed(v)
  return math.sqrt(square(v.x) + square(v.y))
end

local function clearFollowerControl(keepAcc)
  extensions.tech_ACC.setDriverOverrideCallback(nil)
  if not keepAcc then
    extensions.tech_ACC.unload()
  end
  extensions.tech_ACC.clearExternalLeader()
end

local function unload()
  state = nil
  lastKinematicsVersion = nil
  lastKinematicsTime = 0.0
  staleKinematicsFrames = 0
  lostTrackNotified = false
  clearFollowerControl()
  ai.setMode("manual")
end

local function leave()
  if not state or not state.platoonId or not state.selfId then
    return
  end

  obj:queueGameEngineLua(string.format(
    "extensions.tech_platooning.leave(%d, %d)",
    state.platoonId,
    state.selfId
  ))
  unload()
end

local function publishKinematics(dtSim)
  if not state then
    return
  end

  local speed = horizSpeed(obj:getVelocity())
  local rawAccel = lastSpeed and (speed - lastSpeed) / math.max(1e-4, dtSim) or 0.0
  filteredLongAccel = lerp(filteredLongAccel, rawAccel, dtSim / (0.2 + dtSim))
  lastSpeed = speed

  obj:queueGameEngineLua(string.format(
    "extensions.tech_platooning.updateVehicleKinematics(%d, %q)",
    state.selfId,
    lpack.encode({speed = speed, longAccel = filteredLongAccel})
  ))
end

local function readPredecessorKinematics()
  if not state or not state.predecessorId then
    return nil
  end

  local mailboxName = "platoonKin_" .. tostring(state.predecessorId)
  local version = obj:getLastMailboxVersion(mailboxName)
  if version and version ~= lastKinematicsVersion then
    lastKinematicsVersion = version
    lastKinematicsTime = obj:getSimTime()
    staleKinematicsFrames = 0
    lostTrackNotified = false
    return lpack.decode(obj:getLastMailbox(mailboxName))
  end

  if obj:getSimTime() - lastKinematicsTime > kinematicsTimeout then
    staleKinematicsFrames = staleKinematicsFrames + 1
  end
  return nil
end

local function notifyLostTrack()
  if lostTrackNotified or not state or not state.platoonId or not state.selfId then
    return
  end

  lostTrackNotified = true
  obj:queueGameEngineLua(string.format(
    "extensions.tech_platooning.onVehicleLostTrack(%d, %d)",
    state.platoonId,
    state.selfId
  ))
end

local function launchLeader(leaderMode, speed)
  if leaderMode == leaderAccMode then
    ai.setMode("manual")
    extensions.tech_ACC.setLeaderMode("auto")
    extensions.tech_ACC.load(speed or 0.0)
    return
  end

  ai.setMode(aiModes[leaderMode] or "manual")
  ai.setSpeedMode("limit")
  ai.setSpeed(speed or 0.0)
  ai.setAggression(0.2)
  ai.driveInLane("on")
end

local function applyState(nextState)
  state = nextState
  staleKinematicsFrames = 0
  lostTrackNotified = false

  if not state then
    unload()
    return
  end

  if state.role == "follower" then
    extensions.tech_ACC.setLeaderMode("external")
    extensions.tech_ACC.setDriverOverrideCallback(leave)
    extensions.tech_ACC.load(targetSpeedMargin)
    ai.setTargetObjectID(state.predecessorId)
    ai.setMode("follow")
    ai.driveInLane("on")
  else
    clearFollowerControl(state.launched and state.leaderMode == leaderAccMode)
    if state.launched then
      launchLeader(state.leaderMode, state.commandedSpeed)
    else
      ai.setMode("manual")
    end
  end
end

local function updateGFX(dtSim)
  publishKinematics(dtSim)

  if not state or state.role ~= "follower" then
    return
  end

  local kinematics = readPredecessorKinematics()
  if kinematics then
    local leadSpeed = kinematics.speed
    extensions.tech_ACC.changeSpeed(leadSpeed + targetSpeedMargin)
    extensions.tech_ACC.setExternalLeader(state.predecessorId, leadSpeed, kinematics.longAccel)
    return
  end

  if staleKinematicsFrames > maxStaleKinematicsFrames then
    notifyLostTrack()
  end
end

M.updateGFX = updateGFX
M.onState = function(payload) applyState(lpack.decode(payload)) end
M.unload = unload
M.onUnload = unload

return M
