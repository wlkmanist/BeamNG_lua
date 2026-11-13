-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

M.dependencies = {"render_renderViews"}

local reflectionCardRenderViewMaskBit = 63
-- A fresh render view needs about a second before post effects converge
-- Earlier frames come out darker and contrastier
local renderViewSettleDelay = 1

-- Offscreen thumbnail, must be called from a coroutine.
-- Nothing on screen is touched, the render view hides the UI and markersS.
function M.captureFramedThumbnail(filepath, camera, options)
  local done, captured = false, false
  M.takeThumbnailScreenshot(filepath, camera, function(result)
    done, captured = true, result == true
  end, nil, {
    resolution = options.resolution,
    supersampling = options.supersampling,
    fov = options.fov,
    nearPlane = options.nearPlane,
    -- depth based post effects normalize by the far plane, so it has to match the one DOF was tuned against
    farClip = RenderViewManagerInstance:getView("main").frustum:getFarDist()
  })
  local timeout = os.clock() + math.max(options.captureTimeout or 5, 0.1)
  while not done and os.clock() < timeout do coroutine.yield() end
  return captured and FS:fileExists(filepath) and FS:fileSize(filepath) > 0
end

function M.takeThumbnailScreenshot(filepath, camera, callback, uniqueId, options)
  if type(filepath) ~= "string" or filepath == "" or type(camera) ~= "table" or not camera.pos or not camera.rot
  then
    log("W", "thumbnail", "takeThumbnailScreenshot: missing filepath or camera pos/rot")
    if callback then callback() end
    return
  end

  options = options or {}
  local resolution = options.resolution or {500, 281}
  local supersampling = options.supersampling or 4

  local renderViewOptions = {
    renderViewName = "thumbnailScreenshot",
    screenshotDelay = camera.screenshotDelay or renderViewSettleDelay,
    resolution = vec3(
      math.floor(resolution[1] * supersampling),
      math.floor(resolution[2] * supersampling),
      0
    ),
    downscaleFactor = supersampling,
    copyMainViewExposure = true,
    rot = camera.rot,
    pos = camera.pos,
    fov = camera.fov or options.fov or 20,
    nearPlane = camera.nearPlane or options.nearPlane or 0.1,
    farClip = options.farClip,
    filename = filepath,
    renderViewMaskBit = reflectionCardRenderViewMaskBit
  }

  FS:removeFile(filepath)
  log("I", "", "Saved screenshot:" .. renderViewOptions.filename)
  render_renderViews.takeScreenshot(renderViewOptions, callback)
end

return M
