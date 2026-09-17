-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"

local rpmToAV = 0.104719755

local controlledEngine
local engineRPMPID
local avTarget0
local avTarget1
local throttleInputElectricsName
local throttleCommandElectricsName

local function updateFixedStep(dt)
  local throttle = electrics.values[throttleInputElectricsName] or 0
  local targetAV = linearScale(throttle, 0, 1, avTarget0, avTarget1)
  local currentAV = controlledEngine.outputAV1
  local throttleCommand = engineRPMPID:get(currentAV, targetAV, dt)
  electrics.values[throttleCommandElectricsName] = throttleCommand
end

local function reset(jbeamData)
  if controlledEngine then
    engineRPMPID:reset()
  end
end

local function init(jbeamData)
  local controlledEngineName = jbeamData.controlledEngineName or "mainEngine"
  controlledEngine = powertrain.getDevice(controlledEngineName)
  if not controlledEngine then
    log("E", "powertrainControl.throttleGovenor", string.format("Engine '%s' not found, govenor not active.", controlledEngineName))
    return
  end

  engineRPMPID = newPIDParallel(jbeamData.rpmPIDp or 0.5, jbeamData.rpmPIDi or 0.1, jbeamData.rpmPIDd or 0.05, -1, 1, 1, 1, -10, 10)

  avTarget0 = (jbeamData.rpmTarget0 or controlledEngine.idleRPM) * rpmToAV
  avTarget1 = (jbeamData.rpmTarget1 or controlledEngine.maxRPM) * rpmToAV
  throttleCommandElectricsName = jbeamData.throttleCommandElectricsName or "throttleGoverned"
  throttleInputElectricsName = jbeamData.throttleInputElectricsName or "throttle"

  M.updateFixedStep = updateFixedStep
end

M.init = init
M.reset = reset
M.updateFixedStep = nil

return M
