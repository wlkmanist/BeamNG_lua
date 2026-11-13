-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

--[[
  JSON FILE REPORTER

  Uploads the session files that telemetry_core writes to /telemetry/sessions/*.jsonl.

  Runs once per game start, a few seconds after loading, and only uploads when the
  oldest pending session ended more than reportIntervalHours ago, as the server config
  sets it. This batches several sessions into one request instead of one per game start.

  The file of the running session is skipped, because core still appends to it.

  On success the uploaded files are removed. On failure they stay so the next game
  start retries them, but the oldest are dropped once too many pile up.
]]

local M = {}
M.dependencies = {'telemetry_core', 'telemetry_configManager'}

local logTag = 'telemetry_reporter'

-- Only used until the server config arrives
local defaultReportIntervalHours = 12

-- Keeps the directory bounded if uploads keep failing
local maxPendingFiles = 20

local uploadStartDelaySeconds = 5

-- The server sets how long a finished session is held. Waiting between that and twice
-- it keeps clients from all reporting at the same moment.
local function getReportIntervalSeconds()
  local config = extensions.telemetry_configManager.getConfig()
  local hours = config and config.reportIntervalHours or defaultReportIntervalHours
  local seconds = hours * 3600
  return seconds + math.random() * seconds
end

local function getPendingFiles()
  local currentFile = extensions.telemetry_core.getSessionFile()
  local pending = {}
  for _, filename in ipairs(FS:findFiles('/telemetry/sessions/', '*.jsonl', 0, true, false)) do
    if filename ~= currentFile then
      table.insert(pending, filename)
    end
  end
  table.sort(pending)
  return pending
end

local function readSession(filename)
  local content = readFile(filename)
  if not content then return nil end

  local events = {}
  for line in content:gmatch('[^\n]+') do
    local event = jsonDecode(line)
    if event then
      table.insert(events, event)
    end
  end

  if #events == 0 then return nil end
  return events
end

local function trimPendingFiles(files)
  local excess = #files - maxPendingFiles
  if excess <= 0 then return end

  log('W', logTag, "Dropping " .. excess .. " old telemetry sessions, uploads keep failing")
  for i = 1, excess do
    FS:removeFile(files[i])
  end
end

local function onUploadFinished(response, uploadedFiles)
  if response and response.result == 'ok' then
    log('I', logTag, "Telemetry uploaded, removing " .. #uploadedFiles .. " session files")
    for _, filename in ipairs(uploadedFiles) do
      FS:removeFile(filename)
    end
  else
    log('E', logTag, "Telemetry upload failed, keeping the files for the next game start")
    trimPendingFiles(uploadedFiles)
  end
end

local function uploadJob(job)
  job.sleep(uploadStartDelaySeconds)

  local files = getPendingFiles()
  if #files == 0 then return end

  -- modtime of a finished session is when it was last written, so effectively when it
  -- ended. It is unix time from the local clock, so compare it against the local clock,
  -- not against the server corrected time.
  local oldest = nil
  for _, filename in ipairs(files) do
    local stat = FS:stat(filename)
    local modtime = stat and stat.modtime
    if modtime and (not oldest or modtime < oldest) then
      oldest = modtime
    end
  end

  if oldest and os.time() < oldest + getReportIntervalSeconds() then
    return
  end

  local sessions = {}
  local sent = {}
  for _, filename in ipairs(files) do
    local events = readSession(filename)
    if events then
      table.insert(sessions, events)
      table.insert(sent, filename)
    else
      -- empty or unreadable, nothing worth keeping
      FS:removeFile(filename)
    end
    job.yield()
  end

  if #sessions == 0 then return end

  log('I', logTag, "Uploading " .. #sessions .. " telemetry sessions")

  core_online.apiCall('s11/v2/telemetryReports', function(r) onUploadFinished(r.responseData, sent) end, {
    userID = extensions.telemetry_userIdentity.getAnonymousUserID(),
    version = extensions.telemetry_configManager.getTelemetryVersion(),
    report = sessions
  })
end

local function onExtensionLoaded()
  setExtensionUnloadMode(M, "manual")
  extensions.core_jobsystem.create(uploadJob, 0.5)
end

M.onExtensionLoaded = onExtensionLoaded

return M
