-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local min = math.min
local max = math.max

local M = { state = {} }
M.state.speed = 1 -- playback speed indicator
local speeds = {1/1000, 1/500, 1/200, 1/100, 1/50, 1/32, 1/16, 1/8, 1/4, 1/2, 3/4, 1.0, 1.5, 2, 4, 8}
local autoReplayRunning = false
local autoReplayPath = "replays/autoReplay/"

local function getFileStream()
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
  for i,file in ipairs(FS:findFiles('replays', '*.rpl', 1, false, false)) do
    file = string.gsub(file, "/(.*)", "%1") -- strip leading /
    table.insert(result, {filename=file, size=FS:fileSize(file)})
  end
  return result
end

local function stateChanged(loadedFile, positionSeconds, totalSeconds, speed, paused, fpsPlay, fpsRec, statestr, framePositionSeconds)
  if M.state.state ~= statestr then
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
  guihooks.trigger('replayStateChanged', M.state)
  extensions.hook("onReplayStateChanged", M.state)
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
    return
  end
  local stream = getFileStream()
  if not stream then return end

  if M.state.state == 'inactive' then
    stream:setPaused(false)
    local ret = stream:play(M.state.loadedFile)
    if ret ~= 0 then displayMsg("error", "replay.playError", {filename=M.state.loadedFile}) end
  elseif M.state.state == 'playback' then
    stream:setPaused(not M.state.paused)
  else
    log("E","",'Will not toggle play from state: '..dumps(M.state.state))
  end
end

local function loadFile(filename)
  local stream = getFileStream()
  if not stream then return end
  log("D","", "Loading: "..filename)

  stream:stop()
  stream:setPaused(true)
  local ret = stream:play(filename)
  if ret ~= 0 then displayMsg("error", "replay.playError", {filename=filename}) end
end

local function stop()
  local stream = getFileStream()
  if not stream then return end

  log("D","", 'Stopping from state: '..M.state.state);
  stream:stop()
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
  end
end

local function toggleRecording(autoplayAfterStopping, isAutoReplay)
  isAutoReplay = isAutoReplay or false

  local stream = getFileStream()
  if not stream then return end
  log("D","",'Toggle recording from state: '..M.state.state)

  if M.state.state == 'recording' then
    if not isAutoReplay and autoReplayRunning then
      ui_message("replay.cantManualRecording", 5, "replay", "local_movies")
      return
    end
    if isAutoReplay then autoReplayRunning = false end
    if autoplayAfterStopping then
      ui_message(isAutoReplay and "stopAutoReplayRecordingAutoplay" or "replay.stopRecordingAutoplay", 5, "replay", "local_movies")
      loadFile(M.state.loadedFile)
    else
      ui_message(isAutoReplay and "stopAutoReplayRecording" or "replay.stopRecording", 5, "replay", "local_movies")
      stream:stop()
    end
  elseif M.state.state == 'playback' then
    stop()
  else
    if not isAutoReplay and autoReplayRunning then
      ui_message("replay.cantManualRecording", 5, "replay", "local_movies")
      return
    end

    local date = os.date("%Y-%m-%d_%H-%M-%S")

    local map = core_levels.getLevelName(getMissionFilename())

    if map == nil then
      log("E", "", "Cannot start recording replay. Map filename: "..dumps(getMissionFilename()))
    else
      if isAutoReplay then autoReplayRunning = true end
      local dir = isAutoReplay and autoReplayPath or "replays/"
      local filename = dir..date.." "..map..".rpl"
      log("D","",'record to: '..filename)
      ui_message(isAutoReplay and "replay.startRecordingAutoReplay" or "replay.startRecording", 5, "replay", "local_movies")
      stream:record(filename)
    end
  end
end

local function toggleAutomaticRecording()
  toggleRecording(false, true)
end

local function seek(percent)
  local stream = getFileStream()
  if not stream then return end

  if M.state.state ~= 'playback' then return end
  stream:seek(max(0, min(1, percent)))
end

local function jumpFrames(offset)
  --dump{'jumpFrames', offset}
  local stream = getFileStream()
  if not stream then return end
  stream:setPaused(true)
  stream:stepFrames(offset)
  ui_message({txt="replay.jumpFrames", context={frameCount=offset}}, 2, "replay", "local_movies")
end

local function jumpTime(timeDiffInSeconds)
  --dump{'jumpTime', timeDiffInSeconds}
  local stream = getFileStream()
  if not stream then return end
  stream:setPaused(true)
  stream:stepTime(timeDiffInSeconds)
  ui_message({txt="replay.jump", context={seconds=timeDiffInSeconds}}, 2, "replay", "local_movies")
end

local function openReplayFolderInExplorer()
  if not fileExistsOrNil('/replays/') then  -- create dir if it doesnt exist
    FS:directoryCreate("/replay/", true)
  end
  Engine.Platform.exploreFolder("/replays/")
end

local function onClientEndMission(levelPath)
  if M.state.state == 'playback' and not M.requestedStartLevel then
    log("I", "", string.format("Stopping replay playback. Reason: level changed from \"%s\" to \"%s\"", getLoadedFile(), levelPath))
    displayMsg("info", "replay.stopPlayback")
    stop()
  end
  M.requestedStartLevel = nil
end

-- TODO:
--local function onDrawDebug(lastDebugFocusPos, dtReal, dtSim, dtRaw)
  -- 1) get the current replay frame (current VehicleState)
  --    > getCurrentStateReplayNodeCount(vehId)
  --    > getCurrentStateReplayNodePosition(vehId, x)
  -- local vdata = extensions.core_vehicle_manager.getVehicleData(vid).vdata
  -- -> iterate through the nodes and beams and debug draw them
  -- 2) figure out the bdebug mode? beams? nodes?
  -- 3) custom draw the things
--end

local function startLevel(levelPath)
  M.requestedStartLevel = true
  core_levels.startLevel(levelPath, nil, nil, false) -- don't spawn a vehicle by default
end

-- public interface
M.onInit = onInit
M.onClientEndMission = onClientEndMission
M.startLevel = startLevel

M.stateChanged = stateChanged
M.getRecordings = getRecordings
M.setSpeed = setSpeed -- 1=realtime, 0.5=slowmo, 2=fastmotion (the change will be instantaneous, without any smoothing)
M.toggleSpeed = toggleSpeed
M.togglePlay = togglePlay
M.toggleRecording = toggleRecording
M.toggleAutomaticRecording = toggleAutomaticRecording
M.getAutoReplayPath = function() return autoReplayPath end
M.cancelRecording = cancelRecording
M.loadFile = loadFile
M.stop = stop
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
M.isPaused = isPaused
M.getLoadedFile = getLoadedFile
--M.onDrawDebug = onDrawDebug -- TODO

return M
