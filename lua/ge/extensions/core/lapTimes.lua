-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = 'lapTimes'

-- Core state variables
local status = "stopped" -- "stopped", "started", "paused", "complete"
local currentTime = 0

-- Lap and segment tracking
local currentLap = 0
local currentSegment = 0
local totalLaps = 0
local totalSegments = 0

-- Time tracking data structures
local segmentTimes = {} -- Historical segment times (flat array for UI compatibility)
local segmentTimesByLap = {} -- Segments organized by lap and segment number

-- Best times tracking
local bestLapTime = nil
local bestLapIndex = -1
local bestSegmentTimes = {} -- Best time for each segment
local bestSegmentLaps = {} -- Which lap achieved the best time for each segment

-- Multi-vehicle support
local placements = {} -- Vehicle placements
local placementOrder = {}

-- Configuration
local closedCircuit = false -- Store whether the race path is a closed circuit

-- Stream data containers
local fastStreamData = {} -- Current time, current lap time, etc.
local slowStreamData = {} -- Historical times, best times, etc.
local staticStreamData = {} -- Lap counts, etc.
local placementStreamData = {} -- Placement data, vehicle states, etc.

-- Stream send flags
local needFastStream = false
local needSlowStream = false
local needStaticStream = false
local needPlacementStream = false

--------------------------------------------------------------------
-- Core initialization and control functions
--------------------------------------------------------------------

-- Initialize the lap times system
local function initialize()
  status = "stopped"
  currentTime = 0

  currentLap = 0
  currentSegment = 0
  totalLaps = 0
  totalSegments = 0

  table.clear(segmentTimes)
  table.clear(segmentTimesByLap)

  bestLapTime = nil
  bestLapIndex = -1
  table.clear(bestSegmentTimes)
  table.clear(bestSegmentLaps)

  table.clear(placements)

  -- Clear stream data
  table.clear(fastStreamData)
  table.clear(slowStreamData)
  table.clear(staticStreamData)
  table.clear(placementStreamData)

  log('I', logTag, 'Lap times system initialized')
  -- Request UI refresh after reset
  needFastStream = true
  needSlowStream = true
  needStaticStream = true
  needPlacementStream = true
end


--------------------------------------------------------------------
-- Utility functions
--------------------------------------------------------------------

-- Format time in seconds to MM:SS.mmm format
local function formatTime(timeInSeconds, addSign)
  if timeInSeconds == nil then
    return nil
  end

  if addSign then
    local sign = timeInSeconds >= 0 and '+' or '-'
    return sign .. M.formatTime(math.abs(timeInSeconds), false)
  else
    local minutes = math.floor(timeInSeconds / 60)
    local secondsWhole = math.floor(timeInSeconds - minutes * 60)
    local millis = math.floor((timeInSeconds - minutes * 60 - secondsWhole) * 1000)
    return string.format("%.2d:%.2d.%.3d", minutes, secondsWhole, millis)
  end
end

-- Get color for time difference
local function getDiffFlavor(val)
  if val > 0 then
    return 'worse' -- Slower
  elseif val < 0 then
    return 'better' -- Faster
  else
    return 'same' -- Same
  end
end

-- Set configuration
local function setConfiguration(config)
  if config.totalLaps then
    totalLaps = config.totalLaps
  end
  if config.totalSegments then
    totalSegments = config.totalSegments
  end
  if config.closedCircuit ~= nil then
    closedCircuit = config.closedCircuit
  end
end

-- Snapshot-driven integration -------------------------------------------------

local function onRaceStart(meta)
  if not meta then return end
  M.initialize()
  totalLaps = meta.totalLaps or 0
  totalSegments = meta.totalSegments or 0
  closedCircuit = meta.pathConfig and meta.pathConfig.isClosed or false
  status = "started"
  needFastStream = true
  needSlowStream = true
  needStaticStream = true
  needPlacementStream = true
end

local function onRaceStop()
  status = "stopped"
  needFastStream = true
  needSlowStream = true
  needStaticStream = true
  needPlacementStream = true
end

-- Update fast-changing data from race state
local function updateFastFromRace(race, playerId)
  if not race or not race.states or not race.states[playerId] then
    return
  end

  local state = race.states[playerId]

  -- Update current time (offset by startTime so rolling starts count from the first checkpoint)
  -- Use endTime when complete for sub-frame accuracy matching the recorded finish time.
  local raceTimeRef = state.complete and (state.endTime or 0) or (race.time or 0)
  currentTime = raceTimeRef - (state.startTime or 0)

  -- Calculate current lap/segment data
  local currentLapStart = state.startTime or 0
  if state.currentLap ~= 0 and #state.historicTimes > 0 then
    currentLapStart = state.historicTimes[#state.historicTimes].endTime
  end

  local segmentStart = currentLapStart
  if #state.currentTimes > 0 then
    segmentStart = state.currentTimes[#state.currentTimes].endTime
  end

  -- Calculate current lap and segment durations
  local currentLapDuration, currentSegmentDuration
  if state.complete then
    currentLapDuration = math.max(0, (state.endTime or 0) - currentLapStart)
    currentSegmentDuration = math.max(0, (state.endTime or 0) - segmentStart)
  else
    currentLapDuration = math.max(0, (race.time or 0) - currentLapStart)
    currentSegmentDuration = math.max(0, (race.time or 0) - segmentStart)
  end

  -- Populate fast stream data directly
  table.clear(fastStreamData)

  fastStreamData.currentTime = currentTime
  fastStreamData.currentTimeFormatted = M.formatTime(currentTime)

  -- Build lap data directly in stream
  if currentLapStart ~= nil then
    fastStreamData.currentLapTime = currentLapDuration
    fastStreamData.currentLapTimeFormatted = M.formatTime(currentLapDuration)
    fastStreamData.currentLapDiffToBest = nil
    fastStreamData.currentLapDiffToBestFormatted = nil
    fastStreamData.currentLapDiffToBestFlavor = nil
    fastStreamData.currentLapDiffToPrevious = nil
    fastStreamData.currentLapDiffToPreviousFormatted = nil
    fastStreamData.currentLapDiffToPreviousFlavor = nil
  else
    fastStreamData.currentLapTime = 0
    fastStreamData.currentLapTimeFormatted = M.formatTime(0)
    fastStreamData.currentLapDiffToBest = nil
    fastStreamData.currentLapDiffToBestFormatted = nil
    fastStreamData.currentLapDiffToBestFlavor = nil
    fastStreamData.currentLapDiffToPrevious = nil
    fastStreamData.currentLapDiffToPreviousFormatted = nil
    fastStreamData.currentLapDiffToPreviousFlavor = nil
  end

  -- Build segment data directly in stream
  if segmentStart ~= nil then
    fastStreamData.currentSegmentTime = currentSegmentDuration
    fastStreamData.currentSegmentTimeFormatted = M.formatTime(currentSegmentDuration)
    fastStreamData.currentSegmentDiffToBest = nil
    fastStreamData.currentSegmentDiffToBestFormatted = nil
    fastStreamData.currentSegmentDiffToBestFlavor = nil
    fastStreamData.currentSegmentDiffToPrevious = nil
    fastStreamData.currentSegmentDiffToPreviousFormatted = nil
    fastStreamData.currentSegmentDiffToPreviousFlavor = nil
  else
    fastStreamData.currentSegmentTime = 0
    fastStreamData.currentSegmentTimeFormatted = M.formatTime(0)
    fastStreamData.currentSegmentDiffToBest = nil
    fastStreamData.currentSegmentDiffToBestFormatted = nil
    fastStreamData.currentSegmentDiffToBestFlavor = nil
    fastStreamData.currentSegmentDiffToPrevious = nil
    fastStreamData.currentSegmentDiffToPreviousFormatted = nil
    fastStreamData.currentSegmentDiffToPreviousFlavor = nil
  end

  -- Set flag for onUpdate to send the stream
  needFastStream = true
end

-- Update slow-changing data from race state
local function updateSlowFromRace(race, playerId)
  if not race or not race.states or not race.states[playerId] then
    return
  end

  local state = race.states[playerId]

  -- Update status from race state
  if state.complete == true then
    status = "complete"
  elseif race.suspended == true then
    status = "paused"
  elseif race.started == true then
    status = "started"
  else
    status = "stopped"
  end

  -- Update current lap/segment
  if state.complete == true then
    -- When race is complete, show max values
    currentLap = totalLaps
    currentSegment = totalSegments
  else
    currentLap = (state.currentLap or 0) + 1
    currentSegment = (#state.currentTimes) + 1
  end

  -- Process historical lap times to find best lap
  local bestLap = nil
  local lapData = {} -- Temporary for this function only

  for i = 1, #state.historicTimes do
    local l = state.historicTimes[i]
    local duration = l.duration or ((l.endTime or 0) - (l.beginTime or 0))

    if not bestLap or duration < bestLap then
      bestLap = duration
    end

    -- Store minimal data needed for stream building
    lapData[i] = {
      lap = (l.lap or (i - 1)) + 1,
      startTime = l.beginTime,
      endTime = l.endTime,
      duration = duration,
      time = l.endTime
    }
  end

  -- Build historical segment times and find bests
  table.clear(segmentTimes)
  table.clear(segmentTimesByLap)
  table.clear(bestSegmentTimes)
  table.clear(bestSegmentLaps)
  local bestPerIndex = {}

  -- Process completed laps from historicTimes
  for i = 1, #state.historicTimes do
    local l = state.historicTimes[i]
    local oneBasedLap = (l.lap or (i - 1)) + 1
    for idx = 1, #l.segmentTimes do
      local s = l.segmentTimes[idx]
      local duration = s.duration or ((s.endTime or 0) - (s.beginTime or 0))
      if not bestPerIndex[idx] or duration < bestPerIndex[idx] then
        bestPerIndex[idx] = duration
        bestSegmentTimes[idx] = duration
        bestSegmentLaps[idx] = oneBasedLap
      end
      local segEntry = {
        lap = oneBasedLap,
        segment = idx,
        startTime = s.beginTime,
        endTime = s.endTime,
        duration = duration,
        skipped = false,
        isBest = false,
        diffToPrevious = nil,
        diffToBest = nil
      }
      table.insert(segmentTimes, segEntry)
      segmentTimesByLap[oneBasedLap] = segmentTimesByLap[oneBasedLap] or {}
      segmentTimesByLap[oneBasedLap][idx] = segEntry
    end
  end

  -- Process current lap segments from currentTimes
  for idx = 1, #state.currentTimes do
    local s = state.currentTimes[idx]
    local duration = s.duration or ((s.endTime or 0) - (s.beginTime or 0))
    if not bestPerIndex[idx] or duration < bestPerIndex[idx] then
      bestPerIndex[idx] = duration
      bestSegmentTimes[idx] = duration
      bestSegmentLaps[idx] = (state.currentLap or 0) + 1
    end
    local segEntry = {
      lap = (state.currentLap or 0) + 1,
      segment = idx,
      startTime = s.beginTime,
      endTime = s.endTime,
      duration = duration,
      skipped = false,
      isBest = false,
      diffToPrevious = nil,
      diffToBest = nil
    }
    table.insert(segmentTimes, segEntry)
    local currentLapIndex1 = (state.currentLap or 0) + 1
    segmentTimesByLap[currentLapIndex1] = segmentTimesByLap[currentLapIndex1] or {}
    segmentTimesByLap[currentLapIndex1][idx] = segEntry
  end

  -- Compute diffs and mark bests
  -- Build quick access map lap->index->duration
  local lapIndexToDuration = {}
  for _, seg in ipairs(segmentTimes) do
    lapIndexToDuration[seg.lap] = lapIndexToDuration[seg.lap] or {}
    lapIndexToDuration[seg.lap][seg.segment] = seg.duration
  end

  for _, seg in ipairs(segmentTimes) do
    if lapIndexToDuration[seg.lap - 1] and lapIndexToDuration[seg.lap - 1][seg.segment] then
      seg.diffToPrevious = seg.duration - lapIndexToDuration[seg.lap - 1][seg.segment]
    end
    local bestAtIdx = bestPerIndex[seg.segment]
    seg.diffToBest = bestAtIdx and (seg.duration - bestAtIdx) or nil
    if bestAtIdx and seg.duration == bestAtIdx then
      seg.isBest = true
    end
  end

  -- Update best lap tracking
  bestLapTime = bestLap
  bestLapIndex = 0
  if bestLapTime then
    for i, lap in ipairs(lapData) do
      if lap.duration == bestLapTime then
        bestLapIndex = i
        break
      end
    end
  end

  -- Populate slow stream data directly
  table.clear(slowStreamData)

  -- Race status
  slowStreamData.status = status

  -- Current lap and segment
  slowStreamData.currentLap = currentLap
  slowStreamData.currentSegment = currentSegment

  -- Best times
  slowStreamData.bestLapTimeFormatted = bestLapTime and M.formatTime(bestLapTime) or nil
  slowStreamData.bestLapIndex = bestLapIndex

  -- Format best segment times with lap information
  slowStreamData.bestSegmentTimesFormatted = {}
  for segmentIndex, time in pairs(bestSegmentTimes) do
    local lap = bestSegmentLaps[segmentIndex] or 1
    slowStreamData.bestSegmentTimesFormatted[segmentIndex] = {
      time = M.formatTime(time),
      lap = lap
    }
  end

  -- Historical lap times - build stream directly from temporary data
  slowStreamData.lapTimes = {}
  local prevLapDuration = nil

  for i, lap in ipairs(lapData) do
    -- Calculate diffs
    local diffToPrevious = prevLapDuration and (lap.duration - prevLapDuration) or nil
    local diffToBest = bestLapTime and (lap.duration - bestLapTime) or nil
    local isBest = bestLapTime and lap.duration == bestLapTime or false
    -- Only mark as best if there are multiple laps to compare
    local hasMultipleLaps = #lapData > 1

    local lapInfo = {
      lap = lap.lap,
      durationFormatted = M.formatTime(lap.duration),
      timeFormatted = lap.time and M.formatTime(lap.time) or nil,
      endTimeFormatted = M.formatTime(lap.endTime),
      lapFlavor = (isBest and hasMultipleLaps) and 'best' or 'default',
      diffToPreviousFormatted = diffToPrevious and M.formatTime(diffToPrevious, true) or nil,
      diffToBestFormatted = diffToBest and M.formatTime(diffToBest, true) or nil,
      diffToPreviousFlavor = diffToPrevious and getDiffFlavor(diffToPrevious) or 'default',
      diffToBestFlavor = diffToBest and getDiffFlavor(diffToBest) or 'default'
    }
    table.insert(slowStreamData.lapTimes, lapInfo)
    prevLapDuration = lap.duration
  end

  -- Historical segment times
  slowStreamData.segmentTimes = {}

  -- Count how many times each segment index appears
  local segmentCounts = {}
  for _, segment in ipairs(segmentTimes) do
    segmentCounts[segment.segment] = (segmentCounts[segment.segment] or 0) + 1
  end

  for i, segment in ipairs(segmentTimes) do
    -- Only mark as best if there are multiple instances of this segment to compare
    local hasMultipleInstances = segmentCounts[segment.segment] > 1

    local segmentInfo = {
      segment = segment.lap and (segment.lap .. '-' .. segment.segment) or segment.segment,
      durationFormatted = M.formatTime(segment.duration),
      timeFormatted = segment.time and M.formatTime(segment.time) or nil,
      endTimeFormatted = M.formatTime(segment.endTime),
      segmentFlavor = (segment.isBest and hasMultipleInstances) and 'best' or 'default',
      diffToPreviousFormatted = segment.diffToPrevious and M.formatTime(segment.diffToPrevious, true) or nil,
      diffToBestFormatted = segment.diffToBest and M.formatTime(segment.diffToBest, true) or nil,
      diffToPreviousFlavor = segment.diffToPrevious and getDiffFlavor(segment.diffToPrevious) or 'default',
      diffToBestFlavor = segment.diffToBest and getDiffFlavor(segment.diffToBest) or 'default'
    }
    table.insert(slowStreamData.segmentTimes, segmentInfo)
  end

  -- Combined lap+segment list (alternating segments then lap for completed laps, plus current lap segments)
  slowStreamData.combinedTimes = {}

  -- Include completed laps (from historicTimes)
  for i, lap in ipairs(lapData) do
    -- Add all segments for this lap
    if segmentTimesByLap[lap.lap] then
      for segmentIndex = 1, totalSegments do
        local segment = segmentTimesByLap[lap.lap][segmentIndex]
        if segment then
          local hasMultipleInstances = segmentCounts[segment.segment] > 1
          local combinedSegmentInfo = {
            type = 'segment',
            lap = segment.lap,
            segment = segment.segment,
            identifier = segment.lap .. '-' .. segment.segment,
            durationFormatted = M.formatTime(segment.duration),
            timeFormatted = segment.time and M.formatTime(segment.time) or nil,
            endTimeFormatted = M.formatTime(segment.endTime),
            flavor = (segment.isBest and hasMultipleInstances) and 'best' or 'default',
            diffToPreviousFormatted = segment.diffToPrevious and M.formatTime(segment.diffToPrevious, true) or nil,
            diffToBestFormatted = segment.diffToBest and M.formatTime(segment.diffToBest, true) or nil,
            diffToPreviousFlavor = segment.diffToPrevious and getDiffFlavor(segment.diffToPrevious) or 'default',
            diffToBestFlavor = segment.diffToBest and getDiffFlavor(segment.diffToBest) or 'default'
          }
          table.insert(slowStreamData.combinedTimes, combinedSegmentInfo)
        end
      end
    end

    -- Add the lap itself after all its segments
    local diffToPrevious = i > 1 and (lap.duration - lapData[i-1].duration) or nil
    local diffToBest = bestLapTime and (lap.duration - bestLapTime) or nil
    local isBest = bestLapTime and lap.duration == bestLapTime or false
    local hasMultipleLaps = #lapData > 1

    local combinedLapInfo = {
      type = 'lap',
      lap = lap.lap,
      identifier = lap.lap,
      durationFormatted = M.formatTime(lap.duration),
      timeFormatted = lap.time and M.formatTime(lap.time) or nil,
      endTimeFormatted = M.formatTime(lap.endTime),
      flavor = (isBest and hasMultipleLaps) and 'best' or 'default',
      diffToPreviousFormatted = diffToPrevious and M.formatTime(diffToPrevious, true) or nil,
      diffToBestFormatted = diffToBest and M.formatTime(diffToBest, true) or nil,
      diffToPreviousFlavor = diffToPrevious and getDiffFlavor(diffToPrevious) or 'default',
      diffToBestFlavor = diffToBest and getDiffFlavor(diffToBest) or 'default'
    }
    table.insert(slowStreamData.combinedTimes, combinedLapInfo)
  end

  -- Add completed segments from current lap (if any)
  local currentLapIndex1 = (state.currentLap or 0) + 1
  if segmentTimesByLap[currentLapIndex1] and not state.complete then
    for segmentIndex = 1, totalSegments do
      local segment = segmentTimesByLap[currentLapIndex1][segmentIndex]
      if segment then
        local hasMultipleInstances = segmentCounts[segment.segment] > 1
        local combinedSegmentInfo = {
          type = 'segment',
          lap = segment.lap,
          segment = segment.segment,
          identifier = segment.lap .. '-' .. segment.segment,
          durationFormatted = M.formatTime(segment.duration),
          timeFormatted = segment.time and M.formatTime(segment.time) or nil,
          endTimeFormatted = M.formatTime(segment.endTime),
          flavor = (segment.isBest and hasMultipleInstances) and 'best' or 'default',
          diffToPreviousFormatted = segment.diffToPrevious and M.formatTime(segment.diffToPrevious, true) or nil,
          diffToBestFormatted = segment.diffToBest and M.formatTime(segment.diffToBest, true) or nil,
          diffToPreviousFlavor = segment.diffToPrevious and getDiffFlavor(segment.diffToPrevious) or 'default',
          diffToBestFlavor = segment.diffToBest and getDiffFlavor(segment.diffToBest) or 'default'
        }
        table.insert(slowStreamData.combinedTimes, combinedSegmentInfo)
      end
    end
  end

  -- Set flag for onUpdate to send the stream
  needSlowStream = true
end

-- Update static data from race state
local function updateStaticFromRace(race, playerId)
  if not race then
    return
  end

  -- Update meta information
  totalLaps = race.lapCount or totalLaps
  local segments = 0
  if race.path and race.path.pathnodes and race.path.pathnodes.sorted then
    segments = #race.path.pathnodes.sorted
  end
  totalSegments = segments
  closedCircuit = race.path and race.path.config and race.path.config.closed or false

  -- Populate static stream data directly
  table.clear(staticStreamData)

  staticStreamData.totalLaps = totalLaps
  staticStreamData.totalSegments = totalSegments
  staticStreamData.closedCircuit = closedCircuit

  -- Set flag for onUpdate to send the stream
  needStaticStream = true
end

-- Update placement data from race state
local function updatePlacementFromRace(race, playerId)
  if not race then
    return
  end

  -- Handle placement (simplified for now)
  table.clear(placements)
  table.clear(placementOrder)
  -- TODO: Build placement from race.states if needed

  -- Populate placement stream data directly
  table.clear(placementStreamData)

  -- TODO: Build placement data from race.states
  placementStreamData.placements = placements
  placementStreamData.order = placementOrder

  -- Set flag for onUpdate to send the stream
    needPlacementStream = true
end


-- Main update function (called from extension system)
local function onUpdate(dtReal, dtSim, dtRaw)
  -- Only send streams when flagged - data is already prepared by updateXFromRace functions
  if needFastStream then
    guihooks.queueStream("lapTimes_fast", fastStreamData)
    needFastStream = false
  end
  if needSlowStream then
    guihooks.queueStream("lapTimes_slow", slowStreamData)
    needSlowStream = false
  end
  if needStaticStream then
    guihooks.queueStream("lapTimes_static", staticStreamData)
    needStaticStream = false
  end
  if needPlacementStream then
    guihooks.queueStream("lapTimes_placement", placementStreamData)
    needPlacementStream = false
  end
end

--------------------------------------------------------------------
-- Public interface
--------------------------------------------------------------------

-- Core control functions
M.initialize = initialize

-- Utility functions
M.formatTime = formatTime
M.getDiffFlavor = getDiffFlavor
M.setConfiguration = setConfiguration
M.onRaceStart = onRaceStart
M.onRaceStop = onRaceStop

M.updateFastFromRace = updateFastFromRace
M.updateSlowFromRace = updateSlowFromRace
M.updateStaticFromRace = updateStaticFromRace
M.updatePlacementFromRace = updatePlacementFromRace

-- Main update function
M.onUpdate = onUpdate

--------------------------------------------------------------------
-- New Race System hooks
--------------------------------------------------------------------

local function newRaceStart(race)
  local segments = 0
  if race.path and race.path.pathnodes and race.path.pathnodes.sorted then
    segments = #race.path.pathnodes.sorted
  end
  M.setConfiguration({
    totalLaps = race.lapCount or 0,
    totalSegments = segments,
    closedCircuit = race.path and race.path.config and race.path.config.closed or false
  })
end


local function newRaceStop()
  M.onRaceStop()
end

M.newRaceStart = newRaceStart
M.newRaceStop = newRaceStop

--------------------------------------------------------------------
-- Old Race scenario hooks (kept for compatibility)
--------------------------------------------------------------------

local function onRaceStart()
  -- Legacy hook - functionality moved to onRaceStart(meta)
end

local function onRaceWaypointReached(wpInfo)
  -- Legacy hook - not used in new system
end

local function onRaceResult(final)
  -- Legacy hook - not used in new system
end


return M
