-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local renderViewName = 'defaultRenderView' -- the name is the unique identifier for renderviews
--local targetRenderView = DebugDrawerTargetRenderViews({renderViewName})

local defaultRes = vec3(512, 256, 0) -- resolution in pixels
local activateAAAfter

local function getMainViewExposure()
  local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
  if not localExposure then return nil end
  local autoExposure = localExposure.autoExposure == true
  local mainView = RenderViewManagerInstance:getView("main")
  return {
    manualEV = not autoExposure and localExposure.manualEV or nil,
    currentExposure = autoExposure and mainView and mainView.currentExposure or nil
  }
end

local function saveToFileJob(job)
  local renderView = job.args[1]
  local filename = job.args[2]
  local screenshotDelay = job.args[3] or 0.1
  local callback = job.args[4]
  local downscaleFactor = job.args[5]

  local cefVisible = ui_visibility.getCef()
  local imguiVisible = ui_visibility.getImgui()
  ui_visibility.setCef(false)
  ui_visibility.setImgui(false)
  gameplay_markerInteraction.setMarkersVisibleTemporary(false)
  job.sleep(screenshotDelay)

  local tempFile = filename .. ".tmp.png"
  local success = false
  FS:removeFile(tempFile)

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
  ui_visibility.setCef(cefVisible)
  ui_visibility.setImgui(imguiVisible)

  if activateAAAfter then
    settings.setValue('GraphicAntialias', 4)
    activateAAAfter = nil
  end

  if callback then callback(success) end
end

local function takeScreenshot(options, callback)
  local resolution = options.resolution or defaultRes
  local downscaleFactor = options.downscaleFactor -- NEW
  local manualEV = options.manualEV
  local currentExposure = options.currentExposure

  if options.copyMainViewExposure then
    local exposure = getMainViewExposure()
    manualEV = exposure and exposure.manualEV or nil
    currentExposure = exposure and exposure.currentExposure or nil
  end

  -- create the renderview
  local renderView = RenderViewManagerInstance:getOrCreateView(options.renderViewName or renderViewName)
  renderView.luaOwned = true -- make sure the view is deleted properly if the GC collects it
  if options.renderViewMaskBit ~= nil then
    renderView:maskSet(options.renderViewMaskBit)
  end

  -- update the parameters
  local mat = QuatF(options.rot.x, options.rot.y, options.rot.z, options.rot.w):getMatrix()
  mat:setPosition(options.pos)

  renderView.renderCubemap = false
  renderView.cameraMatrix = mat -- determines where the virtual camera is in 3d space
  renderView.resolution = Point2I(resolution.x, resolution.y)
  renderView.viewPort = RectI(0, 0, resolution.x, resolution.y)
  renderView.namedTexTargetColor = options.renderViewName or renderViewName -- important: the target texture, used in texObj
  if options.usePostEffects ~= nil then
    renderView.usePostEffects = options.usePostEffects == true
  end
  if options.clearColor then
    renderView.clearColor = options.clearColor
  end
  if options.objectTypeWhitelistMask then
    renderView.objectTypeWhitelistMask = options.objectTypeWhitelistMask
  end
  if options.objectTypeBlacklistMask then
    renderView.objectTypeBlacklistMask = options.objectTypeBlacklistMask
  end
  if options.shadowCasterObjectTypeWhitelistMask then
    renderView.shadowCasterObjectTypeWhitelistMask = options.shadowCasterObjectTypeWhitelistMask
  end
  if options.shadowCasterObjectTypeBlacklistMask then
    renderView.shadowCasterObjectTypeBlacklistMask = options.shadowCasterObjectTypeBlacklistMask
  end
  if options.focusObjects then
    renderView:enterFocusObjectsMode()
    for _, object in ipairs(options.focusObjects) do
      renderView:addFocusObject(object)
    end
  end
  renderView.useManualEV = manualEV ~= nil
  renderView.manualEV = manualEV or 0
  if not renderView.useManualEV and currentExposure and currentExposure > 0 then
    renderView.currentExposure = currentExposure
  end
  -- renderView.getCameraObject()
  -- renderView.setCameraObject()
  -- renderView.clearCameraObject()
  local aspectRatio = resolution.x / resolution.y
  local renderOrthogonal = false
  local fov = options.fov or 75
  local nearPlane = options.nearPlane or 0.1
  local farClip = options.farClip or 2000
  renderView.frustum = Frustum.construct(renderOrthogonal, math.rad(fov), aspectRatio, nearPlane, farClip)
  renderView.fov = fov
  renderView.renderEditorIcons = false

  -- T2x history does not survive an independent view; stateless FXAA is opt-in so mask captures stay unfiltered.
  local aaType = settings.getValue('GraphicAntialiasType')
  local disableFxaa = aaType == "fxaa" and options.allowAntialiasing ~= true
  if settings.getValue('GraphicAntialias') == 4 and (disableFxaa or aaType == "smaaT2x") then
    settings.setValue('GraphicAntialias', 0)
    activateAAAfter = true
  end

  core_jobsystem.create(saveToFileJob, nil, renderView, options.filename, options.screenshotDelay, callback, downscaleFactor)
end

M.takeScreenshot = takeScreenshot

return M