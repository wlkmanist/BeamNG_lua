-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
Usage example:

local p = LuaProfiler("my profiler")

function onUpdatePhysics()
  p:start()

  stuff()
  p:add("physics stuff")
end

function onUpdateGfx(dtSim, dtReal)
  p:start()

  foo()
  p:add("foo")

  for i=1,10 do
    bar()
    baz()
    p.add("bar&baz")
  done

  qux()
  p:add("qux")

  p:finish(true)          -- show stats each frame
  --p:finish(dtSim>0)     -- show stats each frame (except during pause)
  --p:finish(dtSim>0, dtReal) -- show stats when a peak is detected (except during pause)
  --p:finish(true, nil, 0.002) -- show stats each frame, but hide all those that take less than 2ms to run
end
]]

local C = {}
C.__index = C
local max, floor, abs = math.max, math.floor, math.abs

-- constructor; title is only displayed in logs, can be used to differentiate between different profilers running at the same time
function C:init(title)
  self.title = title
end

-- call once after each section of code whose running time you want to profile
function C:add(section)
  if not self.timer then
    log("E", "", "luaProfiler: Missing start")
    print(debug.tracesimple())
    return
  end
  -- store previous section time
  if section ~= nil then
    local garbage = self.garbagePrev and (collectgarbage("count")*1024 - self.garbagePrev) or nil
    local time = self.timer:stopAndReset()
    local foundSection = nil
    self.sections = self.sections or {}
    for _,v in ipairs(self.sections) do
      if v.section == section then
        foundSection = v
        break
      end
    end
    if foundSection then
      foundSection.time = foundSection.time + time
      foundSection.garbage = foundSection.garbage + garbage
      foundSection.runs = foundSection.runs + 1
    else
      table.insert(self.sections, {
         section = section
        ,time = time
        ,garbage = garbage
        ,runs = 1
      })
    end
  end

  -- reset or create timer
  self.timer = self.timer or (HighPerfTimer or hptimer)()
  self.timer:stopAndReset()
  self.garbagePrev = collectgarbage("count") * 1024
end

local function format(value, decimals, pad, decimalSeparator)
  local factor = 10^decimals
  local result = floor(value*factor + 0.5) / factor
  local k
  while decimalSeparator do
    result, k = string.gsub(result, "^(-?%d+)(%d%d%d)", '%1,%2')
    if k == 0 then break end
  end
  if decimals > 0 then
    return lpad(string.format("%." .. decimals .. "f", result), pad or 0, ' ')
  else
    return lpad(result, pad or 0, ' ')
  end
end

local function computeStats(result, slow, fast, value, dt)
  result.smSlow = result.smSlow or newTemporalSmoothing(slow)
  result.smFast = result.smFast or newTemporalSmoothing(fast)
  local smTotalSlow = result.smSlow:getUncapped(value, dt)
  local smTotalFast = result.smFast:getUncapped(value, dt)
  result.unstableRel = abs(smTotalFast - smTotalSlow) / smTotalSlow
  result.deltaRel = (value-smTotalSlow) / smTotalSlow
  result.average = smTotalSlow
end

local function makeSerializableStats(stats)
  if not stats then return {average = 0, deltaRel = 0, unstableRel = 0} end
  return {
    average = stats.average or 0,
    deltaRel = stats.deltaRel or 0,
    unstableRel = stats.unstableRel or 0
  }
end

local function computeFrameResult(self, compute, dt, threshold)
  local currTotalTime
  local report = nil
  local detectPeaks = type(dt) == "number"
  dt = detectPeaks and dt or 0
  threshold = threshold or 0

  if compute ~= false then
    currTotalTime = 0.0
    local currTotalGarbage = 0
    self.stats = self.stats or {}
    self.sections = self.sections or {}
    local maxTime = 0
    for _, t in ipairs(self.sections) do
      currTotalTime = currTotalTime + t.time
      maxTime = max(maxTime, t.time)
      currTotalGarbage = currTotalGarbage + max(0, t.garbage)
      self.stats[t.section] = self.stats[t.section] or {}
      computeStats(self.stats[t.section], 0.5, 5, t.time, dt)
    end
    self.stats.total = self.stats.total or {}
    computeStats(self.stats.total, 0.5, 5, currTotalTime, dt)
    local peakDetected = (self.stats.total.deltaRel > 0.5) and (self.stats.total.unstableRel < 0.1)
    peakDetected = true
    local shouldOutput = ((not detectPeaks) or (detectPeaks and peakDetected)) and (currTotalTime >= threshold)

    report = {
      title = self.title,
      detectPeaks = detectPeaks,
      threshold = threshold,
      peakDetected = peakDetected,
      shouldOutput = shouldOutput,
      total = {
        time = currTotalTime,
        garbage = currTotalGarbage,
        stats = makeSerializableStats(self.stats.total)
      },
      sections = {}
    }

    for _, t in ipairs(self.sections) do
      local sectionStats = self.stats[t.section]
      local localPeakDetected = sectionStats.deltaRel > 0.3
      local sectionShouldOutput = ((not detectPeaks) or (detectPeaks and localPeakDetected)) and (t.time >= threshold)
      table.insert(report.sections, {
        section = t.section,
        runs = t.runs,
        time = t.time,
        garbage = t.garbage,
        peakDetected = localPeakDetected,
        shouldOutput = sectionShouldOutput,
        graph = maxTime > 0 and graphs((10 * t.time / maxTime), 10) or graphs(0, 10),
        stats = makeSerializableStats(sectionStats)
      })
    end
  end

  return currTotalTime, report
end

-- needs to be used once per independent-function* that you want to profile
-- (*) which doesn't share any common caller ancestor with a function that already used start()
function C:start()
  self.timer = self.timer or (HighPerfTimer or hptimer)()
  self.timer:stopAndReset()
  self.garbagePrev = collectgarbage("count") * 1024
end

-- compute: will silence all logs if 'false'. use as a quick way to disable profiling without having to remove all 'add(...)' calls
-- dt: is used to compute averages and find out peaks (enables peak detection)
function C:finish(compute, dt, threshold)
  local currTotalTime, report = computeFrameResult(self, compute, dt, threshold)
  if report and report.shouldOutput then
    local msg = format(report.total.garbage, 0, 8) .. " bytes"
    msg = msg .." " .. format(report.total.time, 4, 8).." ms"
    if report.detectPeaks then
      msg = msg.." vs "..format(report.total.stats.average, 2, 8).." ms (+"..format(report.total.stats.deltaRel * 100, 0, 5).."%)"
    end
    msg = msg.." TOTAL "..report.title
    log("I", "", msg)

    for _, s in ipairs(report.sections) do
      if s.shouldOutput then
        local title = s.section..(s.runs > 1 and (" (x"..s.runs..")") or "")
        local sectionMsg = format(s.garbage, 0, 8) .. " bytes"
        sectionMsg = sectionMsg .." " .. format(s.time, 4, 8).." ms"
        if report.detectPeaks then
          sectionMsg = sectionMsg.." vs "..format(s.stats.average, 2, 8).." ms (+"..format(s.stats.deltaRel * 100, 0, 5).."%)"
        end
        sectionMsg = sectionMsg..s.graph
        sectionMsg = sectionMsg .. " " .. title
        log("I", "", sectionMsg)
      end
    end
  end
  self.timer = nil
  self.sections = nil
  return currTotalTime
end

-- same computation as finish(), but returns a serializable table instead of writing logs
function C:finishToTable(dt, threshold)
  local _, report = computeFrameResult(self, true, dt, threshold)
  self.timer = nil
  self.sections = nil
  return report
end

function LuaProfiler(...)
  local o = {}
  setmetatable(o, C)
  o:init(...)
  return o
end
