-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}
-- declared, not reached for on demand: extensions.<name> loads a missing module, and that
-- load runs the onExtensionLoaded of everything still queued, trackers included. They would
-- then run before the config below is initialized.
M.dependencies = {'telemetry_configManager'}

local sessionId = nil

-- Event buffer for efficient storage
local eventBuffer = nil


local eventCount = 0
local totalEventCount = 0
local trackingExtensions = {}
local trackersReady = false
-- Every telemetry run the current config names. A session start event snapshots the whole
-- set, so any change to it has to start a new session.
local activeRunIds = nil
local sessionContinued = false

local reporterExtension = 'telemetry_reporters_jsonFileReporter'

-- A local only run keeps its sessions and survey state apart, so the reporter of a normal
-- run never uploads them and they never stand in for a survey that was really sent
local function getDataFolder()
  return extensions.telemetry_configManager.isLocalOnly() and "/telemetry/local/" or "/telemetry/"
end

local function getSessionFileForId(id)
  if not id then return nil end
  return getDataFolder() .. "sessions/" .. id .. ".jsonl"
end

-- The file of the running session. The reporter must not upload or delete this one.
local function getSessionFile()
  return getSessionFileForId(sessionId)
end

-- Identifies this run inside the report. Unrelated to the account session token, it is
-- a timestamp plus random bytes and carries no identity. Reported so a re-upload after
-- a lost response can be recognized as a duplicate instead of counted twice.
local function getSessionId()
  return sessionId
end

local function _writeEventsToFile()
  if eventCount == 0 then return end

  local sessionsFolder = getDataFolder() .. "sessions"
  if not FS:directoryExists(sessionsFolder) then
    FS:directoryCreate(sessionsFolder, true)
  end
  local filename = getSessionFile()

  local file = io.open(filename, "a")
  if file then
    file:write(tostring(eventBuffer))
    file:close()

    -- Reset buffer and count after writing
    eventBuffer:reset()  -- Reuse the existing buffer instead of creating a new one
    eventCount = 0
  else
    log('E', 'telemetry', "Failed to open file for writing: " .. filename)
  end
end

-- Answers whether the event was stored, so a caller that keeps its own record of what it
-- sent can tell a dropped event from a delivered one
local function addEvent(event)
  -- Return silently if telemetry is disabled (no buffer)
  if not eventBuffer then return false end

  -- Validate event parameter
  if not event or type(event) ~= "table" then
    log('E', 'telemetry', "addEvent: event parameter is required and must be a table" .. (event and " (got " .. type(event) .. ")" or ""))
    return false
  end

  -- Check for required name field
  if not event.name or type(event.name) ~= "string" or event.name == "" then
    log('E', 'telemetry', "addEvent: event.name is required and must be a non-empty string" .. (event.name and " (got " .. type(event.name) .. ")" or ""))
    return false
  end

  if event.t ~= nil then
    log('E', 'telemetry', "addEvent: event.t is used for the timestamp. Please do not use it")
  end

  event.t = os.clockhp()

  extensions.hook('onTelemetryEventAdded', event)

  --log('I', 'telemetry', dumpsz({'addEvent', event}, 2))

  -- Append to event buffer
  eventBuffer:put(jsonEncode(event))
  eventBuffer:put("\n")
  eventCount = eventCount + 1
  totalEventCount = totalEventCount + 1

  -- Auto-write every 100 events
  if eventCount >= 100 then
    _writeEventsToFile()
  end

  return true
end

-- Collects whatever the consent settings say and whatever the server config says, so a
-- tracker can be tested without a run that targets this client. -notelemetry still wins.
-- Temporary for non-shipping builds: drop the shipping_build case before release.
local function isTelemetryForced()
  if not shipping_build then return true end
  return tableFindKey(Engine.getStartingArgs(), '-telemetry') ~= nil
end

local function isPlatformSupported(platform)
  return platform ~= "ps5" and platform ~= "ps5pro"
end

-- Lifecycle functions
local function shouldTelemetryBeActive()
  if not isPlatformSupported(Engine.Platform.getPlatform()) then
    log('I', 'telemetry', "Telemetry disabled on PlayStation 5.")
    return false
  end

  if tableFindKey(Engine.getStartingArgs(), '-notelemetry') then
    log('I', 'telemetry', "Telemetry disabled due to -notelemetry argument.")
    return false
  end


  -- nothing leaves the machine, so agents can use it to check the trackers
  if extensions.telemetry_configManager.isLocalOnly() then
    log('I', 'telemetry', "Telemetry local only (-telemetryLocal), every tracker on, nothing is uploaded")
    return true
  end

  if Engine.isAgentMode and Engine.isAgentMode() then
    log('I', 'telemetry', "Telemetry disabled in AI agent mode.")
    return false
  end

  if isTelemetryForced() then
    log('I', 'telemetry', "Telemetry force enabled (non-shipping build or -telemetry argument)")
    return true
  end

  if not settings then return false end

  -- tech license holders are excluded from telemetry
  local techLicense = ResearchVerifier ~= nil and ResearchVerifier.isTechLicenseVerified() or false
  if techLicense then return false end

  -- 'ask' means the consent dialog has not been answered yet, so stay off
  local onlineFeatures = settings.getValue('onlineFeatures', 'disable')
  local telemetryEnabled = settings.getValue('telemetry', 'disable')
  return onlineFeatures == 'enable' and telemetryEnabled == 'enable'
end

-- Priority mapping (lower numbers load first / last on unload)
local trackerPriorities = {
  session = 1,      -- Must be first - manages session lifecycle
}

-- Load tracking extensions with priority ordering (sessions must be first)
local function loadTrackingExtensions()
  -- Auto-discover trackers from trackers subfolder
  local trackerFiles = FS:findFiles('lua/ge/extensions/telemetry/trackers/', '*.lua', 1, true, false)
  local trackersToLoad = {}

  for _, filePath in ipairs(trackerFiles) do
    -- Get relative path from trackers folder and convert to extension name format
    local relativePath = string.gsub(filePath, 'lua/ge/extensions/telemetry/trackers/', '')
    relativePath = string.gsub(relativePath, '^/', '') -- remove leading slash
    local nameWithoutExt = string.gsub(relativePath, '%.lua$', '')
    local trackerName = string.gsub(nameWithoutExt, '/', '_')

    local priority = trackerPriorities[trackerName] or 500 -- Default priority for unknown trackers
    table.insert(trackersToLoad, {name = trackerName, priority = priority})
  end

  -- Sort by priority (lower numbers first - session=1 loads first)
  table.sort(trackersToLoad, function(a, b) return a.priority < b.priority end)

  -- Load in priority order
  for _, tracker in ipairs(trackersToLoad) do
    local extName = 'telemetry_trackers_' .. tracker.name
    local loaded = trackingExtensions[tracker.name]
      or extensions.isExtensionLoaded(extName)
    -- Every tracker is opt-in. A missing or malformed module config stays off.
    if not extensions.telemetry_configManager.isModuleEnabled(tracker.name) then
      log('I', 'telemetry', "Tracker disabled by config: " .. tracker.name)
      if loaded then extensions.unload(extName) end
      trackingExtensions[tracker.name] = nil
    elseif not loaded then
      -- telemetry is diagnostics and loads from settings.finalizeInit, inside
      -- updateFirstFrame. A tracker that throws must not take the remaining trackers, nor
      -- the rest of the first frame, down with it.
      local ok, err = pcall(extensions.load, extName)
      if not ok then
        log('E', 'telemetry', "Tracker failed to load: " .. tracker.name .. " - " .. tostring(err))
      end
    end
    -- do not index extensions[extName] here, that would reload a tracker that refused to load
    if extensions.isExtensionLoaded(extName) then
      trackingExtensions[tracker.name] = true
    end
  end
end

local function unloadTrackingExtensions()
  -- Collect loaded trackers with priorities
  local trackersToUnload = {}
  for trackerName, _ in pairs(trackingExtensions) do
    local priority = trackerPriorities[trackerName] or 500
    table.insert(trackersToUnload, {name = trackerName, priority = priority})
  end

  -- Sort by priority in reverse order (higher numbers first - session=1 unloads last)
  table.sort(trackersToUnload, function(a, b) return a.priority > b.priority end)

  -- Unload in reverse priority order
  for _, tracker in ipairs(trackersToUnload) do
    local extName = 'telemetry_trackers_' .. tracker.name
    extensions.unload(extName)
    trackingExtensions[tracker.name] = nil
  end
end

local disableTelemetry

-- The server returns the runs in a stable order, so comparing them in order is enough
local function sameRunIds(previous, current)
  if #previous ~= #current then return false end
  for i = 1, #previous do
    if previous[i] ~= current[i] then return false end
  end
  return true
end

local function validSessionId(value)
  return type(value) == "string"
    and #value == 85
    and string.match(value, "^%d%d%d%d%-%d%d%-%d%dT%d%d%-%d%d%-%d%dZ_%x+$") ~= nil
end

local function canContinueSession(previousSession, runIds)
  if luaVmStartReason ~= "reload"
      or type(previousSession) ~= "table"
      or not validSessionId(previousSession.sessionId)
      or type(previousSession.runIds) ~= "table"
      or type(runIds) ~= "table"
      or not sameRunIds(previousSession.runIds, runIds) then
    return false
  end
  return FS:fileExists(getSessionFileForId(previousSession.sessionId))
end

local function finishPreviousSession(previousSession)
  if type(previousSession) ~= "table" or not validSessionId(previousSession.sessionId) then return end

  local filename = getSessionFileForId(previousSession.sessionId)
  if not FS:fileExists(filename) then return end

  local now = os.clockhp()
  local file = io.open(filename, "a")
  if not file then
    log('E', 'telemetry', "Failed to finish telemetry session after reload: " .. filename)
    return
  end
  file:write(jsonEncode({
    name = "session",
    type = "end",
    t = now,
    duration = now,
    endTime = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }))
  file:write("\n")
  file:close()
end

-- Enable telemetry functionality
local function enableTelemetry(previousSession)
  log('I', 'telemetry', "Enabling telemetry")

  -- the trackers write their surveys here before the first event is flushed
  local surveysFolder = getDataFolder() .. "surveys"
  if not FS:directoryExists(surveysFolder) then
    FS:directoryCreate(surveysFolder, true)
  end

  -- Initialize event buffer
  eventBuffer = require('string.buffer').new()
  eventCount = 0
  sessionContinued = false
  -- local clock, the login has not happened yet at this point
  sessionId = os.date("!%Y-%m-%dT%H-%M-%SZ") .. "_" .. hashStringSHA256(SecureComm.getRandomBytesHexSlow(256))

  -- Initialize config manager first. The config can arrive later, from the server.
  extensions.telemetry_configManager.initializeConfig(function(config)
    if config.enabled == false and not isTelemetryForced() then
      finishPreviousSession(previousSession)
      previousSession = nil
      if eventBuffer then
        log('I', 'telemetry', "Telemetry disabled by remote configuration")
        disableTelemetry()
      end
      activeRunIds = nil
      return
    end

    if previousSession then
      if canContinueSession(previousSession, config.runIds) then
        sessionId = previousSession.sessionId
        sessionContinued = true
        log('I', 'telemetry', "Continuing telemetry session after Lua reload")
      else
        finishPreviousSession(previousSession)
      end
      previousSession = nil
    elseif eventBuffer and activeRunIds and not sameRunIds(activeRunIds, config.runIds) then
      -- The session opened before this config arrived. If it collected for no run at
      -- all it is the stub every game start makes while waiting for the server, a few
      -- seconds long and belonging to no project, so it is thrown away rather than
      -- uploaded: reported, it counts as a game start in every per-session figure.
      -- A change between two real run sets keeps both, because both collected for
      -- something.
      local discardStub = #activeRunIds == 0
      log('I', 'telemetry', "Telemetry runs changed, starting a new telemetry session")
      disableTelemetry(discardStub)
      enableTelemetry()
      return
    end

    activeRunIds = config.runIds
    if trackersReady and eventBuffer then
      loadTrackingExtensions()
    end
    if not eventBuffer and shouldTelemetryBeActive() then
      enableTelemetry()
    end
  end)

  -- a cached config can switch telemetry off again while we are still setting up
  if not eventBuffer then return end

  -- The reporter uploads the session files written by previous runs
  if not extensions.telemetry_configManager.isLocalOnly() then
    extensions.load(reporterExtension)
  end

  if sessionContinued then
    addEvent({name = "luaReload"})
  end

  -- Load tracking extensions
  log('I', 'telemetry', "Loading tracking extensions...")
  trackersReady = true
  loadTrackingExtensions()
end

-- Disable telemetry functionality (switch to no-op mode)
-- discardSession throws the session away instead of reporting it. Its events are
-- dropped and the file is removed, because part of it may already be on disk.
disableTelemetry = function(discardSession)
  log('I', 'telemetry', "Disabling telemetry - switching to no-op mode")
  activeRunIds = nil
  trackersReady = false

  -- Unload tracking extensions
  unloadTrackingExtensions()

  local sessionFile = getSessionFile()

  -- Write any remaining events
  if eventBuffer and not discardSession then
    _writeEventsToFile()
  end

  if discardSession and sessionFile and FS:fileExists(sessionFile) then
    log('I', 'telemetry', "Discarding the telemetry session collected before the config")
    FS:removeFile(sessionFile)
  end

  if extensions.isExtensionLoaded(reporterExtension) then
    extensions.unload(reporterExtension)
  end

  -- Clean up buffer - this makes addEvent a no-op
  eventBuffer = nil
  eventCount = 0
  sessionContinued = false
end

local function onExtensionLoaded(previousSession)
  -- Always stay loaded to prevent errors, but operate as no-op when disabled
  setExtensionUnloadMode(M, "manual")

  -- Check if telemetry should be active based on settings
  if shouldTelemetryBeActive() then
    enableTelemetry(previousSession)
  else
    finishPreviousSession(previousSession)
    log('I', 'telemetry', "Telemetry disabled via settings - operating in no-op mode")
    -- Keep eventBuffer nil to make addEvent a no-op
    eventBuffer = nil
    extensions.telemetry_configManager.setPollingEnabled(false)
  end

  return true -- Stay loaded
end

local function onSettingsChanged()
  local shouldBeActive = shouldTelemetryBeActive()

  if shouldBeActive and not eventBuffer then
    -- Telemetry was disabled, now enabling
    enableTelemetry()
  elseif not shouldBeActive and eventBuffer then
    -- Telemetry was enabled, now disabling
    disableTelemetry()
  end
  if not shouldBeActive then
    extensions.telemetry_configManager.setPollingEnabled(false)
  end
end

local function onExtensionUnloaded()
  if eventBuffer then
    disableTelemetry()
  end
  extensions.telemetry_configManager.setPollingEnabled(false)
end

local function onSerialize(reason)
  if reason ~= "reload" or not eventBuffer or not validSessionId(sessionId) then return end
  return {
    sessionId = sessionId,
    runIds = activeRunIds,
  }
end

-- Seconds since the game started, used by trackers to measure durations
local function getRunTime()
  return os.clockhp()
end

-- The telemetry runs this session collects for. Set before any tracker loads.
local function getRunIds()
  return activeRunIds
end

local function isSessionContinued()
  return sessionContinued
end

-- Flush buffered events to disk, so they survive a crash from this point on
local function triggerReportWrite()
  if eventBuffer then
    _writeEventsToFile()
  end
end

-- Duration tracking
local function startActivity(activityName, data)
  local event = {name = activityName, type = "start"}
  tableMerge(event, data or {})
  addEvent(event)
end

local function endActivity(activityName, data)
  local event = {name = activityName, type = "end"}
  tableMerge(event, data or {})
  addEvent(event)
end

-- Public API
M.addEvent = addEvent
M.getRunTime = getRunTime
M.getRunIds = getRunIds
M.isSessionContinued = isSessionContinued
M.triggerReportWrite = triggerReportWrite
M.getSessionFile = getSessionFile
M.getSessionId = getSessionId
M.getDataFolder = getDataFolder
M.isPlatformSupported = isPlatformSupported

-- duration API
M.startActivity = startActivity
M.endActivity = endActivity

-- callbacks
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSerialize = onSerialize
M.onSettingsChanged = onSettingsChanged
M.onExit = onExtensionUnloaded

return M