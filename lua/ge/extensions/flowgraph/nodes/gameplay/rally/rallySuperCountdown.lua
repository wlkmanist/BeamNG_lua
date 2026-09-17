-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt


-- TL;DR
-- false start logic:
-- - Unstage without beam break → abort & reschedule to the next minute (no penalty).
-- - Beam break before zero → false start (+10 s) and the run begins.
-- - Use small tolerances so tiny jitters don’t cause unwanted reslots.


local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local ScheduleUtils = require('/lua/ge/extensions/gameplay/rally/loop/scheduleUtils')
local StagedCountdownUtils = require('/lua/ge/extensions/gameplay/rally/loop/stagedCountdownUtils')
local StagedCountdownTest = require('/lua/ge/extensions/gameplay/rally/loop/stagedCountdownTest')
local im = ui_imgui

local C = {}
local logTag = 'superCountdown'

local defaultWarningTimes = {60, 30, 15, 10}

-- Speed thresholds (in m/s)
local SPEED_THRESHOLD_STOPPED = 0.08  -- ~0.3 kph - base threshold for "stopped" check
local SPEED_THRESHOLD_STOPPED_HYSTERESIS = 0.6 / 3.6  -- 0.6 kph - additional tolerance when transitioning to "not stopped"
local SPEED_THRESHOLD_SKIP_BASE = 1 / 3.6  -- 1 kph - base threshold for skip availability
local SPEED_THRESHOLD_SKIP_HYSTERESIS = 1 / 3.6  -- 1 kph - additional tolerance when disabling skip

-- Countdown message constants
local FINISH_MSG = 'Go!'
local FINISH_MSG_DURATION = 1
local COUNTDOWN_MSG_FORMAT = '%d'
local COUNTDOWN_SKIP_LEAD_SECONDS = 6

-- Reusable temporary vectors (module-level, shared across instances)
local tmpPlaneNormal = vec3()
local tmpToVehicle = vec3()
local tmpClosestPoint = vec3()
local tmpMidPoint = vec3()

-- Module-level vehicle data (reused each frame like vehicleStoppedNearPlane)
local veh, vehicleData
local vehPos, vehVel = vec3(), vec3()

C.name = 'Rally Super Countdown'
C.icon = "timer"
C.description = 'Complete rally start line system: timing, position lookup, proximity checking, staging validation, countdown, rescheduling, and false start detection. Replaces Rally Clock, Rally Position Getter, and Stopped Near Plane nodes.'
C.color = rallyUtil.rallyLoop_flowgraph_color

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'flow', name = 'reset', description = 'Reset the countdown.', impulse = true },
  { dir = 'in', type = 'table', name = 'pathData', tableType = 'pathData', description = 'Data from the path for start line position lookup.' },
  { dir = 'in', type = 'string', name = 'spName', description = 'Name of the start line position to get from pathData.' },
  { dir = 'in', type = 'string', name = 'eventName', description = 'Name of the event to get the scheduled time for (e.g., "SS_start_line").' },
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of the vehicle to check.' },
  { dir = 'in', type = 'number', name = 'distance', default = 1, hardcoded = true, description = 'Distance threshold for launch zone (meters).' },
  { dir = 'in', type = 'number', name = 'stagingCheckTime', default = 10, description = 'Seconds before start to check if vehicle is staged.' },
  { dir = 'in', type = 'number', name = 'maxReschedules', default = 3, description = 'Maximum number of reschedule attempts.' },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow for this node.' },
  { dir = 'out', type = 'flow', name = 'finished', description = 'Triggers when countdown has finished.', impulse = true },
  { dir = 'out', type = 'flow', name = 'ongoing', description = 'Triggers when countdown is in progress.' },
  { dir = 'out', type = 'flow', name = 'waiting', description = 'Triggers when countdown is waiting.' },
  { dir = 'out', type = 'flow', name = 'rescheduled', description = 'Triggers when start time is rescheduled.', impulse = true },
  { dir = 'out', type = 'flow', name = 'falseStart', description = 'Triggers when false start detected.', impulse = true },
  { dir = 'out', type = 'flow', name = 'maxReschedulesReached', description = 'Triggers when max reschedules limit is reached.', impulse = true },
}
C.tags = {'rally'}

-- State machine states
local STATE_WAITING_FOR_STAGING_CHECK = 'waiting_for_staging_check'
local STATE_WAITING_FOR_STAGED = 'waiting_for_staged'
local STATE_COUNTDOWN_ARMED = 'countdown_armed'
local STATE_COUNTDOWN_RUNNING = 'countdown_running'
local STATE_LAUNCHED = 'launched'
local STATE_FINISHED = 'finished'
local STATE_FALSE_START = 'false_start'

function C:init(mgr, ...)
  self.data.useImgui = false
  self.data.useMessages = false
  self.data.bigFinishMsg = true
  self.data.test = false  -- Enable test mode
  self.data.drawDebug = false  -- Enable debug drawing

  self.state = STATE_WAITING_FOR_STAGING_CHECK
  self.duration = 1
  self.timer = 1
  self.launchedTimer = 0
  self.msg = "Go!"
  self.scheduledEventTime = nil
  self.targetStartTime = nil
  self.stagingCheckTime = nil
  self.rescheduleCount = 0
  self.vehicleFrozen = false
  self.stagingCheckPassed = false
  self.startTimerAttempted = false
  self.vehicleDataValid = false  -- Track if vehicle data was updated this frame
  self.skipRequested = false  -- Flag for skip action
  self.skipDebounceTimer = 0  -- Debounce timer to prevent skip spamming
  self.lastCanSkipValue = false  -- Track previous skip state for asymmetric threshold
  self.lastIsStoppedValue = false  -- Track previous stopped state for asymmetric threshold

  -- Individual flags for special audio (separate from reschedule logic)
  self.playCommsCheck = true
  self.playBeltsCheck = true
  self.playPrecountdown = true

  -- Cached proximity state (updated once per frame)
  self.signedDistance = 0
  self.isNearPlaneValue = false
  self.isStoppedValue = false
  self.isStagedValue = false

  self.warningsTriggered = {}

  self.flags = {
    finished = false,
    rescheduled = false,
    falseStart = false,
    maxReschedulesReached = false
  }

  -- Proximity checking state (instance vectors for plane position/rotation)
  self.pos = vec3()
  self.rot = quat()
  self.startPosValid = false  -- Track if start position was successfully looked up

  -- Cache for start position lookup
  self.cachedPathData = nil
  self.cachedSpName = nil
  self.startPositionInvalidReason = nil

  -- Cache for scheduled event time lookup (from Rally Clock)
  self.cachedEventName = nil
  self.cachedMissionId = nil
  self.cachedScheduledEventTime = nil

  -- Test mode instance
  self.testInstance = nil
end

function C:_executionStarted()
  self:stopTimer()

  -- Recreate plane position/rotation vectors (avoid stale references)
  self.pos = vec3()
  self.rot = quat()
  self.startPosValid = false

  -- Reset caches when execution starts
  self.cachedPathData = nil
  self.cachedSpName = nil
  self.startPositionInvalidReason = nil
  self.cachedEventName = nil
  self.cachedMissionId = nil
  self.cachedScheduledEventTime = nil

  -- Initialize test mode
  if self.data.test then
    self.testInstance = StagedCountdownTest()
  else
    self.testInstance = nil
  end
end

function C:_executionStopped()
  self:stopTimer()
  self:unfreezeVehicle()
end

function C:reset()
  self:stopTimer()
  self:unfreezeVehicle()
  self.pinOut.flow.value = false
  self.pinOut.finished.value = false
  self.pinOut.ongoing.value = false
  self.pinOut.waiting.value = false
  self.pinOut.rescheduled.value = false
  self.pinOut.falseStart.value = false
  self.pinOut.maxReschedulesReached.value = false

  -- Recalculate test scheduled event time if in test mode
  if self.data.test and self.testInstance then
    self.testInstance:calculateScheduledEventTime()
  end
end

function C:stopTimer()
  self.state = STATE_WAITING_FOR_STAGING_CHECK
  self.timer = 1
  self.launchedTimer = 0
  self.scheduledEventTime = nil
  self.targetStartTime = nil
  self.stagingCheckTime = nil
  self.rescheduleCount = 0
  self.stagingCheckPassed = false
  self.startTimerAttempted = false
  self.skipDebounceTimer = 0
  self.lastCanSkipValue = false
  self.lastIsStoppedValue = false
  self.warningsTriggered = {}
  self.flags = {
    finished = false,
    rescheduled = false,
    falseStart = false,
    maxReschedulesReached = false
  }
  -- Reset audio flags
  self.playCommsCheck = true
  self.playBeltsCheck = true
  self.playPrecountdown = true
end

function C:freezeVehicle()
  if self.vehicleFrozen then return end

  if StagedCountdownUtils.freezeVehicle(self.pinIn.vehId.value, logTag) then
    self.vehicleFrozen = true
  end
end

function C:unfreezeVehicle()
  if not self.vehicleFrozen then return end

  if StagedCountdownUtils.unfreezeVehicle(self.pinIn.vehId.value, logTag) then
    self.vehicleFrozen = false
  end
end

function C:updateVehicleData()
  -- Get vehicle and update position/velocity (using module-level variables)
  if not self.pinIn.vehId.value then
    return false
  end

  veh = scenetree.findObjectById(self.pinIn.vehId.value)
  if not veh then
    return false
  end

  vehicleData = map.objects[veh:getId()]
  if not vehicleData then
    return false
  end

  -- Get vehicle front center (set module-level vehPos, vehVel)
  vehPos:set(rallyUtil.getVehFrontCenter(veh:getId()))
  vehVel:set(vehicleData.vel)

  return true
end

function C:updateStartPosition()
  -- Look up start line position from pathData (cached for performance)
  local pathData = self.pinIn.pathData.value
  local spName = self.pinIn.spName.value

  local function applyStartPosition(sp)
    self.pos:set(sp.pos)
    self.rot:set(sp.rot)
    self.startPosValid = true
    self.cachedPathData = pathData
    self.cachedSpName = spName
    self.startPositionInvalidReason = nil
    return true
  end

  if not spName then
    self.startPosValid = false
    self.startPositionInvalidReason = 'missing spName'
    return false
  end

  -- Check if inputs are valid
  if not pathData then
    self.startPosValid = false
    self.startPositionInvalidReason = 'missing pathData'
    return false
  end

  -- Check if cache is valid (inputs haven't changed)
  if self.cachedPathData == pathData and self.cachedSpName == spName and self.startPosValid then
    return true  -- Use cached position
  end

  -- Cache miss - look up the start position
  local sp = pathData:findStartPositionByName(spName)
  if sp then
    return applyStartPosition(sp)
    -- log('D', logTag, string.format('Start position cached: %s', spName))
  else
    self.startPosValid = false
    local names = {}
    if pathData.startPositions and pathData.startPositions.sorted then
      for _, startPosition in ipairs(pathData.startPositions.sorted) do
        table.insert(names, tostring(startPosition.name))
      end
    end
    self.startPositionInvalidReason = string.format('start position not found: %s; available=[%s]', tostring(spName), table.concat(names, ', '))
    return false
  end
end

function C:updateProximityState()
  -- Calculate all proximity state once per frame (requires valid vehicle data)
  if not self.vehicleDataValid then
    self.signedDistance = 0
    self.isNearPlaneValue = false
    self.isStoppedValue = false
    self.isStagedValue = false
    return
  end

  -- Calculate signed distance from vehicle to plane
  local planePos = self.pos
  local rot = self.rot

  -- The plane normal is the y-axis (since plane is drawn in x-z) - reuse tmpPlaneNormal
  tmpPlaneNormal:set(0, 1, 0)
  tmpPlaneNormal:set(rot * tmpPlaneNormal)
  tmpPlaneNormal:normalize()

  -- Calculate signed distance from vehicle to plane - reuse tmpToVehicle
  tmpToVehicle:setSub2(vehPos, planePos)
  local dist = tmpToVehicle:dot(tmpPlaneNormal)

  -- Flip sign so back/past is negative, front/before is positive (for display convention)
  self.signedDistance = -dist

  -- Check if vehicle is stopped (with asymmetric threshold to prevent flickering)
  local velocity = vehVel:length()
  if not self.lastIsStoppedValue then
    -- Currently not stopped - require velocity below base threshold to become stopped
    if velocity < SPEED_THRESHOLD_STOPPED then
      self.isStoppedValue = true
      self.lastIsStoppedValue = true
    else
      self.isStoppedValue = false
    end
  else
    -- Currently stopped - require velocity above threshold + hysteresis to become not stopped
    if velocity > SPEED_THRESHOLD_STOPPED + SPEED_THRESHOLD_STOPPED_HYSTERESIS then
      self.isStoppedValue = false
      self.lastIsStoppedValue = false
    else
      self.isStoppedValue = true
    end
  end

  -- Check if vehicle is within distance threshold and in front of plane (not past it)
  self.isNearPlaneValue = self.signedDistance >= 0 and math.abs(self.signedDistance) <= (self.pinIn.distance.value or 1)

  -- Vehicle is staged if it's near the plane AND stopped
  self.isStagedValue = self.isNearPlaneValue and self.isStoppedValue
end

function C:isStopped()
  -- Return cached stopped state
  return self.isStoppedValue
end

function C:isNearPlane()
  -- Return cached proximity state
  return self.isNearPlaneValue
end

function C:isStaged()
  -- Return cached staged state
  return self.isStagedValue
end

function C:isInLaunchZone()
  -- Vehicle is in launch zone if it's near the plane (doesn't need to be stopped)
  return self.isNearPlaneValue
end

function C:hasCrossedStartLine()
  -- Check if vehicle has crossed the start line (signedDistance becomes negative)
  return self.signedDistance < 0
end

function C:getRallyLoopManager()
  if self.data.test then
    return nil  -- In test mode, don't use manager
  end

  if not extensions.isExtensionLoaded(rallyUtil.extRallyLoop) then
    return nil
  end
  return gameplay_rallyLoop.getManager()
end

function C:getCurrentEpochTime()
  if self.data.test and self.testInstance then
    return self.testInstance.epoch
  end

  local rm = self:getRallyLoopManager()
  if not rm then
    return nil
  end
  return rm:getEpochTime()
end

function C:getScheduledEventTime()
  if self.data.test and self.testInstance then
    return self.testInstance.scheduledEventTime
  end

  local rm = self:getRallyLoopManager()
  if not rm then
    return nil
  end

  -- Get event name from input pin
  local eventName = self.pinIn.eventName.value
  local currentMissionId = rm:getCurrentMissionId()

  -- Check if cache is invalid (event name or mission changed)
  if self.cachedEventName ~= eventName or self.cachedMissionId ~= currentMissionId then
    -- Cache miss - look up the scheduled event time
    local scheduledEventTime = rm:getScheduledEventTime(eventName)

    -- Update cache
    self.cachedScheduledEventTime = scheduledEventTime
    self.cachedEventName = eventName
    self.cachedMissionId = currentMissionId

    -- log('D', logTag, string.format('Cache updated: event=%s, mission=%s, time=%s',
    --   eventName or 'nil', currentMissionId or 'nil',
    --   scheduledEventTime and string.format('%.2f', scheduledEventTime) or 'nil'))
  end

  -- Use cached value
  return self.cachedScheduledEventTime
end

function C:requestReschedule()
  local maxReschedules = self.pinIn.maxReschedules.value or 3

  if self.rescheduleCount >= maxReschedules then
    log('W', logTag, 'Max reschedules reached (' .. maxReschedules .. ')')
    self.flags.maxReschedulesReached = true
    return false
  end

  -- Test mode: reschedule to next minute-aligned slot
  if self.data.test and self.testInstance then
    local slotSizeMinutes = 1  -- Default for test mode

    -- Reset warnings for new slot
    self.warningsTriggered = {}

    local success, newTime = self.testInstance:reschedule(
      slotSizeMinutes,
      self.rescheduleCount,
      maxReschedules,
      defaultWarningTimes,
      self.warningsTriggered
    )

    if success then
      self.rescheduleCount = self.rescheduleCount + 1
      self.scheduledEventTime = newTime
      self.flags.rescheduled = true
    end

    return success
  end

  -- Normal mode: use rally loop manager
  local rm = self:getRallyLoopManager()
  if rm then
    local result = rm:rescheduleNextSSStart()
    if result and result.success then
      self.rescheduleCount = self.rescheduleCount + 1
      self.scheduledEventTime = result.newTime
      self.flags.rescheduled = true

      -- Reset warnings for new slot, then mark warnings as already triggered if they're in the past (same as test mode)
      self.warningsTriggered = {}
      local currentEpochTime = self:getCurrentEpochTime()
      if currentEpochTime then
        local timeUntilEvent = self.scheduledEventTime - currentEpochTime
        for _, warningTime in ipairs(defaultWarningTimes) do
          if timeUntilEvent < warningTime then
            self.warningsTriggered[warningTime] = true
            -- log('D', logTag, string.format('Marking %ds warning as already passed (%.1fs until event)', warningTime, timeUntilEvent))
          end
        end
      end

      -- log('D', logTag, string.format('Rescheduled to %.2f (attempt %d/%d)',
        -- result.newTime, self.rescheduleCount, maxReschedules))
      return true
    end
  end

  return false
end

function C:shouldPlayVoiceCountdown()
  return self.playVoiceCountdown
end

function C:shouldShowVisualCountdown()
  return self.showVisualCountdown
end

function C:enableRallyManagerPacenoteProcessing()
  if gameplay_rally then
    local rm = gameplay_rally.getRallyManager()
    if rm then
      rm:setPacenoteProcessingEnabled(true)
    end
  end
end

function C:enqueueSystemPacenote(pacenote_name, audioLenOffset)
  if not gameplay_rally then
    return  -- Rally audio system not loaded (test mode)
  end
  local rm = gameplay_rally.getRallyManager()
  if rm then
    rm:enqueueRandomSystemPacenote(pacenote_name, audioLenOffset)
  end
end

function C:enqueuePauseSecs(secs)
  if not gameplay_rally then
    return  -- Rally audio system not loaded (test mode)
  end
  local rm = gameplay_rally.getRallyManager()
  if rm then
    rm:enqueuePauseSecs(secs)
  end
end

function C:randomPauseSecs(min, max)
  local secs = math.random(min, max)
  self:enqueuePauseSecs(secs)
end

function C:show(msg, big, duration)
  duration = duration or (big and 1.4 or 0.95)
  -- guihooks.trigger('ScenarioFlashMessage', {{msg, duration, "", big}})

  if self.data.useMessages then
    local msgStr = tostring(msg)
    -- Prefix numeric messages with "Countdown: "
    local msgForDisplay = tonumber(msgStr) and ("Countdown: " .. msgStr) or msgStr

    guihooks.trigger('Message', {
      ttl = 1,
      msg = msgForDisplay,
      category = ("stagedCountdown__"..self.id),
      icon = 'timer'}
    )
  end
end

function C:shouldStartTimer()
  return self.pinIn.flow.value
    and self.state == STATE_WAITING_FOR_STAGING_CHECK
    and not self.scheduledEventTime
    and not self.startTimerAttempted
end

function C:configureCountdownSettings()
  -- Configure countdown duration and audio/visual settings based on user preferences
  local settingVisualPacenotes = settings.getValue('rallyVisualPacenotes')
  local settingAudioPacenotes = settings.getValue('rallyAudioPacenotes')
  local settingCountdownStyle = 'countdown_style_5'

  self.showVisualCountdown = settingVisualPacenotes or nil
  self.playVoiceCountdown = settingAudioPacenotes or nil

  -- Get false start setting from rally loop manager (locked at mission start)
  local rm = self:getRallyLoopManager()
  local enableFalseStarts = rm and rm:getEnableFalseStarts()
  if enableFalseStarts ~= nil then
    self.freezeWhenStaged = not enableFalseStarts
  end

  if settingAudioPacenotes then
    if settingCountdownStyle == 'countdown_style_3' then
      self.duration = 4
      self.maxAnnounced = 3
    elseif settingCountdownStyle == 'countdown_style_5' then
      self.duration = 6
      self.maxAnnounced = 5
    else
      log("E", logTag, "Invalid countdown style: " .. settingCountdownStyle)
      self.duration = 3
      self.maxAnnounced = 3
    end
  else
    self.duration = 3
    self.maxAnnounced = 3
  end
end

function C:startTimer()
  self.startTimerAttempted = true
  self:configureCountdownSettings()

  -- guihooks.trigger('ScenarioFlashMessageClear')
  self.flags.finished = false
  self.pinOut.flow.value = false

  -- Get scheduled event time
  local scheduledEventTime = self:getScheduledEventTime()

  if scheduledEventTime then
    self.scheduledEventTime = scheduledEventTime
    self.targetStartTime = scheduledEventTime - self.duration
    self.stagingCheckTime = scheduledEventTime - (self.pinIn.stagingCheckTime.value or 10)
    self.state = STATE_WAITING_FOR_STAGING_CHECK
    self.stagingCheckPassed = false

    -- Mark warnings as already triggered if they're in the past
    local currentEpochTime = self:getCurrentEpochTime()
    if currentEpochTime then
      local timeUntilEvent = scheduledEventTime - currentEpochTime
      for _, warningTime in ipairs(defaultWarningTimes) do
        if timeUntilEvent < warningTime then
          self.warningsTriggered[warningTime] = true
          -- log('D', logTag, string.format('Marking %ds warning as already passed (%.1fs until event)', warningTime, timeUntilEvent))
        end
      end
    end

    -- log('D', logTag, string.format('Initialized: staging check at %.2f, countdown start at %.2f, event at %.2f',
    --   self.stagingCheckTime, self.targetStartTime, scheduledEventTime))
  else
    log('W', logTag, 'No scheduled event time provided')
  end
end

function C:updateTimesAfterReschedule()
  -- Update countdown times after a successful reschedule
  self.targetStartTime = self.scheduledEventTime - self.duration
  self.stagingCheckTime = self.scheduledEventTime - (self.pinIn.stagingCheckTime.value or 10)
end

function C:checkStagingAt10s()
  if not self.vehicleDataValid then
    log('W', logTag, 'Vehicle data not available for -10s check')
    return false
  end

  if self:isStaged() then
    -- log('D', logTag, 'Vehicle is staged at -10s check - countdown will proceed')
    self.state = STATE_COUNTDOWN_ARMED
    self.stagingCheckPassed = true

    -- Freeze vehicle if option is enabled
    if self.freezeWhenStaged then
      self:freezeVehicle()
    end

    return true
  else
    -- log('D', logTag, 'Vehicle not staged at -10s check - rescheduling')
    if self:requestReschedule() then
      -- Rescheduling successful, update times for new slot
      self:updateTimesAfterReschedule()
      self.state = STATE_WAITING_FOR_STAGING_CHECK
      -- Note: warnings are handled inside requestReschedule()

      -- Play rescheduled audio
      if self:shouldPlayVoiceCountdown() then
        self:enqueueSystemPacenote('rescheduled')
      end
    else
      -- Max reschedules reached - exit and pass flow
      -- log('W', logTag, 'Max reschedules reached - finishing node and passing flow')
      self.state = STATE_FINISHED
      self.flags.finished = true
      self.pinOut.flow.value = true
    end
    return false
  end
end

function C:monitorCountdown()
  if not self.vehicleDataValid then
    log('W', logTag, 'Vehicle data not available for monitoring')
    return
  end

  -- Check for false start (vehicle crossed line before countdown ends)
  if self:hasCrossedStartLine() then
    log('W', logTag, 'FALSE START detected - vehicle crossed start line early')
    self.state = STATE_FALSE_START
    self.flags.falseStart = true

    -- Play false start audio
    if self:shouldPlayVoiceCountdown() then
      self:randomPauseSecs(1, 2)
      self:enqueueSystemPacenote('falseStart')
    end

    -- Record false start penalty in the manager
    local rm = self:getRallyLoopManager()
    if rm then
      rm:recordFalseStartPenalty()
    end

    -- Enable rally manager pacenote processing
    self:enableRallyManagerPacenoteProcessing()

    -- Unfreeze vehicle if it was frozen
    self:unfreezeVehicle()

    -- Let the stage start anyway (timer runs from actual crossing)
    self.flags.finished = true
    self.pinOut.flow.value = true
    return
  end

  -- Check if vehicle left launch zone (unstaged)
  if not self:isInLaunchZone() then
    log('W', logTag, 'Vehicle left launch zone during countdown - cancelling and rescheduling')
    self:unfreezeVehicle()

    if self:requestReschedule() then
      -- Rescheduling successful, reset to new slot
      self:updateTimesAfterReschedule()
      self.state = STATE_WAITING_FOR_STAGING_CHECK
      self.stagingCheckPassed = false
      -- Note: warnings are handled inside requestReschedule()
      -- guihooks.trigger('ScenarioFlashMessageClear')

      -- Switch UI back to start line context
      guihooks.trigger('RallyUIContextEnter_START_LINE', {})

      -- Play rescheduled audio
      if self:shouldPlayVoiceCountdown() then
        self:enqueueSystemPacenote('rescheduled')
      end
    else
      -- Max reschedules reached - exit and pass flow
      log('W', logTag, 'Max reschedules reached - finishing node and passing flow')
      self.state = STATE_FINISHED
      self.flags.finished = true
      self.pinOut.flow.value = true
    end
  end
end

function C:isOriginalSchedule()
  return self.rescheduleCount == 0
end

function C:isFlowActive()
  return self.state == STATE_FINISHED or self.state == STATE_FALSE_START
end

function C:isOngoing()
  return self.state == STATE_COUNTDOWN_RUNNING
end

function C:isWaiting()
  return self.state == STATE_WAITING_FOR_STAGING_CHECK or
         self.state == STATE_COUNTDOWN_ARMED or
         self.state == STATE_WAITING_FOR_STAGED
end

function C:processWarnings()
  local currentEpochTime = self:getCurrentEpochTime()
  if not currentEpochTime or not self.scheduledEventTime then
    return
  end

  local timeUntilEvent = self.scheduledEventTime - currentEpochTime

  for _, warningTime in ipairs(defaultWarningTimes) do
    if math.floor(timeUntilEvent) <= warningTime and not self.warningsTriggered[warningTime] then
      self.warningsTriggered[warningTime] = true

      -- Skip 10 second warning if max reschedules reached
      if warningTime == 10 and self.flags.maxReschedulesReached then
        log('D', logTag, 'Skipping 10s warning - max reschedules reached')
        goto continue
      end

      local warningMsg = string.format('%d seconds', warningTime)
      if self:shouldShowVisualCountdown() or self.data.useMessages or self.data.useImgui then
        self:show(warningMsg, false, 1.5)
      end

      if self:shouldPlayVoiceCountdown() then
        self:enqueueSystemPacenote('warningSeconds'..warningTime)

        -- Play special audio based on individual flags (original schedule or not skipped)
        if self:isOriginalSchedule() then
          if warningTime == 10 and self.playPrecountdown then
            self:enqueuePauseSecs(0.5)
            self:enqueueSystemPacenote('precountdown', 0.5)
          elseif warningTime == 30 and self.playBeltsCheck then
            self:randomPauseSecs(2, 5)
            self:enqueueSystemPacenote('beltsCheck')
          elseif warningTime == 60 and self.playCommsCheck then
            self:randomPauseSecs(2, 5)
            self:enqueueSystemPacenote('commsCheck')
          end
        end
      end

      ::continue::
    end
  end
end

function C:updateCountdownStateMachine()
  local currentEpochTime = self:getCurrentEpochTime()
  if not currentEpochTime then
    log('W', logTag, 'No current epoch time provided')
    return
  end

  -- State machine (process staging check BEFORE warnings to avoid playing incorrect audio)
  if self.state == STATE_WAITING_FOR_STAGING_CHECK then
    -- Waiting for -10s staging check
    if self.stagingCheckTime and currentEpochTime >= self.stagingCheckTime then
      self:checkStagingAt10s()
    end

  elseif self.state == STATE_COUNTDOWN_ARMED then
    -- Vehicle is staged, waiting for countdown to start
    -- Monitor for false starts and unstaging even before countdown begins
    self:monitorCountdown()

    if self.state ~= STATE_COUNTDOWN_ARMED then
      -- State changed during monitoring (cancelled, false start, etc.)
      return
    end

    if self.targetStartTime and currentEpochTime >= self.targetStartTime then
      self.timer = self.duration
      self.state = STATE_COUNTDOWN_RUNNING
      self.pinOut.waiting.value = false

      -- Send initial countdown value to UI
      -- local countdownValue = math.floor(self.timer)
      -- guihooks.trigger('RallyUIPerformCountdown', { countdown = countdownValue })

      -- log('D', logTag, 'Countdown started')
    end

  elseif self.state == STATE_COUNTDOWN_RUNNING then
    -- Countdown in progress
    self:monitorCountdown()

    if self.state ~= STATE_COUNTDOWN_RUNNING then
      -- State changed during monitoring (cancelled, false start, etc.)
      return
    end

    local old = math.floor(self.timer)
    self.timer = self.timer - self.mgr.dtSim

    if self.timer <= 0 then
      -- Countdown finished normally - transition to STATE_LAUNCHED

      -- Send final countdown value to UI (triggers GO!)
      -- guihooks.trigger('RallyUIPerformCountdown', { countdown = 0 })

      if self:shouldShowVisualCountdown() or self.data.useMessages or self.data.useImgui then
        self:show(FINISH_MSG, self.data.bigFinishMsg, FINISH_MSG_DURATION)
      end

      if self:shouldPlayVoiceCountdown() then
        self:enqueueSystemPacenote('countdowngo')
      end

      -- Transition to STATE_LAUNCHED (not STATE_FINISHED yet)
      self.state = STATE_LAUNCHED
      self.launchedTimer = 0.5  -- Show countdown at 0 for 0.5 seconds

      -- Enable rally manager pacenote processing
      self:enableRallyManagerPacenoteProcessing()

      -- Unfreeze vehicle when countdown finishes
      self:unfreezeVehicle()
    else
      -- Countdown in progress - show numbers
      if old ~= math.floor(self.timer) then
        -- Send countdown value to UI (use old value, the one that just finished)
        -- guihooks.trigger('RallyUIPerformCountdown', { countdown = old })

        if old <= self.maxAnnounced then
          local countdownMsg = string.format(COUNTDOWN_MSG_FORMAT, old)
          local bigMsg = COUNTDOWN_MSG_FORMAT == "%d"

          if self:shouldShowVisualCountdown() or self.data.useMessages or self.data.useImgui then
            self:show(countdownMsg, bigMsg, 0.95)
          end

          if self:shouldPlayVoiceCountdown() then
            self:enqueueSystemPacenote('countdown'..countdownMsg)
          end
        end
      end
    end

  elseif self.state == STATE_LAUNCHED then
    -- Vehicle has launched - countdown is at 0
    -- Wait for launchedTimer before transitioning to FINISHED
    self.launchedTimer = self.launchedTimer - self.mgr.dtSim

    if self.launchedTimer <= 0 then
      -- Transition to FINISHED state
      self.flags.finished = true
      self.state = STATE_FINISHED
      self.pinOut.flow.value = true
    end

  elseif self.state == STATE_WAITING_FOR_STAGED then
    -- This state is no longer used (max reschedules now goes directly to FINISHED)
    -- Kept for backwards compatibility
  end

  -- Process warnings after state machine (so rescheduleCount is updated)
  if self:isWaiting() then
    self:processWarnings()
  end
end

function C:getWallClockTime()
  -- Calculate wall clock time from epoch
  -- Test mode: use test instance
  if self.data.test and self.testInstance then
    return self.testInstance:getWallClockTime()
  end

  -- Normal mode: use rally loop manager
  local rm = self:getRallyLoopManager()
  if not rm then
    return nil
  end

  local currentEpochTime = rm:getEpochTime()
  if not currentEpochTime then
    return nil
  end

  local rallyStartTimeSecs = rm:getRallyStartTimeSecs()
  if not rallyStartTimeSecs then
    return nil
  end

  local environmentStartTimeSecs = rm.environmentStartTimeSecs
  if not environmentStartTimeSecs then
    return nil
  end

  -- Wall clock = environment start + epoch
  local wallClockSecs = (environmentStartTimeSecs + currentEpochTime) % 86400
  return wallClockSecs
end

function C:shouldDrawDebug()
  local rm = self:getRallyLoopManager()
  return self.data.drawDebug or (rm and rm:getDrawFlag('stopZones'))
end

function C:drawDebugVisualization()
  if not self:shouldDrawDebug() or not self.vehicleDataValid then
    return
  end

  -- Don't draw debug visuals when just passing flow through (countdown finished)
  if self:isFlowActive() then
    return
  end

  StagedCountdownUtils.drawDebugPlane(self.pos, self.rot)
  StagedCountdownUtils.drawVehicleToPlaneDebug(vehPos, self.pos, self.rot, tmpPlaneNormal, tmpToVehicle, tmpClosestPoint, tmpMidPoint)
  StagedCountdownUtils.drawDebugVehiclePoint(vehPos, self:isNearPlane())
end

function C:drawMiddle(builder, style)
  builder:Middle()

  -- Gather data for drawing
  local nodeData = {
    useImgui = self.data.useImgui,
    test = self.data.test,
    wallClockSecs = self:getWallClockTime(),
    currentEpochTime = self:getCurrentEpochTime(),
    scheduledEventTime = self:getScheduledEventTime(),
    stagingCheckTime = self.pinIn.stagingCheckTime.value,
    testInstance = self.testInstance,
    state = self.state,
    rescheduleCount = self.rescheduleCount,
    maxReschedules = self.pinIn.maxReschedules.value,
    inZone = nil,
    staged = nil
  }

  -- Use vehicle data if available from this frame
  if self.vehicleDataValid then
    nodeData.staged = self:isStaged()
    nodeData.inZone = self:isInLaunchZone()
  end

  -- Draw info
  local formatFunc = function(secs)
    return rallyUtil.formatTimeFromSeconds(secs, true, false)
  end
  StagedCountdownUtils.drawMiddleInfo(im, nodeData, formatFunc)

  -- Draw progress
  StagedCountdownUtils.drawMiddleProgress(im, self.state, self.duration, self.timer, STATE_COUNTDOWN_RUNNING, STATE_FINISHED)
end

function C:canSkipCountdown()
  -- Only allow skip in early waiting states, not during countdown
  if self.state ~= STATE_WAITING_FOR_STAGING_CHECK and self.state ~= STATE_WAITING_FOR_STAGED then
    return false
  end

  if not self.scheduledEventTime then
    return false
  end

  -- Check debounce timer (prevents skip spamming)
  if self.skipDebounceTimer > 0 then
    return false
  end

  -- Asymmetric threshold for staging check (prevents flickering when near boundary)
  -- Use different thresholds for enabling vs disabling skip
  local baseDistance = self.pinIn.distance.value or 1

  if not self.lastCanSkipValue then
    -- Currently not skippable - require strict staging to enable skip
    if not self:isStaged() then
      return false
    end
    self.lastCanSkipValue = true
    return true
  else
    -- Currently skippable - use relaxed thresholds to maintain skip state
    -- Allow slightly more distance (+0.5m) and speed (+1 kph hysteresis) before disabling
    local isNearWithHysteresis = self.signedDistance >= 0 and math.abs(self.signedDistance) <= (baseDistance + 0.5)
    local isStoppedWithHysteresis = vehVel:length() < (SPEED_THRESHOLD_SKIP_BASE + SPEED_THRESHOLD_SKIP_HYSTERESIS)

    if not (isNearWithHysteresis and isStoppedWithHysteresis) then
      self.lastCanSkipValue = false
      return false
    end
    return true
  end
end

function C:skipToCountdown()
  -- Skip directly to the final countdown window before launch.
  if not self:canSkipCountdown() then return end

  local targetEpochTime = self.scheduledEventTime - COUNTDOWN_SKIP_LEAD_SECONDS

  local rm = self:getRallyLoopManager()
  if rm then
    local oldClock = rm:getEpochTime()
    rm.clock = targetEpochTime

    -- Set 2-second debounce to prevent immediate re-skip
    self.skipDebounceTimer = 2.0

    -- After a clock skip, prioritize the final voice countdown over stale
    -- warning/precountdown audio that can back up the rally audio queue.
    for _, warningTime in ipairs(defaultWarningTimes) do
      self.warningsTriggered[warningTime] = true
      -- log('D', logTag, string.format('Marking %ds warning as already passed after skip', warningTime))
    end

    -- Suppress extra warning-adjacent audio after a skip; only 5-4-3-2-1-go should play.
    self.playCommsCheck = false
    self.playBeltsCheck = false
    self.playPrecountdown = false

    -- log('I', logTag, string.format('Skipped countdown from %.2fs to %.2fs', oldClock, targetEpochTime))
  end
end

function C:onGameplayInteract()
  if self:canSkipCountdown() then
    self.skipRequested = true
  end
end

function C:work(args)
  -- Update test epoch if in test mode
  if self.data.test and self.testInstance then
    self.testInstance.epoch = self.testInstance.epoch + self.mgr.dtSim
  end

  -- Decrement skip debounce timer
  if self.skipDebounceTimer > 0 then
    self.skipDebounceTimer = self.skipDebounceTimer - self.mgr.dtSim
  end

  -- Look up start line position (cached after first lookup)
  if not self:updateStartPosition() then
    if self.pinIn.flow.value then
      log('E', logTag, 'problem with updateStartPosition: '..tostring(self.startPositionInvalidReason))
    end
    return  -- No valid start position, cannot proceed
  end

  -- Update vehicle data once per frame
  self.vehicleDataValid = self:updateVehicleData()

  -- Update proximity state once per frame (depends on vehicle data)
  self:updateProximityState()

  if self.pinIn.reset.value then
    self:reset()
  end

  if self:shouldStartTimer() then
    self:startTimer()
  end

  self:updateCountdownStateMachine()
  self:drawDebugVisualization()

  -- Cache skip availability (used multiple times below)
  local canSkip = self:canSkipCountdown()

  -- Update countdown skip availability directly on manager
  local rm = self:getRallyLoopManager()
  if rm then
    rm:setCountdownCanSkip(canSkip)
  end

  -- Handle skip request
  if self.skipRequested then
    self.skipRequested = false
    if canSkip then
      self:skipToCountdown()
    end
  end

  -- Send proximity update hook for loopToolbox (same as vehicleStoppedNearPlane)
  -- Only send if not flow active to avoid duplicate updates, ie when the countdown hasnt happened yet.
  if self.vehicleDataValid and self.scheduledEventTime and not self:isFlowActive() then
    -- Unified proximity data structure
    local proximityData = {
      isNear = self:isInLaunchZone(),
      distance = self.signedDistance,
      isStopped = self:isStopped(),
      isFrozen = self.vehicleFrozen,
      timer = self.state == STATE_COUNTDOWN_RUNNING and (self.duration - self.timer) or 0,
      duration = self.duration
    }

    -- Determine active state based on countdown state
    local currentActiveState = rallyUtil.activeState_vehicleProximity
    local countdownData = nil

    if self.state == STATE_COUNTDOWN_ARMED or self.state == STATE_COUNTDOWN_RUNNING or self.state == STATE_LAUNCHED then
      currentActiveState = rallyUtil.activeState_countdown

      -- Prepare countdown data (just the countdown value - clock data is in rallyClock)
      local countdownValue
      if self.state == STATE_LAUNCHED then
        countdownValue = 0  -- Send 0 to trigger green GO in UI
      elseif self.state == STATE_COUNTDOWN_RUNNING then
        countdownValue = math.ceil(self.timer)
      else
        countdownValue = math.ceil(self.scheduledEventTime - (self:getCurrentEpochTime() or 0))
      end

      countdownData = {
        countdown = countdownValue,
        state = self.state
      }
    end

    -- Send to Lua extensions
    local updateData = {
      activeState = currentActiveState,
      vehicleProximity = proximityData
    }

    if countdownData then
      updateData.countdownData = countdownData
    end

    extensions.hook("onRallyDataUpdated", updateData)
  end

  -- Update output pins
  self.pinOut.flow.value = self:isFlowActive()
  self.pinOut.ongoing.value = self:isOngoing()
  self.pinOut.waiting.value = self:isWaiting()

  -- Set impulse flags and reset them
  for pName, val in pairs(self.flags) do
    self.pinOut[pName].value = val
    self.flags[pName] = false
  end
end

return _flowgraph_createNode(C)