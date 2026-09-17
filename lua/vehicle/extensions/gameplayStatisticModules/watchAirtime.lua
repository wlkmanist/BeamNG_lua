-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local initialWheelCount = 0
local startTime = 0
local curTrigger = false

local function watchAirtime()
  if initialWheelCount ~= wheels.wheelCount then return end --if we lose a wheel
  local prevTrigger = curTrigger
  local curTrigger = obj:getGroundSpeed() > 6

  for i = 0, initialWheelCount-1 do
    local wd = wheels.wheels[i]
    curTrigger = curTrigger and wd.contactMaterialID1 ==-1 and wd.contactMaterialID2 ==-1
    if not curTrigger then break end
  end
  --todo redo this
  local _, _, z = obj:getDirectionVectorUpXYZ()
  curTrigger = curTrigger and ( z > 0.707 ) --45deg

  if curTrigger then
    if not prevTrigger then
      startTime = obj:getSimTime()
    end
  else
    if prevTrigger then
      local airTime = obj:getSimTime() - startTime
      if airTime > 0.1 then
        gameplayStatistic.metricAdd("vehicle/airtime.time", airTime, true)
      end
    end
  end
end

local function onExtensionLoaded()
  if controller.mainController.typeName ~= "vehicleController/vehicleController" then
    return false --unload
  end

  initialWheelCount = wheels.wheelCount
  if initialWheelCount==0 then
    return false
  end
end

M.onExtensionLoaded = onExtensionLoaded
M.workload = watchAirtime

return M