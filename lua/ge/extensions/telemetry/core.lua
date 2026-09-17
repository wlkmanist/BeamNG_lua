-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

-- enable this to get more detailed logs
local debugMode = false

local sessionId = nil

-- Event buffer for efficient storage
local eventBuffer = nil


local eventCount = 0
local totalEventCount = 0
local trackingExtensions = {}

local function _writeEventsToFile()
  if not FS:directoryExists("telemetry") then
    FS:directoryCreate("telemetry")
  end
  local filename = "/telemetry/" .. sessionId .. ".jsonl"

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

local function addEvent(event)
  -- Return silently if telemetry is disabled (no buffer)
  if not eventBuffer then return end

  -- Validate event parameter
  if not event or type(event) ~= "table" then
    log('E', 'telemetry', "addEvent: event parameter is required and must be a table" .. (event and " (got " .. type(event) .. ")" or ""))
    return
  end

  -- Check for required name field
  if not event.name or type(event.name) ~= "string" or event.name == "" then
    log('E', 'telemetry', "addEvent: event.name is required and must be a non-empty string" .. (event.name and " (got " .. type(event.name) .. ")" or ""))
    return
  end

  -- In debug mode, validate event name format
  if debugMode then
    -- Check if event.t is already set
    if event.t ~= nil then
      log('E', 'telemetry', "addEvent: event.t is used for the timestamp. Please do not use it")
    end

    -- Validate event name format: must start with lowercase and be camelCase
    local firstChar = event.name:sub(1, 1)
    if firstChar:upper() == firstChar then
      log('E', 'telemetry', "addEvent: event.name must start with a lowercase letter: '" .. event.name .. "'")
      return
    end

    -- Check for invalid characters (only allow letters and numbers)
    if event.name:match("[^%a%d]") then
      log('E', 'telemetry', "addEvent: event.name must be camelCase without spaces or special characters: '" .. event.name .. "'")
      return
    end
  end

  event.t = os.clockhp()

  extensions.hook('onTelemetryEventAdded', event)

  if debugMode then
    log('I', 'telemetry', dumpsz({'addEvent', event}, 2))
  end

  -- Append to event buffer
  eventBuffer:put(jsonEncode(event))
  eventBuffer:put("\n")
  eventCount = eventCount + 1
  totalEventCount = totalEventCount + 1

  -- Auto-write every 100 events
  if eventCount > 100 then
    _writeEventsToFile()
  end
end

-- Lifecycle functions
local function shouldTelemetryBeActive()
  local noTelemetry = tableFindKey(Engine.getStartingArgs(), '-notelemetry')
  if noTelemetry then
    log('I', '', "Telemetry disabled due to -notelemetry argument.")
    return false
  end
  if not shipping_build then
    log('I', '', "Telemetry is enabled in non-shipping builds for developers")
    return true
  else
    return false
  end

  -- Check settings requirements
  if not settings then return false end

  local techLicense = ResearchVerifier ~= nil and ResearchVerifier.isTechLicenseVerified() or false
  local onlineFeatures = settings.getValue('onlineFeatures', 'disable')
  local telemetryEnabled = settings.getValue('telemetry', 'disable')
  return not techLicense and onlineFeatures == 'enable' and telemetryEnabled == 'enable'
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
    extensions.load(extName)
    if extensions[extName] ~= nil then
      trackingExtensions[tracker.name] = extensions[extName]
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

-- Enable telemetry functionality
local function enableTelemetry()
  log('I', 'telemetry', "Enabling telemetry")

  -- Initialize event buffer
  eventBuffer = require('string.buffer').new()
  eventCount = 0
  sessionId = os.date("!%Y-%m-%dT%H-%M-%SZ") .. "_" .. hashStringSHA256(SecureComm.getRandomBytesHexSlow(256))

  -- Initialize config manager first
  extensions.telemetry_configManager.initializeConfig()

  -- Load tracking extensions
  log('I', 'telemetry', "Loading tracking extensions...")
  loadTrackingExtensions()
end

-- Disable telemetry functionality (switch to no-op mode)
local function disableTelemetry()
  log('I', 'telemetry', "Disabling telemetry - switching to no-op mode")

  -- Unload tracking extensions
  unloadTrackingExtensions()

  -- Write any remaining events
  if eventBuffer then
    _writeEventsToFile()
  end

  -- Clean up buffer - this makes addEvent a no-op
  eventBuffer = nil
  eventCount = 0
end

local function onExtensionLoaded()
  -- Always stay loaded to prevent errors, but operate as no-op when disabled
  setExtensionUnloadMode(M, "manual")

  -- Check if telemetry should be active based on settings
  if shouldTelemetryBeActive() then
    enableTelemetry()
  else
    log('I', 'telemetry', "Telemetry disabled via settings - operating in no-op mode")
    -- Keep eventBuffer nil to make addEvent a no-op
    eventBuffer = nil
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
end

local function onExtensionUnloaded()
  if eventBuffer then
    disableTelemetry()
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
-- Test API
M.saveTelemetryData = function()
  -- Write any remaining events
  if eventBuffer then
    _writeEventsToFile()
  end

  -- Clean up buffer - this makes addEvent a no-op
  eventBuffer = nil
  eventCount = 0
end

-- Public API
M.addEvent = addEvent

-- duration API
M.startActivity = startActivity
M.endActivity = endActivity

-- callbacks
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onSettingsChanged = onSettingsChanged
M.onExit = onExtensionUnloaded

return M