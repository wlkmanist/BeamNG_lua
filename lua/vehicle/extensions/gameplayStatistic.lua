-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- extensions.gameplay_statistic.setDebug(true)

local M = {}

local timers = {}
local statSchedule = {}
local lenstatSchedule=0
local currentStatSchedule=1

local function metricAdd(name,value,aggregate)
  obj:queueGameEngineLua("gameplay_statistic.metricAdd("..dumps(name)..","..tostring(value)..","..tostring(aggregate)..")")
end

local function metricSet(name,value,aggregate)
  obj:queueGameEngineLua("gameplay_statistic.metricSet("..dumps(name)..","..tostring(value)..","..tostring(aggregate)..")")
end

local function updateGFX(dt)
  if lenstatSchedule > 0 then
    if not playerInfo.anyPlayerSeated and ai.mode ~= "disabled" then return end
    statSchedule[currentStatSchedule]()
    currentStatSchedule = currentStatSchedule + 1
    if currentStatSchedule > lenstatSchedule then currentStatSchedule = 1 end
  end
end

local function addSchedule(fn)
  table.insert(statSchedule, fn)
  lenstatSchedule = #statSchedule
  M.updateGFX = updateGFX
  extensions.hookUpdate("updateGFX")
end

local function removeSchedule(fn)
  for i in ipairs(statSchedule) do
    if statSchedule[i] == fn then
      table.remove(statSchedule, i)
      lenstatSchedule = #statSchedule
      if lenstatSchedule == 0 then
        M.updateGFX = nil
        extensions.hookUpdate("updateGFX")
      end
      return true
    end
  end
  return false
end

local function onExtensionLoaded()
  if wheels.wheelCount == 0 and not hydros.isPhysicsStepUsed() and not powertrain.isPhysicsStepUsed() then
    return false --unload
  end

  extensions.load("gameplayStatisticModules/watchAirtime")
  extensions.load("gameplayStatisticModules/watchBurnout")

  if extensions.gameplayStatisticModules_watchAirtime then
    addSchedule(extensions.gameplayStatisticModules_watchAirtime.workload)
  end

  if extensions.gameplayStatisticModules_watchBurnout then
    addSchedule(extensions.gameplayStatisticModules_watchBurnout.workload)
  end
end

M.onExtensionLoaded = onExtensionLoaded
--M.onExtensionUnloaded = onExtensionUnloaded

M.metricAdd = metricAdd
M.metricSet = metricSet
M.addSchedule = addSchedule
M.removeSchedule = removeSchedule

M.updateGFX = nil

return M