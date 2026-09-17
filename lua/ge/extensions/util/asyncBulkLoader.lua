
-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
local tooLongLoadingThreshold = math.huge -- set this to a lower value to enable reporting of long loading times (time in ms)
--core_jobsystem.create(function(job) asyncVehicleYield = job.yield print("start...") core_vehicles.getModelsData() print("done!") end, 0.1)

local streamName = "asyncBulkLoaderProgress"
local asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = false, percent = -1 }

M.reportStream = function()
  guihooks.triggerStream(streamName, asyncBulkLoaderProgress)
end

-- File-scan progress for vehicle decode: 0-100 = determinate, -1 = indeterminate.
M.reportScanPercent = function(percent)
  asyncBulkLoaderProgress.percent = percent
  M.reportStream()
end

M.addTotal = function(total)
  asyncBulkLoaderProgress.total = asyncBulkLoaderProgress.total + total
  M.reportStream()
end

local countSeen = {}

M.addCount = function(count)
  asyncBulkLoaderProgress.count = asyncBulkLoaderProgress.count + count
  M.reportStream()
  local trace = debug.tracesimple()
  if not countSeen[trace] then
    countSeen[trace] = 0
    --print("new trace: " .. trace:match("([^\n]*\n?[^\n]*)"))
  end
  countSeen[trace] = countSeen[trace] + count
end

-- profiling
local profilerLow, profilerHigh

if tooLongLoadingThreshold ~= math.huge then
  M.startProfiling = function()
    profilerLow = LuaProfiler("asyncBulkLoader low level")
    profilerHigh = LuaProfiler("asyncBulkLoader high level")

    profilerLow:start()
    profilerHigh:start()
  end

  M.profileLow = function(section)
    if not profilerLow then return end
    profilerLow:add(section)
  end

  M.profileHigh = function(section)
    if not profilerHigh then return end
    profilerHigh:add(section)
  end

  M.stopProfiling = function(timeTaken, sectionName)
    local report = (timeTaken or 0) > tooLongLoadingThreshold

    profilerHigh:add("total")
    profilerLow:add("total")
    if report then
      local lowReport = profilerLow:finishToTable(report)
      local highReport = profilerHigh:finishToTable(report)
      log("W","",string.format("asyncBulkLoader: %s total time took %d ms - this is too long! Report saved to asyncBulkLoader_report.json", sectionName or "total", lowReport.total.time))
      jsonWriteFile("asyncBulkLoader_report.json", {lowReport = lowReport, highReport = highReport}, true, 8)
    else
      profilerLow:finish(false)
      profilerHigh:finish(false)
    end
    profilerLow = nil
    profilerHigh = nil
  end
else
  M.startProfiling = nop
  M.profileLow = nop
  M.profileHigh = nop
  M.stopProfiling = nop
end




-- checker functions

M.isVehiclesLoaded = function()
  return core_vehicles.isModelsDataLoaded()
end

M.isMissionsLoaded = function()
  return gameplay_missions_missions.areAllMissionsLoaded()
end

M.isGameplaySelectorLoaded = function()
  return ui_gameplaySelector_general.isGameplayDataLoaded()
end

M.isLevelsLoaded = function()
  return core_levels.isListLoaded()
end

M.loadVehiclesDirect = function()
  local h = hptimer()
  core_vehicles.loadModelListNoGarbage()
  print("loadVehiclesDirect took: " .. h:stop() .. " ms")
end

M.loadMissionsDirect = function()
  local h = hptimer()
  gameplay_missions_missions.getAllMissions()
  print("loadMissionsDirect took: " .. h:stop() .. " ms")
end

M.loadGameplaySelectorDirect = function()
  local h = hptimer()
  ui_gameplaySelector_general.getTiles('')
  print("loadGameplaySelectorDirect took: " .. h:stop() .. " ms")
end

M.loadLevelsDirect = function()
  local h = hptimer()
  core_levels.getList()
  print("loadLevelsDirect took: " .. h:stop() .. " ms")
end

M.yield = nop
M.isLoading = function()
  return asyncBulkLoaderProgress.inProgress
end

M.setupYield = function(job)
  if tooLongLoadingThreshold == math.huge then
    M.yield = job.yield
  else
    M.yield = function(section)
      if not section then
        local source = split(debug.tracesimple(), "\n")[3] or "unknown"
        print(debug.tracesimple())
        section = source
      end
      M.profileLow("yield " .. section)
      job.yield()
    end
  end
end

M.loadVehicles = function()
  if core_vehicles.isModelsDataLoaded() then
    return "alreadyLoaded"
  end

  if M.isLoading() then
    log("E","", "loadVehicles: already loading")
    print(debug.tracesimple())
    return "alreadyLoading"
  end

  core_jobsystem.create(function(job)
    local h = hptimer()
    M.startProfiling()

    M.setupYield(job)
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = true, percent = -1 }
    M.reportStream()

    M.profileHigh("bulk loader setup done")
    core_vehicles.loadModelListNoGarbage()

    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = false, percent = -1 }

    local ms = h:stop()
    print("loadVehicles took: " .. ms .. " ms")

    M.reportStream()
    guihooks.trigger("asyncVehicleLoadComplete")
    extensions.hook("asyncVehicleLoadComplete")

    M.stopProfiling(ms, "loadVehicles")

  end, 1/30)
  return "startLoading"
end


M.loadMissions = function()
  if gameplay_missions_missions.areAllMissionsLoaded() then
    return "alreadyLoaded"
  end

  if M.isLoading() then
    log("E","", "loadMissions: already loading")
    print(debug.tracesimple())
    return "alreadyLoading"
  end

  core_jobsystem.create(function(job)
    local h = hptimer()
    M.startProfiling()

    M.setupYield(job)
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = true }
    M.reportStream()

    M.profileHigh("bulk loader setup done")
    gameplay_missions_missions.getAllMissions()

    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = false }

    local ms = h:stop()
    print("loadMissions took: " .. ms .. " ms")

    M.reportStream()
    guihooks.trigger("asyncMissionLoadComplete")

    M.stopProfiling(ms, "loadMissions")
  end, 1/30)
  return "startLoading"
end

M.loadGameplaySelector = function()
  if M.isGameplaySelectorLoaded() then
    return "alreadyLoaded"
  end

  if M.isLoading() then
    log("E","", "loadGameplaySelector: already loading")
    print(debug.tracesimple())
    return "alreadyLoading"
  end

  core_jobsystem.create(function(job)
    local h = hptimer()
    M.startProfiling()

    M.setupYield(job)
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = true }
    M.reportStream()

    M.profileHigh("bulk loader setup done")
    ui_gameplaySelector_general.getTiles('')

    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = false }

    local ms = h:stop()
    print("loadGameplaySelector took: " .. ms .. " ms")

    M.reportStream()
    guihooks.trigger("asyncGameplaySelectorLoadComplete")
    extensions.hook("asyncGameplaySelectorLoadComplete")

    M.stopProfiling(ms, "loadGameplaySelector")

  end, 1/30)

  return "startLoading"
end



M.loadLevels = function()
  if core_levels.isListLoaded() then
    return "alreadyLoaded"
  end

  if M.isLoading() then
    log("E","", "loadLevels: already loading")
    print(debug.tracesimple())
    return "alreadyLoading"
  end

  core_jobsystem.create(function(job)
    local h = hptimer()
    M.startProfiling()

    M.setupYield(job)
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = true }
    M.reportStream()

    M.profileHigh("bulk loader setup done")
    core_levels.getList()

    M.yield = nil
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = false }
    local ms = h:stop()
    print("loadLevels took: " .. ms .. " ms")
    M.reportStream()
    guihooks.trigger("asyncLevelLoadComplete")
    extensions.hook("asyncLevelLoadComplete")

    M.stopProfiling(ms, "loadLevels")

  end, 1/30)
  return "startLoading"
end

M.sendAllCareerSaveSlotsDataAsync = function()
  core_jobsystem.create(function(job)
    local h = hptimer()
    M.startProfiling()

    M.setupYield(job)
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = true }
    M.reportStream()

    M.profileHigh("bulk loader setup done")
    -- use this code to profile loading time of vehicle vs career save slots
    --local hV = hptimer()
    --core_vehicles.loadModelListNoGarbage()
    --print("sendAllCareerSaveSlotsDataAsync - vehicle loading took: " .. hV:stop() .. " ms")

    local ms = h:stop()

    print("sendAllCareerSaveSlotsDataAsync - career save slots loading took: " .. ms .. " ms")

    M.yield = nop
    asyncBulkLoaderProgress = { count = 0, total = 0, inProgress = false }
    M.reportStream()
    M.stopProfiling(ms, "sendAllCareerSaveSlotsDataAsync")

    career_career.sendAllCareerProfilesData()
  end, 1/30)
  return "startLoading"
end

return M