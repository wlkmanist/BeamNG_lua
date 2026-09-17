-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"

local steeringPID
local steeringCylinders
local steeringPositionMin
local steeringPositionMax
local invSteeringCylinderCount
local steeringValveElectricsName

local function updateFixedStep(dt)
  local currentSteering = 0
  --iterate over steeringCylinders and track extend percentage
  for _, cylinder in ipairs(steeringCylinders) do
    currentSteering = currentSteering + cylinder.currentExtendPercent * cylinder.direction
  end
  currentSteering = currentSteering * invSteeringCylinderCount
  currentSteering = linearScale(currentSteering, steeringPositionMin, steeringPositionMax, -1, 1)

  local steeringTarget = electrics.values.steering_input or 0

  local steeringValveControl = steeringPID:get(currentSteering, steeringTarget, dt)

  electrics.values[steeringValveElectricsName] = steeringValveControl
end

local function reset(jbeamData)
  electrics.values[steeringValveElectricsName] = 0
  steeringPID:reset()
end

local function init(jbeamData)
  steeringPID = newPIDParallel(jbeamData.steeringPIDKp or 0.5, jbeamData.steeringPIDKi or 0.3, jbeamData.steeringPIDKd or 0.01, -1, 1, 1000, 1000, -1, 1, 0.002)
  --steeringPID:setDebug(true)

  steeringCylinders = {}

  local steeringCylinderCount = 0
  for _, cylinderName in ipairs(jbeamData.steeringPositionCylinders or {}) do
    local cylinder = powertrain.getHydraulicConsumer(cylinderName)
    if cylinder then
      table.insert(steeringCylinders, cylinder)
      steeringCylinderCount = steeringCylinderCount + 1
    end
  end
  if steeringCylinderCount > 0 then
    invSteeringCylinderCount = 1 / steeringCylinderCount
  else
    invSteeringCylinderCount = 0
  end

  steeringValveElectricsName = jbeamData.steeringValveElectricsName or "steerCylinder"
  steeringPositionMin = jbeamData.steeringPositionMin or 0
  steeringPositionMax = jbeamData.steeringPositionMax or 1
end

M.init = init
M.reset = reset
M.updateFixedStep = updateFixedStep

return M
