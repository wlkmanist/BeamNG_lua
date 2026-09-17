-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local renderViewName = 'defaultRenderView' -- the name is the unique identifier for renderviews
--local targetRenderView = DebugDrawerTargetRenderViews({renderViewName})

local defaultRes = vec3(512, 256, 0) -- resolution in pixels
local activateAAAfter

local function getMainViewManualEV()
  local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
  return localExposure and localExposure.manualEV or nil
end

local function saveToFileJob(job)
  local renderView = job.args[1]
  local filename = job.args[2]
  local screenshotDelay = job.args[3] or 0.1
  local callback = job.args[4]
  local downscaleFactor = job.args[5]

  ui_visibility.set(false)
  gameplay_markerInteraction.setMarkersVisibleTemporary(false)
  job.sleep(screenshotDelay)

  local tempFile = filename .. ".tmp.png"
  local success = false

  if renderView:saveToDisk(tempFile) then
    if downscaleFactor then
      local bmp = GBitmap()
      if bmp:loadFile(tempFile) then
        bmp:setFormat(10) -- GFXFormatR8G8B8
        local small = bmp:createDownscaledBitmap(downscaleFactor)
        success = small and small:saveFile(filename) or false
      else
        log('E', '', 'failed to load temp image for resizing')
      end
    else
      local copyResult = FS:copyFile(tempFile, filename)
      success = copyResult == true or copyResult == 0
    end
  else
    log('E', '', 'failed to save to disk: ' .. tostring(tempFile))
  end

  if not success then
    log('E', '', 'failed to create screenshot: ' .. tostring(filename))
  end

  FS:removeFile(tempFile)
  RenderViewManagerInstance:destroyView(renderView)
  gameplay_markerInteraction.setMarkersVisibleTemporary(true)
  ui_visibility.set(true)

  if activateAAAfter then
    settings.setValue('GraphicAntialias', 4)
    activateAAAfter = nil
  end

  if callback then callback(success) end
end

local function takeScreenshot(options, callback)
  local resolution = options.resolution or defaultRes
  local downscaleFactor = options.downscaleFactor -- NEW

  if options.copyMainViewExposure then
    options.manualEV = getMainViewManualEV()
  end

  -- create the renderview
  local renderView = RenderViewManagerInstance:getOrCreateView(options.renderViewName or renderViewName)
  renderView.luaOwned = true -- make sure the view is deleted properly if the GC collects it

  -- update the parameters
  local mat = QuatF(options.rot.x, options.rot.y, options.rot.z, options.rot.w):getMatrix()
  mat:setPosition(options.pos)

  renderView.renderCubemap = false
  renderView.cameraMatrix = mat -- determines where the virtual camera is in 3d space
  renderView.resolution = Point2I(resolution.x, resolution.y)
  renderView.viewPort = RectI(0, 0, resolution.x, resolution.y)
  renderView.namedTexTargetColor = options.renderViewName or renderViewName -- important: the target texture, used in texObj
  renderView.useManualEV = options.manualEV ~= nil
  renderView.manualEV = options.manualEV or 0
  -- renderView.getCameraObject()
  -- renderView.setCameraObject()
  -- renderView.clearCameraObject()
  local aspectRatio = resolution.x / resolution.y
  local renderOrthogonal = false
  local fov = options.fov or 75
  local nearPlane = options.nearPlane or 0.1
  local farClip = 2000
  renderView.frustum = Frustum.construct(renderOrthogonal, math.rad(fov), aspectRatio, nearPlane, farClip)
  renderView.fov = fov
  renderView.renderEditorIcons = false

  if settings.getValue('GraphicAntialias') == 4 and settings.getValue('GraphicAntialiasType') == "fxaa" then
    settings.setValue('GraphicAntialias', 0)
    activateAAAfter = true
  end

  core_jobsystem.create(saveToFileJob, nil, renderView, options.filename, options.screenshotDelay, callback, downscaleFactor)
end

M.takeScreenshot = takeScreenshot

return M