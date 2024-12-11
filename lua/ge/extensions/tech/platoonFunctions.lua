-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


local M = {}

local vid
local sensorId
local sensorIdRadar
local WIDTH = 100
local HEIGHT = 100
local resolution = {WIDTH, HEIGHT}
local targetSpeed
local data
local debug
local prevDistanceToCars = {}
local prevSpeed
local prevSpeed2
local prevDistanceToCars2 = {}
local zeroSpeed = 0
local speedcalc = 0
local vehicleID
local noCars
local vehiclesData= {}
local launched = false
local platoonArch = require('ge\\extensions\\tech\\PlatoonArch')
-- local platoonsManager = require('ge\\extensions\\tech\\platoonsIDFileManager')

local function changeSpeed(speed)
  targetSpeed = speed
end

local function loadWithID(leaderID, vid, speed, debugFlag)
  loaded = true
  Engine.Annotation.enable(true)
  -- local outcome = platoonsManager.initializePlatoonFile()
  -- local outcome = platoonsManager.initializePlatoonFile()
  -- print("outcome: "..outcome)
  AnnotationManager.setInstanceAnnotations(true)
  local ACCFunctionCall = "extensions.tech_platooning.formPlatoon("..leaderID..","..vid..","..speed..")" 


  be:queueObjectLua(vid, ACCFunctionCall)
end

local function joinWithID(leaderID, vid, speed, debugFlag)
  loaded = true
  Engine.Annotation.enable(true)
  AnnotationManager.setInstanceAnnotations(true)
  local ACCFunctionCall = "extensions.tech_platooning.joinPlatoon("..leaderID..","..vid..","..speed..")" 
  be:queueObjectLua(vid, ACCFunctionCall)
end


local function leavePlatoon(vid)
  loaded = false
  --   ui_message("ACC extension unloaded", 5, "Tech", "forward")
  local ACCFunctionCall = "extensions.tech_platooning.leavePlatoon("..vid..")"
  be:queueObjectLua(vid, ACCFunctionCall)

end

local function launchPlatoon(leaderID,leaderMode)
  launched = true
  print("Launched")
  -- print("mode: "..mode)
  local launchFunctonCall = "extensions.tech_platooning.launchPlatoon("..leaderID..","..leaderMode..")"
  be:queueObjectLua(leaderID, launchFunctonCall)
end

local function endPlatoon(platoonID)
  launched = false
  print("Platoon ended GELUA")
  local leaderID = platoonArch.getLeader(platoonID)
  local launchFunctonCall = "extensions.tech_platooning.endPlatoon("..leaderID..")"
  be:queueObjectLua(leaderID, launchFunctonCall)
  local vehiclesList = platoonArch.getRelayVehicles()
  for i, v in ipairs(vehiclesList) do
    print("ENDING THE PLATOON HEREEEE")
    print(i, v)
    local launchFunctonCall = "extensions.tech_platooning.endPlatoon("..v..")"
    be:queueObjectLua(v, launchFunctonCall)
  end 
  platoonArch.emptydata(platoonID)
end

local function leaderExitPlatoon(platoonID)
  local leaderID = platoonArch.getLeader(platoonID)
  local vehiclesList = platoonArch.getRelayVehicles()
  -- print(vehicle)
  local newLeaderID = vehiclesList[1]
  print("newleader: "..newLeaderID)
  local leaderExitFunctionCall = "extensions.tech_platooning.leaderExitPlatoon("..leaderID..")" --old leader exiting the platoon
  be:queueObjectLua(leaderID, leaderExitFunctionCall)
  local newLeaderFunctionCall = "extensions.tech_platooning.reassignLeader("..newLeaderID..")" --asssigning new leader to follow
  be:queueObjectLua(newLeaderID, newLeaderFunctionCall)
  for i, v in ipairs(vehiclesList) do
    print("for loop for leader reassignment i:")
    print(i, v)
    if i > 1 then
      local launchFunctonCall = "extensions.tech_platooning.updateLeaderToFollow("..newLeaderID..")" --changing the leader to follow for the rest of the vehicles in the platoon
      be:queueObjectLua(v, launchFunctonCall)
    end
  end 
end  

local function leaderExitPlatoonByLeaderID(leaderID)
  -- local leaderID = platoonArch.getLeader(platoonID)
  local platoonID = platoonArch.getPlatoonID(leaderID)
  print("platoonID PF: "..platoonID)
  local vehiclesList = platoonArch.getRelayVehiclesWtihID(platoonID)
  -- print(vehicle)
  local newLeaderID = vehiclesList[1]
  print("newleader: "..newLeaderID)
  local leaderExitFunctionCall = "extensions.tech_platooning.leaderExitPlatoon("..leaderID..")" --old leader exiting the platoon
  be:queueObjectLua(leaderID, leaderExitFunctionCall)
  local newLeaderFunctionCall = "extensions.tech_platooning.reassignLeader("..platoonID..","..newLeaderID..")" --asssigning new leader to follow
  be:queueObjectLua(newLeaderID, newLeaderFunctionCall)
  for i, v in ipairs(vehiclesList) do
    print("for loop for leader reassignment i:")
    print(i, v)
    if i > 1 then
      local launchFunctonCall = "extensions.tech_platooning.updateLeaderToFollow("..newLeaderID..")" --changing the leader to follow for the rest of the vehicles in the platoon
      be:queueObjectLua(v, launchFunctonCall)
    end
  end 
end  
-- Public interface
M.onUpdate            = onUpdate
M.onExtensionLoaded   = function() log('I', 'ACC', 'adaptiveCruiseControlWithRadar extension loaded') end
M.onExtensionUnloaded = unload
M.leavePlatoon        = leavePlatoon
M.load                = load
M.loadWithID          = loadWithID
M.joinWithID          = joinWithID
M.changeSpeed         = changeSpeed
M.launchPlatoon       = launchPlatoon
M.endPlatoon          = endPlatoon
M.leaderExitPlatoon   = leaderExitPlatoon
M.leaderExitPlatoonByLeaderID = leaderExitPlatoonByLeaderID

return M