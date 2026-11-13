-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {
  "util_screenshotCreator_settings",
  "util_screenshotCreator_capture",
  "util_screenshotCreator_framing_legacy",
  "util_screenshotCreator_framing_isometric",
  "util_screenshotCreator_framing_procedural",
  "util_screenshotCreator_framing_configured",
  "util_screenshotCreator_framingManager"
}

local activeCapture

local function runCapture(capture)
  local resolution = util_screenshotCreator_settings.getThumbnailResolution()
  local framing = util_screenshotCreator_settings.getFramingContext(resolution)
  framing.vehicle = capture.vehicle
  framing.modelName = capture.vehicle.jbeam or capture.vehicle.JBeam
  framing.configName = capture.configName
  framing.framingModeId = util_screenshotCreator_framingManager.getSelectedModeId()
  framing.preview = false

  local camera, resolveError = util_screenshotCreator_framingManager.resolve(framing.framingModeId, framing)
  if not camera then
    capture.callback(false, capture.outputPath, capture.token, resolveError)
    return
  end

  local success = util_screenshotCreator_capture.captureFramedThumbnail(capture.outputPath, camera, {
    resolution = resolution,
    fov = framing.fov,
    nearPlane = framing.nearPlane,
    captureTimeout = 5
  })
  capture.callback(success, capture.outputPath, capture.token)
end

function M.start(vehicle, configName, outputPath, callback, token)
  if activeCapture then return false, "busy" end
  local capture = {
    vehicle = vehicle,
    configName = configName,
    outputPath = outputPath,
    callback = callback,
    token = token
  }
  capture.coroutine = coroutine.create(function() runCapture(capture) end)
  activeCapture = capture
  return true
end

function M.onPreRender()
  local capture = activeCapture
  if not capture then return end
  local ok, err = coroutine.resume(capture.coroutine)
  if not ok then
    activeCapture = nil
    log("E", "currentConfigThumbnail", tostring(err))
    capture.callback(false, capture.outputPath, capture.token, tostring(err))
  elseif activeCapture == capture and coroutine.status(capture.coroutine) == "dead" then
    activeCapture = nil
  end
end

function M.onExtensionUnloaded()
  activeCapture = nil
end

return M
