-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local screenshotPath = 'screenshots/'
local jobs = {}
local jobsList = {}
local currentRunId = 0
local uploadJobIds = {}
local jobMetadataById = {}
local jobSidecarEnabledById = {}
local pendingUploadSidecars = {}
local reservedScreenshotPaths = {}
local minimalScreenshotMetadata
local getOnlineProviderPlayerName
local debugTracingEnabled = false
local embedWriteApiMissingLogged = false
local embedReadApiMissingLogged = false
local ADVANCED_PHOTOMODE_CALL_ORIGIN = "ui_pause_photomode"
local PHOTOMODE_ROLL_ENTRY_LIMIT = 10
local PHOTOMODE_ROLL_METADATA_CACHE_LIMIT = 5
local PHOTOMODE_ROLL_METADATA_CACHE_MISS = {}
local photomodeRollMetadataCacheByPath = {}
local photomodeRollMetadataCacheKeys = {}

local function logTrace(message)
  if not debugTracingEnabled then
    return
  end
  log('I', 'screenshot', '[Trace] ' .. tostring(message))
end

local function describeEmbeddedMetadataState(metadata, openMap, shareUrl)
  local parts = {
    "hasMeta=" .. tostring(type(metadata) == 'table'),
    "hasOpenMap=" .. tostring(type(openMap) == 'table'),
    "hasShareUrl=" .. tostring(type(shareUrl) == 'string' and shareUrl ~= ''),
  }
  if type(metadata) == 'table' and type(metadata.level) == 'string' and metadata.level ~= '' then
    parts[#parts + 1] = "level=" .. tostring(metadata.level)
  end
  return table.concat(parts, " ")
end

local function extractScreenshotCallOptions(...)
  local argCount = select('#', ...)
  for i = argCount, 1, -1 do
    local value = select(i, ...)
    if type(value) == 'table' then
      return value
    end
  end
  return nil
end

local function isAdvancedPhotomodeScreenshot(options)
  return type(options) == 'table' and options.callOrigin == ADVANCED_PHOTOMODE_CALL_ORIGIN
end

local function shouldAttachScreenshotMetadata(options, uploadRequested)
  if uploadRequested == true then return true end
  if type(options) ~= 'table' then return false end
  return options.jsonMetaData == true or options.includeMetadata == true or isAdvancedPhotomodeScreenshot(options)
end

local function shouldPersistScreenshotMetadata(options)
  if type(options) ~= 'table' then return false end
  return options.persistMetadataSidecar == true or isAdvancedPhotomodeScreenshot(options)
end

local function normalizeArtifactCaptureFlags(splitSceneVehicle, saveNormalDepth)
  return splitSceneVehicle == true, saveNormalDepth == true
end

local function pushJobsToUI()
  if guihooks then
    guihooks.trigger("ScreenshotJobsUpdate", jobsList)
  end
end

local function pruneDoneJobs()
  local newList = {}
  for i = 1, #jobsList do
    local j = jobsList[i]
    if j and j.phase ~= 'done' then
      newList[#newList + 1] = j
    else
      if j and j.id then
        jobs[j.id] = nil
        jobSidecarEnabledById[j.id] = nil
      end
    end
  end
  jobsList = newList
end

local function startNewRun()
  currentRunId = currentRunId + 1
  logTrace("startNewRun runId=" .. tostring(currentRunId))
  pruneDoneJobs()
  pushJobsToUI()
end

local function createScreenshotTracked(p)
  local p2 = shallowcopy(p or {})
  local id = createScreenshot2(p2)
  if not id or id == 0 then return id end

  local j = jobs[id]
  if not j then
    j = {id = id, runId = currentRunId, percent = 0, message = '', phase = 'queue', result = nil}
    jobs[id] = j
    jobsList[#jobsList + 1] = j
  end
  j.filename = tostring(p2.filename or j.filename or '')
  j.bufferType = tostring(p2.bufferType or j.bufferType or '')
  j.type = tostring(p2.jobType or j.type or '')
  local metaTbl = nil
  if type(p2.jsonMetaData) == 'string' and p2.jsonMetaData ~= '' then
    metaTbl = jsonDecode(p2.jsonMetaData)
    metaTbl = minimalScreenshotMetadata(metaTbl)
  end
  if type(metaTbl) == 'table' then
    jobMetadataById[id] = metaTbl
  end
  if p2.persistMetadataSidecar == true then
    jobSidecarEnabledById[id] = true
  end
  if p2.upload == true then
    uploadJobIds[id] = true
  end

  logTrace(
    "job queued"
      .. " runId=" .. tostring(currentRunId)
      .. " id=" .. tostring(id)
      .. " type=" .. tostring(j.type or "")
      .. " bufferType=" .. tostring(j.bufferType or "")
      .. " filename=" .. tostring(j.filename or "")
  )
  pushJobsToUI()
  return id
end

local function getMetadataJson()
  local res = {
    versionb = beamng_versionb,
    versiond = beamng_versiond,
    windowtitle = beamng_windowtitle,
    buildtype = beamng_buildtype,
    buildinfo = beamng_buildinfo,
    arch = beamng_arch,
    buildnumber = beamng_buildnumber,
    shipping_build = shipping_build,
  }
  res.level = getMissionFilename()
  if extensions.core_gamestate.state.state then
    res.gameState = extensions.core_gamestate.state.state
  end

  local onlinePlayerName = getOnlineProviderPlayerName()
  if onlinePlayerName then
    res.playerName = onlinePlayerName
  end
  if OnlineServiceProvider and OnlineServiceProvider.isWorking and OnlineServiceProvider.accountID ~= "" then
    res.steamIDHash = tostring(hashStringSHA1(OnlineServiceProvider.accountID))
    res.steamPlayerName = onlinePlayerName or OnlineServiceProvider.playerName
  end

  local pos = core_camera.getPosition()
  local rot = core_camera.getQuat()
  res.fov = core_camera.getFovDeg()
  if pos.x ~= 0 or pos.y ~=0 or pos.z ~= 0 then
    res.cameraPos = {pos.x, pos.y, pos.z}
    res.cameraRot = {rot.x, rot.y, rot.z, rot.w}
  end

  res.os = Engine.Platform.getOSInfo()
  res.cpu = Engine.Platform.getCPUInfo()
  res.gpu = Engine.Platform.getGPUInfo()
  if res.gpu then
    res.gpu.vulkanEnabled = Engine.Render.getAdapterType() == "Vulkan"
  end
  if core_environment then
    res.tod = core_environment.getTimeOfDay()
  end
  extensions.hook('onCollectScreenshotMetadata', res)
  return jsonEncode(res)
end

local function normalizeSlashes(p)
  return tostring(p or ''):gsub('\\', '/')
end

local function removePhotomodeRollMetadataCacheKey(cacheKey)
  for i = #photomodeRollMetadataCacheKeys, 1, -1 do
    if photomodeRollMetadataCacheKeys[i] == cacheKey then
      table.remove(photomodeRollMetadataCacheKeys, i)
      return
    end
  end
end

local function clearPhotomodeRollMetadataCache(screenshotPath)
  if screenshotPath == nil then
    photomodeRollMetadataCacheByPath = {}
    photomodeRollMetadataCacheKeys = {}
    return
  end

  local cacheKey = normalizeSlashes(screenshotPath)
  if cacheKey == '' or photomodeRollMetadataCacheByPath[cacheKey] == nil then return end
  photomodeRollMetadataCacheByPath[cacheKey] = nil
  removePhotomodeRollMetadataCacheKey(cacheKey)
end

local function getCachedPhotomodeRollMetadata(screenshotPath)
  local cacheKey = normalizeSlashes(screenshotPath)
  if cacheKey == '' then return false, nil end

  local cached = photomodeRollMetadataCacheByPath[cacheKey]
  if cached == nil then return false, nil end

  removePhotomodeRollMetadataCacheKey(cacheKey)
  photomodeRollMetadataCacheKeys[#photomodeRollMetadataCacheKeys + 1] = cacheKey
  if cached == PHOTOMODE_ROLL_METADATA_CACHE_MISS then return true, nil end
  return true, cached
end

local function cachePhotomodeRollMetadata(screenshotPath, data)
  local cacheKey = normalizeSlashes(screenshotPath)
  if cacheKey == '' then return data end

  if photomodeRollMetadataCacheByPath[cacheKey] ~= nil then
    removePhotomodeRollMetadataCacheKey(cacheKey)
  elseif #photomodeRollMetadataCacheKeys >= PHOTOMODE_ROLL_METADATA_CACHE_LIMIT then
    local evictedKey = table.remove(photomodeRollMetadataCacheKeys, 1)
    if evictedKey then
      photomodeRollMetadataCacheByPath[evictedKey] = nil
    end
  end

  photomodeRollMetadataCacheByPath[cacheKey] = data or PHOTOMODE_ROLL_METADATA_CACHE_MISS
  photomodeRollMetadataCacheKeys[#photomodeRollMetadataCacheKeys + 1] = cacheKey
  return data
end

local function prunePhotomodeRollMetadataCache(candidates)
  local keepByPath = {}
  for i = 1, math.min(#candidates, PHOTOMODE_ROLL_METADATA_CACHE_LIMIT) do
    local cacheKey = normalizeSlashes(candidates[i].path)
    if cacheKey ~= '' then
      keepByPath[cacheKey] = true
    end
  end

  for i = #photomodeRollMetadataCacheKeys, 1, -1 do
    local cacheKey = photomodeRollMetadataCacheKeys[i]
    if not keepByPath[cacheKey] then
      photomodeRollMetadataCacheByPath[cacheKey] = nil
      table.remove(photomodeRollMetadataCacheKeys, i)
    end
  end
end

local function basenameFromPath(p)
  local s = normalizeSlashes(p)
  return s:match('[^/]+$') or s
end

local function getScreenshotMetadataSidecarPath(screenshotPath)
  local normalizedPath = normalizeSlashes(screenshotPath)
  if normalizedPath == '' then return '' end
  return normalizedPath .. '.metadata.json'
end

local function toNumberArray(src, expectedLen)
  if type(src) ~= 'table' then return nil end
  if expectedLen and #src < expectedLen then return nil end
  local out = {}
  for i = 1, #src do
    local n = tonumber(src[i])
    if not n then return nil end
    out[i] = n
  end
  return out
end

getOnlineProviderPlayerName = function()
  if settings and settings.getValue and settings.getValue('onlineFeatures') ~= 'enable' then return nil end
  if not OnlineServiceProvider or OnlineServiceProvider.isWorking ~= true then return nil end
  if OnlineServiceProvider.accountLoggedIn ~= true and tostring(OnlineServiceProvider.accountID or '') == '' then return nil end

  local playerName = tostring(OnlineServiceProvider.playerName or ''):gsub("^%s+", ""):gsub("%s+$", "")
  return playerName ~= '' and playerName or nil
end

minimalScreenshotMetadata = function(metadata)
  if type(metadata) ~= 'table' then return nil end
  local out = {}
  if type(metadata.level) == 'string' and metadata.level ~= '' then
    out.level = metadata.level
  end
  local playerName = type(metadata.playerName) == 'string' and metadata.playerName or metadata.steamPlayerName
  if type(playerName) == 'string' and playerName ~= '' then
    out.playerName = playerName
  end
  local tod = tonumber(metadata.timeOfDay)
  if not tod and type(metadata.tod) == 'table' then
    tod = tonumber(metadata.tod.time)
  end
  if tod then
    out.timeOfDay = tod
  end
  local fov = tonumber(metadata.fov)
  if fov and fov > 0 then
    out.fov = fov
  end
  local camPos = toNumberArray(metadata.cameraPos, 3)
  if camPos then out.cameraPos = camPos end
  local camRot = toNumberArray(metadata.cameraRot, 4)
  if camRot then out.cameraRot = camRot end
  if type(metadata.photomodePresets) == 'table' then
    out.photomodePresets = metadata.photomodePresets
  end
  if next(out) == nil then return nil end
  return out
end

local function buildOpenMapFromMetadata(metadata)
  if type(metadata) ~= 'table' then return nil end
  if type(metadata.level) ~= 'string' or metadata.level == '' then return nil end
  local out = { level = metadata.level }
  local camPos = toNumberArray(metadata.cameraPos, 3)
  local camRot = toNumberArray(metadata.cameraRot, 4)
  if camPos then out.camPos = camPos end
  if camRot then out.camRot = camRot end
  local tod = tonumber(metadata.timeOfDay)
  if tod then out.timeOfDay = tod end
  local fov = tonumber(metadata.fov)
  if fov and fov > 0 then out.fov = fov end
  return out
end

local function isMetadataPayloadUsable(data)
  if type(data) ~= 'table' then return false end
  if type(data.metadata) == 'table' and next(data.metadata) ~= nil then return true end
  if type(data.openMap) == 'table' and next(data.openMap) ~= nil then return true end
  return type(data.shareUrl) == 'string' and data.shareUrl ~= ''
end

local function writeScreenshotFallbackSidecar(screenshotPath, data, metadata, openMap, shareUrl, reason)
  local sidecarPath = getScreenshotMetadataSidecarPath(screenshotPath)
  if sidecarPath == '' then
    log('W', 'screenshot', 'metadata sidecar write failed: missing sidecar path for ' .. tostring(normalizeSlashes(screenshotPath)))
    return false
  end

  local writeOk = jsonWriteFile(sidecarPath, data, true) == true
  if not writeOk then
    log('W', 'screenshot', 'metadata sidecar write failed for ' .. tostring(sidecarPath) .. ' ' .. describeEmbeddedMetadataState(metadata, openMap, shareUrl))
    return false
  end

  logTrace(
    "metadata sidecar write ok"
      .. " path=" .. tostring(sidecarPath)
      .. " reason=" .. tostring(reason or 'fallback')
      .. " " .. describeEmbeddedMetadataState(metadata, openMap, shareUrl)
  )
  return true
end

local function readScreenshotFallbackSidecar(screenshotPath)
  local sidecarPath = getScreenshotMetadataSidecarPath(screenshotPath)
  if sidecarPath == '' or not FS:fileExists(sidecarPath) then
    logTrace("metadata sidecar read missing path=" .. tostring(sidecarPath))
    return nil
  end

  local data = jsonReadFile(sidecarPath)
  if not isMetadataPayloadUsable(data) then
    log('W', 'screenshot', 'metadata sidecar read invalid for ' .. tostring(sidecarPath))
    return nil
  end

  logTrace("metadata sidecar read ok path=" .. tostring(sidecarPath) .. " " .. describeEmbeddedMetadataState(data.metadata, data.openMap, data.shareUrl))
  return data
end

local function writeScreenshotSidecar(screenshotPath, metadata, shareUrl, options)
  options = type(options) == 'table' and options or {}
  local normalizedPath = normalizeSlashes(screenshotPath)
  local data = {
    version = 1,
    source = (type(shareUrl) == 'string' and shareUrl ~= '') and 'publishScreenShot' or 'screenshot',
    screenshotPath = normalizedPath,
    screenshotFileName = basenameFromPath(screenshotPath),
    createdAt = os.date('!%Y-%m-%dT%H:%M:%SZ'),
  }
  if type(shareUrl) == 'string' and shareUrl ~= '' then
    data.shareUrl = shareUrl
  end
  local minimalMeta = minimalScreenshotMetadata(metadata)
  local openMap = nil
  if type(minimalMeta) == 'table' then
    data.metadata = minimalMeta
    openMap = buildOpenMapFromMetadata(minimalMeta)
    if openMap then
      data.openMap = openMap
    end
  end
  logTrace("embedded metadata write begin path=" .. tostring(normalizedPath) .. " " .. describeEmbeddedMetadataState(minimalMeta, openMap, shareUrl))
  local sidecarReason = nil
  local embeddedWriteOk = false
  if type(writeScreenshotEmbeddedMetadata) ~= 'function' then
    if not embedWriteApiMissingLogged then
      embedWriteApiMissingLogged = true
      log('W', 'screenshot', 'embedded metadata write unavailable: writeScreenshotEmbeddedMetadata is missing')
    end
    logTrace("embedded metadata write skipped path=" .. tostring(normalizedPath) .. " reason=api_missing")
    sidecarReason = 'embed_api_missing'
  else
    local payload = jsonEncode(data)
    if type(payload) ~= 'string' or payload == '' then
      log('W', 'screenshot', 'embedded metadata write failed: payload encode returned empty for ' .. tostring(normalizedPath))
      sidecarReason = 'embed_payload_encode_failed'
    else
      embeddedWriteOk = writeScreenshotEmbeddedMetadata(screenshotPath, payload) == true
      if not embeddedWriteOk then
        log('W', 'screenshot', 'embedded metadata write failed for ' .. tostring(normalizedPath) .. ' ' .. describeEmbeddedMetadataState(minimalMeta, openMap, shareUrl))
        sidecarReason = 'embed_write_failed'
      else
        logTrace("embedded metadata write ok path=" .. tostring(normalizedPath) .. " " .. describeEmbeddedMetadataState(minimalMeta, openMap, shareUrl))
      end
    end
  end

  if embeddedWriteOk and not options.forceSidecar then
    clearPhotomodeRollMetadataCache(screenshotPath)
    return true
  end

  if embeddedWriteOk then
    sidecarReason = 'sidecar_sync'
  else
    logTrace("metadata persistence fallback=sidecar path=" .. tostring(normalizedPath) .. " reason=" .. tostring(sidecarReason))
  end

  local sidecarWriteOk = writeScreenshotFallbackSidecar(screenshotPath, data, minimalMeta, openMap, shareUrl, sidecarReason)
  if not sidecarWriteOk and embeddedWriteOk then
    log('W', 'screenshot', 'metadata sidecar sync failed after embedded metadata write for ' .. tostring(normalizedPath))
  end
  local writeOk = embeddedWriteOk or sidecarWriteOk
  if writeOk then
    clearPhotomodeRollMetadataCache(screenshotPath)
  end
  return writeOk
end

local function readPhotomodeUploadSidecarUncached(screenshotPath)
  local normalizedPath = normalizeSlashes(screenshotPath)
  if type(readScreenshotEmbeddedMetadata) ~= 'function' then
    if not embedReadApiMissingLogged then
      embedReadApiMissingLogged = true
      log('W', 'screenshot', 'embedded metadata read unavailable: readScreenshotEmbeddedMetadata is missing')
    end
    logTrace("embedded metadata read skipped path=" .. tostring(normalizedPath) .. " reason=api_missing")
    return readScreenshotFallbackSidecar(screenshotPath)
  end

  local encoded = readScreenshotEmbeddedMetadata(screenshotPath)
  if type(encoded) ~= 'string' or encoded == '' then
    logTrace("embedded metadata read empty path=" .. tostring(normalizedPath))
    return readScreenshotFallbackSidecar(screenshotPath)
  end

  local data = jsonDecode(encoded)
  if isMetadataPayloadUsable(data) then
    logTrace("embedded metadata read ok path=" .. tostring(normalizedPath) .. " " .. describeEmbeddedMetadataState(data.metadata, data.openMap, data.shareUrl))
    return data
  end

  log('W', 'screenshot', 'embedded metadata read invalid for ' .. tostring(normalizedPath))
  return readScreenshotFallbackSidecar(screenshotPath)
end

local function readPhotomodeUploadSidecar(screenshotPath, useCache)
  if useCache then
    local cacheHit, cached = getCachedPhotomodeRollMetadata(screenshotPath)
    if cacheHit then return cached end
  end

  local data = readPhotomodeUploadSidecarUncached(screenshotPath)
  if useCache then
    return cachePhotomodeRollMetadata(screenshotPath, data)
  end
  return data
end

local function doScreenshot(batchTag, upload, path, ext, options)
  startNewRun()
  -- find the next available screenshot filename
  local counter = 0

  local finalPath, format, filepath, filename, reservedPath
  if path and ext then
    finalPath = path
    format = ext
    upload = nil
    batchTag = nil
  else
    format = settings.getValue("screenshotFormat")

    filename = ''
    local filename_without_ext = ''
    filepath = ''
    local screenPath = screenshotPath .. tostring(getScreenShotFolderString())
    if not FS:directoryExists(screenPath) then
      FS:directoryCreate(screenPath)
    end
    repeat
      filename_without_ext = 'screenshot_' .. tostring(getScreenShotDateTimeString())
      if counter > 0 then
        filename_without_ext = filename_without_ext .. '_' .. tostring(counter)
      end
      filename = filename_without_ext .. '.' ..format
      filepath = screenPath .. '/' .. filename
      reservedPath = FS:expandFilename(filepath)
      counter = counter + 1
    until not FS:fileExists(filepath) and not reservedScreenshotPaths[reservedPath]
    reservedScreenshotPaths[reservedPath] = true
    finalPath = screenPath .. '/' .. filename_without_ext
  end

   -- TODO: fix metadata to include level, vehicles, etc


  local uploadRequested = upload == true
  local attachMetadata = shouldAttachScreenshotMetadata(options, uploadRequested)
  local persistMetadata = shouldPersistScreenshotMetadata(options)
  local writeJPG = tostring(format or ''):lower() == 'jpg' or tostring(format or ''):lower() == 'jpeg'
  local p = {
    filename = finalPath,
    writeJPG = writeJPG,
    superSampling = 1,
    tiles = 1,
    overlap = 0,
    rescaleFactor = 1,
    upload = uploadRequested,
    jsonMetaData = attachMetadata and getMetadataJson() or nil,
    persistMetadataSidecar = persistMetadata,
    bufferType = "color",
    objectTypeWhitelistMask = 0,
    objectTypeBlacklistMask = 0,
    shadowCasterObjectTypeWhitelistMask = 0,
    shadowCasterObjectTypeBlacklistMask = 0,
  }
  p.jobType = "full"
  createScreenshotTracked(p)
end

local function publish(batchTag, options)
  if settings.getValue('onlineFeatures') ~= 'enable' then
    log('E', 'screenshot.publish', 'screenshot publishing disabled because online features are disabled')
    guihooks.trigger("toastrMsg", {type="warning", title="Error uploading screenshot", msg="Online features are disabled. This setting must be enbled to upload screenshots to BeamNG's media server"})
    return
  end
  doScreenshot(batchTag, true, nil, nil, options)
end

local function doSteamScreenshot(options)
  if settings.getValue('onlineFeatures') ~= 'enable' then
    log('E', 'screenshot.publish', 'screenshot publishing disabled because online features are disabled')
    return
  end
  options = type(options) == 'table' and options or {}
  doScreenshot(nil, options.upload == true, nil, nil, options)
  OnlineServiceProvider.triggerScreenshot()
end

local function openScreenshotsFolderInExplorer()
  if not fileExistsOrNil('/screenshots/') then  -- create dir if it doesnt exist
    FS:directoryCreate('/screenshots/', true)
  end
  local screenshotFolderString = getScreenShotFolderString()
  local path = string.format("screenshots/%s", screenshotFolderString)
  if not FS:directoryExists(path) then FS:directoryCreate(path) end
  Engine.Platform.exploreFolder(path .. '/')
end

local function openScreenshotFileInExplorer(filePath)
  filePath = tostring(filePath or '')
  if filePath == '' then return end
  if not FS:fileExists(filePath) then
    log('W', 'screenshot', 'openScreenshotFileInExplorer: file not found: ' .. filePath)
    return
  end
  Engine.Platform.exploreFolder(filePath)
end

local function isPhotomodeRollMainShot(fn)
  if not fn or fn == '' then return false end
  local low = string.lower(fn)
  if string.find(low, '_scene', 1, true) or string.find(low, '_vehicle', 1, true)
      or string.find(low, '_normal', 1, true) or string.find(low, '_depth', 1, true) then
    return false
  end
  -- Accept both screenshot_YYYYMMDD_HHMMSS and screenshot_YYYY-MM-DD_HH-MM-SS
  return string.match(low, '^screenshot_%d%d%d%d%-?%d%d%-?%d%d_%d%d%-?%d%d%-?%d%d') ~= nil
end

local function addPhotomodeRollCandidate(candidates, path, limit)
  local fn = tostring(path or ''):match('[^/\\]+$') or tostring(path or '')
  if not isPhotomodeRollMainShot(fn) then return end

  local insertIndex = #candidates + 1
  while insertIndex > 1 and candidates[insertIndex - 1].fn < fn do
    insertIndex = insertIndex - 1
  end
  if insertIndex > limit then return end

  table.insert(candidates, insertIndex, { path = path, fn = fn })
  if #candidates > limit then
    table.remove(candidates)
  end
end

--- Collect latest main photomode captures in a month folder. Multi-pattern '*.png\\t*.jpg' findFiles can return nothing on some platforms; use separate globs.
local function findLatestPhotomodeRollCandidatesInFolder(folder, limit)
  local dir = folder .. '/'
  local candidates = {}
  local imageCount = 0
  local function addList(list)
    if not list then return end
    for _, f in ipairs(list) do
      imageCount = imageCount + 1
      addPhotomodeRollCandidate(candidates, f, limit)
    end
  end
  addList(FS:findFiles(dir, '*.png', -1, false, false))
  addList(FS:findFiles(dir, '*.jpg', -1, false, false))
  addList(FS:findFiles(dir, '*.jpeg', -1, false, false))
  if imageCount == 0 then
    local all = FS:findFiles(dir, '*', -1, false, false)
    if all then
      for _, f in ipairs(all) do
        local low = string.lower(f)
        if string.sub(low, -4) == '.png' or string.sub(low, -4) == '.jpg' or string.sub(low, -5) == '.jpeg' then
          imageCount = imageCount + 1
          addPhotomodeRollCandidate(candidates, f, limit)
        end
      end
    end
  end
  if imageCount == 0 then
    local listing = FS:directoryList(dir, false, false) or FS:directoryList(folder, false, false)
    if listing then
      for _, name in ipairs(listing) do
        local low = string.lower(tostring(name))
        if string.sub(low, -4) == '.png' or string.sub(low, -4) == '.jpg' or string.sub(low, -5) == '.jpeg' then
          local full = folder .. '/' .. name
          imageCount = imageCount + 1
          addPhotomodeRollCandidate(candidates, full, limit)
        end
      end
    end
  end
  return candidates
end

--- Sorted newest first (lexicographic on filename works for screenshot_YYYYMMDD_HHMMSS…).
local function getPhotomodeRollLimit(limit)
  local normalizedLimit = tonumber(limit)
  if normalizedLimit == nil then return PHOTOMODE_ROLL_ENTRY_LIMIT end
  if normalizedLimit <= 0 then return math.huge end
  return math.floor(normalizedLimit)
end

local function shouldSearchAllPhotomodeRollFolders(limit)
  local normalizedLimit = tonumber(limit)
  return normalizedLimit ~= nil and normalizedLimit <= 0
end

local function findLatestPhotomodeRollCandidatesRecursive(root, limit)
  if not FS:directoryExists(root) then return {} end

  local candidates = {}
  local function addList(list)
    if not list then return end
    for _, f in ipairs(list) do
      addPhotomodeRollCandidate(candidates, f, limit)
    end
  end

  addList(FS:findFiles(root .. '/', '*.png', -1, true, false))
  addList(FS:findFiles(root .. '/', '*.jpg', -1, true, false))
  addList(FS:findFiles(root .. '/', '*.jpeg', -1, true, false))
  return candidates
end

local function getPhotomodeRollEntries(limit)
  local normalizedLimit = getPhotomodeRollLimit(limit)
  local candidates

  if shouldSearchAllPhotomodeRollFolders(limit) then
    local root = FS:directoryExists('screenshots') and 'screenshots' or '/screenshots'
    candidates = findLatestPhotomodeRollCandidatesRecursive(root, normalizedLimit)
  else
    local folder = string.format('screenshots/%s', getScreenShotFolderString())
    if not FS:directoryExists(folder) then
      local alt = string.format('/screenshots/%s', getScreenShotFolderString())
      if FS:directoryExists(alt) then
        folder = alt
      else
        return {}
      end
    end
    candidates = findLatestPhotomodeRollCandidatesInFolder(folder, normalizedLimit)
  end

  if #candidates == 0 then return {} end
  prunePhotomodeRollMetadataCache(candidates)
  local out = {}
  for i = 1, #candidates do
    local row = { gamePath = candidates[i].path }
    local sidecar = readPhotomodeUploadSidecar(candidates[i].path, i <= PHOTOMODE_ROLL_METADATA_CACHE_LIMIT)
    if sidecar then
      if type(sidecar.shareUrl) == 'string' and sidecar.shareUrl ~= '' then
        row.shareUrl = sidecar.shareUrl
      end
      local sidecarMeta = minimalScreenshotMetadata(sidecar.metadata)
      if type(sidecarMeta) == 'table' then
        row.metadata = sidecarMeta
      end
      if type(sidecar.openMap) == 'table' then
        row.openMap = sidecar.openMap
      elseif type(sidecarMeta) == 'table' then
        local openMap = buildOpenMapFromMetadata(sidecarMeta)
        if openMap then
          row.openMap = openMap
        end
      end
    end
    out[i] = row
  end
  return out
end

--- JSON string for UI (engineLua table payloads are not reliably serialized to Angular/CEF; scalar string is).
local function getPhotomodeRollEntriesJson(limit)
  return jsonEncode(getPhotomodeRollEntries(limit))
end

local function getScreenshotJobsSnapshotJson()
  local snapshot = {}
  for i = 1, #jobsList do
    local job = jobsList[i]
    if job then
      local metadata = jobMetadataById[job.id]
      local minimalMeta = minimalScreenshotMetadata(metadata)
      local openMap = buildOpenMapFromMetadata(minimalMeta)
      snapshot[#snapshot + 1] = {
        id = job.id,
        runId = job.runId,
        percent = job.percent,
        message = job.message,
        phase = job.phase,
        result = job.result,
        filename = job.filename,
        bufferType = job.bufferType,
        type = job.type,
        metadata = minimalMeta,
        openMap = openMap,
      }
    end
  end
  return jsonEncode(snapshot)
end

local function safeFilenameTag(s)
  s = tostring(s or '')
  s = s:gsub('%W+', '_')
  s = s:gsub('^_+', ''):gsub('_+$', '')
  return s
end

local function enqueueScreenshot(p)
  if not p or not p.filename or p.filename == '' then return end
  local splitSceneVehicle, saveNormalDepth = normalizeArtifactCaptureFlags(
    p.splitSceneVehicle == true,
    p.saveNormalDepth == true
  )
  p.splitSceneVehicle = nil -- internal only
  p.saveNormalDepth = nil -- internal only

  -- keep old behavior: "no rescale" is factor 1
  local rf = tonumber(p.rescaleFactor)
  if not rf or rf <= 0 then rf = 1 end
  p.rescaleFactor = rf

  if not splitSceneVehicle and not saveNormalDepth then
    p.jobType = "full"
    createScreenshotTracked(p)
    return
  end

  local baseFilename = p.filename

  -- Full: full-color render of everything.
  p.filename = baseFilename
  p.bufferType = "color"
  p.objectTypeWhitelistMask = 0
  p.objectTypeBlacklistMask = 0
  p.shadowCasterObjectTypeWhitelistMask = 0
  p.shadowCasterObjectTypeBlacklistMask = 0
  if splitSceneVehicle then
    p.writeJPG = false
  end
  p.jobType = "full"
  createScreenshotTracked(p)

  if splitSceneVehicle then
    -- Scene: everything except vehicle, and vehicle also does NOT cast shadows.
    p.writeJPG = false
    p.bufferType = "color"

    p.filename = baseFilename .. "_scene"
    p.objectTypeWhitelistMask = 0
    p.objectTypeBlacklistMask = SOTMVehicle
    p.shadowCasterObjectTypeWhitelistMask = 0
    p.shadowCasterObjectTypeBlacklistMask = SOTMVehicle
    p.jobType = "scene"
    createScreenshotTracked(p)

    -- Vehicle: only vehicle visible.
    p.filename = baseFilename .. "_vehicle"
    p.objectTypeWhitelistMask = SOTMVehicle
    p.objectTypeBlacklistMask = 0
    p.shadowCasterObjectTypeWhitelistMask = 0
    p.shadowCasterObjectTypeBlacklistMask = 0
    p.jobType = "vehicle"
    createScreenshotTracked(p)

    -- Vehicle shadow: vehicle hidden but only vehicle casts shadows into the scene.
    p.filename = baseFilename .. "_vehicle_shadow"
    p.objectTypeWhitelistMask = 0
    p.objectTypeBlacklistMask = SOTMVehicle
    p.shadowCasterObjectTypeWhitelistMask = SOTMVehicle
    p.shadowCasterObjectTypeBlacklistMask = 0
    p.jobType = "vehicle shadow"
    createScreenshotTracked(p)
  end

  if saveNormalDepth then
    p.writeJPG = false
    p.objectTypeWhitelistMask = 0
    p.objectTypeBlacklistMask = 0
    p.shadowCasterObjectTypeWhitelistMask = 0
    p.shadowCasterObjectTypeBlacklistMask = 0

    -- Normals: full-scene normals buffer.
    p.filename = baseFilename .. "_normal"
    p.bufferType = "normals"
    p.jobType = "normals"
    createScreenshotTracked(p)

    -- Depth: full-scene depth buffer.
    p.filename = baseFilename .. "_depth"
    p.bufferType = "depth"
    p.jobType = "depth"
    createScreenshotTracked(p)

    if splitSceneVehicle then
      -- Scene normals: normals buffer without vehicle and without vehicle shadow casting.
      p.filename = baseFilename .. "_scene_normal"
      p.objectTypeWhitelistMask = 0
      p.objectTypeBlacklistMask = SOTMVehicle
      p.shadowCasterObjectTypeWhitelistMask = 0
      p.shadowCasterObjectTypeBlacklistMask = SOTMVehicle
      p.bufferType = "normals"
      p.jobType = "scene normals"
      createScreenshotTracked(p)

      -- Scene depth: depth buffer without vehicle and without vehicle shadow casting.
      p.filename = baseFilename .. "_scene_depth"
      p.objectTypeWhitelistMask = 0
      p.objectTypeBlacklistMask = SOTMVehicle
      p.shadowCasterObjectTypeWhitelistMask = 0
      p.shadowCasterObjectTypeBlacklistMask = SOTMVehicle
      p.bufferType = "depth"
      p.jobType = "scene depth"
      createScreenshotTracked(p)

      -- Vehicle normals: normals buffer for vehicle only.
      p.filename = baseFilename .. "_vehicle_normal"
      p.objectTypeWhitelistMask = SOTMVehicle
      p.objectTypeBlacklistMask = 0
      p.shadowCasterObjectTypeWhitelistMask = 0
      p.shadowCasterObjectTypeBlacklistMask = 0
      p.bufferType = "normals"
      p.jobType = "vehicle normals"
      createScreenshotTracked(p)

      -- Vehicle depth: depth buffer for vehicle only.
      p.filename = baseFilename .. "_vehicle_depth"
      p.objectTypeWhitelistMask = SOTMVehicle
      p.objectTypeBlacklistMask = 0
      p.shadowCasterObjectTypeWhitelistMask = 0
      p.shadowCasterObjectTypeBlacklistMask = 0
      p.bufferType = "depth"
      p.jobType = "vehicle depth"
      createScreenshotTracked(p)
    end
  end
end

local function _screenshot(superSampling, tiles, overlap, highest, rescaleFactor, bufferType, filenameTag, splitSceneVehicle, saveNormalDepth, options)
  bufferType = bufferType or "color"
  rescaleFactor = tonumber(rescaleFactor)
  if not rescaleFactor or rescaleFactor <= 0 then rescaleFactor = 1 end
  splitSceneVehicle, saveNormalDepth = normalizeArtifactCaptureFlags(splitSceneVehicle, saveNormalDepth)

  -- set the new values
  if highest and not M.hqActive then
    M.hqActive = true
    -- log('I','screenshot', "Setting new render parameters ...")
    -- save current values
    M.sc_detailAdjustSaved = VariableRegistry.get("$pref::TS::detailAdjust")
    M.sc_lodScaleSaved = VariableRegistry.get("$pref::Terrain::lodScale")
    M.sc_GroundCoverScaleSaved =  getGroundCoverScale()

    VariableRegistry.set("$pref::TS::detailAdjust", 20) -- 1.5; -- high is better
    VariableRegistry.set("$pref::Terrain::lodScale", 0.001) -- 0.75; -- lower is better
    setGroundCoverScale(8) -- 1 -- bigger is better
    flushGroundCoverGrids()
  end

  -- Supersampled captures render a single frame at a new resolution, which
  -- invalidates the volumetric cloud temporal history. Trace clouds at full
  -- resolution with a higher step count so the captured frame is not noisy.
  if superSampling and superSampling > 1 and not M.cloudHqActive and CloudLayer then
    M.cloudHqActive = true
    M.sc_cloudDownsampleSaved = CloudLayer.vrtDownsampleFactor
    M.sc_cloudStepCountSaved = CloudLayer.stepCount
    M.sc_cloudSunShadowStepCountSaved = CloudLayer.sunShadowStepCount
    CloudLayer.vrtDownsampleFactor = 1
    CloudLayer.stepCount = 256
    CloudLayer.sunShadowStepCount = 16
  end

  local screenshotFolderString = getScreenShotFolderString()
  local path = string.format("screenshots/%s", screenshotFolderString)
  if not FS:directoryExists(path) then FS:directoryCreate(path) end
  local screenshotDateTimeString = getScreenShotDateTimeString()
  local subFilename = string.format("%s/screenshot_%s", path, screenshotDateTimeString)
  if filenameTag and filenameTag ~= '' then
    subFilename = subFilename .. '_' .. filenameTag
  end
  local screenshotFormat = settings.getValue("screenshotFormat")
  local writeJPG = tostring(screenshotFormat or ''):lower() == 'jpg' or tostring(screenshotFormat or ''):lower() == 'jpeg'
  local outputExtension = writeJPG and '.jpg' or '.png'

  local fullFilename
  local outputFilename
  local screenshotNumber = 0
  repeat
    if screenshotNumber > 0 then
      fullFilename = FS:expandFilename(string.format("%s_%s", subFilename, screenshotNumber))
    else
      fullFilename = FS:expandFilename(subFilename)
    end
    outputFilename = fullFilename .. outputExtension
    screenshotNumber = screenshotNumber + 1
  until not FS:fileExists(outputFilename) and not reservedScreenshotPaths[outputFilename]
  reservedScreenshotPaths[outputFilename] = true
  log('I','screenshot', "writing screenshot: " .. fullFilename)

  -- log('I','screenshot', "Taking screenshot "..fullFilename.." Format = "..screenshotFormat.." superSampling = "..tostring(superSampling).." tiles = "..tostring(tiles).." overlap = "..tostring(overlap).." rescaleFactor = "..tostring(rescaleFactor))
  local uploadRequested = type(options) == 'table' and options.upload == true
  local attachMetadata = shouldAttachScreenshotMetadata(options, uploadRequested)
  local persistMetadata = shouldPersistScreenshotMetadata(options)
  enqueueScreenshot({
    filename = fullFilename,
    writeJPG = writeJPG,
    superSampling = superSampling,
    tiles = tiles,
    overlap = overlap,
    rescaleFactor = rescaleFactor,
    upload = uploadRequested,
    jsonMetaData = attachMetadata and getMetadataJson() or nil,
    persistMetadataSidecar = persistMetadata,
    callOrigin = options and options.callOrigin or nil,
    bufferType = bufferType,
    splitSceneVehicle = splitSceneVehicle,
    saveNormalDepth = saveNormalDepth,
  })
end

-- executed by c++ when the screenshot is done
-- res == 0 means all good
local function screenshotSaved(id, res, filename)
  local j = jobs[id]
  if not j then
    log('E', 'screenshot', "screenshotSaved: unknown job id " .. tostring(id))
    return
  end

  j.result = res
  j.filename = tostring(filename or j.filename or '')
  local isUploadJob = uploadJobIds[id] == true
  local meta = jobMetadataById[id]
  local sidecarEnabled = jobSidecarEnabledById[id] == true
  if res == 0 then
    j.phase = 'done'
    j.percent = 100
    if sidecarEnabled and j.type == 'full' and j.filename ~= '' then
      if isUploadJob then
        writeScreenshotSidecar(j.filename, meta, nil)
        pendingUploadSidecars[id] = {
          filename = j.filename,
          metadata = meta
        }
      else
        writeScreenshotSidecar(j.filename, meta, nil)
        uploadJobIds[id] = nil
        jobMetadataById[id] = nil
        jobSidecarEnabledById[id] = nil
      end
    else
      pendingUploadSidecars[id] = nil
      uploadJobIds[id] = nil
      jobMetadataById[id] = nil
      jobSidecarEnabledById[id] = nil
    end
  else
    j.phase = 'error'
    pendingUploadSidecars[id] = nil
    uploadJobIds[id] = nil
    jobMetadataById[id] = nil
    jobSidecarEnabledById[id] = nil
  end
  logTrace(
    "screenshotSaved"
      .. " runId=" .. tostring(j.runId)
      .. " id=" .. tostring(id)
      .. " phase=" .. tostring(j.phase)
      .. " result=" .. tostring(res)
      .. " filename=" .. tostring(j.filename or "")
  )
  pushJobsToUI()
end

local function screenshotUploaded(id, result, _adminUrl, shareUrl)
  id = tonumber(id) or 0
  result = tonumber(result) or 1
  shareUrl = tostring(shareUrl or '')

  local pending = pendingUploadSidecars[id]
  if pending and pending.filename and pending.filename ~= '' then
    writeScreenshotSidecar(pending.filename, pending.metadata, shareUrl, { forceSidecar = true })
    if guihooks and guihooks.trigger then
      guihooks.trigger("ScreenshotUploadComplete", {
        id = id,
        result = result,
        gamePath = pending.filename,
        shareUrl = shareUrl
      })
    end
  elseif guihooks and guihooks.trigger then
    guihooks.trigger("ScreenshotUploadComplete", {
      id = id,
      result = result,
      gamePath = "",
      shareUrl = shareUrl
    })
  end

  if guihooks and guihooks.trigger then
    if result == 0 then
      guihooks.trigger("toastrMsg", {type="info", title="Screenshot uploaded", msg="Screenshot uploaded to BeamNG media server"})
    else
      guihooks.trigger("toastrMsg", {type="warning", title="Screenshot upload failed", msg="Could not upload screenshot"})
    end
  end

  pendingUploadSidecars[id] = nil
  uploadJobIds[id] = nil
  jobMetadataById[id] = nil
  jobSidecarEnabledById[id] = nil
end

-- this is called when the screenshot is taken on the GPU, but not written to disc yet. see screenshotSaved
-- we revet some graphic settings in here only to return to a normal render state
local function screenshotTaken(id)
  local j = jobs[id]
  if not j then
    log('E', 'screenshot', "screenshotTaken: unknown job id " .. tostring(id))
    return
  end
  j.phase = 'saving'
  logTrace("screenshotTaken runId=" .. tostring(j.runId) .. " id=" .. tostring(id) .. " phase=saving")
  pushJobsToUI()
end

local function clearScreenshotJobs()
  jobs = {}
  M.hqActive = false
  jobsList = {}
  uploadJobIds = {}
  jobMetadataById = {}
  jobSidecarEnabledById = {}
  pendingUploadSidecars = {}
  pushJobsToUI()
end

local function screenshotProgress(id, percent, message)
  local j = jobs[id]
  if not j then
    log('E', 'screenshot', "screenshotProgress: unknown job id " .. tostring(id))
    return
  end
  j.phase = 'in progress'
  j.percent = tonumber(percent) or j.percent or 0
  j.message = tostring(message or '')
  logTrace(
    "screenshotProgress"
      .. " runId=" .. tostring(j.runId)
      .. " id=" .. tostring(id)
      .. " percent=" .. tostring(j.percent)
      .. " message=" .. tostring(j.message)
  )
  pushJobsToUI()
end

local function screenshotAllDone()
  if M.hqActive then
    M.hqActive = false
    log('I','screenshot', "Screenshot done, resetting render parameters")
    VariableRegistry.set("$pref::TS::detailAdjust", M.sc_detailAdjustSaved)
    VariableRegistry.set("$pref::Terrain::lodScale", M.sc_lodScaleSaved)
    setGroundCoverScale(M.sc_GroundCoverScaleSaved)
  end

  if M.cloudHqActive then
    M.cloudHqActive = false
    if CloudLayer then
      CloudLayer.vrtDownsampleFactor = M.sc_cloudDownsampleSaved
      CloudLayer.stepCount = M.sc_cloudStepCountSaved
      CloudLayer.sunShadowStepCount = M.sc_cloudSunShadowStepCountSaved
    end
  end

  reservedScreenshotPaths = {}
  logTrace("screenshotAllDone runId=" .. tostring(currentRunId))
  if extensions and extensions.hook then
    extensions.hook('onScreenshotAllDone')
  end
  if guihooks and guihooks.trigger then
    guihooks.trigger("ScreenshotJobsAllDone", true)
  end
end

-- WARNING: Be very careful when tweaking supersampling, massive will cause freezes and crash some GPU drivers
-- Normal: Just takes the picture.
-- Native. If you are at 1080p, you get a 1080p picture.
local function takeScreenShot(a, b, c, d)
  startNewRun()
  local options = extractScreenshotCallOptions(c, d)
  local splitSceneVehicle, saveNormalDepth
  if type(a) == 'table' then
    splitSceneVehicle = c == true
    saveNormalDepth = d == true
  else
    splitSceneVehicle = a == true
    saveNormalDepth = b == true
  end
  logTrace(
    "takeScreenShot request"
      .. " runId=" .. tostring(currentRunId)
      .. " splitSceneVehicle=" .. tostring(splitSceneVehicle)
      .. " saveNormalDepth=" .. tostring(saveNormalDepth)
  )
  _screenshot(1, 1, 0, false, nil, 'color', nil, splitSceneVehicle, saveNormalDepth, options)
end

-- Big: 2x Scale (4x total pixels).
-- 1080p user gets a 4K image.
-- 4K user gets an 8K image (Safe limit for most GPUs).
local function takeBigScreenShot(a, b, c, d)
  startNewRun()
  local options = extractScreenshotCallOptions(c, d)
  local splitSceneVehicle, saveNormalDepth
  if type(a) == 'table' then
    splitSceneVehicle = c == true
    saveNormalDepth = d == true
  else
    splitSceneVehicle = a == true
    saveNormalDepth = b == true
  end
  _screenshot(4, 1, 0, false, nil, 'color', nil, splitSceneVehicle, saveNormalDepth, options)
end

-- Huge: 3x Scale (9x total pixels).
-- 1080p user gets a ~6K image.
-- 4K user gets a ~12K image.
local function takeHugeScreenShot(a, b, c, d)
  startNewRun()
  local options = extractScreenshotCallOptions(c, d)
  local splitSceneVehicle, saveNormalDepth
  if type(a) == 'table' then
    splitSceneVehicle = c == true
    saveNormalDepth = d == true
  else
    splitSceneVehicle = a == true
    saveNormalDepth = b == true
  end
  _screenshot(9, 1, 0, true, nil, 'color', nil, splitSceneVehicle, saveNormalDepth, options)
end

-- Custom: expose supersampling (first argument) for UI preview/advanced usage.
-- The parameter is total pixel multiplier (1 = native, 4 = 2x linear, 9 = 3x linear).
-- WARNING: values above 9 are likely to freeze/crash some GPU drivers.
local function takeCustomScreenShot(superSampling, rescaleFactor, a, b, c, d)
  startNewRun()
  local options = extractScreenshotCallOptions(c, d)
  superSampling = tonumber(superSampling) or 1
  superSampling = math.floor(superSampling + 0.5)
  superSampling = math.max(1, math.min(24, superSampling))
  rescaleFactor = tonumber(rescaleFactor)
  local splitSceneVehicle, saveNormalDepth
  if type(a) == 'table' then
    splitSceneVehicle = c == true
    saveNormalDepth = d == true
  else
    splitSceneVehicle = a == true
    saveNormalDepth = b == true
  end
  _screenshot(superSampling, 1, 0, superSampling >= 9, rescaleFactor, 'color', nil, splitSceneVehicle, saveNormalDepth, options)
end

local function takeMotionBlurScreenShot(superSampling, rescaleFactor, a, b, c, d)
  startNewRun()
  local options = extractScreenshotCallOptions(c, d)
  superSampling = tonumber(superSampling) or 1
  superSampling = math.floor(superSampling + 0.5)
  superSampling = math.max(1, math.min(24, superSampling))
  rescaleFactor = tonumber(rescaleFactor)
  local splitSceneVehicle, saveNormalDepth
  if type(a) == 'table' then
    splitSceneVehicle = c == true
    saveNormalDepth = d == true
  else
    splitSceneVehicle = a == true
    saveNormalDepth = b == true
  end
  _screenshot(superSampling, 1, 0, superSampling >= 9, rescaleFactor, 'color', nil, splitSceneVehicle, saveNormalDepth, options)
end

-- Single entry point for legacy photomode UI callbacks (must be one expression in guihooks.trigger).
function M.runPhotomodeFlashCapture(kind, ...)
  extensions.load('util/photomodeFlash')
  if extensions.util_photomodeFlash and extensions.util_photomodeFlash.runCapture then
    extensions.util_photomodeFlash.runCapture(kind, ...)
  end
end

-- public interface
M.publish = publish
M.doScreenshot = doScreenshot
M.doSteamScreenshot = doSteamScreenshot
M.createScreenshotTracked = createScreenshotTracked
M.openScreenshotsFolderInExplorer = openScreenshotsFolderInExplorer
M.openScreenshotFileInExplorer = openScreenshotFileInExplorer
M.getPhotomodeRollEntries = getPhotomodeRollEntries
M.getPhotomodeRollEntriesJson = getPhotomodeRollEntriesJson
M.getScreenshotJobsSnapshotJson = getScreenshotJobsSnapshotJson
M.setDebugTracingEnabled = function(value) debugTracingEnabled = value == true end
M.isDebugTracingEnabled = function() return debugTracingEnabled end

M.clearScreenshotJobs = clearScreenshotJobs
M.screenshotProgress = screenshotProgress
M.screenshotAllDone = screenshotAllDone

M.takeScreenShot = takeScreenShot
M.takeBigScreenShot = takeBigScreenShot
M.takeHugeScreenShot = takeHugeScreenShot
M.takeCustomScreenShot = takeCustomScreenShot
M.takeMotionBlurScreenShot = takeMotionBlurScreenShot

M.screenshotTaken = screenshotTaken -- GPU snapshot done
M.screenshotSaved = screenshotSaved -- saved to disk
M.screenshotUploaded = screenshotUploaded -- upload finished (success or error)

return M