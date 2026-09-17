-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local rallyUtil = require('/lua/ge/extensions/gameplay/rally/util')
local voicepack = require('/lua/ge/extensions/gameplay/rally/voicepack')
local RallyEnums = require('/lua/ge/extensions/gameplay/rally/enums')
local VehicleTracker  = require('/lua/ge/extensions/gameplay/rally/vehicleTracker')
local AudioManager = require('/lua/ge/extensions/gameplay/rally/audioManager')
local DrivelineRoute = require('/lua/ge/extensions/gameplay/rally/driveline/drivelineRoute')
local DrivelineV3 = require('/lua/ge/extensions/gameplay/rally/driveline/drivelineV3')
local StageObserver = require('/lua/ge/extensions/gameplay/rally/stage/stageObserver')
local StageTimingState = require('/lua/ge/extensions/gameplay/rally/stage/stageTimingState')
local RecoveryClockAdvance = require('/lua/ge/extensions/gameplay/rally/recoveryClockAdvance')
local Snaproad = require('/lua/ge/extensions/gameplay/rally/snaproad')
local NotebookPath = require('/lua/ge/extensions/gameplay/rally/notebook/path')
local dequeue = require('dequeue')

local C = {}
local logTag = ''

local holdValue = 'HOLD'

local function createSyntheticEmptyNotebook(missionDir)
  local notebook = NotebookPath("Route Preview")
  notebook.syntheticRoutePreview = true

  if missionDir then
    notebook:setFname(missionDir..'/'..rallyUtil.notebooksPath..'/__route_preview_empty.notebook.json')
  end

  log('I', logTag, 'using synthetic empty notebook for route preview: '..tostring(notebook.fname))
  return notebook
end

function C:init(missionDir, missionId)
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, '<<<<< RallyManager init >>>>>') end

  self.damageThresh = 100

  self.pacenoteQueue = dequeue.new()

  self.missionId = missionId
  self.missionDir = missionDir
  self.missionName = nil
  self:getMissionName()

  self.notebook = nil
  self.racePath = nil
  self.raceData = nil
  -- self.splitPathnodes = nil

  self.audioManager = nil
  self.vehicleTracker = nil
  -- self.drivelineMode = nil
  self.drivelineRoute = nil
  self.drivelineV3 = nil

  self.errorMsgForUser = nil
  self.pacenoteProcessingEnabled = true
  self.lastPlayedPacenote = nil
  self.lastPlayedPacenoteIdx = nil
  self.lastPlayedPacenoteName = nil
  self.trackerPreviousDistFromStart = nil
  self.trackerStageComplete = false
  self.trackerStageFinishTime = nil
  self.stageObserver = StageObserver()
  self.stageTimingState = StageTimingState()
  self.stageRuntimeAuthorityMode = 'shadow'
  self.preserveRecoveryTrackerOnNextVehicleReset = false

  -- session-scoped voicepack picker, set by the Rally Toolbox.
  --   nil or {type='preferences'} -> defer to accepted-language/MRU preferences
  --   {type='voicepack', id=<namespaced id>, scope='global'|'mission', dirname=<voicepack folder>}
  self.voicepackPick = nil
  self.voicepackPickWritesSettings = true
end

function C:getVoicepackPick()
  return self.voicepackPick or { type = 'preferences' }
end

function C:getVoicepackPickWritesSettings()
  return self.voicepackPickWritesSettings ~= false
end

function C:_refreshNotebookForVoicepackPick()
  if not self.notebook then return end
  if self.notebook.invalidateActiveVoicepackCache then
    self.notebook:invalidateActiveVoicepackCache()
  end
  self.notebook:invalidateCustomAudioMapping()
  self.notebook:onRallySettingsChanged()
end

function C:setVoicepackPick(pick, opts)
  opts = opts or {}
  self.voicepackPick = pick and pick.type == 'auto' and { type = 'preferences' } or pick
  self.voicepackPickWritesSettings = opts.writeSettings ~= false
  if self.voicepackPickWritesSettings and self.voicepackPick and self.voicepackPick.type == 'voicepack' then
    voicepack.addToMRU(self.voicepackPick, self.missionDir, self.missionId)
  end
  if not opts.deferNotebookRefresh then
    self:_refreshNotebookForVoicepackPick()
  end
end

function C:getErrorMsgForUser()
  return self.errorMsgForUser
end

function C:getPacenoteProcessingEnabled()
  return self.pacenoteProcessingEnabled
end

function C:setPacenoteProcessingEnabled(enabled)
  self.pacenoteProcessingEnabled = enabled
end

-- function C:setDrivelineMode(drivelineMode)
--   self.drivelineMode = drivelineMode
-- end

-- function C:getDrivelineMode()
--   return self.drivelineMode
-- end

function C:getMissionId()
  return self.missionId
end

function C:getMissionDir()
  return self.missionDir
end

function C:getNotebookPath()
  return self.notebook
end

function C:getAudioManager()
  return self.audioManager
end

function C:getRacePath()
  return self.racePath
end

function C:getRaceData()
  return self.raceData
end

function C:setRaceData(raceData)
  self.raceData = raceData
end

function C:getStartPositionByName(name)
  if not self.racePath then
    return nil
  end

  for _, sp in ipairs(self.racePath.startPositions.sorted) do
    if sp.name == name then
      return sp
    end
  end
  return nil
end

function C:getTCInPos()
  return self:getStartPositionByName("TC_in")
end

function C:getTCOutPos()
  return self:getStartPositionByName("TC_out")
end

function C:getSSStartLinePos()
  return self:getStartPositionByName("SS_start_line")
end

function C:getSSStopControlPos()
  return self:getStartPositionByName("SS_stop_control")
end

function C:getMissionName()
  if self.missionName then
    return self.missionName
  else
    self.missionName = rallyUtil.translatedMissionNameFromId(self.missionId)
    return self.missionName
  end
end

function C:getMissionStartTrigger()
  local mission = gameplay_missions_missions.getMissionById(self.missionId)
  if not mission then
    log('E', logTag, 'getMissionStartTriggerPos: mission not found')
    return nil
  end
  return mission.startTrigger
end

function C:triggerPacenote(pacenote)
  profilerPushEvent("rallyManager:triggerPacenote")
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'triggerPacenote name='..tostring(pacenote.name)) end
  if self:_playbackAllowed(pacenote) then
    local settingVisualPacenotes = settings.getValue('rallyVisualPacenotes')
    local settingAudioPacenotes = settings.getValue('rallyAudioPacenotes')

    if settingAudioPacenotes then
      -- gcprobe()
      if self:sendPacenoteToAudioManager(pacenote) then
        self:setLastPlayedPacenote(pacenote)
      end
      -- gcprobe()
    end

    -- custom audio notebooks intentionally do not emit visual pacenotes:
    -- their visuals would be derived from auto-compiled structured data the author
    -- isnt managing, and the JS app expects well-formed visual entries.
    if settingVisualPacenotes and not (self.notebook and self.notebook:isAudioModeCustom()) then
      -- gcprobe()
      self:triggerShowVisualPacenote(pacenote)
      -- gcprobe()
    end
  end
  profilerPopEvent("rallyManager:triggerPacenote")
end

function C:setupDrivelineRouteHooks()
  local rallyManager = self

  self.drivelineRoute.onPacenoteCsDynamicHit = function(pacenote, shouldTriggerAudio)
    if shouldTriggerAudio then
      rallyManager:enqueuePacenote(pacenote)
      if pacenote.slowCorner then
        rallyManager:enqueueHold()
      end
    end
  end

  self.drivelineRoute.onPacenoteCsImmediateHit = function(pacenote, shouldTriggerAudio)
    if shouldTriggerAudio then
      rallyManager:enqueuePacenote(pacenote)
      if pacenote.slowCorner then
        rallyManager:enqueueHold()
      end
    end
  end

  self.drivelineRoute.onPacenoteCsStaticHit = function(pacenote, shouldTriggerAudio)
    rallyManager:triggerClearVisualPacenote(pacenote)
    if shouldTriggerAudio then
      rallyManager:enqueuePacenote(pacenote)
      if pacenote.slowCorner then
        rallyManager:enqueueHold()
      end
    end
    if pacenote:isSlowCornerReleaseCsStatic() then
      if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'slowCorner release csStatic name='..tostring(pacenote.name)) end
      rallyManager:clearQueueHold()
    end
  end

  self.drivelineRoute.onPacenoteCeStaticHit = function(pacenote, shouldTriggerAudio)
    if shouldTriggerAudio then
      rallyManager:enqueuePacenote(pacenote)
      if pacenote.slowCorner then
        rallyManager:enqueueHold()
      end
    end
    if pacenote:isSlowCornerReleaseCeStatic() then
      if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'slowCorner release ceStatic name='..tostring(pacenote.name)) end
      rallyManager:clearQueueHold()
    end
  end

  self.drivelineRoute.onPacenoteCsOffsetHit = function(pacenote, shouldTriggerAudio, offset)
    -- offset has to be manually checked by the programmer here against what trigger points the driveline route is tracking.
    if offset == -40 then
      if shouldTriggerAudio then
        rallyManager:enqueuePacenote(pacenote)
        if pacenote.slowCorner then
          rallyManager:enqueueHold()
        end
      end
      if pacenote:isSlowCornerReleaseCsStaticMinus40() then
        if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'slowCorner release csStaticMinus40 name='..tostring(pacenote.name)) end
        rallyManager:clearQueueHold()
      end
    end
  end

  self.drivelineRoute.onPacenoteCeOffsetHit = function(pacenote, shouldTriggerAudio, offset)
    -- offset has to be manually checked by the programmer here against what trigger points the driveline route is tracking.
    if offset == -5 then
      if shouldTriggerAudio then
        rallyManager:enqueuePacenote(pacenote)
        if pacenote.slowCorner then
          rallyManager:enqueueHold()
        end
      end
      if pacenote:isSlowCornerReleaseCeMinus5() then
        if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'slowCorner release ceMinus5 name='..tostring(pacenote.name)) end
        rallyManager:clearQueueHold()
      end
    end
  end

  self.drivelineRoute.onPacenoteCornerPercentHit = function(pacenote, shouldTriggerAudio, percent)
    -- percent has to be manually checked by the programmer here against what trigger points the driveline route is tracking.
    if percent == 0.5 then
      if shouldTriggerAudio then
        rallyManager:enqueuePacenote(pacenote)
        if pacenote.slowCorner then
          rallyManager:enqueueHold()
        end
      end

      if pacenote:isSlowCornerReleaseCsHalf() then
        if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'slowCorner release csHalf name='..tostring(pacenote.name)) end
        rallyManager:clearQueueHold()
      end
    end
  end
end

function C:codriver()
  return self.notebook:selectedCodriver()
end

-- used by RallyEditor
-- function C:getSnaproadPointsFromRoute()
--   local dr = DrivelineRoute()
--   local points = dr:pointsForSnaproad(self.race, self.notebook)
--   if not points then
--     log('E', logTag, 'failed to load snaproad points')
--     return false
--   end

--   return points
-- end

-- function C:indexSplits()
--   self.splitPathnodes = {}
--   local pathnodes = self.racePath.pathnodes.sorted
--   for _, pathnode in ipairs(pathnodes) do
--     local name = pathnode.name
--     local useAsSplit = pathnode.useAsSplit
--     if useAsSplit then
--       local rp = pathnode:getRoutePoint()
--       if rp then
--         self.splitPathnodes[name] = pathnode
--       end
--     end
--   end
-- end

function C:getPointDistanceFromStartMeters(point)
  return self.drivelineRoute:getPointDistanceFromStartMeters(point)
end

function C:getPointDistanceFromStartKm(point)
  return self.drivelineRoute:getPointDistanceFromStartKm(point)
end

function C:getTimeAllocationSecs()
  if not self.drivelineRoute or not self.drivelineV3 then
    return nil
  end

  local distanceMeters = self.drivelineRoute:getDistanceMeters()
  if not distanceMeters or distanceMeters < 0 then
    return nil
  end

  local distanceKm = distanceMeters / 1000
  local speedKph = self.drivelineV3:getSpeedLimitKph()

  -- Time = Distance / Speed, convert hours to seconds
  local timeHours = distanceKm / speedKph
  local timeSeconds = timeHours * 3600

  return timeSeconds
end

function C:getTimeAllocationString()
  local timeSecs = self:getTimeAllocationSecs()
  if not timeSecs then
    return "N/A"
  end

  -- Round up to nearest minute
  local totalMinutes = math.ceil(timeSecs / 60)
  local hours = math.floor(totalMinutes / 60)
  local minutes = totalMinutes % 60
  return string.format("%dh %dm", hours, minutes)
end

-- function C:getSplitPathnode(name)
--   if not self.splitPathnodes then
--     log('E', logTag, 'getSplitPathnode: splitPathnodes not indexed')
--     return nil
--   end
--   return self.splitPathnodes[name]
-- end

function C:getSplitDataList()
  if not self.drivelineRoute or not self.drivelineRoute.splitDataList then
    return nil
  end
  return self.drivelineRoute.splitDataList
end

function C:getSplitDataIndex()
  if not self.drivelineRoute or not self.drivelineRoute.splitDataIndex then
    return nil
  end
  return self.drivelineRoute.splitDataIndex
end

function C:getPathnodeObservationList()
  if not self.drivelineRoute or not self.drivelineRoute.pathnodeObservationList then
    return nil
  end
  return self.drivelineRoute.pathnodeObservationList
end

-- Picks the active voicepack via an exact toolbox/mission pick or the preference/MRU resolver,
-- then finds the matching notebook in this mission. If none exists, returns an in-memory
-- empty notebook so geometry-only rally routes can still be previewed.
function C:resolveAndLoadNotebook()
  local _, vpEntry = voicepack.resolveEffectiveEntry(self.missionDir, self:getVoicepackPick(), {
    missionId = self.missionId,
    writeSettings = self:getVoicepackPickWritesSettings(),
  })
  local notebookFname = voicepack.resolveMissionNotebook(self.missionDir, vpEntry)

  if not notebookFname then
    log('W', logTag, 'no notebook found for mission '..tostring(self.missionDir)..' (voicepack compositorStyle='..tostring(vpEntry and vpEntry.compositorStyle)..')')
    return createSyntheticEmptyNotebook(self.missionDir)
  end

  return rallyUtil.loadNotebook(notebookFname)
end

function C:rebuildAssets(options)
  options = options or {}
  if options.assets == false then
    return self:runtimeResync(options)
  end

  log('I', logTag, 'RallyManager rebuildAssets')
  -- log('D', logTag, 'rebuildAssets')

  self.errorMsgForUser = nil

  self.vehicleTracker = VehicleTracker(self.damageThresh)

  local racePath, err = rallyUtil.loadRacePath(self.missionDir)
  if not racePath then
    log('E', logTag, 'RallyManager setup: no racePath ('..tostring(err)..')')
    self.errorMsgForUser = 'race.json missing'
    return false
  end
  self.racePath = racePath

  self.notebook = self:resolveAndLoadNotebook()
  if not self.notebook then
    log('E', logTag, 'RallyManager setup: failed to load notebook')
    self.errorMsgForUser = 'failed to load notebook'
    return false
  end

  if self.notebook:isAudioModeCustom() then
    log('I', logTag, 'custom audio notebook loaded ('..tostring(self.notebook:basename())..'); visual pacenotes disabled for this notebook')
  end

  -- structured-note cache derivation depends on the active text compositor, which
  -- is resolved via this rallyManager's voicepack pick. By now self has been
  -- registered with gameplay_rally and self.voicepackPick is set, so resolution
  -- picks the right style.
  self.notebook:refreshAllStructuredNotes()

  -- cacheCompiledPacenotes is deferred until after the snaproad is attached
  -- (below), so measured corner projections and distance calls land in the cache.
  -- must load audioManager after notebook is loaded
  self.audioManager = AudioManager(self)

  -- self.drivelineMode = self.drivelineMode or ms:getDrivelineMode()
  -- if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'drivelineMode=' .. tostring(RallyEnums.drivelineModeNames[self.drivelineMode])) end

  self.drivelineRoute = DrivelineRoute()
  self:setupDrivelineRouteHooks()

  if self.drivelineRoute then
    -- Try to load driveline using DrivelineV3
    self.drivelineV3 = DrivelineV3(self.missionDir)
    local drivelineLoadSuccess = self.drivelineV3:loadDrivelineFromFile()

    if drivelineLoadSuccess then
      -- Successfully loaded and processed driveline
      local pointList = self.drivelineV3:getFinalPointList()
      if pointList then
        -- Hand the snaproad to the notebook before route loading so the
        -- load refresh can rebuild distance calls against the real road.
        self.notebook:setSnaproad(Snaproad(pointList))
        self.notebook:refreshPacenotes()

        if not self.drivelineRoute:loadRouteFromRecordedDriveline(self.racePath, self.notebook, pointList) then
          log('E', logTag, 'failed to load driveline route from processed driveline')
          self.errorMsgForUser = 'failed to load recorded driveline'
          return false
        end
      else
        log('E', logTag, 'DrivelineV3 processed but failed to create PointList')
        self.errorMsgForUser = 'failed to create PointList'
        return false
      end
    -- else
    --   -- No driveline data exists yet, which is OK for recording mode
    --   log('I', logTag, 'no driveline found, initializing for recording mode')
    --   -- Initialize drivelineRoute from the race route so we can still function
    --   if not self.drivelineRoute:loadRoute(self.race, self.notebook) then
    --     log('E', logTag, 'failed to load fallback route driveline for recording mode')
    --     self.errorMsgForUser = 'failed to load fallback route for recording mode'
    --     return false
    --   end
    end

    self.drivelineRoute:setVehicleTracker(self.vehicleTracker)
  else
    log('E', logTag, 'failed to initialize driveline route')
    self.errorMsgForUser = 'failed to initialize DrivelineRoute'
    return false
  end

  -- Snaproad is attached and autofill has populated before/after distance calls;
  -- now cache the compiled noteText that the audio queue and visual app will read.
  self.notebook:cacheCompiledPacenotes()

  if not self:runtimeResync({ deferRuntime = options.deferRuntime ~= false }) then
    log('E', logTag, 'runtimeResync failed')
    self.errorMsgForUser = 'runtimeResync failed'
    return false
  end

  return true
end

-- Voicepack changes rebuild all compositor-derived state, including distance calls.
function C:reloadVoicepackAssets(pick, opts)
  opts = opts or {}
  self:setVoicepackPick(pick, {
    writeSettings = opts.writeSettings,
    deferNotebookRefresh = true,
  })
  return self:rebuildAssets()
end

function C:resetStageRuntime()
  self.trackerPreviousDistFromStart = nil
  self.trackerStageComplete = false
  self.trackerStageFinishTime = nil

  if self.stageTimingState then
    self.stageTimingState:reset()
  end
  if self.stageObserver then
    self.stageObserver:reset()
    self.stageObserver:setAuthorityMode(self:getStageRuntimeAuthorityMode())
  end
end

function C:resetPacenoteRuntime()
  self:triggerClearAllVisualPacenotes()
  self:resetAudioQueue()
  self.pacenoteQueue = dequeue.new()
end

function C:resyncAfterTeleport(options)
  options = options or {}
  log('I', logTag, 'RallyManager resyncAfterTeleport')

  self:resetPacenoteRuntime()
  self.trackerPreviousDistFromStart = nil
  if self.stageObserver then
    if self.stageObserver.resetAfterTeleport then
      self.stageObserver:resetAfterTeleport()
    elseif self.stageObserver.resetFootprint then
      self.stageObserver:resetFootprint()
    end
  end

  if self.drivelineRoute then
    if options.deferRuntime == false then
      self.drivelineRoute:recalculate({ preserveStaticTracker = options.preserveRecoveryTracker == true })
      self.drivelineRoute.recalcNeeded = false
      self.drivelineRoute.dtSimSumSinceRecalc = 0
      self.drivelineRoute.dynamicTriggerSpeedMs = nil
    else
      self.drivelineRoute:setRecalcNeeded({ preserveStaticTracker = options.preserveRecoveryTracker == true })
    end
  end

  return true
end

function C:clearResolvedAudioObjs()
  if self.notebook then
    self.notebook:clearResolvedAudioObjs()
  end
end

function C:runtimeResync(options)
  options = options or {}
  log('I', logTag, 'RallyManager runtimeResync')
  -- log('D', logTag, 'runtimeResync')

  self:clearResolvedAudioObjs()
  self:resetStageRuntime()

  return self:resyncAfterTeleport(options)
end

function C:onSettingsChanged()
  if self.notebook then
    self.notebook:onRallySettingsChanged()
  end
  self:resetAudioQueue()
end

function C:setPreserveRecoveryTrackerOnNextVehicleReset(val)
  self.preserveRecoveryTrackerOnNextVehicleReset = val == true
end

function C:onVehicleResetted()
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'onVehicleResetted') end
  local preserveRecoveryTracker = self.preserveRecoveryTrackerOnNextVehicleReset == true
  self.preserveRecoveryTrackerOnNextVehicleReset = false
  self:clearResolvedAudioObjs()
  if not self:resyncAfterTeleport({ preserveRecoveryTracker = preserveRecoveryTracker }) then
    log('E', logTag, 'resyncAfterTeleport failed')
  end
end

function C:_playbackAllowed(pacenote)
  local allowed, err = pacenote:playbackAllowed()
  if err then
    log('E', logTag, 'error in pacenote:playbackAllowed(): '..err)
    allowed = true
  end

  if not allowed then
    log('I', logTag, '['..pacenote.name..'] playbackAllowed: false')
  end

  return allowed
end

function C:triggerShowVisualPacenote(pacenote)
  if not pacenote then return end
  profilerPushEvent("rallyManager:triggerShowVisualPacenote")
  local compiledPacenote = pacenote:asCompiled()

  if not compiledPacenote or not compiledPacenote.visualPacenoteEvent then
    log('E', logTag, "triggerShowVisualPacenote: no compiled visual pacenote event")
    profilerPopEvent("rallyManager:triggerShowVisualPacenote")
    return
  end

  if gameplay_rally and gameplay_rally.getDebugLogging() then
    log('D', logTag, string.format('triggerShowVisualPacenote name=%s, serialNo=%s', pacenote.name, pacenote.visualSerialNo))
  end

  guihooks.trigger('showVisualPacenote2', compiledPacenote.visualPacenoteEvent)
  profilerPopEvent("rallyManager:triggerShowVisualPacenote")
end

function C:triggerClearVisualPacenote(pacenote)
  if not pacenote then return end
  profilerPushEvent("rallyManager:triggerClearVisualPacenote")
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, string.format('triggerClearVisualPacenote name=%s, serialNo=%s', pacenote.name, pacenote.visualSerialNo)) end
  guihooks.trigger('clearOneVisualPacenote', pacenote.visualSerialNo)
  profilerPopEvent("rallyManager:triggerClearVisualPacenote")
end

function C:triggerClearAllVisualPacenotes()
  profilerPushEvent("rallyManager:triggerClearAllVisualPacenotes")
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'triggerClearAllVisualPacenotes') end
  guihooks.trigger('clearAllVisualPacenotes')
  profilerPopEvent("rallyManager:triggerClearAllVisualPacenotes")
end

function C:drawPacenotesForDriving()
  local nextPacenotes = self:getNextPacenotes()
  local pacenote = nextPacenotes[1]
  if pacenote then
    local wp_cs = pacenote:getCornerStartWaypoint()
    local render_wp = wp_cs
    local codriver = self:codriver()
    local compiledPacenote = pacenote:asCompiled(codriver)
    if compiledPacenote then
      local noteText = compiledPacenote.noteText
      render_wp:drawDebugRecce(1, noteText)
    end
  end
end

function C:onUpdate(dtReal, dtSim, dtRaw)
  profilerPushEvent("rallyManager:onUpdate")
  if self.vehicleTracker then
    self.vehicleTracker:onUpdate(dtReal, dtSim, dtRaw)
  end

  -- gcprobe()
  if self.drivelineRoute then
    self.drivelineRoute:onUpdate(dtReal, dtSim, dtRaw)
    if self.stageTimingState then
      self.stageTimingState:advance(dtSim or 0)
    end
    self:updateTrackerSplitObservations()
  end

  -- gcprobe()
  if self.audioManager then
    self.audioManager:onUpdate(dtReal, dtSim, dtRaw)
  end
  -- gcprobe()

  self:processPacenoteQueue()
  -- gcprobe()
  profilerPopEvent("rallyManager:onUpdate")
end

function C:clearQueueHold()
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'clearQueueHold') end
  local peekValue = self.pacenoteQueue:peek_left()
  if peekValue == holdValue then
    self.pacenoteQueue:pop_left()
  end
end

function C:enqueuePacenote(pacenote)
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'enqueuePacenote name='..tostring(pacenote.name)) end
  self.pacenoteQueue:push_right(pacenote)
end

function C:enqueueHold()
  if gameplay_rally and gameplay_rally.getDebugLogging() then log('D', logTag, 'enqueueHold') end
  self.pacenoteQueue:push_right(holdValue)
end

local peekValue = nil
local qPacenote = nil
function C:processPacenoteQueue()
  if not self.pacenoteProcessingEnabled then return end
  profilerPushEvent("rallyManager:processPacenoteQueue")
  peekValue = self.pacenoteQueue:peek_left()
  if peekValue == holdValue then
    -- log('D', logTag, 'processPacenoteQueue: '..tostring(peekValue)) -- spams the log
    -- do nothing
  elseif self.pacenoteQueue:length() > 0 then
    qPacenote = self.pacenoteQueue:pop_left()
    if qPacenote then
      if gameplay_rally and gameplay_rally.getDebugLogging() then
        log('D', logTag, string.format('processPacenoteQueue: got pacenote name=%s', tostring(qPacenote.name)))
      end
      self:triggerPacenote(qPacenote)
    else
      log('E', logTag, 'processPacenoteQueue: expected pacenote in queue')
    end
  elseif peekValue ~= nil then
    if gameplay_rally and gameplay_rally.getDebugLogging() then
      log('E', logTag, string.format('processPacenoteQueue: unknown peek value: %s', tostring(peekValue)))
    end
  end
  profilerPopEvent("rallyManager:processPacenoteQueue")
end

function C:closestPacenoteToVehicle()
  local pacenotes = self.notebook:findNClosestPacenotes(self.vehicleTracker:pos(), 1)
  if pacenotes and pacenotes[1] then
    return pacenotes[1]
  else
    return nil
  end
end

function C:getNextPacenotes()
  if not self.drivelineRoute then return {} end
  return { self.drivelineRoute:getNextPacenote() }
end

function C:enqueueRandomSystemPacenote(name, audioLenOffset)
  local pacenote, metadata = self.notebook:getRandomSystemPacenote(name)
  if pacenote and self.audioManager and metadata then
    -- Extract the actual audioLen from the metadata table using the audio filename
    local audioLen = nil
    if not pacenote.audioFname then
      log('E', logTag, string.format('enqueueRandomSystemPacenote: no audioFname for system pacenote %s', name))
      return
    end

    -- Extract basename from path (e.g., "/path/to/file.ogg" -> "file.ogg")
    local basename = pacenote.audioFname:match("([^/\\]+)$")
    if not basename then
      log('E', logTag, string.format('enqueueRandomSystemPacenote: could not extract basename from %s', pacenote.audioFname))
      return
    end

    local metadataVal = metadata[basename]
    if not metadataVal then
      log('E', logTag, string.format('enqueueRandomSystemPacenote: no metadata entry found for %s', basename))
      return
    end

    -- log('D', logTag, string.format('enqueueRandomSystemPacenote: %s - raw audioLen value: %s (type: %s)', basename, tostring(metadataVal.audioLen), type(metadataVal.audioLen)))

    audioLen = tonumber(metadataVal.audioLen)
    if not audioLen then
      log('E', logTag, string.format('enqueueRandomSystemPacenote: invalid audioLen for %s: %s (type: %s)', basename, tostring(metadataVal.audioLen), type(metadataVal.audioLen)))
      return
    end
    audioLen = audioLen + (audioLenOffset or 0)

    -- log('D', logTag, string.format('enqueueRandomSystemPacenote: %s - converted audioLen: %f', basename, audioLen))

    self.audioManager:enqueueSystemPacenote(pacenote, nil, audioLen)
  else
    log('E', logTag, "enqueueRandomSystemPacenote: couldnt find system pacenote with name '"..name.."'")
  end
end

function C:enqueuePauseSecs(secs)
  if not self.audioManager then return end
  self.audioManager:enqueuePauseSecs(secs)
end

function C:sendPacenoteToAudioManager(pacenote)
  if not self.audioManager then return false end
  self.audioManager:enqueuePacenoteAudio(pacenote)
  return true
end

function C:playFirstPacenote()
  if not self.audioManager then
    log('W', logTag, 'playFirstPacenote: no audioManager')
    return
  end

  local pacenote = self.notebook.pacenotes.sorted[1]
  if not pacenote then
    log('W', logTag, 'playFirstPacenote: no first pacenote found')
    return
  end

  if self:sendPacenoteToAudioManager(pacenote) then
    self:setLastPlayedPacenote(pacenote)
  end
end

function C:getDrivelineRoute()
  return self.drivelineRoute
end

function C:setLastPlayedPacenote(pacenote)
  if not pacenote then return end

  self.lastPlayedPacenote = pacenote
  self.lastPlayedPacenoteName = pacenote.name
  self.lastPlayedPacenoteIdx = nil

  local pacenotes = self.notebook and self.notebook.pacenotes and self.notebook.pacenotes.sorted
  if pacenotes then
    for i, notebookPacenote in ipairs(pacenotes) do
      if notebookPacenote == pacenote then
        self.lastPlayedPacenoteIdx = i
        break
      end
    end
  end
end

function C:getLastPlayedPacenote()
  local pacenotes = self.notebook and self.notebook.pacenotes and self.notebook.pacenotes.sorted
  if pacenotes and self.lastPlayedPacenoteIdx then
    return pacenotes[self.lastPlayedPacenoteIdx]
  end
  return self.lastPlayedPacenote
end

function C:getLastPlayedPacenoteRecoveryPose(distanceBefore)
  if not self.drivelineRoute then
    return nil, nil, 'no driveline route'
  end

  local pacenote = self:getLastPlayedPacenote()
  if not pacenote then
    return nil, nil, 'no last-played pacenote'
  end

  local pos, rot, fwd = self.drivelineRoute:vehiclePlacementPosAndRotForPacenote(pacenote, distanceBefore)
  if not pos or not rot then
    return nil, nil, 'failed to calculate recovery pose'
  end

  return pos, rot, nil, pacenote, fwd
end

function C:recoverVehicleToLastPlayedPacenote(veh, options)
  options = options or {}
  veh = veh or getPlayerVehicle(0)
  if not veh then
    return false, 'no vehicle'
  end

  local pos, rot, reason, pacenote = self:getLastPlayedPacenoteRecoveryPose(options.distanceBefore or 10)
  if not pos or not rot then
    log('W', logTag, 'recoverVehicleToLastPlayedPacenote failed: '..tostring(reason))
    return false, reason
  end

  spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, options.resetVehicle, nil, options.unlimitedSafeSpawnRange)
  if not self:resyncAfterTeleport() then
    log('E', logTag, 'recoverVehicleToLastPlayedPacenote failed: resyncAfterTeleport failed')
  end
  extensions.hook('onVehicleTeleportedToLastRoad', veh:getID())
  return true, nil, pacenote
end

function C:getRouteDepartureRecoveryPose(options)
  options = options or {}
  if not self.drivelineRoute then
    return nil, nil, 'no driveline route'
  end

  local pos, rot, reason, fwd, distToTarget = self.drivelineRoute:vehiclePlacementPosAndRotForRecovery(
    options.backoffDistance,
    options.tangentLookAhead
  )
  if not pos or not rot then
    return nil, nil, reason or 'failed to calculate route recovery pose'
  end

  return pos, rot, nil, {
    fwd = fwd,
    distToTarget = distToTarget,
    trackerState = self.drivelineRoute:getStaticTrackerState(),
  }
end

function C:recoverVehicleToRouteDeparture(veh, options)
  options = options or {}
  veh = veh or getPlayerVehicle(0)
  if not veh then
    return false, 'no vehicle'
  end

  local pos, rot, reason, recoveryData = self:getRouteDepartureRecoveryPose(options)
  if not pos or not rot then
    log('W', logTag, 'recoverVehicleToRouteDeparture failed: '..tostring(reason))
    return false, reason
  end

  local repairVehicle = options.repairVehicle
  if repairVehicle == nil then
    repairVehicle = options.resetVehicle
  end
  if repairVehicle == nil then
    if gameplay_rally and gameplay_rally.getRecoveryRepairVehicle then
      repairVehicle = gameplay_rally.getRecoveryRepairVehicle()
    else
      repairVehicle = true
    end
  end

  spawn.safeTeleport(veh, pos, rot, nil, nil, nil, true, repairVehicle, nil, options.unlimitedSafeSpawnRange)
  if not self:resyncAfterTeleport() then
    log('E', logTag, 'recoverVehicleToRouteDeparture failed: resyncAfterTeleport failed')
  end
  extensions.hook('onVehicleTeleportedToLastRoad', veh:getID())
  extensions.hook('onRallyRouteRecoveryComplete', {
    vehId = veh:getID(),
    repairVehicle = repairVehicle,
    recoveryData = recoveryData,
  })
  return true, nil, recoveryData
end

function C:getRecoveryDestinationPos()
  local pos = self:getRouteDepartureRecoveryPose()
  if pos then
    return pos
  end
  if self.drivelineRoute then
    return self.drivelineRoute:getAheadRoutePointPos()
  end
  return nil
end

function C:resetAudioQueue()
  if not self.audioManager then return end
  self.audioManager:resetQueue()
end

function C:getSpeedLimitKph()
  if not self.drivelineV3 then
    return nil
  end
  return self.drivelineV3:getSpeedLimitKph()
end

function C:getLiaisonAllocatedTimeSecs()
  if not self.drivelineV3 then
    return nil
  end
  return self.drivelineV3:getLiaisonAllocatedTimeSecs()
end

function C:hasAnyPacenotes()
  if not self.notebook then return false end
  return self.notebook:hasAnyPacenotes()
end

function C:getStartAndFinishStartPositions()
  if not self.racePath then return nil end

  local startSP = self.racePath:findStartPositionByName("SS_start_line") or self.racePath:findStartPositionByName("TC_in")
  -- Race distance is measured to the flying finish (last race pathnode), not the
  -- stop control (TC_out): the flying-finish -> stop-control run-down is immaterial.
  local finishSP = self.racePath:getLastPathnode()

  if not startSP or not finishSP then
    log('E', logTag, "no start or finish start position found in raceDistance calculation")
    return nil
  end

  return startSP, finishSP
end

function C:getRaceDistanceMeters()
  if not self.racePath then return nil end
  if not self.drivelineV3 then return nil end
  local startSP, finishSP = self:getStartAndFinishStartPositions()
  if not startSP or not finishSP then return nil end

  return self.drivelineV3:calculateDistanceBetweenPoints(startSP.pos, finishSP.pos)
end

-- returns a table with the following fields:
-- distM: distance in meters
-- distPct: percentage of the race completed from 0 to 1
function C:getRaceCompletionData()
  local dr = self:getDrivelineRoute()
  return dr:getRaceCompletionData()
end

function C:setStageRuntimeAuthorityMode(mode)
  self.stageRuntimeAuthorityMode = mode == 'tracker' and 'tracker' or 'shadow'
  if self.stageObserver then
    self.stageObserver:setAuthorityMode(self.stageRuntimeAuthorityMode)
  end
end

function C:getStageRuntimeAuthorityMode()
  return self.stageRuntimeAuthorityMode or 'shadow'
end

function C:getStageObserverState()
  return self.stageObserver and self.stageObserver:getState() or nil
end

function C:setStageRuntimeActive(active)
  if self.stageTimingState then
    self.stageTimingState:setActive(active == true and not self.trackerStageComplete)
  end
end

function C:getStageRuntimeTime()
  if self.trackerStageFinishTime then return self.trackerStageFinishTime end
  return self.stageTimingState and self.stageTimingState:getTime() or 0
end

function C:getStageTimingState()
  return self.stageTimingState and self.stageTimingState:getState() or nil
end

function C:addRecoveryRaceTime(recoveryType)
  -- Single stages are always a special stage.
  local seconds = RecoveryClockAdvance.getSpecialStageSeconds(recoveryType)
  if seconds <= 0 or not self.stageTimingState then
    return false
  end

  local added = self.stageTimingState:addTime(seconds)
  if added then
    log('I', logTag, string.format('added recovery race time type=%s seconds=%s', tostring(recoveryType), tostring(seconds)))
  end
  return added
end

function C:sampleRaceStageTime(vehId)
  if (self.stageTimingState and self.stageTimingState:isActive()) or self.trackerStageComplete then
    return self:getStageRuntimeTime()
  end
  if not self.raceData then return nil end
  local state = vehId and self.raceData.states and self.raceData.states[vehId] or nil
  if state and state.complete and state.historicTimes and state.historicTimes[#state.historicTimes] then
    return state.historicTimes[#state.historicTimes].endTime
  end
  return self.raceData.time
end

function C:getTrackerStageTime()
  if self.stageObserver then
    local observerTime = self.stageObserver:getStageTime()
    if observerTime then return observerTime end
  end
  if self.trackerStageFinishTime then return self.trackerStageFinishTime end
  if self.stageTimingState and self.stageTimingState:isActive() then return self:getStageRuntimeTime() end
  if self.raceData then return self.raceData.time end
  return nil
end

function C:updateTrackerSplitObservations()
  local dr = self:getDrivelineRoute()
  local tracker = dr and dr.getStaticTrackerState and dr:getStaticTrackerState()
  local vehId = self.vehicleTracker and self.vehicleTracker:getVehicleId()
  local splitList = self:getSplitDataList()
  local pathnodeObservationList = self:getPathnodeObservationList()
  local stageTime = self:sampleRaceStageTime(vehId)

  if self.stageObserver then
    self.stageObserver:update({
      drivelineRoute = dr,
      tracker = tracker,
      pathnodeObservationList = pathnodeObservationList,
      splitList = splitList,
      vehId = vehId,
      raceData = self.raceData,
      stageTime = stageTime,
      stageFrameStartTime = self.stageTimingState and self.stageTimingState:getFrameStartTime() or nil,
      stageFrameDt = self.stageTimingState and self.stageTimingState:getFrameDt() or 0,
      stageTimingState = self.stageTimingState,
    })
    self.trackerPreviousDistFromStart = self.stageObserver.previousDistFromStart
    self.trackerStageComplete = self.stageObserver.stageComplete == true
    self.trackerStageFinishTime = self.stageObserver.stageFinishTime
    if self.trackerStageComplete and self.trackerStageFinishTime and self.stageTimingState and not self.stageTimingState:isComplete() then
      self.stageTimingState:completeAt(self.trackerStageFinishTime)
    end
  end
end

local stageData = {
  completion = {},
}

function C:getActiveStageData()
  if not self.vehicleTracker then return nil end

  local vehId = self.vehicleTracker:getVehicleId()

  local observerState = self:getStageObserverState()
  local authorityMode = self:getStageRuntimeAuthorityMode()
  local useTrackerAuthority = authorityMode == 'tracker'
  local splitList = self:getSplitDataList()

  stageData.currentSSTime = 0
  stageData.isActive = false
  stageData.isComplete = self.trackerStageComplete == true
  if observerState then
    stageData.isComplete = observerState.stageComplete == true
  end
  stageData.splits = splitList
  stageData.authorityMode = authorityMode
  stageData.source = useTrackerAuthority and 'tracker' or 'race'
  local completion = self:getRaceCompletionData()
  -- stageData.completion.distM = completion.distM
  stageData.completion.distPct = clamp(completion.distPct or 0, 0, 1)
  -- stageData.completion.distKm = completion.distKm
  stageData.completion.totalDistM = completion.totalDistM

  if self.raceData and self.raceData.states and vehId and not useTrackerAuthority then
    local state = self.raceData.states[vehId]
    if state then
      local currentTime = nil

      if state.complete then
        currentTime = state.historicTimes[#state.historicTimes].endTime
      else
        currentTime = self.raceData.time
      end

      stageData.isActive = state.active
      stageData.isComplete = state.complete or self.trackerStageComplete == true

      if state.complete then
        stageData.completion.distPct = clamp(completion.distPct or 0, 0, 1)
      end

      -- Round to nearest tenth
      currentTime = math.floor(currentTime * 10 + 0.5) / 10

      stageData.currentSSTime = currentTime
    else
      log('E', logTag, 'getActiveStageData: no state for vehicle '..tostring(vehId))
    end
  end

  local trackerStageComplete = observerState and observerState.stageComplete or self.trackerStageComplete
  local trackerStageFinishTime = observerState and observerState.stageFinishTime or self.trackerStageFinishTime
  if useTrackerAuthority and observerState then
    local trackerRuntimeStarted = (self.stageTimingState and self.stageTimingState:isActive()) or observerState.raceActive == true or observerState.currentStageTime ~= nil
    stageData.isActive = trackerRuntimeStarted and observerState.stageComplete ~= true
    stageData.isComplete = observerState.stageComplete == true
  end

  -- user may drive over the line before start, so dont show it on the visual dashboard
  if not stageData.isActive then
    stageData.completion.distPct = stageData.isComplete and 1 or 0
  end

  if trackerStageComplete and trackerStageFinishTime then
    stageData.currentSSTime = math.floor(trackerStageFinishTime * 10 + 0.5) / 10
    stageData.completion.distPct = 1
  elseif useTrackerAuthority or not self.raceData then
    local trackerTime = self:getTrackerStageTime() or self:getStageRuntimeTime()
    stageData.currentSSTime = trackerTime and math.floor(trackerTime * 10 + 0.5) / 10 or 0
    if not self.raceData then
      stageData.source = 'trackerFallback'
    end
  end

  return stageData
end

function C:recordSplit(pathnodeId, time)
  local splitIdx = self:getSplitDataIndex()
  if not splitIdx then return end
  local splitData = splitIdx[pathnodeId]
  if not splitData then return end
  if self.stageObserver then
    self.stageObserver:recordRaceSplit(splitData, time)
  else
    splitData.time = splitData.time or time
    splitData.source = splitData.source or 'race'
  end
end

function C:clearSplitTimes()
  local splitList = self:getSplitDataList()
  local pathnodeObservationList = self:getPathnodeObservationList()

  for _, splitData in ipairs(pathnodeObservationList or splitList or {}) do
    splitData.time = nil
    splitData.source = nil
    splitData.trackerObserved = nil
    splitData.trackerObservedState = nil
    splitData.trackerCrossingMode = nil
    splitData.trackerCrossingT = nil
    splitData.trackerTime = nil
    splitData.trackerObservedUpdateSerial = nil
    splitData.trackerMissed = nil
    splitData.trackerMissedUpdateSerial = nil
    splitData.missingReason = nil
  end
  self:resetStageRuntime()
end

function C:getLoopPrefabPath()
  return self.missionDir .. '/loopPrefab.prefab.json'
end

return function(...)
  local o = {}
  setmetatable(o, C)
  C.__index = C
  o:init(...)
  return o
end
