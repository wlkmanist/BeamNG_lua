-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  TELEMETRY MEMORY TRACKER

  Reports how much memory the machine has, how much of it this game holds, and whether the
  OS started moving pages to disk to keep going.

  memoryPressure is sent at most once per session, the first time low free memory and
  sustained paging are seen together. One event is enough to find the players it happens
  to, and a machine that is thrashing cannot fill the report with events.

  The paging counters are machine wide and include file reads by any process, see
  bng::os::getPagingInfo. Paging on its own therefore proves nothing, which is why it only
  counts here together with low free memory.

  memorySample is off unless the server sets sampleIntervalSeconds, for an investigation.
  Polling stops once nothing can be reported any more, so the usual session pays for a
  handful of readings.
]]

local M = {}
M.dependencies = {'telemetry_core'}

local pollIntervalSeconds = 5
-- the smaller of a tenth of the machine and 2 GB, so a large machine does not have to run
-- almost empty before this counts as low
local pressureAvailableRatio = 0.1
local pressureAvailableLimitBytes = 2 * 1024 * 1024 * 1024
local pressurePagingBytesPerSecond = 1024 * 1024

local sampleIntervalSeconds = 0
local pollTimer = 0
local sampleTimer = 0
local previousReadBytes = nil
local previousWriteBytes = nil
local pressureReported = false
local finished = false

-- The paging rates are nil until two readings exist, and on platforms that report no
-- counters at all. Reporting a zero there would read as "no paging", which is not known.
local function snapshot(memory, availableBytes, readBytesPerSecond, writeBytesPerSecond, paused)
  local physicalUsedBytes = memory.osPhysUsed or 0
  local gamePhysicalUsedBytes = memory.processPhysUsed or 0
  return {
    physicalTotalBytes = memory.osPhysAvailable,
    physicalAvailableBytes = availableBytes,
    physicalUsedBytes = physicalUsedBytes,
    gamePhysicalUsedBytes = gamePhysicalUsedBytes,
    -- pages shared between processes are counted once for the machine, so this is an estimate
    outsideGamePhysicalUsedBytesEstimate = math.max(physicalUsedBytes - gamePhysicalUsedBytes, 0),
    virtualTotalBytes = memory.osVirtAvailable,
    virtualUsedBytes = memory.osVirtUsed,
    gameVirtualUsedBytes = memory.processVirtUsed,
    pagingReadBytesPerSecond = readBytesPerSecond and math.floor(readBytesPerSecond + 0.5),
    pagingWriteBytesPerSecond = writeBytesPerSecond and math.floor(writeBytesPerSecond + 0.5),
    level = getCurrentLevelIdentifier(),
    paused = paused or nil,
  }
end

local function emitEvent(name, memory, availableBytes, readBytesPerSecond, writeBytesPerSecond, paused)
  local data = snapshot(memory, availableBytes, readBytesPerSecond, writeBytesPerSecond, paused)
  data.name = name
  if name == "memorySample" then data.intervalSeconds = sampleIntervalSeconds end
  extensions.telemetry_core.addEvent(data)
end

local function pollMemory(elapsed, paused)
  local memory = Engine.Platform.getMemoryInfo(true)
  local availableBytes = math.max((memory.osPhysAvailable or 0) - (memory.osPhysUsed or 0), 0)
  local readBytesPerSecond, writeBytesPerSecond

  if memory.pagingSupported then
    -- the counters only count up, a smaller reading means they were reset under us
    if previousReadBytes and memory.pagingReadBytes >= previousReadBytes
        and memory.pagingWriteBytes >= previousWriteBytes then
      readBytesPerSecond = (memory.pagingReadBytes - previousReadBytes) / elapsed
      writeBytesPerSecond = (memory.pagingWriteBytes - previousWriteBytes) / elapsed
    end
    previousReadBytes = memory.pagingReadBytes
    previousWriteBytes = memory.pagingWriteBytes
  end

  if sampleIntervalSeconds > 0 then
    sampleTimer = sampleTimer + elapsed
    if sampleTimer >= sampleIntervalSeconds then
      sampleTimer = sampleTimer % sampleIntervalSeconds
      emitEvent("memorySample", memory, availableBytes, readBytesPerSecond, writeBytesPerSecond, paused)
    end
  end

  if not pressureReported and readBytesPerSecond then
    local availableLimitBytes = math.min(
      pressureAvailableLimitBytes,
      (memory.osPhysAvailable or 0) * pressureAvailableRatio)
    if availableBytes <= availableLimitBytes
        and readBytesPerSecond + writeBytesPerSecond >= pressurePagingBytesPerSecond then
      pressureReported = true
      emitEvent("memoryPressure", memory, availableBytes, readBytesPerSecond, writeBytesPerSecond, paused)
    end
  end

  -- samples are off and the one pressure event is sent, or this platform cannot detect it
  if sampleIntervalSeconds > 0 then return end
  if not pressureReported and memory.pagingSupported then return end

  finished = true
  M.onUpdate = nil
  extensions.hookUpdate("onUpdate")
  if not memory.pagingSupported then
    log('D', 'telemetry', 'No OS paging counters here, memory pressure cannot be detected')
  end
end

local function onUpdate(dtReal, dtSim)
  if finished then return end

  pollTimer = pollTimer + dtReal
  if pollTimer < pollIntervalSeconds then return end

  local elapsed = pollTimer
  pollTimer = 0
  pollMemory(elapsed, dtSim <= 0)
end

local function onExtensionLoaded()
  -- a reload means a new telemetry session, and the module keeps its state across one, so
  -- everything the last session decided has to go
  pollTimer = 0
  sampleTimer = 0
  previousReadBytes = nil
  previousWriteBytes = nil
  pressureReported = false
  finished = false

  sampleIntervalSeconds = 0
  local configured = extensions.telemetry_configManager.getModuleConfig('memory').sampleIntervalSeconds
  if type(configured) == "number" and configured > 0 then
    sampleIntervalSeconds = clamp(configured, 5, 3600)
  end
  if M.onUpdate ~= onUpdate then
    M.onUpdate = onUpdate
    extensions.hookUpdate("onUpdate")
  end
  setExtensionUnloadMode(M, "manual")
end

M.onExtensionLoaded = onExtensionLoaded
M.onUpdate = onUpdate

return M
