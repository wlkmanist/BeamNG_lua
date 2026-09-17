-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local StagedCountdownUtils = require('/lua/ge/extensions/gameplay/rally/loop/stagedCountdownUtils')
local im = ui_imgui

local C = {}
local logTag = 'rallyStageSuperCountdown'

local defaultDuration = 3
local defaultMaxAnnounced = 3

local SPEED_THRESHOLD_STOPPED = 0.08
local FINISH_MSG = 'Go!'
local FINISH_MSG_DURATION = 1
local GO_DISPLAY_DURATION = 0.1
local COUNTDOWN_MSG_FORMAT = '%d'

local STATE_WAITING = 'waiting'
local STATE_COUNTDOWN_RUNNING = 'countdown_running'
local STATE_LAUNCHED = 'launched'
local STATE_FINISHED = 'finished'
local STATE_FALSE_START = 'false_start'

local tmpPlaneNormal = vec3()
local tmpToVehicle = vec3()
local tmpLateralToControl = vec3()
local tmpClosestPoint = vec3()
local tmpMidPoint = vec3()

local veh, vehicleData
local vehPos, vehVel = vec3(), vec3()

-- Keep false-start checks close to the actual start control instead of the
-- infinite start-line plane.
local finiteStartZoneRadius = 10

local function ensureRallyLoopBridgeLoaded()
  if extensions and extensions.isExtensionLoaded and extensions.load and not extensions.isExtensionLoaded(rallyUtil.extRallyLoop) then
    extensions.load(rallyUtil.extRallyLoop)
  end
end

C.name = 'Rally Stage Super Countdown'
C.icon = 'timer'
C.description = 'Standalone rally stage countdown with start-line proximity, false-start detection, and no rally-loop schedule dependency.'
C.color = rallyUtil.rally_flowgraph_color

C.pinSchema = {
  { dir = 'in', type = 'flow', name = 'flow', description = 'Inflow for this node.' },
  { dir = 'in', type = 'flow', name = 'reset', description = 'Reset the countdown.', impulse = true },
  { dir = 'in', type = 'table', name = 'pathData', tableType = 'pathData', description = 'Data from the path for start line position lookup.' },
  { dir = 'in', type = 'string', name = 'spName', description = 'Name of the start line position in pathData.' },
  { dir = 'in', type = 'number', name = 'vehId', description = 'Id of the vehicle to check.' },
  { dir = 'in', type = 'number', name = 'distance', default = 1, hardcoded = true, description = 'Distance threshold for launch zone (meters).' },

  { dir = 'out', type = 'flow', name = 'flow', description = 'Outflow after countdown or false start.' },
  { dir = 'out', type = 'flow', name = 'finished', description = 'Triggers when countdown has finished.', impulse = true },
  { dir = 'out', type = 'flow', name = 'ongoing', description = 'Triggers when countdown is in progress.' },
  { dir = 'out', type = 'flow', name = 'waiting', description = 'Triggers while the node is armed but not counting down.' },
  { dir = 'out', type = 'flow', name = 'falseStart', description = 'Triggers when false start detected.', impulse = true },
}
C.tags = {'rally'}

function C:init(mgr, ...)
  self.data.useImgui = false
  self.data.useMessages = false
  self.data.bigFinishMsg = true
  self.data.drawDebug = false

  self.state = STATE_WAITING
  self.duration = 1
  self.timer = 1
  self.maxAnnounced = defaultMaxAnnounced
  self.msg = FINISH_MSG
  self.running = false
  self.done = false
  self.startTimerAttempted = false
  self.goDisplayTimer = 0
  self.environmentStartTimeSecs = 0
  self.epochTime = 0
  self.scheduledEventTime = nil
  self.targetStartTime = nil
  self.lastAnnouncedCountdown = nil

  self.showVisualCountdown = nil
  self.playSoundEffects = nil
  self.playVoiceCountdown = nil

  self.vehicleDataValid = false
  self.signedDistance = 0
  self.displayDistance = 0
  self.lateralDistance = 0
  self.isInsideFiniteStartZone = false
  self.isOverLineAllowed = false
  self.isNearPlaneValue = false
  self.isStoppedValue = false
  self.isStagedValue = false

  self.pos = vec3()
  self.rot = quat()
  self.startPosValid = false
  self.cachedPathData = nil
  self.cachedSpName = nil

  self.flags = {
    finished = false,
    falseStart = false
  }
end

function C:_executionStarted()
  ensureRallyLoopBridgeLoaded()
  self:stopTimer()
  self.pos = vec3()
  self.rot = quat()
  self.startPosValid = false
  self.cachedPathData = nil
  self.cachedSpName = nil
end

function C:_executionStopped()
  self:stopTimer()
end

function C:reset()
  self:stopTimer()
  self.pinOut.flow.value = false
  self.pinOut.finished.value = false
  self.pinOut.ongoing.value = false
  self.pinOut.waiting.value = false
  self.pinOut.falseStart.value = false
end

function C:stopTimer()
  self.state = STATE_WAITING
  self.duration = 1
  self.timer = 1
  self.running = false
  self.done = false
  self.startTimerAttempted = false
  self.goDisplayTimer = 0
  self.environmentStartTimeSecs = 0
  self.epochTime = 0
  self.scheduledEventTime = nil
  self.targetStartTime = nil
  self.lastAnnouncedCountdown = nil
  self.flags = {
    finished = false,
    falseStart = false
  }
end

function C:updateStartPosition()
  local pathData = self.pinIn.pathData.value
  local spName = self.pinIn.spName.value

  if not pathData or not spName then
    self.startPosValid = false
    return false
  end

  if self.cachedPathData == pathData and self.cachedSpName == spName and self.startPosValid then
    return true
  end

  local sp = pathData:findStartPositionByName(spName)
  if sp then
    self.pos:set(sp.pos)
    self.rot:set(sp.rot)
    self.startPosValid = true
    self.cachedPathData = pathData
    self.cachedSpName = spName
    return true
  end

  self.startPosValid = false
  log('W', logTag, string.format('Start position not found: %s', spName or 'nil'))
  return false
end

function C:updateVehicleData()
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

  vehPos:set(rallyUtil.getVehFrontCenter(veh:getId()))
  vehVel:set(vehicleData.vel)
  return true
end

function C:updateProximityState()
  if not self.vehicleDataValid or not self.startPosValid then
    self.signedDistance = 0
    self.displayDistance = 0
    self.lateralDistance = 0
    self.isInsideFiniteStartZone = false
    self.isOverLineAllowed = false
    self.isNearPlaneValue = false
    self.isStoppedValue = false
    self.isStagedValue = false
    return
  end

  tmpPlaneNormal:set(0, 1, 0)
  tmpPlaneNormal:set(self.rot * tmpPlaneNormal)
  tmpPlaneNormal:normalize()

  tmpToVehicle:setSub2(vehPos, self.pos)
  local dist = tmpToVehicle:dot(tmpPlaneNormal)

  self.signedDistance = -dist

  tmpLateralToControl:set(tmpPlaneNormal)
  tmpLateralToControl:setScaled(dist)
  tmpLateralToControl:setSub2(tmpToVehicle, tmpLateralToControl)
  self.lateralDistance = tmpLateralToControl:length()
  self.isInsideFiniteStartZone = self.lateralDistance <= finiteStartZoneRadius

  self.isStoppedValue = vehVel:length() < SPEED_THRESHOLD_STOPPED

  -- Standalone stages can spawn with the vehicle nose over the start plane.
  -- Until false starts are handled here, keep that as a neutral UI state
  -- instead of letting clamped display distance derive GO BACK/STAGED/SLOW.
  local startDistance = self.pinIn.distance.value or 1
  self.isOverLineAllowed = self.isInsideFiniteStartZone and self.signedDistance < 0
  self.isNearPlaneValue = self.isInsideFiniteStartZone and self.signedDistance >= 0 and self.signedDistance <= startDistance
  self.isStagedValue = self.isNearPlaneValue and self.isStoppedValue

  if self.isInsideFiniteStartZone then
    self.displayDistance = math.max(0, self.signedDistance)
  else
    self.displayDistance = math.max(0, self.lateralDistance - finiteStartZoneRadius)
  end
end

function C:hasCrossedStartLine()
  -- False-start detection is intentionally shelved for the first stage
  -- countdown pass. Some rally stage starts spawn with the vehicle front
  -- already past the start plane, which made this fire immediately.
  return false
end

function C:shouldDrawDebug()
  return self.data.drawDebug
end

function C:drawDebugVisualization()
  if not self:shouldDrawDebug() or not self.vehicleDataValid or not self.startPosValid then
    return
  end

  StagedCountdownUtils.drawDebugPlane(self.pos, self.rot, true)
  StagedCountdownUtils.drawVehicleToPlaneDebug(vehPos, self.pos, self.rot, tmpPlaneNormal, tmpToVehicle, tmpClosestPoint, tmpMidPoint)
  StagedCountdownUtils.drawDebugVehiclePoint(vehPos, self.isNearPlaneValue)
end

function C:configureCountdownSettings()
  local countdownSettings = StagedCountdownUtils.getStageCountdownSettings(defaultDuration, defaultMaxAnnounced)
  self.showVisualCountdown = countdownSettings.showVisualCountdown
  self.playSoundEffects = countdownSettings.playSoundEffects
  self.playVoiceCountdown = countdownSettings.playVoiceCountdown
  self.duration = countdownSettings.duration
  self.maxAnnounced = countdownSettings.maxAnnounced
end

function C:calculateScheduledEventTime()
  local countdownSchedule = StagedCountdownUtils.calculateImmediateMinuteCountdown(self.duration)
  self.environmentStartTimeSecs = countdownSchedule.environmentStartTimeSecs
  self.epochTime = countdownSchedule.epochTime
  self.scheduledEventTime = countdownSchedule.scheduledEventTime
  self.targetStartTime = countdownSchedule.targetStartTime
  self.timer = countdownSchedule.timer
end

function C:getTimeUntilLaunch()
  return math.max(0, (self.scheduledEventTime or 0) - self.epochTime)
end

function C:getCountdownPhase(showingGo)
  local launchWindowSecs = self.scheduledEventTime or (self.duration + 1)
  if showingGo then
    return {
      timeUntilLaunch = 0,
      countdownValue = 0,
      announcedCountdown = nil,
      countdownElapsed = launchWindowSecs,
      progress = 1
    }
  end

  local timeUntilLaunch = self:getTimeUntilLaunch()
  local countdownValue = math.ceil(timeUntilLaunch)
  countdownValue = math.max(0, math.min(launchWindowSecs, countdownValue))
  local countdownElapsed = launchWindowSecs - math.min(timeUntilLaunch, launchWindowSecs)
  countdownElapsed = math.max(0, math.min(launchWindowSecs, countdownElapsed))

  return {
    timeUntilLaunch = timeUntilLaunch,
    countdownValue = countdownValue,
    announcedCountdown = timeUntilLaunch <= self.duration and countdownValue > 0 and countdownValue or nil,
    countdownElapsed = countdownElapsed,
    progress = countdownElapsed / math.max(1e-12, launchWindowSecs)
  }
end

function C:updateClock()
  if not self.startTimerAttempted or self.done then
    return
  end

  self.epochTime = self.epochTime + self.mgr.dtSim
end

function C:getWallClockTime()
  return StagedCountdownUtils.getWallClockTime(self.environmentStartTimeSecs, self.epochTime)
end

function C:getRallyClockData()
  return StagedCountdownUtils.buildRallyClockData(self:getWallClockTime())
end

function C:unfreezeVehicle()
  local vehObj = nil
  if self.pinIn.vehId.value then
    vehObj = scenetree.findObjectById(self.pinIn.vehId.value)
  end
  vehObj = vehObj or getPlayerVehicle(0)

  if vehObj then
    core_vehicleBridge.executeAction(vehObj, 'setFreeze', false)
    log('D', logTag, 'Vehicle unfrozen')
    return true
  end

  log('W', logTag, 'Could not unfreeze vehicle')
  return false
end

function C:startTimer()
  self.startTimerAttempted = true
  self:configureCountdownSettings()
  self:calculateScheduledEventTime()

  self.running = true
  self.done = false
  self.state = STATE_COUNTDOWN_RUNNING
  self.flags.finished = false
  self.flags.falseStart = false
  self.lastAnnouncedCountdown = nil
  self.pinOut.flow.value = false
  guihooks.trigger('ScenarioFlashMessageClear')
end

function C:shouldShowVisualCountdown()
  return self.showVisualCountdown
end

function C:shouldPlayVoiceCountdown()
  return self.playVoiceCountdown
end

function C:shouldPlaySoundEffects()
  return self.playSoundEffects
end

function C:enqueueSystemPacenote(pacenoteName)
  if not gameplay_rally then
    return
  end
  local rm = gameplay_rally.getRallyManager()
  if rm then
    rm:enqueueRandomSystemPacenote(pacenoteName)
  end
end

function C:enableRallyManagerPacenoteProcessing()
  if not gameplay_rally then
    return
  end
  local rm = gameplay_rally.getRallyManager()
  if rm then
    rm:setPacenoteProcessingEnabled(true)
  end
end

function C:show(msg, big, duration, luaCall)
  duration = duration or (big and 1.4 or 0.95)
  guihooks.trigger('ScenarioFlashMessage', {{msg, duration, luaCall or '', big}})

  if self.data.useMessages then
    local msgStr = tostring(msg)
    local msgForDisplay = tonumber(msgStr) and ('Countdown: ' .. msgStr) or msgStr
    guihooks.trigger('Message', {
      ttl = 1,
      msg = msgForDisplay,
      category = ('rallyStageCountdown__' .. self.id),
      icon = 'timer'
    })
  end
end

function C:finishCountdown()
  local finishSound = ''
  if self:shouldPlaySoundEffects() and not self:shouldPlayVoiceCountdown() then
    finishSound = "Engine.Audio.playOnce('AudioGui', 'event:UI_CountdownGo')"
  end

  self:unfreezeVehicle()

  if self:shouldShowVisualCountdown() then
    self:show(FINISH_MSG, self.data.bigFinishMsg, FINISH_MSG_DURATION, finishSound)
  elseif finishSound ~= '' then
    guihooks.trigger('ScenarioFlashMessage', {{'', 0, finishSound, false}})
  end

  if self:shouldPlayVoiceCountdown() then
    self:enqueueSystemPacenote('countdowngo')
  end

  self:enableRallyManagerPacenoteProcessing()
  self.flags.finished = true
  self.running = false
  self.done = true
  self.goDisplayTimer = GO_DISPLAY_DURATION
  self.state = STATE_LAUNCHED
  self.pinOut.flow.value = true
end

function C:triggerFalseStart()
  log('W', logTag, 'FALSE START detected - vehicle crossed start line early')

  if self:shouldPlayVoiceCountdown() then
    self:enqueueSystemPacenote('falseStart')
  end

  self:enableRallyManagerPacenoteProcessing()
  self.flags.falseStart = true
  self.flags.finished = true
  self.running = false
  self.done = true
  self.goDisplayTimer = 0
  self.state = STATE_FALSE_START
  self.pinOut.flow.value = true
end

function C:updateCountdown()
  if self.done then
    return
  end

  if self.state == STATE_WAITING then
    self.timer = self:getTimeUntilLaunch()
    if self.targetStartTime and self.epochTime >= self.targetStartTime then
      self.running = true
      self.state = STATE_COUNTDOWN_RUNNING
      self.timer = self:getTimeUntilLaunch()
    else
      return
    end
  end

  if not self.running then
    return
  end

  if self:hasCrossedStartLine() then
    self:triggerFalseStart()
    return
  end

  self.timer = self:getTimeUntilLaunch()
  local countdownPhase = self:getCountdownPhase(false)

  if countdownPhase.timeUntilLaunch <= 0 then
    self:finishCountdown()
    return
  end

  if countdownPhase.announcedCountdown and countdownPhase.announcedCountdown ~= self.lastAnnouncedCountdown and countdownPhase.announcedCountdown <= self.maxAnnounced then
    self.lastAnnouncedCountdown = countdownPhase.announcedCountdown
    local countdownMsg = string.format(COUNTDOWN_MSG_FORMAT, countdownPhase.announcedCountdown)
    local bigMsg = COUNTDOWN_MSG_FORMAT == '%d'
    local countdownSound = ''

    if self:shouldPlaySoundEffects() and not self:shouldPlayVoiceCountdown() then
      countdownSound = "Engine.Audio.playOnce('AudioGui', 'event:UI_Countdown1')"
    end

    if self:shouldShowVisualCountdown() then
      self:show(countdownMsg, bigMsg, 0.95, countdownSound)
    elseif countdownSound ~= '' then
      guihooks.trigger('ScenarioFlashMessage', {{'', 0, countdownSound, false}})
    end

    if self:shouldPlayVoiceCountdown() then
      self:enqueueSystemPacenote('countdown' .. countdownMsg)
    end
  end
end

function C:updateGoDisplay()
  if self.goDisplayTimer <= 0 then
    return
  end

  self.goDisplayTimer = self.goDisplayTimer - self.mgr.dtSim
  if self.goDisplayTimer <= 0 then
    self.state = STATE_FINISHED
  end
end

function C:sendRallyDataUpdate()
  local showingGo = self.goDisplayTimer > 0
  if not self.pinIn.flow.value and not self.startTimerAttempted and not showingGo then
    return
  end

  if not self.startPosValid or not self.vehicleDataValid or (self.done and not showingGo) then
    return
  end

  local countdownActive = self.startTimerAttempted and (not self.done or showingGo)
  local countdownPhase = self:getCountdownPhase(showingGo)

  local proximityData = {
    isStartLine = true,
    isOverLineAllowed = self.isOverLineAllowed or false,
    isNear = self.isNearPlaneValue,
    distance = self.displayDistance,
    distanceToPlane = self.signedDistance,
    isStopped = self.isStoppedValue,
    isFrozen = false,
    timer = (self.running or showingGo) and countdownPhase.countdownElapsed or 0,
    duration = self.duration
  }

  local updateData = {
    activeState = countdownActive and rallyUtil.activeState_countdown or rallyUtil.activeState_vehicleProximity,
    vehicleProximity = proximityData,
    rallyClock = self:getRallyClockData()
  }

  if countdownActive then
    updateData.countdownData = {
      countdown = countdownPhase.countdownValue,
      state = self.state
    }
  end

  extensions.hook('onRallyDataUpdated', updateData)
end

function C:drawMiddle(builder, style)
  builder:Middle()
  local progress = self.running and self:getCountdownPhase(false).progress or 0
  im.ProgressBar(progress, im.ImVec2(100, 0))
  im.Text(self.state)
end

function C:work(args)
  if self.pinIn.reset.value then
    self:reset()
  end

  self:updateStartPosition()
  self.vehicleDataValid = self:updateVehicleData()
  self:updateProximityState()

  if self.pinIn.flow.value and not self.running and not self.done and not self.startTimerAttempted then
    self:startTimer()
  end

  self:updateClock()
  self:updateCountdown()
  self:updateGoDisplay()
  self:drawDebugVisualization()
  self:sendRallyDataUpdate()

  self.pinOut.flow.value = self.done
  self.pinOut.ongoing.value = self.running
  self.pinOut.waiting.value = self.pinIn.flow.value and not self.running and not self.done

  for pName, val in pairs(self.flags) do
    self.pinOut[pName].value = val
    self.flags[pName] = false
  end
end

return _flowgraph_createNode(C)
