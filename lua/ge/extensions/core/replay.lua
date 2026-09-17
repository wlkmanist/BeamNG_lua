-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max

local M = { state = {} }
M.state.speed = 1 -- playback speed indicator
local speeds = {1/1000, 1/500, 1/200, 1/100, 1/50, 1/32, 1/16, 1/8, 1/4, 1/2, 3/4, 1.0, 1.5, 2, 4, 8}
local missionReplayRecording = false
local missionReplaysPath = "replays/missionReplays/"
local userSavedMissionReplays = "replays/userSavedMissionReplays/"
local replayRootPath = "replays/"
local replayCatalogUpdatedEvent = "replayRecordingsUpdated"
local missingReplayMetadataFields = {"map", "vehicle", "date"}
local replayMetadataScanChunkSize = 64 * 1024
local replayMetadataScanLimit = 1024 * 1024
local replayMetadataScanOverlap = 512
local replayMetadataCache = {}
local replayDebugEnabled = false
local replayDebugStateTicksRemaining = 0
local pendingReplayInitialPause
local debugLog
local getReplayDebugSnapshot
local getFileStream
local loadFile

local function setDebugEnabled(enabled)
  replayDebugEnabled = enabled == true
  log("I", "core_replay.debug", "Replay debug logging " .. (replayDebugEnabled and "enabled" or "disabled"))
end

local function logUiAction(scope, data)
  debugLog("ui." .. tostring(scope), data)
end

local function getDebugEnabled()
  return replayDebugEnabled
end

function debugLog(scope, data)
  if not replayDebugEnabled then return end
  log("I", "core_replay.debug", tostring(scope) .. ": " .. dumps(data))
end

local function trimString(value)
  if type(value) ~= "string" then return "" end
  return string.gsub(string.gsub(value, "^%s+", ""), "%s+$", "")
end

local function hasPathTraversal(filename)
  return filename == ".." or string.find(filename, "^%.%./") ~= nil or string.find(filename, "/%.%./") ~= nil or string.find(filename, "/%.%.$") ~= nil
end

local invalidReplayBasenameChars = {"<", ">", ":", "\"", "/", "\\", "|", "?", "*"}

local function hasInvalidReplayBasenameChars(filename)
  for _, char in ipairs(invalidReplayBasenameChars) do
    if string.find(filename, char, 1, true) ~= nil then return true end
  end
  return false
end

local function hasInvalidReplayPathSegment(filename)
  for segment in string.gmatch(filename, "[^/]+") do
    if segment == "." or segment == ".." or hasInvalidReplayBasenameChars(segment) then return true end
  end
  return false
end

local function normalizeReplayFilename(filename, addExtension)
  if type(filename) ~= "string" then
    return nil, "Replay filename must be a string"
  end

  local normalized = trimString(filename)
  normalized = string.gsub(normalized, "\\", "/")
  normalized = string.gsub(normalized, "^/+", "")

  if normalized == "" then
    return nil, "Replay filename is empty"
  end
  if string.find(normalized, ":", 1, true) ~= nil then
    return nil, "Replay filename must be game-relative"
  end
  if string.find(normalized, "//", 1, true) ~= nil or hasPathTraversal(normalized) then
    return nil, "Replay filename cannot contain path traversal"
  end
  if string.sub(normalized, 1, string.len(replayRootPath)) ~= replayRootPath then
    return nil, "Replay filename must be under replays/"
  end
  if addExtension and string.sub(string.lower(normalized), -4) ~= ".rpl" then
    normalized = normalized .. ".rpl"
  end
  if string.sub(string.lower(normalized), -4) ~= ".rpl" then
    return nil, "Replay filename must end with .rpl"
  end
  if hasInvalidReplayPathSegment(normalized) then
    return nil, "Replay filename contains invalid characters"
  end

  return normalized
end

local function getPathDir(filename)
  return string.match(filename, "^(.*[/])") or ""
end

local function getPathBasename(filename)
  return string.match(filename, "([^/]+)$") or filename
end

local function stripReplayExtension(filename)
  if string.sub(string.lower(filename), -4) == ".rpl" then
    return string.sub(filename, 1, -5)
  end
  return filename
end

local function getReplaySortTime(filename)
  local fileStats = FS:stat(filename)
  if not fileStats then return 0 end
  return fileStats.createtime or fileStats.modtime or fileStats.filetime or 0
end

local function scanReplayLevelName(filename)
  local file = io.open(filename, "rb")
  if not file then return nil end

  local scannedBytes = 0
  local overlap = ""
  local levelName
  while scannedBytes < replayMetadataScanLimit do
    local chunk = file:read(min(replayMetadataScanChunkSize, replayMetadataScanLimit - scannedBytes))
    if not chunk or chunk == "" then break end
    scannedBytes = scannedBytes + #chunk

    local searchable = string.lower(string.gsub(overlap .. chunk, "\\", "/"))
    levelName = string.match(searchable, "/levels/([^/%z]+)/main%.level%.json")
    if levelName then break end
    overlap = string.sub(searchable, -replayMetadataScanOverlap)
  end
  file:close()
  return levelName
end

local function getReplayLevelName(filename, fileSize, sortTime)
  local signature = tostring(fileSize or 0) .. ":" .. tostring(sortTime or 0)
  local cached = replayMetadataCache[filename]
  if cached and cached.signature == signature then return cached.levelName end

  local levelName = scanReplayLevelName(filename)
  replayMetadataCache[filename] = {
    signature = signature,
    levelName = levelName or false,
  }
  return levelName
end

local function getCurrentLevelName()
  return type(getCurrentLevelIdentifier) == "function" and getCurrentLevelIdentifier() or nil
end

local function levelsMatch(first, second)
  return type(first) == "string"
    and first ~= ""
    and type(second) == "string"
    and second ~= ""
    and string.lower(first) == string.lower(second)
end

local function normalizeReplayRenameTarget(oldFilename, newFilename)
  local oldPath, oldErr = normalizeReplayFilename(oldFilename)
  if not oldPath then return nil, nil, oldErr end

  local newValue = trimString(newFilename)
  if newValue == "" then
    return nil, nil, "New replay filename is empty"
  end

  local targetPath
  if string.find(newValue, "/", 1, true) ~= nil or string.find(newValue, "\\", 1, true) ~= nil then
    targetPath = normalizeReplayFilename(newValue, true)
  else
    local basename = newValue
    if string.sub(string.lower(basename), -4) ~= ".rpl" then
      basename = basename .. ".rpl"
    end
    if basename == "." or basename == ".." or hasInvalidReplayBasenameChars(basename) then
      return nil, nil, "New replay filename contains invalid characters"
    end
    targetPath = normalizeReplayFilename(getPathDir(oldPath) .. basename)
  end

  if not targetPath then
    return nil, nil, "New replay filename must stay under replays/"
  end
  local targetBasename = getPathBasename(targetPath)
  if targetBasename == "." or targetBasename == ".." or hasInvalidReplayBasenameChars(targetBasename) then
    return nil, nil, "New replay filename contains invalid characters"
  end

  return oldPath, targetPath
end

local function replayOperationResult(success, filename, message, extra)
  local result = {
    success = success,
    filename = filename,
  }
  if message then result.message = message end
  if extra then
    for key, value in pairs(extra) do
      result[key] = value
    end
  end
  return result
end

function getReplayDebugSnapshot(extra)
  local state = core_gamestate and core_gamestate.state or {}
  local snapshot = {
    replayState = M.state.state,
    loadedFile = M.state.loadedFile,
    paused = M.state.paused,
    gameState = state and state.state or nil,
    menuItems = state and state.menuItems or nil,
    missionFilename = type(getMissionFilename) == "function" and getMissionFilename() or nil,
    worldReadyState = worldReadyState,
    loading = core_gamestate and core_gamestate.loading and core_gamestate.loading() or nil,
    loadingLevels = core_gamestate and core_gamestate.getLoadingStatus and core_gamestate.getLoadingStatus("levels") or nil,
    loadingWorldReady = core_gamestate and core_gamestate.getLoadingStatus and core_gamestate.getLoadingStatus("worldReadyState") or nil,
    loadingFreeroam = core_gamestate and core_gamestate.getLoadingStatus and core_gamestate.getLoadingStatus("freeroam") or nil,
    modManagerReady = core_modmanager and core_modmanager.isReady and core_modmanager.isReady() or nil,
    enterableObjectCount = be and be.getEnterableObjectCount and be:getEnterableObjectCount() or nil,
  }
  if extra then
    for key, value in pairs(extra) do
      snapshot[key] = value
    end
  end
  return snapshot
end

function getFileStream()
  if not be then return end
  return be:getFileStream()
end


local function onInit()
  local stream = getFileStream()
  if stream then
    stream:requestState()
  end
end

local function getRecordings()
  local result = {}
  local currentLevel = getCurrentLevelName()
  for i,file in ipairs(FS:findFiles('replays', '*.rpl', 1, false, false)) do
    file = string.gsub(file, "/(.*)", "%1") -- strip leading /
    local normalizedFile = normalizeReplayFilename(file)
    if normalizedFile then
      local basename = getPathBasename(normalizedFile)
      local sortTime = getReplaySortTime(normalizedFile)
      local fileSize = FS:fileSize(normalizedFile)
      local map = getReplayLevelName(normalizedFile, fileSize, sortTime)
      local missingMetadataFields = map and {"vehicle", "date"} or missingReplayMetadataFields
      table.insert(result, {
        filename = normalizedFile,
        path = normalizedFile,
        key = normalizedFile,
        basename = basename,
        displayName = stripReplayExtension(basename),
        size = fileSize,
        sortTime = sortTime,
        map = map or nil,
        levelName = map or nil,
        metadataAvailable = map ~= nil and map ~= false,
        missingMetadataFields = missingMetadataFields,
      })
    end
  end
  table.sort(result, function(a, b)
    local aMatchesCurrentLevel = levelsMatch(a.levelName, currentLevel)
    local bMatchesCurrentLevel = levelsMatch(b.levelName, currentLevel)
    if aMatchesCurrentLevel ~= bMatchesCurrentLevel then return aMatchesCurrentLevel end
    if a.sortTime ~= b.sortTime then return a.sortTime > b.sortTime end
    return a.filename > b.filename
  end)
  return result
end

local function getPlaybackContext(filename)
  local replayFilename, err = normalizeReplayFilename(filename)
  if not replayFilename then
    return replayOperationResult(false, filename, err, {code = "invalidFilename"})
  end
  if not FS:fileExists(replayFilename) then
    return replayOperationResult(false, replayFilename, "Replay file does not exist", {code = "fileNotFound"})
  end

  local fileSize = FS:fileSize(replayFilename)
  local sortTime = getReplaySortTime(replayFilename)
  local recordedLevel = getReplayLevelName(replayFilename, fileSize, sortTime)
  local currentLevel = getCurrentLevelName()
  local levelKnown = type(recordedLevel) == "string" and recordedLevel ~= ""
  local hasCurrentLevel = type(currentLevel) == "string" and currentLevel ~= ""
  local requiresLevelLoad = hasCurrentLevel
    and (not levelKnown or not levelsMatch(recordedLevel, currentLevel))

  return replayOperationResult(true, replayFilename, nil, {
    code = "ok",
    recordedLevel = recordedLevel or nil,
    currentLevel = currentLevel,
    levelKnown = levelKnown,
    requiresLevelLoad = requiresLevelLoad,
  })
end

local function notifyReplayRecordingsUpdated()
  guihooks.trigger(replayCatalogUpdatedEvent, getRecordings())
end

local function getEnterableObjectCount()
  return be and be.getEnterableObjectCount and be:getEnterableObjectCount() or 0
end

local function startPendingReplayInitialPause(filename, source)
  pendingReplayInitialPause = {
    filename = filename,
    source = source,
  }
  debugLog("pendingReplayInitialPause.start", getReplayDebugSnapshot(pendingReplayInitialPause))
end

local function finishPendingReplayInitialPause(trigger)
  local pending = pendingReplayInitialPause
  if not pending then return end
  if pending.filename ~= M.state.loadedFile then
    debugLog("pendingReplayInitialPause.waitFileMismatch", getReplayDebugSnapshot({
      pending = pending,
      trigger = trigger,
    }))
    return
  end
  if M.state.state ~= "playback" or M.state.paused == true then return end
  if worldReadyState ~= 2 or getEnterableObjectCount() <= 0 then return end

  local stream = getFileStream()
  if not stream then return end

  pendingReplayInitialPause = nil
  debugLog("pendingReplayInitialPause.finish.begin", getReplayDebugSnapshot({
    pending = pending,
    trigger = trigger,
  }))
  stream:seek(0)
  stream:setPaused(true)
  debugLog("pendingReplayInitialPause.finish.afterPause", getReplayDebugSnapshot({
    pending = pending,
    trigger = trigger,
  }))
end

local function stateChanged(loadedFile, positionSeconds, totalSeconds, speed, paused, fpsPlay, fpsRec, statestr, framePositionSeconds)
  local prevState = M.state.state
  local prevPaused = M.state.paused
  local prevLoadedFile = M.state.loadedFile

  if prevState ~= statestr then
    if statestr == 'playback' then -- we are in playback now
      local o = scenetree.findObject("VehicleCommonActionMap")
      if o then o:setEnabled(false) end
      o = scenetree.findObject("VehicleSpecificActionMap")
      if o then o:setEnabled(false) end
      o = scenetree.findObject("ReplayPlaybackActionMap")
      if o then o:push() end
    else -- we are not in playback now (start of game, just exited playback, etc)
      local o = scenetree.findObject("ReplayPlaybackActionMap")
      if o then o:pop() end
      o = scenetree.findObject("VehicleSpecificActionMap")
      if o then o:setEnabled(true) end
      o = scenetree.findObject("VehicleCommonActionMap")
      if o then o:setEnabled(true) end
    end
  end
  -- speed: we lose some precission on the way to C++ and back, round it a bit
  M.state = {loadedFile = loadedFile, positionSeconds = positionSeconds, totalSeconds = totalSeconds, speed = round(speed*1000)/1000, paused = paused, fpsPlay = fpsPlay, fpsRec = fpsRec, state = statestr, framePositionSeconds = framePositionSeconds}
  if replayDebugEnabled and (
    prevState ~= statestr
    or prevPaused ~= paused
    or prevLoadedFile ~= loadedFile
    or replayDebugStateTicksRemaining > 0
  ) then
    debugLog("stateChanged", getReplayDebugSnapshot({
      loadedFileArg = loadedFile,
      positionSeconds = positionSeconds,
      framePositionSeconds = framePositionSeconds,
      totalSeconds = totalSeconds,
      speed = speed,
      pausedArg = paused,
      fpsPlay = fpsPlay,
      fpsRec = fpsRec,
      stateArg = statestr,
      prevState = prevState,
      prevPaused = prevPaused,
      prevLoadedFile = prevLoadedFile,
      debugTicksRemaining = replayDebugStateTicksRemaining,
    }))
    if replayDebugStateTicksRemaining > 0 then
      replayDebugStateTicksRemaining = replayDebugStateTicksRemaining - 1
    end
  end
  guihooks.trigger('replayStateChanged', M.state)
  extensions.hook("onReplayStateChanged", M.state)

  -- Low-frequency replay lifecycle hook: emits only on "core" changes (no seeks/position updates).
  if prevState ~= statestr then
    if prevState == 'playback' then
      extensions.hook("onReplayCoreEvent", {event = 'playbackStopped', state = M.state, prevState = prevState})
    elseif prevState == 'recording' then
      extensions.hook("onReplayCoreEvent", {event = 'recordingStopped', state = M.state, prevState = prevState})
    end
    if statestr == 'playback' then
      extensions.hook("onReplayCoreEvent", {event = 'playbackStarted', state = M.state, prevState = prevState})
    elseif statestr == 'recording' then
      extensions.hook("onReplayCoreEvent", {event = 'recordingStarted', state = M.state, prevState = prevState})
    end
  end
  if prevPaused ~= paused and statestr == 'playback' then
    extensions.hook("onReplayCoreEvent", {event = paused and 'playbackPaused' or 'playbackResumed', state = M.state, prevPaused = prevPaused})
  end
  if prevLoadedFile ~= loadedFile then
    extensions.hook("onReplayCoreEvent", {event = 'loadedFileChanged', state = M.state, prevLoadedFile = prevLoadedFile})
  end
  finishPendingReplayInitialPause("stateChanged")
end

local function publishUnloadedReplayState()
  stateChanged("", 0, 0, M.state.speed or 1, true, 0, 0, "inactive", 0)
end

local function getPositionSeconds()
  return M.state.positionSeconds
end

local function getTotalSeconds()
  return M.state.totalSeconds
end

local function getState()
  return M.state.state
end

local function isGameplayAllowed()
  --log('I', '', "Replay needs to decide if gameplay is allowed")
  if M.state.state ~= 'playback' then
    return true
  end
  -- TODO: this should be a playback option
  return true
end

local function isPaused()
  return M.state.paused
end

local function getLoadedFile()
  return M.state.loadedFile
end

local function setSpeed(speed)
  local stream = getFileStream()
  if not stream then return end
  if M.state.speed ~= speed then
    stream:setSpeed(speed)
  end
end

local togglingSpeed = 1/8
local function toggleSpeed(val)
  local newSpeed = M.state.speed
  if val == "realtime" then
    if M.state.speed == 1 then
      newSpeed = togglingSpeed
    else
      togglingSpeed = M.state.speed
      newSpeed = 1
    end
  elseif val == "slowmotion" then
    newSpeed = 1/8
  else
    local speedId = -1
    for i,speed in ipairs(speeds) do
      if speed == M.state.speed then
        speedId = i
        break
      end
    end
    if speedId == -1 and val < 0 then
      for i=#speeds,1,-1 do
        if speeds[i] <= M.state.speed then
          speedId = i
          break
        end
      end
    end
    if speedId == -1 and val > 0 then
      for i,speed in ipairs(speeds) do
        if speed >= M.state.speed then
          speedId = i
          break
        end
      end
    end
    speedId = min(#speeds, max(1, speedId+val))
    newSpeed = speeds[speedId]
  end
  setSpeed(newSpeed)
  simTimeAuthority.reportSpeed(newSpeed)
end

local function pause(v)
  local stream = getFileStream()
  if not stream then return end

  if M.state.state ~= 'playback' then return end
  stream:setPaused(v)
end

local function displayMsg(level, msg, context)
  -- level is a toastr category name ("error", "info", "warning"...)
  guihooks.trigger("toastrMsg", {type=level, title="Replay "..level, msg=msg, context=context})
  log(string.gsub(level, "^(.).*", string.upper), "", "Replay msg: "..dumps(level, msg, context))
end

local function togglePlay()
  if not M.state.loadedFile or M.state.loadedFile == "" then
    debugLog("togglePlay.emptyLoadedFile", getReplayDebugSnapshot())
    return
  end
  local stream = getFileStream()
  if not stream then
    debugLog("togglePlay.noStream", getReplayDebugSnapshot())
    return
  end

  debugLog("togglePlay.begin", getReplayDebugSnapshot())

  if M.state.state == 'inactive' then
    loadFile(M.state.loadedFile, true)
  elseif M.state.state == 'playback' then
    stream:setPaused(not M.state.paused)
  else
    log("E","",'Will not toggle play from state: '..dumps(M.state.state))
  end
end

local function playReplayStream(filename, autoplay, source, options)
  local stream = getFileStream()
  if not stream then
    debugLog("playReplayStream.noStream", getReplayDebugSnapshot({filename = filename, autoplay = autoplay, source = source}))
    return replayOperationResult(false, filename, "Replay stream is not available", {code = "streamUnavailable"})
  end
  local pauseWhenReady = type(options) == "table" and options.pauseWhenReady == true
  local requestedPaused = autoplay ~= true
  debugLog("playReplayStream.begin", getReplayDebugSnapshot({filename = filename, autoplay = autoplay, source = source, pauseWhenReady = pauseWhenReady, requestedPaused = requestedPaused}))
  stream:setPaused(requestedPaused)
  debugLog("playReplayStream.afterSetPaused", getReplayDebugSnapshot({filename = filename, autoplay = autoplay, source = source, pauseWhenReady = pauseWhenReady, requestedPaused = requestedPaused}))
  replayDebugStateTicksRemaining = replayDebugEnabled and 10 or 0
  local ret = stream:play(filename)
  debugLog("playReplayStream.streamPlay", getReplayDebugSnapshot({filename = filename, autoplay = autoplay, source = source, pauseWhenReady = pauseWhenReady, ret = ret}))
  if ret ~= 0 then
    displayMsg("error", "replay.playError", {filename=filename})
    return replayOperationResult(false, filename, "Replay stream failed to play", {code = "streamPlayFailed", ret = ret})
  end
  if requestedPaused then
    stream:setPaused(true)
    debugLog("playReplayStream.afterPlaySetPaused", getReplayDebugSnapshot({filename = filename, autoplay = autoplay, source = source, pauseWhenReady = pauseWhenReady, requestedPaused = requestedPaused}))
  end
  if pauseWhenReady then
    startPendingReplayInitialPause(filename, source)
  end
  return replayOperationResult(true, filename, nil, {code = "ok", ret = ret})
end

function loadFile(filename, autoplay, options)
  local stream = getFileStream()
  if not stream then
    debugLog("loadFile.noStream", getReplayDebugSnapshot({filename = filename, autoplay = autoplay}))
    return replayOperationResult(false, filename, "Replay stream is not available", {code = "streamUnavailable"})
  end
  local replayFilename, normalizeErr = normalizeReplayFilename(filename)
  if not replayFilename then
    debugLog("loadFile.invalidFilename", getReplayDebugSnapshot({filename = filename, autoplay = autoplay, error = normalizeErr}))
    displayMsg("error", "replay.playError", {filename=filename})
    return replayOperationResult(false, filename, normalizeErr, {code = "invalidFilename"})
  end

  log("D","", "Loading: "..replayFilename)
  debugLog("loadFile.begin", getReplayDebugSnapshot({filename = replayFilename, autoplay = autoplay, options = options}))

  pendingReplayInitialPause = nil
  stream:stop()
  debugLog("loadFile.afterStop", getReplayDebugSnapshot({filename = replayFilename, autoplay = autoplay, options = options}))

  return playReplayStream(replayFilename, autoplay, "loadFile", options)
end

local function stop()
  local stream = getFileStream()
  if not stream then return end

  pendingReplayInitialPause = nil
  log("D","", 'Stopping from state: '..M.state.state);
  stream:stop()
end

local function stopAndUnload()
  if M.state.state == 'recording' then
    return replayOperationResult(false, M.state.loadedFile, "Cannot unload replay while recording is active", {code = "recordingActive"})
  end

  local stream = getFileStream()
  if not stream then
    return replayOperationResult(false, M.state.loadedFile, "Replay stream is not available", {code = "streamUnavailable"})
  end

  pendingReplayInitialPause = nil
  stream:stop()
  publishUnloadedReplayState()
  return replayOperationResult(true, "", nil, {code = "ok"})
end

local function cancelRecording()
  local stream = getFileStream()
  if not stream then return end

  log("D","",'Cancelling recording from state: '..M.state.state)
  if M.state.state == 'recording' then
    ui_message("replay.cancelRecording", 5, "replay", "local_movies")
    local file = M.state.loadedFile
    stream:stop()
    FS:removeFile(file)
    publishUnloadedReplayState()
  end
end

local function getNewReplayRecordingFilename(isMissionReplay)
  local date = os.date("%Y-%m-%d_%H-%M-%S")
  local map = core_levels.getLevelName(getMissionFilename())

  if map == nil then
    log("E", "", "Cannot start recording replay. Map filename: "..dumps(getMissionFilename()))
    return nil, "Cannot start replay recording without a level name"
  end

  local dir = isMissionReplay and missionReplaysPath or replayRootPath
  return dir..date.." "..map..".rpl"
end

local function startReplayRecording(stream, isMissionReplay)
  if not stream then
    return replayOperationResult(false, nil, "Replay stream is not available", {code = "streamUnavailable"})
  end
  if not isMissionReplay and missionReplayRecording then
    ui_message("replay.cantManualRecording", 5, "replay", "local_movies")
    return replayOperationResult(false, M.state.loadedFile, "Mission replay recording is active", {code = "recordingActive"})
  end

  local filename, err = getNewReplayRecordingFilename(isMissionReplay)
  if not filename then
    return replayOperationResult(false, nil, err, {code = "recordStartFailed"})
  end

  if isMissionReplay then missionReplayRecording = true end
  log("D","",'record to: '..filename)
  ui_message(isMissionReplay and "replay.startRecordingAutoReplay" or "replay.startRecording", isMissionReplay and 5 or -1, "replay", "local_movies")
  stream:record(filename)
  return replayOperationResult(true, filename, nil, {code = "ok"})
end

local function stopReplayRecording(stream, autoplayAfterStopping, isMissionReplay, notifyCatalog)
  if not stream then
    return replayOperationResult(false, M.state.loadedFile, "Replay stream is not available", {code = "streamUnavailable"})
  end
  if M.state.state ~= 'recording' then
    return replayOperationResult(false, M.state.loadedFile, "Replay recording is not active", {code = "notRecording"})
  end
  if not isMissionReplay and missionReplayRecording then
    ui_message("replay.cantManualRecording", 5, "replay", "local_movies")
    return replayOperationResult(false, M.state.loadedFile, "Mission replay recording is active", {code = "recordingActive"})
  end

  local filename = M.state.loadedFile
  local playbackResult
  if isMissionReplay then missionReplayRecording = false end
  if autoplayAfterStopping then
    ui_message(isMissionReplay and "stopAutoReplayRecordingAutoplay" or "replay.stopRecordingAutoplay", 5, "replay", "local_movies")
    playbackResult = loadFile(filename)
  else
    ui_message(isMissionReplay and "stopAutoReplayRecording" or "replay.stopRecording", 5, "replay", "local_movies")
    stream:stop()
  end
  if notifyCatalog then notifyReplayRecordingsUpdated() end

  return replayOperationResult(true, filename, nil, {code = "ok", playbackResult = playbackResult})
end

local function startRecording()
  if M.state.state == 'recording' then
    return replayOperationResult(false, M.state.loadedFile, "Replay recording is already active", {code = "recordingActive"})
  end
  if M.state.state == 'playback' then
    return replayOperationResult(false, M.state.loadedFile, "Cannot start replay recording during playback", {code = "playbackActive"})
  end

  local stream = getFileStream()
  if not stream then
    return replayOperationResult(false, nil, "Replay stream is not available", {code = "streamUnavailable"})
  end

  return startReplayRecording(stream, false)
end

local function stopRecording(options)
  if M.state.state ~= 'recording' then
    return replayOperationResult(false, M.state.loadedFile, "Replay recording is not active", {code = "notRecording"})
  end
  if missionReplayRecording then
    ui_message("replay.cantManualRecording", 5, "replay", "local_movies")
    return replayOperationResult(false, M.state.loadedFile, "Mission replay recording is active", {code = "recordingActive"})
  end

  local stream = getFileStream()
  if not stream then
    return replayOperationResult(false, M.state.loadedFile, "Replay stream is not available", {code = "streamUnavailable"})
  end

  local autoplayAfterStopping = type(options) == "table" and options.autoplayAfterStopping == true
  return stopReplayRecording(stream, autoplayAfterStopping, false, true)
end

local function toggleRecording(autoplayAfterStopping, isMissionReplay)
  isMissionReplay = isMissionReplay or false

  local stream = getFileStream()
  if not stream then return end
  log("D","",'Toggle recording from state: '..M.state.state)

  if M.state.state == 'recording' then
    if not isMissionReplay and missionReplayRecording then
      ui_message("replay.cantManualRecording", 5, "replay", "local_movies")
      return
    end
    local loadAfterStopping = autoplayAfterStopping == true or (autoplayAfterStopping == nil and not isMissionReplay)
    stopReplayRecording(stream, loadAfterStopping, isMissionReplay, not isMissionReplay)
  elseif M.state.state == 'playback' then
    stop()
  else
    local result = startReplayRecording(stream, isMissionReplay)
    if result.success then return result.filename end
  end
end

local function toggleMissionRecording()
  return toggleRecording(false, true)
end

local function seek(percent)
  local stream = getFileStream()
  if not stream then return end

  if M.state.state ~= 'playback' then return end
  stream:seek(max(0, min(1, percent)))
end

local function jumpFrames(offset)
  local stream = getFileStream()
  if not stream then return end
  stream:stepFrames(offset)
  ui_message({txt="replay.jumpFrames", context={frameCount=offset}}, 2, "replay", "local_movies")
end

local function jumpTime(timeDiffInSeconds)
  local stream = getFileStream()
  if not stream then return end
  stream:stepTime(timeDiffInSeconds)
  ui_message({txt="replay.jump", context={seconds=timeDiffInSeconds}}, 2, "replay", "local_movies")
end

local function openReplayFolderInExplorer()
  if not fileExistsOrNil('/replays/') then  -- create dir if it doesnt exist
    FS:directoryCreate("/replays/", true)
  end
  Engine.Platform.exploreFolder("/replays/")
end

local function onClientEndMission(levelPath)
  debugLog("onClientEndMission", getReplayDebugSnapshot({levelPath = levelPath, requestedStartLevel = M.requestedStartLevel}))
  if M.state.state == 'playback' and not M.requestedStartLevel then
    log("I", "", string.format("Stopping replay playback. Reason: level changed from \"%s\" to \"%s\"", getLoadedFile(), levelPath))
    displayMsg("info", "replay.stopPlayback")
    stop()
  end
  M.requestedStartLevel = nil
end

local function startLevel(levelPath)
  M.requestedStartLevel = true
  local levelName = core_levels.getLevelName(levelPath)
  debugLog("startLevel.begin", getReplayDebugSnapshot({levelPath = levelPath, levelName = levelName}))
  local spawnVehicle = false  -- don't spawn a vehicle by default
  freeroam_freeroam.startFreeroamByName(levelName, nil, nil, spawnVehicle)  -- don't spawn a vehicle by default
  debugLog("startLevel.afterStartFreeroamByName", getReplayDebugSnapshot({levelPath = levelPath, levelName = levelName}))
end

local function removeRecording(filename)
  local replayFilename, err = normalizeReplayFilename(filename)
  if not replayFilename then
    return replayOperationResult(false, filename, err)
  end
  if not FS:fileExists(replayFilename) then
    return replayOperationResult(false, replayFilename, "Replay file does not exist")
  end

  local loadedFilename = M.state.loadedFile and normalizeReplayFilename(M.state.loadedFile) or nil
  if loadedFilename == replayFilename then
    stop()
  end

  if FS:removeFile(replayFilename) ~= 0 then
    return replayOperationResult(false, replayFilename, "Failed to delete replay file")
  end

  local metaFilename = replayFilename .. ".rplMeta.json"
  if FS:fileExists(metaFilename) then
    FS:removeFile(metaFilename)
  end

  notifyReplayRecordingsUpdated()
  return replayOperationResult(true, replayFilename)
end

local function acceptRename(oldFilename, newFilename)
  local oldReplayFilename, newReplayFilename, err = normalizeReplayRenameTarget(oldFilename, newFilename)
  if not oldReplayFilename then
    return replayOperationResult(false, oldFilename, err)
  end
  if oldReplayFilename == newReplayFilename then
    return replayOperationResult(true, oldReplayFilename, "Replay filename unchanged", {newFilename = newReplayFilename})
  end
  if not FS:fileExists(oldReplayFilename) then
    return replayOperationResult(false, oldReplayFilename, "Replay file does not exist", {newFilename = newReplayFilename})
  end
  if FS:fileExists(newReplayFilename) then
    return replayOperationResult(false, oldReplayFilename, "Target replay file already exists", {newFilename = newReplayFilename})
  end

  local loadedFilename = M.state.loadedFile and normalizeReplayFilename(M.state.loadedFile) or nil
  local wasLoaded = loadedFilename == oldReplayFilename
  local stream = getFileStream()
  if wasLoaded and stream then
    stream:stop()
  end

  if FS:renameFile(oldReplayFilename, newReplayFilename) ~= 0 then
    return replayOperationResult(false, oldReplayFilename, "Failed to rename replay file", {newFilename = newReplayFilename})
  end
  if FS:fileExists(oldReplayFilename) then
    FS:removeFile(oldReplayFilename)
  end

  local oldMetaFilename = oldReplayFilename .. ".rplMeta.json"
  if FS:fileExists(oldMetaFilename) then
    local newMetaFilename = newReplayFilename .. ".rplMeta.json"
    if FS:fileExists(newMetaFilename) then
      FS:removeFile(newMetaFilename)
    end
    if FS:renameFile(oldMetaFilename, newMetaFilename) == 0 and FS:fileExists(oldMetaFilename) then
      FS:removeFile(oldMetaFilename)
    end
  end

  notifyReplayRecordingsUpdated()
  if wasLoaded then
    loadFile(newReplayFilename)
  end

  return replayOperationResult(true, oldReplayFilename, nil, {newFilename = newReplayFilename})
end

local function getCurrentUserSavedReplayFilesPath()
  local finalPath = userSavedMissionReplays

  -- save the replay in the proper folder
  if career_career and career_career.isActive() then
    local currentSaveSlot, _ = career_saveSystem.getCurrentProfile()
    finalPath = finalPath .. "career/" .. currentSaveSlot .. "/"
  else -- we are in freeroam
    finalPath = finalPath .. "freeroam/"
  end

  return finalPath
end

local function getMissionReplayFiles(mission, returnOnlyWithAttempt)
  local files = {}
  local filesWithUserSaved = {}

  if returnOnlyWithAttempt == nil then
    returnOnlyWithAttempt = false
  end

  -- add all the missions replays that have been automatically recorded
  for i, file in ipairs(FS:findFiles(M.getMissionReplaysPath(), '*.rpl', 0, false, false)) do
    table.insert(filesWithUserSaved, {file = file})
  end
  -- add all the user saved replays that correspong to the current environment. Ie freeroam or career, save slot
  for i, file in ipairs(FS:findFiles(getCurrentUserSavedReplayFilesPath(), '*.rpl', 0, false, false)) do
    table.insert(filesWithUserSaved, {file = file, userSaved = true})
  end

  local currentSaveSlot, _ = career_saveSystem.getCurrentProfile()
  local isCurrentlyInCareer = career_career and career_career.isActive()

  local ret = {}
  for _, file in ipairs(filesWithUserSaved) do
    local dir, fn, ext = path.split(file.file)
    local metaFileName = dir .. fn .. ".rplMeta.json"
    local meta = jsonReadFile(metaFileName)
    if meta and meta.missionId == mission.id and ((returnOnlyWithAttempt and meta.attempt) or not returnOnlyWithAttempt) and ((isCurrentlyInCareer and meta.context.saveSlot == currentSaveSlot) or not isCurrentlyInCareer) then
      table.insert(ret, {
        replayFile = file.file,
        replayFileName = fn,
        meta = meta,
        userSaved = file.userSaved
      })
    end
  end


  table.sort(ret, function(a,b) return a.meta.time < b.meta.time end)
  return ret
end

local function saveMissionReplay(replayFileName)
  local finalPath = getCurrentUserSavedReplayFilesPath()

  if not FS:directoryExists(finalPath) then FS:directoryCreate(finalPath) end
  local dir, fn, ext = path.split(replayFileName)

  FS:copyFile(replayFileName, finalPath..fn)
  FS:copyFile(replayFileName..".rplMeta.json", finalPath..fn..".rplMeta.json")

  FS:removeFile(replayFileName)
  FS:removeFile(replayFileName..".rplMeta.json")

  local meta = jsonReadFile(finalPath..fn..".rplMeta.json")
  local recordingFiles = getMissionReplayFiles(gameplay_missions_missions.getMissionById(meta.missionId))
  guihooks.trigger("recordingFilesUpdated", recordingFiles)
end

local function removeMissionSavedReplay(replayFileName)
  local dir, fn, ext = path.split(replayFileName)

  if not FS:directoryExists(missionReplaysPath) then FS:directoryCreate(missionReplaysPath) end

  FS:copyFile(replayFileName, missionReplaysPath..fn)
  FS:copyFile(replayFileName..".rplMeta.json", missionReplaysPath..fn..".rplMeta.json")

  FS:removeFile(replayFileName)
  FS:removeFile(replayFileName..".rplMeta.json")

  local meta = jsonReadFile(missionReplaysPath..fn..".rplMeta.json")
  local recordingFiles = getMissionReplayFiles(gameplay_missions_missions.getMissionById(meta.missionId))
  guihooks.trigger("recordingFilesUpdated", recordingFiles)
end

local function openMissionReplayFolder(replayFileName)
  if not replayFileName or replayFileName == "" then return end
  if FS:fileExists(replayFileName) then
    Engine.Platform.exploreFolder(replayFileName)
  else
    log('E', '', 'Replay file path does not exist: '..tostring(replayFileName))
  end
end

-- called by c++
local function _getReplayVehicleData(id)
  --log('E', '', 'Getting vehicle data for id: '..tostring(id))
  local res = extensions.core_vehicle_manager.getVehicleData(id)
  return jsonEncode(res)
  -- this has to return a string
end

-- public interface
M.onInit = onInit
M.onClientEndMission = onClientEndMission
M.startLevel = startLevel
M.setDebugEnabled = setDebugEnabled
M.getDebugEnabled = getDebugEnabled
M.logUiAction = logUiAction

M.stateChanged = stateChanged
M.getRecordings = getRecordings
M.getPlaybackContext = getPlaybackContext
M.setSpeed = setSpeed -- 1=realtime, 0.5=slowmo, 2=fastmotion (the change will be instantaneous, without any smoothing)
M.toggleSpeed = toggleSpeed
M.togglePlay = togglePlay
M.toggleRecording = toggleRecording
M.startRecording = startRecording
M.stopRecording = stopRecording
M.cancelRecording = cancelRecording
M.loadFile = loadFile
M.stop = stop
M.stopAndUnload = stopAndUnload
M.pause = pause
M.seek = seek -- [0..1] normalized position to seek to
M.jumpTime = jumpTime
-- M.jump is replaced by M.jumpTime and M.jumpFrames
M.jump = jumpFrames
M.jumpFrames = jumpFrames
M.openReplayFolderInExplorer = openReplayFolderInExplorer
M.displayMsg = displayMsg
M.getPositionSeconds = getPositionSeconds
M.getTotalSeconds = getTotalSeconds
M.getState = getState
M.isGameplayAllowed = isGameplayAllowed
M.isPaused = isPaused
M.getLoadedFile = getLoadedFile
M.acceptRename = acceptRename
M.removeRecording = removeRecording
M._getReplayVehicleData = _getReplayVehicleData

-- Mission / Automatic replay (they're the same thing eh)
M.saveMissionReplay = saveMissionReplay
M.getMissionReplayFiles = getMissionReplayFiles
M.getMissionReplaysPath = function() return missionReplaysPath end
M.toggleMissionRecording = toggleMissionRecording
M.removeMissionSavedReplay = removeMissionSavedReplay
M.openMissionReplayFolder = openMissionReplayFolder
return M
