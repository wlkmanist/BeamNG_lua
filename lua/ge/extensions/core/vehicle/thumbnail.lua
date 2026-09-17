-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"core_vehicle_manager"}

local TEMP_THUMBNAIL_DIR = "/screenshots/vehicleConfigTemp"
local PREVIEW_READY_HOOK = "VehicleConfigThumbnailPreviewReady"
local captureSequence = math.floor(os.clockhp() * 1000000)
local captures = {}

local function ensureDirectory(path)
  if type(path) ~= "string" or path == "" then
    return
  end
  if not FS:directoryExists(path) then
    FS:directoryCreate(path, true)
  end
end

local function getDirectory(path)
  if type(path) ~= "string" then
    return nil
  end
  return string.match(path, "^(.*)[/\\][^/\\]+$")
end

local function sanitizeConfigName(configName)
  if type(configName) ~= "string" then
    return nil
  end
  local sanitized = configName
  sanitized = sanitized:gsub("\\", "/")
  sanitized = sanitized:match("([^/]+)$") or sanitized
  sanitized = sanitized:gsub("%.pc$", "")
  sanitized = sanitized:gsub("%.jpg$", "")
  if sanitized == "" then
    return nil
  end
  return sanitized
end

local function normalizePath(path)
  if type(path) ~= "string" then
    return nil
  end
  local normalized = path:gsub("\\", "/")
  normalized = normalized:gsub("/+", "/")
  return normalized
end

local function getCurrentConfigName()
  local playerVehicle = getPlayerVehicle(0)
  if not playerVehicle then
    return nil
  end
  local partConfig = tostring(playerVehicle.partConfig or "")
  return sanitizeConfigName(partConfig)
end

local function normalizeCopyResult(copyResult)
  return copyResult == true or copyResult == 0
end

local function nextCaptureId()
  captureSequence = captureSequence + 1
  return captureSequence
end

local function getCapturePath(captureId)
  return string.format("%s/save-preview-%d.jpg", TEMP_THUMBNAIL_DIR, captureId)
end

local function generateThumbnail(configName, outputPath, doneHook, completionCallback, completionToken)
  local normalizedConfigName = sanitizeConfigName(configName)
  if not normalizedConfigName then
    return false
  end

  local workOptions = {
    selection = normalizedConfigName,
    configName = normalizedConfigName,
  }
  if type(outputPath) == "string" and outputPath ~= "" then
    workOptions.outputPath = outputPath
  end
  if type(doneHook) == "string" and doneHook ~= "" then
    workOptions.onDoneHook = doneHook
  end
  if type(completionCallback) == "function" then
    workOptions.internalCompletionCallback = completionCallback
    workOptions.completionToken = completionToken
  end

  local started = extensions.util_screenshotCreator.startWork(workOptions)
  return started == nil and true or started
end

local function generateConfigThumbnail(configName)
  return generateThumbnail(configName, nil, nil)
end

local function getTemporaryThumbnail()
  local readyCaptureId
  for captureId, capture in pairs(captures) do
    if capture.ready and not capture.cancelled and FS:fileExists(capture.path)
      and (not readyCaptureId or captureId > readyCaptureId) then
      readyCaptureId = captureId
    end
  end
  if readyCaptureId then
    return { captureId = readyCaptureId, path = captures[readyCaptureId].path }
  end
  return { path = nil }
end

local function onCaptureCompleted(success, outputPath, captureId)
  local capture = captures[captureId]
  if not capture then
    if type(captureId) == "number" then
      FS:removeFile(getCapturePath(captureId))
    end
    return
  end

  capture.inProgress = false
  local validOutput = success == true
    and normalizePath(outputPath) == capture.path
    and FS:fileExists(capture.path)
  if capture.cancelled then
    FS:removeFile(capture.path)
    captures[captureId] = nil
    return
  end
  if not validOutput then
    FS:removeFile(capture.path)
    captures[captureId] = nil
    guihooks.trigger(PREVIEW_READY_HOOK, {captureId = captureId, success = false})
    return
  end

  capture.ready = true
  guihooks.trigger(PREVIEW_READY_HOOK, {
    captureId = captureId,
    success = true,
    path = capture.path,
  })
end

local function captureTemporaryThumbnail()
  local configName = getCurrentConfigName()
  if not configName then
    log("E", "core_vehicle_thumbnail", "cannot capture preview thumbnail: no current config name")
    return {success = false, reason = "noCurrentConfig"}
  end

  ensureDirectory(TEMP_THUMBNAIL_DIR)
  local captureId = nextCaptureId()
  local capturePath = getCapturePath(captureId)
  FS:removeFile(capturePath)
  captures[captureId] = {
    path = capturePath,
    inProgress = true,
    ready = false,
    cancelled = false,
  }
  local started = generateThumbnail(configName, capturePath, nil, onCaptureCompleted, captureId)
  if not started then
    captures[captureId] = nil
    return {success = false, reason = "busy"}
  end
  return {success = true, captureId = captureId, path = capturePath}
end

local function cancelTemporaryThumbnail(captureId)
  local capture = captures[captureId]
  if not capture then
    return {success = false, reason = "captureNotFound", captureId = captureId}
  end
  capture.cancelled = true
  FS:removeFile(capture.path)
  if not capture.inProgress then
    captures[captureId] = nil
  end
  return {success = true, captureId = captureId}
end

local function clearTemporaryThumbnail(captureId)
  if captureId ~= nil then
    return cancelTemporaryThumbnail(captureId)
  end
  local captureIds = {}
  for id in pairs(captures) do
    table.insert(captureIds, id)
  end
  for _, id in ipairs(captureIds) do
    cancelTemporaryThumbnail(id)
  end
  return {success = true}
end

local function isValidTemporaryThumbnail(path)
  local normalizedPath = normalizePath(path)
  for _, capture in pairs(captures) do
    if capture.path == normalizedPath and capture.ready and not capture.cancelled and FS:fileExists(capture.path) then
      return true
    end
  end
  return false
end

local function copyThumbnailFile(sourcePath, targetPath)
  if type(sourcePath) ~= "string" or sourcePath == "" then
    return false
  end
  if type(targetPath) ~= "string" or targetPath == "" then
    return false
  end
  if not FS:fileExists(sourcePath) then
    return false
  end

  ensureDirectory(getDirectory(targetPath))
  local operationId = nextCaptureId()
  local tempTargetPath = string.format("%s.thumbnail-%d.tmp", targetPath, operationId)
  local backupTargetPath = string.format("%s.thumbnail-%d.bak", targetPath, operationId)
  FS:removeFile(tempTargetPath)
  FS:removeFile(backupTargetPath)
  if not normalizeCopyResult(FS:copyFile(sourcePath, tempTargetPath)) then
    FS:removeFile(tempTargetPath)
    return false
  end

  local hadTarget = FS:fileExists(targetPath)
  if hadTarget and FS:renameFile(targetPath, backupTargetPath) ~= 0 then
    FS:removeFile(tempTargetPath)
    return false
  end

  if FS:renameFile(tempTargetPath, targetPath) ~= 0 then
    if hadTarget and FS:renameFile(backupTargetPath, targetPath) ~= 0 then
      log("E", "core_vehicle_thumbnail", "unable to restore thumbnail backup: " .. tostring(targetPath))
    end
    FS:removeFile(tempTargetPath)
    return false
  end

  if hadTarget then
    FS:removeFile(backupTargetPath)
  end
  return true
end

local function commitTemporaryThumbnail(captureId, targetPath)
  local capture = captures[captureId]
  if not capture or not capture.ready or capture.cancelled or not FS:fileExists(capture.path) then
    return false
  end
  if not copyThumbnailFile(capture.path, targetPath) then
    return false
  end
  FS:removeFile(capture.path)
  captures[captureId] = nil
  return true
end

M.generateConfigThumbnail = generateConfigThumbnail
M.captureTemporaryThumbnail = captureTemporaryThumbnail
M.getTemporaryThumbnail = getTemporaryThumbnail
M.cancelTemporaryThumbnail = cancelTemporaryThumbnail
M.clearTemporaryThumbnail = clearTemporaryThumbnail
M.isValidTemporaryThumbnail = isValidTemporaryThumbnail
M.copyThumbnailFile = copyThumbnailFile
M.commitTemporaryThumbnail = commitTemporaryThumbnail

return M
