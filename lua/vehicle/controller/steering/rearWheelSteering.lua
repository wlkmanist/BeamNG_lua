-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Provides speed-dependent steering commands for rear and auxiliary axles

local M = {}
M.type = "auxiliary"

local modes = {
  feedForward = "feedForward",
  closedLoop = "closedLoop"
}
--shared variables
local rearSteeringOutputElectricsName

--feedForward variables
local feedForwardMap

local function updateGFXFeedForward(dt)
  local frontSteeringInput = electrics.values.steering_input or 0
  local vehicleSpeed = electrics.values.wheelspeed or 0
  local rearSteeringOutput = feedForwardMap:get(vehicleSpeed, frontSteeringInput) or 0
  electrics.values[rearSteeringOutputElectricsName] = rearSteeringOutput
end

local function updateGFXClosedLoop(dt)
  --nop, not implemented atm
end

local function reset(jbeamData)
  electrics.values[rearSteeringOutputElectricsName] = 0
end

local function init(jbeamData)
  local modeUpdatesMethods = {[modes.feedForward] = updateGFXFeedForward, [modes.closedLoop] = updateGFXClosedLoop}
  local mode = jbeamData.mode or "feedForward"
  rearSteeringOutputElectricsName = jbeamData.rearSteeringOutputElectricsName or "rws"
  if not modeUpdatesMethods[mode] then
    log("E", "rearWheelSteering", "Invalid mode: " .. tostring(mode))
  end
  M.updateGFX = modeUpdatesMethods[mode]

  if mode == modes.feedForward then
    if not jbeamData.feedForwardMapData then
      log("E", "rearWheelSteering", "Missing feedForwardMapData for feedForward mode")
      return
    end
    local interpolatedMap = require("interpolatedMap")
    feedForwardMap = interpolatedMap.new()
    feedForwardMap:loadData(jbeamData.feedForwardMapData)
    feedForwardMap.clampToDataRange = true
  elseif mode == modes.closedLoop then
    log("W", "rearWheelSteering", "closedLoop mode is not implemented yet")
  end
end

M.init = init
M.reset = reset

M.updateGFX = nil

return M
