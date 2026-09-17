-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local RallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local RallyManager = require('/lua/ge/extensions/gameplay/rally/rallyManager')
local RecoveryClockAdvance = require('/lua/ge/extensions/gameplay/rally/recoveryClockAdvance')
local Penalties = require('/lua/ge/extensions/gameplay/rally/loop/penalties')
local ScheduleUtils = require('/lua/ge/extensions/gameplay/rally/loop/scheduleUtils')
local RoadSectionPenaltyKeeper = require('/lua/ge/extensions/gameplay/rally/loop/roadSectionPenaltyKeeper')
local SpeedingDetector = require('/lua/ge/extensions/gameplay/rally/loop/speedingDetector')
local TrafficExclusion = require('/lua/ge/extensions/gameplay/rally/trafficExclusion')
local RallyEventLog = require('/lua/ge/extensions/gameplay/rally/loop/rallyEventLog')
local UiColors = require('/lua/ge/extensions/gameplay/rally/loop/uiColors')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local RallyLoopTime = require('/lua/ge/extensions/gameplay/rally/loop/rallyLoopTime')
-- local dbgDraw = require('utils/debugDraw')

local C = {}
local logTag = ''
local stageNumbers = {1, 2, 3, 4}

local serviceOut = "serviceOut"
local serviceIn = "serviceIn"
local showStageAppsKey = 'rallyShowStageApps'

local distanceUnit = "km"

local serviceParkSpeedLimitKph = 30

-- Time allocation buffer multipliers
local roadSectionTimeBufferMultiplier = 1.0  -- No buffer for road sections (liaisons)
local specialStageTimeBufferMultiplier = 1.0  -- No buffer for special stages (competitive)

local function startPositionNames(racePath)
  local names = {}
  if racePath and racePath.startPositions and racePath.startPositions.sorted then
    for _, startPosition in ipairs(racePath.startPositions.sorted) do
      table.insert(names, tostring(startPosition.name))
    end
  end
  return table.concat(names, ', ')
end

-- UI Configuration
local USE_24H_FORMAT = true  -- Set to false for AM/PM format

local function roundToTenth(value)
  -- Round value to nearest tenth (one decimal place)
  if not value then return nil end
  return math.floor(value * 10 + 0.5) / 10
end

local function convertSpeedForDisplay(speedKmh)
  -- Convert speed limit from km/h to display units (km/h or mph)
  -- For imperial, rounds to nearest 5 for cleaner display
  if not speedKmh then return nil, 'km/h' end
  local unitSystem = settings.getValue('uiUnitLength')
  if unitSystem == 'imperial' then
    local speedMph = speedKmh * 0.621371
    local rounded = math.floor(speedMph / 5 + 0.5) * 5  -- Round to nearest 5
    return rounded, 'mph'
  else
    return speedKmh, 'km/h'
  end
end

function C:getServiceParkSpeedLimitKph()
  return serviceParkSpeedLimitKph
end

function C:getServiceParkSpeedLimitDisplay()
  local value, unit = convertSpeedForDisplay(serviceParkSpeedLimitKph)
  return string.format('%d %s', value, unit)
end

function C:init(missionId, missionDir)
  if gameplay_rallyLoop and gameplay_rallyLoop.getDebugLogging() then log('D', logTag, '<<<<< RallyLoopManager init >>>>>') end
  self.missionId = missionId
  self.missionDir = missionDir
  log('D', logTag, 'missionId='..tostring(missionId)..' missionDir='..tostring(missionDir))

  -- Initialize draw flags
  self.drawFlags = {
    showDebugInfo = false
  }

  -- Initialize countdown skip state (updated by countdown node via event)
  self.countdownCanSkip = false

  -- Initialize active state (updated by rally data events)
  self.currentActiveState = RallyUtil.activeState_inactive
  self.currentVehicleProximity = nil
  self.currentCountdownData = nil

  -- Initialize test mode
  self.testMode = false
  self.testActiveState = nil

  -- Initialize rally clock data table (updated in-place for GC efficiency)
  self.rallyClockData = {
    wallClockTime = nil,
    day = nil,
    totalTime = 0,
    canSkipTimeControls = false,
    isTimeControlSkipAvailable = false,
    earlyTimeControlPenaltiesEnabled = false,
    canSkipCountdown = false,
    isNgrcMode = self.isNgrcMode
  }

  -- Initialize schedule data table (updated in-place for GC efficiency)
  self.scheduleData = {
    label = nil,
    eventType = nil,
    ssLabel = nil,
    eventWallClockStart = nil,
    eventWallClockEnd = nil,
    timeDiff = nil,
    timeDiffWithEnd = nil,
    lateness = nil,
    penalty = 0,
    hasPenalty = false,
    canIncurLatePenalty = false,
    totalSSCount = 0,
    speedLimit = nil,
    speedLimitDisplay = nil,
    speedUnit = 'km/h',
    inServicePark = false,
    isSpeeding = false
  }

  -- Initialize timecard data (minimal array for timecard UI)
  self.timecardData = {}

  -- Initialize UI color data (updated in-place for GC efficiency)
  self.uiColors = {}
  UiColors.updateForLoop(self.uiColors, self.isNgrcMode)

  -- Initialize stream data table (updated in-place for GC efficiency)
  self.streamData = {
    activeState = RallyUtil.activeState_inactive,
    rallyClock = self.rallyClockData,
    stageData = nil,
    vehicleProximity = self.currentVehicleProximity,
    countdownData = self.currentCountdownData,
    scheduleData = self.scheduleData,
    timecardData = self.timecardData,
    penaltyData = nil,
    showStageApps = true,
    missionName = nil,
    uiColors = self.uiColors
  }

  -- Initialize wall clock with current environment time of day
  local currentTime = self:getTimeOfDay()
  if currentTime and currentTime.time then
    -- Convert 0-1 to seconds of day (same as getTimeOfDayFormatted)
    local timeIn24 = currentTime.time * 24  -- Hours as float (0-24)
    local adjustedHours = (timeIn24 + 12) % 24  -- Shift by 12 hours (noon -> 0)
    self.environmentStartTimeSecs = adjustedHours * 3600  -- Convert to seconds
    self.wallClockStartTimeSecs = self.environmentStartTimeSecs  -- Alias for compatibility
    log('D', logTag, string.format('Environment start time: %.0f seconds', self.environmentStartTimeSecs))
  else
    self.environmentStartTimeSecs = 0  -- Default to midnight if we can't get time
    self.wallClockStartTimeSecs = 0
    log('W', logTag, 'Could not get environment time, defaulted to midnight')
  end

  -- The rally epoch clock - will be initialized after calculating rally start time
  -- Starts negative (before rally start), reaches 0 at rally start, then positive
  self.clock = 0  -- Will be set properly in calculateSchedule
  -- self.clockPaused = false  -- Can be toggled to pause/resume time progression
  self.clockPaused = true  -- start the clock paused, and it will be enabled when the start button is clicked

  -- Initialize mission sequence tracking
  self.missionSequence = {}
  self.currentMissionIndex = 0

  -- initialize schedule
  self.scheduleParams = {
    -- Rally pre-start timing
    currentTimeToRallyStartSecs = 2 * 60, -- Time from environment start to first TC (rally begins)

    -- TC to Start Line timing
    tcToStartLinePlannedSecs = 1 * 60, -- Planned time from TC_out to SS_start_line (initial schedule)
    tcToStartLineMinimumSecs = 1 * 60, -- Minimum delay from TC arrival to SS_start_line (enforced at runtime)
    tcArrivalRescheduleThresholdSecs = 35, -- Reschedule start line if < 35s until scheduled time when arriving at TC

    -- Rescheduling
    slotSizeMinutes = 1 -- Minute slot size for start line rescheduling (when not staged at -10s)
  }

  -- initialize skip parameters
  self.skipParams = {
    secondsBeforeEvent = 1, -- Skip to this many seconds before the next TC event
    distanceMetersMin = 5, -- Minimum distance from TC waypoint to enable skip (meters)
    distanceMeters = 50, -- Maximum distance from TC waypoint to enable skip (meters)
    maxVelocity = serviceParkSpeedLimitKph / 3.6 -- Maximum velocity to enable skip (m/s)
  }
  self.schedule = nil
  self.scheduleValid = true
  self.validationIssues = {}
  self.rallyStartTimeSecs = nil

  self.missionExecutionTransferFlag = false

  -- Initialize event log for all events (timecards, recoveries, flips, penalties)
  self.eventLog = RallyEventLog()

  -- Get flowgraph variables from the mission instance
  self.fgVariables = {}
  local mission = gameplay_missions_missions.getMissionById(missionId)
  if mission then
    -- if mission.mgr and mission.mgr.variables then
      -- Access the flowgraph variable manager
      -- self.fgMgr = mission.mgr
      -- log('D', logTag, 'Got flowgraph manager from mission')
    -- end
    -- Also store the original fgVariables table if needed
    if mission.fgVariables then
      self.fgVariables = mission.fgVariables
      log('D', logTag, 'fgVariables='..dumps(self.fgVariables))

      -- Build mission sequence from flowgraph variables
      self:buildMissionSequence()

      -- Calculate schedule for all missions in the sequence
      self:calculateSchedule(true)

      -- Start at first mission in sequence
      if self:isScheduleValid() and #self.missionSequence > 0 then
        self.currentMissionIndex = 1
        log('D', logTag, 'Initialized to first mission: ' .. tostring(self.missionSequence[1]))
      else
        self.currentMissionIndex = 0
      end
    end
    self.mission = mission
    self.missionName = mission.name
  else
    log('W', logTag, 'Could not find mission instance for id: '..tostring(missionId))
  end

  -- Initialize mission-owned settings after the mission object is available.
  self:initSettings()
  self.rallyClockData.isNgrcMode = self.isNgrcMode
  UiColors.updateForLoop(self.uiColors, self.isNgrcMode)
end

-- init settings with the loop manager so they cant be changed during the loop
function C:resolveMissionBoolSetting(key, defaultValue)
  local value = self.mission and self.mission.lastUserSettings and self.mission.lastUserSettings[key]
  if value ~= nil then
    return value
  end

  if settings and settings.getValue then
    value = settings.getValue(key)
    if value ~= nil then
      return value
    end
  end

  return defaultValue
end

function C:resolveGlobalBoolSetting(key, defaultValue)
  if settings and settings.getValue then
    local value = settings.getValue(key)
    if value ~= nil then
      return value
    end
  end

  return defaultValue
end

function C:isDevTrafficDisabled()
  return self.mission
    and self.mission.devMission == true
    and self.mission.missionTypeData
    and self.mission.missionTypeData.devDisableTraffic == true
end

function C:initSettings()
  self.enableFalseStarts = self:resolveMissionBoolSetting('rallyEnableFalseStarts', true)
  self.repairVehicleOnRecovery = self:resolveMissionBoolSetting('rallyRepairVehicleOnRecovery', true)
  self.earlyTimeControlPenaltiesEnabled = self:resolveMissionBoolSetting('rallyEnableEarlyTimeControlPenalties', false)
  self.trafficEnabled = not self:isDevTrafficDisabled()
    and self:resolveMissionBoolSetting('rallyEnableTraffic', true)
  self.showStageApps = self:resolveGlobalBoolSetting(showStageAppsKey, true)
  self.isNgrcMode = not self.repairVehicleOnRecovery
end

function C:applyStartScreenSettings(values)
  if type(values) ~= 'table' then return end

  if values.rallyEnableFalseStarts ~= nil then
    self.enableFalseStarts = values.rallyEnableFalseStarts == true
  end
  if values.rallyRepairVehicleOnRecovery ~= nil then
    self.repairVehicleOnRecovery = values.rallyRepairVehicleOnRecovery == true
  end
  if values.rallyEnableEarlyTimeControlPenalties ~= nil then
    self.earlyTimeControlPenaltiesEnabled = values.rallyEnableEarlyTimeControlPenalties == true
  end

  self.isNgrcMode = not self.repairVehicleOnRecovery
  self.rallyClockData.isNgrcMode = self.isNgrcMode
  self.rallyClockData.earlyTimeControlPenaltiesEnabled = self.earlyTimeControlPenaltiesEnabled == true
  UiColors.updateForLoop(self.uiColors, self.isNgrcMode)
end

function C:getRecoveryRepairVehicle()
  if self.repairVehicleOnRecovery == nil then
    self.repairVehicleOnRecovery = self:resolveMissionBoolSetting('rallyRepairVehicleOnRecovery', true)
  end
  if self.repairVehicleOnRecovery then return true end
  -- Hardcore/NGRC: no repair on competitive stages, but marshals can repair
  -- the vehicle after a recovery on liaisons and other non-SS sections.
  return not self:isInSpecialStage()
end

function C:getTrafficEnabled()
  if self:isDevTrafficDisabled() then return false end
  if self.trafficEnabled == nil then
    self.trafficEnabled = self:resolveMissionBoolSetting('rallyEnableTraffic', true)
  end
  return self.trafficEnabled
end

function C:getShowStageApps()
  if self.showStageApps == nil then
    self.showStageApps = self:resolveGlobalBoolSetting(showStageAppsKey, true)
  end
  return self.showStageApps ~= false
end

function C:onSettingsChanged()
  self.showStageApps = self:resolveGlobalBoolSetting(showStageAppsKey, true)
end

function C:extractMissionId(value)
  -- Extract mission ID from "Mission Name (mission-id)" format
  if not value or value == "<none>" then
    return nil
  end
  local missionId = value:match("%((.+)%)$")
  return missionId
end

function C:_getExpectedScheduleLabel(missionType, nextSSNumber, roadSectionCount)
  if missionType == 'rallyRoadSection' then
    return "ROAD" .. tostring((roadSectionCount or 0) + 1)
  elseif missionType == 'rallyStage' then
    return "SS" .. tostring(nextSSNumber or '?')
  end
  return nil
end

function C:_getValidationHint(missionType, errorMessage)
  local msg = string.lower(tostring(errorMessage or ""))
  if msg:find("driveline") then
    if missionType == 'rallyRoadSection' then
      return "Check that the driveline reaches TC_out."
    elseif missionType == 'rallyStage' then
      return "Check that the driveline reaches SS_stop_control."
    end
    return "Check that the driveline reaches the finish control."
  elseif msg:find("race") then
    return "Check race.race.json exists and contains required start positions."
  end
  return nil
end

function C:_addValidationIssue(issue)
  self.validationIssues = self.validationIssues or {}
  issue.blocking = issue.blocking ~= false
  table.insert(self.validationIssues, issue)
  self.scheduleValid = false
end

function C:buildMissionSequence()
  -- Build the linear sequence: serviceOutMission -> stages -> serviceInMission
  local sequence = {}

  -- Start with serviceOutMission
  -- local serviceOut = self:extractMissionId(self.fgVariables.serviceOutMission)
  -- if serviceOut then
    table.insert(sequence, serviceOut)
  -- end

  -- Add stages in order
  for _, stageNum in ipairs(stageNumbers) do
    local roadSection = self:extractMissionId(self.fgVariables["stage"..stageNum.."_rallyRoadSection"])
    local stage = self:extractMissionId(self.fgVariables["stage"..stageNum.."_rallyStage"])

    if roadSection then
      table.insert(sequence, roadSection)
    end
    if stage then
      table.insert(sequence, stage)
    end
  end

  -- Add serviceIn road section before service in mission
  local returnRoadSection = self:extractMissionId(self.fgVariables.return_rallyRoadSection)
  if returnRoadSection then
    table.insert(sequence, returnRoadSection)
  end

  -- End with serviceInMission
  -- local serviceIn = self:extractMissionId(self.fgVariables.serviceInMission)
  -- if serviceIn then
    table.insert(sequence, serviceIn)
  -- end

  -- Add rallyLoop mission after serviceIn to wind up the loop
  -- table.insert(sequence, self.missionId)

  self.missionSequence = sequence
  self.currentMissionIndex = 0
  log('D', logTag, 'Mission sequence built: '..dumps(self.missionSequence))

  -- Validate the built sequence
  -- if not self:validateMissionSequence() then
  --   log('E', logTag, 'Mission sequence validation failed')
  --   self.missionSequence = {}
  --   self.currentMissionIndex = 0
  --   return
  -- end
end

function C:validateMissionSequence()
  -- Check that sequence is not empty
  -- if #self.missionSequence == 0 then
  --   log('E', logTag, 'Mission sequence is empty')
  --   return false
  -- end

  -- Must have at least serviceOut and serviceIn (minimum 2 missions)
  -- if #self.missionSequence < 2 then
  --   log('E', logTag, 'Mission sequence must have at least 2 missions (serviceOut and serviceIn)')
  --   return false
  -- end

  -- First mission should be serviceOutMission
  local firstMissionId = self.missionSequence[1]
  local serviceOutId = self:extractMissionId(self.fgVariables.serviceOutMission)
  if firstMissionId ~= serviceOutId then
    log('E', logTag, 'Mission sequence must start with serviceOutMission')
    return false
  end

  -- TODO disabling for now since we're still developing
  -- Last mission should be serviceInMission
  -- local lastMissionId = self.missionSequence[#self.missionSequence]
  -- local serviceInId = self:extractMissionId(self.fgVariables.serviceInMission)
  -- if lastMissionId ~= serviceInId then
  --   log('E', logTag, 'Mission sequence must end with serviceInMission')
  --   return false
  -- end

  return true
end

function C:calculateRallyStartTime()
  -- Calculate rally start time (round environment start time to next minute, then add delay)
  if not self.environmentStartTimeSecs then
    log('E', logTag, 'Environment start time not set')
    return 0
  end

  local currentTimeSecs = self.environmentStartTimeSecs

  -- Round up to next minute
  local roundedTimeSecs = math.ceil(currentTimeSecs / 60) * 60
  -- Add delay to rally start
  local rallyStartTimeSecs = roundedTimeSecs + (self.scheduleParams.currentTimeToRallyStartSecs or 0)

  self.rallyStartTimeSecs = rallyStartTimeSecs

  log('D', logTag, string.format('Rally start time: %.0f seconds (%.2f minutes from environment start)',
    rallyStartTimeSecs, (rallyStartTimeSecs - currentTimeSecs) / 60))

  return rallyStartTimeSecs
end

function C:getRallyStartTimeSecs()
  return self.rallyStartTimeSecs
end

function C:getRallyStartTimeFormatted()
  return self:formatTimeFromSecondsString(self.rallyStartTimeSecs, false, false)
end

function C:getRallyStartDurationSecs()
  -- Return actual duration from environment start time to rally start time
  if not self.rallyStartTimeSecs or not self.environmentStartTimeSecs then
    return nil
  end
  return self.rallyStartTimeSecs - self.environmentStartTimeSecs
end

function C:getRallyPreStartAllocatedDurationSecs()
  return self.scheduleParams.currentTimeToRallyStartSecs
end

function C:getSlotSizeMinutes()
  return self.scheduleParams.slotSizeMinutes
end

function C:getWallClockTimeSecs()
  -- Returns the current wall clock time in seconds of day
  -- self.clock is in rally epoch, so add rally start time to get wall clock
  if not self.rallyStartTimeSecs then
    return nil
  end
  return (self.rallyStartTimeSecs + self.clock) % 86400  -- Wrap around at 24 hours (86400 seconds)
end

function C:getWallClockDay()
  -- Returns the current day number (1-based)
  if not self.rallyStartTimeSecs then
    return nil
  end
  local totalSecs = self.rallyStartTimeSecs + self.clock
  return math.floor(totalSecs / 86400) + 1  -- Day 1, Day 2, etc.
end

function C:getWallClockTimeFormatted()
  -- Returns formatted wall clock time with day counter (Day X - HH:MM:SS.T / HH:MM:SS.T AM/PM)
  local wallClockSecs = self:getWallClockTimeSecs()
  local day = self:getWallClockDay()
  if not wallClockSecs or not day then
    return "N/A"
  end
  local timeStr = self:formatTimeFromSecondsString(wallClockSecs, true, true)
  return string.format("%s, Day %d", timeStr, day)
end

function C:getEpochTime()
  -- self.clock is already in rally epoch
  -- Can be negative (before rally officially starts)
  return self.clock
end

function C:getEpochTimeFormatted()
  local epochTime = self:getEpochTime()
  local sign = epochTime >= 0 and "+" or "-"
  local timeStr = self:formatTimeFromSecondsString(math.abs(epochTime), true, false)
  return sign .. timeStr
end

function C:setClockPaused(paused)
  self.clockPaused = paused
end

function C:getClockPaused()
  return self.clockPaused
end

function C:adjustClock(seconds)
  self.clock = self.clock + seconds
end

function C:getScheduledEventTime(eventName)
  -- Find the scheduled time for the event matching the given name in the current mission
  if not eventName or eventName == '' then
    log('W', logTag, 'getScheduledEventTime: No event name provided')
    return nil
  end

  -- Get current mission ID
  local currentMissionId = self:getCurrentMissionId()
  if not currentMissionId then
    log('W', logTag, 'getScheduledEventTime: No current mission ID')
    return nil
  end

  -- Get events list
  if not self.events or #self.events == 0 then
    log('W', logTag, 'getScheduledEventTime: No events in schedule')
    return nil
  end

  -- Search for event matching the name and current mission
  for i, event in ipairs(self.events) do
    if event.missionId == currentMissionId and event.spName == eventName then
      -- log('D', logTag, string.format('Found event "%s" for mission "%s" at time %.2f',
      --   eventName, currentMissionId, event.time or -1))
      return event.time
    end
  end

  log('W', logTag, string.format('Event "%s" not found for current mission "%s"', eventName, currentMissionId))
  return nil
end

function C:calculateSchedule(includeDebugData)
  includeDebugData = includeDebugData or false

  -- Initialize schedule calculation state
  local state = self:_initScheduleCalculation()
  -- local serviceOutId = state.serviceOutId
  -- local serviceInId = state.serviceInId
  local returnRoadSectionId = state.returnRoadSectionId
  local serviceInRoadSectionId = returnRoadSectionId
  local startingSSNumber = state.startingSSNumber
  local nextSSNumber = state.nextSSNumber
  local roadSectionCount = state.roadSectionCount
  local lastTCLabel = state.lastTCLabel
  local currentScheduleTimeSecs = state.currentScheduleTimeSecs

  -- Process each mission in the sequence
  for i, missionId in ipairs(self.missionSequence) do
    if missionId == serviceOut then
      lastTCLabel = self:_addServiceOutToSchedule(currentScheduleTimeSecs, startingSSNumber)
    elseif missionId == serviceIn then
      self:_addServiceInToSchedule()
    else
      -- Handle regular mission (stage or road section)
      local result = self:_processRegularMission(missionId, currentScheduleTimeSecs, nextSSNumber, roadSectionCount, lastTCLabel, serviceInRoadSectionId, includeDebugData)
      currentScheduleTimeSecs = result.currentScheduleTimeSecs
      nextSSNumber = result.nextSSNumber
      roadSectionCount = result.roadSectionCount
      lastTCLabel = result.lastTCLabel
      if not result.success then
        self.events = {}
        self.nextEventIndex = 1
        log('W', logTag, 'Schedule calculation aborted after failed mission: ' .. tostring(missionId))
        return false
      end
      -- Increment SS count if this was a stage
      if result.isStage then
        self.totalSSCount = self.totalSSCount + 1
      end
    end
  end

  -- Post-process schedule entries
  self:_postProcessSchedule()
  self.scheduleValid = true
  return true
end

function C:getCurrentMissionId()
  if self.currentMissionIndex > 0 and self.currentMissionIndex <= #self.missionSequence then
    return self.missionSequence[self.currentMissionIndex]
  end
  return nil
end

function C:isInRoadSection()
  -- Check if we're currently in a road section mission (liaison stage)
  -- Returns true only for road sections, false for serviceOut, serviceIn, stages, etc.
  if not self.schedule or self.currentMissionIndex <= 0 then
    return false
  end

  local scheduleEntry = self.schedule[self.currentMissionIndex]
  if not scheduleEntry then
    return false
  end

  -- Road sections have roadSectionLabel, service missions have missionType, stages have ssLabel
  return scheduleEntry.roadSectionLabel ~= nil
end

function C:isInSpecialStage()
  -- Check if we're currently in a special stage (competitive timed section)
  -- Returns true only for SS stages, false for road sections, service missions, etc.
  if not self.schedule or self.currentMissionIndex <= 0 then
    return false
  end

  local scheduleEntry = self.schedule[self.currentMissionIndex]
  if not scheduleEntry then
    return false
  end

  -- Special stages have ssLabel
  return scheduleEntry.ssLabel ~= nil
end

function C:shouldPenalizeSpeeding()
  -- Speeding penalties only apply when NOT in special stages
  -- In special stages, drivers are encouraged to go fast
  return not self:isInSpecialStage()
end

function C:getRallyLoopMissionId()
  return self.missionId
end

function C:getRallyLoopName()
  return self.missionName
end

function C:getRallyLoopMission()
  return self.mission
end

function C:getVoicepackPickForMission(missionId, missionDir)
  local value = self.mission and self.mission.lastUserSettings and self.mission.lastUserSettings.rallyVoicepackPick
  return voicepack.resolveLoopVoicepackPick(missionDir, missionId, value)
end

function C:getNextMissionId()
  if #self.missionSequence == 0 then
    log('W', logTag, 'Mission sequence is empty')
    return nil
  end

  self.currentMissionIndex = self.currentMissionIndex + 1
  if self.currentMissionIndex > #self.missionSequence then
    log('D', logTag, 'Reached end of mission sequence')
    return nil
  end

  local nextMissionId = self.missionSequence[self.currentMissionIndex]
  log('D', logTag, 'Next mission ID: '..tostring(nextMissionId))
  return nextMissionId
end

function C:startNextMission()
  local nextMissionId = self:getNextMissionId()

  if not nextMissionId then
    log('E', logTag, 'Failed to get next mission ID')
    return false
  end

  -- Check if we're in an active mission context
  if not gameplay_missions_missionManager.getForegroundMissionId() then
    log('W', logTag, 'No foreground mission active, cannot transfer execution')
    return false
  end

  log('D', logTag, 'Starting next mission: '..nextMissionId)

  local nextMission = gameplay_missions_missions.getMissionById(nextMissionId)
  if not nextMission then
    log('E', logTag, 'Could not find mission: '..nextMissionId)
    return false
  end

  self.missionExecutionTransferFlag = true
  -- gameplay_missions_missionManager.startFromWithinMission(nextMission)
  -- gameplay_missions_missionManager.startSeamless(nextMission)
  local instant = true
  gameplay_missions_missionManager.startFromWithinMission(nextMission, nil, instant)

  return true
end

function C:restartRallyLoop()
  self.missionExecutionTransferFlag = true
  local mission = gameplay_missions_missions.getMissionById(self:getRallyLoopMissionId())
  if not mission then
    log('E', logTag, 'Could not find rallyLoop mission for restart: '..self:getRallyLoopMissionId())
    return
  end
  local instant = true
  gameplay_missions_missionManager.startFromWithinMission(mission, nil, instant)
end

function C:gotoRallyLoopInstant()
  self.missionExecutionTransferFlag = true
  local mission = gameplay_missions_missions.getMissionById(self:getRallyLoopMissionId())
  if not mission then
    log('E', logTag, 'Could not find rallyLoop mission for goto instant: '..self:getRallyLoopMissionId())
    return
  end
  local instant = true
  gameplay_missions_missionManager.startFromWithinMission(mission, nil, instant)
end

function C:getSchedule()
  return self.schedule
end

local function formatStageLabel(label)
  if label == nil then
    return nil
  end
  local text = tostring(label)
  if text == '' then
    return nil
  end
  if text:find('^SS') then
    return text
  end
  return 'SS' .. text
end

function C:getStageLabels()
  local labels = {}
  for _, entry in ipairs(self.schedule or {}) do
    if entry.ssLabel then
      labels[#labels + 1] = formatStageLabel(entry.ssLabel)
    end
  end
  return labels
end

function C:isScheduleValid()
  return self.scheduleValid ~= false
end

function C:getValidationIssues()
  return self.validationIssues or {}
end

function C:hasValidationIssues()
  return self.validationIssues and #self.validationIssues > 0
end

function C:getEvents()
  return self.events
end

function C:getNextEventIndex()
  return self.nextEventIndex
end

function C:getCurrentRacePath()
  -- Get current mission from schedule
  if self.currentMissionIndex <= 0 or self.currentMissionIndex > #self.missionSequence then
    return nil
  end

  -- Get schedule entry for current mission
  if not self.schedule or not self.schedule[self.currentMissionIndex] then
    return nil
  end

  local scheduleEntry = self.schedule[self.currentMissionIndex]

  -- Check if this is an actual mission (not serviceOut/serviceIn placeholder)
  if scheduleEntry.notActualMission then
    return nil
  end

  -- Construct race file path
  local missionDir = scheduleEntry.missionDir
  if not missionDir then
    return nil
  end

  return missionDir .. '/race.race.json'
end

function C:advanceToNextEvent()
  -- Advance to next event (includes events with or without scheduled times)
  if not self.events then return end

  local startIndex = self.nextEventIndex + 1
  if startIndex <= #self.events then
    self.nextEventIndex = startIndex
    log('D', logTag, 'Advanced to next event: ' .. startIndex .. ' (' .. self.events[startIndex].label .. ')')
  else
    -- No more events
    self.nextEventIndex = #self.events + 1
    log('D', logTag, 'No more events')
  end
end

function C:filterTimingResultForSettings(timingResult)
  -- When early TC penalties are disabled, strip early penalties but keep status/late penalties.
  if not timingResult or self.earlyTimeControlPenaltiesEnabled then
    return timingResult
  end

  local filtered = {}
  local totalPenalty = 0
  for _, penaltyData in ipairs(timingResult.penalties or {}) do
    if penaltyData.type ~= 'time_control_early' then
      table.insert(filtered, penaltyData)
      totalPenalty = totalPenalty + (penaltyData.amount or 0)
    end
  end

  return {
    status = timingResult.status,
    totalPenalty = totalPenalty,
    hasPenalty = totalPenalty > 0,
    penalties = filtered
  }
end

function C:recordTimeCardEntry(entryName, stageTimeSecs)
  -- Record a time card entry for an event completion
  if not entryName then
    log('E', logTag, 'recordTimeCardEntry called with no entry name')
    return false
  end

  local currentEvent = self.events and self.events[self.nextEventIndex] or nil
  if not currentEvent then
    log('W', logTag, 'No current event to record for entry: ' .. entryName)
    return false
  end

  -- Validate that we're recording the right event for the right mission
  local currentMissionId = self:getCurrentMissionId()
  if currentEvent.missionId ~= currentMissionId then
    log('E', logTag, string.format('Event mission mismatch: event is for mission %s but current mission is %s (entry: %s)',
      currentEvent.missionId or 'nil', currentMissionId or 'nil', entryName))
    return false
  end

  -- Validate that the entry name matches the event's start position name
  if entryName ~= currentEvent.spName then
    log('E', logTag, string.format('Entry name mismatch: expected "%s" but got "%s" for event %d',
      currentEvent.spName or 'nil', entryName, self.nextEventIndex))
    return false
  end

  -- Create time card entry - store pointer to the event and record timing
  -- self.clock is already in rally epoch
  local timeDiff = currentEvent.time and (self.clock - currentEvent.time) or nil
  local timingResult = nil

  -- Calculate penalty if we have a time difference (only for events that can incur late penalties)
  if timeDiff and currentEvent.canIncurLatePenalty then
    timingResult = self:filterTimingResultForSettings(Penalties.getTimingStatus(self.clock, currentEvent.time))
    local timeControlPenalty = timingResult.totalPenalty

    -- Log individual penalties to eventLog
    for _, penaltyData in ipairs(timingResult.penalties or {}) do
      self.eventLog:addItem(currentEvent, self.clock, 'penalty', {
        penaltyType = penaltyData.type,
        amount = penaltyData.amount,
        checkpointLabel = currentEvent.label,
        minutesEarly = penaltyData.data.minutesEarly,
        minutesLate = penaltyData.data.minutesLate,
        actualMinute = penaltyData.data.actualMinute,
        scheduledMinute = penaltyData.data.scheduledMinute
      })
    end
  end

  -- Check for route recalc penalties on TC events
  -- if currentEvent.type == 'tc' then
  --   -- Query eventLog for route recalc penalties for this event
  --   local logItems = self.eventLog:getItemsByEventGroup(currentEvent.eventGroup)
  --   for _, item in ipairs(logItems) do
  --     if item.type == 'penalty' and item.data.penaltyType == 'route_recalc' and item.eventId == currentEvent.eventId then
  --       log('W', logTag, string.format('Route recalc penalty: +%ds (violation #%d, recalcs: %d)',
  --         item.data.amount, item.data.violationNumber, item.data.recalcCount))
  --     end
  --   end

  --   -- Query eventLog for speeding penalties for this event
  --   for _, item in ipairs(logItems) do
  --     if item.type == 'penalty' and item.data.penaltyType == 'speeding' and item.eventId == currentEvent.eventId then
  --       local modeStr = item.data.strictMode and ' (STRICT)' or ''
  --       log('W', logTag, string.format('Speeding penalty: +%ds (%.1f kph over %d kph)%s',
  --         item.data.amount, item.data.speedOver, item.data.speedLimit, modeStr))
  --     end
  --   end
  -- end

  -- Check for speeding penalties on service_in events
  -- if currentEvent.type == 'service_in' then
  --   -- Query eventLog for speeding penalties for this event
  --   local logItems = self.eventLog:getItemsByEventGroup(currentEvent.eventGroup)
  --   for _, item in ipairs(logItems) do
  --     if item.type == 'penalty' and item.data.penaltyType == 'speeding' and item.eventId == currentEvent.eventId then
  --       local modeStr = item.data.strictMode and ' (STRICT)' or ''
  --       log('W', logTag, string.format('Speeding penalty (service_in): +%ds (%.1f kph over %d kph)%s',
  --         item.data.amount, item.data.speedOver, item.data.speedLimit, modeStr))
  --     end
  --   end
  -- end

  -- Track local data for logging
  local splits = nil

  -- Add stage time if provided
  if stageTimeSecs then
    -- Store split times for SS stop events
    if currentEvent.type == 'ss_stop' then
      local rm = self:getRallyManager()
      if rm then
        splits = rm:getSplitDataList()
      end
    end
  end

  -- Log timecard entry to eventLog
  self.eventLog:addItem(currentEvent, self.clock, 'timecard', {
    actualTime = self.clock,
    timeDiff = timeDiff,
    timingResult = timingResult,
    stageTimeSecs = stageTimeSecs,
    splits = splits
  })

  -- Force show timecard when a time control entry is recorded
  guihooks.trigger('RallyGameplayInteract', { forceShowTimecard = true})


  -- If this is a TC event, check if we need to reschedule the start line
  if currentEvent.type == 'tc' then
    local nextSSEvent, _ = self:_findNextSSStartEvent()
    if nextSSEvent and nextSSEvent.time then
      local timeUntilStartLine = nextSSEvent.time - self.clock
      local threshold = self.scheduleParams.tcArrivalRescheduleThresholdSecs

      if timeUntilStartLine < threshold then
        log('D', logTag, string.format('TC arrival: %.1fs until start line (< %.1fs threshold), rescheduling',
          timeUntilStartLine, threshold))
        self:calculateStartLineTime(self.clock)
      else
        log('D', logTag, string.format('TC arrival: %.1fs until start line (>= %.1fs threshold), no reschedule needed',
          timeUntilStartLine, threshold))
      end
    end
  end

  -- Update this specific timecard entry before advancing
  self:updateTimecardEntry(self.nextEventIndex)

  -- Advance to next event
  self:advanceToNextEvent()

  return true
end

function C:roundToNextMinute(timeSecs)
  -- Delegate to shared utility
  return ScheduleUtils.roundToNextMinute(timeSecs)
end

function C:_findNextSSStartEvent()
  -- Find the next SS start event from current event index (searching forward)
  -- Returns: event, eventIndex (or nil, nil if not found)
  if not self.events or #self.events == 0 then
    return nil, nil
  end

  for i = self.nextEventIndex, #self.events do
    if self.events[i].type == 'ss_start' then
      return self.events[i], i
    end
  end

  return nil, nil
end

function C:_findPreviousSSStartEvent()
  -- Find the previous SS start event from current event index (searching backward)
  -- Used to find the SS start event for the current stage (when at SS stop)
  -- Returns: event, eventIndex (or nil, nil if not found)
  if not self.events or #self.events == 0 then
    return nil, nil
  end

  for i = self.nextEventIndex, 1, -1 do
    if self.events[i].type == 'ss_start' then
      return self.events[i], i
    end
  end

  return nil, nil
end

function C:_findNextTCEvent()
  -- Find the next TC event from current event index (searching forward)
  -- Returns: event, eventIndex (or nil, nil if not found)
  if not self.events or #self.events == 0 then
    return nil, nil
  end

  for i = self.nextEventIndex, #self.events do
    if self.events[i].type == 'tc' then
      return self.events[i], i
    end
  end

  return nil, nil
end

function C:_findPreviousTCEvent()
  -- Find the previous TC event from current event index (searching backward)
  -- Returns: event, eventIndex (or nil, nil if not found)
  if not self.events or #self.events == 0 then
    return nil, nil
  end

  for i = self.nextEventIndex, 1, -1 do
    if self.events[i].type == 'tc' then
      return self.events[i], i
    end
  end

  return nil, nil
end

function C:_updateSSStartTime(newTime, onlyIfLater, reason)
  -- Internal method to update SS start time
  -- newTime: the new scheduled time to set
  -- onlyIfLater: if true, only update if newTime > current time (for late arrivals)
  -- reason: string describing why the reschedule happened (for logging)

  local event, eventIndex = self:_findNextSSStartEvent()
  if not event then
    log('W', logTag, '_updateSSStartTime: No upcoming SS start event found')
    return {success = false, reason = 'no_ss_start_event'}
  end

  local originalTime = event.time

  -- Check if we should update based on onlyIfLater flag
  if onlyIfLater and newTime <= originalTime then
    event.scheduledTimeWasAdjusted = false
    log('D', logTag, string.format('SS start time unchanged at %.2f (calculated %.2f was not later) - %s',
      originalTime, newTime, reason))
    return {success = false, newTime = originalTime, reason = 'not_later'}
  end

  -- Update the time
  event.time = newTime
  event.scheduledTimeWasAdjusted = true
  event.rescheduleCount = (event.rescheduleCount or 0) + 1

  log('D', logTag, string.format('Updated SS start time from %.2f to %.2f - %s (reschedule #%d)',
    originalTime, newTime, reason, event.rescheduleCount))

  return {
    success = true,
    newTime = newTime,
    oldTime = originalTime,
    rescheduleCount = event.rescheduleCount
  }
end

function C:calculateStartLineTime(tcArrivalTime)
  -- Calculate the SS start line time based on TC arrival time
  -- This gives the driver time to prepare (buckle up, etc.) before launching into the competitive stage
  -- Only updates if the new time is LATER than the originally scheduled time (handles late arrivals)

  -- Smart rounding: if we have enough time left in the current minute, use the next minute boundary
  -- Otherwise, schedule to the minute after that
  local secondsIntoMinute = tcArrivalTime % 60
  local secondsUntilNextMinute = 60 - secondsIntoMinute
  local threshold = self.scheduleParams.tcArrivalRescheduleThresholdSecs

  local calculatedStartLineTime
  if secondsUntilNextMinute >= threshold then
    -- Enough time left in current minute - schedule to next minute boundary
    calculatedStartLineTime = self:roundToNextMinute(tcArrivalTime)
    log('D', logTag, string.format('TC arrival at +%.1fs into minute, %.1fs until next minute (>= %.1fs threshold), scheduling to next minute',
      secondsIntoMinute, secondsUntilNextMinute, threshold))
  else
    -- Not enough time - schedule to minute after next
    local minDelay = self.scheduleParams.tcToStartLineMinimumSecs
    calculatedStartLineTime = self:roundToNextMinute(tcArrivalTime + minDelay)
    log('D', logTag, string.format('TC arrival at +%.1fs into minute, %.1fs until next minute (< %.1fs threshold), scheduling to minute after next',
      secondsIntoMinute, secondsUntilNextMinute, threshold))
  end

  local result = self:_updateSSStartTime(calculatedStartLineTime, true, string.format('TC arrival, smart rounding'))
  return result.newTime
end

function C:getEventLog()
  return self.eventLog
end

function C:getTotalSSDistanceKm()
  return self.totalSSDistanceKm or 0
end

function C:getTotalRoadSectionDistanceKm()
  return self.totalRoadSectionDistanceKm or 0
end

function C:getTotalDistanceKm()
  return self.totalDistanceKm or 0
end

function C:getTotalTime()
  return self.eventLog:getTotalTime()
end

function C:getTotalPenalty()
  return self.eventLog:getTotalPenalty()
end

function C:getTimeOfDay()
  -- Shim to get time of day from environment extension

  if core_environment then
    local tod = core_environment.getTimeOfDay()
    if tod then
      -- log('D', logTag, tostring(tod))
    else
      -- log('D', logTag, 'tod is nil')
      -- TODO temporary fix for now
      tod =  {time = 0.92} -- 0.92 is the default start time for italy
    end
    return tod
  end
  return nil
end

function C:formatTimeFromSeconds(timeSecs, includeSeconds, includeTenths)
  -- Use appropriate format based on USE_24H_FORMAT setting
  -- Returns a table: {time = "HH:MM"} or {time = "HH:MM", ampm = "AM"}
  if self:getUse24hFormat() then
    return RallyUtil.formatTime24Hour(timeSecs, includeSeconds, includeTenths)
  else
    return RallyUtil.formatTime12Hour(timeSecs, includeSeconds, includeTenths)
  end
end

function C:formatTimeFromSecondsString(timeSecs, includeSeconds, includeTenths)
  -- Helper to get formatted time as a display string (for debug drawing, etc.)
  local timeTable = self:formatTimeFromSeconds(timeSecs, includeSeconds, includeTenths)
  if timeTable.ampm then
    return timeTable.time .. " " .. timeTable.ampm
  else
    return timeTable.time
  end
end

function C:formatDuration(seconds)
  -- Format relative time duration in M:SS format (e.g., "0:11", "1:33")
  if not seconds then return nil end

  local absSeconds = math.abs(seconds)
  local minutes = math.floor(absSeconds / 60)
  local secs = math.floor(absSeconds % 60)

  return string.format("%d:%02d", minutes, secs)
end

function C:formatStageTime(seconds)
  -- Format stage time as duration with tenths (matches frontend formatSSTime)
  -- Rounds to nearest tenth and formats dynamically based on duration
  if not seconds then return nil end

  -- Round to nearest tenth of a second
  local roundedSeconds = math.floor(seconds * 10 + 0.5) / 10

  local hours = math.floor(roundedSeconds / 3600)
  local minutes = math.floor((roundedSeconds % 3600) / 60)
  local secs = math.floor(roundedSeconds % 60)
  local tenths = math.floor((roundedSeconds % 1) * 10) % 10

  -- Build time string based on which components are non-zero
  if hours > 0 then
    -- Show hours: H:MM:SS.T or HH:MM:SS.T
    return string.format("%d:%02d:%02d.%d", hours, minutes, secs, tenths)
  elseif minutes > 0 then
    -- Show minutes: M:SS.T or MM:SS.T (no leading zero for minutes)
    return string.format("%d:%02d.%d", minutes, secs, tenths)
  else
    -- Show only seconds: S.T or SS.T (no leading zero for seconds)
    return string.format("%d.%d", secs, tenths)
  end
end

function C:getTimeOfDayFormatted()
  -- Get time of day and format as HH:MM:SS / HH:MM:SS AM/PM
  local tod = self:getTimeOfDay()
  if not tod or not tod.time then
    return "N/A"
  end

  -- Convert 0-1 to seconds of day
  -- tod.time = 0 is noon (12:00), so add 12 hours and wrap around
  local timeIn24 = tod.time * 24  -- Hours as float (0-24)
  local adjustedHours = (timeIn24 + 12) % 24  -- Shift by 12 hours (noon -> 0)
  local timeSecs = adjustedHours * 3600  -- Convert to seconds

  return self:formatTimeFromSecondsString(timeSecs, true, false)
end


function C:epochToWallClock(epochTime)
  -- Convert rally epoch time (relative to rally start) to wall clock time (absolute time of day)
  if not epochTime or not self.rallyStartTimeSecs then
    return nil
  end
  return epochTime + self.rallyStartTimeSecs
end

-- Private helper methods for calculateSchedule

function C:_calculateRoadSectionTimes(tcInPos, tcOutPos, currentScheduleTimeSecs, timeAllocationSecs)
  -- Calculate schedule times for road sections
  -- Returns: tcInTime, tcOutTime, sectionDurationSecs, updatedScheduleTime
  local tcInTime = nil
  local tcOutTime = nil
  local sectionDurationSecs = nil
  local updatedScheduleTime = currentScheduleTimeSecs

  if tcInPos then
    -- TC_in uses current time without advancing
    -- For first road section, this will be the same as serviceOut TC
    tcInTime = currentScheduleTimeSecs
  end
  if tcOutPos and timeAllocationSecs then
    -- Apply buffer multiplier to road section time
    local bufferedTime = timeAllocationSecs * roadSectionTimeBufferMultiplier
    -- Add time allocation and round up to next minute
    tcOutTime = self:roundToNextMinute(currentScheduleTimeSecs + bufferedTime)
    sectionDurationSecs = tcOutTime - tcInTime
    -- Advance schedule time to TC_out for next mission
    updatedScheduleTime = tcOutTime
  end

  return tcInTime, tcOutTime, sectionDurationSecs, updatedScheduleTime
end

function C:_calculateStageTimes(ssStartLinePos, ssStopControlPos, currentScheduleTimeSecs, timeAllocationSecs)
  -- Calculate schedule times for special stages
  -- Returns: ssStartLineTime, ssStopControlTime, transitionDurationSecs, sectionDurationSecs, updatedScheduleTime
  local ssStartLineTime = nil
  local ssStopControlTime = nil
  local transitionDurationSecs = nil
  local sectionDurationSecs = nil
  local updatedScheduleTime = currentScheduleTimeSecs

  if ssStartLinePos then
    -- Add delay from last TC_out to SS start line and round up to next minute
    local startLineDelay = self.scheduleParams.tcToStartLinePlannedSecs or 0
    local previousTime = currentScheduleTimeSecs
    ssStartLineTime = self:roundToNextMinute(currentScheduleTimeSecs + startLineDelay)
    transitionDurationSecs = ssStartLineTime - previousTime
    updatedScheduleTime = ssStartLineTime
  end
  if ssStopControlPos and timeAllocationSecs then
    -- Apply buffer multiplier to special stage time
    local bufferedTime = timeAllocationSecs * specialStageTimeBufferMultiplier
    -- Add time allocation and round up to next minute
    ssStopControlTime = self:roundToNextMinute(updatedScheduleTime + bufferedTime)
    sectionDurationSecs = ssStopControlTime - ssStartLineTime
    updatedScheduleTime = ssStopControlTime
  end

  return ssStartLineTime, ssStopControlTime, transitionDurationSecs, sectionDurationSecs, updatedScheduleTime
end

function C:_calculateRoadSectionLabels(roadSectionCount, nextSSNumber, isServiceInRoadSection, lastTCLabel, tcInPos, tcOutPos)
  -- Calculate TC_in and TC_out labels for road sections
  -- Returns: tcInLabel, tcOutLabel, updatedLastTCLabel
  local tcInLabel = nil
  local tcOutLabel = nil
  local updatedLastTCLabel = lastTCLabel

  -- Set TC_in label
  if roadSectionCount == 1 and tcInPos then
    -- First road section has TC_in matching serviceOut
    tcInLabel = lastTCLabel  -- Same as serviceOut
  elseif isServiceInRoadSection and tcInPos then
    -- ServiceIn road section TC_in: use last TC label (from previous road section or stage)
    tcInLabel = lastTCLabel
  end

  -- TC_out logic
  if tcOutPos then
    if isServiceInRoadSection then
      -- ServiceIn road section: TC{lastSS}A (entry to parc fermé)
      tcOutLabel = "TC" .. (nextSSNumber - 1) .. "A"
      log('D', logTag, string.format('ServiceIn road section TC_out: nextSSNumber=%d, label=%s', nextSSNumber, tcOutLabel))
    else
      -- Regular road section: TC{nextSS}
      tcOutLabel = "TC" .. nextSSNumber
    end
    updatedLastTCLabel = tcOutLabel
  end

  log('D', logTag, string.format('Road section %d: TC_in=%s, TC_out=%s, isServiceIn=%s, lastTCLabel=%s',
    roadSectionCount, tcInLabel or 'nil', tcOutLabel or 'nil', tostring(isServiceInRoadSection), updatedLastTCLabel or 'nil'))

  return tcInLabel, tcOutLabel, updatedLastTCLabel
end

function C:_addServiceOutToSchedule(currentScheduleTimeSecs, startingSSNumber)
  -- Process serviceOut mission and add to schedule
  -- Returns: lastTCLabel for subsequent missions
  local tcLabel
  if startingSSNumber == 1 then
    -- Rally start (first loop ever)
    tcLabel = "TC0"
  else
    -- Continuation from previous day - yesterday's final SS was (startingSSNumber - 1)
    -- TC{n}A was entry to parc fermé yesterday, so today starts with TC{n}B
    tcLabel = "TC" .. (startingSSNumber - 1) .. "B"
  end

  table.insert(self.schedule, {
    missionId = serviceOut,
    missionType = 'serviceOut',
    notActualMission = true,
    serviceOutTriggerPos = nil,  -- Will be set in post-processing to first road section's TC_in
    serviceOutTriggerRot = nil,
    tcLabel = tcLabel,
    tcTime = currentScheduleTimeSecs,
    durationSecs = nil,  -- No time allocation for service out
    speedLimitKph = serviceParkSpeedLimitKph
  })
  -- log('D', logTag, 'Added serviceOut to schedule: with label: ' .. tcLabel .. ' at time: ' .. currentScheduleTimeSecs)

  return tcLabel
end

function C:_addServiceInToSchedule()
  -- Process serviceIn mission and add to schedule
  -- ServiceIn has no time allocation since it's not a timed event
  local stallPos = self.fgVariables.serviceStallPos
  table.insert(self.schedule, {
    missionId = serviceIn,
    missionType = 'serviceIn',
    notActualMission = true,
    -- serviceInTriggerPos = nil,  -- Not used - commented out
    serviceStallPos = stallPos,  -- Service stall parking position - NOT a scheduled TC, just where you park
    -- No tcLabel or tcTime - service stall arrival is not a scheduled checkpoint
    durationSecs = nil,  -- No time allocation for service in
    noEvents = true,  -- ServiceIn has no scheduled events
    speedLimitKph = serviceParkSpeedLimitKph
  })
  -- log('D', logTag, 'Added serviceIn to schedule')
  -- log('D', logTag, 'ServiceIn serviceStallPos from fgVariables: ' .. dumps(stallPos))
  -- log('D', logTag, 'ServiceIn schedule entry: ' .. dumps(self.schedule[#self.schedule]))
end

function C:_processRegularMission(missionId, currentScheduleTimeSecs, nextSSNumber, roadSectionCount, lastTCLabel, serviceInRoadSectionId, includeDebugData)
  -- Load and process stage/road section missions
  -- Returns: table with updated values (currentScheduleTimeSecs, nextSSNumber, roadSectionCount, lastTCLabel, success)

  local missionDir = RallyUtil.missionDirHelper(missionId)
  local mission = gameplay_missions_missions.getMissionById(missionId)
  local missionType = mission and mission.missionType or nil
  local isStage = false  -- Will be set to true if this is a stage mission

  -- Create temporary rally manager
  local tempRallyManager = RallyManager(missionDir, missionId)

  -- Load the mission data to calculate distance/time
  local success = tempRallyManager:rebuildAssets()

  if success then
    local dr = tempRallyManager:getDrivelineRoute()
    -- local distanceMeters = dr and dr:getDistanceMeters() or nil
    local distanceMeters = tempRallyManager:getRaceDistanceMeters() or nil
    local distanceKm = distanceMeters and (distanceMeters / 1000) or nil
    local timeAllocationSecs = tempRallyManager:getTimeAllocationSecs()
    local speedLimitKph = tempRallyManager:getSpeedLimitKph()

    -- Extract waypoint positions for debug drawing
    local tcInSP = tempRallyManager:getTCInPos()
    local tcInPos = tcInSP and tcInSP.pos or nil
    local tcInRot = tcInSP and tcInSP.rot or nil
    local tcInName = tcInSP and tcInSP.name or nil
    local tcOutSP = tempRallyManager:getTCOutPos()
    local tcOutPos = tcOutSP and tcOutSP.pos or nil
    local tcOutRot = tcOutSP and tcOutSP.rot or nil
    local tcOutName = tcOutSP and tcOutSP.name or nil
    local ssStartLineSP = tempRallyManager:getSSStartLinePos()
    local ssStartLinePos = ssStartLineSP and ssStartLineSP.pos or nil
    local ssStartLineName = ssStartLineSP and ssStartLineSP.name or nil
    local ssStopControlSP = tempRallyManager:getSSStopControlPos()
    local ssStopControlPos = ssStopControlSP and ssStopControlSP.pos or nil
    local ssStopControlName = ssStopControlSP and ssStopControlSP.name or nil

    -- Store driveline point list for debug drawing (only if requested)
    local drivelinePointList = nil
    if includeDebugData and tempRallyManager.drivelineV3 then
      log('W', logTag, 'including debug data for rallyloop schedule')
      drivelinePointList = tempRallyManager.drivelineV3:getFinalPointList()
    end

    -- Determine if this is a stage. Mission type is authoritative; SS positions
    -- are validated below so broken stage authoring cannot slip through as a road section.
    isStage = missionType == 'rallyStage' or ssStartLinePos ~= nil or ssStopControlPos ~= nil
    local ssLabel = nil
    local roadSectionLabel = nil
    local tcInLabel = nil
    local tcOutLabel = nil

    if isStage then
      if not ssStartLineSP or not ssStopControlSP then
        local missing = {}
        if not ssStartLineSP then table.insert(missing, 'SS_start_line') end
        if not ssStopControlSP then table.insert(missing, 'SS_stop_control') end
        local message = string.format(
          'Special stage is missing required start position(s): %s. Available start positions: [%s]',
          table.concat(missing, ', '),
          startPositionNames(tempRallyManager:getRacePath())
        )
        self:_addValidationIssue({
          type = 'scheduleMissingStageStartPositions',
          missionId = missionId,
          missionType = 'rallyStage',
          label = 'SS'..tostring(nextSSNumber),
          message = message,
          hint = 'Check race.race.json startPositions include SS_start_line and SS_stop_control.'
        })
        success = false
      else
      -- This is a special stage
        ssLabel = "SS" .. nextSSNumber
        ssLabel = tostring(nextSSNumber)
        nextSSNumber = nextSSNumber + 1  -- Increment for next stage
        log('D', logTag, 'Stage detected: ' .. ssLabel)
        -- Accumulate SS distance
        if distanceKm then
          self.totalSSDistanceKm = self.totalSSDistanceKm + distanceKm
          self.totalDistanceKm = self.totalDistanceKm + distanceKm
        end
      end
    else
      -- This is a road section with TCs
      roadSectionCount = roadSectionCount + 1
      roadSectionLabel = "ROAD" .. roadSectionCount
      -- Accumulate road section distance
      if distanceKm then
        self.totalRoadSectionDistanceKm = self.totalRoadSectionDistanceKm + distanceKm
        self.totalDistanceKm = self.totalDistanceKm + distanceKm
      end

      local liaisonTimeSecs = tempRallyManager:getLiaisonAllocatedTimeSecs()
      if liaisonTimeSecs then
        timeAllocationSecs = liaisonTimeSecs
      end

      -- Check if this is the serviceIn road section (special case)
      local isServiceInRoadSection = (missionId == serviceInRoadSectionId)
      log('D', logTag, string.format('Checking road section: missionId=%s, serviceInRoadSectionId=%s, isServiceIn=%s',
        missionId or 'nil', serviceInRoadSectionId or 'nil', tostring(isServiceInRoadSection)))

      tcInLabel, tcOutLabel, lastTCLabel = self:_calculateRoadSectionLabels(roadSectionCount, nextSSNumber, isServiceInRoadSection, lastTCLabel, tcInPos, tcOutPos)
    end

    if not success then
      tempRallyManager = nil
      return {
        currentScheduleTimeSecs = currentScheduleTimeSecs,
        nextSSNumber = nextSSNumber,
        roadSectionCount = roadSectionCount,
        lastTCLabel = lastTCLabel,
        success = false,
        isStage = isStage
      }
    end

    -- Calculate schedule times for this mission
    local tcInTime = nil
    local tcOutTime = nil
    local ssStartLineTime = nil
    local ssStopControlTime = nil
    local transitionDurationSecs = nil  -- Time from previous waypoint to start of this section
    local sectionDurationSecs = nil     -- Time for the section itself

    if isStage then
      -- Special stage: start line gets current time + TC to start line delay, stop control gets time after stage
      ssStartLineTime, ssStopControlTime, transitionDurationSecs, sectionDurationSecs, currentScheduleTimeSecs =
        self:_calculateStageTimes(ssStartLinePos, ssStopControlPos, currentScheduleTimeSecs, timeAllocationSecs)
    else
      -- Road section: TC_in gets current time, TC_out gets time after transit
      tcInTime, tcOutTime, sectionDurationSecs, currentScheduleTimeSecs =
        self:_calculateRoadSectionTimes(tcInPos, tcOutPos, currentScheduleTimeSecs, timeAllocationSecs)
    end

    table.insert(self.schedule, {
      missionId = missionId,
      missionDir = missionDir,
      distanceKm = distanceKm,
      timeAllocationSecs = timeAllocationSecs,
      speedLimitKph = speedLimitKph,
      tcInPos = tcInPos,
      tcInRot = tcInRot,
      tcInName = tcInName,
      tcInLabel = tcInLabel,
      tcInTime = tcInTime,
      tcOutPos = tcOutPos,
      tcOutRot = tcOutRot,
      tcOutName = tcOutName,
      tcOutLabel = tcOutLabel,
      tcOutTime = tcOutTime,
      ssStartLinePos = ssStartLinePos,
      ssStartLineName = ssStartLineName,
      ssStartLineTime = ssStartLineTime,
      ssStopControlPos = ssStopControlPos,
      ssStopControlName = ssStopControlName,
      ssStopControlTime = ssStopControlTime,
      ssLabel = ssLabel,
      roadSectionLabel = roadSectionLabel,
      drivelinePointList = drivelinePointList,
      transitionDurationSecs = transitionDurationSecs,
      sectionDurationSecs = sectionDurationSecs,
      noEvents = nil
    })

    log('D', logTag, string.format('Schedule calculated for %s: %.2f km, %s',
      missionId, distanceKm or 0, tempRallyManager:getTimeAllocationString() or 'N/A'))
  else
    local errorMessage = tempRallyManager:getErrorMsgForUser() or 'Failed to load mission'
    local expectedLabel = self:_getExpectedScheduleLabel(missionType, nextSSNumber, roadSectionCount)
    local hint = self:_getValidationHint(missionType, errorMessage)
    log('W', logTag, 'Failed to calculate schedule for mission: ' .. missionId .. ' (' .. tostring(errorMessage) .. ')')
    self:_addValidationIssue({
      type = 'scheduleLoadFailed',
      missionId = missionId,
      missionType = missionType,
      label = expectedLabel,
      message = errorMessage,
      hint = hint
    })
  end

  -- Clean up temporary rally manager (allow garbage collection)
  tempRallyManager = nil

  return {
    currentScheduleTimeSecs = currentScheduleTimeSecs,
    nextSSNumber = nextSSNumber,
    roadSectionCount = roadSectionCount,
    lastTCLabel = lastTCLabel,
    success = success,
    isStage = isStage
  }
end

function C:_initScheduleCalculation()
  -- Initialize schedule state, service IDs, counters, rally start time, and distance totals
  -- Returns: table with initialization values

  -- Initialize schedule storage as an array
  self.schedule = {}
  self.events = {}
  self.nextEventIndex = 1  -- Index of next event to complete (1-based)
  self.scheduleValid = true
  self.validationIssues = {}

  -- Get service mission IDs for comparison
  -- local serviceOutId = self:extractMissionId(self.fgVariables.serviceOutMission)
  -- local serviceInId = self:extractMissionId(self.fgVariables.serviceInMission)
  local returnRoadSectionId = self:extractMissionId(self.fgVariables.return_rallyRoadSection)

  -- Get starting SS number from mission configuration (defaults to 1 for rally start)
  local startingSSNumber = self.fgVariables.startingSSNumber or 1
  local nextSSNumber = startingSSNumber  -- Next special stage number to assign
  local roadSectionCount = 0  -- Counter for road sections seen
  local lastTCLabel = nil  -- Track the last TC label assigned

  -- Calculate rally start time (for wall clock display purposes)
  local rallyStartTimeSecs = self:calculateRallyStartTime()
  -- Schedule times are stored in rally epoch (relative to rally start), starting at 0
  local currentScheduleTimeSecs = 0

  -- Initialize self.clock in rally epoch
  -- Clock starts negative (before rally start), will reach 0 at rally start, then positive
  self.clock = -(rallyStartTimeSecs - self.environmentStartTimeSecs)
  log('D', logTag, string.format('Clock initialized to rally epoch: %.2f seconds', self.clock))

  log('D', logTag, 'Starting SS number: ' .. startingSSNumber)

  -- Initialize distance totals
  self.totalSSDistanceKm = 0
  self.totalRoadSectionDistanceKm = 0
  self.totalDistanceKm = 0

  -- Initialize total SS count
  self.totalSSCount = 0

  -- Initialize road section penalty keeper
  self.roadSectionPenaltyKeeper = RoadSectionPenaltyKeeper(self)

  -- Initialize speeding detector
  self.speedingDetector = SpeedingDetector(self)

  return {
    -- serviceOutId = serviceOutId,
    -- serviceInId = serviceInId,
    returnRoadSectionId = returnRoadSectionId,
    startingSSNumber = startingSSNumber,
    nextSSNumber = nextSSNumber,
    roadSectionCount = roadSectionCount,
    lastTCLabel = lastTCLabel,
    rallyStartTimeSecs = rallyStartTimeSecs,
    currentScheduleTimeSecs = currentScheduleTimeSecs
  }
end

function C:_postProcessSchedule()
  -- Set serviceOut trigger position
  if #self.schedule > 1 then
    local serviceOutEntry = self.schedule[1]
    if serviceOutEntry.missionType == 'serviceOut' then
      local nextEntry = self.schedule[2]
      -- Set serviceOutTriggerPos to first road section's TC_in
      if nextEntry.tcInPos and nextEntry.tcInRot then
        serviceOutEntry.serviceOutTriggerPos = {nextEntry.tcInPos.x, nextEntry.tcInPos.y, nextEntry.tcInPos.z}
        -- Flip rot about the z axis (nextEntry.tcInRot is already a quat object)
        -- local rot = nextEntry.tcInRot * quat(0, 0, 1, 0)
        local rot = nextEntry.tcInRot
        serviceOutEntry.serviceOutTriggerRot = {rot.x, rot.y, rot.z, rot.w}
        log('D', logTag, 'Set serviceOutTriggerPos to first road section TC_in')
      end
    end
  end

  -- Build events list from schedule
  self:_buildEventsFromSchedule()

  -- Initialize timecard data once at startup
  self:initTimecardData()

  log('D', logTag, string.format('Schedule calculation complete - Total SS: %.2f km, Total Road Section: %.2f km, Total Distance: %.2f km',
    self.totalSSDistanceKm, self.totalRoadSectionDistanceKm, self.totalDistanceKm))
end

function C:_buildEventsFromSchedule()
  -- Build linear event sequence from schedule entries
  -- Events are the actual waypoints/checkpoints that vehicles interact with
  -- All times are already in rally epoch (relative to rally start)
  self.events = {}

  for i, entry in ipairs(self.schedule) do
    if entry.missionType == 'serviceOut' then
      -- ServiceOut: TC event
      if entry.tcLabel and entry.tcTime and entry.serviceOutTriggerPos then
        -- Get the name from the first road section's TC_in (since serviceOut trigger uses that position)
        local spName = nil
        if #self.schedule > 1 then
          local nextEntry = self.schedule[i + 1]
          if nextEntry then
            spName = nextEntry.tcInName
          end
        end
        table.insert(self.events, {
          type = 'tc',
          label = entry.tcLabel,
          spName = spName,
          time = entry.tcTime,
          pos = entry.serviceOutTriggerPos,
          missionId = entry.missionId,
          missionIndex = i,
          canIncurLatePenalty = true,
          eventId = entry.tcLabel,
          eventGroup = "SERVICE",
          inServicePark = true
        })
      end
    elseif entry.missionType == 'serviceIn' then
      -- ServiceIn: Add event for service bay arrival
      table.insert(self.events, {
        type = 'service_in',
        label = 'Service Bay',
        spName = nil,
        time = nil,  -- No scheduled time
        pos = entry.serviceStallPos,
        missionId = entry.missionId,
        missionIndex = i,
        hideTimecardEntry = true,
        canIncurLatePenalty = false,
        eventId = "SERVICE_IN",
        eventGroup = "SERVICE",
        inServicePark = true
      })
    else
      -- Regular missions: stages or road sections
      if entry.ssLabel then
        -- Special Stage events
        if entry.ssStartLinePos and entry.ssStartLineTime then
          table.insert(self.events, {
            type = 'ss_start',
            label = 'Start Line',
            spName = entry.ssStartLineName,
            time = entry.ssStartLineTime,
            pos = {entry.ssStartLinePos.x, entry.ssStartLinePos.y, entry.ssStartLinePos.z},
            missionId = entry.missionId,
            missionIndex = i,
            hideTimecardEntry = true,
            canIncurLatePenalty = false,
            eventId = "SS" .. entry.ssLabel .. "_start",
            eventGroup = "SS" .. entry.ssLabel,
            inServicePark = false
          })
        end
        if entry.ssStopControlPos and entry.ssStopControlTime then
          table.insert(self.events, {
            type = 'ss_stop',
            label = 'Stop Control',
            spName = entry.ssStopControlName,
            time = entry.ssStopControlTime,
            pos = {entry.ssStopControlPos.x, entry.ssStopControlPos.y, entry.ssStopControlPos.z},
            missionId = entry.missionId,
            missionIndex = i,
            hideTimecardEntry = true,
            canIncurLatePenalty = false,
            eventId = "SS" .. entry.ssLabel .. "_stop",
            eventGroup = "SS" .. entry.ssLabel,
            inServicePark = false
          })
        end
      elseif entry.roadSectionLabel then
        -- Road Section events (only TC_out, as TC_in is usually same as previous TC_out)
        if entry.tcOutPos and entry.tcOutLabel and entry.tcOutTime then
          table.insert(self.events, {
            type = 'tc',
            label = entry.tcOutLabel,
            spName = entry.tcOutName,
            time = entry.tcOutTime,
            pos = {entry.tcOutPos.x, entry.tcOutPos.y, entry.tcOutPos.z},
            missionId = entry.missionId,
            missionIndex = i,
            canIncurLatePenalty = true,
            eventId = entry.tcOutLabel,
            eventGroup = entry.tcOutLabel,
            inServicePark = false
          })
        end
      end
    end
  end

  log('D', logTag, string.format('Built events list with %d events', #self.events))

  -- Initialize nextEventIndex to first event with a scheduled time
  self.nextEventIndex = 0
  for i = 1, #self.events do
    if self.events[i].time then
      self.nextEventIndex = i
      log('D', logTag, 'Initialized nextEventIndex to first event: ' .. i)
      break
    end
  end
  if self.nextEventIndex == 0 then
    self.nextEventIndex = 1  -- Fallback if no valid events found
  end
end

function C:initTimecardData()
  -- Build initial timecard structure once when schedule is calculated
  -- This creates the array structure that will be updated in-place
  self.timecardData = {}
  self.streamData.timecardData = self.timecardData

  if not self.events or #self.events == 0 then
    return
  end

  -- Track which SS stages we've added to avoid duplicates
  local addedStages = {}

  -- Loop through all events and build initial timecard entries
  for i, event in ipairs(self.events) do
    -- For TC events (timecard entries)
    if not event.hideTimecardEntry then
      local entry = {
        label = event.label,
        scheduledTime = nil,  -- Formatted wall clock time string
        recordedTime = nil,   -- Formatted wall clock time string when recorded
        status = nil,         -- "early"/"late"/"on-time"
        group = nil,
        isStageEntry = false
      }

      -- Get scheduled time in wall clock format (if event has a time)
      if event.time then
        local wallClockSecs = self:epochToWallClock(event.time)
        -- For 12-hour format, store as table {time, ampm}; for 24-hour, store as string
        if self:getUse24hFormat() then
          entry.scheduledTime = RallyUtil.formatTime24Hour(wallClockSecs, false, false)
        else
          entry.scheduledTime = RallyUtil.formatTime12Hour(wallClockSecs, false, false)
        end
      end

      -- Extract number from label for grouping (e.g., "TC1" -> "1")
      local numberMatch = string.match(event.label or "", "%d+$")
      if numberMatch then
        entry.group = "group-" .. numberMatch
      end

      table.insert(self.timecardData, entry)
      event.timecardIndex = #self.timecardData
    end

    -- For SS stages, add a stage time entry (once per stage, when we see ss_stop)
    if event.type == 'ss_stop' and event.missionIndex then
      local scheduleEntry = self.schedule[event.missionIndex]
      if scheduleEntry and scheduleEntry.ssLabel and not addedStages[scheduleEntry.ssLabel] then
        local entry = {
          label = "SS"..scheduleEntry.ssLabel,  -- e.g., "SS1", "SS2"
          stageTime = nil,  -- Will be filled when stage completes (formatted with seconds and tenths)
          isStageEntry = true,
          group = "group-" .. scheduleEntry.ssLabel
        }

        table.insert(self.timecardData, entry)
        event.timecardIndex = #self.timecardData
        addedStages[scheduleEntry.ssLabel] = true

        log('D', logTag, 'Added stage entry to timecard: ' .. scheduleEntry.ssLabel)
      end
    end
  end
end

function C:updateTimecardEntry(eventIndex)
  -- Update a single timecard entry when timecard is recorded
  -- This is much more efficient than rebuilding the entire array
  if not self.events or not self.events[eventIndex] then
    return
  end

  local event = self.events[eventIndex]

  -- Only update if this event has a timecard entry
  if event.timecardIndex and self.timecardData[event.timecardIndex] then
    local entry = self.timecardData[event.timecardIndex]

    -- Query eventLog for timecard entry for this event
    local logItems = self.eventLog:getItemsByEventGroup(event.eventGroup)
    local timecardItem = nil
    for _, item in ipairs(logItems) do
      if item.type == 'timecard' and item.eventId == event.eventId then
        timecardItem = item
        break
      end
    end

    -- Update recorded time from timecard entry
    if timecardItem and timecardItem.data.actualTime then
      local wallClockSecs = self:epochToWallClock(timecardItem.data.actualTime)
      -- For 12-hour format, store as table {time, ampm}; for 24-hour, store as string
      if self:getUse24hFormat() then
        entry.recordedTime = RallyUtil.formatTime24Hour(wallClockSecs, false, false)
      else
        entry.recordedTime = RallyUtil.formatTime12Hour(wallClockSecs, false, false)
      end

      -- Update status (early/late/on-time) from timing result
      if timecardItem.data.timingResult and timecardItem.data.timingResult.status then
        entry.status = timecardItem.data.timingResult.status
      end
    end

    -- For ss_stop events, also update the stage time (formatted with seconds and tenths)
    if event.type == 'ss_stop' and timecardItem and timecardItem.data.stageTimeSecs then
      entry.stageTime = self:formatStageTime(timecardItem.data.stageTimeSecs)
    end
  end
end

function C:updateScheduleData()
  -- Updates schedule data table in-place for GC efficiency
  local nextEvent = self.events and self.events[self.nextEventIndex]

  if not nextEvent then
    self.scheduleData.label = nil
    self.scheduleData.eventType = nil
    self.scheduleData.ssLabel = nil
    self.scheduleData.eventWallClockStart = nil
    self.scheduleData.eventWallClockEnd = nil
    self.scheduleData.timeDiff = nil
    self.scheduleData.timeDiffWithEnd = nil
    self.scheduleData.lateness = nil
    self.scheduleData.penalty = 0
    self.scheduleData.hasPenalty = false
    self.scheduleData.canIncurLatePenalty = false
    self.scheduleData.totalSSCount = self.totalSSCount
    self.scheduleData.speedLimit = nil
    self.scheduleData.speedLimitDisplay = nil
    self.scheduleData.speedUnit = 'km/h'
    self.scheduleData.inServicePark = false
    self.scheduleData.isSpeeding = false
    return
  end

  -- Get SS label and speed limit from schedule entry
  local ssLabel = nil
  local speedLimit = nil
  if self.schedule and nextEvent.missionIndex then
    local scheduleEntry = self.schedule[nextEvent.missionIndex]
    if scheduleEntry then
      ssLabel = scheduleEntry.ssLabel  -- e.g., "SS1", "SS2"
      speedLimit = scheduleEntry.speedLimitKph
    end
  end

  -- Handle events with no scheduled time (like serviceIn)
  if not nextEvent.time then
    -- ServiceIn or other non-timed events
    self.scheduleData.label = nextEvent.label
    self.scheduleData.eventType = nextEvent.type
    self.scheduleData.ssLabel = ssLabel
    self.scheduleData.eventWallClockStart = nil
    self.scheduleData.eventWallClockEnd = nil
    self.scheduleData.timeDiff = nil
    self.scheduleData.timeDiffWithEnd = nil
    self.scheduleData.lateness = nil
    self.scheduleData.penalty = 0
    self.scheduleData.hasPenalty = false
    self.scheduleData.canIncurLatePenalty = nextEvent.canIncurLatePenalty or false
    self.scheduleData.totalSSCount = self.totalSSCount
    self.scheduleData.speedLimit = speedLimit
    self.scheduleData.speedLimitDisplay, self.scheduleData.speedUnit = convertSpeedForDisplay(speedLimit)
    self.scheduleData.inServicePark = nextEvent.inServicePark or false

    -- Calculate isSpeeding status
    local isSpeeding = false
    if self:shouldPenalizeSpeeding() and self.schedule and self.currentMissionIndex > 0 then
      local scheduleEntry = self.schedule[self.currentMissionIndex]
      if scheduleEntry and scheduleEntry.speedLimitKph then
        local veh = getPlayerVehicle(0)
        if veh then
          local velocityMs = veh:getVelocity():length()
          local currentSpeedKph = velocityMs * 3.6
          if currentSpeedKph > scheduleEntry.speedLimitKph then
            isSpeeding = true
          end
        end
      end
    end
    self.scheduleData.isSpeeding = isSpeeding

    return
  end

  -- Calculate time difference and penalty status for timed events
  -- timeDiff convention: negative = early, positive = late
  local currentEpochTime = self:getEpochTime()
  local timeDiff = currentEpochTime - nextEvent.time
  local timeDiffWithEnd = currentEpochTime - (nextEvent.time + 59)
  local timingResult = self:filterTimingResultForSettings(Penalties.getTimingStatus(currentEpochTime, nextEvent.time))

  -- Format event label (e.g., "TC0", "SS1")
  local eventLabel = nextEvent.label

  -- Calculate the start and end of the scheduled minute (on-time window)
  -- nextEvent.time is already minute-aligned (e.g., 9:42:00)
  local eventWallClockStartSecs = self:epochToWallClock(nextEvent.time)
  -- local eventWallClockEndSecs = self:epochToWallClock(nextEvent.time + 59) -- inclusive end range
  local eventWallClockEndSecs = self:epochToWallClock(nextEvent.time + 60) --exclusive end range

  self.scheduleData.label = eventLabel
  self.scheduleData.eventType = nextEvent.type
  self.scheduleData.ssLabel = ssLabel
  self.scheduleData.eventWallClockStart = self:formatTimeFromSeconds(eventWallClockStartSecs, false, false)
  self.scheduleData.eventWallClockEnd = self:formatTimeFromSeconds(eventWallClockEndSecs, false, false)
  self.scheduleData.timeDiff = self:formatDuration(timeDiff)
  self.scheduleData.timeDiffWithEnd = self:formatDuration(timeDiffWithEnd)
  self.scheduleData.lateness = timingResult.status
  self.scheduleData.penalty = timingResult.totalPenalty
  self.scheduleData.hasPenalty = timingResult.hasPenalty
  self.scheduleData.canIncurLatePenalty = nextEvent.canIncurLatePenalty or false
  self.scheduleData.totalSSCount = self.totalSSCount
  self.scheduleData.speedLimit = speedLimit
  self.scheduleData.speedLimitDisplay, self.scheduleData.speedUnit = convertSpeedForDisplay(speedLimit)
  self.scheduleData.inServicePark = nextEvent.inServicePark or false

  -- Calculate isSpeeding status
  local isSpeeding = false
  if self:shouldPenalizeSpeeding() and self.schedule and self.currentMissionIndex > 0 then
    local scheduleEntry = self.schedule[self.currentMissionIndex]
    if scheduleEntry and scheduleEntry.speedLimitKph then
      local veh = getPlayerVehicle(0)
      if veh then
        local velocityMs = veh:getVelocity():length()
        local currentSpeedKph = velocityMs * 3.6
        if currentSpeedKph > scheduleEntry.speedLimitKph then
          isSpeeding = true
        end
      end
    end
  end
  self.scheduleData.isSpeeding = isSpeeding
end

function C:getRallyManager()
  if not extensions.isExtensionLoaded('gameplay_rally') then return nil end
  if self.rallyManager then return self.rallyManager end
  self.rallyManager = gameplay_rally.getRallyManager()
  return self.rallyManager
end

function C:getUse24hFormat()
  return USE_24H_FORMAT
end

function C:getWallClockTimeTable()
  -- Returns wall clock time as a table (same format as timecard entries)
  -- Returns nil if wall clock time is not available
  local wallClockSecs = self:getWallClockTimeSecs()
  if not wallClockSecs then
    return nil
  end

  if self:getUse24hFormat() then
    return RallyUtil.formatTime24Hour(wallClockSecs, true, false)
  else
    return RallyUtil.formatTime12Hour(wallClockSecs, true, false)
  end
end

function C:updateRallyClockData()
  -- Updates rally clock data table in-place for GC efficiency
  self.rallyClockData.wallClockTime = self:getWallClockTimeTable()
  self.rallyClockData.day = self:getWallClockDay()
  self.rallyClockData.totalTime = self:formatStageTime(self:getTotalTime())

  self.rallyClockData.canSkipTimeControls = self:canSkipTimeControls()
  self.rallyClockData.isTimeControlSkipAvailable = self:isTimeControlSkipAvailable()
  self.rallyClockData.earlyTimeControlPenaltiesEnabled = self.earlyTimeControlPenaltiesEnabled == true

  self.rallyClockData.canSkipCountdown = self:canSkipCountdown()
end

function C:activateRallyModeInteractActionMap(enabled)
  enabled = enabled or false
  if enabled then
    pushActionMap('RallyModeInteract')
  else
    popActionMap('RallyModeInteract')
  end
end

function C:onUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("rallyLoopManager:onUpdate")
  if not self.clockPaused then
    self.clock = self.clock + dtSim
  end
  self:evaluateSkip()
  self:activateRallyModeInteractActionMap(self:canSkip())

  -- Update penalty keeper for cleanup and state management
  if self.roadSectionPenaltyKeeper then
    self.roadSectionPenaltyKeeper:onUpdate()
  end

  -- Update speeding detector (only in road sections where speed limits apply)
  if self.speedingDetector and self:shouldPenalizeSpeeding() then
    local scheduleEntry = self.schedule[self.currentMissionIndex]
    if scheduleEntry and scheduleEntry.speedLimitKph then
      -- Enable strict mode for serviceIn and serviceOut
      local strictMode = scheduleEntry.missionType == 'serviceIn' or scheduleEntry.missionType == 'serviceOut'
      self.speedingDetector:update(dtSim, scheduleEntry.speedLimitKph, strictMode)
    end
  end

  profilerPopEvent("rallyLoopManager:onUpdate")
end

function C:onGuiUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("rallyLoopManager:onGuiUpdate")
  -- self.clock = self.clock + dtSim
  profilerPopEvent("rallyLoopManager:onGuiUpdate")
end

local skipEventPos = vec3()
function C:evaluateSkip()
  -- Evaluate whether skip is available based on position, velocity, and timing.
  -- Penalties off: auto clock-skip when slow enough near a TC.
  -- Penalties on: manual clock-skip via interact when slow enough near a TC.
  self:setCanSkipTimeControls(false, false)

  local nextEvent = self.events and self.events[self.nextEventIndex]
  if nextEvent and nextEvent.type == 'tc' then
    local timeUntilEvent = nextEvent.time - self.clock
    if timeUntilEvent > self.skipParams.secondsBeforeEvent then
      local veh = getPlayerVehicle(0)
      if veh then
        local vehPos = veh:getPosition()
        skipEventPos:set(nextEvent.pos[1], nextEvent.pos[2], nextEvent.pos[3])
        local distanceSq = vehPos:squaredDistance(skipEventPos)
        local distanceThresholdSq = square(self.skipParams.distanceMeters)
        local distanceThresholdSqMin = square(self.skipParams.distanceMetersMin)
        local velocity = veh:getVelocity():length()
        if distanceSq < distanceThresholdSq and distanceSq > distanceThresholdSqMin then
          if self.earlyTimeControlPenaltiesEnabled then
            if velocity < self.skipParams.maxVelocity then
              self:setCanSkipTimeControls(true, true)
            elseif velocity > self.skipParams.maxVelocity+0.5 then -- asymmetric threshold for skipping
              self:setCanSkipTimeControls(false, true)
            end
          else
            if velocity < self.skipParams.maxVelocity then
              self:setCanSkipTimeControls(false, true)
              self:skipToNextEvent()
            elseif velocity > self.skipParams.maxVelocity+0.5 then -- asymmetric threshold for skipping
              self:setCanSkipTimeControls(false, true)
            end
          end
        end
      end
    end
  end
end

function C:setCanSkipTimeControls(canSkip, isTimeControlSkipAvailable)
  self.canSkipTimeControlsFlag = canSkip or false
  self.isTimeControlSkipAvailableFlag = isTimeControlSkipAvailable or false
end

function C:isTimeControlSkipAvailable()
  return self.isTimeControlSkipAvailableFlag
end

function C:canSkipTimeControls()
  return self.canSkipTimeControlsFlag or false
end

function C:canSkip()
  return self:canSkipTimeControls() or self:canSkipCountdown()
end

function C:skipToNextEvent()
  -- Skip to N seconds before the next TC event
  local nextEvent = self.events and self.events[self.nextEventIndex]
  if not nextEvent then
    log('W', logTag, 'skipToNextEvent: No next event found')
    return false
  end

  if nextEvent.type ~= 'tc' then
    log('W', logTag, 'skipToNextEvent: Next event is not a TC event')
    return false
  end

  local targetTime = nextEvent.time - self.skipParams.secondsBeforeEvent
  if targetTime <= self.clock then
    log('W', logTag, 'skipToNextEvent: Target time is not in the future')
    return false
  end

  local oldClock = self.clock
  self.clock = targetTime
  log('I', logTag, string.format('Skipped from epoch time %.2fs to %.2fs (advanced %.2fs)',
    oldClock, targetTime, targetTime - oldClock))

  -- Notify UI that time was skipped
  guihooks.trigger('RallyClockSkipped', {
    oldTime = oldClock,
    newTime = targetTime,
    skippedSeconds = targetTime - oldClock
  })

  return true
end

function C:skipLiaisonForTesting(options)
  options = options or {}

  if not self:isInRoadSection() then
    return false, 'not in liaison'
  end

  local scheduleEntry = self.schedule and self.schedule[self.currentMissionIndex] or nil
  if not scheduleEntry then
    return false, 'no current schedule entry'
  end

  local nextEvent = self.events and self.events[self.nextEventIndex] or nil
  if not nextEvent then
    return false, 'no next event'
  end

  local currentMissionId = self:getCurrentMissionId()
  if nextEvent.type ~= 'tc' or nextEvent.missionId ~= currentMissionId or nextEvent.spName ~= scheduleEntry.tcOutName then
    return false, 'next event is not this liaison TC_out'
  end

  if not scheduleEntry.tcOutPos then
    return false, 'no TC_out position'
  end

  if not scheduleEntry.tcOutTime then
    return false, 'no TC_out time'
  end

  local veh = getPlayerVehicle(0)
  if not veh then
    return false, 'no player vehicle'
  end

  local rm = self:getRallyManager()
  local notebook = rm and rm:getNotebookPath()
  local snaproad = notebook and notebook:getSnaproad()
  if not snaproad then
    return false, 'no snaproad'
  end

  local distanceBefore = options.distanceBefore or 50
  local loc = snaproad:advanceAlongRoute(scheduleEntry.tcOutPos, distanceBefore, false, nil, true)
  if not loc or not loc.pos then
    return false, 'failed to calculate liaison skip position'
  end

  local fwd = snaproad:normalForSnapResult(loc)
  if not fwd then
    return false, 'failed to calculate liaison skip direction'
  end

  local rot = quatFromDir(fwd, vec3(0, 0, 1)):normalized()
  spawn.safeTeleport(veh, loc.pos, rot, nil, nil, nil, true, options.resetVehicle ~= false)
  if not rm:resyncAfterTeleport() then
    return false, 'failed to resync rally manager after teleport'
  end
  extensions.hook('onVehicleTeleportedToLastRoad', veh:getID())

  local oldClock = self.clock
  local targetTime = scheduleEntry.tcOutTime - (self.skipParams.secondsBeforeEvent or 1)
  self.clock = targetTime

  log('I', logTag, string.format('Skip liaison for testing: teleported %.1fm before %s and set clock from %.2fs to %.2fs',
    distanceBefore, scheduleEntry.tcOutLabel or 'TC_out', oldClock, targetTime))

  guihooks.trigger('RallyClockSkipped', {
    oldTime = oldClock,
    newTime = targetTime,
    skippedSeconds = targetTime - oldClock
  })

  return true
end

function C:onRallyModeInteract()
  if self:canSkipTimeControls() then
    self:skipToNextEvent()
  else
    guihooks.trigger('RallyGameplayInteract', {})
  end
end

function C:drawDebug(zOnTop, drawRoute, drawLabels)
  zOnTop = zOnTop or false
  drawRoute = (drawRoute == nil) and true or drawRoute
  drawLabels = (drawLabels == nil) and false or drawLabels
  if not self.fgVariables then return end

  -- Control level of detail in labels
  local includeDetails = false

  -- Service stall is now drawn as part of the serviceIn mission in the schedule loop below

  -- Draw waypoints from each mission in the sequence
  if not self.schedule then return end

  -- Determine what to draw
  local shouldDrawShapes = drawRoute
  local shouldDrawText = drawLabels

  local function drawPin(basePos, pinColor, label, labelTextColor, labelBgColor)
    if not basePos then return end
    local endPos = vec3(basePos)
    local pinTop = endPos + vec3(0, 0, 4)
    local sphereRadius = 0.55
    debugDrawer:drawCylinder(endPos, pinTop, 0.18, pinColor)
    debugDrawer:drawSphere(pinTop, sphereRadius, pinColor)
    if label then
      debugDrawer:drawTextAdvanced(pinTop + vec3(0, 0, sphereRadius), String(label), labelTextColor, true, false, labelBgColor, false, false)
    end
  end

  for i, data in ipairs(self.schedule) do
    if not data.error then
      -- Use red for road sections, blue for SS stages, gray for service missions
      local clr
      if data.ssLabel then
        -- SS stage - blue
        clr = {0, 0, 1}
      elseif data.roadSectionLabel then
        -- Road section - red
        clr = {0.7, 0, 0}
      else
        -- Service missions - gray
        clr = {0.3, 0.3, 0.3}
      end
      local clrF = ColorF(clr[1], clr[2], clr[3], 0.7)
      local clrI = ColorI(clr[1] * 255, clr[2] * 255, clr[3] * 255, 255)
      -- local clrPacked = color(clr[1] * 255, clr[2] * 255, clr[3] * 255, 255)

      -- Calculate luminance to determine appropriate text color
      local luminance = 0.299 * clr[1] + 0.587 * clr[2] + 0.114 * clr[3]
      local textColor = luminance > 0.5 and ColorF(0, 0, 0, 1) or ColorF(1, 1, 1, 1)

      local missionId = data.missionId

      -- Draw service mission triggers
      if data.missionType == 'serviceOut' and data.serviceOutTriggerPos and data.tcLabel then
        local pos = vec3(data.serviceOutTriggerPos[1], data.serviceOutTriggerPos[2], data.serviceOutTriggerPos[3])
        if shouldDrawShapes then
          debugDrawer:drawSphere(pos, 1.5, clrF)
        end
        if shouldDrawText then
          -- Convert from rally epoch to wall clock for display
          local wallClockTime = self:epochToWallClock(data.tcTime)
          local timeStr = self:formatTimeFromSecondsString(wallClockTime, false, false)
          local label = includeDetails and (data.tcLabel .. " " .. timeStr .. " | " .. missionId .. " | Service Out TC") or (data.tcLabel .. " " .. timeStr)
          debugDrawer:drawTextAdvanced(pos, String(label), textColor, true, false, clrI, false, false)
        end
      end

      -- Draw serviceIn mission with serviceStallPos (not a scheduled TC, just parking area)
      if data.missionType == 'serviceIn' and data.serviceStallPos then
        local pos = vec3(data.serviceStallPos[1], data.serviceStallPos[2], data.serviceStallPos[3])
        if shouldDrawShapes then
          debugDrawer:drawSphere(pos, 1.5, clrF)
        end
        if shouldDrawText then
          local label = includeDetails and ("Service Stall | " .. missionId) or "Service Stall"
          debugDrawer:drawTextAdvanced(pos, String(label), textColor, true, false, clrI, false, false)
        end
      end

      -- Draw road section waypoints (TC_in, TC_out)
      if data.tcInPos and data.tcInLabel then
        local pos = vec3(data.tcInPos.x, data.tcInPos.y, data.tcInPos.z)
        if shouldDrawShapes then
          debugDrawer:drawSphere(pos, 1.5, clrF)
        end
        if shouldDrawText then
          -- Convert from rally epoch to wall clock for display
          local wallClockTime = self:epochToWallClock(data.tcInTime)
          local timeStr = self:formatTimeFromSecondsString(wallClockTime, false, false)
          local label = includeDetails and (data.tcInLabel .. " " .. timeStr .. " | " .. missionId .. " | TC_in") or (data.tcInLabel .. " " .. timeStr)
          debugDrawer:drawTextAdvanced(pos, String(label), textColor, true, false, clrI, false, false)
        end
      end

      if data.tcOutPos and data.tcOutLabel then
        local pos = vec3(data.tcOutPos.x, data.tcOutPos.y, data.tcOutPos.z)
        if shouldDrawShapes then
          debugDrawer:drawSphere(pos, 1.5, clrF)
        end
        if shouldDrawText then
          -- Convert from rally epoch to wall clock for display
          local wallClockTime = self:epochToWallClock(data.tcOutTime)
          local timeStr = self:formatTimeFromSecondsString(wallClockTime, false, false)
          local label = includeDetails and (data.tcOutLabel .. " " .. timeStr .. " | " .. missionId .. " | TC_out") or (data.tcOutLabel .. " " .. timeStr)
          debugDrawer:drawTextAdvanced(pos, String(label), textColor, true, false, clrI, false, false)
        end
      end

      -- Draw stage waypoints (SS_start_line, SS_stop_control)
      if data.ssStartLinePos and data.ssLabel then
        local pos = vec3(data.ssStartLinePos.x, data.ssStartLinePos.y, data.ssStartLinePos.z)
        if shouldDrawShapes then
          debugDrawer:drawSphere(pos, 1.5, clrF)
        end
        if shouldDrawText then
          -- Convert from rally epoch to wall clock for display
          local wallClockTime = self:epochToWallClock(data.ssStartLineTime)
          local timeStr = self:formatTimeFromSecondsString(wallClockTime, false, false)
          local ssLabel = tostring(data.ssLabel):find("^SS") and tostring(data.ssLabel) or ("SS" .. tostring(data.ssLabel))
          local label = includeDetails and (ssLabel .. " START " .. timeStr .. " | " .. missionId .. " | SS_start_line") or (ssLabel .. " START " .. timeStr)
          debugDrawer:drawTextAdvanced(pos, String(label), textColor, true, false, clrI, false, false)
        end
      end

      if data.ssStopControlPos and data.ssLabel then
        local pos = vec3(data.ssStopControlPos.x, data.ssStopControlPos.y, data.ssStopControlPos.z)
        if shouldDrawShapes then
          debugDrawer:drawSphere(pos, 1.5, clrF)
        end
        if shouldDrawText then
          -- Convert from rally epoch to wall clock for display
          local wallClockTime = self:epochToWallClock(data.ssStopControlTime)
          local timeStr = self:formatTimeFromSecondsString(wallClockTime, false, false)
          local ssLabel = tostring(data.ssLabel):find("^SS") and tostring(data.ssLabel) or ("SS" .. tostring(data.ssLabel))
          local label = includeDetails and (ssLabel .. " STOP " .. timeStr .. " | " .. missionId .. " | SS_stop_control") or (ssLabel .. " STOP " .. timeStr)
          debugDrawer:drawTextAdvanced(pos, String(label), textColor, true, false, clrI, false, false)
        end
      end

      -- Draw driveline path
      local drivelineStartPos = nil
      local drivelineEndPos = nil
      if shouldDrawShapes and data.drivelinePointList then
        local points = data.drivelinePointList:getAll()
        if points and #points > 1 then
          local thickness = 1
          for j = 1, #points - 1 do
            local pos1 = points[j].pos
            local pos2 = points[j + 1].pos
            debugDrawer:drawSquarePrism(
              pos1, pos2,
              Point2F(thickness, thickness),
              Point2F(thickness, thickness),
              clrF, not zOnTop, false)
          end
          drivelineStartPos = points[1].pos
          drivelineEndPos = points[#points].pos
        end
      end
      if shouldDrawShapes then
        local pinColor = ColorF(clr[1], clr[2], clr[3], 0.95)
        if data.ssLabel then
          local ssLabel = tostring(data.ssLabel):find("^SS") and tostring(data.ssLabel) or ("SS" .. tostring(data.ssLabel))
          drawPin(drivelineStartPos, pinColor, ssLabel .. " START", textColor, clrI)
          drawPin(drivelineEndPos, pinColor, ssLabel .. " END", textColor, clrI)
        elseif data.roadSectionLabel then
          local roadLabel = tostring(data.roadSectionLabel)
          drawPin(drivelineStartPos, pinColor, roadLabel .. " START", textColor, clrI)
          drawPin(drivelineEndPos, pinColor, roadLabel .. " END", textColor, clrI)
        end
      end
    end
  end
end

function C:setupForNewMission()
  self.rallyManager = nil
end

function C:getMissionExecutionTransferFlag()
  return self.missionExecutionTransferFlag
end

function C:setMissionExecutionTransferFlag(val)
  self.missionExecutionTransferFlag = val
end

function C:getDrawFlag(flagName)
  return self.drawFlags and self.drawFlags[flagName] or false
end

function C:setDrawFlag(flagName, value)
  if not self.drawFlags then
    self.drawFlags = {}
  end
  self.drawFlags[flagName] = value
end

function C:getEnvironmentStartTimeFormatted()
  if not self.environmentStartTimeSecs then
    return "N/A"
  end
  return self:formatTimeFromSecondsString(self.environmentStartTimeSecs, true, false)
end

function C:onRallyDataUpdated(data)
  if not data then return end

  -- Store activeState
  if data.activeState then
    self.currentActiveState = data.activeState
  end

  -- Store vehicleProximity
  if data.vehicleProximity then
    local proximityData = data.vehicleProximity

    if proximityData.distance then
      local d = proximityData.distance
      proximityData.distance = math.floor(d * 100 + 0.5) / 100
    else
      proximityData.distance = nil
    end
    if proximityData.distanceToPlane then
      local d = proximityData.distanceToPlane
      proximityData.distanceToPlane = math.floor(d * 100 + 0.5) / 100
    else
      proximityData.distanceToPlane = nil
    end

    self.currentVehicleProximity = proximityData
  end

  -- Store countdownData
  if data.countdownData then
    self.currentCountdownData = data.countdownData
  end
end

function C:getStreamData()
  -- Update rally clock data in-place
  self:updateRallyClockData()
  -- Update schedule data in-place
  self:updateScheduleData()
  UiColors.updateForLoop(self.uiColors, self.isNgrcMode)

  -- Get stage data and set label from scheduleData (only in special stage context)
  local stageData = nil
  if self:isInSpecialStage() then
    local rm = self:getRallyManager()
    if rm then
      stageData = rm:getActiveStageData()
      if stageData then
        -- Set label from scheduleData
        local scheduleData = self.scheduleData
        if scheduleData.ssLabel then
          stageData.label = scheduleData.ssLabel
        elseif scheduleData.label then
          stageData.label = scheduleData.label
        else
          stageData.label = '??'
        end

        stageData.unit = distanceUnit
      end
    end
  end

  -- Update stream data references
  -- Override activeState with testActiveState when testMode is enabled
  if self.testMode and self.testActiveState then
    self.streamData.activeState = self.testActiveState
  else
    self.streamData.activeState = self.currentActiveState or RallyUtil.activeState_inactive
  end
  self.streamData.stageData = stageData
  self.streamData.vehicleProximity = self.currentVehicleProximity
  self.streamData.countdownData = self.currentCountdownData
  self.streamData.penaltyData = self.eventLog:getPenaltySummary()
  self.streamData.showDebugInfo = self:getDrawFlag('showDebugInfo')
  self.streamData.showStageApps = self:getShowStageApps()
  self.streamData.missionName = self.missionName and _tr(self.missionName) or nil

  return self.streamData
end

function C:setCountdownCanSkip(canSkip)
  self.countdownCanSkip = canSkip or false
  -- TODO do the skipping stuff
end

function C:canSkipCountdown()
  return self.countdownCanSkip or false
end

function C:rescheduleNextSSStart()
  -- Reschedule the next SS start event to the next slot
  -- Used when vehicle is not staged at the -10s mark
  -- Always reschedules (doesn't check if later) because we're pushing to a future slot

  local event, eventIndex = self:_findNextSSStartEvent()
  if not event then
    log('W', logTag, 'rescheduleNextSSStart: No upcoming SS start event found')
    return {success = false, reason = 'no_ss_start_event'}
  end

  local slotSizeMinutes = self.scheduleParams.slotSizeMinutes

  -- Calculate new time using shared utility
  local newTime = ScheduleUtils.calculateNextSlotTime(event.time, slotSizeMinutes, true)

  -- Use shared method to update (onlyIfLater = false, since we always want to reschedule to next slot)
  local result = self:_updateSSStartTime(newTime, false, string.format('Not staged at -10s, slot: %d min', slotSizeMinutes))
  return result
end

function C:getSSRescheduleCount()
  -- Get reschedule count for the next SS start event
  local event, eventIndex = self:_findNextSSStartEvent()
  if not event then
    return 0
  end

  return event.rescheduleCount or 0
end

function C:recordFalseStartPenalty()
  -- Record false start penalty for the current stage (next SS start event)
  -- Penalty value lives in loop/penalties.lua.
  local event, eventIndex = self:_findNextSSStartEvent()
  if not event then
    log('W', logTag, 'recordFalseStartPenalty: No upcoming SS start event found')
    return false
  end

  -- Count existing false starts for this event from the log
  local existingFalseStarts = 0
  local eventItems = self.eventLog:getItemsByEventGroup(event.eventGroup)
  for _, item in ipairs(eventItems) do
    if item.type == 'penalty' and item.data.penaltyType == 'false_start' and item.eventId == event.eventId then
      existingFalseStarts = existingFalseStarts + 1
    end
  end

  local falseStartCount = existingFalseStarts + 1

  local penaltySecs = Penalties.calculateFalseStartPenalty(falseStartCount)

  -- Get stage label from schedule entry
  local stageLabel = nil
  if self.schedule and event.missionIndex then
    local scheduleEntry = self.schedule[event.missionIndex]
    if scheduleEntry then
      stageLabel = scheduleEntry.ssLabel
    end
  end

  -- Log false start penalty to eventLog immediately
  self.eventLog:addItem(event, self.clock, 'penalty', {
    penaltyType = 'false_start',
    amount = penaltySecs,
    falseStartCount = falseStartCount,
    eventLabel = event.label,
    stageLabel = stageLabel
  })

  return true
end

function C:recordRouteRecalcPenalty(penaltyData)
  -- Record route recalc penalty for the next TC event
  -- Similar to recordFalseStartPenalty but for TC events
  local event, eventIndex = self:_findNextTCEvent()
  if not event then
    log('W', logTag, 'recordRouteRecalcPenalty: No upcoming TC event found')
    return false
  end
  guihooks.trigger('Message', {msg = 'Route penalty recorded', ttl = 1, category = 'rally', icon = 'warning'})

  -- Get TC label from event
  local tcLabel = event.label

  -- Log route recalc penalty to eventLog immediately
  self.eventLog:addItem(event, self.clock, 'penalty', {
    penaltyType = 'route_recalc',
    amount = penaltyData.amount,
    violationNumber = penaltyData.data.violationNumber,
    recalcCount = penaltyData.data.recalcCount
  })

  log('W', logTag, string.format('Recorded route recalc penalty #%d: %ds for TC event %d (%s)',
    penaltyData.data.violationNumber, penaltyData.amount, eventIndex, tcLabel or 'unknown'))
  return true
end

function C:recordSpeedingPenalty(speedingData)
  -- Record speeding penalty for the next event (TC or service_in)
  -- Find next event that can have penalties attached (TC or service_in)
  local event, eventIndex = nil, nil
  if self.events and self.nextEventIndex then
    for i = self.nextEventIndex, #self.events do
      local evt = self.events[i]
      if evt.type == 'tc' or evt.type == 'service_in' then
        event = evt
        eventIndex = i
        break
      end
    end
  end

  if not event then
    log('W', logTag, 'recordSpeedingPenalty: No upcoming event found for penalty attachment')
    return false
  end

  -- Create structured penalty data
  local penaltyAmount = 10  -- 10 seconds penalty for speeding

  -- Get event label
  local eventLabel = event.label

  -- Log speeding penalty to eventLog immediately
  self.eventLog:addItem(event, self.clock, 'penalty', {
    penaltyType = 'speeding',
    amount = penaltyAmount,
    speedOver = speedingData.speedOver,
    speedLimit = speedingData.speedLimit,
    strictMode = speedingData.strictMode
  })

  -- Show message to user
  -- local modeStr = speedingData.strictMode and " (STRICT)" or ""
  -- guihooks.trigger('Message', {
  --   msg = string.format('Speeding penalty: +%ds%s', penaltyAmount, modeStr),
  --   ttl = 3,
  --   category = 'rally',
  --   icon = 'warning'
  -- })

  -- log('W', logTag, string.format('Recorded speeding penalty: %ds for event %d (%s, type: %s) - Speed: %.1f kph over %d kph limit%s',
    -- penaltyAmount, eventIndex, eventLabel or 'unknown', event.type or 'unknown',
    -- speedingData.speedOver, speedingData.speedLimit, modeStr))
  return true
end

function C:recordTestPenalty(amount)
  amount = math.floor(tonumber(amount) or 10)
  if amount <= 0 then
    return false
  end

  local event, eventIndex = nil, nil
  if self.events and self.nextEventIndex then
    event = self.events[self.nextEventIndex]
    eventIndex = self.nextEventIndex
    if not event and #self.events > 0 then
      eventIndex = #self.events
      event = self.events[eventIndex]
    end
  end

  if not event then
    log('W', logTag, 'recordTestPenalty: No event found for penalty attachment')
    return false
  end

  self.eventLog:addItem(event, self.clock or 0, 'penalty', {
    penaltyType = 'test_penalty',
    amount = amount,
    eventLabel = event.label,
  })

  if guihooks and guihooks.trigger then
    guihooks.trigger('Message', {msg = string.format('Test penalty recorded: +%ds', amount), ttl = 1, category = 'rally', icon = 'warning'})
  end

  log('I', logTag, string.format('Recorded test penalty: %ds for event %d (%s)', amount, eventIndex or 0, event.label or 'unknown'))
  return true
end


function C:getServiceOutTCPos()
  -- Get serviceOut TC position from schedule (should be first entry)
  if not self.schedule or #self.schedule == 0 then
    return nil
  end

  local serviceOutEntry = self.schedule[1]
  if serviceOutEntry and serviceOutEntry.missionType == 'serviceOut' then
    return serviceOutEntry.serviceOutTriggerPos
  end

  return nil
end

function C:getServiceOutTCRot()
  -- Get serviceOut TC rotation from schedule (should be first entry)
  if not self.schedule or #self.schedule == 0 then
    return nil
  end

  local serviceOutEntry = self.schedule[1]
  if serviceOutEntry and serviceOutEntry.missionType == 'serviceOut' then
    return serviceOutEntry.serviceOutTriggerRot
  end

  return nil
end

function C:onUIStartButtonClicked()
  -- when the button is clicked, start the clock
  log('I', logTag, 'onUIStartButtonClicked called for rally loop manager')
  self:applyStartScreenSettings(self.mission and self.mission.lastUserSettings)
  self:setClockPaused(false)
  core_recoveryPrompt.setButtonActiveById('restartMission', true)

  -- unfreeze vehicle
  local vehicle = getPlayerVehicle(0)
  if vehicle then
    core_vehicleBridge.executeAction(vehicle,'setFreeze', false)
  end
end

function C:onRecalculatedRoute(source)
  -- make sure source is nil and therefore is not raceRoute so we dont double-count.

  -- disabled for the time being );

  -- if source then return end
  -- if self.roadSectionPenaltyKeeper and self:isInRoadSection() then
    -- self.roadSectionPenaltyKeeper:registerRecalc()
  -- end
end

function C:onCreatedRallyGroundMarkerRoute()
  if self.roadSectionPenaltyKeeper then
    self.roadSectionPenaltyKeeper:reset()
  end
end

function C:trackRecovery(recoveryType)
  log('W', logTag, 'trackRecovery type='..recoveryType)

  -- Get vehicle position
  local vehicle = be:getPlayerVehicle(0)
  if not vehicle then
    log('W', logTag, 'trackRecovery: No player vehicle found')
    return
  end
  local position = vehicle:getPosition()

  local isSpecialStage = self:isInSpecialStage()
  local clockAdvanceSeconds = RecoveryClockAdvance.getSeconds(recoveryType, isSpecialStage)
  if clockAdvanceSeconds > 0 then
    local oldClock = self.clock
    self.clock = self.clock + clockAdvanceSeconds
    RallyLoopTime.advancePlayingTime(clockAdvanceSeconds)
    guihooks.trigger('RallyClockSkipped', {
      oldTime = oldClock,
      newTime = self.clock,
      skippedSeconds = clockAdvanceSeconds
    })
  end

  -- Get current event
  local currentEvent = self.events and self.events[self.nextEventIndex] or nil
  if not currentEvent then
    log('W', logTag, 'trackRecovery: No current event found')
    return
  end

  -- Log to eventLog
  if recoveryType == 'recovery' then
    self.eventLog:addItem(currentEvent, self.clock, 'recovery', {
      position = {x = position.x, y = position.y, z = position.z},
      clockAdvanceSeconds = clockAdvanceSeconds,
      isSpecialStage = isSpecialStage
    })
  elseif recoveryType == 'flip' then
    self.eventLog:addItem(currentEvent, self.clock, 'flip', {
      position = {x = position.x, y = position.y, z = position.z},
      clockAdvanceSeconds = clockAdvanceSeconds,
      isSpecialStage = isSpecialStage
    })
  end
end

function C:onRallyRouteRecoveryComplete(data)
  self.lastRouteRecoveryData = data
  if data then
    log('I', logTag, string.format(
      'route recovery complete vehId=%s repairVehicle=%s',
      tostring(data.vehId),
      tostring(data.repairVehicle)
    ))
  end
end

-- function C:trackSpeeding(velKph, limitKph)
--   self.speedingDetector:trackSpeeding(velKph, limitKph)
-- end

function C:applyTrafficExclusion()
  local loopMission = gameplay_missions_missions.getMissionById(self.missionId)
  if not loopMission then
    log('W', logTag, 'applyTrafficExclusion: could not find loop mission: ' .. tostring(self.missionId))
    return
  end
  TrafficExclusion.applyForRallyLoop(loopMission)
end

function C:clearTrafficExclusion()
  TrafficExclusion.clearTrafficExclusion()
end

function C:setTestMode(enabled)
  self.testMode = enabled or false
  if not self.testMode then
    self.currentActiveState = RallyUtil.activeState_inactive
  end
end

function C:getTestMode()
  return self.testMode
end

function C:getEnableFalseStarts()
  return self.enableFalseStarts
end

function C:setTestActiveState(state)
  self.testActiveState = state
  if self.testMode then
    self.currentActiveState = state
  end
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end