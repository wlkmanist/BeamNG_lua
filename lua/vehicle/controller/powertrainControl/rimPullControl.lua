-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"
M.defaultOrder = 40

local max = math.max
local clamp = clamp

local relevantTorqueConverter = nil

local function updateGFX(dt)
  --read the rim pull input from the relevant axis action
  local rimPullInput = input.rimPull or 0
  --calculate how much torque reduction we want
  local rimPullOutput = linearScale(rimPullInput, 0, 0.5, 1, 0.2)
  --calculate how much brake we want to apply, only apply brake past 50% input
  local brakeOutput = linearScale(rimPullInput, 0.5, 1, 0, 1)

  input.brake = max(input.brake, brakeOutput) --overwrite the brake input before vehicleController uses it

  if relevantTorqueConverter then
    relevantTorqueConverter.impellerClutchCoef = clamp(rimPullOutput, 0, 1)
  end
end

local function reset(jbeamData)
end

local function init(jbeamData)
  local torqueConverterName = jbeamData.torqueConverterName or "torqueConverter"
  relevantTorqueConverter = powertrain.getDevice(torqueConverterName)
  if not relevantTorqueConverter then
    log("D", "rimPullControl.init", "Torque converter not found, rim pull control disabled: " .. torqueConverterName)
    M.updateGFX = nop
  end
end

M.init = init
M.reset = reset
M.updateGFX = updateGFX

return M
