-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
M.type = "auxiliary"

local abs = math.abs

local cylinderPID
local cylinders
local cylinderPositionMin
local cylinderPositionMax
local invCylinderCount
local cylinderValveElectricsName
local targetExtendPercent = 0

local function setCylinderTargetExtendPercent(extendPercent)
  targetExtendPercent = clamp(extendPercent, cylinderPositionMin, cylinderPositionMax)
end

local function updateFixedStep(dt)
  local currentExtendPercent = 0
  --iterate over cylinders and track extend percentage
  for _, cylinder in ipairs(cylinders) do
    currentExtendPercent = currentExtendPercent + cylinder.currentExtendPercent
  end
  currentExtendPercent = currentExtendPercent * invCylinderCount

  local cylinderValveControl = cylinderPID:get(currentExtendPercent, targetExtendPercent, dt)

  if abs(cylinderValveControl) < 0.001 then
    cylinderValveControl = 0
  end

  electrics.values[cylinderValveElectricsName] = cylinderValveControl
end

local function reset(jbeamData)
  electrics.values[cylinderValveElectricsName] = 0
  targetExtendPercent = 0
  cylinderPID:reset()
end

local function init(jbeamData)
  cylinderPID = newPIDParallel(jbeamData.cylinderPIDKp or 0.5, jbeamData.cylinderPIDKi or 0.3, jbeamData.cylinderPIDKd or 0.01, -1, 1, 1000, 10, nil, nil, 0.01)
  cylinderPID:setDebug(true)

  cylinders = {}

  for _, cylinderName in ipairs(jbeamData.cylinders or {}) do
    local cylinder = powertrain.getHydraulicConsumer(cylinderName)
    if cylinder then
      table.insert(cylinders, cylinder)
    end
  end

  if #cylinders <= 0 then
    invCylinderCount = 0
    log("D", "closedLoopLinearControl.init", "No hydraulic cylinders found!")
  else
    invCylinderCount = 1 / #cylinders
  end

  cylinderValveElectricsName = jbeamData.cylinderValveElectricsName or "cylinderValve"
  cylinderPositionMin = jbeamData.cylinderPositionMin or 0
  cylinderPositionMax = jbeamData.cylinderPositionMax or 1
  targetExtendPercent = clamp(jbeamData.targetExtendPercentInitial or 0, cylinderPositionMin, cylinderPositionMax)
end

M.init = init
M.reset = reset
M.updateFixedStep = updateFixedStep

M.setCylinderTargetExtendPercent = setCylinderTargetExtendPercent

return M
