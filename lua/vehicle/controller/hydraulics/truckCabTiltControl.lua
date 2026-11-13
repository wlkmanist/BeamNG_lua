-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--Purpose: Coordinates the control of a truck's cab tilt system and cab latch

local M = {}
M.type = "auxiliary"

local cabLatchControllerNames
local cabTiltCylinderNames

local tiltCylinderValveModeLatched = "float"
local tiltCylinderValveModeUnlatched = "closed"

local function updateGFX(dt)
  local isCabLatched = false
  for _, cabLatchControllerName in pairs(cabLatchControllerNames) do
    local cabLatchController = controller.getControllerSafe(cabLatchControllerName)
    if cabLatchController then
      isCabLatched = isCabLatched or cabLatchController.getGroupState() == "attached"
    end
  end

  local tiltCylinderValveMode
  if isCabLatched then
    tiltCylinderValveMode = tiltCylinderValveModeLatched
  else
    tiltCylinderValveMode = tiltCylinderValveModeUnlatched
  end

  for _, cabTiltCylinderName in pairs(cabTiltCylinderNames) do
    local cabTiltCylinder = powertrain.getHydraulicConsumer(cabTiltCylinderName)
    if cabTiltCylinder then
      cabTiltCylinder:setValveType(tiltCylinderValveMode)
    end
  end
end

local function reset(jbeamData)
end

local function init(jbeamData)
  tiltCylinderValveModeLatched = jbeamData.tiltCylinderValveModeLatched or "float"
  tiltCylinderValveModeUnlatched = jbeamData.tiltCylinderValveModeUnlatched or "closed"
  cabLatchControllerNames = jbeamData.cabLatchControllers or {}
  cabTiltCylinderNames = jbeamData.cabTiltCylinders or {}
end

M.init = init
M.reset = reset

M.updateGFX = updateGFX

return M
