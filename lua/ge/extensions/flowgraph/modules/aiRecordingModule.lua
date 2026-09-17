-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt
local C = {}
C.moduleOrder = 1 -- after missionReplayModule
C.hooks = {"onVehicleSubmitRecordingForMission"}

local enabled = false
local vehicleStates = {}

function C:init()
end

function C:executionStopped()
  self:stopAiRecording()
end

function C:executionStarted()
  -- AI recording setup if needed
  if parseArgs and parseArgs.args and parseArgs.args.enableAiRecordingForMissions == true then
    enabled = true
  end
  if self.mgr.activity and self.mgr.activity.startingOptions and self.mgr.activity.startingOptions.aiPath then
    enabled = true
    print("ai recording enabled for mission")
  end
end
local lastAttempt = nil
local lastTotalChange = nil
function C:stopAiRecording(attempt, totalChange)
  lastAttempt = attempt
  lastTotalChange = totalChange
  if enabled then
    local veh = getPlayerVehicle(0)
    if not veh then return end

    print("stopping the ai recording")
    if vehicleStates[veh:getId()] == 'recording' then
      -- schedule the recording to be stopped and be sent from the vehicle to this module
      veh:queueLuaCommand('obj:queueGameEngineLua("extensions.hook(\\"onVehicleSubmitRecordingForMission\\","..tostring(objectId)..","..serialize(ai.stopRecording())..")")')
    end
  end
end

function C:stopAiReplay()
  if enabled then
    local veh = getPlayerVehicle(0)
    if not veh then return end

    if self.mgr.activity and self.mgr.activity.startingOptions and self.mgr.activity.startingOptions.aiPath then
      print("stopping the ai replay")
      veh:queueLuaCommand('ai:scriptStop(false, false)')
    end
  end
end

function C:onVehicleSubmitRecordingForMission(vehId, aiPath)
  if not vehicleStates[vehId] then return end
  vehicleStates[vehId] = nil
  local mission = self.mgr.activity
  local dir = mission.missionFolder.."/tests/"
  local fn = string.format("recording_%s.missionTestData.json", os.date("%Y-%m-%d %H_%M_%S"))
  print("Saving script AI recording to "..dir..fn)
  local veh = getObjectByID(vehId)

  local vData = {
    model = veh.jbeam,
    config = veh.partConfig,
    isConfigFile = string.endswith(veh.partConfig,'.pc'),
    licensePlate = veh:getDynDataFieldbyName("licenseText", 0) or "",
  }

  local aiDuration = aiPath.path[#aiPath.path].t

  local testData = {
    aiPath = aiPath,
    userSettings = mission.lastUserSettings,
    vehicle = vData,
    attemptStars = lastTotalChange.unlockedStarsAttempt,
    attemptData = lastAttempt.data,
    attemptStars = lastAttempt.unlockedStars,
    aiDuration = aiDuration,
  }
  jsonWriteFile(dir..fn, testData, true)
end

function C:startAiRecording()
  if enabled then
    print("Starting the ai recording")
    local veh = getPlayerVehicle(0)
    if not veh then return end
    vehicleStates[veh:getId()] = 'recording'
    veh:queueLuaCommand('ai.startRecording()')
  end
end

function C:startAiReplay()
  if enabled then
    if self.mgr.activity and self.mgr.activity.startingOptions and self.mgr.activity.startingOptions.aiPath then
      print("Starting the ai replay")
      local veh = getPlayerVehicle(0)
      if not veh then return end
      vehicleStates[veh:getId()] = 'recording'
      veh:queueLuaCommand('ai.startFollowing('..serialize(self.mgr.activity.startingOptions.aiPath)..', nil, nil, "noReset", true)')
    end
  end
end

function C:setenabled(newEnabled)
  enabled = newEnabled
end

function C:isRecordingScriptAi()
  return enabled
end

function C:getVehicleStates()
  return vehicleStates
end

return _flowgraph_createModule(C)
