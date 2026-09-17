-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local M = {}

local logTag = "settings_graphic"

-- local/default variables for settings
local CEF_UI_maxSizeHeight = "1080"

local GraphicsQualityGroup       = require('core/settings/graphicsQualityGroup')
local lightingQualityGroup       = GraphicsQualityGroup('core/settings/lightingQuality', 'Lighting Quality')
local shadowsQuality             = require('core/settings/shadowsQuality')
local shadowsQualityGroup        = GraphicsQualityGroup('core/settings/shadowsQuality', 'Shadows Quality')
local textureQualityGroup        = GraphicsQualityGroup('core/settings/textureQuality', 'Texture Quality')
local meshQualityGroup           = GraphicsQualityGroup('core/settings/meshQuality', 'Mesh Quality')
local terrainQualityGroup        = GraphicsQualityGroup('core/settings/terrainQuality', 'Terrain Quality')
local clusteredQuality           = require('core/settings/clusteredQuality')

local platform = Engine and Engine.Platform and Engine.Platform.getPlatform() or ""

local overallQualityPresets = jsonReadFile("lua/ge/extensions/core/settings/settingsPresets.json") or {}

local internalPresetOrder = {}
local platformPresetOrder = {}
local usingPlatformPresets = false

local platformPresetIgnoreForCustomDetection = {
  PostFXDOFGeneralEnabled = true,
  PostFXMotionBlurEnabled = true,
  PostFXMotionBlurStrength = true,
  PostFXMotionBlurPlayerVehicle = true,
  fpsLimitEnabled = true,
}

local allowedPresetKeys = {}
for _, group in pairs(overallQualityPresets) do
  if type(group) == "table" then
    for k,_ in pairs(group) do
      allowedPresetKeys[k] = true
    end
  end
end

local function normalizePresetFilePath(file)
  if type(file) ~= "string" then return nil end
  if file:sub(1, 1) == "/" then
    file = file:sub(2)
  end
  return file
end

local function addPresetFromEntry(entry, orderTable, filterToDefaultGraphicKeys)
  local name = entry and entry.name
  local file = normalizePresetFilePath(entry and entry.file)

  if type(name) ~= "string" or type(file) ~= "string" then
    return false
  end

  local raw = jsonReadFile(file)
  if type(raw) ~= "table" then
    log("W", logTag, "Unable to load graphics preset file: " .. tostring(file))
    return false
  end

  if filterToDefaultGraphicKeys then
    local filtered = {}
    for k, v in pairs(raw) do
      if allowedPresetKeys[k] then
        filtered[k] = v
      end
    end
    overallQualityPresets[name] = filtered
  else
    overallQualityPresets[name] = raw
  end

  table.insert(orderTable, name)
  return true
end


local platformPresetTable = jsonReadFile("lua/ge/extensions/core/settings/settingsPresets-platform.json") or {}
local platformPresetEntries = nil

if platform ~= "" and type(platformPresetTable) == "table" then
  platformPresetEntries = platformPresetTable[platform]
end

if type(platformPresetEntries) == "table" then
  overallQualityPresets = {}
  usingPlatformPresets = true

  for _, entry in ipairs(platformPresetEntries) do
    addPresetFromEntry(entry, platformPresetOrder, false)
  end
elseif not shipping_build then
  local extraList = jsonReadFile("lua/ge/extensions/core/settings/settingsPresets-internal.json") or {}

  for _, entry in ipairs(extraList) do
    addPresetFromEntry(entry, internalPresetOrder, true)
  end
end

local graphicsOptions = nil
local graphicInformation = nil

local function setScreenSpaceShadowsEnabled(value)
  VariableRegistry.set('$AL::UseSSSmask', value)
  local sss = scenetree.findObject("ScreenSpaceShadowsPostFx")
  if not sss then return end
  if value then
    sss:enable()
  else
    sss:disable()
  end
end

local function hdrSupported()
  return GFXHdr and GFXHdr.getSupported() or false
end

local hdrOutputModeUpdateTimer = 0

local function getHdrOutputModeName()
  if not hdrSupported() then return "LDR" end
  if not GFXHdr or type(GFXHdr.getOutputModeName) ~= "function" then return "" end
  return GFXHdr.getOutputModeName()
end

local function updateHdrOutputModeSetting()
  settings.setValue("GraphicHDROutputModeName", getHdrOutputModeName())
  settings.notifyUI()
end

local function delayedHdrOutputMode()
  hdrOutputModeUpdateTimer = 2
end

local function applyExposureCompensation(value)
  local localExposure = scenetree.findObject("PostEffectLocalExposureObject")
  if localExposure then
    localExposure.exposureBiasEV = value
  end
end

local function setBloomEnabledForLightingQuality(lightingQuality)
  local postFX = scenetree.findObject("PostEffectBloomObject")
  if not postFX then return end

  if lightingQuality == "Lowest" then
    postFX:disable()
  else
    postFX:enable()
  end
  postFX.threshHold = 8
end

local function applyGraphicsState()
  if M.triggered_manual_save then
    log('E','graphic','Detected Saving in progress....ignoring redundant call')
    return
  end

  M.triggered_manual_save = true

  -- save the changes
  settings.requestSave()

  -- set canvas mode
  local canvas = scenetree.findObject("Canvas")

  if not canvas then
    return
  end

  local resolutionWidth, resolutionHeight = graphicsOptions.GraphicDisplayResolutions.getWidthHeight()
  local refreshRate = graphicsOptions.GraphicDisplayRefreshRates.get()

  local displayDriver = graphicsOptions.GraphicDisplayDriver.get()
  displayDriver = displayDriver:gsub("/","\\")
  GFXDevice.setDisplayDevice(displayDriver)

  log('D','graphic','Applying graphic settings: '..tostring(displayDriver)..', '..graphicsOptions.GraphicDisplayModes.get()..', '..tostring(resolutionWidth)..' x '..tostring(resolutionHeight)..' '..tostring(refreshRate)..' Hz')

  local videoMode = {}
  videoMode.width = resolutionWidth
  videoMode.height = resolutionHeight
  videoMode.refreshRate = refreshRate
  videoMode.displayMode = graphicsOptions.GraphicDisplayModes.get()
  GFXDevice.setVideoMode( videoMode )
  if graphicsOptions.GraphicHDREnabled and type(graphicsOptions.GraphicHDREnabled.apply) == "function" then
    graphicsOptions.GraphicHDREnabled.apply()
  end

  delayedHdrOutputMode()

  local skipWindowPlacementRestore = M.skipWindowPlacementRestore
  M.skipWindowPlacementRestore = nil

  if graphicsOptions.GraphicDisplayModes.isWindow() then
    if skipWindowPlacementRestore then
      if graphicsOptions.WindowPlacement and type(graphicsOptions.WindowPlacement.set) == 'function' then
        graphicsOptions.WindowPlacement.set(canvas:getPlacement())
        settings.refreshTSState(true)
        settings.requestSave()
      end
    else
      local desiredwindowPlacement = graphicsOptions.WindowPlacement.get()
      canvas:restorePlacement(desiredwindowPlacement)
    end
  end

  if settings.getValue('GraphicTripleMonitorEnabled') then
    local borderFovDeg = settings.getValue('GraphicTripleMonitorBordersFovDeg')
    local centerFovDeg = settings.getValue('GraphicTripleMonitorCenterFovDeg')
    local leftFovDeg = settings.getValue('GraphicTripleMonitorLeftFovDeg')
    local rightFovDeg = settings.getValue('GraphicTripleMonitorRightFovDeg')
    Engine.setRenderMode(((leftFovDeg > 0) or (rightFovDeg > 0)) and "MultiMonitor" or "SingleMonitor", math.rad(centerFovDeg), math.rad(leftFovDeg), math.rad(rightFovDeg), math.rad(borderFovDeg))
  else
    Engine.setRenderMode("SingleMonitor", 0, 0, 0, 0)
  end

  M.triggered_manual_save = false
  M.appliedChanges = true
end


local function videoModeFromString( videoModeStr )
  local canvas = scenetree.findObject("Canvas")

  if not canvas then
    return
  end

  local vm = { width = 0, height = 0, displayMode = "", bitDepth = 0, refreshRate = 0, antialiasLevel = 0}
  local entries = split( videoModeStr, ' ')
  local count = tableSize(entries)
  if count == 6 then
    if tonumber( entries[1] ) then vm.width = tonumber( entries[1] ) end
    if tonumber( entries[2] ) then vm.height = tonumber( entries[2] ) end
    if tonumber( entries[4] ) then vm.bitDepth = tonumber( entries[4] ) end
    if tonumber( entries[5] ) then vm.refreshRate = tonumber( entries[5] ) end
    if tonumber( entries[6] ) then vm.antialiasLevel = tonumber( entries[6] ) end

    vm.displayMode = entries[3]
  end

  return vm
end

local function getDefault()
  local data = {}
  local vm = videoModeFromString(getDesktopVideoMode())
  data.GraphicDisplayResolutions = vm.width .. ' ' .. vm.height
  data.GraphicDisplayRefreshRates = vm.refreshRate
  return data
end

local restartDialogShowed = {}
local function openNeedRestartDialog(reason)
  if not restartDialogShowed[reason] then
    restartDialogShowed[reason] = true
    local result = messageBox(_tr("ui.options.graphics.gpu.change.title"), _tr("ui.options.graphics.gpu.change.description"), 4, 2)
  end
end

local function gcd(a, b)
  a = math.abs(a)
  b = math.abs(b)

  while b ~= 0 do
    a, b = b, a % b
  end

  return a
end

local preferredRatios = {
  {16, 9},
  {16, 10},
  {4, 3},
  {5, 4},
  {21, 9},
  {32, 9},
  {3, 2},
}

local function getAspectRatio(w, h)
  w = tonumber(w)
  h = tonumber(h)

  if not w or not h or w <= 0 or h <= 0 then
    return ''
  end

  w = math.floor(w + 0.5)
  h = math.floor(h + 0.5)

  local actual = w / h

  local tolerance = 0.005

  for _, ratio in ipairs(preferredRatios) do
    local rw, rh = ratio[1], ratio[2]
    local target = rw / rh

    if math.abs(actual - target) / target <= tolerance then
      return '(' .. rw .. ':' .. rh .. ')'
    end
  end

  local divisor = gcd(w, h)
  if divisor <= 0 then
    return ''
  end

  local rw = w / divisor
  local rh = h / divisor

  -- Prefer 16:10 over reduced 8:5
  if rw == 8 and rh == 5 then
    rw, rh = 16, 10
  end

  return '(' .. tostring(rw) .. ':' .. tostring(rh) .. ')'
end

local function getGPU()
  local gpu = VariableRegistry.get( '$pref::Video::gpu' )
  local adapters = GFXInit.getAdapters()
  for _,adapter in ipairs(adapters) do
    if gpu ~= '' and adapter.gpu == gpu then return gpu end
    if gpu == '' and adapter.gpu ~= '' then return adapter.gpu end
  end

  gpu = adapters[1] and adapters[1].gpu or ""
  VariableRegistry.set( '$pref::Video::gpu', gpu )
  return gpu
end

local function getGFX()
  local gfx = VariableRegistry.get( '$pref::Video::displayDevice' )
  local adapters = GFXInit.getAdapters()
  for _,adapter in ipairs(adapters) do
    if gfx ~= '' and adapter.gfx == gfx then return gfx end
    if gfx == '' and adapter.gfx ~= '' then  return adapter.gfx end
  end

  gfx = adapters[1] and adapters[1].gfx or ""
  VariableRegistry.set( '$pref::Video::displayDevice', gfx )
  return gfx
end

local function updateDisplayInfoWindowRegion()
  local canvas = scenetree.findObject("Canvas")
  if canvas then
    graphicInformation = graphicInformation or {}
    local left, top, width, height = canvas:getWindowBounds()
    graphicInformation.mainWindowRegion = {left = left, top = top, width = width, height = height}
  end
end

local function gatherDisplayInformation()
  -- log('I','','gatherDisplayInformation called....')
  graphicInformation = {}
  graphicInformation.gpu = getGPU()
  graphicInformation.api = getGFX()
  local adapters = GFXInit.getAdapters()
  graphicInformation.outputs = {}
  for k, a in ipairs(adapters) do
    if a.gpu == graphicInformation.gpu and a.gfx == graphicInformation.api then
      local left, top, width, height = GFXDevice.getDisplayRegion(a.output:gsub("/","\\"))
      local hertz = GFXDevice.getDisplayRefreshRate(a.output:gsub("/","\\"))
      a.output = a.output:gsub("\\","/")
      table.insert(graphicInformation.outputs, {monitorName = a.monitor, output = a.output, region = {left = left, top = top, width = width, height = height}, refreshRate = hertz })
    end
  end
  updateDisplayInfoWindowRegion()
  -- log('I','','graphicInformation: '..dumps(graphicInformation))
end

local function buildOptionHelpers()
  local o = {}

  -- Settings GraphicDisplayModes
  o.GraphicDisplayModes = {
    displayMode = "Window",
    get = function ()
      return o.GraphicDisplayModes.displayMode
    end,
    set = function ( value )
      o.GraphicDisplayModes.displayMode = value
    end,
    getModes = function()
      return {keys={"Borderless", "Fullscreen", "Window"},
      values={"ui.options.graphics.displayMode.borderless", "ui.options.graphics.displayMode.fullScreen", "ui.options.graphics.displayMode.window"}}
    end,
    isFullscreen = function()
      return o.GraphicDisplayModes.displayMode == "Fullscreen"
    end,
    isWindow = function()
      return o.GraphicDisplayModes.displayMode == "Window"
    end,
    isBorderless = function()
      return o.GraphicDisplayModes.displayMode == "Borderless"
    end,
    sanitize = function(shouldLog)
      local current = o.GraphicDisplayModes.get()
      local modes = o.GraphicDisplayModes.getModes()
      for _,v in ipairs(modes.keys) do
        if current == v then
          if shouldLog then log('D', 'graphic',"Sanitizing display mode - "..tostring(current)..": Passed.") end
          return
        end
      end
      if shouldLog then log('D', 'graphic',"Sanitizing display mode - "..tostring(current)..": Failed. Patching to display mode 'Window'") end
      o.GraphicDisplayModes.set('Window')
    end
  }

  -- Settings GraphicResolutions
  o.GraphicDisplayResolutions = {
    width = 0,
    height = 0,
    SelectHighestForDisplay = function (displayName)
      local displayResolution = GFXDevice.getDisplayDesktopResolution(displayName:gsub("/","\\"))
      o.GraphicDisplayResolutions.width = displayResolution.width or 1280
      o.GraphicDisplayResolutions.height = displayResolution.height or 720
    end,
    getWidthHeight = function ()
      if o.GraphicDisplayResolutions.width == 0 or o.GraphicDisplayResolutions.height == 0 then
        o.GraphicDisplayResolutions.get()
      end
      return o.GraphicDisplayResolutions.width, o.GraphicDisplayResolutions.height
    end,
    get = function ()
      if o.GraphicDisplayResolutions.width == 0 or o.GraphicDisplayResolutions.height == 0 then
        local videoMode = GFXDevice.getDesktopMode()
        o.GraphicDisplayResolutions.width = videoMode.width or 1280
        o.GraphicDisplayResolutions.height = videoMode.height or 720
      end
      return o.GraphicDisplayResolutions.width .. ' ' .. o.GraphicDisplayResolutions.height
    end,
    set = function ( value )
      o.GraphicDisplayResolutions.width, o.GraphicDisplayResolutions.height = value:match(' *(%d*) +(%d*)')
      o.GraphicDisplayResolutions.width = tonumber(o.GraphicDisplayResolutions.width) or 1280
      o.GraphicDisplayResolutions.height = tonumber(o.GraphicDisplayResolutions.height) or 720
    end,
    getModes = function()
      local keys = {}
      local values = {}
      local addedRes = {}

      local getKey = function(vm)
        return vm.width ..' '.. vm.height
      end

      local getValue = function(vm)
        return vm.width..' x '..vm.height..' '..getAspectRatio(vm.width, vm.height)
      end

      local videoModeList = GFXDevice.getDisplayVideoModes(o.GraphicDisplayDriver.get():gsub("/","\\"))
      table.sort(videoModeList, function(a, b)
                                if a.width == b.width then
                                  return a.height > b.height
                                end
                                return a.width > b.width
                              end
                              )

      for k, vm in ipairs(videoModeList) do
        local key = getKey(vm)
        if addedRes[key] == nil and vm.height > 400 then
          addedRes[key] = 1
          table.insert(keys, key)
          table.insert(values, getValue(vm) )
        end
      end
      return {keys=keys, values=values}
    end,
    sanitize = function(shouldLog)
      local current = o.GraphicDisplayResolutions.get()
      local displayMode = o.GraphicDisplayModes.get()
      if displayMode == 'Window' then
        if shouldLog then log('D', 'graphic',"Sanitizing display resolution for Window mode - "..tostring(current)..": Passed.") end
        return
      end
      local modes = o.GraphicDisplayResolutions.getModes()
      for _,v in ipairs(modes.keys) do
        if current == v then
          if shouldLog then log('D', 'graphic',"Sanitizing display resolution - "..tostring(current)..": Passed.") end
          return
        end
      end
      local canvas = scenetree.findObject("Canvas")
      local desktopMode = GFXDevice.getDesktopMode() or {width = 1280, height = 720}
      local newMode = tostring(desktopMode.width)..' '..tostring(desktopMode.height)
      if shouldLog then log('D', 'graphic',"Sanitizing display resolution - "..tostring(current)..": Failed. Patching to "..newMode) end
      o.GraphicDisplayResolutions.set(newMode)
    end,
    init = function ( value )
      o.GraphicDisplayResolutions.width, o.GraphicDisplayResolutions.height = value:match(' *(%d*) +(%d*)')
      o.GraphicDisplayResolutions.width = tonumber(o.GraphicDisplayResolutions.width) or 1280
      o.GraphicDisplayResolutions.height = tonumber(o.GraphicDisplayResolutions.height) or 720
    end,
  }

  -- Settings GraphicDisplayRefreshRates
  o.GraphicDisplayRefreshRates = {
    hertz = 0,
    get = function ()
      if o.GraphicDisplayRefreshRates.hertz == 0 then
        local refreshRates = o.GraphicDisplayRefreshRates.getModes()
        local found = false
        for _,v in ipairs(refreshRates.keys) do
          if o.GraphicDisplayRefreshRates.hertz == v then
            found = true
            break
          end
        end
        if not found then
          local desktopRes = videoModeFromString(getDesktopVideoMode())
          o.GraphicDisplayRefreshRates.hertz = refreshRates.keys[1] or desktopRes.refreshRate or 60
        end
      end
      return o.GraphicDisplayRefreshRates.hertz
    end,
    set = function ( value )
      local displayMode = o.GraphicDisplayModes.get()
      if displayMode == 'Window' then return end
      if value then
        o.GraphicDisplayRefreshRates.hertz = tonumber(value)
      end
    end,
    getModes = function()
      local keys = {}
      local values = {}
      local addedRes = {}

      local resolutionWidth, resolutionHeight = o.GraphicDisplayResolutions.getWidthHeight()
      local videoModeList = GFXDevice.getDisplayVideoModes(o.GraphicDisplayDriver.get():gsub("/","\\"))
      for k, vm in ipairs(videoModeList) do
        if vm.width == resolutionWidth and vm.height == resolutionHeight then
          local key = vm.refreshRate
          if addedRes[key] == nil and vm.height > 400 then
            addedRes[key] = 1
            table.insert(keys, key)
          end
        end
      end
      table.sort(keys, function(a, b) return a > b end)
      for i=1,#keys do
        table.insert(values, keys[i]..'Hz')
      end
      return {keys=keys, values=values}
    end,
    sanitize = function(shouldLog)
      local current = o.GraphicDisplayRefreshRates.get()
      local displayMode = o.GraphicDisplayModes.get()
      if displayMode == 'Window' then return end
      local modes = o.GraphicDisplayRefreshRates.getModes()
      for _,v in ipairs(modes.keys) do
        if current == v then
          if shouldLog then log('D', 'graphic', "Sanitizing refresh rate - "..tostring(current)..": Passed.") end
          return
        end
      end
      if shouldLog then log('D', 'graphic',"Sanitizing refresh rate - "..tostring(current)..": Failed. Patching to "..tostring(modes.keys[1]).." hertz") end
      o.GraphicDisplayRefreshRates.set(modes.keys[1])
    end
  }

  -- SettingsGraphicDisplayDriver
  o.GraphicDisplayDriver = {
    adapter = nil,
    get = function ()
      if not o.GraphicDisplayDriver.adapter then
        local adapters = GFXInit.getAdapters()
        o.GraphicDisplayDriver.adapter = adapters[1]
      end

      return o.GraphicDisplayDriver.adapter.output:gsub("\\","/")
    end,
    set = function ( value )
      value = value and value:gsub("/","\\") or ""
      local adapters = GFXInit.getAdapters()
      for i, a in ipairs(adapters) do
        if a.output == value then
          o.GraphicDisplayDriver.adapter = a
          return
        end
      end
    end,
    getModes = function()
      local keys = {}
      local values = {}
      local currentGPU = getGPU()
      local currentGFX = getGFX()
      local adapters = GFXInit.getAdapters()
      for k, a in ipairs(adapters) do
        if a.gpu == currentGPU and a.gfx == currentGFX then
          a.output = a.output:gsub("\\","/")
          table.insert(keys, a.output)
          table.insert(values, a.monitor)
        end
      end
      return {keys=keys, values=values}
    end,
    sanitize = function(shouldLog)
      local current = o.GraphicDisplayDriver.get()
      local modes = o.GraphicDisplayDriver.getModes()
      for _,v in pairs(modes.keys) do
        if current == v then
          if shouldLog then log('D', 'graphic',"Sanitizing display - "..tostring(current)..": Passed.") end
          return
        end
      end
      if shouldLog then log('D', 'graphic',"Sanitizing display - "..tostring(current)..": Failed. Patching to display '"..tostring(modes.keys[1]).."'") end
      o.GraphicDisplayDriver.adapter = o.GraphicDisplayDriver.set(modes.keys[1])
    end
  }

  o.GraphicGPU = {
    get = function ()
      return getGPU()
    end,
    set = function ( value )
      local currentGPU = getGPU()
      VariableRegistry.set( '$pref::Video::gpu', value )
      local newGPU = getGPU()

      if currentGPU ~= newGPU then
        local adapters = GFXInit.getAdapters()
        for k, a in ipairs(adapters) do
          if a.gpu == newGPU then
            a.output = a.output:gsub("/","\\")
            GFXDevice.setDisplayDevice(newGPU)
            return
          end
        end
        openNeedRestartDialog("GraphicGPU")
      end
    end,
    getModes = function()
      local keys = {}
      local values = {}
      local gpus = {}
      local adapters = GFXInit.getAdapters()
      for k, a in ipairs(adapters) do
        if not gpus[a.gpu] then
          table.insert(keys, a.gpu)
          table.insert(values, a.gpu)
          gpus[a.gpu] = true
        end
      end
      return {keys=keys, values=values}
    end
  }

  o.WindowPlacement = {
    placement = "",
    get = function ()
      if o.WindowPlacement.placement == "" then
        local canvas = scenetree.findObject("Canvas")
        o.WindowPlacement.placement =  canvas and canvas:getPlacement() or ""
      end
      return o.WindowPlacement.placement
    end,
    set = function ( value )
      o.WindowPlacement.placement = value
      updateDisplayInfoWindowRegion()
    end,
    init = function ( value )
      o.WindowPlacement.placement = value
    end,
  }

  o.uiUpscaling = {
    get = function()
      return CEF_UI_maxSizeHeight
    end,

    set = function(value)
      CEF_UI_maxSizeHeight = value
      if value ~= VariableRegistry.get('$CEF_UI::maxSizeHeight') then
        VariableRegistry.set('$CEF_UI::maxSizeHeight', tonumber(value))
      end
    end,
    getModes = function()
      return {keys={720, 1080, 1440, 0}, values={'1280 x 720', '1920 x 1080', '2560 x 1440', 'ui.options.graphics.uimaxresUnlimited'}}
    end
  }

  o.vulkanEnabled = {
    get = function ()
      return Engine.getVulkanEnabled()
    end,
    set = function ( value )
      Engine.setVulkanEnabled(value)
    end
  }

  -- SettingsGraphicHDR
  o.GraphicHDRSupported = {
    get = function()
      return hdrSupported()
    end
  }

  o.GraphicHDREnabled = {
    get = function()
      return settings.getValue("GraphicHDREnabled", false)
    end,

    set = function(value)
      local requested = value == true
      local active = requested and hdrSupported()

      settings.setValue("GraphicHDREnabled", requested)

      if requested and not active then
        log("D", "graphic", "HDR requested but current display does not support HDR. Keeping HDR preference enabled.")
      end

      if GFXHdr then
        if type(GFXHdr.setRequested) == "function" then
          GFXHdr.setRequested(active)
        end

        if type(GFXHdr.applyRequested) == "function" then
          GFXHdr.applyRequested()
        end

        if active then
          if type(GFXHdr.setPaperWhiteNits) == "function" then
            GFXHdr.setPaperWhiteNits(tonumber(settings.getValue("GraphicHDRPaperWhiteNits", 250)) or 250)
          end

          if type(GFXHdr.setPeakWhiteNits) == "function" then
            GFXHdr.setPeakWhiteNits(tonumber(settings.getValue("GraphicHDRPeakWhiteNits", 1200)) or 1200)
          end

          if type(GFXHdr.setUiMultiplier) == "function" then
            GFXHdr.setUiMultiplier(tonumber(settings.getValue("GraphicHDRUiMultiplier", 1.5)) or 1.5)
          end
        end
      end

      delayedHdrOutputMode()
    end,

    init = function(value)
      o.GraphicHDREnabled.set(value)
    end,

    apply = function()
      o.GraphicHDREnabled.set(settings.getValue("GraphicHDREnabled", false))
    end
  }

  o.GraphicHDRPaperWhiteNits = {
    get = function()
      return tonumber(settings.getValue("GraphicHDRPaperWhiteNits", 250)) or 250
    end,

    set = function(value)
      value = tonumber(value) or 250
      settings.setValue("GraphicHDRPaperWhiteNits", value)

      if hdrSupported() and GFXHdr and type(GFXHdr.setPaperWhiteNits) == "function" then
        GFXHdr.setPaperWhiteNits(value)
      end
    end,

    init = function(value)
      settings.setValue("GraphicHDRPaperWhiteNits", tonumber(value) or 250)
    end
  }

  o.GraphicHDRPeakWhiteNits = {
    get = function()
      return tonumber(settings.getValue("GraphicHDRPeakWhiteNits", 1200)) or 1200
    end,

    set = function(value)
      value = tonumber(value) or 1200
      settings.setValue("GraphicHDRPeakWhiteNits", value)

      if hdrSupported() and GFXHdr and type(GFXHdr.setPeakWhiteNits) == "function" then
        GFXHdr.setPeakWhiteNits(value)
      end
    end,

    init = function(value)
      settings.setValue("GraphicHDRPeakWhiteNits", tonumber(value) or 1200)
    end
  }

  o.GraphicHDRUiMultiplier = {
    get = function()
      return tonumber(settings.getValue("GraphicHDRUiMultiplier", 1.5)) or 1.5
    end,

    set = function(value)
      value = tonumber(value) or 1.5
      settings.setValue("GraphicHDRUiMultiplier", value)

      if hdrSupported() and GFXHdr and type(GFXHdr.setUiMultiplier) == "function" then
        GFXHdr.setUiMultiplier(value)
      end
    end,

    init = function(value)
      settings.setValue("GraphicHDRUiMultiplier", tonumber(value) or 1.5)
    end
  }

  o.GraphicHDROutputModeName = {
    get = function()
      return settings.getValue("GraphicHDROutputModeName", getHdrOutputModeName())
    end
  }

  o.GraphicEVCompensation = {
    get = function()
      return tonumber(settings.getValue("GraphicEVCompensation", 0)) or 0
    end,

    set = function(value)
      value = math.max(-3, math.min(3, tonumber(value) or 0))
      settings.setValue("GraphicEVCompensation", value)
      applyExposureCompensation(value)
    end,

    init = function(value)
      o.GraphicEVCompensation.set(value)
    end
  }

  -- SettingsGraphicSync
  o.vsync = {
    get = function ()
      local v = VariableRegistry.get('$video::vsync')
      return v
    end,
    set = function ( value )
      local boolValue = value == true or (type(value)=="number" and value > 0)
      VariableRegistry.set( '$video::vsync', boolValue )
    end,
    getModes = function()
      return {keys={false, true}, values={'Off', 'On'}}
    end
  }

  o.GraphicAntialiasType = {
    get = function ()
      local value = settings.getValue('GraphicAntialiasType')
      -- log('I','','get GraphicAntialiasType = '..tostring(value))
      return value
    end,
    set = function ( value )
      local enabled = o.GraphicAntialias.get();
      if enabled == 0 then return end

      local smaaPostEffect = scenetree.findObject("SMAA_PostEffect")
      local fxaaPostEffect = scenetree.findObject("FXAA_PostEffect")
      if value == "fxaa" then
        if smaaPostEffect then smaaPostEffect:disable() end
        if fxaaPostEffect then fxaaPostEffect:enable() end
      elseif value == "smaa" then
        if fxaaPostEffect then fxaaPostEffect:disable() end
        if smaaPostEffect then smaaPostEffect:enable() end
      end
      settings.setValue('GraphicAntialiasType', value)
    end,
    getModes = function ()
      return {keys={'fxaa', 'smaa'}, values={'FXAA', 'SMAA'}}
    end
  }

  -- SettingsGraphicAntialias
  o.GraphicAntialias = {
    get = function ()
      return settings.getValue('GraphicAntialias')
    end,
    set = function ( value )
      local SMAA_PostEffect = scenetree.findObject("SMAA_PostEffect")
      if not SMAA_PostEffect then return end
      local FXAA_PostEffect = scenetree.findObject("FXAA_PostEffect")
      if not FXAA_PostEffect then return end
      if tonumber(value) == 0 then
        SMAA_PostEffect:disable()
        FXAA_PostEffect:disable()
      else
        local antialiasType = settings.getValue('GraphicAntialiasType')
        if antialiasType == 'fxaa' then
          FXAA_PostEffect:enable()
        else
          SMAA_PostEffect:enable()
        end
      end
      settings.setValue('GraphicAntialias', value)
    end,
    getModes = function()
      return {keys={"0", "1", "2", "4"}, values={"Off", "x1", "x2", "x4"}}
    end
  }

  -- SettingsGraphicAnisotropic
  o.GraphicAnisotropic = {
    get = function ()
      return tonumber(VariableRegistry.get('$pref::Video::defaultAnisotropy'))
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::Video::defaultAnisotropy', value )
    end,
    getModes = function()
      return {keys={"0", "2","4", "8", "16"}, values={"Off", "x2", "x4", "x8", "x16"}}
    end
  }

  -- SettingsGraphicOverallQuality
  o.GraphicOverallQuality = {
    presetKeys = {},
    qualityLevel = '3',
    get = function (value)
      return o.GraphicOverallQuality.qualityLevel
    end,
    set = function (value)
      -- log('I','graphic',' setting GraphicOverallQuality = '..tostring(value))

      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end

      if type(value) == 'number' then
        if usingPlatformPresets then
          value = platformPresetOrder[clamp(value + 1, 1, #platformPresetOrder)]
        else
          local upgrade_old_id_to_name = {'Custom', 'Lowest', 'Low', 'Normal', 'High', 'Ultra'}
          value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
        end
      end

      local levelData = overallQualityPresets[value]
      if type(levelData) ~= "table" then
        log("W", logTag, "Tried to apply unknown graphics preset: " .. tostring(value))
        return
      end

      o.GraphicOverallQuality.qualityLevel = tostring(value)
      for k, v in pairs(levelData) do
        if o[k] and type(o[k].set) == "function" then
          o[k].set(v)
        else
          settings.setValue(k, v)
        end
      end
      setBloomEnabledForLightingQuality(o.GraphicLightingQuality.get())
      if usingPlatformPresets then
        settings.refreshTSState(true)

        -- applyGraphicsState needs Canvas/GFX to exist. Avoid calling it too early.
        if scenetree.findObject("Canvas") and applyGraphicsState then
          applyGraphicsState()
        else
          settings.requestSave()
        end

        settings.notifyUI()
      end
    end,
    getModes = function()
      if usingPlatformPresets then
        local keys = {}
        local values = {}

        for _, name in ipairs(platformPresetOrder) do
          table.insert(keys, name)
          table.insert(values, name)
        end

        return {keys = keys, values = values}
      end

      local keys = {'Custom', 'Lowest', 'Low', 'SteamDeck', 'Normal', 'High', 'Ultra'}
      local values = {
        'ui.options.graphics.Custom',
        'ui.options.graphics.Lowest',
        'ui.options.graphics.Low',
        'ui.options.graphics.SteamDeck',
        'ui.options.graphics.Normal',
        'ui.options.graphics.High',
        'ui.options.graphics.Ultra'
      }

      for _, name in ipairs(internalPresetOrder) do
        table.insert(keys, name)
        table.insert(values, name)
      end

      return {keys = keys, values = values}
    end,
    init = function ()
      local temp = {}

      for _, group in pairs(overallQualityPresets) do
        if type(group) == "table" then
          for key, _ in pairs(group) do
            if not (usingPlatformPresets and platformPresetIgnoreForCustomDetection[key]) then
              temp[key] = true
            end
          end
        end
      end

      o.GraphicOverallQuality.presetKeys = {}

      for k, _ in pairs(temp) do
        table.insert(o.GraphicOverallQuality.presetKeys, k)
      end

      -- log('I','','building preset keys: '..dumps(o.GraphicOverallQuality.presetKeys))
    end,
    onSettingsChanged = function ()
      -- log('I','','onSettingsChanged called.....')

      local matchedGroupIndex = nil
      local presetKeys = o.GraphicOverallQuality.presetKeys or {}

      for index, group in pairs(overallQualityPresets) do
        if type(group) == "table" then
          local matchFound = true

          for _, presetKey in ipairs(presetKeys) do
            local current

            if o[presetKey] and type(o[presetKey].get) == "function" then
              current = o[presetKey].get()
            else
              current = settings.getValue(presetKey)
            end

            local presetValue = group[presetKey]

            if tostring(presetValue) ~= tostring(current) then
              matchFound = false
              break
            end
          end

          if matchFound then
            matchedGroupIndex = index
            break
          end
        end
      end

      if matchedGroupIndex == nil then
        if usingPlatformPresets then
          return
        end

        o.GraphicOverallQuality.set(0) -- Custom
        return
      end

      o.GraphicOverallQuality.qualityLevel = tostring(matchedGroupIndex)
    end
  }

  -- SettingsGraphicMeshQuality
  o.GraphicMeshQuality = {
    qualityLevel = "Normal",

    get = function ()
      return o.GraphicMeshQuality.qualityLevel
    end,

    set = function ( value )
      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end
      if type(value) == 'number' then
        local upgrade_old_id_to_name = {'Lowest', 'Low', 'Normal', 'High', 'Ultra'}
        value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
      end

      meshQualityGroup:applyLevel(value)
      o.GraphicMeshQuality.qualityLevel = value
    end,

    getModes = function()
      return {keys={'Lowest', 'Low', 'Normal', 'High', 'Ultra'}, values={'ui.options.graphics.Lowest', 'ui.options.graphics.Low', 'ui.options.graphics.Normal', 'ui.options.graphics.High', 'ui.options.graphics.Ultra'}}
    end
  }

  -- SettingsGraphicTerrainQuality
  o.GraphicTerrainQuality = {
    qualityLevel = "Normal",

    get = function ()
      return o.GraphicTerrainQuality.qualityLevel
    end,

    set = function ( value )
      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end
      if type(value) == 'number' then
        local upgrade_old_id_to_name = {'Lowest', 'Low', 'Normal', 'High'}
        value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
      end

      terrainQualityGroup:applyLevel(value)
      o.GraphicTerrainQuality.qualityLevel = value
    end,

    getModes = function()
      return {keys={'Lowest', 'Low', 'Normal', 'High'}, values={'ui.options.graphics.Lowest', 'ui.options.graphics.Low', 'ui.options.graphics.Normal', 'ui.options.graphics.High'}}
    end
  }

  -- SettingsGraphicTextureQuality
  o.GraphicTextureQuality = {
    qualityLevel = "Normal",

    get = function ()
      return o.GraphicTextureQuality.qualityLevel
    end,

    set = function ( value )
      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end
      if type(value) == 'number' then
        local upgrade_old_id_to_name = {'Lowest', 'Low', 'Normal'}
        value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
      end

      if value == "High" then
        value = "Normal"
      end

      textureQualityGroup:applyLevel(value)
      o.GraphicTextureQuality.qualityLevel = value
    end,

    getModes = function()
      return {keys={'Lowest', 'Low', 'Normal'}, values={'ui.options.graphics.Lowest', 'ui.options.graphics.Low', 'ui.options.graphics.Normal'}}
    end
  }

  -- SettingsGraphicLightingQuality
  o.GraphicLightingQuality = {
    qualityLevel = "High",

    get = function ()
      return o.GraphicLightingQuality.qualityLevel
    end,

    set = function ( value )
      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end
      if type(value) == 'number' then
        local upgrade_old_id_to_name = {'Lowest', 'Low', 'High', 'Ultra'}
        value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
      end

      if value == "Normal" then
        value = "High"
      end

      lightingQualityGroup:applyLevel(value)
      o.GraphicLightingQuality.qualityLevel = value
      setBloomEnabledForLightingQuality(value)

      if PSSMLightShadowMap then
        PSSMLightShadowMap.penumbraEnabled = value == "Ultra"
      end
    end,

    getModes = function()
      return {keys={'Lowest', 'Low', 'High', 'Ultra'}, values={'ui.options.graphics.Lowest', 'ui.options.graphics.Low', 'ui.options.graphics.High', 'ui.options.graphics.Ultra'}}
    end
  }

  -- SettingsGraphicShadowQuality
  o.GraphicShadowsQuality = {
    qualityLevel = "Normal",

    get = function ()
      return o.GraphicShadowsQuality.qualityLevel
    end,

    set = function ( value )
      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end
      if type(value) == 'number' then
        local upgrade_old_id_to_name = {'Disabled', 'Lowest', 'Low', 'Normal', 'High', 'Ultra'}
        value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
      end

      shadowsQualityGroup:applyLevel(value)
      if PSSMLightShadowMap and shadowsQuality.vehicleTexSizes[value] then
        PSSMLightShadowMap.vehicleTexSize = shadowsQuality.vehicleTexSizes[value]
      end
      o.GraphicShadowsQuality.qualityLevel = value
      if value == "Disabled" then
        setScreenSpaceShadowsEnabled(false)
      end
    end,

    getModes = function()
      return {keys={'Disabled', 'Lowest', 'Low', 'Normal', 'High', 'Ultra'}, values={'ui.options.graphics.shadows.none', 'ui.options.graphics.Lowest', 'ui.options.graphics.Low', 'ui.options.graphics.Normal', 'ui.options.graphics.High', 'ui.options.graphics.Ultra'}}
    end
  }

  -- GraphicDynReflectionEnabled
  o.GraphicDynReflectionEnabled = {
    get = function ()
      return VariableRegistry.get( '$pref::BeamNGVehicle::dynamicReflection::enabled' ) ~= false
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicReflection::enabled', value )
    end
  }

  -- GraphicDynReflectionFacesPerupdate
  o.GraphicDynReflectionFacesPerupdate = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicReflection::facesPerUpdate' ) )
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicReflection::facesPerUpdate', value )
    end
  }

  -- GraphicDynReflectionDetail
  o.GraphicDynReflectionDetail = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicReflection::detail' ) )
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicReflection::detail', value )
    end
  }

  -- GraphicDynReflectionDistance
  o.GraphicDynReflectionDistance = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicReflection::distance' ) )
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicReflection::distance', value )
    end
  }

  -- GraphicDynReflectionTexsize
  o.GraphicDynReflectionTexsize = {
    get = function ()
      local value = math.log(tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicReflection::textureSize' ) ) )/math.log( 2 )
      return value - 7
    end,
    set = function ( value )
      value = math.pow(2, value + 7)
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicReflection::textureSize', value )
    end
  }

  -- GraphicDynMirrorsEnabled
  o.GraphicDynMirrorsEnabled = {
    get = function ()
      return VariableRegistry.get( '$pref::BeamNGVehicle::dynamicMirrors::enabled' ) ~= false
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicMirrors::enabled', value )
    end
  }

  -- GraphicDynMirrorsDetail
  o.GraphicDynMirrorsDetail = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicMirrors::detail' ) )
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicMirrors::detail', value )
    end
  }

  -- GraphicDynMirrorsDistance
  o.GraphicDynMirrorsDistance = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicMirrors::distance' ) )
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicMirrors::distance', value )
    end
  }

  -- GraphicDynMirrorsTexsize
  o.GraphicDynMirrorsTexsize = {
    get = function ()
      local value = math.log(tonumber( VariableRegistry.get( '$pref::BeamNGVehicle::dynamicMirrors::textureSize' ) ) )/math.log( 2 )
      return value - 7
    end,
    set = function ( value )
      value = math.pow(2, value + 7)
      VariableRegistry.set( '$pref::BeamNGVehicle::dynamicMirrors::textureSize', value )
    end
  }

  -- SettingsGraphicCloudsQuality
  o.GraphicCloudsQuality = {
    get = function ()
      local value = settings.getValue('GraphicCloudsQuality')
      return value
    end,
    set = function ( value )
      local cloudLayer = CloudLayer
      if not cloudLayer then return end
      if value == "Disabled" then
        cloudLayer.volumetricEnabled = false
      elseif value == "High" then
        cloudLayer.volumetricEnabled = true
        cloudLayer.vrtDownsampleFactor = 4
        cloudLayer.shadowLutUpdateGroupSize = 2
      elseif value == "Normal" then
        cloudLayer.volumetricEnabled = true
        cloudLayer.vrtDownsampleFactor = 6
        cloudLayer.shadowLutUpdateGroupSize = 4
      elseif value == "Low" then
        cloudLayer.volumetricEnabled = true
        cloudLayer.vrtDownsampleFactor = 8
        cloudLayer.shadowLutUpdateGroupSize = 8
      end
      settings.setValue('GraphicCloudsQuality', value)
    end,
    getModes = function ()
      return {keys={'Disabled', 'Low', 'Normal', 'High'}, values={'ui.options.graphics.shadows.none', 'ui.options.graphics.Low', 'ui.options.graphics.Normal', 'ui.options.graphics.High'}}
    end
  }

  -- SettingsPostFXDOFGeneralEnabled
  o.PostFXDOFGeneralEnabled = {
    get = function ()
      local DOFPostEffect = scenetree.findObject("DOFPostEffect")
      if not DOFPostEffect then return end
      return DOFPostEffect:isEnabled() ~= false
    end,
    set = function ( value )
      VariableRegistry.set( '$DOFPostFx::Enable', value )
      local DOFPostEffect = scenetree.findObject("DOFPostEffect")
      if not DOFPostEffect then return end
      if value then
        DOFPostEffect:enable()
      else
        DOFPostEffect:disable()
      end
    end
  }

  -- SettingsPostFXMotionBlurEnabled
  o.PostFXMotionBlurEnabled = {
    get = function ()
      return settings.getValue("PostFXMotionBlurEnabled")
    end,
    set = function ( value )
      settings.setValue("PostFXMotionBlurEnabled", value)
      local fx = scenetree.findObject("PostFxMotionBlur")
      if not fx then return end
      if value then
        fx:enable()
      else
        fx:disable()
      end
    end
  }

  -- SettingsPostFXMotionBlurStrength
  o.PostFXMotionBlurStrength = {
    get = function ()
      return settings.getValue("PostFXMotionBlurStrength")
    end,
    set = function ( value )
      settings.setValue("PostFXMotionBlurStrength", value)
      if scenetree.PostFxMotionBlur then
        scenetree.PostFxMotionBlur.strength = value
      end
    end
  }

  -- PostFXMotionBlurPlayerVehicle
  o.PostFXMotionBlurPlayerVehicle = {
    get = function ()
      return settings.getValue("PostFXMotionBlurPlayerVehicle")
    end,
    set = function ( value )
      settings.setValue("PostFXMotionBlurPlayerVehicle", value)
      BeamNGVehicle.motionBlurPlayerVehiclesEnabled = value
    end
  }

  -- SettingsPostFXSSAOGeneralEnabled
  o.PostFXSSAOGeneralEnabled = {
    get = function ()
      local SSAOPostFx = scenetree.findObject("SSAOPostFx")
      if not SSAOPostFx then return end
      return SSAOPostFx:isEnabled() ~= false
    end,
    set = function ( value )
      --print("********PostFXSSAOGeneralEnabled 2 set") --not tested
      VariableRegistry.set( '$SSAOPostFx::Enable', value )
      local SSAOPostFx = scenetree.findObject("SSAOPostFx")
      if not SSAOPostFx then return end
      if value then
        SSAOPostFx:enable()
      else
        SSAOPostFx:disable()
      end
    end
  }

  -- SettingsPostFXSSAOGeneralQuality
  o.PostFXSSAOGeneralQuality = {
    get = function ()
      local value = settings.getValue('PostFXSSAOGeneralQuality')
      -- log('I','','get PostFXSSAOGeneralQuality = '..tostring(value))
      return value
    end,
    set = function ( value )
      local enabled = o.PostFXSSAOGeneralEnabled.get();
      if enabled == 0 then return end
      local ssao = scenetree.findObject("SSAOPostFx")
      if not ssao then return end
      if value == "High" then
        scenetree.SSAOPostFx:setSamples(64)
      elseif value == "Normal" then
        scenetree.SSAOPostFx:setSamples(16)
      end
      settings.setValue('PostFXSSAOGeneralQuality', value)
    end,
    getModes = function ()
      return {keys={'Normal', 'High'}, values={'ui.options.graphics.Normal', 'ui.options.graphics.High'}}
    end
  }

  o.PostFXScreenSpaceShadowsAvailable = {
    get = function ()
      return scenetree.findObject("ScreenSpaceShadowsPostFx") ~= nil
    end
  }

  -- SettingsPostFXScreenSpaceShadowsEnabled
  o.PostFXScreenSpaceShadowsEnabled = {
    get = function ()
      local sss = scenetree.findObject("ScreenSpaceShadowsPostFx")
      if not sss then return end
      return sss:isEnabled() ~= false
    end,
    set = function ( value )
      if o.GraphicShadowsQuality.get() == "Disabled" then
        value = false
      end
      setScreenSpaceShadowsEnabled(value)
    end
  }

  -- SettingsGraphicGrassDensity
  o.GraphicGrassDensity = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::GroundCover::densityScale' ))
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::GroundCover::densityScale', value )
    end
  }

  -- SettingsGraphicMaxDecalCount
  o.GraphicMaxDecalCount = {
    get = function ()
      return tonumber( VariableRegistry.get( '$pref::TS::maxDecalCount' ))
    end,
    set = function ( value )
      VariableRegistry.set( '$pref::TS::maxDecalCount', value )
    end
  }

  -- SettingsLastSplitCastersEnabled
  o.lastSplitCastersEnabled = {
    get = function ()
      return PSSMLightShadowMap and PSSMLightShadowMap.lastSplitCastersEnabled
    end,
    set = function ( value )
      if PSSMLightShadowMap then
        PSSMLightShadowMap.lastSplitCastersEnabled = value
      end
    end
  }

  -- SettingsVehicleShadowEnabled
  o.vehicleShadowEnabled = {
    get = function ()
      return PSSMLightShadowMap and PSSMLightShadowMap.vehicleShadowEnabled
    end,
    set = function ( value )
      if PSSMLightShadowMap then
        PSSMLightShadowMap.vehicleShadowEnabled = value
      end
    end
  }

  -- SettingsGraphicClusteredQuality
  o.GraphicClusteredQuality = {
    qualityLevel = "Normal",

    get = function ()
      return settings.getValue('GraphicClusteredQuality') or o.GraphicClusteredQuality.qualityLevel
    end,

    set = function ( value )
      if type(value) == 'string' and tonumber(value) then
        value = tonumber(value)
      end
      if type(value) == 'number' then
        local upgrade_old_id_to_name = {'Lowest', 'Low', 'Normal', 'High', 'Ultra'}
        value = upgrade_old_id_to_name[clamp(value + 1, 1, #upgrade_old_id_to_name)]
      end

      if not clusteredQuality.qualityLevels[value] then
        value = "Normal"
      end

      clusteredQuality.applyLevel(value)
      o.GraphicClusteredQuality.qualityLevel = value
      settings.setValue('GraphicClusteredQuality', value)
    end,

    getModes = function()
      return {keys={'Lowest', 'Low', 'Normal', 'High', 'Ultra'}, values={'ui.options.graphics.Lowest', 'ui.options.graphics.Low', 'ui.options.graphics.Normal', 'ui.options.graphics.High', 'ui.options.graphics.Ultra'}}
    end
  }

    -- SkipGenerateLicencePlate
    o.SkipGenerateLicencePlate = {
      get = function()
        return settings.getValue("SkipGenerateLicencePlate")
      end,
      set = function( value )
        settings.setValue("SkipGenerateLicencePlate",value)
      end
    }

  graphicsOptions = o

  return o
end

local function onInitSettings(data)
   -- we have decided to not allow enabling vulkan via settings for now. see also graphics.partial.html
   if false then
    Engine.vulkanEnabled = data.vulkanEnabled
  end

  for k,v in pairs(data) do
    if graphicsOptions[k] and type(graphicsOptions[k].init) == 'function' then
      graphicsOptions[k].init(v)
    end
  end
end

local function onFirstUpdateSettings()
  --log('I', 'graphic', 'onFirstUpdateSettings called.....')
  local canvas = scenetree.findObject("Canvas")
  if not canvas then return end

  if VariableRegistry.get( '$forceFullscreen' ) == true then
    local data = getDefault()
    data.GraphicFullscreen = true
    for k, v in pairs(data) do
      settings.setValue(k, v)
    end
  end

  log('D', 'graphic', 'Available Video Modes : '..dumps(graphicsOptions.GraphicDisplayResolutions.getModes().keys))

  canvas:showWindow()

  gatherDisplayInformation()
end

local function refreshGraphicsState(newState)
  local settingState = ""
  if newState.GraphicDisplayDriver then settingState = newState.GraphicDisplayDriver..', ' end
  if newState.GraphicDisplayModes then settingState = settingState..newState.GraphicDisplayModes..', ' end
  if newState.GraphicDisplayResolutions then settingState = settingState..newState.GraphicDisplayResolutions..', ' end
  if newState.GraphicDisplayRefreshRates then settingState = settingState..newState.GraphicDisplayRefreshRates..' Hz, ' end
  if newState.WindowPlacement then settingState = settingState..newState.WindowPlacement end
  -- log('D','graphics', 'Refreshing graphics settings: '..settingState)

  -- Do not move from here. Has to be done first due to its instant save of settings
  -- other options only save when we call applyGraphicsState, so we do not want the new states for
  -- those saved indirectly
  if newState.WindowPlacement and newState.WindowPlacement ~= M.current_windowPlacement then
    if graphicsOptions.WindowPlacement and type(graphicsOptions.WindowPlacement.set) == 'function' then
      graphicsOptions.WindowPlacement.set(newState.WindowPlacement)
      -- Window placement needs to save immediately due to things like pressing Ctrl + L which
      -- will recreate LUA VM thereby causing the Window to be placed in the old place saved in settings
      -- instead of the new one just made by the user, if the user does not close the game, the change is not saved
      -- so we save immediately to prevent that
      settings.refreshTSState(true)
      settings.requestSave()
    end
  end

  local shouldLogSanitizeMessage = false
  if newState.GraphicDisplayDriver and newState.GraphicDisplayDriver ~= M.selected_displayDriver then
    -- dump(tostring(M.selected_displayDriver) .. '  is now  '.. newState.GraphicDisplayDriver)
    if graphicsOptions.GraphicDisplayDriver and type(graphicsOptions.GraphicDisplayDriver.set) == 'function' then
      graphicsOptions.GraphicDisplayDriver.set(newState.GraphicDisplayDriver)
      graphicsOptions.GraphicDisplayResolutions.SelectHighestForDisplay(newState.GraphicDisplayDriver)
    end
  end

  if newState.GraphicDisplayModes and newState.GraphicDisplayModes ~= M.selected_displayMode then
    -- dump(tostring(M.selected_displayMode) .. '  is now  '.. newState.GraphicDisplayModes)
    if graphicsOptions.GraphicDisplayModes and type(graphicsOptions.GraphicDisplayModes.set) == 'function' then
      graphicsOptions.GraphicDisplayModes.set(newState.GraphicDisplayModes)
      shouldLogSanitizeMessage = true
    end
  end

  if newState.GraphicDisplayResolutions and newState.GraphicDisplayResolutions ~= M.selected_resolution then
    -- dump(tostring(M.selected_resolution) .. '  is now  '.. newState.GraphicDisplayResolutions)
    if graphicsOptions.GraphicDisplayResolutions and type(graphicsOptions.GraphicDisplayResolutions.set) == 'function' then
      graphicsOptions.GraphicDisplayResolutions.set(newState.GraphicDisplayResolutions)
      if graphicsOptions.GraphicDisplayModes and graphicsOptions.GraphicDisplayModes.isWindow() then
        M.skipWindowPlacementRestore = true
      end
      shouldLogSanitizeMessage = true
    end
  end

  -- Update the refresh rate after refreshing the resolution. Refresh rate set depends on the selected resolution
  if newState.GraphicDisplayRefreshRates and newState.GraphicDisplayRefreshRates ~= M.selected_refreshRate then
    -- dump(tostring(M.selected_refreshRate) .. '  is now  '.. newState.GraphicDisplayRefreshRates)
    if graphicsOptions.GraphicDisplayRefreshRates and type(graphicsOptions.GraphicDisplayRefreshRates.set) == 'function' then
      graphicsOptions.GraphicDisplayRefreshRates.set(newState.GraphicDisplayRefreshRates)
    end
  end

  if graphicsOptions.GraphicDisplayModes and graphicsOptions.GraphicDisplayModes.isBorderless() then
    graphicsOptions.GraphicDisplayResolutions.SelectHighestForDisplay(graphicsOptions.GraphicDisplayDriver.get())
  end

  if graphicsOptions.GraphicDisplayDriver then graphicsOptions.GraphicDisplayDriver.sanitize(shouldLogSanitizeMessage) end
  if graphicsOptions.GraphicDisplayModes then graphicsOptions.GraphicDisplayModes.sanitize(shouldLogSanitizeMessage) end
  if graphicsOptions.GraphicDisplayResolutions then graphicsOptions.GraphicDisplayResolutions.sanitize(shouldLogSanitizeMessage) end
  if graphicsOptions.GraphicDisplayRefreshRates then graphicsOptions.GraphicDisplayRefreshRates.sanitize(shouldLogSanitizeMessage) end

  -- Update the states and also allow the other options to refresh internal state
  M.selected_displayMode    = graphicsOptions.GraphicDisplayModes and graphicsOptions.GraphicDisplayModes.get() or ""
  M.selected_displayDriver  = graphicsOptions.GraphicDisplayDriver and graphicsOptions.GraphicDisplayDriver.get() or ""
  M.selected_resolution     = graphicsOptions.GraphicDisplayResolutions and graphicsOptions.GraphicDisplayResolutions.get() or ""
  M.selected_refreshRate    = graphicsOptions.GraphicDisplayRefreshRates and graphicsOptions.GraphicDisplayRefreshRates.get() or ""
  M.current_windowPlacement = graphicsOptions.WindowPlacement and graphicsOptions.WindowPlacement.get() or ""

  settings.refreshTSState(true)
  -- let UI and Lua know
  settings.notifyUI()
end

local function onUiChangedState(toState, fromState)
  if toState == 'menu.options.graphics' then
    M.selected_displayMode = settings.getValue('GraphicDisplayModes', "Window")
    M.selected_displayDriver = settings.getValue('GraphicDisplayDriver', "")
    M.selected_resolution = settings.getValue('GraphicDisplayResolutions', "0 0")
    M.selected_refreshRate = settings.getValue('GraphicDisplayRefreshRates', 0)
    M.current_windowPlacement = settings.getValue('WindowPlacement', " ")
  elseif fromState == 'menu.options.graphics' then
    if not M.appliedChanges then
      refreshGraphicsState({GraphicDisplayModes = M.selected_displayMode, GraphicDisplayResolutions = M.selected_resolution, GraphicDisplayRefreshRates = M.selected_refreshRate})
      M.skipWindowPlacementRestore = nil
    end

    M.appliedChanges = false
  end
end

local function load(newState)
  refreshGraphicsState(newState)
  applyGraphicsState()
end

local function openMonitorConfiguration()
end

local function openCoconutWindow()
  if shipping_build then
    return
  end

  if Engine and Engine.Render and Engine.Render.setCoconutWindowOpen then
    Engine.Render.setCoconutWindowOpen(true)
  end
end

local function autoDetectApplyGraphicsQuality()
  --
  -- TODO(AK) 15/08/2021: RE-Enable after Porting TS startup to LUA
  --                      RE-Enable after Porting TS startup to LUA
  --                      RE-Enable after Porting TS startup to LUA
  --                      RE-Enable after Porting TS startup to LUA
  --                      RE-Enable after Porting TS startup to LUA
  --                      RE-Enable after Porting TS startup to LUA
  --                      RE-Enable after Porting TS startup to LUA
  --

  -- VariableRegistry.set('$pref::Video::autoDetect', false)
  -- local intel = string.find(string.upper(getDisplayDeviceInformation()), "INTEL") ~= nil
  -- local videoMem = GFXDevice.getVideoMemoryMB()

  -- if videoMem == 0 then
  --     log('E','graphic', "Unable to detect available video memory. Applying 'Normal' quality.");
  --     videoMem = 500
  -- end

  -- if videoMem > 1000 then
  --   graphicsOptions.GraphicMeshQuality.set("High")
  --   graphicsOptions.GraphicTextureQuality.set("High")
  --   graphicsOptions.GraphicLightingQuality.set("High")
  --   graphicsOptions.GraphicShaderQuality.set("High")
  --   TorqueScriptLua.call('PostFXManager::settingsApplyHighPreset')
  --   graphicsOptions.GraphicPostfxQuality.set(3)
  -- elseif videoMem >= 500 then
  --   graphicsOptions.GraphicMeshQuality.set("Normal")
  --   graphicsOptions.GraphicTextureQuality.set("Normal")
  --   graphicsOptions.GraphicLightingQuality.set("Normal")
  --   graphicsOptions.GraphicShaderQuality.set("Normal")
  --   TorqueScriptLua.call('PostFXManager::settingsApplyNormalPreset')
  --   graphicsOptions.GraphicPostfxQuality.set(2)
  -- elseif videoMem > 250 then
  --   graphicsOptions.GraphicMeshQuality.set("Low")
  --   graphicsOptions.GraphicTextureQuality.set("Low")
  --   graphicsOptions.GraphicLightingQuality.set("Low")
  --   graphicsOptions.GraphicShaderQuality.set("Low")
  --   TorqueScriptLua.call('PostFXManager::settingsApplyLowPreset')
  --   graphicsOptions.GraphicPostfxQuality.set(1)
  -- else
  --   graphicsOptions.GraphicMeshQuality.set("Lowest")
  --   graphicsOptions.GraphicTextureQuality.set("Lowest")
  --   graphicsOptions.GraphicLightingQuality.set("Lowest")
  --   graphicsOptions.GraphicShaderQuality.set("Lowest")
  --   TorqueScriptLua.call('PostFXManager::settingsApplyLowestPreset')
  --   graphicsOptions.GraphicPostfxQuality.set(0)
  -- end
end

local function onUpdate(dtReal)
  if hdrOutputModeUpdateTimer <= 0 then return end

  hdrOutputModeUpdateTimer = hdrOutputModeUpdateTimer - (dtReal or 0)

  if hdrOutputModeUpdateTimer <= 0 then
    hdrOutputModeUpdateTimer = 0
    updateHdrOutputModeSetting()
  end
end

local function toggleFullscreen()
  local canvas = scenetree.findObject("Canvas")

  if canvas then
    canvas:toggleFullscreen()
  end
end

M.getOptions = function(optionName)
  return optionName and graphicsOptions[optionName] or graphicsOptions
end

M.getDisplayInformation = function()
  return graphicInformation
end

M.onSettingsChanged = function()
  graphicsOptions.GraphicOverallQuality.onSettingsChanged()
end
M.load = load
M.buildOptionHelpers = buildOptionHelpers
M.onInitSettings = onInitSettings
M.onFirstUpdateSettings = onFirstUpdateSettings
M.refreshGraphicsState = refreshGraphicsState
M.applyGraphicsState = applyGraphicsState
M.onUiChangedState = onUiChangedState
M.openMonitorConfiguration = openMonitorConfiguration
M.openCoconutWindow = openCoconutWindow
M.autoDetectApplyGraphicsQuality = autoDetectApplyGraphicsQuality
M.onUpdate = onUpdate
M.toggleFullscreen = toggleFullscreen
M.getOverallQualityPresets = function() return overallQualityPresets end
return M
